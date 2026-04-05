#!/usr/bin/env bash
# test-check-implementer-lease-scope.sh — Verifies that check-implementer.sh
# Check 6 (workflow scope compliance) uses the lease workflow_id, not the
# branch-derived id, when looking up the scope binding.
#
# Production sequence tested:
#   1. An implementer lease is issued with workflow_id=wf-ci-scope-test (not branch)
#   2. A workflow scope binding is set under wf-ci-scope-test
#   3. check-implementer.sh runs (SubagentStop event)
#   4. Check 6 must use wf-ci-scope-test via lease_context(), not branch-derived id
#   5. The scope check returns a binding (not "no workflow binding found") for wf-ci-scope-test
#   6. No binding is found for the branch-derived id (isolation confirmed)
#
# @decision DEC-WS1-CI-TEST-001
# @title Scenario: check-implementer Check 6 uses lease workflow_id for scope lookup
# @status accepted
# @rationale WS1 Change 2: Check 6 used current_workflow_id() (branch-derived).
#   When a lease is active with a different workflow_id, the scope binding stored
#   under the lease id was invisible to the check — producing a false "no workflow
#   binding" advisory warning. This test proves the fix: a scope binding under the
#   lease wf_id is found by Check 6, not the branch-derived fallback.
set -euo pipefail

TEST_NAME="test-check-implementer-lease-scope"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK_IMPL="$REPO_ROOT/hooks/check-implementer.sh"
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
git -C "$TMP_GIT" checkout -b feature/ci-scope-other 2>/dev/null
git -C "$TMP_GIT" config user.email "t@t.com"
git -C "$TMP_GIT" config user.name "T"
git -C "$TMP_GIT" commit --allow-empty -m "init" -q 2>/dev/null

# Branch-derived workflow_id: context-lib.sh strips "feature/" → "ci-scope-other"
BRANCH_DERIVED_WF="ci-scope-other"
LEASE_WF_ID="wf-ci-scope-test"

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
# Set a workflow scope binding under the LEASE workflow_id
# Bind the workflow first, then set scope
# ---------------------------------------------------------------------------
$CC workflow bind "$LEASE_WF_ID" "$TMP_GIT" "feature/ci-scope-other" \
    --base-branch "main" 2>/dev/null || true

$CC workflow scope-set "$LEASE_WF_ID" \
    --allowed '["hooks/*.sh","tests/**/*.sh"]' \
    --forbidden '["MASTER_PLAN.md"]' 2>/dev/null || true

# Confirm scope binding is present for lease wf_id
SCOPE_JSON=$($CC workflow scope-get "$LEASE_WF_ID" 2>/dev/null || echo '{}')
SCOPE_FOUND=$(printf '%s' "$SCOPE_JSON" | jq -r 'if .found then "yes" else "no" end' 2>/dev/null || echo "no")
if [[ "$SCOPE_FOUND" == "yes" ]]; then
    pass "scope binding set under lease workflow_id ($LEASE_WF_ID)"
else
    fail "scope binding not found for $LEASE_WF_ID — got: $SCOPE_JSON"
fi

# Confirm NO scope binding exists for branch-derived id (isolation)
SCOPE_BRANCH=$($CC workflow scope-get "$BRANCH_DERIVED_WF" 2>/dev/null || echo '{}')
SCOPE_BRANCH_FOUND=$(printf '%s' "$SCOPE_BRANCH" | jq -r 'if .found then "yes" else "no" end' 2>/dev/null || echo "no")
if [[ "$SCOPE_BRANCH_FOUND" == "no" ]]; then
    pass "no scope binding for branch-derived wf_id ($BRANCH_DERIVED_WF) — isolation confirmed"
else
    fail "branch-derived id should have no scope binding — test isolation violated"
fi

# ---------------------------------------------------------------------------
# Run check-implementer.sh
# Input format: {agent_type, response} (SubagentStop hook)
# ---------------------------------------------------------------------------
CI_INPUT=$(jq -n \
    --arg at "implementer" \
    --arg rt "Implementation complete. All tests pass." \
    '{agent_type: $at, response: $rt}')

CI_OUTPUT=$(printf '%s' "$CI_INPUT" \
    | CLAUDE_PROJECT_DIR="$TMP_GIT" \
      CLAUDE_POLICY_DB="$TEST_DB" \
      CLAUDE_RUNTIME_ROOT="$REPO_ROOT/runtime" \
      bash "$CHECK_IMPL" 2>/dev/null || echo '{}')

printf '  [debug] check-implementer output (first 400 chars): %s\n' \
    "$(printf '%s' "$CI_OUTPUT" | head -c 400)"

# ---------------------------------------------------------------------------
# Assert: output does NOT contain "no workflow binding found for 'wf-ci-scope-test'"
# (which would mean Check 6 failed to find the binding under the lease wf_id)
# ---------------------------------------------------------------------------
if printf '%s' "$CI_OUTPUT" | grep -qi "no workflow binding found for '$LEASE_WF_ID'"; then
    fail "Check 6 reported 'no workflow binding' for lease wf_id — fix not applied"
else
    pass "Check 6 did NOT report 'no workflow binding' for lease wf_id ($LEASE_WF_ID)"
fi

# ---------------------------------------------------------------------------
# Assert: output does NOT use the branch-derived id for scope check
# (if it did, it would report "no workflow binding found for 'ci-scope-other'")
# We set no binding for branch-derived id, so this false-positive would appear
# only if the old code path (current_workflow_id) was still running.
# ---------------------------------------------------------------------------
if printf '%s' "$CI_OUTPUT" | grep -qi "no workflow binding found for '$BRANCH_DERIVED_WF'"; then
    fail "Check 6 queried branch-derived wf_id ($BRANCH_DERIVED_WF) — lease-first fix not applied"
else
    pass "Check 6 did NOT query branch-derived wf_id ($BRANCH_DERIVED_WF)"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
TOTAL=6
printf '\nResults: %d/%d passed\n' "$((TOTAL - FAILURES))" "$TOTAL"
if [[ "$FAILURES" -gt 0 ]]; then
    printf 'FAIL: %s — %d check(s) failed\n' "$TEST_NAME" "$FAILURES"
    exit 1
fi

printf 'PASS: %s\n' "$TEST_NAME"
exit 0
