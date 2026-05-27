"""v6 prompt routing authority.

The UserPromptSubmit hook is a transport adapter only.  It sends the raw user
prompt here and renders the returned context.  No shell regex decides whether a
v6 workflow starts.
"""

from __future__ import annotations

import os
import sqlite3
from dataclasses import asdict, dataclass

from runtime.core import stage_runs, work_items

EXPLICIT_PASSTHROUGH_COMMANDS = frozenset(
    {
        "/chat",
        "/help",
        "/status",
        "/doctor",
        "/config",
        "/agents",
        "/resume",
        "/compact",
        "/clear",
        "/no-v6",
    }
)

NATIVE_PLAN_HANDOFF_PATTERNS = (
    "implement the plan",
    "execute the plan",
    "follow the plan",
    "use the existing plan",
    "already a plan",
    "there is already a plan",
    "there's already a plan",
    "native plan mode",
    "follow the dispatch",
)

DISPATCH_RESUME_PATTERNS = (
    "continue dispatch",
    "continue the dispatch",
    "dispatch from runtime state",
    "just resume",
    "resume dispatch",
    "resume the dispatch",
    "resume the planner",
    "resume planner",
    "runtime state",
    "v6_dispatch_ready",
    "next dispatch",
)

DISPATCH_RESUME_EXACT = frozenset({"resume", "continue", "keep going"})


@dataclass(frozen=True)
class PromptRoute:
    action: str
    reason: str
    workflow_id: str
    dispatch_context: str = ""
    bootstrap: dict | None = None

    def as_dict(self) -> dict:
        data = asdict(self)
        if data["bootstrap"] is None:
            data.pop("bootstrap")
        return data


def route_prompt(
    conn: sqlite3.Connection,
    *,
    workflow_id: str,
    worktree_path: str,
    prompt: str,
    mode: str = "v6",
    goal_id: str = "",
    work_item_id: str = "",
) -> dict:
    """Route a user prompt under v6.

    In v6 mode, the default for any non-empty user work prompt is to bootstrap
    the runtime-owned planner stage.  Explicit chat/meta commands pass through.
    """

    prompt = prompt or ""
    workflow_id = (workflow_id or "default").strip() or "default"
    mode = (mode or os.environ.get("CLAUDE_CTRL_MODE") or "v6").strip().lower()

    if not prompt.strip():
        return PromptRoute("pass_through", "empty_prompt", workflow_id).as_dict()
    if os.environ.get("CLAUDE_CTRL_NO_V6") == "1" or mode in {"off", "disabled", "legacy"}:
        return PromptRoute("pass_through", "v6_disabled", workflow_id).as_dict()
    if stage_runs.parse_ticket_from_prompt(prompt):
        return PromptRoute("pass_through", "already_ticketed", workflow_id).as_dict()

    first_line = next((line.strip() for line in prompt.splitlines() if line.strip()), "")
    command = first_line.split(maxsplit=1)[0].lower() if first_line.startswith("/") else ""
    if command in EXPLICIT_PASSTHROUGH_COMMANDS:
        return PromptRoute("pass_through", f"explicit_passthrough:{command}", workflow_id).as_dict()

    resume_dispatch = _looks_like_dispatch_resume(prompt)
    embedded_ticket_id = stage_runs.find_ticket_id_in_text(prompt)
    if embedded_ticket_id:
        ticket = stage_runs.get_ticket(conn, embedded_ticket_id)
        if ticket:
            workflow_id = ticket["workflow_id"]
    elif resume_dispatch:
        workflow_id = stage_runs.resume_workflow_id(
            conn,
            preferred_workflow_id=workflow_id,
            worktree_path=worktree_path,
        )

    ids = work_items.ensure_for_prompt(conn, workflow_id=workflow_id, prompt=prompt)
    if _looks_like_native_plan_handoff(prompt):
        bootstrap = stage_runs.bootstrap_native_plan_handoff(
            conn,
            workflow_id=workflow_id,
            worktree_path=worktree_path,
            goal_id=goal_id or ids["goal_id"],
            work_item_id=work_item_id or ids["work_item_id"],
            prompt=prompt,
            recover_orphans=resume_dispatch,
        )
    else:
        bootstrap = stage_runs.bootstrap_planner(
            conn,
            workflow_id=workflow_id,
            worktree_path=worktree_path,
            goal_id=goal_id or ids["goal_id"],
            work_item_id=work_item_id or ids["work_item_id"],
            prompt=prompt,
            recover_orphans=resume_dispatch,
        )
    bootstrap["goal_id"] = goal_id or ids["goal_id"]
    bootstrap["work_item_id"] = work_item_id or ids["work_item_id"]
    dispatch_context = render_dispatch_context(bootstrap)
    return PromptRoute(
        "bootstrap",
        bootstrap.get("source", "v6_default_bootstrap"),
        workflow_id,
        dispatch_context=dispatch_context,
        bootstrap=bootstrap,
    ).as_dict()


def _looks_like_native_plan_handoff(prompt: str) -> bool:
    text = " ".join((prompt or "").lower().split())
    if not text:
        return False
    if any(pattern in text for pattern in NATIVE_PLAN_HANDOFF_PATTERNS):
        return True
    return "guardian" in text and "implementer" in text and "worktree" in text


def _looks_like_dispatch_resume(prompt: str) -> bool:
    text = " ".join((prompt or "").lower().split())
    return bool(
        text
        and (
            text.strip(".!?") in DISPATCH_RESUME_EXACT
            or any(pattern in text for pattern in DISPATCH_RESUME_PATTERNS)
        )
    )


def render_dispatch_context(bootstrap: dict) -> str:
    if not str(bootstrap.get("prompt_prefix") or ""):
        message = str(bootstrap.get("message") or "active stage has no launchable ticket")
        return f"V6_DISPATCH_STATUS: {message}"
    role = str(bootstrap.get("subagent_type") or "agent")
    stage = str(bootstrap.get("stage_id") or "unknown")
    context = (
        f"V6_DISPATCH_READY: launch {role} for stage {stage}\n"
        "Launch the canonical Agent naturally. Runtime will bind the launch and inject "
        "stage_run_id, workflow_id, allowed verdicts, and the claude_ctrl_result schema."
    )
    if bootstrap.get("source") == "native_plan_handoff":
        context += "\nNative Plan mode handoff: planner stage is already satisfied; do not relaunch planner."
    return context
