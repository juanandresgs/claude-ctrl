#!/usr/bin/env bash
# test-track-lease-invalidation.sh — Verifies that track.sh uses the lease
# workflow_id (not the branch-derived id) when invalidating evaluation_state.
#
# Production sequence tested:
#   1. An implementer lease is issued with workflow_id=wf-track-test (not branch)
#   2. evaluation_state is set to ready_for_guardian under wf-track-test
#   3. track.sh fires with a source file write (PostToolUse:Edit)
#   4. track.sh must use wf-track-test (via lease_context), not the branch-derived id
#   5. eval_state for wf-track-test is invalidated to pending
#   6. eval_state for the branch-derived id is NOT touched
#
# @decision DEC-WS1-TRACK-TEST-001
# @title Scenario: track.sh uses lease workflow_id for eval invalidation
# @status accepted
# @rationale WS1 Change 1: track.sh was using current_workflow_id() which derives
#   from the branch name. When a lease is active with a different workflow_id, the
#   invalidation targeted the wrong key — leaving ready_for_guardian stale. This
#   test proves the fix by issuing a lease with wf-track-test and verifying that a
#   source write invalidates exactly that id, not the branch-derived id.
set -euo pipefail

TEST_NAME="test-track-lease-invalidation"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TRACK_HOOK="$REPO_ROOT/hooks/track.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/state.db"
TMP_GIT="$TMP_DIR/git-repo"

# shellcheck disable=SC2329
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
mkdir -p "$TMP_DIR" "$TMP_GIT"

CC="python3 $REPO_ROOT/runtime/cli.py"
export CLAUDE_POLICY_DB="$TEST_DB"
export CLAUDE_PROJECT_DIR="$TMP_GIT"
export CLAUDE_RUNTIME_ROOT="$REPO_ROOT/runtime"

FAILURES=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

printf '=== %s ===\n' "$TEST_NAME"

# ---------------------------------------------------------------------------
# Setup: minimal git repo on a branch whose name differs from the lease wf_id
# ---------------------------------------------------------------------------
git -C "$TMP_GIT" init -q 2>/dev/null
git -C "$TMP_GIT" checkout -b feature/track-other-branch 2>/dev/null
git -C "$TMP_GIT" config user.email "t@t.com"
git -C "$TMP_GIT" config user.name "T"
git -C "$TMP_GIT" commit --allow-empty -m "init" -q 2>/dev/null

# Branch-derived workflow_id: slashes → dashes, no "feature/" prefix stripping
# context-lib.sh current_workflow_id strips "feature/" prefix → "track-other-branch"
BRANCH_DERIVED_WF="track-other-branch"
LEASE_WF_ID="wf-track-test"

printf '  [setup] branch-derived wf_id: %s\n' "$BRANCH_DERIVED_WF"
printf '  [setup] lease wf_id: %s\n' "$LEASE_WF_ID"

if [[ "$BRANCH_DERIVED_WF" != "$LEASE_WF_ID" ]]; then
    pass "lease workflow_id differs from branch-derived (test isolation confirmed)"
else
    fail "IDs should differ — test setup invalid"
fi

# Bootstrap schema
$CC schema ensure >/dev/null 2>&1

# ---------------------------------------------------------------------------
# Issue an implementer lease with explicit workflow_id != branch
# ---------------------------------------------------------------------------
ISSUE_OUT=$($CC lease issue-for-dispatch "implementer" \
    --worktree-path "$TMP_GIT" \
    --workflow-id "$LEASE_WF_ID" \
    --allowed-ops '["routine_local"]' 2>/dev/null)
LEASE_ID=$(printf '%s' "$ISSUE_OUT" | jq -r '.lease.lease_id // empty' 2>/dev/null || true)

if [[ -n "$LEASE_ID" ]]; then
    pass "implementer lease issued with workflow_id=$LEASE_WF_ID (id=$LEASE_ID)"
else
    fail "implementer lease failed to issue — cannot proceed"
    printf 'FAIL: %s — cannot set up test fixtures\n' "$TEST_NAME"
    exit 1
