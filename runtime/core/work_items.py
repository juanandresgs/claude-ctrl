"""v6 goals/work-items authority.

Workflow IDs are still useful for scoping, but they are not a substitute for a
first-class unit of work.  Prompt routing creates/resolves these rows and stage
runs reference them.
"""

from __future__ import annotations

import sqlite3
import time
import uuid


def _now() -> int:
    return int(time.time())


def _title(prompt: str) -> str:
    text = " ".join((prompt or "").strip().split())
    return (text[:96] or "v6 work item")


def ensure_for_prompt(conn: sqlite3.Connection, *, workflow_id: str, prompt: str) -> dict:
    workflow_id = (workflow_id or "default").strip() or "default"
    now = _now()
    row = conn.execute(
        """
        SELECT wi.*, g.title AS goal_title
        FROM work_items wi
        JOIN goals g ON g.id = wi.goal_id
        WHERE wi.workflow_id = ? AND wi.status = 'active' AND g.status = 'active'
        ORDER BY wi.created_at DESC
        LIMIT 1
        """,
        (workflow_id,),
    ).fetchone()
    if row:
        return {"goal_id": row["goal_id"], "work_item_id": row["id"], "created": False}

    goal_id = f"goal-{uuid.uuid4().hex}"
    work_item_id = f"wi-{uuid.uuid4().hex}"
    title = _title(prompt)
    with conn:
        conn.execute(
            """
            INSERT INTO goals (id, workflow_id, title, prompt_text, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, 'active', ?, ?)
            """,
            (goal_id, workflow_id, title, prompt or "", now, now),
        )
        conn.execute(
            """
            INSERT INTO work_items (id, goal_id, workflow_id, title, prompt_text, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, 'active', ?, ?)
            """,
            (work_item_id, goal_id, workflow_id, title, prompt or "", now, now),
        )
    return {"goal_id": goal_id, "work_item_id": work_item_id, "created": True}


def complete_for_workflow(conn: sqlite3.Connection, workflow_id: str) -> int:
    now = _now()
    with conn:
        cur = conn.execute(
            "UPDATE work_items SET status = 'completed', updated_at = ? WHERE workflow_id = ? AND status = 'active'",
            (now, workflow_id),
        )
    return int(cur.rowcount or 0)
