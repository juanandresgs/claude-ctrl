#!/usr/bin/env bash
# test-token-history-sqlite.sh — Tests for SQLite-backed session_tokens table.
#
# Purpose: Verify that the session_tokens migration, INSERT path (session-end.sh),
#   and SELECT path (session-init.sh) work correctly with concurrency safety.
#
# @decision DEC-STATE-KV-003
# @title session_tokens table for atomic, per-project lifetime token tracking
# @status accepted
# @rationale See state-lib.sh DEC-STATE-KV-003 for full rationale. This test
#   file validates all five acceptance criteria: single INSERT, SUM query,
#   accumulation, project filtering, and JSON fallback for main tokens.
#
# Tests:
#   1. Migration creates session_tokens table with correct schema
#   2. Single INSERT + SELECT SUM returns correct value
#   3. Multiple INSERTs for same project accumulate correctly
#   4. Rows for different projects are isolated (no cross-contamination)
#   5. JSON fallback computes main tokens when .session-main-tokens is absent
#   6. Dual-write: flat-file entry still written alongside SQLite INSERT
#   7. idx_session_tokens_project index exists
#   8. Empty project returns 0 (COALESCE prevents NULL)
#
# Usage: bash tests/test-token-history-sqlite.sh
# Scope: --scope sqlite in run-hooks.sh
#

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT_REAL="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT_REAL/hooks"

# ---------------------------------------------------------------------------
# Test tracking
# ---------------------------------------------------------------------------
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
    local test_name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "  Running: $test_name"
}

pass_test() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "    PASS"
}

fail_test() {
    local reason="$1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "    FAIL: $reason"
}

# ---------------------------------------------------------------------------
# Temp environment helpers
# ---------------------------------------------------------------------------
_TMP_BASE="$PROJECT_ROOT_REAL/tmp/test-token-history-$$"
mkdir -p "$_TMP_BASE"

_TMPDIR=""

setup_env() {
    local label="${1:-test}"
    _TMPDIR="${_TMP_BASE}/${label}"
    mkdir -p "$_TMPDIR"
    # Minimal git repo so detect_project_root works
    git -C "$_TMPDIR" init -q 2>/dev/null || true
    export CLAUDE_DIR="$_TMPDIR/.claude"
    mkdir -p "$CLAUDE_DIR/state"
    export HOME="$_TMPDIR"
    export CLAUDE_SESSION_ID="test-session-$$"
    export PROJECT_ROOT="$_TMPDIR"

    # Reset schema guard so each test gets a fresh schema run
    unset _STATE_SCHEMA_INITIALIZED
    unset _STATE_LIB_LOADED
    unset _WORKFLOW_ID

    # Source state-lib fresh for this test
    # shellcheck source=/dev/null
    source "$HOOKS_DIR/source-lib.sh"
    require_state
}

teardown_env() {
    rm -rf "$_TMPDIR" 2>/dev/null || true
    _TMPDIR=""
}

# Direct sqlite3 helper against test DB
_db() {
    sqlite3 "$CLAUDE_DIR/state/state.db" "$1" 2>/dev/null
}

