"""Tests for scripts/planctl.py — plan discipline enforcement tool.

@decision DEC-PLAN-001
Title: planctl.py as the single enforcement authority for MASTER_PLAN.md discipline
Status: accepted
Rationale: Dual enforcement between plan-validate.sh (inline shell) and
  planctl.py creates divergence risk. By moving all structural validation
  into planctl.py, we have one Python module with unit tests and one thin
  shell wrapper. TKT-010 establishes planctl.py as the canonical authority;
  plan-validate.sh is reduced to a shell bridge that calls planctl.py.

Production trigger: Pre-write hook chain -> plan-validate.sh -> planctl.py validate.
  Also: post-plan-update -> planctl.py refresh-baseline.
  check-immutability fires inside plan-policy.sh on every MASTER_PLAN.md write.

Real production sequence:
  1. Claude writes MASTER_PLAN.md via Write tool
  2. pre-write.sh fires; delegates to plan-policy.sh functions
  3. plan-policy.sh calls planctl.py check-immutability and check-decision-log
  4. If violation -> deny JSON emitted; write blocked
  5. On allowed write: plan-validate.sh (PostToolUse) calls planctl.py validate

These tests exercise the full planctl.py surface via subprocess, mirroring
how hooks invoke it, verifying arg parsing -> logic -> JSON/exit-code chain.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

_WORKTREE = Path(__file__).resolve().parent.parent.parent
_PLANCTL = str(_WORKTREE / "scripts" / "planctl.py")


def run(args: list[str], cwd: str | None = None) -> tuple[int, str]:
    """Run planctl.py with given args; return (exit_code, stdout)."""
    result = subprocess.run(
        [sys.executable, _PLANCTL] + args,
        capture_output=True,
        text=True,
        cwd=cwd,
    )
    return result.returncode, result.stdout.strip()


def run_json(args: list[str], cwd: str | None = None) -> tuple[int, dict]:
    """Run planctl.py and parse stdout as JSON."""
    code, out = run(args, cwd=cwd)
    try:
        parsed = json.loads(out)
    except json.JSONDecodeError:
        parsed = {"_raw": out}
    return code, parsed


# ---------------------------------------------------------------------------
# Minimal valid MASTER_PLAN.md fixture
# ---------------------------------------------------------------------------

MINIMAL_PLAN = textwrap.dedent("""\
    # MASTER_PLAN.md

    Last updated: 2026-03-24 (initial)

    ## Identity

    This is the test project identity.

    ## Architecture

    Architecture overview here.

    ## Original Intent

    Bootstrap a test harness.

    ## Principles

    1. Keep it simple.

    ## Decision Log

    - `2026-03-24 -- DEC-FORK-001` Bootstrap decision.

    ## Active Initiatives

    ### INIT-001: Test Initiative

    - **Status:** in-progress
    - **Goal:** Run tests.
    - **Current truth:** Tests exist.
    - **Scope:** Test files only.
    - **Exit:** All tests pass.
    - **Dependencies:** none

    ## Completed Initiatives

    No completed initiatives yet.

    ## Parked Issues

    None.
