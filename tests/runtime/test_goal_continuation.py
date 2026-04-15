"""Tests for runtime/core/goal_continuation.py — autonomy budget enforcement
and goal-status transitions for planner dispatch outcomes.

@decision DEC-CLAUDEX-GOAL-CONTINUATION-TESTS-001
Title: Budget enforcement, status transitions, and planner-owned boundaries are pinned
Status: accepted (Phase 6 Slice 6)
Rationale: The goal-continuation module gates planner auto-dispatch on the goal
  contract's autonomy budget. These tests pin:

    1. Budget allows next_work_item and decrements.
    2. Exhausted budget blocks auto-dispatch.
    3. Missing active goal allows auto-dispatch (graceful degradation).
    4. Non-active goal status blocks auto-dispatch.
    5. needs_user_decision sets/surfaces awaiting_user status.
    6. goal_complete and blocked_external set/surface terminal statuses.
    7. Reviewer/guardian cannot bypass the planner-owned boundary (goal_continuation
       only accepts planner verdicts, not reviewer/guardian verdicts).
    8. Integration with dispatch_engine: budget enforcement wired into
       process_agent_stop for planner next_work_item transitions.
"""

from __future__ import annotations

import sqlite3

import pytest

from runtime.core import (
    completions,
    decision_work_registry as dwr,
    goal_continuation as gc,
    leases,
)
from runtime.core.dispatch_engine import process_agent_stop
from runtime.schemas import ensure_schema

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


@pytest.fixture
def project_root(tmp_path):
    return str(tmp_path)


def _insert_goal(conn, goal_id, budget=3, status="active"):
    """Insert a goal contract with the given budget and status."""
    return dwr.insert_goal(
        conn,
        dwr.GoalRecord(
            goal_id=goal_id,
            desired_end_state="Test goal",
            status=status,
            autonomy_budget=budget,
        ),
    )


def _issue_lease_at(conn, role, project_root, workflow_id):
    return leases.issue(
        conn,
        role=role,
        workflow_id=workflow_id,
        worktree_path=project_root,
    )


def _submit_planner(conn, lease_id, workflow_id, verdict="next_work_item"):
    return completions.submit(
        conn,
        lease_id=lease_id,
        workflow_id=workflow_id,
        role="planner",
        payload={"PLAN_VERDICT": verdict, "PLAN_SUMMARY": "Test"},
    )


# ---------------------------------------------------------------------------
# 1. check_continuation_budget — pure domain tests
# ---------------------------------------------------------------------------


class TestCheckContinuationBudget:
    def test_budget_allows_and_decrements(self, conn):
        """Active goal with budget > 0 allows continuation and decrements by 1."""
        _insert_goal(conn, "wf-budget-1", budget=3)
        result = gc.check_continuation_budget(conn, workflow_id="wf-budget-1")
        assert result.allowed is True
        assert result.reason == gc.REASON_BUDGET_OK
        assert result.budget_before == 3
        assert result.budget_after == 2
        assert result.signal == ""
        # Verify persistence.
        goal = dwr.get_goal(conn, "wf-budget-1")
        assert goal.autonomy_budget == 2

    def test_budget_decrements_to_zero(self, conn):
        """Budget of 1 allows once, then exhausted."""
        _insert_goal(conn, "wf-budget-2", budget=1)
        r1 = gc.check_continuation_budget(conn, workflow_id="wf-budget-2")
        assert r1.allowed is True
        assert r1.budget_after == 0
        # Second call: budget exhausted.
        r2 = gc.check_continuation_budget(conn, workflow_id="wf-budget-2")
        assert r2.allowed is False
        assert r2.reason == gc.REASON_BUDGET_EXHAUSTED
        assert r2.signal == gc.SIGNAL_BUDGET_EXHAUSTED

    def test_exhausted_budget_blocks(self, conn):
        """Budget of 0 blocks auto-dispatch immediately."""
        _insert_goal(conn, "wf-budget-3", budget=0)
        result = gc.check_continuation_budget(conn, workflow_id="wf-budget-3")
        assert result.allowed is False
        assert result.reason == gc.REASON_BUDGET_EXHAUSTED
        assert result.budget_before == 0
        assert result.budget_after == 0
        assert result.signal == gc.SIGNAL_BUDGET_EXHAUSTED

    def test_no_goal_blocks(self, conn):
        """No goal contract row → denied (no active goal to authorize)."""
        result = gc.check_continuation_budget(conn, workflow_id="wf-no-goal")
        assert result.allowed is False
        assert result.reason == gc.REASON_NO_GOAL
        assert result.signal == gc.SIGNAL_NO_ACTIVE_GOAL
        assert result.budget_before is None
        assert result.budget_after is None

    def test_non_active_goal_blocks(self, conn):
        """Goal with status != 'active' blocks continuation."""
        _insert_goal(conn, "wf-budget-4", budget=5, status="complete")
        result = gc.check_continuation_budget(conn, workflow_id="wf-budget-4")
        assert result.allowed is False
        assert result.reason == gc.REASON_GOAL_NOT_ACTIVE
        assert result.signal == gc.SIGNAL_NO_ACTIVE_GOAL

    def test_awaiting_user_goal_blocks(self, conn):
        """Goal in awaiting_user status blocks continuation."""
        _insert_goal(conn, "wf-budget-5", budget=5, status="awaiting_user")
        result = gc.check_continuation_budget(conn, workflow_id="wf-budget-5")
        assert result.allowed is False
        assert result.reason == gc.REASON_GOAL_NOT_ACTIVE

    def test_blocked_external_goal_blocks(self, conn):
        """Goal in blocked_external status blocks continuation."""
        _insert_goal(conn, "wf-budget-6", budget=5, status="blocked_external")
        result = gc.check_continuation_budget(conn, workflow_id="wf-budget-6")
        assert result.allowed is False
        assert result.reason == gc.REASON_GOAL_NOT_ACTIVE

    def test_multiple_decrements_are_sequential(self, conn):
        """Budget decrements are atomic and sequential."""
        _insert_goal(conn, "wf-budget-7", budget=3)
        for expected_after in (2, 1, 0):
            r = gc.check_continuation_budget(conn, workflow_id="wf-budget-7")
            assert r.allowed is True
            assert r.budget_after == expected_after
        # Fourth call: exhausted.
        r = gc.check_continuation_budget(conn, workflow_id="wf-budget-7")
        assert r.allowed is False
        assert r.reason == gc.REASON_BUDGET_EXHAUSTED


