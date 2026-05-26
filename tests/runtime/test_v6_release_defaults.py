"""Release-default invariants for claude-ctrl v6.

These tests prove that Claude's broad local permissions are intentionally
backstopped by deterministic hooks/policies, not by ad-hoc manual prompts.
"""

from __future__ import annotations

import json
from pathlib import Path

from runtime import cli as cli_mod
from runtime.core import enforcement_config as ec
from runtime.core.db import connect_memory
from runtime.schemas import ensure_schema

ROOT = Path(__file__).resolve().parent.parent.parent


def _hook_commands(settings: dict, event: str) -> list[str]:
    commands: list[str] = []
    for group in settings.get("hooks", {}).get(event, []):
        for hook in group.get("hooks", []):
            command = hook.get("command")
            if command:
                commands.append(command)
    return commands


def test_auto_permissions_are_backstopped_by_deterministic_hooks():
    settings = json.loads((ROOT / "settings.json").read_text(encoding="utf-8"))
    assert settings["permissions"]["defaultMode"] == "auto"
    assert settings["skipAutoPermissionPrompt"] is True

    pre_tool = json.dumps(settings["hooks"].get("PreToolUse", []))
    assert "pre-write.sh" in pre_tool
    assert "pre-bash.sh" in pre_tool
    assert "pre-agent.sh" in pre_tool
    assert "block-worktree-create.sh" in pre_tool
    assert (ROOT / "hooks" / "block-worktree-create.sh").exists()

    assert any("block-worktree-create.sh" in c for c in _hook_commands(settings, "WorktreeCreate"))
    assert any("prompt-submit.sh" in c for c in _hook_commands(settings, "UserPromptSubmit"))
    assert any("subagent-start.sh" in c for c in _hook_commands(settings, "SubagentStart"))
    assert any("v6-result-submit.sh" in c for c in _hook_commands(settings, "SubagentStop"))


def test_release_enforcement_defaults_are_deterministic():
    conn = connect_memory()
    try:
        ensure_schema(conn)
        assert ec.get(conn, "review_gate_regular_stop") == "false"
        assert ec.get(conn, "review_gate_subagent_stop") == "true"
        assert ec.get(conn, "review_gate_provider") == "codex"
    finally:
        conn.close()


def test_v6_launcher_uses_flag_settings_as_single_hook_authority():
    launcher = (ROOT / "scripts" / "claude-v6.sh").read_text(encoding="utf-8")
    assert '--setting-sources ""' in launcher
    assert "--setting-sources user" not in launcher
    assert "--no-session-persistence" in launcher
    assert '--tools ""' in launcher
    assert "export CLAUDE_POLICY_DB=\"$VERIFY_STATE_DIR/state.db\"" in launcher


def test_doctor_scopes_user_prompt_cancelled_events_to_project(tmp_path):
    project = tmp_path / "project"
    other = tmp_path / "other"
    home = tmp_path / "home"
    transcript_dir = home / ".claude" / "projects" / "project"
    project.mkdir()
    other.mkdir()
    transcript_dir.mkdir(parents=True)
    transcript = transcript_dir / "session.jsonl"
    events = [
        {
            "attachment": {
                "type": "hook_cancelled",
                "hookName": "UserPromptSubmit",
                "durationMs": 5044,
                "command": "$HOME/.claude/hooks/prompt-submit.sh",
            },
            "cwd": str(other),
            "timestamp": "2026-05-25T16:00:00.000Z",
            "sessionId": "ignored",
        },
        {
            "attachment": {
                "type": "hook_cancelled",
                "hookName": "UserPromptSubmit",
                "durationMs": 5040,
                "command": "$HOME/.claude/hooks/prompt-submit.sh",
            },
            "cwd": str(project),
            "timestamp": "2026-05-25T16:01:00.000Z",
            "sessionId": "kept",
        },
    ]
    transcript.write_text("\n".join(json.dumps(event) for event in events), encoding="utf-8")

    cancellations = cli_mod._recent_user_prompt_hook_cancellations(project, home=home)

    assert len(cancellations) == 1
    assert cancellations[0]["session_id"] == "kept"
    assert cancellations[0]["duration_ms"] == 5040
