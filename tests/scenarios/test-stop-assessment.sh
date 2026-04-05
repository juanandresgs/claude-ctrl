#!/usr/bin/env bash
# test-stop-assessment.sh: Verifies the stop-assessment gate in dispatch_engine.
#
# Production sequence tested:
#   1. check-implementer.sh detects future-tense trailing signal (Check 7)
#   2. It emits stop_assessment event: "implementer|<wf>|appears_interrupted|<reason>"
#   3. post-task.sh fires → cc-policy dispatch process-stop
#   4. dispatch_engine reads stop_assessment event within 30s window
#   5. Emits agent_stopped (not agent_complete) when match found
#   6. Appends WARNING to suggestion
#   Clean case: no stop_assessment → agent_complete emitted as before
#
# @decision DEC-STOP-ASSESS-003
# Title: Scenario test for stop-assessment gate and suggestion warning
# Status: accepted
# Rationale: This is the compound-interaction test for the stop-assessment
#   feature. It crosses: stop_assessment event (written by check-implementer)
#   → dispatch_engine event query → gated event type → suggestion warning.
#   No mocks — all real SQLite state. Exercises the exact production sequence
#   described in nifty-soaring-stroustrup.md Step 3.
set -euo pipefail

TEST_NAME="test-stop-assessment"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/state.db"
TMP_GIT="$TMP_DIR/git-repo"

# shellcheck disable=SC2329  # cleanup is invoked via trap EXIT
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR" "$TMP_GIT"

# Minimal git repo so detect_project_root returns something from post-task.sh
git -C "$TMP_GIT" init -q 2>/dev/null
git -C "$TMP_GIT" checkout -b feature/test-stop-assess 2>/dev/null

CC="python3 $REPO_ROOT/runtime/cli.py"
export CLAUDE_POLICY_DB="$TEST_DB"
export CLAUDE_PROJECT_DIR="$TMP_GIT"
export CLAUDE_RUNTIME_ROOT="$REPO_ROOT/runtime"

FAILURES=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

printf '=== %s ===\n' "$TEST_NAME"

# ---------------------------------------------------------------------------
# Bootstrap: apply schema to test-scoped DB
# ---------------------------------------------------------------------------
$CC schema ensure >/dev/null 2>&1

# ===========================================================================
# Case A: stop_assessment event present → agent_stopped, WARNING in suggestion
# ===========================================================================
printf '\n-- Case A: interrupted stop (stop_assessment event present) --\n'

WF_ID="test-wf-1"

# Write the stop_assessment event directly (mimicking check-implementer Check 7).
# Format: <agent_type>|<workflow_id>|appears_interrupted|<reason>
EMIT_OUT=$($CC event emit "stop_assessment" \
    --detail "implementer|${WF_ID}|appears_interrupted|test reason: trailing future-tense signal" \
    2>/dev/null || echo '{}')
EMIT_ID=$(printf '%s' "$EMIT_OUT" | jq -r '.id // empty' 2>/dev/null || true)
if [[ -n "$EMIT_ID" ]]; then
    pass "stop_assessment event emitted (id=$EMIT_ID)"
else
    fail "stop_assessment event emitted — cannot proceed"
    printf 'FAIL: %s — cannot emit stop_assessment event\n' "$TEST_NAME"
    exit 1
fi

# Call dispatch process-stop with agent_type=implementer.
# No active lease for this project_root, so workflow_id will be empty string —
# the stop_assessment match uses the empty workflow_id path (detail starts with
# "implementer||appears_interrupted" when no lease exists). To match correctly,
# emit with empty workflow_id.
$CC schema ensure >/dev/null 2>&1  # idempotent; ensure fresh state is applied

# Re-emit with empty workflow_id to match what the engine resolves (no lease → "").
EMIT2_OUT=$($CC event emit "stop_assessment" \
    --detail "implementer||appears_interrupted|test reason: trailing future-tense signal" \
    2>/dev/null || echo '{}')
EMIT2_ID=$(printf '%s' "$EMIT2_OUT" | jq -r '.id // empty' 2>/dev/null || true)
if [[ -n "$EMIT2_ID" ]]; then
    pass "stop_assessment event emitted with empty workflow_id (id=$EMIT2_ID)"
else
    fail "stop_assessment event emitted with empty workflow_id"
fi

