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
import os
import shlex
import sqlite3
import subprocess
from typing import Any

from runtime.core import agent_prompt as agent_prompt_mod
from runtime.core import evaluation as evaluation_mod
from runtime.core import test_state as test_state_mod
from runtime.core import workflows as workflows_mod
from runtime.core.policy_utils import normalize_path
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


def dispatch_bootstrap_guidance(stage_id: str | None = None) -> str:
    """Return the canonical repair path for canonical seat launches.

    ``workflow stage-packet`` is the high-level runtime authority. It either
    returns the full launch spec or explains the exact bootstrap prerequisite
    that is missing.
    """
    stage_fragment = stage_id.strip() if stage_id and stage_id.strip() else "<stage>"
    if stage_fragment in {"planner", "Plan"}:
        from runtime.core.workflow_bootstrap import workflow_bootstrap_guidance

        return (
            workflow_bootstrap_guidance()
            + " Once the workflow already has an active goal + in-progress "
            "work item, `cc-policy workflow stage-packet [<workflow_id>] "
            "--stage-id planner` returns the canonical planner launch spec."
        )
    if stage_fragment == "guardian":
        return (
            "Use `cc-policy workflow stage-packet [<workflow_id>] --stage-id "
            "guardian:land` for landing after reviewer ready_for_guardian, or "
            "`cc-policy workflow stage-packet [<workflow_id>] --stage-id "
            "guardian:provision` for worktree provisioning after planner "
            "next_work_item. Bare `--stage-id guardian` is accepted only when "
            "runtime can infer the compound Guardian mode from the latest valid "
            "completion for the workflow. If <workflow_id> is omitted, runtime "
            "resolves it from the active worktree/lease; that requires "
            "`--worktree-path`, `CLAUDE_PROJECT_DIR`, or a git worktree with a "
            "bound workflow. Then launch the Agent call with "
            "`agent_tool_spec.prompt_prefix` and "
            "`agent_tool_spec.subagent_type` verbatim."
        )
    return (
        "Use `cc-policy workflow stage-packet [<workflow_id>] --stage-id "
        f"{stage_fragment}` to resolve the canonical launch spec. If "
        "<workflow_id> is omitted, runtime resolves it from the active "
        "worktree/lease; that requires `--worktree-path`, `CLAUDE_PROJECT_DIR`, "
        "or a git worktree with a bound workflow. Then launch the Agent call "
        "with `agent_tool_spec.prompt_prefix` and "
        "`agent_tool_spec.subagent_type` verbatim."
    )


class StagePacketBootstrapError(ValueError):
    """Raised when the runtime cannot resolve canonical stage bootstrap state."""


def _resolve_bootstrap_worktree_path(worktree_path: str | None) -> tuple[str | None, str]:
    """Resolve a worktree path for stage-packet bootstrap.

    Returns ``(path, source)`` where source is one of:
      - ``explicit_worktree_path``
      - ``CLAUDE_PROJECT_DIR``
      - ``git_toplevel``
      - ``unresolved``
    """
    if worktree_path and worktree_path.strip():
        return normalize_path(worktree_path), "explicit_worktree_path"

    env_project_dir = os.environ.get("CLAUDE_PROJECT_DIR", "").strip()
    if env_project_dir:
        return normalize_path(env_project_dir), "CLAUDE_PROJECT_DIR"

    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired):
        result = None

    if result is not None and result.returncode == 0:
        root = result.stdout.strip()
        if root:
            return normalize_path(root), "git_toplevel"

    return None, "unresolved"


def resolve_stage_packet_bootstrap(
    conn: sqlite3.Connection,
    *,
    workflow_id: str | None,
    worktree_path: str | None,
    stage_id: str,
) -> tuple[str, dict]:
    """Resolve the canonical workflow binding for a stage-packet request.

    Allowed non-git scenario:
      - caller provides an explicit, already-bound ``workflow_id``.

    Git/bootstrap requirement:
      - when ``workflow_id`` is omitted, runtime must resolve the current
        worktree from ``--worktree-path``, ``CLAUDE_PROJECT_DIR``, or
        ``git rev-parse --show-toplevel``.
    """
    guidance = dispatch_bootstrap_guidance(stage_id)

    if workflow_id and workflow_id.strip():
        binding = workflows_mod.get_binding(conn, workflow_id)
        if binding is None:
            if stage_id in {"planner", "Plan"}:
                raise StagePacketBootstrapError(
                    f"workflow_id {workflow_id!r} is not bound. "
                    + guidance
                )
            raise StagePacketBootstrapError(
                f"workflow_id {workflow_id!r} is not bound. Run "
                f"`cc-policy workflow bind {workflow_id} <worktree_path> <branch>` "
                f"first. {guidance}"
            )
        if worktree_path and worktree_path.strip():
            requested_worktree = normalize_path(worktree_path)
            if requested_worktree != binding["worktree_path"]:
                raise StagePacketBootstrapError(
                    f"workflow_id {workflow_id!r} is bound to worktree "
                    f"{binding['worktree_path']!r}, not {requested_worktree!r}. "
                    "Do not combine a bound workflow_id with a different "
                    "worktree path. Either use the bound worktree, or fix the "
                    f"workflow binding first. {guidance}"
                )
        return workflow_id, binding

    resolved_worktree, source = _resolve_bootstrap_worktree_path(worktree_path)
    if not resolved_worktree:
        raise StagePacketBootstrapError(
            "canonical dispatch seats require a workflow bootstrap context: "
            "no workflow_id supplied and no worktree path could be resolved "
            "(--worktree-path omitted, CLAUDE_PROJECT_DIR unset, and no git "
            "toplevel found). Run from inside a git repo/worktree, set "
            "CLAUDE_PROJECT_DIR, pass --worktree-path, or provide an explicit "
            "bound workflow_id. Fresh projects must `git init` before runtime "
            "can infer local worktree identity. "
            + guidance
        )

    binding = workflows_mod.find_binding_for_worktree(conn, resolved_worktree)
    if binding is None:
        source_note = (
            "current git worktree"
            if source == "git_toplevel"
            else ("CLAUDE_PROJECT_DIR" if source == "CLAUDE_PROJECT_DIR" else "--worktree-path")
        )
        if stage_id in {"planner", "Plan"}:
            raise StagePacketBootstrapError(
                f"no workflow binding found for {source_note} {resolved_worktree!r}. "
                + guidance
            )
        raise StagePacketBootstrapError(
            f"no workflow binding found for {source_note} {resolved_worktree!r}. "
            f"Run `cc-policy workflow bind <workflow_id> {resolved_worktree} <branch>` "
            "first. If this project is not a git repo/worktree yet, `git init` "
            "and create the branch/worktree identity before binding. "
            + guidance
        )

    return binding["workflow_id"], binding


def build_stage_packet(
    conn: sqlite3.Connection,
    *,
    workflow_id: str | None = None,
    stage_id: str,
    goal_id: str | None = None,
    work_item_id: str | None = None,
    worktree_path: str | None = None,
    decision_scope: str = "kernel",
    generated_at: int | None = None,
) -> dict:
    """Build the canonical execution packet for a dispatched stage."""
    resolved_workflow_id, binding = resolve_stage_packet_bootstrap(
        conn,
        workflow_id=workflow_id,
        worktree_path=worktree_path,
        stage_id=stage_id,
    )

    dispatch_spec = agent_prompt_mod.build_agent_dispatch_prompt(
        conn,
        workflow_id=resolved_workflow_id,
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
    "dispatch_bootstrap_guidance",
    "resolve_stage_packet_bootstrap",
    "StagePacketBootstrapError",
]
