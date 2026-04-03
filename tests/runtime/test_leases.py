"""Unit tests for runtime/core/leases.py

@decision DEC-LEASE-001
Title: SQLite-backed dispatch leases bind agent identity to worktree + allowed ops
Status: accepted
Rationale: These tests exercise all public functions (classify_git_op, issue,
  claim, get_current, validate_op, release, revoke, expire_stale, summary,
  render_startup_contract) against an in-memory SQLite database. They prove
  the uniqueness invariants, lifecycle transitions, and composite validation
  logic that guard.sh (Phase 2) and the orchestrator will rely on.

  Compound-interaction test (test_full_lifecycle) exercises the real production
  sequence: issue → claim → validate_op → release → validate returns no lease.
"""

import sqlite3
import time

import pytest

from runtime.schemas import ensure_schema
from runtime.core import leases


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


# ---------------------------------------------------------------------------
# classify_git_op
# ---------------------------------------------------------------------------


def test_classify_commit_is_routine_local():
    assert leases.classify_git_op("git commit -m 'msg'") == "routine_local"


def test_classify_merge_is_routine_local():
    assert leases.classify_git_op("git merge feature/foo") == "routine_local"


def test_classify_push_is_high_risk():
    assert leases.classify_git_op("git push origin main") == "high_risk"


def test_classify_rebase_is_high_risk():
    assert leases.classify_git_op("git rebase main") == "high_risk"


def test_classify_reset_is_high_risk():
    assert leases.classify_git_op("git reset --hard HEAD~1") == "high_risk"


def test_classify_merge_no_ff_is_high_risk():
    assert leases.classify_git_op("git merge --no-ff feature/bar") == "high_risk"


def test_classify_git_log_is_unclassified():
    assert leases.classify_git_op("git log --oneline -10") == "unclassified"


def test_classify_git_status_is_unclassified():
    assert leases.classify_git_op("git status") == "unclassified"


def test_classify_git_c_path_commit_is_routine_local():
    """git -C /path/to/repo commit should still classify as routine_local."""
    assert leases.classify_git_op("git -C /some/path commit -m 'msg'") == "routine_local"


# ---------------------------------------------------------------------------
# issue()
# ---------------------------------------------------------------------------


def test_issue_returns_lease_with_uuid_id(conn):
    lease = leases.issue(conn, role="implementer")
    assert lease is not None
    assert isinstance(lease["lease_id"], str)
    assert len(lease["lease_id"]) == 32  # uuid4().hex


def test_issue_sets_expires_at_correctly(conn):
    ttl = 3600
    lease = leases.issue(conn, role="tester", ttl=ttl)
    assert lease["expires_at"] == lease["issued_at"] + ttl


def test_issue_default_allowed_ops(conn):
    import json

    lease = leases.issue(conn, role="implementer")
    allowed = json.loads(lease["allowed_ops_json"])
    assert allowed == ["routine_local"]


def test_issue_default_blocked_ops_empty(conn):
    import json

    lease = leases.issue(conn, role="implementer")
    blocked = json.loads(lease["blocked_ops_json"])
    assert blocked == []


def test_issue_status_is_active(conn):
    lease = leases.issue(conn, role="implementer")
    assert lease["status"] == "active"


def test_issue_revokes_existing_active_for_same_worktree(conn):
    """Uniqueness invariant: second issue for same worktree revokes first."""
    wt = "/repo/feature-x"
    lease1 = leases.issue(conn, role="implementer", worktree_path=wt)
    lease2 = leases.issue(conn, role="tester", worktree_path=wt)

    # First lease should now be revoked.
    first = leases.get(conn, lease1["lease_id"])
    assert first["status"] == "revoked"

    # Second lease is active.
    assert lease2["status"] == "active"


def test_issue_two_different_worktrees_concurrent(conn):
    """Two leases for different worktrees can coexist as active."""
    lease_a = leases.issue(conn, role="implementer", worktree_path="/repo/feature-a")
    lease_b = leases.issue(conn, role="implementer", worktree_path="/repo/feature-b")

    assert leases.get(conn, lease_a["lease_id"])["status"] == "active"
    assert leases.get(conn, lease_b["lease_id"])["status"] == "active"


# ---------------------------------------------------------------------------
# claim()
# ---------------------------------------------------------------------------


