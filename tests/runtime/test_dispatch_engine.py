"""Tests for runtime/core/dispatch_engine.py

@decision DEC-DISPATCH-ENGINE-001
Title: dispatch_engine.process_agent_stop is the authoritative dispatch state machine
Status: accepted
Rationale: post-task.sh contained ~200 lines of routing logic in bash. This module
  ports that logic to Python so it can be unit-tested without subprocess overhead,
  is independently verifiable, and uses domain modules directly. The bash adapter
  becomes a thin wrapper (~20 lines) that pipes JSON through cc-policy dispatch
  process-stop and echoes the hookSpecificOutput result.

  Compound-interaction tests exercise the real production path:
    lease issue → completion submit → process_agent_stop →
    routing resolved from completion record → lease released after routing.

  Phase 5 (DEC-PHASE5-ROUTING-001): implementer routes to reviewer (not tester).
  Tester is neutralized as a live workflow-routing authority — stop releases
  the lease but does not auto-dispatch.
"""

import json
import sqlite3

import pytest

from runtime.core import completions, critic_reviews, evaluation, leases
from runtime.core import decision_work_registry as dwr
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


def _submit_valid_planner_completion(conn, lease_id, workflow_id, verdict="next_work_item"):
    """Submit a valid planner completion record (Phase 6 Slice 4)."""
    return completions.submit(
        conn,
        lease_id=lease_id,
        workflow_id=workflow_id,
        role="planner",
        payload={
            "PLAN_VERDICT": verdict,
            "PLAN_SUMMARY": "Test planner summary",
        },
    )


def _insert_goal(conn, goal_id, budget=5, status="active"):
    """Insert an active goal contract so planner→guardian budget check passes.

    Phase 6 Slice 6: goal_continuation.check_continuation_budget() denies
    auto-dispatch when no active goal contract exists. Tests that expect
    planner (next_work_item) to route to guardian must insert a goal first.
    """
    return dwr.insert_goal(
        conn,
        dwr.GoalRecord(
            goal_id=goal_id,
            desired_end_state="Test goal",
            status=status,
            autonomy_budget=budget,
        ),
    )


# ---------------------------------------------------------------------------
# planner routing via completion record (Phase 6 Slice 4)
# ---------------------------------------------------------------------------


def test_planner_next_work_item_routes_to_guardian(conn, project_root):
    """Phase 6 Slice 4: planner (next_work_item) → guardian via _route_from_completion."""
    wf_id = "wf-planner-001"
    _insert_goal(conn, wf_id)
    lease = _issue_lease_at(conn, "planner", project_root, workflow_id=wf_id)
    _submit_valid_planner_completion(conn, lease["lease_id"], wf_id, verdict="next_work_item")
    result = process_agent_stop(conn, "planner", project_root)
    assert result["next_role"] == "guardian"
    assert result["error"] is None


def test_planner_alias_plan_routes_to_guardian(conn, project_root):
    """Tolerate 'Plan' capitalisation — routes same as 'planner'."""
    wf_id = "wf-planner-alias-001"
    _insert_goal(conn, wf_id)
    lease = _issue_lease_at(conn, "planner", project_root, workflow_id=wf_id)
    _submit_valid_planner_completion(conn, lease["lease_id"], wf_id, verdict="next_work_item")
    result = process_agent_stop(conn, "Plan", project_root)
    assert result["next_role"] == "guardian"
    assert result["error"] is None


def test_planner_goal_complete_routes_to_none(conn, project_root):
    """Phase 6 Slice 4: planner (goal_complete) → None (terminal)."""
    wf_id = "wf-planner-gc-001"
    lease = _issue_lease_at(conn, "planner", project_root, workflow_id=wf_id)
    _submit_valid_planner_completion(conn, lease["lease_id"], wf_id, verdict="goal_complete")
    result = process_agent_stop(conn, "planner", project_root)
    assert result["next_role"] is None
    assert result["error"] is None
    assert result["auto_dispatch"] is False


def test_planner_needs_user_decision_routes_to_none(conn, project_root):
    """Phase 6 Slice 4: planner (needs_user_decision) → None (user input needed)."""
    wf_id = "wf-planner-ud-001"
    lease = _issue_lease_at(conn, "planner", project_root, workflow_id=wf_id)
    _submit_valid_planner_completion(conn, lease["lease_id"], wf_id, verdict="needs_user_decision")
    result = process_agent_stop(conn, "planner", project_root)
    assert result["next_role"] is None
    assert result["error"] is None
    assert result["auto_dispatch"] is False


def test_planner_blocked_external_routes_to_none(conn, project_root):
    """Phase 6 Slice 4: planner (blocked_external) → None (external dependency)."""
    wf_id = "wf-planner-be-001"
    lease = _issue_lease_at(conn, "planner", project_root, workflow_id=wf_id)
    _submit_valid_planner_completion(conn, lease["lease_id"], wf_id, verdict="blocked_external")
    result = process_agent_stop(conn, "planner", project_root)
    assert result["next_role"] is None
    assert result["error"] is None
    assert result["auto_dispatch"] is False


def test_planner_no_lease_returns_error(conn, project_root):
    """Phase 6 Slice 4: planner without lease → PROCESS ERROR."""
    result = process_agent_stop(conn, "planner", project_root)
    assert result["error"] is not None
    assert "PROCESS ERROR" in result["error"]
    assert result["next_role"] is None


def test_planner_no_completion_record_returns_error(conn, project_root):
    """Phase 6 Slice 4: planner with lease but no completion → PROCESS ERROR."""
    wf_id = "wf-planner-nocomp-001"
    _issue_lease_at(conn, "planner", project_root, workflow_id=wf_id)
    result = process_agent_stop(conn, "planner", project_root)
    assert result["error"] is not None
    assert "PROCESS ERROR" in result["error"]


def test_planner_invalid_completion_returns_error(conn, project_root):
    """Phase 6 Slice 4: planner with invalid completion → PROCESS ERROR."""
    wf_id = "wf-planner-invalid-001"
    lease = _issue_lease_at(conn, "planner", project_root, workflow_id=wf_id)
    completions.submit(
        conn,
        lease_id=lease["lease_id"],
        workflow_id=wf_id,
        role="planner",
        payload={"PLAN_VERDICT": "bogus_verdict", "PLAN_SUMMARY": "test"},
    )
    result = process_agent_stop(conn, "planner", project_root)
    assert result["error"] is not None
    assert "PROCESS ERROR" in result["error"]


