"""Agent lifecycle handlers.

Owns the start/stop marker transitions for agent identity. These are thin
wrappers over runtime.core.markers that give callers a semantic interface
without needing to know the marker table schema.

Called by the CLI ``cc-policy dispatch agent-start`` / ``agent-stop``
subcommands, which post-task.sh and subagent-start.sh will call in lieu
of direct rt_marker_set / rt_marker_deactivate calls.

@decision DEC-LIFECYCLE-001
Title: lifecycle.py owns agent start/stop marker transitions
Status: accepted
Rationale: Marker activation and deactivation is a distinct concern from
  dispatch routing. Separating it into lifecycle.py makes both modules
  independently testable and avoids conflating routing logic (dispatch_engine.py)
  with agent identity tracking. The module is intentionally thin — all
  persistence is delegated to runtime.core.markers, which owns the
  agent_markers table.
"""

from __future__ import annotations

import sqlite3

from runtime.core import markers


def on_agent_start(conn: sqlite3.Connection, agent_type: str, agent_id: str) -> None:
    """Mark agent_id as active with the given role.

    Calls markers.set_active(), which upserts on conflict so a re-start
    correctly resets started_at and clears any previous stopped_at.

    Args:
        conn:       Open SQLite connection with schema applied.
        agent_type: Role string (implementer, tester, guardian, planner).
        agent_id:   Unique agent identifier (e.g. session UUID or pid).
    """
    markers.set_active(conn, agent_id, agent_type)


def on_agent_stop(conn: sqlite3.Connection, agent_type: str, agent_id: str) -> None:
    """Deactivate the marker for agent_id.

    Calls markers.deactivate(), which is a no-op when agent_id is not found,
    so callers do not need to guard against unknown agent IDs.

    Args:
        conn:       Open SQLite connection with schema applied.
        agent_type: Role string — accepted for symmetry with on_agent_start
                    but not used for the deactivation query (agent_id is the
                    primary key). Retained so callers can log it if needed.
        agent_id:   Unique agent identifier matching the one passed to
                    on_agent_start.
    """
    markers.deactivate(conn, agent_id)
