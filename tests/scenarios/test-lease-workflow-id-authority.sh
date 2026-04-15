#!/usr/bin/env bash
# test-lease-workflow-id-authority.sh: Verifies that when a lease is issued with
# an explicit workflow_id that differs from the branch-derived id, all hooks
# (post-task.sh, check-reviewer.sh) use the lease's workflow_id — not the
# branch name.
#
# Production sequence tested:
#   1. A reviewer lease is issued with workflow_id=wf-lease-test (not matching branch)
#   2. A valid reviewer completion record is submitted under that workflow_id
#   3. post-task.sh fires — must use wf-lease-test, not git-repo (branch-derived)
#   4. check-reviewer.sh fires with REVIEW_* trailers — must submit a completion
#      record under wf-lease-test
#   5. Completion record for wf-lease-test is persisted with role=reviewer
#   6. No completion record is written under the branch-derived workflow_id
#
# Phase 8 Slice 11 retired the legacy ``tester`` role; the WS1 lease-authority
# invariant is now proven against the ``reviewer`` evaluator, which is the
# live read-only evaluator after Slice 11 (DEC-PHASE8-SLICE11-001).
# check-reviewer.sh does NOT write evaluation_state (see its DEC-CHECK-REVIEWER-001
# docstring); readiness is owned by the reviewer completion/findings path, so
# the WS1 invariant is proven via the completion_records table rather than
# evaluation_state.
#
# @decision DEC-WS1-TEST-001
# @title Scenario: lease workflow_id beats branch-derived id in all hook paths
# @status accepted
# @rationale WS1 ensures that hooks use lease_context() as the identity source
#   when a lease is active. This test proves the invariant end-to-end by using
#   a lease workflow_id that intentionally differs from the branch-derived one.
#   Without the fix, post-task.sh would emit workflow_id=git-repo; with the fix
#   it emits workflow_id=wf-lease-test. The completion record persisted by
#   check-reviewer.sh must also carry the lease workflow_id, not the branch id.
set -euo pipefail

TEST_NAME="test-lease-workflow-id-authority"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
POST_TASK_HOOK="$REPO_ROOT/hooks/post-task.sh"
CHECK_REVIEWER_HOOK="$REPO_ROOT/hooks/check-reviewer.sh"
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

# Helper: build a reviewer completion payload with valid REVIEW_FINDINGS_JSON.
make_reviewer_payload() {
    local verdict="$1"
    local severity="$2"
    local title="$3"
    jq -nc \
        --arg v "$verdict" \
        --arg s "$severity" \
        --arg t "$title" \
        '{
            REVIEW_VERDICT: $v,
            REVIEW_HEAD_SHA: "deadbeef",
            REVIEW_FINDINGS_JSON: ({findings: [{severity: $s, title: $t, detail: "ok"}]} | tojson)
        }'
}

# Issue a reviewer lease with an explicit workflow_id different from the branch
ISSUE_OUT=$($CC lease issue-for-dispatch "reviewer" \
    --worktree-path "$TMP_GIT" \
    --workflow-id "$LEASE_WF_ID" \
    --allowed-ops '["routine_local"]' 2>/dev/null)
LEASE_ID=$(printf '%s' "$ISSUE_OUT" | jq -r '.lease.lease_id // empty' 2>/dev/null || true)

if [[ -n "$LEASE_ID" ]]; then
    pass "reviewer lease issued with workflow_id=$LEASE_WF_ID (id=$LEASE_ID)"
else
    fail "reviewer lease issued — cannot proceed"
    echo "FAIL: $TEST_NAME — cannot set up test fixtures"
    exit 1
fi

# Submit a valid reviewer completion record under the lease workflow_id
VALID_PAYLOAD=$(make_reviewer_payload "ready_for_guardian" "note" "ok")
SUBMIT_OUT=$($CC completion submit \
    --lease-id "$LEASE_ID" \
    --workflow-id "$LEASE_WF_ID" \
    --role "reviewer" \
    --payload "$VALID_PAYLOAD" 2>/dev/null || echo '{"valid":false}')
SUBMIT_VALID=$(printf '%s' "$SUBMIT_OUT" | jq -r 'if .valid == 1 or .valid == true then "true" else "false" end' 2>/dev/null || echo "false")

if [[ "$SUBMIT_VALID" == "true" ]]; then
    pass "valid reviewer completion submitted under lease workflow_id"
else
    fail "valid reviewer completion submitted (got: $SUBMIT_OUT)"
    echo "FAIL: $TEST_NAME — cannot set up completion record"
    exit 1
