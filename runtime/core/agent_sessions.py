"""Runtime-owned agent_session domain authority.

Closes the final §2a model-symmetry gap: with ``seats`` promoted at
``e982d50``, ``agent_session`` was the last supervision primitive whose
writes still lived inside ``dispatch_hook.py`` as an inline
``INSERT OR IGNORE INTO agent_sessions`` statement. This module gives the
runtime a first-class state machine for session lifecycle so transitions
cannot be forgotten or silently duplicated.

Authority scope
---------------
- **This module** owns every state transition on ``agent_sessions``
  rows and every lifecycle query (create idempotently, mark-completed,
  mark-dead, mark-orphaned, list-active, get).
- ``dispatch_hook.ensure_session_and_seat`` delegates inward to
  :func:`create` but may not write ``agent_sessions`` rows directly.
- Transport adapters (tmux, MCP, watchdog) never call this module
  directly; they go through the hook-adapter helpers per CUTOVER §2a
  rule 3.

State machine
-------------
::

    create()          -> active
      ├─ mark_completed()  -> completed   (normal end)
      ├─ mark_dead()       -> dead         (crash / irrecoverable)
      └─ mark_orphaned()   -> orphaned     (session lost)

Terminal states: ``completed``, ``dead``, ``orphaned``.  All three are
terminal — once a session leaves ``active`` it does not return and
cannot flip between the three terminal states.  Calling a transition
that matches the current status is an idempotent no-op (returns
``transitioned=False`` without writing); any other cross-terminal move
raises ``ValueError``.

Vocabulary comes from ``runtime.schemas.AGENT_SESSION_STATUSES`` —
this module is the sole writer that enforces the vocabulary on the
way in and never invents new values.

@decision DEC-AGENT-SESSION-DOMAIN-001
@title agent_session promoted to runtime-owned domain module
@status accepted
@rationale §2a required every supervision primitive to be a
  runtime-owned domain with state-machine enforcement, query surface,
  and CLI.  After seat was promoted at e982d50, agent_session was
  the last one whose writes lived inside ``dispatch_hook.py``.  This
  module closes that gap with the same structural pattern as
  ``runtime.core.seats`` and ``runtime.core.supervision_threads``,
  completing §2a model symmetry.  Post-Phase-8 continuation under the
  closed Phase 2b scope; no new phase.
"""

from __future__ import annotations

import sqlite3
import time
from typing import Optional

from runtime.schemas import AGENT_SESSION_STATUSES


# ---------------------------------------------------------------------------
# State machine
# ---------------------------------------------------------------------------

_VALID_TRANSITIONS: dict[str, frozenset[str]] = {
    "active": frozenset({"completed", "dead", "orphaned"}),
    # Terminal — no transitions out.
    "completed": frozenset(),
    "dead": frozenset(),
    "orphaned": frozenset(),
}


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _now() -> int:
    return int(time.time())


def _row_to_dict(row: sqlite3.Row) -> dict:
    return dict(row)


def _require_status(status: str) -> None:
    if status not in AGENT_SESSION_STATUSES:
        raise ValueError(
            f"agent_sessions: invalid status {status!r}; "
            f"allowed: {sorted(AGENT_SESSION_STATUSES)}"
        )


def _fetch(conn: sqlite3.Connection, session_id: str) -> sqlite3.Row:
    row = conn.execute(
        "SELECT * FROM agent_sessions WHERE session_id = ?", (session_id,)
    ).fetchone()
    if row is None:
        raise ValueError(
            f"agent_sessions: session_id not found: {session_id!r}"
        )
    return row


