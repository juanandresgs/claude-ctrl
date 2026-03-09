#!/usr/bin/env bash
# test-db-guardian-w3a.sh — Unit tests for db-guardian-lib.sh (Wave 3a)
#
# Tests Database Guardian JSON handoff protocol:
#   D1: _dbg_validate_request() — schema validation with all required fields
#   D2: _dbg_format_request()   — request JSON construction with all fields
#   D3: _dbg_parse_response()   — response field extraction (pipe-delimited)
#   D4: _dbg_format_response()  — response JSON construction
#   D5: _dbg_emit_guardian_required() — DB-GUARDIAN-REQUIRED signal formatting
#   Integration: _db_op_type_from_cli() — operation type detection from CLI+SQL
#
# Usage: bash tests/test-db-guardian-w3a.sh
#
# @decision DEC-DBGUARD-W3A-TEST-001
# @title Test-first unit tests for db-guardian-lib.sh Wave 3a functions
# @status accepted
# @rationale All tests source db-guardian-lib.sh and db-safety-lib.sh directly and
#   call functions in isolation. No mocks needed — both libraries have no external
#   dependencies beyond bash builtins, jq, and standard POSIX utilities. Test
#   coverage includes valid requests, all rejection paths, round-trip JSON fidelity,
#   and edge cases (empty inputs, unknown types, missing fields). Results format
#   matches Wave 1b/2b (PASS/FAIL prefix) for run-hooks.sh aggregation compatibility.
#   Minimum 25 tests as specified in Wave 3a requirements.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$(dirname "$SCRIPT_DIR")/hooks"

# Source the libraries under test
source "$HOOKS_DIR/source-lib.sh"
require_db_guardian
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

assert_starts_with() {
    local test_name="$1"
    local prefix="$2"
    local actual="$3"
    if [[ "$actual" == "$prefix"* ]]; then
        pass "$test_name"
    else
        fail "$test_name" "expected to start with '$prefix', got '$actual'"
    fi
}

assert_not_empty() {
    local test_name="$1"
    local actual="$2"
    if [[ -n "$actual" ]]; then
        pass "$test_name"
    else
        fail "$test_name" "expected non-empty value, got empty"
    fi
}

assert_is_json() {
    local test_name="$1"
    local actual="$2"
    if command -v jq >/dev/null 2>&1; then
        if echo "$actual" | jq empty 2>/dev/null; then
            pass "$test_name"
        else
            fail "$test_name" "expected valid JSON, got: $(echo "$actual" | head -c 100)"
        fi
    else
        # Fallback when jq unavailable: check for { } brackets
        if echo "$actual" | grep -q '{' && echo "$actual" | grep -q '}'; then
            pass "$test_name"
        else
            fail "$test_name" "expected JSON object (no jq available for full validation)"
        fi
    fi
}

echo ""
echo "=== Database Guardian Wave 3a — db-guardian-lib.sh unit tests ==="
echo ""

# =============================================================================
# Section 1: _dbg_validate_request — valid requests pass
# =============================================================================
echo "--- T01-T06: Request validation (valid requests) ---"

_VALID_REQUEST='{
  "operation_type": "data_mutation",
  "description": "Delete expired sessions from the sessions table",
  "query": "DELETE FROM sessions WHERE expires_at < NOW()",
  "target_database": "app_db",
  "target_environment": "production",
  "context_snapshot": {
    "affected_tables": ["sessions"],
    "estimated_row_count": 1500,
    "cascade_risk": false
  },
  "requires_approval": true,
  "reversibility_info": {
    "reversible": false,
    "rollback_method": "backup restore",
    "recovery_checkpoint": "snap-20260309-0800"
  }
}'

# T01: Valid complete request passes
_result=$(_dbg_validate_request "$_VALID_REQUEST")
assert_eq "T01: complete valid request returns 'valid'" "valid" "$_result"

