#!/usr/bin/env bash
# test-routing-tester-completion.sh: Verifies that post-task.sh routes tester
# completion to guardian when a valid completion record exists.
#
# Production sequence tested:
#   1. A tester lease is issued (as if by dispatch)
#   2. Tester submits a valid completion record (verdict=ready_for_guardian)
#   3. post-task.sh fires with agent_type=tester
#   4. Hook reads the active lease, reads the completion record, calls
#      cc-policy completion route tester ready_for_guardian → "guardian"
#   5. Hook releases the lease AFTER routing
#   6. Output contains "guardian" in additionalContext
#
# @decision DEC-DISPATCH-TEST-002
# @title Scenario test: tester completion routing via completion record
# @status accepted
# @rationale This is the compound-interaction test required by the implementer
#   role guide. It crosses: lease state → completion record → routing table →
#   post-task hook output → dispatch queue. No mocks — all real SQLite state.
set -euo pipefail

TEST_NAME="test-routing-tester-completion"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/post-task.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/state.db"
TMP_GIT="$TMP_DIR/git-repo"

# shellcheck disable=SC2329  # cleanup is invoked via trap EXIT
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
mkdir -p "$TMP_DIR" "$TMP_GIT"

# Initialize a minimal git repo so detect_project_root returns something
git -C "$TMP_GIT" init -q 2>/dev/null
git -C "$TMP_GIT" checkout -b feature/test-wf 2>/dev/null

CC="python3 $REPO_ROOT/runtime/cli.py"
export CLAUDE_POLICY_DB="$TEST_DB"
export CLAUDE_PROJECT_DIR="$TMP_GIT"
# Point cc_policy at the worktree's cli.py so hooks pick up the 'completion route'
# subcommand added in this branch rather than the production runtime at $HOME/.claude/runtime.
export CLAUDE_RUNTIME_ROOT="$REPO_ROOT/runtime"

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "=== $TEST_NAME ==="

# --- Bootstrap schema ---
$CC schema ensure >/dev/null 2>&1

# --- Issue a tester lease for the test workflow ---
WF_ID="feature-test-wf"
ISSUE_OUT=$($CC lease issue-for-dispatch "tester" \
    --worktree-path "$TMP_GIT" \
    --workflow-id "$WF_ID" \
    --allowed-ops '["routine_local"]' 2>/dev/null)
LEASE_ID=$(printf '%s' "$ISSUE_OUT" | jq -r '.lease.lease_id // empty' 2>/dev/null || true)

if [[ -n "$LEASE_ID" ]]; then
    pass "tester lease issued (id=$LEASE_ID)"
else
    fail "tester lease issued — cannot proceed without lease"
    echo "FAIL: $TEST_NAME — cannot set up test fixtures"
    exit 1
fi

# --- Submit a valid tester completion record (verdict=ready_for_guardian) ---
VALID_PAYLOAD='{"EVAL_VERDICT":"ready_for_guardian","EVAL_TESTS_PASS":"true","EVAL_NEXT_ROLE":"guardian","EVAL_HEAD_SHA":"abc123"}'
SUBMIT_OUT=$($CC completion submit \
    --lease-id "$LEASE_ID" \
    --workflow-id "$WF_ID" \
    --role "tester" \
    --payload "$VALID_PAYLOAD" 2>/dev/null || echo '{"valid":false}')
SUBMIT_VALID=$(printf '%s' "$SUBMIT_OUT" | jq -r 'if .valid == 1 or .valid == true then "true" else "false" end' 2>/dev/null || echo "false")

if [[ "$SUBMIT_VALID" == "true" ]]; then
    pass "valid tester completion record submitted"
else
    fail "valid tester completion record submitted (got: $SUBMIT_OUT)"
    echo "FAIL: $TEST_NAME — cannot set up completion record"
    exit 1
fi

# --- Verify lease is still active before running hook (it must NOT be released yet) ---
LEASE_BEFORE=$($CC lease current --worktree-path "$TMP_GIT" 2>/dev/null || echo '{"found":false}')
LEASE_FOUND=$(printf '%s' "$LEASE_BEFORE" | jq -r '.found // false' 2>/dev/null || echo "false")
if [[ "$LEASE_FOUND" == "true" ]]; then
    pass "lease still active before hook fires"
else
    fail "lease still active before hook fires — lease was released too early"
fi

# --- Run post-task.sh with agent_type=tester ---
HOOK_PAYLOAD=$(printf '{"hook_event_name":"SubagentStop","agent_type":"tester"}')
HOOK_OUTPUT=$(printf '%s' "$HOOK_PAYLOAD" \
    | CLAUDE_PROJECT_DIR="$TMP_GIT" CLAUDE_POLICY_DB="$TEST_DB" "$HOOK" 2>/dev/null || true)

echo "  [debug] hook output: $HOOK_OUTPUT"

# --- Verify output: should suggest guardian ---
if echo "$HOOK_OUTPUT" | jq '.' >/dev/null 2>&1; then
    CTX=$(echo "$HOOK_OUTPUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)
    if [[ "$CTX" == *"guardian"* ]]; then
        pass "output suggests guardian dispatch"
    else
        fail "output suggests guardian dispatch (got ctx: $CTX)"
    fi
    if [[ "$CTX" == *"PROCESS ERROR"* ]]; then
        fail "output must not contain PROCESS ERROR (got: $CTX)"
    else
        pass "output contains no PROCESS ERROR"
    fi
    # WS1: verify that the dispatch context uses the LEASE workflow_id (feature-test-wf),
    # not the branch-derived one (which would be "git-repo" from the TMP_GIT repo name).
    if [[ "$CTX" == *"workflow_id=$WF_ID"* ]]; then
        pass "dispatch context uses lease workflow_id ($WF_ID)"
    else
        fail "dispatch context uses lease workflow_id — expected workflow_id=$WF_ID in: $CTX"
    fi
else
    fail "hook output is valid JSON (got: $HOOK_OUTPUT)"
fi

# --- Verify lease is now released after hook ---
LEASE_AFTER=$($CC lease current --worktree-path "$TMP_GIT" 2>/dev/null || echo '{"found":false}')
LEASE_FOUND_AFTER=$(printf '%s' "$LEASE_AFTER" | jq -r '.found // false' 2>/dev/null || echo "false")
if [[ "$LEASE_FOUND_AFTER" == "false" ]]; then
    pass "lease released after hook fires"
else
    fail "lease released after hook fires — lease still active after post-task"
fi

# --- Verify dispatch queue has guardian enqueued ---
NEXT_ROLE=$($CC dispatch next 2>/dev/null | jq -r '.role // empty' 2>/dev/null || true)
if [[ "$NEXT_ROLE" == "guardian" ]]; then
    pass "dispatch queue: guardian enqueued"
else
    fail "dispatch queue: guardian enqueued (got: '$NEXT_ROLE')"
fi

# --- Results ---
TOTAL=8
echo ""
echo "Results: $((TOTAL - FAILURES))/$TOTAL passed"
if [[ "$FAILURES" -gt 0 ]]; then
    echo "FAIL: $TEST_NAME — $FAILURES check(s) failed"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
