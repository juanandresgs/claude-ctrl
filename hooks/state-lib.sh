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

# Guard against double-sourcing
[[ -n "${_STATE_LIB_LOADED:-}" ]] && return 0

_STATE_LIB_VERSION=2

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

INSERT OR IGNORE INTO state
    (key, value, workflow_id, session_id, updated_at, source, pid)
VALUES
    ('_schema_version', '1', '_system', NULL, strftime('%s','now'), 'state-lib', NULL);
" | sqlite3 "$db" 2>/dev/null || true

    _STATE_SCHEMA_INITIALIZED=1
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
BEGIN;
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
BEGIN;
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
#   .test-status, .proof-epoch, .cas-failures, .proof-gate-pending) into
#   a structured directory hierarchy. The project hash becomes a directory
#   name instead of a file suffix, yielding clean internal names.
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
# Legacy functions (preserved for Wave 2 dual-write migration)
# ─────────────────────────────────────────────────────────────────────────────

# _legacy_state_update KEY VALUE [SOURCE]
#   Original jq-based state_update. Renamed for Wave 2 dual-write.
#   DEPRECATED: Use state_update() instead. Kept for migration compatibility.
#
# @decision DEC-STATE-002
# @title flock on state_update() to prevent TOCTOU race conditions (legacy, superseded)
# @status superseded
# @rationale SQLite WAL handles concurrency without external locking.
#   This implementation is preserved for the Wave 2 dual-write window only.
_legacy_state_update() {
    local key="${1:?_legacy_state_update requires a key}"
    local value="${2:?_legacy_state_update requires a value}"
    local source="${3:-${_HOOK_NAME:-unknown}}"
    local claude_dir="${CLAUDE_DIR:-$(get_claude_dir 2>/dev/null || echo "$HOME/.claude")}"
    local state_dir_base="${claude_dir}/state"
    mkdir -p "$state_dir_base" 2>/dev/null || true
    local state_file="${state_dir_base}/state.json"
    local locks_dir="${state_dir_base}/locks"
    mkdir -p "$locks_dir" 2>/dev/null || true
    local lockfile="${locks_dir}/state.lock"
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    mkdir -p "$claude_dir" 2>/dev/null || return 0

    (
        if ! _lock_fd 5 9; then
            log_info "STATE" "lock timeout for ${key}, skipping update" 2>/dev/null || true
            return 0
        fi

        if [[ ! -f "$state_file" ]]; then
            echo '{"history":[]}' > "$state_file" 2>/dev/null || return 0
        fi

        local tmp="${state_file}.tmp.$$"
        jq --arg key "$key" \
           --arg val "$value" \
           --arg src "$source" \
           --arg ts "$timestamp" \
           '
           setpath($key | split(".") | map(select(. != "")); $val) |
           .history = ([{key: $key, value: $val, source: $src, ts: $ts}] + (.history // []))[:20]
           ' "$state_file" > "$tmp" 2>/dev/null && mv "$tmp" "$state_file" 2>/dev/null || {
            rm -f "$tmp" 2>/dev/null
            return 0
        }

        log_info "STATE" "updated ${key}=${value} (source=${source})" 2>/dev/null || true
    ) 9>"$lockfile"
}

# _legacy_state_read KEY
#   Original jq-based state_read. Renamed for Wave 2 dual-write.
#   DEPRECATED: Use state_read() instead. Kept for migration compatibility.
_legacy_state_read() {
    local key="${1:?_legacy_state_read requires a key}"
    local claude_dir="${CLAUDE_DIR:-$(get_claude_dir 2>/dev/null || echo "$HOME/.claude")}"
    local state_file="${claude_dir}/state/state.json"
    if [[ ! -f "$state_file" && -f "${claude_dir}/state.json" ]]; then
        state_file="${claude_dir}/state.json"
    fi

    [[ ! -f "$state_file" ]] && return 1

    local value
    value=$(jq -r "getpath(\"${key}\" | split(\".\") | map(select(. != \"\"))) // empty" "$state_file" 2>/dev/null)
    if [[ -n "$value" ]]; then
        echo "$value"
        return 0
    fi
    return 1
}

export -f workflow_id _state_sql _state_ensure_schema _state_db_path
export -f state_update state_read state_cas state_delete
export -f state_dir state_locks_dir
export -f _legacy_state_update _legacy_state_read
export -f _sql_escape _proof_ordinal

_STATE_LIB_LOADED=1
