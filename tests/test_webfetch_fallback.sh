#!/usr/bin/env bash
# test_webfetch_fallback.sh — Tests for webfetch-fallback.sh PostToolUse hook
#
# Purpose: Verifies that the webfetch-fallback.sh hook correctly detects WebFetch failures
# and outputs retry guidance, while remaining silent on success.
#
# Rationale: The hook is a critical part of the resilient fetch strategy. These tests ensure
# it fires correctly on failure patterns and doesn't interfere with successful fetches.
#
# @decision DEC-FETCH-004
# @title Test suite for WebFetch fallback hook
# @status accepted
# @rationale Hook behavior is deterministic and critical to the fallback strategy.
#            Tests verify failure detection patterns (error keywords, empty output, null)
#            and confirm the hook remains silent on successful fetches.

set -euo pipefail

# Determine hook path - use worktree path if testing from worktree, else use main repo
if [ -f "hooks/webfetch-fallback.sh" ]; then
    HOOK_PATH="hooks/webfetch-fallback.sh"
else
    HOOK_PATH="${HOME}/.claude/hooks/webfetch-fallback.sh"
fi

PASS_COUNT=0
FAIL_COUNT=0

# Color codes for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Test helper
run_test() {
    local test_name="$1"
    local input_json="$2"
    local expected_exit="$3"
    local expected_output_pattern="$4"

    echo "Testing: $test_name"

    # Run hook with input
    local output
    local exit_code=0
    output=$(echo "$input_json" | bash "$HOOK_PATH" 2>&1) || exit_code=$?

    # Check exit code
    if [ "$exit_code" -ne "$expected_exit" ]; then
        echo -e "${RED}✗ FAIL${NC}: Expected exit code $expected_exit, got $exit_code"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi

    # Check output pattern
    if [ -n "$expected_output_pattern" ]; then
        if echo "$output" | grep -q "$expected_output_pattern"; then
            echo -e "${GREEN}✓ PASS${NC}: Output contains expected pattern"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            echo -e "${RED}✗ FAIL${NC}: Output does not contain '$expected_output_pattern'"
            echo "Actual output: $output"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            return 1
        fi
    else
        # Expect empty output
        if [ -z "$output" ]; then
            echo -e "${GREEN}✓ PASS${NC}: Output is empty as expected"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            echo -e "${RED}✗ FAIL${NC}: Expected empty output, got: $output"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            return 1
        fi
    fi
}

echo "=== WebFetch Fallback Hook Tests ==="
echo

# Test 1: Error in output (blocked domain)
run_test "Blocked domain error" \
    '{"tool_name":"WebFetch","tool_input":{"url":"https://archive.ph/test"},"tool_output":"Error: This domain is blocked"}' \
    0 \
    "mcp__fetch__fetch"

# Test 2: Failed fetch
run_test "Failed fetch" \
    '{"tool_name":"WebFetch","tool_input":{"url":"https://example.com"},"tool_output":"Error: Failed to fetch content"}' \
    0 \
    "mcp__fetch__fetch"

# Test 3: Cascade error (sibling tool call)
run_test "Cascade error" \
    '{"tool_name":"WebFetch","tool_input":{"url":"https://example.com"},"tool_output":"Error: Sibling tool call errored"}' \
    0 \
    "batch-fetch.py"

# Test 4: Timeout error
run_test "Timeout error" \
    '{"tool_name":"WebFetch","tool_input":{"url":"https://slow.example.com"},"tool_output":"Error: timeout exceeded"}' \
    0 \
    "mcp__fetch__fetch"

# Test 5: Empty output
run_test "Empty output" \
    '{"tool_name":"WebFetch","tool_input":{"url":"https://example.com"},"tool_output":""}' \
    0 \
    "mcp__fetch__fetch"

# Test 6: Null output
run_test "Null output" \
    '{"tool_name":"WebFetch","tool_input":{"url":"https://example.com"},"tool_output":null}' \
    0 \
    "mcp__fetch__fetch"

# Test 7: Success case (should output nothing)
run_test "Successful fetch" \
    '{"tool_name":"WebFetch","tool_input":{"url":"https://example.com"},"tool_output":"Example Domain\nThis domain is for use in illustrative examples..."}' \
    0 \
    ""

# Test 8: Another success case with HTML
run_test "Successful HTML fetch" \
    '{"tool_name":"WebFetch","tool_input":{"url":"https://example.com"},"tool_output":"<html><body>Content here</body></html>"}' \
    0 \
    ""

echo
echo "=== Test Summary ==="
echo -e "${GREEN}Passed: $PASS_COUNT${NC}"
echo -e "${RED}Failed: $FAIL_COUNT${NC}"

if [ "$FAIL_COUNT" -eq 0 ]; then
    echo -e "\n${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "\n${RED}Some tests failed${NC}"
    exit 1
fi