# ---------------------------------------------------------------------------
# 2. update_goal_status_for_verdict — terminal status transitions
# ---------------------------------------------------------------------------


class TestUpdateGoalStatusForVerdict:
    def test_goal_complete_sets_complete(self, conn):
        _insert_goal(conn, "wf-status-1")
        new = gc.update_goal_status_for_verdict(
            conn, workflow_id="wf-status-1", verdict="goal_complete"
        )
        assert new == "complete"
        assert dwr.get_goal(conn, "wf-status-1").status == "complete"

    def test_needs_user_decision_sets_awaiting_user(self, conn):
        _insert_goal(conn, "wf-status-2")
        new = gc.update_goal_status_for_verdict(
            conn, workflow_id="wf-status-2", verdict="needs_user_decision"
        )
        assert new == "awaiting_user"
        assert dwr.get_goal(conn, "wf-status-2").status == "awaiting_user"

    def test_blocked_external_sets_blocked_external(self, conn):
        _insert_goal(conn, "wf-status-3")
        new = gc.update_goal_status_for_verdict(
            conn, workflow_id="wf-status-3", verdict="blocked_external"
        )
        assert new == "blocked_external"
        assert dwr.get_goal(conn, "wf-status-3").status == "blocked_external"

    def test_next_work_item_does_not_change_status(self, conn):
        """next_work_item is a continuation, not a terminal verdict."""
        _insert_goal(conn, "wf-status-4")
        new = gc.update_goal_status_for_verdict(
            conn, workflow_id="wf-status-4", verdict="next_work_item"
        )
        assert new is None
        assert dwr.get_goal(conn, "wf-status-4").status == "active"

    def test_no_goal_returns_none(self, conn):
        new = gc.update_goal_status_for_verdict(
            conn, workflow_id="wf-no-goal", verdict="goal_complete"
        )
        assert new is None

    def test_unknown_verdict_returns_none(self, conn):
        _insert_goal(conn, "wf-status-5")
        new = gc.update_goal_status_for_verdict(
            conn, workflow_id="wf-status-5", verdict="unknown_verdict"
        )
        assert new is None
        assert dwr.get_goal(conn, "wf-status-5").status == "active"


# ---------------------------------------------------------------------------
# 3. Planner-owned boundary: reviewer/guardian cannot bypass
# ---------------------------------------------------------------------------


