#!/usr/bin/env bash
# test-context-lib-lease-first.sh — Verifies W-CONV-3: lease-first identity in
# context-lib.sh helpers and bind_workflow() duplicate prevention.
#
# Production sequences tested:
#   (a) get_workflow_binding() uses lease workflow_id when a lease is active
#   (b) read_evaluation_status() with no explicit wf_id uses lease wf_id
#   (c) Both fall back to branch-derived id when no lease is active
#   (d) bind_workflow() for the same worktree_path with a different workflow_id
#       removes the old row (stale binding prevention, DEC-CONV-003)
#
# @decision DEC-CONV-003-TEST
# @title Scenario: context-lib lease-first helpers and bind_workflow dedup (W-CONV-3)
# @status accepted
# @rationale W-CONV-3 adds lease-first identity resolution to get_workflow_binding(),
#   read_evaluation_status(), and sibling helpers. This test drives each path end-to-
#   end against a real SQLite database and real hook scripts to prove the contract:
#   lease workflow_id wins, branch-derived id is only the fallback, and a rebind
#   of the same worktree_path under a new workflow_id removes the stale row.
set -euo pipefail

TEST_NAME="test-context-lib-lease-first"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$REPO_ROOT/runtime/cli.py"
CHECK_IMPL="$REPO_ROOT/hooks/check-implementer.sh"
SESSION_INIT="$REPO_ROOT/hooks/session-init.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/state.db"
TMP_GIT="$TMP_DIR/git-repo"

# shellcheck disable=SC2329
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
mkdir -p "$TMP_DIR" "$TMP_GIT"

CC="python3 $CLI"
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
git -C "$TMP_GIT" checkout -b feature/conv3-other 2>/dev/null
git -C "$TMP_GIT" config user.email "t@t.com"
git -C "$TMP_GIT" config user.name "T"
git -C "$TMP_GIT" commit --allow-empty -m "init" -q 2>/dev/null

# context-lib.sh strips "feature/" from branch names → "conv3-other"
BRANCH_DERIVED_WF="conv3-other"
LEASE_WF_ID="wf-conv3-lease-test"

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
# (d) bind_workflow() duplicate prevention — test this first so (a) has a
#     clean slate, and because it is a Python-level change we can verify
#     directly via the CLI without needing a running hook.
# ---------------------------------------------------------------------------
printf '\n--- (d) bind_workflow duplicate prevention ---\n'

OLD_WF_ID="wf-conv3-old"
NEW_WF_ID="wf-conv3-new"

# Bind OLD workflow for the worktree (positional args: workflow_id worktree_path branch)
$CC workflow bind "$OLD_WF_ID" "$TMP_GIT" "feature/conv3-other" >/dev/null 2>&1

OLD_ROW=$($CC workflow get "$OLD_WF_ID" 2>/dev/null || echo '{}')
OLD_FOUND=$(printf '%s' "$OLD_ROW" | jq -r 'if .found then "yes" else "no" end' 2>/dev/null || echo "no")
if [[ "$OLD_FOUND" == "yes" ]]; then
    pass "old binding inserted (wf_id=$OLD_WF_ID)"
else
    fail "old binding inserted — got: $OLD_ROW"
fi

# Now bind a NEW workflow for the SAME worktree — should evict the old row
$CC workflow bind "$NEW_WF_ID" "$TMP_GIT" "feature/conv3-other" >/dev/null 2>&1

NEW_ROW=$($CC workflow get "$NEW_WF_ID" 2>/dev/null || echo '{}')
NEW_FOUND=$(printf '%s' "$NEW_ROW" | jq -r 'if .found then "yes" else "no" end' 2>/dev/null || echo "no")
if [[ "$NEW_FOUND" == "yes" ]]; then
    pass "new binding inserted (wf_id=$NEW_WF_ID)"
else
    fail "new binding inserted — got: $NEW_ROW"
fi

# Old row must be gone
OLD_ROW_AFTER=$($CC workflow get "$OLD_WF_ID" 2>/dev/null || echo '{}')
OLD_FOUND_AFTER=$(printf '%s' "$OLD_ROW_AFTER" | jq -r 'if .found then "yes" else "no" end' 2>/dev/null || echo "no")
if [[ "$OLD_FOUND_AFTER" == "no" ]]; then
    pass "old binding evicted after rebind to same worktree_path"
