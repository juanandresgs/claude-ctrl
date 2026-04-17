"""Runtime-owned supervision-thread domain authority.

Owns the ``supervision_threads`` table seeded in Phase 2b Slice 7
(``DEC-CLAUDEX-SUPERVISION-DOMAIN-001``).  This module is the
runtime-owned answer to CUTOVER_PLAN Target Architecture §2a design rule 4:

    Recursive supervision is represented explicitly as a relationship
    between seats.  "Open an attached analysis thread on the running
    worker" is therefore a first-class runtime action, not a
    special-case bridge trick.

Until now the `supervision_threads` table existed but had no domain
module — meaning every real "attach / detach" happened via bridge
diagnostics (tmux panes, relay sentinels) that §2a rule 3 explicitly
forbids from being authoritative.  This module closes that gap.

Authority scope
---------------
- **This module** owns every state transition on
  ``supervision_threads`` rows.
- It consumes ``seats.seat_id`` values as FK references; it does not
  write to ``seats`` or ``agent_sessions``.
- Adapters (tmux, MCP, watchdog) do not belong here.  They may call
  :func:`attach` / :func:`detach` after physical actions; they do not
  read or write any other column directly.

State machine
-------------
::

    attach()
      └─► active
              │
              ├─ detach()    ─► completed   (normal end)
              └─ abandon()   ─► abandoned   (supervisor seat died)

Terminal states: ``completed``, ``abandoned``.  Both are final; a
thread marked ``completed`` or ``abandoned`` cannot be re-activated.
A fresh relationship requires a new :func:`attach` call.

Status + type vocabulary comes from ``runtime.schemas`` — this module
imports ``SUPERVISION_THREAD_STATUSES`` and
``SUPERVISION_THREAD_TYPES`` as the sole vocabulary authority and
does not invent new values.

@decision DEC-SUPERVISION-THREADS-DOMAIN-001
@title supervision_threads promoted to runtime-owned domain module
@status accepted
@rationale Phase 2b §2a (DEC-CLAUDEX-SUPERVISION-DOMAIN-001) seeded
  the supervision_threads table but never promoted it to a domain.
  Three of four §2a supervision primitives (agent_session, seat,
  dispatch_attempt) have runtime authorities and CLI exposure;
  supervision_thread did not until this slice.  The empty domain
  meant "open an attached analysis thread on the running worker"
  had to live in bridge diagnostics.  This module gives the runtime
  a first-class API so CUTOVER §2a rule 4 is mechanically reachable
  from ``cc-policy``.  Post-Phase-8 continuation under closed
  Phase 2b scope; no new phase opened.
"""

from __future__ import annotations

import sqlite3
import time
import uuid
from typing import Optional

from runtime.schemas import (
    SUPERVISION_THREAD_STATUSES,
    SUPERVISION_THREAD_TYPES,
)


# ---------------------------------------------------------------------------
# State machine
# ---------------------------------------------------------------------------

_VALID_TRANSITIONS: dict[str, frozenset[str]] = {
    "active":    frozenset({"completed", "abandoned"}),
    # Terminal — no transitions out.
    "completed": frozenset(),
    "abandoned": frozenset(),
}


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _now() -> int:
    return int(time.time())


def _row_to_dict(row: sqlite3.Row) -> dict:
    return dict(row)


def _require_status(status: str) -> None:
    if status not in SUPERVISION_THREAD_STATUSES:
        raise ValueError(
            f"supervision_threads: invalid status {status!r}; "
            f"allowed: {sorted(SUPERVISION_THREAD_STATUSES)}"
        )


def _require_thread_type(thread_type: str) -> None:
    if thread_type not in SUPERVISION_THREAD_TYPES:
        raise ValueError(
            f"supervision_threads: invalid thread_type {thread_type!r}; "
            f"allowed: {sorted(SUPERVISION_THREAD_TYPES)}"
        )