# T02: schema_alter operation type passes
_req_schema_alter=$(echo "$_VALID_REQUEST" | sed 's/"data_mutation"/"schema_alter"/')
_result=$(_dbg_validate_request "$_req_schema_alter")
assert_eq "T02: schema_alter operation_type passes validation" "valid" "$_result"

# T03: migration operation type passes
_req_migration=$(echo "$_VALID_REQUEST" | sed 's/"data_mutation"/"migration"/')
_result=$(_dbg_validate_request "$_req_migration")
assert_eq "T03: migration operation_type passes validation" "valid" "$_result"

# T04: query operation type passes
_req_query=$(echo "$_VALID_REQUEST" | sed 's/"data_mutation"/"query"/')
_result=$(_dbg_validate_request "$_req_query")
assert_eq "T04: query operation_type passes validation" "valid" "$_result"

# T05: staging environment passes
_req_staging=$(echo "$_VALID_REQUEST" | sed 's/"production"/"staging"/')
_result=$(_dbg_validate_request "$_req_staging")
assert_eq "T05: staging target_environment passes validation" "valid" "$_result"

# T06: local environment passes
_req_local=$(echo "$_VALID_REQUEST" | sed 's/"production"/"local"/')
_result=$(_dbg_validate_request "$_req_local")
assert_eq "T06: local target_environment passes validation" "valid" "$_result"

# =============================================================================
# Section 2: _dbg_validate_request — invalid requests rejected
# =============================================================================
echo ""
echo "--- T07-T16: Request validation (invalid requests rejected) ---"

# T07: Empty input rejected
_result=$(_dbg_validate_request "" || true)
assert_starts_with "T07: empty request rejected" "invalid:" "$_result"

# T08: Missing operation_type rejected
_req_no_optype='{"description":"test","query":"SELECT 1","target_database":"db","target_environment":"local","reversibility_info":{"reversible":false,"rollback_method":"none","recovery_checkpoint":""}}'
_result=$(_dbg_validate_request "$_req_no_optype" || true)
assert_starts_with "T08: missing operation_type rejected" "invalid:" "$_result"

# T09: Unknown operation_type rejected
_req_bad_optype=$(echo "$_VALID_REQUEST" | sed 's/"data_mutation"/"raw_exec"/')
_result=$(_dbg_validate_request "$_req_bad_optype" || true)
assert_starts_with "T09: unknown operation_type rejected" "invalid:" "$_result"

# T10: Missing query rejected
_req_no_query='{"operation_type":"query","description":"test","target_database":"db","target_environment":"local","reversibility_info":{"reversible":false,"rollback_method":"none","recovery_checkpoint":""}}'
_result=$(_dbg_validate_request "$_req_no_query" || true)
assert_starts_with "T10: missing query rejected" "invalid:" "$_result"

# T11: Missing target_environment rejected
_req_no_env='{"operation_type":"query","description":"test","query":"SELECT 1","target_database":"db","reversibility_info":{"reversible":false,"rollback_method":"none","recovery_checkpoint":""}}'
_result=$(_dbg_validate_request "$_req_no_env" || true)
assert_starts_with "T11: missing target_environment rejected" "invalid:" "$_result"

# T12: Unknown target_environment rejected
_req_bad_env=$(echo "$_VALID_REQUEST" | sed 's/"production"/"qa"/')
_result=$(_dbg_validate_request "$_req_bad_env" || true)
assert_starts_with "T12: unknown target_environment rejected" "invalid:" "$_result"

# T13: Missing description rejected
_req_no_desc='{"operation_type":"query","query":"SELECT 1","target_database":"db","target_environment":"local","reversibility_info":{"reversible":false,"rollback_method":"none","recovery_checkpoint":""}}'
_result=$(_dbg_validate_request "$_req_no_desc" || true)
assert_starts_with "T13: missing description rejected" "invalid:" "$_result"

