"""Runtime-owned planner bootstrap authority.

@decision DEC-CLAUDEX-PLANNER-BOOTSTRAP-001
Title: runtime/core/planner_bootstrap.py is the sole local-adoption bootstrap for canonical planner seats
Status: accepted
Rationale: Canonical seats (planner / implementer / reviewer / guardian)
  require a workflow-scoped contract block. Fresh local adoption is exactly the
  moment when that workflow state may not exist yet, which forced operators into
  low-level rituals (`workflow bind`, `goal-set`, `work-item-set`, `marker set`,
  and manual completion/lease surgery) just to get planner started. That shape
  violated the hardFork trust model by making the workaround feel necessary.

  This module closes the gap with one runtime-owned bootstrap path:

    * require a git worktree for local inference
    * create / use the local ``<git-root>/.claude/state.db``
    * bind the workflow to the worktree/branch
    * seed the initial active goal + in-progress work item
    * seed evaluation_state=pending
    * return the canonical planner stage-packet / launch spec

  Non-git contexts are intentionally excluded from this helper. They must use
  explicit managed-context primitives instead of local inference.
"""

from __future__ import annotations

import sqlite3
import subprocess
from pathlib import Path

from runtime.core import decision_work_registry as dwr
from runtime.core import evaluation as evaluation_mod
from runtime.core import workflows as workflows_mod
from runtime.core.db import connect
from runtime.core.policy_utils import normalize_path
from runtime.core.stage_packet import build_stage_packet
from runtime.schemas import ensure_schema

DEFAULT_PLANNER_GOAL_ID = "g-initial-planning"
DEFAULT_PLANNER_WORK_ITEM_ID = "wi-initial-planning"
DEFAULT_PLANNER_TITLE = "Initial planning bootstrap"


def planner_bootstrap_guidance() -> str:
    """Return the canonical local-adoption bootstrap path for planner."""
    return (
        "For a fresh local project, run "
        "`cc-policy workflow bootstrap-planner <workflow_id> "
        "--desired-end-state <text>` from inside the git repo/worktree "
        "(or pass --worktree-path <repo>). That command creates the local "
        "project state DB, binds the workflow, seeds the initial active "
        "goal + in-progress work item, and returns the canonical planner "
        "launch spec."
    )


class PlannerBootstrapError(ValueError):
    """Raised when planner bootstrap cannot be completed."""


def _run_git(path: str | None, *args: str) -> str:
    command = ["git"]
    if path:
        command.extend(["-C", path])
    command.extend(args)
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired) as exc:
        raise PlannerBootstrapError(
            "local planner bootstrap requires a git worktree, but git could "
            f"not resolve it: {exc}. Run `git init` first, or use explicit "
            "managed-context workflow primitives outside local adoption."
        ) from exc
    if result.returncode != 0:
        stderr = result.stderr.strip() or result.stdout.strip() or "git command failed"
        raise PlannerBootstrapError(
            "local planner bootstrap requires a git repo/worktree. "
            f"`git {' '.join(args)}` failed: {stderr}. Run `git init` first, "
            "or use explicit managed-context workflow primitives outside local adoption."
        )
    return result.stdout.strip()


def resolve_local_planner_bootstrap_target(
    worktree_path: str | None = None,
) -> dict:
    """Resolve the git-backed local target for planner bootstrap."""
    candidate = normalize_path(worktree_path) if worktree_path else None
    git_root = normalize_path(_run_git(candidate, "rev-parse", "--show-toplevel"))
    branch = _run_git(git_root, "branch", "--show-current")
    if not branch:
        raise PlannerBootstrapError(
            "local planner bootstrap requires a named branch. Detached HEAD "
            "is not supported for planner adoption. Check out or create a "
            "branch first, then rerun bootstrap-planner."
        )

    head_sha: str | None
    try:
        head_sha = _run_git(git_root, "rev-parse", "HEAD") or None
    except PlannerBootstrapError:
        # Fresh repos may not have a commit yet; planner bootstrap is still
        # valid in that case, and evaluation_state can remain headless.
        head_sha = None

    return {
        "worktree_path": git_root,
        "branch": branch,
        "head_sha": head_sha,
        "db_path": str(Path(git_root) / ".claude" / "state.db"),
    }