def test_planner_lease_released_after_routing(conn, project_root):
    """Lease must be status='released' after planner process_agent_stop completes."""
    wf_id = "wf-planner-release-001"
    _insert_goal(conn, wf_id)
    lease = _issue_lease_at(conn, "planner", project_root, workflow_id=wf_id)
    _submit_valid_planner_completion(conn, lease["lease_id"], wf_id)
    process_agent_stop(conn, "planner", project_root)
    refreshed = leases.get(conn, lease["lease_id"])
    assert refreshed["status"] == "released"


def test_planner_goal_complete_suggestion_signal(conn, project_root):
    """Phase 6 Slice 4: goal_complete verdict → GOAL_COMPLETE signal in suggestion."""
    wf_id = "wf-planner-gc-sig-001"
    lease = _issue_lease_at(conn, "planner", project_root, workflow_id=wf_id)
    _submit_valid_planner_completion(conn, lease["lease_id"], wf_id, verdict="goal_complete")
    result = process_agent_stop(conn, "planner", project_root)
    assert "GOAL_COMPLETE" in result["suggestion"]


def test_planner_needs_user_decision_suggestion_signal(conn, project_root):
    """Phase 6 Slice 4: needs_user_decision verdict → USER_DECISION_REQUIRED signal."""
    wf_id = "wf-planner-ud-sig-001"
    lease = _issue_lease_at(conn, "planner", project_root, workflow_id=wf_id)
    _submit_valid_planner_completion(conn, lease["lease_id"], wf_id, verdict="needs_user_decision")
    result = process_agent_stop(conn, "planner", project_root)
    assert "USER_DECISION_REQUIRED" in result["suggestion"]


def test_planner_blocked_external_suggestion_signal(conn, project_root):
    """Phase 6 Slice 4: blocked_external verdict → BLOCKED_EXTERNAL signal."""
    wf_id = "wf-planner-be-sig-001"
    lease = _issue_lease_at(conn, "planner", project_root, workflow_id=wf_id)
    _submit_valid_planner_completion(conn, lease["lease_id"], wf_id, verdict="blocked_external")
    result = process_agent_stop(conn, "planner", project_root)
    assert "BLOCKED_EXTERNAL" in result["suggestion"]


def test_full_planner_completion_production_sequence(conn, project_root):
    """Compound-interaction: planner lease → completion submit → dispatch routing.

    Production sequence (Phase 6 Slice 4):
      1. Orchestrator issues planner lease.
      2. check-planner.sh submits completion record with PLAN_VERDICT=next_work_item.
      3. post-task.sh fires → process_agent_stop() routes via _route_from_completion.
      4. Routing: planner → guardian (mode=provision).
      5. auto_dispatch=True, suggestion starts with AUTO_DISPATCH: guardian.
    """
    wf_id = "wf-planner-prod-001"
    _insert_goal(conn, wf_id)

    # Step 1: lease issued
    lease = _issue_lease_at(conn, "planner", project_root, workflow_id=wf_id)
    assert lease["status"] == "active"

    # Step 2: completion submitted (mirrors check-planner.sh)
    comp = _submit_valid_planner_completion(conn, lease["lease_id"], wf_id)
    assert comp["valid"] is True
    assert comp["verdict"] == "next_work_item"

    # Step 3+4: process_agent_stop routes via completion
    result = process_agent_stop(conn, "planner", project_root)
    assert result["next_role"] == "guardian"
    assert result["error"] is None
    assert result["workflow_id"] == wf_id
    assert result.get("guardian_mode") == "provision"

    # Step 5: auto_dispatch
    assert result["auto_dispatch"] is True
    assert isinstance(result["next_dispatch_id"], int)
    assert result["suggestion"].startswith("AUTO_DISPATCH: guardian")
    assert "mode=provision" in result["suggestion"]

    row = conn.execute(
        "SELECT workflow_id, source_role, next_role, guardian_mode, status, payload_json "
        "FROM dispatch_next_actions WHERE id = ?",
        (result["next_dispatch_id"],),
    ).fetchone()
    assert row is not None
    assert row["workflow_id"] == wf_id
    assert row["source_role"] == "planner"
    assert row["next_role"] == "guardian"
    assert row["guardian_mode"] == "provision"
    assert row["status"] == "pending"
    assert json.loads(row["payload_json"])["next_role"] == "guardian"

    # Lease released after routing
    refreshed = leases.get(conn, lease["lease_id"])
    assert refreshed["status"] == "released"


# ---------------------------------------------------------------------------
# implementer → reviewer (Phase 5: DEC-PHASE5-ROUTING-001)
# ---------------------------------------------------------------------------


def test_implementer_routes_to_reviewer(conn, project_root):
    """Phase 5: implementer routes to reviewer, not tester."""
    _issue_lease(conn, "implementer", workflow_id="wf-impl-001")
    result = process_agent_stop(conn, "implementer", project_root)
    assert result["next_role"] == "reviewer"
    assert result["error"] is None


def test_implementer_does_not_set_eval_pending(conn, project_root):
    """Phase 5: eval_state=pending is no longer written on implementer stop."""
    wf_id = "wf-impl-002"
    _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    process_agent_stop(conn, "implementer", project_root)
    state = evaluation.get(conn, wf_id)
    # No eval_state row should exist — the write was removed in Phase 5.
    assert state is None or state.get("status") != "pending"


def test_implementer_no_lease_still_routes_to_reviewer(conn, project_root):
    """Phase 5: implementer→reviewer routing is fixed — no lease needed."""
    result = process_agent_stop(conn, "implementer", project_root)
    assert result["next_role"] == "reviewer"
    assert result["error"] is None


def test_implementer_includes_worktree_path_for_reviewer(conn, project_root):
    """Phase 5: implementer stop populates worktree_path for reviewer dispatch."""
    from runtime.core import workflows

    wf_id = "wf-impl-wt-001"
    worktree = "/some/project/.worktrees/feature-impl-reviewer"
    workflows.bind_workflow(conn, workflow_id=wf_id, worktree_path=worktree, branch="feature/impl-reviewer")
    _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    result = process_agent_stop(conn, "implementer", project_root)
    assert result["next_role"] == "reviewer"
    assert result.get("worktree_path") == worktree