fi

# ---------------------------------------------------------------------------
# Set evaluation_state = ready_for_guardian under the LEASE workflow_id
# ---------------------------------------------------------------------------
$CC evaluation set "$LEASE_WF_ID" ready_for_guardian --head-sha "deadbeef" >/dev/null 2>&1

EVAL_BEFORE=$($CC evaluation get "$LEASE_WF_ID" 2>/dev/null || echo '{}')
EVAL_STATUS_BEFORE=$(printf '%s' "$EVAL_BEFORE" | jq -r '.status // "not_found"' 2>/dev/null || echo "not_found")
if [[ "$EVAL_STATUS_BEFORE" == "ready_for_guardian" ]]; then
    pass "eval_state for $LEASE_WF_ID set to ready_for_guardian before hook fires"
else
    fail "eval_state setup failed — got $EVAL_STATUS_BEFORE"
    printf 'FAIL: %s — cannot set up eval state\n' "$TEST_NAME"
    exit 1
fi

# ---------------------------------------------------------------------------
# Create a real source file in the tracked git repo so track.sh sees it
# ---------------------------------------------------------------------------
SRC_FILE="$TMP_GIT/src/index.ts"
mkdir -p "$TMP_GIT/src"
printf 'export const x = 1;\n' > "$SRC_FILE"

# ---------------------------------------------------------------------------
# Simulate track.sh being called by PostToolUse:Edit hook
# Hook JSON format: {tool_input: {file_path: "<path>"}}
# ---------------------------------------------------------------------------
HOOK_JSON=$(jq -n --arg fp "$SRC_FILE" '{tool_input: {file_path: $fp}}')

TRACK_OUT=$(printf '%s' "$HOOK_JSON" \
    | CLAUDE_PROJECT_DIR="$TMP_GIT" \
      CLAUDE_POLICY_DB="$TEST_DB" \
      CLAUDE_RUNTIME_ROOT="$REPO_ROOT/runtime" \
      bash "$TRACK_HOOK" 2>/dev/null || true)

printf '  [debug] track.sh output: %s\n' "$TRACK_OUT"

# ---------------------------------------------------------------------------
# Assert: eval_state for LEASE workflow_id was invalidated → pending
# ---------------------------------------------------------------------------
EVAL_AFTER=$($CC evaluation get "$LEASE_WF_ID" 2>/dev/null || echo '{}')
EVAL_STATUS_AFTER=$(printf '%s' "$EVAL_AFTER" | jq -r '.status // "not_found"' 2>/dev/null || echo "not_found")

if [[ "$EVAL_STATUS_AFTER" == "pending" ]]; then
    pass "eval_state for lease wf_id ($LEASE_WF_ID) invalidated to pending after source write"
else
    fail "eval_state for lease wf_id should be pending — got $EVAL_STATUS_AFTER"
fi

# ---------------------------------------------------------------------------
# Assert: eval_state for BRANCH-DERIVED id was NOT touched
# ---------------------------------------------------------------------------
EVAL_BRANCH=$($CC evaluation get "$BRANCH_DERIVED_WF" 2>/dev/null || echo '{}')
EVAL_STATUS_BRANCH=$(printf '%s' "$EVAL_BRANCH" | jq -r '.status // "not_found"' 2>/dev/null || echo "not_found")

if [[ "$EVAL_STATUS_BRANCH" == "not_found" || "$EVAL_STATUS_BRANCH" == "idle" ]]; then
    pass "eval_state for branch-derived wf_id ($BRANCH_DERIVED_WF) was NOT touched"
else
    fail "eval_state for branch-derived id should be untouched — got $EVAL_STATUS_BRANCH"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
TOTAL=5
printf '\nResults: %d/%d passed\n' "$((TOTAL - FAILURES))" "$TOTAL"
if [[ "$FAILURES" -gt 0 ]]; then
    printf 'FAIL: %s — %d check(s) failed\n' "$TEST_NAME" "$FAILURES"
    exit 1
fi

printf 'PASS: %s\n' "$TEST_NAME"
exit 0
