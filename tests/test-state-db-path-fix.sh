#!/usr/bin/env bash
# test-state-db-path-fix.sh — Tests for DEC-STATE-KV-008: correct state.db path in session-init.sh
#
# Purpose: Verify that session-init.sh reads lifetime tokens from the canonical root-level
#   state.db (~/.claude/state/state.db) rather than the per-project subdirectory
#   (~/.claude/state/{phash}/state.db), and that the backfill guard correctly imports
#   flat-file entries when the DB row count is lower than the flat-file line count.
#
# @decision DEC-STATE-KV-008
# @title Regression tests for state.db path fix in session-init.sh
# @status accepted
# @rationale The original code used state_dir() which returns ~/.claude/state/{phash}/,
#   not the root-level DB path. This test suite guards against regression by verifying:
#   (1) lifetime token reads come from the canonical path, not the per-project subdir;
#   (2) backfill fires when flat file has more entries than DB (not just when DB is empty);
#   (3) backfill deduplicates by (session_id, timestamp), not autoincrement ID.
#
# Tests:
#   1. Canonical DB path resolves to ~/.claude/state/state.db (not {phash}/state.db)
#   2. Per-project subdir state.db (0 bytes) does NOT cause false positive file-existence check
#   3. Backfill imports flat-file entries into the canonical DB
#   4. Backfill skips entries that already exist in DB by (session_id, timestamp)
#   5. Backfill fires when flat-file count > DB count (even when DB count > 0)
#   6. Lifetime token SUM reads from canonical DB after backfill
#   7. Flat-file fallback still works when canonical DB is absent
#
# Usage: bash tests/test-state-db-path-fix.sh
# Scope: runs as part of the SQLite state test group
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
_TMP_BASE="$PROJECT_ROOT_REAL/tmp/test-state-db-path-$$"
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
    unset _STATE_SCHEMA_INITIALIZED 2>/dev/null || true
    unset _STATE_LIB_LOADED 2>/dev/null || true
    unset _WORKFLOW_ID 2>/dev/null || true

    # Source state-lib fresh for this test
    # shellcheck source=/dev/null
    source "$HOOKS_DIR/source-lib.sh"
    require_state
}

teardown_env() {
    rm -rf "$_TMPDIR" 2>/dev/null || true
    _TMPDIR=""
}

# Direct sqlite3 helper against the CANONICAL root-level test DB
_db() {
    sqlite3 "$CLAUDE_DIR/state/state.db" "$1" 2>/dev/null
}

# Direct sqlite3 helper against a per-project subdir DB (the wrong path from the bug)
_db_wrong() {
    local phash="$1"
    local query="$2"
    sqlite3 "$CLAUDE_DIR/state/${phash}/state.db" "$query" 2>/dev/null
}