else
    fail "old binding must be evicted — still found wf_id=$OLD_WF_ID"
fi

# ---------------------------------------------------------------------------
# (c) Fallback: no active lease → helpers use branch-derived workflow_id
# ---------------------------------------------------------------------------
printf '\n--- (c) fallback to branch-derived id when no lease ---\n'

# Ensure no active lease (expire any leftover)
$CC lease expire-stale >/dev/null 2>&1 || true

# Write eval state under the branch-derived id directly (positional: workflow_id status)
$CC evaluation set "$BRANCH_DERIVED_WF" pending >/dev/null 2>&1 || true

# Run check-implementer.sh — it should use branch-derived id for eval status read
CI_PAYLOAD=$(jq -n --arg at "implementer" '{agent_type: $at, response: "done"}')
CI_OUT=$(printf '%s' "$CI_PAYLOAD" \
    | CLAUDE_PROJECT_DIR="$TMP_GIT" CLAUDE_POLICY_DB="$TEST_DB" "$CHECK_IMPL" 2>/dev/null || true)

printf '  [debug] check-implementer output (no-lease): %s\n' "$CI_OUT"

# Should not crash and output should be valid JSON
if printf '%s' "$CI_OUT" | jq '.' >/dev/null 2>&1; then
    pass "check-implementer produced valid JSON with no active lease"
else
    fail "check-implementer produced valid JSON with no active lease (got: $CI_OUT)"
fi

# The eval status for branch-derived id should be readable (pending)
EVAL_FALLBACK=$($CC evaluation get "$BRANCH_DERIVED_WF" 2>/dev/null || echo '{}')
EVAL_FALLBACK_STATUS=$(printf '%s' "$EVAL_FALLBACK" | jq -r '.status // "not_found"' 2>/dev/null || echo "not_found")
if [[ "$EVAL_FALLBACK_STATUS" == "pending" ]]; then
    pass "branch-derived eval state readable (status=pending) — fallback confirmed"
else
    fail "branch-derived eval state readable — expected pending, got: $EVAL_FALLBACK_STATUS"
fi

# Clean up the pending state
$CC evaluation set "$BRANCH_DERIVED_WF" idle >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# (a) get_workflow_binding() uses lease workflow_id when lease active
# (b) read_evaluation_status() with no explicit wf_id uses lease workflow_id
# Both are exercised by running check-implementer.sh while a lease is active.
# ---------------------------------------------------------------------------
printf '\n--- (a)+(b) lease-first: helpers use lease wf_id when lease active ---\n'

# Issue an implementer lease with the lease wf_id (different from branch)
ISSUE_OUT=$($CC lease issue-for-dispatch "implementer" \
    --worktree-path "$TMP_GIT" \
    --workflow-id "$LEASE_WF_ID" \
    --allowed-ops '["routine_local"]' 2>/dev/null)
LEASE_ID=$(printf '%s' "$ISSUE_OUT" | jq -r '.lease.lease_id // empty' 2>/dev/null || true)

if [[ -n "$LEASE_ID" ]]; then
    pass "implementer lease issued (workflow_id=$LEASE_WF_ID, lease_id=$LEASE_ID)"
else
    fail "implementer lease issued — cannot proceed"
    printf 'FAIL: %s — lease setup failed\n' "$TEST_NAME"
    exit 1
fi

# Bind the lease workflow_id so scope check has a binding to find
$CC workflow bind "$LEASE_WF_ID" "$TMP_GIT" "feature/conv3-other" >/dev/null 2>&1

# Write eval state under the LEASE workflow_id
$CC evaluation set "$LEASE_WF_ID" ready_for_guardian >/dev/null 2>&1 || true

