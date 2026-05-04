# @decision DEC-CRITIC-RUNS-001 — critic run telemetry is a first-class runtime domain
# Why: Final critic verdicts alone cannot make Codex work visible while it is running,
# cannot preserve CRITIC_UNAVAILABLE fallback state, and cannot answer loopback /
# fallback-rate questions for system improvement. A dedicated run ledger owns
# lifecycle, progress, metrics, and trace linkage while critic_reviews remains the
# routing verdict authority.
# Alternatives considered: Adding progress fields to critic_reviews was rejected
# because that table models final verdicts consumed by dispatch routing; overloading
# events was rejected because typed progress and metrics would become ad hoc text.
"""Critic run telemetry and visibility domain.

``critic_reviews`` owns the final routing verdict. This module owns the
observable run lifecycle around that verdict: started/running/completed,
progress snippets, fallback status, trace linkage, and aggregate metrics.

The data here is evidence and presentation material. Dispatch authority still
comes from critic_reviews, completion records, reviewer convergence, leases, and
evaluation state.
"""

from __future__ import annotations

import json
import sqlite3
import time
import uuid
from dataclasses import asdict, dataclass
from typing import Optional

from runtime.core import critic_reviews, traces


IMPLEMENTER_ROLE = critic_reviews.IMPLEMENTER_ROLE

ACTIVE_STATUSES: frozenset[str] = frozenset({
    "started",
    "provider_ready",
    "reviewing",
})

TERMINAL_STATUSES: frozenset[str] = frozenset({
    "completed",
    "failed",
    "fallback_required",
    "fallback_completed",
})

VALID_STATUSES: frozenset[str] = ACTIVE_STATUSES | TERMINAL_STATUSES


@dataclass(frozen=True)
class CriticMetrics:
    """Aggregate run metrics for evaluation and improvement work."""

    total_runs: int
    final_runs: int
    active_runs: int
    ready_for_reviewer: int
    try_again: int
    blocked_by_plan: int
    critic_unavailable: int
    fallback_required: int
    fallback_completed: int
    failed: int
    loopback_rate: float
    unavailable_rate: float
    fallback_completion_rate: float
    average_duration_seconds: float
    average_try_again_streak: float
    escalation_counts: dict[str, int]

    def as_dict(self) -> dict:
        return asdict(self)


def _now() -> int:
    return int(time.time())


def _new_run_id() -> str:
    return f"critic-{uuid.uuid4().hex[:16]}"


def _normalise_role(role: str) -> str:
    value = str(role or "").strip().lower()
    if value != IMPLEMENTER_ROLE:
        raise ValueError(f"critic run role must be {IMPLEMENTER_ROLE!r}, got {role!r}")
    return value


def _normalise_status(status: str) -> str:
    value = str(status or "").strip().lower()
    if value not in VALID_STATUSES:
        raise ValueError(f"critic run status must be one of {sorted(VALID_STATUSES)}, got {status!r}")
    return value


def _parse_list(raw: str | None) -> list:
    if not raw:
        return []
    try:
        parsed = json.loads(raw)
    except (TypeError, ValueError):
        return []
    return parsed if isinstance(parsed, list) else []


def _parse_dict(raw: str | None) -> dict:
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
    except (TypeError, ValueError):
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _row_to_dict(row: sqlite3.Row | None) -> Optional[dict]:
    if row is None:
        return None
    data = dict(row)
    data["progress"] = _parse_list(data.pop("progress_json", "[]"))
    data["metrics"] = _parse_dict(data.pop("metrics_json", "{}"))
    started_at = int(data.get("started_at") or 0)
    completed_at = int(data.get("completed_at") or 0)
    updated_at = int(data.get("updated_at") or 0)
    end = completed_at or updated_at or _now()
    data["elapsed_seconds"] = max(0, end - started_at) if started_at else 0
    data["active"] = str(data.get("status") or "") in ACTIVE_STATUSES
    return data


