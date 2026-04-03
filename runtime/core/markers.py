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
    status is set to 'active' on upsert.
    """
    now = int(time.time())
    with conn:
        conn.execute(
            """
            INSERT INTO agent_markers (agent_id, role, started_at, stopped_at, is_active, status)
            VALUES (?, ?, ?, NULL, 1, 'active')
            ON CONFLICT(agent_id) DO UPDATE SET
                role       = excluded.role,
                started_at = excluded.started_at,
                stopped_at = NULL,
                is_active  = 1,
                status     = 'active'
            """,
            (agent_id, role, now),
        )


def get_active(conn: sqlite3.Connection) -> Optional[dict]:
    """Return the most recently started active marker, or None."""
    row = conn.execute(
        """
        SELECT agent_id, role, started_at, stopped_at, is_active, status
        FROM   agent_markers
        WHERE  is_active = 1
        ORDER  BY started_at DESC
        LIMIT  1
        """
    ).fetchone()
    return _row_to_dict(row) if row else None


def get_active_with_age(conn: sqlite3.Connection) -> Optional[dict]:
    """Return the active marker with computed age_seconds field.

    age_seconds = current_time - started_at. Returns None if no active marker.

    @decision DEC-RT-023
    @title get_active_with_age computes marker age at read time
    @status accepted
    @rationale TKT-023 requires the statusline to display how long the current
      marker has been active so operators can detect stale subagent markers.
      Age is computed at read time (not stored) to avoid write-side churn on
      a hot read path. The max(0, ...) guard handles clock skew.
    """
    marker = get_active(conn)
    if marker is None:
        return None
    now = int(time.time())
    marker["age_seconds"] = max(0, now - (marker.get("started_at") or now))
    return marker


def deactivate(conn: sqlite3.Connection, agent_id: str) -> None:
    """Mark agent_id as stopped. No-op if agent_id is not found."""
    now = int(time.time())
    with conn:
        conn.execute(
            """
            UPDATE agent_markers
            SET    stopped_at = ?,
                   is_active  = 0,
                   status     = 'stopped'
            WHERE  agent_id   = ?
            """,
            (now, agent_id),
        )


def list_all(conn: sqlite3.Connection) -> list[dict]:
    """Return all agent_markers rows ordered by started_at descending."""
    rows = conn.execute(
        """
        SELECT agent_id, role, started_at, stopped_at, is_active, status
        FROM   agent_markers
        ORDER  BY started_at DESC
        """
    ).fetchall()
    return [_row_to_dict(r) for r in rows]


def expire_stale(
    conn: sqlite3.Connection,
    ttl: int = 7200,
    now: int | None = None,
) -> int:
    """Deactivate markers older than ttl seconds. Returns count expired.

    Transitions status from 'active' to 'expired' and clears is_active for
    any marker whose started_at is more than ttl seconds before now. This
    prevents ghost markers from crashed sessions blocking new dispatch.

    @decision DEC-STAB-A4-002
    Title: expire_stale uses started_at age rather than a separate expires_at
    Status: accepted
    Rationale: agent_markers has no expires_at column (unlike dispatch_leases).
      Using started_at + ttl as the expiry boundary avoids a schema migration
      that would require altering existing rows. The 2-hour default TTL matches
      DEFAULT_LEASE_TTL in schemas.py so marker and lease cleanup are aligned.
    """
    if now is None:
        now = int(time.time())
    cutoff = now - ttl
    with conn:
        cursor = conn.execute(
            """
            UPDATE agent_markers
            SET    status    = 'expired',
                   is_active = 0
            WHERE  status    = 'active'
              AND  started_at < ?
            """,
            (cutoff,),
        )
    return cursor.rowcount
