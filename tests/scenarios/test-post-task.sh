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

# shellcheck disable=SC2329  # cleanup is invoked via trap EXIT
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
# Use CLAUDE_RUNTIME_ROOT to point at the worktree's cli.py so the
# 'completion route' subcommand (added in TKT-STAB-A2) is available.
# -----------------------------------------------------------------------
RUNTIME_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runtime"
run_hook() {
    local agent_type="$1"
    local payload
    payload=$(printf '{"hook_event_name":"SubagentStop","agent_type":"%s"}' "$agent_type")
    printf '%s' "$payload" \
        | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TEST_DB" \
          CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" "$HOOK" 2>/dev/null
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
# Test 3: tester completion with NO active lease → PROCESS ERROR (TKT-STAB-A2)
# The eval_state fallback has been removed. A tester without a lease must
# produce a PROCESS ERROR, not silently route to guardian.
# -----------------------------------------------------------------------
output=$(run_hook "tester") || true
if ! echo "$output" | jq '.' >/dev/null 2>&1; then
    echo "  FAIL: tester (no lease) — output is not valid JSON (got: $output)"
    FAILURES=$((FAILURES + 1))
else
    ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // empty')
    if [[ "$ctx" != *"PROCESS ERROR"* ]]; then
        echo "  FAIL: tester (no lease) — expected PROCESS ERROR in additionalContext, got: $ctx"
        FAILURES=$((FAILURES + 1))
    fi
fi

# -----------------------------------------------------------------------
# Test 4: guardian completion with NO active lease → PROCESS ERROR (TKT-STAB-A2)
# -----------------------------------------------------------------------
output=$(run_hook "guardian") || true
if ! echo "$output" | jq '.' >/dev/null 2>&1; then
    echo "  FAIL: guardian (no lease) — output is not valid JSON (got: $output)"
    FAILURES=$((FAILURES + 1))
else
    ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)
    if [[ "$ctx" != *"PROCESS ERROR"* ]]; then
        echo "  FAIL: guardian (no lease) — expected PROCESS ERROR, got: $ctx"
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

# RUNTIME_ROOT already set above in run_hook block; use the worktree's cli.py.
# Query test-scoped db directly.
#
# NOTE (DEC-STOP-ASSESS-002): Synthetic planner completions in this test do not
# run check-implementer.sh, so no stop_assessment events are written to the DB.
# dispatch_engine._detect_interrupted finds no matching event and emits
# agent_complete (not agent_stopped). The assertion below remains correct
# after the stop-assessment gate was introduced.
event_count=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    event query --type "agent_complete" 2>/dev/null \
    | jq -r '.count // 0' 2>/dev/null || echo "0")
if [[ "$event_count" -lt 1 ]]; then
    echo "  FAIL: events — expected at least 1 agent_complete event, got: $event_count"
    FAILURES=$((FAILURES + 1))
fi

# -----------------------------------------------------------------------
# Test 7: dispatch queue is NOT populated — DEC-WS6-001 removed queue writes
# from the hot path. post-task.sh emits next-role via hookSpecificOutput
# (additionalContext), not via dispatch_queue enqueue. The queue must remain
# empty after a planner completion.
# -----------------------------------------------------------------------
queue_next=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    dispatch next 2>/dev/null \
    | jq -r '.role // empty' 2>/dev/null || echo "")
if [[ -n "$queue_next" ]]; then
    echo "  FAIL: dispatch queue — expected empty queue (DEC-WS6-001), got: '$queue_next'"
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
