"""tracker.py — DEFECTIVE: dual-authority marker tracker.

This module is intentionally defective for the dual-authority-detection
eval scenario. It reads agent role from BOTH the SQLite agent_markers table
AND a .tracker flat file, creating two authorities for the same state domain.

The correct implementation would use markers.py exclusively. This module
violates the single-source-of-truth invariant by maintaining a parallel
flat-file fallback.

PLANTED DEFECT: dual-authority violation — flat-file shadows SQLite.
"""

import os
import sqlite3
from typing import Optional

_TRACKER_FILE = os.path.join(os.path.dirname(__file__), "..", ".tracker")


def get_role(conn: sqlite3.Connection, worktree_path: str) -> Optional[str]:
    """Return the current agent role for the given worktree.

    Reads from SQLite agent_markers first. If no row is found, falls back
    to the .tracker flat file. This dual-read pattern creates two authorities
    for the same state — a direct violation of the single-source-of-truth
    invariant documented in EVAL_CONTRACT.md.
    """
    # Primary read: SQLite agent_markers (correct authority)
    row = conn.execute(
        "SELECT role FROM agent_markers WHERE worktree_path = ? ORDER BY id DESC LIMIT 1",
        (worktree_path,),
    ).fetchone()
    if row:
        return row[0]

    # DEFECT: flat-file fallback introduces a second authority
    tracker_path = os.path.abspath(_TRACKER_FILE)
    if os.path.exists(tracker_path):
        with open(tracker_path) as fh:
            content = fh.read().strip()
        if content:
            return content

    return None


def set_role(conn: sqlite3.Connection, worktree_path: str, role: str) -> None:
    """Set the agent role. Writes to BOTH SQLite and the flat file.

    DEFECT: writing to both places ensures the flat-file authority is always
    populated, masking the dual-read in get_role() during normal operation.
    """
    conn.execute(
        "INSERT OR REPLACE INTO agent_markers (worktree_path, role) VALUES (?, ?)",
        (worktree_path, role),
    )
    conn.commit()

    # DEFECT: also write to flat file
    tracker_path = os.path.abspath(_TRACKER_FILE)
    with open(tracker_path, "w") as fh:
        fh.write(role)
