#!/usr/bin/env bash
# test-post-task.sh: feeds synthetic SubagentStop JSON payloads to post-task.sh
# and verifies dispatch suggestions and event recording.
#
# @decision DEC-DISPATCH-002
# @title Test canonical flow suggestions from post-task.sh
# @status accepted
# @rationale post-task.sh must emit the correct next-role suggestion for each
#   agent type in the canonical flow
#   (planner → guardian(provision) → implementer → reviewer → guardian(merge)).
#   The guardian case must produce no suggestion (cycle complete). Events must
#   be recorded in SQLite for each completion. These tests exercise the actual
#   production sequence: synthetic hook JSON → post-task.sh → cc-policy SQLite
#   → verified db state.
#
#   Phase 8 Slice 11 retired the legacy ``tester`` role. Test 3 now pins the
#   unknown-role silent-exit invariant (DEC-PHASE8-SLICE11-001): a stop event
#   carrying ``agent_type="tester"`` must not produce a PROCESS ERROR or any
#   routing suggestion — ``dispatch_engine._known_types`` excludes ``tester``
#   and ``process_agent_stop`` returns silently.
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

seed_planner_happy_path() {
    PYTHONPATH="$REPO_ROOT" python3 - "$TEST_DB" "$TMP_DIR" <<'PYEOF'
import sqlite3, sys
from runtime.core import completions, decision_work_registry as dwr, leases
from runtime.schemas import ensure_schema

db_path, project_root = sys.argv[1], sys.argv[2]
workflow_id = "wf-post-task-planner"

conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row
ensure_schema(conn)
dwr.insert_goal(
    conn,
    dwr.GoalRecord(
        goal_id=workflow_id,
        desired_end_state="Planner post-task test",
        status="active",
        autonomy_budget=5,
    ),
)
lease = leases.issue(
    conn,
    role="planner",
    workflow_id=workflow_id,
    worktree_path=project_root,
)
completions.submit(
    conn,
    lease_id=lease["lease_id"],
    workflow_id=workflow_id,
    role="planner",
    payload={"PLAN_VERDICT": "next_work_item", "PLAN_SUMMARY": "test"},
)
conn.close()
PYEOF
}

# -----------------------------------------------------------------------
# Test 1: planner completion → suggests guardian
# -----------------------------------------------------------------------
seed_planner_happy_path
output=$(run_hook "planner") || true
if ! echo "$output" | jq '.' >/dev/null 2>&1; then
    echo "  FAIL: planner — output is not valid JSON (got: $output)"
    FAILURES=$((FAILURES + 1))
else
    ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // empty')
    if [[ "$ctx" != *"guardian"* ]]; then
        echo "  FAIL: planner — expected 'guardian' in additionalContext, got: $ctx"
        FAILURES=$((FAILURES + 1))
    fi
fi

# -----------------------------------------------------------------------
# Test 2: implementer completion → suggests reviewer
# -----------------------------------------------------------------------
output=$(run_hook "implementer") || true
if ! echo "$output" | jq '.' >/dev/null 2>&1; then
    echo "  FAIL: implementer — output is not valid JSON (got: $output)"
    FAILURES=$((FAILURES + 1))
else
    ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // empty')
    if [[ "$ctx" != *"reviewer"* ]]; then
        echo "  FAIL: implementer — expected 'reviewer' in additionalContext, got: $ctx"
        FAILURES=$((FAILURES + 1))
    fi
fi

# -----------------------------------------------------------------------
# Test 3: retired tester agent_type → unknown-role silent exit
# (Phase 8 Slice 11 / DEC-PHASE8-SLICE11-001)
#
# Prior to Slice 11 this case asserted PROCESS ERROR when a tester stop
# arrived without an active lease. Slice 11 removed ``tester`` from
# ``dispatch_engine._known_types``, so the hook now returns silently: no
# PROCESS ERROR, no next-role suggestion, no additionalContext routing hint.
# post-task.sh is allowed to emit diagnostic chatter but must not claim a
# routing decision or error.
# -----------------------------------------------------------------------
output=$(run_hook "tester") || true
if ! echo "$output" | jq '.' >/dev/null 2>&1; then
    # Empty stdout is acceptable for unknown-role silent exit.
    if [[ -z "$output" ]]; then
        : # pass — silent exit
    else
        echo "  FAIL: tester (unknown role) — output is not valid JSON and not empty (got: $output)"
        FAILURES=$((FAILURES + 1))
    fi
else
    ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // empty')
    if [[ "$ctx" == *"PROCESS ERROR"* ]]; then
        echo "  FAIL: tester (unknown role) — must not emit PROCESS ERROR after Slice 11, got: $ctx"
        FAILURES=$((FAILURES + 1))
    fi
    if [[ "$ctx" == AUTO_DISPATCH:* ]]; then
        echo "  FAIL: tester (unknown role) — must not emit AUTO_DISPATCH routing, got: $ctx"
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
