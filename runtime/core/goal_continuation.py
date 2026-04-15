"""Goal-continuation authority for planner post-dispatch enforcement.

@decision DEC-CLAUDEX-GOAL-CONTINUATION-001
Title: runtime/core/goal_continuation.py owns autonomy-budget enforcement
    and goal-status transitions for planner dispatch outcomes
Status: accepted (Phase 6 Slice 6)
Rationale: After Phase 6 Slice 5 activated the guardian(land) -> planner
  continuation loop, the planner's ``next_work_item`` verdict auto-dispatches
  to guardian(provision) unconditionally. This module gates that
  auto-dispatch on:

    1. An active goal contract exists for the workflow.
    2. The goal's ``autonomy_budget`` has remaining units.
    3. One budget unit is consumed atomically on each continuation.

  When no active goal exists or budget is exhausted, auto-dispatch is
  suppressed and an explicit user-boundary signal is surfaced. Terminal
  planner verdicts (``goal_complete``, ``needs_user_decision``,
  ``blocked_external``) update the goal status to the canonical vocabulary
  (``complete``, ``awaiting_user``, ``blocked_external``).

  Authority boundaries:
    * This module is the sole budget-enforcement authority. Hooks, prompt
      prose, and suggestion text must not duplicate budget semantics.
    * Goal status transitions are planner-owned. Reviewer and guardian
      cannot bypass the planner-owned boundary.
    * The ``goal_contracts`` table (``decision_work_registry``) is the
      single source of truth for budget and status.

  Workflow-to-goal resolution: ``workflow_id`` is used directly as the
  ``goal_id`` for the ``goal_contracts`` table lookup. This is the
  simplest deterministic rule. Workflows without a corresponding goal
  contract row are denied (no active goal contract to authorize
  automatic continuation).
"""

from __future__ import annotations

import dataclasses
import sqlite3
from typing import Optional

from runtime.core import decision_work_registry as dwr
from runtime.core.contracts import GOAL_STATUSES

# ---------------------------------------------------------------------------
# Public result shape
# ---------------------------------------------------------------------------

#: Reason codes for continuation decisions. Consumers key off these strings.
REASON_BUDGET_OK: str = "budget_ok"
REASON_NO_GOAL: str = "no_active_goal"
REASON_BUDGET_EXHAUSTED: str = "budget_exhausted"
REASON_GOAL_NOT_ACTIVE: str = "goal_not_active"

#: Signal strings surfaced in the dispatch suggestion.
SIGNAL_BUDGET_EXHAUSTED: str = "BUDGET_EXHAUSTED"
SIGNAL_NO_ACTIVE_GOAL: str = "NO_ACTIVE_GOAL"


class ContinuationResult:
    """Outcome of a planner continuation-budget check.

    Attributes:
        allowed: Whether auto-dispatch should proceed.
        reason: A stable reason code from the REASON_* constants.
        signal: A human/machine-readable signal for the suggestion builder,
            or empty string when continuation is allowed.
        budget_before: The budget value before this check, or None when no
            goal contract was found.
        budget_after: The budget value after decrement, or None when no
            goal contract was found or continuation was denied.
    """

    __slots__ = ("allowed", "reason", "signal", "budget_before", "budget_after")

    def __init__(
        self,
        *,
        allowed: bool,
        reason: str,
        signal: str = "",
        budget_before: Optional[int] = None,
        budget_after: Optional[int] = None,
    ) -> None:
        self.allowed = allowed
        self.reason = reason
        self.signal = signal
        self.budget_before = budget_before
        self.budget_after = budget_after


# ---------------------------------------------------------------------------
# Planner verdict → goal status mapping
# ---------------------------------------------------------------------------

#: Maps planner terminal verdicts to the canonical goal status they should
#: produce. ``next_work_item`` is not here because it is the continuation
#: path, not a terminal transition.
_VERDICT_TO_GOAL_STATUS: dict[str, str] = {
    "goal_complete": "complete",
    "needs_user_decision": "awaiting_user",
    "blocked_external": "blocked_external",
}


# ---------------------------------------------------------------------------
# Core enforcement
# ---------------------------------------------------------------------------


def check_continuation_budget(
    conn: sqlite3.Connection,
    *,
    workflow_id: str,
) -> ContinuationResult:
    """Check and consume one autonomy-budget unit for a planner continuation.

    Called by ``dispatch_engine`` when the planner verdict is
    ``next_work_item`` and routing resolved to guardian(provision). This
    function:

      1. Looks up the goal contract for ``workflow_id`` (used as goal_id).
      2. If no row exists → denied (no active goal contract to authorize
         continuation).
      3. If the goal status is not ``active`` → denied.
      4. If ``autonomy_budget <= 0`` → denied (budget exhausted).
      5. Otherwise → decrements budget by 1 atomically and returns allowed.

    Returns:
        A ``ContinuationResult`` with the enforcement outcome.
    """
    goal = dwr.get_goal(conn, workflow_id)

    if goal is None:
        return ContinuationResult(
            allowed=False,
            reason=REASON_NO_GOAL,
            signal=SIGNAL_NO_ACTIVE_GOAL,
        )

    if goal.status != "active":
        return ContinuationResult(
            allowed=False,
            reason=REASON_GOAL_NOT_ACTIVE,
            signal=SIGNAL_NO_ACTIVE_GOAL,
            budget_before=goal.autonomy_budget,
        )

    if goal.autonomy_budget <= 0:
        return ContinuationResult(
            allowed=False,
            reason=REASON_BUDGET_EXHAUSTED,
            signal=SIGNAL_BUDGET_EXHAUSTED,
            budget_before=0,
            budget_after=0,
        )

    # Consume one budget unit atomically.
    new_budget = goal.autonomy_budget - 1
    updated = dataclasses.replace(
        goal, autonomy_budget=new_budget
    )
    dwr.upsert_goal(conn, updated)

    return ContinuationResult(
        allowed=True,
        reason=REASON_BUDGET_OK,
        budget_before=goal.autonomy_budget,
        budget_after=new_budget,
    )


def update_goal_status_for_verdict(
    conn: sqlite3.Connection,
    *,
    workflow_id: str,
    verdict: str,
) -> Optional[str]:
    """Update the goal contract status based on a planner terminal verdict.

    Maps the verdict to the canonical goal status vocabulary and persists
    the transition. Returns the new status string, or ``None`` if:
      - The verdict is not a terminal verdict (e.g. ``next_work_item``).
      - No goal contract exists for the workflow.

    This is a planner-owned boundary: only planner verdicts trigger status
    transitions. Reviewer and guardian cannot call this.
    """
    new_status = _VERDICT_TO_GOAL_STATUS.get(verdict)
    if new_status is None:
        return None

    goal = dwr.get_goal(conn, workflow_id)
    if goal is None:
        return None

    updated = dataclasses.replace(goal, status=new_status)
    dwr.upsert_goal(conn, updated)
    return new_status


__all__ = [
    "REASON_BUDGET_OK",
    "REASON_NO_GOAL",
    "REASON_BUDGET_EXHAUSTED",
    "REASON_GOAL_NOT_ACTIVE",
    "SIGNAL_BUDGET_EXHAUSTED",
    "SIGNAL_NO_ACTIVE_GOAL",
    "ContinuationResult",
    "check_continuation_budget",
    "update_goal_status_for_verdict",
]
