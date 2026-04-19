"""Unit tests for the _resolve_policy_db helper in hooks/lib/runtime-bridge.sh.

Tests exercise all five resolution permutations under hermetic subprocess
invocations with controlled env vars and controlled cwd.

@decision DEC-CLAUDEX-SA-UNIFIED-DB-ROUTING-001
Title: _resolve_policy_db is the single authoritative resolver for DB routing
Status: accepted — unit-test suite seals the 5 permutations.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_BRIDGE = str(_REPO_ROOT / "hooks" / "lib" / "runtime-bridge.sh")

pytestmark = pytest.mark.skipif(
    shutil.which("bash") is None,
    reason="_resolve_policy_db requires bash",
)


def _run_resolver(env: dict, cwd: str) -> tuple[int, str, str]:
    """Invoke _resolve_policy_db in a bash subshell and return (rc, stdout, stderr)."""
    result = subprocess.run(
        ["bash", "-c", f"source {_BRIDGE}; _resolve_policy_db"],
        capture_output=True,
        text=True,
        env=env,
        cwd=cwd,
    )
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def _clean_env() -> dict:
    """Return a minimal env with CLAUDE_POLICY_DB and CLAUDE_PROJECT_DIR removed."""
    env = dict(os.environ)
    env.pop("CLAUDE_POLICY_DB", None)
    env.pop("CLAUDE_PROJECT_DIR", None)
    return env


# ---------------------------------------------------------------------------
# (a) Only CLAUDE_POLICY_DB set → returns it verbatim
# ---------------------------------------------------------------------------


class TestResolvePolicyDbClaudePolicyDbWins:
    def test_returns_claude_policy_db_verbatim(self, tmp_path):
        db_path = str(tmp_path / "explicit.db")
        env = _clean_env()
        env["CLAUDE_POLICY_DB"] = db_path
        rc, out, _ = _run_resolver(env, cwd=str(_REPO_ROOT))
        assert rc == 0
        assert out == db_path, (
            f"Expected CLAUDE_POLICY_DB={db_path!r} to be returned verbatim, got {out!r}"
        )

    def test_does_not_call_git_when_policy_db_set(self, tmp_path):
        """When CLAUDE_POLICY_DB is set, the function must return immediately
        (tier 1) even when cwd is outside a git tree."""
        db_path = str(tmp_path / "nongit.db")
        env = _clean_env()
        env["CLAUDE_POLICY_DB"] = db_path
        # Use tmp_path as cwd — it is not a git repo.
        rc, out, _ = _run_resolver(env, cwd=str(tmp_path))
        assert rc == 0
        assert out == db_path


# ---------------------------------------------------------------------------
# (b) Only CLAUDE_PROJECT_DIR set → returns $CLAUDE_PROJECT_DIR/.claude/state.db
# ---------------------------------------------------------------------------


class TestResolvePolicyDbClaudeProjectDir:
    def test_returns_project_dir_state_db(self, tmp_path):
        project_dir = str(tmp_path / "myproject")
        expected = project_dir + "/.claude/state.db"
        env = _clean_env()
        env["CLAUDE_PROJECT_DIR"] = project_dir
        rc, out, _ = _run_resolver(env, cwd=str(_REPO_ROOT))
        assert rc == 0
        assert out == expected, (
            f"Expected {expected!r}, got {out!r}"
        )

    def test_exports_claude_policy_db_when_project_dir_used(self, tmp_path):
        """_resolve_policy_db must export CLAUDE_POLICY_DB when resolving via tier 2."""
        project_dir = str(tmp_path / "export-check")
        expected = project_dir + "/.claude/state.db"
        env = _clean_env()
        env["CLAUDE_PROJECT_DIR"] = project_dir
        # Run in a subshell that checks the exported var after calling the function.
        result = subprocess.run(
            [
                "bash",
                "-c",
                f"source {_BRIDGE}; _resolve_policy_db >/dev/null; echo \"$CLAUDE_POLICY_DB\"",
            ],
            capture_output=True,
            text=True,
            env=env,
            cwd=str(_REPO_ROOT),
        )
        assert result.returncode == 0
        assert result.stdout.strip() == expected


# ---------------------------------------------------------------------------
# (c) Neither env var set, cwd inside a git tree → returns <toplevel>/.claude/state.db
# ---------------------------------------------------------------------------


class TestResolvePolicyDbGitFallback:
    def test_returns_git_toplevel_state_db(self, tmp_path):
        """Create a minimal git repo in tmp_path and verify tier-3 resolution."""
        git_root = tmp_path / "gitrepo"
        git_root.mkdir()
        subprocess.run(
            ["git", "init", str(git_root)],
            capture_output=True,
            check=True,
        )
        expected = str(git_root / ".claude" / "state.db")
        env = _clean_env()
        rc, out, _ = _run_resolver(env, cwd=str(git_root))
        assert rc == 0
        assert out == expected, (
            f"Expected git-based resolution to {expected!r}, got {out!r}"
        )

    def test_exports_claude_policy_db_on_git_resolution(self, tmp_path):
        """_resolve_policy_db must export CLAUDE_POLICY_DB when resolving via tier 3."""
        git_root = tmp_path / "gitrepo2"
        git_root.mkdir()
        subprocess.run(
            ["git", "init", str(git_root)],
            capture_output=True,
            check=True,
        )
        expected = str(git_root / ".claude" / "state.db")
        env = _clean_env()
        result = subprocess.run(
            [
                "bash",
                "-c",
                f"source {_BRIDGE}; _resolve_policy_db >/dev/null; echo \"$CLAUDE_POLICY_DB\"",
            ],
            capture_output=True,
            text=True,
            env=env,
            cwd=str(git_root),
        )
        assert result.returncode == 0
        assert result.stdout.strip() == expected

    def test_resolves_from_subdir_of_git_repo(self, tmp_path):
        """Tier 3 must resolve even when cwd is a subdirectory inside the git tree."""
        git_root = tmp_path / "gitrepo3"
        git_root.mkdir()
        subprocess.run(
            ["git", "init", str(git_root)],
            capture_output=True,
            check=True,
        )
        subdir = git_root / "some" / "deep" / "dir"
        subdir.mkdir(parents=True)
        expected = str(git_root / ".claude" / "state.db")
        env = _clean_env()
        rc, out, _ = _run_resolver(env, cwd=str(subdir))
        assert rc == 0
        assert out == expected


# ---------------------------------------------------------------------------
# (d) Neither env var set, cwd outside any git tree → returns empty string
# ---------------------------------------------------------------------------


class TestResolvePolicyDbNoGit:
    def test_returns_empty_when_no_git_tree(self, tmp_path):
        """Resolution must fail gracefully (empty output) when all three tiers fail."""
        # tmp_path is not a git repo (and has no git parent).
        # We use a fresh directory that is definitely not under any git tree.
        no_git_dir = tmp_path / "not-a-repo"
        no_git_dir.mkdir()
        env = _clean_env()
        # Override HOME to prevent ~/.git or home-dir git config interference.
        env["HOME"] = str(tmp_path / "fakehome")
        rc, out, _ = _run_resolver(env, cwd=str(no_git_dir))
        assert rc == 0
        assert out == "", (
            f"Expected empty output when no git tree and no env vars, got {out!r}"
        )

    def test_does_not_export_claude_policy_db_on_empty_resolution(self, tmp_path):
        """When resolution fails, CLAUDE_POLICY_DB must NOT be exported."""
        no_git_dir = tmp_path / "not-a-repo2"
        no_git_dir.mkdir()
        env = _clean_env()
        env["HOME"] = str(tmp_path / "fakehome")
        # Use a separate args list to avoid f-string/shell-variable collision.
        # The bash script checks if CLAUDE_POLICY_DB was exported by the function.
        check_script = (
            f"source {_BRIDGE}; "
            "_resolve_policy_db >/dev/null; "
            'echo "VAR=${CLAUDE_POLICY_DB:-UNSET}"'
        )
        result = subprocess.run(
            ["bash", "-c", check_script],
            capture_output=True,
            text=True,
            env=env,
            cwd=str(no_git_dir),
        )
        assert result.returncode == 0
        assert "VAR=UNSET" in result.stdout, (
            f"Expected CLAUDE_POLICY_DB to be unset; stdout={result.stdout!r}"
        )


# ---------------------------------------------------------------------------
# (e) All three set → CLAUDE_POLICY_DB wins (tier 1 priority)
# ---------------------------------------------------------------------------


class TestResolvePolicyDbAllThreeSet:
    def test_policy_db_wins_over_project_dir_and_git(self, tmp_path):
        """When CLAUDE_POLICY_DB, CLAUDE_PROJECT_DIR, and a git root all exist,
        CLAUDE_POLICY_DB must be returned without modification."""
        git_root = tmp_path / "gitrepo"
        git_root.mkdir()
        subprocess.run(
            ["git", "init", str(git_root)],
            capture_output=True,
            check=True,
        )
        explicit_db = str(tmp_path / "explicit_wins.db")
        project_dir = str(tmp_path / "projdir")

        env = _clean_env()
        env["CLAUDE_POLICY_DB"] = explicit_db
        env["CLAUDE_PROJECT_DIR"] = project_dir

        rc, out, _ = _run_resolver(env, cwd=str(git_root))
        assert rc == 0
        assert out == explicit_db, (
            f"Expected CLAUDE_POLICY_DB={explicit_db!r} to win; got {out!r}"
        )
        # Must NOT return the project_dir or git-based path.
        assert "projdir" not in out
        assert str(git_root) not in out
