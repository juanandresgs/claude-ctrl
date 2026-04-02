"""Unit tests for runtime/core/leases.py — dispatch lease domain module.

@decision DEC-LEASE-001
Title: Dispatch leases replace marker-based WHO enforcement for Check 3
Status: accepted
Rationale: Tests exercise all 18 required scenarios from the plan:
  classify_git_op parity, issue/claim/release lifecycle, get_current
  resolution priority, validate_op composite validation (eval + approval),
  expire_stale, and render_startup_contract. The compound lifecycle test
  (test 17) is the production-sequence proof required by the Evaluation
  Contract — it exercises issue → claim → release → validate_op across
  all subsystem boundaries.
"""

import sqlite3
import time

import pytest

from runtime.schemas import ensure_schema
from runtime.core import leases
from runtime.core import evaluation as evaluation_mod
from runtime.core import approvals as approvals_mod


# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    """In-memory SQLite connection with full schema applied."""
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


def _make_lease(conn, role="implementer", worktree_path="/wt/a", workflow_id="wf-1", **kwargs):
    """Helper: issue a lease with sensible defaults."""
    return leases.issue(
        conn,
        role=role,
        worktree_path=worktree_path,
        workflow_id=workflow_id,
        **kwargs,
    )


# ---------------------------------------------------------------------------
# Test 1: classify_git_op — must match bash classifier for all vectors
# ---------------------------------------------------------------------------


class TestClassifyGitOp:
    """Verify Python classifier matches context-lib.sh bash classifier exactly."""

    def test_git_commit(self):
        assert leases.classify_git_op("git commit -m 'foo'") == "routine_local"

    def test_git_merge(self):
        assert leases.classify_git_op("git merge feature-branch") == "routine_local"

    def test_git_push(self):
        assert leases.classify_git_op("git push origin main") == "high_risk"

    def test_git_rebase(self):
        assert leases.classify_git_op("git rebase main") == "high_risk"

    def test_git_reset(self):
        assert leases.classify_git_op("git reset HEAD~1") == "high_risk"

    def test_git_reset_hard(self):
        assert leases.classify_git_op("git reset --hard HEAD") == "high_risk"

    def test_git_merge_no_ff(self):
        assert leases.classify_git_op("git merge --no-ff feature") == "high_risk"

    def test_git_log(self):
        assert leases.classify_git_op("git log --oneline") == "unclassified"

    def test_git_status(self):
        assert leases.classify_git_op("git status") == "unclassified"

    def test_git_diff(self):
        assert leases.classify_git_op("git diff HEAD") == "unclassified"

    def test_git_c_commit(self):
        """git -C /path commit must still classify as routine_local."""
        assert leases.classify_git_op("git -C /path/to/repo commit -m msg") == "routine_local"

    def test_git_c_push(self):
        """git -C /path push must still classify as high_risk."""
        assert leases.classify_git_op("git -C /path/to/repo push origin main") == "high_risk"

    def test_merge_without_no_ff_is_routine(self):
        """Plain merge without --no-ff is routine_local, not high_risk."""
        assert leases.classify_git_op("git merge --ff-only main") == "routine_local"

    def test_non_git_command(self):
        assert leases.classify_git_op("ls -la") == "unclassified"

    def test_empty_string(self):
        assert leases.classify_git_op("") == "unclassified"


# ---------------------------------------------------------------------------
# Test 2: issue() — UUID, correct defaults, expires_at
# ---------------------------------------------------------------------------


def test_issue_returns_uuid_lease_id(conn):
    lease = _make_lease(conn)
    assert isinstance(lease["lease_id"], str)
    assert len(lease["lease_id"]) == 32  # UUID4 hex = 32 chars


def test_issue_correct_defaults(conn):
    lease = _make_lease(conn)
    assert lease["status"] == "active"
    assert lease["allowed_ops"] == ["routine_local"]
    assert lease["blocked_ops"] == []
    assert lease["requires_eval"] == 1  # stored as INTEGER
    assert lease["agent_id"] is None


def test_issue_sets_expires_at(conn):
    before = int(time.time())
    lease = _make_lease(conn, ttl=3600)
    after = int(time.time())
    assert lease["expires_at"] >= before + 3600
    assert lease["expires_at"] <= after + 3600