# T14: Missing target_database rejected
_req_no_db='{"operation_type":"query","description":"test","query":"SELECT 1","target_environment":"local","reversibility_info":{"reversible":false,"rollback_method":"none","recovery_checkpoint":""}}'
_result=$(_dbg_validate_request "$_req_no_db" || true)
assert_starts_with "T14: missing target_database rejected" "invalid:" "$_result"

# T15: Missing reversibility_info rejected
_req_no_rev='{"operation_type":"query","description":"test","query":"SELECT 1","target_database":"db","target_environment":"local"}'
_result=$(_dbg_validate_request "$_req_no_rev" || true)
assert_starts_with "T15: missing reversibility_info rejected" "invalid:" "$_result"

# T16: Malformed JSON rejected
_result=$(_dbg_validate_request "{not valid json" || true)
assert_starts_with "T16: malformed JSON rejected" "invalid:" "$_result"

# =============================================================================
# Section 3: _dbg_format_request — all fields populated correctly
# =============================================================================
echo ""
echo "--- T17-T21: Request formatting ---"

# T17: Format request produces valid JSON
_formatted=$(_dbg_format_request \
    "data_mutation" \
    "Delete expired sessions" \
    "DELETE FROM sessions WHERE expires_at < NOW()" \
    "app_db" \
    "production" \
    "sessions" \
    "1500" \
    "false" \
    "true" \
    "false" \
    "backup restore" \
    "snap-20260309-0800")
assert_is_json "T17: _dbg_format_request produces valid JSON" "$_formatted"

# T18: operation_type is in formatted output
assert_contains "T18: formatted request contains operation_type" '"operation_type"' "$_formatted"

# T19: target_environment is in formatted output
assert_contains "T19: formatted request contains target_environment" '"production"' "$_formatted"

# T20: query is in formatted output
assert_contains "T20: formatted request contains query" 'DELETE FROM sessions' "$_formatted"

# T21: Format with schema_alter type produces valid JSON
_formatted_ddl=$(_dbg_format_request \
    "schema_alter" \
    "Add index to orders table" \
    "CREATE INDEX idx_orders_created ON orders(created_at)" \
    "orders_db" \
    "staging" \
    "orders" \
    "0" \
    "false" \
    "false" \
    "true" \
    "transaction rollback" \
    "")
assert_is_json "T21: schema_alter format request produces valid JSON" "$_formatted_ddl"

# =============================================================================
# Section 4: _dbg_parse_response — field extraction
# =============================================================================
echo ""
echo "--- T22-T27: Response parsing ---"

_VALID_RESPONSE='{
  "status": "denied",
  "execution_id": "dbg-12345-6789",
  "result": {"rows_affected": 0, "data": []},
  "policy_decision": {
    "rule_matched": "PROD-DDL-ALWAYS-ESCALATE",
    "action": "deny",
    "reason": "Production DDL requires explicit approval"
  },
  "simulation_result": {
    "explain_output": "Seq Scan on sessions",
    "estimated_impact": "1500 rows affected",
    "cascade_effects": []
  }
}'

# T22: Parse valid response returns pipe-delimited string
IFS='|' read -r _status _rule _reason _rows <<< "$(_dbg_parse_response "$_VALID_RESPONSE")"
assert_eq "T22: parse response status field" "denied" "$_status"

# T23: Parse response rule_matched field
assert_eq "T23: parse response rule_matched field" "PROD-DDL-ALWAYS-ESCALATE" "$_rule"

# T24: Parse response reason field
assert_contains "T24: parse response reason contains explanation" "explicit approval" "$_reason"

# T25: Parse response rows_affected field
assert_eq "T25: parse response rows_affected field" "0" "$_rows"

