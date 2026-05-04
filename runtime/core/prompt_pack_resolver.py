"""Pure prompt-pack layer resolver (shadow-only).

@decision DEC-CLAUDEX-EVAL-CONTRACT-SCHEMA-PARITY-001
Title: Extend _render_evaluation_summary to render 9 EvaluationContract fields
Status: accepted
Rationale: Prior to slice 33, ``_render_evaluation_summary`` rendered only
  4 sections (desired_end_state + required_tests + required_evidence +
  acceptance_notes). The 5 new fields added to ``contracts.EvaluationContract``
  by DEC-CLAUDEX-EVAL-CONTRACT-SCHEMA-PARITY-001 would round-trip through the
  codec silently without reaching the compiled prompt body — silent data loss.
  This extension adds rendering for the 5 new fields with pinned group-order
  section headers so the compiled prompt body is always in sync with the
  schema. Group order: (tests/evidence) → (real-path/authority/integration/
  forbidden) → (rollback/acceptance/ready-for-guardian). The test suite pins
  this order so future slices cannot silently reorder it (novel design element 1).
  Cross-reference: DEC-CLAUDEX-PROMPT-PACK-RESOLVER-001 (parent resolver decision).

@decision DEC-CLAUDEX-PROMPT-PACK-RESOLVER-001
Title: runtime/core/prompt_pack_resolver.py composes the six canonical prompt-pack layers from existing shadow authorities plus explicit caller summaries
Status: proposed (shadow-mode, Phase 2 prompt-pack resolver bootstrap)
Rationale: CUTOVER_PLAN §Prompt Pack Layers lists six canonical
  layers that every active session / subagent should receive:
  constitution, stage_contract, workflow_contract,
  local_decision_pack, runtime_state_pack, next_actions. The
  earlier ``runtime.core.prompt_pack`` slice delivered the compiler
  that hashes a caller-supplied layer dict into a
  :class:`projection_schemas.PromptPack`. This slice delivers the
  next piece of the Phase 2 chain: a pure resolver that composes
  the six layer strings from live shadow authorities, so the
  compiler can be driven from runtime-owned state rather than
  hand-maintained prompt fragments.

  Scope discipline:

    * **Pure function.** ``resolve_prompt_pack_layers`` and every
      helper are deterministic pure functions: same inputs produce
      byte-identical output dicts. No filesystem I/O, no SQLite,
      no subprocess, no time calls.
    * **Shadow-only.** The module imports only existing shadow
      authorities: ``runtime.core.prompt_pack`` (for the canonical
      layer-name constants), ``runtime.core.stage_registry`` (for
      stages + transitions + verdict vocabularies),
      ``runtime.core.authority_registry`` (for capabilities +
      operational-fact ownership),
      ``runtime.core.constitution_registry`` (for concrete
      constitution-level files),
      ``runtime.core.contracts`` (for the Phase 1 goal /
      work-item contract dataclasses that the
      ``workflow_summary_from_contracts`` helper consumes), and
      ``runtime.core.decision_work_registry`` (for the
      ``DecisionRecord`` dataclass that the
      ``local_decision_summary_from_records`` helper consumes —
      no SQLite connection is opened inside the helper). AST
      tests pin that no live routing module is imported, and
      that no live routing module or CLI imports this resolver
      yet.
    * **Mechanical derivation for facts the shadow kernel already
      owns.** The ``constitution``, ``stage_contract``, and
      ``next_actions`` layers are derived mechanically from the
      runtime-owned authorities — changing
      ``constitution_registry.CONCRETE_PATHS``,
      ``authority_registry.STAGE_CAPABILITIES`` (via
      ``resolve_contract()``), or
      ``stage_registry.TRANSITIONS`` automatically changes the
      rendered layer text. Tests pin this by monkey-patching the
      authorities and asserting the resolver output moves with
      them.
    * **Explicit caller input for facts not yet fully owned.** The
      ``workflow_contract``, ``local_decision_pack``, and
      ``runtime_state_pack`` layers rely on runtime state that
      either (a) lives in a Phase 1 shadow substrate that is not
      yet queryable as a single canonical view (workflow +
      evaluation contracts live in
      ``runtime.core.contracts`` and
      ``runtime.core.decision_work_registry`` but there is no
      cross-authority resolver yet) or (b) depends on live
      repo/session state (branch, worktree, leases, approvals,
      findings). Rather than invent a second authority by
      synthesising those layers from partial views, this resolver
      accepts small typed caller dataclasses
      (:class:`WorkflowContractSummary`,
      :class:`LocalDecisionSummary`,
      :class:`RuntimeStateSummary`) and renders them verbatim.
      When a later slice lands the cross-authority resolver, those
      callers will be replaced by the resolver output; this
      module's contract will not need to change.

  Return contract:

    :func:`resolve_prompt_pack_layers` returns a ``dict[str, str]``
    keyed **exactly** by
    ``runtime.core.prompt_pack.CANONICAL_LAYER_ORDER``. No
    additional keys, no missing keys. The dict can be passed
    directly into
    :func:`runtime.core.prompt_pack.build_prompt_pack` without any
    reshaping — a dedicated test in
    ``test_prompt_pack_resolver.py`` pins this round-trip.

  What this module deliberately does NOT do:

    * It does not wire the resolver into any hook, CLI, or
      runtime routing path.
    * It does not call ``build_prompt_pack`` itself — it returns
      the layer dict and lets the caller decide whether to hash
      it into a projection.
    * It does not resolve workflow / decision / runtime-state
      layers from live authorities — that is deferred to a later
      slice that walks ``contracts`` / ``decision_work_registry``
      / session state.
    * It does not read ``CLAUDE.md`` / ``AGENTS.md`` content; the
      constitution layer references them structurally (their
      declared paths and ownership) rather than inlining their
      prose. Inlining prose would reintroduce the "folklore text"
      antipattern that CUTOVER_PLAN §Compiled Guidance is
      replacing.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, Tuple

from runtime.core import authority_registry as ar
from runtime.core import constitution_registry as cr
from runtime.core import contracts
from runtime.core import decision_work_registry as dwr
from runtime.core import prompt_pack as pp
from runtime.core import stage_registry as sr

# ---------------------------------------------------------------------------
# Caller-supplied summary dataclasses
#
# These are small, frozen, typed containers that the caller uses to
# supply the three layers the shadow kernel cannot yet resolve
# mechanically. Each dataclass validates its inputs at construction
# time and exposes a pure ``render()`` method that produces the
# layer body. Tests pin the rendered format exactly.
# ---------------------------------------------------------------------------


def _require_non_empty_str(obj: object, attr: str) -> None:
    value = getattr(obj, attr)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(
            f"{type(obj).__name__}.{attr} must be a non-empty string; got {value!r}"
        )


def _require_tuple_of_non_empty_strings(obj: object, attr: str) -> None:
    value = getattr(obj, attr)
    if not isinstance(value, tuple):
        raise ValueError(
            f"{type(obj).__name__}.{attr} must be a tuple; got {type(value).__name__}"
        )
    for item in value:
        if not isinstance(item, str) or not item:
            raise ValueError(
                f"{type(obj).__name__}.{attr} entries must be non-empty strings"
            )


@dataclass(frozen=True)
class WorkflowContractSummary:
    """Caller-supplied workflow contract summary for the ``workflow_contract`` layer.

    All fields are required. Empty / whitespace-only strings are
    rejected at construction time so a downstream prompt-pack
    compiler never sees a blank workflow contract section.
    """

    workflow_id: str
    title: str
    status: str
    scope_summary: str
    evaluation_summary: str
    rollback_boundary: str

    def __post_init__(self) -> None:
        for attr in (
            "workflow_id",
            "title",
            "status",
            "scope_summary",
            "evaluation_summary",
            "rollback_boundary",
        ):
            _require_non_empty_str(self, attr)

    def render(self) -> str:
        return (
            f"Workflow ID: {self.workflow_id}\n"
            f"Title: {self.title}\n"
            f"Status: {self.status}\n"
            f"Scope summary: {self.scope_summary}\n"
            f"Evaluation summary: {self.evaluation_summary}\n"
            f"Rollback boundary: {self.rollback_boundary}"
        )


@dataclass(frozen=True)
class LocalDecisionSummary:
    """Caller-supplied decision summary for the ``local_decision_pack`` layer.

    ``rationale`` is required (even if just a placeholder like
    ``"(no relevant decisions)"``) so the layer is always
    non-empty. The id and supersession lists are optional tuples of
    non-empty strings.
    """

    rationale: str = "(no relevant decisions)"
    relevant_decision_ids: Tuple[str, ...] = ()
    supersession_notes: Tuple[str, ...] = ()

    def __post_init__(self) -> None:
        _require_non_empty_str(self, "rationale")
        _require_tuple_of_non_empty_strings(self, "relevant_decision_ids")
        _require_tuple_of_non_empty_strings(self, "supersession_notes")

    def render(self) -> str:
        lines = [f"Rationale: {self.rationale}"]
        if self.relevant_decision_ids:
            lines.append("Relevant decisions:")
            for did in self.relevant_decision_ids:
                lines.append(f"- {did}")
        else:
            lines.append("Relevant decisions: (none)")
        if self.supersession_notes:
            lines.append("Supersession notes:")
            for note in self.supersession_notes:
                lines.append(f"- {note}")
        else:
            lines.append("Supersession notes: (none)")
        return "\n".join(lines)


@dataclass(frozen=True)
class RuntimeStateSummary:
    """Caller-supplied runtime-state summary for the ``runtime_state_pack`` layer.

    ``current_branch`` and ``worktree_path`` are required. The
    remaining lists (leases, approvals, findings) are optional
    tuples of non-empty strings — the layer reports "none" for
    empty tuples so the rendered text is always meaningful.
    """

    current_branch: str
    worktree_path: str
    active_leases: Tuple[str, ...] = ()
    open_approvals: Tuple[str, ...] = ()
    unresolved_findings: Tuple[str, ...] = ()

    def __post_init__(self) -> None:
        _require_non_empty_str(self, "current_branch")
        _require_non_empty_str(self, "worktree_path")
        _require_tuple_of_non_empty_strings(self, "active_leases")
        _require_tuple_of_non_empty_strings(self, "open_approvals")
        _require_tuple_of_non_empty_strings(self, "unresolved_findings")

    def render(self) -> str:
        lines = [
            f"Current branch: {self.current_branch}",
            f"Worktree path: {self.worktree_path}",
        ]
        if self.active_leases:
            lines.append("Active leases:")
            for lease in self.active_leases:
                lines.append(f"- {lease}")
        else:
            lines.append("Active leases: (none)")
        if self.open_approvals:
            lines.append("Open approvals:")
            for approval in self.open_approvals:
                lines.append(f"- {approval}")
        else:
            lines.append("Open approvals: (none)")
        if self.unresolved_findings:
            lines.append("Unresolved findings:")
            for finding in self.unresolved_findings:
                lines.append(f"- {finding}")
        else:
            lines.append("Unresolved findings: (none)")
        return "\n".join(lines)


# ---------------------------------------------------------------------------
# Authority-derived layer renderers
#
# These renderers walk the shadow kernel's runtime-owned
# authorities. They are deterministic given identical authority
# state — no time calls, no RNG, no I/O.
# ---------------------------------------------------------------------------


def render_constitution_layer() -> str:
    """Render the ``constitution`` layer from runtime authority modules.

    The rendered body references structural facts the shadow kernel
    already owns:

      * Every concrete constitution-level file from
        :data:`runtime.core.constitution_registry.CONCRETE_PATHS`
      * The capability vocabulary from
        :data:`runtime.core.authority_registry.CAPABILITIES`
      * The operational-fact authority table
        (``fact_name → owner_module`` pairs)

    The layer deliberately does NOT inline the *contents* of
    CLAUDE.md / AGENTS.md / etc. — it references them structurally,
    so this module does not reintroduce the folklore-text
    antipattern that CUTOVER_PLAN §Compiled Guidance is
    replacing.
    """
    lines: list[str] = []
    lines.append("Constitution-level files (runtime-owned concrete set):")
    for entry in cr.concrete_entries():
        # ``entry.path`` is guaranteed non-None for concrete entries.
        lines.append(f"- {entry.path}")

    lines.append("")
    lines.append("Capability vocabulary (authority_registry.CAPABILITIES):")
    for cap in sorted(ar.CAPABILITIES):
        lines.append(f"- {cap}")

    lines.append("")
    lines.append("Operational-fact authority table:")
    for fact in ar.AUTHORITY_TABLE:
        lines.append(f"- {fact.name} → {fact.owner_module}")

    return "\n".join(lines)


def render_stage_contract_layer(stage: str) -> str:
    """Render the ``stage_contract`` layer for ``stage``.

    Derived from:

      * :func:`runtime.core.authority_registry.resolve_contract` —
        the structured capability contract (granted, denied,
        read_only) resolved through the single capability authority.
      * :func:`runtime.core.stage_registry.allowed_verdicts` —
        the verdict vocabulary this stage may emit.

    Accepts live-role aliases (e.g. ``"Plan"``, ``"guardian"``) via
    ``resolve_contract()`` and canonicalizes all downstream lookups
    through ``contract.stage_id``.

    Raises ``ValueError`` if ``stage`` does not resolve to a known
    active stage via :func:`runtime.core.authority_registry.resolve_contract`.
    """
    contract = ar.resolve_contract(stage)
    if contract is None:
        raise ValueError(
            f"render_stage_contract_layer: unknown active stage {stage!r}; "
            f"valid: {sorted(sr.ACTIVE_STAGES)}"
        )

    verdicts = sr.allowed_verdicts(contract.stage_id)

    lines = [f"Stage: {contract.stage_id}", ""]

    if contract.read_only:
        lines.append("Read-only: yes")
        lines.append("")

    lines.append("Allowed capabilities:")
    if contract.granted:
        for cap in sorted(contract.granted):
            lines.append(f"- {cap}")
    else:
        lines.append("- (none)")

    lines.append("")
    lines.append("Forbidden capabilities:")
    if contract.denied:
        for cap in sorted(contract.denied):
            lines.append(f"- {cap}")
    else:
        lines.append("- (none)")

    lines.append("")
    lines.append("Allowed verdicts:")
    if verdicts:
        for verdict in sorted(verdicts):
            lines.append(f"- {verdict}")
    else:
        lines.append("- (none — terminal stage)")

    return "\n".join(lines)


def render_next_actions_layer(stage: str) -> str:
    """Render the ``next_actions`` layer for ``stage``.

    Lists the legal ``(verdict → next_stage)`` transitions from
    :func:`runtime.core.stage_registry.outgoing`. Transitions are
    emitted in the declaration order of
    :data:`runtime.core.stage_registry.TRANSITIONS`, so the
    rendered body is deterministic.

    Raises ``ValueError`` if ``stage`` is not in
    :data:`runtime.core.stage_registry.ACTIVE_STAGES`.
    """
    if stage not in sr.ACTIVE_STAGES:
        raise ValueError(
            f"render_next_actions_layer: unknown active stage {stage!r}; "
            f"valid: {sorted(sr.ACTIVE_STAGES)}"
        )

    transitions = sr.outgoing(stage)
    lines = [f"Legal next actions from {stage}:"]
    if transitions:
        for transition in transitions:
            lines.append(
                f"- verdict={transition.verdict} → {transition.to_stage}"
            )
    else:
        lines.append("- (terminal; no outgoing transitions)")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Top-level resolver
# ---------------------------------------------------------------------------


def resolve_prompt_pack_layers(
    *,
    stage: str,
    workflow_summary: WorkflowContractSummary,
    decision_summary: LocalDecisionSummary,
    runtime_state_summary: RuntimeStateSummary,
) -> Dict[str, str]:
    """Resolve the six canonical prompt-pack layers as a mapping.

    Returns a ``dict[str, str]`` keyed exactly by
    :data:`runtime.core.prompt_pack.CANONICAL_LAYER_ORDER`:

      * ``constitution`` — from :func:`render_constitution_layer`
      * ``stage_contract`` — from
        :func:`render_stage_contract_layer`
      * ``workflow_contract`` — from ``workflow_summary.render()``
      * ``local_decision_pack`` — from ``decision_summary.render()``
      * ``runtime_state_pack`` — from
        ``runtime_state_summary.render()``
      * ``next_actions`` — from :func:`render_next_actions_layer`

    The returned dict can be passed directly into
    :func:`runtime.core.prompt_pack.build_prompt_pack` as the
    ``layers`` argument without any reshaping.

    Raises ``ValueError`` if:
      * ``stage`` is not in
        :data:`runtime.core.stage_registry.ACTIVE_STAGES`
      * any caller-supplied summary is not the expected dataclass
        instance
    """
    if not isinstance(workflow_summary, WorkflowContractSummary):
        raise ValueError(
            "workflow_summary must be a WorkflowContractSummary instance"
        )
    if not isinstance(decision_summary, LocalDecisionSummary):
        raise ValueError(
            "decision_summary must be a LocalDecisionSummary instance"
        )
    if not isinstance(runtime_state_summary, RuntimeStateSummary):
        raise ValueError(
            "runtime_state_summary must be a RuntimeStateSummary instance"
        )

    layers: Dict[str, str] = {
        pp.LAYER_CONSTITUTION: render_constitution_layer(),
        pp.LAYER_STAGE_CONTRACT: render_stage_contract_layer(stage),
        pp.LAYER_WORKFLOW_CONTRACT: workflow_summary.render(),
        pp.LAYER_LOCAL_DECISION_PACK: decision_summary.render(),
        pp.LAYER_RUNTIME_STATE_PACK: runtime_state_summary.render(),
        pp.LAYER_NEXT_ACTIONS: render_next_actions_layer(stage),
    }

    # Invariant: the returned dict must match the canonical layer
    # vocabulary exactly. This is a defense-in-depth check; the
    # prompt_pack compiler will also reject mismatched layer sets.
    assert set(layers.keys()) == set(pp.CANONICAL_LAYER_ORDER), (
        "prompt_pack_resolver produced a non-canonical layer set; "
        f"got {sorted(layers.keys())}, expected "
        f"{sorted(pp.CANONICAL_LAYER_ORDER)}"
    )
    return layers


# ---------------------------------------------------------------------------
# contracts.py → WorkflowContractSummary bridge
#
# This is the second authority-derived layer helper in the resolver.
# It shrinks the caller-supplied surface for the
# ``workflow_contract`` layer: instead of hand-crafting a
# :class:`WorkflowContractSummary`, the caller can now pass a
# :class:`runtime.core.contracts.GoalContract` plus a
# :class:`runtime.core.contracts.WorkItemContract` and get a
# deterministically-rendered summary that passes
# ``WorkflowContractSummary``'s own validation.
#
# The helper deliberately does NOT widen the top-level
# ``resolve_prompt_pack_layers`` signature. Callers that want to
# use it simply pre-compute a ``WorkflowContractSummary`` via
# :func:`workflow_summary_from_contracts` and pass the result into
# ``resolve_prompt_pack_layers(workflow_summary=...)``. Keeping the
# two surfaces separate means the resolver's call-shape stability
# is untouched, and the new helper can be tested, refactored, or
# replaced independently once a later slice introduces a live
# walker that produces ``GoalContract`` / ``WorkItemContract``
# instances from SQLite.
# ---------------------------------------------------------------------------


_NO_AUTHORITATIVE_SCOPE_MARKER = (
    "(no authoritative workflow_scope configured for this workflow; "
    "commit/merge enforcement will fail-closed with \"No scope manifest\" "
    "until a planner runs `cc-policy workflow scope-set <workflow_id>` — "
    "this block intentionally does not render work_item.scope as live law)"
)
"""Explicit marker used by :func:`workflow_summary_from_contracts` when the
caller passes ``workflow_scope_record=None``.

