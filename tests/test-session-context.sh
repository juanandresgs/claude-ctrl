#!/usr/bin/env bash
# Tests for get_session_summary_context() and get_session_trajectory()
# — structured session context for commits and trajectory data accuracy.
#
# Validates:
#   1. Structured text output from a sample .session-events.jsonl
#   2. Non-trivial session (>5 events) generates meaningful context
#   3. Trivial session (<3 events) produces empty output
#   4. Stats line includes correct counts (tool calls, files, checkpoints)
#   5. Guardian injection path: 10+ events produce non-empty output with header+Stats
#   6. Stats accuracy: known event counts map to correct TRAJ_* variables
#   7. (W6-3-A) Guardian data flow: SESSION_SUMMARY non-empty when session events exist
#   8. (W6-3-B) Trajectory field precision: all 5 TRAJ_* variables match known input
#
# @decision DEC-V2-005
# @title Test suite for session context in commits
# @status accepted
# @rationale Tests cover the core contract of get_session_summary_context():
#   structured output for non-trivial sessions, silence for trivial ones.
#   W5-1 adds Guardian injection path test (10+ events) and trajectory accuracy
#   test with known counts to validate TRAJ_* variable correctness.
#   W6-3 adds two further tests: (A) verifies the guardian branch data flow from
#   subagent-start.sh — that SESSION_SUMMARY is non-empty when session events exist —
#   and (B) verifies all five TRAJ_* trajectory fields precisely match a synthetic
#   event log with known exact counts (7 writes to 4 unique files, 3 test failures,
#   2 checkpoints, 1 rewind). Uses temp directories with synthetic
#   .session-events.jsonl to avoid dependency on live session state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTEXT_LIB="${SCRIPT_DIR}/../hooks/context-lib.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0

# Cleanup trap (DEC-PROD-002): collect temp dirs and remove on exit
_CLEANUP_DIRS=()
trap '[[ ${#_CLEANUP_DIRS[@]} -gt 0 ]] && rm -rf "${_CLEANUP_DIRS[@]}" 2>/dev/null; true' EXIT
TESTS_FAILED=0

pass_test() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} $1"
}

fail_test() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} $1"
    echo -e "  ${YELLOW}Details:${NC} $2"
}

run_test() {
    TESTS_RUN=$((TESTS_RUN + 1))
}

# Create a temp project root with a .claude/ dir and synthetic event log
make_project() {
    local dir
    dir=$(mktemp -d)
    mkdir -p "$dir/.claude"
    echo "$dir"
}

# Write a write-event line to the event log
write_event() {
    local dir="$1" file="$2" ts="${3:-2026-02-17T10:00:00Z}"
    echo "{\"ts\":\"$ts\",\"event\":\"write\",\"file\":\"$file\"}" >> "$dir/.claude/.session-events.jsonl"
}

# Write a checkpoint event
checkpoint_event() {
    local dir="$1" ts="${2:-2026-02-17T10:01:00Z}"
    echo "{\"ts\":\"$ts\",\"event\":\"checkpoint\"}" >> "$dir/.claude/.session-events.jsonl"
}

# Write a test_run failure event
test_fail_event() {
    local dir="$1" assertion="${2:-test_auth_token}" ts="${3:-2026-02-17T10:02:00Z}"
    echo "{\"ts\":\"$ts\",\"event\":\"test_run\",\"result\":\"fail\",\"assertion\":\"$assertion\"}" >> "$dir/.claude/.session-events.jsonl"
}

# Write an agent_start event
agent_start_event() {
    local dir="$1" type="${2:-implementer}" ts="${3:-2026-02-17T10:00:00Z}"
    echo "{\"ts\":\"$ts\",\"event\":\"agent_start\",\"type\":\"$type\"}" >> "$dir/.claude/.session-events.jsonl"
}