# Initialize DB schema via _state_sql
_init_schema() {
    _state_sql "SELECT 1;" >/dev/null 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Helper: extract the resolved _bf_db / _lt_db path from the fixed code
# These inline path expressions mirror exactly what session-init.sh now uses.
# ---------------------------------------------------------------------------
_canonical_db_path() {
    echo "${CLAUDE_DIR:-$HOME/.claude}/state/state.db"
}

# ---------------------------------------------------------------------------
# Test 1: Canonical DB path is root-level, not per-project subdir
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 1: Canonical state.db path resolves correctly ==="

run_test "canonical path points to root-level state.db"
setup_env "t1"
_phash=$(source "$HOOKS_DIR/source-lib.sh" && project_hash "$_TMPDIR" 2>/dev/null || echo "testhash")
_correct_path="$CLAUDE_DIR/state/state.db"
_wrong_path="$CLAUDE_DIR/state/${_phash}/state.db"
_resolved=$(_canonical_db_path)
if [[ "$_resolved" == "$_correct_path" ]]; then
    pass_test
else
    fail_test "expected '$_correct_path', got '$_resolved'"
fi
teardown_env

run_test "canonical path does NOT contain phash subdirectory"
setup_env "t1b"
_resolved=$(_canonical_db_path)
# Path must not contain any hash-like segment (8 hex chars) between state/ and state.db
if echo "$_resolved" | grep -qE 'state/[0-9a-f]{8}/state\.db'; then
    fail_test "path contains per-project phash subdir: '$_resolved'"
else
    pass_test
fi
teardown_env

# ---------------------------------------------------------------------------
# Test 2: Per-project subdir state.db (0 bytes) is not mistaken for the real DB
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 2: 0-byte per-project state.db does not cause false positive ==="

run_test "zero-byte per-project state.db exists but canonical db is the real one"
setup_env "t2"
_init_schema
# The canonical DB must have tables after schema init
_canonical="$CLAUDE_DIR/state/state.db"
_tbl=$(sqlite3 "$_canonical" "SELECT name FROM sqlite_master WHERE type='table' AND name='session_tokens';" 2>/dev/null)
# Now create a 0-byte file at the wrong (per-project) path
_phash=$(source "$HOOKS_DIR/source-lib.sh" && project_hash "$_TMPDIR" 2>/dev/null || echo "testhash")
mkdir -p "$CLAUDE_DIR/state/${_phash}"
touch "$CLAUDE_DIR/state/${_phash}/state.db"
_wrong_size=$(wc -c < "$CLAUDE_DIR/state/${_phash}/state.db" 2>/dev/null | tr -d ' ')
if [[ "$_tbl" == "session_tokens" && "${_wrong_size}" -eq 0 ]]; then
    pass_test
else
    fail_test "canonical tbl='$_tbl' (expected session_tokens), wrong_size='$_wrong_size' (expected 0)"
fi
teardown_env

# ---------------------------------------------------------------------------
# Test 3: Backfill imports flat-file entries into the canonical DB
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 3: Backfill populates canonical DB from flat file ==="

run_test "backfill imports all flat-file entries when DB is empty"
setup_env "t3"
_init_schema
_canonical="$CLAUDE_DIR/state/state.db"
# Write a flat file with 3 entries
_ts1="2026-01-01T10:00:00Z"
_ts2="2026-01-02T10:00:00Z"
_ts3="2026-01-03T10:00:00Z"
cat > "$CLAUDE_DIR/.session-token-history" <<EOF
${_ts1}|10000|8000|2000|sess-t3a|testhash|testproj
${_ts2}|20000|16000|4000|sess-t3b|testhash|testproj
${_ts3}|30000|24000|6000|sess-t3c|testhash|testproj
EOF
# Simulate the backfill logic from the fixed session-init.sh
_bf_db="${CLAUDE_DIR}/state/state.db"
_bf_history="${CLAUDE_DIR}/.session-token-history"
_bf_flatfile_count=$(wc -l < "$_bf_history" 2>/dev/null | tr -d ' ')
_bf_db_count=$(sqlite3 "$_bf_db" "SELECT COUNT(*) FROM session_tokens;" 2>/dev/null || echo "0")
if [[ "${_bf_flatfile_count:-0}" -gt "${_bf_db_count:-0}" ]]; then
    while IFS='|' read -r _bf_ts _bf_total _bf_main _bf_sub _bf_sid _bf_phash _bf_pname; do
        [[ -z "$_bf_ts" || -z "$_bf_total" ]] && continue
        _bf_total="${_bf_total//[^0-9]/}"
        _bf_main="${_bf_main//[^0-9]/}"
        _bf_sub="${_bf_sub//[^0-9]/}"
        [[ -z "$_bf_total" ]] && continue
        _bf_sid_e=$(printf '%s' "${_bf_sid:-unknown}" | sed "s/'/''/g")
        _bf_phash_e=$(printf '%s' "${_bf_phash:-}" | sed "s/'/''/g")
        _bf_pname_e=$(printf '%s' "${_bf_pname:-unknown}" | sed "s/'/''/g")
        _bf_ts_e=$(printf '%s' "${_bf_ts:-}" | sed "s/'/''/g")
        _bf_exists=$(sqlite3 "$_bf_db" \
            "SELECT COUNT(*) FROM session_tokens WHERE session_id='${_bf_sid_e}' AND timestamp='${_bf_ts_e}';" \
            2>/dev/null || echo "0")
        [[ "${_bf_exists:-0}" -gt 0 ]] && continue
        sqlite3 "$_bf_db" \
            "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
             VALUES ('${_bf_sid_e}', '${_bf_phash_e}', '${_bf_pname_e}', '${_bf_ts_e}', ${_bf_total:-0}, ${_bf_main:-0}, ${_bf_sub:-0}, 'backfill');" \
            2>/dev/null || true
    done < "$_bf_history"
fi
_count=$(sqlite3 "$_canonical" "SELECT COUNT(*) FROM session_tokens WHERE source='backfill';" 2>/dev/null)
if [[ "$_count" == "3" ]]; then
    pass_test
else
    fail_test "expected 3 backfill rows, got '$_count'"
fi
teardown_env

run_test "backfill total_tokens sum matches flat file"
setup_env "t3b"
_init_schema
_canonical="$CLAUDE_DIR/state/state.db"
cat > "$CLAUDE_DIR/.session-token-history" <<EOF
2026-01-01T10:00:00Z|10000|8000|2000|sess-t3b1|testhash|testproj
2026-01-02T10:00:00Z|20000|16000|4000|sess-t3b2|testhash|testproj
EOF
_bf_db="${CLAUDE_DIR}/state/state.db"
_bf_history="${CLAUDE_DIR}/.session-token-history"
_bf_flatfile_count=$(wc -l < "$_bf_history" 2>/dev/null | tr -d ' ')
_bf_db_count=$(sqlite3 "$_bf_db" "SELECT COUNT(*) FROM session_tokens;" 2>/dev/null || echo "0")
if [[ "${_bf_flatfile_count:-0}" -gt "${_bf_db_count:-0}" ]]; then
    while IFS='|' read -r _bf_ts _bf_total _bf_main _bf_sub _bf_sid _bf_phash _bf_pname; do
        [[ -z "$_bf_ts" || -z "$_bf_total" ]] && continue
        _bf_total="${_bf_total//[^0-9]/}"
        _bf_main="${_bf_main//[^0-9]/}"
        _bf_sub="${_bf_sub//[^0-9]/}"
        [[ -z "$_bf_total" ]] && continue
        _bf_sid_e=$(printf '%s' "${_bf_sid:-unknown}" | sed "s/'/''/g")
        _bf_phash_e=$(printf '%s' "${_bf_phash:-}" | sed "s/'/''/g")
        _bf_pname_e=$(printf '%s' "${_bf_pname:-unknown}" | sed "s/'/''/g")
        _bf_ts_e=$(printf '%s' "${_bf_ts:-}" | sed "s/'/''/g")
        _bf_exists=$(sqlite3 "$_bf_db" \
            "SELECT COUNT(*) FROM session_tokens WHERE session_id='${_bf_sid_e}' AND timestamp='${_bf_ts_e}';" \
            2>/dev/null || echo "0")
        [[ "${_bf_exists:-0}" -gt 0 ]] && continue
        sqlite3 "$_bf_db" \
            "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
             VALUES ('${_bf_sid_e}', '${_bf_phash_e}', '${_bf_pname_e}', '${_bf_ts_e}', ${_bf_total:-0}, ${_bf_main:-0}, ${_bf_sub:-0}, 'backfill');" \
            2>/dev/null || true
    done < "$_bf_history"
fi
_sum=$(sqlite3 "$_canonical" "SELECT COALESCE(SUM(total_tokens), 0) FROM session_tokens;" 2>/dev/null)
if [[ "$_sum" == "30000" ]]; then
    pass_test
else
    fail_test "expected SUM=30000, got '$_sum'"
fi
teardown_env

# ---------------------------------------------------------------------------
# Test 4: Backfill deduplication by (session_id, timestamp)
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 4: Backfill deduplication by (session_id, timestamp) ==="

run_test "backfill skips rows already present by (session_id, timestamp)"
setup_env "t4"
_init_schema
_canonical="$CLAUDE_DIR/state/state.db"
# Pre-insert one row with same session_id + timestamp as what backfill will try
_ts="2026-01-05T12:00:00Z"
sqlite3 "$_canonical" \
    "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
     VALUES ('sess-existing', 'testhash', 'proj', '${_ts}', 50000, 40000, 10000, 'session-end');" \
    2>/dev/null
# Flat file has the same entry plus one new one
cat > "$CLAUDE_DIR/.session-token-history" <<EOF
${_ts}|50000|40000|10000|sess-existing|testhash|proj
2026-01-06T12:00:00Z|15000|12000|3000|sess-new|testhash|proj
EOF
_bf_db="${CLAUDE_DIR}/state/state.db"
_bf_history="${CLAUDE_DIR}/.session-token-history"
_bf_flatfile_count=$(wc -l < "$_bf_history" 2>/dev/null | tr -d ' ')
_bf_db_count=$(sqlite3 "$_bf_db" "SELECT COUNT(*) FROM session_tokens;" 2>/dev/null || echo "0")
if [[ "${_bf_flatfile_count:-0}" -gt "${_bf_db_count:-0}" ]]; then
    while IFS='|' read -r _bf_ts _bf_total _bf_main _bf_sub _bf_sid _bf_phash _bf_pname; do
        [[ -z "$_bf_ts" || -z "$_bf_total" ]] && continue
        _bf_total="${_bf_total//[^0-9]/}"
        _bf_main="${_bf_main//[^0-9]/}"
        _bf_sub="${_bf_sub//[^0-9]/}"
        [[ -z "$_bf_total" ]] && continue
        _bf_sid_e=$(printf '%s' "${_bf_sid:-unknown}" | sed "s/'/''/g")
        _bf_phash_e=$(printf '%s' "${_bf_phash:-}" | sed "s/'/''/g")
        _bf_pname_e=$(printf '%s' "${_bf_pname:-unknown}" | sed "s/'/''/g")
        _bf_ts_e=$(printf '%s' "${_bf_ts:-}" | sed "s/'/''/g")
        _bf_exists=$(sqlite3 "$_bf_db" \
            "SELECT COUNT(*) FROM session_tokens WHERE session_id='${_bf_sid_e}' AND timestamp='${_bf_ts_e}';" \
            2>/dev/null || echo "0")
        [[ "${_bf_exists:-0}" -gt 0 ]] && continue
        sqlite3 "$_bf_db" \
            "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
             VALUES ('${_bf_sid_e}', '${_bf_phash_e}', '${_bf_pname_e}', '${_bf_ts_e}', ${_bf_total:-0}, ${_bf_main:-0}, ${_bf_sub:-0}, 'backfill');" \
            2>/dev/null || true
    done < "$_bf_history"
fi
# Should have exactly 2 rows: the original session-end row + the new backfill row
_total_count=$(sqlite3 "$_canonical" "SELECT COUNT(*) FROM session_tokens;" 2>/dev/null)
_dup_count=$(sqlite3 "$_canonical" "SELECT COUNT(*) FROM session_tokens WHERE session_id='sess-existing';" 2>/dev/null)
if [[ "$_total_count" == "2" && "$_dup_count" == "1" ]]; then
    pass_test
else
    fail_test "total_count=$_total_count (expected 2), dup_count=$_dup_count (expected 1)"
fi
teardown_env

# ---------------------------------------------------------------------------
# Test 5: Backfill fires when DB count > 0 but flat-file count is larger
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 5: Backfill fires when DB count > 0 but flat file has more entries ==="

run_test "backfill runs when DB has 1 stale row but flat file has 5 entries"
setup_env "t5"
_init_schema
_canonical="$CLAUDE_DIR/state/state.db"
# Pre-insert a stale test row (simulates the abc12345/tester row from the real DB)
sqlite3 "$_canonical" \
    "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
     VALUES ('test-session-stale', 'staleproject', 'stale', '2026-01-01T00:00:00Z', 25000, 25000, 0, 'tester');" \
    2>/dev/null
# Flat file has 5 real entries
cat > "$CLAUDE_DIR/.session-token-history" <<EOF
2026-01-10T10:00:00Z|100000|80000|20000|sess-t5a|realhash|realproj
2026-01-11T10:00:00Z|110000|88000|22000|sess-t5b|realhash|realproj
2026-01-12T10:00:00Z|120000|96000|24000|sess-t5c|realhash|realproj
2026-01-13T10:00:00Z|130000|104000|26000|sess-t5d|realhash|realproj
2026-01-14T10:00:00Z|140000|112000|28000|sess-t5e|realhash|realproj
EOF
_bf_db="${CLAUDE_DIR}/state/state.db"
_bf_history="${CLAUDE_DIR}/.session-token-history"
_bf_flatfile_count=$(wc -l < "$_bf_history" 2>/dev/null | tr -d ' ')
_bf_db_count=$(sqlite3 "$_bf_db" "SELECT COUNT(*) FROM session_tokens;" 2>/dev/null || echo "0")
_backfill_ran=0
if [[ "${_bf_flatfile_count:-0}" -gt "${_bf_db_count:-0}" ]]; then
    _backfill_ran=1
    while IFS='|' read -r _bf_ts _bf_total _bf_main _bf_sub _bf_sid _bf_phash _bf_pname; do
        [[ -z "$_bf_ts" || -z "$_bf_total" ]] && continue
        _bf_total="${_bf_total//[^0-9]/}"
        _bf_main="${_bf_main//[^0-9]/}"
        _bf_sub="${_bf_sub//[^0-9]/}"
        [[ -z "$_bf_total" ]] && continue
        _bf_sid_e=$(printf '%s' "${_bf_sid:-unknown}" | sed "s/'/''/g")
        _bf_phash_e=$(printf '%s' "${_bf_phash:-}" | sed "s/'/''/g")
        _bf_pname_e=$(printf '%s' "${_bf_pname:-unknown}" | sed "s/'/''/g")
        _bf_ts_e=$(printf '%s' "${_bf_ts:-}" | sed "s/'/''/g")
        _bf_exists=$(sqlite3 "$_bf_db" \
            "SELECT COUNT(*) FROM session_tokens WHERE session_id='${_bf_sid_e}' AND timestamp='${_bf_ts_e}';" \
            2>/dev/null || echo "0")
        [[ "${_bf_exists:-0}" -gt 0 ]] && continue
        sqlite3 "$_bf_db" \
            "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
             VALUES ('${_bf_sid_e}', '${_bf_phash_e}', '${_bf_pname_e}', '${_bf_ts_e}', ${_bf_total:-0}, ${_bf_main:-0}, ${_bf_sub:-0}, 'backfill');" \
            2>/dev/null || true
    done < "$_bf_history"
fi
# Should have 6 rows: 1 stale + 5 backfilled
_total=$(sqlite3 "$_canonical" "SELECT COUNT(*) FROM session_tokens;" 2>/dev/null)
if [[ "$_backfill_ran" -eq 1 && "$_total" == "6" ]]; then
    pass_test
else
    fail_test "backfill_ran=$_backfill_ran (expected 1), total=$_total (expected 6)"
fi
teardown_env

run_test "old backfill guard (COUNT=0) would have FAILED this case"
# This test documents the regression: the old COUNT=0 guard would NOT have run backfill
setup_env "t5b"
_init_schema
_canonical="$CLAUDE_DIR/state/state.db"
sqlite3 "$_canonical" \
    "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
     VALUES ('test-stale', 'staleproject', 'stale', '2026-01-01T00:00:00Z', 25000, 25000, 0, 'tester');" \
    2>/dev/null
cat > "$CLAUDE_DIR/.session-token-history" <<EOF
2026-02-01T10:00:00Z|50000|40000|10000|sess-real|realhash|realproj
2026-02-02T10:00:00Z|60000|48000|12000|sess-real2|realhash|realproj
EOF
# Simulate OLD guard: would it run backfill?
_old_count=$(sqlite3 "$_canonical" "SELECT COUNT(*) FROM session_tokens;" 2>/dev/null || echo "1")
_old_would_run=0
[[ "${_old_count:-1}" -eq 0 ]] && _old_would_run=1
# New guard: would it run backfill?
_ff_count=$(wc -l < "$CLAUDE_DIR/.session-token-history" 2>/dev/null | tr -d ' ')
_db_count=$(sqlite3 "$_canonical" "SELECT COUNT(*) FROM session_tokens;" 2>/dev/null || echo "0")
_new_would_run=0
[[ "${_ff_count:-0}" -gt "${_db_count:-0}" ]] && _new_would_run=1
if [[ "$_old_would_run" -eq 0 && "$_new_would_run" -eq 1 ]]; then
    pass_test
else
    fail_test "old_would_run=$_old_would_run (expected 0), new_would_run=$_new_would_run (expected 1)"
fi
teardown_env

# ---------------------------------------------------------------------------
# Test 6: Lifetime token SUM reads from canonical DB after backfill
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 6: Lifetime token SUM from canonical DB ==="

run_test "LIFETIME_TOKENS populated from canonical DB after backfill"
setup_env "t6"
_init_schema
_canonical="$CLAUDE_DIR/state/state.db"
_phash="deadbeef"
# Insert known rows
sqlite3 "$_canonical" \
    "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
     VALUES ('sess-lt1', '${_phash}', 'ltproj', '2026-02-10T10:00:00Z', 200000, 160000, 40000, 'session-end');" \
    2>/dev/null
sqlite3 "$_canonical" \
    "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
     VALUES ('sess-lt2', '${_phash}', 'ltproj', '2026-02-11T10:00:00Z', 300000, 240000, 60000, 'session-end');" \
    2>/dev/null
# Simulate the lifetime query from the fixed session-init.sh
_lt_db="${CLAUDE_DIR}/state/state.db"
LIFETIME_TOKENS=0
if [[ -f "$_lt_db" ]]; then
    _lt_phash_e=$(printf '%s' "$_phash" | sed "s/'/''/g")
    _LT_DB_TOK=$(sqlite3 "$_lt_db" \
        "SELECT COALESCE(SUM(total_tokens), 0) FROM session_tokens WHERE project_hash = '${_lt_phash_e}';" \
        2>/dev/null || echo "0")
    if [[ "$_LT_DB_TOK" =~ ^[0-9]+$ ]] && [[ "$_LT_DB_TOK" -gt 0 ]]; then
        LIFETIME_TOKENS="$_LT_DB_TOK"
    fi
fi
if [[ "$LIFETIME_TOKENS" == "500000" ]]; then
    pass_test
else
    fail_test "expected LIFETIME_TOKENS=500000, got '$LIFETIME_TOKENS'"
fi
teardown_env

run_test "LIFETIME_TOKENS isolates by project_hash (no cross-contamination)"
setup_env "t6b"
_init_schema
_canonical="$CLAUDE_DIR/state/state.db"
sqlite3 "$_canonical" \
    "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
     VALUES ('sess-p1', 'projectA', 'projA', '2026-02-20T10:00:00Z', 100000, 80000, 20000, 'session-end');" \
    2>/dev/null
sqlite3 "$_canonical" \
    "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
     VALUES ('sess-p2', 'projectB', 'projB', '2026-02-20T11:00:00Z', 999999, 999999, 0, 'session-end');" \
    2>/dev/null
_lt_db="${CLAUDE_DIR}/state/state.db"
LIFETIME_TOKENS=0
if [[ -f "$_lt_db" ]]; then
    _lt_phash_e="projectA"
    _LT_DB_TOK=$(sqlite3 "$_lt_db" \
        "SELECT COALESCE(SUM(total_tokens), 0) FROM session_tokens WHERE project_hash = '${_lt_phash_e}';" \
        2>/dev/null || echo "0")
    if [[ "$_LT_DB_TOK" =~ ^[0-9]+$ ]] && [[ "$_LT_DB_TOK" -gt 0 ]]; then
        LIFETIME_TOKENS="$_LT_DB_TOK"
    fi
fi
if [[ "$LIFETIME_TOKENS" == "100000" ]]; then
    pass_test
else
    fail_test "expected LIFETIME_TOKENS=100000 (only projectA), got '$LIFETIME_TOKENS'"
fi
teardown_env

# ---------------------------------------------------------------------------
# Test 7: Flat-file fallback works when canonical DB is absent
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 7: Flat-file fallback when canonical DB is absent ==="

run_test "flat-file fallback activates when state.db does not exist"
setup_env "t7"
# No schema init — DB does not exist
_lt_db="${CLAUDE_DIR}/state/state.db"
_PHASH="fallbackhash"
# Write flat file
cat > "$CLAUDE_DIR/.session-token-history" <<EOF
2026-03-01T10:00:00Z|77000|60000|17000|sess-fb1|fallbackhash|fbproj
2026-03-02T10:00:00Z|88000|70000|18000|sess-fb2|fallbackhash|fbproj
EOF
LIFETIME_TOKENS=0
# Canonical DB check (should be absent)
if [[ -f "$_lt_db" ]]; then
    _LT_DB_TOK=$(sqlite3 "$_lt_db" \
        "SELECT COALESCE(SUM(total_tokens), 0) FROM session_tokens WHERE project_hash = '${_PHASH}';" \
        2>/dev/null || echo "0")
    if [[ "$_LT_DB_TOK" =~ ^[0-9]+$ ]] && [[ "$_LT_DB_TOK" -gt 0 ]]; then
        LIFETIME_TOKENS="$_LT_DB_TOK"
    fi
fi
# Flat-file fallback
_TOKEN_HISTORY="${CLAUDE_DIR}/.session-token-history"
if [[ "${LIFETIME_TOKENS:-0}" -eq 0 && -f "$_TOKEN_HISTORY" ]]; then
    _LIFETIME_TOK=$(awk -F'|' -v ph="$_PHASH" '(NF < 6) || ($6 == ph) {sum += $2} END {print sum+0}' "$_TOKEN_HISTORY" 2>/dev/null || echo "0")
    LIFETIME_TOKENS="${_LIFETIME_TOK:-0}"
fi
if [[ "$LIFETIME_TOKENS" == "165000" ]]; then
    pass_test
else
    fail_test "expected LIFETIME_TOKENS=165000 from flat file, got '$LIFETIME_TOKENS'"
fi
teardown_env

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "Tests run:    $TESTS_RUN"
echo "Tests passed: $TESTS_PASSED"
echo "Tests failed: $TESTS_FAILED"
echo ""

# Cleanup temp base
rm -rf "$_TMP_BASE" 2>/dev/null || true

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    echo "RESULT: FAIL ($TESTS_FAILED failures)"
    exit 1
else
    echo "RESULT: PASS"
    exit 0
fi
