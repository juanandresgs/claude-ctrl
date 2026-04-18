"""Regression pins for Claude worker model authority.

The bridge worker must launch under the 1M-context Opus model, but the
authority for that choice belongs in the bridge settings profile rather
than the launcher shell wrapper. The launcher's job is only to point
Claude Code at ``ClauDEX/bridge/claude-settings.json`` and preserve the
other launch flags.

@decision DEC-CLAUDEX-LAUNCH-MODEL-001
@title Bridge settings own the Claude worker model
@status accepted
@rationale The worker model is a control-plane fact, so it must have
  one checked-in owner. The bridge settings profile is the correct
  owner because it already defines the worker's permissions and hooks.
  Keeping a second model default in the launcher recreates parallel
  authority and allows the wrong context window to slip into live lanes.
"""

from __future__ import annotations

import os
import json
from pathlib import Path

import pytest


_REPO_ROOT = Path(__file__).resolve().parents[2]
_LAUNCH_SCRIPT = _REPO_ROOT / "scripts" / "claudex-claude-launch.sh"
_SETTINGS_FILE = _REPO_ROOT / "ClauDEX" / "bridge" / "claude-settings.json"


@pytest.fixture(scope="module")
def launch_src() -> str:
    assert _LAUNCH_SCRIPT.is_file(), (
        f"launcher script missing at expected path: {_LAUNCH_SCRIPT}"
    )
    return _LAUNCH_SCRIPT.read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def bridge_settings() -> dict:
    assert _SETTINGS_FILE.is_file(), (
        f"bridge settings file missing at expected path: {_SETTINGS_FILE}"
    )
    return json.loads(_SETTINGS_FILE.read_text(encoding="utf-8"))


def test_bridge_settings_pin_1m_opus_model(bridge_settings):
    assert bridge_settings.get("model") == "opus[1m]", (
        "ClauDEX/bridge/claude-settings.json must be the sole checked-in "
        "authority for the worker model and must pin 'opus[1m]'."
    )


def test_bridge_settings_pin_worker_statusline_command(bridge_settings):
    status_line = bridge_settings.get("statusLine")
    assert isinstance(status_line, dict), (
        "ClauDEX/bridge/claude-settings.json must define `statusLine` for the "
        "actual worker launch path; otherwise a fresh bridge worker can never "
        "render the runtime-backed HUD."
    )
    assert status_line.get("type") == "command", (
        "ClauDEX/bridge/claude-settings.json must set `statusLine.type` to "
        "`command` for the worker launch path."
    )
    assert status_line.get("command") == "$HOME/.claude/scripts/statusline.sh", (
        "ClauDEX/bridge/claude-settings.json must point `statusLine.command` "
        "at the canonical runtime-backed HUD renderer."
    )


def test_launcher_no_longer_carries_model_authority(launch_src):
    assert "CLAUDEX_CLAUDE_MODEL" not in launch_src, (
        "claudex-claude-launch.sh must not keep a launcher-side model "
        "override surface once the bridge settings file owns the model."
    )
    assert "--model" not in launch_src, (
        "claudex-claude-launch.sh must not pass --model once "
        "ClauDEX/bridge/claude-settings.json owns model authority."
    )


def test_launcher_still_points_at_bridge_settings(launch_src):
    assert '--settings "$SETTINGS_FILE"' in launch_src, (
        "claudex-claude-launch.sh must still point Claude Code at the "
        "bridge settings profile."
    )


def test_executable_bit_preserved():
    """The launcher is invoked as an executable by overnight-start /
    bridge-up; the executable bit must not be lost by a routine edit."""
    mode = os.stat(_LAUNCH_SCRIPT).st_mode
    assert mode & 0o111, (
        f"claudex-claude-launch.sh must remain executable "
        f"(current mode: {oct(mode)})"
    )
