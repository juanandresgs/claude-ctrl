"""Tests for `cc-policy prompt-pack check` (read-only prompt-pack drift CLI).

@decision DEC-CLAUDEX-PROMPT-PACK-CHECK-CLI-TESTS-001
Title: The read-only prompt-pack check CLI wraps validate_prompt_pack without adding its own comparison logic
Status: proposed (Phase 2 read-only CLI, DEC-CLAUDEX-PROMPT-PACK-VALIDATION-001)
Rationale: The CLI handler is a thin wrapper around
  ``runtime.core.prompt_pack_validation.validate_prompt_pack``. All
  comparison logic lives in the pure validator; the CLI layer only
  reads the candidate file and the inputs JSON, validates their
  top-level shape, and shapes the payload. These tests pin:

    1. Healthy synthetic case: writing
       ``render_prompt_pack(...)`` output and a matching inputs
       JSON to temp files then invoking the CLI returns exit 0
       with ``status=ok`` and the validator's full report.
    2. Drift case: a mutated candidate returns exit 1 with
       ``status=violation`` and a valid JSON report on stdout.
    3. Missing candidate path → ``_err(...)`` error exit.
    4. Missing inputs path → ``_err(...)`` error exit.
    5. Malformed JSON inputs → ``_err(...)``.
    6. Missing required key (workflow_id / stage_id / layers /
       generated_at) → ``_err(...)``.
    7. Wrong required-key types (non-string workflow_id, non-dict
       layers, non-int generated_at, boolean-as-int generated_at,
       non-string manifest_version) → ``_err(...)``.
    8. Payload contract: healthy and drift payloads both carry
       ``report`` + ``candidate_path`` + ``inputs_path`` +
       ``repo_root`` + ``status``, and the ``report`` subobject
       has the stable 11-key validator contract.
    9. Output is always valid JSON on stdout regardless of exit
       code.
   10. Read-only guarantee: neither the candidate file nor the
       inputs file is modified (byte content + mtime unchanged).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from runtime.core import prompt_pack as pp
from runtime.core import prompt_pack_validation as ppv

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
        parsed = json.loads(output)
    except json.JSONDecodeError:
        parsed = {"_raw": output}
    return result.returncode, parsed


def _default_layers() -> dict:
    return {
        name: f"Body for {name} layer."
        for name in pp.CANONICAL_LAYER_ORDER
    }


def _write_healthy_pair(tmp_path: Path) -> tuple[Path, Path, str]:
    """Write a matching candidate+inputs pair and return their paths.

    Returns ``(candidate_path, inputs_path, rendered_text)``.
    """
    layers = _default_layers()
    text = pp.render_prompt_pack(
        workflow_id="wf-check",
        stage_id="planner",
        layers=layers,
    )
    candidate = tmp_path / "candidate.md"
    candidate.write_text(text)
    inputs = tmp_path / "inputs.json"
    inputs.write_text(
        json.dumps(
            {
                "workflow_id": "wf-check",
                "stage_id": "planner",
                "layers": layers,
                "generated_at": 1_700_000_000,
            }
        )
    )
    return candidate, inputs, text


def _write_inputs(tmp_path: Path, payload: dict) -> Path:
    path = tmp_path / "inputs.json"
    path.write_text(json.dumps(payload))
    return path


# ---------------------------------------------------------------------------
# 1. Healthy synthetic case
# ---------------------------------------------------------------------------


class TestHealthySyntheticCase:
    def test_matching_candidate_and_inputs_exits_zero(self, tmp_path):
        candidate, inputs, _text = _write_healthy_pair(tmp_path)
        code, out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(inputs),
            ]
        )
        assert code == 0, f"unexpected drift: {out}"
        assert out["status"] == "ok"
        assert out["report"]["status"] == ppv.VALIDATION_STATUS_OK
        assert out["report"]["healthy"] is True
        assert out["report"]["first_mismatch"] is None

    def test_payload_includes_all_path_fields(self, tmp_path):
        candidate, inputs, _text = _write_healthy_pair(tmp_path)
        code, out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(inputs),
            ]
        )
        assert code == 0
        assert out["candidate_path"] == str(candidate.resolve())
        assert out["inputs_path"] == str(inputs.resolve())
        assert "repo_root" in out
        assert Path(out["repo_root"]).exists()

    def test_report_hash_matches_projection(self, tmp_path):
        candidate, inputs, _text = _write_healthy_pair(tmp_path)
        code, out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(inputs),
            ]
        )
        assert code == 0
        projection = pp.build_prompt_pack(
            workflow_id="wf-check",
            stage_id="planner",
            layers=_default_layers(),
            generated_at=1_700_000_000,
        )
        assert out["report"]["expected_content_hash"] == projection.content_hash
        assert out["report"]["candidate_content_hash"] == projection.content_hash

    def test_healthy_identity_fields_echoed_back(self, tmp_path):
        candidate, inputs, _text = _write_healthy_pair(tmp_path)
        code, out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(inputs),
            ]
        )
        assert code == 0
        assert out["report"]["workflow_id"] == "wf-check"
        assert out["report"]["stage_id"] == "planner"

    def test_optional_manifest_version_is_accepted(self, tmp_path):
        layers = _default_layers()
        text = pp.render_prompt_pack(
            workflow_id="wf-mv",
            stage_id="planner",
            layers=layers,
        )
        candidate = tmp_path / "c.md"
        candidate.write_text(text)
        inputs = _write_inputs(
            tmp_path,
            {
                "workflow_id": "wf-mv",
                "stage_id": "planner",
                "layers": layers,
                "generated_at": 1,
                "manifest_version": "2.5.0",
            },
        )
        code, out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(inputs),
            ]
        )
        assert code == 0
        assert out["report"]["healthy"] is True


# ---------------------------------------------------------------------------
# 2. Drift cases
# ---------------------------------------------------------------------------


class TestDriftCases:
    def test_mutated_candidate_is_drift(self, tmp_path):
        candidate, inputs, text = _write_healthy_pair(tmp_path)
        # Change the first layer body inline.
        candidate.write_text(
            text.replace("Body for constitution layer.", "TAMPERED body", 1)
        )
        code, out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(inputs),
            ]
        )
        assert code == 1
        assert out["status"] == "violation"
        assert out["report"]["status"] == ppv.VALIDATION_STATUS_DRIFT
        assert out["report"]["healthy"] is False
        assert out["report"]["first_mismatch"] is not None
        assert "TAMPERED" in out["report"]["first_mismatch"]["candidate"]

    def test_extra_trailing_content_is_drift(self, tmp_path):
        candidate, inputs, text = _write_healthy_pair(tmp_path)
        candidate.write_text(text + "EXTRA TRAILING LINE\n")
        code, out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(inputs),
            ]
        )
        assert code == 1
        assert out["status"] == "violation"
        assert (
            out["report"]["candidate_line_count"]
            > out["report"]["expected_line_count"]
        )

    def test_empty_candidate_is_drift(self, tmp_path):
        candidate, inputs, _text = _write_healthy_pair(tmp_path)
        candidate.write_text("")
        code, out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(inputs),
            ]
        )
        assert code == 1
        assert out["status"] == "violation"
        assert out["report"]["healthy"] is False
        assert out["report"]["first_mismatch"] is not None


# ---------------------------------------------------------------------------
# 3. Missing-file errors
# ---------------------------------------------------------------------------


class TestMissingFileErrors:
    def test_missing_candidate_returns_error(self, tmp_path):
        _candidate, inputs, _text = _write_healthy_pair(tmp_path)
        bogus = tmp_path / "does-not-exist.md"
        code, out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(bogus),
                "--inputs-path",
                str(inputs),
            ]
        )
        assert code != 0
        assert (
            "candidate file not found" in out.get("message", "")
            or "_raw" in out
        )

    def test_missing_inputs_returns_error(self, tmp_path):
        candidate, _inputs, _text = _write_healthy_pair(tmp_path)
        bogus = tmp_path / "does-not-exist.json"
        code, out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(bogus),
            ]
        )
        assert code != 0
        assert (
            "inputs file not found" in out.get("message", "") or "_raw" in out
        )


# ---------------------------------------------------------------------------
# 4. Malformed inputs
# ---------------------------------------------------------------------------


class TestMalformedInputs:
    def _candidate_with_inputs(
        self, tmp_path: Path, inputs_payload
    ) -> tuple[Path, Path]:
        """Write a well-formed candidate + caller-supplied inputs.

        ``inputs_payload`` may be a dict (serialised to JSON) or a
        raw string (written verbatim — used for malformed JSON
        cases).
        """
        candidate = tmp_path / "c.md"
        candidate.write_text(
            pp.render_prompt_pack(
                workflow_id="wf",
                stage_id="planner",
                layers=_default_layers(),
            )
        )
        inputs = tmp_path / "inputs.json"
        if isinstance(inputs_payload, str):
            inputs.write_text(inputs_payload)
        else:
            inputs.write_text(json.dumps(inputs_payload))
        return candidate, inputs

    def _run(self, candidate: Path, inputs: Path) -> tuple[int, dict]:
        return _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(inputs),
            ]
        )

    def test_malformed_json_returns_error(self, tmp_path):
        candidate, inputs = self._candidate_with_inputs(
            tmp_path, "{ not valid json"
        )
        code, out = self._run(candidate, inputs)
        assert code != 0
        assert (
            "failed to read inputs" in out.get("message", "") or "_raw" in out
        )

    def test_inputs_must_be_object(self, tmp_path):
        candidate, inputs = self._candidate_with_inputs(
            tmp_path, "[1, 2, 3]"
        )
        code, out = self._run(candidate, inputs)
        assert code != 0
        assert (
            "must be an object" in out.get("message", "") or "_raw" in out
        )

    def test_missing_workflow_id_returns_error(self, tmp_path):
        candidate, inputs = self._candidate_with_inputs(
            tmp_path,
            {
                "stage_id": "planner",
                "layers": _default_layers(),
                "generated_at": 1,
            },
        )
        code, out = self._run(candidate, inputs)
        assert code != 0
        assert "workflow_id" in out.get("message", "") or "_raw" in out

    def test_non_string_workflow_id_returns_error(self, tmp_path):
        candidate, inputs = self._candidate_with_inputs(
            tmp_path,
            {
                "workflow_id": 42,
                "stage_id": "planner",
                "layers": _default_layers(),
                "generated_at": 1,
            },
        )
        code, out = self._run(candidate, inputs)
        assert code != 0
        assert "workflow_id" in out.get("message", "") or "_raw" in out

    def test_empty_workflow_id_returns_error(self, tmp_path):
        candidate, inputs = self._candidate_with_inputs(
            tmp_path,
            {
                "workflow_id": "",
                "stage_id": "planner",
                "layers": _default_layers(),
                "generated_at": 1,
            },
        )
        code, out = self._run(candidate, inputs)
        assert code != 0
        assert "workflow_id" in out.get("message", "") or "_raw" in out

    def test_missing_stage_id_returns_error(self, tmp_path):
        candidate, inputs = self._candidate_with_inputs(
            tmp_path,
            {
                "workflow_id": "wf",
                "layers": _default_layers(),
                "generated_at": 1,
            },
        )
        code, out = self._run(candidate, inputs)
        assert code != 0
        assert "stage_id" in out.get("message", "") or "_raw" in out

    def test_missing_layers_returns_error(self, tmp_path):
        candidate, inputs = self._candidate_with_inputs(
            tmp_path,
            {
                "workflow_id": "wf",
                "stage_id": "planner",
                "generated_at": 1,
            },
        )
        code, out = self._run(candidate, inputs)
        assert code != 0
        assert "layers" in out.get("message", "") or "_raw" in out

    def test_non_object_layers_returns_error(self, tmp_path):
        candidate, inputs = self._candidate_with_inputs(
            tmp_path,
            {
                "workflow_id": "wf",
                "stage_id": "planner",
                "layers": ["not", "a", "dict"],
                "generated_at": 1,
            },
        )
        code, out = self._run(candidate, inputs)
        assert code != 0
        assert "layers" in out.get("message", "") or "_raw" in out

    def test_missing_generated_at_returns_error(self, tmp_path):
        candidate, inputs = self._candidate_with_inputs(
            tmp_path,
            {
                "workflow_id": "wf",
                "stage_id": "planner",
                "layers": _default_layers(),
            },
        )
        code, out = self._run(candidate, inputs)
        assert code != 0
        assert "generated_at" in out.get("message", "") or "_raw" in out

    def test_string_generated_at_returns_error(self, tmp_path):
        candidate, inputs = self._candidate_with_inputs(
            tmp_path,
            {
                "workflow_id": "wf",
                "stage_id": "planner",
                "layers": _default_layers(),
                "generated_at": "1700000000",
            },
        )
        code, out = self._run(candidate, inputs)
        assert code != 0
        assert "generated_at" in out.get("message", "") or "_raw" in out

    def test_boolean_generated_at_returns_error(self, tmp_path):
        candidate, inputs = self._candidate_with_inputs(
            tmp_path,
            {
                "workflow_id": "wf",
                "stage_id": "planner",
                "layers": _default_layers(),
                "generated_at": True,
            },
        )
        code, out = self._run(candidate, inputs)
        assert code != 0
        assert "generated_at" in out.get("message", "") or "_raw" in out

    def test_negative_generated_at_returns_error(self, tmp_path):
        candidate, inputs = self._candidate_with_inputs(
            tmp_path,
            {
                "workflow_id": "wf",
                "stage_id": "planner",
                "layers": _default_layers(),
                "generated_at": -1,
            },
        )
        code, out = self._run(candidate, inputs)
        assert code != 0
        assert "generated_at" in out.get("message", "") or "_raw" in out

    def test_non_string_manifest_version_returns_error(self, tmp_path):
        candidate, inputs = self._candidate_with_inputs(
            tmp_path,
            {
                "workflow_id": "wf",
                "stage_id": "planner",
                "layers": _default_layers(),
                "generated_at": 1,
                "manifest_version": 99,
            },
        )
        code, out = self._run(candidate, inputs)
        assert code != 0
        assert "manifest_version" in out.get("message", "") or "_raw" in out

    def test_invalid_layers_raises_through_validator(self, tmp_path):
        # Missing a canonical layer — the CLI's top-level shape
        # check passes (layers is a dict), but the validator's
        # delegation to render_prompt_pack raises ValueError, which
        # the CLI translates to a helpful error.
        bad_layers = _default_layers()
        del bad_layers["constitution"]
        candidate, inputs = self._candidate_with_inputs(
            tmp_path,
            {
                "workflow_id": "wf",
                "stage_id": "planner",
                "layers": bad_layers,
                "generated_at": 1,
            },
        )
        code, out = self._run(candidate, inputs)
        assert code != 0
        message = out.get("message", "")
        assert "invalid inputs" in message or "_raw" in out
        # The validator's specific message about missing canonical
        # layers must be surfaced.
        assert "constitution" in message or "_raw" in out


# ---------------------------------------------------------------------------
# 5. Payload contract
# ---------------------------------------------------------------------------


EXPECTED_PAYLOAD_KEYS_HEALTHY = {
    "report",
    "candidate_path",
    "inputs_path",
    "repo_root",
    "status",
}

# Drift path adds nothing — ``status`` is still present but set to
# ``"violation"``. Key set is identical.
EXPECTED_PAYLOAD_KEYS_DRIFT = EXPECTED_PAYLOAD_KEYS_HEALTHY

EXPECTED_REPORT_KEYS = {
    "status",
    "healthy",
    "expected_content_hash",
    "candidate_content_hash",
    "exact_match",
    "expected_line_count",
    "candidate_line_count",
    "first_mismatch",
    "generator_version",
    "workflow_id",
    "stage_id",
}


class TestPayloadContract:
    def test_healthy_payload_has_stable_keys(self, tmp_path):
        candidate, inputs, _text = _write_healthy_pair(tmp_path)
        code, out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(inputs),
            ]
        )
        assert code == 0
        assert set(out.keys()) == EXPECTED_PAYLOAD_KEYS_HEALTHY
        assert set(out["report"].keys()) == EXPECTED_REPORT_KEYS

    def test_drift_payload_has_stable_keys(self, tmp_path):
        candidate, inputs, text = _write_healthy_pair(tmp_path)
        candidate.write_text(text + "EXTRA\n")
        code, out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(inputs),
            ]
        )
        assert code == 1
        assert set(out.keys()) == EXPECTED_PAYLOAD_KEYS_DRIFT
        assert set(out["report"].keys()) == EXPECTED_REPORT_KEYS
        assert out["status"] == "violation"

    def test_output_is_always_valid_json_on_stdout(self, tmp_path):
        candidate, inputs, text = _write_healthy_pair(tmp_path)
        code, out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(inputs),
            ]
        )
        assert code == 0
        assert "_raw" not in out

        candidate.write_text(text + "EXTRA\n")
        code, out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(inputs),
            ]
        )
        assert code == 1
        assert "_raw" not in out


# ---------------------------------------------------------------------------
# 6. Read-only guarantee
# ---------------------------------------------------------------------------


class TestReadOnlyGuarantee:
    def test_cli_does_not_modify_candidate_file(self, tmp_path):
        candidate, inputs, _text = _write_healthy_pair(tmp_path)
        pre_bytes = candidate.read_bytes()
        pre_mtime = candidate.stat().st_mtime

        code, _out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(inputs),
            ]
        )
        assert code == 0
        assert candidate.read_bytes() == pre_bytes
        assert candidate.stat().st_mtime == pre_mtime

    def test_cli_does_not_modify_inputs_file(self, tmp_path):
        candidate, inputs, _text = _write_healthy_pair(tmp_path)
        pre_bytes = inputs.read_bytes()
        pre_mtime = inputs.stat().st_mtime

        code, _out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(inputs),
            ]
        )
        assert code == 0
        assert inputs.read_bytes() == pre_bytes
        assert inputs.stat().st_mtime == pre_mtime

    def test_cli_does_not_modify_files_on_drift_path(self, tmp_path):
        candidate, inputs, text = _write_healthy_pair(tmp_path)
        candidate.write_text(text + "DRIFT\n")
        cand_pre_bytes = candidate.read_bytes()
        cand_pre_mtime = candidate.stat().st_mtime
        inp_pre_bytes = inputs.read_bytes()
        inp_pre_mtime = inputs.stat().st_mtime

        code, _out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(inputs),
            ]
        )
        assert code == 1
        assert candidate.read_bytes() == cand_pre_bytes
        assert candidate.stat().st_mtime == cand_pre_mtime
        assert inputs.read_bytes() == inp_pre_bytes
        assert inputs.stat().st_mtime == inp_pre_mtime

    def test_cli_does_not_create_extra_files(self, tmp_path):
        candidate, inputs, _text = _write_healthy_pair(tmp_path)
        pre_entries = set(tmp_path.iterdir())

        _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(inputs),
            ]
        )

        post_entries = set(tmp_path.iterdir())
        assert post_entries == pre_entries, (
            f"CLI created unexpected files in tmp_path: "
            f"{post_entries - pre_entries}"
        )


# ---------------------------------------------------------------------------
# 7. --metadata-path opt-in gate (Phase 7 Slice 12)
#
# @decision DEC-CLAUDEX-PROMPT-PACK-CHECK-CLI-METADATA-TESTS-001
# Title: --metadata-path extends check with metadata-drift validation; body-only behavior remains unchanged
# Status: proposed (Phase 7 Slice 12)
# Rationale: Phase 7 Slice 11 made compiled prompt-pack
#   ``metadata.stale_condition.watched_files`` meaningful (full
#   concrete constitution set). Slice 12 adds the CLI gate so
#   operators can revalidate metadata without reconstructing the
#   constitution set themselves. These tests pin:
#
#     * body-only behavior (no ``--metadata-path``) is byte-identical
#       to the prior contract — the new flag is pure opt-in
#     * when ``--metadata-path`` is active, the overall exit is 0 iff
#       BOTH body and metadata reports are healthy
#     * a tampered metadata file with a clean body still fails
#     * a drifted body with a clean metadata file still fails
#     * missing ``inputs.watched_files`` errors with a CLI error
#       rather than silently falling back to defaults
#     * malformed ``inputs.watched_files`` (non-list, non-string
#       entries, empty-string entries) all error cleanly
# ---------------------------------------------------------------------------


def _build_metadata_dict(
    *,
    workflow_id: str = "wf-meta",
    stage_id: str = "planner",
    layers: dict | None = None,
    generated_at: int = 1_700_000_000,
    watched_files: tuple[str, ...] = ("runtime/core/prompt_pack_resolver.py",),
) -> dict:
    """Build a metadata dict that the check CLI will accept as healthy.

    Uses the same helpers the CLI uses so the synthetic metadata
    matches what the validator rebuilds.
    """
    if layers is None:
        layers = _default_layers()
    projection = pp.build_prompt_pack(
        workflow_id=workflow_id,
        stage_id=stage_id,
        layers=layers,
        generated_at=generated_at,
        watched_files=watched_files,
    )
    return ppv._serialise_metadata_to_compile_shape(projection.metadata)


def _write_healthy_metadata_triple(
    tmp_path: Path,
    *,
    workflow_id: str = "wf-meta",
    stage_id: str = "planner",
    generated_at: int = 1_700_000_000,
    watched_files: tuple[str, ...] = ("runtime/core/prompt_pack_resolver.py",),
) -> tuple[Path, Path, Path, dict]:
    """Write body + inputs (with watched_files) + metadata files.

    Returns ``(candidate_path, inputs_path, metadata_path, metadata_dict)``.
    """
    layers = _default_layers()
    text = pp.render_prompt_pack(
        workflow_id=workflow_id,
        stage_id=stage_id,
        layers=layers,
    )
    candidate = tmp_path / "candidate.md"
    candidate.write_text(text)
    inputs = tmp_path / "inputs.json"
    inputs.write_text(
        json.dumps(
            {
                "workflow_id": workflow_id,
                "stage_id": stage_id,
                "layers": layers,
                "generated_at": generated_at,
                "watched_files": list(watched_files),
            }
        )
    )
    metadata_dict = _build_metadata_dict(
        workflow_id=workflow_id,
        stage_id=stage_id,
        layers=layers,
        generated_at=generated_at,
        watched_files=watched_files,
    )
    metadata = tmp_path / "metadata.json"
    metadata.write_text(json.dumps(metadata_dict))
    return candidate, inputs, metadata, metadata_dict


class TestMetadataPathOptInGate:
    def test_body_only_behavior_unchanged_without_metadata_flag(self, tmp_path):
        """Omitting ``--metadata-path`` yields the prior body-only report
        shape — no ``metadata_report`` / ``metadata_path`` keys leak in."""
        candidate, inputs, _text = _write_healthy_pair(tmp_path)
        code, out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(inputs),
            ]
        )
        assert code == 0
        assert out["status"] == "ok"
        assert "metadata_report" not in out
        assert "metadata_path" not in out
        assert out["report"]["healthy"] is True

    def test_metadata_path_healthy_case_exits_zero(self, tmp_path):
        """When body + inputs + metadata all agree, the CLI exits 0 and
        both reports report healthy."""
        candidate, inputs, metadata, _md = _write_healthy_metadata_triple(tmp_path)
        code, out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(inputs),
                "--metadata-path",
                str(metadata),
            ]
        )
        assert code == 0, f"unexpected drift: {out}"
        assert out["status"] == "ok"
        assert out["report"]["healthy"] is True
        assert out["metadata_report"]["status"] == ppv.VALIDATION_STATUS_OK
        assert out["metadata_report"]["healthy"] is True
        assert out["metadata_report"]["exact_match"] is True
        assert out["metadata_report"]["first_mismatch"] is None
        assert out["metadata_path"] == str(metadata.resolve())

    def test_tampered_metadata_fails_with_clean_body(self, tmp_path):
        """Body matches, but metadata has been mutated → overall fail."""
        candidate, inputs, metadata, md = _write_healthy_metadata_triple(tmp_path)
        tampered = dict(md)
        tampered["stale_condition"] = {
            **md["stale_condition"],
            "watched_files": ["WRONG_FILE.md"],
        }
        metadata.write_text(json.dumps(tampered))
        code, out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(inputs),
                "--metadata-path",
                str(metadata),
            ]
        )
        assert code == 1
        assert out["status"] == "violation"
        # Body is still clean.
        assert out["report"]["healthy"] is True
        # Metadata surfaces drift.
        assert out["metadata_report"]["healthy"] is False
        assert out["metadata_report"]["status"] == ppv.VALIDATION_STATUS_DRIFT
        assert out["metadata_report"]["first_mismatch"] is not None
        assert "watched_files" in out["metadata_report"]["first_mismatch"]["path"]

    def test_body_drift_with_metadata_ok_still_fails(self, tmp_path):
        """Metadata is clean, but body is drifted → overall fail."""
        candidate, inputs, metadata, _md = _write_healthy_metadata_triple(tmp_path)
        text = candidate.read_text()
        candidate.write_text(
            text.replace("Body for constitution layer.", "TAMPERED body", 1)
        )
        code, out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(inputs),
                "--metadata-path",
                str(metadata),
            ]
        )
        assert code == 1
        assert out["status"] == "violation"
        assert out["report"]["healthy"] is False
        assert out["metadata_report"]["healthy"] is True

    def test_missing_watched_files_in_inputs_errors(self, tmp_path):
        """Opting into --metadata-path without inputs.watched_files must
        error loudly rather than silently using a default tuple."""
        candidate, _inputs, metadata, _md = _write_healthy_metadata_triple(tmp_path)
        # Rewrite inputs WITHOUT watched_files.
        layers = _default_layers()
        inputs_no_wf = tmp_path / "inputs_no_wf.json"
        inputs_no_wf.write_text(
            json.dumps(
                {
                    "workflow_id": "wf-meta",
                    "stage_id": "planner",
                    "layers": layers,
                    "generated_at": 1_700_000_000,
                }
            )
        )
        code, out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(inputs_no_wf),
                "--metadata-path",
                str(metadata),
            ]
        )
        assert code != 0
        assert out["status"] == "error"
        assert "watched_files" in out["message"]

    def test_non_list_watched_files_errors(self, tmp_path):
        candidate, _inputs, metadata, _md = _write_healthy_metadata_triple(tmp_path)
        layers = _default_layers()
        bad_inputs = tmp_path / "bad_inputs.json"
        bad_inputs.write_text(
            json.dumps(
                {
                    "workflow_id": "wf-meta",
                    "stage_id": "planner",
                    "layers": layers,
                    "generated_at": 1_700_000_000,
                    "watched_files": "not-a-list",
                }
            )
        )
        code, out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(bad_inputs),
                "--metadata-path",
                str(metadata),
            ]
        )
        assert code != 0
        assert out["status"] == "error"
        assert "watched_files" in out["message"]

    def test_non_string_entry_in_watched_files_errors(self, tmp_path):
        candidate, _inputs, metadata, _md = _write_healthy_metadata_triple(tmp_path)
        layers = _default_layers()
        bad_inputs = tmp_path / "bad_inputs2.json"
        bad_inputs.write_text(
            json.dumps(
                {
                    "workflow_id": "wf-meta",
                    "stage_id": "planner",
                    "layers": layers,
                    "generated_at": 1_700_000_000,
                    "watched_files": ["ok.md", 42],
                }
            )
        )
        code, out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(bad_inputs),
                "--metadata-path",
                str(metadata),
            ]
        )
        assert code != 0
        assert out["status"] == "error"
        assert "watched_files" in out["message"]

    def test_empty_string_entry_in_watched_files_errors(self, tmp_path):
        candidate, _inputs, metadata, _md = _write_healthy_metadata_triple(tmp_path)
        layers = _default_layers()
        bad_inputs = tmp_path / "bad_inputs3.json"
        bad_inputs.write_text(
            json.dumps(
                {
                    "workflow_id": "wf-meta",
                    "stage_id": "planner",
                    "layers": layers,
                    "generated_at": 1_700_000_000,
                    "watched_files": ["ok.md", ""],
                }
            )
        )
        code, out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(bad_inputs),
                "--metadata-path",
                str(metadata),
            ]
        )
        assert code != 0
        assert out["status"] == "error"
        assert "watched_files" in out["message"]

    def test_missing_metadata_file_errors(self, tmp_path):
        candidate, inputs, _metadata, _md = _write_healthy_metadata_triple(tmp_path)
        bogus = tmp_path / "nope.json"
        code, out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(inputs),
                "--metadata-path",
                str(bogus),
            ]
        )
        assert code != 0
        assert out["status"] == "error"
        assert "metadata file not found" in out["message"]

    def test_malformed_metadata_json_errors(self, tmp_path):
        candidate, inputs, metadata, _md = _write_healthy_metadata_triple(tmp_path)
        metadata.write_text("{not valid json")
        code, out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(inputs),
                "--metadata-path",
                str(metadata),
            ]
        )
        assert code != 0
        assert out["status"] == "error"
        assert "failed to read metadata" in out["message"]

    def test_metadata_not_an_object_errors(self, tmp_path):
        candidate, inputs, metadata, _md = _write_healthy_metadata_triple(tmp_path)
        metadata.write_text(json.dumps(["not", "an", "object"]))
        code, out = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(candidate),
                "--inputs-path",
                str(inputs),
                "--metadata-path",
                str(metadata),
            ]
        )
        assert code != 0
        assert out["status"] == "error"
        assert "metadata JSON must be an object" in out["message"]
