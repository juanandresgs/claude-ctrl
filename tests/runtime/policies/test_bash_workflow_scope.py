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


# ---------------------------------------------------------------------------
# DEC-PE-W3-010-STAGED-GATE-002 — git commit -a / --all auto-stage semantics.
# The commit-path scope gate must union the staged index with the tracked
# modified/deleted set when the invocation auto-stages (-a / --all / short-
# flag bundle with 'a'). Untracked files are NEVER swept in. Plain
# ``git commit`` continues to gate on the staged index only.
# ---------------------------------------------------------------------------


from runtime.core.policies.bash_workflow_scope import _commit_stages_all


# _commit_stages_all — pure helper unit tests (no git repo needed)


def test_commit_stages_all_short_dash_a():
    assert _commit_stages_all(("-a",))


def test_commit_stages_all_long_all():
    assert _commit_stages_all(("--all",))


def test_commit_stages_all_bundled_short_am():
    """-am is shorthand for -a -m."""
    assert _commit_stages_all(("-am", "msg"))


def test_commit_stages_all_bundled_short_av():
    assert _commit_stages_all(("-av",))


def test_commit_stages_all_bundled_short_avm():
    assert _commit_stages_all(("-avm", "msg"))


def test_commit_stages_all_plain_message_does_not_match():
    """-m alone does not auto-stage."""
    assert not _commit_stages_all(("-m", "msg"))


def test_commit_stages_all_amend_does_not_match():
    """--amend is unrelated to --all."""
    assert not _commit_stages_all(("--amend",))
    assert not _commit_stages_all(("--amend", "--no-edit"))


def test_commit_stages_all_empty_args():
    assert not _commit_stages_all(())


def test_commit_stages_all_positional_args_ignored():
    """Positional tokens (paths, refs) must not be matched."""
    assert not _commit_stages_all(("path/with/a/in/it.txt",))


def test_commit_stages_all_other_short_flags_not_matched():
    for flag in ("-m", "-n", "-q", "-v", "-s", "-S"):
        assert not _commit_stages_all((flag,)), f"false positive on {flag}"


# End-to-end regressions against a real git repo


def _modify_tracked_in_branch(repo, relpath, content_first="hist\n",
                              content_modified="modified\n"):
    """Commit a file (tracked history), then modify it in the working tree.
    The modification is NOT staged — it's what ``git commit -a`` would stage.
    """
    full = repo / relpath
    full.parent.mkdir(parents=True, exist_ok=True)
    full.write_text(content_first)
    _git(repo, "add", relpath)
    _git(repo, "commit", "-m", f"baseline {relpath}", "-q")
    full.write_text(content_modified)
    # Intentionally do NOT `git add` — leave as tracked-modified.


