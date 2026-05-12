"""Tests for dispatch_engine critic routing — DEC-CRITIC-CONTEXT-001, DEC-CRITIC-BLOCKED-002.

These tests exercise the dispatch_engine.process_agent_stop path for an implementer stop,
specifically:
  1. When a TRY_AGAIN critic_reviews row exists for the correct workflow_id,
     dispatch_engine returns next_role="implementer".
  2. When critic_enabled=True and no critic_reviews row exists,
     dispatch_engine returns next_role=None and error includes "PROCESS ERROR: implementer critic did not run."

Production sequence (test 1):
  implementer-critic.sh runs Codex → persists critic_reviews row with
  verdict=TRY_AGAIN → post-task.sh calls dispatch process-stop →
  dispatch_engine.assess_latest reads the row → returns next_role="implementer" →
  suggestion contains AUTO_DISPATCH: implementer.

Production sequence (test 2):
  critic_enabled=True but critic_reviews has no row for this workflow_id
  (hook crashed or wrong workflow_id written) → dispatch_engine returns
  next_role=None, error="PROCESS ERROR: implementer critic did not run." →
  suggestion contains BLOCKED: and PROCESS ERROR.

Real SQLite; no subprocess mocking.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_REPO_ROOT))

from runtime.core.db import connect
from runtime.schemas import ensure_schema
import runtime.core.leases as leases_mod
import runtime.core.completions as completions_mod
import runtime.core.critic_reviews as critic_reviews_mod
import runtime.core.enforcement_config as enforcement_config_mod
import runtime.core.dispatch_engine as dispatch_engine_mod


@pytest.fixture
def db(tmp_path):
    conn = connect(tmp_path / "state.db")
    ensure_schema(conn)
    yield conn
    conn.close()


def _issue_impl_lease(conn, workflow_id: str, project_root: str) -> dict:
    return leases_mod.issue(
        conn,
        role="implementer",
        worktree_path=project_root,
        workflow_id=workflow_id,
    )


def _submit_completion(conn, workflow_id: str, lease_id: str, verdict: str) -> None:
    completions_mod.submit(
        conn,
        lease_id=lease_id,
        workflow_id=workflow_id,
        role="implementer",
        payload={
            "IMPL_STATUS": "complete" if verdict == "READY_FOR_REVIEWER" else "partial",
            "IMPL_RESULT": verdict,
        },
    )


def _submit_critic_review(conn, workflow_id: str, lease_id: str, verdict: str) -> dict:
    """Submit a critic review with a test execution proof so it's routable."""
    metadata = {
        "execution_proof": {
            "provider": "test",
            "test_override": True,
            "parsed_structured_output_present": True,
        }
    }
    return critic_reviews_mod.submit(
        conn,
        workflow_id=workflow_id,
        lease_id=lease_id,
        verdict=verdict,
        summary="Test critic summary.",
        detail="Test critic detail.",
        metadata=metadata,
    )


def _enable_critic(conn, workflow_id: str, project_root: str) -> None:
    """Ensure critic_enabled_implementer_stop=true (it defaults to true, but be explicit)."""
    enforcement_config_mod.set_(
        conn,
        "critic_enabled_implementer_stop",
        "true",
        scope=f"workflow={workflow_id}",
        actor_role="planner",
    )


def _disable_critic(conn, workflow_id: str, project_root: str) -> None:
    enforcement_config_mod.set_(
        conn,
        "critic_enabled_implementer_stop",
        "false",
        scope=f"workflow={workflow_id}",
        actor_role="planner",
    )


# ---------------------------------------------------------------------------
# Test 1: TRY_AGAIN critic row routes back to implementer
# ---------------------------------------------------------------------------


