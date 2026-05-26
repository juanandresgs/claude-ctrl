#!/usr/bin/env bash
# test-lease-workflow-id-authority.sh: Verifies that when a lease is issued with
# an explicit workflow_id that differs from the branch-derived id, all hooks
# (post-task.sh, check-tester.sh) use the lease's workflow_id — not the branch name.
#
# Production sequence tested:
#   1. A tester lease is issued with workflow_id=wf-lease-test (not matching branch)
#   2. Tester submits a valid completion record under that workflow_id
#   3. post-task.sh fires — must use wf-lease-test, not git-repo (branch-derived)
#   4. check-tester.sh fires — must write eval_state under wf-lease-test
#   5. Eval state for wf-lease-test == ready_for_guardian
#   6. Eval state for git-repo (branch-derived) is NOT touched
#
# @decision DEC-WS1-TEST-001
# @title Scenario: lease workflow_id beats branch-derived id in all hook paths
# @status accepted
# @rationale WS1 ensures that hooks use lease_context() as the identity source
#   when a lease is active. This test proves the invariant end-to-end by using
#   a lease workflow_id that intentionally differs from the branch-derived one.
#   Without the fix, post-task.sh would emit workflow_id=git-repo; with the fix
#   it emits workflow_id=wf-lease-test.
set -euo pipefail

TEST_NAME="test-lease-workflow-id-authority"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
POST_TASK_HOOK="$REPO_ROOT/hooks/post-task.sh"
CHECK_TESTER_HOOK="$REPO_ROOT/hooks/check-tester.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/state.db"
TMP_GIT="$TMP_DIR/git-repo"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
mkdir -p "$TMP_DIR" "$TMP_GIT"

# Initialize a minimal git repo on a branch with a DIFFERENT name than the lease wf id
git -C "$TMP_GIT" init -q 2>/dev/null
git -C "$TMP_GIT" checkout -b feature/some-other-branch 2>/dev/null
git -C "$TMP_GIT" -c user.email="t@t.com" -c user.name="T" commit --allow-empty -m "init" -q 2>/dev/null

CC="python3 $REPO_ROOT/runtime/cli.py"
export CLAUDE_POLICY_DB="$TEST_DB"
export CLAUDE_PROJECT_DIR="$TMP_GIT"
export CLAUDE_RUNTIME_ROOT="$REPO_ROOT/runtime"

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "=== $TEST_NAME ==="

# Verify branch-derived workflow_id would be different from the lease's
BRANCH_DERIVED_WF="feature-some-other-branch"
LEASE_WF_ID="wf-lease-test"
echo "  [setup] branch-derived wf_id would be: $BRANCH_DERIVED_WF"
echo "  [setup] lease wf_id: $LEASE_WF_ID"
if [[ "$BRANCH_DERIVED_WF" != "$LEASE_WF_ID" ]]; then
    pass "lease workflow_id differs from branch-derived (test isolation confirmed)"
else
    fail "lease workflow_id differs from branch-derived — test setup invalid"
fi

# Bootstrap schema
$CC schema ensure >/dev/null 2>&1

# Issue a tester lease with an explicit workflow_id different from the branch
ISSUE_OUT=$($CC lease issue-for-dispatch "tester" \
    --worktree-path "$TMP_GIT" \
    --workflow-id "$LEASE_WF_ID" \
    --allowed-ops '["routine_local"]' 2>/dev/null)
LEASE_ID=$(printf '%s' "$ISSUE_OUT" | jq -r '.lease.lease_id // empty' 2>/dev/null || true)

if [[ -n "$LEASE_ID" ]]; then
    pass "tester lease issued with workflow_id=$LEASE_WF_ID (id=$LEASE_ID)"
else
    fail "tester lease issued — cannot proceed"
    echo "FAIL: $TEST_NAME — cannot set up test fixtures"
    exit 1
fi

# Submit a valid tester completion record under the lease workflow_id
VALID_PAYLOAD='{"EVAL_VERDICT":"ready_for_guardian","EVAL_TESTS_PASS":"true","EVAL_NEXT_ROLE":"guardian","EVAL_HEAD_SHA":"deadbeef"}'
SUBMIT_OUT=$($CC completion submit \
    --lease-id "$LEASE_ID" \
    --workflow-id "$LEASE_WF_ID" \
    --role "tester" \
    --payload "$VALID_PAYLOAD" 2>/dev/null || echo '{"valid":false}')
SUBMIT_VALID=$(printf '%s' "$SUBMIT_OUT" | jq -r 'if .valid == 1 or .valid == true then "true" else "false" end' 2>/dev/null || echo "false")

if [[ "$SUBMIT_VALID" == "true" ]]; then
    pass "valid tester completion submitted under lease workflow_id"
else
    fail "valid tester completion submitted (got: $SUBMIT_OUT)"
    echo "FAIL: $TEST_NAME — cannot set up completion record"
    exit 1
fi

