"""Runtime-owned dispatch attempt domain authority.

Owns the ``dispatch_attempts`` table introduced in Phase 2b
(DEC-CLAUDEX-SUPERVISION-DOMAIN-001).

A dispatch attempt represents one issued instruction to a specific seat,
with full delivery claim, acknowledgment, retry, and timeout state.  This
table is the sole runtime authority for "was the instruction delivered?" —
replacing queue-file timestamps, sentinel echoes, and pane-text heuristics
once transport adapters are wired in a later slice.

Authority scope
---------------
- **This module** owns every state transition on ``dispatch_attempts``.
- ``dispatch.py`` owns ``dispatch_queue`` / ``dispatch_cycles`` (legacy,
  non-authoritative for routing — DEC-WS6-001).  These are orthogonal tables
  for orthogonal domains; there is no shared state between them.
- No adapter code (tmux, MCP, watchdog) belongs here.  Adapters call
  ``claim()`` after physical delivery; they may not read or write any other
  column directly.

State machine
-------------
::

    issue()
      └─► pending
              │
              ├─ claim()        ─► delivered
              │                         │
              │                         ├─ acknowledge() ─► acknowledged  (terminal)
              │                         ├─ fail()        ─► failed
              │                         └─ timeout()     ─► timed_out
              │
              ├─ cancel()       ─► cancelled             (terminal)
              ├─ fail()         ─► failed
              └─ timeout()      ─► timed_out

    retry()   [from timed_out | failed]  ─► pending  (+retry_count)

Terminal states: ``acknowledged``, ``cancelled``.
``failed`` and ``timed_out`` may be retried indefinitely by callers.

@decision DEC-CLAUDEX-SUPERVISION-DOMAIN-001
Title: dispatch_attempts domain helper is the sole authority for delivery
       claim/ack/timeout/retry state
Status: accepted
Rationale: CUTOVER_PLAN §Phase 2b exit criterion — "a queued instruction is
  not considered healthy until a transport adapter records delivery claim in
  canonical runtime state". This module provides the claim/ack surface so
  adapters can satisfy that criterion without inventing a parallel authority.
  All state transitions go through this module.  Callers that need to inspect
  delivery health use ``get()`` or ``list_for_seat()`` — never raw SQL.
"""

from __future__ import annotations

import sqlite3
import time
import uuid
from typing import Optional

from runtime.schemas import DISPATCH_ATTEMPT_STATUSES

__all__ = [
    "issue",
    "claim",
    "acknowledge",
    "fail",
    "cancel",
    "timeout",
    "retry",
    "get",
    "list_for_seat",
    "expire_stale",
]

# ---------------------------------------------------------------------------
# Valid transitions: {from_status: frozenset_of_valid_to_statuses}
# Used by _transition() to reject illegal moves.
# ---------------------------------------------------------------------------

_VALID_TRANSITIONS: dict[str, frozenset[str]] = {
    "pending":      frozenset({"delivered", "cancelled", "failed", "timed_out"}),
    "delivered":    frozenset({"acknowledged", "failed", "timed_out"}),
    "timed_out":    frozenset({"pending"}),
    "failed":       frozenset({"pending"}),
    # Terminal — no transitions out.
    "acknowledged": frozenset(),
    "cancelled":    frozenset(),
}


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _now() -> int:
    return int(time.time())


def _row_to_dict(row: sqlite3.Row) -> dict:
    return dict(row)


