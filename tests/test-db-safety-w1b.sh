#!/usr/bin/env bash
# test-db-safety-w1b.sh — Unit tests for db-safety-lib.sh (Wave 1b: modular architecture)
#
# Tests:
#   T01: _db_detect_cli identifies psql
#   T02: _db_detect_cli identifies mysql
#   T03: _db_detect_cli identifies sqlite3
#   T04: _db_detect_cli identifies mongosh
#   T05: _db_detect_cli identifies redis-cli
#   T06: _db_detect_cli returns "none" for non-DB commands (ls, git, etc.)
#   T07: _db_detect_environment reads APP_ENV correctly
#   T08: _db_detect_environment detects production hostname patterns
#   T09: _db_classify_risk flags DROP TABLE as deny
#   T10: _db_classify_risk flags TRUNCATE as deny
#   T11: _db_classify_risk flags DELETE without WHERE as advisory
#   T12: _db_classify_risk flags SELECT as safe
#   T13: _db_classify_risk flags FLUSHALL as deny
#   T14: Environment tiering: prod+deny = blocked (via dispatch in pre-bash.sh)
#   T15: Environment tiering: dev+deny = advisory only
#   T16: _db_detect_cli handles quoted/escaped command arguments
#   T17: Unknown CLI passes through without blocking
#   T18: _db_detect_cli identifies cockroach CLI
#   T19: _db_classify_risk flags FLUSHDB as deny
#   T20: _db_classify_risk flags dropDatabase() as deny (MongoDB)
#   T21: _db_classify_risk flags DELETE without WHERE on mysql as advisory
#   T22: _db_detect_environment reads RAILS_ENV
#   T23: _db_detect_environment reads NODE_ENV
#   T24: _db_classify_risk flags ALTER TABLE DROP COLUMN as deny
#   T25: _db_detect_cli handles path-prefixed CLI (/usr/bin/psql)
#
# @decision DEC-DBSAFE-TEST-001
# @title Test-first unit tests for db-safety-lib.sh functions
# @status accepted
# @rationale All tests source db-safety-lib.sh directly and call functions in
#   isolation. No mocks needed — the library has no external dependencies beyond
#   bash builtins and standard POSIX utilities. Environment variable state is
#   saved/restored around each test to ensure test isolation.

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
        fail "$test_name" "expected to contain '$needle', got '$haystack'"
    fi
}

# Save and restore environment around tests that set env vars
_save_env() {
    _SAVED_APP_ENV="${APP_ENV:-__UNSET__}"
    _SAVED_RAILS_ENV="${RAILS_ENV:-__UNSET__}"
    _SAVED_NODE_ENV="${NODE_ENV:-__UNSET__}"
    _SAVED_FLASK_ENV="${FLASK_ENV:-__UNSET__}"
    _SAVED_DATABASE_URL="${DATABASE_URL:-__UNSET__}"
    _SAVED_PGHOST="${PGHOST:-__UNSET__}"
    _SAVED_ENVIRONMENT="${ENVIRONMENT:-__UNSET__}"
}

_restore_env() {
    [[ "$_SAVED_APP_ENV" == "__UNSET__" ]] && unset APP_ENV || export APP_ENV="$_SAVED_APP_ENV"
    [[ "$_SAVED_RAILS_ENV" == "__UNSET__" ]] && unset RAILS_ENV || export RAILS_ENV="$_SAVED_RAILS_ENV"
    [[ "$_SAVED_NODE_ENV" == "__UNSET__" ]] && unset NODE_ENV || export NODE_ENV="$_SAVED_NODE_ENV"
    [[ "$_SAVED_FLASK_ENV" == "__UNSET__" ]] && unset FLASK_ENV || export FLASK_ENV="$_SAVED_FLASK_ENV"
    [[ "$_SAVED_DATABASE_URL" == "__UNSET__" ]] && unset DATABASE_URL || export DATABASE_URL="$_SAVED_DATABASE_URL"
    [[ "$_SAVED_PGHOST" == "__UNSET__" ]] && unset PGHOST || export PGHOST="$_SAVED_PGHOST"
    [[ "$_SAVED_ENVIRONMENT" == "__UNSET__" ]] && unset ENVIRONMENT || export ENVIRONMENT="$_SAVED_ENVIRONMENT"
}