def test_dispatch_engine_routes_try_again_back_to_implementer(db, tmp_path):
    """dispatch_engine.process_agent_stop returns next_role="implementer" for TRY_AGAIN.

    Compound-interaction: lease → completion → critic_review → dispatch_engine
    routing. All four components interact via real SQLite. This exercises the
    production sequence of what happens after Codex returns TRY_AGAIN.

    The dispatch_engine MUST read the critic_reviews row (not the completion
    record's verdict) when critic_enabled=True.
    """
    project_root = str(tmp_path / "feature-worktree")
    workflow_id = "wf-critic-try-again-001"

    # Issue implementer lease
    lease = _issue_impl_lease(db, workflow_id, project_root)
    lease_id = lease["lease_id"]

    # Implementer submits a completion claiming READY_FOR_REVIEWER
    _submit_completion(db, workflow_id, lease_id, "READY_FOR_REVIEWER")

    # Critic disagrees: TRY_AGAIN (with valid test proof so it's routable)
    _submit_critic_review(db, workflow_id, lease_id, "TRY_AGAIN")

    # Ensure critic is enabled
    _enable_critic(db, workflow_id, project_root)

    # Run dispatch_engine
    result = dispatch_engine_mod.process_agent_stop(db, "implementer", project_root)

    assert result["next_role"] == "implementer", (
        f"Expected next_role='implementer' for TRY_AGAIN critic verdict, "
        f"got {result['next_role']!r}. error={result.get('error')!r}"
    )
    assert result["error"] is None, (
        f"Expected no error for TRY_AGAIN routing, got: {result['error']!r}"
    )
    assert result.get("critic_verdict") == "TRY_AGAIN", (
        f"Expected critic_verdict='TRY_AGAIN', got {result.get('critic_verdict')!r}"
    )
    assert result.get("critic_found") is True, (
        "Expected critic_found=True"
    )
    # auto_dispatch should be True (uninterrupted, critic found, next_role set)
    assert result.get("auto_dispatch") is True, (
        f"Expected auto_dispatch=True for TRY_AGAIN routing, got {result.get('auto_dispatch')!r}"
    )
    # Suggestion must contain AUTO_DISPATCH: implementer
    suggestion = str(result.get("suggestion") or "")
    assert "AUTO_DISPATCH: implementer" in suggestion, (
        f"Expected suggestion to contain 'AUTO_DISPATCH: implementer', got: {suggestion!r}"
    )


# ---------------------------------------------------------------------------
# Test 2: critic_enabled=True but no critic row → PROCESS ERROR + BLOCKED
# ---------------------------------------------------------------------------


def test_dispatch_engine_blocks_when_critic_missing(db, tmp_path):
    """dispatch_engine.process_agent_stop returns PROCESS ERROR when critic_enabled and no row.

    When critic_enabled=True and there is no critic_reviews row for the resolved
    workflow_id, the dispatch_engine must return next_role=None and
    error="PROCESS ERROR: implementer critic did not run."

    The suggestion must also contain a 'BLOCKED:' marker on its own line so the
    orchestrator's chain-stop rule fires even when the implementer itself emitted
    READY_FOR_REVIEWER in its response text (DEC-CRITIC-BLOCKED-002).
    """
    project_root = str(tmp_path / "feature-worktree")
    workflow_id = "wf-critic-missing-001"

    # Issue implementer lease
    lease = _issue_impl_lease(db, workflow_id, project_root)
    lease_id = lease["lease_id"]

    # Implementer says it's done but critic never ran
    _submit_completion(db, workflow_id, lease_id, "READY_FOR_REVIEWER")

    # Ensure critic is enabled (default is true, but be explicit)
    _enable_critic(db, workflow_id, project_root)

    # Run dispatch_engine — no critic_reviews row exists
    result = dispatch_engine_mod.process_agent_stop(db, "implementer", project_root)

    assert result["next_role"] is None, (
        f"Expected next_role=None when critic_enabled and no critic row, "
        f"got {result['next_role']!r}"
    )
    assert result["error"] is not None, "Expected an error when critic is missing"
    assert "PROCESS ERROR: implementer critic did not run" in str(result["error"]), (
        f"Expected 'PROCESS ERROR: implementer critic did not run' in error, "
        f"got: {result['error']!r}"
    )

    # DEC-CRITIC-BLOCKED-002: suggestion must carry BLOCKED: line
    suggestion = str(result.get("suggestion") or "")
    assert "BLOCKED:" in suggestion, (
        f"Expected 'BLOCKED:' in suggestion for critic-missing PROCESS ERROR "
        f"(DEC-CRITIC-BLOCKED-002), got: {suggestion!r}"
    )
    assert "PROCESS ERROR: implementer critic did not run" in suggestion, (
        f"Expected PROCESS ERROR line preserved in suggestion, got: {suggestion!r}"
    )
    # auto_dispatch must be False
    assert result.get("auto_dispatch") is False, (
        f"Expected auto_dispatch=False when critic is missing, got {result.get('auto_dispatch')!r}"
    )