# Call get_session_summary_context in a subshell that sources context-lib.sh
call_summary() {
    local dir="$1"
    (
        # Suppress any git errors from context-lib.sh
        source "$CONTEXT_LIB" 2>/dev/null
        get_session_summary_context "$dir" 2>/dev/null
    )
}

# Write a rewind event
rewind_event() {
    local dir="$1" ts="${2:-2026-02-17T10:05:00Z}"
    echo "{\"ts\":\"$ts\",\"event\":\"rewind\"}" >> "$dir/.claude/.session-events.jsonl"
}

# Call get_session_trajectory in a subshell, echoing the TRAJ_* variables
call_trajectory() {
    local dir="$1"
    (
        source "$CONTEXT_LIB" 2>/dev/null
        get_session_trajectory "$dir" 2>/dev/null
        echo "TRAJ_TOOL_CALLS=${TRAJ_TOOL_CALLS}"
        echo "TRAJ_FILES_MODIFIED=${TRAJ_FILES_MODIFIED}"
        echo "TRAJ_TEST_FAILURES=${TRAJ_TEST_FAILURES}"
        echo "TRAJ_CHECKPOINTS=${TRAJ_CHECKPOINTS}"
        echo "TRAJ_REWINDS=${TRAJ_REWINDS}"
    )
}

# ============================================================================
# Test 1: Trivial session (<3 events) produces empty output
# ============================================================================

test_trivial_session_empty() {
    run_test
    echo -n "Testing trivial session (<3 events) produces empty output... "

    local dir
    dir=$(make_project)
    trap "rm -rf '$dir'" RETURN

    # Only 2 events — below the triviality threshold
    write_event "$dir" "hooks/guard.sh" "2026-02-17T10:00:00Z"
    write_event "$dir" "hooks/guard.sh" "2026-02-17T10:00:30Z"

    local result
    result=$(call_summary "$dir")

    if [[ -z "$result" ]]; then
        pass_test "Trivial session (<3 events) returns empty"
    else
        fail_test "Trivial session should return empty" "Got: $result"
    fi
}

# ============================================================================
# Test 2: Non-trivial session (>5 events) generates meaningful context
# ============================================================================

test_nontrivial_session_has_content() {
    run_test
    echo -n "Testing non-trivial session (>5 events) generates context block... "

    local dir
    dir=$(make_project)
    trap "rm -rf '$dir'" RETURN

    # 8 events — well above the threshold
    write_event "$dir" "hooks/guard.sh"         "2026-02-17T10:00:00Z"
    write_event "$dir" "hooks/context-lib.sh"   "2026-02-17T10:01:00Z"
    write_event "$dir" "tests/test-gate.sh"     "2026-02-17T10:02:00Z"
    write_event "$dir" "hooks/guard.sh"         "2026-02-17T10:03:00Z"
    checkpoint_event  "$dir"                    "2026-02-17T10:04:00Z"
    write_event "$dir" "hooks/guard.sh"         "2026-02-17T10:05:00Z"
    write_event "$dir" "hooks/context-lib.sh"   "2026-02-17T10:06:00Z"
    write_event "$dir" "hooks/guard.sh"         "2026-02-17T10:07:00Z"

    local result
    result=$(call_summary "$dir")

    if [[ -n "$result" ]]; then
        pass_test "Non-trivial session generates context"
    else
        fail_test "Non-trivial session should generate context" "Got empty output"
    fi
}

# ============================================================================
# Test 3: Output starts with --- Session Context --- header
# ============================================================================

test_output_has_header() {
    run_test
    echo -n "Testing output has --- Session Context --- header... "

    local dir
    dir=$(make_project)
    trap "rm -rf '$dir'" RETURN

    # 6 events
    for i in $(seq 1 6); do
        write_event "$dir" "hooks/guard.sh" "2026-02-17T10:0${i}:00Z"
    done

    local result
    result=$(call_summary "$dir")

    if echo "$result" | grep -q '^--- Session Context ---'; then
        pass_test "Output starts with --- Session Context ---"
    else
        fail_test "Missing --- Session Context --- header" "Got: $result"
    fi
}