def test_implementer_critic_try_again_routes_back_to_implementer(conn, project_root):
    """Persisted TRY_AGAIN critic verdict loops back to implementer."""
    wf_id = "wf-impl-critic-try-001"
    lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    _submit_valid_implementer_completion(conn, lease["lease_id"], wf_id, status="complete")
    _submit_critic_review(
        conn,
        wf_id,
        "TRY_AGAIN",
        lease_id=lease["lease_id"],
        summary="Need another implementation pass.",
        detail="The happy path still lacks tests.",
        fingerprint="fp-try-1",
        metadata={
            "next_steps": ["Add regression coverage for the happy path."],
            "artifact_path": "/tmp/critic-review.md",
        },
    )
    result = process_agent_stop(conn, "implementer", project_root)
    assert result["critic_found"] is True
    assert result["critic_verdict"] == "TRY_AGAIN"
    assert result["next_role"] == "implementer"
    assert result["auto_dispatch"] is True
    assert result["suggestion"].startswith("AUTO_DISPATCH: implementer")
    assert "CRITIC_RETRY" in result["suggestion"]
    assert "CRITIC_NEXT_STEPS" in result["suggestion"]
    assert "Add regression coverage for the happy path." in result["suggestion"]
    assert "CRITIC_ARTIFACT: /tmp/critic-review.md" in result["suggestion"]
    assert "CRITIC_ACTION: Re-dispatch implementer" in result["suggestion"]


def test_implementer_critic_blocked_by_plan_routes_to_planner(conn, project_root):
    """Persisted BLOCKED_BY_PLAN critic verdict escalates to planner."""
    wf_id = "wf-impl-critic-plan-001"
    lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    _submit_valid_implementer_completion(conn, lease["lease_id"], wf_id, status="complete")
    _submit_critic_review(
        conn,
        wf_id,
        "BLOCKED_BY_PLAN",
        lease_id=lease["lease_id"],
        summary="Plan gap detected.",
        detail="The change requires planner authority to split the authority migration.",
        fingerprint="fp-plan-1",
    )
    result = process_agent_stop(conn, "implementer", project_root)
    assert result["critic_found"] is True
    assert result["critic_verdict"] == "BLOCKED_BY_PLAN"
    assert result["next_role"] == "planner"
    assert result["auto_dispatch"] is True
    assert result["worktree_path"] == ""


def test_implementer_critic_unavailable_routes_to_reviewer(conn, project_root):
    """Persisted CRITIC_UNAVAILABLE falls through to reviewer adjudication."""
    wf_id = "wf-impl-critic-unavail-001"
    lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    _submit_valid_implementer_completion(conn, lease["lease_id"], wf_id, status="blocked")
    _submit_critic_review(
        conn,
        wf_id,
        "CRITIC_UNAVAILABLE",
        lease_id=lease["lease_id"],
        summary="Codex unavailable.",
        detail="The Codex runtime was not reachable, so reviewer must adjudicate.",
        fingerprint="fp-unavail-1",
    )
    result = process_agent_stop(conn, "implementer", project_root)
    assert result["critic_found"] is True
    assert result["critic_verdict"] == "CRITIC_UNAVAILABLE"
    assert result["next_role"] == "reviewer"
    assert result["auto_dispatch"] is True


def test_implementer_critic_retry_limit_escalates_to_reviewer(conn, project_root):
    """Third TRY_AGAIN critic verdict escalates to reviewer adjudication."""
    wf_id = "wf-impl-critic-limit-001"
    lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    _submit_valid_implementer_completion(conn, lease["lease_id"], wf_id, status="complete")
    _submit_critic_review(
        conn, wf_id, "TRY_AGAIN", lease_id="lease-1", fingerprint="fp-limit-1"
    )
    _submit_critic_review(
        conn, wf_id, "TRY_AGAIN", lease_id="lease-2", fingerprint="fp-limit-2"
    )
    _submit_critic_review(
        conn, wf_id, "TRY_AGAIN", lease_id=lease["lease_id"], fingerprint="fp-limit-3"
    )
    result = process_agent_stop(conn, "implementer", project_root)
    assert result["critic_verdict"] == "TRY_AGAIN"
    assert result["critic_escalated"] is True
    assert result["critic_escalation_reason"] == critic_reviews.ESCALATION_RETRY_LIMIT
    assert result["next_role"] == "reviewer"
    assert result["auto_dispatch"] is True


def test_implementer_critic_repeated_fingerprint_escalates_to_reviewer(conn, project_root):
    """Repeated TRY_AGAIN fingerprints escalate to reviewer before infinite looping."""
    from runtime.core import enforcement_config

    wf_id = "wf-impl-critic-fp-001"
    enforcement_config.set_(conn, "critic_retry_limit", "5", actor_role="planner")
    lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    _submit_valid_implementer_completion(conn, lease["lease_id"], wf_id, status="complete")
    _submit_critic_review(
        conn, wf_id, "TRY_AGAIN", lease_id="lease-1", fingerprint="same-fingerprint"
    )
    _submit_critic_review(
        conn, wf_id, "TRY_AGAIN", lease_id=lease["lease_id"], fingerprint="same-fingerprint"
    )
    result = process_agent_stop(conn, "implementer", project_root)
    assert result["critic_escalated"] is True
    assert (
        result["critic_escalation_reason"]
        == critic_reviews.ESCALATION_REPEATED_FINGERPRINT
    )
    assert result["next_role"] == "reviewer"
    assert result["auto_dispatch"] is True


# ---------------------------------------------------------------------------
# tester — retired (Phase 8 Slice 11): not a known runtime role
# ---------------------------------------------------------------------------


def test_tester_stop_does_not_auto_dispatch(conn, project_root):
    """Phase 8 Slice 11: tester is not a known runtime role.
    process_agent_stop(conn, 'tester', ...) must not auto-dispatch to any
    role regardless of whether a lease exists."""
    wf_id = "wf-tester-retired-001"
    _issue_lease_at(conn, "tester", project_root, workflow_id=wf_id)
    result = process_agent_stop(conn, "tester", project_root)
    assert result["next_role"] is None or result["next_role"] == ""
    assert result["auto_dispatch"] is False


def test_tester_stop_does_not_mutate_lease(conn, project_root):
    """Phase 8 Slice 11: tester is not a known runtime role, so
    process_agent_stop(conn, 'tester', ...) takes no routing action and
    therefore does not release the lease — the lease lifecycle is owned by
    known-role branches only."""
    wf_id = "wf-tester-retired-002"
    lease = _issue_lease_at(conn, "tester", project_root, workflow_id=wf_id)
    process_agent_stop(conn, "tester", project_root)
    refreshed = leases.get(conn, lease["lease_id"])
    assert refreshed["status"] == "active"


# ---------------------------------------------------------------------------
# guardian routing via completion record
# ---------------------------------------------------------------------------


def test_guardian_committed_routes_to_planner(conn, project_root):
    """Phase 6 Slice 5: guardian committed → planner (post-guardian continuation)."""
    wf_id = "wf-guardian-001"
    lease = _issue_lease_at(conn, "guardian", project_root, workflow_id=wf_id)
    _submit_valid_guardian_completion(conn, lease["lease_id"], wf_id, verdict="committed")
    result = process_agent_stop(conn, "guardian", project_root)
    assert result["next_role"] == "planner"
    assert result["error"] is None


def test_guardian_denied_routes_to_implementer(conn, project_root):
    """Guardian with 'denied' verdict → implementer."""
    wf_id = "wf-guardian-002"
    lease = _issue_lease_at(conn, "guardian", project_root, workflow_id=wf_id)
    _submit_valid_guardian_completion(conn, lease["lease_id"], wf_id, verdict="denied")
    result = process_agent_stop(conn, "guardian", project_root)
    assert result["next_role"] == "implementer"
    assert result["error"] is None


def test_guardian_merged_routes_to_planner(conn, project_root):
    """Phase 6 Slice 5: guardian merged → planner (post-guardian continuation)."""
    wf_id = "wf-guardian-003"
    lease = _issue_lease_at(conn, "guardian", project_root, workflow_id=wf_id)
    _submit_valid_guardian_completion(conn, lease["lease_id"], wf_id, verdict="merged")
    result = process_agent_stop(conn, "guardian", project_root)
    assert result["next_role"] == "planner"
    assert result["error"] is None


def test_guardian_pushed_routes_to_planner(conn, project_root):
    """Guardian pushed → planner (post-guardian continuation)."""
    wf_id = "wf-guardian-push-001"
    lease = _issue_lease_at(conn, "guardian", project_root, workflow_id=wf_id)
    _submit_valid_guardian_completion(conn, lease["lease_id"], wf_id, verdict="pushed")
    result = process_agent_stop(conn, "guardian", project_root)
    assert result["next_role"] == "planner"
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


def test_guardian_lease_released_after_routing(conn, project_root):
    wf_id = "wf-release-002"
    lease = _issue_lease_at(conn, "guardian", project_root, workflow_id=wf_id)
    _submit_valid_guardian_completion(conn, lease["lease_id"], wf_id)
    process_agent_stop(conn, "guardian", project_root)
    refreshed = leases.get(conn, lease["lease_id"])
    assert refreshed["status"] == "released"


def test_implementer_lease_released_after_routing(conn, project_root):
    """Implementer lease is released after critic-driven routing is resolved."""
    wf_id = "wf-release-impl-001"
    lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    _submit_valid_implementer_completion(conn, lease["lease_id"], wf_id, status="complete")
    _submit_critic_review(
        conn,
        wf_id,
        "READY_FOR_REVIEWER",
        lease_id=lease["lease_id"],
        fingerprint="fp-release-impl",
    )
    process_agent_stop(conn, "implementer", project_root)
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
    """Planner (next_work_item) → suggestion must mention guardian."""
    wf_id = "wf-sug-planner-001"
    _insert_goal(conn, wf_id)
    lease = _issue_lease_at(conn, "planner", project_root, workflow_id=wf_id)
    _submit_valid_planner_completion(conn, lease["lease_id"], wf_id)
    result = process_agent_stop(conn, "planner", project_root)
    assert "guardian" in result["suggestion"]


def test_guardian_committed_suggestion_auto_dispatch_planner(conn, project_root):
    """Phase 6 Slice 5: guardian committed → suggestion starts with AUTO_DISPATCH: planner."""
    wf_id = "wf-sug-001"
    lease = _issue_lease_at(conn, "guardian", project_root, workflow_id=wf_id)
    _submit_valid_guardian_completion(conn, lease["lease_id"], wf_id, verdict="committed")
    result = process_agent_stop(conn, "guardian", project_root)
    assert result["next_role"] == "planner"
    assert result["suggestion"].startswith("AUTO_DISPATCH: planner")


# ---------------------------------------------------------------------------
# Compound integration: neutralized tester production sequence (Phase 5)
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


def _submit_critic_review(
    conn,
    workflow_id,
    verdict,
    *,
    lease_id="",
    summary="critic summary",
    detail="critic detail",
    fingerprint="fp-default",
    metadata=None,
):
    return critic_reviews.submit(
        conn,
        workflow_id=workflow_id,
        lease_id=lease_id,
        verdict=verdict,
        provider="codex",
        summary=summary,
        detail=detail,
        fingerprint=fingerprint,
        metadata=metadata or {},
    )


def test_implementer_valid_contract_emits_agent_complete(conn, project_root):
    """Valid IMPL_STATUS=complete contract → agent_complete event, routing → reviewer."""
    wf_id = "wf-impl-contract-001"
    lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    _submit_valid_implementer_completion(conn, lease["lease_id"], wf_id, status="complete")
    result = process_agent_stop(conn, "implementer", project_root)
    assert result["next_role"] == "reviewer"
    assert result["error"] is None
    complete_events = [e for e in result["events"] if e["type"] == "agent_complete"]
    assert len(complete_events) >= 1


def test_implementer_partial_contract_emits_agent_stopped(conn, project_root):
    """Valid IMPL_STATUS=partial contract → agent_stopped event, routing still → reviewer."""
    wf_id = "wf-impl-contract-002"
    lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    _submit_valid_implementer_completion(conn, lease["lease_id"], wf_id, status="partial")
    result = process_agent_stop(conn, "implementer", project_root)
    assert result["next_role"] == "reviewer"
    stopped_events = [e for e in result["events"] if e["type"] == "agent_stopped"]
    assert len(stopped_events) >= 1


def test_implementer_blocked_contract_emits_agent_stopped(conn, project_root):
    """Valid IMPL_STATUS=blocked contract → agent_stopped event, routing still → reviewer."""
    wf_id = "wf-impl-contract-003"
    lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    _submit_valid_implementer_completion(conn, lease["lease_id"], wf_id, status="blocked")
    result = process_agent_stop(conn, "implementer", project_root)
    assert result["next_role"] == "reviewer"
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
    assert result["next_role"] == "reviewer"  # routing unchanged
    invalid_events = [e for e in result["events"] if e["type"] == "impl_contract_invalid"]
    assert len(invalid_events) >= 1


def test_implementer_contract_uses_lease_workflow_id(conn, project_root):
    """Contract is read under the lease workflow_id, result carries that id."""
    wf_id = "wf-impl-lease-001"
    lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    _submit_valid_implementer_completion(conn, lease["lease_id"], wf_id, status="complete")
    result = process_agent_stop(conn, "implementer", project_root)
    assert result["workflow_id"] == wf_id
    assert result["next_role"] == "reviewer"
    complete_events = [e for e in result["events"] if e["type"] == "agent_complete"]
    assert len(complete_events) >= 1


def test_implementer_no_trailers_heuristic_fallback(conn, project_root):
    """Implementer with lease but no completion record → heuristic fallback (advisory).

    When no IMPL_STATUS/IMPL_HEAD_SHA trailers are present the check-implementer.sh
    Check 8 submits nothing. dispatch_engine finds no completion record for the lease
    and falls through to the heuristic (DEC-IMPL-CONTRACT-001). Routing is still
    → reviewer (unchanged). No impl_contract_invalid event is emitted because there
    is nothing malformed — there is simply no record.

    This is the backward-compatibility path: old implementers that predate the
    structured contract produce no record and the heuristic governs instead.
    """
    wf_id = "wf-impl-no-trailers-001"
    _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    # No completion record submitted — simulates missing trailers.
    result = process_agent_stop(conn, "implementer", project_root)
    assert result["next_role"] == "reviewer"
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
      6. Routing → reviewer (Phase 5: implementer routes to reviewer, not tester).
      7. auto_dispatch=True because not interrupted.

    Domain boundaries crossed: leases / completions (evaluation no longer written here).
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

    # Step 6: routing → reviewer (Phase 5)
    assert result["next_role"] == "reviewer"
    assert result["error"] is None
    assert result["workflow_id"] == wf_id

    # Step 5: contract overrides heuristic → agent_complete (not agent_stopped)
    complete_events = [e for e in result["events"] if e["type"] == "agent_complete"]
    assert len(complete_events) >= 1
    stopped_events = [e for e in result["events"] if e["type"] == "agent_stopped"]
    assert len(stopped_events) == 0

    # Step 7: auto_dispatch=True
    assert result["auto_dispatch"] is True
    assert result["suggestion"].startswith("AUTO_DISPATCH: reviewer")


def test_full_tester_role_retired_production_sequence(conn, project_root):
    """Phase 8 Slice 11: tester is not a known runtime role.

    Legacy compound test converted from the pre-Phase-5 tester→guardian
    production sequence. After Bundle 2, a completion submit with
    role='tester' returns role_not_enforced; the stop releases the lease
    and does not auto-dispatch.
    """
    wf_id = "wf-compound-001"

    # Step 1: issue lease with worktree_path = project_root (production model)
    lease = _issue_lease_at(conn, "tester", project_root, workflow_id=wf_id)
    assert lease["status"] == "active"

    # Step 2: attempt to submit a tester completion — must be rejected as
    # role_not_enforced because tester is no longer a known schema.
    comp_result = completions.submit(
        conn,
        lease_id=lease["lease_id"],
        workflow_id=wf_id,
        role="tester",
        payload={
            "EVAL_VERDICT": "ready_for_guardian",
            "EVAL_TESTS_PASS": "yes",
            "EVAL_NEXT_ROLE": "guardian",
            "EVAL_HEAD_SHA": "abc123",
        },
    )
    assert comp_result["valid"] is False
    assert "role_not_enforced" in comp_result["missing_fields"]

    # Step 3: process_agent_stop — tester is unknown in Phase 8 Slice 11
    result = process_agent_stop(conn, "tester", project_root)

    # Tester does not route — next_role is None, no auto-dispatch
    assert result["next_role"] is None or result["next_role"] == ""
    assert result["auto_dispatch"] is False

    # Lease remains active because no known-role branch handled the stop
    refreshed = leases.get(conn, lease["lease_id"])
    assert refreshed["status"] == "active"


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
    """Planner (next_work_item) → auto_dispatch=True, next_role=guardian."""
    wf_id = "wf-ad-planner-001"
    _insert_goal(conn, wf_id)
    lease = _issue_lease_at(conn, "planner", project_root, workflow_id=wf_id)
    _submit_valid_planner_completion(conn, lease["lease_id"], wf_id)
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
    assert result["next_role"] == "reviewer"
    assert result["error"] is None


def test_implementer_stop_interrupted_no_auto_dispatch(conn, project_root):
    """Implementer stop with IMPL_STATUS=partial (interrupted) → auto_dispatch=False."""
    wf_id = "wf-ad-impl-002"
    lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    # partial verdict → is_interrupted = True via contract override
    _submit_valid_implementer_completion(conn, lease["lease_id"], wf_id, status="partial")
    result = process_agent_stop(conn, "implementer", project_root)
    assert result["auto_dispatch"] is False
    assert result["next_role"] == "reviewer"  # routing unchanged


def test_tester_never_auto_dispatches_after_slice_11(conn, project_root):
    """Phase 8 Slice 11: tester is not a known runtime role. No matter what
    payload accompanies the stop, process_agent_stop must not auto-dispatch."""
    wf_id = "wf-ad-tester-unknown"
    _issue_lease_at(conn, "tester", project_root, workflow_id=wf_id)
    result = process_agent_stop(conn, "tester", project_root)
    assert result["auto_dispatch"] is False
    assert result["next_role"] is None or result["next_role"] == ""


def test_guardian_committed_auto_dispatch_to_planner(conn, project_root):
    """Phase 6 Slice 5: guardian committed → auto_dispatch=True, next_role=planner."""
    wf_id = "wf-ad-guardian-001"
    lease = _issue_lease_at(conn, "guardian", project_root, workflow_id=wf_id)
    _submit_valid_guardian_completion(conn, lease["lease_id"], wf_id, verdict="committed")
    result = process_agent_stop(conn, "guardian", project_root)
    assert result["auto_dispatch"] is True
    assert result["next_role"] == "planner"
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
    """Routing error (no lease for reviewer) → auto_dispatch=False."""
    # No lease → PROCESS ERROR for reviewer
    result = process_agent_stop(conn, "reviewer", project_root)
    assert result["auto_dispatch"] is False
    assert result["error"] is not None
    assert "PROCESS ERROR" in result["error"]


def test_suggestion_auto_dispatch_prefix(conn, project_root):
    """When auto_dispatch=True, suggestion starts with 'AUTO_DISPATCH: '."""
    wf_id = "wf-sug-ad-001"
    _insert_goal(conn, wf_id)
    lease = _issue_lease_at(conn, "planner", project_root, workflow_id=wf_id)
    _submit_valid_planner_completion(conn, lease["lease_id"], wf_id)
    result = process_agent_stop(conn, "planner", project_root)
    assert result["auto_dispatch"] is True
    assert result["suggestion"].startswith("AUTO_DISPATCH: ")


def test_suggestion_canonical_prefix_when_false(conn, project_root):
    """When auto_dispatch=False and non-terminal (interrupted impl), suggestion format unchanged.

    For the interrupted implementer case: auto_dispatch=False and next_role=reviewer,
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
    """Compound-interaction test: full planner→guardian→impl→reviewer→guardian chain
    verifying auto_dispatch at each transition boundary.

    W-GWT-1: planner now routes to guardian (provision mode), not implementer directly.
    Phase 5: implementer routes to reviewer, tester is no longer in the live chain.

    Production sequence exercised:
      planner stop → auto_dispatch=True (guardian suggested, mode=provision)
      implementer stop (complete) → auto_dispatch=True (reviewer suggested)
      reviewer stop (ready_for_guardian) → auto_dispatch=True (guardian suggested)
      guardian stop (committed) → auto_dispatch=True (planner, post-guardian continuation)
    """
    wf_id = "wf-ad-cycle-001"
    _insert_goal(conn, wf_id)

    # --- Planner stop → guardian (Phase 6 Slice 4: completion-driven) ---
    planner_lease = _issue_lease_at(conn, "planner", project_root, workflow_id=wf_id)
    _submit_valid_planner_completion(conn, planner_lease["lease_id"], wf_id)
    r_planner = process_agent_stop(conn, "planner", project_root)
    assert r_planner["auto_dispatch"] is True
    assert r_planner["next_role"] == "guardian"
    assert r_planner["suggestion"].startswith("AUTO_DISPATCH: guardian")

    # --- Implementer stop (complete contract) → reviewer (Phase 5) ---
    impl_lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    _submit_valid_implementer_completion(conn, impl_lease["lease_id"], wf_id, status="complete")
    r_impl = process_agent_stop(conn, "implementer", project_root)
    assert r_impl["auto_dispatch"] is True
    assert r_impl["next_role"] == "reviewer"
    assert r_impl["suggestion"].startswith("AUTO_DISPATCH: reviewer")

    # --- Reviewer stop (ready_for_guardian) → guardian ---
    reviewer_lease = _issue_lease_at(conn, "reviewer", project_root, workflow_id=wf_id)
    _submit_valid_reviewer_completion(conn, reviewer_lease["lease_id"], wf_id)
    r_reviewer = process_agent_stop(conn, "reviewer", project_root)
    assert r_reviewer["auto_dispatch"] is True
    assert r_reviewer["next_role"] == "guardian"
    assert r_reviewer["suggestion"].startswith("AUTO_DISPATCH: guardian")

    # --- Guardian stop (committed → planner, Phase 6 Slice 5) ---
    guardian_lease = _issue_lease_at(conn, "guardian", project_root, workflow_id=wf_id)
    _submit_valid_guardian_completion(conn, guardian_lease["lease_id"], wf_id, verdict="committed")
    r_guardian = process_agent_stop(conn, "guardian", project_root)
    assert r_guardian["auto_dispatch"] is True
    assert r_guardian["next_role"] == "planner"
    assert r_guardian["suggestion"].startswith("AUTO_DISPATCH: planner")


# ---------------------------------------------------------------------------
# DEC-PHASE5-STOP-REVIEW-SEPARATION-001: Stop-review gate is non-authoritative
# for workflow dispatch. These tests prove that codex_stop_review events cannot
# affect workflow routing or auto_dispatch decisions.
# ---------------------------------------------------------------------------


def test_stop_review_block_does_not_affect_auto_dispatch(conn, project_root):
    """Separation invariant: a recent BLOCK codex_stop_review event leaves
    auto_dispatch=True for a clear workflow transition.

    This is the primary proof point for DEC-PHASE5-STOP-REVIEW-SEPARATION-001.
    Uses implementer (complete contract) as the clean auto-dispatch case.
    """
    from runtime.core import events as ev

    wf_id = "wf-sep-ad-001"
    lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    _submit_valid_implementer_completion(conn, lease["lease_id"], wf_id, status="complete")
    ev.emit(
        conn,
        type="codex_stop_review",
        source=f"workflow:{wf_id}",
        detail=f"VERDICT: BLOCK — workflow={wf_id} | Insufficient test coverage",
    )
    result = process_agent_stop(conn, "implementer", project_root)
    # auto_dispatch must be True — stop-review cannot override it
    assert result["auto_dispatch"] is True
    assert result["next_role"] == "reviewer"
    assert result["error"] is None
    # codex_blocked must not be present in result
    assert "codex_blocked" not in result
    assert "codex_reason" not in result
    # Suggestion must NOT contain CODEX BLOCK
    assert "CODEX BLOCK" not in result["suggestion"]


def test_stop_review_block_does_not_affect_next_role(conn, project_root):
    """Separation invariant: codex_stop_review BLOCK cannot change next_role.

    Exercises implementer→reviewer transition with a BLOCK event present.
    """
    from runtime.core import events as ev

    wf_id = "wf-sep-impl-001"
    lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    _submit_valid_implementer_completion(conn, lease["lease_id"], wf_id, status="complete")

    ev.emit(
        conn,
        type="codex_stop_review",
        source=f"workflow:{wf_id}",
        detail=f"VERDICT: BLOCK — workflow={wf_id} | review concern",
    )
    result = process_agent_stop(conn, "implementer", project_root)
    # next_role must be reviewer regardless of stop-review event
    assert result["next_role"] == "reviewer"
    assert result["auto_dispatch"] is True
    assert result["error"] is None


def test_stop_review_allow_does_not_affect_dispatch(conn, project_root):
    """Separation invariant: ALLOW codex_stop_review has no effect on dispatch.

    Uses implementer (complete contract) as the clean auto-dispatch case.
    """
    from runtime.core import events as ev

    wf_id = "wf-sep-allow-001"
    lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    _submit_valid_implementer_completion(conn, lease["lease_id"], wf_id, status="complete")
    ev.emit(
        conn,
        type="codex_stop_review",
        source=f"workflow:{wf_id}",
        detail=f"VERDICT: ALLOW — workflow={wf_id} | work looks good",
    )
    result = process_agent_stop(conn, "implementer", project_root)
    assert result["auto_dispatch"] is True
    assert result["next_role"] == "reviewer"
    assert "codex_blocked" not in result


def test_stop_review_absent_dispatch_unchanged(conn, project_root):
    """Separation invariant: absence of codex_stop_review events has no effect.

    Uses implementer (complete contract) as the clean auto-dispatch case.
    """
    wf_id = "wf-sep-absent-001"
    lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    _submit_valid_implementer_completion(conn, lease["lease_id"], wf_id, status="complete")
    result = process_agent_stop(conn, "implementer", project_root)
    assert result["auto_dispatch"] is True
    assert result["next_role"] == "reviewer"
    assert result["error"] is None
    assert "codex_blocked" not in result


def test_stop_review_result_has_no_codex_fields(conn, project_root):
    """Separation invariant: process_agent_stop result dict does not contain
    codex_blocked or codex_reason fields.

    Uses implementer (complete contract) as the clean auto-dispatch case.
    """
    from runtime.core import events as ev

    wf_id = "wf-sep-nofields-001"
    lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    _submit_valid_implementer_completion(conn, lease["lease_id"], wf_id, status="complete")
    ev.emit(
        conn,
        type="codex_stop_review",
        source=f"workflow:{wf_id}",
        detail=f"VERDICT: BLOCK — workflow={wf_id} | should be invisible",
    )
    result = process_agent_stop(conn, "implementer", project_root)
    assert "codex_blocked" not in result, "codex_blocked must not appear in result"
    assert "codex_reason" not in result, "codex_reason must not appear in result"


def test_stop_review_block_on_error_path_still_no_effect(conn, project_root):
    """Separation invariant: BLOCK + error path → no codex fields, error is from routing."""
    from runtime.core import events as ev

    wf_id = current_workflow_id(project_root)
    ev.emit(
        conn,
        type="codex_stop_review",
        source=_codex_workflow_source(project_root),
        detail=f"VERDICT: BLOCK — workflow={wf_id} | test reason",
    )
    # Reviewer with no lease → PROCESS ERROR
    result = process_agent_stop(conn, "reviewer", project_root)
    assert result["auto_dispatch"] is False
    assert result["error"] is not None
    assert "PROCESS ERROR" in result["error"]
    assert "codex_blocked" not in result


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
    """Planner (next_work_item) sets guardian_mode='provision' in result."""
    wf_id = "wf-gwt-planner-mode-001"
    _insert_goal(conn, wf_id)
    lease = _issue_lease_at(conn, "planner", project_root, workflow_id=wf_id)
    _submit_valid_planner_completion(conn, lease["lease_id"], wf_id)
    result = process_agent_stop(conn, "planner", project_root)
    assert result.get("guardian_mode") == "provision"


def test_planner_auto_dispatch_to_guardian(conn, project_root):
    """Planner (next_work_item) → auto_dispatch=True, suggestion starts AUTO_DISPATCH: guardian."""
    wf_id = "wf-gwt-planner-ad-001"
    _insert_goal(conn, wf_id)
    lease = _issue_lease_at(conn, "planner", project_root, workflow_id=wf_id)
    _submit_valid_planner_completion(conn, lease["lease_id"], wf_id)
    result = process_agent_stop(conn, "planner", project_root)
    assert result["auto_dispatch"] is True
    assert result["suggestion"].startswith("AUTO_DISPATCH: guardian")


def test_planner_suggestion_encodes_mode(conn, project_root):
    """Planner AUTO_DISPATCH suggestion encodes mode=provision."""
    wf_id = "wf-gwt-planner-enc-001"
    _insert_goal(conn, wf_id)
    lease = _issue_lease_at(conn, "planner", project_root, workflow_id=wf_id)
    _submit_valid_planner_completion(conn, lease["lease_id"], wf_id)
    result = process_agent_stop(conn, "planner", project_root)
    assert "mode=provision" in result["suggestion"]


def test_planner_with_lease_resolves_workflow_id(conn, project_root):
    """When planner has an active lease, workflow_id is resolved from it."""
    wf_id = "wf-gwt-planner-lease-001"
    _insert_goal(conn, wf_id)
    lease = _issue_lease_at(conn, "planner", project_root, workflow_id=wf_id)
    _submit_valid_planner_completion(conn, lease["lease_id"], wf_id)
    result = process_agent_stop(conn, "planner", project_root)
    assert result["next_role"] == "guardian"
    assert result["workflow_id"] == wf_id
    assert result.get("guardian_mode") == "provision"


def test_planner_suggestion_encodes_workflow_id_when_known(conn, project_root):
    """When workflow_id is resolved at planner stop, suggestion encodes it."""
    wf_id = "wf-gwt-planner-wf-001"
    _insert_goal(conn, wf_id)
    lease = _issue_lease_at(conn, "planner", project_root, workflow_id=wf_id)
    _submit_valid_planner_completion(conn, lease["lease_id"], wf_id)
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


def test_tester_with_bound_workflow_still_no_routing(conn, project_root):
    """Phase 8 Slice 11: even with a bound workflow worktree, a tester stop
    does not route — tester is not a known runtime role."""
    from runtime.core import workflows

    wf_id = "wf-gwt-nc-wt-001"
    worktree = "/some/project/.worktrees/feature-impl-001"
    workflows.bind_workflow(
        conn,
        workflow_id=wf_id,
        worktree_path=worktree,
        branch="feature/impl-001",
    )
    _issue_lease_at(conn, "tester", project_root, workflow_id=wf_id)
    result = process_agent_stop(conn, "tester", project_root)
    # Tester is retired — no routing, no auto-dispatch
    assert result["next_role"] is None or result["next_role"] == ""
    assert result["auto_dispatch"] is False


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
    _insert_goal(conn, wf_id)
    worktree = "/some/project/.worktrees/feature-gwt-chain"

    # Step 1: Planner stop → routes to guardian (Phase 6 Slice 4: completion-driven)
    planner_lease = _issue_lease_at(conn, "planner", project_root, workflow_id=wf_id)
    _submit_valid_planner_completion(conn, planner_lease["lease_id"], wf_id)
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


# ---------------------------------------------------------------------------
# Phase 4: Reviewer routing via completion record
# ---------------------------------------------------------------------------


def _submit_valid_reviewer_completion(
    conn,
    lease_id,
    workflow_id,
    verdict="ready_for_guardian",
    *,
    head_sha="sha-reviewer-001",
    findings=None,
):
    """Submit a valid reviewer completion with the three required fields."""
    if findings is None:
        findings = [
            {"severity": "note", "title": "Minor style", "detail": "Nit pick"},
        ]
    return completions.submit(
        conn,
        lease_id=lease_id,
        workflow_id=workflow_id,
        role="reviewer",
        payload={
            "REVIEW_VERDICT": verdict,
            "REVIEW_HEAD_SHA": head_sha,
            "REVIEW_FINDINGS_JSON": json.dumps({"findings": findings}),
        },
    )


def test_reviewer_ready_for_guardian_routes_to_guardian(conn, project_root):
    """Reviewer (ready_for_guardian) → guardian via _route_from_completion."""
    wf_id = "wf-reviewer-001"
    lease = _issue_lease_at(conn, "reviewer", project_root, workflow_id=wf_id)
    _submit_valid_reviewer_completion(
        conn,
        lease["lease_id"],
        wf_id,
        verdict="ready_for_guardian",
        head_sha="sha-ready-001",
    )
    result = process_agent_stop(conn, "reviewer", project_root)
    assert result["next_role"] == "guardian"
    assert result["error"] is None
    assert result["auto_dispatch"] is True
    assert result["suggestion"].startswith("AUTO_DISPATCH: guardian")
    state = evaluation.get(conn, wf_id)
    assert state is not None
    assert state["status"] == "ready_for_guardian"
    assert state["head_sha"] == "sha-ready-001"


def test_reviewer_ready_with_blocking_findings_fails_closed(conn, project_root):
    """Reviewer cannot route Guardian when ready verdict has open blocking findings."""
    wf_id = "wf-reviewer-ready-blocking-001"
    lease = _issue_lease_at(conn, "reviewer", project_root, workflow_id=wf_id)
    _submit_valid_reviewer_completion(
        conn,
        lease["lease_id"],
        wf_id,
        verdict="ready_for_guardian",
        head_sha="sha-ready-blocking-001",
        findings=[
            {
                "severity": "blocking",
                "title": "Blocking issue",
                "detail": "This must prevent Guardian landing.",
            },
        ],
    )
    result = process_agent_stop(conn, "reviewer", project_root)
    assert result["next_role"] is None
    assert result["auto_dispatch"] is False
    assert "readiness did not converge" in result["error"]
    state = evaluation.get(conn, wf_id)
    assert state is not None
    assert state["status"] == "needs_changes"
    assert state["head_sha"] == "sha-ready-blocking-001"
    assert state["blockers"] == 1


def test_reviewer_needs_changes_routes_to_implementer_with_worktree(conn, project_root):
    """Reviewer (needs_changes) → implementer with worktree_path from workflow_bindings."""
    from runtime.core import workflows

    wf_id = "wf-reviewer-nc-001"
    worktree = "/some/project/.worktrees/feature-reviewer-nc"
    workflows.bind_workflow(
        conn,
        workflow_id=wf_id,
        worktree_path=worktree,
        branch="feature/reviewer-nc",
    )
    lease = _issue_lease_at(conn, "reviewer", project_root, workflow_id=wf_id)
    _submit_valid_reviewer_completion(conn, lease["lease_id"], wf_id, verdict="needs_changes")
    result = process_agent_stop(conn, "reviewer", project_root)
    assert result["next_role"] == "implementer"
    assert result["error"] is None
    assert result["auto_dispatch"] is True
    assert result.get("worktree_path") == worktree
    assert worktree in result["suggestion"]
    state = evaluation.get(conn, wf_id)
    assert state is not None
    assert state["status"] == "needs_changes"


def test_reviewer_needs_changes_no_binding_still_routes(conn, project_root):
    """Reviewer (needs_changes) routes correctly even without a workflow binding."""
    wf_id = "wf-reviewer-nc-nobind-001"
    lease = _issue_lease_at(conn, "reviewer", project_root, workflow_id=wf_id)
    _submit_valid_reviewer_completion(conn, lease["lease_id"], wf_id, verdict="needs_changes")
    result = process_agent_stop(conn, "reviewer", project_root)
    assert result["next_role"] == "implementer"
    assert result["error"] is None
    assert result.get("worktree_path", "") == ""


def test_reviewer_blocked_by_plan_routes_to_planner(conn, project_root):
    """Reviewer (blocked_by_plan) → planner via _route_from_completion."""
    wf_id = "wf-reviewer-bp-001"
    lease = _issue_lease_at(conn, "reviewer", project_root, workflow_id=wf_id)
    _submit_valid_reviewer_completion(conn, lease["lease_id"], wf_id, verdict="blocked_by_plan")
    result = process_agent_stop(conn, "reviewer", project_root)
    assert result["next_role"] == "planner"
    assert result["error"] is None
    assert result["auto_dispatch"] is True
    state = evaluation.get(conn, wf_id)
    assert state is not None
    assert state["status"] == "blocked_by_plan"


def test_reviewer_no_completion_record_returns_error(conn, project_root):
    """Reviewer with lease but no completion record → PROCESS ERROR (same as tester)."""
    wf_id = "wf-reviewer-nocomp-001"
    _issue_lease_at(conn, "reviewer", project_root, workflow_id=wf_id)
    result = process_agent_stop(conn, "reviewer", project_root)
    assert result["error"] is not None
    assert "PROCESS ERROR" in result["error"]
    assert result["next_role"] is None or result["next_role"] == ""


def test_reviewer_invalid_completion_returns_error(conn, project_root):
    """Reviewer completion with invalid verdict → PROCESS ERROR."""
    wf_id = "wf-reviewer-invalid-001"
    lease = _issue_lease_at(conn, "reviewer", project_root, workflow_id=wf_id)
    completions.submit(
        conn,
        lease_id=lease["lease_id"],
        workflow_id=wf_id,
        role="reviewer",
        payload={"REVIEW_VERDICT": "bogus_verdict"},
    )
    result = process_agent_stop(conn, "reviewer", project_root)
    assert result["error"] is not None
    assert "PROCESS ERROR" in result["error"]


def test_reviewer_no_lease_returns_error(conn, project_root):
    """Reviewer without a lease → PROCESS ERROR."""
    result = process_agent_stop(conn, "reviewer", project_root)
    assert result["error"] is not None
    assert "PROCESS ERROR" in result["error"]


def test_reviewer_lease_released_after_routing(conn, project_root):
    """Lease must be status='released' after reviewer process_agent_stop completes."""
    wf_id = "wf-reviewer-release-001"
    lease = _issue_lease_at(conn, "reviewer", project_root, workflow_id=wf_id)
    _submit_valid_reviewer_completion(conn, lease["lease_id"], wf_id)
    process_agent_stop(conn, "reviewer", project_root)
    refreshed = leases.get(conn, lease["lease_id"])
    assert refreshed["status"] == "released"


def test_implementer_routes_to_reviewer_phase5(conn, project_root):
    """Phase 5: implementer routes to reviewer (was tester before Phase 5)."""
    wf_id = "wf-regression-impl-001"
    lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf_id)
    _submit_valid_implementer_completion(conn, lease["lease_id"], wf_id, status="complete")
    result = process_agent_stop(conn, "implementer", project_root)
    assert result["next_role"] == "reviewer"
    assert result["error"] is None
