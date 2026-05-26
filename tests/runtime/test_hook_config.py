"""Hook wiring invariants for the repo-owned control plane."""

from __future__ import annotations

import json
from pathlib import Path


_ROOT = Path(__file__).resolve().parent.parent.parent
_SETTINGS = _ROOT / "settings.json"
_PLUGIN_HOOKS = (
    _ROOT
    / "plugins"
    / "marketplaces"
    / "openai-codex"
    / "plugins"
    / "codex"
    / "hooks"
    / "hooks.json"
)
_STOP_REVIEW = (
    "node $HOME/.claude/plugins/marketplaces/openai-codex/plugins/codex/scripts/"
    "stop-review-gate-hook.mjs"
)


def _commands(hook_groups: list[dict]) -> list[str]:
    commands: list[str] = []
    for group in hook_groups:
        for hook in group.get("hooks", []):
            command = hook.get("command")
            if command:
                commands.append(command)
    return commands


def test_settings_json_has_no_hidden_regular_stop_review_gate() -> None:
    settings = json.loads(_SETTINGS.read_text(encoding="utf-8"))
    plugin_hooks = json.loads(_PLUGIN_HOOKS.read_text(encoding="utf-8"))

    stop_commands = _commands(settings["hooks"].get("Stop", []))
    assert _STOP_REVIEW not in stop_commands

    subagent_stop_commands = []
    for group in settings["hooks"]["SubagentStop"]:
        subagent_stop_commands.extend(_commands([group]))
    assert _STOP_REVIEW not in subagent_stop_commands
    assert any("v6-result-submit.sh" in command for command in subagent_stop_commands)

    assert "Stop" not in plugin_hooks["hooks"]
