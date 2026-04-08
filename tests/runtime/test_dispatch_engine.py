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
from runtime.core.policy_utils import current_workflow_id
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


def _codex_workflow_source(project_root: str) -> str:
    return f"workflow:{current_workflow_id(project_root)}"


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


def test_planner_routes_to_guardian(conn, project_root):
    """W-GWT-1: Planner now routes to guardian (not implementer) for worktree provisioning."""
    result = process_agent_stop(conn, "planner", project_root)
    assert result["next_role"] == "guardian"
    assert result["error"] is None


def test_planner_alias_plan_routes_to_guardian(conn, project_root):
    """Tolerate 'Plan' capitalisation (matches bash case statement) — W-GWT-1."""
    result = process_agent_stop(conn, "Plan", project_root)
    assert result["next_role"] == "guardian"
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
    """W-GWT-1: planner now routes to guardian, suggestion must mention guardian."""
    result = process_agent_stop(conn, "planner", project_root)
    assert "guardian" in result["suggestion"]


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


# ---------------------------------------------------------------------------
# implementer completion contract (DEC-IMPL-CONTRACT-001)
# ---------------------------------------------------------------------------


def _submit_valid_implementer_completion(conn, lease_id, workflow_id, status="complete"):
    return completions.submit(
        conn,
        lease_id=lease_id,
        workflow_id=workflow_id,
        role="implementer",
        payload={
            "IMPL_STATUS": status,
            "IMPL_HEAD_SHA": "abc123",
        },
    )


def test_implementer_valid_contract_emits_agent_complete(conn, project_root):
    """Valid IMPL_STATUS=complete contract → agent_complete event, routing unchanged."""
    wf_id = "wf-impl-contract-001"
    lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    _submit_valid_implementer_completion(conn, lease["lease_id"], wf_id, status="complete")
    result = process_agent_stop(conn, "implementer", project_root)
    assert result["next_role"] == "tester"
    assert result["error"] is None
    complete_events = [e for e in result["events"] if e["type"] == "agent_complete"]
    assert len(complete_events) >= 1


def test_implementer_partial_contract_emits_agent_stopped(conn, project_root):
    """Valid IMPL_STATUS=partial contract → agent_stopped event, routing still → tester."""
    wf_id = "wf-impl-contract-002"
    lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    _submit_valid_implementer_completion(conn, lease["lease_id"], wf_id, status="partial")
    result = process_agent_stop(conn, "implementer", project_root)
    assert result["next_role"] == "tester"
    stopped_events = [e for e in result["events"] if e["type"] == "agent_stopped"]
    assert len(stopped_events) >= 1


def test_implementer_blocked_contract_emits_agent_stopped(conn, project_root):
    """Valid IMPL_STATUS=blocked contract → agent_stopped event, routing still → tester."""
    wf_id = "wf-impl-contract-003"
    lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    _submit_valid_implementer_completion(conn, lease["lease_id"], wf_id, status="blocked")
    result = process_agent_stop(conn, "implementer", project_root)
    assert result["next_role"] == "tester"
    stopped_events = [e for e in result["events"] if e["type"] == "agent_stopped"]
    assert len(stopped_events) >= 1


def test_implementer_invalid_contract_not_trusted(conn, project_root):
    """Malformed IMPL_STATUS emits impl_contract_invalid and does not override heuristic."""
    wf_id = "wf-impl-contract-004"
    lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    # Submit with bogus IMPL_STATUS — will be stored valid=0
    completions.submit(
        conn,
        lease_id=lease["lease_id"],
        workflow_id=wf_id,
        role="implementer",
        payload={"IMPL_STATUS": "bogus_status", "IMPL_HEAD_SHA": "abc123"},
    )
    result = process_agent_stop(conn, "implementer", project_root)
    assert result["next_role"] == "tester"  # routing unchanged
    invalid_events = [e for e in result["events"] if e["type"] == "impl_contract_invalid"]
    assert len(invalid_events) >= 1


def test_implementer_contract_uses_lease_workflow_id(conn, project_root):
    """Contract is read under the lease workflow_id, result carries that id."""
    wf_id = "wf-impl-lease-001"
    lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    _submit_valid_implementer_completion(conn, lease["lease_id"], wf_id, status="complete")
    result = process_agent_stop(conn, "implementer", project_root)
    assert result["workflow_id"] == wf_id
    assert result["next_role"] == "tester"
    complete_events = [e for e in result["events"] if e["type"] == "agent_complete"]
    assert len(complete_events) >= 1