def test_claim_sets_agent_id(conn):
    lease = leases.issue(conn, role="implementer", worktree_path="/repo/wt")
    claimed = leases.claim(conn, agent_id="agent-abc", worktree_path="/repo/wt")
    assert claimed is not None
    assert claimed["agent_id"] == "agent-abc"
    assert claimed["lease_id"] == lease["lease_id"]


def test_claim_returns_none_for_released_lease(conn):
    lease = leases.issue(conn, role="implementer", worktree_path="/repo/wt")
    leases.release(conn, lease["lease_id"])
    result = leases.claim(conn, agent_id="agent-x", worktree_path="/repo/wt")
    assert result is None


def test_claim_returns_none_for_revoked_lease(conn):
    lease = leases.issue(conn, role="implementer", worktree_path="/repo/wt")
    leases.revoke(conn, lease["lease_id"])
    result = leases.claim(conn, agent_id="agent-x", worktree_path="/repo/wt")
    assert result is None


def test_claim_returns_none_when_no_active_lease(conn):
    result = leases.claim(conn, agent_id="agent-x", worktree_path="/repo/nonexistent")
    assert result is None


def test_claim_revokes_existing_active_lease_for_same_agent(conn):
    """One-lease-per-agent invariant: claiming a new lease revokes the old one."""
    lease_a = leases.issue(conn, role="implementer", worktree_path="/repo/wt-a")
    leases.claim(conn, agent_id="agent-1", worktree_path="/repo/wt-a")

    lease_b = leases.issue(conn, role="tester", worktree_path="/repo/wt-b")
    # Claiming lease_b with agent-1 should revoke lease_a for that agent.
    leases.claim(conn, agent_id="agent-1", lease_id=lease_b["lease_id"])

    refreshed_a = leases.get(conn, lease_a["lease_id"])
    assert refreshed_a["status"] == "revoked"


def test_claim_by_lease_id_takes_priority(conn):
    lease = leases.issue(conn, role="implementer")
    claimed = leases.claim(conn, agent_id="agent-z", lease_id=lease["lease_id"])
    assert claimed is not None
    assert claimed["agent_id"] == "agent-z"


# ---------------------------------------------------------------------------
# get_current() resolution priority
# ---------------------------------------------------------------------------


def test_get_current_priority_lease_id_over_agent(conn):
    lease1 = leases.issue(conn, role="implementer", worktree_path="/repo/wt1")
    lease2 = leases.issue(conn, role="tester", worktree_path="/repo/wt2")
    leases.claim(conn, "agent-x", lease_id=lease2["lease_id"])

    # lease_id should win over agent_id.
    result = leases.get_current(conn, lease_id=lease1["lease_id"], agent_id="agent-x")
    assert result["lease_id"] == lease1["lease_id"]


def test_get_current_priority_agent_over_worktree(conn):
    leases.issue(conn, role="implementer", worktree_path="/repo/wt1")
    lease2 = leases.issue(conn, role="tester", worktree_path="/repo/wt2")
    leases.claim(conn, "agent-x", lease_id=lease2["lease_id"])

    result = leases.get_current(conn, agent_id="agent-x", worktree_path="/repo/wt1")
    assert result["lease_id"] == lease2["lease_id"]


def test_get_current_priority_worktree_over_workflow(conn):
    lease1 = leases.issue(conn, role="implementer", worktree_path="/repo/wt1", workflow_id="wf-1")
    leases.issue(conn, role="tester", worktree_path="/repo/wt2", workflow_id="wf-2")

    result = leases.get_current(conn, worktree_path="/repo/wt1", workflow_id="wf-2")
    assert result["lease_id"] == lease1["lease_id"]


def test_get_current_returns_none_for_non_active_lease(conn):
    lease = leases.issue(conn, role="implementer", worktree_path="/repo/wt")
    leases.release(conn, lease["lease_id"])
    result = leases.get_current(conn, worktree_path="/repo/wt")
    assert result is None


def test_get_current_returns_none_when_nothing_found(conn):
    result = leases.get_current(conn, worktree_path="/repo/ghost")
    assert result is None


# ---------------------------------------------------------------------------
# validate_op()
# ---------------------------------------------------------------------------


