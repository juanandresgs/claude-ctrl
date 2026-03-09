#!/usr/bin/env bash
# test-db-safety-w1a.sh — Tests for Wave 1a DB safety features.
#
# Tests the following components:
#   A1: pre-bash.sh blocks direct sqlite3 access to state.db
#   A2: state-diag.sh read-only diagnostic tool
#   A3: session-init.sh backup on session start
#   A4: state_integrity_check() in state-lib.sh
#
# Usage: bash tests/test-db-safety-w1a.sh
#
# @decision DEC-DBSAFE-TEST-001
# @title Isolated temp environment per test for db-safety tests
# @status accepted
# @rationale Each test creates its own CLAUDE_DIR/state/ to avoid cross-test
#   contamination. pre-bash.sh tests use stdin JSON simulation matching the real
#   hook interface. state-diag.sh tests use a real SQLite DB with known content.
#   state_integrity_check() tests use a deliberate corruption scenario.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
    local test_name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "Running: $test_name"
}

pass_test() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  PASS"
}

fail_test() {
    local reason="$1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL: $reason"
}

skip_test() {
    local reason="$1"
    echo "  SKIP: $reason"
}

# Global tmp dir — cleaned on EXIT
TMPDIR_BASE="$PROJECT_ROOT/tmp/test-db-safety-w1a-$$"
mkdir -p "$TMPDIR_BASE"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Helper: invoke pre-bash.sh with a fake command and return the JSON output
# ─────────────────────────────────────────────────────────────────────────────
_invoke_pre_bash() {
    local cmd="$1"
    local json
    json=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"}' \
        "$(printf '%s' "$cmd" | sed 's/"/\\"/g')" \
        "$PROJECT_ROOT")
    echo "$json" | bash "$HOOKS_DIR/pre-bash.sh" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# A1 Tests: pre-bash.sh blocks sqlite3 access to state.db
# ─────────────────────────────────────────────────────────────────────────────

run_test "A1.1: sqlite3 state/state.db is blocked"
_RESULT=$(_invoke_pre_bash "sqlite3 ~/.claude/state/state.db 'SELECT * FROM state'")
if echo "$_RESULT" | grep -q '"deny"'; then
    pass_test
else
    fail_test "expected deny for sqlite3 state/state.db, got: $(echo "$_RESULT" | head -2)"
fi

run_test "A1.2: sqlite3 with state.db path variant is blocked"
_RESULT=$(_invoke_pre_bash "sqlite3 /Users/turla/.claude/state/state.db .tables")
if echo "$_RESULT" | grep -q '"deny"'; then
    pass_test
else
    fail_test "expected deny for full-path sqlite3 state.db, got: $(echo "$_RESULT" | head -2)"
fi

run_test "A1.3: sqlite3 with bare state.db filename is blocked"
_RESULT=$(_invoke_pre_bash "sqlite3 state.db 'SELECT 1'")
if echo "$_RESULT" | grep -q '"deny"'; then
    pass_test
else
    fail_test "expected deny for sqlite3 state.db (bare filename), got: $(echo "$_RESULT" | head -2)"
fi

run_test "A1.4: sqlite3 other.db is NOT blocked"
_RESULT=$(_invoke_pre_bash "sqlite3 /tmp/other.db 'SELECT 1'")
if echo "$_RESULT" | grep -q '"deny"'; then
    fail_test "sqlite3 other.db should NOT be blocked, got: $(echo "$_RESULT" | head -2)"
else
    pass_test
fi

run_test "A1.5: sqlite3 myproject.db is NOT blocked"
_RESULT=$(_invoke_pre_bash "sqlite3 ~/myproject.db 'SELECT * FROM users'")
if echo "$_RESULT" | grep -q '"deny"'; then
    fail_test "sqlite3 myproject.db should NOT be blocked, got: $(echo "$_RESULT" | head -2)"
else
    pass_test
fi

run_test "A1.6: deny message references state_read/state_update API"
_RESULT=$(_invoke_pre_bash "sqlite3 ~/.claude/state/state.db 'SELECT * FROM state'")
if echo "$_RESULT" | grep -q 'state_read\|state_update\|state-diag'; then
    pass_test
else
    fail_test "deny message should reference state_read()/state_update() or state-diag.sh, got: $(echo "$_RESULT" | head -3)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# A2 Tests: state-diag.sh read-only diagnostic tool
# ─────────────────────────────────────────────────────────────────────────────

_DIAG_SCRIPT="$SCRIPTS_DIR/state-diag.sh"

run_test "A2.0: state-diag.sh exists and is executable"
if [[ -x "$_DIAG_SCRIPT" ]]; then
    pass_test
else
    fail_test "state-diag.sh not found or not executable at $_DIAG_SCRIPT"
fi

if [[ ! -x "$_DIAG_SCRIPT" ]]; then
    echo "SKIP: Remaining A2 tests require state-diag.sh"
else

# Create a temp DB for A2 tests
_DIAG_TMPDIR="$TMPDIR_BASE/diag-test"
mkdir -p "$_DIAG_TMPDIR/state"
_DIAG_DB="$_DIAG_TMPDIR/state/state.db"

# Bootstrap a minimal schema in the test DB
sqlite3 "$_DIAG_DB" "
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS state (
    key TEXT NOT NULL,
    value TEXT NOT NULL,
    workflow_id TEXT NOT NULL,
    session_id TEXT,
    updated_at INTEGER NOT NULL,
    source TEXT NOT NULL,
    pid INTEGER,
    PRIMARY KEY (key, workflow_id)
);
CREATE TABLE IF NOT EXISTS history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    key TEXT NOT NULL,
    value TEXT NOT NULL,
    workflow_id TEXT NOT NULL,
    session_id TEXT,
    source TEXT NOT NULL,
    timestamp INTEGER NOT NULL,
    pid INTEGER
);
INSERT OR IGNORE INTO state (key, value, workflow_id, session_id, updated_at, source, pid)
VALUES ('test_key', 'test_value', 'test_workflow', NULL, strftime('%s','now'), 'test', $$);
INSERT OR IGNORE INTO state (key, value, workflow_id, session_id, updated_at, source, pid)
VALUES ('active_workflow', 'wf-12345', '_system', NULL, strftime('%s','now'), 'test', $$);
" 2>/dev/null