# ============================================================================
# Test 4: Stats line includes correct tool call count
# ============================================================================

test_stats_line_tool_calls() {
    run_test
    echo -n "Testing Stats line includes correct tool call count... "

    local dir
    dir=$(make_project)
    trap "rm -rf '$dir'" RETURN

    # 5 write events (tool calls) + 1 checkpoint to exceed trivial threshold
    write_event "$dir" "hooks/guard.sh"       "2026-02-17T10:00:00Z"
    write_event "$dir" "hooks/context-lib.sh" "2026-02-17T10:01:00Z"
    write_event "$dir" "tests/test-gate.sh"   "2026-02-17T10:02:00Z"
    write_event "$dir" "hooks/guard.sh"       "2026-02-17T10:03:00Z"
    write_event "$dir" "hooks/guard.sh"       "2026-02-17T10:04:00Z"
    checkpoint_event  "$dir"                  "2026-02-17T10:05:00Z"

    local result
    result=$(call_summary "$dir")

    # Should report 5 tool calls (write events)
    if echo "$result" | grep -qE 'Stats:.*5 tool calls'; then
        pass_test "Stats line shows correct tool call count (5)"
    else
        fail_test "Stats line has wrong tool call count" "Got: $result"
    fi
}

# ============================================================================
# Test 5: Stats line includes correct file count (unique files)
# ============================================================================

test_stats_line_file_count() {
    run_test
    echo -n "Testing Stats line includes correct unique file count... "

    local dir
    dir=$(make_project)
    trap "rm -rf '$dir'" RETURN

    # 3 unique files, but guard.sh written 3 times (still 1 unique file)
    write_event "$dir" "hooks/guard.sh"       "2026-02-17T10:00:00Z"
    write_event "$dir" "hooks/guard.sh"       "2026-02-17T10:01:00Z"
    write_event "$dir" "hooks/context-lib.sh" "2026-02-17T10:02:00Z"
    write_event "$dir" "tests/test-gate.sh"   "2026-02-17T10:03:00Z"
    checkpoint_event  "$dir"                  "2026-02-17T10:04:00Z"
    write_event "$dir" "hooks/guard.sh"       "2026-02-17T10:05:00Z"

    local result
    result=$(call_summary "$dir")

    # Should report 3 unique files: guard.sh, context-lib.sh, test-gate.sh
    if echo "$result" | grep -qE 'Stats:.*3 files'; then
        pass_test "Stats line shows correct unique file count (3)"
    else
        fail_test "Stats line has wrong file count" "Got: $result"
    fi
}

# ============================================================================
# Test 6: Stats line includes checkpoint count
# ============================================================================

test_stats_line_checkpoints() {
    run_test
    echo -n "Testing Stats line includes correct checkpoint count... "

    local dir
    dir=$(make_project)
    trap "rm -rf '$dir'" RETURN

    # 2 checkpoints
    write_event     "$dir" "hooks/guard.sh"  "2026-02-17T10:00:00Z"
    checkpoint_event "$dir"                  "2026-02-17T10:01:00Z"
    write_event     "$dir" "hooks/guard.sh"  "2026-02-17T10:02:00Z"
    checkpoint_event "$dir"                  "2026-02-17T10:03:00Z"
    write_event     "$dir" "hooks/guard.sh"  "2026-02-17T10:04:00Z"
    write_event     "$dir" "hooks/guard.sh"  "2026-02-17T10:05:00Z"

    local result
    result=$(call_summary "$dir")

    if echo "$result" | grep -qE 'Stats:.*2 checkpoints'; then
        pass_test "Stats line shows correct checkpoint count (2)"
    else
        fail_test "Stats line has wrong checkpoint count" "Got: $result"
    fi
}

