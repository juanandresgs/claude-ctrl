#!/usr/bin/env bash
# test-completion-tester.sh: CLI-level tester completion tests.
# Exercises valid and invalid completion payloads for the tester role.
#
# @decision DEC-COMPLETION-TEST-001
# @title Scenario test: tester completion records gate eval routing
# @status accepted
# @rationale Tester completion records (DEC-COMPLETION-001) are the Phase 2
#   mechanism that replaces grep-based EVAL_* trailer parsing with structured
#   SQLite records. This test exercises: valid payload -> valid=true, correct
#   verdict stored; missing fields -> valid=false, missing_fields populated;
#   wrong verdict value -> valid=false. Uses cc-policy CLI directly.
set -euo pipefail

TEST_NAME="test-completion-tester"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/state.db"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
mkdir -p "$TMP_DIR"

# Use the worktree's own runtime/cli.py — Phase 1 commands (lease, completion)
# are not yet in the production runtime at $CLAUDE_RUNTIME_ROOT.
CC="python3 $REPO_ROOT/runtime/cli.py"
export CLAUDE_POLICY_DB="$TEST_DB"

FAILURES=0

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "=== $TEST_NAME ==="

# Bootstrap schema and issue a lease
$CC schema ensure >/dev/null 2>&1

ISSUE_OUT=$($CC lease issue-for-dispatch "tester" \
    --worktree-path "$TMP_DIR" \
    --workflow-id "test-wf-tester-completion" \
    --allowed-ops '["routine_local"]' 2>/dev/null)
LEASE_ID=$(printf '%s' "$ISSUE_OUT" | jq -r '.lease.lease_id // empty' 2>/dev/null || true)
if [[ -n "$LEASE_ID" ]]; then pass "tester lease issued"; else fail "tester lease issued"; fi

# --- Test 1: Valid payload -> valid=true ---
VALID_PAYLOAD='{"EVAL_VERDICT":"ready_for_guardian","EVAL_TESTS_PASS":"true","EVAL_NEXT_ROLE":"guardian","EVAL_HEAD_SHA":"abc123"}'
SUBMIT1=$($CC completion submit \
    --lease-id "$LEASE_ID" \
    --workflow-id "test-wf-tester-completion" \
    --role "tester" \
    --payload "$VALID_PAYLOAD" 2>/dev/null || echo '{"valid":0}')

SUB1_VALID=$(printf '%s' "$SUBMIT1" | jq -r 'if .valid == 1 or .valid == true then "true" else "false" end' 2>/dev/null || echo "false")
SUB1_VERDICT=$(printf '%s' "$SUBMIT1" | jq -r '.verdict // empty' 2>/dev/null || true)
SUB1_MISSING=$(printf '%s' "$SUBMIT1" | jq -r '.missing_fields | length' 2>/dev/null || echo "1")

if [[ "$SUB1_VALID" == "true" ]]; then pass "valid payload: valid=true"; else fail "valid payload: valid=true (got $SUB1_VALID)"; fi
if [[ "$SUB1_VERDICT" == "ready_for_guardian" ]]; then pass "valid payload: verdict=ready_for_guardian"; else fail "valid payload: verdict=ready_for_guardian (got $SUB1_VERDICT)"; fi
if [[ "$SUB1_MISSING" == "0" ]]; then pass "valid payload: no missing fields"; else fail "valid payload: no missing fields (got $SUB1_MISSING)"; fi

# --- Test 2: Latest record retrieval ---
LATEST1=$($CC completion latest --lease-id "$LEASE_ID" 2>/dev/null || echo '{"found":false}')
L1_FOUND=$(printf '%s' "$LATEST1" | jq -r '.found // false' 2>/dev/null || echo "false")
L1_VERDICT=$(printf '%s' "$LATEST1" | jq -r '.verdict // empty' 2>/dev/null || true)
if [[ "$L1_FOUND" == "true" ]]; then pass "latest: found=true after submit"; else fail "latest: found=true after submit"; fi
if [[ "$L1_VERDICT" == "ready_for_guardian" ]]; then pass "latest: verdict matches submitted"; else fail "latest: verdict matches submitted (got $L1_VERDICT)"; fi

# --- Test 3: Invalid payload — missing fields ---
mkdir -p "$TMP_DIR/wt2"
ISSUE2=$($CC lease issue-for-dispatch "tester" \
    --worktree-path "$TMP_DIR/wt2" \
    --workflow-id "test-wf-tester-invalid" \
    --allowed-ops '["routine_local"]' 2>/dev/null)
