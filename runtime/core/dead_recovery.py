"""Runtime-owned dead-loop / silent-death recovery sweeper.

The SubagentStop adapter chain (landed at ``3967f6d``) handles the
normal seat-teardown case by invoking ``dispatch seat-release`` when
a subagent's stop event fires.  When the event never fires — silent
crash, transport drop, host process kill — the stop-hook path is
never walked and the supervision fabric accumulates stale ``active``
rows:

- the ``dispatch_attempts`` row eventually becomes ``timed_out`` via
  ``dispatch_attempts.expire_stale`` (authored by the watchdog),
- but the owning ``seat`` stays ``active``,
- the ``agent_session`` stays ``active``,
- every ``supervision_thread`` touching the seat stays ``active``.

This module is the runtime-owned answer.  It is *not* a stop-hook
recurrence — every transition here is authored by the runtime
control plane, invoked by the watchdog sweep, and delegated to the
owning domain modules.  No raw SQL against ``agent_sessions`` /
``seats`` / ``supervision_threads`` — the Rule-1 authority-writer
invariant (``tests/runtime/test_authority_table_writers.py``) stays
green without extending its allowlist.

Authority scope
---------------
- **This module** chooses *which* rows to transition and *when* they
  are eligible.  It does not implement transitions itself.
- Each transition is delegated to its owning domain module:
  ``seats.mark_dead``, ``supervision_threads.abandon_for_seat``,
  ``agent_sessions.mark_dead`` / ``mark_completed``.
- Grace-window policy lives here as a module-level constant so a
  reviewer can tune it without hunting through call sites.

@decision DEC-DEAD-RECOVERY-001
@title Runtime-owned dead/orphan sweeper for §2a seat and session
@status accepted
@rationale The SubagentStop adapter chain cannot recover from silent
  crashes because no stop event fires.  Relying on hook recursion to
  retry would re-introduce the dual-authority anti-pattern §2a rule 3
  exists to prevent.  This module moves the decision "is this seat /
  session dead?" into the runtime, invoked by the existing watchdog
  sweep, with delegation to the four §2a domain modules.  Post-
  Phase-8 continuation under the closed Phase 2b scope; no new phase.
"""

from __future__ import annotations

import sqlite3
import time

from runtime.core import agent_sessions as _as
from runtime.core import seats as _seats
from runtime.core import supervision_threads as _sup


__all__ = [
    "DEFAULT_GRACE_SECONDS",
    "sweep_dead_seats",
    "sweep_dead_sessions",
    "sweep_all",
]


# ---------------------------------------------------------------------------
# Tuning
# ---------------------------------------------------------------------------
#
# A seat's attempt must have been terminal (timed_out / failed) for at
# least this many seconds before the sweeper considers the seat dead.
# The default is deliberately generous so a slow adapter that terminates
# the attempt but has not yet emitted a SubagentStop event does not get
# its seat marked dead prematurely.  Re-litigable from one place.
#
# 900 seconds (15 minutes) = ~2× the default dispatch timeout window.
DEFAULT_GRACE_SECONDS: int = 900


# Attempt statuses that mean "this seat is no longer working and will
# not recover through the normal ack/claim path".  We deliberately
# exclude ``cancelled`` because a cancel can be a user-driven early
# termination that still warrants a SubagentStop arrival.
_DEAD_ATTEMPT_STATUSES: frozenset[str] = frozenset({"timed_out", "failed"})


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _now() -> int:
    return int(time.time())


