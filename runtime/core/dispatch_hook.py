"""Hook-side helpers for dispatch_attempts wiring.

Called by the PreToolUse Agent runtime carrier effect and by subagent-start.sh
(SubagentStart) to record canonical delivery state in ``dispatch_attempts``
without duplicating logic in shell code.

This module is the thin Python bridge between Claude Code harness events and the
``dispatch_attempts`` domain authority.  All state-machine transitions flow
through ``runtime.core.dispatch_attempts`` via ``runtime.core.claude_code_adapter``.

Authority boundary
------------------
- **This module** owns session/seat bootstrapping and the two hook-to-state-machine
  mappings: PreToolUse:Agent → issue, SubagentStart → claim.
- **``dispatch_attempts``** owns every state transition.
- **``claude_code_adapter``** is the sole transport adapter for this transport.
- **Shell hooks** never write directly to ``dispatch_attempts``.

@decision DEC-CLAUDEX-HOOK-WIRING-001
Title: dispatch_hook.py bridges harness events to dispatch_attempts state machine
Status: accepted
Rationale: Hooks are thin transport adapters; they must not own state transitions
  or session bootstrapping logic directly.  dispatch_hook.py provides two
  functions that map PreToolUse:Agent and SubagentStart to canonical
  attempt-issue and attempt-claim operations, keeping session and seat
  bootstrapping in one place.  PreToolUse Agent calls this module from
  ``cc-policy evaluate`` after policy allow; SubagentStart still reaches it via
  ``cc-policy dispatch attempt-claim``.  Both functions are best-effort: they
  return None on a no-op rather than raising, so tracking failures never block
  dispatch.
"""

from __future__ import annotations

import json
import sqlite3
from typing import Optional

from runtime.core import dispatch_attempts, leases
from runtime.core.claude_code_adapter import ADAPTER

__all__ = [
    "ensure_session_and_seat",
    "record_agent_dispatch",
    "record_subagent_delivery",
    "record_subagent_quarantine",
    "release_session_seat",
]

_SEAT_ID_SEP = ":"


def _seat_id(session_id: str, agent_type: str) -> str:
    """Stable seat_id derived from (session_id, agent_type)."""
    return f"{session_id}{_SEAT_ID_SEP}{agent_type}"


def ensure_session_and_seat(
    conn: sqlite3.Connection,
    session_id: str,
    agent_type: str,
) -> str:
    """Upsert agent_sessions + seats rows for this hook invocation.

    Returns the seat_id.  Both inserts are idempotent — repeated calls for the
    same (session_id, agent_type) are safe.  Rows are created with the
    minimum required fields; callers that need richer session state (e.g. a
    specific workflow_id on agent_sessions) may update rows after this call.

    Transport is always ``'claude_code'`` because this module is part of the
    claude_code adapter slice.

    Authority note — ``seats.role`` vs harness ``agent_type``
    ---------------------------------------------------------
    ``seats.role`` uses the runtime seat-role vocabulary defined in
    ``schemas.SEAT_ROLES``: ``worker``, ``supervisor``, ``reviewer``,
    ``observer``.  Harness ``agent_type`` values (``general-purpose``,
    ``planner``, ``implementer``, …) are a separate transport-side fact.
    Hook-wired seats are always created as ``role='worker'`` because any
    agent receiving a dispatched instruction occupies a worker seat in the
    supervision topology.  The harness identity is preserved in the stable
    ``seat_id`` derivation (``"{session_id}:{agent_type}"``) so the lookup
    correlation is never lost; it is just not written into ``role``.
    """
    # Late imports: both domain modules import only runtime.schemas, so
    # importing them here keeps dispatch_hook's module-level dependency
    # graph unchanged and avoids any circular-import surprise during
    # test collection.
    from runtime.core import agent_sessions as _as
    from runtime.core import seats as _seats

    seat_id = _seat_id(session_id, agent_type)

    # Delegate the agent_sessions write inward to the agent-session
    # domain module (DEC-AGENT-SESSION-DOMAIN-001).  create() is
    # idempotent — if a row already exists for this session_id it is
    # returned unchanged, matching the prior INSERT OR IGNORE
    # semantics exactly (including preservation of any pre-existing
    # workflow_id or transport_handle bound by earlier callers).
    _as.create(conn, session_id, transport="claude_code")

    # Delegate the seats write inward to the seat domain module
    # (DEC-SEAT-DOMAIN-001).  seats.create() is idempotent — if a row
    # already exists for this seat_id it is returned unchanged, matching
    # the prior INSERT OR IGNORE semantics exactly.  External return
    # shape is unchanged: callers still receive the seat_id string.
    _seats.create(conn, seat_id, session_id, "worker")

    return seat_id