def test_issue_custom_allowed_ops(conn):
    lease = _make_lease(conn, allowed_ops=["routine_local", "high_risk"])
    assert "high_risk" in lease["allowed_ops"]
    assert "routine_local" in lease["allowed_ops"]


def test_issue_sets_role(conn):
    lease = _make_lease(conn, role="guardian")
    assert lease["role"] == "guardian"


def test_issue_sets_next_step(conn):
    lease = _make_lease(conn, next_step="commit and merge feature branch")
    assert lease["next_step"] == "commit and merge feature branch"


# ---------------------------------------------------------------------------
# Test 3: issue() revokes existing active lease for same worktree
# ---------------------------------------------------------------------------


def test_issue_revokes_existing_active_for_same_worktree(conn):
    lease1 = _make_lease(conn, role="implementer", worktree_path="/wt/x", workflow_id="wf-1")
    lid1 = lease1["lease_id"]

    # Issue a second lease for the same worktree
    lease2 = _make_lease(conn, role="guardian", worktree_path="/wt/x", workflow_id="wf-2")
    lid2 = lease2["lease_id"]

    # First lease must now be revoked
    old = leases.get(conn, lid1)
    assert old["status"] == "revoked", f"expected revoked, got {old['status']}"

    # Second lease is active
    assert lease2["status"] == "active"
    assert lid1 != lid2


def test_issue_does_not_affect_different_worktree(conn):
    lease1 = _make_lease(conn, worktree_path="/wt/a", workflow_id="wf-a")
    lease2 = _make_lease(conn, worktree_path="/wt/b", workflow_id="wf-b")

    # Both should be active (different worktrees)
    a = leases.get(conn, lease1["lease_id"])
    b = leases.get(conn, lease2["lease_id"])
    assert a["status"] == "active"
    assert b["status"] == "active"


# ---------------------------------------------------------------------------
# Test 4: claim() sets agent_id, returns lease
# ---------------------------------------------------------------------------


def test_claim_sets_agent_id(conn):
    lease = _make_lease(conn, worktree_path="/wt/c", workflow_id="wf-c")
    claimed = leases.claim(conn, "agent-1234", worktree_path="/wt/c")

    assert claimed is not None
    assert claimed["agent_id"] == "agent-1234"
    assert claimed["lease_id"] == lease["lease_id"]


def test_claim_by_lease_id(conn):
    lease = _make_lease(conn, worktree_path="/wt/d", workflow_id="wf-d")
    claimed = leases.claim(conn, "agent-999", lease_id=lease["lease_id"])

    assert claimed is not None
    assert claimed["agent_id"] == "agent-999"


def test_claim_returns_none_for_nonexistent_worktree(conn):
    result = leases.claim(conn, "agent-111", worktree_path="/nonexistent/path")
    assert result is None


def test_claim_returns_none_for_released_lease(conn):
    lease = _make_lease(conn, worktree_path="/wt/e", workflow_id="wf-e")
    leases.release(conn, lease["lease_id"])
    result = leases.claim(conn, "agent-222", worktree_path="/wt/e")
    assert result is None


# ---------------------------------------------------------------------------
# Test 5: claim() revokes other active lease for same agent_id
# ---------------------------------------------------------------------------


def test_claim_revokes_other_active_lease_for_same_agent(conn):
    # Two leases on different worktrees
    lease_a = _make_lease(conn, worktree_path="/wt/p", workflow_id="wf-p")
    lease_b = _make_lease(conn, worktree_path="/wt/q", workflow_id="wf-q")

    # Claim lease_a with agent-777
    leases.claim(conn, "agent-777", lease_id=lease_a["lease_id"])

    # Now claim lease_b with same agent — lease_a must be revoked
    leases.claim(conn, "agent-777", lease_id=lease_b["lease_id"])

    old_a = leases.get(conn, lease_a["lease_id"])
    new_b = leases.get(conn, lease_b["lease_id"])

    assert old_a["status"] == "revoked", f"expected revoked, got {old_a['status']}"
    assert new_b["status"] == "active"
    assert new_b["agent_id"] == "agent-777"


