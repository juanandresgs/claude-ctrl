#!/usr/bin/env bash
# Test suite for Issue #84 — Session-Aware Hooks (trajectory-based guidance)
#
# @decision DEC-V2-TRAJ-001
# @title Test suite for detect_approach_pivots and trajectory-aware guidance
# @status accepted
# @rationale Tests cover the three components of v2 Phase 3:
#   1. detect_approach_pivots() in context-lib.sh
#   2. Trajectory-aware test-gate.sh guidance on strike 2+
#   3. Enhanced session-summary.sh with trajectory narrative
#   Uses temp directories and mock event files for isolation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="${SCRIPT_DIR}/../hooks"
LOG_SH="${HOOKS_DIR}/log.sh"
CONTEXT_LIB="${HOOKS_DIR}/context-lib.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}PASS${NC} $1"
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}FAIL${NC} $1"
    if [[ -n "${2:-}" ]]; then
        echo -e "  ${YELLOW}Details:${NC} $2"
    fi
}

run_test() {
    TESTS_RUN=$((TESTS_RUN + 1))
}

# Create a temporary project directory with .claude subdirectory
make_temp_project() {
    local dir
    dir=$(mktemp -d)
    mkdir -p "$dir/.claude"
    echo "$dir"
}

# Write a sequence of JSONL events to the session events file
# Usage: write_events <project_dir> <<'EOF'
# {"ts":"...","event":"write","file":"foo.py","lines_changed":5}
# EOF
write_events() {
    local project_dir="$1"
    cat > "$project_dir/.claude/.session-events.jsonl"
}

# Helper: ISO8601 timestamp N seconds ago
ts_ago() {
    local seconds="${1:-0}"
    local now
    now=$(date +%s)
    local past=$(( now - seconds ))
    date -u -r "$past" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
        || date -u -d "@$past" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
        || echo "2026-02-17T10:00:00Z"
}

# ============================================================================
# Test 1: detect_approach_pivots finds edit->fail->edit patterns
# ============================================================================

test_detect_pivots_finds_patterns() {
    run_test
    local proj
    proj=$(make_temp_project)
    trap "rm -rf '$proj'" RETURN

    # Write a realistic edit->fail->edit->fail sequence on foo.py
    cat > "$proj/.claude/.session-events.jsonl" <<EOF
{"ts":"$(ts_ago 120)","event":"write","file":"$proj/foo.py","lines_changed":10}
{"ts":"$(ts_ago 110)","event":"test_run","result":"fail","failures":1,"assertion":"test_compute"}
{"ts":"$(ts_ago 100)","event":"write","file":"$proj/foo.py","lines_changed":3}
{"ts":"$(ts_ago 90)","event":"test_run","result":"fail","failures":1,"assertion":"test_compute"}
{"ts":"$(ts_ago 80)","event":"write","file":"$proj/foo.py","lines_changed":2}
{"ts":"$(ts_ago 70)","event":"test_run","result":"fail","failures":1,"assertion":"test_compute"}
EOF

    local result
    result=$(
        source "$CONTEXT_LIB"
        detect_approach_pivots "$proj"
        echo "PIVOT_COUNT=$PIVOT_COUNT"
        echo "PIVOT_FILES=$PIVOT_FILES"
        echo "PIVOT_ASSERTIONS=$PIVOT_ASSERTIONS"
    )

    local pivot_count
    pivot_count=$(echo "$result" | grep "^PIVOT_COUNT=" | cut -d= -f2)
    local pivot_files
    pivot_files=$(echo "$result" | grep "^PIVOT_FILES=" | cut -d= -f2-)
    local pivot_assertions
    pivot_assertions=$(echo "$result" | grep "^PIVOT_ASSERTIONS=" | cut -d= -f2-)

    if [[ "$pivot_count" -ge 1 ]]; then
        pass "detect_approach_pivots detects edit->fail->edit pattern (PIVOT_COUNT=$pivot_count)"
    else
        fail "detect_approach_pivots failed to detect pivot pattern" \
            "Result: $result"
    fi

    run_test
    if echo "$pivot_files" | grep -q "foo.py"; then
        pass "detect_approach_pivots identifies the pivoting file"
    else
        fail "detect_approach_pivots did not identify pivoting file" \
            "PIVOT_FILES='$pivot_files'"
    fi

    run_test
    if echo "$pivot_assertions" | grep -q "test_compute"; then
        pass "detect_approach_pivots captures failing assertion name"
    else
        fail "detect_approach_pivots did not capture assertion name" \
            "PIVOT_ASSERTIONS='$pivot_assertions'"
    fi
}

