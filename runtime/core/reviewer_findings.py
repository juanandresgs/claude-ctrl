"""Reviewer findings domain authority — structured findings ledger.

Owns the ``reviewer_findings`` table introduced in Phase 4
(DEC-CLAUDEX-REVIEWER-FINDINGS-SCHEMA-001).

A reviewer finding is a single structured observation from a reviewer round:
a code issue, a concern, or an informational note. Findings have per-finding
status transitions (open → resolved / waived) so convergence state can be
computed mechanically from the ledger without parsing freeform prose.

Authority scope
---------------
- **This module** owns every write to ``reviewer_findings``.
- Status/severity vocabularies are imported from ``runtime/schemas.py``
  (``FINDING_STATUSES``, ``FINDING_SEVERITIES``) — the single authority.
- This module does NOT import routing, hooks, evaluation_state, or
  dispatch_engine. It is pure domain code with SQLite persistence.

Status transitions
------------------
::

    insert()
      └─► open (default)
              │
              ├─ resolve()  ─► resolved
              └─ waive()    ─► waived

    resolved / waived  →  reopen()  ─► open

Terminal observation: findings do not have a "deleted" state. To remove a
finding from consideration, waive it. To reinstate it, reopen it.

@decision DEC-CLAUDEX-REVIEWER-FINDINGS-DOMAIN-001
Title: reviewer_findings domain helper is the sole authority for finding
       insert/upsert/status-transition/query
Status: accepted
Rationale: CUTOVER_PLAN §Phase 4 exit criterion — "the runtime can represent
  reviewer completions and findings natively". The completion schema
  (DEC-COMPLETION-REVIEWER-001) references REVIEW_FINDINGS_JSON as a payload
  field; this module provides the structured backing store so prompt-pack
  compilation and convergence logic can query findings by status, severity,
  file, or round without re-parsing completion payloads.
"""

from __future__ import annotations

import sqlite3
import time
import uuid
from dataclasses import dataclass
from typing import List, Optional

from runtime.schemas import FINDING_SEVERITIES, FINDING_STATUSES

__all__ = [
    "FINDING_STATUSES",
    "FINDING_SEVERITIES",
    "ReviewerFinding",
    "insert",
    "ingest_completion_findings",
    "upsert",
    "get",
    "list_findings",
    "resolve",
    "waive",
    "reopen",
    "_VALID_TRANSITIONS",
]


# ---------------------------------------------------------------------------
# Validation helpers (matches decision_work_registry discipline)
# ---------------------------------------------------------------------------


def _require_positive_int(obj: object, attr: str) -> None:
    value = getattr(obj, attr)
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(
            f"{type(obj).__name__}.{attr} must be an int; got {type(value).__name__}"
        )
    if value < 1:
        raise ValueError(
            f"{type(obj).__name__}.{attr} must be >= 1; got {value}"
        )


def _require_non_negative_int(obj: object, attr: str) -> None:
    value = getattr(obj, attr)
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(
            f"{type(obj).__name__}.{attr} must be an int; got {type(value).__name__}"
        )
    if value < 0:
        raise ValueError(
            f"{type(obj).__name__}.{attr} must be non-negative; got {value}"
        )


# ---------------------------------------------------------------------------
# Typed record shape
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ReviewerFinding:
    """A single reviewer finding record.

    All required fields are validated at construction time. Callers that
    accept dicts should convert them into this dataclass first so invalid
    data cannot reach SQLite.
    """

    finding_id: str
    workflow_id: str
    severity: str
    status: str
    title: str
    detail: str
    created_at: int
    updated_at: int
    work_item_id: Optional[str] = None
    reviewer_round: int = 0
    head_sha: Optional[str] = None
    file_path: Optional[str] = None
    line: Optional[int] = None

    def __post_init__(self):
        if not self.finding_id:
            raise ValueError("finding_id must be non-empty")
        if not self.workflow_id:
            raise ValueError("workflow_id must be non-empty")
        if not self.title:
            raise ValueError("title must be non-empty")
        if not self.detail:
            raise ValueError("detail must be non-empty")
        if self.severity not in FINDING_SEVERITIES:
            raise ValueError(
                f"severity must be one of {sorted(FINDING_SEVERITIES)}, "
                f"got {self.severity!r}"
            )
        if self.status not in FINDING_STATUSES:
            raise ValueError(
                f"status must be one of {sorted(FINDING_STATUSES)}, "
                f"got {self.status!r}"
            )
        _require_non_negative_int(self, "reviewer_round")
        if self.line is not None:
            _require_positive_int(self, "line")
        _require_non_negative_int(self, "created_at")
        _require_non_negative_int(self, "updated_at")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _generate_finding_id() -> str:
    return str(uuid.uuid4())