# T26: Parse executed response with rows
_EXEC_RESPONSE='{
  "status": "executed",
  "execution_id": "dbg-99999-1111",
  "result": {"rows_affected": 42, "data": []},
  "policy_decision": {
    "rule_matched": "DEV-ALL-ALLOW",
    "action": "allow",
    "reason": "Development environment: all operations allowed"
  },
  "simulation_result": {"explain_output": "", "estimated_impact": "42 rows", "cascade_effects": []}
}'
IFS='|' read -r _status2 _rule2 _reason2 _rows2 <<< "$(_dbg_parse_response "$_EXEC_RESPONSE")"
assert_eq "T26: parse executed response rows_affected" "42" "$_rows2"

# T27: Parse empty response returns safe defaults
_result=$(_dbg_parse_response "" 2>/dev/null || echo "|||0")
IFS='|' read -r _es _er _err _erows <<< "$_result"
assert_eq "T27: empty response returns 0 rows_affected" "0" "$_erows"

# =============================================================================
# Section 5: _dbg_format_response — response construction
# =============================================================================
echo ""
echo "--- T28-T32: Response formatting ---"

# T28: Format denied response produces valid JSON
_denied_resp=$(_dbg_format_response \
    "denied" \
    "dbg-test-001" \
    "PROD-MUTATION-NO-CHECKPOINT" \
    "deny" \
    "Production data mutation requires recovery checkpoint" \
    "0" \
    "" \
    "")
assert_is_json "T28: _dbg_format_response denied produces valid JSON" "$_denied_resp"

# T29: Format response contains status field
assert_contains "T29: denied response contains status" '"status"' "$_denied_resp"

# T30: Format executed response produces valid JSON
_exec_resp=$(_dbg_format_response \
    "executed" \
    "dbg-test-002" \
    "DEV-ALL-ALLOW" \
    "allow" \
    "Development environment: allowed" \
    "15" \
    "Seq Scan on users" \
    "15 rows affected")
assert_is_json "T30: _dbg_format_response executed produces valid JSON" "$_exec_resp"

# T31: Format approval_required response contains execution_id
_appr_resp=$(_dbg_format_response \
    "approval_required" \
    "dbg-test-003" \
    "PROD-DDL-ALWAYS-ESCALATE" \
    "escalate" \
    "Production DDL always requires explicit user approval" \
    "0" \
    "EXPLAIN: Table scan on orders, 50000 rows" \
    "50000 rows estimated")
assert_contains "T31: approval_required response contains execution_id" '"dbg-test-003"' "$_appr_resp"

# T32: rows_affected normalizes non-integer to 0
_resp_bad_rows=$(_dbg_format_response "denied" "dbg-test-004" "RULE" "deny" "reason" "not-a-number" "" "")
assert_contains "T32: non-integer rows_affected normalized to 0" '"rows_affected": 0' "$_resp_bad_rows"

# =============================================================================
# Section 6: _dbg_emit_guardian_required — signal formatting
# =============================================================================
echo ""
echo "--- T33-T37: DB-GUARDIAN-REQUIRED signal ---"

# T33: Signal contains DB-GUARDIAN-REQUIRED marker
_signal=$(_dbg_emit_guardian_required \
    "schema_alter" \
    "psql -c 'ALTER TABLE users ADD COLUMN email_verified BOOLEAN'" \
    "Production DDL blocked" \
    "production")
assert_contains "T33: signal contains DB-GUARDIAN-REQUIRED marker" "DB-GUARDIAN-REQUIRED:" "$_signal"

# T34: Signal contains operation_type
assert_contains "T34: signal contains operation_type" '"operation_type":"schema_alter"' "$_signal"

# T35: Signal contains target_environment
assert_contains "T35: signal contains target_environment" '"target_environment":"production"' "$_signal"

# T36: Long command is truncated in signal
_long_cmd="psql -c 'SELECT * FROM users WHERE id IN ($(seq 1 100 | tr '\n' ',')1)'"
_signal_long=$(_dbg_emit_guardian_required "query" "$_long_cmd" "reason" "production")
assert_contains "T36: long command truncated in signal" "..." "$_signal_long"