def test_implementer_no_trailers_heuristic_fallback(conn, project_root):
    """Implementer with lease but no completion record → heuristic fallback (advisory).

    When no IMPL_STATUS/IMPL_HEAD_SHA trailers are present the check-implementer.sh
    Check 8 submits nothing. dispatch_engine finds no completion record for the lease
    and falls through to the heuristic (DEC-IMPL-CONTRACT-001). Routing is still
    → tester (unchanged). No impl_contract_invalid event is emitted because there
    is nothing malformed — there is simply no record.

    This is the backward-compatibility path: old implementers that predate the
    structured contract produce no record and the heuristic governs instead.
    """
    wf_id = "wf-impl-no-trailers-001"
    _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    # No completion record submitted — simulates missing trailers.
    result = process_agent_stop(conn, "implementer", project_root)
    assert result["next_role"] == "tester"
    assert result["error"] is None
    # No impl_contract_invalid event — missing record is not the same as malformed.
    invalid_events = [e for e in result["events"] if e["type"] == "impl_contract_invalid"]
    assert len(invalid_events) == 0


def test_full_implementer_contract_production_sequence(conn, project_root):
    """Compound-interaction test: implementer trailer → completion submit → dispatch routing.

    Exercises the real production sequence end-to-end across multiple components:
      1. Orchestrator issues implementer lease (leases domain).
      2. check-implementer.sh Check 8 parses IMPL_STATUS trailer and calls
         completions.submit() (completions domain — simulated directly here).
      3. post-task.sh fires → process_agent_stop() (dispatch_engine) runs.
      4. dispatch_engine reads completion record for lease_id (completions domain).
      5. Valid contract (IMPL_STATUS=complete) overrides heuristic → agent_complete event.
      6. Routing → tester (fixed transition, unchanged by contract).
      7. eval_state set to pending (evaluation domain).
      8. auto_dispatch=True because not interrupted.

    All three domain boundaries (leases / completions / evaluation) are crossed.
    """
    wf_id = "wf-impl-prod-seq-001"

    # Step 1: lease issued (mirrors orchestrator pre-dispatch action)
    lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    assert lease["status"] == "active"

    # Step 2: completion record submitted (mirrors check-implementer.sh Check 8)
    comp_result = _submit_valid_implementer_completion(
        conn, lease["lease_id"], wf_id, status="complete"
    )
    assert comp_result["valid"] is True
    assert comp_result["verdict"] == "complete"

    # Step 3+4+5+6: process_agent_stop
    result = process_agent_stop(conn, "implementer", project_root)

    # Step 6: routing → tester
    assert result["next_role"] == "tester"
    assert result["error"] is None
    assert result["workflow_id"] == wf_id

    # Step 5: contract overrides heuristic → agent_complete (not agent_stopped)
    complete_events = [e for e in result["events"] if e["type"] == "agent_complete"]
    assert len(complete_events) >= 1
    stopped_events = [e for e in result["events"] if e["type"] == "agent_stopped"]
    assert len(stopped_events) == 0

    # Step 7: eval_state = pending written
    from runtime.core import evaluation

    state = evaluation.get(conn, wf_id)
    assert state is not None
    assert state["status"] == "pending"

    # Step 8: auto_dispatch=True
    assert result["auto_dispatch"] is True
    assert result["suggestion"].startswith("AUTO_DISPATCH: tester")


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


# ---------------------------------------------------------------------------
# W-AD-1: auto_dispatch field and suggestion prefix
# ---------------------------------------------------------------------------
# @decision DEC-AD-001
# Title: auto_dispatch field in process_agent_stop result
# Status: accepted
# Rationale: The dispatch pipeline computes next_role correctly but the
#   orchestrator asks the user for permission at every handoff. The auto_dispatch
#   bool field distinguishes "auto-dispatch this" from "suggestion, check with
#   user". It is True for clear, unblocked, non-terminal transitions and False
#   for interrupted, errored, or terminal states. When True, the suggestion is
#   prefixed with "AUTO_DISPATCH: <role>\n" so the orchestrator can parse it
#   without additional signaling. This implements W-AD-1 (issue #13).
# ---------------------------------------------------------------------------


