"""v6 dispatch pump projection.

Claude Code hooks cannot themselves call the Agent tool, but the runtime can
present a single authoritative launch envelope for an external sidecar/remote
control integration.  This keeps hook text as UI, not the dispatch authority.
"""

from __future__ import annotations

import sqlite3

from runtime.core import stage_runs


def next_launch(conn: sqlite3.Connection, *, workflow_id: str = "") -> dict:
    action = stage_runs.next_action(conn, workflow_id=workflow_id)
    if not action:
        return {"found": False, "authority": "v6_stage_machine", "launch": None}
    if action.get("status") == "worker_pending":
        return {
            "found": True,
            "authority": "v6_stage_machine",
            "next_action": action,
            "ticket": None,
            "launch": None,
            "message": "critic worker pending; no agent launch until reviewer ticket or critic fallback is published",
        }
    ticket = stage_runs.issue_ticket_for_next_action(conn, int(action["id"]))
    return launch_for_ticket(conn, ticket["id"], next_action=action)


def launch_for_ticket(conn: sqlite3.Connection, ticket_id: str, *, next_action: dict | None = None) -> dict:
    ticket = stage_runs.get_ticket(conn, ticket_id)
    if not ticket:
        raise ValueError(f"launch ticket not found: {ticket_id}")
    ctx = stage_runs.prompt_context_for_ticket(conn, ticket_id)
    prompt = f"{stage_runs.TICKET_PREFIX}{ticket_id}\n{ctx['context_text']}"
    return {
        "found": True,
        "authority": "v6_stage_machine",
        "next_action": next_action,
        "ticket": {**ticket, "prompt_prefix": f"{stage_runs.TICKET_PREFIX}{ticket_id}"},
        "launch": {
            "subagent_type": ticket["subagent_type"],
            "stage_id": ticket["stage_id"],
            "stage_run_id": ticket["stage_run_id"],
            "prompt": prompt,
            "prompt_first_line": f"{stage_runs.TICKET_PREFIX}{ticket_id}",
        },
    }
