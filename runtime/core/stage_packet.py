"""Runtime-owned stage execution packet.

@decision DEC-CLAUDEX-STAGE-PACKET-001
Title: runtime/core/stage_packet.py is the single execution-packet authority for dispatched stages
Status: accepted
Rationale: dispatch used to require the orchestrator to stitch together several
  independent read surfaces by hand:
    * the Agent contract block / required_subagent_type
    * workflow binding and scope manifest
    * goal/work-item contracts
    * runtime snapshot, evaluation state, and test-state readbacks
    * canonical command shapes for follow-up inspection

  That shape forced repeated CLI/help probing and re-derived context on every
  slice. This module collapses those read-only authorities into one packet
  without introducing new state. The packet delegates:
    * contract resolution to ``agent_prompt.build_agent_dispatch_prompt``
    * typed contract capture to ``workflow_contract_capture.capture_workflow_contracts``
    * runtime state capture to ``prompt_pack_state.capture_runtime_state_snapshot``
    * workflow binding / scope to ``workflows``
    * readiness/test state to their existing runtime tables
"""

from __future__ import annotations

import dataclasses
import shlex
import sqlite3
from typing import Any

from runtime.core import agent_prompt as agent_prompt_mod
from runtime.core import evaluation as evaluation_mod
from runtime.core import test_state as test_state_mod
from runtime.core import workflows as workflows_mod
from runtime.core.prompt_pack_state import capture_runtime_state_snapshot
from runtime.core.workflow_contract_capture import capture_workflow_contracts


def _jsonable(value: Any) -> Any:
    if dataclasses.is_dataclass(value):
        return _jsonable(dataclasses.asdict(value))
    if isinstance(value, dict):
        return {key: _jsonable(item) for key, item in value.items()}
    if isinstance(value, tuple):
        return [_jsonable(item) for item in value]
    if isinstance(value, list):
        return [_jsonable(item) for item in value]
    return value


def _shell_join(*parts: str | None) -> str:
    return " ".join(shlex.quote(part) for part in parts if part is not None)


def build_stage_packet(
    conn: sqlite3.Connection,
    *,
    workflow_id: str,
    stage_id: str,
    goal_id: str | None = None,
    work_item_id: str | None = None,
    decision_scope: str = "kernel",
    generated_at: int | None = None,
) -> dict:
    """Build the canonical execution packet for a dispatched stage."""
    dispatch_spec = agent_prompt_mod.build_agent_dispatch_prompt(
        conn,
        workflow_id=workflow_id,
        stage_id=stage_id,
        goal_id=goal_id,
        work_item_id=work_item_id,
        decision_scope=decision_scope,
        generated_at=generated_at,
    )

    contract = dispatch_spec["contract"]
    resolved_workflow_id = contract["workflow_id"]
    resolved_goal_id = contract["goal_id"]
    resolved_work_item_id = contract["work_item_id"]
    resolved_stage_id = contract["stage_id"]

    goal_contract, work_item_contract = capture_workflow_contracts(
        conn,
        goal_id=resolved_goal_id,
        work_item_id=resolved_work_item_id,
    )
    binding = workflows_mod.get_binding(conn, resolved_workflow_id)
    scope = workflows_mod.get_scope(conn, resolved_workflow_id)
    evaluation_state = evaluation_mod.get(conn, resolved_workflow_id)

    runtime_snapshot = None
    test_state = None
    if binding is not None:
        runtime_snapshot = capture_runtime_state_snapshot(
            conn,
            workflow_id=resolved_workflow_id,
            work_item_id=resolved_work_item_id,
        )
        test_state = test_state_mod.get_status(conn, binding["worktree_path"])

    work_item_scope = _jsonable(work_item_contract.scope)
    workflow_scope = _jsonable(scope) if scope is not None else None
    scope_matches = (
        workflow_scope is not None
        and work_item_scope["allowed_paths"] == workflow_scope["allowed_paths"]
        and work_item_scope["required_paths"] == workflow_scope["required_paths"]
        and work_item_scope["forbidden_paths"] == workflow_scope["forbidden_paths"]
        and work_item_scope["state_domains"] == workflow_scope["authority_domains"]
    )

    commands = {
        "workflow_get": _shell_join("cc-policy", "workflow", "get", resolved_workflow_id),
        "goal_get": _shell_join("cc-policy", "workflow", "goal-get", resolved_goal_id),
        "work_item_get": _shell_join(
            "cc-policy", "workflow", "work-item-get", resolved_work_item_id
        ),
        "scope_get": _shell_join("cc-policy", "workflow", "scope-get", resolved_workflow_id),
        "evaluation_get": _shell_join(
            "cc-policy", "evaluation", "get", resolved_workflow_id
        ),
        "agent_prompt": _shell_join(
            "cc-policy",
            "dispatch",
            "agent-prompt",
            "--workflow-id",
            resolved_workflow_id,
            "--stage-id",
            resolved_stage_id,
            "--goal-id",
            resolved_goal_id,
            "--work-item-id",
            resolved_work_item_id,
        ),
        "stage_packet": _shell_join(
            "cc-policy",
            "workflow",
            "stage-packet",
            resolved_workflow_id,
            "--stage-id",
            resolved_stage_id,
            "--goal-id",
            resolved_goal_id,
            "--work-item-id",
            resolved_work_item_id,
        ),
    }
    if binding is not None:
        commands["test_state_get"] = _shell_join(
            "cc-policy",
            "test-state",
            "get",
            "--project-root",
            binding["worktree_path"],
        )

    return {
        "workflow_id": resolved_workflow_id,
        "stage_id": resolved_stage_id,
        "goal_id": resolved_goal_id,
        "work_item_id": resolved_work_item_id,
        "agent_tool_spec": {
            "subagent_type": dispatch_spec["required_subagent_type"],
            "prompt_prefix": dispatch_spec["prompt_prefix"],
            "contract_block_line": dispatch_spec["contract_block_line"],
        },
        "dispatch_contract": dispatch_spec["contract"],
        "workflow_binding": binding,
        "workflow_scope": workflow_scope,
        "goal_contract": _jsonable(goal_contract),
        "work_item_contract": _jsonable(work_item_contract),
        "runtime_state_snapshot": _jsonable(runtime_snapshot) if runtime_snapshot else None,
        "evaluation_state": evaluation_state,
        "test_state": test_state,
        "scope_parity": {
            "workflow_scope_found": workflow_scope is not None,
            "matches_work_item_scope": scope_matches,
        },
        "commands": commands,
    }


__all__ = [
    "build_stage_packet",
]
