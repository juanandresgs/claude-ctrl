"""Unit tests for bash_tmp_safety policy.

Exercises the sole authority for /tmp write enforcement (DEC-PE-W3-001).
Production trigger: PreToolUse Bash hook — any shell command with a
redirect, mv, cp, tee, or mkdir targeting /tmp or /private/tmp.

@decision DEC-PE-W3-TEST-001
@title Unit tests for bash_tmp_safety policy
@status accepted
@rationale Verify that all /tmp write patterns are denied and that the
  Claude scratchpad exception (/private/tmp/claude-*) is honoured.
  Tests exercise both the deny path and the allow-through path so
  that regressions in either direction are caught immediately.
"""

from __future__ import annotations

from runtime.core.policies.bash_tmp_safety import check
from tests.runtime.policies.conftest import make_context, make_request

# ---------------------------------------------------------------------------
# Deny cases
# ---------------------------------------------------------------------------


def test_redirect_to_tmp_denied():
    req = make_request("echo hello > /tmp/output.txt")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "Sacred Practice #3" in decision.reason
    assert decision.policy_name == "bash_tmp_safety"


def test_redirect_to_private_tmp_denied():
    req = make_request("echo hello > /private/tmp/output.txt")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"


def test_append_redirect_to_tmp_denied():
    req = make_request("echo line >> /tmp/log.txt")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"


def test_mv_to_tmp_denied():
    req = make_request("mv /project/file.txt /tmp/file.txt")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"


def test_cp_to_tmp_denied():
    req = make_request("cp /project/report.md /tmp/report.md")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"


def test_tee_to_tmp_denied():
    req = make_request("echo output | tee /tmp/output.log")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"


def test_mkdir_tmp_denied():
    req = make_request("mkdir /tmp/mydir")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"


def test_mkdir_p_tmp_denied():
    req = make_request("mkdir -p /tmp/mydir/subdir")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"


def test_reason_contains_project_tmp_suggestion():
    ctx = make_context(project_root="/project")
    req = make_request("echo test > /tmp/out.txt", context=ctx)
    decision = check(req)
    assert decision is not None
    assert "/project/tmp" in decision.reason


# ---------------------------------------------------------------------------
# Allow cases (Claude scratchpad exception)
# ---------------------------------------------------------------------------


def test_claude_scratchpad_allowed():
    req = make_request("echo data > /private/tmp/claude-workspace/notes.txt")
    decision = check(req)
    assert decision is None


def test_claude_scratchpad_mkdir_allowed():
    req = make_request("mkdir -p /private/tmp/claude-session/")
    decision = check(req)
    assert decision is None


# ---------------------------------------------------------------------------
# Skip cases (non-matching commands)
# ---------------------------------------------------------------------------


def test_read_from_tmp_not_denied():
    """Reading from /tmp doesn't write to it — should be allowed."""
    req = make_request("cat /tmp/existing.log")
    decision = check(req)
    assert decision is None


def test_non_tmp_command_skipped():
    req = make_request("ls -la /project/tmp/")
    decision = check(req)
    assert decision is None


def test_empty_command_skipped():
    req = make_request("")
    decision = check(req)
    assert decision is None


def test_project_tmp_write_allowed():
    """Writing to project-local tmp/ is fine — only /tmp is blocked."""
    req = make_request("echo data > /project/tmp/output.txt")
    decision = check(req)
    assert decision is None