def test_commit_minus_a_denies_out_of_scope_tracked_edit(tmp_path):
    """An out-of-scope tracked edit (not yet staged) must be denied on
    ``git commit -a`` — git would auto-stage it, so the scope gate must
    see it."""
    repo = _init_repo(tmp_path)
    # Track an out-of-scope file and modify it; do not stage the modification.
    _modify_tracked_in_branch(repo, "scripts/legacy.sh")
    # Nothing explicitly staged.
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**", "tests/**"],
        forbidden=["scripts/**"],
    )
    req = make_request("git commit -a -m 'sneak'", context=ctx, cwd=str(repo))
    decision = check(req)
    assert decision is not None, (
        "git commit -a must catch out-of-scope tracked edits even when the "
        "index is empty at PreToolUse time"
    )
    assert decision.action == "deny"
    assert "FORBIDDEN" in decision.reason
    assert "scripts/legacy.sh" in decision.reason


def test_commit_minus_a_allows_in_scope_tracked_edit(tmp_path):
    """Happy path: tracked in-scope edit passes ``git commit -a``."""
    repo = _init_repo(tmp_path)
    _modify_tracked_in_branch(repo, "runtime/core/thing.py")
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**", "tests/**"],
        forbidden=["scripts/**"],
    )
    req = make_request("git commit -am 'ok'", context=ctx, cwd=str(repo))
    decision = check(req)
    assert decision is None


def test_plain_commit_ignores_unstaged_tracked_edits(tmp_path):
    """Plain ``git commit`` (no -a) must NOT pull in tracked-but-unstaged
    edits. Only the explicitly-staged index counts."""
    repo = _init_repo(tmp_path)
    # Tracked out-of-scope edit, NOT staged. Plain commit should not see it.
    _modify_tracked_in_branch(repo, "scripts/legacy.sh")
    # Stage an in-scope file to make the commit non-empty.
    _stage(repo, "runtime/core/clean.py", "# ok\n")
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**", "tests/**"],
        forbidden=["scripts/**"],
    )
    req = make_request("git commit -m 'ok'", context=ctx, cwd=str(repo))
    decision = check(req)
    assert decision is None, (
        "Plain git commit must ignore the unstaged tracked edit in scripts/legacy.sh; "
        "only the staged index (runtime/core/clean.py) counts."
    )


def test_commit_minus_a_ignores_untracked_files(tmp_path):
    """``git commit -a`` does NOT auto-stage untracked files. The scope
    gate must not over-sweep — untracked out-of-scope files must not
    cause the commit-a gate to deny."""
    repo = _init_repo(tmp_path)
    # Untracked out-of-scope file (never `git add`-ed).
    (repo / "scripts").mkdir(parents=True, exist_ok=True)
    (repo / "scripts" / "never-tracked.sh").write_text("new\n")
    # Stage an in-scope file so the commit has something to do.
    _stage(repo, "runtime/core/clean.py", "# ok\n")
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**", "tests/**"],
        forbidden=["scripts/**"],
    )
    req = make_request("git commit -a -m 'ok'", context=ctx, cwd=str(repo))
    decision = check(req)
    assert decision is None, (
        "git commit -a must not sweep untracked files; scripts/never-tracked.sh "
        "is untracked and git itself would not stage it."
    )


def test_commit_minus_a_unions_staged_and_tracked(tmp_path):
    """Realistic mixed case: one in-scope file already staged, one
    out-of-scope tracked file modified but not staged. With -a, git will
    stage both at commit time, so the gate must deny on the forbidden one."""
    repo = _init_repo(tmp_path)
    _stage(repo, "runtime/core/ok.py", "# staged ok\n")
    _modify_tracked_in_branch(repo, "scripts/legacy.sh")
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**", "tests/**"],
        forbidden=["scripts/**"],
    )
    req = make_request("git commit -a -m 'mixed'", context=ctx, cwd=str(repo))
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "FORBIDDEN" in decision.reason
    assert "scripts/legacy.sh" in decision.reason


# ---------------------------------------------------------------------------
# DEC-PE-W3-010-STAGED-GATE-003 — commit pathspec / --only / --include
# semantics. Plain ``git commit <pathspec>`` implicitly uses --only mode:
# commits the contents of matched tracked files only, ignoring unrelated
# staged changes. ``--include`` unions staged ∪ pathspec. The scope gate
# must gate on the exact set each invocation will commit.
# ---------------------------------------------------------------------------


from runtime.core.policies.bash_workflow_scope import _parse_commit_pathspec


# _parse_commit_pathspec — pure unit tests (no git repo)


def test_parse_pathspec_empty_args():
    assert _parse_commit_pathspec(()) == ([], False, False)


def test_parse_pathspec_dash_m_value_not_pathspec():
    assert _parse_commit_pathspec(("-m", "msg")) == ([], False, False)


def test_parse_pathspec_bundle_am_with_value():
    """-am "msg" — bundle ends with 'm' (value-taking), so "msg" is the
    m-flag value, NOT pathspec."""
    assert _parse_commit_pathspec(("-am", "msg")) == ([], False, False)


def test_parse_pathspec_bundle_am_with_value_then_pathspec():
    assert _parse_commit_pathspec(("-am", "msg", "file.py")) == (
        ["file.py"], False, False,
    )


def test_parse_pathspec_single_pathspec():
    assert _parse_commit_pathspec(("file.py",)) == (["file.py"], False, False)


def test_parse_pathspec_with_message_then_pathspec():
    assert _parse_commit_pathspec(("-m", "msg", "file.py")) == (
        ["file.py"], False, False,
    )


def test_parse_pathspec_long_message_separate_value():
    assert _parse_commit_pathspec(("--message", "msg", "file.py")) == (
        ["file.py"], False, False,
    )


def test_parse_pathspec_long_message_inline_value():
    assert _parse_commit_pathspec(("--message=msg", "file.py")) == (
        ["file.py"], False, False,
    )


def test_parse_pathspec_long_include():
    assert _parse_commit_pathspec(("--include", "file.py")) == (
        ["file.py"], True, False,
    )


def test_parse_pathspec_short_include():
    assert _parse_commit_pathspec(("-i", "file.py")) == (
        ["file.py"], True, False,
    )


def test_parse_pathspec_long_only():
    assert _parse_commit_pathspec(("--only", "file.py")) == (
        ["file.py"], False, True,
    )


def test_parse_pathspec_short_only():
    assert _parse_commit_pathspec(("-o", "file.py")) == (
        ["file.py"], False, True,
    )


def test_parse_pathspec_double_dash_sentinel():
    """Everything after -- is pathspec, even flag-looking tokens."""
    assert _parse_commit_pathspec(("-m", "msg", "--", "-weird-file")) == (
        ["-weird-file"], False, False,
    )


def test_parse_pathspec_author_flag_value():
    assert _parse_commit_pathspec(("--author=me", "file.py")) == (
        ["file.py"], False, False,
    )


def test_parse_pathspec_file_flag_consumes_value():
    assert _parse_commit_pathspec(("-F", "commit-msg.txt", "file.py")) == (
        ["file.py"], False, False,
    )


def test_parse_pathspec_multiple_pathspec():
    assert _parse_commit_pathspec(("a.py", "b.py", "c.py")) == (
        ["a.py", "b.py", "c.py"], False, False,
    )


# End-to-end real-repo regressions for pathspec / --only / --include


def test_pathspec_commit_denies_out_of_scope_tracked_file(tmp_path):
    """DEC-PE-W3-010-STAGED-GATE-003: ``git commit out-of-scope.py``
    (implicit --only) commits that file even if nothing is pre-staged.
    The gate must deny."""
    repo = _init_repo(tmp_path)
    _modify_tracked_in_branch(repo, "scripts/legacy.sh")
    # Nothing staged.
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**", "tests/**"],
        forbidden=["scripts/**"],
    )
    req = make_request(
        "git commit -m 'sneak' scripts/legacy.sh", context=ctx, cwd=str(repo)
    )
    decision = check(req)
    assert decision is not None, (
        "pathspec commit on out-of-scope tracked file must be denied"
    )
    assert decision.action == "deny"
    assert "FORBIDDEN" in decision.reason
    assert "scripts/legacy.sh" in decision.reason


def test_pathspec_commit_allows_in_scope_tracked_file(tmp_path):
    """Happy path: ``git commit runtime/core/thing.py`` (implicit --only)
    on an in-scope tracked file passes."""
    repo = _init_repo(tmp_path)
    _modify_tracked_in_branch(repo, "runtime/core/thing.py")
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**", "tests/**"],
        forbidden=["scripts/**"],
    )
    req = make_request(
        "git commit -m 'ok' runtime/core/thing.py", context=ctx, cwd=str(repo)
    )
    decision = check(req)
    assert decision is None


def test_pathspec_only_ignores_unrelated_staged_changes(tmp_path):
    """Implicit --only means unrelated staged changes are NOT committed
    on this invocation, so they must NOT factor into the scope gate.
    Stage an out-of-scope file; commit a different in-scope path; the
    invocation should pass because only the pathspec file is committed.

    Setup order matters: baseline first, then stage — ``_modify_tracked_in_branch``
    ends with a ``git commit`` that would otherwise absorb the staged file."""
    repo = _init_repo(tmp_path)
    # In-scope tracked file — the pathspec target (baseline + modify).
    _modify_tracked_in_branch(repo, "runtime/core/thing.py")
    # Out-of-scope staged file — this commit should NOT include it.
    _stage(repo, "scripts/legacy.sh", "#!/bin/sh\n")
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**", "tests/**"],
        forbidden=["scripts/**"],
    )
    req = make_request(
        "git commit -m 'only' runtime/core/thing.py", context=ctx, cwd=str(repo)
    )
    decision = check(req)
    assert decision is None, (
        "implicit --only must ignore unrelated staged out-of-scope changes; "
        "the gate must only check the pathspec files"
    )


def test_explicit_only_denies_out_of_scope_pathspec(tmp_path):
    """Explicit --only behaves the same as implicit pathspec commit."""
    repo = _init_repo(tmp_path)
    _modify_tracked_in_branch(repo, "scripts/legacy.sh")
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**", "tests/**"],
        forbidden=["scripts/**"],
    )
    req = make_request(
        "git commit --only -m 'sneak' scripts/legacy.sh", context=ctx, cwd=str(repo)
    )
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "FORBIDDEN" in decision.reason
    assert "scripts/legacy.sh" in decision.reason


def test_include_unions_staged_and_pathspec_denies_on_forbidden_staged(tmp_path):
    """``--include`` commits staged ∪ pathspec. If the staged side has a
    forbidden file, the gate must deny even if the pathspec side is clean.

    Order matters: baseline the in-scope file first (its baseline commit
    would otherwise absorb the forbidden staged file), then stage the
    forbidden file."""
    repo = _init_repo(tmp_path)
    _modify_tracked_in_branch(repo, "runtime/core/thing.py")  # pathspec, clean
    _stage(repo, "scripts/bad.sh", "#!/bin/sh\n")  # staged, forbidden
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**", "tests/**"],
        forbidden=["scripts/**"],
    )
    req = make_request(
        "git commit --include -m 'both' runtime/core/thing.py",
        context=ctx, cwd=str(repo),
    )
    decision = check(req)
    assert decision is not None, (
        "--include unions staged + pathspec; forbidden in staged must deny"
    )
    assert decision.action == "deny"
    assert "FORBIDDEN" in decision.reason
    assert "scripts/bad.sh" in decision.reason


def test_include_unions_staged_and_pathspec_denies_on_forbidden_pathspec(tmp_path):
    """Symmetric: staged is clean, pathspec has forbidden file.

    Baseline the forbidden pathspec file first so _stage's content lands
    into the index rather than being absorbed by the baseline commit."""
    repo = _init_repo(tmp_path)
    _modify_tracked_in_branch(repo, "scripts/bad.sh")  # pathspec, forbidden
    _stage(repo, "runtime/core/ok.py", "# ok\n")  # staged, in-scope
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**", "tests/**"],
        forbidden=["scripts/**"],
    )
    req = make_request(
        "git commit --include -m 'both' scripts/bad.sh",
        context=ctx, cwd=str(repo),
    )
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "FORBIDDEN" in decision.reason
    assert "scripts/bad.sh" in decision.reason


def test_include_passes_when_both_sides_in_scope(tmp_path):
    """Happy path for --include: both staged and pathspec are in scope.

    Baseline the pathspec side first so the _stage call puts one.py in
    the index at check time."""
    repo = _init_repo(tmp_path)
    _modify_tracked_in_branch(repo, "runtime/core/two.py")
    _stage(repo, "runtime/core/one.py", "# ok\n")
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**", "tests/**"],
        forbidden=["scripts/**"],
    )
    req = make_request(
        "git commit --include -m 'both' runtime/core/two.py",
        context=ctx, cwd=str(repo),
    )
    decision = check(req)
    assert decision is None


def test_pathspec_does_not_sweep_untracked_files(tmp_path):
    """``git commit <pathspec>`` on a directory still only commits tracked
    files within that directory. An untracked out-of-scope file in the
    same tree must not cause deny."""
    repo = _init_repo(tmp_path)
    _modify_tracked_in_branch(repo, "runtime/core/thing.py")  # tracked in-scope
    # Untracked out-of-scope sibling inside allowed directory.
    (repo / "runtime" / "core" / "untracked.py").write_text("# new\n")
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/core/thing.py"],
        forbidden=[],
    )
    req = make_request(
        "git commit -m 'only tracked' runtime/core/thing.py",
        context=ctx, cwd=str(repo),
    )
    decision = check(req)
    assert decision is None, (
        "pathspec commit must not pull untracked files into the scope check"
    )


def test_pathspec_with_double_dash_sentinel(tmp_path):
    """The POSIX ``--`` sentinel: everything after is pathspec, even if
    it starts with a dash. Tracked out-of-scope file denied."""
    repo = _init_repo(tmp_path)
    _modify_tracked_in_branch(repo, "scripts/legacy.sh")
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**"],
        forbidden=["scripts/**"],
    )
    req = make_request(
        "git commit -m 'via --' -- scripts/legacy.sh",
        context=ctx, cwd=str(repo),
    )
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "FORBIDDEN" in decision.reason
    assert "scripts/legacy.sh" in decision.reason


# ---------------------------------------------------------------------------
# DEC-PE-W3-010-STAGED-GATE-004 — commit --pathspec-from-file / --pathspec-file-nul
# The parser must not treat the filename arg as pathspec, and the policy
# must resolve the file's contents into pathspec entries so they are
# gated the same as inline pathspec. Untracked files remain excluded.
# ---------------------------------------------------------------------------


from runtime.core.policies.bash_workflow_scope import (
    _extract_pathspec_file_info,
    _read_pathspec_file,
)


# Pure-helper unit tests — _extract_pathspec_file_info


def test_extract_pathspec_file_info_absent():
    assert _extract_pathspec_file_info(("-m", "msg", "file.py")) == (None, False)


def test_extract_pathspec_file_info_inline_equals():
    """``--pathspec-from-file=paths.txt`` inline form."""
    assert _extract_pathspec_file_info(
        ("--pathspec-from-file=paths.txt", "-m", "msg")
    ) == ("paths.txt", False)


def test_extract_pathspec_file_info_separated_form():
    """``--pathspec-from-file paths.txt`` separated form — filename is
    the NEXT arg."""
    assert _extract_pathspec_file_info(
        ("--pathspec-from-file", "paths.txt", "-m", "msg")
    ) == ("paths.txt", False)


def test_extract_pathspec_file_info_nul_flag_inline():
    assert _extract_pathspec_file_info(
        ("--pathspec-file-nul", "--pathspec-from-file=paths.txt")
    ) == ("paths.txt", True)


def test_extract_pathspec_file_info_nul_flag_separated():
    assert _extract_pathspec_file_info(
        ("--pathspec-from-file", "paths.txt", "--pathspec-file-nul")
    ) == ("paths.txt", True)


def test_extract_pathspec_file_info_stdin_sentinel_preserved():
    """``--pathspec-from-file=-`` is returned verbatim; the reader
    decides what to do (we do not emulate future stdin)."""
    assert _extract_pathspec_file_info(
        ("--pathspec-from-file=-", "-m", "msg")
    ) == ("-", False)


# Parser no-misclassification proof: the filename in the separated form
# must NOT end up in pathspec (it's consumed as the flag's value).


def test_parse_pathspec_with_pathspec_from_file_separated_no_pathspec():
    from runtime.core.policies.bash_workflow_scope import _parse_commit_pathspec
    assert _parse_commit_pathspec(
        ("--only", "--pathspec-from-file", "paths.txt")
    ) == ([], False, True)


def test_parse_pathspec_with_pathspec_from_file_inline_no_pathspec():
    from runtime.core.policies.bash_workflow_scope import _parse_commit_pathspec
    assert _parse_commit_pathspec(
        ("--only", "--pathspec-from-file=paths.txt")
    ) == ([], False, True)


# _read_pathspec_file tests


def test_read_pathspec_file_newline_separated(tmp_path):
    f = tmp_path / "paths.txt"
    f.write_text("runtime/core/a.py\ntests/test_a.py\n\n  \n")
    got = _read_pathspec_file(str(tmp_path), "paths.txt", nul_separator=False)
    assert got == ["runtime/core/a.py", "tests/test_a.py"]


def test_read_pathspec_file_nul_separated(tmp_path):
    f = tmp_path / "paths.txt"
    f.write_bytes(b"runtime/core/a.py\x00tests/test_a.py\x00scripts/x.sh\x00")
    got = _read_pathspec_file(str(tmp_path), "paths.txt", nul_separator=True)
    assert got == ["runtime/core/a.py", "tests/test_a.py", "scripts/x.sh"]


def test_read_pathspec_file_missing_returns_empty(tmp_path):
    got = _read_pathspec_file(str(tmp_path), "no-such.txt", nul_separator=False)
    assert got == []


def test_read_pathspec_file_stdin_sentinel_returns_empty(tmp_path):
    got = _read_pathspec_file(str(tmp_path), "-", nul_separator=False)
    assert got == []


def test_read_pathspec_file_absolute_path(tmp_path):
    f = tmp_path / "absolute.txt"
    f.write_text("runtime/core/a.py\n")
    got = _read_pathspec_file("/some/other/dir", str(f), nul_separator=False)
    assert got == ["runtime/core/a.py"]


# Real-repo end-to-end regressions


def _write_pathspec_file(repo, filename, entries, nul=False):
    full = repo / filename
    if nul:
        full.write_bytes(b"\x00".join(e.encode() for e in entries) + b"\x00")
    else:
        full.write_text("\n".join(entries) + "\n")


def test_pathspec_from_file_denies_out_of_scope_tracked(tmp_path):
    """``git commit --only --pathspec-from-file=paths.txt`` with a
    forbidden tracked file listed in paths.txt and nothing staged must
    still be denied — closing the under-gating hole the prior slice
    missed."""
    repo = _init_repo(tmp_path)
    _modify_tracked_in_branch(repo, "scripts/legacy.sh")
    _write_pathspec_file(repo, "paths.txt", ["scripts/legacy.sh"])
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**", "tests/**"],
        forbidden=["scripts/**"],
    )
    # Inline form.
    req = make_request(
        "git commit --only --pathspec-from-file=paths.txt -m 'sneak'",
        context=ctx, cwd=str(repo),
    )
    decision = check(req)
    assert decision is not None, (
        "pathspec-from-file must resolve entries and gate on them; forbidden "
        "tracked file in the list must deny"
    )
    assert decision.action == "deny"
    assert "FORBIDDEN" in decision.reason
    assert "scripts/legacy.sh" in decision.reason


def test_pathspec_from_file_separated_form_denies_out_of_scope(tmp_path):
    """Separated form: ``--pathspec-from-file paths.txt`` (no equals).
    The parser must not treat ``paths.txt`` itself as a pathspec entry,
    and the file's contents must be resolved."""
    repo = _init_repo(tmp_path)
    _modify_tracked_in_branch(repo, "scripts/legacy.sh")
    _write_pathspec_file(repo, "paths.txt", ["scripts/legacy.sh"])
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**", "tests/**"],
        forbidden=["scripts/**"],
    )
    req = make_request(
        "git commit --only --pathspec-from-file paths.txt -m 'sneak'",
        context=ctx, cwd=str(repo),
    )
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "FORBIDDEN" in decision.reason
    assert "scripts/legacy.sh" in decision.reason
    # The filename itself must NOT appear in the deny reason — it is the
    # source, not pathspec.
    assert "paths.txt" not in decision.reason


def test_pathspec_from_file_allows_in_scope(tmp_path):
    """Happy path: all pathspec entries from the file are in scope."""
    repo = _init_repo(tmp_path)
    _modify_tracked_in_branch(repo, "runtime/core/ok.py")
    _write_pathspec_file(repo, "paths.txt", ["runtime/core/ok.py"])
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**", "tests/**"],
        forbidden=["scripts/**"],
    )
    req = make_request(
        "git commit --only --pathspec-from-file=paths.txt -m 'ok'",
        context=ctx, cwd=str(repo),
    )
    decision = check(req)
    assert decision is None


def test_pathspec_from_file_nul_separated_denies_out_of_scope(tmp_path):
    """``--pathspec-file-nul`` + ``--pathspec-from-file``: entries are
    NUL-separated. Must parse correctly and gate on the entries."""
    repo = _init_repo(tmp_path)
    _modify_tracked_in_branch(repo, "scripts/legacy.sh")
    _modify_tracked_in_branch(repo, "runtime/core/ok.py")
    _write_pathspec_file(
        repo, "paths.txt", ["runtime/core/ok.py", "scripts/legacy.sh"], nul=True,
    )
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**", "tests/**"],
        forbidden=["scripts/**"],
    )
    req = make_request(
        "git commit --only --pathspec-file-nul --pathspec-from-file=paths.txt -m 'x'",
        context=ctx, cwd=str(repo),
    )
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "FORBIDDEN" in decision.reason
    assert "scripts/legacy.sh" in decision.reason


def test_pathspec_from_file_does_not_sweep_untracked(tmp_path):
    """File lists an untracked path — git would error anyway, but scope
    gate must not deny on untracked files (the no-oversweep invariant)."""
    repo = _init_repo(tmp_path)
    _modify_tracked_in_branch(repo, "runtime/core/thing.py")
    # Untracked out-of-scope path listed in the pathspec file.
    _write_pathspec_file(
        repo, "paths.txt",
        ["runtime/core/thing.py", "untracked/out-of-scope.py"],
    )
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**"],
        forbidden=["untracked/**"],
    )
    req = make_request(
        "git commit --only --pathspec-from-file=paths.txt -m 'ok'",
        context=ctx, cwd=str(repo),
    )
    decision = check(req)
    assert decision is None, (
        "untracked path listed in pathspec file must not trigger deny; "
        "no-oversweep invariant preserved"
    )


def test_pathspec_from_file_unions_with_inline_pathspec(tmp_path):
    """Inline pathspec and pathspec-from-file co-exist — both sets of
    entries must be gated. If either has a forbidden file, deny."""
    repo = _init_repo(tmp_path)
    _modify_tracked_in_branch(repo, "runtime/core/ok.py")
    _modify_tracked_in_branch(repo, "scripts/legacy.sh")
    _write_pathspec_file(repo, "paths.txt", ["scripts/legacy.sh"])
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**"],
        forbidden=["scripts/**"],
    )
    # Inline pathspec = runtime/core/ok.py (in-scope). File pathspec =
    # scripts/legacy.sh (forbidden). Must deny.
    req = make_request(
        "git commit --only --pathspec-from-file=paths.txt -m 'x' runtime/core/ok.py",
        context=ctx, cwd=str(repo),
    )
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "FORBIDDEN" in decision.reason
    assert "scripts/legacy.sh" in decision.reason


def test_pathspec_from_file_stdin_is_denied(tmp_path):
    """DEC-PE-W3-010-STAGED-GATE-005: ``--pathspec-from-file=-`` reads
    pathspec entries from the commit process's future stdin, which
    PreToolUse cannot inspect. Fail closed — otherwise a caller could
    feed out-of-scope tracked paths on stdin and bypass the scope gate
    while inline/staged signals look clean.

    Example bypass shape (the exact case the prior slice missed):

        git commit --only --pathspec-from-file=- -m x runtime/core/thing.py
        # stdin contents: scripts/legacy.sh

    The inline pathspec is in-scope, the staged index is empty, and
    ``scripts/legacy.sh`` on stdin would still be the file actually
    committed — but the gate cannot see it. Deny instead.
    """
    repo = _init_repo(tmp_path)
    _modify_tracked_in_branch(repo, "runtime/core/thing.py")
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**"],
        forbidden=["scripts/**"],
    )
    req = make_request(
        "git commit --only --pathspec-from-file=- -m 'x' runtime/core/thing.py",
        context=ctx, cwd=str(repo),
    )
    decision = check(req)
    assert decision is not None, (
        "stdin-backed pathspec (``--pathspec-from-file=-``) must fail "
        "closed — it cannot be validated pre-execution"
    )
    assert decision.action == "deny"
    assert decision.policy_name == "bash_workflow_scope"
    # Reason must clearly identify the stdin-backed pathspec as the cause
    # and point at the remediation (write the paths to a file).
    assert "pathspec-from-file=-" in decision.reason or "stdin" in decision.reason.lower()
    assert "DEC-PE-W3-010-STAGED-GATE-005" in decision.reason


def test_pathspec_from_file_stdin_denied_even_when_everything_else_is_in_scope(tmp_path):
    """Even with a clean staged set and clean inline pathspec, stdin
    cannot be inspected, so the invocation must still deny. The
    attacker's leverage is exactly that the other signals look clean."""
    repo = _init_repo(tmp_path)
    _modify_tracked_in_branch(repo, "runtime/core/thing.py")
    # Stage an in-scope file so staged signal also looks clean.
    _stage(repo, "runtime/core/extra.py", "# ok\n")
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**", "tests/**"],
        forbidden=["scripts/**"],
    )
    req = make_request(
        "git commit --include --pathspec-from-file=- -m 'x' runtime/core/thing.py",
        context=ctx, cwd=str(repo),
    )
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"


def test_pathspec_from_file_dash_with_nul_also_denied(tmp_path):
    """``--pathspec-file-nul`` does not change the fail-closed
    treatment of stdin — the unobservable surface is the same."""
    repo = _init_repo(tmp_path)
    _modify_tracked_in_branch(repo, "runtime/core/thing.py")
    ctx = _ctx_with_scope(
        repo,
        allowed=["runtime/**"],
        forbidden=["scripts/**"],
    )
    req = make_request(
        "git commit --only --pathspec-file-nul --pathspec-from-file=- -m 'x'",
        context=ctx, cwd=str(repo),
    )
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
