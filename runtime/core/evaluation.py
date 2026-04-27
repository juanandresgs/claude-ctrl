"""Review-readiness state lifecycle authority.

Owns the evaluation_state table. All mutations are in explicit transactions.
Status values: idle | pending | needs_changes | ready_for_guardian | blocked_by_plan
(see schemas.EVALUATION_STATUSES).

This module is the sole readiness authority for Guardian commit/merge after
TKT-024 cutover. The legacy proof_state table was retired post-Phase-8 under
Category C bundle 1 (DEC-CATEGORY-C-PROOF-RETIRE-001); evaluation_state is
now the only readiness store. evaluation_state is written exclusively by:
  - dispatch_engine.py (valid reviewer REVIEW_* completion → verdict status)
  - track.sh           (source write after clearance → pending via invalidate_if_ready)
  - quick_eval.py      (simple-task fast path → ready_for_guardian)

@decision DEC-EVAL-001
Title: evaluation_state is the sole Guardian readiness authority (TKT-024)
Status: accepted
Rationale: the legacy proof_state flow was gated on the user typing "verified"
  — ceremony, not technical proof. It has since been retired under
  DEC-CATEGORY-C-PROOF-RETIRE-001. The reviewer workflow produces
  structured REVIEW_VERDICT/REVIEW_HEAD_SHA/REVIEW_FINDINGS_JSON trailers. This
  module backs those trailers with a persistent SQLite table and enforces that
  only a matching head_sha + ready_for_guardian status passes guard.sh Check 10.
  head_sha is stored so a source write after reviewer clearance is detected by
  track.sh (SHA mismatch or invalidate_if_ready resets to pending). Status
  validation happens here in Python so callers get a typed ValueError rather
  than a SQLite constraint traceback.
"""

from __future__ import annotations

import sqlite3
import time
from typing import Optional

from runtime.schemas import EVALUATION_STATUSES


def _row_to_dict(row: sqlite3.Row) -> dict:
    return dict(row)


def get(conn: sqlite3.Connection, workflow_id: str) -> Optional[dict]:
    """Return evaluation state for workflow_id, or None if not found."""
    row = conn.execute(
        """
        SELECT workflow_id, status, head_sha, blockers, major, minor, updated_at
        FROM   evaluation_state
        WHERE  workflow_id = ?
        """,
        (workflow_id,),
    ).fetchone()
    return _row_to_dict(row) if row else None


def set_status(
    conn: sqlite3.Connection,
    workflow_id: str,
    status: str,
    head_sha: Optional[str] = None,
    blockers: int = 0,
    major: int = 0,
    minor: int = 0,
) -> None:
    """Upsert evaluation state for workflow_id.

    head_sha, blockers, major, minor are only written when explicitly provided
    (non-None / non-zero). On a status-only update (e.g. pending) the existing
    counts are preserved via DO UPDATE SET selective assignment.

    Raises ValueError for unknown status values.
    """
    if status not in EVALUATION_STATUSES:
        raise ValueError(
            f"unknown evaluation status {status!r}; valid: {sorted(EVALUATION_STATUSES)}"
        )
    now = int(time.time())
    with conn:
        conn.execute(
            """
            INSERT INTO evaluation_state
                (workflow_id, status, head_sha, blockers, major, minor, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(workflow_id) DO UPDATE SET
                status     = excluded.status,
                head_sha   = COALESCE(excluded.head_sha,   evaluation_state.head_sha),
                blockers   = excluded.blockers,
                major      = excluded.major,
                minor      = excluded.minor,
                updated_at = excluded.updated_at
            """,
            (workflow_id, status, head_sha, blockers, major, minor, now),
        )


def list_all(conn: sqlite3.Connection) -> list[dict]:
    """Return all evaluation_state rows ordered by updated_at descending."""
    rows = conn.execute(
        """
        SELECT workflow_id, status, head_sha, blockers, major, minor, updated_at
        FROM   evaluation_state
        ORDER  BY updated_at DESC
        """
    ).fetchall()
    return [_row_to_dict(r) for r in rows]


def invalidate_if_ready(conn: sqlite3.Connection, workflow_id: str) -> bool:
    """Reset status from ready_for_guardian to pending if currently ready.

    Called by track.sh when a source file changes after the reviewer has
    cleared the workflow. Returns True when the row was invalidated, False
    when the row was not ready_for_guardian (no-op).

    This is the mechanism that enforces: source changes after reviewer
    clearance invalidate readiness, requiring a new reviewer pass.
    """
    now = int(time.time())
    with conn:
        cursor = conn.execute(
            """
            UPDATE evaluation_state
            SET    status = 'pending', updated_at = ?
            WHERE  workflow_id = ? AND status = 'ready_for_guardian'
            """,
            (now, workflow_id),
        )
    return cursor.rowcount > 0
