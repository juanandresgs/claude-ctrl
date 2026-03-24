"""Project-scoped todo counts for statusline display.

Todo counts are a property of the project (not a single session). set_counts()
writes project_count and global_count for a project hash. get_counts() returns
those values or safe zeroes when no row exists.

@decision DEC-RT-017
Title: todo_state table — project-scoped todo counts for statusline display
Status: accepted
Rationale: Todos are project-wide workflow state, not session state. One row
  per project (PRIMARY KEY = project_hash) means the latest write wins, which is
  correct: the most recent todo scan reflects current state. get_counts() returns
  found=False with zeroes when no row exists so the statusline never crashes on a
  fresh project. set_counts() uses INSERT OR REPLACE for idempotent upsert semantics.
  The caller (todo.sh or a hook) owns the project_hash computation.
"""

from __future__ import annotations

import sqlite3
import time


def set_counts(
    conn: sqlite3.Connection,
    project_hash: str,
    project_count: int,
    global_count: int,
) -> None:
    """Write or replace the todo counts for a project.

    INSERT OR REPLACE: subsequent writes for the same project_hash replace
    the prior row — no accumulation, latest count wins.
    """
    conn.execute(
        "INSERT OR REPLACE INTO todo_state VALUES (?,?,?,?)",
        (project_hash, int(project_count), int(global_count), int(time.time())),
    )
    conn.commit()


def get_counts(conn: sqlite3.Connection, project_hash: str) -> dict:
    """Return the stored todo counts for a project.

    Returns {"project": <int>, "global": <int>, "found": <bool>, "status": "ok"}.
    Returns project=0, global=0, found=False when no row exists — never raises.
    """
    row = conn.execute(
        "SELECT project_count, global_count FROM todo_state WHERE project_hash=?",
        (project_hash,),
    ).fetchone()
    if row:
        return {
            "project": row[0],
            "global": row[1],
            "found": True,
            "status": "ok",
        }
    return {"project": 0, "global": 0, "found": False, "status": "ok"}
