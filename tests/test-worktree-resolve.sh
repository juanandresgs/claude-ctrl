#!/usr/bin/env bash
# test-worktree-resolve.sh — Tests for _resolve_to_main_worktree() and
#   worktree-aware detect_project_root() in hooks/log.sh.
#
# Purpose: Verify that when CWD is inside a git worktree,
#   detect_project_root() returns the main repo root (not the worktree path),
#   so project_hash() produces a consistent hash across main and worktree contexts.
#
# Problem solved: When CWD is in a worktree, git rev-parse --show-toplevel
#   returns the worktree path, not the main repo root. This breaks lifetime
#   token sums, cache file paths, and proof-status lookups because the hash
#   differs between main and worktree invocations.
#
# @decision DEC-TEST-WORKTREE-RESOLVE-001
# @title Test _resolve_to_main_worktree and worktree-aware detect_project_root
# @status accepted
# @rationale Tests verify the fix for worktree-hash-mismatch using real git
#   repos in tmp/ (no mocks). Creates a real main repo + real worktree to
#   exercise the actual git-common-dir path. Follows Sacred Practice #5.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="${PROJECT_ROOT}/hooks"
LOG_SH="${HOOKS_DIR}/log.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass_test() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "${GREEN}PASS${NC} $1"
}

fail_test() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "${RED}FAIL${NC} $1"
    echo -e "  ${YELLOW}Details:${NC} $2"
}

# Temporary directory for test repos (in project tmp/, not /tmp/)
TEST_TMP="${PROJECT_ROOT}/tmp/test-worktree-resolve-$$"

setup_test_repos() {
    mkdir -p "$TEST_TMP"

    # Create a main test repo
    local main_repo="${TEST_TMP}/main-repo"
    mkdir -p "$main_repo"
    git -C "$main_repo" init --initial-branch=main >/dev/null 2>&1
    git -C "$main_repo" config user.email "test@test.com" >/dev/null 2>&1
    git -C "$main_repo" config user.name "Test" >/dev/null 2>&1
    touch "$main_repo/README.md"
    git -C "$main_repo" add README.md >/dev/null 2>&1
    git -C "$main_repo" commit -m "initial commit" >/dev/null 2>&1

    # Create a linked worktree off the main repo
    local worktree_dir="${TEST_TMP}/main-repo-worktrees/feature-test"
    mkdir -p "${TEST_TMP}/main-repo-worktrees"
    git -C "$main_repo" worktree add "$worktree_dir" -b feature/test >/dev/null 2>&1

    echo "$main_repo"  # Return main repo path
}

teardown_test_repos() {
    rm -rf "$TEST_TMP"
}

# ============================================================================
# Test 1: _resolve_to_main_worktree returns input unchanged for non-worktree
# ============================================================================

test_resolve_non_worktree() {
    local main_repo="${TEST_TMP}/main-repo"

    # Source log.sh to get the function
    # shellcheck disable=SC1090
    source "$LOG_SH" 2>/dev/null

    local result
    result=$(_resolve_to_main_worktree "$main_repo")

    if [[ "$result" == "$main_repo" ]]; then
        pass_test "_resolve_to_main_worktree: returns input unchanged for main repo root"
    else
        fail_test "_resolve_to_main_worktree: returns input unchanged for main repo root" \
            "Expected '$main_repo', got '$result'"
    fi
}

# ============================================================================
# Test 2: _resolve_to_main_worktree returns main repo root for worktree paths
# ============================================================================

test_resolve_worktree_path() {
    local main_repo="${TEST_TMP}/main-repo"
    local worktree_dir="${TEST_TMP}/main-repo-worktrees/feature-test"

    # Source log.sh
    # shellcheck disable=SC1090
    source "$LOG_SH" 2>/dev/null

    local result
    result=$(_resolve_to_main_worktree "$worktree_dir")

    if [[ "$result" == "$main_repo" ]]; then
        pass_test "_resolve_to_main_worktree: returns main repo root for worktree path"
    else
        fail_test "_resolve_to_main_worktree: returns main repo root for worktree path" \
            "Expected '$main_repo', got '$result'"
    fi
}

