"""Unit tests for bash_git_who policy.

Exercises lease-based WHO enforcement for git commit/merge/push (DEC-PE-W3-008).
Production trigger: PreToolUse Bash hook — git commit, merge, or push when
no valid active lease covers the operation class.

Lease data is injected via PolicyContext — no DB I/O needed.

@decision DEC-PE-W3-TEST-008
@title Unit tests for bash_git_who policy
@status accepted
@rationale Verify all deny branches: no lease, expired lease, op_class in
  blocked_ops, op_class not in allowed_ops. Also verify meta-repo bypass,
  non-git-op skip, and the nominal allow path (valid lease, op in allowed_ops).
  Lease dicts are constructed inline so tests remain hermetic.
"""

from __future__ import annotations

import time

from runtime.core.policies.bash_git_who import check
from tests.runtime.policies.conftest import make_context, make_request


def _future_expiry():
    return int(time.time()) + 3600


def _past_expiry():
    return int(time.time()) - 1


def _make_lease(
    *,
    allowed_ops=None,
    blocked_ops=None,
    expires_at=None,
    workflow_id="feature-test",
):
    import json

    return {
        "workflow_id": workflow_id,
        "expires_at": expires_at if expires_at is not None else _future_expiry(),
        "allowed_ops_json": json.dumps(allowed_ops or ["routine_local"]),
        "blocked_ops_json": json.dumps(blocked_ops or []),
    }


# ---------------------------------------------------------------------------
# Deny: no lease
# ---------------------------------------------------------------------------


