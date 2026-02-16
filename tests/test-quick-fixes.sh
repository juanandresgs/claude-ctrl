#!/usr/bin/env bash
# Integration tests for quick fixes: #77 (double-nested paths), #34 (deleted CWD), #40 (PRD auto-save)
#
# Purpose: Validate three independent bug fixes:
#   1. get_claude_dir() prevents double-nesting when PROJECT_ROOT is ~/.claude
#   2. detect_project_root() recovers from deleted CWD
#   3. /prd skill auto-saves output to predictable paths
#
# @decision DEC-QUICKFIX-001
# @title Test suite for proof-status path fix, CWD recovery, and PRD auto-save
# @status accepted
# @rationale Tests cover the three bug fixes in isolation. Uses temp directories
#   to simulate various scenarios without affecting the real environment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_SH="${SCRIPT_DIR}/../hooks/log.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counter
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Helper functions
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

# ============================================================================
# Test 1: get_claude_dir() prevents double-nesting (#77)
# ============================================================================

test_get_claude_dir_normal_project() {
    run_test
    echo -n "Testing get_claude_dir() with normal project root... "

    # Create temp project
    local temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    # Source log.sh in a subshell to test get_claude_dir
    local result
    result=$(
        source "$LOG_SH"
        PROJECT_ROOT="$temp_dir"
        get_claude_dir
    )

    local expected="${temp_dir}/.claude"
    if [[ "$result" == "$expected" ]]; then
        pass_test "Normal project returns PROJECT_ROOT/.claude"
    else
        fail_test "Normal project path wrong" "Expected: $expected, Got: $result"
    fi
}

test_get_claude_dir_home_claude() {
    run_test
    echo -n "Testing get_claude_dir() when PROJECT_ROOT is ~/.claude... "

    # Simulate PROJECT_ROOT being ~/.claude
    local result
    result=$(
        source "$LOG_SH"
        PROJECT_ROOT="${HOME}/.claude"
        get_claude_dir
    )

    local expected="${HOME}/.claude"
    if [[ "$result" == "$expected" ]]; then
        pass_test "~/.claude project returns PROJECT_ROOT (no double-nest)"
    else
        fail_test "~/.claude path wrong" "Expected: $expected, Got: $result"
    fi
}

test_proof_status_path_in_home_claude() {
    run_test
    echo -n "Testing .proof-status path when PROJECT_ROOT is ~/.claude... "

    # Test that proof-status path doesn't double-nest
    # Simulate the real scenario: HOME/.claude is the project root
    local result
    result=$(
        source "$LOG_SH"
        export PROJECT_ROOT="${HOME}/.claude"
        CLAUDE_DIR=$(get_claude_dir)
        echo "${CLAUDE_DIR}/.proof-status"
    )

    local expected="${HOME}/.claude/.proof-status"
    if [[ "$result" == "$expected" ]]; then
        pass_test ".proof-status path correct (no .claude/.claude/)"
    else
        fail_test ".proof-status path wrong" "Expected: $expected, Got: $result"
    fi
}

# ============================================================================
# Test 2: detect_project_root() recovers from deleted CWD (#34)
# ============================================================================

test_deleted_cwd_recovery() {
    run_test
    echo -n "Testing detect_project_root() recovery from deleted CWD... "

    # Create temp directory and cd into it
    local temp_dir=$(mktemp -d)
    local original_pwd="$PWD"

    # Create a subshell to test deletion scenario
    local result
    result=$(
        cd "$temp_dir"
        # Delete the directory while we're inside it
        rm -rf "$temp_dir"
        # Source log.sh and call detect_project_root
        source "$LOG_SH" 2>&1
        detect_project_root
    )

    # Should recover to HOME or /
    if [[ "$result" == "$HOME" || "$result" == "/" ]]; then
        pass_test "Deleted CWD recovers to safe fallback"
    else
        fail_test "Deleted CWD recovery failed" "Expected HOME or /, got: $result"
    fi
}

test_deleted_cwd_warning() {
    run_test
    echo -n "Testing detect_project_root() emits warning for deleted CWD... "

    # Create temp directory and cd into it
    local temp_dir=$(mktemp -d)

    # Test in subshell
    local output
    output=$(
        cd "$temp_dir"
        rm -rf "$temp_dir"
        source "$LOG_SH" 2>&1
        detect_project_root 2>&1
    )

    if echo "$output" | grep -q "WARNING.*CWD was deleted"; then
        pass_test "Warning message emitted for deleted CWD"
    else
        fail_test "No warning for deleted CWD" "Output: $output"
    fi
}

# ============================================================================
# Test 3: PRD skill auto-saves output (#40)
# ============================================================================

test_prd_skill_has_autosave_instruction() {
    run_test
    echo -n "Testing PRD skill has auto-save instruction... "

    local prd_skill="${SCRIPT_DIR}/../skills/prd/SKILL.md"
    if [[ ! -f "$prd_skill" ]]; then
        fail_test "PRD skill not found" "Expected at $prd_skill"
        return
    fi

    # Check if the skill mentions auto-save to .claude/prds/
    if grep -q "\.claude/prds/" "$prd_skill"; then
        pass_test "PRD skill contains auto-save instruction"
    else
        fail_test "PRD skill missing auto-save" "No mention of .claude/prds/ in SKILL.md"
    fi
}

# ============================================================================
# Run all tests
# ============================================================================

echo "Running quick-fixes test suite..."
echo ""

# Fix #77: get_claude_dir()
test_get_claude_dir_normal_project
test_get_claude_dir_home_claude
test_proof_status_path_in_home_claude

# Fix #34: deleted CWD recovery
test_deleted_cwd_recovery
test_deleted_cwd_warning

# Fix #40: PRD auto-save
test_prd_skill_has_autosave_instruction

# Summary
echo ""
echo "========================================="
echo "Test Results:"
echo "  Total: $TESTS_RUN"
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
