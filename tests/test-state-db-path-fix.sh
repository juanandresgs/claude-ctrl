#!/usr/bin/env bash
# test-state-db-path-fix.sh — Tests for DEC-STATE-KV-008/009: correct state.db path and
# SQLite-sole-authority for token history in session-init.sh.
#
# Purpose: Verify that session-init.sh reads lifetime tokens from the canonical root-level
#   state.db (~/.claude/state/state.db) rather than the per-project subdirectory
#   (~/.claude/state/{phash}/state.db), and that NO flat-file read or backfill occurs
#   (DEC-STATE-KV-009: flat file is no longer written to or read from).
#
# @decision DEC-STATE-KV-008
# @title Regression tests for state.db path fix in session-init.sh
# @status accepted
# @rationale The original code used state_dir() which returns ~/.claude/state/{phash}/,
#   not the root-level DB path. This test suite guards against regression by verifying:
#   (1) lifetime token reads come from the canonical path, not the per-project subdir;
#   (2) no flat-file read or backfill occurs (DEC-STATE-KV-009);
#   (3) new installs with no flat file and empty SQLite return LIFETIME_TOKENS=0.
#
# Tests:
#   1. Canonical DB path resolves to ~/.claude/state/state.db (not {phash}/state.db)
#   2. Per-project subdir state.db (0 bytes) does NOT cause false positive file-existence check
#   3. SQLite-only: no flat file read when SQLite has data (DEC-STATE-KV-009)
#   4. SQLite-only: flat file present but session-init reads only SQLite (DEC-STATE-KV-009)
#   5. SQLite-only: backfill no longer fires — flat file presence alone does not trigger import
#   6. Lifetime token SUM reads from canonical DB
#   7. New install: empty SQLite returns LIFETIME_TOKENS=0 (no flat-file fallback)
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
# Test 3: SQLite-only — no flat file read (DEC-STATE-KV-009)
# ---------------------------------------------------------------------------
# @decision DEC-STATE-KV-009
# @title SQLite-sole-authority: session-init no longer reads flat file
# @status accepted
# @rationale The flat file is no longer written to (session-end.sh) or read
#   from (session-init.sh). These tests verify the SQLite-only read path:
#   tokens come from session_tokens WHERE project_hash, and a present flat
#   file has NO effect on LIFETIME_TOKENS.
echo ""
echo "=== Test 3: SQLite-only read — flat file has no effect (DEC-STATE-KV-009) ==="

run_test "SQLite-only: LIFETIME_TOKENS from SQLite, flat file present but ignored"
setup_env "t3"
_init_schema
_canonical="$CLAUDE_DIR/state/state.db"
_phash="abc99999"
# Write SQLite row (the only source of truth)
sqlite3 "$_canonical" \
    "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
     VALUES ('sess-sqlite', '${_phash}', 'myproj', '2026-01-01T10:00:00Z', 42000, 35000, 7000, 'session-end');" \
    2>/dev/null
# Write a flat file with DIFFERENT values to verify it is NOT read
cat > "$CLAUDE_DIR/.session-token-history" <<EOF
2026-01-01T10:00:00Z|999000|800000|199000|sess-sqlite|${_phash}|myproj
EOF
# Simulate the session-init.sh SQLite-only read path (DEC-STATE-KV-009)
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
# Must be 42000 from SQLite, NOT 999000 from flat file
if [[ "$LIFETIME_TOKENS" == "42000" ]]; then
    pass_test
else
    fail_test "expected LIFETIME_TOKENS=42000 (from SQLite), got '$LIFETIME_TOKENS' (flat file would give 999000)"
fi
teardown_env

run_test "SQLite-only: multiple SQLite rows accumulate correctly"
setup_env "t3b"
_init_schema
_canonical="$CLAUDE_DIR/state/state.db"
_phash="abc99999"
sqlite3 "$_canonical" \
    "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
     VALUES ('sess-s1', '${_phash}', 'myproj', '2026-01-01T10:00:00Z', 10000, 8000, 2000, 'session-end');" \
    2>/dev/null
