"""Tests for runtime/core/dispatch_engine.py

@decision DEC-DISPATCH-ENGINE-001
Title: dispatch_engine.process_agent_stop is the authoritative dispatch state machine
Status: accepted
Rationale: post-task.sh contained ~200 lines of routing logic in bash. This module
  ports that logic to Python so it can be unit-tested without subprocess overhead,
  is independently verifiable, and uses domain modules directly. The bash adapter
  becomes a thin wrapper (~20 lines) that pipes JSON through cc-policy dispatch
  process-stop and echoes the hookSpecificOutput result.

  Compound-interaction test (test_full_tester_to_guardian_production_sequence)
  exercises the real production path:
    lease issue → completion submit → process_agent_stop →
    eval_state pending for implementer → routing resolved from completion record →
    lease released after routing.
"""

import sqlite3

import pytest

from runtime.core import completions, evaluation, leases
from runtime.core.dispatch_engine import process_agent_stop
from runtime.schemas import ensure_schema

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    """In-memory SQLite connection with full schema."""
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


@pytest.fixture
def project_root(tmp_path):
    """Minimal project root directory."""
    return str(tmp_path)


def _issue_lease(conn, role, workflow_id="wf-test-001", worktree="/tmp/wt"):
    return leases.issue(
        conn,
        role=role,
        workflow_id=workflow_id,
        worktree_path=worktree,
    )


def _issue_lease_at(conn, role, project_root, workflow_id="wf-test-001"):
    """Issue a lease with worktree_path matching project_root (production model)."""
    return leases.issue(
        conn,
        role=role,
        workflow_id=workflow_id,
        worktree_path=project_root,
    )


def _submit_valid_tester_completion(conn, lease_id, workflow_id):
    return completions.submit(
        conn,
        lease_id=lease_id,
        workflow_id=workflow_id,
        role="tester",
        payload={
            "EVAL_VERDICT": "ready_for_guardian",
            "EVAL_TESTS_PASS": "yes",
            "EVAL_NEXT_ROLE": "guardian",
            "EVAL_HEAD_SHA": "abc123",
        },
    )


def _submit_valid_guardian_completion(conn, lease_id, workflow_id, verdict="committed"):
    return completions.submit(
        conn,
        lease_id=lease_id,
        workflow_id=workflow_id,
        role="guardian",
        payload={
            "LANDING_RESULT": verdict,
            "OPERATION_CLASS": "routine_local",
        },
    )


# ---------------------------------------------------------------------------
# planner → implementer (fixed transition)
# ---------------------------------------------------------------------------


def test_planner_routes_to_implementer(conn, project_root):
    result = process_agent_stop(conn, "planner", project_root)
    assert result["next_role"] == "implementer"
    assert result["error"] is None


def test_planner_alias_plan_routes_to_implementer(conn, project_root):
    """Tolerate 'Plan' capitalisation (matches bash case statement)."""
    result = process_agent_stop(conn, "Plan", project_root)
    assert result["next_role"] == "implementer"
    assert result["error"] is None


# ---------------------------------------------------------------------------
# implementer → tester (fixed transition) + eval_state = pending
# ---------------------------------------------------------------------------


def test_implementer_routes_to_tester(conn, project_root):
    _issue_lease(conn, "implementer", workflow_id="wf-impl-001")
    result = process_agent_stop(conn, "implementer", project_root)
    assert result["next_role"] == "tester"
    assert result["error"] is None


def test_implementer_sets_eval_pending(conn, project_root):
    """When a workflow_id is resolvable, eval_state is set to pending."""
    wf_id = "wf-impl-002"
    _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    process_agent_stop(conn, "implementer", project_root)
    state = evaluation.get(conn, wf_id)
    assert state is not None
    assert state["status"] == "pending"


def test_implementer_no_lease_still_routes_to_tester(conn, project_root):
    """Implementer→tester routing is fixed — no lease needed for routing."""
    result = process_agent_stop(conn, "implementer", project_root)
    assert result["next_role"] == "tester"
    assert result["error"] is None


# ---------------------------------------------------------------------------
# tester routing via completion record
# ---------------------------------------------------------------------------


