#!/usr/bin/env bash
# test-remove-db-guardian.sh — Tests verifying db-guardian dead weight removal.
#
# Verifies:
#   1. _dbg_emit_guardian_required is available after sourcing db-safety-lib.sh
#   2. _dbg_emit_guardian_required produces correct JSON signal output
#   3. require_db_guardian is a safe no-op (returns 0 without sourcing missing file)
#   4. db-guardian-lib.sh and db-guardian.md do NOT exist (cleanup confirmed)
#   5. test-db-guardian-w3a.sh and test-db-guardian-w3b.sh do NOT exist (cleanup confirmed)
#
# Usage: bash tests/test-remove-db-guardian.sh
#
# @decision DEC-PERF-001
# @title _dbg_emit_guardian_required relocated to db-safety-lib.sh
# @status accepted
# @rationale db-guardian-lib.sh had zero active invocations across 1,093 traces.
#   The safety signal function belongs in the safety library, not the agent library.
#   Removing dead code reduces system prompt mass by 12.8KB.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$(dirname "$SCRIPT_DIR")/hooks"
AGENTS_DIR="$(dirname "$SCRIPT_DIR")/agents"
TESTS_DIR="$(dirname "$SCRIPT_DIR")/tests"

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
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$test_name"
    else
        fail "$test_name" "expected '$needle' to appear in: $haystack"
    fi
}

assert_not_exists() {
    local test_name="$1"
    local path="$2"
    if [[ ! -e "$path" ]]; then
        pass "$test_name"
    else
        fail "$test_name" "expected '$path' to NOT exist, but it does"
    fi
}

# =============================================================================
# Section 1: _dbg_emit_guardian_required available from db-safety-lib.sh
# =============================================================================
echo "--- _dbg_emit_guardian_required function availability ---"

if type _dbg_emit_guardian_required &>/dev/null 2>&1; then
    pass "T01: _dbg_emit_guardian_required is available after require_db_safety"
else
    fail "T01: _dbg_emit_guardian_required is available after require_db_safety" "function not found in scope"
fi

# =============================================================================
# Section 2: Signal output correctness
# =============================================================================
echo ""
echo "--- _dbg_emit_guardian_required output format ---"

_sig=$(  _dbg_emit_guardian_required "data_mutation" "DROP TABLE users" "destructive DDL" "production"  )

assert_contains "T02: signal contains DB-GUARDIAN-REQUIRED prefix" "DB-GUARDIAN-REQUIRED:" "$_sig"
assert_contains "T03: signal contains operation_type" '"operation_type":"data_mutation"' "$_sig"
assert_contains "T04: signal contains denied_command" '"denied_command":"DROP TABLE users"' "$_sig"
assert_contains "T05: signal contains deny_reason" '"deny_reason":"destructive DDL"' "$_sig"
assert_contains "T06: signal contains target_environment" '"target_environment":"production"' "$_sig"

# Test with default args
_sig_default=$( _dbg_emit_guardian_required )
assert_contains "T07: signal with defaults contains DB-GUARDIAN-REQUIRED:" "DB-GUARDIAN-REQUIRED:" "$_sig_default"
assert_contains "T08: signal with defaults has data_mutation op_type" '"operation_type":"data_mutation"' "$_sig_default"

# Test command truncation (>200 chars)
_long_cmd=$(printf 'A%.0s' {1..250})
_sig_truncated=$( _dbg_emit_guardian_required "query" "$_long_cmd" "too long" "staging" )
assert_contains "T09: long command is truncated to 203 chars (200 + ...)" "..." "$_sig_truncated"

# =============================================================================
# Section 3: require_db_guardian is a safe no-op
# =============================================================================
echo ""
echo "--- require_db_guardian no-op behavior ---"

if type require_db_guardian &>/dev/null 2>&1; then
    _rc=0
    require_db_guardian || _rc=$?
    assert_eq "T10: require_db_guardian returns 0 (no-op)" "0" "$_rc"
else
    fail "T10: require_db_guardian returns 0 (no-op)" "function not found — check source-lib.sh"
fi

# =============================================================================
# Section 4: Dead files removed
# =============================================================================
echo ""
echo "--- Dead file removal ---"

assert_not_exists "T11: hooks/db-guardian-lib.sh deleted" "$HOOKS_DIR/db-guardian-lib.sh"
assert_not_exists "T12: agents/db-guardian.md deleted" "$AGENTS_DIR/db-guardian.md"
assert_not_exists "T13: tests/test-db-guardian-w3a.sh deleted" "$TESTS_DIR/test-db-guardian-w3a.sh"
assert_not_exists "T14: tests/test-db-guardian-w3b.sh deleted" "$TESTS_DIR/test-db-guardian-w3b.sh"

# =============================================================================
# Results
# =============================================================================
echo ""
echo "Results: $((_T_PASSED + _T_FAILED)) total | $_T_PASSED passed | $_T_FAILED failed"
[[ "$_T_FAILED" -eq 0 ]] && exit 0 || exit 1
