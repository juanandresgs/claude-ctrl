"""Tests for `cc-policy hook doc-check` (read-only hook-doc drift CLI).

@decision DEC-CLAUDEX-HOOK-DOC-CHECK-CLI-TESTS-001
Title: The read-only hook doc-check CLI wraps validate_hook_doc without adding its own comparison logic
Status: proposed (Phase 2 read-only CLI, DEC-CLAUDEX-HOOK-DOC-VALIDATION-001)
Rationale: The CLI handler is a thin wrapper around
  ``runtime.core.hook_doc_validation.validate_hook_doc``. These
  tests pin:

    1. The healthy synthetic case: writing ``render_hook_doc()``
       output to a temp ``HOOKS.md`` and pointing the CLI at it via
       ``--doc-path`` returns exit 0 with ``status=ok`` and the
       validator's full report.
    2. Drift cases: a mutated candidate (modified line, extra
       content, empty file) returns exit 1 with ``status=violation``
       and a valid JSON report on stdout.
    3. Missing file: returns a non-zero error with a helpful
       message.
    4. Real-repo current state: Phase 7 Slice 1 regenerated
       ``hooks/HOOKS.md`` from the runtime manifest projection.
       The default-target call returns exit 0 with ``status=ok``
       and ``healthy=True``. If this test fails, the doc has
       drifted from the manifest and must be regenerated.
    5. Output is always valid JSON on stdout regardless of exit
       code (CI-friendly contract, same as
       ``cc-policy hook validate-settings``).
    6. The CLI does not write to the candidate file (mtime and
       byte content unchanged after invocation).
    7. CLI payload carries ``doc_path`` and ``repo_root`` alongside
       the validator report.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from runtime.core import hook_doc_projection as hdp
from runtime.core import hook_doc_validation as hdv

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_CLI = str(_REPO_ROOT / "runtime" / "cli.py")
_REAL_HOOK_DOC = _REPO_ROOT / "hooks" / "HOOKS.md"


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
        parsed = json.loads(output)
    except json.JSONDecodeError:
        parsed = {"_raw": output}
    return result.returncode, parsed


# ---------------------------------------------------------------------------
# 1. Healthy synthetic case — rendered output as candidate
# ---------------------------------------------------------------------------


class TestHealthySyntheticCase:
    def test_rendered_output_as_candidate_exits_zero(self, tmp_path):
        expected = hdp.render_hook_doc()
        fake_doc = tmp_path / "HOOKS.md"
        fake_doc.write_text(expected)

        code, out = _run_cli(
            ["hook", "doc-check", "--doc-path", str(fake_doc)]
        )
        assert code == 0, f"unexpected drift: {out}"
        assert out["status"] == "ok"
        assert out["report"]["status"] == hdv.VALIDATION_STATUS_OK
        assert out["report"]["healthy"] is True
        assert out["report"]["first_mismatch"] is None

    def test_payload_includes_doc_path_and_repo_root(self, tmp_path):
        expected = hdp.render_hook_doc()
        fake_doc = tmp_path / "HOOKS.md"
        fake_doc.write_text(expected)

        code, out = _run_cli(
            ["hook", "doc-check", "--doc-path", str(fake_doc)]
        )
        assert code == 0
        assert "doc_path" in out
        assert "repo_root" in out
        assert out["doc_path"] == str(fake_doc.resolve())
        assert Path(out["repo_root"]).exists()

    def test_report_hash_fields_match_projection(self, tmp_path):
        expected = hdp.render_hook_doc()
        fake_doc = tmp_path / "HOOKS.md"
        fake_doc.write_text(expected)

        code, out = _run_cli(
            ["hook", "doc-check", "--doc-path", str(fake_doc)]
        )
        assert code == 0
        # The CLI calls validate_hook_doc with int(time.time()) for
        # generated_at; the hash is derived from the rendered body
        # only, so a separate local build must produce the same
        # content_hash.
        projection = hdp.build_hook_doc_projection(generated_at=1)
        assert out["report"]["expected_content_hash"] == projection.content_hash
        assert (
            out["report"]["candidate_content_hash"]
            == projection.content_hash
        )

    def test_healthy_case_missing_trailing_newline_still_passes(self, tmp_path):
        # The validator pads trailing newlines to match expected.
        expected = hdp.render_hook_doc()
        fake_doc = tmp_path / "HOOKS.md"
        fake_doc.write_text(expected.rstrip("\n"))

        code, out = _run_cli(
            ["hook", "doc-check", "--doc-path", str(fake_doc)]
        )
        assert code == 0
        assert out["report"]["healthy"] is True


# ---------------------------------------------------------------------------
# 2. Drift cases
# ---------------------------------------------------------------------------


class TestDriftCases:
    def test_modified_title_line_is_drift(self, tmp_path):
        expected = hdp.render_hook_doc()
        lines = expected.splitlines()
        assert lines[0].startswith("# ClauDEX Hook Adapter Manifest")
        lines[0] = "# TAMPERED TITLE"
        candidate = "\n".join(lines) + "\n" * 2
        fake_doc = tmp_path / "HOOKS.md"
        fake_doc.write_text(candidate)

        code, out = _run_cli(
            ["hook", "doc-check", "--doc-path", str(fake_doc)]
        )
        assert code == 1
        assert out["status"] == "violation"
        assert out["report"]["status"] == hdv.VALIDATION_STATUS_DRIFT
        assert out["report"]["healthy"] is False
        assert out["report"]["first_mismatch"] is not None
        assert out["report"]["first_mismatch"]["line"] == 1
        assert (
            out["report"]["first_mismatch"]["candidate"] == "# TAMPERED TITLE"
        )

    def test_extra_content_line_is_drift(self, tmp_path):
        expected = hdp.render_hook_doc()
        fake_doc = tmp_path / "HOOKS.md"
        fake_doc.write_text(expected + "EXTRA ROGUE CONTENT LINE\n")

        code, out = _run_cli(
            ["hook", "doc-check", "--doc-path", str(fake_doc)]
        )
        assert code == 1
        assert out["status"] == "violation"
        assert out["report"]["healthy"] is False
        assert (
            out["report"]["candidate_line_count"]
            > out["report"]["expected_line_count"]
        )

    def test_empty_file_is_drift(self, tmp_path):
        fake_doc = tmp_path / "HOOKS.md"
        fake_doc.write_text("")

        code, out = _run_cli(
            ["hook", "doc-check", "--doc-path", str(fake_doc)]
        )
        assert code == 1
        assert out["status"] == "violation"
        assert out["report"]["healthy"] is False
        assert out["report"]["first_mismatch"] is not None


# ---------------------------------------------------------------------------
# 3. Missing file error path
# ---------------------------------------------------------------------------


class TestMissingFileError:
    def test_missing_file_returns_error(self, tmp_path):
        bogus = tmp_path / "does-not-exist.md"
        code, out = _run_cli(
            ["hook", "doc-check", "--doc-path", str(bogus)]
        )
        assert code != 0
        # Handler uses ``_err(...)`` which prints to stderr with
        # ``status=error`` and a ``message`` field.
        assert "not found" in out.get("message", "") or "_raw" in out


# ---------------------------------------------------------------------------
# 4. Real-repo current state pin (honest)
# ---------------------------------------------------------------------------


class TestRealRepoCurrentState:
    def test_real_repo_hook_doc_is_current(self):
        # Phase 7 Slice 1: hooks/HOOKS.md is now the derived projection
        # of runtime.core.hook_manifest.HOOK_MANIFEST, regenerated from
        # runtime.core.hook_doc_projection.render_hook_doc(). The doc-check
        # CLI must return exit 0 with healthy=True.
        assert _REAL_HOOK_DOC.is_file(), (
            "precondition: hooks/HOOKS.md must exist in the repo"
        )
        code, out = _run_cli(["hook", "doc-check"])
        assert code == 0, (
            f"hooks/HOOKS.md must match the runtime projection; "
            f"if drifting, regenerate via render_hook_doc(). Output: {out}"
        )
        assert out["status"] == "ok"
        assert out["report"]["status"] == hdv.VALIDATION_STATUS_OK
        assert out["report"]["healthy"] is True
        assert out["report"]["exact_match"] is True

    def test_real_repo_default_payload_fields(self):
        code, out = _run_cli(["hook", "doc-check"])
        assert "doc_path" in out
        assert "repo_root" in out
        # Default doc path is the repo root's hooks/HOOKS.md.
        assert out["doc_path"].endswith("hooks/HOOKS.md")


# ---------------------------------------------------------------------------
# 5. Output shape + JSON contract
# ---------------------------------------------------------------------------


class TestOutputContract:
    def test_healthy_payload_has_stable_keys(self, tmp_path):
        expected = hdp.render_hook_doc()
        fake_doc = tmp_path / "HOOKS.md"
        fake_doc.write_text(expected)

        code, out = _run_cli(
            ["hook", "doc-check", "--doc-path", str(fake_doc)]
        )
        assert code == 0
        assert "report" in out
        assert "doc_path" in out
        assert "repo_root" in out
        assert "status" in out

    def test_drift_payload_has_stable_keys(self, tmp_path):
        fake_doc = tmp_path / "HOOKS.md"
        fake_doc.write_text("garbage not matching the manifest\n")

        code, out = _run_cli(
            ["hook", "doc-check", "--doc-path", str(fake_doc)]
        )
        assert code == 1
        assert "report" in out
        assert "doc_path" in out
        assert "repo_root" in out
        assert out["status"] == "violation"

    def test_report_subobject_has_validator_key_set(self, tmp_path):
        expected = hdp.render_hook_doc()
        fake_doc = tmp_path / "HOOKS.md"
        fake_doc.write_text(expected)

        code, out = _run_cli(
            ["hook", "doc-check", "--doc-path", str(fake_doc)]
        )
        assert code == 0
        expected_report_keys = {
            "status",
            "healthy",
            "expected_content_hash",
            "candidate_content_hash",
            "exact_match",
            "expected_line_count",
            "candidate_line_count",
            "first_mismatch",
            "generator_version",
        }
        assert set(out["report"].keys()) == expected_report_keys

    def test_output_is_always_valid_json_on_stdout(self, tmp_path):
        # Healthy path
        fake_doc = tmp_path / "HOOKS.md"
        fake_doc.write_text(hdp.render_hook_doc())
        code, out = _run_cli(
            ["hook", "doc-check", "--doc-path", str(fake_doc)]
        )
        assert code == 0
        assert "_raw" not in out, "healthy path emitted non-JSON"

        # Drift path
        fake_doc.write_text("drifted\n")
        code, out = _run_cli(
            ["hook", "doc-check", "--doc-path", str(fake_doc)]
        )
        assert code == 1
        assert "_raw" not in out, "drift path emitted non-JSON"


# ---------------------------------------------------------------------------
# 6. CLI does not write to the candidate file
# ---------------------------------------------------------------------------


class TestReadOnlyGuarantee:
    def test_cli_does_not_modify_candidate_file(self, tmp_path):
        expected = hdp.render_hook_doc()
        fake_doc = tmp_path / "HOOKS.md"
        fake_doc.write_text(expected)
        pre_bytes = fake_doc.read_bytes()
        pre_mtime = fake_doc.stat().st_mtime

        code, _out = _run_cli(
            ["hook", "doc-check", "--doc-path", str(fake_doc)]
        )
        assert code == 0
        assert fake_doc.read_bytes() == pre_bytes
        assert fake_doc.stat().st_mtime == pre_mtime

    def test_cli_does_not_modify_drift_candidate_file(self, tmp_path):
        fake_doc = tmp_path / "HOOKS.md"
        fake_doc.write_text("drifted content\n")
        pre_bytes = fake_doc.read_bytes()
        pre_mtime = fake_doc.stat().st_mtime

        code, _out = _run_cli(
            ["hook", "doc-check", "--doc-path", str(fake_doc)]
        )
        assert code == 1
        assert fake_doc.read_bytes() == pre_bytes
        assert fake_doc.stat().st_mtime == pre_mtime

    def test_cli_does_not_execute_any_hook_script(self, tmp_path):
        # The validator does not know about hook scripts; the CLI
        # handler only reads the candidate file. Nothing under the
        # fake tmp_path should grow or get touched beyond the
        # candidate itself.
        fake_doc = tmp_path / "HOOKS.md"
        fake_doc.write_text(hdp.render_hook_doc())
        pre_entries = set(tmp_path.iterdir())

        _run_cli(["hook", "doc-check", "--doc-path", str(fake_doc)])

        post_entries = set(tmp_path.iterdir())
        assert post_entries == pre_entries, (
            f"CLI created unexpected files in tmp_path: "
            f"{post_entries - pre_entries}"
        )