def record_agent_dispatch(
    conn: sqlite3.Connection,
    session_id: str,
    agent_type: str,
    instruction: str,
    *,
    workflow_id: Optional[str] = None,
    work_item_id: str = "",
    goal_id: str = "",
    stage_id: str = "",
    decision_scope: str = "",
    parent_agent_id: str = "",
    tool_use_id: str = "",
    target_project_root: str = "",
    contract: Optional[dict] = None,
    timeout_at: Optional[int] = None,
) -> dict:
    """PreToolUse:Agent → issue a pending dispatch_attempts row.

    Called by ``cc-policy evaluate`` when a CLAUDEX_CONTRACT_BLOCK is present
    in an allowed Agent tool prompt.  Upserts ``agent_sessions`` and ``seats``
    on the fly so callers never need to pre-provision these rows for the
    delivery tracking path.

    Parameters
    ----------
    conn:
        Open SQLite connection.
    session_id:
        The orchestrator's session_id as reported in the PreToolUse payload.
    agent_type:
        The ``tool_input.subagent_type`` from the PreToolUse payload.
    instruction:
        Diagnostic label for the attempt.  For claude_code, this is typically
        the ``CLAUDEX_CONTRACT_BLOCK`` line from the prompt (not the full prompt
        body) so the attempt row is queryable without storing a large blob.
    workflow_id:
        Optional workflow binding, extracted from the CLAUDEX_CONTRACT_BLOCK.
    timeout_at:
        Optional Unix timestamp after which the attempt is swept by
        ``expire_stale()``.

    Returns
    -------
    dict
        The newly created attempt row, including ``attempt_id``.
    """
    seat_id = ensure_session_and_seat(conn, session_id, agent_type)
    worktree_path = target_project_root or ""
    branch = ""
    if workflow_id:
        row = conn.execute(
            "SELECT worktree_path, branch FROM workflow_bindings WHERE workflow_id = ? LIMIT 1",
            (workflow_id,),
        ).fetchone()
        if row is not None:
            worktree_path = row["worktree_path"] or worktree_path
            branch = row["branch"] or ""

    lease_id = ""
    lease_role = ""
    if stage_id:
        from runtime.core.authority_registry import lease_role_for_stage

        lease_role = lease_role_for_stage(stage_id) or agent_type
    elif agent_type:
        lease_role = agent_type

    if lease_role and worktree_path:
        requires_eval = stage_id not in {"planner", "reviewer", "guardian:provision"}
        lease = leases.issue(
            conn,
            lease_role,
            worktree_path=worktree_path,
            workflow_id=workflow_id,
            branch=branch,
            requires_eval=requires_eval,
            metadata={
                "dispatch_session_id": session_id,
                "dispatch_agent_type": agent_type,
                "dispatch_stage_id": stage_id,
            },
        )
        if lease:
            lease_id = lease.get("lease_id", "")

    contract_json = json.dumps(contract or {}, sort_keys=True)
    return ADAPTER.dispatch(
        conn,
        seat_id,
        instruction,
        workflow_id=workflow_id,
        work_item_id=work_item_id,
        goal_id=goal_id,
        stage_id=stage_id,
        decision_scope=decision_scope,
        parent_session_id=session_id,
        parent_agent_id=parent_agent_id,
        requested_role=agent_type,
        target_project_root=target_project_root,
        worktree_path=worktree_path,
        contract_json=contract_json,
        tool_use_id=tool_use_id,
        lease_id=lease_id,
        timeout_at=timeout_at,
    )


def record_subagent_delivery(
    conn: sqlite3.Connection,
    session_id: str,
    agent_type: str,
    *,
    attempt_id: str = "",
    child_agent_id: str = "",
) -> Optional[dict]:
    """SubagentStart → claim delivery on the most recent pending attempt.

    Called by ``subagent-start.sh`` **only when the carrier-backed correlation
    path matched** — i.e. only when ``pending_agent_requests`` returned a
    non-empty carrier row for this ``(session_id, agent_type)`` pair.

    **Caller contract (enforced in hook, not here):**
    This function must NOT be called for a bare SubagentStart that produced no
    carrier row.  Without the carrier proof there is no PreToolUse-backed link
    between the SubagentStart and the pending attempt, and claiming it would
    bypass the carrier authority.  The hook gates the call inside the
    ``if [[ -n "$_CARRIER_JSON" ]]`` branch to enforce this.

    Finds the most recently created ``pending`` attempt for the
    (session_id, agent_type) seat and advances it to ``'delivered'``.

    Returns ``None`` if no pending attempt exists — normal no-op for any
    SubagentStart that was not preceded by a ``dispatch attempt-issue`` call.
    Callers must never raise on ``None``; the function is intentionally
    best-effort so delivery tracking never blocks SubagentStart.

    Parameters
    ----------
    conn:
        Open SQLite connection.
    session_id:
        The session_id from the SubagentStart payload (matches the orchestrator
        session that wrote the carrier row in ``pending_agent_requests``).
    agent_type:
        The ``agent_type`` from the SubagentStart payload.

    Returns
    -------
    dict or None
        The updated attempt row at ``'delivered'`` status, or ``None`` if no
        pending attempt was found for this seat.
    """
    if attempt_id:
        row = dispatch_attempts.get(conn, attempt_id)
        if row is None or row.get("status") != "pending":
            return None
        return dispatch_attempts.claim(
            conn,
            attempt_id,
            child_session_id=session_id,
            child_agent_id=child_agent_id,
        )

    seat_id = _seat_id(session_id, agent_type)
    pending = dispatch_attempts.list_for_seat(conn, seat_id, status="pending")
    if not pending:
        return None
    # Legacy fallback only: consume FIFO instead of newest so repeated same-role
    # launches cannot steal a newer carrier.
    attempt_id = pending[0]["attempt_id"]
    return dispatch_attempts.claim(
        conn,
        attempt_id,
        child_session_id=session_id,
        child_agent_id=child_agent_id,
    )


