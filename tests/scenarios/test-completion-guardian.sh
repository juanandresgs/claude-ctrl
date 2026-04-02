#!/usr/bin/env bash
# test-completion-guardian.sh: CLI-level guardian completion tests.
# Exercises valid and invalid completion payloads for the guardian role.
#
# @decision DEC-COMPLETION-TEST-002
# @title Scenario test: guardian completion records gate cycle-completion routing
# @status accepted
# @rationale Guardian completion records (DEC-COMPLETION-001) capture
#   LANDING_RESULT and OPERATION_CLASS so post-task.sh can route
#   deterministically: committed/merged -> cycle complete; denied/skipped
#   -> re-dispatch implementer. This test verifies all valid verdicts and
#   that missing fields produce valid=false. Advisory in v1 (commit already
#   happened) but the record must still be valid for routing to work.
set -euo pipefail

TEST_NAME="test-completion-guardian"
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

# Bootstrap schema
$CC schema ensure >/dev/null 2>&1

# Issue a guardian lease
ISSUE_OUT=$($CC lease issue-for-dispatch "guardian" \
    --worktree-path "$TMP_DIR" \
    --workflow-id "test-wf-guardian-completion" \
    --allowed-ops '["routine_local","high_risk"]' \
    --no-eval 2>/dev/null)
LEASE_ID=$(printf '%s' "$ISSUE_OUT" | jq -r '.lease.lease_id // empty' 2>/dev/null || true)
if [[ -n "$LEASE_ID" ]]; then pass "guardian lease issued"; else fail "guardian lease issued"; fi

# --- Test 1: committed verdict -> valid ---
COMMITTED_PAYLOAD='{"LANDING_RESULT":"committed","OPERATION_CLASS":"routine_local"}'
SUB1=$($CC completion submit \
    --lease-id "$LEASE_ID" \
    --workflow-id "test-wf-guardian-completion" \
    --role "guardian" \
    --payload "$COMMITTED_PAYLOAD" 2>/dev/null || echo '{"valid":0}')

SUB1_VALID=$(printf '%s' "$SUB1" | jq -r 'if .valid == 1 or .valid == true then "true" else "false" end' 2>/dev/null || echo "false")
SUB1_VERDICT=$(printf '%s' "$SUB1" | jq -r '.verdict // empty' 2>/dev/null || true)
if [[ "$SUB1_VALID" == "true" ]]; then pass "committed: valid=true"; else fail "committed: valid=true (got $SUB1_VALID)"; fi
if [[ "$SUB1_VERDICT" == "committed" ]]; then pass "committed: verdict=committed"; else fail "committed: verdict=committed (got $SUB1_VERDICT)"; fi

# --- Test 2: merged verdict -> valid ---
mkdir -p "$TMP_DIR/wt2"
ISSUE2=$($CC lease issue-for-dispatch "guardian" \
    --worktree-path "$TMP_DIR/wt2" \
    --workflow-id "test-wf-guardian-merged" \
    --allowed-ops '["routine_local","high_risk"]' \
    --no-eval 2>/dev/null)
LEASE2_ID=$(printf '%s' "$ISSUE2" | jq -r '.lease.lease_id // empty' 2>/dev/null || true)

MERGED_PAYLOAD='{"LANDING_RESULT":"merged","OPERATION_CLASS":"routine_local"}'
SUB2=$($CC completion submit \
    --lease-id "$LEASE2_ID" \
    --workflow-id "test-wf-guardian-merged" \
    --role "guardian" \
    --payload "$MERGED_PAYLOAD" 2>/dev/null || echo '{"valid":0}')
SUB2_VALID=$(printf '%s' "$SUB2" | jq -r 'if .valid == 1 or .valid == true then "true" else "false" end' 2>/dev/null || echo "false")
if [[ "$SUB2_VALID" == "true" ]]; then pass "merged: valid=true"; else fail "merged: valid=true (got $SUB2_VALID)"; fi