def test_validate_op_allowed_with_lease_and_allowed_op(conn):
    leases.issue(
        conn,
        role="implementer",
        worktree_path="/repo/wt",
        allowed_ops=["routine_local"],
        requires_eval=False,
    )
    result = leases.validate_op(conn, "git commit -m 'x'", worktree_path="/repo/wt")
    assert result["op_class"] == "routine_local"
    assert result["allowed"] is True


def test_validate_op_denied_when_op_not_in_allowed_ops(conn):
    leases.issue(
        conn,
        role="implementer",
        worktree_path="/repo/wt",
        allowed_ops=["routine_local"],
        requires_eval=False,
    )
    result = leases.validate_op(conn, "git push origin main", worktree_path="/repo/wt")
    assert result["op_class"] == "high_risk"
    assert result["allowed"] is False
    assert "not in allowed_ops" in result["reason"]


def test_validate_op_denied_when_no_lease(conn):
    result = leases.validate_op(conn, "git commit -m 'x'", worktree_path="/repo/ghost")
    assert result["allowed"] is False
    assert result["op_class"] == "routine_local"  # op_class always populated
    assert result["lease_id"] is None


def test_validate_op_denied_when_lease_expired(conn):
    """A lease whose expires_at is in the past should deny ops."""
    past = int(time.time()) - 100
    lease = leases.issue(
        conn,
        role="implementer",
        worktree_path="/repo/wt",
        allowed_ops=["routine_local"],
        requires_eval=False,
        ttl=7200,
    )
    # Manually backdate expires_at to simulate expiry.
    with conn:
        conn.execute(
            "UPDATE dispatch_leases SET expires_at = ? WHERE lease_id = ?",
            (past, lease["lease_id"]),
        )
    result = leases.validate_op(conn, "git commit -m 'x'", worktree_path="/repo/wt")
    assert result["allowed"] is False
    assert "expired" in result["reason"]


def test_validate_op_class_always_present_without_lease(conn):
    """op_class must be in result even when there is no active lease."""
    result = leases.validate_op(conn, "git rebase main", worktree_path="/repo/none")
    assert "op_class" in result
    assert result["op_class"] == "high_risk"
    assert result["lease_id"] is None


# ---------------------------------------------------------------------------
# release() / revoke()
# ---------------------------------------------------------------------------


def test_release_transitions_active_to_released(conn):
    lease = leases.issue(conn, role="implementer")
    result = leases.release(conn, lease["lease_id"])
    assert result is True
    refreshed = leases.get(conn, lease["lease_id"])
    assert refreshed["status"] == "released"
    assert refreshed["released_at"] is not None


def test_release_non_active_returns_false(conn):
    lease = leases.issue(conn, role="implementer")
    leases.release(conn, lease["lease_id"])
    # Second release on already-released lease.
    result = leases.release(conn, lease["lease_id"])
    assert result is False


def test_revoke_transitions_active_to_revoked(conn):
    lease = leases.issue(conn, role="implementer")
    result = leases.revoke(conn, lease["lease_id"])
    assert result is True
    refreshed = leases.get(conn, lease["lease_id"])
    assert refreshed["status"] == "revoked"


# ---------------------------------------------------------------------------
# expire_stale()
# ---------------------------------------------------------------------------


def test_expire_stale_transitions_past_ttl_leases(conn):
    lease = leases.issue(conn, role="implementer", ttl=10)
    future_now = int(time.time()) + 100
    count = leases.expire_stale(conn, now=future_now)
    assert count == 1
    refreshed = leases.get(conn, lease["lease_id"])
    assert refreshed["status"] == "expired"


def test_expire_stale_does_not_touch_future_leases(conn):
    # TTL of 2 hours — far from expired.
    lease = leases.issue(conn, role="implementer", ttl=7200)
    count = leases.expire_stale(conn, now=int(time.time()))
    assert count == 0
    refreshed = leases.get(conn, lease["lease_id"])
    assert refreshed["status"] == "active"


def test_expire_stale_does_not_touch_non_active_leases(conn):
    lease = leases.issue(conn, role="implementer", ttl=10)
    leases.release(conn, lease["lease_id"])  # already released
    count = leases.expire_stale(conn, now=int(time.time()) + 100)
    assert count == 0  # released lease not touched by expire_stale


# ---------------------------------------------------------------------------
# Full lifecycle (compound interaction)
# ---------------------------------------------------------------------------