def _transition(
    conn: sqlite3.Connection,
    thread_id: str,
    to_status: str,
) -> dict:
    """Apply a validated status transition on a single thread.

    Raises ``ValueError`` if the current status does not permit
    ``to_status`` or the thread doesn't exist.  Returns the updated
    row as a dict.
    """
    _require_status(to_status)
    row = conn.execute(
        "SELECT * FROM supervision_threads WHERE thread_id = ?",
        (thread_id,),
    ).fetchone()
    if row is None:
        raise ValueError(
            f"supervision_threads: thread_id not found: {thread_id!r}"
        )

    current = row["status"]
    allowed = _VALID_TRANSITIONS.get(current, frozenset())
    if to_status not in allowed:
        raise ValueError(
            f"supervision_threads: invalid transition {current!r} → "
            f"{to_status!r} for thread {thread_id!r}"
        )

    now = _now()
    with conn:
        conn.execute(
            """
            UPDATE supervision_threads
            SET    status = ?, updated_at = ?
            WHERE  thread_id = ?
            """,
            (to_status, now, thread_id),
        )
    return get(conn, thread_id)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def attach(
    conn: sqlite3.Connection,
    supervisor_seat_id: str,
    worker_seat_id: str,
    thread_type: str,
) -> dict:
    """Create a new ``active`` supervision_thread row.

    Parameters
    ----------
    conn:
        Open SQLite connection with the supervision schema present.
    supervisor_seat_id:
        ``seats.seat_id`` of the steering / auditing seat.
    worker_seat_id:
        ``seats.seat_id`` of the seat being steered / audited.
    thread_type:
        Kind of supervision relationship.  Must be a member of
        ``SUPERVISION_THREAD_TYPES``.

    Returns
    -------
    dict
        The newly created thread row.

    Raises
    ------
    ValueError
        if ``thread_type`` is not in the declared vocabulary, or if
        ``supervisor_seat_id == worker_seat_id`` (a seat cannot
        supervise itself), or if either seat_id is empty.
    sqlite3.IntegrityError
        if either ``seat_id`` does not exist (FK enforced by
        SQLite when ``PRAGMA foreign_keys=ON`` is set; callers who
        depend on rejection must set it).
    """
    _require_thread_type(thread_type)
    if not supervisor_seat_id:
        raise ValueError("supervision_threads: supervisor_seat_id must be non-empty")
    if not worker_seat_id:
        raise ValueError("supervision_threads: worker_seat_id must be non-empty")
    if supervisor_seat_id == worker_seat_id:
        raise ValueError(
            "supervision_threads: a seat cannot supervise itself "
            f"(seat_id={supervisor_seat_id!r})"
        )

    thread_id = uuid.uuid4().hex
    now = _now()
    with conn:
        conn.execute(
            """
            INSERT INTO supervision_threads (
                thread_id, supervisor_seat_id, worker_seat_id,
                thread_type, status, created_at, updated_at
            ) VALUES (?, ?, ?, ?, 'active', ?, ?)
            """,
            (thread_id, supervisor_seat_id, worker_seat_id, thread_type, now, now),
        )
    return get(conn, thread_id)


def detach(conn: sqlite3.Connection, thread_id: str) -> dict:
    """Transition an ``active`` thread to ``completed`` (normal end).

    Raises ``ValueError`` if the thread is unknown or not ``active``.
    """
    return _transition(conn, thread_id, "completed")


def abandon(conn: sqlite3.Connection, thread_id: str) -> dict:
    """Transition an ``active`` thread to ``abandoned`` (supervisor died).

    Raises ``ValueError`` if the thread is unknown or not ``active``.
    """
    return _transition(conn, thread_id, "abandoned")


def get(conn: sqlite3.Connection, thread_id: str) -> dict:
    """Return the supervision_thread row as a dict.

    Raises ``ValueError`` if ``thread_id`` does not exist.
    """
    row = conn.execute(
        "SELECT * FROM supervision_threads WHERE thread_id = ?",
        (thread_id,),
    ).fetchone()
    if row is None:
        raise ValueError(
            f"supervision_threads: thread_id not found: {thread_id!r}"
        )
    return _row_to_dict(row)


def list_for_supervisor(
    conn: sqlite3.Connection,
    supervisor_seat_id: str,
    *,
    status: Optional[str] = None,
) -> list[dict]:
    """Return every thread whose ``supervisor_seat_id`` matches.

    When ``status`` is provided, rows are filtered to that exact
    status.  Otherwise all statuses are returned.
    """
    if status is not None:
        _require_status(status)
        rows = conn.execute(
            """
            SELECT * FROM supervision_threads
            WHERE  supervisor_seat_id = ? AND status = ?
            ORDER  BY created_at
            """,
            (supervisor_seat_id, status),
        ).fetchall()
    else:
        rows = conn.execute(
            """
            SELECT * FROM supervision_threads
            WHERE  supervisor_seat_id = ?
            ORDER  BY created_at
            """,
            (supervisor_seat_id,),
        ).fetchall()
    return [_row_to_dict(r) for r in rows]


def list_for_worker(
    conn: sqlite3.Connection,
    worker_seat_id: str,
    *,
    status: Optional[str] = None,
) -> list[dict]:
    """Return every thread whose ``worker_seat_id`` matches.

    When ``status`` is provided, rows are filtered to that exact
    status.  Otherwise all statuses are returned.
    """
    if status is not None:
        _require_status(status)
        rows = conn.execute(
            """
            SELECT * FROM supervision_threads
            WHERE  worker_seat_id = ? AND status = ?
            ORDER  BY created_at
            """,
            (worker_seat_id, status),
        ).fetchall()
    else:
        rows = conn.execute(
            """
            SELECT * FROM supervision_threads
            WHERE  worker_seat_id = ?
            ORDER  BY created_at
            """,
            (worker_seat_id,),
        ).fetchall()
    return [_row_to_dict(r) for r in rows]


def list_active(conn: sqlite3.Connection) -> list[dict]:
    """Return every thread with ``status == 'active'`` in created_at order."""
    rows = conn.execute(
        """
        SELECT * FROM supervision_threads
        WHERE  status = 'active'
        ORDER  BY created_at
        """,
    ).fetchall()
    return [_row_to_dict(r) for r in rows]
