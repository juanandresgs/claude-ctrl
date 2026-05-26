"""Proof-of-work lifecycle authority.

Owns the proof_state table. All mutations are in explicit transactions.
Status values: idle | pending | verified (see schemas.PROOF_STATUSES).

@decision DEC-RT-001
Title: Canonical SQLite schema for all shared workflow state
Status: accepted
Rationale: proof_state is one of six tables in the WAL-mode SQLite runtime
  database. This module is the sole writer of that table. Flat-file
  .proof-status-* files are superseded by this authority (TKT-007 removes
  them). All status validation happens here in Python so callers get a
  typed ValueError rather than a SQLite constraint traceback.
"""

from __future__ import annotations

import sqlite3
import time
from typing import Optional

from runtime.schemas import PROOF_STATUSES


def _row_to_dict(row: sqlite3.Row) -> dict:
    return dict(row)


def get(conn: sqlite3.Connection, workflow_id: str) -> Optional[dict]:
    """Return proof state for workflow_id, or None if not found."""
    row = conn.execute(
        "SELECT workflow_id, status, updated_at FROM proof_state WHERE workflow_id = ?",
        (workflow_id,),
    ).fetchone()
    return _row_to_dict(row) if row else None


def set_status(conn: sqlite3.Connection, workflow_id: str, status: str) -> None:
    """Upsert proof status for workflow_id.

    Raises ValueError for unknown status values so callers get a clear error
    rather than a silent DB constraint violation.
    """
    if status not in PROOF_STATUSES:
        raise ValueError(f"unknown proof status {status!r}; valid: {sorted(PROOF_STATUSES)}")
    now = int(time.time())
    with conn:
        conn.execute(
            """
            INSERT INTO proof_state (workflow_id, status, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(workflow_id) DO UPDATE SET
                status     = excluded.status,
                updated_at = excluded.updated_at
            """,
            (workflow_id, status, now),
        )


def list_all(conn: sqlite3.Connection) -> list[dict]:
    """Return all proof_state rows ordered by updated_at descending."""
    rows = conn.execute(
        "SELECT workflow_id, status, updated_at FROM proof_state ORDER BY updated_at DESC"
    ).fetchall()
    return [_row_to_dict(r) for r in rows]