fi

# Run post-task.sh with agent_type=reviewer and verify dispatch uses lease wf_id
HOOK_PAYLOAD=$(printf '{"hook_event_name":"SubagentStop","agent_type":"reviewer"}')
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

# Re-issue a fresh reviewer lease for check-reviewer.sh test
ISSUE_OUT2=$($CC lease issue-for-dispatch "reviewer" \
    --worktree-path "$TMP_GIT" \
    --workflow-id "$LEASE_WF_ID" \
    --allowed-ops '["routine_local"]' 2>/dev/null)
LEASE_ID2=$(printf '%s' "$ISSUE_OUT2" | jq -r '.lease.lease_id // empty' 2>/dev/null || true)

if [[ -n "$LEASE_ID2" ]]; then
    pass "second reviewer lease issued for check-reviewer.sh verification"
else
    fail "second reviewer lease issued"
fi

# Build a fake reviewer response with valid REVIEW_* trailers.
# REVIEW_FINDINGS_JSON must be a single-line JSON object (check-reviewer.sh
# parses it with grep -oE '^REVIEW_FINDINGS_JSON:[[:space:]]*\{.*\}').
FINDINGS_JSON=$(jq -nc '{findings: [{severity: "note", title: "ok", detail: "ok"}]}')
REVIEWER_RESPONSE="Review complete.
REVIEW_VERDICT: ready_for_guardian
REVIEW_HEAD_SHA: deadbeef
REVIEW_FINDINGS_JSON: $FINDINGS_JSON"

CR_PAYLOAD=$(jq -n \
    --arg r "$REVIEWER_RESPONSE" \
    --arg at "reviewer" \
    '{agent_type: $at, last_assistant_message: $r}')

# Run check-reviewer.sh
CR_OUTPUT=$(printf '%s' "$CR_PAYLOAD" \
    | CLAUDE_PROJECT_DIR="$TMP_GIT" CLAUDE_POLICY_DB="$TEST_DB" "$CHECK_REVIEWER_HOOK" 2>/dev/null || true)

echo "  [debug] check-reviewer output: $CR_OUTPUT"

# Verify a completion record was written for lease LEASE_ID2 under the LEASE
# workflow_id (not the branch-derived id). This is the WS1 invariant for the
# reviewer path: check-reviewer.sh MUST resolve identity via lease_context(),
# so the persisted completion_record.workflow_id equals the lease's wf_id.
COMP_JSON=$($CC completion latest --lease-id "$LEASE_ID2" 2>/dev/null || echo '{"found":false}')
COMP_FOUND=$(printf '%s' "$COMP_JSON" | jq -r '.found // false' 2>/dev/null || echo "false")
COMP_ROLE=$(printf '%s' "$COMP_JSON" | jq -r '.role // "none"' 2>/dev/null || echo "none")
COMP_WF=$(printf '%s' "$COMP_JSON" | jq -r '.workflow_id // "none"' 2>/dev/null || echo "none")
COMP_VALID=$(printf '%s' "$COMP_JSON" | jq -r 'if .valid == 1 or .valid == true then "true" else "false" end' 2>/dev/null || echo "false")

if [[ "$COMP_FOUND" == "true" && "$COMP_ROLE" == "reviewer" && "$COMP_WF" == "$LEASE_WF_ID" && "$COMP_VALID" == "true" ]]; then
    pass "completion record persisted under lease workflow_id ($LEASE_WF_ID) with role=reviewer, valid=true"
else
    fail "completion record persisted under lease workflow_id — got found=$COMP_FOUND role=$COMP_ROLE workflow_id=$COMP_WF valid=$COMP_VALID"
fi

# Verify no completion record was written under the BRANCH-DERIVED workflow_id
COMP_JSON_BRANCH=$($CC completion latest --workflow-id "$BRANCH_DERIVED_WF" 2>/dev/null || echo '{"found":false}')
COMP_FOUND_BRANCH=$(printf '%s' "$COMP_JSON_BRANCH" | jq -r '.found // false' 2>/dev/null || echo "false")
if [[ "$COMP_FOUND_BRANCH" != "true" ]]; then
    pass "no completion record written under branch-derived workflow_id ($BRANCH_DERIVED_WF)"
else
    COMP_BRANCH_ROLE=$(printf '%s' "$COMP_JSON_BRANCH" | jq -r '.role // "none"' 2>/dev/null || echo "none")
    fail "completion record must NOT be written under branch-derived id — got role=$COMP_BRANCH_ROLE for $BRANCH_DERIVED_WF"
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
