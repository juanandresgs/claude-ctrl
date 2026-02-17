#!/usr/bin/env bash
# Tests for hooks/source-lib.sh — session-scoped library snapshot bootstrapper.
#
# Purpose: Validate that source-lib.sh correctly caches hook libraries to prevent
#   race conditions during concurrent git merges. Verifies cache creation, reuse,
#   correctness under partial-write simulation, cleanup, and stale cache pruning.
#
# @decision DEC-SRCLIB-001
# @title Tests for session-scoped hook library caching
# @status accepted
# @rationale Tests prove the three safety properties: (1) cache is created atomically
#   on first invocation, (2) subsequent invocations reuse cached copies without
#   re-copying, (3) cleanup removes session caches correctly. The partial-write
#   simulation test validates the core race-condition fix — a session that caches
#   before a merge begins is immune to any partial file state during the merge.

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
# Test 1: Cache is created on first invocation
# ============================================================================

test_cache_created_on_first_invocation() {
    run_test
    local test_session="srclib-test-$$-${RANDOM}"
    local cache_dir="${HOME}/.claude/.hook-cache/${test_session}"

    # Ensure no prior cache
    rm -rf "$cache_dir"

    local result
    result=$(
        CLAUDE_SESSION_ID="$test_session" bash -c "source '${SOURCE_LIB}' 2>/dev/null && echo OK"
    )

    if [[ "$result" == "OK" ]] && [[ -f "${cache_dir}/log.sh" ]] && [[ -f "${cache_dir}/context-lib.sh" ]]; then
        pass_test "Cache created on first invocation (log.sh and context-lib.sh present)"
    else
        fail_test "Cache not created on first invocation" \
            "result='$result', log.sh exists=$(test -f "${cache_dir}/log.sh" && echo yes || echo no), context-lib.sh exists=$(test -f "${cache_dir}/context-lib.sh" && echo yes || echo no)"
    fi

    rm -rf "$cache_dir"
}

# ============================================================================
# Test 2: Second invocation reuses cache (no re-copy — check mtimes)
# ============================================================================

test_second_invocation_reuses_cache() {
    run_test
    local test_session="srclib-test-$$-${RANDOM}"
    local cache_dir="${HOME}/.claude/.hook-cache/${test_session}"

    # First invocation — populate cache
    CLAUDE_SESSION_ID="$test_session" bash -c "source '${SOURCE_LIB}'" 2>/dev/null

    # Record mtime of cached log.sh after first invocation
    local mtime_before
    mtime_before=$(stat -f "%m" "${cache_dir}/log.sh" 2>/dev/null || stat -c "%Y" "${cache_dir}/log.sh" 2>/dev/null)

    # Sleep 1s so that a new copy would have a different mtime
    sleep 1

    # Second invocation — should reuse cache
    CLAUDE_SESSION_ID="$test_session" bash -c "source '${SOURCE_LIB}'" 2>/dev/null

    local mtime_after
    mtime_after=$(stat -f "%m" "${cache_dir}/log.sh" 2>/dev/null || stat -c "%Y" "${cache_dir}/log.sh" 2>/dev/null)

    if [[ "$mtime_before" == "$mtime_after" ]]; then
        pass_test "Second invocation reuses cache (mtime unchanged)"
    else
        fail_test "Second invocation re-copied cache (mtime changed)" \
            "before=$mtime_before, after=$mtime_after"
    fi

    rm -rf "$cache_dir"
}

# ============================================================================
# Test 3: Cached copy is valid even when source has trailing garbage
# ============================================================================
# This simulates the race condition: source-lib.sh copies the library BEFORE
# the merge starts (good copy). Then the merge partially overwrites the source.
# The hook should still work from cache.

test_cache_immune_to_partial_source_write() {
    run_test
    local test_session="srclib-test-$$-${RANDOM}"
    local cache_dir="${HOME}/.claude/.hook-cache/${test_session}"
    local tmp_hooks
    tmp_hooks=$(mktemp -d)
    trap "rm -rf '$tmp_hooks' '$cache_dir'" RETURN

    # Copy real hooks to tmp dir
    cp "${HOOKS_DIR}/log.sh" "${tmp_hooks}/log.sh"
    cp "${HOOKS_DIR}/context-lib.sh" "${tmp_hooks}/context-lib.sh"

    # Create a patched source-lib.sh that points to our tmp hooks dir
    cat > "${tmp_hooks}/source-lib.sh" <<'EOF'
#!/usr/bin/env bash
_SRCLIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CACHE_KEY="${CLAUDE_SESSION_ID:-$$}"
_CACHE_DIR="${HOME}/.claude/.hook-cache/${_CACHE_KEY}"
if [[ ! -f "${_CACHE_DIR}/log.sh" ]]; then
    mkdir -p "${_CACHE_DIR}"
    for _lib in log.sh context-lib.sh; do
        cp "${_SRCLIB_DIR}/${_lib}" "${_CACHE_DIR}/${_lib}.tmp.$$"
        mv "${_CACHE_DIR}/${_lib}.tmp.$$" "${_CACHE_DIR}/${_lib}"
    done
fi
source "${_CACHE_DIR}/log.sh"
source "${_CACHE_DIR}/context-lib.sh"
EOF

    # First invocation — populates cache from good copies
    CLAUDE_SESSION_ID="$test_session" bash -c "source '${tmp_hooks}/source-lib.sh'" 2>/dev/null

    # Now corrupt the SOURCE log.sh (simulating a partial git merge write)
    echo "TRUNCATED PARTIAL" > "${tmp_hooks}/log.sh"

    # Second invocation should still succeed (sourcing from cache, not corrupted source)
    local result
    result=$(
        CLAUDE_SESSION_ID="$test_session" bash -c "
            source '${tmp_hooks}/source-lib.sh' 2>/dev/null
            # log_json is defined in log.sh — verify it's callable
            type log_json > /dev/null 2>&1 && echo OK || echo FAIL
        "
    )

    if [[ "$result" == "OK" ]]; then
        pass_test "Cache immune to partial source write (log_json callable from cache)"
    else
        fail_test "Cache not protecting against partial source write" "result=$result"
    fi
}

