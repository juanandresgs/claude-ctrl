"""Integration tests for block-worktree-create hook adapter."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[2]
HOOK = ROOT / "hooks" / "block-worktree-create.sh"


def test_block_worktree_create_adapter_denies_and_preserves_event_name(tmp_path) -> None:
    env = {
        **os.environ,
        "CLAUDE_RUNTIME_ROOT": str(ROOT / "runtime"),
        "CLAUDE_POLICY_DB": str(tmp_path / "state.db"),
        "PYTHONPATH": str(ROOT),
    }
    result = subprocess.run(
        [str(HOOK)],
        input=json.dumps({"hook_event_name": "WorktreeCreate"}),
        text=True,
        capture_output=True,
        env=env,
        timeout=10,
    )
    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    assert payload["decision"] == "block"
    assert "Guardian worktree authority" in payload["reason"]
    assert "hookSpecificOutput" not in payload


def test_enter_worktree_adapter_denies_pretool_event(tmp_path) -> None:
    env = {
        **os.environ,
        "CLAUDE_RUNTIME_ROOT": str(ROOT / "runtime"),
        "CLAUDE_POLICY_DB": str(tmp_path / "state.db"),
        "PYTHONPATH": str(ROOT),
    }
    result = subprocess.run(
        [str(HOOK)],
        input=json.dumps({"hook_event_name": "PreToolUse", "tool_name": "EnterWorktree"}),
        text=True,
        capture_output=True,
        env=env,
        timeout=10,
    )
    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    assert payload["action"] == "deny"
    assert payload["policy_name"] == "worktree_harness_guard"
    assert payload["hookSpecificOutput"]["hookEventName"] == "PreToolUse"
    assert payload["hookSpecificOutput"]["permissionDecision"] == "deny"
