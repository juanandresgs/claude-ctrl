"""
braid2.policy_surface — integration surface between braid-v2 and the shared ClauDEX policy authority.

Authority split
---------------
braid-v2 owns:       runtime topology, dispatch, gates, findings, repair
runtime/core owns:   repo law, capability model, policy evaluation, prompt packs

This module defines the four calls braid-v2 makes into the shared policy authority.
Each function either invokes a live pure-function from runtime/core (when the module
is importable and the required inputs are available at the braid-v2 call site) or
returns an explicit ``not_wired`` stub whose ``provenance`` block names the exact
target and explains what the caller must supply to complete the wiring.

Live wiring status per function
--------------------------------
  evaluate_spawn_request   — always not_wired.
    Requires a fully-built PolicyContext from build_context(conn, ...) where
    conn is the runtime SQLite DB. braid-v2 does not hold that connection.
    Wiring path: pass the call through cc-policy evaluate CLI, or inject a
    caller-supplied pre-built PolicyContext dict via a future parameter once
    braid-v2 has a runtime-DB adapter.
    Authority: runtime/core/policy_engine.py → PolicyRegistry.evaluate()

  evaluate_self_adaptation — live when runtime.core.authority_registry is importable.
    stage_has_capability() is a pure function; no DB required.
    Authority: runtime/core/authority_registry.py → stage_has_capability()

  compile_prompt_pack      — live when explicit_layers are supplied by caller.
    build_prompt_pack() is a pure function; no DB required.
    compile_prompt_pack_for_stage() requires a DB conn and typed contracts —
    callers that need that path must invoke it directly.
    Authority: runtime/core/prompt_pack.py → build_prompt_pack()

  resolve_launch_profile   — live when runtime.core.prompt_pack_resolver is
    importable and caller supplies non-empty workflow_id and a valid stage.
    resolve_prompt_pack_layers() is a pure function; no DB required.
    Authority: runtime/core/prompt_pack_resolver.py → resolve_prompt_pack_layers()
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field, asdict
from typing import Any, Mapping


# ---------------------------------------------------------------------------
# Provenance constants — point at the authoritative runtime/core modules
# ---------------------------------------------------------------------------

_POLICY_ENGINE_MODULE = "runtime/core/policy_engine.py"
_AUTHORITY_REGISTRY_MODULE = "runtime/core/authority_registry.py"
_PROMPT_PACK_MODULE = "runtime/core/prompt_pack.py"
_PROMPT_PACK_RESOLVER_MODULE = "runtime/core/prompt_pack_resolver.py"


# ---------------------------------------------------------------------------
# Result types
# ---------------------------------------------------------------------------

@dataclass
class PolicyVerdict:
    """Structured result returned by braid-v2 policy surface calls.

    Fields
    ------
    status : "approved" | "denied" | "not_wired"
        ``approved``   — the authority approved the request.
        ``denied``     — the authority denied the request; see ``reason``.
        ``not_wired``  — live authority is not reachable; see ``provenance``.
    wired : bool
        True when the result came from a live runtime/core call.
    reason : str
        Human-readable explanation (always populated).
    provenance : dict
        Pointer at the runtime/core module that owns this decision. Always
        includes ``module``, ``function``, and ``status`` fields. When
        ``status="not_wired"`` also includes a ``wiring_requirements`` key
        that documents what the caller must supply to complete live wiring.
    evaluated_at : int
        Unix timestamp of evaluation (seconds).
    metadata : dict
        Caller-supplied context echoed back for audit trail inclusion.
    """

    status: str
    wired: bool
    reason: str
    provenance: dict
    evaluated_at: int = field(default_factory=lambda: int(time.time()))
    metadata: dict = field(default_factory=dict)

    def approved(self) -> bool:
        return self.status == "approved"

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class PromptPackResult:
    """Result of compile_prompt_pack."""

    status: str        # "compiled" | "not_wired"
    wired: bool
    pack: dict | None  # PromptPack fields when wired, else None
    provenance: dict
    evaluated_at: int = field(default_factory=lambda: int(time.time()))

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class LaunchProfileResult:
    """Result of resolve_launch_profile."""

    status: str        # "resolved" | "not_wired"
    wired: bool
    profile: dict | None
    provenance: dict
    evaluated_at: int = field(default_factory=lambda: int(time.time()))

    def to_dict(self) -> dict:
        return asdict(self)


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _not_wired_provenance(module: str, function: str, wiring_requirements: str) -> dict:
    return {
        "module": module,
        "function": function,
        "status": "not_wired",
        "wiring_requirements": wiring_requirements,
    }


# ---------------------------------------------------------------------------
# 1. evaluate_spawn_request
#
# Always not_wired.
#
# Why: live evaluation requires a PolicyContext built from the runtime SQLite DB
# via build_context(conn, ...).  braid-v2 holds its own topology DB but never
# holds the runtime/core DB connection.  Attempting build_context(None, ...)
# fails immediately because build_context() calls conn.execute() on line 1 of
# its body — there is no code path that tolerates conn=None.
#
# Wiring path for future implementers:
#   Option A — route through cc-policy CLI:
#     shell out to: cc-policy evaluate --event-type PreToolUse
#                     --tool-name Agent --tool-input <json>
#                     --cwd <worktree_path>
#     parse stdout JSON → map PolicyDecision.action to PolicyVerdict.status
#   Option B — add a caller_context: dict param once braid-v2 acquires a
#     runtime-DB adapter.  The caller resolves the PolicyContext via
#     build_context(runtime_conn, ...) and passes the serialized result here.
#     This function then constructs PolicyRequest and calls registry.evaluate().
# ---------------------------------------------------------------------------

def evaluate_spawn_request(
    *,
    worker_harness: str,
    supervisor_harness: str,
    goal_ref: str | None = None,
    work_item_ref: str | None = None,
    requested_by_seat: str | None = None,
    parent_bundle_id: str | None = None,
    transport: str = "tmux",
    actor_role: str = "",
    workflow_id: str = "",
    worktree_path: str = "",
    project_root: str = "",
    extra: dict | None = None,
) -> PolicyVerdict:
    """Ask the shared policy authority whether this spawn request is permitted.

    Always returns ``status="not_wired"`` because live evaluation requires
    a fully-resolved PolicyContext from build_context(conn, ...) where ``conn``
    is the runtime SQLite DB. braid-v2 does not hold that connection.

    The provenance block documents the two wiring paths future implementers
    can use (cc-policy CLI or caller-supplied PolicyContext).

    braid-v2 calls this before creating a spawn_request row so the approval
    status and provenance can be embedded in ``spawn_request.request_json``
    for audit trail purposes.
    """
    metadata = {
        "worker_harness": worker_harness,
        "supervisor_harness": supervisor_harness,
        "goal_ref": goal_ref,
        "work_item_ref": work_item_ref,
        "requested_by_seat": requested_by_seat,
        "parent_bundle_id": parent_bundle_id,
        "transport": transport,
        "actor_role": actor_role,
        "workflow_id": workflow_id,
        **(extra or {}),
    }
    return PolicyVerdict(
        status="not_wired",
        wired=False,
        reason=(
            "Policy authority is not reachable from braid-v2: live evaluation "
            "requires a PolicyContext resolved from the runtime SQLite DB via "
            "build_context(conn, ...), which braid-v2 does not hold. "
            "Embed this provenance in spawn_request.request_json for audit trail. "
            "See provenance.wiring_requirements for the two completion paths."
        ),
        provenance=_not_wired_provenance(
            module=_POLICY_ENGINE_MODULE,
            function="PolicyRegistry.evaluate",
            wiring_requirements=(
                "Option A (CLI): shell to `cc-policy evaluate --event-type PreToolUse "
                "--tool-name Agent --tool-input <json> --cwd <worktree_path>` and map "
                "PolicyDecision.action to PolicyVerdict.status. "
                "Option B (inline): add a caller_context: dict param once braid-v2 "
                "has a runtime-DB adapter; caller resolves PolicyContext via "
                "build_context(runtime_conn, cwd=worktree_path, actor_role=actor_role) "
                "and passes it here; function constructs PolicyRequest and calls "
                "default_registry().evaluate(request)."
            ),
        ),
        metadata=metadata,
    )


# ---------------------------------------------------------------------------
# 2. evaluate_self_adaptation
#
# Live when runtime.core.authority_registry is importable.
# stage_has_capability() is a pure function — no DB, no I/O.
# ---------------------------------------------------------------------------

def evaluate_self_adaptation(
    *,
    bundle_id: str,
    seat_id: str,
    seat_role: str,
    adaptation_type: str,
    proposed_change: dict,
    required_capability: str = "",
    extra: dict | None = None,
) -> PolicyVerdict:
    """Ask the shared authority whether seat_role may perform self-adaptation.

    Self-adaptation covers any runtime topology or configuration change a
    seat initiates on its own (autonomy budget increase, config override,
    harness substitution, etc.).

    Live wiring
    -----------
    Delegates to ``authority_registry.stage_has_capability(seat_role, cap)``
    which is a pure function. Works whenever ``runtime.core.authority_registry``
    is on the import path — no DB connection required.
    """
    metadata = {
        "bundle_id": bundle_id,
        "seat_id": seat_id,
        "seat_role": seat_role,
        "adaptation_type": adaptation_type,
        "proposed_change": proposed_change,
        "required_capability": required_capability,
        **(extra or {}),
    }
    cap = required_capability or _adaptation_capability(adaptation_type)

    # --- attempt live invocation ---
    try:
        import importlib
        ar = importlib.import_module("runtime.core.authority_registry")
        allowed = ar.stage_has_capability(seat_role, cap) if cap else True
        return PolicyVerdict(
            status="approved" if allowed else "denied",
            wired=True,
            reason=(
                f"role '{seat_role}' {'has' if allowed else 'lacks'} "
                f"capability '{cap}' required for adaptation '{adaptation_type}'"
            ),
            provenance={
                "module": _AUTHORITY_REGISTRY_MODULE,
                "function": "stage_has_capability",
                "status": "live",
                "capability_checked": cap,
            },
            metadata=metadata,
        )
    except Exception:  # noqa: BLE001
        pass

    # --- stub ---
    return PolicyVerdict(
        status="not_wired",
        wired=False,
        reason=(
            f"Capability gate for '{adaptation_type}' not evaluated "
            f"(authority_registry not reachable). Required capability: '{cap}'."
        ),
        provenance=_not_wired_provenance(
            module=_AUTHORITY_REGISTRY_MODULE,
            function="stage_has_capability",
            wiring_requirements=(
                f"Import runtime.core.authority_registry and call "
                f"stage_has_capability(stage={seat_role!r}, capability={cap!r}). "
                f"Pure function; no DB required."
            ),
        ),
        metadata=metadata,
    )


def _adaptation_capability(adaptation_type: str) -> str:
    """Map a braid-v2 adaptation type to the runtime/core capability it requires.

    This table is the braid-v2 side of the authority split. New adaptation
    types must be registered here alongside a corresponding capability in
    ``runtime/core/authority_registry.py:CAPABILITIES``.
    """
    _TABLE: dict[str, str] = {
        "autonomy_budget_increase": "can_set_control_config",
        "harness_substitution": "can_set_control_config",
        "config_override": "can_set_control_config",
        "source_edit": "can_write_source",
        "governance_edit": "can_write_governance",
        "worktree_provision": "can_provision_worktree",
        "git_land": "can_land_git",
    }
    return _TABLE.get(adaptation_type, "")


# ---------------------------------------------------------------------------
# 3. compile_prompt_pack
#
# Live when caller supplies explicit_layers (all 6 canonical layer strings).
# build_prompt_pack() is a pure function — no DB, no I/O.
#
# compile_prompt_pack_for_stage() is NOT called here because it requires a
# live SQLite DB connection and typed GoalContract / WorkItemContract objects
# that braid-v2 does not hold. Callers needing that function must invoke it
# directly in a context where the runtime DB is available.
# ---------------------------------------------------------------------------

def compile_prompt_pack(
    *,
    workflow_id: str,
    stage_id: str,
    explicit_layers: dict | None = None,
    goal_ref: str | None = None,
    work_item_ref: str | None = None,
    decision_scope: str = "none",
    current_branch: str | None = None,
    worktree_path: str | None = None,
    extra: dict | None = None,
) -> PromptPackResult:
    """Compile a prompt pack for the given stage via the shared authority.

    Live path (``explicit_layers`` supplied)
    ----------------------------------------
    When the caller provides all six canonical layer strings as ``explicit_layers``,
    delegates to ``runtime.core.prompt_pack.build_prompt_pack()`` which is a pure
    function requiring no DB connection. Returns the compiled PromptPack.

    Canonical layer names (all six required):
      constitution, stage_contract, workflow_contract,
      local_decision_pack, runtime_state_pack, next_actions

    Not-wired path (``explicit_layers`` omitted)
    ---------------------------------------------
    Returns ``status="not_wired"`` with provenance pointing at the two entry
    points the caller should use:
      * ``build_prompt_pack(workflow_id, stage_id, layers, generated_at)`` — pure,
        for callers that can supply all six layer strings.
      * ``compile_prompt_pack_for_stage(conn, ...)`` — needs a runtime DB conn
        and typed GoalContract / WorkItemContract; not callable from braid-v2.
    """
    if explicit_layers is not None:
        # Live path: delegate to the pure build_prompt_pack compiler
        try:
            import importlib
            import time as _time
            pp = importlib.import_module("runtime.core.prompt_pack")
            pack = pp.build_prompt_pack(
                workflow_id=workflow_id,
                stage_id=stage_id,
                layers=explicit_layers,
                generated_at=int(_time.time()),
            )
            # Serialise to a plain dict for transport across the boundary
            pack_dict: dict = {
                "workflow_id": pack.workflow_id,
                "stage_id": pack.stage_id,
                "content_hash": pack.content_hash,
                "layer_names": list(pack.layer_names),
            }
            return PromptPackResult(
                status="compiled",
                wired=True,
                pack=pack_dict,
                provenance={
                    "module": _PROMPT_PACK_MODULE,
                    "function": "build_prompt_pack",
                    "status": "live",
                },
            )
        except Exception as exc:  # noqa: BLE001
            return PromptPackResult(
                status="not_wired",
                wired=False,
                pack=None,
                provenance=_not_wired_provenance(
                    module=_PROMPT_PACK_MODULE,
                    function="build_prompt_pack",
                    wiring_requirements=(
                        f"explicit_layers were supplied but build_prompt_pack raised: {exc}. "
                        f"Ensure all six canonical layers are non-empty strings and "
                        f"runtime.core.prompt_pack is importable."
                    ),
                ),
            )

    # Not-wired: caller did not supply explicit_layers
    return PromptPackResult(
        status="not_wired",
        wired=False,
        pack=None,
        provenance=_not_wired_provenance(
            module=_PROMPT_PACK_MODULE,
            function="build_prompt_pack",
            wiring_requirements=(
                "Pass explicit_layers: a dict with exactly the six canonical layer "
                "strings keyed by name ('constitution', 'stage_contract', "
                "'workflow_contract', 'local_decision_pack', 'runtime_state_pack', "
                "'next_actions'). Each value must be a non-empty string. "
                "This calls build_prompt_pack(workflow_id, stage_id, layers, "
                "generated_at) — a pure function with no DB required. "
                "Alternatively, for full DB-backed compilation, call "
                "compile_prompt_pack_for_stage(conn, workflow_id=..., stage_id=..., "
                "goal=<GoalContract>, work_item=<WorkItemContract>, "
                "decision_scope=..., generated_at=...) directly where conn is "
                "the runtime SQLite DB connection."
            ),
        ),
    )


# ---------------------------------------------------------------------------
# 4. resolve_launch_profile
#
# Live when runtime.core.prompt_pack_resolver is importable and caller
# supplies a non-empty workflow_id and a valid stage.
# resolve_prompt_pack_layers() is a pure function — no DB, no I/O.
# The resolver validates isinstance of its summary arguments at call time,
# so this function constructs the real dataclass instances (not proxies).
# ---------------------------------------------------------------------------

def resolve_launch_profile(
    *,
    harness: str,
    stage: str,
    goal_ref: str | None = None,
    work_item_ref: str | None = None,
    workflow_id: str = "",
    current_branch: str = "(unknown)",
    worktree_path: str = "(unknown)",
    extra: dict | None = None,
) -> LaunchProfileResult:
    """Resolve which launch profile (layers) applies for this harness/stage.

    Live wiring
    -----------
    Delegates to ``runtime.core.prompt_pack_resolver.resolve_prompt_pack_layers()``
    which is a pure function requiring no DB connection. The resolver accepts
    typed caller-supplied summary dataclasses; this function constructs them
    from the available braid-v2 call-site arguments.

    The resolver performs strict ``isinstance`` checks on its summary arguments,
    so real dataclass instances (not mocks or proxies) must be passed — this is
    enforced here by importing the real classes from the module.

    Returns ``not_wired`` if:
      * ``stage`` is empty (resolver requires a non-empty stage in ACTIVE_STAGES)
      * ``workflow_id`` is empty (required for WorkflowContractSummary)
      * runtime.core.prompt_pack_resolver is not importable
    """
    if not stage or not workflow_id:
        return LaunchProfileResult(
            status="not_wired",
            wired=False,
            profile=None,
            provenance=_not_wired_provenance(
                module=_PROMPT_PACK_RESOLVER_MODULE,
                function="resolve_prompt_pack_layers",
                wiring_requirements=(
                    "Both 'stage' and 'workflow_id' must be non-empty. "
                    f"Got stage={stage!r}, workflow_id={workflow_id!r}. "
                    "stage must be one of the ACTIVE_STAGES in "
                    "runtime/core/stage_registry.py."
                ),
            ),
        )

    # --- attempt live invocation ---
    try:
        import importlib
        resolver = importlib.import_module("runtime.core.prompt_pack_resolver")

        # Construct real dataclass instances — the resolver's isinstance checks
        # require these to be actual instances of the declared dataclasses.
        workflow_summary = resolver.WorkflowContractSummary(
            workflow_id=workflow_id,
            title=goal_ref or f"(goal: {goal_ref or 'none'})",
            status="active",
            scope_summary=work_item_ref or "(work item: none)",
            evaluation_summary="(not yet evaluated)",
            rollback_boundary="(unknown at braid-v2 call site)",
        )
        decision_summary = resolver.LocalDecisionSummary()
        runtime_state_summary = resolver.RuntimeStateSummary(
            current_branch=current_branch,
            worktree_path=worktree_path,
        )
        layers = resolver.resolve_prompt_pack_layers(
            stage=stage,
            workflow_summary=workflow_summary,
            decision_summary=decision_summary,
            runtime_state_summary=runtime_state_summary,
        )
        return LaunchProfileResult(
            status="resolved",
            wired=True,
            profile={
                "harness": harness,
                "stage": stage,
                "layers": layers,
            },
            provenance={
                "module": _PROMPT_PACK_RESOLVER_MODULE,
                "function": "resolve_prompt_pack_layers",
                "status": "live",
            },
        )
    except Exception as exc:  # noqa: BLE001
        return LaunchProfileResult(
            status="not_wired",
            wired=False,
            profile=None,
            provenance=_not_wired_provenance(
                module=_PROMPT_PACK_RESOLVER_MODULE,
                function="resolve_prompt_pack_layers",
                wiring_requirements=(
                    f"Live call raised: {exc}. "
                    f"Ensure stage={stage!r} is in runtime/core/stage_registry.ACTIVE_STAGES "
                    f"and runtime.core.prompt_pack_resolver is importable."
                ),
            ),
        )
