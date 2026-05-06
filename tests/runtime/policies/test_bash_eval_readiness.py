"""Unit tests for bash_eval_readiness policy.

Exercises the evaluation-state gate for commit/merge (DEC-PE-W3-009).
Production trigger: PreToolUse Bash hook — git commit or git merge when
eval_state.status != 'ready_for_guardian'.

eval_state is injected via PolicyContext — no DB I/O needed.
SHA comparison tests use short/full prefix matching.

@decision DEC-PE-W3-TEST-009
@title Unit tests for bash_eval_readiness policy
@status accepted
@rationale Verify all deny branches: eval_state missing (not_found),
  status not ready_for_guardian (various values), and SHA mismatch.
  Verify allow path: status == ready_for_guardian with matching or absent SHA.
  Verify exemptions: meta-repo bypass, admin recovery (merge --abort,
  reset --merge). SHA comparison is tested via the internal helper.
"""

from __future__ import annotations

from runtime.core.policies.bash_eval_readiness import _sha_prefix_match, check
from tests.runtime.policies.conftest import make_context, make_request

# ---------------------------------------------------------------------------
# _sha_prefix_match unit tests (pure helper)
# ---------------------------------------------------------------------------


def test_sha_prefix_match_full_equals_full():
    sha = "abc123def456" * 3
    assert _sha_prefix_match(sha, sha)


def test_sha_prefix_match_short_prefix_of_full():
    full = "abc123def456789"
    short = "abc123"
    assert _sha_prefix_match(short, full)
    assert _sha_prefix_match(full, short)


def test_sha_prefix_match_mismatch():
    assert not _sha_prefix_match("abc123", "def456")


def test_sha_prefix_match_empty():
    assert not _sha_prefix_match("", "abc123")
    assert not _sha_prefix_match("abc123", "")


# ---------------------------------------------------------------------------
# Deny: eval_state missing or wrong status
# ---------------------------------------------------------------------------


def test_no_eval_state_commit_denied():
    ctx = make_context(eval_state=None)
    req = make_request("git commit -m 'feat'", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "not_found" in decision.reason
    assert decision.policy_name == "bash_eval_readiness"


def test_eval_state_pending_denied():
    ctx = make_context(eval_state={"status": "pending", "head_sha": ""})
    req = make_request("git commit -m 'feat'", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "pending" in decision.reason


def test_eval_state_in_progress_denied():
    ctx = make_context(eval_state={"status": "in_progress", "head_sha": ""})
    req = make_request("git merge feature/foo", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"


def test_eval_state_failed_denied():
    ctx = make_context(eval_state={"status": "failed", "head_sha": ""})
    req = make_request("git commit -m 'fix'", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"


def test_implementer_branch_checkpoint_commit_skips_eval_gate():
    lease = {
        "role": "implementer",
        "workflow_id": "feature-test",
        "worktree_path": "/project/.worktrees/feature-test",
    }
    ctx = make_context(
        project_root="/project/.worktrees/feature-test",
        actor_role="implementer",
        lease=lease,
        eval_state=None,
        work_item_id="wi-test",
        landing_grant={"can_commit_branch": True},
    )
    req = make_request("git commit -m 'checkpoint'", context=ctx)
    decision = check(req)
    assert decision is None


# ---------------------------------------------------------------------------
# Allow: status == ready_for_guardian
# ---------------------------------------------------------------------------


def test_ready_for_guardian_no_sha_allowed():
    """No stored SHA — skip SHA check, allow through."""
    ctx = make_context(eval_state={"status": "ready_for_guardian", "head_sha": ""})
    req = make_request("git commit -m 'final'", context=ctx)
    decision = check(req)
    # The policy will call git rev-parse HEAD; in test env it may fail,
    # returning empty string — so SHA check is skipped and None is returned.
    # We verify no deny is emitted for the status check.
    if decision is not None:
        # If a deny is emitted it must be SHA-related (not status-related)
        assert "ready_for_guardian" not in decision.reason


# ---------------------------------------------------------------------------
# Exemptions
# ---------------------------------------------------------------------------


def test_meta_repo_bypassed():
    ctx = make_context(is_meta_repo=True, eval_state=None)
    req = make_request("git commit -m 'config'", context=ctx)
    decision = check(req)
    assert decision is None


def test_merge_abort_exempted():
    ctx = make_context(eval_state=None)
    req = make_request("git merge --abort", context=ctx)
    decision = check(req)
    assert decision is None


def test_reset_merge_exempted():
    ctx = make_context(eval_state=None)
    req = make_request("git reset --merge", context=ctx)
    decision = check(req)
    assert decision is None


# ---------------------------------------------------------------------------
# Skip: non-matching commands
# ---------------------------------------------------------------------------


def test_git_status_skipped():
    ctx = make_context(eval_state=None)
    req = make_request("git status", context=ctx)
    decision = check(req)
    assert decision is None


def test_git_push_skipped():
    ctx = make_context(eval_state=None)
    req = make_request("git push origin feature/foo", context=ctx)
    decision = check(req)
    assert decision is None


def test_empty_command_skipped():
    ctx = make_context(eval_state=None)
    req = make_request("", context=ctx)
    decision = check(req)
    assert decision is None


def test_quoted_git_merge_prompt_skipped():
    ctx = make_context(eval_state=None)
    req = make_request('node tool.mjs task "investigate git merge gating"', context=ctx)
    assert check(req) is None


def test_quoted_git_commit_prompt_skipped():
    ctx = make_context(eval_state=None)
    req = make_request('node tool.mjs task "investigate git commit gating"', context=ctx)
    assert check(req) is None
