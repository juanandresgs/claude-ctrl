#!/usr/bin/env bash
# test-routing-guardian-completion.sh: Verifies that post-task.sh routes
# guardian landing completion back to planner when verdict=merged.
#
# Production sequence tested:
#   1. A guardian lease is issued
#   2. Guardian submits a valid completion record (verdict=merged)
#   3. post-task.sh fires with agent_type=guardian
#   4. Hook reads the active lease, reads the completion record, calls
#      cc-policy completion route guardian merged -> planner
#   5. Hook produces an AUTO_DISPATCH planner suggestion
#   6. Lease is released after routing
#
# @decision DEC-DISPATCH-TEST-004
# @title Scenario test: guardian merged verdict resumes planner continuation
# @status accepted
# @rationale The stage registry is the routing authority. guardian:land with a
#   merged verdict returns to planner so the planner owns the next decision
#   (next work item, goal_complete, user decision, or external block). The
#   guardian completion path must produce AUTO_DISPATCH: planner and must not
#   emit the old guardian-side cycle_complete signal.
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

# --- Verify output: guardian merged resumes planner continuation ---
if [[ -z "$HOOK_OUTPUT" ]]; then
    fail "guardian merged should produce AUTO_DISPATCH: planner, got empty output"
elif echo "$HOOK_OUTPUT" | jq '.' >/dev/null 2>&1; then
    CTX=$(echo "$HOOK_OUTPUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)
    if [[ "$CTX" == AUTO_DISPATCH:\ planner* ]]; then
        pass "guardian merged emits AUTO_DISPATCH: planner"
    else
        fail "guardian merged should dispatch planner, got: $CTX"
    fi
    if [[ "$CTX" == *"PROCESS ERROR"* ]]; then
        fail "guardian must not emit PROCESS ERROR for valid merged verdict (got: $CTX)"
    else
        pass "guardian merged: no PROCESS ERROR"
    fi
else
    if [[ "$HOOK_OUTPUT" == AUTO_DISPATCH:\ planner* ]]; then
        pass "guardian merged emits AUTO_DISPATCH: planner"
    else
        fail "guardian merged should dispatch planner, got: $HOOK_OUTPUT"
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

# --- Verify routing emitted completion audit, not old cycle_complete ---
AGENT_EVENT_COUNT=$($CC event query --type "agent_complete" 2>/dev/null \
    | jq -r '.count // 0' 2>/dev/null || echo "0")
if [[ "$AGENT_EVENT_COUNT" -ge 1 ]]; then
    pass "agent_complete event emitted"
else
    fail "agent_complete event emitted (count=$AGENT_EVENT_COUNT)"
fi

CYCLE_EVENT_COUNT=$($CC event query --type "cycle_complete" 2>/dev/null \
    | jq -r '.count // 0' 2>/dev/null || echo "0")
if [[ "$CYCLE_EVENT_COUNT" -eq 0 ]]; then
    pass "guardian merged did not emit stale cycle_complete event"
else
    fail "guardian merged emitted stale cycle_complete event (count=$CYCLE_EVENT_COUNT)"
fi

# --- Results ---
TOTAL=7
echo ""
echo "Results: $((TOTAL - FAILURES))/$TOTAL passed"
if [[ "$FAILURES" -gt 0 ]]; then
    echo "FAIL: $TEST_NAME — $FAILURES check(s) failed"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
