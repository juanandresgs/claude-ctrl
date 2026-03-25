#!/usr/bin/env bash
# test-full-lifecycle.sh — Simulates a complete planner->implementer->tester
# ->guardian dispatch cycle and verifies every enforcement point along the way.
#
# Production sequence exercised:
#   1. Setup: temp project with git repo and MASTER_PLAN.md
#   2. Planner phase:
#       - Set marker role=planner
#       - Source write: DENIED (planner cannot write source)
#       - Governance write (MASTER_PLAN.md): ALLOWED
#       - post-task.sh fired with agent_type=planner -> implementer enqueued
#   3. Implementer phase:
#       - Set marker role=implementer
#       - Source write: ALLOWED
#       - Governance write: DENIED
#       - post-task.sh fired with agent_type=implementer -> tester enqueued
#   4. Tester phase:
#       - Set marker role=tester
#       - Source write: DENIED
#       - post-task.sh fired with agent_type=tester -> guardian enqueued
#   5. Guardian phase:
#       - Set marker role=guardian
#       - Set proof=verified, test-status=pass
#       - Git op: ALLOWED
#       - post-task.sh fired with agent_type=guardian -> cycle complete
#   6. Verify dispatch queue progressed: planner->implementer->tester->guardian
#   7. Verify events recorded for each agent_complete
#   8. Cleanup
#
# @decision DEC-ACC-001
# @title Full lifecycle test exercises the complete dispatch cycle end-to-end
# @status accepted
# @rationale The production system is a state machine: planner->implementer->
#   tester->guardian. Unit tests and matrix tests verify individual cells.
#   The lifecycle test verifies the transitions: that each phase correctly
#   denies what it should, produces the right dispatch suggestion, and leaves
#   the runtime in the correct state for the next phase. This is the compound
#   interaction test that crosses all component boundaries.
#
# Usage:  bash tests/acceptance/test-full-lifecycle.sh
# Exit:   0 all pass, 1 any fail
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PRE_WRITE="$REPO_ROOT/hooks/pre-write.sh"
GUARD="$REPO_ROOT/hooks/guard.sh"
POST_TASK="$REPO_ROOT/hooks/post-task.sh"
CLI="$REPO_ROOT/runtime/cli.py"
TMP_DIR="$REPO_ROOT/tmp/lifecycle-$$"
TEST_DB="$TMP_DIR/state.db"

PASS=0
FAIL=0
FAILED_CASES=()

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude" "$TMP_DIR/src"

# ---------------------------------------------------------------------------
# Project setup: git repo on feature branch with MASTER_PLAN.md
# ---------------------------------------------------------------------------
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" checkout -b feature/lifecycle-test -q 2>/dev/null || true
git -C "$TMP_DIR" commit --allow-empty -m "init" -q
printf '# Plan\n## Status: in-progress\n' > "$TMP_DIR/MASTER_PLAN.md"
git -C "$TMP_DIR" add MASTER_PLAN.md
git -C "$TMP_DIR" commit -m "add plan" -q

WORKFLOW_ID="feature-lifecycle-test"

# cc-policy helper scoped to test DB
policy() {
    CLAUDE_POLICY_DB="$TEST_DB" PYTHONPATH="$REPO_ROOT" python3 "$CLI" "$@"
}

# Run hook with CLAUDE_PROJECT_DIR and CLAUDE_POLICY_DB scoped to temp project
run_pre_write() {
    local payload="$1"
    printf '%s' "$payload" \
        | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TEST_DB" \
          "$PRE_WRITE" 2>/dev/null || true
}

run_guard() {
    local payload="$1"
    printf '%s' "$payload" \
        | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TEST_DB" \
          "$GUARD" 2>/dev/null || true
}

run_post_task() {
    local agent_type="$1"
    printf '{"hook_event_name":"SubagentStop","agent_type":"%s"}' "$agent_type" \
        | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TEST_DB" \
          "$POST_TASK" 2>/dev/null || true
}

set_role() {
    # TKT-018: role detection is runtime-only; .subagent-tracker removed.
    # Deactivate any prior marker then set the new one, or deactivate all when
    # role is empty (simulates the no-role / orchestrator state).
    local role="$1"
    if [[ -n "$role" ]]; then
        policy marker set "agent-test" "$role" >/dev/null 2>&1
    else
        policy marker deactivate "agent-test" >/dev/null 2>&1 || true
    fi
}

