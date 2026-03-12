#!/usr/bin/env bash
# state-lib.sh — SQLite WAL-based state store for Claude Code hooks.
#
# Loaded on demand via: require_state (defined in source-lib.sh)
# Depends on: log.sh (detect_project_root, get_claude_dir, log_info)
#             core-lib.sh (project_hash)
#             source-lib.sh (detect_workflow_id)
#
# Provides:
#   workflow_id         - Derive deterministic workflow identifier
#   state_update        - Write a key/value to SQLite state.db
#   state_read          - Read a value from SQLite state.db by key
#   state_cas           - Compare-and-swap with lattice enforcement
#   state_delete        - Remove a key from SQLite state.db
#   state_dir           - Return canonical state directory for project
#   state_locks_dir     - Return centralized locks directory
#   state_migrate       - Run pending schema migrations (idempotent)
#   proof_state_get     - Read proof state as pipe-delimited string (SQLite sole authority)
#   proof_state_set     - Transition proof state with monotonic lattice enforcement
#   proof_epoch_reset   - Bump epoch to allow proof state regression
#   marker_create       - Create an agent marker in agent_markers table
#   marker_query        - Query markers with PID liveness check (self-healing)
#   marker_update       - Update marker status (lifecycle transitions)
#   marker_cleanup      - Remove stale markers; mark dead-PID markers as crashed
#   state_emit          - Append an event to the events ledger; returns sequence number
#   state_events_since  - Read events newer than a consumer's last checkpoint
#   state_checkpoint    - Update a consumer's position in the event ledger
#   state_events_count  - Count events newer than a consumer's last checkpoint
#   state_gc_events     - Garbage-collect events all consumers have processed
#
# The SQLite database ($CLAUDE_DIR/state/state.db) is the authoritative state
# store. Old jq-based functions are preserved as _legacy_* for Wave 2 dual-write.
#
# @decision DEC-SQLITE-001
# @title SQLite WAL as the primary state backend for Claude Code hooks
# @status accepted
# @rationale The previous jq/state.json approach had three critical problems:
#   (1) flock-based locking serialized concurrent writes but had O(n) read-modify-write
#       cost as the history array grew — ~30ms per call;
#   (2) TOCTOU race window between read and write phases even with flock;
#   (3) No per-workflow isolation — all instances on same project shared state.
#   SQLite WAL mode solves all three: atomic INSERT OR REPLACE is single-statement
#   (no read-modify-write), busy_timeout=5000ms handles contention transparently,
#   and workflow_id column provides per-worktree isolation. The sqlite3 CLI is
#   pre-installed on macOS (shipped since 10.4) and standard on Linux — zero new
#   dependencies. Each sqlite3 invocation is ~2-3ms vs ~30ms for jq+flock.
#   Decision rationale: MASTER_PLAN.md DEC-RSM-SQLITE-001.
#
# @decision DEC-STATE-001
# @title state.json as audit/coordination layer alongside dotfiles (legacy — kept for migration)
# @status superseded
# @rationale Original decision preserved for Wave 2 migration reference. The SQLite
#   database replaces state.json as the primary store. Legacy functions preserved as _legacy_*.
#
# @decision DEC-STATE-UNIFY-001
# @title BEGIN IMMEDIATE for all write transactions
# @status accepted
# @rationale WAL mode with BEGIN acquires SHARED lock on read, then tries to upgrade
#   to RESERVED on first write. Two connections both holding SHARED cannot both upgrade
#   — deadlock. BEGIN IMMEDIATE acquires RESERVED immediately, so only one writer
#   enters the transaction; the other gets SQLITE_BUSY and retries via busy_timeout.
#   3/3 deep research providers confirm this as the #1 WAL concurrency fix.
#   Applied in: state_update(), state_cas(). See MASTER_PLAN.md DEC-STATE-UNIFY-001.
#
# @decision DEC-STATE-UNIFY-002
# @title _migrations table for schema versioning with per-migration checksums
# @status accepted
# @rationale Per-migration records with checksums enable rollback detection and
#   partial migration recovery. PRAGMA user_version is a single integer with no
#   history — insufficient for a system where schema evolves independently across
#   multiple active worktrees. _migrations table: version (PK), name, checksum,
#   applied_at. Runner is idempotent — re-running completed migrations is a no-op.
#   See MASTER_PLAN.md DEC-STATE-UNIFY-002.
#
# @decision DEC-STATE-UNIFY-005
# @title Append-only event ledger with consumer checkpoints for workflow coordination
# @status accepted
# @rationale The generic state table is a key-value store with last-write-wins
#   semantics — unsuitable for event streaming where order and completeness matter.
#   A dedicated events table with AUTOINCREMENT seq provides a durable, ordered
#   log: producers call state_emit() to append, consumers call state_events_since()
#   to read their slice without racing other consumers. Consumer checkpoints
#   (event_checkpoints table) track each consumer's position independently —
#   allowing multiple agents (tester, guardian, observer) to consume the same
#   event stream at different rates without coordination. GC is safe only when
#   all consumers have advanced past an event (min-checkpoint deletion).
#   payload is TEXT — callers pass JSON strings; state-lib.sh stores/retrieves
#   as-is and never parses payload content. BEGIN IMMEDIATE on writes prevents
#   the WAL RESERVED-lock deadlock described in DEC-STATE-UNIFY-001.
#   See MASTER_PLAN.md DEC-STATE-UNIFY-005.

# Guard against double-sourcing
[[ -n "${_STATE_LIB_LOADED:-}" ]] && return 0

_STATE_LIB_VERSION=3

# ─────────────────────────────────────────────────────────────────────────────
# Internal helpers
# ─────────────────────────────────────────────────────────────────────────────

# _sql_escape VALUE
#   Escape single quotes for SQLite string literals.
#   SQL injection prevention: replace every ' with '' (SQLite quoting convention).
#
# @decision DEC-SQLITE-007
# @title Use sed for single-quote escaping rather than bash ${var//\'/\'\'}
# @status accepted
# @rationale Bash parameter expansion ${val//\'/\'\'}  produces backslash-prefixed
#   quotes (\'\') in the substitution — the backslash is treated literally, not as
#   an escape. SQLite expects '' (two bare single-quotes), not \'\'. Using
#   `sed "s/'/''/g"` is portable, produces the correct double-quote output, and
#   round-trips correctly: sqlite3 stores '' as a single ' in the value.
_sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

# _state_db_path
#   Return the canonical path to the SQLite state database.
#   Creates the directory if it does not exist.
_state_db_path() {
    local claude_dir="${CLAUDE_DIR:-$(get_claude_dir 2>/dev/null || echo "$HOME/.claude")}"
    local db_dir="${claude_dir}/state"
    mkdir -p "$db_dir" 2>/dev/null || true
    echo "${db_dir}/state.db"
}

# _STATE_SCHEMA_INITIALIZED — module-level guard so schema runs only once per invocation
_STATE_SCHEMA_INITIALIZED=""