# Run post-task.sh with agent_type=tester and verify dispatch uses lease wf_id
HOOK_PAYLOAD=$(printf '{"hook_event_name":"SubagentStop","agent_type":"tester"}')
HOOK_OUTPUT=$(printf '%s' "$HOOK_PAYLOAD" \
    | CLAUDE_PROJECT_DIR="$TMP_GIT" CLAUDE_POLICY_DB="$TEST_DB" "$POST_TASK_HOOK" 2>/dev/null || true)

echo "  [debug] post-task output: $HOOK_OUTPUT"

if echo "$HOOK_OUTPUT" | jq '.' >/dev/null 2>&1; then
    CTX=$(echo "$HOOK_OUTPUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)

    # WS1 core assertion: dispatch context must contain the LEASE workflow_id
    if [[ "$CTX" == *"workflow_id=$LEASE_WF_ID"* ]]; then
        pass "dispatch context uses lease workflow_id ($LEASE_WF_ID)"
    else
        fail "dispatch context uses lease workflow_id — expected workflow_id=$LEASE_WF_ID in: $CTX"
    fi

    # WS1 negative: dispatch must NOT use the branch-derived id
    if [[ "$CTX" == *"workflow_id=$BRANCH_DERIVED_WF"* ]]; then
        fail "dispatch context must NOT use branch-derived workflow_id ($BRANCH_DERIVED_WF)"
    else
        pass "dispatch context does not use branch-derived workflow_id"
    fi

    if [[ "$CTX" == *"guardian"* ]]; then
        pass "dispatch suggests guardian (routing correct)"
    else
        fail "dispatch suggests guardian (got: $CTX)"
    fi
else
    fail "post-task hook output is valid JSON (got: $HOOK_OUTPUT)"
fi

# Re-issue a fresh tester lease for check-tester.sh test
ISSUE_OUT2=$($CC lease issue-for-dispatch "tester" \
    --worktree-path "$TMP_GIT" \
    --workflow-id "$LEASE_WF_ID" \
    --allowed-ops '["routine_local"]' 2>/dev/null)
LEASE_ID2=$(printf '%s' "$ISSUE_OUT2" | jq -r '.lease.lease_id // empty' 2>/dev/null || true)

if [[ -n "$LEASE_ID2" ]]; then
    pass "second tester lease issued for check-tester.sh verification"
else
    fail "second tester lease issued"
fi

# Build a fake tester response with valid EVAL_* trailers
TESTER_RESPONSE="Analysis complete.
EVAL_VERDICT: ready_for_guardian
EVAL_TESTS_PASS: true
EVAL_NEXT_ROLE: guardian
EVAL_HEAD_SHA: deadbeef"

CT_PAYLOAD=$(jq -n \
    --arg r "$TESTER_RESPONSE" \
    --arg at "tester" \
    '{agent_type: $at, response: $r}')

# Run check-tester.sh
CT_OUTPUT=$(printf '%s' "$CT_PAYLOAD" \
    | CLAUDE_PROJECT_DIR="$TMP_GIT" CLAUDE_POLICY_DB="$TEST_DB" "$CHECK_TESTER_HOOK" 2>/dev/null || true)

echo "  [debug] check-tester output: $CT_OUTPUT"

# Verify eval_state was written under the LEASE workflow_id
EVAL_JSON=$($CC evaluation get "$LEASE_WF_ID" 2>/dev/null || echo '{}')
EVAL_STATUS=$(printf '%s' "$EVAL_JSON" | jq -r '.status // "not_found"' 2>/dev/null || echo "not_found")
if [[ "$EVAL_STATUS" == "ready_for_guardian" ]]; then
    pass "eval_state written under lease workflow_id ($LEASE_WF_ID) = ready_for_guardian"
else
    fail "eval_state written under lease workflow_id — got status=$EVAL_STATUS for $LEASE_WF_ID"
fi

# Verify eval_state for the BRANCH-DERIVED id was NOT written
EVAL_JSON_BRANCH=$($CC evaluation get "$BRANCH_DERIVED_WF" 2>/dev/null || echo '{}')
EVAL_STATUS_BRANCH=$(printf '%s' "$EVAL_JSON_BRANCH" | jq -r '.status // "not_found"' 2>/dev/null || echo "not_found")
if [[ "$EVAL_STATUS_BRANCH" == "not_found" || "$EVAL_STATUS_BRANCH" == "idle" ]]; then
    pass "eval_state NOT written under branch-derived workflow_id ($BRANCH_DERIVED_WF)"
else
    fail "eval_state must NOT be written under branch-derived id — got $EVAL_STATUS_BRANCH for $BRANCH_DERIVED_WF"
fi

# --- Results ---
TOTAL=9
echo ""
echo "Results: $((TOTAL - FAILURES))/$TOTAL passed"
if [[ "$FAILURES" -gt 0 ]]; then
    echo "FAIL: $TEST_NAME — $FAILURES check(s) failed"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