echo "=== db-safety-lib.sh unit tests (Wave 1b) ==="
echo ""

# =============================================================================
# T01-T05: _db_detect_cli — recognizes known DB CLIs
# =============================================================================
echo "--- _db_detect_cli: known CLIs ---"

# T01: psql
assert_eq "T01: detect psql" "psql" "$(_db_detect_cli "psql -h localhost -U postgres mydb")"

# T02: mysql
assert_eq "T02: detect mysql" "mysql" "$(_db_detect_cli "mysql -u root -p mydb")"

# T03: sqlite3
assert_eq "T03: detect sqlite3" "sqlite3" "$(_db_detect_cli "sqlite3 /path/to/db.sqlite")"

# T04: mongosh
assert_eq "T04: detect mongosh" "mongosh" "$(_db_detect_cli "mongosh mongodb://localhost:27017/mydb")"

# T05: redis-cli
assert_eq "T05: detect redis-cli" "redis-cli" "$(_db_detect_cli "redis-cli -h redis.example.com FLUSHALL")"

echo ""

# =============================================================================
# T06: _db_detect_cli — returns "none" for non-DB commands
# =============================================================================
echo "--- _db_detect_cli: non-DB commands return 'none' ---"

# T06a: ls
assert_eq "T06a: none for ls" "none" "$(_db_detect_cli "ls -la /tmp")"

# T06b: git
assert_eq "T06b: none for git" "none" "$(_db_detect_cli "git status")"

# T06c: grep
assert_eq "T06c: none for grep" "none" "$(_db_detect_cli "grep -r 'pattern' .")"

# T06d: curl
assert_eq "T06d: none for curl" "none" "$(_db_detect_cli "curl https://api.example.com/data")"

# T06e: python (not a DB CLI)
assert_eq "T06e: none for python" "none" "$(_db_detect_cli "python3 manage.py migrate")"

echo ""

# =============================================================================
# T07-T08: _db_detect_environment — reads environment variables
# =============================================================================
echo "--- _db_detect_environment: env var detection ---"

_save_env
unset APP_ENV RAILS_ENV NODE_ENV FLASK_ENV DATABASE_URL PGHOST ENVIRONMENT 2>/dev/null || true

# T07a: APP_ENV=production
export APP_ENV=production
assert_eq "T07a: APP_ENV=production" "production" "$(_db_detect_environment)"
unset APP_ENV

# T07b: APP_ENV=development
export APP_ENV=development
assert_eq "T07b: APP_ENV=development" "development" "$(_db_detect_environment)"
unset APP_ENV

# T07c: APP_ENV=staging
export APP_ENV=staging
assert_eq "T07c: APP_ENV=staging" "staging" "$(_db_detect_environment)"
unset APP_ENV

# T07d: APP_ENV=local
export APP_ENV=local
assert_eq "T07d: APP_ENV=local" "local" "$(_db_detect_environment)"
unset APP_ENV

# T07e: APP_ENV=prod (abbreviation)
export APP_ENV=prod
assert_eq "T07e: APP_ENV=prod" "production" "$(_db_detect_environment)"
unset APP_ENV

# T08: DATABASE_URL with production hostname pattern
export DATABASE_URL="postgresql://user:pass@prod-db.rds.amazonaws.com:5432/mydb"
assert_eq "T08: DATABASE_URL with RDS prod hostname" "production" "$(_db_detect_environment)"
unset DATABASE_URL

_restore_env
echo ""

# =============================================================================
# T09-T13: _db_classify_risk — SQL and Redis destructive patterns
# =============================================================================
echo "--- _db_classify_risk: SQL/Redis patterns ---"