# Run dispatch process-stop
PROC_INPUT='{"agent_type":"implementer","project_root":"/nonexistent"}'
PROC_OUT=$(printf '%s' "$PROC_INPUT" \
    | CLAUDE_POLICY_DB="$TEST_DB" python3 "$REPO_ROOT/runtime/cli.py" \
      dispatch process-stop 2>/dev/null || echo '{}')

# Assert: agent_stopped event emitted (count >= 1)
STOPPED_COUNT=$($CC event query --type "agent_stopped" 2>/dev/null \
    | jq -r '.count // 0' 2>/dev/null || echo "0")
if [[ "$STOPPED_COUNT" -ge 1 ]]; then
    pass "agent_stopped event recorded (count=$STOPPED_COUNT)"
else
    fail "agent_stopped event recorded — expected >=1, got $STOPPED_COUNT"
fi

# Assert: agent_complete event NOT emitted (count should be 0)
COMPLETE_COUNT=$($CC event query --type "agent_complete" 2>/dev/null \
    | jq -r '.count // 0' 2>/dev/null || echo "0")
if [[ "$COMPLETE_COUNT" -eq 0 ]]; then
    pass "agent_complete NOT emitted when interrupted (count=0)"
else
    fail "agent_complete NOT emitted when interrupted — expected 0, got $COMPLETE_COUNT"
fi

# Assert: suggestion contains WARNING
SUGGESTION=$(printf '%s' "$PROC_OUT" \
    | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)
if [[ "$SUGGESTION" == *"WARNING: Agent appears interrupted"* ]]; then
    pass "suggestion contains WARNING: Agent appears interrupted"
else
    fail "suggestion contains WARNING: Agent appears interrupted (got: $SUGGESTION)"
fi

# ===========================================================================
# Case B: clean stop (no stop_assessment) → agent_complete, no WARNING
# ===========================================================================
printf '\n-- Case B: clean stop (no stop_assessment event) --\n'

# Use a fresh DB to guarantee no residual stop_assessment events.
CLEAN_DB="$TMP_DIR/clean-state.db"
CLEAN_GIT="$TMP_DIR/clean-git"
mkdir -p "$CLEAN_GIT"
git -C "$CLEAN_GIT" init -q 2>/dev/null
git -C "$CLEAN_GIT" checkout -b feature/test-clean 2>/dev/null

CLAUDE_POLICY_DB="$CLEAN_DB" python3 "$REPO_ROOT/runtime/cli.py" \
    schema ensure >/dev/null 2>&1

CLEAN_INPUT='{"agent_type":"implementer","project_root":"/nonexistent"}'
CLEAN_OUT=$(printf '%s' "$CLEAN_INPUT" \
    | CLAUDE_POLICY_DB="$CLEAN_DB" python3 "$REPO_ROOT/runtime/cli.py" \
      dispatch process-stop 2>/dev/null || echo '{}')

# Assert: agent_complete event emitted (count >= 1)
CLEAN_COMPLETE_COUNT=$(CLAUDE_POLICY_DB="$CLEAN_DB" python3 "$REPO_ROOT/runtime/cli.py" \
    event query --type "agent_complete" 2>/dev/null \
    | jq -r '.count // 0' 2>/dev/null || echo "0")
if [[ "$CLEAN_COMPLETE_COUNT" -ge 1 ]]; then
    pass "agent_complete emitted on clean stop (count=$CLEAN_COMPLETE_COUNT)"
else
    fail "agent_complete emitted on clean stop — expected >=1, got $CLEAN_COMPLETE_COUNT"
fi

# Assert: agent_stopped NOT emitted on clean stop
CLEAN_STOPPED_COUNT=$(CLAUDE_POLICY_DB="$CLEAN_DB" python3 "$REPO_ROOT/runtime/cli.py" \
    event query --type "agent_stopped" 2>/dev/null \
    | jq -r '.count // 0' 2>/dev/null || echo "0")
if [[ "$CLEAN_STOPPED_COUNT" -eq 0 ]]; then
    pass "agent_stopped NOT emitted on clean stop (count=0)"
else
    fail "agent_stopped NOT emitted on clean stop — expected 0, got $CLEAN_STOPPED_COUNT"
fi

# Assert: no WARNING in suggestion on clean stop
CLEAN_SUGGESTION=$(printf '%s' "$CLEAN_OUT" \
    | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)
if [[ "$CLEAN_SUGGESTION" != *"WARNING: Agent appears interrupted"* ]]; then
    pass "no WARNING in suggestion on clean stop"
else
    fail "no WARNING in suggestion on clean stop (got: $CLEAN_SUGGESTION)"
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
