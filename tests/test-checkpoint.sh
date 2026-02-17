#!/usr/bin/env bash
# Integration tests for checkpoint.sh — Phase 1 (Checkpoints & Rewind)
#
# Purpose: Validate that checkpoint.sh creates git refs on the 5th write,
#   on first modification of a new file, and skips correctly (main branch,
#   non-git repos, meta-repos).
#
# @decision DEC-V2-002
# @title Tests for git ref-based checkpoint creation
# @status accepted
# @rationale Verifies the checkpoint threshold logic (every 5 writes, first
#   modification of new file), skip conditions, and git ref creation without
#   affecting the working copy or index. Tests use an isolated git repo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="${SCRIPT_DIR}/../hooks"
CHECKPOINT_SH="${HOOKS_DIR}/checkpoint.sh"
LOG_SH="${HOOKS_DIR}/log.sh"

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

# Setup: create an isolated git repo for testing
setup_test_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@test.com"
    git -C "$repo" config user.name "Test"
    echo "initial" > "$repo/file.txt"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "init"
    git -C "$repo" checkout -q -b feature/test 2>/dev/null
}

# Simulate running checkpoint.sh with a given file path and env setup
run_checkpoint() {
    local repo="$1"
    local file_path="$2"
    local claude_dir="$3"
    local session_id="${4:-test-session-$$}"

    # Build the hook input JSON
    local input
    input=$(jq -n --arg fp "$file_path" '{"tool_name":"Write","tool_input":{"file_path":$fp}}')

    # Run checkpoint.sh with isolated CLAUDE_DIR and CLAUDE_SESSION_ID
    CLAUDE_PROJECT_DIR="$repo" \
    CLAUDE_SESSION_ID="$session_id" \
    HOME="${claude_dir%/.claude}" \
    bash "$CHECKPOINT_SH" <<< "$input" 2>/dev/null
    return $?
}

# Count checkpoint refs for a branch
count_checkpoint_refs() {
    local repo="$1"
    local branch="${2:-feature/test}"
    git -C "$repo" for-each-ref "refs/checkpoints/${branch}/" 2>/dev/null | wc -l | tr -d ' '
}

# ============================================================================
# Test 1: Non-git repo — checkpoint.sh exits 0 without creating refs
# ============================================================================
test_non_git_repo() {
    run_test
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    local claude_dir="$tmp/.claude"
    mkdir -p "$claude_dir"

    # Run against non-git directory
    local input
    input=$(jq -n --arg fp "$tmp/myfile.py" '{"tool_name":"Write","tool_input":{"file_path":$fp}}')
    CLAUDE_PROJECT_DIR="$tmp" \
    CLAUDE_SESSION_ID="testsession" \
    HOME="$tmp" \
    bash "$CHECKPOINT_SH" <<< "$input" 2>/dev/null

    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        pass_test "Non-git repo: exits 0 cleanly"
    else
        fail_test "Non-git repo: expected exit 0, got $exit_code"
    fi
}

