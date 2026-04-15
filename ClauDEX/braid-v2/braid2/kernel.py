from __future__ import annotations

import json
import sqlite3
import time
from typing import Any

from .ids import make_id
from .observation import detect_interaction_gate, summarize_text


def now_ts() -> int:
    return int(time.time())


def _fetchone(conn: sqlite3.Connection, sql: str, params: tuple[Any, ...] = ()) -> dict | None:
    row = conn.execute(sql, params).fetchone()
    return dict(row) if row is not None else None


def _fetchall(conn: sqlite3.Connection, sql: str, params: tuple[Any, ...] = ()) -> list[dict]:
    return [dict(row) for row in conn.execute(sql, params).fetchall()]


def _require(row: dict | None, entity: str, entity_id: str) -> dict:
    if row is None:
        raise ValueError(f"{entity} not found: {entity_id}")
    return row


def get_bundle(conn: sqlite3.Connection, bundle_id: str) -> dict | None:
    return _fetchone(conn, "SELECT * FROM loop_bundles WHERE bundle_id = ?", (bundle_id,))


def get_session(conn: sqlite3.Connection, session_id: str) -> dict | None:
    return _fetchone(conn, "SELECT * FROM agent_sessions WHERE session_id = ?", (session_id,))


def get_seat(conn: sqlite3.Connection, seat_id: str) -> dict | None:
    return _fetchone(conn, "SELECT * FROM seats WHERE seat_id = ?", (seat_id,))


def get_thread(conn: sqlite3.Connection, thread_id: str) -> dict | None:
    return _fetchone(conn, "SELECT * FROM supervision_threads WHERE thread_id = ?", (thread_id,))


def get_dispatch_attempt(conn: sqlite3.Connection, attempt_id: str) -> dict | None:
    return _fetchone(conn, "SELECT * FROM dispatch_attempts WHERE attempt_id = ?", (attempt_id,))


def get_gate(conn: sqlite3.Connection, gate_id: str) -> dict | None:
    return _fetchone(conn, "SELECT * FROM interaction_gates WHERE gate_id = ?", (gate_id,))


def create_bundle(
    conn: sqlite3.Connection,
    *,
    bundle_type: str,
    status: str = "provisioning",
    parent_bundle_id: str | None = None,
    requested_by_seat: str | None = None,
    goal_ref: str | None = None,
    work_item_ref: str | None = None,
    autonomy_budget: str | None = None,
    notes: str | None = None,
    bundle_id: str | None = None,
) -> dict:
    bundle_id = bundle_id or make_id("bundle")
    ts = now_ts()
    conn.execute(
        """
        INSERT INTO loop_bundles (
            bundle_id, parent_bundle_id, requested_by_seat, bundle_type, status,
            goal_ref, work_item_ref, autonomy_budget, notes, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            bundle_id,
            parent_bundle_id,
            requested_by_seat,
            bundle_type,
            status,
            goal_ref,
            work_item_ref,
            autonomy_budget,
            notes,
            ts,
            ts,
        ),
    )
    conn.commit()
    return _require(get_bundle(conn, bundle_id), "bundle", bundle_id)


def set_bundle_status(conn: sqlite3.Connection, bundle_id: str, status: str) -> dict:
    ts = now_ts()
    conn.execute(
        "UPDATE loop_bundles SET status = ?, updated_at = ? WHERE bundle_id = ?",
        (status, ts, bundle_id),
    )
    conn.commit()
    return _require(get_bundle(conn, bundle_id), "bundle", bundle_id)


def create_session(
    conn: sqlite3.Connection,
    *,
    bundle_id: str,
    harness: str,
    transport: str,
    status: str = "active",
    cwd: str | None = None,
    transcript_ref: str | None = None,
    launched_by_seat: str | None = None,
    adopted: bool = False,
    session_id: str | None = None,
) -> dict:
    _require(get_bundle(conn, bundle_id), "bundle", bundle_id)
    session_id = session_id or make_id("session")
    ts = now_ts()
    conn.execute(
        """
        INSERT INTO agent_sessions (
            session_id, bundle_id, harness, transport, status, cwd, transcript_ref,
            launched_by_seat, adopted, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            session_id,
            bundle_id,
            harness,
            transport,
            status,
            cwd,
            transcript_ref,
            launched_by_seat,
            1 if adopted else 0,
            ts,
            ts,
        ),
    )
    conn.commit()
    return _require(get_session(conn, session_id), "session", session_id)


