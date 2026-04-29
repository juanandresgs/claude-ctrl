"""Runtime-owned local workflow bootstrap authority.

@decision DEC-CLAUDEX-WORKFLOW-BOOTSTRAP-001
Title: runtime/core/workflow_bootstrap.py is the sole fresh-project bootstrap authority
Status: accepted
Rationale: Canonical seats (planner / implementer / reviewer / guardian) require
  a workflow-scoped contract block. Fresh local adoption is the one moment when
  that workflow state may not exist yet, so bootstrap must be a first-class
  runtime primitive rather than an orchestrator workaround or a forged seat
  launch.

  This module owns that bootstrap path:

    * require a git worktree for local inference
    * resolve the target state DB through the canonical resolver family
    * bind the workflow to the local repo/worktree + branch
    * seed or normalize the initial active goal + in-progress planner work item
    * seed evaluation_state=pending
    * return the canonical planner stage-packet / launch spec

  The initial planner work item is intentionally seeded headless
  (``head_sha=None``). Planning bootstrap is not a landing candidate; attaching
  the repo's current HEAD to the initial planning item incorrectly routes the
  item through landing-oriented commit-shape checks.

  Non-git contexts are intentionally excluded from this helper. They must use
  explicit managed-context primitives instead of local inference.
"""

from __future__ import annotations

import shlex
import sqlite3
import subprocess
from pathlib import Path

from runtime.core import bootstrap_requests as bootstrap_requests_mod
from runtime.core import decision_work_registry as dwr
from runtime.core import evaluation as evaluation_mod
from runtime.core import workflows as workflows_mod
from runtime.core.config import resolve_db_path
from runtime.core.db import connect
from runtime.core.policy_utils import normalize_path
from runtime.core.stage_packet import build_stage_packet
from runtime.schemas import ensure_schema

DEFAULT_INITIAL_GOAL_ID = "g-initial-planning"
DEFAULT_INITIAL_WORK_ITEM_ID = "wi-initial-planning"
DEFAULT_INITIAL_TITLE = "Initial planning bootstrap"
DEFAULT_BOOTSTRAP_REQUEST_TTL_SECONDS = bootstrap_requests_mod.DEFAULT_TTL_SECONDS


def workflow_bootstrap_guidance() -> str:
    """Return the canonical fresh-project bootstrap path."""
    return (
        "For a fresh local project, first run "
        "`cc-policy workflow bootstrap-request <workflow_id> "
        "--desired-end-state <text>` from inside the git repo/worktree "
        "(or pass --worktree-path <repo>) to mint a one-shot bootstrap token. "
        "Then run `cc-policy workflow bootstrap-local <workflow_id> "
        "--bootstrap-token <token>` to create or reuse the canonical local "
        "state DB, bind the workflow, seed the initial active goal + "
        "in-progress planner work item, and return the canonical planner "
        "launch spec."
    )


class WorkflowBootstrapError(ValueError):
    """Raised when local workflow bootstrap cannot be completed."""


def _quote_command(parts: list[str]) -> str:
    return " ".join(shlex.quote(part) for part in parts)


def _effective_value(
    *,
    field: str,
    cli_value,
    request_payload: dict,
    fallback,
):
    if cli_value is not None:
        requested = request_payload.get(field, None)
        if requested is not None and cli_value != requested:
            raise WorkflowBootstrapError(
                f"--{field.replace('_', '-')}={cli_value!r} conflicts with "
                f"bootstrap request payload value {requested!r}"
            )
        return cli_value
    if field in request_payload:
        return request_payload[field]
    return fallback


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
        raise WorkflowBootstrapError(
            "local workflow bootstrap requires a git worktree, but git could "
            f"not resolve it: {exc}. Run `git init` first, or use explicit "
            "managed-context workflow primitives outside local adoption."
        ) from exc
    if result.returncode != 0:
        stderr = result.stderr.strip() or result.stdout.strip() or "git command failed"
        raise WorkflowBootstrapError(
            "local workflow bootstrap requires a git repo/worktree. "
            f"`git {' '.join(args)}` failed: {stderr}. Run `git init` first, "
            "or use explicit managed-context workflow primitives outside local adoption."
        )
    return result.stdout.strip()