def test_no_lease_commit_denied():
    ctx = make_context(lease=None)
    req = make_request("git commit -m 'add feature'", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "lease" in decision.reason.lower()
    assert decision.policy_name == "bash_git_who"


def test_no_lease_merge_denied():
    ctx = make_context(lease=None)
    req = make_request("git merge feature/foo", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"


def test_no_lease_push_denied():
    ctx = make_context(lease=None)
    req = make_request("git push origin feature/bar", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    # Should signal stale lease expiry effect
    assert decision.effects is not None
    assert "expire_stale_leases" in decision.effects


# ---------------------------------------------------------------------------
# Deny: expired lease
# ---------------------------------------------------------------------------


def test_expired_lease_denied():
    lease = _make_lease(expires_at=_past_expiry())
    ctx = make_context(lease=lease)
    req = make_request("git commit -m 'fix'", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "expired" in decision.reason.lower()
    assert decision.effects is not None
    assert decision.effects.get("expire_stale_leases") is True


# ---------------------------------------------------------------------------
# Deny: op_class in blocked_ops
# ---------------------------------------------------------------------------


def test_op_in_blocked_ops_denied():
    # classify_git_op("git push ...") returns "high_risk" — use the real op_class.
    lease = _make_lease(
        allowed_ops=["routine_local", "high_risk"],
        blocked_ops=["high_risk"],
    )
    ctx = make_context(lease=lease)
    req = make_request("git push origin feature/foo", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "blocked_ops" in decision.reason


# ---------------------------------------------------------------------------
# Deny: op_class not in allowed_ops
# ---------------------------------------------------------------------------


def test_op_not_in_allowed_ops_denied():
    lease = _make_lease(allowed_ops=["routine_local"])
    ctx = make_context(lease=lease)
    # push is classified as high_risk / push, not routine_local
    req = make_request("git push origin feature/bar", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "allowed_ops" in decision.reason


# ---------------------------------------------------------------------------
# Allow: valid lease, op in allowed_ops
# ---------------------------------------------------------------------------


def test_commit_with_valid_lease_allowed():
    lease = _make_lease(allowed_ops=["routine_local"])
    ctx = make_context(lease=lease)
    req = make_request("git commit -m 'feat: add thing'", context=ctx)
    decision = check(req)
    assert decision is None


def test_push_allowed_when_in_allowed_ops():
    # classify_git_op("git push ...") returns "high_risk" — include that class.
    lease = _make_lease(allowed_ops=["routine_local", "high_risk"])
    ctx = make_context(lease=lease)
    req = make_request("git push origin feature/done", context=ctx)
    decision = check(req)
    assert decision is None


# ---------------------------------------------------------------------------
# Bypass: meta-repo
# ---------------------------------------------------------------------------


def test_meta_repo_commit_bypasses_who():
    ctx = make_context(is_meta_repo=True, lease=None)
    req = make_request("git commit -m 'config'", context=ctx)
    decision = check(req)
    assert decision is None


# ---------------------------------------------------------------------------
# Skip: non-git-op commands
# ---------------------------------------------------------------------------


def test_git_status_skipped():
    ctx = make_context(lease=None)
    req = make_request("git status", context=ctx)
    decision = check(req)
    assert decision is None


def test_empty_command_skipped():
    ctx = make_context(lease=None)
    req = make_request("", context=ctx)
    decision = check(req)
    assert decision is None


def test_non_git_command_skipped():
    ctx = make_context(lease=None)
    req = make_request("ls -la", context=ctx)
    decision = check(req)
    assert decision is None


def test_natural_language_prompt_with_git_commit_is_skipped():
    ctx = make_context(lease=None)
    req = make_request('node tool.mjs task "investigate git commit gating"', context=ctx)
    decision = check(req)
    assert decision is None


def test_echo_git_push_argument_is_skipped():
    ctx = make_context(lease=None)
    req = make_request("echo git push", context=ctx)
    decision = check(req)
    assert decision is None


def test_nested_shell_git_push_still_denied_without_lease():
    ctx = make_context(lease=None)
    req = make_request('bash -lc "git push origin main"', context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert decision.policy_name == "bash_git_who"


# ---------------------------------------------------------------------------
# Phase 3: READ_ONLY_REVIEW capability gate
# ---------------------------------------------------------------------------


def test_reviewer_read_only_denies_git_commit_even_with_valid_lease():
    """Reviewer with READ_ONLY_REVIEW capability is denied git commit
    even when a lease with routine_local is present."""
    lease = _make_lease(allowed_ops=["routine_local"])
    lease["role"] = "reviewer"
    ctx = make_context(actor_role="reviewer", lease=lease)
    req = make_request("git commit -m 'should not happen'", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "read-only" in decision.reason.lower()
    assert decision.policy_name == "bash_git_who"


def test_reviewer_read_only_denies_git_merge():
    """Reviewer is denied git merge regardless of lease."""
    lease = _make_lease(allowed_ops=["routine_local"])
    lease["role"] = "reviewer"
    ctx = make_context(actor_role="reviewer", lease=lease)
    req = make_request("git merge feature/foo", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "read-only" in decision.reason.lower()


def test_reviewer_read_only_denies_git_push():
    """Reviewer is denied git push even with a permissive lease."""
    lease = _make_lease(allowed_ops=["routine_local", "high_risk"])
    lease["role"] = "reviewer"
    ctx = make_context(actor_role="reviewer", lease=lease)
    req = make_request("git push origin main", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "read-only" in decision.reason.lower()


def test_arbitrary_role_with_read_only_review_injected_is_denied():
    """The gate keys off READ_ONLY_REVIEW capability, not the role string.
    An arbitrary role name with the capability injected must be denied."""
    from runtime.core.authority_registry import (
        CAN_EMIT_DISPATCH_TRANSITION,
        READ_ONLY_REVIEW,
    )
    from runtime.core.policy_engine import PolicyContext

    lease = _make_lease(allowed_ops=["routine_local"])
    lease["role"] = "custom_auditor"
    ctx = PolicyContext(
        actor_role="custom_auditor",
        actor_id="agent-test",
        workflow_id="feature-test",
        worktree_path="/project/.worktrees/feature-test",
        branch="feature/test",
        project_root="/project",
        is_meta_repo=False,
        lease=lease,
        scope=None,
        eval_state=None,
        test_state=None,
        binding=None,
        dispatch_phase=None,
        capabilities=frozenset({READ_ONLY_REVIEW, CAN_EMIT_DISPATCH_TRANSITION}),
    )
    req = make_request("git commit -m 'audit trail'", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "read-only" in decision.reason.lower()


def test_implementer_with_valid_lease_still_allowed_for_commit():
    """Implementer with CAN_WRITE_SOURCE and a valid lease for routine_local
    is still allowed — the READ_ONLY_REVIEW gate must not affect non-reviewer
    stages."""
    lease = _make_lease(allowed_ops=["routine_local"])
    lease["role"] = "implementer"
    ctx = make_context(actor_role="implementer", lease=lease)
    req = make_request("git commit -m 'feat: add thing'", context=ctx)
    decision = check(req)
    assert decision is None


def test_meta_repo_bypass_unaffected_by_read_only():
    """Meta-repo bypass fires before the READ_ONLY_REVIEW check —
    reviewer in meta-repo is not denied."""
    ctx = make_context(actor_role="reviewer", is_meta_repo=True, lease=None)
    req = make_request("git commit -m 'config update'", context=ctx)
    decision = check(req)
    assert decision is None


def test_reviewer_non_git_command_still_skipped():
    """READ_ONLY_REVIEW gate only fires for classified git ops.
    Non-git commands are skipped regardless of capability."""
    ctx = make_context(actor_role="reviewer", lease=None)
    req = make_request("ls -la", context=ctx)
    decision = check(req)
    assert decision is None


def test_reviewer_git_status_still_skipped():
    """git status is classified as 'unclassified' — skipped before
    READ_ONLY_REVIEW gate fires."""
    ctx = make_context(actor_role="reviewer", lease=None)
    req = make_request("git status", context=ctx)
    decision = check(req)
    assert decision is None


# ---------------------------------------------------------------------------
# DEC-PE-GIT-WHO-LEASE-DENY-DIAG-001
# Distinguish "no lease exists" from "lease exists but not attachable".
#
# All three branches below DENY — diagnostic classification only; enforcement
# is unchanged.  The tests pin the distinct wording so operators cannot mistake
# one remediation class for the other.
# ---------------------------------------------------------------------------


def test_no_lease_and_no_suppressed_roles_uses_original_wording():
    """Truly no lease anywhere on the worktree — original 'issue-for-dispatch'
    remediation text applies."""
    ctx = make_context(
        actor_role="implementer",
        lease=None,
        worktree_lease_suppressed_roles=frozenset(),
    )
    req = make_request("git commit -m 'add feature'", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert decision.policy_name == "bash_git_who"
    # Original wording fragments preserved.
    assert "No active dispatch lease" in decision.reason
    assert "issue-for-dispatch" in decision.reason
    # Must NOT claim a lease exists — there isn't one in this scenario.
    assert "Active lease(s)" not in decision.reason
    # Effect preserved (expire_stale_leases sweep).
    assert decision.effects is not None
    assert decision.effects.get("expire_stale_leases") is True


def test_no_lease_but_worktree_has_guardian_lease_and_empty_actor_role():
    """Orchestrator path (actor_role="") with a guardian lease present on the
    worktree — emit explicit actor-role-unresolved diagnostic naming the
    suppressed role, and must NOT tell operator to re-issue the lease."""
    ctx = make_context(
        actor_role="",
        lease=None,
        worktree_lease_suppressed_roles=frozenset({"guardian"}),
    )
    req = make_request("git commit -m 'checkpoint'", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert decision.policy_name == "bash_git_who"
    # Must name the actual cause — not "missing lease".
    assert "Active lease(s)" in decision.reason
    assert "guardian" in decision.reason
    # Must cite the governing decision so operators can find the rationale.
    assert "DEC-PE-EGAP-BUILD-CTX-001" in decision.reason
    # Must steer operators away from the wrong remediation.
    assert "Do NOT re-issue" in decision.reason
    # Must distinguish from the real "no lease" message — the literal
    # original wording must NOT appear here.
    assert "No active dispatch lease" not in decision.reason
    # Effect preserved.
    assert decision.effects is not None
    assert decision.effects.get("expire_stale_leases") is True


def test_no_lease_but_worktree_has_other_role_lease_and_mismatched_actor():
    """Actor role set (implementer) but worktree only has a guardian lease —
    emit role-mismatch diagnostic naming both the actor role and the holder
    role."""
    ctx = make_context(
        actor_role="implementer",
        lease=None,
        worktree_lease_suppressed_roles=frozenset({"guardian"}),
    )
    req = make_request("git commit -m 'impl work'", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert decision.policy_name == "bash_git_who"
    assert "Active lease(s)" in decision.reason
    assert "guardian" in decision.reason
    assert "'implementer'" in decision.reason
    # Must NOT be the orchestrator branch.
    assert "Do NOT re-issue" not in decision.reason
    # Must NOT be the original "no lease" text.
    assert "No active dispatch lease" not in decision.reason


def test_multiple_suppressed_roles_listed_sorted():
    """When multiple role leases exist on the worktree, all are listed in
    sorted order so the diagnostic is deterministic."""
    ctx = make_context(
        actor_role="",
        lease=None,
        worktree_lease_suppressed_roles=frozenset({"guardian", "implementer"}),
    )
    req = make_request("git commit -m 'x'", context=ctx)
    decision = check(req)
    assert decision is not None
    # Sorted alphabetically: guardian, implementer.
    assert "[guardian, implementer]" in decision.reason


def test_suppressed_roles_ignored_when_lease_actually_attached():
    """When context.lease IS populated, the suppressed-roles field is
    irrelevant — normal allow/role-check/op-class paths fire.  This guarantees
    the new diagnostic cannot regress the happy path."""
    lease = _make_lease(allowed_ops=["routine_local"])
    lease["role"] = "guardian"
    ctx = make_context(
        actor_role="guardian",
        lease=lease,
        worktree_lease_suppressed_roles=frozenset({"guardian"}),
    )
    req = make_request("git commit -m 'landing'", context=ctx)
    decision = check(req)
    # Valid lease → allow (check returns None).
    assert decision is None