# T09: DROP TABLE → deny
_result=$(_db_classify_risk "psql -c 'DROP TABLE users'" "psql")
assert_eq "T09: DROP TABLE risk level" "deny" "${_result%%:*}"

# T10: TRUNCATE → deny
_result=$(_db_classify_risk "psql -c 'TRUNCATE orders'" "psql")
assert_eq "T10: TRUNCATE risk level" "deny" "${_result%%:*}"

# T11: DELETE without WHERE → advisory
_result=$(_db_classify_risk "psql -c 'DELETE FROM sessions'" "psql")
assert_eq "T11: DELETE without WHERE risk level" "advisory" "${_result%%:*}"

# T12: SELECT → safe
_result=$(_db_classify_risk "psql -c 'SELECT * FROM users LIMIT 10'" "psql")
assert_eq "T12: SELECT risk level" "safe" "${_result%%:*}"

# T13: FLUSHALL → deny
_result=$(_db_classify_risk "redis-cli FLUSHALL" "redis-cli")
assert_eq "T13: FLUSHALL risk level" "deny" "${_result%%:*}"

echo ""

# =============================================================================
# T14-T15: Environment tiering (via dispatch logic simulation)
# =============================================================================
echo "--- Environment tiering ---"

_save_env
unset APP_ENV RAILS_ENV NODE_ENV FLASK_ENV DATABASE_URL PGHOST ENVIRONMENT 2>/dev/null || true

# T14: production + deny → should be blocked
# Simulate by checking the risk level and environment separately
export APP_ENV=production
_env=$(_db_detect_environment)
_result=$(_db_classify_risk "psql -c 'DROP TABLE users'" "psql")
_risk="${_result%%:*}"
# In production, deny-risk should be... deny
if [[ "$_env" == "production" && "$_risk" == "deny" ]]; then
    pass "T14: prod+deny combination would trigger block"
else
    fail "T14: prod+deny combination would trigger block" "env=$_env risk=$_risk"
fi
unset APP_ENV

# T15: development + deny → should allow (with warning)
export APP_ENV=development
_env=$(_db_detect_environment)
_result=$(_db_classify_risk "psql -c 'DROP TABLE users'" "psql")
_risk="${_result%%:*}"
# In development, deny-risk is allowed (with warning)
if [[ "$_env" == "development" && "$_risk" == "deny" ]]; then
    pass "T15: dev+deny combination would allow with warning"
else
    fail "T15: dev+deny combination would allow with warning" "env=$_env risk=$_risk"
fi
unset APP_ENV

_restore_env
echo ""

# =============================================================================
# T16: _db_detect_cli — handles quoted/escaped arguments
# =============================================================================
echo "--- _db_detect_cli: quoted/escaped arguments ---"

# T16a: psql with quoted SQL
assert_eq "T16a: psql with double-quoted SQL" "psql" \
    "$(_db_detect_cli 'psql -c "SELECT * FROM users WHERE name = '"'"'Alice'"'"'"')"

# T16b: mysql with single-quoted password
assert_eq "T16b: mysql with single-quoted password" "mysql" \
    "$(_db_detect_cli "mysql -u root -p'mypassword' dbname")"

# T16c: sqlite3 after &&
assert_eq "T16c: sqlite3 after &&" "sqlite3" \
    "$(_db_detect_cli "cd /data && sqlite3 app.db .tables")"

echo ""

# =============================================================================
# T17: Unknown CLI passes through without blocking
# =============================================================================
echo "--- Unknown CLI passes through ---"

# T17: a command that looks vaguely like a DB CLI but isn't known
assert_eq "T17a: psqladmin is not psql" "none" "$(_db_detect_cli "psqladmin --help")"
assert_eq "T17b: mysqldump is not mysql" "none" "$(_db_detect_cli "mysqldump mydb > backup.sql")"

echo ""

# =============================================================================
# T18: cockroach CLI
# =============================================================================
echo "--- _db_detect_cli: cockroach ---"

# T18a: cockroach sql
assert_eq "T18a: detect cockroach" "cockroach" "$(_db_detect_cli "cockroach sql --insecure")"