# ============================================================================
# Test 7: Test failures produce a Friction line
# ============================================================================

test_friction_line_on_failures() {
    run_test
    echo -n "Testing Friction line appears when test failures occurred... "

    local dir
    dir=$(make_project)
    trap "rm -rf '$dir'" RETURN

    write_event      "$dir" "hooks/guard.sh"  "2026-02-17T10:00:00Z"
    test_fail_event  "$dir" "test_auth_token" "2026-02-17T10:01:00Z"
    write_event      "$dir" "hooks/guard.sh"  "2026-02-17T10:02:00Z"
    test_fail_event  "$dir" "test_auth_token" "2026-02-17T10:03:00Z"
    write_event      "$dir" "hooks/guard.sh"  "2026-02-17T10:04:00Z"
    write_event      "$dir" "hooks/guard.sh"  "2026-02-17T10:05:00Z"

    local result
    result=$(call_summary "$dir")

    if echo "$result" | grep -q '^Friction:'; then
        pass_test "Friction line appears for test failures"
    else
        fail_test "Missing Friction line for test failures" "Got: $result"
    fi
}

# ============================================================================
# Test 8: No Friction line when no test failures
# ============================================================================

test_no_friction_on_clean_session() {
    run_test
    echo -n "Testing no Friction line when session had no test failures... "

    local dir
    dir=$(make_project)
    trap "rm -rf '$dir'" RETURN

    # Clean session — writes and checkpoint only
    write_event      "$dir" "hooks/guard.sh"       "2026-02-17T10:00:00Z"
    write_event      "$dir" "hooks/context-lib.sh" "2026-02-17T10:01:00Z"
    checkpoint_event "$dir"                         "2026-02-17T10:02:00Z"
    write_event      "$dir" "tests/test-gate.sh"   "2026-02-17T10:03:00Z"
    write_event      "$dir" "hooks/guard.sh"        "2026-02-17T10:04:00Z"
    write_event      "$dir" "hooks/guard.sh"        "2026-02-17T10:05:00Z"

    local result
    result=$(call_summary "$dir")

    if ! echo "$result" | grep -q '^Friction:'; then
        pass_test "No Friction line in clean session"
    else
        fail_test "Unexpected Friction line in clean session" "Got: $result"
    fi
}

# ============================================================================
# Test 9 (W5-1): Guardian injection path — 10+ events produce full context block
# ============================================================================

test_guardian_injection_path() {
    run_test
    echo -n "Testing Guardian injection path (10+ events has header and Stats)... "

    local dir
    dir=$(make_project)
    trap "rm -rf '$dir'" RETURN

    # Build a realistic session: 6 writes to 3 files, 2 test failures,
    # 1 checkpoint, 1 agent_start, 1 rewind — 11 events total
    write_event "$dir" "hooks/guard.sh"         "2026-02-19T08:00:00Z"
    write_event "$dir" "hooks/context-lib.sh"   "2026-02-19T08:01:00Z"
    test_fail_event "$dir" "test_guard_branch"  "2026-02-19T08:02:00Z"
    write_event "$dir" "hooks/guard.sh"         "2026-02-19T08:03:00Z"
    test_fail_event "$dir" "test_guard_branch"  "2026-02-19T08:04:00Z"
    write_event "$dir" "hooks/test-gate.sh"     "2026-02-19T08:05:00Z"
    checkpoint_event "$dir"                     "2026-02-19T08:06:00Z"
    write_event "$dir" "hooks/guard.sh"         "2026-02-19T08:07:00Z"
    agent_start_event "$dir" "implementer"      "2026-02-19T08:08:00Z"
    write_event "$dir" "hooks/context-lib.sh"   "2026-02-19T08:09:00Z"
    rewind_event "$dir"                         "2026-02-19T08:10:00Z"

    local result
    result=$(call_summary "$dir")

    # Assert 1: non-empty
    if [[ -z "$result" ]]; then
        fail_test "Guardian injection path: got empty output for 11-event session" "result was empty"
        return
    fi

    # Assert 2: has --- Session Context --- header
    if ! echo "$result" | grep -q '^--- Session Context ---'; then
        fail_test "Guardian injection path: missing --- Session Context --- header" "Got: $result"
        return
    fi

    # Assert 3: has Stats: line
    if ! echo "$result" | grep -q '^Stats:'; then
        fail_test "Guardian injection path: missing Stats: line" "Got: $result"
        return
    fi

    pass_test "Guardian injection path: 11-event session has header and Stats line"
}