class TestPlannerOwnedBoundary:
    def test_reviewer_verdict_does_not_trigger_status_transition(self, conn):
        """Reviewer verdicts (ready_for_guardian, needs_changes, blocked_by_plan)
        are not planner verdicts and must not trigger goal status changes."""
        _insert_goal(conn, "wf-boundary-1")
        for verdict in ("ready_for_guardian", "needs_changes", "blocked_by_plan"):
            new = gc.update_goal_status_for_verdict(
                conn, workflow_id="wf-boundary-1", verdict=verdict
            )
            assert new is None, f"reviewer verdict {verdict!r} must not change goal status"
        assert dwr.get_goal(conn, "wf-boundary-1").status == "active"

    def test_guardian_verdict_does_not_trigger_status_transition(self, conn):
        """Guardian verdicts (committed, merged, denied, skipped, provisioned)
        are not planner verdicts and must not trigger goal status changes."""
        _insert_goal(conn, "wf-boundary-2")
        for verdict in ("committed", "merged", "denied", "skipped", "provisioned"):
            new = gc.update_goal_status_for_verdict(
                conn, workflow_id="wf-boundary-2", verdict=verdict
            )
            assert new is None, f"guardian verdict {verdict!r} must not change goal status"
        assert dwr.get_goal(conn, "wf-boundary-2").status == "active"

    def test_budget_check_only_consumes_on_allow(self, conn):
        """Budget is only consumed when the check succeeds (allowed=True).
        Failed checks must not decrement."""
        _insert_goal(conn, "wf-boundary-3", budget=0)
        gc.check_continuation_budget(conn, workflow_id="wf-boundary-3")
        # Budget should still be 0, not negative.
        assert dwr.get_goal(conn, "wf-boundary-3").autonomy_budget == 0


# ---------------------------------------------------------------------------
# 4. Integration with dispatch_engine.process_agent_stop
# ---------------------------------------------------------------------------