def _transition(
    conn: sqlite3.Connection,
    attempt_id: str,
    to_status: str,
    extra_sets: Optional[dict] = None,
) -> dict:
    """Apply a validated status transition on a single attempt.

    Raises ``ValueError`` if the current status does not permit ``to_status``.
    Returns the updated row as a dict.
    """
    row = conn.execute(
        "SELECT * FROM dispatch_attempts WHERE attempt_id = ?",
        (attempt_id,),
    ).fetchone()
    if row is None:
        raise ValueError(f"dispatch_attempts: attempt_id not found: {attempt_id!r}")

    current = row["status"]
    allowed = _VALID_TRANSITIONS.get(current, frozenset())
    if to_status not in allowed:
        raise ValueError(
            f"dispatch_attempts: invalid transition {current!r} → {to_status!r} "
            f"for attempt {attempt_id!r}"
        )

    now = _now()
    set_clauses = ["status = ?", "updated_at = ?"]
    params: list = [to_status, now]

    if extra_sets:
        for col, val in extra_sets.items():
            set_clauses.append(f"{col} = ?")
            params.append(val)

    params.append(attempt_id)
    sql = f"UPDATE dispatch_attempts SET {', '.join(set_clauses)} WHERE attempt_id = ?"
    with conn:
        conn.execute(sql, params)

    updated = conn.execute(
        "SELECT * FROM dispatch_attempts WHERE attempt_id = ?", (attempt_id,)
    ).fetchone()
    return _row_to_dict(updated)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def issue(
    conn: sqlite3.Connection,
    seat_id: str,
    instruction: str,
    *,
    workflow_id: Optional[str] = None,
    work_item_id: str = "",
    goal_id: str = "",
    stage_id: str = "",
    decision_scope: str = "",
    parent_session_id: str = "",
    parent_agent_id: str = "",
    requested_role: str = "",
    target_project_root: str = "",
    worktree_path: str = "",
    prompt_pack_id: str = "",
    contract_json: str = "{}",
    tool_use_id: str = "",
    hook_invocation_id: str = "",
    lease_id: str = "",
    timeout_at: Optional[int] = None,
) -> dict:
    """Issue a new pending dispatch attempt for ``seat_id``.

    Parameters
    ----------
    conn:
        Open SQLite connection with the supervision schema present.
    seat_id:
        The seat that should receive the instruction.
    instruction:
        Free-form instruction content (text or JSON string).
    workflow_id:
        Optional workflow binding for diagnostic queries.
    timeout_at:
        Unix timestamp after which the attempt should be marked timed_out by
        ``expire_stale()``.  ``None`` means no automatic expiry.

    Returns
    -------
    dict
        The newly created attempt row.
    """
    attempt_id = uuid.uuid4().hex
    now = _now()
    with conn:
        conn.execute(
            """
            INSERT INTO dispatch_attempts (
                attempt_id, seat_id, workflow_id, work_item_id, goal_id,
                stage_id, decision_scope, parent_session_id, parent_agent_id,
                requested_role, target_project_root, worktree_path,
                prompt_pack_id, contract_json, tool_use_id, hook_invocation_id,
                lease_id, instruction,
                status, retry_count, timeout_at,
                created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                      'pending', 0, ?, ?, ?)
            """,
            (
                attempt_id,
                seat_id,
                workflow_id,
                work_item_id,
                goal_id,
                stage_id,
                decision_scope,
                parent_session_id,
                parent_agent_id,
                requested_role,
                target_project_root,
                worktree_path,
                prompt_pack_id,
                contract_json,
                tool_use_id,
                hook_invocation_id,
                lease_id,
                instruction,
                timeout_at,
                now,
                now,
            ),
        )
    return get(conn, attempt_id)


def claim(
    conn: sqlite3.Connection,
    attempt_id: str,
    *,
    child_session_id: str = "",
    child_agent_id: str = "",
) -> dict:
    """Record that a transport adapter has delivered the instruction.

    Transitions: ``pending`` → ``delivered``.

    This is the signal that the physical delivery has been claimed by the
    transport layer.  It does not mean the agent has processed the instruction.
    """
    extra = {"delivery_claimed_at": _now(), "claimed_at": _now()}
    if child_session_id:
        extra["child_session_id"] = child_session_id
    if child_agent_id:
        extra["child_agent_id"] = child_agent_id
    return _transition(
        conn,
        attempt_id,
        "delivered",
        extra_sets=extra,
    )


def acknowledge(conn: sqlite3.Connection, attempt_id: str) -> dict:
    """Record that the agent has confirmed receipt of the instruction.

    Transitions: ``delivered`` → ``acknowledged``  (terminal).
    """
    return _transition(
        conn,
        attempt_id,
        "acknowledged",
        extra_sets={"acknowledged_at": _now()},
    )


def fail(conn: sqlite3.Connection, attempt_id: str, *, reason: str = "") -> dict:
    """Mark the attempt as failed due to a delivery or compile error.

    Transitions: ``pending`` or ``delivered`` → ``failed``.

    Callers that wish to retry should call ``retry()`` after inspecting the
    stored failure reason.
    """
    extra: dict[str, object] = {"closed_at": _now()}
    if reason:
        extra["failure_reason"] = reason
    return _transition(conn, attempt_id, "failed", extra_sets=extra)