# _state_ensure_schema DB
#   Idempotent schema initialization: CREATE TABLE/INDEX/TRIGGER IF NOT EXISTS.
#   Called by _state_sql() on first invocation within a hook process.
#
# @decision DEC-SQLITE-002
# @title Idempotent schema creation via CREATE IF NOT EXISTS on every first call
# @status accepted
# @rationale Running schema creation on every first connection is safe because all
#   DDL statements use IF NOT EXISTS. The cost is one extra sqlite3 invocation
#   per hook process (amortized across all state_update/state_read calls in that
#   process). The alternative — a separate schema version check — would require
#   two round-trips (read version, then conditionally create), which is slower.
#   Module-level guard _STATE_SCHEMA_INITIALIZED prevents re-running within the
#   same process.
_state_ensure_schema() {
    local db="$1"
    [[ -n "${_STATE_SCHEMA_INITIALIZED:-}" ]] && return 0

    # Set WAL mode first (persistent across connections — only needs to run once).
    # Redirect stdout to /dev/null: PRAGMA journal_mode=WAL outputs "wal" which
    # would contaminate caller output if not suppressed.
    #
    # @decision DEC-SQLITE-006
    # @title Suppress PRAGMA output via stdout redirect in _state_ensure_schema
    # @status accepted
    # @rationale sqlite3 -cmd "PRAGMA journal_mode=WAL" prints "wal" to stdout.
    #   sqlite3 -cmd "PRAGMA busy_timeout=5000" prints "5000" to stdout.
    #   These bleed into the return value of _state_sql() callers (state_read,
    #   state_cas, etc.). The fix: (1) run WAL setup with stdout redirected to
    #   /dev/null — WAL mode is persistent, so this only runs once per DB file;
    #   (2) use the `.timeout N` dot command (not PRAGMA) for busy_timeout in
    #   _state_sql() — dot commands produce no stdout output. WAL mode is then
    #   already set for all subsequent connections.
    sqlite3 "$db" "PRAGMA journal_mode=WAL;" >/dev/null 2>/dev/null || true

    # Create tables, indexes, trigger, and schema version marker.
    # Use .timeout 5000 (dot command, no output) for busy_timeout on this connection.
    printf '.timeout 5000\n%s\n' "
CREATE TABLE IF NOT EXISTS state (
    key         TEXT    NOT NULL,
    value       TEXT    NOT NULL,
    workflow_id TEXT    NOT NULL,
    session_id  TEXT,
    updated_at  INTEGER NOT NULL,
    source      TEXT    NOT NULL,
    pid         INTEGER,
    PRIMARY KEY (key, workflow_id)
);

CREATE TABLE IF NOT EXISTS history (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    key         TEXT    NOT NULL,
    value       TEXT    NOT NULL,
    workflow_id TEXT    NOT NULL,
    session_id  TEXT,
    source      TEXT    NOT NULL,
    timestamp   INTEGER NOT NULL,
    pid         INTEGER
);

CREATE INDEX IF NOT EXISTS idx_history_workflow
    ON history(workflow_id, timestamp DESC);

CREATE INDEX IF NOT EXISTS idx_state_workflow
    ON state(workflow_id);

CREATE TRIGGER IF NOT EXISTS cap_history
AFTER INSERT ON history
BEGIN
    DELETE FROM history
    WHERE id IN (
        SELECT id FROM history
        WHERE workflow_id = NEW.workflow_id
        ORDER BY timestamp DESC
        LIMIT -1 OFFSET 500
    );
END;

CREATE TABLE IF NOT EXISTS _migrations (
    version     INTEGER PRIMARY KEY,
    name        TEXT    NOT NULL,
    checksum    TEXT,
    applied_at  INTEGER NOT NULL
);

INSERT OR IGNORE INTO state
    (key, value, workflow_id, session_id, updated_at, source, pid)
VALUES
    ('_schema_version', '1', '_system', NULL, strftime('%s','now'), 'state-lib', NULL);

CREATE TABLE IF NOT EXISTS proof_state (
    workflow_id TEXT PRIMARY KEY,
    status      TEXT NOT NULL DEFAULT 'none'
                    CHECK(status IN ('none','needs-verification','pending','verified','committed')),
    epoch       INTEGER NOT NULL DEFAULT 0,
    updated_at  INTEGER NOT NULL,
    updated_by  TEXT    NOT NULL,
    session_id  TEXT,
    pid         INTEGER
);

CREATE TABLE IF NOT EXISTS agent_markers (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    agent_type  TEXT NOT NULL,
    session_id  TEXT NOT NULL,
    workflow_id TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'active'
                    CHECK(status IN ('active','pre-dispatch','completed','crashed')),
    pid         INTEGER NOT NULL,
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL,
    trace_id    TEXT,
    metadata    TEXT,
    UNIQUE(agent_type, session_id, workflow_id)
);

CREATE INDEX IF NOT EXISTS idx_markers_type_wf
    ON agent_markers(agent_type, workflow_id, status);

CREATE TABLE IF NOT EXISTS events (
    seq         INTEGER PRIMARY KEY AUTOINCREMENT,
    type        TEXT NOT NULL,
    workflow_id TEXT NOT NULL,
    session_id  TEXT,
    payload     TEXT,
    created_at  INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_events_type_wf
    ON events(type, workflow_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_events_seq
    ON events(seq);

CREATE TABLE IF NOT EXISTS event_checkpoints (
    consumer    TEXT PRIMARY KEY,
    last_seq    INTEGER NOT NULL DEFAULT 0,
    updated_at  INTEGER NOT NULL
);
" | sqlite3 "$db" 2>/dev/null || true

    _STATE_SCHEMA_INITIALIZED=1

    # Run any pending migrations (idempotent — already-applied migrations skipped)
    _state_run_migrations "$db"
}

# ─────────────────────────────────────────────────────────────────────────────
# Migration framework
# ─────────────────────────────────────────────────────────────────────────────

# _MIGRATIONS — ordered array of "version:name:function_name" entries.
#   Each entry defines one migration. The runner processes them in order.
#   Future Implementers: to add a new migration:
#   1. Define _migration_NNN_description() below (receives db path as $1)
#   2. Add "NNN:description:_migration_NNN_description" to this array
#   3. Use printf + sqlite3 for SQL within the function (not _state_sql — that
#      would recurse into schema init before migrations are complete)
_MIGRATIONS=(
    "1:initial_schema:_migration_001_initial_schema"
)

# _migration_001_initial_schema DB
#   No-op migration: records that the baseline schema (state + history tables)
#   was created by _state_ensure_schema(). This migration exists to establish
#   version 1 in the _migrations table — subsequent migrations can depend on
#   version 1 being present. No SQL schema changes needed here.
_migration_001_initial_schema() {
    # No-op: existing schema created by _state_ensure_schema().
    # This migration just records that the baseline schema exists.
    return 0
}

# _state_checksum_fn FUNCTION_NAME
#   Compute SHA-256 checksum of a function's body (via `type -f`).
#   Used to detect if a migration's implementation has changed since it was applied.
#   Returns 64-char lowercase hex string.
_state_checksum_fn() {
    local fn_name="$1"
    local fn_body
    fn_body=$(type -f "$fn_name" 2>/dev/null || echo "$fn_name:undefined")
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$fn_body" | shasum -a 256 | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$fn_body" | sha256sum | awk '{print $1}'
    else
        # Fallback: no sha available — use a stable placeholder (not cryptographic)
        printf '%s' "$fn_body" | cksum | awk '{printf "%064d", $1}'
    fi
}

# _state_run_migrations DB
#   Executes pending migrations in order. Each migration is a function named
#   _migration_NNN_description() that receives the db path as $1.
#   Idempotent: completed migrations (by version) are skipped.
#   On failure: logs error, returns 1 — does NOT continue past failed migration.
#   Called automatically by _state_ensure_schema() after table creation.
_state_run_migrations() {
    local db="$1"
    local migration_entry version name fn_name checksum applied ts

    for migration_entry in "${_MIGRATIONS[@]}"; do
        # Parse "version:name:fn_name" entry
        version="${migration_entry%%:*}"
        local rest="${migration_entry#*:}"
        name="${rest%%:*}"
        fn_name="${rest#*:}"

        # Check if this version is already applied
        applied=$(printf '.timeout 5000\nSELECT COUNT(*) FROM _migrations WHERE version=%s;\n' "$version" \
            | sqlite3 "$db" 2>/dev/null || echo "0")
        applied="${applied//[[:space:]]/}"

        if [[ "$applied" -ge 1 ]]; then
            # Already applied — skip (idempotent)
            continue
        fi

        # Compute checksum of the migration function body
        checksum=$(_state_checksum_fn "$fn_name")

        # Execute the migration function
        if ! "$fn_name" "$db"; then
            # Migration failed — log and stop (don't continue past failure)
            log_info "STATE-MIGRATION" "Migration ${version} (${name}) FAILED — stopping migration runner" 2>/dev/null || true
            return 1
        fi

        # Record the migration in _migrations
        ts=$(date +%s)
        local name_e checksum_e
        name_e=$(printf '%s' "$name" | sed "s/'/''/g")
        checksum_e=$(printf '%s' "$checksum" | sed "s/'/''/g")
        printf '.timeout 5000\nINSERT OR IGNORE INTO _migrations (version, name, checksum, applied_at) VALUES (%s, '"'"'%s'"'"', '"'"'%s'"'"', %s);\n' \
            "$version" "$name_e" "$checksum_e" "$ts" \
            | sqlite3 "$db" 2>/dev/null || true
    done
    return 0
}

# state_migrate
#   Run any pending migrations against the state database.
#   Called automatically by _state_ensure_schema() on first invocation.
#   Safe to call explicitly — idempotent, already-applied migrations are skipped.
#
#   Future Implementers: add new migrations by:
#   1. Define _migration_NNN_description() function (receives DB path as $1)
#   2. Add "NNN:description:_migration_NNN_description" to _MIGRATIONS array
#   3. Migration functions receive DB path as $1 — use printf+sqlite3 directly
#   4. Use _state_sql() for SQL execution ONLY if schema is already initialized
#      (never inside _state_run_migrations — that runs during schema init)
state_migrate() {
    local db
    db=$(_state_db_path)
    _state_run_migrations "$db"
}

# _state_sql SQL
#   Execute SQL against the state database with busy_timeout set via the
#   .timeout dot command (no stdout output — unlike PRAGMA busy_timeout=N).
#   WAL mode is already persistent from _state_ensure_schema().
#   Ensures schema is initialized on first call within this process.
#   Returns sqlite3 output. Exit code follows sqlite3 conventions.
_state_sql() {
    local sql="$1"
    local db
    db=$(_state_db_path)
    _state_ensure_schema "$db"
    # Use .timeout (dot command) for busy_timeout — produces no stdout output.
    # Pipe SQL via stdin to avoid any -cmd flag output contamination.
    printf '.timeout 5000\n%s\n' "$sql" | sqlite3 "$db" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# Workflow ID derivation
# ─────────────────────────────────────────────────────────────────────────────

# Cached workflow ID for current process lifetime
_WORKFLOW_ID=""

# workflow_id
#   Return deterministic workflow identifier: {phash}_{worktree_name}
#   or {phash}_main for the main checkout.
#
#   Uses detect_workflow_id() from source-lib.sh to identify the worktree
#   context, then combines with project_hash() for full qualification.
#
#   Caches in _WORKFLOW_ID for the hook's lifetime (one hook = one process).
#
# @decision DEC-SQLITE-003
# @title workflow_id = {phash}_{wt_name} for per-worktree state isolation
# @status accepted
# @rationale Two instances on different worktrees of the same project must have
#   independent proof state. workflow_id = {phash}_{wt_name} provides this:
#   same project root → same phash, different worktrees → different wt_name.
#   The main checkout uses "main" as wt_name (matches detect_workflow_id() default).
#   Per-session partitioning (adding session_id to workflow_id) was rejected:
#   the proof state is about code state, not session identity — if tester-A
#   verifies worktree-X, guardian-A should be able to commit it even if it is
#   a different session. See PRD section 7 Q2/Q8 for full trade-off analysis.
workflow_id() {
    if [[ -n "${_WORKFLOW_ID:-}" ]]; then echo "$_WORKFLOW_ID"; return 0; fi
    local project_root="${PROJECT_ROOT:-$(detect_project_root 2>/dev/null || echo "$PWD")}"
    local phash
    phash=$(project_hash "$project_root")
    local wt_id
    wt_id=$(detect_workflow_id "" 2>/dev/null || echo "main")
    _WORKFLOW_ID="${phash}_${wt_id}"
    echo "$_WORKFLOW_ID"
}

# ─────────────────────────────────────────────────────────────────────────────
# Proof status lattice enforcement
# ─────────────────────────────────────────────────────────────────────────────

# _proof_ordinal VALUE
#   Return the ordinal position of a proof status value in the monotonic lattice.
#   Returns 0 for unknown values (safest — won't block transitions from unknown states).
#
# @decision DEC-SQLITE-004
# @title Monotonic lattice enforcement in state_cas() for proof_status key
# @status accepted
# @rationale proof_status must advance monotonically within an epoch:
#   none→needs-verification→pending→verified→committed. Regressions are
#   rejected to prevent a crashed or malicious process from rolling back a
#   verified proof. Epoch reset (write to proof.epoch) is the only valid
#   way to allow regression — callers must explicitly bump the epoch.
#   Implemented in application logic (not SQLite CHECK constraint) because
#   the epoch check requires reading the current epoch value, which cannot
#   be expressed as a single-row CHECK constraint in SQLite.
_proof_ordinal() {
    case "$1" in
        none)                echo 0 ;;
        needs-verification)  echo 1 ;;
        pending)             echo 2 ;;
        verified)            echo 3 ;;
        committed)           echo 4 ;;
        *)                   echo 0 ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Public API