assert_deny() {
    local label="$1" output="$2"
    local decision
    decision=$(printf '%s' "$output" \
        | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    if [[ "$decision" == "deny" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — expected deny, got "%s"\n' "$label" "$decision"
        FAIL=$(( FAIL + 1 )); FAILED_CASES+=("$label")
    fi
}

assert_allow() {
    local label="$1" output="$2"
    local decision
    decision=$(printf '%s' "$output" \
        | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    if [[ "$decision" == "deny" ]]; then
        local reason
        reason=$(printf '%s' "$output" \
            | jq -r '.hookSpecificOutput.permissionDecisionReason // "(none)"' 2>/dev/null)
        printf '  FAIL: %s — unexpected deny: %s\n' "$label" "$reason"
        FAIL=$(( FAIL + 1 )); FAILED_CASES+=("$label")
    else
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    fi
}

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — "%s" not found in output\n' "$label" "$needle"
        FAIL=$(( FAIL + 1 )); FAILED_CASES+=("$label")
    fi
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — expected "%s", got "%s"\n' "$label" "$expected" "$actual"
        FAIL=$(( FAIL + 1 )); FAILED_CASES+=("$label")
    fi
}

SOURCE_PAYLOAD=$(jq -n \
    --arg fp "$TMP_DIR/src/impl.py" \
    '{tool_name:"Write",tool_input:{file_path:$fp,content:"x=1"}}')
GOV_PAYLOAD=$(jq -n \
    --arg fp "$TMP_DIR/MASTER_PLAN.md" \
    '{tool_name:"Write",tool_input:{file_path:$fp,content:"# Plan v2"}}')
GIT_PAYLOAD=$(jq -n \
    --arg cmd "git commit --allow-empty -m lifecycle" \
    --arg cwd "$TMP_DIR" \
    '{tool_name:"Bash",tool_input:{command:$cmd},cwd:$cwd}')

# ---------------------------------------------------------------------------
# Phase 2: planner
# ---------------------------------------------------------------------------
printf '\n-- Phase: planner\n'
set_role "planner"

out=$(run_pre_write "$SOURCE_PAYLOAD")
assert_deny  "planner: source write denied"      "$out"

out=$(run_pre_write "$GOV_PAYLOAD")
assert_allow "planner: governance write allowed" "$out"

out=$(run_guard "$GIT_PAYLOAD")
assert_deny  "planner: git op denied"            "$out"

post=$(run_post_task "planner")
assert_contains "planner post-task: suggests implementer" "$post" "implementer"

# ---------------------------------------------------------------------------
# Phase 3: implementer
# ---------------------------------------------------------------------------
printf '\n-- Phase: implementer\n'
set_role "implementer"

out=$(run_pre_write "$SOURCE_PAYLOAD")
assert_allow "implementer: source write allowed"    "$out"

out=$(run_pre_write "$GOV_PAYLOAD")
assert_deny  "implementer: governance write denied" "$out"

out=$(run_guard "$GIT_PAYLOAD")
assert_deny  "implementer: git op denied"           "$out"

post=$(run_post_task "implementer")
assert_contains "implementer post-task: suggests tester" "$post" "tester"

# ---------------------------------------------------------------------------
# Phase 4: tester
# ---------------------------------------------------------------------------
printf '\n-- Phase: tester\n'
set_role "tester"

out=$(run_pre_write "$SOURCE_PAYLOAD")
assert_deny  "tester: source write denied"    "$out"

out=$(run_guard "$GIT_PAYLOAD")
assert_deny  "tester: git op denied"          "$out"

post=$(run_post_task "tester")
assert_contains "tester post-task: suggests guardian" "$post" "guardian"

# ---------------------------------------------------------------------------
# Phase 5: guardian — set all gates then allow git op
# ---------------------------------------------------------------------------
printf '\n-- Phase: guardian\n'
set_role "guardian"
printf 'pass|0|%s\n' "$(date +%s)" > "$TMP_DIR/.claude/.test-status"
printf 'verified|%s\n' "$(date +%s)" \
    > "$TMP_DIR/.claude/.proof-status-${WORKFLOW_ID}"

out=$(run_pre_write "$SOURCE_PAYLOAD")
assert_deny  "guardian: source write denied"           "$out"

out=$(run_guard "$GIT_PAYLOAD")
assert_allow "guardian: git op allowed (gates met)"    "$out"

post=$(run_post_task "guardian")
# Guardian should produce no next-dispatch suggestion (cycle complete)
if [[ -n "$post" ]]; then
    ctx=$(printf '%s' "$post" \
        | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)
    if [[ "$ctx" == *"dispatching"* ]]; then
        printf '  FAIL: guardian post-task: should not suggest next role\n'
        FAIL=$(( FAIL + 1 )); FAILED_CASES+=("guardian: no next suggestion")
    else
        printf '  PASS: guardian post-task: no dispatch suggestion\n'
        PASS=$(( PASS + 1 ))
    fi
else
    printf '  PASS: guardian post-task: no output (cycle complete)\n'
    PASS=$(( PASS + 1 ))
fi

# ---------------------------------------------------------------------------
# Phase 6: verify dispatch queue progression
# ---------------------------------------------------------------------------
printf '\n-- Verify dispatch queue and events\n'

# After running each post-task, the queue should have been populated.
# We ran planner->implementer->tester post-tasks, each enqueuing the next role.
# Queue: implementer (from planner) + tester (from implementer) + guardian (from tester)
queue_result=$(policy dispatch next)
next_role=$(printf '%s' "$queue_result" | jq -r '.role // empty')
assert_eq "dispatch queue: first item is implementer" "implementer" "$next_role"

# ---------------------------------------------------------------------------
# Phase 7: verify events recorded
# ---------------------------------------------------------------------------
events=$(policy event query --type "agent_complete")
event_count=$(printf '%s' "$events" | jq -r '.count // 0')
if [[ "$event_count" -ge 3 ]]; then
    printf '  PASS: events: %s agent_complete events recorded\n' "$event_count"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: events: expected >=3 agent_complete events, got %s\n' "$event_count"
    FAIL=$(( FAIL + 1 )); FAILED_CASES+=("events: agent_complete count")
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n=== test-full-lifecycle: %d passed, %d failed ===\n' "$PASS" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
    printf 'Failed cases:\n'
    for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
    printf '\nFAIL: test-full-lifecycle\n'
    exit 1
fi

printf 'PASS: test-full-lifecycle\n'
exit 0
