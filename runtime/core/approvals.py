"""One-shot approval tokens for high-risk git operations.

@decision DEC-APPROVAL-001
Title: SQLite-backed approval tokens gate high-risk git ops
Status: accepted
Rationale: evaluation_state=ready_for_guardian is sufficient authority for
  routine local landing (commit, merge). High-risk operations (push, rebase,
  reset, force, destructive) require an explicit one-shot approval token
  granted by the user or orchestrator. Tokens are consumed on first use —
  each high-risk operation requires its own grant. This is the mechanical
  enforcement that replaces "ask the user in prose."

  The domain module owns all reads and writes to the approvals table.
  CLI wrappers in cli.py surface this as cc-policy approval grant/check/list.
  Shell wrappers in runtime-bridge.sh expose rt_approval_grant and
  rt_approval_check for use in guard.sh Check 13.

  Token lifecycle:
    grant()             → INSERT row with consumed=0
    check_and_consume() → UPDATE consumed=1 on first match, returns True
    check_and_consume() → returns False if no unconsumed token found (second call)
    list_pending()      → SELECT WHERE consumed=0 (read-only diagnostic)
"""

from __future__ import annotations

import sqlite3
import time
from typing import Optional

from runtime.schemas import APPROVAL_OP_TYPES

# Re-export so callers do not need to import schemas separately.
VALID_OP_TYPES: frozenset[str] = APPROVAL_OP_TYPES


def grant(
    conn: sqlite3.Connection, workflow_id: str, op_type: str, granted_by: str = "user"
) -> int:
    """Create a one-shot approval token. Returns the row id.

    Raises ValueError for unknown op_type values (validated against
    VALID_OP_TYPES / schemas.APPROVAL_OP_TYPES so both stay in sync).
    Multiple tokens may exist for the same (workflow_id, op_type) pair —
    each high-risk invocation consumes exactly one token.
    """
    if op_type not in VALID_OP_TYPES:
        raise ValueError(f"unknown op_type {op_type!r}; valid: {sorted(VALID_OP_TYPES)}")
    now = int(time.time())
    with conn:
        cursor = conn.execute(
            """INSERT INTO approvals (workflow_id, op_type, granted_by, created_at)
               VALUES (?, ?, ?, ?)""",
            (workflow_id, op_type, granted_by, now),
        )
    return cursor.lastrowid


def check_and_consume(conn: sqlite3.Connection, workflow_id: str, op_type: str) -> bool:
    """Check for an unconsumed approval, consume it atomically, return True.

    Returns False when no unconsumed token exists for (workflow_id, op_type).

    Uses a subquery to select the rowid of the earliest unconsumed token and
    updates only that row — equivalent to UPDATE ... LIMIT 1 but compatible
    with macOS system SQLite which does not compile in the SQLITE_ENABLE_UPDATE_DELETE_LIMIT
    option. SQLite serialises writes so this is safe under concurrent access.
    No ValueError raised for unknown op_type — the guard.sh gate already
    classified the op; an unknown type simply returns False.
    """
    now = int(time.time())
    with conn:
        cursor = conn.execute(
            """UPDATE approvals
               SET consumed = 1, consumed_at = ?
               WHERE rowid = (
                   SELECT rowid FROM approvals
                   WHERE workflow_id = ? AND op_type = ? AND consumed = 0
                   ORDER BY created_at ASC
                   LIMIT 1
               )""",
            (now, workflow_id, op_type),
        )
    return cursor.rowcount > 0


def list_pending(conn: sqlite3.Connection, workflow_id: Optional[str] = None) -> list[dict]:
    """List unconsumed approvals, optionally filtered by workflow_id.

    Returns a list of dicts with keys: id, workflow_id, op_type, granted_by,
    created_at. Does not return consumed_at — only unconsumed rows are shown.
    Ordered by created_at descending so the most recent grant appears first.
    """
    if workflow_id is not None:
        rows = conn.execute(
            """SELECT id, workflow_id, op_type, granted_by, created_at
               FROM approvals WHERE consumed = 0 AND workflow_id = ?
               ORDER BY created_at DESC""",
            (workflow_id,),
        ).fetchall()
    else:
        rows = conn.execute(
            """SELECT id, workflow_id, op_type, granted_by, created_at
               FROM approvals WHERE consumed = 0
               ORDER BY created_at DESC""",
        ).fetchall()
    return [dict(r) for r in rows]
