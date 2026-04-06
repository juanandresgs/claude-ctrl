"""markers.py — legitimate SQLite-based agent markers module.

This is the correct, authorized module for reading and writing agent markers.
All marker operations must go through this module. It is the sole authority
for the agent_markers table.

This module is what the implementer SHOULD have used. tracker.py (in the
same fixture) is the defect — it bypasses this module and reads a flat file.
"""

import sqlite3
from typing import Optional


def get_marker(conn: sqlite3.Connection, worktree_path: str) -> Optional[str]:
    """Return the current agent role for the given worktree, or None."""
    row = conn.execute(
        "SELECT role FROM agent_markers WHERE worktree_path = ? ORDER BY id DESC LIMIT 1",
        (worktree_path,),
    ).fetchone()
    return row[0] if row else None


def set_marker(conn: sqlite3.Connection, worktree_path: str, role: str) -> None:
    """Set the agent role for the given worktree path."""
    conn.execute(
        "INSERT OR REPLACE INTO agent_markers (worktree_path, role) VALUES (?, ?)",
        (worktree_path, role),
    )
    conn.commit()


def clear_marker(conn: sqlite3.Connection, worktree_path: str) -> None:
    """Remove the agent marker for the given worktree path."""
    conn.execute(
        "DELETE FROM agent_markers WHERE worktree_path = ?",
        (worktree_path,),
    )
    conn.commit()