# ============================================================================
# Test 2: detect_approach_pivots returns 0 pivots when no patterns exist
# ============================================================================

test_detect_pivots_no_patterns() {
    run_test
    local proj
    proj=$(make_temp_project)
    trap "rm -rf '$proj'" RETURN

    # Only one write, one failure — not enough for a pivot
    cat > "$proj/.claude/.session-events.jsonl" <<EOF
{"ts":"$(ts_ago 60)","event":"write","file":"$proj/bar.py","lines_changed":5}
{"ts":"$(ts_ago 50)","event":"test_run","result":"fail","failures":2,"assertion":"test_bar"}
EOF

    local result
    result=$(
        source "$CONTEXT_LIB"
        detect_approach_pivots "$proj"
        echo "PIVOT_COUNT=$PIVOT_COUNT"
    )

    local pivot_count
    pivot_count=$(echo "$result" | grep "^PIVOT_COUNT=" | cut -d= -f2)

    if [[ "$pivot_count" -eq 0 ]]; then
        pass "detect_approach_pivots returns 0 pivots when no loop pattern exists"
    else
        fail "detect_approach_pivots falsely detected pivots" \
            "PIVOT_COUNT=$pivot_count (expected 0)"
    fi
}

test_detect_pivots_missing_event_log() {
    run_test
    local proj
    proj=$(make_temp_project)
    trap "rm -rf '$proj'" RETURN

    # No events file at all
    local result
    result=$(
        source "$CONTEXT_LIB"
        detect_approach_pivots "$proj"
        echo "PIVOT_COUNT=$PIVOT_COUNT"
    )

    local pivot_count
    pivot_count=$(echo "$result" | grep "^PIVOT_COUNT=" | cut -d= -f2)

    if [[ "$pivot_count" -eq 0 ]]; then
        pass "detect_approach_pivots returns 0 pivots when event log is missing"
    else
        fail "detect_approach_pivots failed on missing event log" \
            "PIVOT_COUNT=$pivot_count (expected 0)"
    fi
}

test_detect_pivots_all_passes() {
    run_test
    local proj
    proj=$(make_temp_project)
    trap "rm -rf '$proj'" RETURN

    # Writes followed by passes — no pivot pattern
    cat > "$proj/.claude/.session-events.jsonl" <<EOF
{"ts":"$(ts_ago 120)","event":"write","file":"$proj/ok.py","lines_changed":10}
{"ts":"$(ts_ago 110)","event":"test_run","result":"pass","failures":0,"assertion":""}
{"ts":"$(ts_ago 100)","event":"write","file":"$proj/ok.py","lines_changed":3}
{"ts":"$(ts_ago 90)","event":"test_run","result":"pass","failures":0,"assertion":""}
EOF

    local result
    result=$(
        source "$CONTEXT_LIB"
        detect_approach_pivots "$proj"
        echo "PIVOT_COUNT=$PIVOT_COUNT"
    )

    local pivot_count
    pivot_count=$(echo "$result" | grep "^PIVOT_COUNT=" | cut -d= -f2)

    if [[ "$pivot_count" -eq 0 ]]; then
        pass "detect_approach_pivots returns 0 pivots when tests pass between edits"
    else
        fail "detect_approach_pivots falsely detected pivots on passing tests" \
            "PIVOT_COUNT=$pivot_count (expected 0)"
    fi
}

# ============================================================================
# Test 3: test-gate on strike 2+ with event log provides trajectory guidance
# ============================================================================