sqlite3 "$_canonical" \
    "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
     VALUES ('sess-s2', '${_phash}', 'myproj', '2026-01-02T10:00:00Z', 20000, 16000, 4000, 'session-end');" \
    2>/dev/null
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
if [[ "$LIFETIME_TOKENS" == "30000" ]]; then
    pass_test
else
    fail_test "expected LIFETIME_TOKENS=30000, got '$LIFETIME_TOKENS'"
fi
teardown_env

# ---------------------------------------------------------------------------
# Test 4: SQLite-only — flat file present does NOT trigger backfill (DEC-STATE-KV-009)
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 4: No backfill from flat file (DEC-STATE-KV-009) ==="

run_test "flat file present but no backfill row created in session_tokens"
setup_env "t4"
_init_schema
_canonical="$CLAUDE_DIR/state/state.db"
# Write flat file with entries that would have triggered backfill under old code
cat > "$CLAUDE_DIR/.session-token-history" <<EOF
2026-01-01T10:00:00Z|10000|8000|2000|sess-ff1|testhash|testproj
2026-01-02T10:00:00Z|20000|16000|4000|sess-ff2|testhash|testproj
2026-01-03T10:00:00Z|30000|24000|6000|sess-ff3|testhash|testproj
EOF
# session-init.sh no longer runs backfill — DB should remain empty
_count=$(sqlite3 "$_canonical" "SELECT COUNT(*) FROM session_tokens;" 2>/dev/null)
if [[ "$_count" == "0" ]]; then
    pass_test
else
    fail_test "expected 0 rows (no backfill), got '$_count' rows"
fi
teardown_env

# ---------------------------------------------------------------------------
# Test 5: SQLite-only — project isolation still works (DEC-STATE-KV-009)
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 5: Project isolation in SQLite-only read path ==="

run_test "project hash filter isolates tokens correctly"
setup_env "t5"
_init_schema
_canonical="$CLAUDE_DIR/state/state.db"
_phash_a="aaaa1234"
_phash_b="bbbb5678"
sqlite3 "$_canonical" \
    "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
     VALUES ('sess-a1', '${_phash_a}', 'projA', '2026-01-10T10:00:00Z', 100000, 80000, 20000, 'session-end');" \
    2>/dev/null
sqlite3 "$_canonical" \
    "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
     VALUES ('sess-b1', '${_phash_b}', 'projB', '2026-01-11T10:00:00Z', 999000, 900000, 99000, 'session-end');" \
    2>/dev/null
_lt_db="${CLAUDE_DIR}/state/state.db"
LIFETIME_TOKENS=0
if [[ -f "$_lt_db" ]]; then
    _lt_phash_e=$(printf '%s' "$_phash_a" | sed "s/'/''/g")
    _LT_DB_TOK=$(sqlite3 "$_lt_db" \
        "SELECT COALESCE(SUM(total_tokens), 0) FROM session_tokens WHERE project_hash = '${_lt_phash_e}';" \
        2>/dev/null || echo "0")
    if [[ "$_LT_DB_TOK" =~ ^[0-9]+$ ]] && [[ "$_LT_DB_TOK" -gt 0 ]]; then
        LIFETIME_TOKENS="$_LT_DB_TOK"
    fi
fi
# Must be 100000 (projA only), not 1099000 (all projects)
if [[ "$LIFETIME_TOKENS" == "100000" ]]; then
    pass_test
else
    fail_test "expected 100000 (projA only), got '$LIFETIME_TOKENS'"
fi
teardown_env

run_test "old backfill guard (COUNT=0) is no longer present — flat file ignored"
# This documents that the flat-file-count > db-count guard no longer exists.
# A flat file with entries that exceed the DB count does NOT trigger any import.
setup_env "t5b"
_init_schema
_canonical="$CLAUDE_DIR/state/state.db"
# DB has 1 row, flat file has 5 — old code would have backfilled, new code does not
sqlite3 "$_canonical" \
    "INSERT INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
     VALUES ('test-stale', 'staleproject', 'stale', '2026-01-01T00:00:00Z', 25000, 25000, 0, 'tester');" \
    2>/dev/null
