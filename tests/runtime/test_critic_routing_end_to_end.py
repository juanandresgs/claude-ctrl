"""End-to-end critic routing test — DEC-CRITIC-CONTEXT-001, DEC-CRITIC-BLOCKED-002.

Exercises the full production sequence for the critic loop:
  1. Issue an implementer lease with a known workflow_id.
  2. Simulate the SubagentStop hook input JSON with the correct agent_id and cwd.
  3. Call critic_context.resolve() to verify the resolver returns the implementer's
     workflow_id (not the orchestrator's).
  4. Submit a critic_reviews row tagged to the resolved workflow_id with a
     test execution proof (simulates what implementer-critic.sh does after
     cc-policy critic context resolve succeeds).
  5. Verify the submitted critic_reviews row has:
       - workflow_id == implementer lease workflow_id (not orchestrator fallback)
       - non-empty lease_id
  6. Run dispatch_engine.process_agent_stop with the feature worktree path and
     verify next_role == "implementer" (TRY_AGAIN routes back to implementer).

This is the compound-interaction test covering the full state transition:
  SubagentStop hook input → critic_context.resolve → critic_reviews.submit →
  dispatch_engine.process_agent_stop → next_role=implementer.

Real SQLite; no subprocess mocking for runtime calls.  The Codex/Gemini CLI
itself is not invoked — we use the CLAUDEX_IMPLEMENTER_CRITIC_TEST_RESPONSE
mechanism (test execution proof) to simulate a structured critic verdict.
Mocking Codex/Gemini is acceptable here because we're not testing the Codex
integration; we're testing that the workflow_id and lease_id reach the
critic_reviews row correctly.
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
import runtime.core.critic_context as critic_context_mod
import runtime.core.dispatch_engine as dispatch_engine_mod


@pytest.fixture
def db(tmp_path):
    conn = connect(tmp_path / "state.db")
    ensure_schema(conn)
    yield conn
    conn.close()


def test_critic_review_submitted_with_correct_workflow_id(db, tmp_path):
    """The critic_reviews row is tagged to the implementer lease workflow_id.

    Full production sequence:
      1. Issue implementer lease with a known feature workflow_id.
      2. Hook input arrives with the correct agent_id and cwd.
      3. critic_context.resolve() returns the feature workflow_id and lease_id.
      4. critic_review.submit() is called with those resolved values.
      5. The persisted row has workflow_id==feature_workflow_id and non-empty lease_id.
      6. dispatch_engine reads the row and routes back to implementer (TRY_AGAIN).

    This test verifies that the routing verdict is driven by a row correctly
    tagged to the implementer's workflow, not the orchestrator's.
    """
    feature_worktree = str(tmp_path / "feature-worktree")
    orchestrator_root = str(tmp_path / "orchestrator-root")
    feature_workflow_id = "feature-fix-critic-routing"
    orchestrator_workflow_id = "main-orchestrator-session"
    test_agent_id = "implementer-agent-xyz"

    # --- Step 1: Issue implementer lease ---
    impl_lease = leases_mod.issue(
        db,
        role="implementer",
        worktree_path=feature_worktree,
        workflow_id=feature_workflow_id,
    )
    impl_lease_id = impl_lease["lease_id"]
    # Claim the lease with agent_id (simulates SubagentStart)
    leases_mod.claim(db, agent_id=test_agent_id, lease_id=impl_lease_id)

    # Issue an orchestrator lease (simulates parent session) at a different path
    leases_mod.issue(
        db,
        role="planner",
        worktree_path=orchestrator_root,
        workflow_id=orchestrator_workflow_id,
    )

    # --- Step 2: SubagentStop hook input (with correct agent_id and cwd) ---
    hook_input = {
        "agent_type": "implementer",
        "agent_id": test_agent_id,
        "cwd": feature_worktree,
    }

    # --- Step 3: critic_context.resolve returns the feature workflow_id ---
    ctx = critic_context_mod.resolve(db, hook_input)
    assert ctx["found"] is True, f"Context resolver failed: {ctx}"
    assert ctx["workflow_id"] == feature_workflow_id, (
        f"Expected workflow_id={feature_workflow_id!r}, got {ctx['workflow_id']!r}. "
        "Resolver must NOT return the orchestrator's workflow_id."
    )
    assert ctx["lease_id"] == impl_lease_id, (
        f"Expected lease_id={impl_lease_id!r}, got {ctx['lease_id']!r}"
    )

    # --- Step 4: Implementer submits a completion (what it always does at Stop) ---
    completions_mod.submit(
        db,
        lease_id=impl_lease_id,
        workflow_id=feature_workflow_id,
        role="implementer",
        payload={
            "IMPL_STATUS": "complete",
            "IMPL_RESULT": "READY_FOR_REVIEWER",
        },
    )

    # --- Step 4b: Submit a critic_reviews row using the resolved context ---
    # (Simulates what implementer-critic.sh does after the resolver returns found=True)
    metadata = {
        "execution_proof": {
            "provider": "test",
            "test_override": True,
            "parsed_structured_output_present": True,
        }
    }
    review = critic_reviews_mod.submit(
        db,
        workflow_id=ctx["workflow_id"],   # <-- MUST be feature_workflow_id
        lease_id=ctx["lease_id"],          # <-- MUST be non-empty
        verdict="TRY_AGAIN",
        summary="Test: needs work.",
        detail="Missing tests for the resolver path.",
        metadata=metadata,
    )

    # --- Step 5: Verify the persisted row ---
    assert review["workflow_id"] == feature_workflow_id, (
        f"critic_reviews row workflow_id must match feature workflow_id. "
        f"Got: {review['workflow_id']!r}"
    )
    assert review["lease_id"] == impl_lease_id, (
        f"critic_reviews row lease_id must be non-empty and match the implementer lease. "
        f"Got: {review['lease_id']!r}"
    )
    assert review["workflow_id"] != orchestrator_workflow_id, (
        "critic_reviews row must NOT be tagged to the orchestrator's workflow_id."
    )

    # --- Step 6: dispatch_engine reads the row and routes back to implementer ---
    result = dispatch_engine_mod.process_agent_stop(db, "implementer", feature_worktree)

    assert result["next_role"] == "implementer", (
        f"Expected next_role='implementer' for TRY_AGAIN critic verdict. "
        f"error={result.get('error')!r}, suggestion={result.get('suggestion')!r}"
    )
    assert result["error"] is None, (
        f"Expected no error for TRY_AGAIN routing, got: {result['error']!r}"
    )
    assert result.get("critic_verdict") == "TRY_AGAIN"
    suggestion = str(result.get("suggestion") or "")
    assert "AUTO_DISPATCH: implementer" in suggestion, (
        f"Expected AUTO_DISPATCH: implementer in suggestion, got: {suggestion!r}"
    )