test_gate_strike2_trajectory_guidance() {
    run_test
    local proj
    proj=$(make_temp_project)
    trap "rm -rf '$proj'" RETURN

    # Set up a failing test status
    local now
    now=$(date +%s)
    echo "fail|3|$now" > "$proj/.claude/.test-status"

    # Set up strike count (strike 2 = already denied once)
    echo "1|$now" > "$proj/.claude/.test-gate-strikes"

    # Set up session events showing edit->fail->edit->fail on same file
    cat > "$proj/.claude/.session-events.jsonl" <<EOF
{"ts":"$(ts_ago 120)","event":"write","file":"$proj/src/compute.py","lines_changed":10}
{"ts":"$(ts_ago 110)","event":"test_run","result":"fail","failures":3,"assertion":"test_compute_result"}
{"ts":"$(ts_ago 90)","event":"write","file":"$proj/src/compute.py","lines_changed":4}
{"ts":"$(ts_ago 70)","event":"test_run","result":"fail","failures":3,"assertion":"test_compute_result"}
EOF

    # Mock a Write tool call targeting a source file
    local hook_input
    hook_input=$(jq -n \
        --arg file "$proj/src/compute.py" \
        '{tool_name: "Write", tool_input: {file_path: $file, content: "x=1"}}')

    local output
    output=$(
        export CLAUDE_PROJECT_DIR="$proj"
        echo "$hook_input" | bash "${HOOKS_DIR}/test-gate.sh" 2>/dev/null
    )

    # Should deny with trajectory-aware message
    if echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' > /dev/null 2>&1; then
        pass "test-gate denies on strike 2 with trajectory events"
    else
        fail "test-gate did not deny on strike 2" "Output: $output"
        return
    fi

    run_test
    local reason
    reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)
    # Should include trajectory guidance (file name or assertion or pivot mention)
    if echo "$reason" | grep -qiE "compute|pivot|edited.*times|assertion"; then
        pass "test-gate strike 2+ includes trajectory-aware guidance"
    else
        fail "test-gate strike 2+ missing trajectory guidance" \
            "Reason: $reason"
    fi
}

# ============================================================================
# Test 4: test-gate without event log falls back to current behavior
# ============================================================================

test_gate_no_event_log_fallback() {
    run_test
    local proj
    proj=$(make_temp_project)
    trap "rm -rf '$proj'" RETURN

    # Failing test status, no event log
    local now
    now=$(date +%s)
    echo "fail|2|$now" > "$proj/.claude/.test-status"
    echo "1|$now" > "$proj/.claude/.test-gate-strikes"
    # No .session-events.jsonl

    local hook_input
    hook_input=$(jq -n \
        --arg file "$proj/src/app.py" \
        '{tool_name: "Write", tool_input: {file_path: $file, content: "x=1"}}')

    local output
    output=$(
        export CLAUDE_PROJECT_DIR="$proj"
        echo "$hook_input" | bash "${HOOKS_DIR}/test-gate.sh" 2>/dev/null
    )

    # Should still deny (falls back to strike behavior)
    if echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' > /dev/null 2>&1; then
        pass "test-gate still denies on strike 2 when no event log (fallback behavior)"
    else
        fail "test-gate failed to deny on strike 2 without event log" "Output: $output"
    fi
}

test_gate_strike1_advisory_unchanged() {
    run_test
    local proj
    proj=$(make_temp_project)
    trap "rm -rf '$proj'" RETURN

    # Failing test status, first strike (no strikes file yet)
    local now
    now=$(date +%s)
    echo "fail|1|$now" > "$proj/.claude/.test-status"

    local hook_input
    hook_input=$(jq -n \
        --arg file "$proj/src/main.py" \
        '{tool_name: "Write", tool_input: {file_path: $file, content: "x=1"}}')

    local output
    output=$(
        export CLAUDE_PROJECT_DIR="$proj"
        echo "$hook_input" | bash "${HOOKS_DIR}/test-gate.sh" 2>/dev/null
    )

    # Strike 1 should ALLOW (with advisory, no deny)
    local has_deny
    has_deny=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null)
    if [[ "$has_deny" != "deny" ]]; then
        pass "test-gate strike 1 still allows (advisory only)"
    else
        fail "test-gate strike 1 wrongly denied" "Output: $output"
    fi
}

# ============================================================================
# Test 5: Session summary includes trajectory narrative when events exist
# ============================================================================