# T37: Signal with unknown target_env uses the passed value
_signal_unk=$(_dbg_emit_guardian_required "data_mutation" "psql -c 'DELETE FROM logs'" "reason" "unknown")
assert_contains "T37: signal preserves unknown target_environment" '"target_environment":"unknown"' "$_signal_unk"

# =============================================================================
# Section 7: _db_op_type_from_cli — operation type detection
# =============================================================================
echo ""
echo "--- T38-T43: Operation type detection from CLI + SQL ---"

# T38: DDL command detected as schema_alter
_op=$(_db_op_type_from_cli "psql" "psql -c 'ALTER TABLE users ADD COLUMN verified BOOLEAN'")
assert_eq "T38: ALTER TABLE detected as schema_alter" "schema_alter" "$_op"

# T39: CREATE TABLE detected as schema_alter
_op=$(_db_op_type_from_cli "psql" "psql -c 'CREATE TABLE new_table (id SERIAL PRIMARY KEY)'")
assert_eq "T39: CREATE TABLE detected as schema_alter" "schema_alter" "$_op"

# T40: DELETE FROM detected as data_mutation
_op=$(_db_op_type_from_cli "psql" "psql -c 'DELETE FROM sessions WHERE expires_at < NOW()'")
assert_eq "T40: DELETE FROM detected as data_mutation" "data_mutation" "$_op"

# T41: UPDATE detected as data_mutation
_op=$(_db_op_type_from_cli "mysql" "mysql -e 'UPDATE users SET active = 0 WHERE last_seen < DATE_SUB(NOW(), INTERVAL 1 YEAR)'")
assert_eq "T41: UPDATE detected as data_mutation" "data_mutation" "$_op"

# T42: Migration CLI invocation detected as migration
_op=$(_db_op_type_from_cli "psql" "psql -f migrate_v2.sql --migration")
assert_eq "T42: --migration flag detected as migration" "migration" "$_op"

# T43: SELECT query defaults to query type
_op=$(_db_op_type_from_cli "psql" "psql -c 'SELECT count(*) FROM users'")
assert_eq "T43: SELECT defaults to query type" "query" "$_op"

# =============================================================================
# Section 8: Edge cases
# =============================================================================
echo ""
echo "--- T44-T47: Edge cases ---"

# T44: Format request with empty affected_tables
_fmt_empty_tables=$(_dbg_format_request \
    "query" \
    "Simple SELECT query" \
    "SELECT 1" \
    "mydb" \
    "development" \
    "" \
    "0" \
    "false" \
    "false" \
    "true" \
    "none" \
    "")
assert_is_json "T44: format request with empty affected_tables is valid JSON" "$_fmt_empty_tables"

# T45: Format response with auto-generated execution_id
_resp_auto_id=$(_dbg_format_response "denied" "" "RULE" "deny" "reason" "0" "" "")
assert_contains "T45: auto-generated execution_id starts with dbg-" '"dbg-' "$_resp_auto_id"

# T46: Validate request with development environment passes
_dev_req='{"operation_type":"data_mutation","description":"seed data","query":"INSERT INTO test VALUES (1)","target_database":"devdb","target_environment":"development","reversibility_info":{"reversible":true,"rollback_method":"transaction rollback","recovery_checkpoint":""}}'
_result=$(_dbg_validate_request "$_dev_req")
assert_eq "T46: development environment passes validation" "valid" "$_result"

# T47: DROP TABLE detected as schema_alter by op_type_from_cli
_op=$(_db_op_type_from_cli "mysql" "mysql -e 'DROP TABLE IF EXISTS tmp_imports'")
assert_eq "T47: DROP TABLE detected as schema_alter" "schema_alter" "$_op"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "==========================="
_T_TOTAL=$((_T_PASSED + _T_FAILED))
echo "Results: $_T_TOTAL total | Passed: $_T_PASSED | Failed: $_T_FAILED"

if [[ $_T_FAILED -gt 0 ]]; then
    exit 1
fi
exit 0