# --- Test 3: denied verdict -> valid (routes back to implementer) ---
mkdir -p "$TMP_DIR/wt3"
ISSUE3=$($CC lease issue-for-dispatch "guardian" \
    --worktree-path "$TMP_DIR/wt3" \
    --workflow-id "test-wf-guardian-denied" \
    --allowed-ops '["routine_local","high_risk"]' \
    --no-eval 2>/dev/null)
LEASE3_ID=$(printf '%s' "$ISSUE3" | jq -r '.lease.lease_id // empty' 2>/dev/null || true)

DENIED_PAYLOAD='{"LANDING_RESULT":"denied","OPERATION_CLASS":"routine_local"}'
SUB3=$($CC completion submit \
    --lease-id "$LEASE3_ID" \
    --workflow-id "test-wf-guardian-denied" \
    --role "guardian" \
    --payload "$DENIED_PAYLOAD" 2>/dev/null || echo '{"valid":0}')
SUB3_VALID=$(printf '%s' "$SUB3" | jq -r 'if .valid == 1 or .valid == true then "true" else "false" end' 2>/dev/null || echo "false")
SUB3_VERDICT=$(printf '%s' "$SUB3" | jq -r '.verdict // empty' 2>/dev/null || true)
if [[ "$SUB3_VALID" == "true" ]]; then pass "denied: valid=true"; else fail "denied: valid=true (got $SUB3_VALID)"; fi
if [[ "$SUB3_VERDICT" == "denied" ]]; then pass "denied: verdict=denied"; else fail "denied: verdict=denied (got $SUB3_VERDICT)"; fi

# --- Test 4: missing LANDING_RESULT -> valid=false ---
mkdir -p "$TMP_DIR/wt4"
ISSUE4=$($CC lease issue-for-dispatch "guardian" \
    --worktree-path "$TMP_DIR/wt4" \
    --workflow-id "test-wf-guardian-missing" \
    --allowed-ops '["routine_local"]' \
    --no-eval 2>/dev/null)
LEASE4_ID=$(printf '%s' "$ISSUE4" | jq -r '.lease.lease_id // empty' 2>/dev/null || true)

MISSING_PAYLOAD='{"OPERATION_CLASS":"routine_local"}'
SUB4=$($CC completion submit \
    --lease-id "$LEASE4_ID" \
    --workflow-id "test-wf-guardian-missing" \
    --role "guardian" \
    --payload "$MISSING_PAYLOAD" 2>/dev/null || echo '{"valid":0}')
SUB4_VALID=$(printf '%s' "$SUB4" | jq -r 'if .valid == 1 or .valid == true then "true" else "false" end' 2>/dev/null || echo "false")
SUB4_MISSING=$(printf '%s' "$SUB4" | jq -r '.missing_fields | length' 2>/dev/null || echo "0")
if [[ "$SUB4_VALID" == "false" ]]; then pass "missing LANDING_RESULT: valid=false"; else fail "missing LANDING_RESULT: valid=false (got $SUB4_VALID)"; fi
if [[ "$SUB4_MISSING" -gt 0 ]]; then pass "missing LANDING_RESULT: missing_fields non-empty"; else fail "missing LANDING_RESULT: missing_fields non-empty (got $SUB4_MISSING)"; fi

# --- Test 5: latest retrieval ---
LATEST=$($CC completion latest --lease-id "$LEASE_ID" 2>/dev/null || echo '{"found":false}')
L_FOUND=$(printf '%s' "$LATEST" | jq -r '.found // false' 2>/dev/null || echo "false")
L_ROLE=$(printf '%s' "$LATEST" | jq -r '.role // empty' 2>/dev/null || true)
if [[ "$L_FOUND" == "true" ]]; then pass "latest: found=true"; else fail "latest: found=true (got $L_FOUND)"; fi
if [[ "$L_ROLE" == "guardian" ]]; then pass "latest: role=guardian"; else fail "latest: role=guardian (got $L_ROLE)"; fi

TOTAL=12
echo ""
echo "Results: $((TOTAL - FAILURES))/$TOTAL passed"
if [[ "$FAILURES" -gt 0 ]]; then
    echo "FAIL: $TEST_NAME — $FAILURES check(s) failed"
    exit 1
fi
