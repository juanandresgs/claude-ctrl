"""Unit tests for runtime.core.quick_eval.

Tests the STFP quick evaluation module in isolation using in-memory SQLite
and monkeypatched subprocess calls. No real git repo needed.

Covers:
  - eligible diff (small, non-source files) → eligible=True, eval written
  - too many files → eligible=False, reason mentions file count
  - source file in diff → eligible=False, reason mentions source file
  - too many lines changed → eligible=False, reason mentions line count
  - no changes → eligible=False, reason mentions no changes
  - eval_written=False when criteria NOT met (database not touched)
  - audit event emitted when criteria met

@decision DEC-QUICKEVAL-001
Title: Quick eval is scope-gated, not LLM-gated
Status: accepted
Rationale: These tests prove that mechanical scope validation (file count,
  line count, source extensions) is the complete gate — no LLM call is made.
  Each test exercises a distinct rejection path to ensure criteria are
  independent and do not short-circuit each other silently.
"""

from __future__ import annotations

import sys
from pathlib import Path
from unittest.mock import MagicMock

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

import runtime.core.quick_eval as quick_eval

import runtime.core.evaluation as evaluation_mod
import runtime.core.events as events_mod
from runtime.core.db import connect_memory
from runtime.schemas import ensure_schema

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    c = connect_memory()
    ensure_schema(c)
    yield c
    c.close()


def _make_run(monkeypatch, names_output: str, stat_output: str):
    """Return a subprocess.run replacement that returns canned diff output.

    - names_output: fake stdout for `git diff --name-only HEAD`
    - stat_output:  fake stdout for `git diff --shortstat HEAD`
    """

    def fake_run(cmd, **kwargs):
        result = MagicMock()
        result.returncode = 0
        result.stderr = ""
        if "--name-only" in cmd:
            result.stdout = names_output
        elif "--shortstat" in cmd:
            result.stdout = stat_output
        else:
            result.stdout = ""
        return result

    monkeypatch.setattr(quick_eval.subprocess, "run", fake_run)


# ---------------------------------------------------------------------------
# Happy path: small non-source diff
# ---------------------------------------------------------------------------


def test_eligible_small_nondource_diff(conn, monkeypatch):
    """A change to two .md files with 10 lines total → STFP eligible."""
    _make_run(
        monkeypatch,
        names_output="MASTER_PLAN.md\nREADME.md\n",
        stat_output=" 2 files changed, 8 insertions(+), 2 deletions(-)",
    )

    result = quick_eval.evaluate_quick(conn, "/fake/project", workflow_id="wf-stfp")

    assert result["eligible"] is True
    assert result["reason"] == "STFP criteria met"
    assert result["files_changed"] == 2
    assert result["lines_changed"] == 10
    assert result["eval_written"] is True

    # Verify evaluation_state was written
    row = evaluation_mod.get(conn, "wf-stfp")
    assert row is not None
    assert row["status"] == "ready_for_guardian"

    # Verify audit event was emitted
    events = events_mod.query(conn, type="eval_quick_judge", limit=10)
    assert len(events) == 1
    assert "STFP criteria met" in events[0]["detail"]


def test_eligible_single_json_file(conn, monkeypatch):
    """Change to one .json config file under 50 lines → eligible."""
    _make_run(
        monkeypatch,
        names_output="settings.json\n",
        stat_output=" 1 file changed, 5 insertions(+), 3 deletions(-)",
    )

    result = quick_eval.evaluate_quick(conn, "/fake/project", workflow_id="wf-json")

    assert result["eligible"] is True
    assert result["eval_written"] is True


def test_eligible_shell_hook_change(conn, monkeypatch):
    """Change to a .sh hook file → eligible (hooks/* are non-source)."""
    _make_run(
        monkeypatch,
        names_output="hooks/pre-bash.sh\n",
        stat_output=" 1 file changed, 12 insertions(+), 4 deletions(-)",
    )

    result = quick_eval.evaluate_quick(conn, "/fake/project", workflow_id="wf-hook")

    assert result["eligible"] is True
    assert result["eval_written"] is True


# ---------------------------------------------------------------------------
# File count gate
# ---------------------------------------------------------------------------


def test_too_many_files_rejected(conn, monkeypatch):
    """4 changed files exceeds MAX_FILES=3 → not eligible."""
    _make_run(
        monkeypatch,
        names_output="a.md\nb.md\nc.md\nd.md\n",
        stat_output=" 4 files changed, 20 insertions(+), 5 deletions(-)",
    )

    result = quick_eval.evaluate_quick(conn, "/fake/project", workflow_id="wf-many-files")

    assert result["eligible"] is False
    assert "4" in result["reason"]
    assert "files" in result["reason"].lower()
    assert result["eval_written"] is False

    # Confirm evaluation_state NOT written
    row = evaluation_mod.get(conn, "wf-many-files")
    assert row is None


def test_exactly_max_files_allowed(conn, monkeypatch):
    """Exactly MAX_FILES=3 changed non-source files → eligible."""
    _make_run(
        monkeypatch,
        names_output="a.md\nb.json\nc.sh\n",
        stat_output=" 3 files changed, 10 insertions(+), 0 deletions(-)",
    )

    result = quick_eval.evaluate_quick(conn, "/fake/project", workflow_id="wf-exact-max")

    assert result["eligible"] is True


