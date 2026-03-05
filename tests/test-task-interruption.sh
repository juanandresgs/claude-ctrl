#!/usr/bin/env bash
# test-task-interruption.sh — Tests for active agent detection in prompt-submit.sh
#
# @decision DEC-TEST-INTERRUPT-001
# @title Active agent detection test suite
# @status accepted
# @rationale Tests the Task Interruption Protocol detection logic added to
#   prompt-submit.sh (DEC-INTERRUPT-001). Validates that ACTIVE agent entries
#   in the subagent tracker produce advisory context injection, and that
#   approval keywords and missing tracker files suppress injection correctly.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"

# Ensure tmp directory exists
mkdir -p "$PROJECT_ROOT/tmp"

# Cleanup trap (DEC-PROD-002): collect temp dirs and remove on exit
_CLEANUP_DIRS=()
trap '[[ ${#_CLEANUP_DIRS[@]} -gt 0 ]] && rm -rf "${_CLEANUP_DIRS[@]}" 2>/dev/null; true' EXIT

# Track test results
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
    local test_name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "Running: $test_name"
}

pass_test() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  PASS"
}

fail_test() {
    local reason="$1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL: $reason"
}

# --- Syntax validation ---
run_test "Syntax: prompt-submit.sh is valid bash"
if bash -n "$HOOKS_DIR/prompt-submit.sh"; then
    pass_test
else
    fail_test "prompt-submit.sh has syntax errors"
fi

# Helper: run prompt-submit.sh with a given prompt and optional tracker setup
# Usage: run_prompt_submit "<prompt_text>" "<tracker_content_or_empty>"
# Sets CLAUDE_SESSION_ID to "test-$$" so tracker file is scoped predictably.
run_prompt_submit() {
    local prompt_text="$1"
    local tracker_content="${2:-}"

    # Create a temp directory with .claude/ structure
    local TEMP_DIR
    TEMP_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-interrupt-XXXXXX")
_CLEANUP_DIRS+=("$TEMP_DIR")
    local TEMP_CLAUDE_DIR="$TEMP_DIR/.claude"
    mkdir -p "$TEMP_CLAUDE_DIR"

    # Create a minimal git repo so detect_project_root works
    git -C "$TEMP_DIR" init > /dev/null 2>&1

    local SESSION_ID="test-$$"
    local TRACKER_FILE="$TEMP_CLAUDE_DIR/.subagent-tracker-${SESSION_ID}"

    # Write tracker file if content provided
    if [[ -n "$tracker_content" ]]; then
        echo "$tracker_content" > "$TRACKER_FILE"
    fi

    # Build JSON input
    local INPUT_JSON
    INPUT_JSON=$(printf '{"prompt": "%s"}' "$prompt_text")

    # Run hook with overridden HOME-equivalent so get_claude_dir() returns TEMP_CLAUDE_DIR
    # We run from TEMP_DIR so detect_project_root() finds it.
    # Override CLAUDE_DIR by setting CLAUDE_PROJECT_DIR.
    # NOTE: Use a subshell with explicit exports — inline VAR=val in a pipeline only
    # applies env to the left side (echo), not the right side (bash hook.sh).
    local OUTPUT
    OUTPUT=$(
        export CLAUDE_SESSION_ID="$SESSION_ID"
        export CLAUDE_PROJECT_DIR="$TEMP_DIR"
        export HOME="$TEMP_DIR"
        cd "$TEMP_DIR"
        echo "$INPUT_JSON" | bash "$HOOKS_DIR/prompt-submit.sh" 2>/dev/null
    ) || true

    # Cleanup
    cd "$PROJECT_ROOT"
    rm -rf "$TEMP_DIR"

    echo "$OUTPUT"
}

# --- Test 1: Positive — ACTIVE entry injects advisory context ---
run_test "Positive: ACTIVE implementer agent injects ACTIVE AGENTS context"
# Create tracker with one ACTIVE entry (30 seconds ago) and one DONE entry
NOW_EPOCH=$(date +%s)
ACTIVE_EPOCH=$(( NOW_EPOCH - 30 ))
DONE_EPOCH=$(( NOW_EPOCH - 200 ))
TRACKER_CONTENT="ACTIVE|implementer|${ACTIVE_EPOCH}
DONE|planner|${DONE_EPOCH}|120"

OUTPUT=$(run_prompt_submit "implement a new feature" "$TRACKER_CONTENT")

if echo "$OUTPUT" | grep -q "ACTIVE AGENTS"; then
    if echo "$OUTPUT" | grep -qi "implementer"; then
        pass_test
    else
        fail_test "Output missing 'implementer' agent type: $OUTPUT"
    fi
else
    fail_test "Output missing 'ACTIVE AGENTS' (injection did not fire): $OUTPUT"
fi

# --- Test 2: Negative — approval keyword suppresses injection ---
run_test "Negative: approval keyword 'approved' suppresses ACTIVE AGENTS injection"
NOW_EPOCH=$(date +%s)
ACTIVE_EPOCH=$(( NOW_EPOCH - 60 ))
TRACKER_CONTENT="ACTIVE|implementer|${ACTIVE_EPOCH}"