def cancel(conn: sqlite3.Connection, attempt_id: str) -> dict:
    """Cancel a pending attempt before it is delivered.

    Transitions: ``pending`` → ``cancelled``  (terminal).
    """
    return _transition(conn, attempt_id, "cancelled")


def timeout(conn: sqlite3.Connection, attempt_id: str) -> dict:
    """Mark an individual attempt as timed out.

    Transitions: ``pending`` or ``delivered`` → ``timed_out``.

    For batch expiry of all stale attempts, use ``expire_stale()``.
    """
    return _transition(conn, attempt_id, "timed_out")


def retry(conn: sqlite3.Connection, attempt_id: str) -> dict:
    """Reset a timed-out or failed attempt back to pending for re-delivery.

    Transitions: ``timed_out`` or ``failed`` → ``pending``.

    ``retry_count`` is incremented and ``delivery_claimed_at`` is cleared so
    the next ``claim()`` call correctly timestamps the new delivery attempt.
    """
    row = conn.execute(
        "SELECT retry_count FROM dispatch_attempts WHERE attempt_id = ?",
        (attempt_id,),
    ).fetchone()
    if row is None:
        raise ValueError(f"dispatch_attempts: attempt_id not found: {attempt_id!r}")
    new_count = (row["retry_count"] or 0) + 1

    return _transition(
        conn,
        attempt_id,
        "pending",
        extra_sets={"retry_count": new_count, "delivery_claimed_at": None},
    )


def get(conn: sqlite3.Connection, attempt_id: str) -> Optional[dict]:
    """Fetch one attempt by ``attempt_id``.  Returns ``None`` if not found."""
    row = conn.execute(
        "SELECT * FROM dispatch_attempts WHERE attempt_id = ?",
        (attempt_id,),
    ).fetchone()
    return _row_to_dict(row) if row else None


def list_for_seat(
    conn: sqlite3.Connection,
    seat_id: str,
    *,
    status: Optional[str] = None,
) -> list[dict]:
    """Return all attempts for ``seat_id``, optionally filtered by ``status``.

    Ordered oldest-first (by ``created_at``).
    """
    if status is not None and status not in DISPATCH_ATTEMPT_STATUSES:
        raise ValueError(
            f"dispatch_attempts: unknown status {status!r}. "
            f"Valid: {sorted(DISPATCH_ATTEMPT_STATUSES)}"
        )
    if status is not None:
        rows = conn.execute(
            """
            SELECT * FROM dispatch_attempts
            WHERE  seat_id = ? AND status = ?
            ORDER  BY created_at ASC
            """,
            (seat_id, status),
        ).fetchall()
    else:
        rows = conn.execute(
            """
            SELECT * FROM dispatch_attempts
            WHERE  seat_id = ?
            ORDER  BY created_at ASC
            """,
            (seat_id,),
        ).fetchall()
    return [_row_to_dict(r) for r in rows]


def expire_stale(
    conn: sqlite3.Connection,
    *,
    fallback_pending_max_age_seconds: int | None = None,
) -> int:
    """Sweep for attempts whose ``timeout_at`` has elapsed and mark them ``timed_out``.

    Only ``pending`` and ``delivered`` attempts are eligible — terminal and
    already-timed-out attempts are left untouched.

    Optional legacy hygiene mode:
    - when ``fallback_pending_max_age_seconds`` is provided, ``pending`` rows
      with ``timeout_at IS NULL`` and ``created_at`` older than the fallback
      age are also transitioned to ``timed_out``. This is used to clean up
      older attempt rows created before timeout discipline was enforced.

    Returns the number of attempts expired.
    """
    now = _now()
    expired = 0
    with conn:
        cur = conn.execute(
            """
            UPDATE dispatch_attempts
            SET    status     = 'timed_out',
                   updated_at = ?
            WHERE  status   IN ('pending', 'delivered')
              AND  timeout_at IS NOT NULL
              AND  timeout_at <= ?
            """,
            (now, now),
        )
        expired += cur.rowcount

        if (
            fallback_pending_max_age_seconds is not None
            and fallback_pending_max_age_seconds > 0
        ):
            cutoff = now - int(fallback_pending_max_age_seconds)
            cur2 = conn.execute(
                """
                UPDATE dispatch_attempts
                SET    status     = 'timed_out',
                       updated_at = ?
                WHERE  status     = 'pending'
                  AND  timeout_at IS NULL
                  AND  created_at <= ?
                """,
                (now, cutoff),
            )
            expired += cur2.rowcount
    return expired