# ============================================================================
# Test 10 (W5-1): Stats accuracy for non-trivial session with known counts
# ============================================================================

test_stats_accuracy_known_counts() {
    run_test
    echo -n "Testing get_session_trajectory() accuracy with known event counts... "

    local dir
    dir=$(make_project)
    trap "rm -rf '$dir'" RETURN

    # Synthetic session with precisely known counts:
    #   - 5 writes to 3 unique files (file-a.py x3, file-b.py x1, file-c.py x1)
    #   - 2 test_run fail events
    #   - 1 checkpoint event
    #   - 1 rewind event
    local file_a="src/file-a.py"
    local file_b="src/file-b.py"
    local file_c="src/file-c.py"

    write_event "$dir" "$file_a" "2026-02-19T09:00:00Z"
    test_fail_event "$dir" "test_file_a_parse" "2026-02-19T09:01:00Z"
    write_event "$dir" "$file_a" "2026-02-19T09:02:00Z"
    test_fail_event "$dir" "test_file_a_parse" "2026-02-19T09:03:00Z"
    write_event "$dir" "$file_b" "2026-02-19T09:04:00Z"
    checkpoint_event "$dir"     "2026-02-19T09:05:00Z"
    write_event "$dir" "$file_c" "2026-02-19T09:06:00Z"
    rewind_event "$dir"          "2026-02-19T09:07:00Z"
    write_event "$dir" "$file_a" "2026-02-19T09:08:00Z"

    local traj
    traj=$(call_trajectory "$dir")

    local tool_calls files_modified test_failures checkpoints rewinds
    tool_calls=$(echo "$traj"   | grep "^TRAJ_TOOL_CALLS="    | cut -d= -f2)
    files_modified=$(echo "$traj" | grep "^TRAJ_FILES_MODIFIED=" | cut -d= -f2)
    test_failures=$(echo "$traj"  | grep "^TRAJ_TEST_FAILURES="  | cut -d= -f2)
    checkpoints=$(echo "$traj"    | grep "^TRAJ_CHECKPOINTS="    | cut -d= -f2)
    rewinds=$(echo "$traj"        | grep "^TRAJ_REWINDS="         | cut -d= -f2)

    local all_ok=true

    if [[ "$tool_calls" -ne 5 ]]; then
        fail_test "TRAJ_TOOL_CALLS: expected 5, got '$tool_calls'" "$traj"
        all_ok=false
    fi
    if [[ "$files_modified" -ne 3 ]]; then
        fail_test "TRAJ_FILES_MODIFIED: expected 3 unique files, got '$files_modified'" "$traj"
        all_ok=false
    fi
    if [[ "$test_failures" -ne 2 ]]; then
        fail_test "TRAJ_TEST_FAILURES: expected 2, got '$test_failures'" "$traj"
        all_ok=false
    fi
    if [[ "$checkpoints" -ne 1 ]]; then
        fail_test "TRAJ_CHECKPOINTS: expected 1, got '$checkpoints'" "$traj"
        all_ok=false
    fi
    if [[ "$rewinds" -ne 1 ]]; then
        fail_test "TRAJ_REWINDS: expected 1, got '$rewinds'" "$traj"
        all_ok=false
    fi

    if [[ "$all_ok" == "true" ]]; then
        pass_test "get_session_trajectory() reports correct counts: 5 writes, 3 files, 2 failures, 1 checkpoint, 1 rewind"
    fi
}

# ============================================================================
# Test 11 (W6-3-A): Guardian data flow — SESSION_SUMMARY non-empty when events exist
# ============================================================================
# This test mirrors what subagent-start.sh does in the guardian) case:
#   SESSION_SUMMARY=$(get_session_summary_context "$PROJECT_ROOT" 2>/dev/null || echo "")
# The test verifies that a non-trivial session (sufficient events) produces a
# non-empty SESSION_SUMMARY, which is what drives the rich commit context injection.
# ============================================================================

test_guardian_session_summary_data_flow() {
    run_test
    echo -n "Testing guardian SESSION_SUMMARY data flow (non-empty for sufficient events)... "

    local dir
    dir=$(make_project)
    trap "rm -rf '$dir'" RETURN

    # Build a realistic pre-commit session that guardian would see:
    # 8 writes across 3 files + 1 test failure + 1 checkpoint + 1 agent_start = 12 events
    write_event      "$dir" "hooks/guard.sh"       "2026-02-20T09:00:00Z"
    write_event      "$dir" "hooks/context-lib.sh" "2026-02-20T09:01:00Z"
    test_fail_event  "$dir" "test_guard_merge"     "2026-02-20T09:02:00Z"
    write_event      "$dir" "hooks/guard.sh"       "2026-02-20T09:03:00Z"
    write_event      "$dir" "tests/run-hooks.sh"   "2026-02-20T09:04:00Z"
    checkpoint_event "$dir"                        "2026-02-20T09:05:00Z"
    write_event      "$dir" "hooks/guard.sh"       "2026-02-20T09:06:00Z"
    agent_start_event "$dir" "implementer"         "2026-02-20T09:07:00Z"
    write_event      "$dir" "hooks/context-lib.sh" "2026-02-20T09:08:00Z"
    write_event      "$dir" "tests/run-hooks.sh"   "2026-02-20T09:09:00Z"
    write_event      "$dir" "hooks/guard.sh"       "2026-02-20T09:10:00Z"
    write_event      "$dir" "hooks/guard.sh"       "2026-02-20T09:11:00Z"

    # Replicate the guardian branch data flow from subagent-start.sh:
    #   SESSION_SUMMARY=$(get_session_summary_context "$PROJECT_ROOT" 2>/dev/null || echo "")
    local SESSION_SUMMARY
    SESSION_SUMMARY=$(call_summary "$dir")

    if [[ -n "$SESSION_SUMMARY" ]]; then
        pass_test "guardian SESSION_SUMMARY data flow: non-empty for 12-event session"
    else
        fail_test "guardian SESSION_SUMMARY data flow: expected non-empty, got empty" \
             "Ensure session has sufficient events for get_session_summary_context()"
    fi
}

# ============================================================================
# Test 12 (W6-3-B): Trajectory field precision — all 5 TRAJ_* match known input
# ============================================================================
# Verifies that every trajectory field (tool_uses, files_changed, test_failures,
# checkpoints, rewinds) maps precisely to the synthetic event log. This catches
# regressions in get_session_trajectory() parsing logic with exact-count assertions.
# ============================================================================

