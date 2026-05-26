"""Unit tests for bash_test_gate policy.

Exercises the test-pass gate for commit and merge operations (DEC-PE-W3-007).
Production trigger: PreToolUse Bash hook — git commit or git merge when
test_state is not 'pass' or 'pass_complete'.

Two registered checks share this module:
  bash_test_gate_merge (priority=800)
  bash_test_gate_commit (priority=850)

@decision DEC-PE-W3-TEST-007
@title Unit tests for bash_test_gate policy
@status accepted
@rationale Verify that both merge and commit are gated on test_state.
  Tests cover all four relevant test_state values: None (not_found),
  'fail', 'pass', and 'pass_complete'. Meta-repo bypass and merge --abort
  exemption are verified. The test_state is injected via PolicyContext
  so no DB I/O is needed.
"""

from __future__ import annotations

from runtime.core.policies.bash_test_gate import check_commit, check_merge
from tests.runtime.policies.conftest import make_context, make_request

# ---------------------------------------------------------------------------
# check_merge — deny cases
# ---------------------------------------------------------------------------


def test_merge_with_no_test_state_denied():
    ctx = make_context(test_state=None)
    req = make_request("git merge feature/foo", context=ctx)
    decision = check_merge(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "no test results" in decision.reason.lower()
    assert decision.policy_name == "bash_test_gate_merge"


def test_merge_with_failing_tests_denied():
    ctx = make_context(test_state={"status": "fail"})
    req = make_request("git merge feature/bar", context=ctx)
    decision = check_merge(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "fail" in decision.reason


def test_merge_with_unknown_status_denied():
    ctx = make_context(test_state={"status": "unknown"})
    req = make_request("git merge feature/baz", context=ctx)
    decision = check_merge(req)
    assert decision is not None
    assert decision.action == "deny"


# ---------------------------------------------------------------------------
# check_merge — allow cases
# ---------------------------------------------------------------------------


def test_merge_with_passing_tests_allowed():
    ctx = make_context(test_state={"status": "pass"})
    req = make_request("git merge feature/foo", context=ctx)
    decision = check_merge(req)
    assert decision is None


def test_merge_with_pass_complete_allowed():
    ctx = make_context(test_state={"status": "pass_complete"})
    req = make_request("git merge feature/done", context=ctx)
    decision = check_merge(req)
    assert decision is None


def test_merge_abort_exempted():
    """merge --abort is admin recovery — should not be gated."""
    ctx = make_context(test_state=None)
    req = make_request("git merge --abort", context=ctx)
    decision = check_merge(req)
    assert decision is None


def test_merge_meta_repo_bypassed():
    ctx = make_context(is_meta_repo=True, test_state=None)
    req = make_request("git merge feature/config", context=ctx)
    decision = check_merge(req)
    assert decision is None


# ---------------------------------------------------------------------------
# check_commit — deny cases
# ---------------------------------------------------------------------------


def test_commit_with_no_test_state_denied():
    ctx = make_context(test_state=None)
    req = make_request("git commit -m 'add feature'", context=ctx)
    decision = check_commit(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "no test results" in decision.reason.lower()
    assert decision.policy_name == "bash_test_gate_commit"


def test_commit_with_failing_tests_denied():
    ctx = make_context(test_state={"status": "fail"})
    req = make_request("git commit -m 'wip'", context=ctx)
    decision = check_commit(req)
    assert decision is not None
    assert decision.action == "deny"


# ---------------------------------------------------------------------------
# check_commit — allow cases
# ---------------------------------------------------------------------------


def test_commit_with_passing_tests_allowed():
    ctx = make_context(test_state={"status": "pass"})
    req = make_request("git commit -m 'fix'", context=ctx)
    decision = check_commit(req)
    assert decision is None


def test_commit_with_pass_complete_allowed():
    ctx = make_context(test_state={"status": "pass_complete"})
    req = make_request("git commit -m 'done'", context=ctx)
    decision = check_commit(req)
    assert decision is None


def test_commit_meta_repo_bypassed():
    ctx = make_context(is_meta_repo=True, test_state=None)
    req = make_request("git commit -m 'config'", context=ctx)
    decision = check_commit(req)
    assert decision is None


# ---------------------------------------------------------------------------
# Skip cases — non-matching commands
# ---------------------------------------------------------------------------


def test_non_merge_commit_skipped():
    ctx = make_context(test_state=None)
    req = make_request("git status", context=ctx)
    assert check_merge(req) is None
    assert check_commit(req) is None


def test_empty_command_skipped():
    ctx = make_context(test_state=None)
    req = make_request("", context=ctx)
    assert check_merge(req) is None
    assert check_commit(req) is None


def test_quoted_git_merge_prompt_skipped():
    ctx = make_context(test_state=None)
    req = make_request('node tool.mjs task "investigate git merge gating"', context=ctx)
    assert check_merge(req) is None


def test_quoted_git_commit_prompt_skipped():
    ctx = make_context(test_state=None)
    req = make_request('node tool.mjs task "investigate git commit gating"', context=ctx)
    assert check_commit(req) is None