def test_planner_stop_auto_dispatch(conn, project_root):
    """Planner stop → auto_dispatch=True, next_role=guardian (W-GWT-1)."""
    result = process_agent_stop(conn, "planner", project_root)
    assert result["auto_dispatch"] is True
    assert result["next_role"] == "guardian"
    assert result["error"] is None


def test_implementer_stop_auto_dispatch(conn, project_root):
    """Implementer stop (no interruption, valid contract) → auto_dispatch=True."""
    wf_id = "wf-ad-impl-001"
    lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    _submit_valid_implementer_completion(conn, lease["lease_id"], wf_id, status="complete")
    result = process_agent_stop(conn, "implementer", project_root)
    assert result["auto_dispatch"] is True
    assert result["next_role"] == "tester"
    assert result["error"] is None


def test_implementer_stop_interrupted_no_auto_dispatch(conn, project_root):
    """Implementer stop with IMPL_STATUS=partial (interrupted) → auto_dispatch=False."""
    wf_id = "wf-ad-impl-002"
    lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    # partial verdict → is_interrupted = True via contract override
    _submit_valid_implementer_completion(conn, lease["lease_id"], wf_id, status="partial")
    result = process_agent_stop(conn, "implementer", project_root)
    assert result["auto_dispatch"] is False
    assert result["next_role"] == "tester"  # routing unchanged


def test_tester_ready_for_guardian_auto_dispatch(conn, project_root):
    """Tester stop (ready_for_guardian) → auto_dispatch=True, next_role=guardian."""
    wf_id = "wf-ad-tester-001"
    lease = _issue_lease_at(conn, "tester", project_root, workflow_id=wf_id)
    _submit_valid_tester_completion(conn, lease["lease_id"], wf_id)
    result = process_agent_stop(conn, "tester", project_root)
    assert result["auto_dispatch"] is True
    assert result["next_role"] == "guardian"
    assert result["error"] is None


def test_tester_needs_changes_auto_dispatch(conn, project_root):
    """Tester stop (needs_changes) → auto_dispatch=True, next_role=implementer."""
    wf_id = "wf-ad-tester-002"
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
    assert result["auto_dispatch"] is True
    assert result["next_role"] == "implementer"
    assert result["error"] is None


def test_tester_blocked_by_plan_auto_dispatch(conn, project_root):
    """Tester stop (blocked_by_plan) → auto_dispatch=True, next_role=planner."""
    wf_id = "wf-ad-tester-003"
    lease = _issue_lease_at(conn, "tester", project_root, workflow_id=wf_id)
    completions.submit(
        conn,
        lease_id=lease["lease_id"],
        workflow_id=wf_id,
        role="tester",
        payload={
            "EVAL_VERDICT": "blocked_by_plan",
            "EVAL_TESTS_PASS": "no",
            "EVAL_NEXT_ROLE": "planner",
            "EVAL_HEAD_SHA": "abc123",
        },
    )
    result = process_agent_stop(conn, "tester", project_root)
    assert result["auto_dispatch"] is True
    assert result["next_role"] == "planner"
    assert result["error"] is None


def test_guardian_committed_no_auto_dispatch(conn, project_root):
    """Guardian stop (committed) → auto_dispatch=False (terminal, next_role=None)."""
    wf_id = "wf-ad-guardian-001"
    lease = _issue_lease_at(conn, "guardian", project_root, workflow_id=wf_id)
    _submit_valid_guardian_completion(conn, lease["lease_id"], wf_id, verdict="committed")
    result = process_agent_stop(conn, "guardian", project_root)
    assert result["auto_dispatch"] is False
    assert not result["next_role"]  # None or empty → terminal
    assert result["error"] is None


def test_guardian_denied_auto_dispatch(conn, project_root):
    """Guardian stop (denied) → auto_dispatch=True, next_role=implementer."""
    wf_id = "wf-ad-guardian-002"
    lease = _issue_lease_at(conn, "guardian", project_root, workflow_id=wf_id)
    _submit_valid_guardian_completion(conn, lease["lease_id"], wf_id, verdict="denied")
    result = process_agent_stop(conn, "guardian", project_root)
    assert result["auto_dispatch"] is True
    assert result["next_role"] == "implementer"
    assert result["error"] is None