test_session_summary_trajectory_narrative() {
    run_test
    local proj
    proj=$(make_temp_project)
    trap "rm -rf '$proj'" RETURN

    # Create a session-changes file so summary runs
    echo "$proj/src/main.py" > "$proj/.claude/.session-changes"

    # Write session events with pivots and agent activity
    cat > "$proj/.claude/.session-events.jsonl" <<EOF
{"ts":"$(ts_ago 300)","event":"agent_start","type":"implementer"}
{"ts":"$(ts_ago 280)","event":"write","file":"$proj/src/main.py","lines_changed":20}
{"ts":"$(ts_ago 260)","event":"test_run","result":"fail","failures":2,"assertion":"test_compute"}
{"ts":"$(ts_ago 240)","event":"write","file":"$proj/src/main.py","lines_changed":5}
{"ts":"$(ts_ago 220)","event":"test_run","result":"fail","failures":2,"assertion":"test_compute"}
{"ts":"$(ts_ago 200)","event":"write","file":"$proj/src/main.py","lines_changed":3}
{"ts":"$(ts_ago 180)","event":"test_run","result":"fail","failures":2,"assertion":"test_compute"}
EOF

    # Create a minimal git repo so git state doesn't fail
    git -C "$proj" init -q 2>/dev/null || true
    git -C "$proj" config user.email "test@test.com" 2>/dev/null || true
    git -C "$proj" config user.name "Test" 2>/dev/null || true

    # Run session-summary
    local hook_input
    hook_input='{"stop_hook_active":false}'

    local output
    output=$(
        export CLAUDE_PROJECT_DIR="$proj"
        echo "$hook_input" | bash "${HOOKS_DIR}/session-summary.sh" 2>/dev/null
    )

    # Should have a systemMessage
    if echo "$output" | jq -e '.systemMessage' > /dev/null 2>&1; then
        pass "session-summary produces systemMessage output"
    else
        fail "session-summary missing systemMessage" "Output: $output"
        return
    fi

    run_test
    local msg
    msg=$(echo "$output" | jq -r '.systemMessage // ""' 2>/dev/null)
    # Should mention trajectory data (test failures, pivots, or trajectory section)
    if echo "$msg" | grep -qiE "test.*fail|pivot|trajectory|failures"; then
        pass "session-summary includes trajectory narrative (failures/pivots mentioned)"
    else
        fail "session-summary missing trajectory narrative" \
            "Message: $(echo "$msg" | head -5)"
    fi
}

test_session_summary_no_events_still_works() {
    run_test
    local proj
    proj=$(make_temp_project)
    trap "rm -rf '$proj'" RETURN

    # session-changes file exists but no session-events.jsonl
    echo "$proj/src/main.py" > "$proj/.claude/.session-changes"

    git -C "$proj" init -q 2>/dev/null || true
    git -C "$proj" config user.email "test@test.com" 2>/dev/null || true
    git -C "$proj" config user.name "Test" 2>/dev/null || true

    local hook_input
    hook_input='{"stop_hook_active":false}'

    local output
    output=$(
        export CLAUDE_PROJECT_DIR="$proj"
        echo "$hook_input" | bash "${HOOKS_DIR}/session-summary.sh" 2>/dev/null
    )

    # Should still produce a systemMessage (graceful degradation)
    if echo "$output" | jq -e '.systemMessage' > /dev/null 2>&1; then
        pass "session-summary still works without event log (graceful)"
    else
        fail "session-summary failed without event log" "Output: $output"
    fi
}

# ============================================================================
# Test 6: detect_approach_pivots exported correctly
# ============================================================================

test_detect_pivots_function_exported() {
    run_test
    # Verify the function is exported and accessible in subshells
    local result
    result=$(
        source "$CONTEXT_LIB"
        type detect_approach_pivots 2>&1
    )
    if echo "$result" | grep -q "function"; then
        pass "detect_approach_pivots is defined as a function in context-lib.sh"
    else
        fail "detect_approach_pivots not found in context-lib.sh" \
            "type output: $result"
    fi
}

# ============================================================================
# Run all tests
# ============================================================================

echo "=== Session-Aware Hooks Test Suite (Issue #84) ==="
echo ""

echo "--- detect_approach_pivots() ---"
test_detect_pivots_finds_patterns
test_detect_pivots_no_patterns
test_detect_pivots_missing_event_log
test_detect_pivots_all_passes
test_detect_pivots_function_exported

echo ""
echo "--- test-gate.sh trajectory guidance ---"
test_gate_strike2_trajectory_guidance
test_gate_no_event_log_fallback
test_gate_strike1_advisory_unchanged

echo ""
echo "--- session-summary.sh trajectory narrative ---"
test_session_summary_trajectory_narrative
test_session_summary_no_events_still_works

# Summary
echo ""
echo "==========================================="
echo "Test Results:"
echo "  Total:  $TESTS_RUN"
echo -e "  ${GREEN}Passed: $TESTS_PASSED${NC}"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
    echo -e "  ${RED}Failed: $TESTS_FAILED${NC}"
else
    echo "  Failed: 0"
fi
echo "==========================================="

if [[ "$TESTS_FAILED" -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi
