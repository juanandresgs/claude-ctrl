"""Tests for cc-policy bridge validate-settings CLI.

@decision DEC-CLAUDEX-BRIDGE-VALIDATE-CLI-TESTS-001
Title: cc-policy bridge validate-settings CLI exit codes and JSON output shape
Status: proposed (cc-policy-who-remediation Slice 1)
Rationale: The bridge validate-settings CLI command is the operational surface
  for CI and operator use. These tests pin:

    1. The CLI exits 0 with {"status": "ok", ...} on the live bridge file
       (baseline clean state after Slice 1 removes the 5 delegated patterns).
    2. The CLI exits non-zero with {"status": "drift", "messages": [...]} on
       each of the three canonical drift shapes:
         (i)  a delegated pattern re-added to permissions.deny
         (ii) a safety pattern removed from permissions.deny
         (iii) the PreToolUse Bash → pre-bash.sh hook wiring removed
    3. Output is always valid JSON on stdout regardless of exit code.
    4. --settings-path override routes to the provided file (test hermeticity).

  CLI invocation pattern follows the same pattern as test_hook_validate_settings.py.
"""

from __future__ import annotations

import copy
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from runtime.core import bridge_permissions as bp

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_CLI = str(_REPO_ROOT / "runtime" / "cli.py")
_BRIDGE_SETTINGS = _REPO_ROOT / "ClauDEX" / "bridge" / "claude-settings.json"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _run_cli(args: list[str]) -> tuple[int, dict]:
    """Run the CLI with the given arguments and return (returncode, parsed JSON)."""
    env = {
        **os.environ,
        "PYTHONPATH": str(_REPO_ROOT),
    }
    result = subprocess.run(
        [sys.executable, _CLI] + args,
        capture_output=True,
        text=True,
        env=env,
    )
    # CLI outputs JSON to stdout on both success and failure.
    # On error, stderr may carry the error JSON.
    output = result.stdout.strip() or result.stderr.strip()
    try:
        parsed = json.loads(output)
    except json.JSONDecodeError:
        parsed = {"_raw": output, "_returncode": result.returncode}
    return result.returncode, parsed


def _write_bridge_settings(path: Path, settings: dict) -> None:
    path.write_text(json.dumps(settings, indent=2), encoding="utf-8")


def _load_bridge_settings() -> dict:
    with _BRIDGE_SETTINGS.open() as f:
        return json.load(f)


# ---------------------------------------------------------------------------
# 1. Clean file → exit 0
# ---------------------------------------------------------------------------


class TestCleanFileExitsZero:
    def test_real_bridge_file_exits_zero(self):
        """The live bridge file must pass after Slice 1 removes delegated denies."""
        code, out = _run_cli(["bridge", "validate-settings"])
        assert code == 0, (
            f"cc-policy bridge validate-settings failed on the live bridge "
            f"file (exit {code}): {out}"
        )
        assert out.get("status") == "ok", (
            f"Expected status='ok' on clean file, got: {out}"
        )

    def test_real_bridge_file_output_is_valid_json(self):
        code, out = _run_cli(["bridge", "validate-settings"])
        assert "_raw" not in out, (
            "CLI output must be valid JSON; got non-JSON output"
        )

    def test_settings_path_override_with_clean_file(self, tmp_path):
        """--settings-path override passes on a clean copy of the live file."""
        settings = _load_bridge_settings()
        settings_file = tmp_path / "claude-settings.json"
        _write_bridge_settings(settings_file, settings)
        code, out = _run_cli(
            ["bridge", "validate-settings", "--settings-path", str(settings_file)]
        )
        assert code == 0, (
            f"Expected exit 0 on clean settings fixture, got {code}: {out}"
        )
        assert out.get("status") == "ok"

    def test_settings_path_in_response(self, tmp_path):
        """Response includes the settings_path that was validated."""
        settings = _load_bridge_settings()
        settings_file = tmp_path / "claude-settings.json"
        _write_bridge_settings(settings_file, settings)
        code, out = _run_cli(
            ["bridge", "validate-settings", "--settings-path", str(settings_file)]
        )
        assert code == 0
        assert "settings_path" in out, (
            f"Response should include 'settings_path' key: {out}"
        )


# ---------------------------------------------------------------------------
# 2. Drift shape (i): delegated pattern re-added
# ---------------------------------------------------------------------------


class TestDriftShapeOneDelegatedPatternAdded:
    def test_delegated_pattern_added_exits_nonzero(self, tmp_path):
        settings = _load_bridge_settings()
        poisoned = copy.deepcopy(settings)
        poisoned["permissions"]["deny"].append("Bash(git commit *)")
        settings_file = tmp_path / "claude-settings.json"
        _write_bridge_settings(settings_file, poisoned)

        code, out = _run_cli(
            ["bridge", "validate-settings", "--settings-path", str(settings_file)]
        )
        assert code != 0, (
            f"Expected non-zero exit when delegated pattern re-added, got {code}: {out}"
        )

    def test_delegated_pattern_added_reports_drift_status(self, tmp_path):
        settings = _load_bridge_settings()
        poisoned = copy.deepcopy(settings)
        poisoned["permissions"]["deny"].append("Bash(git push *)")
        settings_file = tmp_path / "claude-settings.json"
        _write_bridge_settings(settings_file, poisoned)

        code, out = _run_cli(
            ["bridge", "validate-settings", "--settings-path", str(settings_file)]
        )
        assert out.get("status") == "drift", (
            f"Expected status='drift', got: {out}"
        )

    def test_delegated_pattern_added_has_readable_messages(self, tmp_path):
        settings = _load_bridge_settings()
        poisoned = copy.deepcopy(settings)
        poisoned["permissions"]["deny"].append("Bash(git merge *)")
        settings_file = tmp_path / "claude-settings.json"
        _write_bridge_settings(settings_file, poisoned)

        code, out = _run_cli(
            ["bridge", "validate-settings", "--settings-path", str(settings_file)]
        )
        assert code != 0
        assert "messages" in out, f"Expected 'messages' key in drift response: {out}"
        assert len(out["messages"]) >= 1
        assert any("runtime-policy-delegated" in m for m in out["messages"]), (
            f"Expected at least one message mentioning 'runtime-policy-delegated': "
            f"{out['messages']}"
        )

    def test_output_is_valid_json_on_drift(self, tmp_path):
        settings = _load_bridge_settings()
        poisoned = copy.deepcopy(settings)
        poisoned["permissions"]["deny"].append("Bash(git commit *)")
        settings_file = tmp_path / "claude-settings.json"
        _write_bridge_settings(settings_file, poisoned)

        code, out = _run_cli(
            ["bridge", "validate-settings", "--settings-path", str(settings_file)]
        )
        assert "_raw" not in out, (
            "CLI output must be valid JSON even on drift exit"
        )


# ---------------------------------------------------------------------------
# 3. Drift shape (ii): safety pattern removed
# ---------------------------------------------------------------------------


class TestDriftShapeTwoSafetyPatternRemoved:
    def test_safety_pattern_removed_exits_nonzero(self, tmp_path):
        settings = _load_bridge_settings()
        poisoned = copy.deepcopy(settings)
        poisoned["permissions"]["deny"] = [
            e for e in poisoned["permissions"]["deny"]
            if e != "Bash(rm -rf *)"
        ]
        settings_file = tmp_path / "claude-settings.json"
        _write_bridge_settings(settings_file, poisoned)

        code, out = _run_cli(
            ["bridge", "validate-settings", "--settings-path", str(settings_file)]
        )
        assert code != 0, (
            f"Expected non-zero exit when safety pattern removed, got {code}: {out}"
        )

    def test_safety_pattern_removed_reports_drift_status(self, tmp_path):
        settings = _load_bridge_settings()
        poisoned = copy.deepcopy(settings)
        poisoned["permissions"]["deny"] = [
            e for e in poisoned["permissions"]["deny"]
            if e != "Bash(git branch -D *)"
        ]
        settings_file = tmp_path / "claude-settings.json"
        _write_bridge_settings(settings_file, poisoned)

        code, out = _run_cli(
            ["bridge", "validate-settings", "--settings-path", str(settings_file)]
        )
        assert out.get("status") == "drift"

    def test_safety_pattern_removed_has_readable_messages(self, tmp_path):
        settings = _load_bridge_settings()
        poisoned = copy.deepcopy(settings)
        poisoned["permissions"]["deny"] = [
            e for e in poisoned["permissions"]["deny"]
            if e != "Read(**/.env*)"
        ]
        settings_file = tmp_path / "claude-settings.json"
        _write_bridge_settings(settings_file, poisoned)

        code, out = _run_cli(
            ["bridge", "validate-settings", "--settings-path", str(settings_file)]
        )
        assert code != 0
        assert "messages" in out
        assert any("safety pattern" in m for m in out["messages"]), (
            f"Expected message mentioning 'safety pattern': {out['messages']}"
        )

    def test_output_is_valid_json_on_safety_drift(self, tmp_path):
        settings = _load_bridge_settings()
        poisoned = copy.deepcopy(settings)
        poisoned["permissions"]["deny"] = [
            e for e in poisoned["permissions"]["deny"]
            if e != "NotebookEdit"
        ]
        settings_file = tmp_path / "claude-settings.json"
        _write_bridge_settings(settings_file, poisoned)

        code, out = _run_cli(
            ["bridge", "validate-settings", "--settings-path", str(settings_file)]
        )
        assert "_raw" not in out, "CLI output must be valid JSON even on drift exit"


