#!/usr/bin/env bash
# test-marker-lifecycle.sh: verifies that SubagentStop check-* hooks deactivate
# the active runtime marker whose role matches the stopping agent type.
#
# Production sequence exercised:
#   1. subagent-start.sh sets marker (agent-$$, role)
#   2. check-*.sh fires on SubagentStop — reads active marker, matches role,
#      calls rt_marker_deactivate to clear is_active
#   3. marker get-active returns found=false
#
# This is the compound-interaction test: it crosses subagent-start marker
# insertion → SQLite marker store → check-hook deactivation in the real
# order they fire in production.
#
# @decision DEC-MARKER-001
# @title SubagentStop marker deactivation lifecycle test
# @status accepted
# @rationale TKT-marker-lifecycle: SubagentStart sets markers with agent-$$
#   as ID. SubagentStop runs in a different PID so cannot match by $$. The
#   fix queries active marker by role and deactivates by stored agent_id.
#   This test validates that lifecycle end-to-end using real hooks and a
#   scoped test DB to avoid polluting shared state.
set -euo pipefail

TEST_NAME="test-marker-lifecycle"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/state.db"
RUNTIME_ROOT="${CLAUDE_RUNTIME_ROOT:-$HOME/.claude/runtime}"
CLI="$RUNTIME_ROOT/cli.py"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude"

# Minimal git repo so hooks can call detect_project_root
(cd "$TMP_DIR" && git init -q && git commit --allow-empty -m "init" -q)

# MASTER_PLAN.md so check-planner does not fail on missing-plan check
echo "# MASTER_PLAN.md" > "$TMP_DIR/MASTER_PLAN.md"

# Seed a .test-status so check-implementer/guardian pass test-status checks
echo "pass|0|$(date +%s)" > "$TMP_DIR/.claude/.test-status"

# Seed a proof-status so check-tester proof-state check is satisfied.
# workflow id is based on current branch — after git init the branch is
# typically "main" or "master"; write both to be portable.
echo "pending|$(date +%s)" > "$TMP_DIR/.claude/.proof-status-main"
echo "pending|$(date +%s)" > "$TMP_DIR/.claude/.proof-status-master"

# Pre-provision schema in scoped test DB
CLAUDE_POLICY_DB="$TEST_DB" python3 "$CLI" schema ensure >/dev/null 2>&1

FAILURES=0

# ---------------------------------------------------------------------------
# Helper: set a marker directly via CLI (simulates subagent-start.sh action)
# ---------------------------------------------------------------------------
set_marker() {
    local agent_id="$1" role="$2"
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$CLI" marker set "$agent_id" "$role" >/dev/null 2>&1
}

# Helper: deactivate a marker directly (cleanup between tests)
deactivate_marker() {
    local agent_id="$1"
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$CLI" marker deactivate "$agent_id" >/dev/null 2>&1 || true
}

# Helper: query active marker found field ("True" or "False")
get_active_found() {
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$CLI" marker get-active 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('found', False))" 2>/dev/null \
        || echo "False"
}

# Helper: query active marker role string
get_active_role() {
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$CLI" marker get-active 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('role',''))" 2>/dev/null \
        || echo ""
}

# Helper: run a check-* hook with a synthetic SubagentStop payload
run_check_hook() {
    local hook_name="$1" agent_type="$2"
    local payload
    payload=$(printf '{"hook_event_name":"SubagentStop","agent_type":"%s"}' "$agent_type")
    printf '%s' "$payload" \
        | CLAUDE_PROJECT_DIR="$TMP_DIR" \
          CLAUDE_POLICY_DB="$TEST_DB" \
          "$REPO_ROOT/hooks/${hook_name}" 2>/dev/null \
        || true
}

# ---------------------------------------------------------------------------
# Test 1: check-implementer deactivates implementer marker
# ---------------------------------------------------------------------------
set_marker "agent-test-impl" "implementer"

found_before=$(get_active_found)
if [[ "$found_before" != "True" ]]; then
    echo "  FAIL: [1] pre-condition: expected active implementer marker, got found=$found_before"
    FAILURES=$((FAILURES + 1))
fi

run_check_hook "check-implementer.sh" "implementer"

found_after=$(get_active_found)
if [[ "$found_after" != "False" ]]; then
    echo "  FAIL: [1] check-implementer did not deactivate marker (found=$found_after)"
    FAILURES=$((FAILURES + 1))