LEASE2_ID=$(printf '%s' "$ISSUE2" | jq -r '.lease.lease_id // empty' 2>/dev/null || true)
if [[ -n "$LEASE2_ID" ]]; then pass "second tester lease issued"; else fail "second tester lease issued"; fi

MISSING_PAYLOAD='{"EVAL_VERDICT":"ready_for_guardian"}'
SUBMIT2=$($CC completion submit \
    --lease-id "$LEASE2_ID" \
    --workflow-id "test-wf-tester-invalid" \
    --role "tester" \
    --payload "$MISSING_PAYLOAD" 2>/dev/null || echo '{"valid":0}')

SUB2_VALID=$(printf '%s' "$SUBMIT2" | jq -r 'if .valid == 1 or .valid == true then "true" else "false" end' 2>/dev/null || echo "false")
SUB2_MISSING_COUNT=$(printf '%s' "$SUBMIT2" | jq -r '.missing_fields | length' 2>/dev/null || echo "0")
if [[ "$SUB2_VALID" == "false" ]]; then pass "missing fields: valid=false"; else fail "missing fields: valid=false (got $SUB2_VALID)"; fi
if [[ "$SUB2_MISSING_COUNT" -gt 0 ]]; then pass "missing fields: missing_fields non-empty"; else fail "missing fields: missing_fields non-empty (got $SUB2_MISSING_COUNT)"; fi

# --- Test 4: Invalid verdict value ---
mkdir -p "$TMP_DIR/wt3"
ISSUE3=$($CC lease issue-for-dispatch "tester" \
    --worktree-path "$TMP_DIR/wt3" \
    --workflow-id "test-wf-tester-badverdict" \
    --allowed-ops '["routine_local"]' 2>/dev/null)
LEASE3_ID=$(printf '%s' "$ISSUE3" | jq -r '.lease.lease_id // empty' 2>/dev/null || true)

BAD_VERDICT_PAYLOAD='{"EVAL_VERDICT":"not_a_verdict","EVAL_TESTS_PASS":"true","EVAL_NEXT_ROLE":"guardian","EVAL_HEAD_SHA":"def456"}'
SUBMIT3=$($CC completion submit \
    --lease-id "$LEASE3_ID" \
    --workflow-id "test-wf-tester-badverdict" \
    --role "tester" \
    --payload "$BAD_VERDICT_PAYLOAD" 2>/dev/null || echo '{"valid":0}')

SUB3_VALID=$(printf '%s' "$SUBMIT3" | jq -r 'if .valid == 1 or .valid == true then "true" else "false" end' 2>/dev/null || echo "false")
if [[ "$SUB3_VALID" == "false" ]]; then pass "invalid verdict: valid=false"; else fail "invalid verdict: valid=false (got $SUB3_VALID)"; fi

# --- Test 5: needs_changes verdict also valid ---
NEEDS_CHANGES_PAYLOAD='{"EVAL_VERDICT":"needs_changes","EVAL_TESTS_PASS":"false","EVAL_NEXT_ROLE":"implementer","EVAL_HEAD_SHA":"def789"}'
SUBMIT4=$($CC completion submit \
    --lease-id "$LEASE_ID" \
    --workflow-id "test-wf-tester-completion" \
    --role "tester" \
    --payload "$NEEDS_CHANGES_PAYLOAD" 2>/dev/null || echo '{"valid":0}')

SUB4_VALID=$(printf '%s' "$SUBMIT4" | jq -r 'if .valid == 1 or .valid == true then "true" else "false" end' 2>/dev/null || echo "false")
SUB4_VERDICT=$(printf '%s' "$SUBMIT4" | jq -r '.verdict // empty' 2>/dev/null || true)
if [[ "$SUB4_VALID" == "true" ]]; then pass "needs_changes: valid=true"; else fail "needs_changes: valid=true (got $SUB4_VALID)"; fi
if [[ "$SUB4_VERDICT" == "needs_changes" ]]; then pass "needs_changes: verdict stored correctly"; else fail "needs_changes: verdict stored correctly (got $SUB4_VERDICT)"; fi

TOTAL=12
echo ""
echo "Results: $((TOTAL - FAILURES))/$TOTAL passed"
if [[ "$FAILURES" -gt 0 ]]; then
    echo "FAIL: $TEST_NAME — $FAILURES check(s) failed"
    exit 1
fi