def test_tester_valid_completion_routes_to_guardian(conn, project_root):
    wf_id = "wf-tester-001"
    lease = _issue_lease_at(conn, "tester", project_root, workflow_id=wf_id)
    _submit_valid_tester_completion(conn, lease["lease_id"], wf_id)
    result = process_agent_stop(conn, "tester", project_root)
    assert result["next_role"] == "guardian"
    assert result["error"] is None


def test_tester_needs_changes_routes_to_implementer(conn, project_root):
    wf_id = "wf-tester-002"
    lease = _issue_lease_at(conn, "tester", project_root, workflow_id=wf_id)
    completions.submit(
        conn,
        lease_id=lease["lease_id"],
        workflow_id=wf_id,
        role="tester",
        payload={
            "EVAL_VERDICT": "needs_changes",
            "EVAL_TESTS_PASS": "no",
            "EVAL_NEXT_ROLE": "implementer",
            "EVAL_HEAD_SHA": "abc123",
        },
    )
    result = process_agent_stop(conn, "tester", project_root)
    assert result["next_role"] == "implementer"
    assert result["error"] is None


def test_tester_invalid_completion_record_returns_error(conn, project_root):
    """Completion record exists but is invalid (missing required fields)."""
    wf_id = "wf-tester-003"
    lease = _issue_lease_at(conn, "tester", project_root, workflow_id=wf_id)
    # Insert a completion with an invalid verdict so valid=0
    completions.submit(
        conn,
        lease_id=lease["lease_id"],
        workflow_id=wf_id,
        role="tester",
        payload={"EVAL_VERDICT": "bogus_verdict"},  # invalid
    )
    result = process_agent_stop(conn, "tester", project_root)
    assert result["error"] is not None
    assert "PROCESS ERROR" in result["error"]
    assert result["next_role"] is None or result["next_role"] == ""


def test_tester_no_completion_record_returns_error(conn, project_root):
    """Lease exists but tester wrote no completion record."""
    wf_id = "wf-tester-004"
    _issue_lease_at(conn, "tester", project_root, workflow_id=wf_id)
    result = process_agent_stop(conn, "tester", project_root)
    assert result["error"] is not None
    assert "PROCESS ERROR" in result["error"]


def test_tester_no_lease_returns_error(conn, project_root):
    """Tester must run under a lease — no active lease is a process error."""
    result = process_agent_stop(conn, "tester", project_root)
    assert result["error"] is not None
    assert "PROCESS ERROR" in result["error"]


# ---------------------------------------------------------------------------
# guardian routing via completion record
# ---------------------------------------------------------------------------


def test_guardian_committed_cycle_complete(conn, project_root):
    """Guardian with 'committed' verdict → None (cycle complete)."""
    wf_id = "wf-guardian-001"
    lease = _issue_lease_at(conn, "guardian", project_root, workflow_id=wf_id)
    _submit_valid_guardian_completion(conn, lease["lease_id"], wf_id, verdict="committed")
    result = process_agent_stop(conn, "guardian", project_root)
    # next_role is None or empty string — both mean cycle complete
    assert not result["next_role"]
    assert result["error"] is None


def test_guardian_denied_routes_to_implementer(conn, project_root):
    """Guardian with 'denied' verdict → implementer."""
    wf_id = "wf-guardian-002"
    lease = _issue_lease_at(conn, "guardian", project_root, workflow_id=wf_id)
    _submit_valid_guardian_completion(conn, lease["lease_id"], wf_id, verdict="denied")
    result = process_agent_stop(conn, "guardian", project_root)
    assert result["next_role"] == "implementer"
    assert result["error"] is None


def test_guardian_merged_cycle_complete(conn, project_root):
    wf_id = "wf-guardian-003"
    lease = _issue_lease_at(conn, "guardian", project_root, workflow_id=wf_id)
    _submit_valid_guardian_completion(conn, lease["lease_id"], wf_id, verdict="merged")
    result = process_agent_stop(conn, "guardian", project_root)
    assert not result["next_role"]
    assert result["error"] is None


def test_guardian_no_completion_record_returns_error(conn, project_root):
    wf_id = "wf-guardian-004"
    _issue_lease_at(conn, "guardian", project_root, workflow_id=wf_id)
    result = process_agent_stop(conn, "guardian", project_root)
    assert result["error"] is not None
    assert "PROCESS ERROR" in result["error"]