# ---------------------------------------------------------------------------
# Source file gate
# ---------------------------------------------------------------------------


def test_python_source_file_rejected(conn, monkeypatch):
    """A .py file in the diff → not eligible, reason mentions file name."""
    _make_run(
        monkeypatch,
        names_output="runtime/core/quick_eval.py\n",
        stat_output=" 1 file changed, 30 insertions(+), 10 deletions(-)",
    )

    result = quick_eval.evaluate_quick(conn, "/fake/project", workflow_id="wf-py")

    assert result["eligible"] is False
    assert "runtime/core/quick_eval.py" in result["reason"]
    assert "requires full reviewer" in result["reason"]
    assert result["eval_written"] is False


def test_typescript_source_file_rejected(conn, monkeypatch):
    """A .ts file in the diff → not eligible."""
    _make_run(
        monkeypatch,
        names_output="src/index.ts\n",
        stat_output=" 1 file changed, 5 insertions(+)",
    )

    result = quick_eval.evaluate_quick(conn, "/fake/project", workflow_id="wf-ts")

    assert result["eligible"] is False
    assert "src/index.ts" in result["reason"]


def test_mixed_source_and_docs_rejected(conn, monkeypatch):
    """Even if only one of several files is source code, reject."""
    _make_run(
        monkeypatch,
        names_output="README.md\nruntime/core/foo.py\n",
        stat_output=" 2 files changed, 15 insertions(+), 5 deletions(-)",
    )

    result = quick_eval.evaluate_quick(conn, "/fake/project", workflow_id="wf-mixed")

    assert result["eligible"] is False
    assert "runtime/core/foo.py" in result["reason"]


# ---------------------------------------------------------------------------
# Line count gate
# ---------------------------------------------------------------------------


def test_too_many_lines_rejected(conn, monkeypatch):
    """51 lines changed (insertions + deletions) → not eligible."""
    _make_run(
        monkeypatch,
        names_output="MASTER_PLAN.md\n",
        stat_output=" 1 file changed, 40 insertions(+), 11 deletions(-)",
    )

    result = quick_eval.evaluate_quick(conn, "/fake/project", workflow_id="wf-big")

    assert result["eligible"] is False
    assert "51" in result["reason"]
    assert result["eval_written"] is False


def test_exactly_max_lines_allowed(conn, monkeypatch):
    """Exactly MAX_LINES=50 lines changed → eligible."""
    _make_run(
        monkeypatch,
        names_output="MASTER_PLAN.md\n",
        stat_output=" 1 file changed, 30 insertions(+), 20 deletions(-)",
    )

    result = quick_eval.evaluate_quick(conn, "/fake/project", workflow_id="wf-exact-lines")

    assert result["eligible"] is True


# ---------------------------------------------------------------------------
# No changes
# ---------------------------------------------------------------------------


def test_no_changes_returns_not_eligible(conn, monkeypatch):
    """Empty diff → not eligible, reason mentions no changes."""
    _make_run(
        monkeypatch,
        names_output="\n",
        stat_output="",
    )

    result = quick_eval.evaluate_quick(conn, "/fake/project", workflow_id="wf-empty")

    assert result["eligible"] is False
    assert "no changes" in result["reason"].lower()
    assert result["eval_written"] is False


# ---------------------------------------------------------------------------
# Compound integration: multiple rules interact correctly
# ---------------------------------------------------------------------------


def test_compound_file_count_checked_before_source(conn, monkeypatch):
    """File count (4 files) triggers before source-file check.

    This ensures rule ordering is consistent: file count is checked first
    so the reason is predictable when multiple criteria fail.
    """
    _make_run(
        monkeypatch,
        names_output="a.md\nb.md\nc.py\nd.md\n",
        stat_output=" 4 files changed, 20 insertions(+), 5 deletions(-)",
    )

    result = quick_eval.evaluate_quick(conn, "/fake/project", workflow_id="wf-compound")

    # File count fires first (4 > 3) before source check
    assert result["eligible"] is False
    assert "4" in result["reason"]


def test_eval_state_not_written_on_any_rejection(conn, monkeypatch):
    """Regardless of rejection reason, evaluation_state must not be written."""
    scenarios = [
        # (names, stat, wf_id)
        ("a.md\nb.md\nc.md\nd.md\n", " 4 files changed, 20 insertions(+)", "wf-rej-1"),
        ("runtime/core/foo.py\n", " 1 file changed, 5 insertions(+)", "wf-rej-2"),
        ("MASTER_PLAN.md\n", " 1 file changed, 40 insertions(+), 11 deletions(-)", "wf-rej-3"),
        ("\n", "", "wf-rej-4"),
    ]

    for names, stat, wf_id in scenarios:
        _make_run(monkeypatch, names_output=names, stat_output=stat)
        result = quick_eval.evaluate_quick(conn, "/fake/project", workflow_id=wf_id)
        assert result["eligible"] is False, f"Expected ineligible for {wf_id}"
        assert result["eval_written"] is False, f"eval_written must be False for {wf_id}"
        row = evaluation_mod.get(conn, wf_id)
        assert row is None, f"evaluation_state must not exist for {wf_id}"