# ---------------------------------------------------------------------------
# Test 6: get_current() priority: lease_id > agent_id > worktree_path > workflow_id
# ---------------------------------------------------------------------------


def test_get_current_priority_lease_id_wins(conn):
    """When lease_id is provided, it takes priority over other identifiers."""
    la = _make_lease(conn, worktree_path="/wt/la", workflow_id="wf-la")
    _make_lease(conn, worktree_path="/wt/lb", workflow_id="wf-lb")

    # Provide lease_id for la, but worktree_path for lb
    result = leases.get_current(
        conn,
        lease_id=la["lease_id"],
        worktree_path="/wt/lb",
    )
    assert result is not None
    assert result["lease_id"] == la["lease_id"]


def test_get_current_agent_id_wins_over_worktree(conn):
    """agent_id takes priority over worktree_path."""
    la = _make_lease(conn, worktree_path="/wt/ma", workflow_id="wf-ma")
    _make_lease(conn, worktree_path="/wt/mb", workflow_id="wf-mb")

    leases.claim(conn, "agent-abc", lease_id=la["lease_id"])

    # Pass agent_id for la but worktree_path for lb
    result = leases.get_current(conn, agent_id="agent-abc", worktree_path="/wt/mb")
    assert result["lease_id"] == la["lease_id"]


def test_get_current_worktree_wins_over_workflow(conn):
    """worktree_path takes priority over workflow_id."""
    la = _make_lease(conn, worktree_path="/wt/na", workflow_id="wf-na")
    _make_lease(conn, worktree_path="/wt/nb", workflow_id="wf-nb")

    result = leases.get_current(conn, worktree_path="/wt/na", workflow_id="wf-nb")
    assert result["lease_id"] == la["lease_id"]


def test_get_current_falls_back_to_workflow_id(conn):
    """Falls back to workflow_id when no other identifiers match."""
    la = _make_lease(conn, worktree_path="/wt/oa", workflow_id="wf-oa")

    result = leases.get_current(conn, workflow_id="wf-oa")
    assert result is not None
    assert result["lease_id"] == la["lease_id"]


# ---------------------------------------------------------------------------
# Test 7: get_current() returns None for non-active leases
# ---------------------------------------------------------------------------


def test_get_current_returns_none_for_released_lease(conn):
    lease = _make_lease(conn, worktree_path="/wt/rel", workflow_id="wf-rel")
    leases.release(conn, lease["lease_id"])
    result = leases.get_current(conn, lease_id=lease["lease_id"])
    assert result is None


def test_get_current_returns_none_for_revoked_lease(conn):
    lease = _make_lease(conn, worktree_path="/wt/rev", workflow_id="wf-rev")
    leases.revoke(conn, lease["lease_id"])
    result = leases.get_current(conn, lease_id=lease["lease_id"])
    assert result is None


def test_get_current_returns_none_for_expired_lease(conn):
    lease = _make_lease(conn, worktree_path="/wt/exp", workflow_id="wf-exp")
    # Force expire via expire_stale with a future "now"
    leases.expire_stale(conn, now=int(time.time()) + 99999)
    result = leases.get_current(conn, lease_id=lease["lease_id"])
    assert result is None


# ---------------------------------------------------------------------------
# Test 8: validate_op() with lease + eval ready + routine_local → allowed
# ---------------------------------------------------------------------------


def test_validate_op_routine_local_eval_ready_allowed(conn):
    # Set up eval state
    evaluation_mod.set_status(conn, "wf-8", "ready_for_guardian")
    lease = _make_lease(
        conn,
        worktree_path="/wt/8",
        workflow_id="wf-8",
        allowed_ops=["routine_local"],
        requires_eval=True,
    )

    result = leases.validate_op(
        conn, "git commit -m 'test'", worktree_path="/wt/8"
    )
    assert result["allowed"] is True, f"expected allowed, reason: {result['reason']}"
    assert result["op_class"] == "routine_local"
    assert result["eval_ok"] is True
    assert result["lease_id"] == lease["lease_id"]


# ---------------------------------------------------------------------------
# Test 9: validate_op() with op not in allowed_ops → denied
# ---------------------------------------------------------------------------


