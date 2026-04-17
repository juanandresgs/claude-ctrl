"""Runtime-owned seat domain authority.

Owns the ``seats`` table seeded in Phase 2b Slice 7
(``DEC-CLAUDEX-SUPERVISION-DOMAIN-001``).  This module closes the last
§2a model symmetry gap: ``agent_session`` remains deferred, but
``seat``'s state transitions and query surface now live in a
runtime-owned domain module rather than scattered inline SQL inside
``dispatch_hook.py``.

Authority scope
---------------
- **This module** owns every state transition on ``seats`` rows and
  every lifecycle query (create idempotently, release, mark-dead,
  list-by-session, list-active, get).
- Hook-adapter helpers (``dispatch_hook.ensure_session_and_seat`` and
  ``dispatch_hook.release_session_seat``) are permitted to call into
  this module, but may not write ``seats`` rows directly.  The inline
  ``INSERT OR IGNORE INTO seats`` / ``UPDATE seats`` statements that
  previously lived in ``dispatch_hook.py`` are delegated inward.
- Transport adapters (tmux, MCP, watchdog) never call ``seats.*``
  directly; they go through the hook-adapter helpers per CUTOVER §2a
  rule 3.

State machine
-------------
::

    create()          -> active
      └─ release()    -> released
      └─ mark_dead()  -> dead
                       │
    release()          -> released
      └─ mark_dead()  -> dead

    dead               (terminal)

``dead`` is terminal — a dead seat stays dead.  ``released`` can still
escalate to ``dead`` if its session dies with the seat still in the
released state.  Calling ``release()`` on an already-released seat is
an idempotent no-op (returns ``transitioned=False`` without raising);
calling ``release()`` on a dead seat raises ``ValueError`` because
it is not a legal transition.

Status and role vocabulary come from ``runtime.schemas`` —
``SEAT_STATUSES`` and ``SEAT_ROLES`` are the sole vocabulary authority
and this module never invents new values.

@decision DEC-SEAT-DOMAIN-001
@title seat promoted to runtime-owned domain module
@status accepted
@rationale §2a required every supervision primitive to be a
  runtime-owned domain with state-machine enforcement, query surface,
  and CLI.  Three of four primitives already were; seat was the last
  whose writes lived inside ``dispatch_hook.py``.  This module closes
  that gap with the same structural pattern as
  ``runtime.core.supervision_threads``.  Post-Phase-8 continuation
  under the closed Phase 2b scope; no new phase.
"""

from __future__ import annotations

import sqlite3
import time
from typing import Optional

from runtime.schemas import SEAT_ROLES, SEAT_STATUSES


# ---------------------------------------------------------------------------
# State machine
# ---------------------------------------------------------------------------

_VALID_TRANSITIONS: dict[str, frozenset[str]] = {
    "active": frozenset({"released", "dead"}),
    "released": frozenset({"dead"}),
    # Terminal — no transitions out.
    "dead": frozenset(),
}


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _now() -> int:
    return int(time.time())


def _row_to_dict(row: sqlite3.Row) -> dict:
    return dict(row)


def _require_role(role: str) -> None:
    if role not in SEAT_ROLES:
        raise ValueError(
            f"seats: invalid role {role!r}; allowed: {sorted(SEAT_ROLES)}"
        )


def _require_status(status: str) -> None:
    if status not in SEAT_STATUSES:
        raise ValueError(
            f"seats: invalid status {status!r}; allowed: {sorted(SEAT_STATUSES)}"
        )


def _fetch(conn: sqlite3.Connection, seat_id: str) -> sqlite3.Row:
    row = conn.execute(
        "SELECT * FROM seats WHERE seat_id = ?", (seat_id,)
    ).fetchone()
    if row is None:
        raise ValueError(f"seats: seat_id not found: {seat_id!r}")
    return row


