"""
Shared runtime schemas and constants.

@decision DEC-RT-001
Title: Canonical SQLite schema for all shared workflow state
Status: accepted
Rationale: All workflow state (proof, agents, events, worktrees, dispatch)
  lives in a single WAL-mode SQLite database reached through cc-policy.
  Flat files and breadcrumbs are explicitly NOT authority — they may exist
  as evidence or recovery material only (DEC-FORK-007, DEC-FORK-013).
  Tables are created idempotently via CREATE TABLE IF NOT EXISTS so schema
  bootstrapping is safe to call multiple times from any entrypoint.
"""

from __future__ import annotations

import sqlite3

# ---------------------------------------------------------------------------
# DDL — one constant per table so callers can reference individual statements
# ---------------------------------------------------------------------------

PROOF_STATE_DDL = """
CREATE TABLE IF NOT EXISTS proof_state (
    workflow_id  TEXT    PRIMARY KEY,
    status       TEXT    NOT NULL DEFAULT 'idle',
    updated_at   INTEGER NOT NULL
)
"""

AGENT_MARKERS_DDL = """
CREATE TABLE IF NOT EXISTS agent_markers (
    agent_id   TEXT    PRIMARY KEY,
    role       TEXT    NOT NULL,
    started_at INTEGER NOT NULL,
    stopped_at INTEGER,
    is_active  INTEGER NOT NULL DEFAULT 1
)
"""

EVENTS_DDL = """
CREATE TABLE IF NOT EXISTS events (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    type       TEXT    NOT NULL,
    source     TEXT,
    detail     TEXT,
    created_at INTEGER NOT NULL
)
"""

WORKTREES_DDL = """
CREATE TABLE IF NOT EXISTS worktrees (
    path       TEXT    PRIMARY KEY,
    branch     TEXT    NOT NULL,
    ticket     TEXT,
    created_at INTEGER NOT NULL,
    removed_at INTEGER
)
"""

DISPATCH_QUEUE_DDL = """
CREATE TABLE IF NOT EXISTS dispatch_queue (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    role         TEXT    NOT NULL,
    status       TEXT    NOT NULL DEFAULT 'pending',
    ticket       TEXT,
    created_at   INTEGER NOT NULL,
    started_at   INTEGER,
    completed_at INTEGER
)
"""

DISPATCH_CYCLES_DDL = """
CREATE TABLE IF NOT EXISTS dispatch_cycles (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    initiative   TEXT,
    status       TEXT    NOT NULL DEFAULT 'active',
    created_at   INTEGER NOT NULL,
    completed_at INTEGER
)
"""

# Ordered list of all DDL statements — used by ensure_schema()
ALL_DDL: list[str] = [
    PROOF_STATE_DDL,
    AGENT_MARKERS_DDL,
    EVENTS_DDL,
    WORKTREES_DDL,
    DISPATCH_QUEUE_DDL,
    DISPATCH_CYCLES_DDL,
]

# Valid status values — enforced at the domain layer, not via SQL CHECK
# so that the error message is human-readable JSON rather than a constraint
# violation traceback.
PROOF_STATUSES: frozenset[str] = frozenset({"idle", "pending", "verified"})
DISPATCH_QUEUE_STATUSES: frozenset[str] = frozenset({"pending", "active", "done", "skipped"})
DISPATCH_CYCLE_STATUSES: frozenset[str] = frozenset({"active", "complete"})


def ensure_schema(conn: sqlite3.Connection) -> None:
    """Create all tables idempotently.

    Safe to call on every startup — CREATE TABLE IF NOT EXISTS means this
    is a no-op once the schema exists. All DDL runs in a single transaction
    so a partial failure leaves the database in its prior state.
    """
    with conn:
        for ddl in ALL_DDL:
            conn.execute(ddl)