def test_validate_op_op_not_in_allowed_ops_denied(conn):
    _make_lease(
        conn,
        worktree_path="/wt/9",
        workflow_id="wf-9",
        allowed_ops=["routine_local"],  # no high_risk
    )

    result = leases.validate_op(
        conn, "git push origin main", worktree_path="/wt/9"
    )
    assert result["allowed"] is False
    assert result["op_class"] == "high_risk"
    assert "not in allowed_ops" in result["reason"]


# ---------------------------------------------------------------------------
# Test 10: validate_op() with worktree mismatch → denied
# ---------------------------------------------------------------------------


def test_validate_op_worktree_mismatch_denied(conn):
    _make_lease(
        conn,
        worktree_path="/wt/A",
        workflow_id="wf-A",
        allowed_ops=["routine_local", "high_risk"],
    )

    # validate_op called with a different worktree_path
    # get_current will find nothing for /wt/B, so result is no-lease
    result = leases.validate_op(
        conn, "git commit -m 'test'", worktree_path="/wt/B"
    )
    # No active lease found for /wt/B → no-lease denial
    assert result["allowed"] is False
    assert result["lease_id"] is None


def test_validate_op_worktree_mismatch_lease_found_by_id(conn):
    """When lease is found by lease_id but worktree_path doesn't match."""
    lease = _make_lease(
        conn,
        worktree_path="/wt/C",
        workflow_id="wf-C",
        allowed_ops=["routine_local"],
    )

    result = leases.validate_op(
        conn,
        "git commit -m 'test'",
        lease_id=lease["lease_id"],
        worktree_path="/wt/D",  # different from lease's /wt/C
    )
    assert result["allowed"] is False
    assert "does not match" in result["reason"]


# ---------------------------------------------------------------------------
# Test 11: validate_op() with no lease → allowed=false, op_class populated
# ---------------------------------------------------------------------------


def test_validate_op_no_lease_returns_op_class(conn):
    result = leases.validate_op(
        conn, "git push origin main", worktree_path="/nonexistent/worktree"
    )
    assert result["allowed"] is False
    assert result["op_class"] == "high_risk"  # op_class always populated
    assert result["lease_id"] is None
    assert "no active lease" in result["reason"]


def test_validate_op_no_lease_routine_local_op_class_populated(conn):
    result = leases.validate_op(
        conn, "git commit -m 'test'", worktree_path="/nonexistent"
    )
    assert result["allowed"] is False
    assert result["op_class"] == "routine_local"
    assert result["lease_id"] is None


# ---------------------------------------------------------------------------
# Test 12: validate_op() with high_risk + approval exists → approval_ok=true
# ---------------------------------------------------------------------------


def test_validate_op_high_risk_with_approval_allowed(conn):
    _make_lease(
        conn,
        worktree_path="/wt/12",
        workflow_id="wf-12",
        allowed_ops=["routine_local", "high_risk"],
        requires_eval=False,
    )
    # Grant an approval token for this workflow
    approvals_mod.grant(conn, "wf-12", "push")

    result = leases.validate_op(
        conn, "git push origin main", worktree_path="/wt/12"
    )
    assert result["allowed"] is True, f"expected allowed, reason: {result['reason']}"
    assert result["op_class"] == "high_risk"
    assert result["requires_approval"] is True
    assert result["approval_ok"] is True


# ---------------------------------------------------------------------------
# Test 13: validate_op() with high_risk + no approval → approval_ok=false
# ---------------------------------------------------------------------------


def test_validate_op_high_risk_no_approval_denied(conn):
    _make_lease(
        conn,
        worktree_path="/wt/13",
        workflow_id="wf-13",
        allowed_ops=["routine_local", "high_risk"],
        requires_eval=False,
    )
    # No approval token granted

    result = leases.validate_op(
        conn, "git push origin main", worktree_path="/wt/13"
    )
    assert result["allowed"] is False
    assert result["op_class"] == "high_risk"
    assert result["requires_approval"] is True
    assert result["approval_ok"] is False
    assert "approval token" in result["reason"]


# ---------------------------------------------------------------------------
# Test 14: validate_op() does NOT consume approval tokens
# ---------------------------------------------------------------------------