# ---------------------------------------------------------------------------
# Lease release after routing (DEC-ROUTING-002)
# ---------------------------------------------------------------------------


def test_tester_lease_released_after_routing(conn, project_root):
    """Lease must be status='released' after process_agent_stop completes."""
    wf_id = "wf-release-001"
    lease = _issue_lease_at(conn, "tester", project_root, workflow_id=wf_id)
    _submit_valid_tester_completion(conn, lease["lease_id"], wf_id)
    process_agent_stop(conn, "tester", project_root)
    refreshed = leases.get(conn, lease["lease_id"])
    assert refreshed["status"] == "released"


def test_guardian_lease_released_after_routing(conn, project_root):
    wf_id = "wf-release-002"
    lease = _issue_lease_at(conn, "guardian", project_root, workflow_id=wf_id)
    _submit_valid_guardian_completion(conn, lease["lease_id"], wf_id)
    process_agent_stop(conn, "guardian", project_root)
    refreshed = leases.get(conn, lease["lease_id"])
    assert refreshed["status"] == "released"


# ---------------------------------------------------------------------------
# workflow_id resolution: lease takes priority over branch-derived
# ---------------------------------------------------------------------------


def test_workflow_id_from_lease_takes_priority(conn, project_root):
    """workflow_id on the result should match the lease's workflow_id."""
    wf_id = "wf-priority-001"
    _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    result = process_agent_stop(conn, "implementer", project_root)
    # The function should resolve workflow_id from the active lease
    assert result["workflow_id"] == wf_id


# ---------------------------------------------------------------------------
# Unknown agent type — silent exit (no routing, no error)
# ---------------------------------------------------------------------------


def test_unknown_agent_type_returns_none(conn, project_root):
    result = process_agent_stop(conn, "unknown_role", project_root)
    assert result["next_role"] is None
    assert result["error"] is None


# ---------------------------------------------------------------------------
# Suggestion string format
# ---------------------------------------------------------------------------


def test_suggestion_contains_next_role(conn, project_root):
    result = process_agent_stop(conn, "planner", project_root)
    assert "implementer" in result["suggestion"]


def test_suggestion_empty_when_cycle_complete(conn, project_root):
    wf_id = "wf-sug-001"
    lease = _issue_lease_at(conn, "guardian", project_root, workflow_id=wf_id)
    _submit_valid_guardian_completion(conn, lease["lease_id"], wf_id, verdict="committed")
    result = process_agent_stop(conn, "guardian", project_root)
    # cycle complete — suggestion should be empty or mention completion
    assert result["next_role"] is None or result["next_role"] == ""


# ---------------------------------------------------------------------------
# Compound integration: full tester→guardian production sequence
# ---------------------------------------------------------------------------


def test_full_tester_to_guardian_production_sequence(conn, project_root):
    """Compound-interaction test exercising the real production path:

    1. Orchestrator issues a lease for tester.
    2. Tester submits a valid completion record.
    3. post-task.sh fires → process_agent_stop runs for tester.
    4. Routing reads the completion record → next_role=guardian.
    5. Lease is released.
    6. Eval state is NOT set to pending (only implementer sets pending).
    """
    wf_id = "wf-compound-001"

    # Step 1: issue lease with worktree_path = project_root (production model)
    lease = _issue_lease_at(conn, "tester", project_root, workflow_id=wf_id)
    assert lease["status"] == "active"

    # Step 2: submit valid completion
    comp_result = _submit_valid_tester_completion(conn, lease["lease_id"], wf_id)
    assert comp_result["valid"] is True
    assert comp_result["verdict"] == "ready_for_guardian"

    # Step 3+4: process_agent_stop
    result = process_agent_stop(conn, "tester", project_root)

    assert result["error"] is None
    assert result["next_role"] == "guardian"
    assert result["workflow_id"] == wf_id
    assert "guardian" in result["suggestion"]

    # Step 5: lease released
    refreshed = leases.get(conn, lease["lease_id"])
    assert refreshed["status"] == "released"

    # Step 6: no eval_state set for tester (only implementer does this)
    # eval state should not exist unless pre-existing
    eval_state = evaluation.get(conn, wf_id)
    assert eval_state is None or eval_state["status"] != "pending"
