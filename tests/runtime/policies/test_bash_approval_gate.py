"""Unit tests for bash_approval_gate policy.

Exercises one-shot approval token requirement for approval-gated git
operations (DEC-PE-W3-011). Straightforward push is intentionally excluded.
Production trigger: PreToolUse Bash hook — git rebase, reset (non-hard),
merge --abort, reset --merge, merge --no-ff.

The policy always returns a deny with effects={"check_and_consume_approval": ...}
for approval-gated high-risk/admin_recovery ops. The CLI handler is responsible for checking
whether an approval token exists and overriding the deny if so.

@decision DEC-PE-W3-TEST-011
@title Unit tests for bash_approval_gate policy
@status accepted
@rationale Verify that high-risk and admin_recovery ops produce a deny with
  the correct effects payload so the CLI handler can locate and consume
  the approval token. Verify that routine ops (commit, plain merge) are not
  gated here. Verify the _resolve_op_type helper correctly classifies each
  command form. Non-git commands and empty commands must be skipped.
"""

from __future__ import annotations

from runtime.core.policies.bash_approval_gate import _resolve_op_type, check
from tests.runtime.policies.conftest import make_context, make_request

# ---------------------------------------------------------------------------
# _resolve_op_type unit tests (pure helper)
# ---------------------------------------------------------------------------


def test_op_type_push_not_approval_gated():
    assert _resolve_op_type("git push origin feature/foo") is None


def test_op_type_rebase():
    assert _resolve_op_type("git rebase main") == "rebase"


def test_op_type_merge_abort():
    assert _resolve_op_type("git merge --abort") == "admin_recovery"


def test_op_type_reset_merge():
    assert _resolve_op_type("git reset --merge") == "admin_recovery"


def test_op_type_reset():
    assert _resolve_op_type("git reset HEAD~1") == "reset"


def test_op_type_non_ff_merge():
    assert _resolve_op_type("git merge --no-ff feature/bar") == "non_ff_merge"


def test_op_type_unknown_returns_none():
    assert _resolve_op_type("git status") is None
    assert _resolve_op_type("git commit -m 'fix'") is None


# ---------------------------------------------------------------------------
# Deny with effects: high-risk ops
# ---------------------------------------------------------------------------


def test_push_not_gated():
    ctx = make_context()
    req = make_request("git push origin feature/done", context=ctx)
    decision = check(req)
    assert decision is None


def test_rebase_requires_approval():
    ctx = make_context()
    req = make_request("git rebase main", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    payload = decision.effects.get("check_and_consume_approval", {})
    assert payload.get("op_type") == "rebase"


def test_reset_requires_approval():
    """git reset (not --hard, which is caught earlier by bash_destructive_git)."""
    ctx = make_context()
    req = make_request("git reset HEAD~1", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    payload = decision.effects.get("check_and_consume_approval", {})
    assert payload.get("op_type") == "reset"


def test_non_ff_merge_requires_approval():
    ctx = make_context()
    req = make_request("git merge --no-ff feature/bar", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    payload = decision.effects.get("check_and_consume_approval", {})
    assert payload.get("op_type") == "non_ff_merge"


# ---------------------------------------------------------------------------
# Deny with effects: admin_recovery ops
# ---------------------------------------------------------------------------


def test_merge_abort_requires_approval():
    ctx = make_context()
    req = make_request("git merge --abort", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    payload = decision.effects.get("check_and_consume_approval", {})
    assert payload.get("op_type") == "admin_recovery"


def test_reset_merge_requires_approval():
    ctx = make_context()
    req = make_request("git reset --merge", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    payload = decision.effects.get("check_and_consume_approval", {})
    assert payload.get("op_type") == "admin_recovery"


# ---------------------------------------------------------------------------
# Reason text contains grant guidance
# ---------------------------------------------------------------------------


def test_reason_contains_grant_guidance():
    ctx = make_context()
    req = make_request("git rebase main", context=ctx)
    decision = check(req)
    assert decision is not None
    assert "cc-policy approval grant" in decision.reason


# ---------------------------------------------------------------------------
# Skip: routine ops not gated by approval_gate
# ---------------------------------------------------------------------------


def test_plain_commit_not_gated():
    ctx = make_context()
    req = make_request("git commit -m 'fix'", context=ctx)
    decision = check(req)
    assert decision is None


def test_plain_merge_not_gated():
    """Plain merge (no --no-ff) is routine_local — not high_risk."""
    ctx = make_context()
    req = make_request("git merge feature/foo", context=ctx)
    decision = check(req)
    assert decision is None


def test_git_status_skipped():
    ctx = make_context()
    req = make_request("git status", context=ctx)
    decision = check(req)
    assert decision is None


def test_non_git_command_skipped():
    ctx = make_context()
    req = make_request("ls -la", context=ctx)
    decision = check(req)
    assert decision is None


def test_empty_command_skipped():
    ctx = make_context()
    req = make_request("", context=ctx)
    decision = check(req)
    assert decision is None