def _eligible_dead_seat_ids(
    conn: sqlite3.Connection,
    *,
    grace_seconds: int,
    now: int,
) -> list[str]:
    """Return the seat_ids whose **most recent** dispatch_attempt is past grace.

    Selection rules:

    1. ``seats.status = 'active'`` — we only sweep seats that are still
       in the lifecycle.  ``released`` and ``dead`` are skipped.
    2. The seat has at least one ``dispatch_attempts`` row.
    3. The attempt with the most recent *delivery activity* for the
       seat — ordered by ``updated_at DESC, attempt_id DESC`` for a
       deterministic tiebreak on same-second transitions — must be
       in ``_DEAD_ATTEMPT_STATUSES`` (``timed_out`` / ``failed``) and
       its ``updated_at`` must be older than ``now - grace_seconds``.

    Eligibility is keyed off the *latest transitioned* attempt, not
    merely the latest-created row.  ``dispatch_attempts.retry()``
    reuses the same row — it updates ``status`` / ``updated_at`` /
    ``retry_count`` but leaves ``created_at`` fixed — so a retried
    attempt can finish later (newer ``updated_at``) than a
    subsequently-issued attempt (newer ``created_at``).  Ordering by
    ``updated_at`` correctly treats that retried row as the seat's
    current delivery effort.

    The mixed-history case from the earlier correction
    (``c400245``) still holds under ``updated_at`` ordering: an old
    ``timed_out`` followed by a newer ``cancelled`` attempt leaves
    ``cancelled`` with the newest ``updated_at``, so the seat is
    still not swept.  The retry regression (this correction) and the
    mixed-history regression therefore share the same selector —
    they disagree only on which ordering key is authoritative, and
    ``updated_at`` satisfies both.
    """
    cutoff = now - int(grace_seconds)
    dead_statuses_placeholder = ",".join("?" for _ in _DEAD_ATTEMPT_STATUSES)

    sql = f"""
        SELECT s.seat_id
        FROM   seats s
        WHERE  s.status = 'active'
          AND  EXISTS (
                SELECT 1 FROM dispatch_attempts da
                WHERE  da.attempt_id = (
                        SELECT attempt_id FROM dispatch_attempts da2
                        WHERE  da2.seat_id = s.seat_id
                        ORDER  BY da2.updated_at DESC, da2.attempt_id DESC
                        LIMIT  1
                )
                  AND  da.status IN ({dead_statuses_placeholder})
                  AND  da.updated_at < ?
          )
        ORDER  BY s.seat_id
    """
    params = tuple(sorted(_DEAD_ATTEMPT_STATUSES)) + (cutoff,)
    rows = conn.execute(sql, params).fetchall()
    return [r["seat_id"] for r in rows]


def _session_seat_summary(
    conn: sqlite3.Connection,
    session_id: str,
) -> dict:
    """Return aggregate seat-status counts for one session."""
    rows = conn.execute(
        """
        SELECT status, COUNT(*) AS n
        FROM   seats
        WHERE  session_id = ?
        GROUP  BY status
        """,
        (session_id,),
    ).fetchall()
    counts = {r["status"]: r["n"] for r in rows}
    return {
        "total": sum(counts.values()),
        "active": counts.get("active", 0),
        "released": counts.get("released", 0),
        "dead": counts.get("dead", 0),
    }


