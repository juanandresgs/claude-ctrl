#!/usr/bin/env bash
# test-worktree-roster.sh — Test suite for worktree-roster.sh
#
# Tests worktree lifecycle tracking: register, list, stale detection, cleanup, prune
#
# @decision DEC-TEST-001
# @title Test worktree roster without mocking internal functions
# @status accepted
# @rationale Tests use real git repos in tmp/, real file I/O, and real process
# checks. Only external boundary we mock is dead PIDs (via high PID numbers that
# won't exist). This follows Sacred Practice #5: test real implementations, not mocks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROSTER_SCRIPT="$PROJECT_ROOT/scripts/worktree-roster.sh"

# Test registry in tmp
TEST_REGISTRY="$PROJECT_ROOT/tmp/.worktree-roster-test.tsv"

# Setup test environment
setup() {
    # Override registry location for tests
    export REGISTRY="$TEST_REGISTRY"
    rm -f "$TEST_REGISTRY"
    mkdir -p "$(dirname "$TEST_REGISTRY")"
    mkdir -p "$PROJECT_ROOT/tmp/test-worktrees"
}

# Cleanup test environment
teardown() {
    rm -f "$TEST_REGISTRY"
    rm -rf "$PROJECT_ROOT/tmp/test-worktrees"
}

# Test helpers
assert_equals() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"

    if [[ "$expected" != "$actual" ]]; then
        echo "FAIL: ${msg:-assertion failed}"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-}"

    if [[ "$haystack" != *"$needle"* ]]; then
        echo "FAIL: ${msg:-assertion failed}"
        echo "  Expected to contain: $needle"
        echo "  Actual: $haystack"
        return 1
    fi
}

# Test 1: Register a worktree
test_register() {
    echo "TEST: Register worktree"

    local test_path="$PROJECT_ROOT/tmp/test-worktrees/test1"
    mkdir -p "$test_path"
    git -C "$test_path" init --initial-branch=test-branch >/dev/null 2>&1
    git -C "$test_path" config user.email "test@test.com" >/dev/null 2>&1
    git -C "$test_path" config user.name "Test" >/dev/null 2>&1
    touch "$test_path/README.md"
    git -C "$test_path" add . >/dev/null 2>&1
    git -C "$test_path" commit -m "initial" >/dev/null 2>&1

    # Register worktree
    REGISTRY="$TEST_REGISTRY" "$ROSTER_SCRIPT" register "$test_path" --issue=123 --session=test-session

    # Verify entry exists
    if [[ ! -f "$TEST_REGISTRY" ]]; then
        echo "FAIL: Registry not created"
        return 1
    fi

    local entry
    entry=$(cat "$TEST_REGISTRY")

    assert_contains "$entry" "$test_path" "Entry should contain path"
    assert_contains "$entry" "test-branch" "Entry should contain branch"
    assert_contains "$entry" "123" "Entry should contain issue"
    assert_contains "$entry" "test-session" "Entry should contain session"

    echo "PASS: Register worktree"
}

# Test 2: Register is idempotent
test_register_idempotent() {
    echo "TEST: Register is idempotent"

    local test_path="$PROJECT_ROOT/tmp/test-worktrees/test2"
    mkdir -p "$test_path"
    git -C "$test_path" init --initial-branch=test-branch >/dev/null 2>&1
    git -C "$test_path" config user.email "test@test.com" >/dev/null 2>&1
    git -C "$test_path" config user.name "Test" >/dev/null 2>&1
    touch "$test_path/README.md"
    git -C "$test_path" add . >/dev/null 2>&1
    git -C "$test_path" commit -m "initial" >/dev/null 2>&1

    # Register twice
    REGISTRY="$TEST_REGISTRY" "$ROSTER_SCRIPT" register "$test_path" --issue=123
    REGISTRY="$TEST_REGISTRY" "$ROSTER_SCRIPT" register "$test_path" --issue=456

    # Should have only one entry
    local count
    count=$(grep -c "^" "$TEST_REGISTRY")
    assert_equals "1" "$count" "Should have only one entry"

    # Should have updated issue number
    local entry
    entry=$(cat "$TEST_REGISTRY")
    assert_contains "$entry" "456" "Should have updated issue number"

    echo "PASS: Register is idempotent"
}

# Test 3: List worktrees
test_list() {
    echo "TEST: List worktrees"

    local test_path="$PROJECT_ROOT/tmp/test-worktrees/test3"
    mkdir -p "$test_path"
    git -C "$test_path" init --initial-branch=test-branch >/dev/null 2>&1
    git -C "$test_path" config user.email "test@test.com" >/dev/null 2>&1
    git -C "$test_path" config user.name "Test" >/dev/null 2>&1
    touch "$test_path/README.md"
    git -C "$test_path" add . >/dev/null 2>&1
    git -C "$test_path" commit -m "initial" >/dev/null 2>&1

    REGISTRY="$TEST_REGISTRY" "$ROSTER_SCRIPT" register "$test_path" --issue=789

    # List worktrees
    local output
    output=$(REGISTRY="$TEST_REGISTRY" "$ROSTER_SCRIPT" list)

    assert_contains "$output" "$test_path" "List should contain path"
    assert_contains "$output" "test-branch" "List should contain branch"
    assert_contains "$output" "789" "List should contain issue"

    echo "PASS: List worktrees"
}

