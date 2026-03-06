#!/usr/bin/env bash
# Tests for hooks/source-lib.sh — direct hook library sourcing.
#
# Purpose: Validate that source-lib.sh correctly sources log.sh and
#   context-lib.sh from the hooks/ directory. Verifies syntax validity,
#   function availability after sourcing, and that all hooks can source
#   the library without error.
#
# @decision DEC-SRCLIB-001
# @title Tests for direct hook library sourcing
# @status accepted
# @rationale Tests prove three properties: (1) source-lib.sh has valid syntax,
#   (2) sourcing it makes log and context functions available, (3) all 34 hooks
#   pass syntax validation. These replace the cache-based tests after the
#   caching mechanism was removed due to its single-point-of-failure risk.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="${SCRIPT_DIR}/../hooks"
SOURCE_LIB="${HOOKS_DIR}/source-lib.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass_test() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}PASS${NC} $1"
}

fail_test() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}FAIL${NC} $1"
    echo -e "  ${YELLOW}Details:${NC} $2"
}

run_test() {
    TESTS_RUN=$((TESTS_RUN + 1))
}

# ============================================================================
# Test 1: Syntax check on source-lib.sh itself
# ============================================================================

test_source_lib_syntax() {
    run_test
    if bash -n "$SOURCE_LIB" 2>/dev/null; then
        pass_test "source-lib.sh passes bash -n syntax check"
    else
        local err
        err=$(bash -n "$SOURCE_LIB" 2>&1)
        fail_test "source-lib.sh has syntax errors" "$err"
    fi
}

# ============================================================================
# Test 2: Sourcing provides log functions
# ============================================================================

test_sourcing_provides_log_functions() {
    run_test
    local result
    result=$(
        bash -c "
            source '${SOURCE_LIB}' 2>/dev/null
            type log_info > /dev/null 2>&1 && echo OK || echo MISSING
        "
    )

    if [[ "$result" == "OK" ]]; then
        pass_test "Sourcing source-lib.sh provides log_info function"
    else
        fail_test "log_info not available after sourcing" "result=$result"
    fi
}

# ============================================================================
# Test 3: Sourcing provides context functions
# ============================================================================

test_sourcing_provides_context_functions() {
    run_test
    local result
    result=$(
        bash -c "
            source '${SOURCE_LIB}' 2>/dev/null
            type detect_project_root > /dev/null 2>&1 && echo OK || echo MISSING
        "
    )

    if [[ "$result" == "OK" ]]; then
        pass_test "Sourcing source-lib.sh provides detect_project_root function"
    else
        fail_test "detect_project_root not available after sourcing" "result=$result"
    fi
}

# ============================================================================
# Test 4: No cache directory created (caching removed)
# ============================================================================

test_no_cache_directory_created() {
    run_test
    local test_session="srclib-test-$$-${RANDOM}"
    local cache_dir="${HOME}/.claude/.hook-cache/${test_session}"

    # Ensure no prior cache
    rm -rf "$cache_dir"

    CLAUDE_SESSION_ID="$test_session" bash -c "source '${SOURCE_LIB}'" 2>/dev/null

    if [[ ! -d "$cache_dir" ]]; then
        pass_test "No cache directory created (caching removed)"
    else
        fail_test "Cache directory unexpectedly created" "dir=$cache_dir"
        rm -rf "$cache_dir"
    fi
}

# ============================================================================
# Test 5: log.sh and source-lib.sh syntax validity
# ============================================================================

test_library_files_syntax() {
    run_test
    local failed=()

    if ! bash -n "${HOOKS_DIR}/log.sh" 2>/dev/null; then
        failed+=("log.sh")
    fi
    if ! bash -n "${HOOKS_DIR}/source-lib.sh" 2>/dev/null; then
        failed+=("source-lib.sh")
    fi

    if [[ ${#failed[@]} -eq 0 ]]; then
        pass_test "log.sh and source-lib.sh pass bash -n syntax check"
    else
        fail_test "Library files have syntax errors" "${failed[*]}"
    fi
}

# ============================================================================
# Test 6: All hooks that source source-lib.sh pass syntax check
# ============================================================================

test_all_hooks_syntax() {
    run_test
    local failed_hooks=()
    local hooks_dir="${SCRIPT_DIR}/../hooks"

    local all_hooks=(
        "check-explore.sh" "check-general-purpose.sh" "check-guardian.sh" "check-implementer.sh"
        "check-planner.sh" "check-tester.sh" "ci-lib.sh" "compact-preserve.sh"
        "core-lib.sh" "doc-lib.sh" "git-lib.sh"
        "log.sh" "notify.sh" "plan-lib.sh" "playwright-cleanup.sh"
        "post-task.sh" "post-write.sh" "pre-bash.sh" "pre-write.sh"
        "prompt-submit.sh" "session-end.sh" "session-init.sh" "session-lib.sh"
        "skill-result.sh" "source-lib.sh" "state-lib.sh" "stop.sh"
        "subagent-start.sh" "task-track.sh" "test-runner.sh" "trace-lib.sh"
        "track-agent-tokens.sh" "webfetch-fallback.sh"
    )

    for hook in "${all_hooks[@]}"; do
        local hook_path="${hooks_dir}/${hook}"
        if [[ ! -f "$hook_path" ]]; then
            failed_hooks+=("MISSING:${hook}")
            continue
        fi
        if ! bash -n "$hook_path" 2>/dev/null; then
            failed_hooks+=("SYNTAX_ERROR:${hook}")
        fi
    done

    if [[ ${#failed_hooks[@]} -eq 0 ]]; then
        pass_test "All 34 hooks pass bash -n syntax check"
    else
        fail_test "Some hooks failed syntax check" "${failed_hooks[*]}"
    fi
}

# ============================================================================
# Test 7: Multiple sourcing in same shell is idempotent
# ============================================================================

test_idempotent_sourcing() {
    run_test
    local result
    result=$(
        bash -c "
            source '${SOURCE_LIB}' 2>/dev/null
            source '${SOURCE_LIB}' 2>/dev/null
            type log_info > /dev/null 2>&1 && type detect_project_root > /dev/null 2>&1 && echo OK || echo FAIL
        "
    )

    if [[ "$result" == "OK" ]]; then
        pass_test "Double-sourcing source-lib.sh is idempotent"
    else
        fail_test "Double-sourcing caused errors" "result=$result"
    fi
}

# ============================================================================
# Run all tests
# ============================================================================

echo "Running test-source-lib.sh -- direct hook library sourcing"
echo ""

test_source_lib_syntax
test_sourcing_provides_log_functions
test_sourcing_provides_context_functions
test_no_cache_directory_created
test_library_files_syntax
test_all_hooks_syntax
test_idempotent_sourcing

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