def _now() -> int:
    return int(time.time())


def _row_to_finding(row: sqlite3.Row) -> ReviewerFinding:
    d = dict(row)
    return ReviewerFinding(**d)


# ---------------------------------------------------------------------------
# Write operations
# ---------------------------------------------------------------------------


def _insert_finding(
    conn: sqlite3.Connection,
    *,
    workflow_id: str,
    severity: str,
    title: str,
    detail: str,
    work_item_id: Optional[str] = None,
    reviewer_round: int = 0,
    head_sha: Optional[str] = None,
    file_path: Optional[str] = None,
    line: Optional[int] = None,
    finding_id: Optional[str] = None,
) -> ReviewerFinding:
    """Validate, build, and execute INSERT without managing a transaction.

    Private helper — callers are responsible for wrapping in a
    ``with conn:`` block or using an existing transaction. This
    separation lets :func:`insert` keep its public self-transacting
    behavior while :func:`ingest_completion_findings` can batch
    multiple inserts under the caller's transaction for atomicity.
    """
    now = _now()
    fid = finding_id or _generate_finding_id()
    finding = ReviewerFinding(
        finding_id=fid,
        workflow_id=workflow_id,
        severity=severity,
        status="open",
        title=title,
        detail=detail,
        created_at=now,
        updated_at=now,
        work_item_id=work_item_id,
        reviewer_round=reviewer_round,
        head_sha=head_sha,
        file_path=file_path,
        line=line,
    )
    conn.execute(
        """INSERT INTO reviewer_findings
           (finding_id, workflow_id, work_item_id, reviewer_round, head_sha,
            severity, status, title, detail, file_path, line,
            created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            finding.finding_id,
            finding.workflow_id,
            finding.work_item_id,
            finding.reviewer_round,
            finding.head_sha,
            finding.severity,
            finding.status,
            finding.title,
            finding.detail,
            finding.file_path,
            finding.line,
            finding.created_at,
            finding.updated_at,
        ),
    )
    return finding


def insert(
    conn: sqlite3.Connection,
    *,
    workflow_id: str,
    severity: str,
    title: str,
    detail: str,
    work_item_id: Optional[str] = None,
    reviewer_round: int = 0,
    head_sha: Optional[str] = None,
    file_path: Optional[str] = None,
    line: Optional[int] = None,
    finding_id: Optional[str] = None,
) -> ReviewerFinding:
    """Insert a new finding. Returns the validated ReviewerFinding."""
    with conn:
        return _insert_finding(
            conn,
            workflow_id=workflow_id,
            severity=severity,
            title=title,
            detail=detail,
            work_item_id=work_item_id,
            reviewer_round=reviewer_round,
            head_sha=head_sha,
            file_path=file_path,
            line=line,
            finding_id=finding_id,
        )


def ingest_completion_findings(
    conn: sqlite3.Connection,
    *,
    workflow_id: str,
    findings: list[dict],
    default_head_sha: Optional[str] = None,
) -> list[ReviewerFinding]:
    """Persist findings from a validated reviewer completion payload.

    This is the bridge between the completion payload shape
    (``REVIEW_FINDINGS_JSON``) and the reviewer findings ledger.
    Each item in ``findings`` is inserted via :func:`_insert_finding`
    — the module-private INSERT helper that does not manage its own
    transaction. This lets the caller's ``with conn:`` block govern
    commit/rollback for all findings atomically.

    Parameters:

      * ``conn`` — open SQLite connection. The caller MUST manage
        the transaction (e.g. ``with conn:``) so that all findings
        commit or roll back together with any surrounding writes.
      * ``workflow_id`` — required; propagated to every finding.
      * ``findings`` — list of dicts, each with at minimum
        ``severity``, ``title``, ``detail``. Optional fields
        (``work_item_id``, ``reviewer_round``, ``head_sha``,
        ``file_path``, ``line``, ``finding_id``) are forwarded
        when present.
      * ``default_head_sha`` — used when a finding item omits
        ``head_sha``. Typically ``REVIEW_HEAD_SHA`` from the
        completion payload.

    Returns the list of persisted :class:`ReviewerFinding` instances
    in insertion order.
    """
    persisted: list[ReviewerFinding] = []
    for item in findings:
        kwargs: dict = {
            "workflow_id": workflow_id,
            "severity": item["severity"],
            "title": item["title"],
            "detail": item["detail"],
        }
        # Optional fields — forward when present in the item.
        if "work_item_id" in item:
            kwargs["work_item_id"] = item["work_item_id"]
        if "file_path" in item:
            kwargs["file_path"] = item["file_path"]
        if "finding_id" in item:
            kwargs["finding_id"] = item["finding_id"]

        # head_sha: item-supplied wins, else default from completion.
        kwargs["head_sha"] = item.get("head_sha", default_head_sha)

        # reviewer_round: forward only if item supplies it (else ledger default).
        if "reviewer_round" in item:
            kwargs["reviewer_round"] = item["reviewer_round"]

        # line: forward only if item supplies it.
        if "line" in item:
            kwargs["line"] = item["line"]

        persisted.append(_insert_finding(conn, **kwargs))
    return persisted


def upsert(
    conn: sqlite3.Connection,
    *,
    finding_id: str,
    workflow_id: str,
    severity: str,
    status: str,
    title: str,
    detail: str,
    work_item_id: Optional[str] = None,
    reviewer_round: int = 0,
    head_sha: Optional[str] = None,
    file_path: Optional[str] = None,
    line: Optional[int] = None,
) -> ReviewerFinding:
    """Insert or update a finding by finding_id.

    On conflict (existing finding_id):
      - Fails loud if ``workflow_id`` differs from the stored row — a finding
        cannot silently migrate between workflows.
      - Status changes on existing rows are validated against
        ``_VALID_TRANSITIONS`` — the same authority used by ``resolve()``,
        ``waive()``, and ``reopen()``. An invalid status transition raises
        ``ValueError`` and leaves the row unchanged. Callers that pass the
        same status as the stored row skip transition validation (no-op on
        status).
      - Updates ``work_item_id`` deterministically to the caller's value (may
        be None to clear it).
      - Updates severity, title, detail, head_sha, reviewer_round,
        file_path, line, and updated_at.
      - Preserves ``created_at`` from the original insert.

    Returns the persisted row (re-read from DB) so the returned object always
    matches stored state.
    """
    now = _now()
    # Validate caller inputs via dataclass construction.
    finding = ReviewerFinding(
        finding_id=finding_id,
        workflow_id=workflow_id,
        severity=severity,
        status=status,
        title=title,
        detail=detail,
        created_at=now,
        updated_at=now,
        work_item_id=work_item_id,
        reviewer_round=reviewer_round,
        head_sha=head_sha,
        file_path=file_path,
        line=line,
    )

    # Check for workflow_id mismatch and status transition validity on
    # existing rows.
    existing = get(conn, finding_id)
    if existing is not None:
        if existing.workflow_id != workflow_id:
            raise ValueError(
                f"Cannot upsert finding {finding_id!r}: workflow_id mismatch — "
                f"stored {existing.workflow_id!r}, caller {workflow_id!r}. "
                f"A finding cannot migrate between workflows."
            )
        # Validate status change against _VALID_TRANSITIONS (the single
        # authority). Same-status is always allowed (no transition).
        if status != existing.status:
            allowed = _VALID_TRANSITIONS.get(existing.status, frozenset())
            if status not in allowed:
                raise ValueError(
                    f"Cannot upsert finding {finding_id!r}: invalid status "
                    f"transition {existing.status!r} -> {status!r}. "
                    f"Allowed from {existing.status!r}: {sorted(allowed)}"
                )

    with conn:
        conn.execute(
            """INSERT INTO reviewer_findings
               (finding_id, workflow_id, work_item_id, reviewer_round, head_sha,
                severity, status, title, detail, file_path, line,
                created_at, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(finding_id) DO UPDATE SET
                 work_item_id = excluded.work_item_id,
                 status = excluded.status,
                 severity = excluded.severity,
                 title = excluded.title,
                 detail = excluded.detail,
                 head_sha = excluded.head_sha,
                 reviewer_round = excluded.reviewer_round,
                 file_path = excluded.file_path,
                 line = excluded.line,
                 updated_at = excluded.updated_at""",
            (
                finding.finding_id,
                finding.workflow_id,
                finding.work_item_id,
                finding.reviewer_round,
                finding.head_sha,
                finding.severity,
                finding.status,
                finding.title,
                finding.detail,
                finding.file_path,
                finding.line,
                finding.created_at,
                finding.updated_at,
            ),
        )
    # Re-read from DB so the returned object reflects the persisted state
    # (e.g. created_at preserved from the original insert on conflict).
    persisted = get(conn, finding_id)
    assert persisted is not None, f"upsert failed: {finding_id!r} not found after write"
    return persisted


# Valid status transitions. Key is the current status, value is the set of
# statuses reachable from it. Enforced in _transition_status().
_VALID_TRANSITIONS: dict[str, frozenset[str]] = {
    "open": frozenset({"resolved", "waived"}),
    "resolved": frozenset({"open"}),
    "waived": frozenset({"open"}),
}


def _transition_status(
    conn: sqlite3.Connection,
    finding_id: str,
    target_status: str,
) -> Optional[ReviewerFinding]:
    """Transition a finding to target_status.

    Returns the updated finding, or None if finding_id does not exist.
    Raises ValueError if the transition is not in _VALID_TRANSITIONS.
    """
    existing = get(conn, finding_id)
    if existing is None:
        return None

    allowed = _VALID_TRANSITIONS.get(existing.status, frozenset())
    if target_status not in allowed:
        raise ValueError(
            f"Invalid status transition for finding {finding_id!r}: "
            f"{existing.status!r} -> {target_status!r}. "
            f"Allowed from {existing.status!r}: {sorted(allowed)}"
        )

    now = _now()
    with conn:
        conn.execute(
            "UPDATE reviewer_findings SET status = ?, updated_at = ? WHERE finding_id = ?",
            (target_status, now, finding_id),
        )
    return get(conn, finding_id)


def resolve(conn: sqlite3.Connection, finding_id: str) -> Optional[ReviewerFinding]:
    """Transition finding from 'open' to 'resolved'.

    Raises ValueError if the finding is not in 'open' status.
    Returns None if the finding does not exist.
    """
    return _transition_status(conn, finding_id, "resolved")


def waive(conn: sqlite3.Connection, finding_id: str) -> Optional[ReviewerFinding]:
    """Transition finding from 'open' to 'waived'.

    Raises ValueError if the finding is not in 'open' status.
    Returns None if the finding does not exist.
    """
    return _transition_status(conn, finding_id, "waived")


def reopen(conn: sqlite3.Connection, finding_id: str) -> Optional[ReviewerFinding]:
    """Transition finding from 'resolved' or 'waived' back to 'open'.

    Raises ValueError if the finding is already 'open'.
    Returns None if the finding does not exist.
    """
    return _transition_status(conn, finding_id, "open")


# ---------------------------------------------------------------------------
# Read operations
# ---------------------------------------------------------------------------


def get(conn: sqlite3.Connection, finding_id: str) -> Optional[ReviewerFinding]:
    """Fetch a single finding by ID, or None."""
    row = conn.execute(
        "SELECT * FROM reviewer_findings WHERE finding_id = ?",
        (finding_id,),
    ).fetchone()
    return _row_to_finding(row) if row else None


def list_findings(
    conn: sqlite3.Connection,
    *,
    workflow_id: Optional[str] = None,
    work_item_id: Optional[str] = None,
    status: Optional[str] = None,
    severity: Optional[str] = None,
    reviewer_round: Optional[int] = None,
) -> List[ReviewerFinding]:
    """List findings with optional filters, ordered by created_at DESC.

    Filters are validated against the same vocabularies as the dataclass:
      - ``status`` must be in FINDING_STATUSES
      - ``severity`` must be in FINDING_SEVERITIES
      - ``reviewer_round`` must be a non-negative int (not bool)

    Raises ValueError on invalid filter values so bad queries fail loudly
    instead of silently returning empty results.
    """
    if status is not None and status not in FINDING_STATUSES:
        raise ValueError(
            f"Invalid status filter {status!r}; "
            f"must be one of {sorted(FINDING_STATUSES)}"
        )
    if severity is not None and severity not in FINDING_SEVERITIES:
        raise ValueError(
            f"Invalid severity filter {severity!r}; "
            f"must be one of {sorted(FINDING_SEVERITIES)}"
        )
    if reviewer_round is not None:
        if isinstance(reviewer_round, bool) or not isinstance(reviewer_round, int):
            raise ValueError(
                f"reviewer_round filter must be an int; "
                f"got {type(reviewer_round).__name__}"
            )
        if reviewer_round < 0:
            raise ValueError(
                f"reviewer_round filter must be >= 0; got {reviewer_round}"
            )

    clauses: list[str] = []
    params: list = []
    if workflow_id is not None:
        clauses.append("workflow_id = ?")
        params.append(workflow_id)
    if work_item_id is not None:
        clauses.append("work_item_id = ?")
        params.append(work_item_id)
    if status is not None:
        clauses.append("status = ?")
        params.append(status)
    if severity is not None:
        clauses.append("severity = ?")
        params.append(severity)
    if reviewer_round is not None:
        clauses.append("reviewer_round = ?")
        params.append(reviewer_round)

    where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
    rows = conn.execute(
        f"SELECT * FROM reviewer_findings {where} ORDER BY created_at DESC",
        params,
    ).fetchall()
    return [_row_to_finding(r) for r in rows]
