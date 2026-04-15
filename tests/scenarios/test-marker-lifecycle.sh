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
CLI="$REPO_ROOT/runtime/cli.py"

# shellcheck disable=SC2329  # invoked via trap EXIT
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude"

# Minimal git repo so hooks can call detect_project_root
(cd "$TMP_DIR" && git init -q && git commit --allow-empty -m "init" -q)

# MASTER_PLAN.md so check-planner does not fail on missing-plan check
echo "# MASTER_PLAN.md" > "$TMP_DIR/MASTER_PLAN.md"

# Seed test-state via runtime so check-implementer/guardian pass test-status checks
CLAUDE_POLICY_DB="$TEST_DB" python3 "$CLI" \
    test-state set pass --project-root "$TMP_DIR" --passed 1 --total 1 >/dev/null 2>&1

# Pre-provision schema in scoped test DB
CLAUDE_POLICY_DB="$TEST_DB" python3 "$CLI" schema ensure >/dev/null 2>&1

# Phase 8 Slice 10 retired the tester stop hook and its proof-state dependency.
# Reviewer/implementer/guardian/planner stop hooks no longer consult proof state
# for marker deactivation, so no seeding is required here.

FAILURES=0

# ---------------------------------------------------------------------------
# Helper: set a marker directly via CLI (simulates subagent-start.sh action)
# ---------------------------------------------------------------------------
set_marker() {
    local agent_id="$1" role="$2"
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$CLI" \
        marker set "$agent_id" "$role" --project-root "$TMP_DIR" >/dev/null 2>&1
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
# Test 2: check-reviewer deactivates reviewer marker
# (Phase 8 Slice 11 retired ``tester``; the reviewer is the live read-only
# evaluator after Slice 11, so the SubagentStop deactivation lifecycle is
# proven against its hook. DEC-PHASE8-SLICE11-001.)
# ---------------------------------------------------------------------------
set_marker "agent-test-rvw" "reviewer"

found_before=$(get_active_found)
if [[ "$found_before" != "True" ]]; then
    echo "  FAIL: [2] pre-condition: expected active reviewer marker, got found=$found_before"
    FAILURES=$((FAILURES + 1))
fi

run_check_hook "check-reviewer.sh" "reviewer"

found_after=$(get_active_found)
if [[ "$found_after" != "False" ]]; then
    echo "  FAIL: [2] check-reviewer did not deactivate marker (found=$found_after)"
    FAILURES=$((FAILURES + 1))
else
    echo "  PASS: [2] check-reviewer deactivated reviewer marker"
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
# Test 7 (W-CONV-2): scoped marker — project_root filtering
# Simulates two markers from different projects; scoped query must return only
# the one that matches the requested project_root.
# ---------------------------------------------------------------------------
PROJ_A="$TMP_DIR/project-a"
PROJ_B="$TMP_DIR/project-b"
# Export variables needed by the inline Python heredoc subprocess calls below.
export CLI TEST_DB PROJ_A PROJ_B

# Write two markers with different project roots
CLAUDE_POLICY_DB="$TEST_DB" python3 "$CLI" marker set \
    "agent-scoped-a" "reviewer" \
    --project-root "$PROJ_A" \
    >/dev/null 2>&1

CLAUDE_POLICY_DB="$TEST_DB" python3 "$CLI" marker set \
    "agent-scoped-b" "implementer" \
    --project-root "$PROJ_B" \
    >/dev/null 2>&1

# Unscoped get-active should return the most recent (agent-scoped-b, assuming set
# ran in order and B is newer). We don't assert which one — just that something
# is active — to keep the test stable against sub-second timestamps.
unscoped_found=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$CLI" marker get-active 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('found', False))" 2>/dev/null \
    || echo "False")
if [[ "$unscoped_found" != "True" ]]; then
    echo "  FAIL: [7] scoped pre-condition: expected an active marker, got found=$unscoped_found"
    FAILURES=$((FAILURES + 1))
else
    echo "  PASS: [7] scoped pre-condition: at least one active marker present"
fi

# Verify scoped query returns the correct role for each project_root.
role_a=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$CLI" marker get-active --project-root "$PROJ_A" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('role',''))" 2>/dev/null \
    || echo "")
role_b=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$CLI" marker get-active --project-root "$PROJ_B" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('role',''))" 2>/dev/null \
    || echo "")

if [[ "$role_a" != "reviewer" || "$role_b" != "implementer" ]]; then
    echo "  FAIL: [7] scoped markers: expected reviewer/implementer by project_root, got A=$role_a B=$role_b"
    FAILURES=$((FAILURES + 1))
else
    echo "  PASS: [7] scoped markers: project_root-scoped get-active returns the correct role"
fi

# Clean up scoped markers
deactivate_marker "agent-scoped-a"
deactivate_marker "agent-scoped-b"

# ---------------------------------------------------------------------------
# Test 8 (W-CONV-2): Explore agent does NOT create a marker row
# Simulates subagent-start.sh spawning an Explore agent. The agent-start
# call must be skipped for lightweight roles, so the marker table row count
# must stay the same before and after the spawn simulation.
# ---------------------------------------------------------------------------
# Count current active markers
count_before=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$CLI" marker list 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('count', 0))" 2>/dev/null \
    || echo "0")

# Directly invoke the filtered agent-start path as subagent-start.sh would:
# for lightweight roles the hook skips the dispatch agent-start call entirely.
# We verify this by calling dispatch agent-start with a lightweight role and
# confirming nothing changed — the shell filter is tested via the hook itself,
# but here we confirm the CLI still writes the row so the ABSENCE of a call
# is what the shell test verifies. Instead, test via subagent-start.sh hook
# directly with agent_type=Explore and confirm no new marker is written.
EXPLORE_PAYLOAD='{"agent_type":"Explore","hook_event_name":"SubagentStart"}'
printf '%s' "$EXPLORE_PAYLOAD" \
    | CLAUDE_PROJECT_DIR="$TMP_DIR" \
      CLAUDE_POLICY_DB="$TEST_DB" \
      "$REPO_ROOT/hooks/subagent-start.sh" >/dev/null 2>&1 || true

count_after=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$CLI" marker list 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('count', 0))" 2>/dev/null \
    || echo "0")

if [[ "$count_after" -gt "$count_before" ]]; then
    echo "  FAIL: [8] Explore agent spawned a marker row (before=$count_before after=$count_after)"
    FAILURES=$((FAILURES + 1))
else
    echo "  PASS: [8] Explore agent spawn creates no marker row (count=$count_after)"
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