test_trajectory_field_precision() {
    run_test
    echo -n "Testing trajectory field precision with exact synthetic counts... "

    local dir
    dir=$(make_project)
    trap "rm -rf '$dir'" RETURN

    # Synthetic event log with precisely known counts:
    #   7 writes across 4 unique files:
    #     hooks/auth.sh   x3
    #     hooks/guard.sh  x2
    #     src/main.py     x1
    #     tests/test.sh   x1
    #   3 test_run fail events
    #   2 checkpoint events
    #   1 rewind event
    write_event      "$dir" "hooks/auth.sh"   "2026-02-20T10:00:00Z"
    test_fail_event  "$dir" "test_auth_jwt"   "2026-02-20T10:01:00Z"
    write_event      "$dir" "hooks/auth.sh"   "2026-02-20T10:02:00Z"
    test_fail_event  "$dir" "test_auth_jwt"   "2026-02-20T10:03:00Z"
    write_event      "$dir" "hooks/guard.sh"  "2026-02-20T10:04:00Z"
    checkpoint_event "$dir"                   "2026-02-20T10:05:00Z"
    write_event      "$dir" "src/main.py"     "2026-02-20T10:06:00Z"
    test_fail_event  "$dir" "test_main_init"  "2026-02-20T10:07:00Z"
    write_event      "$dir" "hooks/auth.sh"   "2026-02-20T10:08:00Z"
    checkpoint_event "$dir"                   "2026-02-20T10:09:00Z"
    write_event      "$dir" "hooks/guard.sh"  "2026-02-20T10:10:00Z"
    rewind_event     "$dir"                   "2026-02-20T10:11:00Z"
    write_event      "$dir" "tests/test.sh"   "2026-02-20T10:12:00Z"

    local traj
    traj=$(call_trajectory "$dir")

    local tool_calls files_modified test_failures checkpoints rewinds
    tool_calls=$(echo "$traj"     | grep "^TRAJ_TOOL_CALLS="    | cut -d= -f2)
    files_modified=$(echo "$traj" | grep "^TRAJ_FILES_MODIFIED=" | cut -d= -f2)
    test_failures=$(echo "$traj"  | grep "^TRAJ_TEST_FAILURES="  | cut -d= -f2)
    checkpoints=$(echo "$traj"    | grep "^TRAJ_CHECKPOINTS="    | cut -d= -f2)
    rewinds=$(echo "$traj"        | grep "^TRAJ_REWINDS="         | cut -d= -f2)

    local all_ok=true

    if [[ "$tool_calls" -ne 7 ]]; then
        fail_test "TRAJ_TOOL_CALLS: expected 7, got '$tool_calls'" "$traj"
        all_ok=false
    fi
    if [[ "$files_modified" -ne 4 ]]; then
        fail_test "TRAJ_FILES_MODIFIED: expected 4 unique files, got '$files_modified'" "$traj"
        all_ok=false
    fi
    if [[ "$test_failures" -ne 3 ]]; then
        fail_test "TRAJ_TEST_FAILURES: expected 3, got '$test_failures'" "$traj"
        all_ok=false
    fi
    if [[ "$checkpoints" -ne 2 ]]; then
        fail_test "TRAJ_CHECKPOINTS: expected 2, got '$checkpoints'" "$traj"
        all_ok=false
    fi
    if [[ "$rewinds" -ne 1 ]]; then
        fail_test "TRAJ_REWINDS: expected 1, got '$rewinds'" "$traj"
        all_ok=false
    fi

    if [[ "$all_ok" == "true" ]]; then
        pass_test "trajectory field precision: 7 writes, 4 unique files, 3 failures, 2 checkpoints, 1 rewind"
    fi
}

# ============================================================================
# Run all tests
# ============================================================================

echo "Running test-session-context test suite..."
echo ""

test_trivial_session_empty
test_nontrivial_session_has_content
test_output_has_header
test_stats_line_tool_calls
test_stats_line_file_count
test_stats_line_checkpoints
test_friction_line_on_failures
test_no_friction_on_clean_session
test_guardian_injection_path
test_stats_accuracy_known_counts
test_guardian_session_summary_data_flow
test_trajectory_field_precision

echo ""
echo "========================================="
echo "Test Results:"
echo "  Total:  $TESTS_RUN"
echo -e "  ${GREEN}Passed: $TESTS_PASSED${NC}"
if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "  ${RED}Failed: $TESTS_FAILED${NC}"
else
    echo "  Failed: 0"
fi
echo "========================================="

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi
