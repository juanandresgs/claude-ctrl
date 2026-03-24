"""Runtime-backed statusline snapshot projection.

Read-only projection across all runtime tables. Full implementation belongs
to TKT-011. This stub defines the snapshot() signature so cli.py and
tests can import it without ImportError while TKT-006 is in progress.

@decision DEC-RT-001
Title: Canonical SQLite schema for all shared workflow state
Status: accepted
Rationale: statusline.snapshot() is a read-only projection — it reads from
  proof_state, agent_markers, worktrees, dispatch_cycles, and events in a
  single pass and returns a unified dict. No writes happen here. The full
  implementation is deferred to TKT-011; this stub returns a minimal safe
  dict so downstream callers (cli.py subcommand, future scripts/statusline.sh)
  can be written and tested against the signature now.
"""

from __future__ import annotations

import sqlite3
import time


def snapshot(conn: sqlite3.Connection) -> dict:
    """Return a read-only projection of runtime state for status display.

    Fields returned:
      proof_status     — most recent proof_state status, or 'idle'
      active_agent     — role of the most recently started active marker, or None
      worktree_count   — number of active (non-removed) worktrees
      dispatch_status  — status of the current active cycle, or None
      dispatch_initiative — initiative name of the current active cycle, or None
      recent_event_count — count of events in the last 60 seconds
      snapshot_at      — Unix epoch when this snapshot was taken

    Never raises: returns safe defaults for any missing data.

    Full implementation (additional fields, parametric workflow/session
    scoping) is in TKT-011.
    """
    now = int(time.time())
    result: dict = {
        "proof_status": "idle",
        "active_agent": None,
        "worktree_count": 0,
        "dispatch_status": None,
        "dispatch_initiative": None,
        "recent_event_count": 0,
        "snapshot_at": now,
    }

    try:
        # Proof status — most recently updated row
        row = conn.execute(
            "SELECT status FROM proof_state ORDER BY updated_at DESC LIMIT 1"
        ).fetchone()
        if row:
            result["proof_status"] = row[0]

        # Active agent — most recently started active marker
        row = conn.execute(
            "SELECT role FROM agent_markers WHERE is_active=1 ORDER BY started_at DESC LIMIT 1"
        ).fetchone()
        if row:
            result["active_agent"] = row[0]

        # Worktree count
        row = conn.execute(
            "SELECT COUNT(*) FROM worktrees WHERE removed_at IS NULL"
        ).fetchone()
        if row:
            result["worktree_count"] = row[0]

        # Dispatch cycle
        row = conn.execute(
            "SELECT status, initiative FROM dispatch_cycles WHERE status='active' ORDER BY created_at DESC LIMIT 1"
        ).fetchone()
        if row:
            result["dispatch_status"] = row[0]
            result["dispatch_initiative"] = row[1]

        # Recent events (last 60s)
        row = conn.execute(
            "SELECT COUNT(*) FROM events WHERE created_at >= ?",
            (now - 60,),
        ).fetchone()
        if row:
            result["recent_event_count"] = row[0]

    except Exception:
        # Never crash the status display — return whatever we have so far
        pass

    return result
