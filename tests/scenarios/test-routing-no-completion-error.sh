#!/usr/bin/env bash
# test-routing-no-completion-error.sh: Verifies that post-task.sh emits a
# PROCESS ERROR when a tester lease exists but no completion record was filed.
#
# Production sequence tested:
#   1. A tester lease is issued
#   2. No completion record is submitted (tester failed to fulfill contract)
#   3. post-task.sh fires with agent_type=tester
#   4. Hook reads the active lease, finds no completion record
#   5. Hook emits PROCESS ERROR in additionalContext (no guardian enqueued)
#   6. Lease is released (cleanup even on error)
#
# @decision DEC-DISPATCH-TEST-003
# @title Scenario test: missing completion record surfaces PROCESS ERROR
# @status accepted
# @rationale Confirms the no-fallback invariant: when a lease exists but has no
#   completion record, the hook must NOT silently fall through to an eval_state
#   read. It must surface PROCESS ERROR so the orchestrator knows the tester
#   did not fulfill its contract.
set -euo pipefail

TEST_NAME="test-routing-no-completion-error"
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
git -C "$TMP_GIT" checkout -b feature/test-no-completion 2>/dev/null

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

# --- Issue a tester lease (no completion record will be submitted) ---
WF_ID="feature-test-no-completion"
ISSUE_OUT=$($CC lease issue-for-dispatch "tester" \
    --worktree-path "$TMP_GIT" \
    --workflow-id "$WF_ID" \
    --allowed-ops '["routine_local"]' 2>/dev/null)
LEASE_ID=$(printf '%s' "$ISSUE_OUT" | jq -r '.lease.lease_id // empty' 2>/dev/null || true)

if [[ -n "$LEASE_ID" ]]; then
    pass "tester lease issued (id=$LEASE_ID)"
else
    fail "tester lease issued — cannot proceed"
    echo "FAIL: $TEST_NAME"
    exit 1
fi

# Intentionally do NOT submit a completion record.

# --- Run post-task.sh with agent_type=tester ---
HOOK_PAYLOAD=$(printf '{"hook_event_name":"SubagentStop","agent_type":"tester"}')
HOOK_OUTPUT=$(printf '%s' "$HOOK_PAYLOAD" \
    | CLAUDE_PROJECT_DIR="$TMP_GIT" CLAUDE_POLICY_DB="$TEST_DB" "$HOOK" 2>/dev/null || true)

echo "  [debug] hook output: $HOOK_OUTPUT"

# --- Verify output: should contain PROCESS ERROR, not a dispatch suggestion ---
if echo "$HOOK_OUTPUT" | jq '.' >/dev/null 2>&1; then
    CTX=$(echo "$HOOK_OUTPUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)
    if [[ "$CTX" == *"PROCESS ERROR"* ]]; then
        pass "output contains PROCESS ERROR"
    else
        fail "output contains PROCESS ERROR (got ctx: $CTX)"
    fi
    if [[ "$CTX" == *"guardian"* && "$CTX" != *"PROCESS ERROR"* ]]; then
        fail "output must not suggest guardian (tester did not complete)"
    else
        pass "output does not spuriously suggest guardian"
    fi
else
    fail "hook output is valid JSON (got: $HOOK_OUTPUT)"
fi

# --- Verify dispatch queue has no guardian (no next role should be enqueued) ---
NEXT_ROLE=$($CC dispatch next 2>/dev/null | jq -r '.role // empty' 2>/dev/null || true)
if [[ "$NEXT_ROLE" != "guardian" ]]; then
    pass "dispatch queue: guardian NOT enqueued on PROCESS ERROR"
else
    fail "dispatch queue: guardian must not be enqueued when contract not fulfilled (got: '$NEXT_ROLE')"
fi

# --- Results ---
TOTAL=4
echo ""
echo "Results: $((TOTAL - FAILURES))/$TOTAL passed"
if [[ "$FAILURES" -gt 0 ]]; then
    echo "FAIL: $TEST_NAME — $FAILURES check(s) failed"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