# Test 4: Stale detection (mock dead PID)
test_stale_detection() {
    echo "TEST: Stale detection"

    local test_path="$PROJECT_ROOT/tmp/test-worktrees/test4"
    mkdir -p "$test_path"
    git -C "$test_path" init --initial-branch=test-branch >/dev/null 2>&1
    git -C "$test_path" config user.email "test@test.com" >/dev/null 2>&1
    git -C "$test_path" config user.name "Test" >/dev/null 2>&1
    touch "$test_path/README.md"
    git -C "$test_path" add . >/dev/null 2>&1
    git -C "$test_path" commit -m "initial" >/dev/null 2>&1

    # Create entry with dead PID (PID 999999 should not exist)
    local created_at
    created_at=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${test_path}\ttest-branch\t999\ttest-session\t999999\t${created_at}" > "$TEST_REGISTRY"

    # Check stale
    local output
    output=$(REGISTRY="$TEST_REGISTRY" "$ROSTER_SCRIPT" stale || true)

    assert_contains "$output" "$test_path" "Stale should contain path"

    echo "PASS: Stale detection"
}

# Test 5: Prune orphaned entries
test_prune() {
    echo "TEST: Prune orphaned entries"

    local test_path1="$PROJECT_ROOT/tmp/test-worktrees/test5-exists"
    local test_path2="$PROJECT_ROOT/tmp/test-worktrees/test5-gone"

    mkdir -p "$test_path1"
    # test_path2 intentionally not created

    local created_at
    created_at=$(date '+%Y-%m-%d %H:%M:%S')

    # Create entries for both
    cat > "$TEST_REGISTRY" <<EOF
${test_path1}	test-branch	100	session1	$$	${created_at}
${test_path2}	test-branch	200	session2	$$	${created_at}
EOF

    # Prune
    REGISTRY="$TEST_REGISTRY" "$ROSTER_SCRIPT" prune

    # Verify only existing path remains
    local count
    count=$(grep -c "^" "$TEST_REGISTRY")
    assert_equals "1" "$count" "Should have pruned one entry"

    local entry
    entry=$(cat "$TEST_REGISTRY")
    assert_contains "$entry" "$test_path1" "Should keep existing path"

    if [[ "$entry" == *"$test_path2"* ]]; then
        echo "FAIL: Should not contain gone path"
        return 1
    fi

    echo "PASS: Prune orphaned entries"
}

# Test 6: JSON output
test_json_output() {
    echo "TEST: JSON output"

    local test_path="$PROJECT_ROOT/tmp/test-worktrees/test6"
    mkdir -p "$test_path"
    git -C "$test_path" init --initial-branch=test-branch >/dev/null 2>&1
    git -C "$test_path" config user.email "test@test.com" >/dev/null 2>&1
    git -C "$test_path" config user.name "Test" >/dev/null 2>&1
    touch "$test_path/README.md"
    git -C "$test_path" add . >/dev/null 2>&1
    git -C "$test_path" commit -m "initial" >/dev/null 2>&1

    REGISTRY="$TEST_REGISTRY" "$ROSTER_SCRIPT" register "$test_path" --issue=111

    # Get JSON output
    local output
    output=$(REGISTRY="$TEST_REGISTRY" "$ROSTER_SCRIPT" list --json)

    # Verify it's valid JSON
    if ! echo "$output" | jq . >/dev/null 2>&1; then
        echo "FAIL: Invalid JSON output"
        return 1
    fi

    # Verify contains expected fields
    assert_contains "$output" '"path"' "JSON should have path field"
    assert_contains "$output" '"branch"' "JSON should have branch field"
    assert_contains "$output" '"issue"' "JSON should have issue field"
    assert_contains "$output" '"status"' "JSON should have status field"

    echo "PASS: JSON output"
}

# Run all tests
run_tests() {
    local failed=0
    local passed=0

    for test_func in test_register test_register_idempotent test_list test_stale_detection test_prune test_json_output; do
        setup
        if $test_func; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
        fi
        teardown
        echo ""
    done

    echo "=========================================="
    echo "Results: $passed passed, $failed failed"
    echo "=========================================="

    if [[ "$failed" -gt 0 ]]; then
        exit 1
    fi
}

# Main
if [[ ! -x "$ROSTER_SCRIPT" ]]; then
    echo "ERROR: worktree-roster.sh not found or not executable at $ROSTER_SCRIPT"
    exit 1
fi

run_tests
