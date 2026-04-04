"""Unit tests for bash_worktree_cwd policy.

Exercises denial of bare cd into .worktrees/ directories (DEC-PE-W3-002).
Production trigger: PreToolUse Bash hook — any cd command whose target
contains '.worktrees/'.

@decision DEC-PE-W3-TEST-002
@title Unit tests for bash_worktree_cwd policy
@status accepted
@rationale Verify that bare cd into a worktree path is denied and that
  all other cd targets (safe directories, non-cd commands) pass through.
  The critical edge cases are commands with and without .worktrees/ in
  the target path.
"""

from __future__ import annotations

from runtime.core.policies.bash_worktree_cwd import check
from tests.runtime.policies.conftest import make_request

# ---------------------------------------------------------------------------
# Deny cases
# ---------------------------------------------------------------------------


def test_bare_cd_into_worktree_denied():
    req = make_request("cd /project/.worktrees/feature-foo")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert ".worktrees/" in decision.reason
    assert decision.policy_name == "bash_worktree_cwd"


def test_cd_into_nested_worktree_path_denied():
    req = make_request("cd /project/.worktrees/feature-bar/src")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"


def test_reason_suggests_git_c_alternative():
    req = make_request("cd /project/.worktrees/feature-baz")
    decision = check(req)
    assert decision is not None
    assert "git -C" in decision.reason


def test_reason_suggests_subshell_alternative():
    req = make_request("cd /project/.worktrees/feature-baz")
    decision = check(req)
    assert decision is not None
    assert "subshell" in decision.reason or "(cd" in decision.reason


# ---------------------------------------------------------------------------
# Allow / skip cases
# ---------------------------------------------------------------------------


def test_cd_to_project_root_allowed():
    req = make_request("cd /project")
    decision = check(req)
    assert decision is None


def test_cd_to_home_allowed():
    req = make_request("cd ~")
    decision = check(req)
    assert decision is None


def test_cd_to_regular_dir_allowed():
    req = make_request("cd /project/src/components")
    decision = check(req)
    assert decision is None


def test_non_cd_command_with_worktree_path_skipped():
    """A non-cd command referencing .worktrees/ is not blocked by this policy."""
    req = make_request("ls /project/.worktrees/feature-foo/")
    decision = check(req)
    assert decision is None


def test_empty_command_skipped():
    req = make_request("")
    decision = check(req)
    assert decision is None


def test_git_c_worktree_command_allowed():
    """git -C .worktrees/... is the recommended alternative — must not be blocked."""
    req = make_request("git -C /project/.worktrees/feature-foo status")
    decision = check(req)
    assert decision is None