def _eligible_terminal_session_ids(conn: sqlite3.Connection) -> list[str]:
    """Return active agent_session ids whose every seat is terminal.

    A session is eligible when:

    1. ``agent_sessions.status = 'active'``.
    2. The session has at least one seat (a session with zero seats is
       fresh and not yet a candidate for recovery).
    3. Every seat for the session is in ``{'released', 'dead'}``.
    """
    rows = conn.execute(
        """
        SELECT a.session_id
        FROM   agent_sessions a
        WHERE  a.status = 'active'
          AND  EXISTS (
                SELECT 1 FROM seats s WHERE s.session_id = a.session_id
          )
          AND  NOT EXISTS (
                SELECT 1 FROM seats s
                WHERE  s.session_id = a.session_id
                  AND  s.status = 'active'
          )
        ORDER  BY a.session_id
        """,
    ).fetchall()
    return [r["session_id"] for r in rows]


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def sweep_dead_seats(
    conn: sqlite3.Connection,
    *,
    grace_seconds: int = DEFAULT_GRACE_SECONDS,
    now: int | None = None,
) -> dict:
    """Mark every eligible active seat as dead and abandon its threads.

    Returns ``{"swept": int, "seats": [seat_id, ...],
               "abandoned_threads": int}``.  The three fields are
    independently useful for telemetry: ``swept`` counts seats whose
    status actually flipped (idempotent no-op seats do not count),
    ``seats`` is the ordered list of affected seat_ids, and
    ``abandoned_threads`` aggregates every supervision_thread row this
    call transitioned from active to abandoned.

    ``grace_seconds`` is the minimum age a terminal attempt must have
    before its seat is swept — defaults to
    :data:`DEFAULT_GRACE_SECONDS` (900).  ``now`` is injectable for
    deterministic tests; when ``None`` the module reads
    ``int(time.time())``.
    """
    if grace_seconds < 0:
        raise ValueError("dead_recovery: grace_seconds must be >= 0")
    effective_now = _now() if now is None else int(now)

    seat_ids = _eligible_dead_seat_ids(
        conn, grace_seconds=grace_seconds, now=effective_now
    )

    swept = 0
    abandoned = 0
    acted_seat_ids: list[str] = []
    for seat_id in seat_ids:
        # Delegate the transition to the seat domain.  Idempotent — if
        # something else flipped the seat between query and write we
        # get transitioned=False and do not double-count.
        result = _seats.mark_dead(conn, seat_id)
        if result["transitioned"]:
            swept += 1
            acted_seat_ids.append(seat_id)
        # Cascade supervision_threads regardless of whether *this*
        # call flipped the seat — it is idempotent on already-
        # abandoned rows.  Ensures threads close whenever a seat is
        # dead, even if the transition happened concurrently.
        abandoned += _sup.abandon_for_seat(conn, seat_id)

    return {
        "swept": swept,
        "seats": acted_seat_ids,
        "abandoned_threads": abandoned,
    }


def sweep_dead_sessions(conn: sqlite3.Connection) -> dict:
    """Transition sessions with every-seat-terminal to the right terminal.

    If any seat of the session is ``dead``, the session transitions to
    ``dead``.  Otherwise (every seat is ``released``) the session
    transitions to ``completed`` — the normal end.

    Returns ``{"swept": int, "completed": [session_id, ...],
               "dead": [session_id, ...]}``.  ``swept`` is the sum of
    transitions this call authored; the two lists are the per-status
    breakdown.
    """
    session_ids = _eligible_terminal_session_ids(conn)

    completed_ids: list[str] = []
    dead_ids: list[str] = []
    for session_id in session_ids:
        summary = _session_seat_summary(conn, session_id)
        if summary["dead"] > 0:
            result = _as.mark_dead(conn, session_id)
            if result["transitioned"]:
                dead_ids.append(session_id)
        else:
            # Every seat is released and none is dead → normal completion.
            result = _as.mark_completed(conn, session_id)
            if result["transitioned"]:
                completed_ids.append(session_id)

    return {
        "swept": len(completed_ids) + len(dead_ids),
        "completed": completed_ids,
        "dead": dead_ids,
    }


def sweep_all(
    conn: sqlite3.Connection,
    *,
    grace_seconds: int = DEFAULT_GRACE_SECONDS,
    now: int | None = None,
) -> dict:
    """Run :func:`sweep_dead_seats` then :func:`sweep_dead_sessions`.

    Convenience entry point for the watchdog.  Running in that order
    matters — marking seats dead first makes newly-orphaned sessions
    visible to :func:`sweep_dead_sessions` on the same invocation.
    Returns a dict that wraps both sub-results under ``seats`` and
    ``sessions`` keys so a single CLI JSON output carries the full
    telemetry.
    """
    seat_result = sweep_dead_seats(conn, grace_seconds=grace_seconds, now=now)
    session_result = sweep_dead_sessions(conn)
    return {
        "seats": seat_result,
        "sessions": session_result,
    }
