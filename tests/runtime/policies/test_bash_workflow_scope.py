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


def test_quoted_git_merge_prompt_skipped():
    ctx = make_context(binding=None, scope=None)
    req = make_request('node tool.mjs task "investigate git merge gating"', context=ctx)
    assert check(req) is None


def test_quoted_git_commit_prompt_skipped():
    ctx = make_context(binding=None, scope=None)
    req = make_request('node tool.mjs task "investigate git commit gating"', context=ctx)
    assert check(req) is None


# ---------------------------------------------------------------------------
# DEC-PE-W3-010-STAGED-GATE-001 — commit path gates on the staged index,
# not on `base_branch...HEAD`. These tests construct a real temp git repo
# with a branch history that would PASS the old base...HEAD check but
# FAIL the new staged-index check (forbidden / OUT_OF_SCOPE staged file),
# and vice versa. They prove the commit path is governed by the staged
# bundle — closing the gap flagged by the WHO-remediation landing.
# ---------------------------------------------------------------------------


import subprocess as _subprocess

import pytest


def _git(repo, *args):
    return _subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True, text=True, check=True,
    )


def _init_repo(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "test@test.invalid")
    _git(repo, "config", "user.name", "test")
    # Seed one commit on main so `base_branch=main` is resolvable.
    (repo / "README.md").write_text("seed\n")
    _git(repo, "add", "README.md")
    _git(repo, "commit", "-m", "seed", "-q")
    # Branch off main to match the production shape (claudesox-local off main).
    _git(repo, "checkout", "-B", "feature/slice", "-q")
    return repo


def _stage(repo, relpath, content="stub\n"):
    full = repo / relpath
    full.parent.mkdir(parents=True, exist_ok=True)
    full.write_text(content)
    _git(repo, "add", relpath)


def _commit_into_branch_history(repo, relpath, content="hist\n"):
    """Land a file on the branch as prior history; NOT staged at check time."""
    full = repo / relpath
    full.parent.mkdir(parents=True, exist_ok=True)
    full.write_text(content)
    _git(repo, "add", relpath)
    _git(repo, "commit", "-m", f"history {relpath}", "-q")


def _ctx_with_scope(repo, *, allowed, forbidden):
    binding = {"base_branch": "main", "worktree_path": str(repo)}
    scope = {
        "allowed_paths": json.dumps(allowed),
        "forbidden_paths": json.dumps(forbidden),
    }
    return make_context(
        binding=binding,
        scope=scope,
        project_root=str(repo),
    )


def _commit_req(ctx, cwd):
    return make_request(
        "git commit -m 'slice'",
        context=ctx,
        cwd=cwd,
    )


def test_staged_forbidden_file_denied_on_commit_even_when_branch_history_is_clean(
    tmp_path,
):
    """The new-staged forbidden file must trip the gate even though the
    branch-ahead history is empty — proving the check runs on the staged
    index, not on base_branch...HEAD."""
    repo = _init_repo(tmp_path)
    # Stage a forbidden file. No prior branch-ahead history.
    _stage(repo, "settings.json", '{"x":1}')
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**", "tests/**"],
        forbidden=["settings.json"],
    )
    decision = check(_commit_req(ctx, str(repo)))
    assert decision is not None
    assert decision.action == "deny"
    assert decision.policy_name == "bash_workflow_scope"
    assert "FORBIDDEN" in decision.reason
    assert "settings.json" in decision.reason


def test_staged_out_of_scope_file_denied_on_commit(tmp_path):
    """A staged file that is neither in allowed_paths nor forbidden_paths
    must still be denied when allowed_paths is non-empty — the staged path
    is treated identically to how branch-ahead paths were treated."""
    repo = _init_repo(tmp_path)
    _stage(repo, "hooks/guard.sh", "echo hi\n")
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**", "tests/**"],
        forbidden=[],
    )
    decision = check(_commit_req(ctx, str(repo)))
    assert decision is not None
    assert decision.action == "deny"
    assert "OUT_OF_SCOPE" in decision.reason
    assert "hooks/guard.sh" in decision.reason


def test_staged_in_scope_file_allowed_on_commit(tmp_path):
    """Happy path: a staged file that matches allowed_paths passes the
    commit gate."""
    repo = _init_repo(tmp_path)
    _stage(repo, "runtime/core/agent_prompt.py", "# ok\n")
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**", "tests/**"],
        forbidden=["settings.json"],
    )
    decision = check(_commit_req(ctx, str(repo)))
    assert decision is None


def test_commit_gate_ignores_branch_history_when_staged_is_in_scope(tmp_path):
    """The key regression fix: a branch-ahead commit can contain forbidden
    files (landed under an older / looser scope), but a NEW commit whose
    staged index is fully in scope must pass. Before DEC-PE-W3-010-STAGED-
    GATE-001 the policy would have denied this commit because it ran
    `base...HEAD` and saw the historical forbidden file."""
    repo = _init_repo(tmp_path)
    # Branch-ahead history carries a forbidden file.
    _commit_into_branch_history(repo, "scripts/legacy.sh", "old\n")
    # Staged index is fully in scope.
    _stage(repo, "runtime/core/agent_prompt.py", "# ok\n")
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**", "tests/**"],
        forbidden=["scripts/**"],
    )
    decision = check(_commit_req(ctx, str(repo)))
    assert decision is None, (
        "Commit should pass: staged files in-scope, forbidden file lives "
        "only in branch-ahead history that was already landed under a "
        "prior scope. Got deny: "
        f"{None if decision is None else decision.reason}"
    )


def test_commit_gate_denies_forbidden_staged_even_when_branch_history_in_scope(
    tmp_path,
):
    """Symmetric check: branch-ahead history is all in-scope, staged file
    is forbidden. Old policy would pass (base...HEAD clean); new policy
    must deny (staged has forbidden)."""
    repo = _init_repo(tmp_path)
    _commit_into_branch_history(repo, "runtime/core/clean.py", "# ok\n")
    _stage(repo, "settings.json", '{"x":1}')
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**", "tests/**"],
        forbidden=["settings.json"],
    )
    decision = check(_commit_req(ctx, str(repo)))
    assert decision is not None
    assert decision.action == "deny"
    assert "FORBIDDEN" in decision.reason
    assert "settings.json" in decision.reason


def test_commit_with_empty_staged_index_allows(tmp_path):
    """No staged files → nothing to check → policy does not deny. (git
    itself will refuse the no-op commit separately; the scope policy's job
    is not to emulate that.)"""
    repo = _init_repo(tmp_path)
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**"],
        forbidden=["settings.json"],
    )
    decision = check(_commit_req(ctx, str(repo)))
    assert decision is None


def test_merge_path_still_uses_branch_ahead_history(tmp_path):
    """DEC-PE-W3-010-STAGED-GATE-001 preserves merge-path semantics —
    merge continues to check base_branch...HEAD (what the merge would
    incorporate), not the staged index."""
    repo = _init_repo(tmp_path)
    # Forbidden file lives ONLY in branch-ahead history (merge target).
    _commit_into_branch_history(repo, "scripts/bad.sh", "old\n")
    # Nothing staged — if the merge path incorrectly used the staged index,
    # it would not catch the forbidden history.
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**"],
        forbidden=["scripts/**"],
    )
    req = make_request("git merge feature/foo", context=ctx, cwd=str(repo))
    decision = check(req)
    assert decision is not None, "merge path must still inspect branch-ahead history"
    assert decision.action == "deny"
    assert "FORBIDDEN" in decision.reason
    assert "scripts/bad.sh" in decision.reason
