"""ClauDEX goal-contract and work-item contract scaffolding (shadow-only).

@decision DEC-CLAUDEX-EVAL-CONTRACT-SCHEMA-PARITY-001
Title: Widen EvaluationContract to 9 fields matching CLAUDE.md Phase 3b vocabulary
Status: accepted
Rationale: CLAUDE.md Phase 3b and agents/planner.md instruct planners to populate
  six semantic fields (required_tests, required_real_path_checks,
  required_authority_invariants, required_integration_points, forbidden_shortcuts,
  ready_for_guardian_definition) plus the base rollback_boundary and acceptance_notes.
  Prior to this slice the runtime codec recognized only 4 fields, causing a
  dual-authority drift: the planner-prose authority prescribed 6 content categories
  while the machine authority accepted 4, silently rejecting well-formed planner
  payloads at compile time. This slice collapses the drift by widening the
  EvaluationContract dataclass to carry all 9 canonical fields. All new fields
  default to empty (tuple → (), string → ""), so persisted legacy rows need no
  migration. The work_item_contract_codec.py closed-key-set is the sole machine
  authority for the legal key list; this module is the sole typed shape authority.
  Architecture Preservation §6 ("No parallel authorities as a transition aid")
  and §2 ("Generate or validate derived surfaces from the authority") both require
  this to be a closure change, not a coexistence patch.
  Cross-reference: DEC-CLAUDEX-CONTRACTS-001 (parent scaffolding decision).

@decision DEC-CLAUDEX-CONTRACTS-001
Title: runtime/core/contracts.py owns the shadow-mode goal and work-item contract shapes
Status: proposed (shadow-mode)
Rationale: CUTOVER_PLAN §4 (Goal Contract and Work-Item Contract) requires the
  outer goal loop and the inner work-item loop to be represented as separate
  runtime-owned state domains. The current live control plane has neither —
  ``runtime/core/workflows.py`` stores workflow bindings and scope, but there
  is no canonical ``GoalContract`` or ``WorkItemContract`` entity that planner
  and reviewer share.

  This module introduces the scaffolding for both contracts. It is shadow-only:

    * The dataclasses here have no SQLite DDL yet and are not persisted.
    * ``dispatch_engine``, ``completions``, and ``evaluation`` do not import
      this module.
    * The live ``workflows`` / ``leases`` / ``evaluation_state`` entities are
      untouched.

  The shapes are intentionally minimal — just enough to (a) express the
  boundary between the two loops and (b) give later Phase 1/2 slices
  something concrete to validate against. Field additions are additive: the
  tests that pin the shape check for presence, not exhaustiveness.

  Key invariants (tested in ``tests/runtime/test_stage_registry.py``):
    1. ``GoalContract`` owns the *outer* loop's decision surface: desired
       end state, autonomy budget, continuation rules, escalation boundary.
       Reviewer never populates this.
    2. ``WorkItemContract`` owns the *inner* loop's bounded execution unit:
       scope manifest, required evidence, rollback boundary, reviewer
       convergence rules. Planner decomposes a GoalContract into one or more
       WorkItemContracts.
    3. The two contracts are linked by ``work_item.goal_id == goal.goal_id``.
    4. A GoalContract may be in exactly one of the legal goal statuses
       (``active``, ``awaiting_user``, ``complete``, ``blocked_external``);
       a WorkItemContract may be in exactly one of the legal work-item
       statuses (``pending``, ``in_progress``, ``in_review``, ``ready_to_land``,
       ``landed``, ``needs_changes``, ``blocked_by_plan``, ``abandoned``).

  This module is the ClauDEX successor to the ad-hoc "scope manifest" phrasing
  scattered through the planner prompt and CLAUDE.md. Once the reviewer stage
  is live, the narrative prose in planner.md will be rewritten to produce
  these structures by generation, not by convention.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import FrozenSet, Optional, Tuple

# ---------------------------------------------------------------------------
# Status vocabularies
#
# These sets are the single authoritative declaration of legal statuses for
# each contract. The tests check membership against these sets so that a
# later slice cannot silently widen the state space.
# ---------------------------------------------------------------------------

GOAL_STATUSES: FrozenSet[str] = frozenset(
    {
        "active",
        "awaiting_user",
        "complete",
        "blocked_external",
    }
)

WORK_ITEM_STATUSES: FrozenSet[str] = frozenset(
    {
        "pending",
        "in_progress",
        "in_review",
        "ready_to_land",
        "landed",
        "needs_changes",
        "blocked_by_plan",
        "abandoned",
    }
)


# ---------------------------------------------------------------------------
# Scope manifest
#
# A scope manifest bounds an implementer's allowed reach inside a work-item.
# The existing live system expresses this as free text in prompts; this
# dataclass gives it a typed shape so the reviewer and policy engine can key
# off it mechanically in a later slice.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ScopeManifest:
    """Typed scope boundary for a single work-item.

    ``allowed_paths`` are filesystem patterns the implementer may touch.
    ``required_paths`` are patterns the implementer *must* touch for the
    work-item to converge. ``forbidden_paths`` are patterns the implementer
    must not touch under any verdict. ``state_domains`` lists the runtime
    state authorities the work-item is allowed to read or write (e.g.
    ``"leases"``, ``"evaluation_state"``, ``"workflow_bindings"``).

    All fields are tuples so the dataclass stays frozen/hashable. Empty
    tuples are legal and mean "unrestricted in this dimension", but the
    reviewer is expected to reject an empty ``allowed_paths`` for any
    non-trivial work-item.
    """

    allowed_paths: Tuple[str, ...] = ()
    required_paths: Tuple[str, ...] = ()
    forbidden_paths: Tuple[str, ...] = ()
    state_domains: Tuple[str, ...] = ()


# ---------------------------------------------------------------------------
# Evaluation contract
#
# A compact typed shape for the per-work-item readiness bar. Reviewer checks
# convergence against this. Planner populates it when the work-item is
# created. These fields mirror the CLAUDE.md "Evaluation Contract" prose but
# in a shape the runtime can validate.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class EvaluationContract:
    """The readiness bar a work-item must clear before ``ready_for_guardian``.

    Field groupings (pinned by test_work_item_contract_codec_eval_schema_parity.py):

    Group 1 — Evidence / tests (original fields):
      ``required_tests``, ``required_evidence``

    Group 2 — Integration surface + implementation constraints (new fields):
      ``required_real_path_checks``, ``required_authority_invariants``,
      ``required_integration_points``, ``forbidden_shortcuts``

    Group 3 — Readiness boundaries (mixed original / new):
      ``rollback_boundary``, ``acceptance_notes``,
      ``ready_for_guardian_definition``

    All new fields default to empty so existing persisted rows decode
    without migration. The codec (work_item_contract_codec._EVAL_TUPLE_KEYS /
    _EVAL_STRING_KEYS) is the machine authority for the legal key set;
    this dataclass is the typed shape authority consumed by the
    prompt-pack render layer.

    DEC-CLAUDEX-EVAL-CONTRACT-SCHEMA-PARITY-001 (see module docstring).
    """

    # Group 1: evidence / tests
    required_tests: Tuple[str, ...] = ()
    required_evidence: Tuple[str, ...] = ()

    # Group 2: integration surface + constraints (NEW — slice 33)
    required_real_path_checks: Tuple[str, ...] = ()
    required_authority_invariants: Tuple[str, ...] = ()
    required_integration_points: Tuple[str, ...] = ()
    forbidden_shortcuts: Tuple[str, ...] = ()

    # Group 3: readiness boundaries
    rollback_boundary: str = ""
    acceptance_notes: str = ""
    ready_for_guardian_definition: str = ""  # NEW — slice 33


# ---------------------------------------------------------------------------
# Goal contract (outer loop)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class GoalContract:
    """Outer-loop decision contract owned by the planner.

    A goal contract describes a user-level objective that may span one or
    more work-items. Planner owns creation, status transitions, and the
    post-guardian continuation decision. Reviewer must not mutate this
    contract; reviewer verdicts feed into the work-item contract instead.
    """

    goal_id: str
    desired_end_state: str
    status: str = "active"
    autonomy_budget: int = 0
    continuation_rules: Tuple[str, ...] = ()
    stop_conditions: Tuple[str, ...] = ()
    escalation_boundaries: Tuple[str, ...] = ()
    user_decision_boundaries: Tuple[str, ...] = ()
    created_at: int = 0
    updated_at: int = 0

    def __post_init__(self) -> None:
        if self.status not in GOAL_STATUSES:
            raise ValueError(
                f"unknown goal status {self.status!r}; valid: {sorted(GOAL_STATUSES)}"
            )


# ---------------------------------------------------------------------------
# Work-item contract (inner loop)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class WorkItemContract:
    """Inner-loop bounded execution unit.

    A work-item contract describes one concrete slice of change the
    implementer-reviewer loop will converge. It carries the scope manifest,
    the evaluation contract, and a status drawn from ``WORK_ITEM_STATUSES``.
    It is always linked to exactly one ``GoalContract`` via ``goal_id``.
    """

    work_item_id: str
    goal_id: str
    title: str
    scope: ScopeManifest = field(default_factory=ScopeManifest)
    evaluation: EvaluationContract = field(default_factory=EvaluationContract)
    status: str = "pending"
    reviewer_round: int = 0
    head_sha: Optional[str] = None
    created_at: int = 0
    updated_at: int = 0

    def __post_init__(self) -> None:
        if self.status not in WORK_ITEM_STATUSES:
            raise ValueError(
                f"unknown work-item status {self.status!r}; "
                f"valid: {sorted(WORK_ITEM_STATUSES)}"
            )


__all__ = [
    "GOAL_STATUSES",
    "WORK_ITEM_STATUSES",
    "ScopeManifest",
    "EvaluationContract",
    "GoalContract",
    "WorkItemContract",
]