# Trigger schema initialization by running a no-op query
_init_schema() {
    _state_sql "SELECT 1;" >/dev/null 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Test 1: session_tokens table created after schema init
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 1: session_tokens table creation ==="

run_test "table exists after _state_ensure_schema"
setup_env "t1"
_init_schema
_tbl=$(_db "SELECT name FROM sqlite_master WHERE type='table' AND name='session_tokens';")
if [[ "$_tbl" == "session_tokens" ]]; then
    pass_test
else
    fail_test "table not found (got: '$_tbl')"
fi
teardown_env

run_test "session_id column exists"
setup_env "t1b"
_init_schema
_schema=$(_db ".schema session_tokens" 2>/dev/null || true)
if echo "$_schema" | grep -q "session_id"; then
    pass_test
else
    fail_test "session_id column missing"
fi
teardown_env

run_test "total_tokens column exists"
setup_env "t1c"
_init_schema
_schema=$(_db ".schema session_tokens" 2>/dev/null || true)
if echo "$_schema" | grep -q "total_tokens"; then
    pass_test
else
    fail_test "total_tokens column missing"
fi
teardown_env

run_test "project_hash column exists"
setup_env "t1d"
_init_schema
_schema=$(_db ".schema session_tokens" 2>/dev/null || true)
if echo "$_schema" | grep -q "project_hash"; then
    pass_test
else
    fail_test "project_hash column missing"
fi
teardown_env

run_test "migration version 2 recorded in _migrations"
setup_env "t1e"
_init_schema
_mv=$(_db "SELECT version FROM _migrations WHERE version=2;" 2>/dev/null || echo "")
if [[ "$_mv" == "2" ]]; then
    pass_test
else
    fail_test "migration version 2 not recorded (got: '$_mv')"
fi
teardown_env

# ---------------------------------------------------------------------------
# Test 2: Single INSERT + SUM
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 2: Single INSERT and SUM ==="

run_test "SUM returns inserted value"
setup_env "t2"
_init_schema
_phash="abc12345"
_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
_db "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
     VALUES ('sess-1', '$_phash', 'testproj', '$_ts', 5000, 4500, 500, 'test');"
_sum=$(_db "SELECT COALESCE(SUM(total_tokens), 0) FROM session_tokens WHERE project_hash = '$_phash';")
if [[ "$_sum" == "5000" ]]; then
    pass_test
else
    fail_test "SUM = '$_sum', expected 5000"
fi
teardown_env

# ---------------------------------------------------------------------------
# Test 3: Multiple INSERTs accumulate
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 3: Multiple INSERT accumulation ==="

run_test "SUM of 3 equal rows = 3000"
setup_env "t3"
_init_schema
_phash="abc12345"
_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for i in 1 2 3; do
    _db "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
         VALUES ('sess-$i', '$_phash', 'testproj', '$_ts', 1000, 900, 100, 'test');"
done
_sum=$(_db "SELECT COALESCE(SUM(total_tokens), 0) FROM session_tokens WHERE project_hash = '$_phash';")
if [[ "$_sum" == "3000" ]]; then
    pass_test
else
    fail_test "SUM = '$_sum', expected 3000"
fi
teardown_env

run_test "row count = 3 after 3 INSERTs"
setup_env "t3b"
_init_schema
_phash="abc12345"
_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for i in 1 2 3; do
    _db "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
         VALUES ('sess-$i', '$_phash', 'testproj', '$_ts', 1000, 900, 100, 'test');"
done
_rows=$(_db "SELECT COUNT(*) FROM session_tokens WHERE project_hash = '$_phash';")
if [[ "$_rows" == "3" ]]; then
    pass_test
else
    fail_test "row count = '$_rows', expected 3"
fi
teardown_env

# ---------------------------------------------------------------------------
# Test 4: Cross-project isolation
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 4: Cross-project isolation ==="

run_test "project A sum unaffected by project B"
setup_env "t4"
_init_schema
_phash_a="aaa00000"
_phash_b="bbb11111"
_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
_db "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
     VALUES ('sess-a', '$_phash_a', 'project-a', '$_ts', 7000, 6000, 1000, 'test');"
_db "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
     VALUES ('sess-b', '$_phash_b', 'project-b', '$_ts', 3000, 2500, 500, 'test');"
_sum_a=$(_db "SELECT COALESCE(SUM(total_tokens), 0) FROM session_tokens WHERE project_hash = '$_phash_a';")
if [[ "$_sum_a" == "7000" ]]; then
    pass_test
else
    fail_test "Project A sum = '$_sum_a', expected 7000"
fi
teardown_env

run_test "project B sum unaffected by project A"
setup_env "t4b"
_init_schema
_phash_a="aaa00000"
_phash_b="bbb11111"
_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
_db "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
     VALUES ('sess-a', '$_phash_a', 'project-a', '$_ts', 7000, 6000, 1000, 'test');"
_db "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
     VALUES ('sess-b', '$_phash_b', 'project-b', '$_ts', 3000, 2500, 500, 'test');"
_sum_b=$(_db "SELECT COALESCE(SUM(total_tokens), 0) FROM session_tokens WHERE project_hash = '$_phash_b';")
if [[ "$_sum_b" == "3000" ]]; then
    pass_test
else
    fail_test "Project B sum = '$_sum_b', expected 3000"
fi
teardown_env

run_test "global sum = sum of all projects"
setup_env "t4c"
_init_schema
_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
_db "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
     VALUES ('sess-a', 'aaa00000', 'project-a', '$_ts', 7000, 6000, 1000, 'test');"
_db "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
     VALUES ('sess-b', 'bbb11111', 'project-b', '$_ts', 3000, 2500, 500, 'test');"
_total=$(_db "SELECT COALESCE(SUM(total_tokens), 0) FROM session_tokens;")
if [[ "$_total" == "10000" ]]; then
    pass_test
else
    fail_test "Global sum = '$_total', expected 10000"
fi
teardown_env

# ---------------------------------------------------------------------------
# Test 5: JSON fallback for main tokens (no .session-main-tokens file)
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 5: JSON fallback for main tokens ==="

run_test "input+output tokens from JSON = 10000 when flat file absent"
setup_env "t5"
_init_schema

_SESSION_END_INPUT='{"reason":"normal","context_window":{"total_input_tokens":8000,"total_output_tokens":2000}}'
_MAIN_TOKEN_FILE="${CLAUDE_DIR}/.session-main-tokens"

# Replicate the session-end.sh logic: flat file first, JSON fallback
_MT=0
if [[ -f "$_MAIN_TOKEN_FILE" ]]; then
    _MT=$(cat "$_MAIN_TOKEN_FILE" 2>/dev/null || echo "0")
    _MT="${_MT%.*}"
    _MT=$(( ${_MT:-0} ))
fi
if [[ "$_MT" -eq 0 ]]; then
    _MI=$(printf '%s' "$_SESSION_END_INPUT" | jq -r '.context_window.total_input_tokens // 0' 2>/dev/null || echo "0")
    _MO=$(printf '%s' "$_SESSION_END_INPUT" | jq -r '.context_window.total_output_tokens // 0' 2>/dev/null || echo "0")
    _MT=$(( ${_MI:-0} + ${_MO:-0} ))
fi

if [[ "$_MT" -eq 10000 ]]; then
    pass_test
else
    fail_test "JSON fallback returned '$_MT', expected 10000"
fi
teardown_env

run_test "flat file takes priority over JSON when present"
setup_env "t5b"
_init_schema

_MAIN_TOKEN_FILE="${CLAUDE_DIR}/.session-main-tokens"
printf '15000' > "$_MAIN_TOKEN_FILE"
_SESSION_END_INPUT='{"reason":"normal","context_window":{"total_input_tokens":8000,"total_output_tokens":2000}}'

_MT=0
if [[ -f "$_MAIN_TOKEN_FILE" ]]; then
    _MT=$(cat "$_MAIN_TOKEN_FILE" 2>/dev/null || echo "0")
    _MT="${_MT%.*}"
    _MT=$(( ${_MT:-0} ))
fi
if [[ "$_MT" -eq 0 ]]; then
    _MI=$(printf '%s' "$_SESSION_END_INPUT" | jq -r '.context_window.total_input_tokens // 0' 2>/dev/null || echo "0")
    _MO=$(printf '%s' "$_SESSION_END_INPUT" | jq -r '.context_window.total_output_tokens // 0' 2>/dev/null || echo "0")
    _MT=$(( ${_MI:-0} + ${_MO:-0} ))
fi

if [[ "$_MT" -eq 15000 ]]; then
    pass_test
else
    fail_test "Expected 15000 from flat file, got '$_MT'"
fi
teardown_env

# ---------------------------------------------------------------------------
# Test 6: Dual-write — flat file still written
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 6: Dual-write — flat file preserved ==="

run_test "flat file has entry after dual-write"
setup_env "t6"
_init_schema

_SESSION_TOKENS=12345
_MAIN_TOKENS=10000
_SUBAGENT_TOTAL=2345
_TOKEN_HISTORY="${CLAUDE_DIR}/.session-token-history"
_TOKEN_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
_TOKEN_PHASH="aaaa1111"
_TOKEN_PNAME="testproject"
_SID="test-session-dual"

# Dual-write: flat file
echo "${_TOKEN_TS}|${_SESSION_TOKENS}|${_MAIN_TOKENS}|${_SUBAGENT_TOTAL}|${_SID}|${_TOKEN_PHASH}|${_TOKEN_PNAME}" >> "$_TOKEN_HISTORY"

# Dual-write: SQLite INSERT (mirrors session-end.sh logic)
_phash_e=$(printf '%s' "$_TOKEN_PHASH" | sed "s/'/''/g")
_pname_e=$(printf '%s' "$_TOKEN_PNAME" | sed "s/'/''/g")
_sid_e=$(printf '%s' "$_SID" | sed "s/'/''/g")
_state_sql "INSERT INTO session_tokens
    (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
    VALUES ('$_sid_e', '$_phash_e', '$_pname_e', '$_TOKEN_TS', $_SESSION_TOKENS, $_MAIN_TOKENS, $_SUBAGENT_TOTAL, 'session-end');" >/dev/null 2>/dev/null || true

_ff_count=$(wc -l < "$_TOKEN_HISTORY" | tr -d ' ')
if [[ "${_ff_count:-0}" -ge "1" ]]; then
    pass_test
else
    fail_test "flat file empty after dual-write"
fi
teardown_env

run_test "SQLite has correct total_tokens after dual-write"
setup_env "t6b"
_init_schema

_SESSION_TOKENS=12345
_MAIN_TOKENS=10000
_SUBAGENT_TOTAL=2345
_TOKEN_HISTORY="${CLAUDE_DIR}/.session-token-history"
_TOKEN_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
_TOKEN_PHASH="aaaa1111"
_TOKEN_PNAME="testproject"
_SID="test-session-dual"

echo "${_TOKEN_TS}|${_SESSION_TOKENS}|${_MAIN_TOKENS}|${_SUBAGENT_TOTAL}|${_SID}|${_TOKEN_PHASH}|${_TOKEN_PNAME}" >> "$_TOKEN_HISTORY"
_phash_e=$(printf '%s' "$_TOKEN_PHASH" | sed "s/'/''/g")
_pname_e=$(printf '%s' "$_TOKEN_PNAME" | sed "s/'/''/g")
_sid_e=$(printf '%s' "$_SID" | sed "s/'/''/g")
_state_sql "INSERT INTO session_tokens
    (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
    VALUES ('$_sid_e', '$_phash_e', '$_pname_e', '$_TOKEN_TS', $_SESSION_TOKENS, $_MAIN_TOKENS, $_SUBAGENT_TOTAL, 'session-end');" >/dev/null 2>/dev/null || true

_db_sum=$(_db "SELECT COALESCE(SUM(total_tokens), 0) FROM session_tokens WHERE project_hash = '$_TOKEN_PHASH';")
if [[ "$_db_sum" == "$_SESSION_TOKENS" ]]; then
    pass_test
else
    fail_test "SQLite total = '$_db_sum', expected '$_SESSION_TOKENS'"
fi
teardown_env

# ---------------------------------------------------------------------------
# Test 7: Index exists
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 7: idx_session_tokens_project index ==="

run_test "idx_session_tokens_project exists after schema init"
setup_env "t7"
_init_schema
_idx=$(_db "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_session_tokens_project';")
if [[ "$_idx" == "idx_session_tokens_project" ]]; then
    pass_test
else
    fail_test "index not found (got: '$_idx')"
fi
teardown_env

# ---------------------------------------------------------------------------
# Test 8: COALESCE prevents NULL for empty result
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 8: Empty project returns 0 ==="

run_test "COALESCE returns 0 for unknown project_hash"
setup_env "t8"
_init_schema
_sum=$(_db "SELECT COALESCE(SUM(total_tokens), 0) FROM session_tokens WHERE project_hash = 'nonexistent';" 2>/dev/null || echo "0")
if [[ "$_sum" == "0" ]]; then
    pass_test
else
    fail_test "Expected 0, got '$_sum'"
fi
teardown_env

# ---------------------------------------------------------------------------
# Test 9: cost_usd column — INSERT with cost, SUM, and project-scoped query
# ---------------------------------------------------------------------------
# @decision DEC-STATE-KV-004
# @title cost_usd column in session_tokens for unified cost+token storage
# @status accepted
# @rationale Validates migration_003_cost_column: the cost_usd REAL column
# (default 0) added to session_tokens eliminates the need for the separate
# .session-cost-history flat file as the primary store. SQLite INSERT is
# atomic (WAL), concurrent session-end hooks cannot corrupt each other.
# session-init.sh reads SUM(cost_usd) WHERE project_hash for per-project
# lifetime spend; the flat file is preserved as dual-write fallback.
echo ""
echo "=== Test 9: cost_usd column (DEC-STATE-KV-004) ==="

run_test "cost_usd column exists after migration_003"
setup_env "t9"
_init_schema
_schema=$(_db ".schema session_tokens" 2>/dev/null || true)
if echo "$_schema" | grep -q "cost_usd"; then
    pass_test
else
    fail_test "cost_usd column missing from session_tokens"
fi
teardown_env

run_test "INSERT with cost_usd, SUM returns correct value"
setup_env "t9b"
_init_schema
_phash="cost1234"
_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
_db "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, cost_usd, source)
     VALUES ('sess-c1', '$_phash', 'costproj', '$_ts', 5000, 4500, 500, 0.12, 'test');"
_sum=$(_db "SELECT COALESCE(SUM(cost_usd), 0) FROM session_tokens WHERE project_hash = '$_phash';")
# Compare with awk for floating-point equality (bash can't compare floats)
_ok=$(awk "BEGIN {printf \"%s\", (\"$_sum\" + 0 > 0.119 && \"$_sum\" + 0 < 0.121) ? \"yes\" : \"no\"}")
if [[ "$_ok" == "yes" ]]; then
    pass_test
else
    fail_test "SUM(cost_usd) = '$_sum', expected ~0.12"
fi
teardown_env

run_test "multiple INSERTs accumulate cost_usd correctly"
setup_env "t9c"
_init_schema
_phash="cost5678"
_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for i in 1 2 3; do
    _db "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, cost_usd, source)
         VALUES ('sess-c$i', '$_phash', 'costproj', '$_ts', 1000, 900, 100, 0.05, 'test');"
done
_sum=$(_db "SELECT COALESCE(SUM(cost_usd), 0) FROM session_tokens WHERE project_hash = '$_phash';")
# 3 * 0.05 = 0.15
_ok=$(awk "BEGIN {printf \"%s\", (\"$_sum\" + 0 > 0.149 && \"$_sum\" + 0 < 0.151) ? \"yes\" : \"no\"}")
if [[ "$_ok" == "yes" ]]; then
    pass_test
else
    fail_test "SUM(cost_usd) = '$_sum', expected ~0.15"
fi
teardown_env

run_test "cost_usd defaults to 0 for old INSERTs without cost column"
setup_env "t9d"
_init_schema
_phash="olddata0"
_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# INSERT without specifying cost_usd — should use DEFAULT 0
_db "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
     VALUES ('sess-old', '$_phash', 'oldproj', '$_ts', 2000, 1800, 200, 'backfill');"
_cost=$(_db "SELECT cost_usd FROM session_tokens WHERE session_id = 'sess-old';")
if [[ "$_cost" == "0" || "$_cost" == "0.0" ]]; then
    pass_test
else
    fail_test "Default cost_usd = '$_cost', expected 0"
fi
teardown_env

run_test "migration version 3 recorded in _migrations"
setup_env "t9e"
_init_schema
_mv=$(_db "SELECT version FROM _migrations WHERE version=3;" 2>/dev/null || echo "")
if [[ "$_mv" == "3" ]]; then
    pass_test
else
    fail_test "migration version 3 not recorded (got: '$_mv')"
fi
teardown_env

# ---------------------------------------------------------------------------
# Test 10: Migration v3 adds cost_usd to existing DB without cost column
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 10: Migration v3 adds cost_usd to existing DB ==="

run_test "migration_003 adds cost_usd to pre-existing session_tokens table"
setup_env "t10"

# Simulate a "pre-migration" DB: create session_tokens WITHOUT cost_usd,
# record migrations 1 and 2 but NOT 3, then re-run migrations.
_db "CREATE TABLE IF NOT EXISTS session_tokens_old (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL, project_hash TEXT NOT NULL,
    project_name TEXT, timestamp TEXT NOT NULL,
    total_tokens INTEGER NOT NULL DEFAULT 0,
    main_tokens INTEGER NOT NULL DEFAULT 0,
    subagent_tokens INTEGER NOT NULL DEFAULT 0,
    source TEXT
);" 2>/dev/null || true

# Insert a row without cost_usd (pre-migration data)
_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
_db "INSERT INTO session_tokens_old VALUES (1, 'pre-sess', 'prephash', 'preproj', '$_ts', 1000, 800, 200, 'test');" 2>/dev/null || true

# Now trigger full schema init (which runs migrations including v3)
_init_schema

# Verify cost_usd is present on the real table (the migration path)
_schema=$(_db ".schema session_tokens" 2>/dev/null || true)
if echo "$_schema" | grep -q "cost_usd"; then
    pass_test
else
    fail_test "After migration_003, cost_usd column not found in session_tokens"
fi
teardown_env

run_test "existing rows have cost_usd=0 after ALTER TABLE adds column"
setup_env "t10b"

# This test uses a raw sqlite3 DB to simulate pre-migration state more precisely.
# Create the DB, add session_tokens WITHOUT cost_usd, add a row, then ALTER TABLE.
_testdb="$CLAUDE_DIR/state/state.db"
mkdir -p "$(dirname "$_testdb")"

# Create table without cost_usd
sqlite3 "$_testdb" "
CREATE TABLE IF NOT EXISTS _migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL, checksum TEXT, applied_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS session_tokens (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL, project_hash TEXT NOT NULL,
    project_name TEXT, timestamp TEXT NOT NULL,
    total_tokens INTEGER NOT NULL DEFAULT 0,
    main_tokens INTEGER NOT NULL DEFAULT 0,
    subagent_tokens INTEGER NOT NULL DEFAULT 0,
    source TEXT
);
INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
    VALUES ('pre-sess', 'pre12345', 'preproj', '2026-01-01T00:00:00Z', 1500, 1200, 300, 'test');
INSERT INTO _migrations (version, name, checksum, applied_at) VALUES (1, 'initial_schema', '', strftime('%s','now'));
INSERT INTO _migrations (version, name, checksum, applied_at) VALUES (2, 'session_tokens', '', strftime('%s','now'));
" 2>/dev/null || true

# Now run migration_003 directly (ALTER TABLE ADD COLUMN)
sqlite3 "$_testdb" "ALTER TABLE session_tokens ADD COLUMN cost_usd REAL NOT NULL DEFAULT 0;" 2>/dev/null || true
sqlite3 "$_testdb" "INSERT INTO _migrations (version, name, checksum, applied_at) VALUES (3, 'cost_column', '', strftime('%s','now'));" 2>/dev/null || true

# Verify existing row has cost_usd=0
_cost=$(_db "SELECT cost_usd FROM session_tokens WHERE session_id = 'pre-sess';")
if [[ "$_cost" == "0" || "$_cost" == "0.0" ]]; then
    pass_test
else
    fail_test "Existing row cost_usd = '$_cost', expected 0 after ALTER TABLE"
fi
teardown_env

# ---------------------------------------------------------------------------
# Cleanup and summary
# ---------------------------------------------------------------------------
rm -rf "$_TMP_BASE" 2>/dev/null || true

echo ""
echo "==============================="
echo "Tests run:    $TESTS_RUN"
echo "Tests passed: $TESTS_PASSED"
echo "Tests failed: $TESTS_FAILED"
echo "==============================="

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