def test_validate_op_does_not_consume_approval_tokens(conn):
    """validate_op uses list_pending (read-only), never check_and_consume."""
    _make_lease(
        conn,
        worktree_path="/wt/14",
        workflow_id="wf-14",
        allowed_ops=["routine_local", "high_risk"],
        requires_eval=False,
    )
    approvals_mod.grant(conn, "wf-14", "push")

    # Call validate_op twice — token must still be present after both calls
    result1 = leases.validate_op(conn, "git push origin main", worktree_path="/wt/14")
    result2 = leases.validate_op(conn, "git push origin main", worktree_path="/wt/14")

    assert result1["allowed"] is True
    assert result2["allowed"] is True  # token still there

    # Verify approval token is still unconsumed
    pending = approvals_mod.list_pending(conn, "wf-14")
    assert len(pending) == 1, "approval token should not have been consumed by validate_op"


# ---------------------------------------------------------------------------
# Test 15: expire_stale() transitions past-TTL active leases
# ---------------------------------------------------------------------------


def test_expire_stale_transitions_past_ttl_leases(conn):
    # Issue lease with very short TTL
    lease = _make_lease(conn, worktree_path="/wt/15", workflow_id="wf-15", ttl=1)

    # expire_stale with now = far future
    count = leases.expire_stale(conn, now=int(time.time()) + 99999)
    assert count >= 1

    updated = leases.get(conn, lease["lease_id"])
    assert updated["status"] == "expired"


def test_expire_stale_returns_count(conn):
    _make_lease(conn, worktree_path="/wt/15a", workflow_id="wf-15a", ttl=1)
    _make_lease(conn, worktree_path="/wt/15b", workflow_id="wf-15b", ttl=1)

    count = leases.expire_stale(conn, now=int(time.time()) + 99999)
    assert count == 2


# ---------------------------------------------------------------------------
# Test 16: expire_stale() doesn't touch non-active or future-TTL leases
# ---------------------------------------------------------------------------


def test_expire_stale_does_not_touch_non_active(conn):
    lease = _make_lease(conn, worktree_path="/wt/16a", workflow_id="wf-16a", ttl=1)
    leases.release(conn, lease["lease_id"])

    count = leases.expire_stale(conn, now=int(time.time()) + 99999)
    # Released lease should not count
    assert count == 0

    updated = leases.get(conn, lease["lease_id"])
    assert updated["status"] == "released"  # unchanged


def test_expire_stale_does_not_touch_future_ttl(conn):
    lease = _make_lease(conn, worktree_path="/wt/16b", workflow_id="wf-16b", ttl=9999)

    # expire with now = current time (lease hasn't expired)
    count = leases.expire_stale(conn, now=int(time.time()))
    assert count == 0

    updated = leases.get(conn, lease["lease_id"])
    assert updated["status"] == "active"


# ---------------------------------------------------------------------------
# Test 17: Lifecycle: issue → claim → release → validate_op returns no-lease
# (Compound interaction — the production sequence end-to-end)
# ---------------------------------------------------------------------------


def test_full_lifecycle_issue_claim_release_validate(conn):
    """Production sequence: orchestrator issues → agent claims → task completes
    → agent releases → guard.sh validate_op finds no active lease.

    This is the compound interaction test crossing:
      leases.issue() → leases.claim() → leases.release() → leases.validate_op()
      → evaluation_mod.get() (check eval state) → approvals_mod.list_pending()
    """
    # Step 1: Orchestrator issues lease (at dispatch time)
    lease = leases.issue(
        conn,
        role="guardian",
        worktree_path="/wt/lifecycle",
        workflow_id="wf-lifecycle",
        allowed_ops=["routine_local", "high_risk"],
        requires_eval=True,
        ttl=7200,
    )
    assert lease["status"] == "active"
    assert lease["agent_id"] is None

    # Step 2: subagent-start.sh claims the lease (binds PID)
    claimed = leases.claim(conn, "agent-42", worktree_path="/wt/lifecycle")
    assert claimed is not None
    assert claimed["agent_id"] == "agent-42"
    assert claimed["status"] == "active"

    # Step 3: During execution, validate_op should work (with eval ready + approval)
    evaluation_mod.set_status(conn, "wf-lifecycle", "ready_for_guardian")
    approvals_mod.grant(conn, "wf-lifecycle", "push")

    mid_result = leases.validate_op(
        conn, "git push origin feature", worktree_path="/wt/lifecycle"
    )
    assert mid_result["allowed"] is True, f"mid-lifecycle denied: {mid_result['reason']}"

    # Step 4: post-task.sh releases the lease (task complete)
    released = leases.release(conn, lease["lease_id"])
    assert released is True

    # Step 5: Guard.sh validate_op finds no active lease — should deny
    after_result = leases.validate_op(
        conn, "git commit -m 'post release'", worktree_path="/wt/lifecycle"
    )
    assert after_result["allowed"] is False
    assert after_result["lease_id"] is None
    assert "no active lease" in after_result["reason"]
    assert after_result["op_class"] == "routine_local"  # op_class still populated


