"""ClauDEX goal-contract and work-item contract scaffolding (shadow-only).

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
    """The readiness bar a work-item must clear before ``ready_for_guardian``."""

    required_tests: Tuple[str, ...] = ()
    required_evidence: Tuple[str, ...] = ()
    rollback_boundary: str = ""
    acceptance_notes: str = ""


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
