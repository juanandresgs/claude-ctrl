"""Tests for ``cc-policy constitution list`` and ``cc-policy constitution validate``.

@decision DEC-CLAUDEX-CONSTITUTION-CLI-TESTS-001
Title: Constitution CLI tests pin list/validate output shape and healthy/unhealthy behavior
Status: accepted
Rationale: The constitution CLI surfaces are read-only inspection tools
  for the constitution registry. Tests pin:

    1. ``list`` returns registry-derived concrete/planned counts and paths.
    2. ``validate`` is healthy in the current repo (all concrete paths exist).
    3. Missing concrete paths produce unhealthy output and non-zero exit.
    4. Tests do not duplicate the full constitution path list — they use
       ``constitution_registry`` as the authority.
    5. Output is valid JSON on stdout (CI-friendly contract).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from runtime.core import constitution_registry as cr

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_CLI = str(_REPO_ROOT / "runtime" / "cli.py")


def _run_cli(args: list[str]) -> tuple[int, dict]:
    """Invoke cc-policy via subprocess and return (exit_code, parsed_json)."""
    env = {**os.environ, "PYTHONPATH": str(_REPO_ROOT)}
    result = subprocess.run(
        [sys.executable, _CLI] + args,
        capture_output=True,
        text=True,
        env=env,
    )
    output = result.stdout.strip() or result.stderr.strip()
    try:
        payload = json.loads(output)
    except (json.JSONDecodeError, TypeError):
        pytest.fail(
            f"CLI output is not valid JSON.\n"
            f"exit={result.returncode}\n"
            f"stdout={result.stdout!r}\n"
            f"stderr={result.stderr!r}"
        )
    return result.returncode, payload


# ---------------------------------------------------------------------------
# constitution list
# ---------------------------------------------------------------------------


class TestConstitutionList:
    def test_list_returns_ok(self):
        code, payload = _run_cli(["constitution", "list"])
        assert code == 0
        assert payload["status"] == "ok"

    def test_list_concrete_count_matches_registry(self):
        code, payload = _run_cli(["constitution", "list"])
        assert payload["concrete_count"] == len(cr.concrete_entries())

    def test_list_planned_count_matches_registry(self):
        code, payload = _run_cli(["constitution", "list"])
        assert payload["planned_count"] == len(cr.planned_areas())

    def test_list_concrete_paths_match_registry(self):
        code, payload = _run_cli(["constitution", "list"])
        assert set(payload["concrete_paths"]) == cr.CONCRETE_PATHS

    def test_list_planned_areas_match_registry(self):
        code, payload = _run_cli(["constitution", "list"])
        expected = [e.name for e in cr.planned_areas()]
        assert payload["planned_areas"] == expected

    def test_list_concrete_entries_have_name_path_rationale(self):
        code, payload = _run_cli(["constitution", "list"])
        for entry in payload["concrete_entries"]:
            assert "name" in entry
            assert "path" in entry
            assert "rationale" in entry

    def test_list_output_is_valid_json(self):
        """Output must always be parseable JSON (CI contract)."""
        code, payload = _run_cli(["constitution", "list"])
        assert isinstance(payload, dict)


# ---------------------------------------------------------------------------
# constitution validate — healthy case
# ---------------------------------------------------------------------------


class TestConstitutionValidateHealthy:
    def test_validate_returns_ok_in_current_repo(self):
        code, payload = _run_cli(["constitution", "validate"])
        assert code == 0
        assert payload["status"] == "ok"
        assert payload["healthy"] is True

    def test_validate_concrete_count_matches_registry(self):
        code, payload = _run_cli(["constitution", "validate"])
        assert payload["concrete_count"] == len(cr.concrete_entries())

    def test_validate_no_missing_paths(self):
        code, payload = _run_cli(["constitution", "validate"])
        assert payload["missing_concrete_paths"] == []

    def test_validate_planned_areas_present(self):
        code, payload = _run_cli(["constitution", "validate"])
        expected = [e.name for e in cr.planned_areas()]
        assert payload["planned_areas"] == expected


# ---------------------------------------------------------------------------
# constitution validate — unhealthy case (missing concrete path)
# ---------------------------------------------------------------------------


class TestConstitutionValidateUnhealthy:
    def test_validate_unhealthy_when_repo_root_has_no_files(self, tmp_path):
        """Point --repo-root at an empty dir; all concrete paths are missing."""
        code, payload = _run_cli([
            "constitution", "validate",
            "--repo-root", str(tmp_path),
        ])
        assert code != 0
        assert payload["healthy"] is False
        assert payload["status"] == "unhealthy"
        assert len(payload["missing_concrete_paths"]) == len(cr.concrete_entries())

    def test_validate_unhealthy_lists_specific_missing_paths(self, tmp_path):
        """Missing paths are enumerated in the output."""
        code, payload = _run_cli([
            "constitution", "validate",
            "--repo-root", str(tmp_path),
        ])
        missing_set = set(payload["missing_concrete_paths"])
        assert cr.CONCRETE_PATHS == missing_set

    def test_validate_partial_missing(self, tmp_path):
        """Create all but one concrete file; validate reports exactly one missing."""
        concrete_paths = list(cr.CONCRETE_PATHS)
        # Create all files except the first one.
        omitted = sorted(concrete_paths)[0]
        for p in concrete_paths:
            if p == omitted:
                continue
            full = tmp_path / p
            full.parent.mkdir(parents=True, exist_ok=True)
            full.write_text("placeholder")

        code, payload = _run_cli([
            "constitution", "validate",
            "--repo-root", str(tmp_path),
        ])
        assert code != 0
        assert payload["healthy"] is False
        assert payload["missing_concrete_paths"] == [omitted]