OUTPUT=$(run_prompt_submit "approved" "$TRACKER_CONTENT")

if echo "$OUTPUT" | grep -q "ACTIVE AGENTS"; then
    fail_test "ACTIVE AGENTS injected for approval keyword (should be suppressed): $OUTPUT"
else
    pass_test
fi

# --- Test 3: Negative — 'lgtm' suppresses injection ---
run_test "Negative: approval keyword 'lgtm' suppresses ACTIVE AGENTS injection"
NOW_EPOCH=$(date +%s)
ACTIVE_EPOCH=$(( NOW_EPOCH - 45 ))
TRACKER_CONTENT="ACTIVE|tester|${ACTIVE_EPOCH}"

OUTPUT=$(run_prompt_submit "lgtm" "$TRACKER_CONTENT")

if echo "$OUTPUT" | grep -q "ACTIVE AGENTS"; then
    fail_test "ACTIVE AGENTS injected for 'lgtm' keyword: $OUTPUT"
else
    pass_test
fi

# --- Test 4: Negative — no tracker file produces no injection ---
run_test "Negative: missing tracker file produces no ACTIVE AGENTS injection"
OUTPUT=$(run_prompt_submit "implement a new feature" "")

if echo "$OUTPUT" | grep -q "ACTIVE AGENTS"; then
    fail_test "ACTIVE AGENTS injected with no tracker file: $OUTPUT"
else
    pass_test
fi

# --- Test 5: Positive — only DONE entries (no ACTIVE) produces no injection ---
run_test "Positive: tracker with only DONE entries produces no ACTIVE AGENTS injection"
NOW_EPOCH=$(date +%s)
DONE_EPOCH=$(( NOW_EPOCH - 300 ))
TRACKER_CONTENT="DONE|implementer|${DONE_EPOCH}|180"

OUTPUT=$(run_prompt_submit "implement a new feature" "$TRACKER_CONTENT")

if echo "$OUTPUT" | grep -q "ACTIVE AGENTS"; then
    fail_test "ACTIVE AGENTS injected when only DONE entries exist: $OUTPUT"
else
    pass_test
fi

# --- Test 6: Positive — elapsed time format (seconds) ---
run_test "Positive: elapsed time under 60s shown in seconds"
NOW_EPOCH=$(date +%s)
ACTIVE_EPOCH=$(( NOW_EPOCH - 45 ))
TRACKER_CONTENT="ACTIVE|guardian|${ACTIVE_EPOCH}"

OUTPUT=$(run_prompt_submit "start new task" "$TRACKER_CONTENT")

if echo "$OUTPUT" | grep -q "ACTIVE AGENTS"; then
    if echo "$OUTPUT" | grep -qE "[0-9]+s"; then
        pass_test
    else
        fail_test "Expected seconds format in elapsed time: $OUTPUT"
    fi
else
    fail_test "ACTIVE AGENTS not injected: $OUTPUT"
fi

# --- Test 7: Positive — elapsed time format (minutes) ---
run_test "Positive: elapsed time over 60s shown in minutes+seconds"
NOW_EPOCH=$(date +%s)
ACTIVE_EPOCH=$(( NOW_EPOCH - 125 ))
TRACKER_CONTENT="ACTIVE|implementer|${ACTIVE_EPOCH}"

OUTPUT=$(run_prompt_submit "fix the bug" "$TRACKER_CONTENT")

if echo "$OUTPUT" | grep -q "ACTIVE AGENTS"; then
    if echo "$OUTPUT" | grep -qE "[0-9]+m[0-9]+s"; then
        pass_test
    else
        fail_test "Expected minutes+seconds format in elapsed time: $OUTPUT"
    fi
else
    fail_test "ACTIVE AGENTS not injected: $OUTPUT"
fi

# --- Test 8: Positive — backlog reminder injected with ACTIVE agents ---
run_test "Positive: backlog reminder included when ACTIVE agents present"
NOW_EPOCH=$(date +%s)
ACTIVE_EPOCH=$(( NOW_EPOCH - 90 ))
TRACKER_CONTENT="ACTIVE|planner|${ACTIVE_EPOCH}"

OUTPUT=$(run_prompt_submit "do something new" "$TRACKER_CONTENT")

if echo "$OUTPUT" | grep -qi "backlog"; then
    pass_test
else
    fail_test "Backlog reminder not injected with ACTIVE agents: $OUTPUT"
fi

# --- Summary ---
echo ""
echo "=========================================="
echo "Test Results: $TESTS_PASSED/$TESTS_RUN passed"
echo "=========================================="

if [[ $TESTS_FAILED -gt 0 ]]; then
    echo "FAILED: $TESTS_FAILED tests failed"
    exit 1
else
    echo "SUCCESS: All tests passed"
    exit 0
fi
