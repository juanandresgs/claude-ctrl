"""v6 git custody policy tests."""

from __future__ import annotations

import sqlite3
import time

from runtime.core.command_intent import build_bash_command_intent
from runtime.core.policies import bash_git_who
from runtime.core.policy_engine import PolicyContext, PolicyRequest
from runtime.schemas import ensure_schema


def _ctx(role: str, lease_role: str, metadata_json: str = "{}") -> PolicyContext:
    now = int(time.time())
    return PolicyContext(
        actor_role=role,
        actor_id="agent",
        workflow_id="wf",
        worktree_path="/repo",
        branch="feature/x",
        project_root="/repo",
        is_meta_repo=False,
        lease={
            "lease_id": "lease",
            "role": lease_role,
            "workflow_id": "wf",
            "worktree_path": "/repo",
            "allowed_ops_json": '["routine_local", "high_risk", "admin_recovery"]',
            "blocked_ops_json": "[]",
            "expires_at": now + 3600,
            "metadata_json": metadata_json,
        },
        scope=None,
        eval_state=None,
        test_state=None,
        binding=None,
        dispatch_phase=None,
    )


def _request(command: str, ctx: PolicyContext) -> PolicyRequest:
    return PolicyRequest(
        event_type="PreToolUse",
        tool_name="Bash",
        tool_input={"command": command},
        context=ctx,
        cwd="/repo",
        command_intent=build_bash_command_intent(command, cwd="/repo"),
    )


def test_v6_implementer_commit_denied_by_default():
    decision = bash_git_who.check(_request("git commit -m x", _ctx("implementer", "implementer")))
    assert decision is not None
    assert decision.action == "deny"
    assert "v6 git custody" in decision.reason


def test_v6_implementer_commit_allowed_only_with_explicit_grant():
    ctx = _ctx(
        "implementer",
        "implementer",
        '{"work_item_grant":{"can_commit_branch":true}}',
    )
    decision = bash_git_who.check(_request("git commit -m x", ctx))
    assert decision is None


def test_v6_implementer_push_denied_even_with_commit_grant():
    ctx = _ctx(
        "implementer",
        "implementer",
        '{"work_item_grant":{"can_commit_branch":true}}',
    )
    decision = bash_git_who.check(_request("git push", ctx))
    assert decision is not None
    assert decision.action == "deny"


def test_guardian_git_still_allowed_by_lease():
    decision = bash_git_who.check(_request("git commit -m x", _ctx("guardian", "guardian")))
    assert decision is None