# ---------------------------------------------------------------------------
# 4. Drift shape (iii): PreToolUse Bash → pre-bash.sh wiring removed
# ---------------------------------------------------------------------------


class TestDriftShapeThreeWiringRemoved:
    def test_wiring_removed_exits_nonzero(self, tmp_path):
        settings = _load_bridge_settings()
        poisoned = copy.deepcopy(settings)
        # Remove all PreToolUse Bash entries
        pretooluse = poisoned.get("hooks", {}).get("PreToolUse", [])
        poisoned["hooks"]["PreToolUse"] = [
            block for block in pretooluse
            if not (isinstance(block, dict) and block.get("matcher") == "Bash")
        ]
        settings_file = tmp_path / "claude-settings.json"
        _write_bridge_settings(settings_file, poisoned)

        code, out = _run_cli(
            ["bridge", "validate-settings", "--settings-path", str(settings_file)]
        )
        assert code != 0, (
            f"Expected non-zero exit when pre-bash.sh wiring removed, "
            f"got {code}: {out}"
        )

    def test_wiring_removed_reports_drift_status(self, tmp_path):
        settings = _load_bridge_settings()
        poisoned = copy.deepcopy(settings)
        pretooluse = poisoned.get("hooks", {}).get("PreToolUse", [])
        poisoned["hooks"]["PreToolUse"] = [
            block for block in pretooluse
            if not (isinstance(block, dict) and block.get("matcher") == "Bash")
        ]
        settings_file = tmp_path / "claude-settings.json"
        _write_bridge_settings(settings_file, poisoned)

        code, out = _run_cli(
            ["bridge", "validate-settings", "--settings-path", str(settings_file)]
        )
        assert out.get("status") == "drift"

    def test_wiring_removed_has_readable_messages(self, tmp_path):
        settings = _load_bridge_settings()
        poisoned = copy.deepcopy(settings)
        pretooluse = poisoned.get("hooks", {}).get("PreToolUse", [])
        poisoned["hooks"]["PreToolUse"] = [
            block for block in pretooluse
            if not (isinstance(block, dict) and block.get("matcher") == "Bash")
        ]
        settings_file = tmp_path / "claude-settings.json"
        _write_bridge_settings(settings_file, poisoned)

        code, out = _run_cli(
            ["bridge", "validate-settings", "--settings-path", str(settings_file)]
        )
        assert code != 0
        assert "messages" in out
        assert any("pre-bash.sh" in m for m in out["messages"]), (
            f"Expected message mentioning 'pre-bash.sh': {out['messages']}"
        )

    def test_output_is_valid_json_on_wiring_drift(self, tmp_path):
        settings = _load_bridge_settings()
        poisoned = copy.deepcopy(settings)
        pretooluse = poisoned.get("hooks", {}).get("PreToolUse", [])
        poisoned["hooks"]["PreToolUse"] = [
            block for block in pretooluse
            if not (isinstance(block, dict) and block.get("matcher") == "Bash")
        ]
        settings_file = tmp_path / "claude-settings.json"
        _write_bridge_settings(settings_file, poisoned)

        code, out = _run_cli(
            ["bridge", "validate-settings", "--settings-path", str(settings_file)]
        )
        assert "_raw" not in out, "CLI output must be valid JSON even on wiring drift"


# ---------------------------------------------------------------------------
# 5. Edge cases
# ---------------------------------------------------------------------------