""")


# ---------------------------------------------------------------------------
# validate command
# ---------------------------------------------------------------------------


class TestValidate:
    def test_valid_plan_exits_zero(self, tmp_path):
        plan = tmp_path / "MASTER_PLAN.md"
        plan.write_text(MINIMAL_PLAN)
        code, _ = run(["validate", str(plan)])
        assert code == 0

    def test_missing_section_exits_nonzero(self, tmp_path):
        plan = tmp_path / "MASTER_PLAN.md"
        content = MINIMAL_PLAN.replace(
            "## Completed Initiatives\n\nNo completed initiatives yet.\n", ""
        )
        plan.write_text(content)
        code, out = run(["validate", str(plan)])
        assert code != 0
        assert "Completed Initiatives" in out or "missing" in out.lower()

    def test_missing_last_updated_exits_nonzero(self, tmp_path):
        plan = tmp_path / "MASTER_PLAN.md"
        content = MINIMAL_PLAN.replace("Last updated: 2026-03-24 (initial)\n", "")
        plan.write_text(content)
        code, out = run(["validate", str(plan)])
        assert code != 0

    def test_invalid_decision_id_format_exits_nonzero(self, tmp_path):
        plan = tmp_path / "MASTER_PLAN.md"
        content = MINIMAL_PLAN.replace("DEC-FORK-001", "DEC-001")
        plan.write_text(content)
        code, out = run(["validate", str(plan)])
        assert code != 0

    def test_active_initiative_missing_status_exits_nonzero(self, tmp_path):
        plan = tmp_path / "MASTER_PLAN.md"
        content = MINIMAL_PLAN.replace("- **Status:** in-progress\n", "")
        plan.write_text(content)
        code, out = run(["validate", str(plan)])
        assert code != 0

    def test_all_required_sections_present(self, tmp_path):
        plan = tmp_path / "MASTER_PLAN.md"
        plan.write_text(MINIMAL_PLAN)
        code, out = run(["validate", str(plan)])
        assert code == 0, f"Expected 0, got {code}: {out}"


# ---------------------------------------------------------------------------
# check-immutability command
# ---------------------------------------------------------------------------


class TestCheckImmutability:
    def test_no_baseline_creates_baseline_and_succeeds(self, tmp_path):
        plan = tmp_path / "MASTER_PLAN.md"
        plan.write_text(MINIMAL_PLAN)
        code, out = run_json(["check-immutability", str(plan)], cwd=str(tmp_path))
        assert code == 0
        assert out.get("immutable") is True
        assert out.get("violations") == []
        assert (tmp_path / ".plan-baseline.json").exists()

    def test_unchanged_plan_is_immutable(self, tmp_path):
        plan = tmp_path / "MASTER_PLAN.md"
        plan.write_text(MINIMAL_PLAN)
        run(["check-immutability", str(plan)], cwd=str(tmp_path))
        code, out = run_json(["check-immutability", str(plan)], cwd=str(tmp_path))
        assert code == 0
        assert out.get("immutable") is True

    def test_appending_to_identity_section_is_allowed(self, tmp_path):
        plan = tmp_path / "MASTER_PLAN.md"
        plan.write_text(MINIMAL_PLAN)
        run(["check-immutability", str(plan)], cwd=str(tmp_path))
        modified = MINIMAL_PLAN.replace(
            "This is the test project identity.",
            "This is the test project identity.\n\nAdditional identity note appended later.",
        )
        plan.write_text(modified)
        code, out = run_json(["check-immutability", str(plan)], cwd=str(tmp_path))
        assert code == 0, f"Append should be allowed: {out}"
        assert out.get("immutable") is True

    def test_rewriting_identity_section_is_violation(self, tmp_path):
        plan = tmp_path / "MASTER_PLAN.md"
        plan.write_text(MINIMAL_PLAN)
        run(["check-immutability", str(plan)], cwd=str(tmp_path))
        modified = MINIMAL_PLAN.replace(
            "This is the test project identity.",
            "COMPLETELY DIFFERENT identity text that replaces the original.",
        )
        plan.write_text(modified)
        code, out = run_json(["check-immutability", str(plan)], cwd=str(tmp_path))
        assert code != 0
        assert out.get("immutable") is False
        assert len(out.get("violations", [])) > 0
        assert any("Identity" in v.get("section", "") for v in out["violations"])

    def test_rewriting_principles_is_violation(self, tmp_path):
        plan = tmp_path / "MASTER_PLAN.md"
        plan.write_text(MINIMAL_PLAN)
        run(["check-immutability", str(plan)], cwd=str(tmp_path))
        modified = MINIMAL_PLAN.replace(
            "1. Keep it simple.",
            "1. Replaced principle.",
        )
        plan.write_text(modified)
        code, out = run_json(["check-immutability", str(plan)], cwd=str(tmp_path))
        assert code != 0
        assert out.get("immutable") is False

    def test_rewriting_original_intent_is_violation(self, tmp_path):
        plan = tmp_path / "MASTER_PLAN.md"
        plan.write_text(MINIMAL_PLAN)
        run(["check-immutability", str(plan)], cwd=str(tmp_path))
        modified = MINIMAL_PLAN.replace(
            "Bootstrap a test harness.",
            "Replaced original intent entirely.",
        )
        plan.write_text(modified)
        code, out = run_json(["check-immutability", str(plan)], cwd=str(tmp_path))
        assert code != 0
        assert out.get("immutable") is False


# ---------------------------------------------------------------------------
# check-decision-log command
# ---------------------------------------------------------------------------


class TestCheckDecisionLog:
    def test_no_baseline_creates_baseline_and_succeeds(self, tmp_path):
        plan = tmp_path / "MASTER_PLAN.md"
        plan.write_text(MINIMAL_PLAN)
        code, out = run_json(["check-decision-log", str(plan)], cwd=str(tmp_path))
        assert code == 0
        assert out.get("append_only") is True

    def test_adding_entry_at_end_is_allowed(self, tmp_path):
        plan = tmp_path / "MASTER_PLAN.md"
        plan.write_text(MINIMAL_PLAN)
        run(["check-decision-log", str(plan)], cwd=str(tmp_path))
        modified = MINIMAL_PLAN.replace(
            "- `2026-03-24 -- DEC-FORK-001` Bootstrap decision.",
            "- `2026-03-24 -- DEC-FORK-001` Bootstrap decision.\n- `2026-03-24 -- DEC-FORK-002` Second decision.",
        )
        plan.write_text(modified)
        code, out = run_json(["check-decision-log", str(plan)], cwd=str(tmp_path))
        assert code == 0
        assert out.get("append_only") is True

    def test_deleting_entry_is_violation(self, tmp_path):
        plan = tmp_path / "MASTER_PLAN.md"
        plan.write_text(MINIMAL_PLAN)
        run(["check-decision-log", str(plan)], cwd=str(tmp_path))
        modified = MINIMAL_PLAN.replace(
            "- `2026-03-24 -- DEC-FORK-001` Bootstrap decision.\n",
            "",
        )
        plan.write_text(modified)
        code, out = run_json(["check-decision-log", str(plan)], cwd=str(tmp_path))
        assert code != 0
        assert out.get("append_only") is False
        assert len(out.get("violations", [])) > 0

    def test_modifying_entry_text_is_violation(self, tmp_path):
        plan = tmp_path / "MASTER_PLAN.md"
        plan.write_text(MINIMAL_PLAN)
        run(["check-decision-log", str(plan)], cwd=str(tmp_path))
        modified = MINIMAL_PLAN.replace(
            "- `2026-03-24 -- DEC-FORK-001` Bootstrap decision.",
            "- `2026-03-24 -- DEC-FORK-001` MODIFIED bootstrap decision.",
        )
        plan.write_text(modified)
        code, out = run_json(["check-decision-log", str(plan)], cwd=str(tmp_path))
        assert code != 0
        assert out.get("append_only") is False

    def test_reordering_entries_is_violation(self, tmp_path):
        """Two entries swapped in order must be detected as a violation."""
        plan = tmp_path / "MASTER_PLAN.md"
        two_entry_plan = MINIMAL_PLAN.replace(
            "- `2026-03-24 -- DEC-FORK-001` Bootstrap decision.",
            "- `2026-03-24 -- DEC-FORK-001` Bootstrap decision.\n- `2026-03-24 -- DEC-FORK-002` Second decision.",
        )
        plan.write_text(two_entry_plan)
        run(["check-decision-log", str(plan)], cwd=str(tmp_path))
        swapped = two_entry_plan.replace(
            "- `2026-03-24 -- DEC-FORK-001` Bootstrap decision.\n- `2026-03-24 -- DEC-FORK-002` Second decision.",
            "- `2026-03-24 -- DEC-FORK-002` Second decision.\n- `2026-03-24 -- DEC-FORK-001` Bootstrap decision.",
        )
        plan.write_text(swapped)
        code, out = run_json(["check-decision-log", str(plan)], cwd=str(tmp_path))
        assert code != 0
        assert out.get("append_only") is False


# ---------------------------------------------------------------------------
# check-compression command
# ---------------------------------------------------------------------------


class TestCheckCompression:
    def test_valid_plan_with_no_completed_initiatives_passes(self, tmp_path):
        plan = tmp_path / "MASTER_PLAN.md"
        plan.write_text(MINIMAL_PLAN)
        code, out = run_json(["check-compression", str(plan)])
        assert code == 0
        assert out.get("valid") is True

    def test_completed_initiative_with_wave_detail_is_violation(self, tmp_path):
        plan = tmp_path / "MASTER_PLAN.md"
        content = MINIMAL_PLAN.replace(
            "## Completed Initiatives\n\nNo completed initiatives yet.",
            textwrap.dedent("""\
                ## Completed Initiatives

                ### INIT-000: Done Init (completed 2026-01-01)

                - **Status:** completed

                #### Wave 1 Execution Detail

                This should not be here.

                ##### Sub-wave detail

                More uncompressed detail.
            """),
        )
        plan.write_text(content)
        code, out = run_json(["check-compression", str(plan)])
        assert code != 0
        assert out.get("valid") is False
        assert len(out.get("violations", [])) > 0

    def test_active_initiative_with_wave_detail_is_fine(self, tmp_path):
        """Active initiatives are allowed to have wave execution detail."""
        plan = tmp_path / "MASTER_PLAN.md"
        content = MINIMAL_PLAN.replace(
            "- **Dependencies:** none",
            textwrap.dedent("""\
                - **Dependencies:** none

                #### Wave 1 Execution Detail

                Still active, so detail is expected."""),
        )
        plan.write_text(content)
        code, out = run_json(["check-compression", str(plan)])
        assert code == 0, f"Active initiative wave detail must be allowed: {out}"
        assert out.get("valid") is True

    def test_active_initiative_missing_required_fields_is_violation(self, tmp_path):
        plan = tmp_path / "MASTER_PLAN.md"
        content = MINIMAL_PLAN.replace("- **Exit:** All tests pass.\n", "")
        plan.write_text(content)
        code, out = run_json(["check-compression", str(plan)])
        assert code != 0
        assert out.get("valid") is False


# ---------------------------------------------------------------------------
# stamp command
# ---------------------------------------------------------------------------


class TestStamp:
    def test_stamp_replaces_last_updated_with_iso_date(self, tmp_path):
        plan = tmp_path / "MASTER_PLAN.md"
        plan.write_text(MINIMAL_PLAN)
        code, _ = run(["stamp", str(plan)])
        assert code == 0
        text = plan.read_text()
        assert re.search(r"Last updated: \d{4}-\d{2}-\d{2}", text)

    def test_stamp_with_summary_appends_parenthetical(self, tmp_path):
        plan = tmp_path / "MASTER_PLAN.md"
        plan.write_text(MINIMAL_PLAN)
        code, _ = run(["stamp", str(plan), "--summary", "test summary"])
        assert code == 0
        text = plan.read_text()
        assert "test summary" in text

    def test_stamp_creates_baseline_file(self, tmp_path):
        plan = tmp_path / "MASTER_PLAN.md"
        plan.write_text(MINIMAL_PLAN)
        run(["stamp", str(plan)])
        assert (tmp_path / ".plan-baseline.json").exists()

    def test_stamp_updates_baseline_on_second_call(self, tmp_path):
        plan = tmp_path / "MASTER_PLAN.md"
        plan.write_text(MINIMAL_PLAN)
        run(["stamp", str(plan)])
        baseline_v1 = (tmp_path / ".plan-baseline.json").read_text()
        # Append to Identity so the permanent-section hash changes
        modified = MINIMAL_PLAN.replace(
            "This is the test project identity.",
            "This is the test project identity.\n\nExtra identity paragraph.",
        )
        plan.write_text(modified)
        run(["stamp", str(plan), "--summary", "v2"])
        baseline_v2 = (tmp_path / ".plan-baseline.json").read_text()
        assert baseline_v1 != baseline_v2


# ---------------------------------------------------------------------------
# refresh-baseline command
# ---------------------------------------------------------------------------


class TestRefreshBaseline:
    def test_creates_baseline_file(self, tmp_path):
        plan = tmp_path / "MASTER_PLAN.md"
        plan.write_text(MINIMAL_PLAN)
        baseline = tmp_path / ".plan-baseline.json"
        assert not baseline.exists()
        code, _ = run(["refresh-baseline", str(plan)], cwd=str(tmp_path))
        assert code == 0
        assert baseline.exists()

    def test_baseline_contains_permanent_sections(self, tmp_path):
        plan = tmp_path / "MASTER_PLAN.md"
        plan.write_text(MINIMAL_PLAN)
        run(["refresh-baseline", str(plan)], cwd=str(tmp_path))
        baseline = json.loads((tmp_path / ".plan-baseline.json").read_text())
        # Baseline structure: {"sections": {"Identity": hash, ...}, "section_texts": {...}, ...}
        sections = baseline.get("sections", {})
        assert "Identity" in sections
        assert "Architecture" in sections
        assert "Original Intent" in sections
        assert "Principles" in sections

    def test_refresh_updates_existing_baseline(self, tmp_path):
        plan = tmp_path / "MASTER_PLAN.md"
        plan.write_text(MINIMAL_PLAN)
        run(["refresh-baseline", str(plan)], cwd=str(tmp_path))
        baseline_v1 = (tmp_path / ".plan-baseline.json").read_text()
        modified = MINIMAL_PLAN.replace(
            "This is the test project identity.",
            "This is the test project identity.\n\nAppended identity detail.",
        )
        plan.write_text(modified)
        run(["refresh-baseline", str(plan)], cwd=str(tmp_path))
        baseline_v2 = (tmp_path / ".plan-baseline.json").read_text()
        assert baseline_v1 != baseline_v2


# ---------------------------------------------------------------------------
# Compound interaction: full production sequence end-to-end
# ---------------------------------------------------------------------------


class TestProductionSequence:
    """Exercise the full production sequence: plan written -> baseline exists ->
    plan modified -> check-immutability and check-decision-log detect violations.

    This mirrors the real hook chain:
      planctl.py stamp (creates baseline) -> plan edited -> planctl.py check-immutability
    """

    def test_full_write_guard_sequence(self, tmp_path):
        plan = tmp_path / "MASTER_PLAN.md"
        plan.write_text(MINIMAL_PLAN)

        # Step 1: Guardian stamps plan after approval — baseline created
        code, _ = run(["stamp", str(plan), "--summary", "approved plan"], cwd=str(tmp_path))
        assert code == 0
        assert (tmp_path / ".plan-baseline.json").exists()

        # Step 2: Validate passes on the stamped plan
        code, _ = run(["validate", str(plan)])
        assert code == 0

        # Step 3: check-immutability with baseline passes on unmodified plan
        code, out = run_json(["check-immutability", str(plan)], cwd=str(tmp_path))
        assert code == 0
        assert out["immutable"] is True

        # Step 4: Planner appends to Identity (allowed — starts with baseline)
        appended = plan.read_text().replace(
            "This is the test project identity.",
            "This is the test project identity.\n\nAdded context.",
        )
        plan.write_text(appended)
        code, out = run_json(["check-immutability", str(plan)], cwd=str(tmp_path))
        assert code == 0, f"Append should be allowed: {out}"
        assert out["immutable"] is True

        # Step 5: Agent rewrites Architecture — must be denied
        rewritten = plan.read_text().replace(
            "Architecture overview here.",
            "COMPLETELY NEW architecture that replaces the original.",
        )
        plan.write_text(rewritten)
        code, out = run_json(["check-immutability", str(plan)], cwd=str(tmp_path))
        assert code != 0
        assert out["immutable"] is False
        assert any("Architecture" in v.get("section", "") for v in out["violations"])

        # Step 6: Decision log check fails when entries deleted
        plan.write_text(MINIMAL_PLAN)
        run(["refresh-baseline", str(plan)], cwd=str(tmp_path))
        no_decisions = plan.read_text().replace(
            "- `2026-03-24 -- DEC-FORK-001` Bootstrap decision.\n",
            "",
        )
        plan.write_text(no_decisions)
        code, out = run_json(["check-decision-log", str(plan)], cwd=str(tmp_path))
        assert code != 0
        assert out["append_only"] is False
