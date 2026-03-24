"""Audit event store.

Owns the events table. Append-only: events are never updated or deleted
in normal operation. query() supports filtering by type and time window.

@decision DEC-RT-001
Title: Canonical SQLite schema for all shared workflow state
Status: accepted
Rationale: events replaces the .audit-log flat file (append_audit() in
  context-lib.sh). The AUTOINCREMENT id gives a stable insertion-order
  cursor. since/limit make recent-events queries cheap without full scans.
"""

from __future__ import annotations

import sqlite3
import time
from typing import Optional


def emit(
    conn: sqlite3.Connection,
    type: str,
    source: Optional[str] = None,
    detail: Optional[str] = None,
) -> int:
    """Insert an event row and return its auto-assigned id."""
    now = int(time.time())
    with conn:
        cur = conn.execute(
            """
            INSERT INTO events (type, source, detail, created_at)
            VALUES (?, ?, ?, ?)
            """,
            (type, source, detail, now),
        )
    return cur.lastrowid


def query(
    conn: sqlite3.Connection,
    type: Optional[str] = None,
    since: Optional[int] = None,
    limit: int = 50,
) -> list[dict]:
    """Return events, newest first, with optional type and time filters.

    Args:
        type:  If given, return only events whose type matches exactly.
        since: If given, return only events with created_at >= since (epoch).
        limit: Maximum number of rows to return (default 50).
    """
    clauses: list[str] = []
    params: list = []

    if type is not None:
        clauses.append("type = ?")
        params.append(type)
    if since is not None:
        clauses.append("created_at >= ?")
        params.append(since)

    where = ("WHERE " + " AND ".join(clauses)) if clauses else ""
    params.append(limit)

    rows = conn.execute(
        f"""
        SELECT id, type, source, detail, created_at
        FROM   events
        {where}
        ORDER  BY id DESC
        LIMIT  ?
        """,
        params,
    ).fetchall()
    return [dict(r) for r in rows]
