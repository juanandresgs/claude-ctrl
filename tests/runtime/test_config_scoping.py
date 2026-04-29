"""Unit tests for runtime/core/config.py DB path resolution.

@decision DEC-SELF-003
@title Canonical 4-step DB resolver — unit test coverage
@status accepted
@rationale TKT-022 requires each of the 4 resolution steps to be independently
  testable: (1) CLAUDE_POLICY_DB env var, (2) CLAUDE_PROJECT_DIR env var,
  (3) git-root detection, (4) ~/.claude/state.db fallback. Each step must
  be individually verifiable and the priority ordering must be enforced.

# @mock-exempt: subprocess.run is an external boundary — spawns a git child
#   process. The git repo state on disk is not deterministic across environments
#   (the test suite itself runs inside a git repo, so real git calls would
#   resolve to THIS repo's root, not the tmp_path fixture). Mocking subprocess
#   is the only way to test step-3 resolution against controlled git roots.
"""
import os
import subprocess
from pathlib import Path
from unittest.mock import patch, MagicMock

import pytest

# Add runtime to path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from runtime.core.config import default_db_path, resolve_db_path, resolve_project_db


class TestDefaultDbPath:
    """Tests for the 4-step canonical DB resolver."""

    def test_step1_claude_policy_db_wins(self, tmp_path):
        """CLAUDE_POLICY_DB takes highest precedence."""
        db = tmp_path / "explicit.db"
        with patch.dict(os.environ, {"CLAUDE_POLICY_DB": str(db)}, clear=False):
            assert default_db_path() == db

    def test_step1_beats_step2(self, tmp_path):
        """CLAUDE_POLICY_DB beats CLAUDE_PROJECT_DIR."""
        explicit = tmp_path / "explicit.db"
        project = tmp_path / "project"
        project.mkdir()
        with patch.dict(os.environ, {
            "CLAUDE_POLICY_DB": str(explicit),
            "CLAUDE_PROJECT_DIR": str(project),
        }, clear=False):
            assert default_db_path() == explicit

    def test_step1_policy_db_override_is_rejected_and_falls_through(self, tmp_path):
        """runtime/policy.db is not a valid state DB override."""
        poisoned = tmp_path / "runtime" / "policy.db"
        project = tmp_path / "project"
        project.mkdir()
        expected = project / ".claude" / "state.db"
        with patch.dict(
            os.environ,
            {
                "CLAUDE_POLICY_DB": str(poisoned),
                "CLAUDE_PROJECT_DIR": str(project),
            },
            clear=False,
        ):
            assert default_db_path() == expected

    def test_step2_claude_project_dir(self, tmp_path):
        """CLAUDE_PROJECT_DIR resolves to project .claude/state.db."""
        project = tmp_path / "myproject"
        project.mkdir()
        expected = project / ".claude" / "state.db"
        env = {"CLAUDE_PROJECT_DIR": str(project)}
        with patch.dict(os.environ, env, clear=False):
            # Remove CLAUDE_POLICY_DB if set
            os.environ.pop("CLAUDE_POLICY_DB", None)
            assert default_db_path() == expected

    def test_step2_beats_step3(self, tmp_path):
        """CLAUDE_PROJECT_DIR beats git-root detection."""
        project = tmp_path / "myproject"
        project.mkdir()
        expected = project / ".claude" / "state.db"
        with patch.dict(os.environ, {"CLAUDE_PROJECT_DIR": str(project)}, clear=False):
            os.environ.pop("CLAUDE_POLICY_DB", None)
            # Even if git returns something else, step 2 wins
            result = default_db_path()
            assert result == expected

    def test_explicit_project_root_beats_claude_project_dir(self, tmp_path):
        """Explicit project_root routes commands to the target repo DB."""
        explicit_project = tmp_path / "explicit-project"
        explicit_project.mkdir()
        env_project = tmp_path / "env-project"
        env_project.mkdir()
        expected = explicit_project / ".claude" / "state.db"

        with patch.dict(
            os.environ,
            {"CLAUDE_PROJECT_DIR": str(env_project)},
            clear=False,
        ):
            os.environ.pop("CLAUDE_POLICY_DB", None)
            assert resolve_db_path(project_root=str(explicit_project)) == expected

    def test_step3_git_root_with_claude_dir(self, tmp_path):
        """Git root with .claude/ dir resolves to project DB."""
        git_root = tmp_path / "repo"
        git_root.mkdir()
        claude_dir = git_root / ".claude"
        claude_dir.mkdir()
        expected = claude_dir / "state.db"

        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = str(git_root) + "\n"

        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("CLAUDE_POLICY_DB", None)
            os.environ.pop("CLAUDE_PROJECT_DIR", None)
            with patch("runtime.core.config.subprocess.run", return_value=mock_result):
                assert default_db_path() == expected

    def test_step3_git_root_without_claude_dir_falls_through(self, tmp_path):
        """Git root without .claude/ dir falls to step 4."""
        git_root = tmp_path / "repo"
        git_root.mkdir()
        # No .claude/ dir

        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = str(git_root) + "\n"

        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("CLAUDE_POLICY_DB", None)
            os.environ.pop("CLAUDE_PROJECT_DIR", None)
            with patch("runtime.core.config.subprocess.run", return_value=mock_result):
                result = default_db_path()
                assert result == Path.home() / ".claude" / "state.db"

    def test_step4_fallback_to_home(self):
        """No env vars, no git → falls back to ~/.claude/state.db."""
        mock_result = MagicMock()
        mock_result.returncode = 128  # not a git repo

        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("CLAUDE_POLICY_DB", None)
            os.environ.pop("CLAUDE_PROJECT_DIR", None)
            with patch("runtime.core.config.subprocess.run", return_value=mock_result):
                assert default_db_path() == Path.home() / ".claude" / "state.db"

    def test_step3_git_timeout_falls_through(self):
        """Git timeout falls through to step 4."""
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("CLAUDE_POLICY_DB", None)
            os.environ.pop("CLAUDE_PROJECT_DIR", None)
            with patch("runtime.core.config.subprocess.run",
                       side_effect=subprocess.TimeoutExpired("git", 5)):
                assert default_db_path() == Path.home() / ".claude" / "state.db"

    def test_step2_nonexistent_project_dir_falls_through(self, tmp_path):
        """CLAUDE_PROJECT_DIR pointing to a non-existent dir falls through to step 3/4."""
        nonexistent = tmp_path / "does-not-exist"
        # nonexistent is not created
        mock_result = MagicMock()
        mock_result.returncode = 128  # not a git repo either

        with patch.dict(os.environ, {"CLAUDE_PROJECT_DIR": str(nonexistent)}, clear=False):
            os.environ.pop("CLAUDE_POLICY_DB", None)
            with patch("runtime.core.config.subprocess.run", return_value=mock_result):
                result = default_db_path()
                # Falls all the way to step 4
                assert result == Path.home() / ".claude" / "state.db"