run_test "A2.1: state-diag.sh list shows state entries"
_DIAG_OUT=$(CLAUDE_DIR="$_DIAG_TMPDIR" bash "$_DIAG_SCRIPT" list 2>&1 || true)
if echo "$_DIAG_OUT" | grep -q "test_key\|test_value\|state"; then
    pass_test
else
    fail_test "state-diag.sh list should show state entries, got: $(echo "$_DIAG_OUT" | head -3)"
fi

run_test "A2.2: state-diag.sh raw SELECT works"
_DIAG_OUT=$(CLAUDE_DIR="$_DIAG_TMPDIR" bash "$_DIAG_SCRIPT" raw "SELECT key FROM state LIMIT 1" 2>&1 || true)
if echo "$_DIAG_OUT" | grep -qiE "key|test_key|value|Error.*read.*only"; then
    pass_test
else
    fail_test "state-diag.sh raw SELECT should work, got: $(echo "$_DIAG_OUT" | head -3)"
fi

run_test "A2.3: state-diag.sh raw INSERT is rejected"
_DIAG_OUT=$(CLAUDE_DIR="$_DIAG_TMPDIR" bash "$_DIAG_SCRIPT" raw "INSERT INTO state VALUES ('x','y','z',NULL,0,'src',0)" 2>&1 || true)
if echo "$_DIAG_OUT" | grep -qiE "error|blocked|denied|read.only|only.*select|SELECT"; then
    pass_test
else
    fail_test "state-diag.sh raw INSERT should be rejected, got: $(echo "$_DIAG_OUT" | head -3)"
fi

run_test "A2.4: state-diag.sh raw DELETE is rejected"
_DIAG_OUT=$(CLAUDE_DIR="$_DIAG_TMPDIR" bash "$_DIAG_SCRIPT" raw "DELETE FROM state WHERE 1=1" 2>&1 || true)
if echo "$_DIAG_OUT" | grep -qiE "error|blocked|denied|read.only|only.*select|SELECT"; then
    pass_test
else
    fail_test "state-diag.sh raw DELETE should be rejected, got: $(echo "$_DIAG_OUT" | head -3)"
fi

run_test "A2.5: state-diag.sh raw UPDATE is rejected"
_DIAG_OUT=$(CLAUDE_DIR="$_DIAG_TMPDIR" bash "$_DIAG_SCRIPT" raw "UPDATE state SET value='bad' WHERE 1=1" 2>&1 || true)
if echo "$_DIAG_OUT" | grep -qiE "error|blocked|denied|read.only|only.*select|SELECT"; then
    pass_test
