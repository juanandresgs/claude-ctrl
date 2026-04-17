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


# ---------------------------------------------------------------------------
# Phase 4: Reviewer SubagentStop group
# ---------------------------------------------------------------------------


def test_settings_includes_reviewer_subagent_stop_group() -> None:
    """Phase 4: settings.json has a SubagentStop group matching 'reviewer'."""
    settings = json.loads(_SETTINGS.read_text(encoding="utf-8"))
    matchers = [g.get("matcher", "") for g in settings["hooks"]["SubagentStop"]]
    assert "reviewer" in matchers


def test_reviewer_subagent_stop_group_has_post_task() -> None:
    """Phase 4: reviewer SubagentStop group includes post-task.sh for dispatch routing."""
    settings = json.loads(_SETTINGS.read_text(encoding="utf-8"))
    for group in settings["hooks"]["SubagentStop"]:
        if group.get("matcher") == "reviewer":
            cmds = _commands([group])
            assert any("post-task.sh" in c for c in cmds), (
                "reviewer SubagentStop group must include post-task.sh"
            )
            return
    raise AssertionError("reviewer SubagentStop group not found")


def test_reviewer_subagent_stop_group_has_check_reviewer() -> None:
    """Phase 4: reviewer SubagentStop group includes check-reviewer.sh."""
    settings = json.loads(_SETTINGS.read_text(encoding="utf-8"))
    for group in settings["hooks"]["SubagentStop"]:
        if group.get("matcher") == "reviewer":
            cmds = _commands([group])
            assert any("check-reviewer.sh" in c for c in cmds), (
                "reviewer SubagentStop group must include check-reviewer.sh"
            )
            return
    raise AssertionError("reviewer SubagentStop group not found")


def test_reviewer_subagent_stop_group_has_stop_review_gate() -> None:
    """Phase 4: stop-review gate present in reviewer SubagentStop group (same as all others)."""
    settings = json.loads(_SETTINGS.read_text(encoding="utf-8"))
    for group in settings["hooks"]["SubagentStop"]:
        if group.get("matcher") == "reviewer":
            cmds = _commands([group])
            assert _STOP_REVIEW in cmds, (
                "reviewer SubagentStop group must include stop-review gate"
            )
            return
    raise AssertionError("reviewer SubagentStop group not found")


def test_check_reviewer_uses_completion_submit_with_role_reviewer() -> None:
    """Phase 4: check-reviewer.sh submits completion via local runtime with role reviewer."""
    check_reviewer = _ROOT / "hooks" / "check-reviewer.sh"
    content = check_reviewer.read_text(encoding="utf-8")
    assert "_local_cc_policy completion submit" in content
    assert '"reviewer"' in content


def test_check_reviewer_does_not_write_evaluation_state() -> None:
    """Phase 4: check-reviewer.sh must NOT call write_evaluation_status or rt_eval_set."""
    check_reviewer = _ROOT / "hooks" / "check-reviewer.sh"
    content = check_reviewer.read_text(encoding="utf-8")
    assert "write_evaluation_status" not in content
    assert "rt_eval_set" not in content


def test_check_reviewer_has_local_runtime_lifecycle_pattern() -> None:
    """Phase 4: check-reviewer.sh has the local runtime resolution and lifecycle pattern."""
    check_reviewer = _ROOT / "hooks" / "check-reviewer.sh"
    content = check_reviewer.read_text(encoding="utf-8")
    assert "_local_cc_policy" in content
    assert "_LOCAL_RUNTIME_CLI" in content
    assert "lifecycle on-stop" in content
    assert "_local_cc_policy lease current" in content
