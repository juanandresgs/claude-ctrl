# @decision DEC-IMPLEMENTER-CRITIC-001 — runtime-owned critic reviews drive implementer inner-loop routing
# Why: Persisting routing-shaped critic verdicts in the runtime keeps implementer retry/adjudication logic out of hooks and preserves reviewer as the sole readiness authority for guardian landing.
# Alternatives considered: Reusing codex_stop_review events was rejected because events are advisory and do not own retry/convergence state; folding the logic into completion_records was rejected because implementer completion contracts describe self-reported stop status, not Codex critic verdicts.
"""Implementer critic review authority.

This module owns the persisted Codex critic verdicts that sit between the
implementer and reviewer in the canonical workflow. The critic is tactical:
it decides whether the implementer should try again, whether the plan is
blocked, or whether the work is ready for outer-loop reviewer adjudication.

Reviewer readiness for guardian landing remains outside this module and is
still owned by reviewer_convergence / reviewer completions.
"""

from __future__ import annotations

import json
import sqlite3
import time
from dataclasses import asdict, dataclass
from typing import Optional

from runtime.core import completions, enforcement_config

IMPLEMENTER_ROLE: str = "implementer"
DEFAULT_CRITIC_RETRY_LIMIT: int = 2

VALID_VERDICTS: frozenset[str] = frozenset({
    "READY_FOR_REVIEWER",
    "TRY_AGAIN",
    "BLOCKED_BY_PLAN",
    "CRITIC_UNAVAILABLE",
})

ROUTE_BY_VERDICT: dict[str, str] = {
    "READY_FOR_REVIEWER": "reviewer",
    "TRY_AGAIN": "implementer",
    "BLOCKED_BY_PLAN": "planner",
    "CRITIC_UNAVAILABLE": "reviewer",
}

ESCALATION_RETRY_LIMIT: str = "retry_limit_exhausted"
ESCALATION_REPEATED_FINGERPRINT: str = "no_convergence_repeated_fingerprint"


@dataclass(frozen=True)
class CriticResolution:
    """Effective routing state derived from the latest critic review."""

    found: bool
    workflow_id: str
    review_id: Optional[int]
    lease_id: str
    role: str
    verdict: str
    provider: str
    summary: str
    detail: str
    fingerprint: str
    next_role: str
    retry_limit: int
    try_again_streak: int
    repeated_fingerprint_streak: int
    escalated: bool
    escalation_reason: str

    def as_dict(self) -> dict:
        return asdict(self)


def _normalise_verdict(verdict: str) -> str:
    value = str(verdict or "").strip().upper()
    if value not in VALID_VERDICTS:
        raise ValueError(
            f"critic review verdict must be one of {sorted(VALID_VERDICTS)}, got {verdict!r}"
        )
    return value


def _normalise_role(role: str) -> str:
    value = str(role or "").strip().lower()
    if value != IMPLEMENTER_ROLE:
        raise ValueError(
            f"critic review role must be {IMPLEMENTER_ROLE!r}, got {role!r}"
        )
    return value


def _parse_metadata(raw: str | None) -> dict:
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
    except (TypeError, ValueError):
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _row_to_dict(row: sqlite3.Row | tuple | None) -> Optional[dict]:
    if row is None:
        return None
    if hasattr(row, "keys"):
        data = dict(row)
    else:
        raise TypeError("critic review rows must be sqlite3.Row instances")
    data["metadata"] = _parse_metadata(data.get("metadata_json"))
    return data


def _retry_limit_for(
    conn: sqlite3.Connection,
    *,
    workflow_id: str = "",
    project_root: str = "",
) -> int:
    raw = enforcement_config.get(
        conn,
        "critic_retry_limit",
        workflow_id=workflow_id,
        project_root=project_root,
    )
    if raw is None:
        return DEFAULT_CRITIC_RETRY_LIMIT
    try:
        parsed = int(str(raw).strip())
    except (TypeError, ValueError):
        return DEFAULT_CRITIC_RETRY_LIMIT
    if parsed < 0:
        return DEFAULT_CRITIC_RETRY_LIMIT
    return parsed