def set_session_status(conn: sqlite3.Connection, session_id: str, status: str) -> dict:
    ts = now_ts()
    conn.execute(
        "UPDATE agent_sessions SET status = ?, updated_at = ? WHERE session_id = ?",
        (status, ts, session_id),
    )
    conn.commit()
    return _require(get_session(conn, session_id), "session", session_id)


def attach_endpoint(
    conn: sqlite3.Connection,
    *,
    session_id: str,
    adapter_name: str,
    endpoint_kind: str,
    endpoint_ref: str,
    metadata: dict | None = None,
    endpoint_id: str | None = None,
) -> dict:
    _require(get_session(conn, session_id), "session", session_id)
    endpoint_id = endpoint_id or make_id("endpoint")
    ts = now_ts()
    conn.execute(
        """
        INSERT INTO transport_endpoints (
            endpoint_id, session_id, adapter_name, endpoint_kind, endpoint_ref,
            metadata_json, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            endpoint_id,
            session_id,
            adapter_name,
            endpoint_kind,
            endpoint_ref,
            json.dumps(metadata or {}, sort_keys=True),
            ts,
            ts,
        ),
    )
    conn.commit()
    return _fetchone(conn, "SELECT * FROM transport_endpoints WHERE endpoint_id = ?", (endpoint_id,))


def create_seat(
    conn: sqlite3.Connection,
    *,
    bundle_id: str,
    session_id: str,
    role: str,
    status: str = "active",
    parent_seat_id: str | None = None,
    label: str | None = None,
    seat_id: str | None = None,
) -> dict:
    _require(get_bundle(conn, bundle_id), "bundle", bundle_id)
    _require(get_session(conn, session_id), "session", session_id)
    seat_id = seat_id or make_id("seat")
    ts = now_ts()
    conn.execute(
        """
        INSERT INTO seats (
            seat_id, bundle_id, session_id, role, status, parent_seat_id, label,
            created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (seat_id, bundle_id, session_id, role, status, parent_seat_id, label, ts, ts),
    )
    conn.commit()
    return _require(get_seat(conn, seat_id), "seat", seat_id)


def set_seat_status(conn: sqlite3.Connection, seat_id: str, status: str) -> dict:
    ts = now_ts()
    conn.execute("UPDATE seats SET status = ?, updated_at = ? WHERE seat_id = ?", (status, ts, seat_id))
    conn.commit()
    return _require(get_seat(conn, seat_id), "seat", seat_id)


def create_thread(
    conn: sqlite3.Connection,
    *,
    bundle_id: str,
    supervisor_seat_id: str,
    target_seat_id: str | None = None,
    target_bundle_id: str | None = None,
    thread_type: str,
    status: str = "active",
    wake_policy: str | None = None,
    escalation_policy: str | None = None,
    thread_id: str | None = None,
) -> dict:
    _require(get_bundle(conn, bundle_id), "bundle", bundle_id)
    _require(get_seat(conn, supervisor_seat_id), "seat", supervisor_seat_id)
    if target_seat_id:
        _require(get_seat(conn, target_seat_id), "seat", target_seat_id)
    if target_bundle_id:
        _require(get_bundle(conn, target_bundle_id), "bundle", target_bundle_id)
    thread_id = thread_id or make_id("thread")
    ts = now_ts()
    conn.execute(
        """
        INSERT INTO supervision_threads (
            thread_id, bundle_id, supervisor_seat_id, target_seat_id, target_bundle_id,
            thread_type, status, wake_policy, escalation_policy, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            thread_id,
            bundle_id,
            supervisor_seat_id,
            target_seat_id,
            target_bundle_id,
            thread_type,
            status,
            wake_policy,
            escalation_policy,
            ts,
            ts,
        ),
    )
    conn.commit()
    return _require(get_thread(conn, thread_id), "thread", thread_id)


def create_spawn_request(
    conn: sqlite3.Connection,
    *,
    parent_bundle_id: str,
    requested_by_seat: str,
    requested_worker: str,
    requested_supervisor: str | None,
    transport: str,
    request_json: dict,
    status: str = "pending",
    request_id: str | None = None,
) -> dict:
    _require(get_bundle(conn, parent_bundle_id), "bundle", parent_bundle_id)
    _require(get_seat(conn, requested_by_seat), "seat", requested_by_seat)
    request_id = request_id or make_id("spawn")
    ts = now_ts()
    conn.execute(
        """
        INSERT INTO spawn_requests (
            request_id, parent_bundle_id, requested_by_seat, status, requested_worker,
            requested_supervisor, transport, request_json, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            request_id,
            parent_bundle_id,
            requested_by_seat,
            status,
            requested_worker,
            requested_supervisor,
            transport,
            json.dumps(request_json, sort_keys=True),
            ts,
            ts,
        ),
    )
    conn.commit()
    return _fetchone(conn, "SELECT * FROM spawn_requests WHERE request_id = ?", (request_id,))


def update_spawn_request(
    conn: sqlite3.Connection,
    request_id: str,
    *,
    status: str,
    child_bundle_id: str | None = None,
) -> dict:
    ts = now_ts()
    conn.execute(
        "UPDATE spawn_requests SET status = ?, child_bundle_id = ?, updated_at = ? WHERE request_id = ?",
        (status, child_bundle_id, ts, request_id),
    )
    conn.commit()
    return _fetchone(conn, "SELECT * FROM spawn_requests WHERE request_id = ?", (request_id,))


def issue_dispatch_attempt(
    conn: sqlite3.Connection,
    *,
    seat_id: str,
    instruction_ref: str,
    issued_by_seat: str | None = None,
    timeout_at: int | None = None,
    attempt_id: str | None = None,
) -> dict:
    _require(get_seat(conn, seat_id), "seat", seat_id)
    if issued_by_seat:
        _require(get_seat(conn, issued_by_seat), "seat", issued_by_seat)
    attempt_id = attempt_id or make_id("attempt")
    ts = now_ts()
    conn.execute(
        """
        INSERT INTO dispatch_attempts (
            attempt_id, seat_id, issued_by_seat, instruction_ref, status, retry_count,
            timeout_at, created_at, updated_at
        ) VALUES (?, ?, ?, ?, 'pending', 0, ?, ?, ?)
        """,
        (attempt_id, seat_id, issued_by_seat, instruction_ref, timeout_at, ts, ts),
    )
    conn.commit()
    return _require(get_dispatch_attempt(conn, attempt_id), "dispatch attempt", attempt_id)


def _transition_attempt(
    conn: sqlite3.Connection,
    attempt_id: str,
    *,
    next_status: str,
    terminal_reason: str | None = None,
) -> dict:
    attempt = _require(get_dispatch_attempt(conn, attempt_id), "dispatch attempt", attempt_id)
    allowed = {
        "pending": {"claimed", "timed_out", "failed", "superseded"},
        "claimed": {"acknowledged", "timed_out", "failed", "superseded"},
        "acknowledged": {"superseded"},
        "timed_out": set(),
        "failed": set(),
        "superseded": set(),
    }
    current_status = attempt["status"]
    if next_status not in allowed.get(current_status, set()):
        raise ValueError(f"invalid dispatch transition: {current_status} -> {next_status}")
    ts = now_ts()
    claimed_at = attempt["claimed_at"]
    acknowledged_at = attempt["acknowledged_at"]
    failed_at = attempt["failed_at"]
    if next_status == "claimed":
        claimed_at = ts
    elif next_status == "acknowledged":
        acknowledged_at = ts
    elif next_status in {"failed", "timed_out"}:
        failed_at = ts
    conn.execute(
        """
        UPDATE dispatch_attempts
           SET status = ?, claimed_at = ?, acknowledged_at = ?, failed_at = ?,
               terminal_reason = ?, updated_at = ?
         WHERE attempt_id = ?
        """,
        (next_status, claimed_at, acknowledged_at, failed_at, terminal_reason, ts, attempt_id),
    )
    conn.commit()
    return _require(get_dispatch_attempt(conn, attempt_id), "dispatch attempt", attempt_id)


def claim_dispatch_attempt(conn: sqlite3.Connection, attempt_id: str) -> dict:
    return _transition_attempt(conn, attempt_id, next_status="claimed")


def acknowledge_dispatch_attempt(conn: sqlite3.Connection, attempt_id: str) -> dict:
    return _transition_attempt(conn, attempt_id, next_status="acknowledged")


def timeout_dispatch_attempt(conn: sqlite3.Connection, attempt_id: str) -> dict:
    return _transition_attempt(conn, attempt_id, next_status="timed_out", terminal_reason="timeout")


def fail_dispatch_attempt(conn: sqlite3.Connection, attempt_id: str, *, reason: str) -> dict:
    return _transition_attempt(conn, attempt_id, next_status="failed", terminal_reason=reason)


def record_heartbeat(
    conn: sqlite3.Connection,
    *,
    bundle_id: str | None,
    seat_id: str | None,
    session_id: str | None,
    source_type: str,
    source_ref: str,
    state: str | None = None,
    details: dict | None = None,
    heartbeat_id: str | None = None,
) -> dict:
    heartbeat_id = heartbeat_id or make_id("heartbeat")
    ts = now_ts()
    conn.execute(
        """
        INSERT INTO heartbeats (
            heartbeat_id, bundle_id, seat_id, session_id, source_type, source_ref,
            state, details_json, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            heartbeat_id,
            bundle_id,
            seat_id,
            session_id,
            source_type,
            source_ref,
            state,
            json.dumps(details or {}, sort_keys=True),
            ts,
        ),
    )
    conn.commit()
    return _fetchone(conn, "SELECT * FROM heartbeats WHERE heartbeat_id = ?", (heartbeat_id,))


def _active_attempt_for_seat(conn: sqlite3.Connection, seat_id: str) -> dict | None:
    return _fetchone(
        conn,
        """
        SELECT * FROM dispatch_attempts
         WHERE seat_id = ? AND status IN ('pending', 'claimed')
         ORDER BY created_at DESC
         LIMIT 1
        """,
        (seat_id,),
    )


def upsert_interaction_gate(
    conn: sqlite3.Connection,
    *,
    bundle_id: str,
    session_id: str,
    seat_id: str,
    gate_type: str,
    prompt_excerpt: str,
    dispatch_attempt_id: str | None = None,
    resolution_policy: str = "escalate_parent",
) -> dict:
    existing = _fetchone(
        conn,
        """
        SELECT * FROM interaction_gates
         WHERE seat_id = ? AND gate_type = ? AND prompt_excerpt = ? AND status IN ('open', 'delegated')
         ORDER BY created_at DESC
         LIMIT 1
        """,
        (seat_id, gate_type, prompt_excerpt),
    )
    ts = now_ts()
    if existing:
        conn.execute(
            """
            UPDATE interaction_gates
               SET dispatch_attempt_id = ?, updated_at = ?
             WHERE gate_id = ?
            """,
            (dispatch_attempt_id, ts, existing["gate_id"]),
        )
        conn.commit()
        gate = _require(get_gate(conn, existing["gate_id"]), "gate", existing["gate_id"])
    else:
        gate_id = make_id("gate")
        conn.execute(
            """
            INSERT INTO interaction_gates (
                gate_id, bundle_id, session_id, seat_id, dispatch_attempt_id, gate_type,
                status, prompt_excerpt, resolution_policy, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, 'open', ?, ?, ?, ?)
            """,
            (
                gate_id,
                bundle_id,
                session_id,
                seat_id,
                dispatch_attempt_id,
                gate_type,
                prompt_excerpt,
                resolution_policy,
                ts,
                ts,
            ),
        )
        conn.commit()
        gate = _require(get_gate(conn, gate_id), "gate", gate_id)
    set_seat_status(conn, seat_id, "blocked")
    set_session_status(conn, session_id, "blocked")
    return gate


def expire_open_gates_for_seat(conn: sqlite3.Connection, seat_id: str) -> int:
    seat = _require(get_seat(conn, seat_id), "seat", seat_id)
    ts = now_ts()
    cursor = conn.execute(
        """
        UPDATE interaction_gates
           SET status = 'expired', updated_at = ?
         WHERE seat_id = ? AND status IN ('open', 'delegated')
        """,
        (ts, seat_id),
    )
    conn.commit()
    set_seat_status(conn, seat_id, "active")
    set_session_status(conn, seat["session_id"], "active")
    return int(cursor.rowcount or 0)


def resolve_interaction_gate(
    conn: sqlite3.Connection,
    gate_id: str,
    *,
    resolved_by_seat: str | None = None,
    resolution: str,
) -> dict:
    gate = _require(get_gate(conn, gate_id), "gate", gate_id)
    if resolved_by_seat:
        _require(get_seat(conn, resolved_by_seat), "seat", resolved_by_seat)
    ts = now_ts()
    conn.execute(
        """
        UPDATE interaction_gates
           SET status = 'resolved', resolved_by_seat = ?, resolution = ?,
               updated_at = ?, resolved_at = ?
         WHERE gate_id = ?
        """,
        (resolved_by_seat, resolution, ts, ts, gate_id),
    )
    conn.commit()
    set_seat_status(conn, gate["seat_id"], "active")
    set_session_status(conn, gate["session_id"], "active")
    return _require(get_gate(conn, gate_id), "gate", gate_id)


def list_gates(
    conn: sqlite3.Connection,
    *,
    bundle_id: str | None = None,
    seat_id: str | None = None,
) -> list[dict]:
    if bundle_id:
        return _fetchall(
            conn,
            "SELECT * FROM interaction_gates WHERE bundle_id = ? ORDER BY created_at",
            (bundle_id,),
        )
    if seat_id:
        return _fetchall(
            conn,
            "SELECT * FROM interaction_gates WHERE seat_id = ? ORDER BY created_at",
            (seat_id,),
        )
    return _fetchall(conn, "SELECT * FROM interaction_gates ORDER BY created_at")


def open_finding(
    conn: sqlite3.Connection,
    *,
    bundle_id: str,
    severity: str,
    finding_type: str,
    summary: str,
    target_seat_id: str | None = None,
    opened_by_seat: str | None = None,
    evidence_ref: str | None = None,
    finding_id: str | None = None,
) -> dict:
    existing = _fetchone(
        conn,
        """
        SELECT * FROM findings
         WHERE bundle_id = ? AND finding_type = ? AND summary = ? AND status = 'open'
         LIMIT 1
        """,
        (bundle_id, finding_type, summary),
    )
    if existing:
        return existing
    finding_id = finding_id or make_id("finding")
    ts = now_ts()
    conn.execute(
        """
        INSERT INTO findings (
            finding_id, bundle_id, opened_by_seat, target_seat_id, severity,
            finding_type, status, evidence_ref, summary, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, 'open', ?, ?, ?, ?)
        """,
        (
            finding_id,
            bundle_id,
            opened_by_seat,
            target_seat_id,
            severity,
            finding_type,
            evidence_ref,
            summary,
            ts,
            ts,
        ),
    )
    conn.commit()
    return _fetchone(conn, "SELECT * FROM findings WHERE finding_id = ?", (finding_id,))


def get_tmux_target_for_seat(conn: sqlite3.Connection, seat_id: str) -> str:
    row = _fetchone(
        conn,
        """
        SELECT te.endpoint_ref
          FROM seats s
          JOIN transport_endpoints te
            ON te.session_id = s.session_id
         WHERE s.seat_id = ? AND te.endpoint_kind = 'pane'
         ORDER BY te.created_at ASC
         LIMIT 1
        """,
        (seat_id,),
    )
    if row is None:
        raise ValueError(f"no pane endpoint for seat {seat_id}")
    return row["endpoint_ref"]


def adopt_tmux_worker(
    conn: sqlite3.Connection,
    *,
    bundle_id: str,
    harness: str,
    endpoint: str,
    role: str,
    cwd: str | None,
    label: str | None,
    adapter: Any,
) -> dict:
    bundle = _require(get_bundle(conn, bundle_id), "bundle", bundle_id)
    meta = adapter.adopt(endpoint)
    session = create_session(
        conn,
        bundle_id=bundle_id,
        harness=harness,
        transport="tmux",
        cwd=cwd or meta.get("cwd"),
        adopted=True,
    )
    endpoint_row = attach_endpoint(
        conn,
        session_id=session["session_id"],
        adapter_name="tmux",
        endpoint_kind="pane",
        endpoint_ref=meta["target"],
        metadata=meta,
    )
    seat = create_seat(
        conn,
        bundle_id=bundle_id,
        session_id=session["session_id"],
        role=role,
        label=label,
    )
    bundle = set_bundle_status(conn, bundle["bundle_id"], "active")
    return {
        "bundle": bundle,
        "session": session,
        "endpoint": endpoint_row,
        "seat": seat,
    }


def spawn_tmux_supervised_bundle(
    conn: sqlite3.Connection,
    *,
    parent_bundle_id: str | None,
    requested_by_seat: str | None,
    worker_harness: str,
    supervisor_harness: str,
    goal_ref: str | None,
    work_item_ref: str | None,
    worker_cwd: str,
    worker_command: str,
    supervisor_cwd: str | None,
    supervisor_command: str,
    tmux_session: str,
    window_name: str | None,
    adapter: Any,
    policy_verdict: dict | None = None,
) -> dict:
    if parent_bundle_id:
        _require(get_bundle(conn, parent_bundle_id), "bundle", parent_bundle_id)
    if requested_by_seat:
        _require(get_seat(conn, requested_by_seat), "seat", requested_by_seat)
    child_bundle = create_bundle(
        conn,
        bundle_type="coding_loop",
        parent_bundle_id=parent_bundle_id,
        requested_by_seat=requested_by_seat,
        goal_ref=goal_ref,
        work_item_ref=work_item_ref,
    )
    request = None
    if parent_bundle_id and requested_by_seat:
        _req_json: dict = {
            "goal_ref": goal_ref,
            "work_item_ref": work_item_ref,
            "tmux_session": tmux_session,
            "window_name": window_name,
        }
        if policy_verdict is not None:
            _req_json["policy_verdict"] = policy_verdict
        request = create_spawn_request(
            conn,
            parent_bundle_id=parent_bundle_id,
            requested_by_seat=requested_by_seat,
            requested_worker=worker_harness,
            requested_supervisor=supervisor_harness,
            transport="tmux",
            request_json=_req_json,
            status="provisioning",
        )

    worker_meta = adapter.spawn_window(
        session_name=tmux_session,
        window_name=window_name,
        cwd=worker_cwd,
        command=worker_command,
    )
    worker_session = create_session(
        conn,
        bundle_id=child_bundle["bundle_id"],
        harness=worker_harness,
        transport="tmux",
        cwd=worker_cwd or worker_meta.get("cwd"),
    )
    worker_endpoint = attach_endpoint(
        conn,
        session_id=worker_session["session_id"],
        adapter_name="tmux",
        endpoint_kind="pane",
        endpoint_ref=worker_meta["target"],
        metadata=worker_meta,
    )
    worker_seat = create_seat(
        conn,
        bundle_id=child_bundle["bundle_id"],
        session_id=worker_session["session_id"],
        role="worker",
        label="worker",
    )

    supervisor_meta = adapter.split_pane(
        target=worker_meta["target"],
        cwd=supervisor_cwd or worker_cwd,
        command=supervisor_command,
        orientation="h",
    )
    supervisor_session = create_session(
        conn,
        bundle_id=child_bundle["bundle_id"],
        harness=supervisor_harness,
        transport="tmux",
        cwd=supervisor_cwd or worker_cwd or supervisor_meta.get("cwd"),
        launched_by_seat=requested_by_seat,
    )
    supervisor_endpoint = attach_endpoint(
        conn,
        session_id=supervisor_session["session_id"],
        adapter_name="tmux",
        endpoint_kind="pane",
        endpoint_ref=supervisor_meta["target"],
        metadata=supervisor_meta,
    )
    supervisor_seat = create_seat(
        conn,
        bundle_id=child_bundle["bundle_id"],
        session_id=supervisor_session["session_id"],
        role="supervisor",
        label="supervisor",
        parent_seat_id=requested_by_seat,
    )
    local_thread = create_thread(
        conn,
        bundle_id=child_bundle["bundle_id"],
        supervisor_seat_id=supervisor_seat["seat_id"],
        target_seat_id=worker_seat["seat_id"],
        thread_type="supervise",
        wake_policy="artifact_or_gate",
    )
    parent_thread = None
    if parent_bundle_id and requested_by_seat:
        parent_thread = create_thread(
            conn,
            bundle_id=parent_bundle_id,
            supervisor_seat_id=requested_by_seat,
            target_bundle_id=child_bundle["bundle_id"],
            thread_type="supervise",
            wake_policy="artifact_or_finding",
        )
        request = update_spawn_request(
            conn,
            request["request_id"],
            status="fulfilled",
            child_bundle_id=child_bundle["bundle_id"],
        )

    child_bundle = set_bundle_status(conn, child_bundle["bundle_id"], "active")
    return {
        "bundle": child_bundle,
        "spawn_request": request,
        "worker": {
            "session": worker_session,
            "endpoint": worker_endpoint,
            "seat": worker_seat,
        },
        "supervisor": {
            "session": supervisor_session,
            "endpoint": supervisor_endpoint,
            "seat": supervisor_seat,
        },
        "local_thread": local_thread,
        "parent_thread": parent_thread,
    }


def observe_tmux_seat(
    conn: sqlite3.Connection,
    *,
    seat_id: str,
    adapter: Any,
    lines: int = 120,
) -> dict:
    seat = _require(get_seat(conn, seat_id), "seat", seat_id)
    session = _require(get_session(conn, seat["session_id"]), "session", seat["session_id"])
    target = get_tmux_target_for_seat(conn, seat_id)
    capture = adapter.capture(target=target, lines=lines)
    text = capture.get("text", "")
    gate = detect_interaction_gate(text)
    heartbeat = record_heartbeat(
        conn,
        bundle_id=seat["bundle_id"],
        seat_id=seat["seat_id"],
        session_id=session["session_id"],
        source_type="adapter",
        source_ref=target,
        state="blocked" if gate else "observed",
        details={
            "target": target,
            "summary": summarize_text(text),
            "current_command": capture.get("current_command"),
        },
    )
    gate_row = None
    expired_gate_count = 0
    if gate:
        active_attempt = _active_attempt_for_seat(conn, seat_id)
        gate_row = upsert_interaction_gate(
            conn,
            bundle_id=seat["bundle_id"],
            session_id=session["session_id"],
            seat_id=seat["seat_id"],
            dispatch_attempt_id=active_attempt["attempt_id"] if active_attempt else None,
            gate_type=gate["gate_type"],
            prompt_excerpt=gate["prompt_excerpt"],
        )
    else:
        expired_gate_count = expire_open_gates_for_seat(conn, seat_id)
    return {
        "seat": seat,
        "session": session,
        "target": target,
        "gate": gate_row,
        "expired_gate_count": expired_gate_count,
        "heartbeat": heartbeat,
        "summary": summarize_text(text),
    }


def _child_bundle_ids(conn: sqlite3.Connection, bundle_id: str) -> list[str]:
    pending = [bundle_id]
    seen: set[str] = set()
    while pending:
        current = pending.pop()
        if current in seen:
            continue
        seen.add(current)
        children = _fetchall(
            conn,
            "SELECT bundle_id FROM loop_bundles WHERE parent_bundle_id = ?",
            (current,),
        )
        pending.extend(row["bundle_id"] for row in children)
    return sorted(seen)


def _bundle_summary(conn: sqlite3.Connection, bundle_id: str) -> dict:
    bundle = _require(get_bundle(conn, bundle_id), "bundle", bundle_id)
    counts = {
        "sessions": _fetchone(
            conn, "SELECT COUNT(*) AS count FROM agent_sessions WHERE bundle_id = ?", (bundle_id,)
        )["count"],
        "seats": _fetchone(conn, "SELECT COUNT(*) AS count FROM seats WHERE bundle_id = ?", (bundle_id,))[
            "count"
        ],
        "threads": _fetchone(
            conn, "SELECT COUNT(*) AS count FROM supervision_threads WHERE bundle_id = ?", (bundle_id,)
        )["count"],
        "open_gates": _fetchone(
            conn,
            "SELECT COUNT(*) AS count FROM interaction_gates WHERE bundle_id = ? AND status IN ('open', 'delegated')",
            (bundle_id,),
        )["count"],
        "pending_reviews": _fetchone(
            conn,
            "SELECT COUNT(*) AS count FROM review_artifacts WHERE bundle_id = ? AND status = 'pending'",
            (bundle_id,),
        )["count"],
        "open_findings": _fetchone(
            conn,
            "SELECT COUNT(*) AS count FROM findings WHERE bundle_id = ? AND status = 'open'",
            (bundle_id,),
        )["count"],
    }
    latest_heartbeat = _fetchone(
        conn,
        "SELECT created_at, state, source_ref FROM heartbeats WHERE bundle_id = ? ORDER BY created_at DESC LIMIT 1",
        (bundle_id,),
    )
    health = "active"
    if counts["open_gates"] or counts["pending_reviews"] or counts["open_findings"]:
        health = "needs_attention"
    if bundle["status"] in {"blocked", "paused", "terminal", "archived"}:
        health = bundle["status"]
    return {
        "bundle": bundle,
        "counts": counts,
        "latest_heartbeat": latest_heartbeat,
        "health": health,
    }


def bundle_tree(conn: sqlite3.Connection, bundle_id: str) -> dict:
    bundle = _require(get_bundle(conn, bundle_id), "bundle", bundle_id)
    sessions = _fetchall(conn, "SELECT * FROM agent_sessions WHERE bundle_id = ? ORDER BY created_at", (bundle_id,))
    session_map: dict[str, dict] = {}
    for session in sessions:
        endpoints = _fetchall(
            conn,
            "SELECT * FROM transport_endpoints WHERE session_id = ? ORDER BY created_at",
            (session["session_id"],),
        )
        session_map[session["session_id"]] = {**session, "endpoints": endpoints}
    seats = _fetchall(conn, "SELECT * FROM seats WHERE bundle_id = ? ORDER BY created_at", (bundle_id,))
    threads = _fetchall(
        conn,
        "SELECT * FROM supervision_threads WHERE bundle_id = ? ORDER BY created_at",
        (bundle_id,),
    )
    gates = _fetchall(
        conn,
        "SELECT * FROM interaction_gates WHERE bundle_id = ? AND status IN ('open', 'delegated') ORDER BY created_at",
        (bundle_id,),
    )
    findings = _fetchall(
        conn,
        "SELECT * FROM findings WHERE bundle_id = ? AND status = 'open' ORDER BY created_at",
        (bundle_id,),
    )
    children = _fetchall(
        conn,
        "SELECT bundle_id FROM loop_bundles WHERE parent_bundle_id = ? ORDER BY created_at",
        (bundle_id,),
    )
    return {
        "bundle": bundle,
        "summary": _bundle_summary(conn, bundle_id),
        "sessions": list(session_map.values()),
        "seats": seats,
        "threads": threads,
        "open_gates": gates,
        "open_findings": findings,
        "children": [bundle_tree(conn, child["bundle_id"]) for child in children],
    }


def controller_sweep(conn: sqlite3.Connection, *, bundle_id: str | None = None) -> dict:
    bundle_ids = _child_bundle_ids(conn, bundle_id) if bundle_id else [
        row["bundle_id"]
        for row in _fetchall(
            conn,
            "SELECT bundle_id FROM loop_bundles WHERE status != 'archived' ORDER BY created_at",
        )
    ]
    if not bundle_ids:
        return {"scope": bundle_id, "bundle_ids": [], "timed_out_attempts": [], "open_gates": [], "pending_reviews": [], "summaries": []}

    placeholders = ",".join("?" for _ in bundle_ids)
    stale_attempts = _fetchall(
        conn,
        f"""
        SELECT da.*, s.bundle_id
          FROM dispatch_attempts da
          JOIN seats s ON s.seat_id = da.seat_id
         WHERE s.bundle_id IN ({placeholders})
           AND da.status IN ('pending', 'claimed')
           AND da.timeout_at IS NOT NULL
           AND da.timeout_at < ?
         ORDER BY da.timeout_at ASC
        """,
        (*bundle_ids, now_ts()),
    )
    timed_out_attempts = []
    for attempt in stale_attempts:
        updated = timeout_dispatch_attempt(conn, attempt["attempt_id"])
        timed_out_attempts.append(updated)
        open_finding(
            conn,
            bundle_id=attempt["bundle_id"],
            severity="warning",
            finding_type="timeout",
            summary=f"Dispatch attempt {attempt['attempt_id']} timed out",
            target_seat_id=attempt["seat_id"],
            evidence_ref=attempt["attempt_id"],
        )

    open_gates = _fetchall(
        conn,
        f"""
        SELECT * FROM interaction_gates
         WHERE bundle_id IN ({placeholders}) AND status IN ('open', 'delegated')
         ORDER BY created_at
        """,
        tuple(bundle_ids),
    )
    pending_reviews = _fetchall(
        conn,
        f"""
        SELECT * FROM review_artifacts
         WHERE bundle_id IN ({placeholders}) AND status = 'pending'
         ORDER BY created_at
        """,
        tuple(bundle_ids),
    )
    summaries = [_bundle_summary(conn, current_bundle_id) for current_bundle_id in bundle_ids]
    health = "active"
    if timed_out_attempts or open_gates or pending_reviews:
        health = "needs_attention"
    return {
        "scope": bundle_id,
        "bundle_ids": bundle_ids,
        "health": health,
        "timed_out_attempts": timed_out_attempts,
        "open_gates": open_gates,
        "pending_reviews": pending_reviews,
        "summaries": summaries,
    }

