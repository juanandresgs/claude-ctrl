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

import os
import shutil
import sqlite3
import tempfile
import time

SCHEMA_MAJOR: int = 6
SCHEMA_NAME: str = "claude-ctrl-v6"

# ---------------------------------------------------------------------------
# DDL — one constant per table so callers can reference individual statements
# ---------------------------------------------------------------------------

SCHEMA_METADATA_DDL = """
CREATE TABLE IF NOT EXISTS schema_metadata (
    key        TEXT PRIMARY KEY,
    value      TEXT NOT NULL,
    updated_at INTEGER NOT NULL
)
"""

PROOF_STATE_DDL = """
CREATE TABLE IF NOT EXISTS proof_state (
    workflow_id  TEXT    PRIMARY KEY,
    status       TEXT    NOT NULL DEFAULT 'idle',
    updated_at   INTEGER NOT NULL
)
"""

AGENT_MARKERS_DDL = """
CREATE TABLE IF NOT EXISTS agent_markers (
    agent_id    TEXT    PRIMARY KEY,
    role        TEXT    NOT NULL,
    started_at  INTEGER NOT NULL,
    stopped_at  INTEGER,
    is_active   INTEGER NOT NULL DEFAULT 1,
    status      TEXT    NOT NULL DEFAULT 'active',
    workflow_id TEXT
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

GOALS_DDL = """
CREATE TABLE IF NOT EXISTS goals (
    id             TEXT PRIMARY KEY,
    workflow_id    TEXT NOT NULL,
    title          TEXT NOT NULL,
    prompt_text    TEXT,
    status         TEXT NOT NULL DEFAULT 'active',
    created_at     INTEGER NOT NULL,
    updated_at     INTEGER NOT NULL
)
"""

GOAL_INDEXES_DDL: list[str] = [
    """CREATE INDEX IF NOT EXISTS idx_goals_workflow_status
       ON goals (workflow_id, status, created_at DESC)""",
]

WORK_ITEMS_DDL = """
CREATE TABLE IF NOT EXISTS work_items (
    id             TEXT PRIMARY KEY,
    goal_id        TEXT NOT NULL REFERENCES goals(id),
    workflow_id    TEXT NOT NULL,
    title          TEXT NOT NULL,
    prompt_text    TEXT,
    status         TEXT NOT NULL DEFAULT 'active',
    created_at     INTEGER NOT NULL,
    updated_at     INTEGER NOT NULL
)
"""

WORK_ITEM_INDEXES_DDL: list[str] = [
    """CREATE INDEX IF NOT EXISTS idx_work_items_goal_status
       ON work_items (goal_id, status, created_at DESC)""",
    """CREATE INDEX IF NOT EXISTS idx_work_items_workflow_status
       ON work_items (workflow_id, status, created_at DESC)""",
]

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

DISPATCH_LEASES_DDL = """
CREATE TABLE IF NOT EXISTS dispatch_leases (
    lease_id           TEXT    PRIMARY KEY,
    agent_id           TEXT,
    role               TEXT    NOT NULL,
    workflow_id        TEXT,
    worktree_path      TEXT,
    branch             TEXT,
    allowed_ops_json   TEXT    NOT NULL DEFAULT '["routine_local"]',
    blocked_ops_json   TEXT    NOT NULL DEFAULT '[]',
    requires_eval      INTEGER NOT NULL DEFAULT 1,
    head_sha           TEXT,
    approval_scope_json TEXT,
    next_step          TEXT,
    status             TEXT    NOT NULL DEFAULT 'active',
    issued_at          INTEGER NOT NULL,
    expires_at         INTEGER NOT NULL,
    released_at        INTEGER,
    metadata_json      TEXT
)
"""

DISPATCH_LEASES_INDEXES_DDL: list[str] = [
    """CREATE INDEX IF NOT EXISTS idx_lease_worktree_active
       ON dispatch_leases (worktree_path, status) WHERE status = 'active'""",
    """CREATE INDEX IF NOT EXISTS idx_lease_agent_active
       ON dispatch_leases (agent_id, status) WHERE status = 'active'""",
    """CREATE INDEX IF NOT EXISTS idx_lease_workflow_active
       ON dispatch_leases (workflow_id, status) WHERE status = 'active'""",
    """CREATE INDEX IF NOT EXISTS idx_lease_status
       ON dispatch_leases (status)""",
]

COMPLETION_RECORDS_DDL = """
CREATE TABLE IF NOT EXISTS completion_records (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    lease_id        TEXT    NOT NULL,
    workflow_id     TEXT    NOT NULL,
    role            TEXT    NOT NULL,
    verdict         TEXT    NOT NULL,
    valid           INTEGER NOT NULL DEFAULT 0,
    payload_json    TEXT    NOT NULL,
    missing_fields  TEXT,
    created_at      INTEGER NOT NULL
)
"""

TEST_STATE_DDL = """
CREATE TABLE IF NOT EXISTS test_state (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    project_root TEXT    NOT NULL UNIQUE,
    head_sha     TEXT,
    status       TEXT    NOT NULL DEFAULT 'unknown',
    pass_count   INTEGER NOT NULL DEFAULT 0,
    fail_count   INTEGER NOT NULL DEFAULT 0,
    total_count  INTEGER NOT NULL DEFAULT 0,
    updated_at   INTEGER NOT NULL
)
"""

TEST_STATE_INDEX_DDL = (
    "CREATE INDEX IF NOT EXISTS idx_test_state_project ON test_state (project_root)"
)

# ---------------------------------------------------------------------------
# v6 stage-machine dispatch authority
# ---------------------------------------------------------------------------

STAGE_RUNS_DDL = """
CREATE TABLE IF NOT EXISTS stage_runs (
    id               TEXT PRIMARY KEY,
    workflow_id      TEXT NOT NULL,
    goal_id          TEXT NOT NULL,
    work_item_id     TEXT NOT NULL,
    stage_id         TEXT NOT NULL,
    status           TEXT NOT NULL DEFAULT 'pending',
    parent_run_id    TEXT,
    launch_ticket_id TEXT,
    agent_id         TEXT,
    session_id       TEXT,
    worktree_path    TEXT,
    lease_id         TEXT,
    input_json       TEXT NOT NULL DEFAULT '{}',
    result_json      TEXT,
    metadata_json    TEXT,
    created_at       INTEGER NOT NULL,
    updated_at       INTEGER NOT NULL,
    expires_at       INTEGER
)
"""

STAGE_RUNS_INDEXES_DDL: list[str] = [
    """CREATE INDEX IF NOT EXISTS idx_stage_runs_workflow_status
       ON stage_runs (workflow_id, status, created_at DESC)""",
    """CREATE INDEX IF NOT EXISTS idx_stage_runs_ticket
       ON stage_runs (launch_ticket_id) WHERE launch_ticket_id IS NOT NULL""",
    """CREATE INDEX IF NOT EXISTS idx_stage_runs_parent
       ON stage_runs (parent_run_id) WHERE parent_run_id IS NOT NULL""",
]

LAUNCH_TICKETS_DDL = """
CREATE TABLE IF NOT EXISTS launch_tickets (
    id             TEXT PRIMARY KEY,
    stage_run_id   TEXT NOT NULL REFERENCES stage_runs(id),
    workflow_id    TEXT NOT NULL,
    stage_id       TEXT NOT NULL,
    subagent_type  TEXT NOT NULL,
    worktree_path  TEXT,
    status         TEXT NOT NULL DEFAULT 'pending',
    prompt_digest  TEXT NOT NULL,
    claim_token    TEXT,
    session_id     TEXT,
    agent_id       TEXT,
    metadata_json  TEXT,
    created_at     INTEGER NOT NULL,
    claimed_at     INTEGER,
    expires_at     INTEGER NOT NULL
)
"""

LAUNCH_TICKETS_INDEXES_DDL: list[str] = [
    """CREATE INDEX IF NOT EXISTS idx_launch_tickets_status
       ON launch_tickets (status, expires_at)""",
    """CREATE INDEX IF NOT EXISTS idx_launch_tickets_stage_run
       ON launch_tickets (stage_run_id)""",
    """CREATE UNIQUE INDEX IF NOT EXISTS idx_launch_tickets_claim_token
       ON launch_tickets (claim_token) WHERE claim_token IS NOT NULL""",
]

STAGE_RESULTS_DDL = """
CREATE TABLE IF NOT EXISTS stage_results (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    stage_run_id        TEXT NOT NULL REFERENCES stage_runs(id),
    workflow_id         TEXT NOT NULL,
    stage_id            TEXT NOT NULL,
    verdict             TEXT NOT NULL,
    valid               INTEGER NOT NULL DEFAULT 0,
    payload_json        TEXT NOT NULL,
    missing_fields_json TEXT,
    created_at          INTEGER NOT NULL
)
"""

STAGE_RESULTS_INDEXES_DDL: list[str] = [
    """CREATE INDEX IF NOT EXISTS idx_stage_results_run
       ON stage_results (stage_run_id, created_at DESC)""",
    """CREATE INDEX IF NOT EXISTS idx_stage_results_workflow
       ON stage_results (workflow_id, created_at DESC)""",
]

DISPATCH_NEXT_ACTIONS_V6_DDL = """
CREATE TABLE IF NOT EXISTS dispatch_next_actions_v6 (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    workflow_id         TEXT NOT NULL,
    source_stage_run_id TEXT NOT NULL,
    next_stage_run_id   TEXT NOT NULL,
    source_stage        TEXT NOT NULL,
    next_stage          TEXT NOT NULL,
    reason              TEXT,
    payload_json        TEXT NOT NULL DEFAULT '{}',
    status              TEXT NOT NULL DEFAULT 'pending',
    ticket_id           TEXT,
    created_at          INTEGER NOT NULL,
    updated_at          INTEGER
)
"""

DISPATCH_NEXT_ACTIONS_V6_INDEXES_DDL: list[str] = [
    """CREATE INDEX IF NOT EXISTS idx_dispatch_next_actions_v6_pending
       ON dispatch_next_actions_v6 (workflow_id, status, created_at)""",
    """CREATE INDEX IF NOT EXISTS idx_dispatch_next_actions_v6_next_run
       ON dispatch_next_actions_v6 (next_stage_run_id)""",
]

CRITIC_RUNS_DDL = """
CREATE TABLE IF NOT EXISTS critic_runs (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    stage_run_id          TEXT NOT NULL REFERENCES stage_runs(id),
    workflow_id           TEXT NOT NULL,
    provider              TEXT NOT NULL,
    status                TEXT NOT NULL,
    verdict               TEXT,
    summary               TEXT,
    prompt_text           TEXT,
    raw_output            TEXT,
    execution_proof_json  TEXT NOT NULL DEFAULT '{}',
    error                 TEXT,
    started_at            INTEGER NOT NULL,
    completed_at          INTEGER,
    timeout_seconds       INTEGER NOT NULL DEFAULT 60
)
"""

CRITIC_RUNS_INDEXES_DDL: list[str] = [
    """CREATE INDEX IF NOT EXISTS idx_critic_runs_stage_run
       ON critic_runs (stage_run_id, started_at DESC)""",
    """CREATE INDEX IF NOT EXISTS idx_critic_runs_workflow
       ON critic_runs (workflow_id, started_at DESC)""",
]

V6_LANDING_READINESS_DDL = """
CREATE TABLE IF NOT EXISTS v6_landing_readiness (
    guardian_stage_run_id TEXT PRIMARY KEY REFERENCES stage_runs(id),
    reviewer_stage_run_id TEXT NOT NULL REFERENCES stage_runs(id),
    workflow_id           TEXT NOT NULL,
    status                TEXT NOT NULL,
    head_sha              TEXT NOT NULL,
    worktree_path         TEXT NOT NULL,
    missing_json          TEXT NOT NULL DEFAULT '[]',
    evidence_json         TEXT NOT NULL DEFAULT '{}',
    created_at            INTEGER NOT NULL,
    updated_at            INTEGER NOT NULL
)
"""

V6_LANDING_READINESS_INDEXES_DDL: list[str] = [
    """CREATE INDEX IF NOT EXISTS idx_v6_landing_readiness_workflow
       ON v6_landing_readiness (workflow_id, status, updated_at DESC)""",
    """CREATE INDEX IF NOT EXISTS idx_v6_landing_readiness_reviewer
       ON v6_landing_readiness (reviewer_stage_run_id)""",
]

# ---------------------------------------------------------------------------
# Observatory DDL (W-OBS-1)
# ---------------------------------------------------------------------------

OBS_METRICS_DDL = """
CREATE TABLE IF NOT EXISTS obs_metrics (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    metric_name TEXT    NOT NULL,
    value       REAL    NOT NULL,
    role        TEXT,
    labels_json TEXT,
    session_id  TEXT,
    created_at  INTEGER NOT NULL
)
"""

OBS_METRICS_INDEXES_DDL: list[str] = [
    """CREATE INDEX IF NOT EXISTS idx_obs_metrics_name_time
       ON obs_metrics (metric_name, created_at)""",
    """CREATE INDEX IF NOT EXISTS idx_obs_metrics_role
       ON obs_metrics (role) WHERE role IS NOT NULL""",
]

OBS_SUGGESTIONS_DDL = """
CREATE TABLE IF NOT EXISTS obs_suggestions (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    signal_id       TEXT,
    category        TEXT    NOT NULL,
    title           TEXT    NOT NULL,
    body            TEXT,
    target_metric   TEXT,
    baseline_value  REAL,
    status          TEXT    NOT NULL DEFAULT 'proposed',
    reject_reason   TEXT,
    disposition_at  INTEGER,
    measure_after   INTEGER,
    measured_value  REAL,
    effective       INTEGER,
    defer_reassess_after INTEGER,
    source_session  TEXT,
    created_at      INTEGER NOT NULL
)
"""

OBS_SUGGESTIONS_INDEXES_DDL: list[str] = [
    """CREATE INDEX IF NOT EXISTS idx_obs_suggestions_status
       ON obs_suggestions (status)""",
    """CREATE INDEX IF NOT EXISTS idx_obs_suggestions_signal
       ON obs_suggestions (signal_id) WHERE signal_id IS NOT NULL""",
]

OBS_RUNS_DDL = """
CREATE TABLE IF NOT EXISTS obs_runs (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    ran_at           INTEGER NOT NULL,
    metrics_snapshot TEXT,
    trace_count      INTEGER,
    suggestion_count INTEGER
)
"""

# @decision DEC-CONFIG-AUTHORITY-001
# Title: Policy engine is the canonical authority for enforcement toggles
# Status: accepted
# Rationale: Before this table, enforcement toggles were scattered across
#   settings.json, the codex plugin's state.json, and hardcoded defaults.
#   The policy engine had no knowledge of plugin-side toggles. This table
#   centralises toggle storage in cc_state.db so that cc-policy is the sole
#   authority. Plugin code (codex setup) becomes a thin shim that delegates
#   to this module via cc-policy config set. Scope precedence (lookup order):
#   workflow=<id> → project=<root> → global → None
ENFORCEMENT_CONFIG_DDL = """
CREATE TABLE IF NOT EXISTS enforcement_config (
    scope       TEXT NOT NULL,         -- 'global' | 'project=<root>' | 'workflow=<id>'
    key         TEXT NOT NULL,         -- e.g. 'review_gate_regular_stop'
    value       TEXT NOT NULL,         -- string-encoded; callers parse
    updated_at  INTEGER NOT NULL,
    PRIMARY KEY (scope, key)
)
"""

ENFORCEMENT_CONFIG_INDEX_DDL = """
CREATE INDEX IF NOT EXISTS idx_enforcement_config_key ON enforcement_config (key, scope)
"""

# Ordered list of all DDL statements — used by ensure_schema()
ALL_DDL: list[str] = [
    SCHEMA_METADATA_DDL,
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
    GOALS_DDL,
    WORK_ITEMS_DDL,
    APPROVALS_DDL,
    EVALUATION_STATE_DDL,
    BUGS_DDL,
    DISPATCH_LEASES_DDL,
    COMPLETION_RECORDS_DDL,
    TEST_STATE_DDL,
    STAGE_RUNS_DDL,
    LAUNCH_TICKETS_DDL,
    STAGE_RESULTS_DDL,
    DISPATCH_NEXT_ACTIONS_V6_DDL,
    CRITIC_RUNS_DDL,
    V6_LANDING_READINESS_DDL,
    OBS_METRICS_DDL,
    OBS_SUGGESTIONS_DDL,
    OBS_RUNS_DDL,
    ENFORCEMENT_CONFIG_DDL,
    ENFORCEMENT_CONFIG_INDEX_DDL,
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
        # Admin recovery: merge --abort and reset --merge.
        # These require an approval token but NOT evaluation readiness.
        "admin_recovery",
    }
)

# Lease lifecycle statuses — enforced at domain layer, not SQL CHECK.
LEASE_STATUSES: frozenset[str] = frozenset({"active", "released", "revoked", "expired"})

STAGE_RUN_STATUSES: frozenset[str] = frozenset(
    {"pending", "launched", "running", "completed", "blocked", "failed", "cancelled", "expired"}
)
LAUNCH_TICKET_STATUSES: frozenset[str] = frozenset(
    {"pending", "claimed", "failed", "expired", "cancelled"}
)
DISPATCH_NEXT_ACTION_V6_STATUSES: frozenset[str] = frozenset(
    {"pending", "ticketed", "claimed", "completed", "cancelled", "expired", "worker_pending"}
)

# Default lease time-to-live: 2 hours.
DEFAULT_LEASE_TTL: int = 7200


def _quote_identifier(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def _database_file(conn: sqlite3.Connection) -> str:
    row = conn.execute("PRAGMA database_list").fetchone()
    if row is None:
        return ""
    return str(row[2] or "")


def _user_objects(conn: sqlite3.Connection) -> list[sqlite3.Row]:
    return list(
        conn.execute(
            """
            SELECT type, name
            FROM sqlite_master
            WHERE type IN ('table', 'index', 'trigger', 'view')
              AND name NOT LIKE 'sqlite_%'
            ORDER BY
              CASE type
                WHEN 'view' THEN 1
                WHEN 'trigger' THEN 2
                WHEN 'index' THEN 3
                WHEN 'table' THEN 4
                ELSE 5
              END,
              name
            """
        ).fetchall()
    )


def _table_exists(conn: sqlite3.Connection, table_name: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        (table_name,),
    ).fetchone()
    return row is not None


def _read_schema_major(conn: sqlite3.Connection) -> str:
    if not _table_exists(conn, "schema_metadata"):
        return ""
    row = conn.execute(
        "SELECT value FROM schema_metadata WHERE key = 'schema_major'"
    ).fetchone()
    return str(row[0]) if row is not None else ""


def _metadata_map(conn: sqlite3.Connection) -> dict[str, str]:
    if not _table_exists(conn, "schema_metadata"):
        return {}
    return {
        str(row[0]): str(row[1])
        for row in conn.execute("SELECT key, value FROM schema_metadata").fetchall()
    }


def _copy_sqlite_snapshot(source: str, destination: str) -> None:
    """Copy a DB, including WAL state, without mutating the source DB."""
    try:
        src = sqlite3.connect(source)
        try:
            dst = sqlite3.connect(destination)
            try:
                src.backup(dst)
            finally:
                dst.close()
        finally:
            src.close()
    except sqlite3.Error:
        shutil.copy2(source, destination)


def _archive_database(conn: sqlite3.Connection) -> str:
    db_file = _database_file(conn)
    if not db_file or db_file == ":memory:" or not os.path.exists(db_file):
        return ""

    archive = f"{db_file}.pre-v{SCHEMA_MAJOR}-{int(time.time())}.bak"
    try:
        conn.execute("PRAGMA wal_checkpoint(FULL)")
    except sqlite3.Error:
        pass

    try:
        conn.execute("VACUUM INTO ?", (archive,))
    except sqlite3.Error:
        shutil.copy2(db_file, archive)
    return archive


def _drop_all_user_objects(conn: sqlite3.Connection) -> None:
    conn.execute("PRAGMA foreign_keys=OFF")
    for row in _user_objects(conn):
        obj_type = row[0]
        name = row[1]
        quoted = _quote_identifier(name)
        if obj_type == "table":
            conn.execute(f"DROP TABLE IF EXISTS {quoted}")
        elif obj_type == "index":
            conn.execute(f"DROP INDEX IF EXISTS {quoted}")
        elif obj_type == "trigger":
            conn.execute(f"DROP TRIGGER IF EXISTS {quoted}")
        elif obj_type == "view":
            conn.execute(f"DROP VIEW IF EXISTS {quoted}")
    conn.execute("PRAGMA foreign_keys=ON")


def _reset_for_current_major(conn: sqlite3.Connection, reason: str) -> str:
    """Archive and reset the live DB so v6 starts from a known schema."""
    try:
        conn.rollback()
    except sqlite3.Error:
        pass

    archive = _archive_database(conn)
    _drop_all_user_objects(conn)
    conn.execute(SCHEMA_METADATA_DDL)
    _stamp_current_major(conn)
    conn.execute(
        """
        INSERT INTO schema_metadata (key, value, updated_at)
        VALUES ('last_reset_reason', ?, CAST(strftime('%s','now') AS INTEGER))
        ON CONFLICT(key) DO UPDATE SET
            value = excluded.value,
            updated_at = excluded.updated_at
        """,
        (reason,),
    )
    if archive:
        conn.execute(
            """
            INSERT INTO schema_metadata (key, value, updated_at)
            VALUES ('last_archive_path', ?, CAST(strftime('%s','now') AS INTEGER))
            ON CONFLICT(key) DO UPDATE SET
                value = excluded.value,
                updated_at = excluded.updated_at
            """,
            (archive,),
        )
    return archive


def _schema_shape_error(exc: sqlite3.OperationalError) -> bool:
    msg = str(exc).lower()
    return "no such column" in msg or "no such table" in msg


def _require_current_major(conn: sqlite3.Connection) -> None:
    objects = _user_objects(conn)
    if not objects:
        return

    major = _read_schema_major(conn)
    if major == str(SCHEMA_MAJOR):
        return

    _reset_for_current_major(conn, f"schema_major_mismatch:{major or 'missing'}")


def _stamp_current_major(conn: sqlite3.Connection) -> None:
    conn.execute(SCHEMA_METADATA_DDL)
    for key, value in (
        ("schema_major", str(SCHEMA_MAJOR)),
        ("schema_name", SCHEMA_NAME),
    ):
        conn.execute(
            """
            INSERT INTO schema_metadata (key, value, updated_at)
            VALUES (?, ?, CAST(strftime('%s','now') AS INTEGER))
            ON CONFLICT(key) DO UPDATE SET
                value = excluded.value,
                updated_at = excluded.updated_at
            """,
            (key, value),
        )


def schema_status(conn: sqlite3.Connection) -> dict[str, str]:
    """Return DB schema identity for CLI health/ensure output."""
    return {
        "schema_major": _read_schema_major(conn),
        "expected_schema_major": str(SCHEMA_MAJOR),
        "schema_name": SCHEMA_NAME,
        "db_path": _database_file(conn),
    }

# Enforced completion roles are determined by ROLE_SCHEMAS in completions.py.
# The keyset of ROLE_SCHEMAS is the authoritative enforced-role set.
# This constant was removed in W-CONV-5 (dead code — nothing consumed it).


def _apply_schema(conn: sqlite3.Connection) -> None:
    """Create all tables and indexes idempotently.

    Safe to call on every startup — CREATE TABLE/INDEX IF NOT EXISTS means this
    is a no-op once the schema exists. All DDL runs in a single transaction
    so a partial failure leaves the database in its prior state.
    Indexes for dispatch_leases are applied after table creation.

    ALTER TABLE migrations are applied after table creation so that existing
    DBs that predate a column addition are brought forward automatically.

    @decision DEC-RT-024
    Title: ALTER TABLE migrations in ensure_schema for agent_markers evolution
    Status: accepted
    Rationale: CREATE TABLE IF NOT EXISTS is idempotent but never adds new
      columns to an existing table. Old DBs created before the `status` column
      was added to AGENT_MARKERS_DDL would fail every markers.py operation that
      references `status`. The standard pattern for SQLite schema evolution is
      to attempt ALTER TABLE ADD COLUMN and swallow the OperationalError when
      the column already exists. This keeps ensure_schema as the single
      migration authority without requiring a separate migration runner.
    """
    _require_current_major(conn)
    with conn:
        # Migrate test_state: the pre-WS3 schema used workflow_id as the PRIMARY KEY
        # and had no project_root column. WS3 changes the primary key to project_root
        # (UNIQUE). Since SQLite cannot ALTER a PRIMARY KEY, we drop and recreate the
        # table when the old schema is detected. Data loss is acceptable: the old
        # test_state rows used workflow_id as key and are incompatible with the new
        # project_root-keyed rows. test-runner.sh will repopulate after the next run.
        #
        # @decision DEC-WS3-003
        # Title: DROP old test_state when pre-WS3 schema is detected
        # Status: accepted
        # Rationale: The old test_state table (workflow_id PK) was never fully wired
        #   into any enforcement hook — it was a stub from an earlier incomplete attempt.
        #   WS3 is the first complete implementation. Dropping and recreating is safer
        #   than a multi-step ALTER that would still leave the wrong primary key.
        #   Existing rows carry no useful state; they will be repopulated by test-runner.sh.
        try:
            existing_columns = {
                row[1] for row in conn.execute("PRAGMA table_info(test_state)").fetchall()
            }
            if existing_columns and "project_root" not in existing_columns:
                # Old schema detected — drop and let CREATE TABLE IF NOT EXISTS rebuild it.
                conn.execute("DROP TABLE IF EXISTS test_state")
                conn.execute("DROP INDEX IF EXISTS idx_test_state_project")
        except sqlite3.OperationalError:
            pass  # table does not exist yet — CREATE TABLE IF NOT EXISTS handles it

        for ddl in ALL_DDL:
            conn.execute(ddl)

        # Migrate launch_tickets before indexes that reference claim_token.
        try:
            conn.execute("ALTER TABLE launch_tickets ADD COLUMN claim_token TEXT")
        except sqlite3.OperationalError:
            pass  # column already exists — no-op

        for idx_ddl in DISPATCH_LEASES_INDEXES_DDL:
            conn.execute(idx_ddl)
        conn.execute(TEST_STATE_INDEX_DDL)
        for idx_ddl in GOAL_INDEXES_DDL:
            conn.execute(idx_ddl)
        for idx_ddl in WORK_ITEM_INDEXES_DDL:
            conn.execute(idx_ddl)
        for idx_ddl in STAGE_RUNS_INDEXES_DDL:
            conn.execute(idx_ddl)
        for idx_ddl in LAUNCH_TICKETS_INDEXES_DDL:
            conn.execute(idx_ddl)
        for idx_ddl in STAGE_RESULTS_INDEXES_DDL:
            conn.execute(idx_ddl)
        for idx_ddl in DISPATCH_NEXT_ACTIONS_V6_INDEXES_DDL:
            conn.execute(idx_ddl)
        for idx_ddl in CRITIC_RUNS_INDEXES_DDL:
            conn.execute(idx_ddl)
        for idx_ddl in V6_LANDING_READINESS_INDEXES_DDL:
            conn.execute(idx_ddl)
        for idx_ddl in OBS_METRICS_INDEXES_DDL:
            conn.execute(idx_ddl)
        for idx_ddl in OBS_SUGGESTIONS_INDEXES_DDL:
            conn.execute(idx_ddl)

        # Migrate agent_markers: add status column if missing.
        # Old DBs (pre-TKT-STAB-A4) have is_active but no status.
        # Swallow OperationalError — it fires when the column already exists.
        try:
            conn.execute(
                "ALTER TABLE agent_markers ADD COLUMN status TEXT NOT NULL DEFAULT 'active'"
            )
        except sqlite3.OperationalError:
            pass  # column already exists — no-op

        # Migrate agent_markers: add workflow_id column if missing.
        # Some intermediate DBs have workflow_id from an earlier migration;
        # newer fresh DBs get it from AGENT_MARKERS_DDL above.
        try:
            conn.execute("ALTER TABLE agent_markers ADD COLUMN workflow_id TEXT")
        except sqlite3.OperationalError:
            pass  # column already exists — no-op

        # Migrate agent_markers: add project_root column if missing.
        # W-CONV-2 (DEC-CONV-002) scopes marker queries by project_root so that
        # markers from one project do not contaminate actor-role inference in
        # another. Old DBs (pre-W-CONV-2) lack this column; ALTER TABLE adds it
        # with NULL default so all existing rows remain valid (unscoped).
        #
        # @decision DEC-CONV-002
        # Title: project_root added to agent_markers for per-project scoping
        # Status: accepted
        # Rationale: get_active() without project_root uses unscoped fallback
        #   (backward compat for statusline.py). get_active(project_root=X) must
        #   filter to markers written with that root — this column is the predicate.
        try:
            conn.execute("ALTER TABLE agent_markers ADD COLUMN project_root TEXT")
        except sqlite3.OperationalError:
            pass  # column already exists — no-op

        # Cleanup migration (W-CONV-2): deactivate any active markers whose role
        # is NOT a dispatch-significant role. Explore, Bash, and general-purpose
        # agents accumulated ghost markers before the subagent-start.sh filter
        # was added. Running this on startup ensures stale lightweight markers
        # cannot pollute actor-role inference in build_context().
        #
        # @decision DEC-CONV-002
        # Title: One-time cleanup of lightweight-role ghost markers
        # Status: accepted
        # Rationale: Accumulated Explore/Bash/unknown markers with is_active=1
        #   were returned by get_active() as the "newest active" marker, silently
        #   overriding the real implementer/tester/guardian role. The cleanup
        #   runs every time ensure_schema() is called (idempotent: rows already
        #   stopped are not touched). Dispatch-significant roles are whitelisted;
        #   everything else is deactivated with status='stopped'.
        conn.execute(
            """
            UPDATE agent_markers
            SET    is_active  = 0,
                   status     = 'stopped',
                   stopped_at = COALESCE(stopped_at, CAST(strftime('%s', 'now') AS INTEGER))
            WHERE  is_active  = 1
              AND  role NOT IN ('planner', 'implementer', 'tester', 'guardian', 'critic', 'reviewer', 'guardian:provision', 'guardian:land')
            """
        )

        # Seed enforcement_config global defaults if not yet present.
        # INSERT OR IGNORE means this is idempotent — re-running ensure_schema()
        # will not overwrite values that have been deliberately changed.
        # v6 default: dispatch-stage review remains on; hidden regular Stop
        # review gates are off/not wired. Provider preference remains codex.
        # (DEC-CONFIG-AUTHORITY-001, DEC-V6-NO-HIDDEN-STOP-001)
        _defaults = [
            ("global", "review_gate_subagent_stop", "true"),
            ("global", "review_gate_regular_stop", "false"),
            ("global", "review_gate_provider", "codex"),
        ]
        for _scope, _key, _value in _defaults:
            conn.execute(
                "INSERT OR IGNORE INTO enforcement_config (scope, key, value, updated_at) "
                "VALUES (?, ?, ?, CAST(strftime('%s','now') AS INTEGER))",
                (_scope, _key, _value),
            )
        _stamp_current_major(conn)


def ensure_schema(conn: sqlite3.Connection) -> None:
    """Ensure the live DB is the current v6 schema, recreating stale majors.

    Absence of ``schema_metadata.schema_major = 6`` means the DB is not trusted
    as this config's authority. Old DB files are archived, then the live DB is
    reset in place and stamped as v6. If a DB falsely claims v6 but still has an
    incompatible table shape, the first schema-shape failure triggers the same
    archive-and-reset path and retries once.
    """
    try:
        _apply_schema(conn)
    except sqlite3.OperationalError as exc:
        if not _schema_shape_error(exc):
            raise
        _reset_for_current_major(conn, f"schema_shape_error:{exc}")
        _apply_schema(conn)


def exercise_schema_upgrade(
    source_db: str,
    *,
    work_dir: str = "",
    keep_copy: bool = False,
    require_reset: bool = False,
) -> dict[str, object]:
    """Exercise stale-DB upgrade on a copy of ``source_db``.

    This is the supported validation path for project DB upgrades. It proves
    detection, archival, reset, and v6 stamping without deleting or mutating the
    live project DB. Deleting ``.claude/state.db`` only proves fresh bootstrap;
    this function proves the upgrade/reset path.
    """
    source = os.path.abspath(os.path.expanduser(source_db))
    if not os.path.isfile(source):
        raise FileNotFoundError(f"schema exercise source DB not found: {source}")

    temp_created = False
    if work_dir:
        exercise_dir = os.path.abspath(os.path.expanduser(work_dir))
        os.makedirs(exercise_dir, exist_ok=True)
    else:
        exercise_dir = tempfile.mkdtemp(prefix="cc-schema-gate.")
        temp_created = True

    copy_db = os.path.join(exercise_dir, "state.db")
    if os.path.abspath(copy_db) == source:
        raise ValueError("schema exercise refuses to operate on the source DB in place")
    if os.path.exists(copy_db):
        raise FileExistsError(f"schema exercise destination already exists: {copy_db}")

    _copy_sqlite_snapshot(source, copy_db)

    before_metadata: dict[str, str] = {}
    with sqlite3.connect(copy_db) as before_conn:
        before_metadata = _metadata_map(before_conn)

    conn = sqlite3.connect(copy_db)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    try:
        ensure_schema(conn)
        status = schema_status(conn)
        after_metadata = _metadata_map(conn)
    finally:
        conn.close()

    archive_path = after_metadata.get("last_archive_path", "")
    archive_exists = bool(archive_path and os.path.exists(archive_path))
    reset_reason = after_metadata.get("last_reset_reason", "")
    reset_exercised = bool(reset_reason)
    schema_ok = (
        status.get("schema_major") == str(SCHEMA_MAJOR)
        and status.get("schema_name") == SCHEMA_NAME
    )
    ok = schema_ok and (not require_reset or (reset_exercised and archive_exists))

    result: dict[str, object] = {
        "ok": ok,
        "source_db": source,
        "work_dir": exercise_dir,
        "copy_db": copy_db,
        "copy_removed": False,
        "before_schema_major": before_metadata.get("schema_major", ""),
        "schema_major": status.get("schema_major", ""),
        "expected_schema_major": status.get("expected_schema_major", ""),
        "schema_name": status.get("schema_name", ""),
        "last_reset_reason": reset_reason,
        "last_archive_path": archive_path,
        "archive_exists": archive_exists,
        "reset_exercised": reset_exercised,
        "require_reset": require_reset,
    }

    if temp_created and not keep_copy:
        shutil.rmtree(exercise_dir, ignore_errors=True)
        result["copy_removed"] = True

    return result