def test_error_no_auto_dispatch(conn, project_root):
    """Routing error (no lease for tester) → auto_dispatch=False."""
    # No lease → PROCESS ERROR for tester
    result = process_agent_stop(conn, "tester", project_root)
    assert result["auto_dispatch"] is False
    assert result["error"] is not None
    assert "PROCESS ERROR" in result["error"]


def test_suggestion_auto_dispatch_prefix(conn, project_root):
    """When auto_dispatch=True, suggestion starts with 'AUTO_DISPATCH: '."""
    result = process_agent_stop(conn, "planner", project_root)
    assert result["auto_dispatch"] is True
    assert result["suggestion"].startswith("AUTO_DISPATCH: ")


def test_suggestion_canonical_prefix_when_false(conn, project_root):
    """When auto_dispatch=False and non-terminal (interrupted impl), suggestion format unchanged.

    For the interrupted implementer case: auto_dispatch=False and next_role=tester,
    so the suggestion should start with 'Canonical flow suggests' (not AUTO_DISPATCH).
    The interruption warning is appended after.
    """
    wf_id = "wf-ad-canon-001"
    lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    _submit_valid_implementer_completion(conn, lease["lease_id"], wf_id, status="blocked")
    result = process_agent_stop(conn, "implementer", project_root)
    # blocked → is_interrupted=True → auto_dispatch=False
    assert result["auto_dispatch"] is False
    # Suggestion starts with 'Canonical flow suggests' not 'AUTO_DISPATCH'
    assert result["suggestion"].startswith("Canonical flow suggests")


def test_auto_dispatch_full_cycle_production_sequence(conn, project_root):
    """Compound-interaction test: full planner→guardian→impl→tester→guardian chain
    verifying auto_dispatch at each transition boundary.

    W-GWT-1: planner now routes to guardian (provision mode), not implementer directly.

    Production sequence exercised:
      planner stop → auto_dispatch=True (guardian suggested, mode=provision)
      implementer stop (complete) → auto_dispatch=True (tester suggested)
      tester stop (ready_for_guardian) → auto_dispatch=True (guardian suggested)
      guardian stop (committed) → auto_dispatch=False (terminal)
    """
    wf_id = "wf-ad-cycle-001"

    # --- Planner stop → guardian (W-GWT-1) ---
    r_planner = process_agent_stop(conn, "planner", project_root)
    assert r_planner["auto_dispatch"] is True
    assert r_planner["next_role"] == "guardian"
    assert r_planner["suggestion"].startswith("AUTO_DISPATCH: guardian")

    # --- Implementer stop (complete contract) ---
    impl_lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    _submit_valid_implementer_completion(conn, impl_lease["lease_id"], wf_id, status="complete")
    r_impl = process_agent_stop(conn, "implementer", project_root)
    assert r_impl["auto_dispatch"] is True
    assert r_impl["next_role"] == "tester"
    assert r_impl["suggestion"].startswith("AUTO_DISPATCH: tester")

    # --- Tester stop (ready_for_guardian) ---
    tester_lease = _issue_lease_at(conn, "tester", project_root, workflow_id=wf_id)
    _submit_valid_tester_completion(conn, tester_lease["lease_id"], wf_id)
    r_tester = process_agent_stop(conn, "tester", project_root)
    assert r_tester["auto_dispatch"] is True
    assert r_tester["next_role"] == "guardian"
    assert r_tester["suggestion"].startswith("AUTO_DISPATCH: guardian")

    # --- Guardian stop (committed → terminal) ---
    guardian_lease = _issue_lease_at(conn, "guardian", project_root, workflow_id=wf_id)
    _submit_valid_guardian_completion(conn, guardian_lease["lease_id"], wf_id, verdict="committed")
    r_guardian = process_agent_stop(conn, "guardian", project_root)
    assert r_guardian["auto_dispatch"] is False
    assert not r_guardian["next_role"]
    assert r_guardian["suggestion"] == ""


# ---------------------------------------------------------------------------
# W-AD-3: Codex stop-review gate (_check_codex_gate integration)
# ---------------------------------------------------------------------------
# @decision DEC-AD-002
# Title: Codex stop-review gate communicates via events table
# Status: accepted
# Rationale: The Codex gate hook writes a workflow-scoped codex_stop_review
#   event and dispatch_engine reads the most recent such event within a
#   60-second window for the current workflow only.
#   BLOCK verdict sets auto_dispatch=False and appends the block reason to
#   suggestion. Errors in the lookup are advisory — never block routing.
#   This keeps dispatch_engine as the sole auto_dispatch decision authority
#   while Codex acts as a pure event emitter.
# ---------------------------------------------------------------------------