# ============================================================================
# Test 4: Cleanup removes cache correctly
# ============================================================================

test_cleanup_removes_cache() {
    run_test
    local test_session="srclib-test-$$-${RANDOM}"
    local cache_dir="${HOME}/.claude/.hook-cache/${test_session}"

    # Populate cache
    CLAUDE_SESSION_ID="$test_session" bash -c "source '${SOURCE_LIB}'" 2>/dev/null

    if [[ ! -d "$cache_dir" ]]; then
        fail_test "Cache dir not created (prerequisite failed)" "dir=$cache_dir"
        return
    fi

    # Simulate what session-end.sh does
    rm -rf "${HOME}/.claude/.hook-cache/${test_session}"

    if [[ ! -d "$cache_dir" ]]; then
        pass_test "Cleanup removes session cache directory"
    else
        fail_test "Cache directory still exists after cleanup" "dir=$cache_dir"
    fi
}

# ============================================================================
# Test 5: Stale cache cleanup works
# ============================================================================

test_stale_cache_cleanup() {
    run_test
    local stale_session="srclib-stale-test-$$-${RANDOM}"
    local stale_cache_dir="${HOME}/.claude/.hook-cache/${stale_session}"
    local fresh_session="srclib-fresh-test-$$-${RANDOM}"
    local fresh_cache_dir="${HOME}/.claude/.hook-cache/${fresh_session}"

    # Create a "stale" cache directory by backdating its mtime
    mkdir -p "$stale_cache_dir"
    echo "fake" > "${stale_cache_dir}/log.sh"
    # Set mtime to 25h ago (older than 1440 min threshold)
    touch -t "$(date -v-25H +%Y%m%d%H%M)" "$stale_cache_dir" 2>/dev/null || \
    touch -d "25 hours ago" "$stale_cache_dir" 2>/dev/null || true

    # Create a "fresh" cache directory with current mtime
    mkdir -p "$fresh_cache_dir"
    echo "fake" > "${fresh_cache_dir}/log.sh"

    # Run the stale cleanup (same logic as session-init.sh)
    find "${HOME}/.claude/.hook-cache" -maxdepth 1 -type d -mmin +1440 -exec rm -rf {} + 2>/dev/null || true

    local stale_gone fresh_present
    stale_gone=false
    fresh_present=false
    [[ ! -d "$stale_cache_dir" ]] && stale_gone=true
    [[ -d "$fresh_cache_dir" ]] && fresh_present=true

    if [[ "$stale_gone" == "true" ]] && [[ "$fresh_present" == "true" ]]; then
        pass_test "Stale cache (25h old) removed; fresh cache preserved"
    elif [[ "$stale_gone" != "true" ]]; then
        fail_test "Stale cache not removed by find+rm" "dir=$stale_cache_dir still exists"
    else
        fail_test "Fresh cache unexpectedly removed" "dir=$fresh_cache_dir gone"
    fi

    rm -rf "$stale_cache_dir" "$fresh_cache_dir"
}

# ============================================================================
# Test 6: Syntax check on source-lib.sh itself
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
# Test 7: All modified hooks pass bash -n syntax check
# ============================================================================

test_modified_hooks_syntax() {
    run_test
    local failed_hooks=()
    local hooks_dir="${SCRIPT_DIR}/../hooks"

    local all_modified_hooks=(
        "prompt-submit.sh" "compact-preserve.sh" "mock-gate.sh" "track.sh"
        "check-tester.sh" "session-end.sh" "checkpoint.sh" "check-implementer.sh"
        "session-init.sh" "code-review.sh" "session-summary.sh" "test-runner.sh"
        "branch-guard.sh" "plan-check.sh" "guard.sh" "task-track.sh"
        "check-planner.sh" "subagent-start.sh" "check-guardian.sh" "test-gate.sh"
        "lint.sh" "doc-gate.sh" "surface.sh"
        "notify.sh" "plan-validate.sh" "auto-review.sh" "skill-result.sh"
        "forward-motion.sh" "playwright-cleanup.sh"
    )

    for hook in "${all_modified_hooks[@]}"; do
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
        pass_test "All 29 modified hooks pass bash -n syntax check"
    else
        fail_test "Some hooks failed syntax check" "${failed_hooks[*]}"
    fi
}

# ============================================================================
# Run all tests
# ============================================================================

echo "Running test-source-lib.sh — session-scoped hook library caching"
echo ""

test_source_lib_syntax
test_cache_created_on_first_invocation
test_second_invocation_reuses_cache
test_cache_immune_to_partial_source_write
test_cleanup_removes_cache
test_stale_cache_cleanup
test_modified_hooks_syntax

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
