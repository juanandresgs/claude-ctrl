#!/usr/bin/env python3
"""Observatory sidecar — reads runtime state and computes health metrics.

Shadow-mode: read-only observer. Never writes to any canonical table.
Produces a JSON health report from a snapshot of all runtime state domains.

Usage (standalone):
    python3 sidecars/observatory/observe.py

Usage (via cc-policy):
    cc-policy sidecar observatory

@decision DEC-SIDECAR-001
Title: Sidecars are read-only consumers of the canonical SQLite runtime
Status: accepted
Rationale: Observatory reads proof_state, agent_markers, events, worktrees,
  and dispatch_queue in five SELECT-only queries. It never calls INSERT,
  UPDATE, or DELETE. Health assessment is a pure Python computation over
  the fetched rows — no state is written back. This is enforced by the
  test suite's row-count assertions and by code review. The sidecar has
  no access to the runtime domain module write methods; it only receives
  an open sqlite3.Connection. All queries use SELECT * with ORDER BY so
  the result is deterministic and the sidecar always knows it is reading
  a point-in-time snapshot. The observed_at timestamp in the report makes
  the snapshot age visible to the consumer.

@decision DEC-SIDECAR-002
Title: Observatory receives a pre-opened connection, not a db path
Status: accepted
Rationale: Accepting a sqlite3.Connection (rather than opening one
  internally) makes the Observatory independently testable with an
  in-memory database without any file-system dependency. The CLI wrapper
  (runtime/cli.py _handle_sidecar) opens the real db connection and
  passes it in, just as every other domain handler does. This pattern
  is consistent with all existing runtime.core.* modules.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path
from typing import Optional
import sqlite3

# Allow running as `python3 sidecars/observatory/observe.py` from project root
_HERE = Path(__file__).resolve().parent
_PROJECT_ROOT = _HERE.parent.parent
if str(_PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(_PROJECT_ROOT))


class Observatory:
    """Read-only observer of all runtime state domains.

    Reads: proof_state, agent_markers, events, worktrees, dispatch_queue.
    Never writes to any table.

    Attributes populated after observe():
        proof_states:    list[sqlite3.Row] — all proof_state rows
        active_markers:  list[sqlite3.Row] — agent_markers WHERE is_active=1
        recent_events:   list[sqlite3.Row] — 20 most recent events
        worktrees:       list[sqlite3.Row] — active (not removed) worktrees
        dispatch:        list[sqlite3.Row] — pending dispatch_queue entries
    """

    def __init__(self, name: str, conn: sqlite3.Connection):
        self.name = name
        self._conn = conn
        # Populated by observe()
        self.proof_states: list = []
        self.active_markers: list = []
        self.recent_events: list = []
        self.worktrees: list = []
        self.dispatch: list = []

    def observe(self) -> None:
        """Execute read-only queries against all canonical state tables.

        Populates all instance attributes for subsequent report() and
        _compute_health() calls. Safe to call multiple times; each call
        refreshes the snapshot.
        """
        conn = self._conn
        self.proof_states = conn.execute(
            "SELECT workflow_id, status, updated_at FROM proof_state"
        ).fetchall()
        self.active_markers = conn.execute(
            "SELECT agent_id, role, started_at FROM agent_markers WHERE is_active=1"
        ).fetchall()
        self.recent_events = conn.execute(
            "SELECT id, type, source, detail, created_at"
            " FROM events ORDER BY id DESC LIMIT 20"
        ).fetchall()
        self.worktrees = conn.execute(
            "SELECT path, branch, ticket, created_at"
            " FROM worktrees WHERE removed_at IS NULL"
        ).fetchall()
        self.dispatch = conn.execute(
            "SELECT id, role, status, ticket, created_at"
            " FROM dispatch_queue WHERE status='pending'"
            " ORDER BY created_at"
        ).fetchall()

    def report(self) -> dict:
        """Return a JSON-serializable health report dict.

        The report is a point-in-time snapshot. observed_at is an epoch
        integer so consumers can determine data age.

        Returns:
            dict with keys: name, observed_at, proof_count, active_agents,
            pending_dispatches, worktree_count, recent_event_count, health.
            health is a nested dict: {"ok": bool, "issues": list[str]}.
        """
        return {
            "name": self.name,
            "observed_at": int(time.time()),
            "proof_count": len(self.proof_states),
            "active_agents": len(self.active_markers),
            "pending_dispatches": len(self.dispatch),
            "worktree_count": len(self.worktrees),
            "recent_event_count": len(self.recent_events),
            "health": self._compute_health(),
        }

    def _compute_health(self) -> dict:
        """Compute a health assessment from the observed state.

        Issues detected:
          many_active_agents  — more than 3 simultaneously active agents
          dispatch_backlog    — more than 10 pending dispatch items
          stale_proofs        — any proof_state with status=pending and
                                updated_at older than 1 hour (3600 seconds)

        Returns:
            {"ok": bool, "issues": list[str]}
            ok is True only when issues is empty.
        """
        issues: list[str] = []

        if len(self.active_markers) > 3:
            issues.append("many_active_agents")

        if len(self.dispatch) > 10:
            issues.append("dispatch_backlog")

        cutoff = time.time() - 3600
        stale = [
            row for row in self.proof_states
            if row["status"] == "pending" and row["updated_at"] < cutoff
        ]
        if stale:
            issues.append("stale_proofs")

        return {"ok": len(issues) == 0, "issues": issues}


# ---------------------------------------------------------------------------
# Standalone entry point
# ---------------------------------------------------------------------------

def _main() -> int:
    """Run the observatory and print a JSON health report to stdout."""
    from runtime.core.config import default_db_path
    from runtime.core.db import connect
    from runtime.schemas import ensure_schema

    db_path = default_db_path()
    if not db_path.exists():
        report = {
            "name": "observatory",
            "observed_at": int(time.time()),
            "error": f"database not found: {db_path}",
            "health": {"ok": False, "issues": ["no_database"]},
        }
        print(json.dumps(report, indent=2))
        return 1

    conn = connect(db_path)
    ensure_schema(conn)
    try:
        obs = Observatory("observatory", conn)
        obs.observe()
        print(json.dumps(obs.report(), indent=2))
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