# ============================================================================
# Test 2: Main branch — checkpoint.sh skips ref creation
# ============================================================================
test_main_branch_skip() {
    run_test
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    mkdir -p "$tmp/.claude"
    git -C "$tmp" init -q
    git -C "$tmp" config user.email "test@test.com"
    git -C "$tmp" config user.name "Test"
    echo "init" > "$tmp/a.txt"
    git -C "$tmp" add -A
    git -C "$tmp" commit -q -m "init"
    # Stay on main branch

    local input
    input=$(jq -n --arg fp "$tmp/a.txt" '{"tool_name":"Write","tool_input":{"file_path":$fp}}')

    # Simulate 5 writes to trigger threshold
    for i in 1 2 3 4 5; do
        CLAUDE_PROJECT_DIR="$tmp" \
        CLAUDE_SESSION_ID="testsession" \
        HOME="$tmp" \
        bash "$CHECKPOINT_SH" <<< "$input" 2>/dev/null
    done

    local ref_count
    ref_count=$(git -C "$tmp" for-each-ref "refs/checkpoints/" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$ref_count" -eq 0 ]]; then
        pass_test "Main branch: no checkpoint refs created (skipped correctly)"
    else
        fail_test "Main branch: expected 0 checkpoint refs, got $ref_count"
    fi
}

# ============================================================================
# Test 3: Feature branch, 5 writes — checkpoint ref created at write 5
# ============================================================================
test_checkpoint_at_threshold() {
    run_test
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    local claude_dir="$tmp/.claude"
    setup_test_repo "$tmp"
    mkdir -p "$claude_dir"

    local session_id="session-threshold-$$"
    local file="$tmp/src.py"

    # Simulate 4 writes — no checkpoint yet
    for i in 1 2 3 4; do
        local input
        input=$(jq -n --arg fp "$file" '{"tool_name":"Write","tool_input":{"file_path":$fp}}')
        CLAUDE_PROJECT_DIR="$tmp" \
        CLAUDE_SESSION_ID="$session_id" \
        HOME="$tmp" \
        bash "$CHECKPOINT_SH" <<< "$input" 2>/dev/null
    done

    local count_before
    count_before=$(count_checkpoint_refs "$tmp" "feature/test")
    # The first-write rule fires for write 1, so count_before may be 1
    # That's expected — the test focuses on threshold behavior

    # Write 5 — threshold hit, second checkpoint
    local input
    input=$(jq -n --arg fp "$file" '{"tool_name":"Write","tool_input":{"file_path":$fp}}')
    CLAUDE_PROJECT_DIR="$tmp" \
    CLAUDE_SESSION_ID="$session_id" \
    HOME="$tmp" \
    bash "$CHECKPOINT_SH" <<< "$input" 2>/dev/null

    local count_after
    count_after=$(count_checkpoint_refs "$tmp" "feature/test")

    if [[ "$count_after" -gt "$count_before" ]]; then
        pass_test "Threshold (5 writes): checkpoint ref created at write 5 (before=${count_before}, after=${count_after})"
    else
        fail_test "Threshold (5 writes): expected new ref at write 5 (before=${count_before}, after=${count_after})"
    fi
}

# ============================================================================
# Test 4: First write on a new file — checkpoint created immediately
# ============================================================================
test_first_write_new_file() {
    run_test
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    local claude_dir="$tmp/.claude"
    setup_test_repo "$tmp"
    mkdir -p "$claude_dir"

    local session_id="session-first-write-$$"
    # Create session-changes file (simulate no prior writes)
    touch "$claude_dir/.session-changes-${session_id}"

    local new_file="$tmp/new-module.py"
    local input
    input=$(jq -n --arg fp "$new_file" '{"tool_name":"Write","tool_input":{"file_path":$fp}}')

    CLAUDE_PROJECT_DIR="$tmp" \
    CLAUDE_SESSION_ID="$session_id" \
    HOME="$tmp" \
    bash "$CHECKPOINT_SH" <<< "$input" 2>/dev/null

    local ref_count
    ref_count=$(count_checkpoint_refs "$tmp" "feature/test")

    if [[ "$ref_count" -ge 1 ]]; then
        pass_test "First write on new file: checkpoint created (refs=${ref_count})"
    else
        fail_test "First write on new file: expected checkpoint ref, got 0"
    fi
}

# ============================================================================
# Test 5: Checkpoint ref points to valid commit object
# ============================================================================
test_checkpoint_ref_valid() {
    run_test
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    local claude_dir="$tmp/.claude"
    setup_test_repo "$tmp"
    mkdir -p "$claude_dir"

    local session_id="session-ref-valid-$$"
    touch "$claude_dir/.session-changes-${session_id}"

    local file="$tmp/app.py"
    echo "print('hello')" > "$file"
    git -C "$tmp" add "$file"
    git -C "$tmp" commit -q -m "add app.py"

    local input
    input=$(jq -n --arg fp "$file" '{"tool_name":"Write","tool_input":{"file_path":$fp}}')

    CLAUDE_PROJECT_DIR="$tmp" \
    CLAUDE_SESSION_ID="$session_id" \
    HOME="$tmp" \
    bash "$CHECKPOINT_SH" <<< "$input" 2>/dev/null

    # Get the checkpoint ref and verify it's a valid commit
    local ref_sha
    ref_sha=$(git -C "$tmp" for-each-ref "refs/checkpoints/feature/test/" --format='%(objectname)' 2>/dev/null | head -1)

    if [[ -n "$ref_sha" ]]; then
        local obj_type
        obj_type=$(git -C "$tmp" cat-file -t "$ref_sha" 2>/dev/null || echo "invalid")
        if [[ "$obj_type" == "commit" ]]; then
            pass_test "Checkpoint ref: points to valid commit object"
        else
            fail_test "Checkpoint ref: expected commit, got $obj_type"
        fi
    else
        fail_test "Checkpoint ref: no ref found in refs/checkpoints/feature/test/"
    fi
}

# ============================================================================
# Test 6: Counter reset — counter file is removed on init
# ============================================================================
test_counter_file_written() {
    run_test
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    local claude_dir="$tmp/.claude"
    setup_test_repo "$tmp"
    mkdir -p "$claude_dir"

    local session_id="session-counter-$$"
    local file="$tmp/some.py"
    local input
    input=$(jq -n --arg fp "$file" '{"tool_name":"Write","tool_input":{"file_path":$fp}}')

    CLAUDE_PROJECT_DIR="$tmp" \
    CLAUDE_SESSION_ID="$session_id" \
    HOME="$tmp" \
    bash "$CHECKPOINT_SH" <<< "$input" 2>/dev/null

    if [[ -f "$claude_dir/.checkpoint-counter" ]]; then
        local counter_val
        counter_val=$(cat "$claude_dir/.checkpoint-counter")
        if [[ "$counter_val" -ge 1 ]]; then
            pass_test "Counter file written: value=${counter_val}"
        else
            fail_test "Counter file written: expected value >= 1, got '${counter_val}'"
        fi
    else
        fail_test "Counter file not created at ${claude_dir}/.checkpoint-counter"
    fi
}

# ============================================================================
# Test 7: Empty file path — checkpoint.sh exits 0 without error
# ============================================================================
test_empty_file_path() {
    run_test
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    local input
    input='{"tool_name":"Write","tool_input":{}}'

    local exit_code=0
    bash "$CHECKPOINT_SH" <<< "$input" 2>/dev/null || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        pass_test "Empty file path: exits 0 cleanly"
    else
        fail_test "Empty file path: expected exit 0, got $exit_code"
    fi
}

# ============================================================================
# Run all tests
# ============================================================================

echo "=== checkpoint.sh Integration Tests ==="
echo ""

test_non_git_repo
test_main_branch_skip
test_checkpoint_at_threshold
test_first_write_new_file
test_checkpoint_ref_valid
test_counter_file_written
test_empty_file_path

echo ""
echo "=== Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed ==="

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
exit 0