def test_full_lifecycle(conn):
    """Compound test: issue → claim → release → validate returns no active lease.

    This exercises the real production sequence:
      1. Orchestrator issues a lease at dispatch time.
      2. Agent claims the lease on startup.
      3. validate_op passes for allowed ops during the session.
      4. Agent releases the lease on completion.
      5. Subsequent validate_op finds no active lease (denied).
    """
    wt = "/repo/feature-lifecycle"

    # Step 1: issue
    lease = leases.issue(
        conn,
        role="implementer",
        worktree_path=wt,
        allowed_ops=["routine_local"],
        requires_eval=False,
    )
    assert lease["status"] == "active"

    # Step 2: claim
    claimed = leases.claim(conn, agent_id="agent-lc", worktree_path=wt)
    assert claimed["agent_id"] == "agent-lc"

    # Step 3: validate_op while active
    v = leases.validate_op(conn, "git commit -m 'work'", worktree_path=wt)
    assert v["allowed"] is True

    # Step 4: release
    leases.release(conn, lease["lease_id"])

    # Step 5: validate after release — no active lease
    v2 = leases.validate_op(conn, "git commit -m 'work'", worktree_path=wt)
    assert v2["allowed"] is False
    assert v2["lease_id"] is None


# ---------------------------------------------------------------------------
# render_startup_contract()
# ---------------------------------------------------------------------------


def test_render_startup_contract_contains_expected_fields(conn):
    lease = leases.issue(
        conn,
        role="implementer",
        worktree_path="/repo/wt",
        workflow_id="wf-123",
        branch="feature/foo",
        next_step="run tests",
        allowed_ops=["routine_local"],
    )
    text = leases.render_startup_contract(lease)
    assert f"LEASE_ID={lease['lease_id']}" in text
    assert "Role: implementer" in text
    assert "Workflow: wf-123" in text
    assert "Worktree: /repo/wt" in text
    assert "Branch: feature/foo" in text
    assert "routine_local" in text
    assert "Next step: run tests" in text
    assert "Expires:" in text


# ---------------------------------------------------------------------------
# Concurrent worktrees — no collision
# ---------------------------------------------------------------------------


def test_concurrent_worktrees_no_collision(conn):
    """Two leases for different worktrees are fully independent.

    Each worktree resolves to its own active lease — validate_op on /repo/a
    never bleeds into /repo/b and vice versa. Both leases allow routine_local
    ops so this test isolates the worktree-resolution invariant without
    entangling the approval-token path.
    """
    lease_a = leases.issue(
        conn,
        role="implementer",
        worktree_path="/repo/a",
        workflow_id="wf-a",
        allowed_ops=["routine_local"],
        requires_eval=False,
    )
    lease_b = leases.issue(
        conn,
        role="tester",
        worktree_path="/repo/b",
        workflow_id="wf-b",
        allowed_ops=["routine_local"],
        requires_eval=False,
    )

    # Both are active with no interference.
    assert leases.get(conn, lease_a["lease_id"])["status"] == "active"
    assert leases.get(conn, lease_b["lease_id"])["status"] == "active"

    # validate_op on each worktree resolves to the correct lease independently.
    va = leases.validate_op(conn, "git commit -m 'work on a'", worktree_path="/repo/a")
    vb = leases.validate_op(conn, "git commit -m 'work on b'", worktree_path="/repo/b")

    assert va["allowed"] is True
    assert va["lease_id"] == lease_a["lease_id"]

    assert vb["allowed"] is True
    assert vb["lease_id"] == lease_b["lease_id"]


# ---------------------------------------------------------------------------
# admin_recovery classification (DEC-LEASE-002)
# ---------------------------------------------------------------------------


def test_classify_merge_abort_is_admin_recovery():
    assert leases.classify_git_op("git merge --abort") == "admin_recovery"


def test_classify_reset_merge_is_admin_recovery():
    assert leases.classify_git_op("git reset --merge") == "admin_recovery"


def test_classify_reset_hard_is_still_high_risk():
    """reset --hard predates admin_recovery and must remain high_risk."""
    assert leases.classify_git_op("git reset --hard HEAD~1") == "high_risk"


def test_classify_reset_hard_is_still_high_risk_no_ref():
    assert leases.classify_git_op("git reset --hard") == "high_risk"


def test_classify_merge_no_abort_is_routine_local():
    """A plain merge (no --abort) stays routine_local."""
    assert leases.classify_git_op("git merge feature/x") == "routine_local"


