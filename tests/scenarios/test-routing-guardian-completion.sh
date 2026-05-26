#!/usr/bin/env bash
# test-routing-guardian-completion.sh: Verifies that post-task.sh routes
# guardian completion to cycle_complete (no next role) when verdict=merged.
#
# Production sequence tested:
#   1. A guardian lease is issued
#   2. Guardian submits a valid completion record (verdict=merged)
#   3. post-task.sh fires with agent_type=guardian
#   4. Hook reads the active lease, reads the completion record, calls
#      cc-policy completion route guardian merged → null (cycle complete)
#   5. Hook emits cycle_complete event, produces no dispatch suggestion
#   6. Lease is released after routing
#
# @decision DEC-DISPATCH-TEST-004
# @title Scenario test: guardian merged verdict produces cycle_complete
# @status accepted
# @rationale Verifies the terminal state of the dispatch cycle. When guardian
#   produces a merged verdict, determine_next_role returns None (no next role).
#   post-task.sh must emit a cycle_complete event and produce no additionalContext
#   dispatch suggestion. No fallback to eval_state.
set -euo pipefail

TEST_NAME="test-routing-guardian-completion"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/post-task.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/state.db"
TMP_GIT="$TMP_DIR/git-repo"

# shellcheck disable=SC2329  # cleanup is invoked via trap EXIT
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
mkdir -p "$TMP_DIR" "$TMP_GIT"

git -C "$TMP_GIT" init -q 2>/dev/null
git -C "$TMP_GIT" checkout -b feature/test-guardian-wf 2>/dev/null

CC="python3 $REPO_ROOT/runtime/cli.py"
export CLAUDE_POLICY_DB="$TEST_DB"
export CLAUDE_PROJECT_DIR="$TMP_GIT"
export CLAUDE_RUNTIME_ROOT="$REPO_ROOT/runtime"

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "=== $TEST_NAME ==="

# --- Bootstrap schema ---
$CC schema ensure >/dev/null 2>&1

# --- Issue a guardian lease ---
WF_ID="feature-test-guardian-wf"
ISSUE_OUT=$($CC lease issue-for-dispatch "guardian" \
    --worktree-path "$TMP_GIT" \
    --workflow-id "$WF_ID" \
    --allowed-ops '["routine_local","high_risk"]' \
    --no-eval 2>/dev/null)
LEASE_ID=$(printf '%s' "$ISSUE_OUT" | jq -r '.lease.lease_id // empty' 2>/dev/null || true)

if [[ -n "$LEASE_ID" ]]; then
    pass "guardian lease issued (id=$LEASE_ID)"
else
    fail "guardian lease issued — cannot proceed"
    echo "FAIL: $TEST_NAME"
    exit 1
fi

# --- Submit a valid guardian completion record (verdict=merged) ---
GUARDIAN_PAYLOAD='{"LANDING_RESULT":"merged","OPERATION_CLASS":"merge"}'
SUBMIT_OUT=$($CC completion submit \
    --lease-id "$LEASE_ID" \
    --workflow-id "$WF_ID" \
    --role "guardian" \
    --payload "$GUARDIAN_PAYLOAD" 2>/dev/null || echo '{"valid":false}')
SUBMIT_VALID=$(printf '%s' "$SUBMIT_OUT" | jq -r 'if .valid == 1 or .valid == true then "true" else "false" end' 2>/dev/null || echo "false")

if [[ "$SUBMIT_VALID" == "true" ]]; then
    pass "valid guardian completion record submitted (verdict=merged)"
else
    fail "valid guardian completion record submitted (got: $SUBMIT_OUT)"
    echo "FAIL: $TEST_NAME"
    exit 1
fi

# --- Run post-task.sh with agent_type=guardian ---
HOOK_PAYLOAD=$(printf '{"hook_event_name":"SubagentStop","agent_type":"guardian"}')
HOOK_OUTPUT=$(printf '%s' "$HOOK_PAYLOAD" \
    | CLAUDE_PROJECT_DIR="$TMP_GIT" CLAUDE_POLICY_DB="$TEST_DB" "$HOOK" 2>/dev/null || true)

echo "  [debug] hook output: '$HOOK_OUTPUT'"

# --- Verify output: guardian cycle-complete produces no dispatch suggestion ---
# Acceptable outputs: empty (silent success) or JSON without dispatch suggestion
if [[ -z "$HOOK_OUTPUT" ]]; then
    pass "guardian cycle_complete: no output (silent terminal state)"
elif echo "$HOOK_OUTPUT" | jq '.' >/dev/null 2>&1; then
    CTX=$(echo "$HOOK_OUTPUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)
    if [[ "$CTX" == *"dispatching"* ]]; then
        fail "guardian must not suggest next dispatch (cycle complete), got: $CTX"
    else
        pass "guardian cycle_complete: no dispatch suggestion in output"
    fi
    if [[ "$CTX" == *"PROCESS ERROR"* ]]; then
        fail "guardian must not emit PROCESS ERROR for valid merged verdict (got: $CTX)"
    else
        pass "guardian cycle_complete: no PROCESS ERROR"
    fi
else
    # Non-JSON output — check it isn't a dispatch suggestion
    if [[ "$HOOK_OUTPUT" == *"dispatching"* ]]; then
        fail "guardian must not suggest next dispatch, got: $HOOK_OUTPUT"
    else
        pass "guardian cycle_complete: no dispatch suggestion"
    fi
fi

# --- Verify lease is released after hook ---
LEASE_AFTER=$($CC lease current --worktree-path "$TMP_GIT" 2>/dev/null || echo '{"found":false}')
LEASE_FOUND_AFTER=$(printf '%s' "$LEASE_AFTER" | jq -r '.found // false' 2>/dev/null || echo "false")
if [[ "$LEASE_FOUND_AFTER" == "false" ]]; then
    pass "lease released after guardian hook fires"
else
    fail "lease released after guardian hook fires — lease still active"
fi

# --- Verify cycle_complete event was emitted ---
CYCLE_EVENT_COUNT=$($CC event query --type "cycle_complete" 2>/dev/null \
    | jq -r '.count // 0' 2>/dev/null || echo "0")
if [[ "$CYCLE_EVENT_COUNT" -ge 1 ]]; then
    pass "cycle_complete event emitted"
else
    fail "cycle_complete event emitted (count=$CYCLE_EVENT_COUNT)"
fi

# --- Results ---
TOTAL=6
echo ""
echo "Results: $((TOTAL - FAILURES))/$TOTAL passed"
if [[ "$FAILURES" -gt 0 ]]; then
    echo "FAIL: $TEST_NAME — $FAILURES check(s) failed"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