def test_codex_gate_no_event_auto_dispatch_stays_true(conn, project_root):
    """No codex_stop_review event → auto_dispatch stays True for clear transition.

    W-GWT-1: planner now routes to guardian, not implementer.
    """
    # Planner stop — clear transition, no Codex event in DB
    result = process_agent_stop(conn, "planner", project_root)
    assert result["auto_dispatch"] is True
    assert result["next_role"] == "guardian"
    assert result["error"] is None
    # Confirm no codex_blocked key set to True
    assert not result.get("codex_blocked")


def test_codex_gate_allow_auto_dispatch_stays_true(conn, project_root):
    """ALLOW verdict → auto_dispatch stays True.

    W-GWT-1: planner now routes to guardian, not implementer.
    """
    from runtime.core import events as ev

    wf_id = current_workflow_id(project_root)
    ev.emit(
        conn,
        type="codex_stop_review",
        source=_codex_workflow_source(project_root),
        detail=f"VERDICT: ALLOW — workflow={wf_id} | work looks good",
    )
    result = process_agent_stop(conn, "planner", project_root)
    assert result["auto_dispatch"] is True
    assert result["next_role"] == "guardian"
    assert not result.get("codex_blocked")


def test_codex_gate_block_overrides_auto_dispatch(conn, project_root):
    """BLOCK verdict → auto_dispatch becomes False, suggestion includes block reason.

    W-GWT-1: planner now routes to guardian, not implementer.
    """
    from runtime.core import events as ev

    wf_id = current_workflow_id(project_root)
    block_reason = "Insufficient test coverage for edge cases"
    ev.emit(
        conn,
        type="codex_stop_review",
        source=_codex_workflow_source(project_root),
        detail=f"VERDICT: BLOCK — workflow={wf_id} | {block_reason}",
    )
    result = process_agent_stop(conn, "planner", project_root)
    assert result["auto_dispatch"] is False
    assert result["next_role"] == "guardian"
    assert result["error"] is None
    assert result.get("codex_blocked") is True
    assert result.get("codex_reason") == block_reason
    assert "CODEX BLOCK" in result["suggestion"]
    assert block_reason in result["suggestion"]


def test_codex_gate_block_on_already_false(conn, project_root):
    """auto_dispatch already False (error) + BLOCK verdict → stays False, no double-negative."""
    from runtime.core import events as ev

    wf_id = current_workflow_id(project_root)
    # Emit a BLOCK verdict
    ev.emit(
        conn,
        type="codex_stop_review",
        source=_codex_workflow_source(project_root),
        detail=f"VERDICT: BLOCK — workflow={wf_id} | test reason",
    )
    # Tester with no lease → PROCESS ERROR → auto_dispatch=False already
    result = process_agent_stop(conn, "tester", project_root)
    assert result["auto_dispatch"] is False
    assert result["error"] is not None
    assert "PROCESS ERROR" in result["error"]
    # codex_blocked should NOT be set since auto_dispatch was already False before gate check
    assert not result.get("codex_blocked")


def test_codex_gate_stale_event_ignored(conn, project_root):
    """Event >60s old → ignored, auto_dispatch stays True.

    W-GWT-1: planner now routes to guardian, not implementer.
    """
    wf_id = current_workflow_id(project_root)
    # Insert a BLOCK event with a created_at timestamp 120 seconds in the past
    stale_ts = int(__import__("time").time()) - 120
    conn.execute(
        "INSERT INTO events (type, source, detail, created_at) VALUES (?, ?, ?, ?)",
        (
            "codex_stop_review",
            _codex_workflow_source(project_root),
            f"VERDICT: BLOCK — workflow={wf_id} | stale reason",
            stale_ts,
        ),
    )
    conn.commit()

    result = process_agent_stop(conn, "planner", project_root)
    # Stale event must be ignored
    assert result["auto_dispatch"] is True
    assert result["next_role"] == "guardian"
    assert not result.get("codex_blocked")


