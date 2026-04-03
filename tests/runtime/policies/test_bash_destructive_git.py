"""Unit tests for bash_destructive_git policy.

Exercises hard denial of git reset --hard, git clean -f, and git branch -D
(DEC-PE-W3-004). These are unconditional denies — no approval token overrides.

Production trigger: PreToolUse Bash hook — any git command matching those
three destructive patterns.

@decision DEC-PE-W3-TEST-004
@title Unit tests for bash_destructive_git policy
@status accepted
@rationale Verify all three destructive patterns are caught unconditionally.
  Safe alternatives (git stash, git clean -n, git branch -d) must pass through.
  Tests confirm the policy_name and reason text so monitoring can attribute
  denials to the correct guard.
"""

from __future__ import annotations

from runtime.core.policies.bash_destructive_git import check
from tests.runtime.policies.conftest import make_request

# ---------------------------------------------------------------------------
# Deny: git reset --hard
# ---------------------------------------------------------------------------


def test_reset_hard_denied():
    req = make_request("git reset --hard HEAD~1")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "reset --hard" in decision.reason
    assert decision.policy_name == "bash_destructive_git"


def test_reset_hard_origin_main_denied():
    req = make_request("git reset --hard origin/main")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"


def test_reset_hard_suggests_stash():
    req = make_request("git reset --hard HEAD")
    decision = check(req)
    assert decision is not None
    assert "stash" in decision.reason.lower() or "backup" in decision.reason.lower()


# ---------------------------------------------------------------------------
# Deny: git clean -f
# ---------------------------------------------------------------------------


def test_clean_f_denied():
    req = make_request("git clean -f")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "clean -f" in decision.reason
    assert decision.policy_name == "bash_destructive_git"


def test_clean_fd_denied():
    """git clean -fd (directories too) should also be caught."""
    req = make_request("git clean -fd")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"


def test_clean_f_suggests_dry_run():
    req = make_request("git clean -f")
    decision = check(req)
    assert decision is not None
    assert "dry run" in decision.reason.lower() or "-n" in decision.reason


# ---------------------------------------------------------------------------
# Deny: git branch -D
# ---------------------------------------------------------------------------


def test_branch_D_denied():
    req = make_request("git branch -D feature/old")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "branch -D" in decision.reason
    assert decision.policy_name == "bash_destructive_git"


def test_branch_D_suggests_lowercase_d():
    req = make_request("git branch -D my-branch")
    decision = check(req)
    assert decision is not None
    assert "-d" in decision.reason or "lowercase" in decision.reason.lower()


# ---------------------------------------------------------------------------
# Allow / skip — safe alternatives and non-matching commands
# ---------------------------------------------------------------------------


def test_reset_soft_allowed():
    req = make_request("git reset --soft HEAD~1")
    decision = check(req)
    assert decision is None


def test_clean_dry_run_allowed():
    req = make_request("git clean -n")
    decision = check(req)
    assert decision is None


def test_branch_lowercase_d_allowed():
    req = make_request("git branch -d merged-branch")
    decision = check(req)
    assert decision is None


def test_git_status_skipped():
    req = make_request("git status")
    decision = check(req)
    assert decision is None


def test_empty_command_skipped():
    req = make_request("")
    decision = check(req)
    assert decision is None