def _transition(
    conn: sqlite3.Connection,
    session_id: str,
    target: str,
) -> dict:
    """Apply a validated status transition on a single session.

    Same-status requests (e.g. ``mark_completed`` on an already-
    completed session) are treated as idempotent no-ops — the row is
    returned with ``transitioned=False`` and no write is performed.
    Invalid transitions (e.g. ``completed → dead``) raise
    ``ValueError``.
    """
    _require_status(target)
    row = _fetch(conn, session_id)
    current = row["status"]

    if current == target:
        return {"row": _row_to_dict(row), "transitioned": False}

    allowed = _VALID_TRANSITIONS.get(current, frozenset())
    if target not in allowed:
        raise ValueError(
            f"agent_sessions: invalid transition {current!r} → "
            f"{target!r} for session {session_id!r}"
        )

    now = _now()
    with conn:
        conn.execute(
            "UPDATE agent_sessions SET status = ?, updated_at = ? "
            "WHERE session_id = ?",
            (target, now, session_id),
        )
    updated = _fetch(conn, session_id)
    return {"row": _row_to_dict(updated), "transitioned": True}


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def create(
    conn: sqlite3.Connection,
    session_id: str,
    transport: str,
    transport_handle: Optional[str] = None,
    workflow_id: Optional[str] = None,
) -> dict:
    """Idempotently create an agent_sessions row, returning the current row.

    Used by hook-adapter bootstrap (``dispatch_hook.ensure_session_and_seat``)
    to guarantee a session exists for a freshly-arriving dispatch.  If
    a row already exists for ``session_id`` the existing row is
    returned unchanged — there is no update on the idempotent path, so
    an upstream ``transport_handle`` or ``workflow_id`` already bound
    to the session is preserved.

    Empty ``session_id`` or ``transport`` raise ``ValueError``.
    """
    if not session_id:
        raise ValueError("agent_sessions: session_id must be non-empty")
    if not transport:
        raise ValueError("agent_sessions: transport must be non-empty")

    now = _now()
    with conn:
        conn.execute(
            """
            INSERT OR IGNORE INTO agent_sessions
                (session_id, workflow_id, transport, transport_handle,
                 status, created_at, updated_at)
            VALUES (?, ?, ?, ?, 'active', ?, ?)
            """,
            (session_id, workflow_id, transport, transport_handle, now, now),
        )
    return _row_to_dict(_fetch(conn, session_id))


def get(conn: sqlite3.Connection, session_id: str) -> dict:
    """Return the agent_sessions row as a dict.

    Raises ``ValueError`` if ``session_id`` does not exist.
    """
    return _row_to_dict(_fetch(conn, session_id))


def mark_completed(conn: sqlite3.Connection, session_id: str) -> dict:
    """Transition an ``active`` session to ``completed`` (normal end).

    Returns ``{"row": <current row>, "transitioned": bool}``.
    Idempotent when the session is already ``completed``; raises
    ``ValueError`` on an unknown session or an invalid cross-terminal
    move.
    """
    return _transition(conn, session_id, "completed")


def mark_dead(conn: sqlite3.Connection, session_id: str) -> dict:
    """Transition an ``active`` session to ``dead`` (crash/irrecoverable).

    Same idempotency and error semantics as :func:`mark_completed`.
    """
    return _transition(conn, session_id, "dead")


def mark_orphaned(conn: sqlite3.Connection, session_id: str) -> dict:
    """Transition an ``active`` session to ``orphaned`` (session lost).

    Same idempotency and error semantics as :func:`mark_completed`.
    """
    return _transition(conn, session_id, "orphaned")


def list_active(
    conn: sqlite3.Connection,
    workflow_id: Optional[str] = None,
) -> list[dict]:
    """Return every active session, ordered by ``created_at``.

    When ``workflow_id`` is provided, rows are filtered to that exact
    workflow binding.  ``None`` returns every active session
    regardless of workflow.
    """
    if workflow_id is None:
        rows = conn.execute(
            """
            SELECT * FROM agent_sessions
            WHERE  status = 'active'
            ORDER  BY created_at
            """,
        ).fetchall()
    else:
        rows = conn.execute(
            """
            SELECT * FROM agent_sessions
            WHERE  status = 'active' AND workflow_id = ?
            ORDER  BY created_at
            """,
            (workflow_id,),
        ).fetchall()
    return [_row_to_dict(r) for r in rows]