def _transition(
    conn: sqlite3.Connection,
    seat_id: str,
    target: str,
) -> dict:
    """Apply a validated status transition on a single seat.

    Same-status requests (e.g. ``release`` on an already-released seat)
    are treated as idempotent no-ops — the row is returned with
    ``transitioned=False`` and no write is performed.  Invalid
    transitions (e.g. ``release`` on a ``dead`` seat) raise
    ``ValueError``.
    """
    _require_status(target)
    row = _fetch(conn, seat_id)
    current = row["status"]

    if current == target:
        return {"row": _row_to_dict(row), "transitioned": False}

    allowed = _VALID_TRANSITIONS.get(current, frozenset())
    if target not in allowed:
        raise ValueError(
            f"seats: invalid transition {current!r} → {target!r} "
            f"for seat {seat_id!r}"
        )

    now = _now()
    with conn:
        conn.execute(
            "UPDATE seats SET status = ?, updated_at = ? WHERE seat_id = ?",
            (target, now, seat_id),
        )
    updated = _fetch(conn, seat_id)
    return {"row": _row_to_dict(updated), "transitioned": True}


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def create(
    conn: sqlite3.Connection,
    seat_id: str,
    session_id: str,
    role: str,
) -> dict:
    """Idempotently create a seat row, returning the current row.

    Used by hook-adapter bootstrap (``dispatch_hook.ensure_session_and_seat``)
    to guarantee a seat exists for a freshly-arriving dispatch.  If a
    row already exists for ``seat_id`` the existing row is returned
    unchanged; there is no update on the idempotent path.  The role
    vocabulary is validated against ``SEAT_ROLES``.

    Empty ``seat_id`` or ``session_id`` raise ``ValueError``.  The
    ``session_id`` FK is not revalidated here because the hook-adapter
    path upserts the session row immediately before calling this
    helper; direct callers must ensure the session row exists or accept
    the SQLite integrity error.
    """
    if not seat_id:
        raise ValueError("seats: seat_id must be non-empty")
    if not session_id:
        raise ValueError("seats: session_id must be non-empty")
    _require_role(role)

    now = _now()
    with conn:
        conn.execute(
            """
            INSERT OR IGNORE INTO seats
                (seat_id, session_id, role, status, created_at, updated_at)
            VALUES (?, ?, ?, 'active', ?, ?)
            """,
            (seat_id, session_id, role, now, now),
        )
    return _row_to_dict(_fetch(conn, seat_id))


def get(conn: sqlite3.Connection, seat_id: str) -> dict:
    """Return the seat row as a dict. Raises ``ValueError`` if missing."""
    return _row_to_dict(_fetch(conn, seat_id))


def release(conn: sqlite3.Connection, seat_id: str) -> dict:
    """Transition an ``active`` seat to ``released``.

    Returns ``{"row": <current seat row>, "transitioned": bool}``.
    ``transitioned`` is ``True`` when this call performed an
    ``active → released`` write; ``False`` when the seat was already
    ``released`` (idempotent no-op).  Raises ``ValueError`` when the
    seat does not exist or when the seat is ``dead`` (illegal
    transition per ``_VALID_TRANSITIONS``).
    """
    return _transition(conn, seat_id, "released")


def mark_dead(conn: sqlite3.Connection, seat_id: str) -> dict:
    """Transition a seat to ``dead`` (terminal).

    Legal from both ``active`` and ``released``.  Idempotent when the
    seat is already ``dead`` (returns ``transitioned=False``).  Raises
    ``ValueError`` only when the seat does not exist.
    """
    return _transition(conn, seat_id, "dead")


def list_for_session(
    conn: sqlite3.Connection,
    session_id: str,
    *,
    status: Optional[str] = None,
) -> list[dict]:
    """Return every seat whose ``session_id`` matches, ordered by ``created_at``.

    When ``status`` is provided, rows are filtered to that exact
    status.  Raises ``ValueError`` for an empty session_id or an invalid
    status.
    """
    if not session_id:
        raise ValueError("seats: session_id must be non-empty")
    if status is not None:
        _require_status(status)
        rows = conn.execute(
            """
            SELECT * FROM seats
            WHERE  session_id = ? AND status = ?
            ORDER  BY created_at
            """,
            (session_id, status),
        ).fetchall()
    else:
        rows = conn.execute(
            """
            SELECT * FROM seats
            WHERE  session_id = ?
            ORDER  BY created_at
            """,
            (session_id,),
        ).fetchall()
    return [_row_to_dict(r) for r in rows]


def list_active(conn: sqlite3.Connection) -> list[dict]:
    """Return every seat with ``status == 'active'`` in ``created_at`` order."""
    rows = conn.execute(
        """
        SELECT * FROM seats
        WHERE  status = 'active'
        ORDER  BY created_at
        """,
    ).fetchall()
    return [_row_to_dict(r) for r in rows]
