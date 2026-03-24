"""Agent marker authority.

Owns the agent_markers table. Tracks which agent roles are active at any
point in time. Supersedes the flat-file .subagent-tracker mechanism
(DEC-SUBAGENT-001) once TKT-007 lands.

@decision DEC-RT-001
Title: Canonical SQLite schema for all shared workflow state
Status: accepted
Rationale: agent_markers replaces .subagent-tracker flat-file coordination.
  The is_active flag lets queries find the current active marker without
  scanning all rows. deactivate() sets stopped_at and clears is_active in
  a single transaction so there is never a window where a marker is
  stopped but still appears active.
"""

from __future__ import annotations

import sqlite3
import time
from typing import Optional


def _row_to_dict(row: sqlite3.Row) -> dict:
    return dict(row)


def set_active(conn: sqlite3.Connection, agent_id: str, role: str) -> None:
    """Upsert an active marker for agent_id with the given role.

    Any existing marker for this agent_id is replaced (PRIMARY KEY conflict).
    started_at is always reset to now on upsert so restarts are tracked.
    """
    now = int(time.time())
    with conn:
        conn.execute(
            """
            INSERT INTO agent_markers (agent_id, role, started_at, stopped_at, is_active)
            VALUES (?, ?, ?, NULL, 1)
            ON CONFLICT(agent_id) DO UPDATE SET
                role       = excluded.role,
                started_at = excluded.started_at,
                stopped_at = NULL,
                is_active  = 1
            """,
            (agent_id, role, now),
        )


def get_active(conn: sqlite3.Connection) -> Optional[dict]:
    """Return the most recently started active marker, or None."""
    row = conn.execute(
        """
        SELECT agent_id, role, started_at, stopped_at, is_active
        FROM   agent_markers
        WHERE  is_active = 1
        ORDER  BY started_at DESC
        LIMIT  1
        """
    ).fetchone()
    return _row_to_dict(row) if row else None


def deactivate(conn: sqlite3.Connection, agent_id: str) -> None:
    """Mark agent_id as stopped. No-op if agent_id is not found."""
    now = int(time.time())
    with conn:
        conn.execute(
            """
            UPDATE agent_markers
            SET    stopped_at = ?,
                   is_active  = 0
            WHERE  agent_id   = ?
            """,
            (now, agent_id),
        )


def list_all(conn: sqlite3.Connection) -> list[dict]:
    """Return all agent_markers rows ordered by started_at descending."""
    rows = conn.execute(
        """
        SELECT agent_id, role, started_at, stopped_at, is_active
        FROM   agent_markers
        ORDER  BY started_at DESC
        """
    ).fetchall()
    return [_row_to_dict(r) for r in rows]
