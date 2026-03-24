#!/usr/bin/env bash
# test-post-task.sh: feeds synthetic SubagentStop JSON payloads to post-task.sh
# and verifies dispatch suggestions and event recording.
#
# @decision DEC-DISPATCH-002
# @title Test canonical flow suggestions from post-task.sh
# @status accepted
# @rationale post-task.sh must emit the correct next-role suggestion for each
#   agent type in the canonical flow (planner→implementer→tester→guardian).
#   The guardian case must produce no suggestion (cycle complete). Events must
#   be recorded in SQLite for each completion. These tests exercise the actual
#   production sequence: synthetic hook JSON → post-task.sh → cc-policy SQLite
#   → verified db state.
set -euo pipefail

TEST_NAME="test-post-task"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/post-task.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/state.db"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR"

# Ensure the hook exists and is executable
if [[ ! -f "$HOOK" ]]; then
    echo "FAIL: $TEST_NAME — hooks/post-task.sh not found"
    exit 1
fi
chmod +x "$HOOK"

FAILURES=0

# -----------------------------------------------------------------------
# Helper: run post-task.sh with a given agent_type and return stdout
# -----------------------------------------------------------------------
run_hook() {
    local agent_type="$1"
    local payload
    payload=$(printf '{"hook_event_name":"SubagentStop","agent_type":"%s"}' "$agent_type")
    printf '%s' "$payload" \
        | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TEST_DB" "$HOOK" 2>/dev/null
}

# -----------------------------------------------------------------------
# Test 1: planner completion → suggests implementer
# -----------------------------------------------------------------------
output=$(run_hook "planner") || true
if ! echo "$output" | jq '.' >/dev/null 2>&1; then
    echo "  FAIL: planner — output is not valid JSON (got: $output)"
    FAILURES=$((FAILURES + 1))
else
    ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // empty')
    if [[ "$ctx" != *"implementer"* ]]; then
        echo "  FAIL: planner — expected 'implementer' in additionalContext, got: $ctx"
        FAILURES=$((FAILURES + 1))
    fi
fi

# -----------------------------------------------------------------------
# Test 2: implementer completion → suggests tester
# -----------------------------------------------------------------------
output=$(run_hook "implementer") || true
if ! echo "$output" | jq '.' >/dev/null 2>&1; then
    echo "  FAIL: implementer — output is not valid JSON (got: $output)"
    FAILURES=$((FAILURES + 1))
else
    ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // empty')
    if [[ "$ctx" != *"tester"* ]]; then
        echo "  FAIL: implementer — expected 'tester' in additionalContext, got: $ctx"
        FAILURES=$((FAILURES + 1))
    fi
fi

# -----------------------------------------------------------------------
# Test 3: tester completion → suggests guardian
# -----------------------------------------------------------------------
output=$(run_hook "tester") || true
if ! echo "$output" | jq '.' >/dev/null 2>&1; then
    echo "  FAIL: tester — output is not valid JSON (got: $output)"
    FAILURES=$((FAILURES + 1))
else
    ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // empty')
    if [[ "$ctx" != *"guardian"* ]]; then
        echo "  FAIL: tester — expected 'guardian' in additionalContext, got: $ctx"
        FAILURES=$((FAILURES + 1))
    fi
fi

# -----------------------------------------------------------------------
# Test 4: guardian completion → no suggestion (cycle complete, no JSON output)
# -----------------------------------------------------------------------
output=$(run_hook "guardian") || true
# guardian should produce no hookSpecificOutput JSON (empty stdout is correct)
if [[ -n "$output" ]]; then
    # If there is output, it must not contain a next-role suggestion
    ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)
    if [[ "$ctx" == *"dispatching"* ]]; then
        echo "  FAIL: guardian — should not suggest next dispatch, got: $ctx"
        FAILURES=$((FAILURES + 1))
    fi
fi

# -----------------------------------------------------------------------
# Test 5: unknown/empty agent_type → exits 0 with no output
# -----------------------------------------------------------------------
empty_output=$(printf '{"hook_event_name":"SubagentStop"}' \
    | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TEST_DB" "$HOOK" 2>/dev/null) || true
if [[ -n "$empty_output" ]]; then
    echo "  FAIL: empty agent_type — expected no output, got: $empty_output"
    FAILURES=$((FAILURES + 1))
fi

# -----------------------------------------------------------------------
# Test 6: event recording — after running planner, events table has an entry
# -----------------------------------------------------------------------
# Re-run planner so we can query the db
run_hook "planner" >/dev/null 2>&1 || true

RUNTIME_ROOT="${CLAUDE_RUNTIME_ROOT:-$HOME/.claude/runtime}"
if python3 "$RUNTIME_ROOT/cli.py" event query --type "agent_complete" 2>/dev/null \
    | jq -e '.count > 0' >/dev/null 2>&1; then
    # Great — but that queries the global db; use the test db instead
    :
fi

# Query test-scoped db directly
event_count=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    event query --type "agent_complete" 2>/dev/null \
    | jq -r '.count // 0' 2>/dev/null || echo "0")
if [[ "$event_count" -lt 1 ]]; then
    echo "  FAIL: events — expected at least 1 agent_complete event, got: $event_count"
    FAILURES=$((FAILURES + 1))
fi

# -----------------------------------------------------------------------
# Test 7: dispatch queue populated — after planner, implementer is queued
# -----------------------------------------------------------------------
queue_next=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    dispatch next 2>/dev/null \
    | jq -r '.role // empty' 2>/dev/null || echo "")
if [[ "$queue_next" != "implementer" ]]; then
    echo "  FAIL: dispatch queue — expected 'implementer' as next, got: '$queue_next'"
    FAILURES=$((FAILURES + 1))
fi

# -----------------------------------------------------------------------
# Results
# -----------------------------------------------------------------------
if [[ "$FAILURES" -gt 0 ]]; then
    echo "FAIL: $TEST_NAME — $FAILURES check(s) failed"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