# ============================================================================
# Test 3: _resolve_to_main_worktree handles invalid paths gracefully
# ============================================================================

test_resolve_invalid_path() {
    # Source log.sh
    # shellcheck disable=SC1090
    source "$LOG_SH" 2>/dev/null

    local result
    result=$(_resolve_to_main_worktree "/nonexistent/path/that/does/not/exist")

    # Should return input unchanged when git fails
    if [[ "$result" == "/nonexistent/path/that/does/not/exist" ]]; then
        pass_test "_resolve_to_main_worktree: returns input unchanged for invalid path"
    else
        fail_test "_resolve_to_main_worktree: returns input unchanged for invalid path" \
            "Expected '/nonexistent/path/that/does/not/exist', got '$result'"
    fi
}

# ============================================================================
# Test 4: detect_project_root returns main repo root when HOOK_INPUT has worktree cwd
# ============================================================================

test_detect_project_root_from_worktree_hook_input() {
    local main_repo="${TEST_TMP}/main-repo"
    local worktree_dir="${TEST_TMP}/main-repo-worktrees/feature-test"

    # Source log.sh
    # shellcheck disable=SC1090
    source "$LOG_SH" 2>/dev/null

    # Simulate HOOK_INPUT with worktree as cwd (like Claude Code would provide)
    export HOOK_INPUT="{\"cwd\":\"$worktree_dir\",\"session_id\":\"test-session\"}"
    unset CLAUDE_PROJECT_DIR 2>/dev/null || true

    local result
    result=$(detect_project_root)

    # Unset to avoid polluting other tests
    unset HOOK_INPUT 2>/dev/null || true
    unset CLAUDE_PROJECT_DIR 2>/dev/null || true

    if [[ "$result" == "$main_repo" ]]; then
        pass_test "detect_project_root: returns main repo root when HOOK_INPUT.cwd is worktree"
    else
        fail_test "detect_project_root: returns main repo root when HOOK_INPUT.cwd is worktree" \
            "Expected '$main_repo', got '$result'"
    fi
}

# ============================================================================
# Test 5: detect_project_root returns main repo root when HOOK_INPUT has subdir of worktree
# ============================================================================

test_detect_project_root_from_worktree_subdir() {
    local main_repo="${TEST_TMP}/main-repo"
    local worktree_dir="${TEST_TMP}/main-repo-worktrees/feature-test"

    # Create a subdir in the worktree
    mkdir -p "${worktree_dir}/src"

    # Source log.sh
    # shellcheck disable=SC1090
    source "$LOG_SH" 2>/dev/null

    # Simulate HOOK_INPUT with worktree subdir as cwd
    export HOOK_INPUT="{\"cwd\":\"${worktree_dir}/src\",\"session_id\":\"test-session\"}"
    unset CLAUDE_PROJECT_DIR 2>/dev/null || true

    local result
    result=$(detect_project_root)

    unset HOOK_INPUT 2>/dev/null || true
    unset CLAUDE_PROJECT_DIR 2>/dev/null || true

    if [[ "$result" == "$main_repo" ]]; then
        pass_test "detect_project_root: returns main repo root when HOOK_INPUT.cwd is worktree subdir"
    else
        fail_test "detect_project_root: returns main repo root when HOOK_INPUT.cwd is worktree subdir" \
            "Expected '$main_repo', got '$result'"
    fi
}

# ============================================================================
# Test 6: project_hash is consistent whether computed from main repo or worktree
# ============================================================================