# ---------------------------------------------------------------------------
# Test 18: render_startup_contract() format
# ---------------------------------------------------------------------------


def test_render_startup_contract_format(conn):
    lease = leases.issue(
        conn,
        role="guardian",
        worktree_path="/wt/sc",
        workflow_id="wf-sc",
        branch="feature/x",
        allowed_ops=["routine_local", "high_risk"],
        next_step="commit and merge feature branch",
        ttl=7200,
    )

    contract = leases.render_startup_contract(lease)

    assert f"LEASE_ID={lease['lease_id']}" in contract
    assert "Role: guardian" in contract
    assert "Workflow: wf-sc" in contract
    assert "Worktree: /wt/sc" in contract
    assert "Branch: feature/x" in contract
    assert "Allowed ops: routine_local, high_risk" in contract
    assert "Next step: commit and merge feature branch" in contract
    assert "Expires:" in contract


def test_render_startup_contract_minimal(conn):
    """render_startup_contract works with a lease that has only required fields."""
    lease = leases.issue(conn, role="tester")
    contract = leases.render_startup_contract(lease)

    assert f"LEASE_ID={lease['lease_id']}" in contract
    assert "Role: tester" in contract
    # Optional fields not present should not appear
    assert "Workflow:" not in contract
    assert "Worktree:" not in contract


# ---------------------------------------------------------------------------
# Additional: list_leases() and summary()
# ---------------------------------------------------------------------------


def test_list_leases_filters_by_status(conn):
    la = _make_lease(conn, worktree_path="/wt/lst-a", workflow_id="wf-lst-a")
    lb = _make_lease(conn, worktree_path="/wt/lst-b", workflow_id="wf-lst-b")
    leases.release(conn, la["lease_id"])

    active = leases.list_leases(conn, status="active")
    released = leases.list_leases(conn, status="released")

    assert any(r["lease_id"] == lb["lease_id"] for r in active)
    assert any(r["lease_id"] == la["lease_id"] for r in released)
    assert not any(r["lease_id"] == la["lease_id"] for r in active)


def test_list_leases_filters_by_worktree(conn):
    _make_lease(conn, worktree_path="/wt/filter-a", workflow_id="wf-filter-a")
    _make_lease(conn, worktree_path="/wt/filter-b", workflow_id="wf-filter-b")

    results = leases.list_leases(conn, worktree_path="/wt/filter-a")
    assert len(results) == 1
    assert results[0]["worktree_path"] == "/wt/filter-a"


def test_summary_shows_active_lease(conn):
    lease = _make_lease(conn, worktree_path="/wt/sum", workflow_id="wf-sum")
    s = leases.summary(conn, worktree_path="/wt/sum")

    assert s["active_lease"] is not None
    assert s["active_lease"]["lease_id"] == lease["lease_id"]
    assert s["counts_by_status"].get("active", 0) == 1


def test_summary_no_active_after_release(conn):
    lease = _make_lease(conn, worktree_path="/wt/sum2", workflow_id="wf-sum2")
    leases.release(conn, lease["lease_id"])

    s = leases.summary(conn, worktree_path="/wt/sum2")
    assert s["active_lease"] is None
    assert s["counts_by_status"].get("released", 0) == 1