def submit(
    conn: sqlite3.Connection,
    *,
    workflow_id: str,
    verdict: str,
    lease_id: str = "",
    role: str = IMPLEMENTER_ROLE,
    provider: str = "codex",
    summary: str = "",
    detail: str = "",
    fingerprint: str = "",
    metadata: Optional[dict] = None,
    project_root: str = "",
) -> dict:
    """Validate and insert a critic review row, then return the effective route."""

    role = _normalise_role(role)
    verdict = _normalise_verdict(verdict)
    workflow_id = str(workflow_id or "").strip()
    if not workflow_id:
        raise ValueError("critic review workflow_id must be non-empty")

    provider = str(provider or "").strip() or "codex"
    summary = str(summary or "").strip()
    detail = str(detail or "").strip()
    fingerprint = str(fingerprint or "").strip()
    metadata_json = json.dumps(metadata or {}, sort_keys=True)
    created_at = int(time.time())

    with conn:
        cursor = conn.execute(
            """INSERT INTO critic_reviews
               (workflow_id, lease_id, role, provider, verdict, summary, detail,
                fingerprint, metadata_json, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                workflow_id,
                lease_id or "",
                role,
                provider,
                verdict,
                summary,
                detail,
                fingerprint,
                metadata_json,
                created_at,
            ),
        )

    row = conn.execute(
        "SELECT * FROM critic_reviews WHERE id = ?",
        (cursor.lastrowid,),
    ).fetchone()
    record = _row_to_dict(row) or {}
    resolution = assess_latest(
        conn,
        workflow_id=workflow_id,
        role=role,
        project_root=project_root,
    )
    record["resolution"] = resolution.as_dict()
    return record


def latest(
    conn: sqlite3.Connection,
    *,
    workflow_id: Optional[str] = None,
    lease_id: Optional[str] = None,
    role: str = IMPLEMENTER_ROLE,
) -> Optional[dict]:
    rows = list_reviews(
        conn,
        workflow_id=workflow_id,
        lease_id=lease_id,
        role=role,
        limit=1,
    )
    return rows[0] if rows else None


def list_reviews(
    conn: sqlite3.Connection,
    *,
    workflow_id: Optional[str] = None,
    lease_id: Optional[str] = None,
    role: Optional[str] = None,
    limit: Optional[int] = None,
) -> list[dict]:
    clauses: list[str] = []
    params: list[object] = []
    if workflow_id is not None:
        clauses.append("workflow_id = ?")
        params.append(workflow_id)
    if lease_id is not None:
        clauses.append("lease_id = ?")
        params.append(lease_id)
    if role is not None:
        clauses.append("role = ?")
        params.append(role)

    where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
    limit_clause = ""
    if limit is not None:
        limit_clause = " LIMIT ?"
        params.append(int(limit))

    rows = conn.execute(
        f"""SELECT * FROM critic_reviews
            {where}
            ORDER BY created_at DESC, id DESC{limit_clause}""",
        tuple(params),
    ).fetchall()
    return [_row_to_dict(row) for row in rows if row is not None]


def assess_latest(
    conn: sqlite3.Connection,
    *,
    workflow_id: str,
    role: str = IMPLEMENTER_ROLE,
    project_root: str = "",
) -> CriticResolution:
    """Return the effective routing decision from the latest critic review."""

    role = _normalise_role(role)
    workflow_id = str(workflow_id or "").strip()
    retry_limit = _retry_limit_for(
        conn,
        workflow_id=workflow_id,
        project_root=project_root,
    )

    rows = list_reviews(conn, workflow_id=workflow_id, role=role)
    if not rows:
        return CriticResolution(
            found=False,
            workflow_id=workflow_id,
            review_id=None,
            lease_id="",
            role=role,
            verdict="",
            provider="",
            summary="",
            detail="",
            fingerprint="",
            next_role=ROUTE_BY_VERDICT["CRITIC_UNAVAILABLE"],
            retry_limit=retry_limit,
            try_again_streak=0,
            repeated_fingerprint_streak=0,
            escalated=False,
            escalation_reason="",
        )

    latest_row = rows[0]
    verdict = latest_row.get("verdict", "")
    next_role = ROUTE_BY_VERDICT.get(verdict, ROUTE_BY_VERDICT["CRITIC_UNAVAILABLE"])
    try_again_streak = 0
    repeated_fingerprint_streak = 0
    escalated = False
    escalation_reason = ""

    if verdict == "TRY_AGAIN":
        window_rows = _active_retry_window(
            conn,
            workflow_id=workflow_id,
            role=role,
            latest_review_created_at=int(latest_row.get("created_at") or 0),
        )
        try_again_streak = _count_try_again_streak(window_rows)
        repeated_fingerprint_streak = _count_repeated_fingerprint_streak(window_rows)
        if repeated_fingerprint_streak >= 2:
            next_role = "reviewer"
            escalated = True
            escalation_reason = ESCALATION_REPEATED_FINGERPRINT
        elif try_again_streak > retry_limit:
            next_role = "reviewer"
            escalated = True
            escalation_reason = ESCALATION_RETRY_LIMIT

    return CriticResolution(
        found=True,
        workflow_id=workflow_id,
        review_id=int(latest_row.get("id")) if latest_row.get("id") is not None else None,
        lease_id=str(latest_row.get("lease_id") or ""),
        role=str(latest_row.get("role") or role),
        verdict=verdict,
        provider=str(latest_row.get("provider") or ""),
        summary=str(latest_row.get("summary") or ""),
        detail=str(latest_row.get("detail") or ""),
        fingerprint=str(latest_row.get("fingerprint") or ""),
        next_role=next_role,
        retry_limit=retry_limit,
        try_again_streak=try_again_streak,
        repeated_fingerprint_streak=repeated_fingerprint_streak,
        escalated=escalated,
        escalation_reason=escalation_reason,
    )


def _active_retry_window(
    conn: sqlite3.Connection,
    *,
    workflow_id: str,
    role: str,
    latest_review_created_at: int,
) -> list[dict]:
    """Return critic reviews in the current implementer inner-loop window.

    The retry window resets after the most recent outer-loop completion
    (planner, reviewer, or guardian) that predates the latest critic row.
    This prevents a new implementer cycle, started after reviewer/planner
    adjudication, from inheriting stale TRY_AGAIN streak state.
    """

    boundary = 0
    for row in completions.list_completions(conn, workflow_id=workflow_id):
        created_at = int(row.get("created_at") or 0)
        if created_at > latest_review_created_at:
            continue
        row_role = str(row.get("role") or "")
        if row_role and row_role != role:
            boundary = created_at
            break

    rows = list_reviews(conn, workflow_id=workflow_id, role=role)
    return [row for row in rows if int(row.get("created_at") or 0) >= boundary]


def _count_try_again_streak(rows: list[dict]) -> int:
    count = 0
    for row in rows:
        if row.get("verdict") != "TRY_AGAIN":
            break
        count += 1
    return count


def _count_repeated_fingerprint_streak(rows: list[dict]) -> int:
    if not rows or rows[0].get("verdict") != "TRY_AGAIN":
        return 0
    fingerprint = str(rows[0].get("fingerprint") or "").strip()
    if not fingerprint:
        return 0

    count = 0
    for row in rows:
        if row.get("verdict") != "TRY_AGAIN":
            break
        if str(row.get("fingerprint") or "").strip() != fingerprint:
            break
        count += 1
    return count

