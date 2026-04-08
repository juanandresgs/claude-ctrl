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


def test_settings_json_is_the_single_stop_review_wiring_authority() -> None:
    settings = json.loads(_SETTINGS.read_text(encoding="utf-8"))
    plugin_hooks = json.loads(_PLUGIN_HOOKS.read_text(encoding="utf-8"))

    stop_commands = _commands(settings["hooks"]["Stop"])
    assert _STOP_REVIEW in stop_commands

    for group in settings["hooks"]["SubagentStop"]:
        assert _STOP_REVIEW in _commands([group])

    assert "Stop" not in plugin_hooks["hooks"]