def _validate_existing_state(
    conn: sqlite3.Connection,
    *,
    workflow_id: str,
    goal_id: str,
    work_item_id: str,
    worktree_path: str,
) -> dict:
    binding = workflows_mod.get_binding(conn, workflow_id)
    if binding is not None and binding["worktree_path"] != worktree_path:
        raise PlannerBootstrapError(
            f"workflow_id {workflow_id!r} is already bound to "
            f"{binding['worktree_path']!r}, not {worktree_path!r}. "
            "Refusing to silently repoint an existing workflow binding."
        )

    goal = dwr.get_goal(conn, goal_id)
    if goal is not None and goal.workflow_id not in (None, workflow_id):
        raise PlannerBootstrapError(
            f"goal_id {goal_id!r} is already owned by workflow "
            f"{goal.workflow_id!r}, not {workflow_id!r}. Choose a distinct "
            "goal_id or retire the existing goal first."
        )

    work_item = dwr.get_work_item(conn, work_item_id)
    if work_item is not None:
        if work_item.workflow_id not in (None, workflow_id):
            raise PlannerBootstrapError(
                f"work_item_id {work_item_id!r} is already owned by workflow "
                f"{work_item.workflow_id!r}, not {workflow_id!r}. Choose a "
                "distinct work_item_id or retire the existing work item first."
            )
        if work_item.goal_id != goal_id:
            raise PlannerBootstrapError(
                f"work_item_id {work_item_id!r} is already attached to "
                f"goal_id {work_item.goal_id!r}, not {goal_id!r}. Choose a "
                "distinct work_item_id or retire the existing work item first."
            )

    return {
        "binding_exists": binding is not None,
        "goal_exists": goal is not None,
        "work_item_exists": work_item is not None,
    }


def bootstrap_planner(
    *,
    workflow_id: str,
    desired_end_state: str,
    title: str = DEFAULT_PLANNER_TITLE,
    goal_id: str = DEFAULT_PLANNER_GOAL_ID,
    work_item_id: str = DEFAULT_PLANNER_WORK_ITEM_ID,
    worktree_path: str | None = None,
    base_branch: str = "main",
    ticket: str | None = None,
    initiative: str | None = None,
    autonomy_budget: int = 0,
    decision_scope: str = "kernel",
    generated_at: int | None = None,
) -> dict:
    """Bootstrap local workflow state and return the canonical planner launch spec."""
    if not workflow_id or not workflow_id.strip():
        raise PlannerBootstrapError("workflow_id must be a non-empty string")
    if not desired_end_state or not desired_end_state.strip():
        raise PlannerBootstrapError("--desired-end-state is required")
    if not title or not title.strip():
        raise PlannerBootstrapError("--title must be a non-empty string")

    target = resolve_local_planner_bootstrap_target(worktree_path)
    db_path = Path(target["db_path"])
    conn = connect(db_path)
    ensure_schema(conn)
    conn.row_factory = sqlite3.Row
    try:
        existing = _validate_existing_state(
            conn,
            workflow_id=workflow_id,
            goal_id=goal_id,
            work_item_id=work_item_id,
            worktree_path=target["worktree_path"],
        )

        workflows_mod.bind_workflow(
            conn,
            workflow_id=workflow_id,
            worktree_path=target["worktree_path"],
            branch=target["branch"],
            base_branch=base_branch,
            ticket=ticket,
            initiative=initiative,
        )
        dwr.upsert_goal(
            conn,
            dwr.GoalRecord(
                goal_id=goal_id,
                desired_end_state=desired_end_state,
                status="active",
                autonomy_budget=autonomy_budget,
                workflow_id=workflow_id,
            ),
        )
        dwr.upsert_work_item(
            conn,
            dwr.WorkItemRecord(
                work_item_id=work_item_id,
                goal_id=goal_id,
                title=title,
                status="in_progress",
                version=1,
                author="planner",
                scope_json="{}",
                evaluation_json="{}",
                head_sha=target["head_sha"],
                reviewer_round=0,
                workflow_id=workflow_id,
            ),
        )
        evaluation_mod.set_status(
            conn,
            workflow_id,
            "pending",
            head_sha=target["head_sha"],
        )
        packet = build_stage_packet(
            conn,
            workflow_id=workflow_id,
            stage_id="planner",
            goal_id=goal_id,
            work_item_id=work_item_id,
            worktree_path=target["worktree_path"],
            decision_scope=decision_scope,
            generated_at=generated_at,
        )
    finally:
        conn.close()

    packet["bootstrap"] = {
        "db_path": str(db_path),
        "worktree_path": target["worktree_path"],
        "branch": target["branch"],
        "head_sha": target["head_sha"],
        "binding_seeded": not existing["binding_exists"],
        "goal_seeded": not existing["goal_exists"],
        "work_item_seeded": not existing["work_item_exists"],
        "mode": "local_git_bootstrap",
    }
    return packet


__all__ = [
    "DEFAULT_PLANNER_GOAL_ID",
    "DEFAULT_PLANNER_WORK_ITEM_ID",
    "DEFAULT_PLANNER_TITLE",
    "PlannerBootstrapError",
    "bootstrap_planner",
    "planner_bootstrap_guidance",
    "resolve_local_planner_bootstrap_target",
]