test_project_hash_consistency() {
    local main_repo="${TEST_TMP}/main-repo"
    local worktree_dir="${TEST_TMP}/main-repo-worktrees/feature-test"

    # Source log.sh
    # shellcheck disable=SC1090
    source "$LOG_SH" 2>/dev/null

    # Hash from main repo path (after resolution — should be unchanged)
    local main_resolved
    main_resolved=$(_resolve_to_main_worktree "$main_repo")
    local hash_from_main
    hash_from_main=$(project_hash "$main_resolved")

    # Hash from worktree path (after resolution — should become main_repo)
    local worktree_resolved
    worktree_resolved=$(_resolve_to_main_worktree "$worktree_dir")
    local hash_from_worktree
    hash_from_worktree=$(project_hash "$worktree_resolved")

    if [[ "$hash_from_main" == "$hash_from_worktree" ]]; then
        pass_test "project_hash: consistent hash from main and worktree (hash=${hash_from_main})"
    else
        fail_test "project_hash: consistent hash from main and worktree" \
            "Main hash='$hash_from_main', Worktree hash='$hash_from_worktree' — they must match"
    fi
}

# ============================================================================
# Test 7: Verify fix on the REAL ~/.claude repo (integration test)
# ============================================================================

test_real_claude_worktree() {
    # This test uses the actual ~/.claude repo and its worktrees
    local claude_root="${HOME}/.claude"

    # Source log.sh
    # shellcheck disable=SC1090
    source "$LOG_SH" 2>/dev/null

    # Find an actual worktree in the ~/.claude repo
    local worktree_path
    worktree_path=$(git -C "$claude_root" worktree list --porcelain 2>/dev/null \
        | grep "^worktree " | grep -v "^worktree ${claude_root}$" | head -1 | sed 's/^worktree //')

    if [[ -z "$worktree_path" || ! -d "$worktree_path" ]]; then
        echo -e "${YELLOW}SKIP${NC} test_real_claude_worktree: no worktrees found in ~/.claude"
        TESTS_RUN=$((TESTS_RUN + 1))
        return
    fi

    local resolved
    resolved=$(_resolve_to_main_worktree "$worktree_path")

    if [[ "$resolved" == "$claude_root" ]]; then
        pass_test "_resolve_to_main_worktree: resolves real ~/.claude worktree to repo root"
    else
        fail_test "_resolve_to_main_worktree: resolves real ~/.claude worktree to repo root" \
            "Expected '$claude_root', got '$resolved'"
    fi
}

# ============================================================================
# Test 8: detect_project_root returns main repo root when CWD is worktree (no HOOK_INPUT)
# ============================================================================

test_detect_project_root_cwd_worktree() {
    local main_repo="${TEST_TMP}/main-repo"
    local worktree_dir="${TEST_TMP}/main-repo-worktrees/feature-test"

    # Run in a subshell to avoid polluting test environment CWD
    local result
    result=$(
        # shellcheck disable=SC1090
        source "$LOG_SH" 2>/dev/null
        unset CLAUDE_PROJECT_DIR 2>/dev/null || true
        HOOK_INPUT=""
        # Change CWD to worktree within subshell (safe — contained in subshell)
        cd "$worktree_dir" && detect_project_root
    )

    if [[ "$result" == "$main_repo" ]]; then
        pass_test "detect_project_root: returns main repo root when CWD is worktree (no HOOK_INPUT)"
    else
        fail_test "detect_project_root: returns main repo root when CWD is worktree (no HOOK_INPUT)" \
            "Expected '$main_repo', got '$result'"
    fi
}

# ============================================================================
# Main
# ============================================================================

main() {
    echo "=== test-worktree-resolve.sh ==="
    echo "Testing _resolve_to_main_worktree() and worktree-aware detect_project_root()"
    echo ""

    # Setup test repos
    setup_test_repos >/dev/null

    # Run tests
    test_resolve_non_worktree
    test_resolve_worktree_path
    test_resolve_invalid_path
    test_detect_project_root_from_worktree_hook_input
    test_detect_project_root_from_worktree_subdir
    test_project_hash_consistency
    test_real_claude_worktree
    test_detect_project_root_cwd_worktree

    # Cleanup
    teardown_test_repos

    echo ""
    echo "=== Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed ==="

    if (( TESTS_FAILED > 0 )); then
        exit 1
    fi
}

main "$@"
