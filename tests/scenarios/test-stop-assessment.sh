#!/usr/bin/env bash
# test-stop-assessment.sh — Real hook-chain test for the stop-assessment feature.
#
# Production sequence tested:
#   1. check-implementer.sh detects future-tense trailing signal (Check 7)
#      → emits stop_assessment event: "<agent_type>|<wf_id>|appears_interrupted|<reason>"
#   2. post-task.sh fires → cc-policy dispatch process-stop
#   3. dispatch_engine reads stop_assessment event within 30s window
#   4. dispatch_engine calls _resolve_stop_assessment_wf_id() to get the correlation key
#      (lease-first, branch-derived fallback — DEC-STOP-ASSESS-004)
#   5. Emits agent_stopped (not agent_complete) when detail prefix matches
#   6. Appends WARNING to suggestion (surfaces via hookSpecificOutput.additionalContext)
#
# Three cases:
#   A: No lease, feature branch — branch-derived workflow_id used on both sides
#   B: Active lease with workflow_id != branch name — lease workflow_id takes priority
#   C: Clean response (no interruption) — agent_complete emitted, no WARNING
#
# @decision DEC-STOP-ASSESS-003
# Title: Scenario test for stop-assessment gate exercises real hook chain
# Status: accepted
# Rationale: This is the compound-interaction test for the stop-assessment feature.
#   Previous version used synthetic event emit + /nonexistent project_root, which
#   bypassed the correlation key mismatch bug (DEC-STOP-ASSESS-004). The real hook
#   chain test catches that: check-implementer.sh runs with the same PROJECT_ROOT
#   as post-task.sh, so both sides resolve workflow_id from the same lease/branch
#   context. No mocks — all real SQLite state, real hook execution.
set -euo pipefail

TEST_NAME="test-stop-assessment"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK_DIR="$REPO_ROOT/hooks"
CHECK_IMPL="$HOOK_DIR/check-implementer.sh"
POST_TASK="$HOOK_DIR/post-task.sh"
RUNTIME_ROOT="$REPO_ROOT/runtime"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

# shellcheck disable=SC2329  # cleanup is invoked via trap EXIT
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR"

FAILURES=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

printf '=== %s ===\n' "$TEST_NAME"

# ---------------------------------------------------------------------------
# Verify required hooks exist
# ---------------------------------------------------------------------------
if [[ ! -f "$CHECK_IMPL" || ! -f "$POST_TASK" ]]; then
    printf 'FAIL: %s — check-implementer.sh or post-task.sh not found\n' "$TEST_NAME"
    exit 1
fi
chmod +x "$CHECK_IMPL" "$POST_TASK"