def test_classify_merge_with_c_flag_and_abort():
    """git -C /path merge --abort should also classify as admin_recovery."""
    assert leases.classify_git_op("git -C /some/path merge --abort") == "admin_recovery"


def test_classify_reset_merge_with_c_flag():
    assert leases.classify_git_op("git -C /repo reset --merge") == "admin_recovery"


# ---------------------------------------------------------------------------
# validate_op — admin_recovery semantics (DEC-LEASE-002)
# ---------------------------------------------------------------------------


def test_validate_op_admin_recovery_skips_eval_check(conn):
    """Admin recovery with lease + approval does not require eval readiness.

    This is the core invariant: merge --abort / reset --merge must not be
    blocked by evaluation_state gate. The repo is in a mid-merge state and
    evaluation_state is meaningless in that context.
    """
    import runtime.core.approvals as approvals

    lease = leases.issue(
        conn,
        "guardian",
        worktree_path="/wt",
        allowed_ops=["routine_local", "high_risk", "admin_recovery"],
        requires_eval=True,
        workflow_id="wf-1",
    )
    assert lease is not None

    # Do NOT set evaluation_state — it must not matter for admin_recovery.
    # Grant the approval token that admin_recovery requires.
    approvals.grant(conn, "wf-1", "admin_recovery")

    result = leases.validate_op(conn, "git reset --merge", worktree_path="/wt")
    assert result["op_class"] == "admin_recovery"
    assert result["eval_ok"] is None  # eval check was skipped entirely
    assert result["requires_approval"] is True
    assert result["approval_ok"] is True
    assert result["allowed"] is True


def test_validate_op_merge_abort_skips_eval_check(conn):
    """merge --abort variant of admin_recovery also skips eval."""
    import runtime.core.approvals as approvals

    leases.issue(
        conn,
        "guardian",
        worktree_path="/wt2",
        allowed_ops=["routine_local", "high_risk", "admin_recovery"],
        requires_eval=True,
        workflow_id="wf-2",
    )
    approvals.grant(conn, "wf-2", "admin_recovery")

    result = leases.validate_op(conn, "git merge --abort", worktree_path="/wt2")
    assert result["op_class"] == "admin_recovery"
    assert result["eval_ok"] is None
    assert result["allowed"] is True


def test_validate_op_admin_recovery_denied_without_lease(conn):
    """admin_recovery without a lease must be denied — lease gate always applies."""
    result = leases.validate_op(conn, "git reset --merge", worktree_path="/wt-no-lease")
    assert result["allowed"] is False
    assert result["op_class"] == "admin_recovery"
    assert result["lease_id"] is None
    assert "no active lease" in result["reason"]


def test_validate_op_admin_recovery_denied_without_approval(conn):
    """admin_recovery with a lease but no approval token must be denied."""
    leases.issue(
        conn,
        "guardian",
        worktree_path="/wt3",
        allowed_ops=["routine_local", "high_risk", "admin_recovery"],
        workflow_id="wf-3",
    )
    # No approvals.grant() call — token missing.
    result = leases.validate_op(conn, "git reset --merge", worktree_path="/wt3")
    assert result["allowed"] is False
    assert result["requires_approval"] is True
    assert result["approval_ok"] is False


def test_validate_op_admin_recovery_denied_when_not_in_allowed_ops(conn):
    """admin_recovery op denied if lease does not include it in allowed_ops."""
    import runtime.core.approvals as approvals

    leases.issue(
        conn,
        "implementer",
        worktree_path="/wt4",
        allowed_ops=["routine_local"],  # admin_recovery NOT listed
        workflow_id="wf-4",
    )
    approvals.grant(conn, "wf-4", "admin_recovery")

    result = leases.validate_op(conn, "git merge --abort", worktree_path="/wt4")
    assert result["allowed"] is False
    assert result["op_class"] == "admin_recovery"
    assert "not in allowed_ops" in result["reason"]


def test_validate_op_routine_landing_still_requires_eval(conn):
    """Introducing admin_recovery must not weaken the eval gate for routine_local.

    This is the regression test: the admin_recovery exemption must be scoped
    narrowly — routine commits must still require evaluation readiness.
    """
    leases.issue(
        conn,
        "implementer",
        worktree_path="/wt5",
        allowed_ops=["routine_local"],
        requires_eval=True,
        workflow_id="wf-5",
    )
    # No evaluation state set — eval_ok must be False, allowed must be False.
    result = leases.validate_op(conn, "git commit -m test", worktree_path="/wt5")
    assert result["op_class"] == "routine_local"
    assert result["eval_ok"] is False
    assert result["allowed"] is False
    assert "ready_for_guardian" in result["reason"]


