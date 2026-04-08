"""Unit tests for bash_force_push policy.

Exercises denial of unsafe force pushes (DEC-PE-W3-003).
Production trigger: PreToolUse Bash hook — git push with --force or -f flags.

@decision DEC-PE-W3-TEST-003
@title Unit tests for bash_force_push policy
@status accepted
@rationale Verify three distinct cases: force push to main/master (hard deny),
  raw --force without --force-with-lease (deny with suggestion), and
  --force-with-lease (allow). Also verifies that regular pushes and
  non-push commands are not affected.
"""

from __future__ import annotations

from runtime.core.policies.bash_force_push import check
from tests.runtime.policies.conftest import make_request

# ---------------------------------------------------------------------------
# Case 1: force push to main/master — hard deny
# ---------------------------------------------------------------------------


def test_force_push_to_main_denied():
    req = make_request("git push --force origin main")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "main/master" in decision.reason
    assert decision.policy_name == "bash_force_push"


def test_force_push_to_master_denied():
    req = make_request("git push --force origin master")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"


def test_short_flag_force_push_to_main_denied():
    req = make_request("git push -f origin main")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"


def test_upstream_main_force_push_denied():
    req = make_request("git push --force upstream main")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"


# ---------------------------------------------------------------------------
# Case 2: raw --force without --force-with-lease — deny with suggestion
# ---------------------------------------------------------------------------


def test_raw_force_push_to_feature_denied():
    req = make_request("git push --force origin feature/foo")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "--force-with-lease" in decision.reason
    assert decision.policy_name == "bash_force_push"


def test_short_f_flag_to_feature_denied():
    req = make_request("git push -f origin feature/bar")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "--force-with-lease" in decision.reason


# ---------------------------------------------------------------------------
# Case 3: --force-with-lease — allow through (no opinion)
# ---------------------------------------------------------------------------


def test_force_with_lease_allowed():
    req = make_request("git push --force-with-lease origin feature/foo")
    decision = check(req)
    assert decision is None


def test_force_with_lease_to_feature_allowed():
    req = make_request("git push --force-with-lease")
    decision = check(req)
    assert decision is None


# ---------------------------------------------------------------------------
# Non-matching commands — skip
# ---------------------------------------------------------------------------


def test_regular_push_allowed():
    req = make_request("git push origin feature/baz")
    decision = check(req)
    assert decision is None


def test_git_commit_skipped():
    req = make_request("git commit -m 'fix'")
    decision = check(req)
    assert decision is None


def test_empty_command_skipped():
    req = make_request("")
    decision = check(req)
    assert decision is None


def test_quoted_git_force_push_prompt_skipped():
    req = make_request('node tool.mjs task "explain git push --force risks"')
    decision = check(req)
    assert decision is None