class TestDispatchEngineIntegration:
    def test_planner_next_work_item_with_budget_auto_dispatches(
        self, conn, project_root
    ):
        """Planner next_work_item with active goal and budget → auto_dispatch=True."""
        wf = "wf-integ-1"
        _insert_goal(conn, wf, budget=3)
        lease = _issue_lease_at(conn, "planner", project_root, wf)
        _submit_planner(conn, lease["lease_id"], wf, verdict="next_work_item")
        result = process_agent_stop(conn, "planner", project_root)
        assert result["next_role"] == "guardian"
        assert result["auto_dispatch"] is True
        assert result.get("guardian_mode") == "provision"
        # Budget decremented.
        assert dwr.get_goal(conn, wf).autonomy_budget == 2

    def test_planner_next_work_item_budget_exhausted_blocks_auto_dispatch(
        self, conn, project_root
    ):
        """Planner next_work_item with budget=0 → auto_dispatch=False, signal surfaced."""
        wf = "wf-integ-2"
        _insert_goal(conn, wf, budget=0)
        lease = _issue_lease_at(conn, "planner", project_root, wf)
        _submit_planner(conn, lease["lease_id"], wf, verdict="next_work_item")
        result = process_agent_stop(conn, "planner", project_root)
        assert result["next_role"] is None
        assert result["auto_dispatch"] is False
        assert result.get("budget_exhausted") is True
        assert gc.SIGNAL_BUDGET_EXHAUSTED in result.get("suggestion", "")

    def test_planner_next_work_item_no_goal_blocks_auto_dispatch(
        self, conn, project_root
    ):
        """Planner next_work_item without goal contract → auto_dispatch=False."""
        wf = "wf-integ-3"
        # No goal contract inserted.
        lease = _issue_lease_at(conn, "planner", project_root, wf)
        _submit_planner(conn, lease["lease_id"], wf, verdict="next_work_item")
        result = process_agent_stop(conn, "planner", project_root)
        assert result["next_role"] is None
        assert result["auto_dispatch"] is False
        assert result.get("budget_exhausted") is True
        assert gc.SIGNAL_NO_ACTIVE_GOAL in result.get("suggestion", "")

    def test_planner_goal_complete_updates_goal_status(
        self, conn, project_root
    ):
        """Planner goal_complete updates goal status to 'complete'."""
        wf = "wf-integ-4"
        _insert_goal(conn, wf, budget=3)
        lease = _issue_lease_at(conn, "planner", project_root, wf)
        _submit_planner(conn, lease["lease_id"], wf, verdict="goal_complete")
        result = process_agent_stop(conn, "planner", project_root)
        assert result["next_role"] is None
        assert result["auto_dispatch"] is False
        assert "GOAL_COMPLETE" in result.get("suggestion", "")
        assert dwr.get_goal(conn, wf).status == "complete"

    def test_planner_needs_user_decision_updates_goal_status(
        self, conn, project_root
    ):
        """Planner needs_user_decision updates goal status to 'awaiting_user'."""
        wf = "wf-integ-5"
        _insert_goal(conn, wf, budget=3)
        lease = _issue_lease_at(conn, "planner", project_root, wf)
        _submit_planner(conn, lease["lease_id"], wf, verdict="needs_user_decision")
        result = process_agent_stop(conn, "planner", project_root)
        assert result["next_role"] is None
        assert result["auto_dispatch"] is False
        assert "USER_DECISION_REQUIRED" in result.get("suggestion", "")
        assert dwr.get_goal(conn, wf).status == "awaiting_user"

    def test_planner_blocked_external_updates_goal_status(
        self, conn, project_root
    ):
        """Planner blocked_external updates goal status to 'blocked_external'."""
        wf = "wf-integ-6"
        _insert_goal(conn, wf, budget=3)
        lease = _issue_lease_at(conn, "planner", project_root, wf)
        _submit_planner(conn, lease["lease_id"], wf, verdict="blocked_external")
        result = process_agent_stop(conn, "planner", project_root)
        assert result["next_role"] is None
        assert result["auto_dispatch"] is False
        assert "BLOCKED_EXTERNAL" in result.get("suggestion", "")
        assert dwr.get_goal(conn, wf).status == "blocked_external"

    def test_planner_non_active_goal_blocks_auto_dispatch(
        self, conn, project_root
    ):
        """Planner next_work_item with non-active goal → no auto_dispatch."""
        wf = "wf-integ-7"
        _insert_goal(conn, wf, budget=3, status="complete")
        lease = _issue_lease_at(conn, "planner", project_root, wf)
        _submit_planner(conn, lease["lease_id"], wf, verdict="next_work_item")
        result = process_agent_stop(conn, "planner", project_root)
        assert result["next_role"] is None
        assert result["auto_dispatch"] is False

    def test_budget_consumed_across_full_cycle(self, conn, project_root):
        """Budget decrements correctly across multiple planner continuations."""
        wf = "wf-integ-8"
        _insert_goal(conn, wf, budget=2)
        # First continuation: budget 2 → 1.
        lease1 = _issue_lease_at(conn, "planner", project_root, wf)
        _submit_planner(conn, lease1["lease_id"], wf)
        r1 = process_agent_stop(conn, "planner", project_root)
        assert r1["auto_dispatch"] is True
        assert dwr.get_goal(conn, wf).autonomy_budget == 1
        # Second continuation: budget 1 → 0.
        lease2 = _issue_lease_at(conn, "planner", project_root, wf)
        _submit_planner(conn, lease2["lease_id"], wf)
        r2 = process_agent_stop(conn, "planner", project_root)
        assert r2["auto_dispatch"] is True
        assert dwr.get_goal(conn, wf).autonomy_budget == 0
        # Third attempt: budget exhausted.
        lease3 = _issue_lease_at(conn, "planner", project_root, wf)
        _submit_planner(conn, lease3["lease_id"], wf)
        r3 = process_agent_stop(conn, "planner", project_root)
        assert r3["auto_dispatch"] is False
        assert r3.get("budget_exhausted") is True

    def test_budget_check_exception_fails_closed(
        self, conn, project_root, monkeypatch
    ):
        """If check_continuation_budget raises, planner must fail closed:
        no auto-dispatch to guardian, error surfaced."""
        from runtime.core import goal_continuation as _gc

        def _boom(**kwargs):
            raise RuntimeError("simulated budget-check failure")

        monkeypatch.setattr(_gc, "check_continuation_budget", _boom)

        wf = "wf-integ-failclose"
        # Insert a valid goal so routing would normally succeed.
        _insert_goal(conn, wf, budget=5)
        lease = _issue_lease_at(conn, "planner", project_root, wf)
        _submit_planner(conn, lease["lease_id"], wf, verdict="next_work_item")
        result = process_agent_stop(conn, "planner", project_root)
        # Must fail closed: no auto-dispatch, error present.
        assert result["next_role"] is None
        assert result["auto_dispatch"] is False
        assert result.get("budget_exhausted") is True
        assert "PROCESS ERROR" in (result.get("error") or "")
        assert result.get("budget_signal") == "BUDGET_CHECK_FAILED"
        # Hook-visible surface: suggestion must also contain the stable signal
        # (flows through the error→suggestion path at L413 of dispatch_engine).
        assert "BUDGET_CHECK_FAILED" in (result.get("suggestion") or "")
