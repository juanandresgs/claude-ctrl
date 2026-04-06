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
    DISPATCH_LEASES_DDL,
    COMPLETION_RECORDS_DDL,
    TEST_STATE_DDL,
    OBS_METRICS_DDL,
    OBS_SUGGESTIONS_DDL,
    OBS_RUNS_DDL,
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

# Default lease time-to-live: 2 hours.
DEFAULT_LEASE_TTL: int = 7200

# Enforced completion roles are determined by ROLE_SCHEMAS in completions.py.
# The keyset of ROLE_SCHEMAS is the authoritative enforced-role set.
# This constant was removed in W-CONV-5 (dead code — nothing consumed it).


def ensure_schema(conn: sqlite3.Connection) -> None:
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
        for idx_ddl in DISPATCH_LEASES_INDEXES_DDL:
            conn.execute(idx_ddl)
        conn.execute(TEST_STATE_INDEX_DDL)
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
              AND  role NOT IN ('planner', 'implementer', 'tester', 'guardian')
            """
        )