else
    echo "  PASS: [1] check-implementer deactivated implementer marker"
fi

# ---------------------------------------------------------------------------
# Test 2: check-tester deactivates tester marker
# ---------------------------------------------------------------------------
set_marker "agent-test-tstr" "tester"

found_before=$(get_active_found)
if [[ "$found_before" != "True" ]]; then
    echo "  FAIL: [2] pre-condition: expected active tester marker, got found=$found_before"
    FAILURES=$((FAILURES + 1))
fi

run_check_hook "check-tester.sh" "tester"

found_after=$(get_active_found)
if [[ "$found_after" != "False" ]]; then
    echo "  FAIL: [2] check-tester did not deactivate marker (found=$found_after)"
    FAILURES=$((FAILURES + 1))
else
    echo "  PASS: [2] check-tester deactivated tester marker"
fi

# ---------------------------------------------------------------------------
# Test 3: check-guardian deactivates guardian marker
# ---------------------------------------------------------------------------
set_marker "agent-test-grd" "guardian"

found_before=$(get_active_found)
if [[ "$found_before" != "True" ]]; then
    echo "  FAIL: [3] pre-condition: expected active guardian marker, got found=$found_before"
    FAILURES=$((FAILURES + 1))
fi

run_check_hook "check-guardian.sh" "guardian"

found_after=$(get_active_found)
if [[ "$found_after" != "False" ]]; then
    echo "  FAIL: [3] check-guardian did not deactivate marker (found=$found_after)"
    FAILURES=$((FAILURES + 1))
else
    echo "  PASS: [3] check-guardian deactivated guardian marker"
fi

# ---------------------------------------------------------------------------
# Test 4: check-planner deactivates planner marker
# ---------------------------------------------------------------------------
set_marker "agent-test-plnr" "planner"

found_before=$(get_active_found)
if [[ "$found_before" != "True" ]]; then
    echo "  FAIL: [4] pre-condition: expected active planner marker, got found=$found_before"
    FAILURES=$((FAILURES + 1))
fi

run_check_hook "check-planner.sh" "planner"

found_after=$(get_active_found)
if [[ "$found_after" != "False" ]]; then
    echo "  FAIL: [4] check-planner did not deactivate marker (found=$found_after)"
    FAILURES=$((FAILURES + 1))
else
    echo "  PASS: [4] check-planner deactivated planner marker"
fi

# ---------------------------------------------------------------------------
# Test 5: role mismatch — planner stop must NOT deactivate a guardian marker
# ---------------------------------------------------------------------------
set_marker "agent-test-mismatch" "guardian"

run_check_hook "check-planner.sh" "planner"

found_after=$(get_active_found)
role_after=$(get_active_role)
if [[ "$found_after" != "True" || "$role_after" != "guardian" ]]; then
    echo "  FAIL: [5] role mismatch — planner stop should leave guardian marker intact (found=$found_after role=$role_after)"
    FAILURES=$((FAILURES + 1))
else
    echo "  PASS: [5] role mismatch — planner stop leaves guardian marker intact"
fi

# Clean up dangling marker for test isolation
deactivate_marker "agent-test-mismatch"

# ---------------------------------------------------------------------------
# Test 6 (compound interaction): full spawn-style ID → stop lifecycle
# Simulates the real production sequence:
#   subagent-start.sh: rt_marker_set "agent-$$" "$AGENT_TYPE"
#   check-*.sh:        queries active, matches role, calls rt_marker_deactivate
# ---------------------------------------------------------------------------
FAKE_PID="99991"
set_marker "agent-${FAKE_PID}" "implementer"

found_before=$(get_active_found)
if [[ "$found_before" != "True" ]]; then
    echo "  FAIL: [6] compound pre-condition: expected active marker (found=$found_before)"
    FAILURES=$((FAILURES + 1))
fi

run_check_hook "check-implementer.sh" "implementer"

found_after=$(get_active_found)
if [[ "$found_after" != "False" ]]; then
    echo "  FAIL: [6] compound interaction — marker not deactivated after full lifecycle (found=$found_after)"
    FAILURES=$((FAILURES + 1))
else
    echo "  PASS: [6] compound interaction — spawn-style agent-PID lifecycle deactivated correctly"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
if [[ "$FAILURES" -gt 0 ]]; then
    echo "FAIL: $TEST_NAME — $FAILURES check(s) failed"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