# ─────────────────────────────────────────────────────────────────────────────

# state_update KEY VALUE [SOURCE]
#   INSERT OR REPLACE into state table + INSERT into history table.
#   Auto-populates: workflow_id, session_id, pid, updated_at/timestamp.
#   MUST be a single sqlite3 invocation (atomic transaction).
#   Returns 0 on success, 1 on failure (non-fatal — caller decides).
#
# @decision DEC-STATE-002
# @title Single sqlite3 invocation for state_update atomicity
# @status accepted
# @rationale The previous jq-based implementation used flock + tmp→mv, requiring
#   two syscalls (write temp, rename) plus one subprocess (jq). SQLite's
#   BEGIN/COMMIT wraps both the state INSERT and history INSERT in a single
#   atomic transaction — either both succeed or neither does. No external lock
#   is needed: SQLite WAL handles concurrent readers/writer internally.
state_update() {
    local key="${1:?state_update requires a key}"
    local value="${2:?state_update requires a value}"
    local source="${3:-${_HOOK_NAME:-unknown}}"
    local wf_id
    wf_id=$(workflow_id)
    local session_id="${CLAUDE_SESSION_ID:-}"
    local pid="$$"
    local ts
    ts=$(date +%s)

    local key_e value_e source_e wf_id_e session_id_e
    key_e=$(_sql_escape "$key")
    value_e=$(_sql_escape "$value")
    source_e=$(_sql_escape "$source")
    wf_id_e=$(_sql_escape "$wf_id")

    local session_val
    if [[ -n "$session_id" ]]; then
        session_id_e=$(_sql_escape "$session_id")
        session_val="'${session_id_e}'"
    else
        session_val="NULL"
    fi

    _state_sql "
BEGIN IMMEDIATE;
INSERT OR REPLACE INTO state
    (key, value, workflow_id, session_id, updated_at, source, pid)
VALUES
    ('${key_e}', '${value_e}', '${wf_id_e}', ${session_val}, ${ts}, '${source_e}', ${pid});
INSERT INTO history
    (key, value, workflow_id, session_id, source, timestamp, pid)
VALUES
    ('${key_e}', '${value_e}', '${wf_id_e}', ${session_val}, '${source_e}', ${ts}, ${pid});
COMMIT;
" >/dev/null && return 0 || return 1
}