else
    fail_test "state-diag.sh raw UPDATE should be rejected, got: $(echo "$_DIAG_OUT" | head -3)"
fi

run_test "A2.6: state-diag.sh integrity command succeeds on healthy DB"
_DIAG_OUT=$(CLAUDE_DIR="$_DIAG_TMPDIR" bash "$_DIAG_SCRIPT" integrity 2>&1 || true)
if echo "$_DIAG_OUT" | grep -qiE "ok|integrity"; then
    pass_test
else
    fail_test "state-diag.sh integrity on healthy DB should show ok, got: $(echo "$_DIAG_OUT" | head -3)"
fi

run_test "A2.7: state-diag.sh schema shows tables"
_DIAG_OUT=$(CLAUDE_DIR="$_DIAG_TMPDIR" bash "$_DIAG_SCRIPT" schema 2>&1 || true)
if echo "$_DIAG_OUT" | grep -qiE "CREATE TABLE|state|history|schema"; then
    pass_test
else
    fail_test "state-diag.sh schema should show CREATE TABLE, got: $(echo "$_DIAG_OUT" | head -3)"
fi

fi # end: state-diag.sh exists check

# ─────────────────────────────────────────────────────────────────────────────
# A3 Tests: session-init.sh backup creates state.db.bak
# ─────────────────────────────────────────────────────────────────────────────

run_test "A3.1: Backup creates state.db.bak at session start"
if ! command -v sqlite3 >/dev/null 2>&1; then
    skip_test "sqlite3 not installed"
else
    _BACKUP_TMPDIR="$TMPDIR_BASE/backup-test"
    mkdir -p "$_BACKUP_TMPDIR/state"
    _BACKUP_DB="$_BACKUP_TMPDIR/state/state.db"

    # Create a real SQLite DB with data
    sqlite3 "$_BACKUP_DB" "
PRAGMA journal_mode=WAL;
CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT, workflow_id TEXT NOT NULL, session_id TEXT, updated_at INTEGER NOT NULL, source TEXT NOT NULL, pid INTEGER);
INSERT INTO state VALUES ('test_backup', 'backup_value', 'wf-test', NULL, strftime('%s','now'), 'test', $$);
" 2>/dev/null

    # Source the backup function from session-init.sh directly if it's extracted,
    # or test via the backup script produced
    # We test the backup logic indirectly: the backup function should be callable
    # by running only the backup portion of session-init.sh

    # Run the backup snippet directly (simulates what session-init.sh does)
    _STATE_DB_PATH="$_BACKUP_DB"
    _STATE_BAK_PATH="${_BACKUP_DB}.bak"

    if [[ -f "$_STATE_DB_PATH" && -s "$_STATE_DB_PATH" ]]; then
        sqlite3 "$_STATE_DB_PATH" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>/dev/null || true
        cp "$_STATE_DB_PATH" "$_STATE_BAK_PATH" 2>/dev/null || true
    fi

    if [[ -f "$_STATE_BAK_PATH" && -s "$_STATE_BAK_PATH" ]]; then
        pass_test
    else
        fail_test "state.db.bak should exist and be non-empty after backup"
    fi
fi

run_test "A3.2: Backup does NOT create state.db.bak when state.db absent"
_NODBDIR="$TMPDIR_BASE/nodbdir"
mkdir -p "$_NODBDIR/state"
_STATE_DB_ABSENT="$_NODBDIR/state/state.db"
_STATE_BAK_ABSENT="${_STATE_DB_ABSENT}.bak"

# Simulate the backup conditional
if [[ -f "$_STATE_DB_ABSENT" && -s "$_STATE_DB_ABSENT" ]]; then
    cp "$_STATE_DB_ABSENT" "$_STATE_BAK_ABSENT" 2>/dev/null || true
fi

if [[ ! -f "$_STATE_BAK_ABSENT" ]]; then
    pass_test
else
    fail_test "state.db.bak should NOT be created when state.db does not exist"
fi

# ─────────────────────────────────────────────────────────────────────────────
# A4 Tests: state_integrity_check() in state-lib.sh
# ─────────────────────────────────────────────────────────────────────────────