def record_subagent_quarantine(
    conn: sqlite3.Connection,
    session_id: str,
    agent_type: str,
    *,
    reason: str,
    agent_id: str = "",
    project_root: str = "",
    attempt_id: str = "",
) -> dict:
    """Record a terminal quarantine for a SubagentStart contract failure."""
    canonical_type = agent_type or "unknown"
    seat_id = ensure_session_and_seat(conn, session_id or "unknown-session", canonical_type)
    if attempt_id:
        row = dispatch_attempts.get(conn, attempt_id)
        if row is not None and row.get("status") in {"pending", "delivered"}:
            return dispatch_attempts.quarantine(
                conn,
                attempt_id,
                reason=reason,
                child_session_id=session_id,
                child_agent_id=agent_id,
            )
    return dispatch_attempts.quarantine_new(
        conn,
        seat_id,
        f"quarantine:{reason}",
        reason=reason,
        parent_session_id=session_id,
        requested_role=canonical_type,
        target_project_root=project_root,
        child_session_id=session_id,
        child_agent_id=agent_id,
    )


def release_session_seat(
    conn: sqlite3.Connection,
    session_id: str,
    agent_type: str,
) -> dict:
    """Release a seat and abandon every supervision_thread touching it.

    Authoritative runtime path for "this seat is going away".  Used at
    seat-lifecycle teardown to:

    1. Transition the matching ``seats`` row to ``status='released'``.
    2. Close every ``active`` ``supervision_threads`` row where this seat
       is supervisor or worker (via
       :func:`runtime.core.supervision_threads.abandon_for_seat`).

    Both operations are idempotent — repeat calls return ``released=False``
    once the seat has already been released, and the abandon sweep
    returns 0 on a second call because only ``active`` rows are
    transitioned.  If no seat exists for ``(session_id, agent_type)``,
    the function is a no-op and ``found=False`` is returned; this
    matches the best-effort posture the other hook helpers use.

    Parameters
    ----------
    conn:
        Open SQLite connection.
    session_id:
        Orchestrator session_id.
    agent_type:
        Harness agent_type (e.g. ``implementer``, ``reviewer``).  The
        same convention as ``ensure_session_and_seat``.

    Returns
    -------
    dict
        ``{"seat_id": str, "found": bool, "released": bool,
           "abandoned_count": int}``.

        * ``found`` — whether a seat row exists for this pair.
        * ``released`` — whether this call performed the active→released
          transition (``False`` if already released or not found).
        * ``abandoned_count`` — number of supervision_threads rows this
          call transitioned from active to abandoned (0 on repeat or if
          the seat has no threads).
    """
    # Late imports: both domain modules import only runtime.schemas, so
    # importing them here keeps dispatch_hook's top-level dependency
    # graph unchanged and avoids any circular-import surprise.
    from runtime.core import seats as _seats
    from runtime.core import supervision_threads as _sup

    seat_id = _seat_id(session_id, agent_type)

    # Delegate existence-check + release transition inward to the seat
    # domain module (DEC-SEAT-DOMAIN-001).  The hook-adapter wrapper
    # keeps the tolerant best-effort semantics it had before this
    # refactor: missing seat is a no-op (found=False), an already-
    # released seat is a no-op (released=False), and a dead seat is a
    # no-op rather than an exception — seats.release() would refuse the
    # dead→released transition, so we only call it from an 'active'
    # seat to preserve external behavior exactly.
    try:
        row = _seats.get(conn, seat_id)
    except ValueError:
        return {
            "seat_id": seat_id,
            "found": False,
            "released": False,
            "abandoned_count": 0,
        }

    released = False
    if row["status"] == "active":
        result = _seats.release(conn, seat_id)
        released = bool(result["transitioned"])

    abandoned_count = _sup.abandon_for_seat(conn, seat_id)
    return {
        "seat_id": seat_id,
        "found": True,
        "released": released,
        "abandoned_count": abandoned_count,
    }