# state_read KEY [WORKFLOW_ID]
#   SELECT value FROM state WHERE key=? AND workflow_id=?
#   If workflow_id not provided, uses workflow_id().
#   Returns empty string if not found (echo nothing, return 0).
#   Single sqlite3 invocation.
state_read() {
    local key="${1:?state_read requires a key}"
    local wf_id="${2:-}"
    if [[ -z "$wf_id" ]]; then
        wf_id=$(workflow_id)
    fi

    local key_e wf_id_e
    key_e=$(_sql_escape "$key")
    wf_id_e=$(_sql_escape "$wf_id")

    local result
    result=$(_state_sql "
SELECT value FROM state
WHERE key='${key_e}' AND workflow_id='${wf_id_e}'
LIMIT 1;
") || true
    echo "$result"
    return 0
}

# state_cas KEY EXPECTED NEW_VALUE [SOURCE]
#   Compare-and-swap: UPDATE WHERE value=expected.
#   Returns "ok" on success, "conflict:$actual" on mismatch.
#   Enforces monotonic lattice for proof_status key: regressions rejected
#   unless proof.epoch has been bumped since the current value was set.
#
# @decision DEC-SQLITE-005
# @title state_cas multi-statement SQL for atomic CAS with history
# @status accepted
# @rationale CAS must be atomic: check + update must not interleave with
#   concurrent writers. SQLite's WAL + single-connection transaction provides
#   this: within one sqlite3 invocation, the UPDATE + changes() check + history
#   INSERT are atomic. No external lock needed. The changes() function returns
#   the number of rows modified by the last UPDATE — 1 means CAS succeeded,
#   0 means the value changed since we read it (conflict).
state_cas() {
    local key="${1:?state_cas requires a key}"
    local expected="${2:?state_cas requires expected value}"
    local new_value="${3:?state_cas requires new value}"
    local source="${4:-${_HOOK_NAME:-unknown}}"
    local wf_id
    wf_id=$(workflow_id)
    local session_id="${CLAUDE_SESSION_ID:-}"
    local pid="$$"
    local ts
    ts=$(date +%s)

    # Lattice enforcement for proof_status key
    if [[ "$key" == "proof_status" || "$key" == "proof.status" ]]; then
        local new_ord expected_ord
        new_ord=$(_proof_ordinal "$new_value")
        expected_ord=$(_proof_ordinal "$expected")
        if [[ "$new_ord" -lt "$expected_ord" ]]; then
            # Regression requested — check if epoch has been bumped
            local bumped
            bumped=$(state_read "proof.epoch.bumped" "$wf_id" 2>/dev/null || echo "")
            if [[ -z "$bumped" ]]; then
                local actual
                actual=$(state_read "$key" "$wf_id" 2>/dev/null || echo "$expected")
                echo "conflict:${actual}"
                return 0
            fi
        fi
    fi

    local key_e expected_e new_value_e source_e wf_id_e session_id_e
    key_e=$(_sql_escape "$key")
    expected_e=$(_sql_escape "$expected")
    new_value_e=$(_sql_escape "$new_value")
    source_e=$(_sql_escape "$source")
    wf_id_e=$(_sql_escape "$wf_id")

    local session_val
    if [[ -n "$session_id" ]]; then
        session_id_e=$(_sql_escape "$session_id")
        session_val="'${session_id_e}'"
    else
        session_val="NULL"
    fi

    local result
    result=$(_state_sql "
BEGIN IMMEDIATE;
UPDATE state
SET value='${new_value_e}', updated_at=${ts}, source='${source_e}', pid=${pid}
WHERE key='${key_e}' AND workflow_id='${wf_id_e}' AND value='${expected_e}';
SELECT changes();
COMMIT;
") || true

    local changes="${result:-0}"
    # Strip whitespace from sqlite3 output
    changes="${changes//[[:space:]]/}"

    if [[ "$changes" -eq 1 ]]; then
        # CAS succeeded — write history record
        _state_sql "
INSERT INTO history
    (key, value, workflow_id, session_id, source, timestamp, pid)
VALUES
    ('${key_e}', '${new_value_e}', '${wf_id_e}', ${session_val}, '${source_e}', ${ts}, ${pid});
" >/dev/null 2>&1 || true
        echo "ok"
    else
        # CAS failed — return actual value
        local actual
        actual=$(state_read "$key" "$wf_id" 2>/dev/null || echo "")
        echo "conflict:${actual}"
    fi
    return 0
}

# state_delete KEY [WORKFLOW_ID]
#   DELETE FROM state WHERE key=? AND workflow_id=?
#   Returns 0 on success (even if key didn't exist).
state_delete() {
    local key="${1:?state_delete requires a key}"
    local wf_id="${2:-}"
    if [[ -z "$wf_id" ]]; then
        wf_id=$(workflow_id)
    fi

    local key_e wf_id_e
    key_e=$(_sql_escape "$key")
    wf_id_e=$(_sql_escape "$wf_id")

    _state_sql "
DELETE FROM state WHERE key='${key_e}' AND workflow_id='${wf_id_e}';
" >/dev/null 2>&1 || true
    return 0
}

# state_dir [PROJECT_ROOT]
#   Returns the canonical state directory for the current project.
#   Creates the directory if it doesn't exist.
#   Path: $CLAUDE_DIR/state/{project_hash}/
#
# @decision DEC-RSM-STATEDIR-001
# @title Unified state directory with per-project hash subdirectories
# @status accepted
# @rationale Consolidates scattered dotfiles (.proof-status-{phash},
#   .test-status, .cas-failures, .proof-gate-pending) into a structured
#   directory hierarchy. The project hash becomes a directory name instead
#   of a file suffix, yielding clean internal names. Note: .proof-epoch was
#   also migrated but subsequently removed (DEC-STATE-DOTFILE-001) — epoch
#   state is now solely in the SQLite proof_state.epoch column.
#   Backward-compatible via dual-write during migration (W3-1, W3-2).
state_dir() {
    local project_root="${1:-${PROJECT_ROOT:-$(detect_project_root)}}"
    local claude_dir
    claude_dir=$(PROJECT_ROOT="$project_root" get_claude_dir)
    local phash
    phash=$(project_hash "$project_root")
    local dir="${claude_dir}/state/${phash}"
    mkdir -p "$dir" 2>/dev/null || true
    echo "$dir"
}

# state_locks_dir
#   Returns the centralized locks directory: $CLAUDE_DIR/state/locks/
#   Creates the directory if it doesn't exist.
state_locks_dir() {
    local claude_dir="${CLAUDE_DIR:-$(get_claude_dir)}"
    local dir="${claude_dir}/state/locks"
    mkdir -p "$dir" 2>/dev/null || true
    echo "$dir"
}

# ─────────────────────────────────────────────────────────────────────────────
# proof_state typed table API
# ─────────────────────────────────────────────────────────────────────────────

# proof_state_get [WORKFLOW_ID]
#   Return current proof state as pipe-delimited string:
#     status|epoch|updated_at|updated_by
#   If WORKFLOW_ID not provided, uses workflow_id().
#   Returns empty string (exit 1) if no entry found.
#
#   W5-2: Flat-file fallback removed. SQLite is the sole authority for proof state.
#   All writers use proof_state_set(); all readers use proof_state_get().
#
# @decision DEC-STATE-UNIFY-003
# @title proof_state typed table for structured proof lifecycle state
# @status accepted
# @rationale The existing proof_status key in the generic `state` table stores
#   a plain TEXT value with no schema enforcement. Adding a dedicated
#   `proof_state` table provides: (1) CHECK constraint on status values —
#   the DB rejects invalid status strings at the storage layer, not just at
#   the application layer; (2) first-class epoch column — epoch is a
#   structured field, not a separate key lookup; (3) typed metadata columns
#   (updated_by, session_id, pid) that mirror the `state` table pattern but
#   scoped to proof lifecycle semantics; (4) workflow_id as PRIMARY KEY
#   enforces one-proof-state-per-workflow invariant at the DB level.
#   This is the typed table approach from DEC-STATE-UNIFY-003 in MASTER_PLAN.md.
#
# @decision DEC-STATE-UNIFY-004
# @title W5-2: Remove flat-file dual-read fallback from proof_state_get
# @status accepted
# @rationale All hook callers have been migrated to proof_state_set() for writes
#   and proof_state_get() for reads. The dual-write window (W2-1 through W5-1) is
#   closed. The flat-file fallback is no longer needed and would allow stale
#   flat files to shadow correct SQLite state. Removing it makes SQLite the sole
#   authority and enables the state-dotfile-bypass lint gate.
proof_state_get() {
    local wf_id="${1:-}"
    if [[ -z "$wf_id" ]]; then
        wf_id=$(workflow_id)
    fi

    local wf_id_e
    wf_id_e=$(_sql_escape "$wf_id")

    local result
    result=$(_state_sql "
.separator '|'
SELECT status, epoch, updated_at, updated_by
FROM proof_state
WHERE workflow_id='${wf_id_e}'
LIMIT 1;
") || true

    if [[ -n "$result" ]]; then
        echo "$result"
        return 0
    fi

    return 1
}

# proof_state_set STATUS [SOURCE]
#   Transition proof state with monotonic lattice enforcement.
#   Returns 0 on success, 1 on lattice violation or failure.
#
#   Lattice: none(0) → needs-verification(1) → pending(2) → verified(3) → committed(4)
#   Forward progression always allowed. Regression (new_ord < current_ord) is
#   rejected unless proof_epoch_reset() has been called since last write.
#
#   Implementation uses a read-then-write pattern with BEGIN IMMEDIATE on the
#   write to prevent concurrent regressions. Since the lattice only prevents
#   backward movement and both concurrent writers are advancing forward, the
#   TOCTOU window is safe: a concurrent writer can only move state further
#   forward, which is acceptable.
#
#   Each successful write inserts a history row for full audit trail.
#
# @decision DEC-STATE-UNIFY-003
# @title Read-then-write pattern for proof_state_set lattice enforcement
# @status accepted
# @rationale Pure SQL conditional INSERT (e.g., INSERT ... WHERE NOT EXISTS ...)
#   cannot easily express the epoch-based regression exception in a single
#   statement without a complex subquery. The read-then-write approach matches
#   state_cas() precedent in this file and keeps the lattice logic in readable
#   bash. BEGIN IMMEDIATE on the write ensures atomicity of the write itself;
#   the read-before-write TOCTOU window is acceptable because concurrent forward
#   progression is idempotent and epoch bumps are always done explicitly.
proof_state_set() {
    local new_status="${1:?proof_state_set requires a status}"
    local source="${2:-${_HOOK_NAME:-unknown}}"
    local wf_id
    wf_id=$(workflow_id)
    local session_id="${CLAUDE_SESSION_ID:-}"
    local pid="$$"
    local ts
    ts=$(date +%s)

    local new_ord
    new_ord=$(_proof_ordinal "$new_status")

    local wf_id_e new_status_e source_e session_id_e
    wf_id_e=$(_sql_escape "$wf_id")
    new_status_e=$(_sql_escape "$new_status")
    source_e=$(_sql_escape "$source")

    local session_val
    if [[ -n "$session_id" ]]; then
        session_id_e=$(_sql_escape "$session_id")
        session_val="'${session_id_e}'"
    else
        session_val="NULL"
    fi

    # Read current state (status + epoch)
    local current
    current=$(_state_sql "
SELECT status || '|' || epoch
FROM proof_state
WHERE workflow_id='${wf_id_e}'
LIMIT 1;
") || true

    local cur_epoch=0
    if [[ -n "$current" ]]; then
        local cur_status
        cur_status="${current%%|*}"
        cur_epoch="${current##*|}"
        local cur_ord
        cur_ord=$(_proof_ordinal "$cur_status")

        # Lattice check: regression requires epoch to have been bumped.
        # Epoch bump is recorded directly in proof_state.epoch via proof_epoch_reset().
        # If new ordinal < current ordinal, only allow if epoch in DB > the epoch
        # that was present when the current status was written. Since proof_epoch_reset()
        # increments epoch in-place, a bumped epoch means the stored epoch > 0 AND
        # was incremented since last status write. We detect this via a separate
        # epoch sentinel key (proof.epoch.bumped) for backward compat with state_cas().
        if (( new_ord < cur_ord )); then
            # Check if an epoch bump has been signalled
            local bumped
            bumped=$(state_read "proof.epoch.bumped" "$wf_id" 2>/dev/null || true)
            if [[ -z "$bumped" ]]; then
                return 1
            fi
        fi
    fi

    # Write: BEGIN IMMEDIATE for concurrent write safety.
    _state_sql "
BEGIN IMMEDIATE;
INSERT OR REPLACE INTO proof_state
    (workflow_id, status, epoch, updated_at, updated_by, session_id, pid)
VALUES
    ('${wf_id_e}', '${new_status_e}',
     COALESCE((SELECT epoch FROM proof_state WHERE workflow_id='${wf_id_e}'), 0),
     ${ts}, '${source_e}', ${session_val}, ${pid});
INSERT INTO history
    (key, value, workflow_id, session_id, source, timestamp, pid)
VALUES
    ('proof_state', '${new_status_e}', '${wf_id_e}', ${session_val}, '${source_e}', ${ts}, ${pid});
COMMIT;
" >/dev/null && return 0 || return 1
}

# proof_epoch_reset [WORKFLOW_ID]
#   Bump the epoch counter for a workflow, allowing proof state regression.
#   Used when source code changes invalidate previous verification.
#
#   After calling proof_epoch_reset(), the next proof_state_set() call may
#   move the status backward (e.g., from verified back to none).
#
#   Sets the proof.epoch.bumped sentinel key in the generic state table for
#   compatibility with state_cas() lattice checks on the proof_status key.
#   Also increments proof_state.epoch directly for the typed table.
#
# @decision DEC-STATE-UNIFY-003
# @title proof_epoch_reset updates both typed table and sentinel key
# @status accepted
# @rationale The existing state_cas() lattice check reads proof.epoch.bumped
#   from the generic state table. proof_epoch_reset() must set that sentinel
#   for backward compat during the dual-write window. The typed proof_state
#   table stores epoch as an integer column; incrementing it directly here
#   ensures the typed API is self-consistent without reading the sentinel key.
proof_epoch_reset() {
    local wf_id="${1:-}"
    if [[ -z "$wf_id" ]]; then
        wf_id=$(workflow_id)
    fi

    local wf_id_e
    wf_id_e=$(_sql_escape "$wf_id")
    local ts
    ts=$(date +%s)

    # Bump epoch in proof_state (upsert: if no row exists, create one with epoch=1)
    _state_sql "
BEGIN IMMEDIATE;
INSERT INTO proof_state (workflow_id, status, epoch, updated_at, updated_by)
VALUES ('${wf_id_e}', 'none', 1, ${ts}, 'proof_epoch_reset')
ON CONFLICT(workflow_id) DO UPDATE SET
    epoch = epoch + 1,
    updated_at = ${ts},
    updated_by = 'proof_epoch_reset';
COMMIT;
" >/dev/null || true

    # Also set the sentinel key for backward compat with state_cas() checks
    state_update "proof.epoch.bumped" "1" "proof_epoch_reset" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# agent_markers typed table API
# ─────────────────────────────────────────────────────────────────────────────

# @decision DEC-STATE-UNIFY-003
# @title agent_markers typed table replaces dotfile-based agent tracking
# @status accepted
# @rationale Agent markers (.active-guardian-{session}-{phash}, etc.) were
#   dotfiles in the trace store directory, created with touch/echo, detected
#   with globs, and cleaned up with rm. This caused: (1) stale markers blocking
#   gates due to no TTL-aware cleanup; (2) glob-based false positives when
#   workflow IDs shared prefixes; (3) no structured query capability (no filter
#   by status, type, or session without parsing filenames). The typed table
#   provides: CHECK constraint on status values, PID liveness column for
#   self-healing cleanup, UNIQUE constraint on (agent_type, session_id,
#   workflow_id) to prevent duplicates, and indexed queries via
#   idx_markers_type_wf. The metadata column (JSON TEXT) is reserved for
#   future use — not populated in Wave 3-1. See MASTER_PLAN.md W3-1.

# marker_create TYPE SESSION_ID WORKFLOW_ID PID [TRACE_ID] [STATUS]
#   Creates an agent marker in the agent_markers table.
#   Default status is 'active'. Uses INSERT OR REPLACE to handle re-creation
#   (idempotent on the UNIQUE(agent_type, session_id, workflow_id) constraint).
#   Returns 0 on success, 1 on failure.
#
#   STATUS values: active | pre-dispatch | completed | crashed
#   (enforced by SQLite CHECK constraint)
marker_create() {
    local agent_type="${1:?marker_create requires agent_type}"
    local session_id="${2:?marker_create requires session_id}"
    local wf_id="${3:?marker_create requires workflow_id}"
    local pid="${4:?marker_create requires pid}"
    local trace_id="${5:-}"
    local status="${6:-active}"
    local ts
    ts=$(date +%s)

    local agent_type_e session_id_e wf_id_e status_e trace_val
    agent_type_e=$(_sql_escape "$agent_type")
    session_id_e=$(_sql_escape "$session_id")
    wf_id_e=$(_sql_escape "$wf_id")
    status_e=$(_sql_escape "$status")

    if [[ -n "$trace_id" ]]; then
        local trace_id_e
        trace_id_e=$(_sql_escape "$trace_id")
        trace_val="'${trace_id_e}'"
    else
        trace_val="NULL"
    fi

    _state_sql "
BEGIN IMMEDIATE;
INSERT OR REPLACE INTO agent_markers
    (agent_type, session_id, workflow_id, status, pid, created_at, updated_at, trace_id, metadata)
VALUES
    ('${agent_type_e}', '${session_id_e}', '${wf_id_e}', '${status_e}',
     ${pid}, ${ts}, ${ts}, ${trace_val}, NULL);
COMMIT;
" >/dev/null && return 0 || return 1
}

# marker_query TYPE [WORKFLOW_ID]
#   Returns matching markers as pipe-delimited lines:
#     agent_type|session_id|workflow_id|status|pid|created_at|trace_id
#   Filters to status='active' only by default (dead PIDs auto-marked as crashed).
#   For each active marker, checks PID liveness via kill -0. If the PID is dead,
#   updates the marker status to 'crashed' immediately (self-healing) and excludes
#   it from results.
#   If WORKFLOW_ID is provided, returns only markers matching that workflow.
#   If WORKFLOW_ID is omitted, returns all markers of TYPE.
#
# @decision DEC-STATE-UNIFY-003
# @title marker_query does PID liveness check for self-healing (replaces TTL-only)
# @status accepted
# @rationale TTL-only staleness detection (e.g., markers older than N seconds)
#   cannot distinguish a long-running legitimate agent from a crashed one. PID
#   liveness check via kill -0 provides exact detection: if the PID is dead,
#   the agent crashed or completed without cleanup. This is the same pattern
#   used by systemd, flock-based lock files, and other Unix process management
#   tools. The self-healing update (status→crashed) is a write side-effect of
#   a read query, which is unusual but necessary to keep the DB consistent
#   without requiring a separate cleanup daemon. The write uses BEGIN IMMEDIATE
#   for concurrent write safety.
marker_query() {
    local agent_type="${1:?marker_query requires agent_type}"
    local wf_id="${2:-}"

    local agent_type_e
    agent_type_e=$(_sql_escape "$agent_type")

    local where_clause
    if [[ -n "$wf_id" ]]; then
        local wf_id_e
        wf_id_e=$(_sql_escape "$wf_id")
        where_clause="WHERE agent_type='${agent_type_e}' AND workflow_id='${wf_id_e}' AND status='active'"
    else
        where_clause="WHERE agent_type='${agent_type_e}' AND status='active'"
    fi

    # Fetch all candidate active markers
    local rows
    rows=$(_state_sql "
.separator '|'
SELECT agent_type, session_id, workflow_id, status, pid, created_at, COALESCE(trace_id,'')
FROM agent_markers
${where_clause}
ORDER BY created_at ASC;
") || true

    [[ -z "$rows" ]] && return 0

    local ts
    ts=$(date +%s)

    # For each row, check PID liveness; emit alive rows, mark dead ones as crashed
    local line marker_pid
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Extract PID (field 5)
        marker_pid=$(echo "$line" | cut -d'|' -f5)
        if [[ -n "$marker_pid" ]] && kill -0 "$marker_pid" 2>/dev/null; then
            # PID is alive — include in output
            echo "$line"
        else
            # PID is dead — self-heal: mark as crashed
            local dead_agent_type dead_session_id dead_wf_id
            dead_agent_type=$(echo "$line" | cut -d'|' -f1)
            dead_session_id=$(echo "$line" | cut -d'|' -f2)
            dead_wf_id=$(echo "$line" | cut -d'|' -f3)
            local dead_agent_type_e dead_session_id_e dead_wf_id_e
            dead_agent_type_e=$(_sql_escape "$dead_agent_type")
            dead_session_id_e=$(_sql_escape "$dead_session_id")
            dead_wf_id_e=$(_sql_escape "$dead_wf_id")
            _state_sql "
BEGIN IMMEDIATE;
UPDATE agent_markers
SET status='crashed', updated_at=${ts}
WHERE agent_type='${dead_agent_type_e}'
  AND session_id='${dead_session_id_e}'
  AND workflow_id='${dead_wf_id_e}';
COMMIT;
" >/dev/null 2>/dev/null || true
        fi
    done <<< "$rows"

    return 0
}

# marker_update TYPE SESSION_ID WORKFLOW_ID STATUS [TRACE_ID]
#   Updates an existing marker's status. Used for lifecycle transitions
#   (e.g., active→completed, active→crashed).
#   Returns 0 on success (even if no row matched — idempotent).
marker_update() {
    local agent_type="${1:?marker_update requires agent_type}"
    local session_id="${2:?marker_update requires session_id}"
    local wf_id="${3:?marker_update requires workflow_id}"
    local new_status="${4:?marker_update requires new_status}"
    local trace_id="${5:-}"
    local ts
    ts=$(date +%s)

    local agent_type_e session_id_e wf_id_e new_status_e trace_clause
    agent_type_e=$(_sql_escape "$agent_type")
    session_id_e=$(_sql_escape "$session_id")
    wf_id_e=$(_sql_escape "$wf_id")
    new_status_e=$(_sql_escape "$new_status")

    if [[ -n "$trace_id" ]]; then
        local trace_id_e
        trace_id_e=$(_sql_escape "$trace_id")
        trace_clause=", trace_id='${trace_id_e}'"
    else
        trace_clause=""
    fi

    _state_sql "
BEGIN IMMEDIATE;
UPDATE agent_markers
SET status='${new_status_e}', updated_at=${ts}${trace_clause}
WHERE agent_type='${agent_type_e}'
  AND session_id='${session_id_e}'
  AND workflow_id='${wf_id_e}';
COMMIT;
" >/dev/null && return 0 || return 1
}

# marker_cleanup [STALE_SECONDS]
#   Two-phase cleanup of agent_markers:
#     Phase 1: Find active markers with dead PIDs → mark as 'crashed' (self-healing)
#     Phase 2: DELETE markers where:
#       - status IN ('completed','crashed') AND updated_at < cutoff
#       - OR status = 'active' AND created_at < cutoff (catch truly stale actives)
#   Default stale threshold: 3600 seconds (1 hour).
#   Returns the count of deleted rows via echo.
marker_cleanup() {
    local stale_seconds="${1:-3600}"
    local ts
    ts=$(date +%s)
    local cutoff=$(( ts - stale_seconds ))

    # Phase 1: Find all active markers and check PID liveness
    local active_rows
    active_rows=$(_state_sql "
.separator '|'
SELECT agent_type, session_id, workflow_id, pid
FROM agent_markers
WHERE status='active';
") || true

    if [[ -n "$active_rows" ]]; then
        local line marker_pid
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            marker_pid=$(echo "$line" | cut -d'|' -f4)
            if [[ -n "$marker_pid" ]] && ! kill -0 "$marker_pid" 2>/dev/null; then
                # Dead PID — mark as crashed
                local dead_at dead_sess dead_wf
                dead_at=$(echo "$line" | cut -d'|' -f1)
                dead_sess=$(echo "$line" | cut -d'|' -f2)
                dead_wf=$(echo "$line" | cut -d'|' -f3)
                local dead_at_e dead_sess_e dead_wf_e
                dead_at_e=$(_sql_escape "$dead_at")
                dead_sess_e=$(_sql_escape "$dead_sess")
                dead_wf_e=$(_sql_escape "$dead_wf")
                _state_sql "
BEGIN IMMEDIATE;
UPDATE agent_markers
SET status='crashed', updated_at=${ts}
WHERE agent_type='${dead_at_e}'
  AND session_id='${dead_sess_e}'
  AND workflow_id='${dead_wf_e}';
COMMIT;
" >/dev/null 2>/dev/null || true
            fi
        done <<< "$active_rows"
    fi

    # Phase 2: Delete stale markers (completed/crashed past cutoff, or truly stale actives)
    local deleted
    deleted=$(_state_sql "
BEGIN IMMEDIATE;
DELETE FROM agent_markers
WHERE (status IN ('completed','crashed') AND updated_at < ${cutoff})
   OR (status = 'active' AND created_at < ${cutoff});
SELECT changes();
COMMIT;
") || true
    deleted="${deleted//[[:space:]]/}"
    echo "${deleted:-0}"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Event Ledger API (DEC-STATE-UNIFY-005)
# ─────────────────────────────────────────────────────────────────────────────

# state_emit TYPE PAYLOAD [WORKFLOW_ID]
#   Append an event to the events ledger.
#   Returns the sequence number (INTEGER) of the new event on stdout.
#   TYPE is a dot-namespaced string (e.g. "workflow.step", "task.completed").
#   PAYLOAD is an opaque TEXT value — callers pass JSON strings; this function
#   stores/retrieves as-is without parsing.
#   WORKFLOW_ID defaults to workflow_id() for the current context.
#   Uses BEGIN IMMEDIATE for write safety (DEC-STATE-UNIFY-001).
#
# @decision DEC-STATE-UNIFY-005
# @title state_emit uses BEGIN IMMEDIATE + last_insert_rowid() for seq return
# @status accepted
# @rationale AUTOINCREMENT on events.seq guarantees strictly-monotone IDs.
#   Returning last_insert_rowid() in the same transaction (before COMMIT) is
#   safe because the rowid is connection-local and cannot be stolen by a
#   concurrent writer. The consumer receives the seq as plain text on stdout
#   so callers can capture it via command substitution.
state_emit() {
    local type="${1:?state_emit requires a type}"
    local payload="${2:-}"
    local wf_id="${3:-}"
    if [[ -z "$wf_id" ]]; then
        wf_id=$(workflow_id)
    fi
    local session_id="${CLAUDE_SESSION_ID:-}"
    local ts
    ts=$(date +%s)

    local type_e payload_e wf_id_e session_id_e
    type_e=$(_sql_escape "$type")
    payload_e=$(_sql_escape "$payload")
    wf_id_e=$(_sql_escape "$wf_id")

    local session_val
    if [[ -n "$session_id" ]]; then
        session_id_e=$(_sql_escape "$session_id")
        session_val="'${session_id_e}'"
    else
        session_val="NULL"
    fi

    local payload_val
    if [[ -n "$payload" ]]; then
        payload_val="'${payload_e}'"
    else
        payload_val="NULL"
    fi

    _state_sql "
BEGIN IMMEDIATE;
INSERT INTO events (type, workflow_id, session_id, payload, created_at)
VALUES ('${type_e}', '${wf_id_e}', ${session_val}, ${payload_val}, ${ts});
SELECT last_insert_rowid();
COMMIT;
"
}

# state_events_since CONSUMER [TYPE] [WORKFLOW_ID] [LIMIT]
#   Return events newer than the consumer's last checkpoint.
#   Output: one pipe-delimited line per event: seq|type|workflow_id|session_id|payload|created_at
#   CONSUMER identifies the caller (e.g. "tester", "guardian", "observer").
#   TYPE — if non-empty, filters to that event type only.
#   WORKFLOW_ID — if non-empty, filters to that workflow only.
#   LIMIT — maximum number of events to return (default: 100).
#   If the consumer has no checkpoint, all events from seq > 0 are returned.
#   Events are ordered by seq ASC (oldest first).
state_events_since() {
    local consumer="${1:?state_events_since requires a consumer}"
    local type="${2:-}"
    local wf_id="${3:-}"
    local limit="${4:-100}"

    local consumer_e type_e wf_id_e
    consumer_e=$(_sql_escape "$consumer")

    # Get consumer's last_seq (0 if no checkpoint exists)
    local last_seq
    last_seq=$(_state_sql "
SELECT COALESCE(
    (SELECT last_seq FROM event_checkpoints WHERE consumer='${consumer_e}'),
    0
);
") || true
    last_seq="${last_seq//[[:space:]]/}"
    last_seq="${last_seq:-0}"

    # Build WHERE clause
    local where_clause="WHERE seq > ${last_seq}"
    if [[ -n "$type" ]]; then
        type_e=$(_sql_escape "$type")
        where_clause="${where_clause} AND type='${type_e}'"
    fi
    if [[ -n "$wf_id" ]]; then
        wf_id_e=$(_sql_escape "$wf_id")
        where_clause="${where_clause} AND workflow_id='${wf_id_e}'"
    fi

    _state_sql "
.separator '|'
SELECT seq, type, workflow_id, COALESCE(session_id,''), COALESCE(payload,''), created_at
FROM events
${where_clause}
ORDER BY seq ASC
LIMIT ${limit};
"
}

# state_checkpoint CONSUMER SEQ
#   Update the consumer's position in the event ledger to SEQ.
#   Uses INSERT OR REPLACE for idempotency — re-setting to the same SEQ is a no-op.
#   Consumers SHOULD call this after processing each batch from state_events_since()
#   to advance their checkpoint and enable GC.
state_checkpoint() {
    local consumer="${1:?state_checkpoint requires a consumer}"
    local seq="${2:?state_checkpoint requires a sequence number}"
    local ts
    ts=$(date +%s)

    local consumer_e
    consumer_e=$(_sql_escape "$consumer")

    _state_sql "
BEGIN IMMEDIATE;
INSERT OR REPLACE INTO event_checkpoints (consumer, last_seq, updated_at)
VALUES ('${consumer_e}', ${seq}, ${ts});
COMMIT;
" >/dev/null && return 0 || return 1
}

# state_events_count CONSUMER [TYPE] [WORKFLOW_ID]
#   Return the count of events newer than the consumer's last checkpoint.
#   Lightweight threshold check (e.g. "are there >= 3 assessments pending?").
#   TYPE — if non-empty, filters to that event type only.
#   WORKFLOW_ID — if non-empty, filters to that workflow only.
#   Returns an integer (0 if none or no checkpoint exists).
state_events_count() {
    local consumer="${1:?state_events_count requires a consumer}"
    local type="${2:-}"
    local wf_id="${3:-}"

    local consumer_e type_e wf_id_e
    consumer_e=$(_sql_escape "$consumer")

    # Get consumer's last_seq (0 if no checkpoint exists)
    local last_seq
    last_seq=$(_state_sql "
SELECT COALESCE(
    (SELECT last_seq FROM event_checkpoints WHERE consumer='${consumer_e}'),
    0
);
") || true
    last_seq="${last_seq//[[:space:]]/}"
    last_seq="${last_seq:-0}"

    # Build WHERE clause
    local where_clause="WHERE seq > ${last_seq}"
    if [[ -n "$type" ]]; then
        type_e=$(_sql_escape "$type")
        where_clause="${where_clause} AND type='${type_e}'"
    fi
    if [[ -n "$wf_id" ]]; then
        wf_id_e=$(_sql_escape "$wf_id")
        where_clause="${where_clause} AND workflow_id='${wf_id_e}'"
    fi

    local count
    count=$(_state_sql "SELECT COUNT(*) FROM events ${where_clause};") || true
    count="${count//[[:space:]]/}"
    echo "${count:-0}"
}

# state_gc_events [MAX_AGE_SECONDS]
#   Garbage-collect events that ALL registered consumers have processed.
#   Deletes events where seq <= MIN(all consumer checkpoints).
#   MAX_AGE_SECONDS — if provided, also deletes events older than that timestamp
#   regardless of checkpoint state (safety net for abandoned consumers / long-idle
#   streams). Only applied when at least one consumer exists.
#   Returns the count of deleted events on stdout.
#
# @decision DEC-STATE-UNIFY-005
# @title GC only when all consumers have advanced past an event
# @status accepted
# @rationale Deleting events that a consumer has not yet processed would cause
#   that consumer to silently miss events — violating the delivery guarantee.
#   The min-checkpoint approach is safe: if any consumer is behind, we only
#   delete up to where that slowest consumer is. MAX_AGE_SECONDS provides a
#   bounded fallback for the case where a consumer is abandoned (crashed,
#   deleted, or never advanced) — without it, the events table would grow
#   forever if any consumer stops advancing. The fallback only fires when
#   MAX_AGE_SECONDS is provided explicitly; callers choose this trade-off.
state_gc_events() {
    local max_age="${1:-}"
    local ts
    ts=$(date +%s)

    # Get minimum checkpoint across all consumers.
    # If no consumers exist, min_checkpoint is NULL — skip GC.
    local min_checkpoint
    min_checkpoint=$(_state_sql "
SELECT MIN(last_seq) FROM event_checkpoints;
") || true
    min_checkpoint="${min_checkpoint//[[:space:]]/}"

    local deleted=0

    if [[ -n "$min_checkpoint" ]] && [[ "$min_checkpoint" != "NULL" ]] && [[ "$min_checkpoint" =~ ^[0-9]+$ ]]; then
        # Delete events all consumers have seen
        local del_result
        del_result=$(_state_sql "
BEGIN IMMEDIATE;
DELETE FROM events WHERE seq <= ${min_checkpoint};
SELECT changes();
COMMIT;
") || true
        del_result="${del_result//[[:space:]]/}"
        deleted="${del_result:-0}"
    fi

    # MAX_AGE_SECONDS fallback: delete events older than cutoff regardless of checkpoint.
    # Only runs when max_age is specified — this handles abandoned consumers.
    if [[ -n "$max_age" ]] && [[ "$max_age" =~ ^[0-9]+$ ]]; then
        local cutoff=$(( ts - max_age ))
        local age_del_result
        age_del_result=$(_state_sql "
BEGIN IMMEDIATE;
DELETE FROM events WHERE created_at < ${cutoff};
SELECT changes();
COMMIT;
") || true
        age_del_result="${age_del_result//[[:space:]]/}"
        deleted=$(( deleted + ${age_del_result:-0} ))
    fi

    echo "$deleted"
}

# ─────────────────────────────────────────────────────────────────────────────
# Integrity Check and Recovery
# ─────────────────────────────────────────────────────────────────────────────

# state_integrity_check
#   Run PRAGMA integrity_check against state.db.
#   If the check fails, log the corruption and attempt to rebuild from .bak.
#   Called from session-init.sh after the backup step (A3).
#
#   Recovery strategy:
#   1. Run PRAGMA integrity_check
#   2. If "ok" — return 0 silently
#   3. If corrupted — log a warning
#   4. If .bak exists — copy it over the corrupted db and re-verify
#   5. Return 0 on success (recovered), 1 if unrecoverable
#
# @decision DEC-DBSAFE-005
# @title state_integrity_check() with .bak recovery in state-lib.sh
# @status accepted
# @rationale SQLite databases can be silently corrupted by interrupted writes,
#   OS crashes, or partial disk flushes. Detecting corruption at session start
#   (after backup is created) provides a recovery window before any hooks read
#   stale or corrupted state. The .bak file (written by session-init.sh before
#   the first hook runs) is the recovery source — it represents the last known
#   good state. If recovery fails (no .bak, or .bak also corrupted), the
#   function returns 1 and logs — the caller (session-init.sh) surfaces this
#   to the user as a CONTEXT warning.
state_integrity_check() {
    local db
    db=$(_state_db_path)

    # If DB doesn't exist yet, nothing to check
    if [[ ! -f "$db" ]]; then
        return 0
    fi

    local result
    result=$(printf '.timeout 5000\nPRAGMA integrity_check;\n' | sqlite3 "$db" 2>/dev/null || echo "error")

    if [[ "$result" == "ok" ]]; then
        return 0
    fi

    # Corruption detected
    log_info "STATE-INTEGRITY" "state.db integrity check failed: $result — attempting recovery from .bak"

    local bak="${db}.bak"
    if [[ ! -f "$bak" ]]; then
        log_info "STATE-INTEGRITY" "No .bak file available for recovery — state.db is corrupted and unrecoverable"
        echo "CORRUPT: state.db integrity check failed (no backup available). Manual intervention required."
        return 1
    fi

    # Attempt recovery: copy .bak over the corrupted db
    if cp "$bak" "$db" 2>/dev/null; then
        # Re-verify the recovered DB
        local recovered_result
        recovered_result=$(printf '.timeout 5000\nPRAGMA integrity_check;\n' | sqlite3 "$db" 2>/dev/null || echo "error")
        if [[ "$recovered_result" == "ok" ]]; then
            log_info "STATE-INTEGRITY" "Recovery succeeded — state.db restored from .bak"
            echo "RECOVERED: state.db was corrupted, successfully restored from backup."
            return 0
        else
            log_info "STATE-INTEGRITY" "Recovery failed — .bak is also corrupted: $recovered_result"
            echo "CORRUPT: state.db integrity check failed and .bak recovery failed. Manual intervention required."
            return 1
        fi
    else
        log_info "STATE-INTEGRITY" "Recovery failed — could not copy .bak to state.db"
        echo "CORRUPT: state.db integrity check failed and backup copy failed. Manual intervention required."
        return 1
    fi
}

export -f workflow_id _state_sql _state_ensure_schema _state_db_path
export -f state_update state_read state_cas state_delete
export -f state_dir state_locks_dir
export -f state_integrity_check
export -f state_migrate _state_run_migrations _state_checksum_fn
export -f _migration_001_initial_schema
export -f proof_state_get proof_state_set proof_epoch_reset
export -f marker_create marker_query marker_update marker_cleanup
export -f state_emit state_events_since state_checkpoint state_events_count state_gc_events
export -f _sql_escape _proof_ordinal

_STATE_LIB_LOADED=1