class TestResolveProjectDb:
    """Tests for resolve_project_db helper."""

    def test_returns_path_when_git_root_has_claude_dir(self, tmp_path):
        git_root = tmp_path / "repo"
        git_root.mkdir()
        (git_root / ".claude").mkdir()

        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = str(git_root) + "\n"

        with patch("runtime.core.config.subprocess.run", return_value=mock_result):
            result = resolve_project_db()
            assert result == git_root / ".claude" / "state.db"

    def test_returns_none_when_no_claude_dir(self, tmp_path):
        git_root = tmp_path / "repo"
        git_root.mkdir()

        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = str(git_root) + "\n"

        with patch("runtime.core.config.subprocess.run", return_value=mock_result):
            assert resolve_project_db() is None

    def test_returns_none_when_not_in_git(self):
        mock_result = MagicMock()
        mock_result.returncode = 128

        with patch("runtime.core.config.subprocess.run", return_value=mock_result):
            assert resolve_project_db() is None

    def test_returns_none_on_file_not_found(self):
        """No git binary → returns None gracefully."""
        with patch("runtime.core.config.subprocess.run",
                   side_effect=FileNotFoundError("git not found")):
            assert resolve_project_db() is None

    def test_returns_none_on_oserror(self):
        """OS error during git call → returns None gracefully."""
        with patch("runtime.core.config.subprocess.run",
                   side_effect=OSError("permission denied")):
            assert resolve_project_db() is None
