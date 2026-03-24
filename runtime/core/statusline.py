"""Runtime-backed statusline snapshot projection.

Read-only projection across all runtime tables. Gathers all state in a single
pass and returns a unified dict suitable for ANSI HUD rendering by
scripts/statusline.sh without that script needing to call multiple subcommands.

TKT-011 promotes this from a stub to the canonical implementation. The
extended field set gives scripts/statusline.sh everything it needs for a
richer HUD: proof workflow identity, active agent ID, per-worktree details,
dispatch cycle identity, and a recent event list.

@decision DEC-RT-011
Title: Statusline snapshot is a read-only projection across all runtime tables
Status: accepted
Rationale: snapshot() is the single read surface for the statusline HUD. It
  reads proof_state, agent_markers, worktrees, dispatch_cycles, dispatch_queue,
  and events in one pass and returns a canonical dict. No writes happen here.
  The extended field set (proof_workflow, active_agent_id, worktrees list,
  dispatch_cycle_id, recent_events list) gives scripts/statusline.sh everything
  it needs for the richer HUD without requiring multiple CLI round-trips.
  All fields default to None/0/[] so the statusline never crashes on an empty
  or partially-populated DB. The broad exception handler at the bottom guards
  against unexpected schema errors only; all normal empty-result paths are
  handled individually so partial state is still returned on any single
  query failure.
"""

from __future__ import annotations

import sqlite3
import time


def snapshot(conn: sqlite3.Connection) -> dict:
    """Return a read-only projection of runtime state for status display.

    Fields returned:
      proof_status        — status of the most recently active proof row
                            ('pending'/'verified'), or 'idle' when none
      proof_workflow      — workflow_id of that proof row, or None
      active_agent        — role of the most recently started active marker,
                            or None
      active_agent_id     — agent_id of that marker, or None
      worktree_count      — number of active (non-removed) worktrees
      worktrees           — list of {path, branch, ticket} for each active wt
      dispatch_status     — role of the oldest pending dispatch queue item,
                            or None when the queue is empty
      dispatch_initiative — initiative name of the current active cycle,
                            or None
      dispatch_cycle_id   — id of the current active cycle, or None
      recent_event_count  — count of the most recent events returned (up to 5)
      recent_events       — list of up to 5 events, newest first, each with
                            {type, detail, created_at}
      snapshot_at         — Unix epoch when this snapshot was taken
      status              — always 'ok'

    Never raises: returns safe defaults for any missing data.
    """
    now = int(time.time())
    result: dict = {
        "proof_status": "idle",
        "proof_workflow": None,
        "active_agent": None,
        "active_agent_id": None,
        "worktree_count": 0,
        "worktrees": [],
        "dispatch_status": None,
        "dispatch_initiative": None,
        "dispatch_cycle_id": None,
        "recent_event_count": 0,
        "recent_events": [],
        "snapshot_at": now,
        "status": "ok",
    }

    try:
        # ------------------------------------------------------------------
        # Proof status — prefer any non-idle row (pending/verified) over idle.
        #
        # @decision DEC-RT-011: Non-idle proof takes precedence because the
        # statusline surfaces active workflow activity. When multiple workflows
        # are tracked, the in-flight one (pending/verified) is the actionable
        # signal; idle rows are background noise. ORDER BY updated_at DESC
        # picks the most recently updated non-idle row when several exist.
        # ------------------------------------------------------------------
        row = conn.execute(
            """
            SELECT workflow_id, status
            FROM   proof_state
            WHERE  status != 'idle'
            ORDER  BY updated_at DESC
            LIMIT  1
            """
        ).fetchone()
        if row:
            result["proof_status"] = row["status"]
            result["proof_workflow"] = row["workflow_id"]

        # ------------------------------------------------------------------
        # Active agent — most recently started active marker
        # ------------------------------------------------------------------
        row = conn.execute(
            """
            SELECT agent_id, role
            FROM   agent_markers
            WHERE  is_active = 1
            ORDER  BY started_at DESC
            LIMIT  1
            """
        ).fetchone()
        if row:
            result["active_agent"] = row["role"]
            result["active_agent_id"] = row["agent_id"]

        # ------------------------------------------------------------------
        # Worktrees — all active (removed_at IS NULL), full detail rows
        # ------------------------------------------------------------------
        rows = conn.execute(
            """
            SELECT path, branch, ticket
            FROM   worktrees
            WHERE  removed_at IS NULL
            ORDER  BY created_at DESC
            """
        ).fetchall()
        wt_list = [
            {"path": r["path"], "branch": r["branch"], "ticket": r["ticket"]}
            for r in rows
        ]
        result["worktree_count"] = len(wt_list)
        result["worktrees"] = wt_list

        # ------------------------------------------------------------------
        # Dispatch — oldest pending queue item (next to be claimed) + active cycle
        # ------------------------------------------------------------------
        row = conn.execute(
            """
            SELECT role
            FROM   dispatch_queue
            WHERE  status = 'pending'
            ORDER  BY created_at ASC
            LIMIT  1
            """
        ).fetchone()
        if row:
            result["dispatch_status"] = row["role"]

        row = conn.execute(
            """
            SELECT id, initiative
            FROM   dispatch_cycles
            WHERE  status = 'active'
            ORDER  BY created_at DESC
            LIMIT  1
            """
        ).fetchone()
        if row:
            result["dispatch_initiative"] = row["initiative"]
            result["dispatch_cycle_id"] = row["id"]

        # ------------------------------------------------------------------
        # Recent events — up to 5 most recent, newest first
        # ------------------------------------------------------------------
        rows = conn.execute(
            """
            SELECT type, detail, created_at
            FROM   events
            ORDER  BY id DESC
            LIMIT  5
            """
        ).fetchall()
        evt_list = [
            {"type": r["type"], "detail": r["detail"], "created_at": r["created_at"]}
            for r in rows
        ]
        result["recent_event_count"] = len(evt_list)
        result["recent_events"] = evt_list

    except Exception:
        # Never crash the statusline — return whatever we have so far.
        # This guard is for unexpected schema errors only; normal empty-result
        # paths are handled individually above and do not raise.
        pass

    return result
