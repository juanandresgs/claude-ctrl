"""Unit tests for bash_main_sacred policy.

Exercises denial of direct commits on main/master (DEC-PE-W3-006).
Production trigger: PreToolUse Bash hook — git commit commands when the
worktree branch is main or master.

Three exceptions are tested:
  1. is_meta_repo == True (orchestrator config edits)
  2. MERGE_HEAD exists (merge finalisation commit)
  3. Only MASTER_PLAN.md is staged

The policy calls subprocess to determine the branch and staged files.
We test the pure-function paths by verifying that meta-repo bypass works
and that non-commit commands are skipped. Branch detection tests are
deferred to integration level since they require a real git repo.

@decision DEC-PE-W3-TEST-006
@title Unit tests for bash_main_sacred policy
@status accepted
@rationale Verify the meta-repo bypass and non-commit skip paths, which
  are pure-function branches requiring no subprocess. The branch-detection
  deny path is verified at a higher level since it requires a live git repo.
  This split ensures the pure paths are caught by fast unit tests.
"""

from __future__ import annotations

import runtime.core.policies.bash_main_sacred as main_sacred
from runtime.core.policies.bash_main_sacred import check
from tests.runtime.policies.conftest import make_context, make_request

# ---------------------------------------------------------------------------
# Skip: non-commit commands
# ---------------------------------------------------------------------------


def test_non_commit_command_skipped():
    req = make_request("git status")
    decision = check(req)
    assert decision is None


def test_git_push_skipped():
    req = make_request("git push origin feature/foo")
    decision = check(req)
    assert decision is None


def test_empty_command_skipped():
    req = make_request("")
    decision = check(req)
    assert decision is None


# ---------------------------------------------------------------------------
# Bypass: meta-repo
# ---------------------------------------------------------------------------


def test_meta_repo_commit_allowed():
    """Commits in the meta-repo (/.claude) are exempt from main-sacred."""
    ctx = make_context(is_meta_repo=True)
    req = make_request("git commit -m 'config update'", context=ctx)
    decision = check(req)
    assert decision is None


def test_meta_repo_commit_on_main_allowed():
    """Even when on main, meta-repo commits are allowed."""
    ctx = make_context(is_meta_repo=True, branch="main")
    req = make_request("git commit -m 'update config'", context=ctx)
    decision = check(req)
    assert decision is None


# ---------------------------------------------------------------------------
# Bypass: canonical guardian landing
# ---------------------------------------------------------------------------


def _force_main_commit_context(monkeypatch, *, staged="src/app.py"):
    monkeypatch.setattr(main_sacred, "_get_branch", lambda _target_dir: "main")
    monkeypatch.setattr(main_sacred, "_merge_head_exists", lambda _target_dir: False)
    monkeypatch.setattr(main_sacred, "_staged_files", lambda _target_dir: staged)


def test_guardian_land_commit_on_main_allowed_by_main_sacred(monkeypatch):
    """Guardian landing remains normal git; later test/eval gates still run."""
    _force_main_commit_context(monkeypatch)
    ctx = make_context(actor_role="guardian:land", project_root="/repo", is_meta_repo=False)
    req = make_request("git commit -m 'land reviewed work'", context=ctx, cwd="/repo")

    decision = check(req)

    assert decision is None


def test_non_guardian_commit_on_main_denied_with_guardian_guidance(monkeypatch):
    _force_main_commit_context(monkeypatch)
    ctx = make_context(actor_role="implementer", project_root="/repo", is_meta_repo=False)
    req = make_request("git commit -m 'source work on main'", context=ctx, cwd="/repo")

    decision = check(req)

    assert decision is not None
    assert decision.action == "deny"
    assert "guardian:land" in decision.reason
    assert "git worktree add" not in decision.reason


# ---------------------------------------------------------------------------
# Deny path (requires live git, tested via integration — stub here for
# completeness to show the test structure)
# ---------------------------------------------------------------------------


def test_quoted_git_commit_prompt_skipped():
    req = make_request('node tool.mjs task "investigate git commit gating"')
    decision = check(req)
    assert decision is None