class TestEdgeCases:
    def test_missing_file_exits_nonzero(self, tmp_path):
        nonexistent = tmp_path / "does-not-exist.json"
        code, out = _run_cli(
            ["bridge", "validate-settings", "--settings-path", str(nonexistent)]
        )
        assert code != 0

    def test_invalid_json_exits_nonzero(self, tmp_path):
        bad_json = tmp_path / "bad.json"
        bad_json.write_text("{not: valid json}", encoding="utf-8")
        code, out = _run_cli(
            ["bridge", "validate-settings", "--settings-path", str(bad_json)]
        )
        assert code != 0


# ---------------------------------------------------------------------------
# End-to-end CLI tests for `bridge broker-health` and
# `bridge probe-response-drift` (2026-04-17)
# ---------------------------------------------------------------------------


class TestCliBridgeBrokerHealth:
    """Drive `cc-policy bridge broker-health` via subprocess and verify
    the classified JSON shape + exit code.
    """

    def test_absent_when_no_pidfile(self, tmp_path):
        # Empty braid root → no pidfile → status=absent, exit 0.
        root = tmp_path / "braid"
        (root / "runs").mkdir(parents=True)
        code, out = _run_cli(
            ["bridge", "broker-health", "--braid-root", str(root)]
        )
        assert code == 0, out
        assert out["status"] == "absent", out
        assert out["braidd_pid"] is None

    def test_degraded_dead_pid_stale_socket(self, tmp_path):
        root = tmp_path / "braid"
        (root / "runs").mkdir(parents=True)
        (root / "runs" / "braidd.pid").write_text("2147483646")
        (root / "runs" / "braidd.sock").write_text("")
        code, out = _run_cli(
            ["bridge", "broker-health", "--braid-root", str(root)]
        )
        assert code == 0, out
        assert out["status"] == "degraded_dead_pid_stale_socket", out
        assert out["pid_alive"] is False
        assert out["socket_exists"] is True
        assert out["recovery_hint"] == "braid down && braid up"


class TestCliBridgeProbeResponseDrift:
    """Drive `cc-policy bridge probe-response-drift` via subprocess and
    verify the classified JSON shape + exit code for the two most
    important classes (broker_cache_miss and pending_absent_inflight_ok).
    """

    def _make_scaffold(
        self,
        tmp_path,
        *,
        run_state: str,
        pending_review: dict | None,
        pidfile_content: str = "2147483646",
    ):
        root = tmp_path / "braid"
        (root / "runs").mkdir(parents=True)
        (root / "runs" / "braidd.pid").write_text(pidfile_content)
        (root / "runs" / "braidd.sock").write_text("")
        (root / "runs" / "active-run").write_text("run-abc")
        (root / "runs" / "run-abc").mkdir()
        (root / "runs" / "run-abc" / "status.json").write_text(
            json.dumps({"state": run_state})
        )
        sdir = tmp_path / "state"
        sdir.mkdir()
        (sdir / "braid-root").write_text(str(root))
        if pending_review is not None:
            (sdir / "pending-review.json").write_text(
                json.dumps(pending_review)
            )
        return root, sdir

    def test_broker_cache_miss_stale_socket(self, tmp_path):
        response_path = tmp_path / "response.json"
        response_path.write_text("{}")
        root, sdir = self._make_scaffold(
            tmp_path,
            run_state="waiting_for_codex",
            pending_review={
                "run_id": "run-abc",
                "response_available": True,
                "response_path": str(response_path),
            },
        )
        code, out = _run_cli(
            [
                "bridge",
                "probe-response-drift",
                "--run-id",
                "run-abc",
                "--braid-root",
                str(root),
                "--state-dir",
                str(sdir),
            ]
        )
        assert code == 0, out
        assert out["status"] == "broker_cache_miss_stale_socket", out
        assert out["run_state"] == "waiting_for_codex"
        assert out["broker_health"]["status"] == (
            "degraded_dead_pid_stale_socket"
        )

    def test_pending_absent_inflight_ok(self, tmp_path):
        root, sdir = self._make_scaffold(
            tmp_path, run_state="inflight", pending_review=None
        )
        code, out = _run_cli(
            [
                "bridge",
                "probe-response-drift",
                "--run-id",
                "run-abc",
                "--braid-root",
                str(root),
                "--state-dir",
                str(sdir),
            ]
        )
        assert code == 0, out
        assert out["status"] == "pending_absent_inflight_ok", out
        assert out["pending_review"]["present"] is False

    def test_missing_run_id_arg_exits_nonzero(self, tmp_path):
        # --run-id is required; argparse should fail.
        code, out = _run_cli(["bridge", "probe-response-drift"])
        assert code != 0
