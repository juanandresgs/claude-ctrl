"""Tests for runtime/core/critic_context.py — DEC-CRITIC-CONTEXT-001.

Production sequence:
  SubagentStop fires on the orchestrator's process → implementer-critic.sh runs →
  calls cc-policy critic context resolve --hook-input <json> →
  runtime/core/critic_context.py resolves the implementer's lease from agent_id
  or cwd → returns {workflow_id, lease_id} scoped to the IMPLEMENTER, not the
  orchestrator.

These tests:
  1. Verify agent_id-first resolution returns the implementer lease's workflow_id,
     NOT a branch-derived fallback or a different workflow_id.
  2. Verify lease_id is populated when an implementer lease exists and is
     associated with the given agent_id.

All tests use real SQLite (runtime.core.db.connect + ensure_schema) and real
leases.issue() calls. No subprocess mocking. Mocking Codex/Gemini external CLI
is acceptable in other test files that exercise the full critic pipeline — the
context resolver itself is a pure SQLite read and must not be mocked.
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
import runtime.core.critic_context as critic_context_mod


@pytest.fixture
def db(tmp_path):
    """Open an in-memory-equivalent DB with schema applied."""
    conn = connect(tmp_path / "state.db")
    ensure_schema(conn)
    yield conn
    conn.close()


def _issue_implementer_lease(conn, workflow_id: str, worktree_path: str) -> dict:
    """Issue an implementer lease and return it."""
    return leases_mod.issue(
        conn,
        role="implementer",
        worktree_path=worktree_path,
        workflow_id=workflow_id,
    )


def _claim_lease(conn, lease_id: str, agent_id: str) -> dict:
    """Claim a lease by associating agent_id with it."""
    return leases_mod.claim(conn, agent_id=agent_id, lease_id=lease_id)


# ---------------------------------------------------------------------------
# Test 1: resolver returns IMPLEMENTER workflow_id, not orchestrator fallback
# ---------------------------------------------------------------------------


def test_critic_context_resolves_implementer_workflow_from_hook_input(db, tmp_path):
    """Context resolver returns the implementer's workflow_id from input.cwd.

    The hook fires in the orchestrator's process.  The hook input JSON carries
    the implementer's actual cwd.  The resolver MUST return the workflow_id
    bound to the implementer's lease (the feature workflow) — not the
    orchestrator's session workflow or a branch-derived fallback.

    Compound-interaction sequence:
      1. Issue an implementer lease at the feature worktree path.
      2. Call critic_context.resolve() with hook input pointing to that worktree.
      3. Assert workflow_id matches the feature workflow, not any fallback.
    """
    feature_worktree = str(tmp_path / "feature-worktree")
    orchestrator_root = str(tmp_path / "orchestrator-root")
    implementer_workflow_id = "feature-fix-critic-routing"
    orchestrator_workflow_id = "main-orchestrator-session"

    # Issue an implementer lease at the feature worktree path.
    _issue_implementer_lease(db, implementer_workflow_id, feature_worktree)

    # Issue an orchestrator lease at a different path (simulates the parent session).
    leases_mod.issue(
        db,
        role="planner",  # orchestrator is not an implementer
        worktree_path=orchestrator_root,
        workflow_id=orchestrator_workflow_id,
    )

    # Hook input: cwd points to the implementer's feature worktree (not orchestrator root).
    hook_input = {
        "agent_type": "implementer",
        "cwd": feature_worktree,
    }

    result = critic_context_mod.resolve(db, hook_input)

    assert result["found"] is True, (
        f"Expected found=True but got: {result}"
    )
    assert result["workflow_id"] == implementer_workflow_id, (
        f"Expected workflow_id={implementer_workflow_id!r} (implementer's), "
        f"got {result['workflow_id']!r}. "
        "Resolver must NOT return the orchestrator's workflow_id."
    )
    assert result["workflow_id"] != orchestrator_workflow_id, (
        "Resolver returned the ORCHESTRATOR's workflow_id — this is the bug being fixed."
    )
    assert result["resolve_path"] == "cwd", (
        f"Expected resolve_path='cwd', got {result['resolve_path']!r}"
    )


# ---------------------------------------------------------------------------
# Test 2: resolver returns lease_id when agent_id is present in hook input
# ---------------------------------------------------------------------------


def test_critic_context_resolves_lease_id_by_agent_id(db, tmp_path):
    """Context resolver returns non-empty lease_id when agent_id resolves an implementer lease.

    The critic_reviews row must carry a non-empty lease_id so that
    dispatch_engine can correlate the critic review with the dispatch attempt.
    An empty lease_id breaks the retry-streak window and means the reviewer
    gate cannot be correctly closed for this implementer dispatch.

    Compound-interaction sequence:
      1. Issue an implementer lease.
      2. Claim the lease with a known agent_id (simulates SubagentStart).
      3. Call critic_context.resolve() with hook input carrying that agent_id.
      4. Assert returned lease_id matches the claimed lease.
    """
    feature_worktree = str(tmp_path / "feature-worktree")
    implementer_workflow_id = "feature-fix-critic-routing"
    test_agent_id = "agent-implementer-abc123"

    # Issue + claim the implementer lease.
    lease = _issue_implementer_lease(db, implementer_workflow_id, feature_worktree)
    expected_lease_id = lease["lease_id"]
    _claim_lease(db, expected_lease_id, test_agent_id)

    # Hook input carries agent_id (priority 1).
    hook_input = {
        "agent_type": "implementer",
        "agent_id": test_agent_id,
        "cwd": feature_worktree,
    }

    result = critic_context_mod.resolve(db, hook_input)

    assert result["found"] is True, (
        f"Expected found=True but got: {result}"
    )
    assert result["lease_id"] == expected_lease_id, (
        f"Expected lease_id={expected_lease_id!r}, got {result['lease_id']!r}. "
        "Non-empty lease_id is required for critic_reviews correlation."
    )
    assert result["workflow_id"] == implementer_workflow_id, (
        f"Expected workflow_id={implementer_workflow_id!r}, got {result['workflow_id']!r}"
    )
    assert result["resolve_path"] == "agent_id", (
        f"Expected resolve_path='agent_id' (priority 1), got {result['resolve_path']!r}"
    )
    assert result["agent_id"] == test_agent_id, (
        f"Expected agent_id={test_agent_id!r} echoed back, got {result['agent_id']!r}"
    )


# ---------------------------------------------------------------------------
# Test 3 (F2): resolver resolves recently-revoked lease by agent_id
# ---------------------------------------------------------------------------


def test_critic_context_resolves_recently_revoked_implementer_lease(db, tmp_path):
    """resolve() returns found=True for a recently-revoked implementer lease matched by agent_id.

    Production failure reproduced (F2): By the time SubagentStop fires, the harness
    has already revoked the implementer lease. leases.get_current() hardcodes
    status='active', so it misses the revoked row. This test verifies that
    critic_context.resolve() uses _fetch_recent_by_agent_id (which widens the
    status filter) to find the revoked lease.

    This is the test that would have caught the shipped regression in #81.
    """
    feature_worktree = str(tmp_path / "feature-worktree")
    implementer_workflow_id = "feature-fix-critic-fail-closed"
    test_agent_id = "agent-revoked-abc456"

    # Issue + claim implementer lease (simulates SubagentStart)
    lease = leases_mod.issue(
        db,
        role="implementer",
        worktree_path=feature_worktree,
        workflow_id=implementer_workflow_id,
    )
    lease_id = lease["lease_id"]
    leases_mod.claim(db, agent_id=test_agent_id, lease_id=lease_id)

    # REVOKE the lease (simulates what the harness does before SubagentStop fires)
    revoked = leases_mod.revoke(db, lease_id)
    assert revoked is True, "Expected lease to be revoked"

    # Verify get_current (active-only) now misses it
    active_lease = leases_mod.get_current(db, agent_id=test_agent_id)
    assert active_lease is None, (
        "leases.get_current should return None for a revoked lease (active-only semantics)."
    )

    # critic_context.resolve() should still find it via _fetch_recent_by_agent_id
    hook_input = {
        "agent_type": "implementer",
        "agent_id": test_agent_id,
        "cwd": feature_worktree,
    }
    result = critic_context_mod.resolve(db, hook_input)

    assert result["found"] is True, (
        f"Expected found=True for recently-revoked lease, got: {result}. "
        "This is F2: critic_context.resolve() must widen the status filter to "
        "find recently-released/revoked leases within RECENT_LEASE_TTL_SECONDS."
    )
    assert result["workflow_id"] == implementer_workflow_id, (
        f"Expected workflow_id={implementer_workflow_id!r}, got {result['workflow_id']!r}"
    )
    assert result["lease_id"] == lease_id, (
        f"Expected lease_id={lease_id!r}, got {result['lease_id']!r}"
    )
    assert result["resolve_path"] == "agent_id", (
        f"Expected resolve_path='agent_id', got {result['resolve_path']!r}"
    )


# ---------------------------------------------------------------------------
# Test 4 (F1+F3): resolver returns found=False when no lease exists — no fallback
# ---------------------------------------------------------------------------


def test_critic_context_does_not_fallback_to_branch_name_via_bash_wrapper(db, tmp_path):
    """resolve() returns found=False (no workflow_id set) when no lease matches.

    The resolver itself MUST NOT fall back to a git branch name or any other
    ambient workflow identity. When found=False, the caller (bash wrapper or
    Node sidecar) is responsible for emitting CRITIC_UNAVAILABLE.

    This is the negative test for DEC-CRITIC-FAIL-CLOSED-002:
      - No implementer lease exists for the given agent_id or cwd.
      - resolve() returns found=False with empty workflow_id.
      - No fallback derivation occurs inside the resolver.
    """
    # No leases issued — resolution must fail.
    hook_input = {
        "agent_type": "implementer",
        "agent_id": "agent-does-not-exist-xyz",
        "cwd": str(tmp_path / "no-such-worktree"),
    }

    result = critic_context_mod.resolve(db, hook_input)

    assert result["found"] is False, (
        f"Expected found=False when no lease exists, got: {result}. "
        "The resolver must NOT fall back to a branch name."
    )
    assert result["workflow_id"] == "", (
        f"Expected empty workflow_id when not found, got: {result['workflow_id']!r}. "
        "resolver must return empty string (not 'main' or any branch name) "
        "so the caller can detect not-found and emit CRITIC_UNAVAILABLE."
    )
    assert result["resolve_path"] == "not_found", (
        f"Expected resolve_path='not_found', got {result['resolve_path']!r}"
    )