def test_validate_op_high_risk_still_requires_eval_and_approval(conn):
    """high_risk ops are unchanged by the admin_recovery introduction.

    A push/rebase/reset --hard must still fail both eval and approval gates.
    """
    leases.issue(
        conn,
        "guardian",
        worktree_path="/wt6",
        allowed_ops=["routine_local", "high_risk"],
        requires_eval=True,
        workflow_id="wf-6",
    )
    # No eval state, no approval — push must be denied at eval gate first.
    result = leases.validate_op(conn, "git push origin main", worktree_path="/wt6")
    assert result["op_class"] == "high_risk"
    assert result["eval_ok"] is False
    assert result["allowed"] is False


# ---------------------------------------------------------------------------
# ROLE_DEFAULTS — per-role allowed_ops defaults (DEC-LEASE-003)
# ---------------------------------------------------------------------------


def test_role_safe_defaults_guardian(conn):
    """issue(role='guardian') must include all three op classes without caller specifying."""
    import json

    lease = leases.issue(conn, role="guardian")
    allowed = json.loads(lease["allowed_ops_json"])
    assert "routine_local" in allowed
    assert "high_risk" in allowed
    assert "admin_recovery" in allowed


def test_role_safe_defaults_tester(conn):
    """issue(role='tester') must produce an empty allowed_ops list."""
    import json

    lease = leases.issue(conn, role="tester")
    allowed = json.loads(lease["allowed_ops_json"])
    assert allowed == []


def test_role_safe_defaults_implementer(conn):
    """issue(role='implementer') must produce ['routine_local'] — unchanged from old default."""
    import json

    lease = leases.issue(conn, role="implementer")
    allowed = json.loads(lease["allowed_ops_json"])
    assert allowed == ["routine_local"]


def test_role_safe_defaults_planner(conn):
    """issue(role='planner') must produce an empty allowed_ops list."""
    import json

    lease = leases.issue(conn, role="planner")
    allowed = json.loads(lease["allowed_ops_json"])
    assert allowed == []


def test_role_safe_defaults_unknown_role(conn):
    """issue(role='unknown') falls back to ['routine_local'] for safety."""
    import json

    lease = leases.issue(conn, role="unknown")
    allowed = json.loads(lease["allowed_ops_json"])
    assert allowed == ["routine_local"]


def test_role_safe_defaults_explicit_override(conn):
    """Explicit allowed_ops= overrides ROLE_DEFAULTS regardless of role."""
    import json

    lease = leases.issue(conn, role="tester", allowed_ops=["routine_local"])
    allowed = json.loads(lease["allowed_ops_json"])
    assert allowed == ["routine_local"]


# ---------------------------------------------------------------------------
# claim() expected_role enforcement
# ---------------------------------------------------------------------------


def test_claim_expected_role_match(conn):
    """Claim with expected_role matching the lease role succeeds."""
    leases.issue(conn, role="tester", worktree_path="/repo/wt-tester")
    result = leases.claim(
        conn, agent_id="agent-t", worktree_path="/repo/wt-tester", expected_role="tester"
    )
    assert result is not None
    assert result["agent_id"] == "agent-t"
    assert result["role"] == "tester"


def test_claim_expected_role_mismatch(conn):
    """Claim with expected_role not matching the lease role returns None.

    This is the key safety invariant: a tester cannot claim a guardian lease.
    """
    leases.issue(conn, role="guardian", worktree_path="/repo/wt-guardian")
    result = leases.claim(
        conn, agent_id="agent-t", worktree_path="/repo/wt-guardian", expected_role="tester"
    )
    assert result is None


def test_claim_no_expected_role(conn):
    """Claim without expected_role succeeds regardless of lease role (backward compat)."""
    leases.issue(conn, role="guardian", worktree_path="/repo/wt-g2")
    result = leases.claim(conn, agent_id="agent-g", worktree_path="/repo/wt-g2")
    assert result is not None
    assert result["role"] == "guardian"