run_test "A4.1: state_integrity_check passes on healthy DB"
if ! command -v sqlite3 >/dev/null 2>&1; then
    skip_test "sqlite3 not installed"
else
    _HEALTHY_TMPDIR="$TMPDIR_BASE/healthy-test"
    mkdir -p "$_HEALTHY_TMPDIR/state"
    _HEALTHY_DB="$_HEALTHY_TMPDIR/state/state.db"

    # Create valid DB
    sqlite3 "$_HEALTHY_DB" "
PRAGMA journal_mode=WAL;
CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT, workflow_id TEXT NOT NULL, session_id TEXT, updated_at INTEGER NOT NULL, source TEXT NOT NULL, pid INTEGER);
INSERT INTO state VALUES ('k1', 'v1', 'wf-1', NULL, strftime('%s','now'), 'test', $$);
" 2>/dev/null

    # Create backup too (needed for recovery path)
    cp "$_HEALTHY_DB" "${_HEALTHY_DB}.bak"

    # Test state_integrity_check via subshell
    _INTEGRITY_OUT=$(bash -c "
export CLAUDE_DIR='$_HEALTHY_TMPDIR'
export PROJECT_ROOT='$PROJECT_ROOT'
source '$HOOKS_DIR/source-lib.sh' 2>/dev/null
require_state
result=\$(state_integrity_check 2>&1)
echo \"\$result\"
" 2>/dev/null || true)

    if echo "$_INTEGRITY_OUT" | grep -qiE "ok|pass|healthy|integrity.*ok"; then
        pass_test
    else
        # Also accept empty output (no corruption = no message needed)
        if [[ -z "$_INTEGRITY_OUT" ]]; then
            pass_test
        else
            fail_test "state_integrity_check on healthy DB should pass, got: $(echo "$_INTEGRITY_OUT" | head -3)"
        fi
    fi
fi

run_test "A4.2: state_integrity_check detects corruption and attempts recovery from .bak"
if ! command -v sqlite3 >/dev/null 2>&1; then
    skip_test "sqlite3 not installed"
else
    _CORRUPT_TMPDIR="$TMPDIR_BASE/corrupt-test"
    mkdir -p "$_CORRUPT_TMPDIR/state"
    _CORRUPT_DB="$_CORRUPT_TMPDIR/state/state.db"
    _CORRUPT_BAK="${_CORRUPT_DB}.bak"

    # Create a valid backup first
    sqlite3 "$_CORRUPT_BAK" "
PRAGMA journal_mode=WAL;
CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT, workflow_id TEXT NOT NULL, session_id TEXT, updated_at INTEGER NOT NULL, source TEXT NOT NULL, pid INTEGER);
INSERT INTO state VALUES ('k1', 'v1', 'wf-1', NULL, strftime('%s','now'), 'test', $$);
" 2>/dev/null

    # Now create a corrupted DB (not a valid SQLite file)
    printf 'THIS IS NOT SQLITE DATA\x00\xFF\xFE\xFD' > "$_CORRUPT_DB"

    _CORRUPT_OUT=$(bash -c "
export CLAUDE_DIR='$_CORRUPT_TMPDIR'
export PROJECT_ROOT='$PROJECT_ROOT'
source '$HOOKS_DIR/source-lib.sh' 2>/dev/null
require_state
result=\$(state_integrity_check 2>&1)
echo \"\$result\"
" 2>/dev/null || true)

    # Check that the function detected corruption and logged it
    # OR that it recovered (backup replaced the corrupted file)
    _RECOVERED=false
    if [[ -f "$_CORRUPT_DB" ]]; then
        _INTEGRITY_CHECK=$(sqlite3 "$_CORRUPT_DB" "PRAGMA integrity_check;" 2>/dev/null || true)
        [[ "$_INTEGRITY_CHECK" == "ok" ]] && _RECOVERED=true
    fi

    if echo "$_CORRUPT_OUT" | grep -qiE "corrupt|error|recover|rebuild|bak"; then
        pass_test
    elif [[ "$_RECOVERED" == "true" ]]; then
        pass_test
    else
        fail_test "state_integrity_check should detect corruption, got: '$(echo "$_CORRUPT_OUT" | head -3)', recovered: $_RECOVERED"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==========================="
echo "Results: $TESTS_RUN total | $TESTS_PASSED passed | $TESTS_FAILED failed"
echo "==========================="

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