def test_codex_gate_wrong_workflow_ignored(conn, project_root):
    """A newer BLOCK verdict for another workflow must not block this workflow."""
    from runtime.core import events as ev

    ev.emit(
        conn,
        type="codex_stop_review",
        source="workflow:wf-other",
        detail="VERDICT: BLOCK — workflow=wf-other | wrong workflow",
    )
    result = process_agent_stop(conn, "planner", project_root)
    assert result["auto_dispatch"] is True
    assert result["next_role"] == "guardian"
    assert not result.get("codex_blocked")


# ---------------------------------------------------------------------------
# W-GWT-1: Guardian worktree authority — routing table + dispatch engine changes
# ---------------------------------------------------------------------------
# @decision DEC-GUARD-WT-001
# Title: planner routes to guardian (not implementer) for worktree provisioning
# Status: accepted
# Rationale: The routing table maps ("planner", _) -> "guardian" so Guardian
#   is the sole worktree lifecycle authority. Guardian determines its mode
#   (provision vs merge) from the guardian_mode structured dispatch field.
#   completions.py maps ("guardian", "provisioned") -> "implementer" so the
#   chain planner -> guardian -> implementer is preserved. dispatch_engine
#   remains a pure routing engine — no git side effects, no lease writes.
# ---------------------------------------------------------------------------


def _submit_valid_guardian_completion_provisioned(conn, lease_id, workflow_id, worktree_path=""):
    """Submit a guardian completion with LANDING_RESULT=provisioned."""
    payload = {
        "LANDING_RESULT": "provisioned",
        "OPERATION_CLASS": "routine_local",
    }
    if worktree_path:
        payload["WORKTREE_PATH"] = worktree_path
    return completions.submit(
        conn,
        lease_id=lease_id,
        workflow_id=workflow_id,
        role="guardian",
        payload=payload,
    )


def test_planner_guardian_mode_is_provision(conn, project_root):
    """Planner stop sets guardian_mode='provision' in result."""
    result = process_agent_stop(conn, "planner", project_root)
    assert result.get("guardian_mode") == "provision"


def test_planner_auto_dispatch_to_guardian(conn, project_root):
    """Planner stop → auto_dispatch=True, suggestion starts AUTO_DISPATCH: guardian."""
    result = process_agent_stop(conn, "planner", project_root)
    assert result["auto_dispatch"] is True
    assert result["suggestion"].startswith("AUTO_DISPATCH: guardian")


def test_planner_suggestion_encodes_mode(conn, project_root):
    """Planner AUTO_DISPATCH suggestion encodes mode=provision."""
    result = process_agent_stop(conn, "planner", project_root)
    assert "mode=provision" in result["suggestion"]


def test_planner_no_lease_still_routes_to_guardian(conn, project_root):
    """Planner without a lease still routes to guardian (best-effort workflow_id)."""
    # No lease issued — planner routing is fixed (no lease required)
    result = process_agent_stop(conn, "planner", project_root)
    assert result["next_role"] == "guardian"
    assert result["error"] is None
    assert result.get("guardian_mode") == "provision"


def test_planner_with_lease_resolves_workflow_id(conn, project_root):
    """When planner has an active lease, workflow_id is resolved from it."""
    wf_id = "wf-gwt-planner-lease-001"
    _issue_lease_at(conn, "planner", project_root, workflow_id=wf_id)
    result = process_agent_stop(conn, "planner", project_root)
    assert result["next_role"] == "guardian"
    assert result["workflow_id"] == wf_id
    assert result.get("guardian_mode") == "provision"


def test_planner_suggestion_encodes_workflow_id_when_known(conn, project_root):
    """When workflow_id is resolved at planner stop, suggestion encodes it."""
    wf_id = "wf-gwt-planner-wf-001"
    _issue_lease_at(conn, "planner", project_root, workflow_id=wf_id)
    result = process_agent_stop(conn, "planner", project_root)
    assert wf_id in result["suggestion"]


def test_guardian_provisioned_routes_to_implementer(conn, project_root):
    """Guardian with 'provisioned' verdict routes to implementer — W-GWT-1."""
    wf_id = "wf-gwt-prov-001"
    lease = _issue_lease_at(conn, "guardian", project_root, workflow_id=wf_id)
    _submit_valid_guardian_completion_provisioned(conn, lease["lease_id"], wf_id)
    result = process_agent_stop(conn, "guardian", project_root)
    assert result["next_role"] == "implementer"
    assert result["error"] is None


