"""Unit tests for bash_eval_readiness policy.

v6 gates commit/merge on the single v6_landing_readiness aggregate, not legacy
evaluation_state. SHA comparison accepts full equality or >=12-char prefix.
"""

from __future__ import annotations

from runtime.core.policies.bash_eval_readiness import _sha_prefix_match, check
from tests.runtime.policies.conftest import make_context, make_request


def test_sha_prefix_match_full_equals_full():
    sha = "abc123def456" * 3
    assert _sha_prefix_match(sha, sha)


def test_sha_prefix_match_twelve_char_prefix_of_full():
    full = "abc123def456789"
    short = "abc123def456"
    assert _sha_prefix_match(short, full)
    assert _sha_prefix_match(full, short)


def test_sha_prefix_match_rejects_too_short_prefix():
    assert not _sha_prefix_match("abc123", "abc123def456789")


def test_sha_prefix_match_mismatch():
    assert not _sha_prefix_match("abc123", "def456")


def test_sha_prefix_match_empty():
    assert not _sha_prefix_match("", "abc123")
    assert not _sha_prefix_match("abc123", "")


def test_no_landing_readiness_commit_denied():
    ctx = make_context(landing_readiness=None)
    req = make_request("git commit -m 'feat'", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "not_found" in decision.reason
    assert decision.policy_name == "bash_eval_readiness"


def test_landing_readiness_pending_denied():
    ctx = make_context(landing_readiness={"status": "pending", "head_sha": ""})
    req = make_request("git commit -m 'feat'", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "pending" in decision.reason


def test_landing_readiness_blocked_denied():
    ctx = make_context(landing_readiness={"status": "blocked", "head_sha": ""})
    req = make_request("git merge feature/foo", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"


def test_ready_no_sha_allowed():
    ctx = make_context(landing_readiness={"status": "ready", "head_sha": ""})
    req = make_request("git commit -m 'final'", context=ctx)
    assert check(req) is None


def test_legacy_eval_state_ready_does_not_allow_without_landing_readiness():
    ctx = make_context(
        eval_state={"status": "ready_for_guardian", "head_sha": ""},
        landing_readiness=None,
    )
    req = make_request("git commit -m 'final'", context=ctx)
    decision = check(req)
    assert decision is not None
    assert "v6_landing_readiness" in decision.reason


def test_meta_repo_bypassed():
    ctx = make_context(is_meta_repo=True, landing_readiness=None)
    req = make_request("git commit -m 'config'", context=ctx)
    assert check(req) is None


def test_merge_abort_exempted():
    ctx = make_context(landing_readiness=None)
    req = make_request("git merge --abort", context=ctx)
    assert check(req) is None


def test_reset_merge_skipped():
    ctx = make_context(landing_readiness=None)
    req = make_request("git reset --merge", context=ctx)
    assert check(req) is None


def test_git_status_skipped():
    ctx = make_context(landing_readiness=None)
    req = make_request("git status", context=ctx)
    assert check(req) is None


def test_git_push_skipped():
    ctx = make_context(landing_readiness=None)
    req = make_request("git push origin feature/foo", context=ctx)
    assert check(req) is None


def test_empty_command_skipped():
    ctx = make_context(landing_readiness=None)
    req = make_request("", context=ctx)
    assert check(req) is None


def test_quoted_git_merge_prompt_skipped():
    ctx = make_context(landing_readiness=None)
    req = make_request('node tool.mjs task "investigate git merge gating"', context=ctx)
    assert check(req) is None


def test_quoted_git_commit_prompt_skipped():
    ctx = make_context(landing_readiness=None)
    req = make_request('node tool.mjs task "investigate git commit gating"', context=ctx)
    assert check(req) is None
