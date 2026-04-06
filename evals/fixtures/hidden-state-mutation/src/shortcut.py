"""shortcut.py — DEFECTIVE: direct state.db mutation.

This module writes directly to ~/.claude/state.db via sqlite3.connect()
instead of going through the runtime domain modules. This bypasses all
runtime invariants, validation, and audit logging.

PLANTED DEFECT: hidden state mutation — direct sqlite3.connect to state.db
instead of using runtime modules.
"""

import os
import sqlite3

_STATE_DB = os.path.expanduser("~/.claude/state.db")


def record_marker(worktree_path: str, role: str) -> None:
    """Record an agent marker directly in state.db.

    DEFECT: connects directly to state.db via sqlite3, bypassing the
    runtime.core.markers module which owns this state domain.
    Any caller of this function mutates state.db without going through
    the authorized domain module.
    """
    conn = sqlite3.connect(_STATE_DB)  # DEFECT: direct connection to state.db
    try:
        conn.execute(
            "INSERT OR REPLACE INTO agent_markers (worktree_path, role) VALUES (?, ?)",
            (worktree_path, role),
        )
        conn.commit()
    finally:
        conn.close()


def clear_marker(worktree_path: str) -> None:
    """Remove an agent marker directly from state.db.

    DEFECT: same direct-connection pattern as record_marker.
    """
    conn = sqlite3.connect(_STATE_DB)  # DEFECT: direct connection to state.db
    try:
        conn.execute(
            "DELETE FROM agent_markers WHERE worktree_path = ?",
            (worktree_path,),
        )
        conn.commit()
    finally:
        conn.close()