@decision DEC-CLAUDEX-PROMPT-PACK-SCOPE-AUTHORITY-002
Title: prompt-pack scope_summary fails-loud with an explicit marker when
  no authoritative workflow_scope row exists — never falls back to
  rendering work_item.scope as if it were live law.
Status: accepted
Rationale: The previous slice (DEC-CLAUDEX-PROMPT-PACK-SCOPE-AUTHORITY-001)
  still routed ``workflow_scope_record=None`` through
  :func:`_render_scope_summary` on ``work_item.scope``. On the real compile
  paths (``prompt_pack.build_prompt_pack_for_stage``,
  ``prompt_pack.build_subagent_start_prompt_pack_response``, and the
  ``cc-policy prompt-pack compile`` CLI branch), the caller always passes
  whatever ``workflows.get_scope()`` returns — so ``None`` means "no
  enforcement row exists yet" and enforcement will fail-closed. Rendering
  ``work_item.scope`` anyway put the agent's prompt pack back in the same
  drift class the first slice was trying to remove: the compiled prompt
  advertised intent-only paths as if they were the law, while the gate
  would refuse the commit with "No scope manifest."
  The correction: compile-path summaries for unconfigured workflows emit
  an explicit marker that cannot be confused with an enforceable scope
  and that tells the operator exactly what to do to get the workflow
  into a commit-able state.