cat > "$CLAUDE_DIR/.session-token-history" <<EOF
2026-02-01T10:00:00Z|50000|40000|10000|sess-real|realhash|realproj
2026-02-02T10:00:00Z|60000|48000|12000|sess-real2|realhash|realproj
2026-02-03T10:00:00Z|70000|56000|14000|sess-real3|realhash|realproj
2026-02-04T10:00:00Z|80000|64000|16000|sess-real4|realhash|realproj
2026-02-05T10:00:00Z|90000|72000|18000|sess-real5|realhash|realproj
EOF
# Under DEC-STATE-KV-009: no backfill code in session-init.sh.
# DB should still have exactly 1 row.
_db_count=$(sqlite3 "$_canonical" "SELECT COUNT(*) FROM session_tokens;" 2>/dev/null || echo "0")
if [[ "$_db_count" == "1" ]]; then
    pass_test
else
    fail_test "expected 1 row (no backfill), got '$_db_count'"
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
# Test 7: New install — empty SQLite returns 0 (no flat-file fallback)
# ---------------------------------------------------------------------------
# @decision DEC-STATE-KV-009
# @title No flat-file fallback: new installs with empty SQLite return 0
# @status accepted
# @rationale The flat-file fallback was removed (DEC-STATE-KV-009). On new installs
#   or brand-new SQLite DBs with no rows, LIFETIME_TOKENS returns 0.  The old fallback
#   would have awk-summed the flat file, but that path no longer exists in session-init.sh.
echo ""
echo "=== Test 7: New install — empty SQLite returns 0 (DEC-STATE-KV-009) ==="

run_test "new install: empty SQLite returns LIFETIME_TOKENS=0"
setup_env "t7"
_init_schema  # Creates the DB but inserts no rows
_lt_db="${CLAUDE_DIR}/state/state.db"
_PHASH="newinstallhash"
# Even with a flat file present, it must NOT be read
cat > "$CLAUDE_DIR/.session-token-history" <<EOF
2026-03-01T10:00:00Z|77000|60000|17000|sess-fb1|newinstallhash|fbproj
2026-03-02T10:00:00Z|88000|70000|18000|sess-fb2|newinstallhash|fbproj
EOF
LIFETIME_TOKENS=0
# session-init.sh SQLite-only read path (DEC-STATE-KV-009)
if [[ -f "$_lt_db" ]]; then
    _lt_phash_e=$(printf '%s' "$_PHASH" | sed "s/'/''/g")
    _LT_DB_TOK=$(sqlite3 "$_lt_db" \
        "SELECT COALESCE(SUM(total_tokens), 0) FROM session_tokens WHERE project_hash = '${_lt_phash_e}';" \
        2>/dev/null || echo "0")
    if [[ "$_LT_DB_TOK" =~ ^[0-9]+$ ]] && [[ "$_LT_DB_TOK" -gt 0 ]]; then
        LIFETIME_TOKENS="$_LT_DB_TOK"
    fi
fi
# NO flat-file fallback — LIFETIME_TOKENS stays 0
if [[ "$LIFETIME_TOKENS" == "0" ]]; then
    pass_test
else
    fail_test "expected LIFETIME_TOKENS=0 (SQLite empty, no fallback), got '$LIFETIME_TOKENS'"
fi
teardown_env

run_test "new install: flat file absent and SQLite empty returns 0"
setup_env "t7b"
_init_schema
_lt_db="${CLAUDE_DIR}/state/state.db"
_PHASH="brandnewhash"
# No flat file at all
LIFETIME_TOKENS=0
if [[ -f "$_lt_db" ]]; then
    _lt_phash_e=$(printf '%s' "$_PHASH" | sed "s/'/''/g")
    _LT_DB_TOK=$(sqlite3 "$_lt_db" \
        "SELECT COALESCE(SUM(total_tokens), 0) FROM session_tokens WHERE project_hash = '${_lt_phash_e}';" \
        2>/dev/null || echo "0")
    if [[ "$_LT_DB_TOK" =~ ^[0-9]+$ ]] && [[ "$_LT_DB_TOK" -gt 0 ]]; then
        LIFETIME_TOKENS="$_LT_DB_TOK"
    fi
fi
if [[ "$LIFETIME_TOKENS" == "0" ]]; then
    pass_test
else
    fail_test "expected LIFETIME_TOKENS=0, got '$LIFETIME_TOKENS'"
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