def _trace_start(conn: sqlite3.Connection, trace_session_id: str, role: str, workflow_id: str) -> None:
    try:
        traces.start_trace(
            conn,
            trace_session_id,
            agent_role=f"{role}:critic",
            ticket=workflow_id,
        )
    except sqlite3.IntegrityError:
        pass
    except Exception:
        pass


def _trace_entry(
    conn: sqlite3.Connection,
    trace_session_id: str,
    entry_type: str,
    *,
    detail: str = "",
    path: str = "",
) -> None:
    if not trace_session_id:
        return
    try:
        traces.add_manifest_entry(
            conn,
            trace_session_id,
            entry_type,
            path=path or None,
            detail=detail or None,
        )
    except Exception:
        pass


def _trace_end(conn: sqlite3.Connection, trace_session_id: str, summary: str) -> None:
    if not trace_session_id:
        return
    try:
        traces.end_trace(conn, trace_session_id, summary=summary)
    except Exception:
        pass


def start(
    conn: sqlite3.Connection,
    *,
    workflow_id: str,
    lease_id: str = "",
    role: str = IMPLEMENTER_ROLE,
    provider: str = "codex",
    run_id: str = "",
    status: str = "started",
) -> dict:
    """Create a critic run and its trace container."""

    workflow_id = str(workflow_id or "").strip()
    if not workflow_id:
        raise ValueError("critic run workflow_id must be non-empty")
    role = _normalise_role(role)
    status = _normalise_status(status)
    provider = str(provider or "").strip() or "codex"
    run_id = str(run_id or "").strip() or _new_run_id()
    trace_session_id = f"critic-run:{run_id}"
    now = _now()
    progress = [{
        "message": "Critic run started.",
        "phase": status,
        "status": status,
        "created_at": now,
    }]

    with conn:
        conn.execute(
            """INSERT INTO critic_runs
               (run_id, workflow_id, lease_id, role, provider, status,
                trace_session_id, progress_json, started_at, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                run_id,
                workflow_id,
                lease_id or "",
                role,
                provider,
                status,
                trace_session_id,
                json.dumps(progress, sort_keys=True),
                now,
                now,
            ),
        )

    _trace_start(conn, trace_session_id, role, workflow_id)
    _trace_entry(
        conn,
        trace_session_id,
        "critic_started",
        detail=f"provider={provider}; workflow={workflow_id}; lease={lease_id or ''}",
    )
    return get(conn, run_id) or {"run_id": run_id}


def get(conn: sqlite3.Connection, run_id: str) -> Optional[dict]:
    row = conn.execute("SELECT * FROM critic_runs WHERE run_id = ?", (run_id,)).fetchone()
    return _row_to_dict(row)


def progress(
    conn: sqlite3.Connection,
    *,
    run_id: str,
    message: str,
    phase: str = "",
    status: str = "",
) -> dict:
    """Append a progress event and optionally advance lifecycle status."""

    run = get(conn, run_id)
    if not run:
        raise ValueError(f"critic run not found: {run_id}")
    message = str(message or "").strip()
    if not message:
        raise ValueError("critic run progress message must be non-empty")
    status_value = _normalise_status(status) if status else str(run.get("status") or "started")
    now = _now()
    entries = list(run.get("progress") or [])
    entries.append({
        "message": message,
        "phase": str(phase or status_value),
        "status": status_value,
        "created_at": now,
    })
    trace_session_id = str(run.get("trace_session_id") or "")
    with conn:
        conn.execute(
            """UPDATE critic_runs
               SET status = ?, progress_json = ?, updated_at = ?
               WHERE run_id = ?""",
            (status_value, json.dumps(entries, sort_keys=True), now, run_id),
        )
    _trace_entry(conn, trace_session_id, "critic_progress", detail=message)
    return get(conn, run_id) or {"run_id": run_id}


def complete(
    conn: sqlite3.Connection,
    *,
    run_id: str,
    verdict: str,
    provider: str = "",
    summary: str = "",
    detail: str = "",
    artifact_path: str = "",
    fingerprint: str = "",
    review_id: Optional[int] = None,
    fallback: str = "",
    error: str = "",
    metrics: Optional[dict] = None,
) -> dict:
    """Complete a critic run with a final verdict or fallback requirement."""

    run = get(conn, run_id)
    if not run:
        raise ValueError(f"critic run not found: {run_id}")
    verdict = str(verdict or "").strip().upper()
    if verdict not in critic_reviews.VALID_VERDICTS:
        raise ValueError(
            f"critic run verdict must be one of {sorted(critic_reviews.VALID_VERDICTS)}, got {verdict!r}"
        )
    provider = str(provider or run.get("provider") or "codex").strip() or "codex"
    fallback = str(fallback or "").strip()
    error = str(error or "").strip()
    status = "fallback_required" if verdict == "CRITIC_UNAVAILABLE" else "failed" if error else "completed"
    now = _now()
    entries = list(run.get("progress") or [])
    entries.append({
        "message": f"Critic verdict: {verdict}.",
        "phase": "finalizing",
        "status": status,
        "created_at": now,
    })
    metric_payload = dict(metrics or {})
    trace_session_id = str(run.get("trace_session_id") or "")
    with conn:
        conn.execute(
            """UPDATE critic_runs
               SET provider = ?, status = ?, verdict = ?, summary = ?, detail = ?,
                   artifact_path = ?, fallback = ?, error = ?, fingerprint = ?,
                   review_id = ?, progress_json = ?, metrics_json = ?,
                   updated_at = ?, completed_at = ?
               WHERE run_id = ?""",
            (
                provider,
                status,
                verdict,
                summary,
                detail,
                artifact_path,
                fallback,
                error,
                fingerprint,
                review_id,
                json.dumps(entries, sort_keys=True),
                json.dumps(metric_payload, sort_keys=True),
                now,
                now,
                run_id,
            ),
        )
    _trace_entry(
        conn,
        trace_session_id,
        "critic_verdict",
        detail=f"verdict={verdict}; provider={provider}; fallback={fallback}; summary={summary}",
        path=artifact_path,
    )
    if status == "fallback_required":
        _trace_entry(
            conn,
            trace_session_id,
            "critic_fallback_required",
            detail=f"fallback={fallback or 'reviewer'}; error={error}",
        )
    else:
        _trace_end(conn, trace_session_id, f"Critic {verdict}: {summary}")
    return get(conn, run_id) or {"run_id": run_id}


def mark_fallback_completed(
    conn: sqlite3.Connection,
    *,
    workflow_id: str,
    fallback: str = "reviewer",
    summary: str = "",
) -> Optional[dict]:
    """Mark the latest CRITIC_UNAVAILABLE run for a workflow as handled."""

    run = latest(conn, workflow_id=workflow_id, role=IMPLEMENTER_ROLE)
    if not run:
        return None
    if run.get("verdict") != "CRITIC_UNAVAILABLE":
        return None
    if run.get("status") == "fallback_completed":
        return run

    now = _now()
    entries = list(run.get("progress") or [])
    entries.append({
        "message": "Reviewer fallback completed.",
        "phase": "fallback",
        "status": "fallback_completed",
        "created_at": now,
    })
    trace_session_id = str(run.get("trace_session_id") or "")
    detail = summary or "Reviewer fallback completed."
    with conn:
        conn.execute(
            """UPDATE critic_runs
               SET status = 'fallback_completed',
                   fallback = ?,
                   progress_json = ?,
                   updated_at = ?
               WHERE run_id = ?""",
            (fallback, json.dumps(entries, sort_keys=True), now, run["run_id"]),
        )
    _trace_entry(conn, trace_session_id, "critic_fallback_completed", detail=detail)
    _trace_end(conn, trace_session_id, detail)
    return get(conn, str(run["run_id"]))


def latest(
    conn: sqlite3.Connection,
    *,
    workflow_id: Optional[str] = None,
    role: Optional[str] = None,
) -> Optional[dict]:
    rows = list_runs(conn, workflow_id=workflow_id, role=role, limit=1)
    return rows[0] if rows else None


def list_runs(
    conn: sqlite3.Connection,
    *,
    workflow_id: Optional[str] = None,
    role: Optional[str] = None,
    status: Optional[str] = None,
    limit: Optional[int] = None,
) -> list[dict]:
    clauses: list[str] = []
    params: list[object] = []
    if workflow_id is not None:
        clauses.append("workflow_id = ?")
        params.append(workflow_id)
    if role is not None:
        clauses.append("role = ?")
        params.append(role)
    if status is not None:
        clauses.append("status = ?")
        params.append(status)
    where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
    limit_clause = ""
    if limit is not None:
        limit_clause = " LIMIT ?"
        params.append(int(limit))
    rows = conn.execute(
        f"""SELECT * FROM critic_runs
            {where}
            ORDER BY updated_at DESC, started_at DESC, run_id DESC{limit_clause}""",
        tuple(params),
    ).fetchall()
    return [_row_to_dict(row) for row in rows if row is not None]


def metrics(
    conn: sqlite3.Connection,
    *,
    workflow_id: Optional[str] = None,
    role: str = IMPLEMENTER_ROLE,
) -> CriticMetrics:
    rows = list_runs(conn, workflow_id=workflow_id, role=role)
    final_rows = [r for r in rows if r.get("verdict")]
    active_rows = [r for r in rows if r.get("status") in ACTIVE_STATUSES]

    def count_verdict(verdict: str) -> int:
        return sum(1 for r in final_rows if r.get("verdict") == verdict)

    ready = count_verdict("READY_FOR_REVIEWER")
    retry = count_verdict("TRY_AGAIN")
    blocked = count_verdict("BLOCKED_BY_PLAN")
    unavailable = count_verdict("CRITIC_UNAVAILABLE")
    fallback_required = sum(1 for r in rows if r.get("status") == "fallback_required")
    fallback_completed = sum(1 for r in rows if r.get("status") == "fallback_completed")
    failed = sum(1 for r in rows if r.get("status") == "failed")

    durations = [float(r.get("elapsed_seconds") or 0) for r in final_rows if r.get("elapsed_seconds") is not None]
    try_again_streaks = []
    escalation_counts: dict[str, int] = {}
    for row in final_rows:
        row_metrics = row.get("metrics") if isinstance(row.get("metrics"), dict) else {}
        streak = row_metrics.get("try_again_streak")
        if isinstance(streak, int) and streak >= 0:
            try_again_streaks.append(float(streak))
        reason = str(row_metrics.get("escalation_reason") or "").strip()
        if reason:
            escalation_counts[reason] = escalation_counts.get(reason, 0) + 1

    total_final = len(final_rows)
    return CriticMetrics(
        total_runs=len(rows),
        final_runs=total_final,
        active_runs=len(active_rows),
        ready_for_reviewer=ready,
        try_again=retry,
        blocked_by_plan=blocked,
        critic_unavailable=unavailable,
        fallback_required=fallback_required,
        fallback_completed=fallback_completed,
        failed=failed,
        loopback_rate=(retry / total_final) if total_final else 0.0,
        unavailable_rate=(unavailable / total_final) if total_final else 0.0,
        fallback_completion_rate=(fallback_completed / unavailable) if unavailable else 0.0,
        average_duration_seconds=(sum(durations) / len(durations)) if durations else 0.0,
        average_try_again_streak=(sum(try_again_streaks) / len(try_again_streaks)) if try_again_streaks else 0.0,
        escalation_counts=escalation_counts,
    )