"""


def _render_scope_summary(scope: "contracts.ScopeManifest") -> str:
    """Render a :class:`contracts.ScopeManifest` into a deterministic block.

    Every section always prints under its labelled heading; empty
    tuples produce explicit ``(unrestricted)`` / ``(none)`` markers
    so downstream readers never see a blank section and cannot
    confuse "no restriction" with "missing data".

    This renderer operates on the work-item intent-declaration shape
    (``contracts.ScopeManifest``). It is **not reachable from any
    production compile path**: ``workflow_summary_from_contracts``
    emits :data:`_NO_AUTHORITATIVE_SCOPE_MARKER` when no authoritative
    ``workflow_scope`` row is provided, not a render of
    ``work_item.scope``. The helper is retained as a unit-level
    utility for tests / diagnostic tooling that work directly with
    the intent-declaration manifest.
    See DEC-CLAUDEX-PROMPT-PACK-SCOPE-AUTHORITY-002.
    """
    lines: list[str] = []

    lines.append("Allowed paths:")
    if scope.allowed_paths:
        for path in scope.allowed_paths:
            lines.append(f"  - {path}")
    else:
        lines.append("  - (unrestricted)")

    lines.append("Required paths:")
    if scope.required_paths:
        for path in scope.required_paths:
            lines.append(f"  - {path}")
    else:
        lines.append("  - (none)")

    lines.append("Forbidden paths:")
    if scope.forbidden_paths:
        for path in scope.forbidden_paths:
            lines.append(f"  - {path}")
    else:
        lines.append("  - (none)")

    lines.append("State domains:")
    if scope.state_domains:
        for domain in scope.state_domains:
            lines.append(f"  - {domain}")
    else:
        lines.append("  - (none)")

    return "\n".join(lines)


def _render_scope_summary_from_workflow_scope(scope_record: dict) -> str:
    """Render a ``workflow_scope`` table row into a deterministic block.

    @decision DEC-CLAUDEX-PROMPT-PACK-SCOPE-AUTHORITY-001
    Title: prompt-pack scope_summary derives from workflow_scope, the
      single enforcement authority — not from work_item.scope
    Status: accepted (cutover-maintenance slice)
    Rationale: ``bash_workflow_scope`` policy reads the ``workflow_scope``
      table (via ``PolicyContext.scope`` populated by
      ``policy_engine.build_context``) for every commit/merge enforcement
      decision. It is the single authority for the scope facts the gate
      evaluates. The prompt-pack previously rendered ``scope_summary``
      from ``work_item.scope`` (written once at work-item insert time and
      never refreshed), which silently drifted from the enforcement
      authority whenever a planner ran
      ``cc-policy workflow scope-set`` — exactly the drift observed in
      the WHO-remediation landing sequence, where the prompt-pack kept
      showing Slice 1 paths while the runtime had been refreshed to cover
      later slices.

      This renderer accepts a dict in the shape returned by
      ``workflows.get_scope(conn, workflow_id)`` — the enforcement
      authority loader — so the compiled prompt-pack cannot go out of
      sync with the policy engine on this surface.

      ``work_item.scope`` is preserved as the planner's intent
      declaration. When
      :func:`workflow_summary_from_contracts` receives both sources, it
      mechanically validates they agree (set equality across allowed /
      required / forbidden paths) and raises ``ValueError`` on
      divergence. That converts silent drift into a loud failure at
      compile time.

    The record shape is:

      {
        "workflow_id": str,
        "allowed_paths": [str, ...],
        "required_paths": [str, ...],
        "forbidden_paths": [str, ...],
        "authority_domains": [str, ...],
        "updated_at": int,
      }

    Every section always prints under its labelled heading; empty
    lists produce explicit ``(unrestricted)`` / ``(none)`` markers.
    ``authority_domains`` replaces ``state_domains`` since that is
    what the enforcement row carries.
    """
    allowed = list(scope_record.get("allowed_paths") or [])
    required = list(scope_record.get("required_paths") or [])
    forbidden = list(scope_record.get("forbidden_paths") or [])
    authorities = list(scope_record.get("authority_domains") or [])

    lines: list[str] = []

    lines.append("Allowed paths:")
    if allowed:
        for path in allowed:
            lines.append(f"  - {path}")
    else:
        lines.append("  - (unrestricted)")

    lines.append("Required paths:")
    if required:
        for path in required:
            lines.append(f"  - {path}")
    else:
        lines.append("  - (none)")

    lines.append("Forbidden paths:")
    if forbidden:
        for path in forbidden:
            lines.append(f"  - {path}")
    else:
        lines.append("  - (none)")

    lines.append("Authority domains:")
    if authorities:
        for domain in authorities:
            lines.append(f"  - {domain}")
    else:
        lines.append("  - (none)")

    return "\n".join(lines)


def _validate_work_item_scope_matches_authority(
    work_item_scope: "contracts.ScopeManifest",
    workflow_scope_record: dict,
) -> None:
    """Raise ``ValueError`` if the work-item scope diverges from the
    authoritative ``workflow_scope`` record on any of the three path sets.

    Compares via set equality so order differences do not trip the gate.
    ``state_domains`` / ``authority_domains`` are NOT compared — they
    carry different vocabularies (state domains on the work-item side,
    authority domains on the enforcement side). The path triad is what
    enforcement evaluates.

    @decision DEC-CLAUDEX-PROMPT-PACK-SCOPE-AUTHORITY-001
    This validator is the mechanical guarantee that the planner's
    intent declaration (``work_items.scope_json``) has not drifted
    from the enforcement authority (``workflow_scope`` row).
    Divergence is a planner bug that should fail loudly before the
    prompt pack is emitted, not silently produce a misleading
    scope summary that contradicts what the commit gate will enforce.
    """
    def _triad(record_or_manifest, allowed_attr, required_attr, forbidden_attr):
        return (
            frozenset(getattr(record_or_manifest, allowed_attr) or ()),
            frozenset(getattr(record_or_manifest, required_attr) or ()),
            frozenset(getattr(record_or_manifest, forbidden_attr) or ()),
        )

    wi = (
        frozenset(work_item_scope.allowed_paths),
        frozenset(work_item_scope.required_paths),
        frozenset(work_item_scope.forbidden_paths),
    )
    auth = (
        frozenset(workflow_scope_record.get("allowed_paths") or ()),
        frozenset(workflow_scope_record.get("required_paths") or ()),
        frozenset(workflow_scope_record.get("forbidden_paths") or ()),
    )
    if wi != auth:
        diffs: list[str] = []
        labels = ("allowed_paths", "required_paths", "forbidden_paths")
        for name, w, a in zip(labels, wi, auth):
            extra_wi = sorted(w - a)
            extra_auth = sorted(a - w)
            if extra_wi or extra_auth:
                diffs.append(
                    f"  {name}: work_item-extra={extra_wi}, "
                    f"workflow_scope-extra={extra_auth}"
                )
        raise ValueError(
            "workflow_summary_from_contracts: work_item.scope has drifted "
            "from the enforcement authority (workflow_scope row). The two "
            "must agree on the path triad before a prompt pack can compile. "
            "Repair with 'cc-policy workflow scope-sync <workflow_id> "
            "--work-item-id <work_item_id> --scope-file <scope.json>' so "
            "workflow_scope and work_items.scope_json are written atomically "
            "from the same ScopeManifest. "
            "Divergence:\n" + "\n".join(diffs)
        )


def _render_evaluation_summary(
    goal: "contracts.GoalContract",
    evaluation: "contracts.EvaluationContract",
) -> str:
    """Render a deterministic goal + evaluation contract summary.

    Combines ``goal.desired_end_state`` with the work-item's
    ``EvaluationContract`` fields. Every field has an explicit
    marker for its empty case so the output is never blank.

    Section group order is pinned by tests (DEC-CLAUDEX-EVAL-CONTRACT-SCHEMA-PARITY-001):

    Group 1 — Tests / Evidence:
      ``Required tests:`` → ``Required evidence:``

    Group 2 — Integration surface + constraints (NEW — slice 33):
      ``Required real-path checks:`` → ``Required authority invariants:``
      → ``Required integration points:`` → ``Forbidden shortcuts:`` → ``Notes:``

    Group 3 — Readiness boundaries:
      ``Rollback boundary: ...`` → ``Acceptance notes: ...``
      → ``Ready for guardian when: ...``

    Future implementers: do NOT reorder sections without updating the
    test_renderer_group_order test in
    tests/runtime/test_work_item_contract_codec_eval_schema_parity.py.
    """
    lines: list[str] = []

    desired = goal.desired_end_state.strip()
    if desired:
        lines.append(f"Desired end state: {desired}")
    else:
        lines.append("Desired end state: (unspecified)")

    # Group 1: tests / evidence
    lines.append("Required tests:")
    if evaluation.required_tests:
        for test in evaluation.required_tests:
            lines.append(f"  - {test}")
    else:
        lines.append("  - (none)")

    lines.append("Required evidence:")
    if evaluation.required_evidence:
        for item in evaluation.required_evidence:
            lines.append(f"  - {item}")
    else:
        lines.append("  - (none)")

    # Group 2: integration surface + constraints
    # (NEW in slice 33 — DEC-CLAUDEX-EVAL-CONTRACT-SCHEMA-PARITY-001)
    lines.append("Required real-path checks:")
    if evaluation.required_real_path_checks:
        for item in evaluation.required_real_path_checks:
            lines.append(f"  - {item}")
    else:
        lines.append("  - (none)")

    lines.append("Required authority invariants:")
    if evaluation.required_authority_invariants:
        for item in evaluation.required_authority_invariants:
            lines.append(f"  - {item}")
    else:
        lines.append("  - (none)")

    lines.append("Required integration points:")
    if evaluation.required_integration_points:
        for item in evaluation.required_integration_points:
            lines.append(f"  - {item}")
    else:
        lines.append("  - (none)")

    lines.append("Forbidden shortcuts:")
    if evaluation.forbidden_shortcuts:
        for item in evaluation.forbidden_shortcuts:
            lines.append(f"  - {item}")
    else:
        lines.append("  - (none)")

    # Group 3: readiness boundaries
    rollback = evaluation.rollback_boundary.strip()
    if rollback:
        lines.append(f"Rollback boundary: {rollback}")
    else:
        lines.append("Rollback boundary: (unspecified)")

    acceptance = evaluation.acceptance_notes.strip()
    if acceptance:
        lines.append(f"Acceptance notes: {acceptance}")
    else:
        lines.append("Acceptance notes: (none)")

    guardian_def = evaluation.ready_for_guardian_definition.strip()
    if guardian_def:
        lines.append(f"Ready for guardian when: {guardian_def}")
    else:
        lines.append("Ready for guardian when: (unspecified)")

    return "\n".join(lines)


def _render_rollback_boundary(
    evaluation: "contracts.EvaluationContract",
) -> str:
    """Return ``evaluation.rollback_boundary`` or an explicit placeholder.

    ``WorkflowContractSummary`` rejects empty/whitespace-only
    strings, so the helper must always hand back a non-empty
    value. A contract that leaves the rollback boundary blank
    produces the sentinel ``"(unspecified)"`` — a clear signal to
    the reader that the upstream record had no declared boundary,
    distinct from a contract that declares ``"git checkout --"``.
    """
    text = evaluation.rollback_boundary.strip()
    if text:
        return text
    return "(unspecified)"


def workflow_summary_from_contracts(
    *,
    workflow_id: str,
    goal: "contracts.GoalContract",
    work_item: "contracts.WorkItemContract",
    workflow_scope_record: Optional[dict] = None,
) -> WorkflowContractSummary:
    """Derive a :class:`WorkflowContractSummary` from canonical contract records.

    This is a pure, deterministic bridge from the Phase 1
    ``runtime.core.contracts`` state family into the resolver's
    ``WorkflowContractSummary`` carrier. Same inputs produce
    byte-identical output.

    Validation rules enforced at call time:

      * ``goal`` must be a :class:`contracts.GoalContract`
        instance. Type mismatch raises ``ValueError`` with a clear
        message.
      * ``work_item`` must be a :class:`contracts.WorkItemContract`
        instance. Type mismatch raises ``ValueError``.
      * ``work_item.goal_id`` must equal ``goal.goal_id``. Mismatch
        raises ``ValueError`` with both ids surfaced in the
        message.

    Field derivation:

      * ``title`` comes from ``work_item.title`` verbatim — not
        folklore text.
      * ``status`` is a compact deterministic string that preserves
        both the goal and work-item status: e.g.
        ``"goal=active; work_item=in_progress"``.
      * ``scope_summary`` is rendered mechanically. When the caller
        passes ``workflow_scope_record`` (a dict returned by
        :func:`runtime.core.workflows.get_scope`), the summary is
        derived from that authoritative record via
        :func:`_render_scope_summary_from_workflow_scope`, AND
        ``work_item.scope`` is mechanically validated to match the
        authority — divergence raises ``ValueError``. When
        ``workflow_scope_record`` is ``None`` the summary emits
        :data:`_NO_AUTHORITATIVE_SCOPE_MARKER` — an explicit
        "no authoritative workflow_scope configured" line that
        cannot be confused with an enforceable scope. The legacy
        ``_render_scope_summary`` path on ``work_item.scope`` is
        **no longer reachable** from compile-path callers; see
        DEC-CLAUDEX-PROMPT-PACK-SCOPE-AUTHORITY-001 and -002 for
        the rationale.
      * ``evaluation_summary`` is rendered mechanically from
        ``goal.desired_end_state`` plus ``work_item.evaluation``
        via :func:`_render_evaluation_summary`.
      * ``rollback_boundary`` comes from
        ``work_item.evaluation.rollback_boundary`` with an
        explicit ``"(unspecified)"`` placeholder when the contract
        leaves it blank.

    The returned summary is already validated by
    :meth:`WorkflowContractSummary.__post_init__`, so it is
    guaranteed safe to pass into
    :func:`resolve_prompt_pack_layers`. An empty / blank
    ``work_item.title`` will surface as a
    ``WorkflowContractSummary`` validation ``ValueError`` rather
    than a silent drop — contracts that carry no title are a bug,
    not an acceptable input.
    """
    if not isinstance(goal, contracts.GoalContract):
        raise ValueError(
            "workflow_summary_from_contracts: goal must be a "
            f"contracts.GoalContract instance; got {type(goal).__name__}"
        )
    if not isinstance(work_item, contracts.WorkItemContract):
        raise ValueError(
            "workflow_summary_from_contracts: work_item must be a "
            f"contracts.WorkItemContract instance; got {type(work_item).__name__}"
        )
    if work_item.goal_id != goal.goal_id:
        raise ValueError(
            "workflow_summary_from_contracts: work_item.goal_id="
            f"{work_item.goal_id!r} does not match goal.goal_id="
            f"{goal.goal_id!r}"
        )

    status = f"goal={goal.status}; work_item={work_item.status}"
    # DEC-CLAUDEX-PROMPT-PACK-SCOPE-AUTHORITY-001: derive scope_summary
    # from the enforcement authority (workflow_scope row) when provided,
    # and mechanically validate that the work-item intent declaration
    # matches.
    # DEC-CLAUDEX-PROMPT-PACK-SCOPE-AUTHORITY-002: when no authoritative
    # record is provided, emit an explicit "no authoritative
    # workflow_scope configured" marker rather than rendering
    # work_item.scope. The production compile paths always pass
    # whatever workflows.get_scope() returns, so None means "no
    # enforcement row exists" — rendering work_item.scope there would
    # advertise intent-only paths as live law while the gate would
    # actually fail-closed with "No scope manifest."
    if workflow_scope_record is not None:
        _validate_work_item_scope_matches_authority(
            work_item.scope, workflow_scope_record
        )
        scope_summary = _render_scope_summary_from_workflow_scope(
            workflow_scope_record
        )
    else:
        scope_summary = _NO_AUTHORITATIVE_SCOPE_MARKER
    evaluation_summary = _render_evaluation_summary(goal, work_item.evaluation)
    rollback_boundary = _render_rollback_boundary(work_item.evaluation)

    return WorkflowContractSummary(
        workflow_id=workflow_id,
        title=work_item.title,
        status=status,
        scope_summary=scope_summary,
        evaluation_summary=evaluation_summary,
        rollback_boundary=rollback_boundary,
    )


# ---------------------------------------------------------------------------
# decision_work_registry.DecisionRecord → LocalDecisionSummary bridge
#
# Symmetric to workflow_summary_from_contracts — this is the third
# authority-derived layer helper. It shrinks the caller-supplied
# surface for the ``local_decision_pack`` layer: instead of
# hand-crafting a :class:`LocalDecisionSummary`, the caller passes
# a tuple of canonical ``DecisionRecord`` values (the caller is
# still responsible for opening the SQLite connection and running
# the query — the helper itself does no I/O) and gets a
# deterministically-rendered summary.
#
# Like the contracts bridge, this helper deliberately does NOT
# widen the top-level ``resolve_prompt_pack_layers`` signature.
# Callers pre-compute the summary via
# :func:`local_decision_summary_from_records` and pass the result
# into ``resolve_prompt_pack_layers(decision_summary=...)``. Keeping
# the two surfaces separate lets the bridge be tested, refactored,
# or replaced independently once a later slice lands a live
# relevance walker that selects decisions for a given scope.
# ---------------------------------------------------------------------------


def _rationale_from_records(
    normalized: Tuple["dwr.DecisionRecord", ...],
) -> str:
    """Compose the rationale string for a non-empty normalized record tuple.

    "Active head" means a decision whose status is ``"accepted"``
    AND whose ``superseded_by`` link is ``None``. When any active
    heads exist, the rationale lists them in canonical order.
    Otherwise the rationale degrades into a count-only fallback
    that acknowledges the record population without pretending
    any of them is authoritative. The degrade message is
    deliberately neutral about *why* no head is active (superseded
    vs rejected vs deprecated vs all-proposed) because tests need
    a stable single degrade form — a future slice can branch on
    status counts if the distinction becomes load-bearing.
    """
    active_heads = tuple(
        d for d in normalized
        if d.status == "accepted" and d.superseded_by is None
    )
    if active_heads:
        head_id_list = ", ".join(d.decision_id for d in active_heads)
        return f"Active head decisions: {head_id_list}"
    return (
        f"No active head decisions among {len(normalized)} "
        f"decision record(s)."
    )


def local_decision_summary_from_records(
    *,
    decisions: Tuple["dwr.DecisionRecord", ...],
) -> LocalDecisionSummary:
    """Derive a :class:`LocalDecisionSummary` from canonical decision records.

    This is a pure, deterministic bridge from the Phase 1
    ``runtime.core.decision_work_registry.DecisionRecord`` state
    into the resolver's ``LocalDecisionSummary`` carrier. The
    helper does **not** open a SQLite connection — the caller
    runs whatever query produces the relevant records (e.g.
    ``decision_work_registry.list_decisions`` scoped to the
    current domain) and hands the resulting tuple to this
    function. Same inputs produce byte-identical output.

    Contract:

      * ``decisions`` must be a tuple. Lists / generators /
        other iterables are rejected with a clear ``ValueError``
        so caller intent about immutability is preserved.
      * Every element must be a
        :class:`runtime.core.decision_work_registry.DecisionRecord`
        instance; wrong types raise ``ValueError`` with the index
        and observed type.
      * ``decision_id`` values must be unique across the tuple.
        Duplicates raise ``ValueError`` naming the colliding ids.
      * An empty tuple returns the default
        :class:`LocalDecisionSummary` (rationale
        ``"(no relevant decisions)"``, empty id tuple, empty
        supersession notes) — the same default a caller would
        construct manually.

    Derivation rules:

      * The helper sorts the records by ``(created_at,
        decision_id)`` so the output is independent of caller
        tuple order.
      * ``relevant_decision_ids`` is the sorted record order.
      * ``supersession_notes`` enumerates ``"NEW supersedes OLD"``
        lines for every record whose ``supersedes`` link is set.
        The notes are deduplicated and sorted lexicographically
        so the output is deterministic.
      * ``rationale`` lists the active head decisions when any
        exist; otherwise it degrades into a count-only message.
        See :func:`_rationale_from_records`.

    The returned summary is already validated by
    :meth:`LocalDecisionSummary.__post_init__`, so it is
    guaranteed safe to pass into
    :func:`resolve_prompt_pack_layers`.
    """
    if not isinstance(decisions, tuple):
        raise ValueError(
            "local_decision_summary_from_records: decisions must be a tuple "
            f"(got {type(decisions).__name__})"
        )

    for idx, item in enumerate(decisions):
        if not isinstance(item, dwr.DecisionRecord):
            raise ValueError(
                f"local_decision_summary_from_records: decisions[{idx}] must "
                f"be a runtime.core.decision_work_registry.DecisionRecord "
                f"instance; got {type(item).__name__}"
            )

    if not decisions:
        # Empty input → the same default a caller would construct
        # by hand. Keeps the empty case semantically identical
        # whether the caller uses the bridge or not.
        return LocalDecisionSummary()

    ids: list[str] = [d.decision_id for d in decisions]
    id_set = set(ids)
    if len(ids) != len(id_set):
        # Find the duplicate set deterministically.
        seen: set[str] = set()
        duplicates: list[str] = []
        for did in ids:
            if did in seen and did not in duplicates:
                duplicates.append(did)
            seen.add(did)
        raise ValueError(
            "local_decision_summary_from_records: duplicate decision_id(s) "
            f"in input: {sorted(duplicates)}"
        )

    # Canonical order: (created_at, decision_id). Independent of
    # whatever order the caller passed in.
    normalized: Tuple["dwr.DecisionRecord", ...] = tuple(
        sorted(decisions, key=lambda d: (d.created_at, d.decision_id))
    )

    relevant_decision_ids: Tuple[str, ...] = tuple(
        d.decision_id for d in normalized
    )

    # Supersession notes: mechanically derive from each record's
    # ``supersedes`` link, dedupe, and sort for determinism.
    note_set: set[str] = set()
    for d in normalized:
        if d.supersedes:
            note_set.add(f"{d.decision_id} supersedes {d.supersedes}")
    supersession_notes: Tuple[str, ...] = tuple(sorted(note_set))

    rationale = _rationale_from_records(normalized)

    return LocalDecisionSummary(
        rationale=rationale,
        relevant_decision_ids=relevant_decision_ids,
        supersession_notes=supersession_notes,
    )


# ---------------------------------------------------------------------------
# RuntimeStateSnapshot → RuntimeStateSummary bridge
#
# The third and final authority-derived helper in the resolver.
# Closes the last hand-carried caller surface for the
# ``runtime_state_pack`` layer. Unlike the contracts and decision
# bridges, the inputs here are NOT yet owned by a shadow
# persistence module: repo-level state like "current branch" and
# "active leases" lives in live runtime / filesystem / git
# state, not in a canonical shadow authority. This slice does NOT
# introduce a live state walker — it introduces a **typed
# snapshot dataclass** that a future walker will populate, plus a
# thin bridge that turns the snapshot into a
# :class:`RuntimeStateSummary`.
#
# The resolver's top-level signature is unchanged: callers still
# pass a :class:`RuntimeStateSummary` into
# :func:`resolve_prompt_pack_layers`. The bridge simply shrinks
# the remaining hand-crafted surface to "produce a
# :class:`RuntimeStateSnapshot` from whatever state source you
# have, then call the bridge" — once a later slice lands a live
# walker, the walker will emit :class:`RuntimeStateSnapshot`
# instances and the bridge stays unchanged.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class RuntimeStateSnapshot:
    """Typed snapshot of live repo/session runtime state.

    Carries the same semantic field set as
    :class:`RuntimeStateSummary` but in a canonical
    producer-owned form: tuples of non-empty strings, validated at
    construction time. A future live walker will instantiate this
    class from whatever state sources it consults (git, leases
    table, approvals, reviewer findings, etc.); this slice only
    delivers the typed carrier + a thin pure bridge.

    Required fields:

      * ``current_branch`` — non-empty string identifying the
        current git branch.
      * ``worktree_path`` — non-empty string identifying the
        worktree the snapshot was taken from.

    Optional collection fields (all default to empty tuple):

      * ``active_leases`` — tuple of active lease identifiers.
      * ``open_approvals`` — tuple of unresolved approval tokens.
      * ``unresolved_findings`` — tuple of outstanding reviewer /
        policy findings.

    Validation mirrors the other snapshot dataclasses in this
    module: non-empty strings are required where marked, every
    collection must be a tuple of non-empty strings.
    """

    current_branch: str
    worktree_path: str
    active_leases: Tuple[str, ...] = ()
    open_approvals: Tuple[str, ...] = ()
    unresolved_findings: Tuple[str, ...] = ()

    def __post_init__(self) -> None:
        _require_non_empty_str(self, "current_branch")
        _require_non_empty_str(self, "worktree_path")
        _require_tuple_of_non_empty_strings(self, "active_leases")
        _require_tuple_of_non_empty_strings(self, "open_approvals")
        _require_tuple_of_non_empty_strings(self, "unresolved_findings")


def runtime_state_summary_from_snapshot(
    *,
    snapshot: RuntimeStateSnapshot,
) -> RuntimeStateSummary:
    """Derive a :class:`RuntimeStateSummary` from a :class:`RuntimeStateSnapshot`.

    Pure and deterministic: same input produces byte-identical
    output. The helper is intentionally thin — the
    :class:`RuntimeStateSummary` already owns the layer render
    logic, and the snapshot already owns the field validation.
    What this bridge adds is:

      1. A type check that the caller passed a
         :class:`RuntimeStateSnapshot` instance (rather than a
         raw dict or an ad-hoc object with the right attribute
         names). Type mismatch raises ``ValueError`` with a clear
         message.
      2. Canonical lexicographic ordering of the three tuple
         fields (``active_leases``, ``open_approvals``,
         ``unresolved_findings``) so the resulting summary is
         independent of snapshot tuple order. Two snapshots that
         carry the same leases in different orders produce
         identical summaries, and therefore identical compiled
         ``PromptPack.content_hash`` values downstream.

    The empty-tuple case is preserved: an empty snapshot
    collection yields an empty summary collection, which
    :meth:`RuntimeStateSummary.render` turns into the existing
    ``(none)`` marker text. The bridge does not duplicate
    render logic — that stays in the summary dataclass.
    """
    if not isinstance(snapshot, RuntimeStateSnapshot):
        raise ValueError(
            "runtime_state_summary_from_snapshot: snapshot must be a "
            f"RuntimeStateSnapshot instance; got {type(snapshot).__name__}"
        )

    # Canonical lexicographic ordering for determinism. Empty
    # tuples sort to empty tuples — the existing
    # RuntimeStateSummary.render() path handles those via
    # ``(none)`` markers without any bridge-side special casing.
    sorted_leases = tuple(sorted(snapshot.active_leases))
    sorted_approvals = tuple(sorted(snapshot.open_approvals))
    sorted_findings = tuple(sorted(snapshot.unresolved_findings))

    return RuntimeStateSummary(
        current_branch=snapshot.current_branch,
        worktree_path=snapshot.worktree_path,
        active_leases=sorted_leases,
        open_approvals=sorted_approvals,
        unresolved_findings=sorted_findings,
    )


def constitution_watched_files() -> Tuple[str, ...]:
    """Return the full concrete constitution-level path set in
    deterministic registry order.

    This helper is the single bridge between compiled prompt packs and
    the constitution-level authority set: the compile path uses it to
    populate ``StaleCondition.watched_files`` so that any change to a
    concrete constitution file stales every compiled prompt pack whose
    constitution layer was derived from it (Phase 7 Slice 11).

    Order matches :func:`constitution_registry.all_concrete_paths`
    (CUTOVER_PLAN baseline → Phase promotions in landing order), so
    downstream metadata is byte-stable across compile calls when the
    registry is unchanged.

    The helper deliberately does NOT duplicate the path list — it
    forwards to ``constitution_registry.all_concrete_paths()`` so the
    registry remains the single authority.
    """
    return cr.all_concrete_paths()


__all__ = [
    # Caller-supplied summary dataclasses
    "WorkflowContractSummary",
    "LocalDecisionSummary",
    "RuntimeStateSummary",
    # Authority-derived layer renderers
    "render_constitution_layer",
    "render_stage_contract_layer",
    "render_next_actions_layer",
    # Top-level resolver
    "resolve_prompt_pack_layers",
    # contracts.py → WorkflowContractSummary bridge
    "workflow_summary_from_contracts",
    # decision_work_registry → LocalDecisionSummary bridge
    "local_decision_summary_from_records",
    # RuntimeStateSnapshot → RuntimeStateSummary bridge
    "RuntimeStateSnapshot",
    "runtime_state_summary_from_snapshot",
    # Compile-path freshness bridge (Phase 7 Slice 11)
    "constitution_watched_files",
]
