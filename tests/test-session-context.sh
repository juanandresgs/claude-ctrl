#!/usr/bin/env bash
# Tests for get_session_summary_context() — structured session context for commits.
#
# Validates:
#   1. Structured text output from a sample .session-events.jsonl
#   2. Non-trivial session (>5 events) generates meaningful context
#   3. Trivial session (<3 events) produces empty output
#   4. Stats line includes correct counts (tool calls, files, checkpoints)
#
# @decision DEC-V2-005
# @title Test suite for session context in commits
# @status accepted
# @rationale Tests cover the core contract of get_session_summary_context():
#   structured output for non-trivial sessions, silence for trivial ones.
#   Uses temp directories with synthetic .session-events.jsonl to avoid
#   dependency on live session state.

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
