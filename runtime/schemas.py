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

TRACES_DDL = """
CREATE TABLE IF NOT EXISTS traces (
    session_id  TEXT    PRIMARY KEY,
    agent_role  TEXT,
    ticket      TEXT,
    started_at  INTEGER NOT NULL,
    ended_at    INTEGER,
    summary     TEXT
)
"""

TRACE_MANIFEST_DDL = """
CREATE TABLE IF NOT EXISTS trace_manifest (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id  TEXT    NOT NULL,
    entry_type  TEXT    NOT NULL,
    path        TEXT,
    detail      TEXT,
    created_at  INTEGER NOT NULL,
    FOREIGN KEY (session_id) REFERENCES traces(session_id)
)
"""

SESSION_TOKENS_DDL = """
CREATE TABLE IF NOT EXISTS session_tokens (
    session_id   TEXT    NOT NULL,
    project_hash TEXT    NOT NULL,
    total_tokens INTEGER NOT NULL DEFAULT 0,
    updated_at   INTEGER NOT NULL,
    PRIMARY KEY (session_id, project_hash)
)
"""

TODO_STATE_DDL = """
CREATE TABLE IF NOT EXISTS todo_state (
    project_hash   TEXT    PRIMARY KEY,
    project_count  INTEGER NOT NULL DEFAULT 0,
    global_count   INTEGER NOT NULL DEFAULT 0,
    updated_at     INTEGER NOT NULL
)
"""

WORKFLOW_BINDINGS_DDL = """
CREATE TABLE IF NOT EXISTS workflow_bindings (
    workflow_id   TEXT    PRIMARY KEY,
    worktree_path TEXT    NOT NULL,
    branch        TEXT    NOT NULL,
    base_branch   TEXT    NOT NULL DEFAULT 'main',
    ticket        TEXT,
    initiative    TEXT,
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL
)
"""

WORKFLOW_SCOPE_DDL = """
CREATE TABLE IF NOT EXISTS workflow_scope (
    workflow_id       TEXT    PRIMARY KEY REFERENCES workflow_bindings(workflow_id),
    allowed_paths     TEXT,
    required_paths    TEXT,
    forbidden_paths   TEXT,
    authority_domains TEXT,
    updated_at        INTEGER NOT NULL
)
"""

EVALUATION_STATE_DDL = """
CREATE TABLE IF NOT EXISTS evaluation_state (
    workflow_id  TEXT    PRIMARY KEY,
    status       TEXT    NOT NULL DEFAULT 'idle',
    head_sha     TEXT,
    blockers     INTEGER DEFAULT 0,
    major        INTEGER DEFAULT 0,
    minor        INTEGER DEFAULT 0,
    updated_at   INTEGER NOT NULL
)
"""

BUGS_DDL = """
CREATE TABLE IF NOT EXISTS bugs (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    fingerprint      TEXT    NOT NULL UNIQUE,
    bug_type         TEXT    NOT NULL,
    title            TEXT    NOT NULL,
    body             TEXT,
    scope            TEXT    NOT NULL DEFAULT 'global',
    source_component TEXT,
    file_path        TEXT,
    evidence         TEXT,
    disposition      TEXT    NOT NULL DEFAULT 'pending',
    issue_number     INTEGER,
    issue_url        TEXT,
    first_seen_at    INTEGER NOT NULL,
    last_seen_at     INTEGER NOT NULL,
    encounter_count  INTEGER NOT NULL DEFAULT 1
)
"""

APPROVALS_DDL = """
CREATE TABLE IF NOT EXISTS approvals (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    workflow_id TEXT    NOT NULL,
    op_type     TEXT    NOT NULL,
    granted_by  TEXT    NOT NULL DEFAULT 'user',
    created_at  INTEGER NOT NULL,
    consumed    INTEGER NOT NULL DEFAULT 0,
    consumed_at INTEGER
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
    TRACES_DDL,
    TRACE_MANIFEST_DDL,
    SESSION_TOKENS_DDL,
    TODO_STATE_DDL,
    WORKFLOW_BINDINGS_DDL,
    WORKFLOW_SCOPE_DDL,
    APPROVALS_DDL,
    EVALUATION_STATE_DDL,
    BUGS_DDL,
]

# Valid status values — enforced at the domain layer, not via SQL CHECK
# so that the error message is human-readable JSON rather than a constraint
# violation traceback.
PROOF_STATUSES: frozenset[str] = frozenset({"idle", "pending", "verified"})
EVALUATION_STATUSES: frozenset[str] = frozenset(
    {
        "idle",
        "pending",
        "needs_changes",
        "ready_for_guardian",
        "blocked_by_plan",
    }
)
DISPATCH_QUEUE_STATUSES: frozenset[str] = frozenset({"pending", "active", "done", "skipped"})
DISPATCH_CYCLE_STATUSES: frozenset[str] = frozenset({"active", "complete"})

# Approval token op_type values — must match approvals.py VALID_OP_TYPES.
# Enforcement happens in the domain layer (ValueError), not SQL CHECK.
APPROVAL_OP_TYPES: frozenset[str] = frozenset(
    {
        "push",
        "rebase",
        "reset",
        "force_push",
        "destructive_cleanup",
        "non_ff_merge",
    }
)


def ensure_schema(conn: sqlite3.Connection) -> None:
    """Create all tables idempotently.

    Safe to call on every startup — CREATE TABLE IF NOT EXISTS means this
    is a no-op once the schema exists. All DDL runs in a single transaction
    so a partial failure leaves the database in its prior state.
    """
    with conn:
        for ddl in ALL_DDL:
            conn.execute(ddl)
