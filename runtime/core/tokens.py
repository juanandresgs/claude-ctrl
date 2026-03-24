"""Session token accumulation — project-scoped lifetime totals.

Each statusline render upserts the current session's running token count into
session_tokens. lifetime() sums all session rows for a project hash so the
statusline can display a cross-session lifetime total without double-counting
within a session (INSERT OR REPLACE semantics).

@decision DEC-RT-016
Title: session_tokens table — lifetime accumulation for project-scoped token budgets
Status: accepted
Rationale: Token counts are written per-session and summed project-wide for a
  lifetime view. upsert() is idempotent (INSERT OR REPLACE) so multiple writes
  from the same session converge on the most recent total. lifetime() sums across
  all sessions for the project so that switching sessions does not reset the display.
  This module holds no state; all persistence is in SQLite. The caller (statusline.sh
  via cc-policy CLI) owns the session_id and project_hash scoping.
"""

from __future__ import annotations

import sqlite3
import time


def upsert(
    conn: sqlite3.Connection,
    session_id: str,
    project_hash: str,
    total_tokens: int,
) -> None:
    """Write or replace the token total for a (session, project) pair.

    INSERT OR REPLACE means a repeated call from the same session always
    reflects the latest total — never accumulates within a session.
    """
    conn.execute(
        "INSERT OR REPLACE INTO session_tokens VALUES (?,?,?,?)",
        (session_id, project_hash, int(total_tokens), int(time.time())),
    )
    conn.commit()


def lifetime(conn: sqlite3.Connection, project_hash: str) -> dict:
    """Return the sum of all session token totals for a project.

    Returns {"total": <int>, "status": "ok"}.
    Returns total=0 when no rows exist — never raises.
    """
    row = conn.execute(
        "SELECT COALESCE(SUM(total_tokens), 0) FROM session_tokens WHERE project_hash=?",
        (project_hash,),
    ).fetchone()
    return {"total": row[0], "status": "ok"}