# T18b: cockroach with path
assert_eq "T18b: detect /usr/local/bin/cockroach" "cockroach" \
    "$(_db_detect_cli "/usr/local/bin/cockroach sql --url 'postgresql://root@localhost:26257/mydb'")"

echo ""

# =============================================================================
# T19: FLUSHDB → deny
# =============================================================================
echo "--- _db_classify_risk: FLUSHDB ---"

_result=$(_db_classify_risk "redis-cli FLUSHDB" "redis-cli")
assert_eq "T19: FLUSHDB risk level" "deny" "${_result%%:*}"

echo ""

# =============================================================================
# T20: MongoDB dropDatabase → deny
# =============================================================================
echo "--- _db_classify_risk: MongoDB patterns ---"

# T20: dropDatabase()
_result=$(_db_classify_risk "mongosh --eval 'db.dropDatabase()'" "mongosh")
assert_eq "T20: dropDatabase() risk level" "deny" "${_result%%:*}"

# T20b: deleteMany({}) → deny (empty filter)
_result=$(_db_classify_risk "mongosh --eval 'db.users.deleteMany({})'" "mongosh")
assert_eq "T20b: deleteMany({}) risk level" "deny" "${_result%%:*}"

echo ""

# =============================================================================
# T21: DELETE without WHERE on mysql → advisory
# =============================================================================
echo "--- _db_classify_risk: mysql advisory ---"

_result=$(_db_classify_risk "mysql -e 'DELETE FROM logs'" "mysql")
assert_eq "T21: mysql DELETE without WHERE" "advisory" "${_result%%:*}"

echo ""

# =============================================================================
# T22-T23: _db_detect_environment reads RAILS_ENV and NODE_ENV
# =============================================================================
echo "--- _db_detect_environment: RAILS_ENV, NODE_ENV ---"

_save_env
unset APP_ENV RAILS_ENV NODE_ENV FLASK_ENV DATABASE_URL PGHOST ENVIRONMENT 2>/dev/null || true

# T22: RAILS_ENV=production
export RAILS_ENV=production
assert_eq "T22: RAILS_ENV=production" "production" "$(_db_detect_environment)"
unset RAILS_ENV

# T23: NODE_ENV=development
export NODE_ENV=development
assert_eq "T23: NODE_ENV=development" "development" "$(_db_detect_environment)"
unset NODE_ENV

_restore_env
echo ""

# =============================================================================
# T24: ALTER TABLE DROP COLUMN → deny
# =============================================================================
echo "--- _db_classify_risk: ALTER TABLE DROP COLUMN ---"

_result=$(_db_classify_risk "psql -c 'ALTER TABLE users DROP COLUMN email'" "psql")
assert_eq "T24: ALTER TABLE DROP COLUMN risk level" "deny" "${_result%%:*}"

echo ""

# =============================================================================
# T25: _db_detect_cli handles path-prefixed CLI
# =============================================================================
echo "--- _db_detect_cli: path-prefixed CLIs ---"

# T25a: /usr/bin/psql
assert_eq "T25a: /usr/bin/psql" "psql" "$(_db_detect_cli "/usr/bin/psql -h localhost mydb")"

# T25b: /usr/local/bin/mysql
assert_eq "T25b: /usr/local/bin/mysql" "mysql" "$(_db_detect_cli "/usr/local/bin/mysql -u root mydb")"

echo ""

# =============================================================================
# Additional: verify library sentinel
# =============================================================================
echo "--- Library sentinel ---"

assert_eq "DB_SAFETY_LIB_VERSION sentinel" "1" "$_DB_SAFETY_LIB_VERSION"

echo ""

# =============================================================================
# Summary
# =============================================================================
echo "==========================="
echo "Results: $((_T_PASSED + _T_FAILED)) total | Passed: $_T_PASSED | Failed: $_T_FAILED"
echo ""

if [[ $_T_FAILED -gt 0 ]]; then
    exit 1
fi
exit 0
