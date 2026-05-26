"""Tests for harness-native worktree guard policy."""

from __future__ import annotations

from runtime.core.policy_engine import PolicyContext, PolicyRequest, default_registry
from runtime.core.policies.worktree_harness_guard import check


def _ctx() -> PolicyContext:
    return PolicyContext(
        actor_role="",
        actor_id="",
        workflow_id="",
        worktree_path="/repo",
        branch="main",
        project_root="/repo",
        is_meta_repo=False,
        lease=None,
        scope=None,
        eval_state=None,
        test_state=None,
        binding=None,
        dispatch_phase=None,
    )


def _request(event: str, tool: str, tool_input: dict | None = None) -> PolicyRequest:
    return PolicyRequest(
        event_type=event,
        tool_name=tool,
        tool_input=tool_input or {},
        context=_ctx(),
        cwd="/repo",
    )


def test_denies_worktree_create_event() -> None:
    decision = check(_request("WorktreeCreate", ""))
    assert decision is not None
    assert decision.action == "deny"
    assert decision.policy_name == "worktree_harness_guard"


def test_denies_enter_worktree_tool() -> None:
    decision = check(_request("PreToolUse", "EnterWorktree"))
    assert decision is not None
    assert decision.action == "deny"


def test_denies_agent_worktree_isolation() -> None:
    decision = check(_request("PreToolUse", "Agent", {"isolation": "worktree"}))
    assert decision is not None
    assert decision.action == "deny"
    assert "guardian(provision) -> implementer" in decision.reason
    assert "ordinary Agent with no isolation flag" in decision.reason


def test_allows_normal_agent() -> None:
    assert check(_request("PreToolUse", "Agent", {"subagent_type": "Explore"})) is None


def test_default_registry_contains_worktree_harness_guard() -> None:
    policies = default_registry().list_policies()
    names = [policy.name for policy in policies]
    assert "worktree_harness_guard" in names
