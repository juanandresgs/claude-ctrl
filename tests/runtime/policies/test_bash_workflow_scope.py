"""Unit tests for bash_workflow_scope policy.

Exercises workflow binding + scope compliance enforcement (DEC-PE-W3-010).
Production trigger: PreToolUse Bash hook — git commit or git merge when
the workflow has no binding, no scope, or changed files violate scope.

binding and scope are injected via PolicyContext — no DB I/O needed.
The _check_compliance helper is tested directly for the scope-matching logic.

@decision DEC-PE-W3-TEST-010
@title Unit tests for bash_workflow_scope policy
@status accepted
@rationale Verify three sub-checks: A (binding missing), B (scope missing),
  C (changed files violate scope). Also verify meta-repo bypass and
  non-commit/merge skip. _check_compliance is tested as a unit to cover
  allowed/forbidden pattern matching without subprocess.
"""

from __future__ import annotations

import json

from runtime.core.policies.bash_workflow_scope import _check_compliance, check
from tests.runtime.policies.conftest import make_context, make_request

# ---------------------------------------------------------------------------
# _check_compliance unit tests (pure helper)
# ---------------------------------------------------------------------------


def _scope(allowed=None, forbidden=None):
    return {
        "allowed_paths": json.dumps(allowed or []),
        "forbidden_paths": json.dumps(forbidden or []),
    }


def test_compliance_empty_changed_files():
    compliant, violations = _check_compliance(_scope(allowed=["*.py"]), [])
    assert compliant
    assert violations == []


def test_compliance_file_in_allowed():
    compliant, violations = _check_compliance(
        _scope(allowed=["runtime/**", "tests/**"]),
        ["runtime/core/foo.py", "tests/test_foo.py"],
    )
    assert compliant
    assert violations == []


def test_compliance_file_out_of_scope():
    compliant, violations = _check_compliance(
        _scope(allowed=["runtime/**"]),
        ["runtime/core/foo.py", "hooks/guard.sh"],
    )
    assert not compliant
    assert any("OUT_OF_SCOPE" in v for v in violations)


def test_compliance_forbidden_file():
    compliant, violations = _check_compliance(
        _scope(allowed=["**"], forbidden=["settings.json"]),
        ["settings.json"],
    )
    assert not compliant
    assert any("FORBIDDEN" in v for v in violations)


def test_compliance_forbidden_takes_precedence_over_allowed():
    """forbidden_paths deny even when file also matches allowed_paths."""
    compliant, violations = _check_compliance(
        _scope(allowed=["**"], forbidden=["runtime/schemas.py"]),
        ["runtime/schemas.py"],
    )
    assert not compliant
    assert any("FORBIDDEN" in v for v in violations)


def test_compliance_no_allowed_no_forbidden_all_pass():
    """Empty allowed list means no restriction (allow all)."""
    compliant, violations = _check_compliance(
        _scope(allowed=[], forbidden=[]),
        ["any/file.py", "another/file.md"],
    )
    assert compliant


# ---------------------------------------------------------------------------
# Sub-check A: binding missing
# ---------------------------------------------------------------------------


def test_no_binding_commit_denied():
    ctx = make_context(binding=None, scope={"allowed_paths": "[]", "forbidden_paths": "[]"})
    req = make_request("git commit -m 'feat'", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "binding" in decision.reason.lower()
    assert decision.policy_name == "bash_workflow_scope"


def test_no_binding_merge_denied():
    ctx = make_context(binding=None, scope={"allowed_paths": "[]", "forbidden_paths": "[]"})
    req = make_request("git merge feature/foo", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"


# ---------------------------------------------------------------------------
# Sub-check B: scope missing
# ---------------------------------------------------------------------------


def test_no_scope_commit_denied():
    ctx = make_context(
        binding={"base_branch": "main", "worktree_path": "/project/.worktrees/feature-test"},
        scope=None,
    )
    req = make_request("git commit -m 'feat'", context=ctx)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "scope" in decision.reason.lower()
    assert decision.policy_name == "bash_workflow_scope"


# ---------------------------------------------------------------------------
# Bypass: meta-repo
# ---------------------------------------------------------------------------


def test_meta_repo_bypassed():
    ctx = make_context(is_meta_repo=True, binding=None, scope=None)
    req = make_request("git commit -m 'config'", context=ctx)
    decision = check(req)
    assert decision is None


# ---------------------------------------------------------------------------
# Skip: non-commit/merge commands
# ---------------------------------------------------------------------------


def test_git_push_skipped():
    ctx = make_context(binding=None, scope=None)
    req = make_request("git push origin feature/foo", context=ctx)
    decision = check(req)
    assert decision is None


def test_git_status_skipped():
    ctx = make_context(binding=None, scope=None)
    req = make_request("git status", context=ctx)
    decision = check(req)
    assert decision is None


def test_empty_command_skipped():
    ctx = make_context(binding=None, scope=None)
    req = make_request("", context=ctx)
    decision = check(req)
    assert decision is None