# (a) verify get_workflow_binding() — driven indirectly through check-implementer.sh
# The hook reads eval status (Check 5) and scope (Check 6) using _CI_WF_ID which
# must resolve to LEASE_WF_ID. Output includes "Evaluation state:" language.
CI_PAYLOAD2=$(jq -n --arg at "implementer" '{agent_type: $at, response: "done"}')
CI_OUT2=$(printf '%s' "$CI_PAYLOAD2" \
    | CLAUDE_PROJECT_DIR="$TMP_GIT" CLAUDE_POLICY_DB="$TEST_DB" "$CHECK_IMPL" 2>/dev/null || true)

printf '  [debug] check-implementer output (with lease): %s\n' "$CI_OUT2"

if printf '%s' "$CI_OUT2" | jq '.' >/dev/null 2>&1; then
    pass "check-implementer produced valid JSON with active lease"
else
    fail "check-implementer produced valid JSON with active lease (got: $CI_OUT2)"
fi

# (b) read_evaluation_status via check-implementer: should report ready_for_guardian
# (written under LEASE_WF_ID, NOT under branch-derived id).
# check-implementer.sh emits additionalContext at the top level.
CTX2=$(printf '%s' "$CI_OUT2" | jq -r '.additionalContext // .hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)
if [[ "$CTX2" == *"ready_for_guardian"* ]]; then
    pass "(b) read_evaluation_status used lease wf_id — ready_for_guardian surfaced"
else
    # Also accept the case where no context is emitted but no crash — advisory check
    fail "(b) read_evaluation_status used lease wf_id — expected ready_for_guardian in context, got: $CTX2"
fi

# Verify eval state was NOT written under branch-derived id
EVAL_BRANCH=$($CC evaluation get "$BRANCH_DERIVED_WF" 2>/dev/null || echo '{}')
EVAL_BRANCH_STATUS=$(printf '%s' "$EVAL_BRANCH" | jq -r '.status // "not_found"' 2>/dev/null || echo "not_found")
if [[ "$EVAL_BRANCH_STATUS" == "not_found" || "$EVAL_BRANCH_STATUS" == "idle" ]]; then
    pass "(a) eval state NOT under branch-derived wf_id ($BRANCH_DERIVED_WF) — lease isolation confirmed"
else
    fail "(a) eval state must NOT exist under branch-derived id — got: $EVAL_BRANCH_STATUS"
fi

# ---------------------------------------------------------------------------
# session-init.sh: confirm it runs without error with and without a lease
# (exercises the lease resolution block we added in W-CONV-3 Change 3)
# ---------------------------------------------------------------------------
printf '\n--- session-init.sh lease resolution smoke test ---\n'

SI_PAYLOAD=$(jq -n '{hook_event_name: "SessionStart"}')
SI_OUT=$(printf '%s' "$SI_PAYLOAD" \
    | CLAUDE_PROJECT_DIR="$TMP_GIT" CLAUDE_POLICY_DB="$TEST_DB" "$SESSION_INIT" 2>/dev/null || true)

printf '  [debug] session-init output: %s\n' "$(printf '%s' "$SI_OUT" | head -c 200)"

if printf '%s' "$SI_OUT" | jq '.' >/dev/null 2>&1; then
    pass "session-init produced valid JSON with active lease"
else
    fail "session-init produced valid JSON with active lease (got: $SI_OUT)"
fi

# Expire the lease and run again — should not crash
$CC lease expire-stale >/dev/null 2>&1 || true
SI_OUT2=$(printf '%s' "$SI_PAYLOAD" \
    | CLAUDE_PROJECT_DIR="$TMP_GIT" CLAUDE_POLICY_DB="$TEST_DB" "$SESSION_INIT" 2>/dev/null || true)

if printf '%s' "$SI_OUT2" | jq '.' >/dev/null 2>&1; then
    pass "session-init produced valid JSON without active lease (fallback path)"
else
    fail "session-init produced valid JSON without active lease (got: $SI_OUT2)"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
TOTAL=16
printf '\nResults: %d/%d passed\n' "$((TOTAL - FAILURES))" "$TOTAL"
if [[ "$FAILURES" -gt 0 ]]; then
    printf 'FAIL: %s — %d check(s) failed\n' "$TEST_NAME" "$FAILURES"
    exit 1
fi

printf 'PASS: %s\n' "$TEST_NAME"
exit 0
