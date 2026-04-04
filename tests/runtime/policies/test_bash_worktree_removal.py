"""Unit tests for bash_worktree_removal policy.

Exercises safe worktree removal enforcement (DEC-PE-W3-005).
Production trigger: PreToolUse Bash hook — git worktree remove commands.

The policy enforces two invariants:
  1. CWD must not be inside the worktree being removed.
  2. The command must include an explicit cd to anchor the CWD.

@decision DEC-PE-W3-TEST-005
@title Unit tests for bash_worktree_removal policy
@status accepted
@rationale Verify both invariants: CWD-inside-worktree is caught, and
  bare worktree remove without a preceding cd is caught. Commands with
  a cd anchor and safe CWD must pass through. Non-worktree-remove
  commands are not affected.
"""

from __future__ import annotations

from runtime.core.policies.bash_worktree_removal import check
from tests.runtime.policies.conftest import make_request

# ---------------------------------------------------------------------------
# Deny: CWD is inside the worktree being removed
# ---------------------------------------------------------------------------


def test_cwd_inside_worktree_denied():
    """Shell CWD is inside the worktree being removed — brick risk."""
    req = make_request(
        "git worktree remove /project/.worktrees/feature-foo",
        cwd="/project/.worktrees/feature-foo/src",
    )
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "cwd" in decision.reason.lower() or "inside" in decision.reason.lower()
    assert decision.policy_name == "bash_worktree_removal"


def test_cwd_exactly_at_worktree_root_denied():
    """CWD exactly at the worktree root is also inside."""
    req = make_request(
        "git worktree remove /project/.worktrees/feature-bar",
        cwd="/project/.worktrees/feature-bar",
    )
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"


# ---------------------------------------------------------------------------
# Deny: no cd anchor in the command
# ---------------------------------------------------------------------------


def test_bare_worktree_remove_without_cd_denied():
    """Command has no cd — CWD is not anchored before removal."""
    req = make_request(
        "git worktree remove /project/.worktrees/feature-baz",
        cwd="/project",
    )
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert decision.policy_name == "bash_worktree_removal"


def test_reason_suggests_cd_then_remove():
    req = make_request(
        "git worktree remove /project/.worktrees/feature-qux",
        cwd="/project",
    )
    decision = check(req)
    assert decision is not None
    assert "cd" in decision.reason


# ---------------------------------------------------------------------------
# Allow: cd anchor present and CWD is safe
# ---------------------------------------------------------------------------


def test_cd_then_remove_from_safe_cwd_allowed():
    """Command includes cd anchor — the safe pattern."""
    req = make_request(
        "cd /project && git worktree remove /project/.worktrees/feature-done",
        cwd="/project",
    )
    decision = check(req)
    assert decision is None


def test_cd_semicolon_then_remove_allowed():
    req = make_request(
        "cd /project; git worktree remove .worktrees/feature-done",
        cwd="/home/user",
    )
    decision = check(req)
    assert decision is None


# ---------------------------------------------------------------------------
# Skip: non-matching commands
# ---------------------------------------------------------------------------


def test_git_worktree_list_skipped():
    req = make_request("git worktree list")
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