def resolve_local_workflow_bootstrap_target(
    worktree_path: str | None = None,
) -> dict:
    """Resolve the git-backed local target for workflow bootstrap."""
    candidate = normalize_path(worktree_path) if worktree_path else None
    git_root = normalize_path(_run_git(candidate, "rev-parse", "--show-toplevel"))
    branch = _run_git(git_root, "branch", "--show-current")
    if not branch:
        raise WorkflowBootstrapError(
            "local workflow bootstrap requires a named branch. Detached HEAD "
            "is not supported for local adoption. Check out or create a "
            "branch first, then rerun bootstrap-local."
        )

    current_head_sha: str | None
    try:
        current_head_sha = _run_git(git_root, "rev-parse", "HEAD") or None
    except WorkflowBootstrapError:
        current_head_sha = None

    return {
        "worktree_path": git_root,
        "branch": branch,
        "current_head_sha": current_head_sha,
        "db_path": str(resolve_db_path(project_root=git_root)),
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
        raise WorkflowBootstrapError(
            f"workflow_id {workflow_id!r} is already bound to "
            f"{binding['worktree_path']!r}, not {worktree_path!r}. "
            "Refusing to silently repoint an existing workflow binding."
        )

    goal = dwr.get_goal(conn, goal_id)
    if goal is not None and goal.workflow_id not in (None, workflow_id):
        raise WorkflowBootstrapError(
            f"goal_id {goal_id!r} is already owned by workflow "
            f"{goal.workflow_id!r}, not {workflow_id!r}. Choose a distinct "
            "goal_id or retire the existing goal first."
        )

    work_item = dwr.get_work_item(conn, work_item_id)
    if work_item is not None:
        if work_item.workflow_id not in (None, workflow_id):
            raise WorkflowBootstrapError(
                f"work_item_id {work_item_id!r} is already owned by workflow "
                f"{work_item.workflow_id!r}, not {workflow_id!r}. Choose a "
                "distinct work_item_id or retire the existing work item first."
            )
        if work_item.goal_id != goal_id:
            raise WorkflowBootstrapError(
                f"work_item_id {work_item_id!r} is already attached to "
                f"goal_id {work_item.goal_id!r}, not {goal_id!r}. Choose a "
                "distinct work_item_id or retire the existing work item first."
            )
        if work_item.status != "in_progress":
            raise WorkflowBootstrapError(
                f"work_item_id {work_item_id!r} already exists for workflow "
                f"{workflow_id!r} with status {work_item.status!r}. "
                "bootstrap-local only normalizes the live initial planning item; "
                "it refuses to reopen a terminal or diverted work item."
            )

    return {
        "binding_exists": binding is not None,
        "goal_exists": goal is not None,
        "work_item": work_item,
    }


def _normalized_initial_work_item(
    *,
    workflow_id: str,
    goal_id: str,
    work_item_id: str,
    title: str,
    existing: dwr.WorkItemRecord | None,
) -> dwr.WorkItemRecord:
    """Return the canonical initial planner work-item record.

    Existing same-workflow rows are preserved where possible, but bootstrap
    always strips ``head_sha`` and keeps the item in ``in_progress`` status so
    the initial planner item remains a planning authority, not a landing
    candidate.
    """
    if existing is None:
        return dwr.WorkItemRecord(
            work_item_id=work_item_id,
            goal_id=goal_id,
            title=title,
            status="in_progress",
            version=1,
            author="planner",
            scope_json="{}",
            evaluation_json="{}",
            head_sha=None,
            reviewer_round=0,
            workflow_id=workflow_id,
        )

    return dwr.WorkItemRecord(
        work_item_id=existing.work_item_id,
        goal_id=existing.goal_id,
        title=existing.title or title,
        status="in_progress",
        version=existing.version,
        author=existing.author or "planner",
        scope_json=existing.scope_json or "{}",
        evaluation_json=existing.evaluation_json or "{}",
        head_sha=None,
        reviewer_round=existing.reviewer_round,
        workflow_id=workflow_id,
    )


def bootstrap_local_workflow(
    *,
    workflow_id: str,
    bootstrap_token: str | None,
    desired_end_state: str | None = None,
    title: str | None = None,
    goal_id: str | None = None,
    work_item_id: str | None = None,
    worktree_path: str | None = None,
    base_branch: str | None = None,
    ticket: str | None = None,
    initiative: str | None = None,
    autonomy_budget: int | None = None,
    decision_scope: str | None = None,
    generated_at: int | None = None,
) -> dict:
    """Bootstrap local workflow state and return the canonical planner launch spec."""
    if not workflow_id or not workflow_id.strip():
        raise WorkflowBootstrapError("workflow_id must be a non-empty string")
    if not bootstrap_token or not bootstrap_token.strip():
        raise WorkflowBootstrapError(
            "bootstrap-local requires a runtime-issued bootstrap token. "
            + workflow_bootstrap_guidance()
        )

    target = resolve_local_workflow_bootstrap_target(worktree_path)
    db_path = Path(target["db_path"])
    conn = connect(db_path)
    ensure_schema(conn)
    conn.row_factory = sqlite3.Row
    try:
        bootstrap_request = bootstrap_requests_mod.resolve_pending(
            conn,
            token=bootstrap_token.strip(),
            workflow_id=workflow_id,
            worktree_path=target["worktree_path"],
            db_path=str(db_path),
        )
        request_payload = bootstrap_request.get("payload", {})
        desired_end_state = _effective_value(
            field="desired_end_state",
            cli_value=desired_end_state,
            request_payload=request_payload,
            fallback=None,
        )
        title = _effective_value(
            field="title",
            cli_value=title,
            request_payload=request_payload,
            fallback=DEFAULT_INITIAL_TITLE,
        )
        goal_id = _effective_value(
            field="goal_id",
            cli_value=goal_id,
            request_payload=request_payload,
            fallback=DEFAULT_INITIAL_GOAL_ID,
        )
        work_item_id = _effective_value(
            field="work_item_id",
            cli_value=work_item_id,
            request_payload=request_payload,
            fallback=DEFAULT_INITIAL_WORK_ITEM_ID,
        )
        base_branch = _effective_value(
            field="base_branch",
            cli_value=base_branch,
            request_payload=request_payload,
            fallback="main",
        )
        ticket = _effective_value(
            field="ticket",
            cli_value=ticket,
            request_payload=request_payload,
            fallback=None,
        )
        initiative = _effective_value(
            field="initiative",
            cli_value=initiative,
            request_payload=request_payload,
            fallback=None,
        )
        autonomy_budget = _effective_value(
            field="autonomy_budget",
            cli_value=autonomy_budget,
            request_payload=request_payload,
            fallback=0,
        )
        decision_scope = _effective_value(
            field="decision_scope",
            cli_value=decision_scope,
            request_payload=request_payload,
            fallback="kernel",
        )
        generated_at = _effective_value(
            field="generated_at",
            cli_value=generated_at,
            request_payload=request_payload,
            fallback=None,
        )

        if not desired_end_state or not str(desired_end_state).strip():
            raise WorkflowBootstrapError("--desired-end-state is required")
        if not title or not str(title).strip():
            raise WorkflowBootstrapError("--title must be a non-empty string")

        existing = _validate_existing_state(
            conn,
            workflow_id=workflow_id,
            goal_id=goal_id,
            work_item_id=work_item_id,
            worktree_path=target["worktree_path"],
        )

        # @decision DEC-ADMIT-001
        # Title: consume() fires before binding/goal/work-item writes (atomicity flip)
        # Status: accepted
        # Rationale: Moving consume() here ensures the one-shot token is atomically
        #   claimed BEFORE any persistent state changes. The winner of a concurrent
        #   bootstrap race claims the token via an UPDATE … WHERE consumed = 0 check;
        #   the loser sees rowcount=0 and raises BootstrapRequestError, bailing out
        #   before any workflow_bindings / goal / work_item rows are written.
        #   Previously consume() ran after all writes, so a race could leave orphaned
        #   partial state. No outer transaction wraps the subsequent writes; the token
        #   itself is the admission gate (#68).
        bootstrap_request = bootstrap_requests_mod.consume(
            conn,
            token=bootstrap_token.strip(),
            workflow_id=workflow_id,
            worktree_path=target["worktree_path"],
            db_path=str(db_path),
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
            _normalized_initial_work_item(
                workflow_id=workflow_id,
                goal_id=goal_id,
                work_item_id=work_item_id,
                title=title,
                existing=existing["work_item"],
            ),
        )
        evaluation_mod.set_status(
            conn,
            workflow_id,
            "pending",
            head_sha=None,
            clear_head_sha=True,
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
        "current_head_sha": target["current_head_sha"],
        "initial_work_item_head_sha": None,
        "binding_seeded": not existing["binding_exists"],
        "goal_seeded": not existing["goal_exists"],
        "work_item_seeded": existing["work_item"] is None,
        "mode": "local_git_workflow_bootstrap",
        "requested_by": bootstrap_request["requested_by"],
        "justification": bootstrap_request["justification"],
    }
    return packet


def request_local_workflow_bootstrap(
    *,
    workflow_id: str,
    desired_end_state: str,
    title: str = DEFAULT_INITIAL_TITLE,
    goal_id: str = DEFAULT_INITIAL_GOAL_ID,
    work_item_id: str = DEFAULT_INITIAL_WORK_ITEM_ID,
    worktree_path: str | None = None,
    base_branch: str = "main",
    ticket: str | None = None,
    initiative: str | None = None,
    autonomy_budget: int = 0,
    decision_scope: str = "kernel",
    generated_at: int | None = None,
    requested_by: str = "operator",
    justification: str = "",
    ttl_seconds: int = DEFAULT_BOOTSTRAP_REQUEST_TTL_SECONDS,
) -> dict:
    """Issue a one-shot bootstrap request token for local workflow adoption."""
    if not workflow_id or not workflow_id.strip():
        raise WorkflowBootstrapError("workflow_id must be a non-empty string")
    if not desired_end_state or not desired_end_state.strip():
        raise WorkflowBootstrapError("--desired-end-state is required")
    if not title or not title.strip():
        raise WorkflowBootstrapError("--title must be a non-empty string")
    if not requested_by or not requested_by.strip():
        raise WorkflowBootstrapError("--requested-by is required")
    if not justification or not justification.strip():
        raise WorkflowBootstrapError("--justification is required")

    target = resolve_local_workflow_bootstrap_target(worktree_path)
    db_path = Path(target["db_path"])
    conn = connect(db_path)
    ensure_schema(conn)
    conn.row_factory = sqlite3.Row
    try:
        request = bootstrap_requests_mod.issue(
            conn,
            workflow_id=workflow_id,
            worktree_path=target["worktree_path"],
            requested_by=requested_by.strip(),
            justification=justification.strip(),
            ttl_seconds=ttl_seconds,
            payload={
                "desired_end_state": desired_end_state,
                "title": title,
                "goal_id": goal_id,
                "work_item_id": work_item_id,
                "base_branch": base_branch,
                "ticket": ticket,
                "initiative": initiative,
                "autonomy_budget": autonomy_budget,
                "decision_scope": decision_scope,
                "generated_at": generated_at,
            },
        )
    finally:
        conn.close()

    bootstrap_command = [
        "cc-policy",
        "workflow",
        "bootstrap-local",
        workflow_id,
        "--bootstrap-token",
        request["token"],
    ]
    if worktree_path:
        bootstrap_command.extend(["--worktree-path", target["worktree_path"]])

    return {
        "workflow_id": workflow_id,
        "bootstrap_request": {
            "token": request["token"],
            "db_path": str(db_path),
            "worktree_path": target["worktree_path"],
            "branch": target["branch"],
            "requested_by": request["requested_by"],
            "justification": request["justification"],
            "created_at": request["created_at"],
            "expires_at": request["expires_at"],
            "ttl_seconds": ttl_seconds,
        },
        "bootstrap_local_command": _quote_command(bootstrap_command),
    }


__all__ = [
    "DEFAULT_BOOTSTRAP_REQUEST_TTL_SECONDS",
    "DEFAULT_INITIAL_GOAL_ID",
    "DEFAULT_INITIAL_WORK_ITEM_ID",
    "DEFAULT_INITIAL_TITLE",
    "WorkflowBootstrapError",
    "bootstrap_local_workflow",
    "request_local_workflow_bootstrap",
    "workflow_bootstrap_guidance",
    "resolve_local_workflow_bootstrap_target",
]