# ---------------------------------------------------------------------------
# Helper: run_hook_chain <tmp_git_dir> <test_db> <response_text>
#
# Runs the real check-implementer.sh then post-task.sh for agent_type=implementer
# against a temp git repo and temp DB. Returns the post-task.sh stdout.
#
# check-implementer.sh writes stop_assessment to DB (if interrupted).
# post-task.sh reads from DB via dispatch process-stop and emits agent_stopped
# or agent_complete.
# ---------------------------------------------------------------------------
run_hook_chain() {
    local git_dir="$1"
    local test_db="$2"
    local response_text="$3"

    # Input JSON for check-implementer.sh: agent_type + response text
    local check_input
    check_input=$(jq -n \
        --arg at "implementer" \
        --arg rt "$response_text" \
        '{agent_type: $at, response: $rt}')

    # Run check-implementer.sh — writes stop_assessment event if interrupted.
    # We don't assert on its output directly; the event it writes is what matters.
    printf '%s' "$check_input" \
        | CLAUDE_PROJECT_DIR="$git_dir" \
          CLAUDE_POLICY_DB="$test_db" \
          CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" \
          "$CHECK_IMPL" >/dev/null 2>&1 || true

    # Input JSON for post-task.sh: agent_type only (project_root resolved from env)
    local post_input
    post_input=$(printf '{"hook_event_name":"SubagentStop","agent_type":"implementer"}')

    # Run post-task.sh — calls dispatch process-stop which reads stop_assessment.
    local post_out
    post_out=$(printf '%s' "$post_input" \
        | CLAUDE_PROJECT_DIR="$git_dir" \
          CLAUDE_POLICY_DB="$test_db" \
          CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" \
          "$POST_TASK" 2>/dev/null || echo '{}')

    printf '%s' "$post_out"
}

# ---------------------------------------------------------------------------
# Helper: count events of a given type in a DB
# ---------------------------------------------------------------------------
count_events() {
    local test_db="$1"
    local event_type="$2"
    CLAUDE_POLICY_DB="$test_db" python3 "$RUNTIME_ROOT/cli.py" \
        event query --type "$event_type" 2>/dev/null \
        | jq -r '.count // 0' 2>/dev/null || echo "0"
}

# Interrupted response: future-tense tail, no test completion evidence.
# Contains "Let me check..." in the trailing ~500 chars.
INTERRUPTED_RESPONSE="I have reviewed the task requirements.
Let me check the existing implementation to understand the current state."

# Clean response: test evidence present, no future-tense trailing signal.
CLEAN_RESPONSE="Implementation complete.
PASS: 5 tests passed. All checks green. Ready for tester review."

# ===========================================================================
# Case A: No lease, feature branch — branch-derived workflow_id on both sides
# ===========================================================================
printf '\n-- Case A: no lease, feature branch (branch-derived wf_id) --\n'

CASE_A_DIR="$TMP_DIR/case-a-git"
CASE_A_DB="$TMP_DIR/case-a.db"
mkdir -p "$CASE_A_DIR"

# Set up minimal git repo on a feature branch.
git -C "$CASE_A_DIR" init -q 2>/dev/null
git -C "$CASE_A_DIR" checkout -b feature/stop-assess-test-a -q 2>/dev/null || true
git -C "$CASE_A_DIR" config user.email "test@test.com" 2>/dev/null
git -C "$CASE_A_DIR" config user.name "Test" 2>/dev/null

# Bootstrap DB schema.
CLAUDE_POLICY_DB="$CASE_A_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1

# Run the real hook chain with the interrupted response.
CASE_A_OUT=$(run_hook_chain "$CASE_A_DIR" "$CASE_A_DB" "$INTERRUPTED_RESPONSE")

# Assert: stop_assessment event was emitted by check-implementer.sh
ASSESS_COUNT=$(count_events "$CASE_A_DB" "stop_assessment")
if [[ "$ASSESS_COUNT" -ge 1 ]]; then
    pass "Case A: stop_assessment event emitted by check-implementer (count=$ASSESS_COUNT)"
else
    fail "Case A: stop_assessment event emitted — expected >=1, got $ASSESS_COUNT"
fi

# Assert: agent_stopped event emitted (dispatch_engine matched the assessment)
STOPPED_COUNT=$(count_events "$CASE_A_DB" "agent_stopped")
if [[ "$STOPPED_COUNT" -ge 1 ]]; then
    pass "Case A: agent_stopped event recorded (count=$STOPPED_COUNT)"
else
    fail "Case A: agent_stopped event recorded — expected >=1, got $STOPPED_COUNT"
fi

# Assert: agent_complete NOT emitted (interrupted path)
COMPLETE_COUNT=$(count_events "$CASE_A_DB" "agent_complete")
if [[ "$COMPLETE_COUNT" -eq 0 ]]; then
    pass "Case A: agent_complete NOT emitted (count=0)"
else
    fail "Case A: agent_complete NOT emitted — expected 0, got $COMPLETE_COUNT"
fi

# Assert: WARNING in suggestion (from additionalContext)
CASE_A_SUGGESTION=$(printf '%s' "$CASE_A_OUT" \
    | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)
if [[ "$CASE_A_SUGGESTION" == *"WARNING: Agent appears interrupted"* ]]; then
    pass "Case A: WARNING present in suggestion"
else
    fail "Case A: WARNING present in suggestion (got: $CASE_A_SUGGESTION)"
fi

# ===========================================================================
# Case B: Active lease with workflow_id different from branch name.
# Lease workflow_id must take priority over branch-derived id on both sides.
# ===========================================================================
printf '\n-- Case B: active lease (lease wf_id != branch name) --\n'

CASE_B_DIR="$TMP_DIR/case-b-git"
CASE_B_DB="$TMP_DIR/case-b.db"
mkdir -p "$CASE_B_DIR"

# Set up git repo on a branch whose sanitized name != lease workflow_id.
git -C "$CASE_B_DIR" init -q 2>/dev/null
git -C "$CASE_B_DIR" checkout -b feature/some-other-branch -q 2>/dev/null || true
git -C "$CASE_B_DIR" config user.email "test@test.com" 2>/dev/null
git -C "$CASE_B_DIR" config user.name "Test" 2>/dev/null
# Create an initial commit so HEAD is valid.
git -C "$CASE_B_DIR" commit --allow-empty -m "init" -q 2>/dev/null || true

# Bootstrap DB schema.
CLAUDE_POLICY_DB="$CASE_B_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1

# Issue an active lease with a distinct workflow_id.
# worktree_path must match PROJECT_ROOT (= CLAUDE_PROJECT_DIR = CASE_B_DIR)
# so lease_context() / leases.get_current(worktree_path=) finds it.
LEASE_OUT=$(CLAUDE_POLICY_DB="$CASE_B_DB" python3 "$RUNTIME_ROOT/cli.py" \
    lease issue-for-dispatch implementer \
    --workflow-id "wf-lease-test" \
    --worktree-path "$CASE_B_DIR" \
    --branch "feature/some-other-branch" \
    --no-eval \
    2>/dev/null || echo '{}')
LEASE_ID=$(printf '%s' "$LEASE_OUT" | jq -r '.lease.lease_id // .lease_id // empty' 2>/dev/null || true)

if [[ -n "$LEASE_ID" ]]; then
    pass "Case B: active lease issued (id=$LEASE_ID, workflow_id=wf-lease-test)"
else
    fail "Case B: active lease issued — cannot proceed without lease"
    printf 'FAIL: %s — cannot issue lease for Case B\n' "$TEST_NAME"
    exit 1
fi

# Run the real hook chain with the interrupted response.
CASE_B_OUT=$(run_hook_chain "$CASE_B_DIR" "$CASE_B_DB" "$INTERRUPTED_RESPONSE")

# Assert: stop_assessment event emitted
ASSESS_B_COUNT=$(count_events "$CASE_B_DB" "stop_assessment")
if [[ "$ASSESS_B_COUNT" -ge 1 ]]; then
    pass "Case B: stop_assessment event emitted (count=$ASSESS_B_COUNT)"
else
    fail "Case B: stop_assessment event emitted — expected >=1, got $ASSESS_B_COUNT"
fi

# Assert: the stop_assessment detail uses wf-lease-test (not branch-derived id).
# This is the key regression check for DEC-STOP-ASSESS-004.
ASSESS_DETAIL=$(CLAUDE_POLICY_DB="$CASE_B_DB" python3 "$RUNTIME_ROOT/cli.py" \
    event query --type "stop_assessment" 2>/dev/null \
    | jq -r '.items[0].detail // empty' 2>/dev/null || true)
if [[ "$ASSESS_DETAIL" == "implementer|wf-lease-test|appears_interrupted|"* ]]; then
    pass "Case B: stop_assessment detail uses lease workflow_id (wf-lease-test)"
else
    fail "Case B: stop_assessment detail uses lease workflow_id — expected prefix 'implementer|wf-lease-test|appears_interrupted|', got: '$ASSESS_DETAIL'"
fi

# Assert: agent_stopped event emitted (dispatch_engine matched on wf-lease-test)
STOPPED_B_COUNT=$(count_events "$CASE_B_DB" "agent_stopped")
if [[ "$STOPPED_B_COUNT" -ge 1 ]]; then
    pass "Case B: agent_stopped event recorded (count=$STOPPED_B_COUNT)"
else
    fail "Case B: agent_stopped event recorded — expected >=1, got $STOPPED_B_COUNT"
fi

# Assert: agent_complete NOT emitted
COMPLETE_B_COUNT=$(count_events "$CASE_B_DB" "agent_complete")
if [[ "$COMPLETE_B_COUNT" -eq 0 ]]; then
    pass "Case B: agent_complete NOT emitted (count=0)"
else
    fail "Case B: agent_complete NOT emitted — expected 0, got $COMPLETE_B_COUNT"
fi

# Assert: WARNING in suggestion
CASE_B_SUGGESTION=$(printf '%s' "$CASE_B_OUT" \
    | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)
if [[ "$CASE_B_SUGGESTION" == *"WARNING: Agent appears interrupted"* ]]; then
    pass "Case B: WARNING present in suggestion"
else
    fail "Case B: WARNING present in suggestion (got: $CASE_B_SUGGESTION)"
fi

# ===========================================================================
# Case C: Clean response (no interruption) → agent_complete, no WARNING
# ===========================================================================
printf '\n-- Case C: clean response (no interruption) --\n'

CASE_C_DIR="$TMP_DIR/case-c-git"
CASE_C_DB="$TMP_DIR/case-c.db"
mkdir -p "$CASE_C_DIR"

git -C "$CASE_C_DIR" init -q 2>/dev/null
git -C "$CASE_C_DIR" checkout -b feature/stop-assess-test-c -q 2>/dev/null || true
git -C "$CASE_C_DIR" config user.email "test@test.com" 2>/dev/null
git -C "$CASE_C_DIR" config user.name "Test" 2>/dev/null

CLAUDE_POLICY_DB="$CASE_C_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1

CASE_C_OUT=$(run_hook_chain "$CASE_C_DIR" "$CASE_C_DB" "$CLEAN_RESPONSE")

# Assert: no stop_assessment event emitted (clean response, no future-tense signal)
ASSESS_C_COUNT=$(count_events "$CASE_C_DB" "stop_assessment")
if [[ "$ASSESS_C_COUNT" -eq 0 ]]; then
    pass "Case C: no stop_assessment event emitted (count=0)"
else
    fail "Case C: no stop_assessment event emitted — expected 0, got $ASSESS_C_COUNT"
fi

# Assert: agent_complete emitted (not agent_stopped)
COMPLETE_C_COUNT=$(count_events "$CASE_C_DB" "agent_complete")
if [[ "$COMPLETE_C_COUNT" -ge 1 ]]; then
    pass "Case C: agent_complete emitted on clean stop (count=$COMPLETE_C_COUNT)"
else
    fail "Case C: agent_complete emitted — expected >=1, got $COMPLETE_C_COUNT"
fi

# Assert: agent_stopped NOT emitted
STOPPED_C_COUNT=$(count_events "$CASE_C_DB" "agent_stopped")
if [[ "$STOPPED_C_COUNT" -eq 0 ]]; then
    pass "Case C: agent_stopped NOT emitted (count=0)"
else
    fail "Case C: agent_stopped NOT emitted — expected 0, got $STOPPED_C_COUNT"
fi

# Assert: no WARNING in suggestion on clean stop
CASE_C_SUGGESTION=$(printf '%s' "$CASE_C_OUT" \
    | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)
if [[ "$CASE_C_SUGGESTION" != *"WARNING: Agent appears interrupted"* ]]; then
    pass "Case C: no WARNING in suggestion"
else
    fail "Case C: no WARNING in suggestion (got: $CASE_C_SUGGESTION)"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
printf '\n'
if [[ "$FAILURES" -gt 0 ]]; then
    printf 'FAIL: %s — %d check(s) failed\n' "$TEST_NAME" "$FAILURES"
    exit 1
fi

printf 'PASS: %s\n' "$TEST_NAME"
exit 0