def test_guardian_provisioned_suggestion_encodes_worktree_path(conn, project_root):
    """Guardian (provisioned) AUTO_DISPATCH suggestion encodes worktree_path."""
    wf_id = "wf-gwt-prov-wt-001"
    worktree = "/some/project/.worktrees/feature-gwt-1"
    lease = _issue_lease_at(conn, "guardian", project_root, workflow_id=wf_id)
    _submit_valid_guardian_completion_provisioned(
        conn, lease["lease_id"], wf_id, worktree_path=worktree
    )
    result = process_agent_stop(conn, "guardian", project_root)
    assert result["next_role"] == "implementer"
    assert result["error"] is None
    assert worktree in result["suggestion"]
    assert result.get("worktree_path") == worktree


def test_guardian_provisioned_auto_dispatch_true(conn, project_root):
    """Guardian (provisioned) is auto-dispatched to implementer."""
    wf_id = "wf-gwt-prov-ad-001"
    lease = _issue_lease_at(conn, "guardian", project_root, workflow_id=wf_id)
    _submit_valid_guardian_completion_provisioned(conn, lease["lease_id"], wf_id)
    result = process_agent_stop(conn, "guardian", project_root)
    assert result["auto_dispatch"] is True
    assert result["next_role"] == "implementer"


def test_tester_needs_changes_suggestion_encodes_worktree_path(conn, project_root):
    """Tester needs_changes auto-dispatch encodes worktree_path from workflow_bindings."""
    from runtime.core import workflows

    wf_id = "wf-gwt-nc-wt-001"
    worktree = "/some/project/.worktrees/feature-impl-001"
    # Register workflow binding (simulates guardian provisioning step)
    workflows.bind_workflow(
        conn,
        workflow_id=wf_id,
        worktree_path=worktree,
        branch="feature/impl-001",
    )
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
    assert worktree in result["suggestion"]
    assert result.get("worktree_path") == worktree


def test_tester_needs_changes_no_binding_still_routes(conn, project_root):
    """Tester needs_changes routes correctly even when workflow_bindings has no entry."""
    wf_id = "wf-gwt-nc-nobind-001"
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
    # worktree_path is empty/missing when no binding exists — that's acceptable
    assert result.get("worktree_path", "") == ""


def test_full_planner_guardian_implementer_chain(conn, project_root):
    """Compound-interaction test: planner→guardian(provisioned)→implementer chain.

    Production sequence (W-GWT-1):
      1. Planner stop → routes to guardian, guardian_mode=provision.
      2. Guardian issues provisioning lease (simulated by _issue_lease_at).
      3. Guardian submits provisioned completion with WORKTREE_PATH.
      4. Guardian stop → routes to implementer, worktree_path in result.
      5. Suggestion encodes worktree_path in AUTO_DISPATCH line.

    Crosses leases / completions / dispatch_engine domain boundaries.
    """
    wf_id = "wf-gwt-chain-001"
    worktree = "/some/project/.worktrees/feature-gwt-chain"

    # Step 1: Planner stop → routes to guardian
    r_planner = process_agent_stop(conn, "planner", project_root)
    assert r_planner["next_role"] == "guardian"
    assert r_planner["auto_dispatch"] is True
    assert r_planner.get("guardian_mode") == "provision"
    assert r_planner["suggestion"].startswith("AUTO_DISPATCH: guardian")

    # Step 2+3: Guardian issues lease and submits provisioned completion
    guardian_lease = _issue_lease_at(conn, "guardian", project_root, workflow_id=wf_id)
    _submit_valid_guardian_completion_provisioned(
        conn, guardian_lease["lease_id"], wf_id, worktree_path=worktree
    )

    # Step 4: Guardian stop → routes to implementer
    r_guardian = process_agent_stop(conn, "guardian", project_root)
    assert r_guardian["next_role"] == "implementer"
    assert r_guardian["error"] is None
    assert r_guardian["auto_dispatch"] is True
    assert r_guardian.get("worktree_path") == worktree

    # Step 5: Suggestion encodes worktree_path
    assert worktree in r_guardian["suggestion"]
    assert r_guardian["suggestion"].startswith("AUTO_DISPATCH: implementer")
