"""ClauDEX authority + capability registry.

@decision DEC-CLAUDEX-AUTHORITY-REGISTRY-001
Title: runtime/core/authority_registry.py is the sole declaration of role capabilities and operational-fact ownership
Status: accepted (Phase 3 — capability resolution live in policy engine; shadow-only for routing modules)
Rationale: CUTOVER_PLAN §Target Architecture §5 ("Capability Model") and
  §Execution Model require an explicit, runtime-owned mapping from roles
  to capabilities so that later policy-engine slices can key off
  ``can_write_source``, ``can_land_git``, ``read_only_review`` etc.
  instead of repeating raw role-name checks across bash and Python. This
  module is that authority.

  Scope discipline (CUTOVER_PLAN §Scope Boundary + the Phase 1 exit
  criterion "routing and capability ownership are explicit in code"):

    * This module owns the *capability vocabulary* and the *stage →
      capability mapping* for the ClauDEX graph.

    * **Live for policy engine**: ``policy_engine.build_context()``
      imports ``capabilities_for()`` to populate
      ``PolicyContext.capabilities``, and ``enforcement_config`` imports
      ``CAN_SET_CONTROL_CONFIG`` for its WHO gate. Three policy modules
      (``write_who``, ``write_plan_guard``, ``bash_worktree_creation``)
      gate on ``context.capabilities`` rather than raw role strings.

    * **Still shadow-only for routing modules**: this module does not
      touch ``dispatch_engine`` or ``completions.determine_next_role``.
      Those live routing paths remain isolated until the cutover plan
      authorises the transition.

    * Stage identifiers are imported from
      ``runtime/core/stage_registry.py`` — this module MUST NOT invent
      a second stage-name vocabulary (that would defeat DEC-CLAUDEX-STAGE-REGISTRY-001).

    * Guardian is split into two stages — ``guardian:provision`` and
      ``guardian:land`` — each with a disjoint capability profile, so
      the model captures the CUTOVER_PLAN's separation of provisioning
      authority from landing authority (§W6).

    * The operational-fact authority table only declares ownership for
      shadow-kernel modules that **actually exist today** in the repo.
      It deliberately does NOT claim ownership for future modules
      (reviewer lane, projection reflow engine, decision registry
      persistence) that the CUTOVER_PLAN lists as end-state
      authorities but have not been built yet. The table is expanded
      in later slices as new owner modules come online — for example,
      the Phase 2 ``hook_wiring`` fact was added once
      ``runtime.core.hook_manifest`` and ``cc-policy hook
      validate-settings`` landed, and the Phase 2
      ``prompt_pack_layers`` fact was added once
      ``runtime.core.prompt_pack`` realised the runtime-compiled
      prompt-pack authority. That keeps the table honest: every entry
      can be imported and exercised right now.

  Capability set (exactly the CUTOVER_PLAN §5 minimum):

    - can_write_source
    - can_write_governance
    - can_land_git
    - can_provision_worktree
    - can_set_control_config
    - read_only_review
    - can_emit_dispatch_transition

  Stage → capability mapping rationale (CUTOVER_PLAN §Target Architecture):

    * ``planner`` owns governance and workflow planning writes and
      config defaults (§Execution Model + §Authority Map: "Goal
      continuation after landing" + "Config defaults"). No source
      writes, no git landing, no worktree provisioning, no review-only
      constraint.

    * ``guardian:provision`` owns worktree provisioning only (§W6). It
      does not land git in provision mode — that is
      ``guardian:land``'s job — and it does not write source or
      governance.

    * ``implementer`` owns source-change authority inside scoped
      workflow boundaries (§Execution Model). Nothing else.

    * ``reviewer`` is mechanically read-only (§W4 +
      §Non-Negotiable Cutover Rules: "reviewer read-only rules are
      enforceable mechanically"). It may emit dispatch verdicts
      (``ready_for_guardian`` / ``needs_changes`` / ``blocked_by_plan``)
      but may not write source, write governance, land git, provision
      worktrees, or set control config.

    * ``guardian:land`` owns git landing authority only. It is the sole
      stage with ``can_land_git``, matching §W5 "Guardian as sole git
      landing authority".

  All active stages carry ``can_emit_dispatch_transition`` because the
  target stage graph is driven by stage verdicts (see
  ``runtime.core.stage_registry``). That is the one capability shared
  across all active stages; the other capabilities are all role-exclusive.

  Operational-fact authority table:

    Shadow-kernel facts that currently exist in code:

      * ``stage_transitions``        → ``runtime.core.stage_registry``
      * ``role_capabilities``        → ``runtime.core.authority_registry``
      * ``authority_table``          → ``runtime.core.authority_registry``
      * ``goal_contract_shape``      → ``runtime.core.contracts``
      * ``work_item_contract_shape`` → ``runtime.core.contracts``
      * ``shadow_decision_mapping``  → ``runtime.core.dispatch_shadow``
      * ``shadow_parity_reporting``  → ``runtime.core.shadow_parity``
      * ``hook_wiring``              → ``runtime.core.hook_manifest``
      * ``prompt_pack_layers``       → ``runtime.core.prompt_pack``

    The ``hook_wiring`` fact realises CUTOVER_PLAN §Authority Map
    row ``Hook wiring | runtime-declared hook manifest or validated
    settings | settings.json, hook docs``: the runtime-owned
    ``hook_manifest`` module is the sole authority for repo hook
    adapter wiring, and ``cc-policy hook validate-settings`` is the
    read-only validator that proves ``settings.json`` matches it.

    The ``prompt_pack_layers`` fact realises CUTOVER_PLAN §Runtime-
    Compiled Prompt Packs and the Phase 2 exit criterion that
    "hook-delivered guidance comes from compiled runtime context":
    the runtime-owned ``prompt_pack`` module owns the canonical
    six-layer vocabulary, the fixed layer ordering, the layer
    validation rules, and the deterministic compilation contract
    that turns explicit layer bodies into a
    ``projection_schemas.PromptPack`` record. The same key name
    (``prompt_pack_layers``) is used in the compiler's
    ``ProjectionMetadata.source_versions`` pair so the authority
    table and the projection provenance stay consistent.

    The table is closed: adding a future owner is a deliberate
    authority change that must be reflected here (and validated by
    tests). That is how this module enforces
    CUTOVER_PLAN Constitutional Rule #1 ("one authority per
    operational fact") for the shadow-kernel surfaces we have today.

  What this module deliberately does NOT do:

    * It does not import ``dispatch_engine``, ``completions``,
      ``policy_engine``, ``hooks``, or any settings/config machinery.
      Its only runtime.core dependency is ``stage_registry``.
    * It is not imported by the live routing modules
      (``dispatch_engine``, ``completions``). Those modules remain
      isolated until the cutover plan authorises the transition.
      (The live policy engine and enforcement_config DO import this
      module — that wiring is intentional as of Phase 3.)
    * It does not decide whether a specific tool call is permitted.
      Those decisions belong in individual policy modules that gate on
      ``PolicyContext.capabilities`` populated from this module's
      ``capabilities_for()`` resolver.
    * It does not enumerate stage transitions — that is
      ``stage_registry``'s job and this module imports the stage names
      from there.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, FrozenSet, Mapping, Optional, Tuple

from runtime.core import stage_registry as sr

# ---------------------------------------------------------------------------
# Capability vocabulary — exactly the CUTOVER_PLAN §5 minimum set.
#
# These strings are the canonical identifiers for every later capability
# check. They are deliberately plain strings (not an enum) so hooks,
# policies, prompt packs, and diagnostics can pass them across process
# boundaries without serialization ceremony.
# ---------------------------------------------------------------------------

CAN_WRITE_SOURCE: str = "can_write_source"
CAN_WRITE_GOVERNANCE: str = "can_write_governance"
CAN_LAND_GIT: str = "can_land_git"
CAN_PROVISION_WORKTREE: str = "can_provision_worktree"
CAN_SET_CONTROL_CONFIG: str = "can_set_control_config"
READ_ONLY_REVIEW: str = "read_only_review"
CAN_EMIT_DISPATCH_TRANSITION: str = "can_emit_dispatch_transition"

CAPABILITIES: FrozenSet[str] = frozenset(
    {
        CAN_WRITE_SOURCE,
        CAN_WRITE_GOVERNANCE,
        CAN_LAND_GIT,
        CAN_PROVISION_WORKTREE,
        CAN_SET_CONTROL_CONFIG,
        READ_ONLY_REVIEW,
        CAN_EMIT_DISPATCH_TRANSITION,
    }
)


# ---------------------------------------------------------------------------
# Stage → capability mapping
#
# The keys here are stage identifiers imported from stage_registry — this
# file never invents stage names. Every active stage in the target graph
# has exactly one entry; sink stages (TERMINAL, USER) have no capabilities
# and are omitted.
#
# Each capability is role-exclusive except `can_emit_dispatch_transition`,
# which every active stage carries because verdict emission is the engine
# of the stage graph.
# ---------------------------------------------------------------------------

STAGE_CAPABILITIES: Mapping[str, FrozenSet[str]] = {
    sr.PLANNER: frozenset(
        {
            CAN_WRITE_GOVERNANCE,
            CAN_SET_CONTROL_CONFIG,
            CAN_EMIT_DISPATCH_TRANSITION,
        }
    ),
    sr.GUARDIAN_PROVISION: frozenset(
        {
            CAN_PROVISION_WORKTREE,
            CAN_EMIT_DISPATCH_TRANSITION,
        }
    ),
    sr.IMPLEMENTER: frozenset(
        {
            CAN_WRITE_SOURCE,
            CAN_EMIT_DISPATCH_TRANSITION,
        }
    ),
    sr.REVIEWER: frozenset(
        {
            READ_ONLY_REVIEW,
            CAN_EMIT_DISPATCH_TRANSITION,
        }
    ),
    sr.GUARDIAN_LAND: frozenset(
        {
            CAN_LAND_GIT,
            CAN_EMIT_DISPATCH_TRANSITION,
        }
    ),
}

# ---------------------------------------------------------------------------
# Live-role capability aliases
#
# The harness emits role identifiers that do not always match the canonical
# stage-registry names. Policies and build_context() call capabilities_for()
# with whatever actor_role they received; this table ensures the lookup
# degrades cleanly rather than returning an empty frozenset for known aliases.
#
# "Plan" — historical harness alias observed in live payloads. Canonical
#   delivery-path subagent type is the repo-owned custom agent name
#   ``planner`` so the launch resolves through ``agents/planner.md`` rather
#   than a generic or built-in planner seat.
# "guardian" — live lease role used by both provision and land modes. Mapped
#   to GUARDIAN_PROVISION so that CAN_PROVISION_WORKTREE is reachable for
#   the bash_worktree_creation policy; both modes may run `git worktree add`
#   for manual recovery paths.
# ---------------------------------------------------------------------------

_LIVE_ROLE_ALIASES: Mapping[str, str] = {
    "Plan": sr.PLANNER,
}

# ---------------------------------------------------------------------------
# Stage → delivery-path subagent identity
#
# The control plane needs a single authority for which Claude subagent type is
# valid for each runtime stage. This is distinct from the stage id itself:
# guardian has two runtime stages but one repo-owned custom agent prompt
# (``agents/guardian.md``). The canonical values below are the exact
# ``tool_input.subagent_type`` strings the orchestrator must use for stage work.
#
# Historical aliases such as ``Plan`` are tolerated for capability lookups via
# _LIVE_ROLE_ALIASES, but they are NOT canonical delivery identities; using the
# wrong subagent type bypasses the stage-specific agent prompt file and weakens
# the checks-and-balances model.
# ---------------------------------------------------------------------------

STAGE_SUBAGENT_TYPES: Mapping[str, str] = {
    sr.PLANNER: "planner",
    sr.GUARDIAN_PROVISION: "guardian",
    sr.IMPLEMENTER: "implementer",
    sr.REVIEWER: "reviewer",
    sr.GUARDIAN_LAND: "guardian",
}

_SUBAGENT_TYPE_ALIASES: Mapping[str, str] = {
    "Plan": "planner",
    "planner": "planner",
    "guardian": "guardian",
    "implementer": "implementer",
    "reviewer": "reviewer",
}

# Canonical active-stage ordering used by all_contracts() and
# stages_with_capability(). Declared once to avoid order drift.
_STAGE_ORDER: Tuple[str, ...] = (
    sr.PLANNER,
    sr.GUARDIAN_PROVISION,
    sr.IMPLEMENTER,
    sr.REVIEWER,
    sr.GUARDIAN_LAND,
)


# ---------------------------------------------------------------------------
# Stage capability contracts (Phase 3 — Capability-Gated Policy Model)
#
# A StageCapabilityContract bundles the granted and denied capability sets
# for a single stage into a frozen, projectable record. The ``denied`` set
# is the complement of ``granted`` within ``CAPABILITIES`` — making the
# negative assertions explicit so that prompt-pack consumers don't need to
# know the full vocabulary to compute what a stage may NOT do.
#
# @decision DEC-CLAUDEX-CAPABILITY-CONTRACT-001
# Title: StageCapabilityContract is the projectable form of STAGE_CAPABILITIES
# Status: accepted (Phase 3 seed)
# Rationale: CUTOVER_PLAN Phase 3 ("Capability-Gated Policy Model") requires
#   capabilities to be "explicit and projectable" — suitable for embedding in
#   runtime-compiled prompt packs so agents receive their boundaries as
#   compiled context rather than prose convention. The raw
#   ``STAGE_CAPABILITIES`` mapping returns a frozenset of granted caps; it
#   does not carry the denied set or structural metadata (read_only flag).
#   StageCapabilityContract closes that gap as a pure, deterministic
#   projection of the same underlying authority (``role_capabilities`` fact).
#   No new operational fact is needed: the contract is derived from
#   STAGE_CAPABILITIES, not a separate data source.
#
#   Invariants (enforced by tests, not narrated):
#     1. resolve_contract(stage) returns None for unknown stages and sink
#        stages — fail-closed.
#     2. granted ∪ denied = CAPABILITIES and granted ∩ denied = ∅ for every
#        contract — the partition is complete and disjoint.
#     3. Reviewer's contract has read_only=True and denies every write/land/
#        provision/governance/config capability.
#     4. Planner, guardian:provision, and guardian:land produce distinct
#        contracts.
#     5. as_prompt_projection() is JSON-serializable and deterministic
#        (sorted lists, stable key order) so prompt packs built from it are
#        byte-identical across runs.
#     6. resolve_contract() resolves live-role aliases via
#        _LIVE_ROLE_ALIASES before lookup, matching capabilities_for()
#        behavior.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class StageCapabilityContract:
    """Structured capability contract for a single active stage.

    Projectable into prompt packs so agents receive their capability
    boundaries as runtime-compiled context rather than prose convention.

    ``granted`` — capabilities the stage may exercise.
    ``denied``  — capabilities the stage explicitly lacks (complement of
                  granted within CAPABILITIES).
    ``read_only`` — True iff the stage carries READ_ONLY_REVIEW.
    """

    stage_id: str
    granted: FrozenSet[str]
    denied: FrozenSet[str]
    read_only: bool

    def as_prompt_projection(self) -> Dict[str, Any]:
        """Return a JSON-serializable, deterministic projection.

        The output dict has sorted lists (not frozensets) and a stable
        key order so prompt packs built from this projection are
        byte-identical across runs.
        """
        return {
            "stage": self.stage_id,
            "granted": sorted(self.granted),
            "denied": sorted(self.denied),
            "read_only": self.read_only,
        }


# ---------------------------------------------------------------------------
# Operational-fact authority table
#
# This is the closed-form Phase 1 "authority map" for shadow-kernel
# surfaces that already live in code. CUTOVER_PLAN Constitutional Rule #1:
# "one authority per operational fact". The test suite pins that every
# fact name is unique and every owner module is importable.
#
# Owners named here are the TRUE owners, not just "a place the fact
# currently appears". Anything that lives only in docs/prose is not an
# authority and does not belong here.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class OperationalFact:
    """A single operational fact with its sole owning runtime module.

    ``name`` is the canonical identifier used by tests and any future
    ``cc-policy authority owner-of`` CLI. ``description`` explains what
    the fact covers in one sentence. ``owner_module`` is the fully
    qualified Python module path; it must be importable from this
    repo's runtime.
    """

    name: str
    description: str
    owner_module: str


AUTHORITY_TABLE: Tuple[OperationalFact, ...] = (
    OperationalFact(
        name="stage_transitions",
        description=(
            "Target ClauDEX stage graph and legal (stage, verdict) → "
            "next_stage transitions."
        ),
        owner_module="runtime.core.stage_registry",
    ),
    OperationalFact(
        name="role_capabilities",
        description=(
            "Mapping from target stage identifiers to the capability set "
            "a stage is allowed to exercise."
        ),
        owner_module="runtime.core.authority_registry",
    ),
    OperationalFact(
        name="authority_table",
        description=(
            "Closed registry of operational facts and their sole owning "
            "runtime modules for the Phase 1 shadow kernel."
        ),
        owner_module="runtime.core.authority_registry",
    ),
    OperationalFact(
        name="goal_contract_shape",
        description=(
            "Typed schema for the outer-loop goal contract owned by "
            "planner (desired end state, autonomy budget, continuation "
            "rules, stop conditions)."
        ),
        owner_module="runtime.core.contracts",
    ),
    OperationalFact(
        name="work_item_contract_shape",
        description=(
            "Typed schema for the inner-loop work-item contract (scope "
            "manifest, evaluation contract, reviewer convergence state)."
        ),
        owner_module="runtime.core.contracts",
    ),
    OperationalFact(
        name="shadow_decision_mapping",
        description=(
            "Pure mapping from live (role, verdict) routing outcomes "
            "into the target shadow (stage, verdict) space, used by the "
            "dispatch_engine shadow observer."
        ),
        owner_module="runtime.core.dispatch_shadow",
    ),
    OperationalFact(
        name="shadow_parity_reporting",
        description=(
            "Aggregation of shadow_stage_decision audit events into a "
            "parity report and invariant check."
        ),
        owner_module="runtime.core.shadow_parity",
    ),
    OperationalFact(
        name="hook_wiring",
        description=(
            "Runtime-declared hook adapter wiring — the sole authority for "
            "which repo-owned hook adapters are bound to which harness "
            "events and matchers. settings.json and hooks/HOOKS.md are "
            "derived surfaces that must be validated against this "
            "manifest (CUTOVER_PLAN §Authority Map line 515 + "
            "§Derived-Surface Validation)."
        ),
        owner_module="runtime.core.hook_manifest",
    ),
    OperationalFact(
        name="prompt_pack_layers",
        description=(
            "Runtime-compiled prompt-pack layer authority — the sole "
            "owner of the canonical six-layer vocabulary (constitution, "
            "stage_contract, workflow_contract, local_decision_pack, "
            "runtime_state_pack, next_actions), their fixed ordering, "
            "layer validation rules, and the deterministic compilation "
            "contract that turns explicit layer bodies into a "
            "projection_schemas.PromptPack record. Hook-delivered "
            "guidance (SessionStart / UserPromptSubmit / SubagentStart) "
            "must route through compiled prompt packs built from this "
            "authority rather than hand-maintained local prompt "
            "fragments (CUTOVER_PLAN §Runtime-Compiled Prompt Packs + "
            "§Phase 2 exit criterion: compiled runtime context)."
        ),
        owner_module="runtime.core.prompt_pack",
    ),
)


# ---------------------------------------------------------------------------
# Pure helpers
#
# Everything below is a pure lookup on the module-level tables above. No
# I/O, no mutation, no exceptions on any string input. Tests pin the
# return shapes.
# ---------------------------------------------------------------------------


def capabilities_for(stage: str) -> FrozenSet[str]:
    """Return the declared capability set for ``stage``.

    Resolves live harness role aliases (``_LIVE_ROLE_ALIASES``) before the
    lookup so that policies and build_context() never need to handle
    harness-level role string variants (e.g. "Plan", "guardian") separately.

    Returns an empty frozenset for unknown stages or sink stages
    (``TERMINAL``, ``USER``). Sink stages legally have no capabilities.
    Never raises — safe to call with any string (or None).
    """
    caps = STAGE_CAPABILITIES.get(stage)
    if caps is not None:
        return caps
    canonical = _LIVE_ROLE_ALIASES.get(stage)
    if canonical is not None:
        return STAGE_CAPABILITIES.get(canonical, frozenset())
    return frozenset()


def stage_has_capability(stage: str, capability: str) -> bool:
    """Return True iff ``stage`` carries ``capability`` in the target model."""
    return capability in capabilities_for(stage)


def stages_with_capability(capability: str) -> Tuple[str, ...]:
    """Return active stages that carry ``capability``, in stage_registry order.

    Used by tests to assert capability exclusivity (e.g. exactly one
    stage has ``can_land_git``).
    """
    return tuple(s for s in _STAGE_ORDER if capability in STAGE_CAPABILITIES.get(s, frozenset()))


def canonical_stage_id(stage: str) -> Optional[str]:
    """Return the canonical active-stage id for ``stage``.

    Accepts canonical stage ids and the historical live-role aliases handled by
    ``resolve_contract()``. Returns ``None`` for unknown / sink / empty input.
    """
    contract = resolve_contract(stage)
    if contract is None:
        return None
    return contract.stage_id


def dispatch_subagent_type_for_stage(stage: str) -> Optional[str]:
    """Return the canonical Claude ``subagent_type`` for ``stage``.

    This is the delivery-path identity the orchestrator must pass to the Agent
    tool so Claude loads the repo-owned agent prompt (e.g. ``agents/planner.md``)
    rather than falling back to a generic seat.
    """
    canonical = canonical_stage_id(stage)
    if canonical is None:
        return None
    return STAGE_SUBAGENT_TYPES.get(canonical)


def canonical_dispatch_subagent_type(subagent_type: str) -> Optional[str]:
    """Canonicalize a Claude ``subagent_type`` for delivery-path stages.

    Returns the canonical custom-agent name (``planner``, ``implementer``,
    ``reviewer``, ``guardian``) or ``None`` when the value is not a recognised
    stage-bound delivery identity.
    """
    if not subagent_type:
        return None
    return _SUBAGENT_TYPE_ALIASES.get(subagent_type)


def stage_accepts_subagent_type(stage: str, subagent_type: str) -> bool:
    """Return True iff ``subagent_type`` is the canonical delivery seat for ``stage``."""
    expected = dispatch_subagent_type_for_stage(stage)
    if expected is None:
        return False
    return canonical_dispatch_subagent_type(subagent_type) == expected


def resolve_contract(stage: str) -> Optional[StageCapabilityContract]:
    """Resolve a stage identity into a structured capability contract.

    Resolves live-role aliases (``_LIVE_ROLE_ALIASES``) before lookup,
    matching ``capabilities_for()`` behavior.

    Returns ``None`` for unknown stages, sink stages (``TERMINAL``,
    ``USER``), and empty/None input — fail-closed. Never raises.

    The contract's ``denied`` set is ``CAPABILITIES - granted``, making
    negative assertions explicit for prompt-pack consumers.
    """
    # Resolve aliases to canonical stage id
    canonical = stage
    if stage not in STAGE_CAPABILITIES:
        alias_target = _LIVE_ROLE_ALIASES.get(stage)
        if alias_target is not None:
            canonical = alias_target
        else:
            return None

    caps = STAGE_CAPABILITIES.get(canonical)
    if caps is None:
        return None

    return StageCapabilityContract(
        stage_id=canonical,
        granted=caps,
        denied=CAPABILITIES - caps,
        read_only=READ_ONLY_REVIEW in caps,
    )


def all_contracts() -> Tuple[StageCapabilityContract, ...]:
    """Return capability contracts for all active stages in canonical order.

    Deterministic ordering (``_STAGE_ORDER``) supports prompt-pack
    compilation stability — repeated calls produce identical tuples.
    """
    result: list[StageCapabilityContract] = []
    for stage in _STAGE_ORDER:
        contract = resolve_contract(stage)
        if contract is not None:
            result.append(contract)
    return tuple(result)


def owner_of(fact_name: str) -> Optional[str]:
    """Return the owner module for ``fact_name``, or ``None`` if not declared.

    Callers that need to raise on unknown facts should do the check
    themselves; this function never raises.
    """
    for fact in AUTHORITY_TABLE:
        if fact.name == fact_name:
            return fact.owner_module
    return None


def facts_owned_by(owner_module: str) -> Tuple[str, ...]:
    """Return the tuple of fact names owned by ``owner_module`` in declaration order."""
    return tuple(f.name for f in AUTHORITY_TABLE if f.owner_module == owner_module)


def declared_facts() -> Tuple[str, ...]:
    """Return all declared fact names in declaration order."""
    return tuple(f.name for f in AUTHORITY_TABLE)


def owner_index() -> Dict[str, str]:
    """Return a fact_name → owner_module dict (derived from AUTHORITY_TABLE)."""
    return {f.name: f.owner_module for f in AUTHORITY_TABLE}


# ---------------------------------------------------------------------------
# Stage↔lease role bridging (Slice 3 — DEC-WHO-STAGE-LEASE-MATCH-001)
#
# Leases are issued with the base role string ("guardian", "implementer",
# "planner") while actors in the policy engine carry compound stage IDs
# ("guardian:provision", "guardian:land"). These helpers bridge the gap so
# build_context() and bash_git_who can match actors to their leases without
# literal string equality.
# ---------------------------------------------------------------------------


def lease_role_for_stage(stage: str) -> Optional[str]:
    """Map a stage identifier to the lease-level role that owns it.

    For compound stages (e.g. "guardian:land"), returns the base role
    ("guardian"). For simple stages, returns the stage itself if known.
    Returns None for unknown stages or empty input.
    """
    if not stage:
        return None
    if stage in STAGE_CAPABILITIES:
        return stage.split(":")[0] if ":" in stage else stage
    canonical = _LIVE_ROLE_ALIASES.get(stage)
    if canonical is not None and canonical in STAGE_CAPABILITIES:
        return canonical.split(":")[0] if ":" in canonical else canonical
    return None


def actor_matches_lease_role(actor_role: str, lease_role: str) -> bool:
    """Return True iff actor_role is authorized to use a lease with lease_role.

    Handles compound stage IDs: "guardian:land" matches lease role "guardian".
    This is the sole authority for actor↔lease role comparison
    (DEC-WHO-STAGE-LEASE-MATCH-001).
    """
    if not actor_role or not lease_role:
        return False
    a = actor_role.lower().strip()
    lr = lease_role.lower().strip()
    if a == lr:
        return True
    base = lease_role_for_stage(actor_role)
    if base and base.lower() == lr:
        return True
    return False


def canonical_actor_stage(actor_role: str, dispatch_phase: Optional[str]) -> str:
    """Canonicalize live bare roles to compound stage IDs where the graph distinguishes them.

    @decision DEC-WHO-GUARDIAN-CANONICALIZE-001
    Title: canonical_actor_stage promotes bare 'guardian' to the right compound stage
    Status: accepted (Slice 3 correction)
    Rationale: Live dispatch (hooks/subagent-start.sh, runtime/core/lifecycle.py,
      runtime/core/completions.py) uses bare ``guardian`` for both provision
      and land modes — that is the live truth the policy engine must map from.
      stage_registry is the single stage-routing authority; this helper reads
      it via ``next_stage()`` rather than inventing a second mapping table.
      ``dispatch_phase`` (populated by build_context() from completion_records
      as ``{role}:{verdict}``) encodes the routing verdict that dispatched the
      current actor. ``next_stage(prev_stage, verdict)`` resolves that verdict
      to the compound guardian stage.

      Derived mapping (from stage_registry, not duplicated here):
        - planner:next_work_item       → guardian:provision
        - reviewer:ready_for_guardian  → guardian:land
        - any other / absent phase     → guardian:provision (safe default —
          provision carries CAN_PROVISION_WORKTREE but NOT CAN_LAND_GIT, so a
          guardian without a clear landing dispatch phase cannot silently land)

    Non-guardian actor_role values pass through unchanged. This is the sole
    authority for actor-role canonicalization in build_context(); no other
    module may emit a parallel mapping.
    """
    if actor_role != "guardian":
        return actor_role

    if dispatch_phase and ":" in dispatch_phase:
        prev_stage, verdict = dispatch_phase.split(":", 1)
        target = sr.next_stage(prev_stage, verdict)
        if target in (sr.GUARDIAN_PROVISION, sr.GUARDIAN_LAND):
            return target

    return sr.GUARDIAN_PROVISION


__all__ = [
    # Capabilities
    "CAN_WRITE_SOURCE",
    "CAN_WRITE_GOVERNANCE",
    "CAN_LAND_GIT",
    "CAN_PROVISION_WORKTREE",
    "CAN_SET_CONTROL_CONFIG",
    "READ_ONLY_REVIEW",
    "CAN_EMIT_DISPATCH_TRANSITION",
    "CAPABILITIES",
    # Stage → capability mapping + live-role aliases
    "STAGE_CAPABILITIES",
    "_LIVE_ROLE_ALIASES",
    # Capability contracts (Phase 3)
    "StageCapabilityContract",
    # Authority table
    "OperationalFact",
    "AUTHORITY_TABLE",
    # Pure helpers
    "capabilities_for",
    "stage_has_capability",
    "stages_with_capability",
    "resolve_contract",
    "all_contracts",
    "owner_of",
    "facts_owned_by",
    "declared_facts",
    "owner_index",
    # Stage↔lease role bridging (Slice 3)
    "lease_role_for_stage",
    "actor_matches_lease_role",
    "canonical_actor_stage",
]
