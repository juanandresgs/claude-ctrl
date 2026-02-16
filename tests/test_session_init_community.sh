#!/usr/bin/env bash
# Integration tests for session-init.sh community status display
#
# Purpose: Validate that session-init.sh correctly reads .community-status
# and formats it for display in the session startup context.
#
# Rationale: session-init.sh is the user-facing hook that displays community
# contributions. These tests verify correct JSON parsing, formatting logic
# (≤3 items shows details, >3 shows counts), and silent behavior for "none".
#
# @decision DEC-COMMUNITY-002
# @title Integration tests for session-init.sh community status formatting
# @status accepted
# @rationale Tests validate the display logic that users see at session startup.
#   Covers edge cases (0 items, 1-3 items with details, >3 items with summary,
#   PRs-only, issues-only). Uses isolated temp directories to avoid side effects.
#   Real git repo created in each test to satisfy session-init.sh requirements.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_INIT="${SCRIPT_DIR}/../hooks/session-init.sh"

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

# Setup test environment
setup() {
    TEST_DIR=$(mktemp -d)
    export HOME="$TEST_DIR"
    mkdir -p "$TEST_DIR/.claude"

    # Create a minimal git repo to satisfy session-init.sh requirements
    cd "$TEST_DIR"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test User"
    touch README.md
    git add README.md
    git commit -q -m "Initial commit"
}

teardown() {
    cd /
    rm -rf "$TEST_DIR"
}

# Test 1: Status "none" - no output
test_status_none() {
    run_test
    echo "Test 1: Status 'none' produces no output"

    setup

    cat > "$HOME/.claude/.community-status" << 'EOF'
{
  "status": "none",
  "checked_at": 1234567890,
  "total_prs": 0,
  "total_issues": 0,
  "items": []
}
EOF

    # Run session-init.sh and capture output
    OUTPUT=$("$SESSION_INIT" 2>/dev/null || true)

    # Check that "Community:" does NOT appear in output
    if echo "$OUTPUT" | grep -q "Community:"; then
        fail_test "Status none" "Output should not contain 'Community:' but it does"
        teardown
        return
    fi

    pass_test "Status 'none' produces no output"
    teardown
}

# Test 2: Status "active" with 1 item - shows detail
test_single_item() {
    run_test
    echo "Test 2: Single item shows detail"

    setup

    cat > "$HOME/.claude/.community-status" << 'EOF'
{
  "status": "active",
  "checked_at": 1234567890,
  "total_prs": 1,
  "total_issues": 0,
  "items": [
    {
      "type": "pr",
      "repo": "test-repo",
      "number": 42,
      "title": "Fix critical bug",
      "author": "contributor1"
    }
  ]
}
EOF

    # Run session-init.sh and capture output
    OUTPUT=$("$SESSION_INIT" 2>/dev/null || true)

    # Check that output contains expected detail
    if ! echo "$OUTPUT" | grep -q "Community: PR #42 on test-repo (Fix critical bug) by contributor1"; then
        fail_test "Single item detail" "Expected detailed PR output but got: $OUTPUT"
        teardown
        return
    fi

    pass_test "Single item shows detail correctly"
    teardown
}

# Test 3: Status "active" with 3 items - shows details
test_three_items() {
    run_test
    echo "Test 3: Three items show details"

    setup

    cat > "$HOME/.claude/.community-status" << 'EOF'
{
  "status": "active",
  "checked_at": 1234567890,
  "total_prs": 2,
  "total_issues": 1,
  "items": [
    {
      "type": "pr",
      "repo": "repo1",
      "number": 1,
      "title": "PR 1",
      "author": "user1"
    },
    {
      "type": "pr",
      "repo": "repo2",
      "number": 2,
      "title": "PR 2",
      "author": "user2"
    },
    {
      "type": "issue",
      "repo": "repo3",
      "number": 3,
      "title": "Issue 3",
      "author": "user3"
    }
  ]
}
EOF

    # Run session-init.sh and capture output
    OUTPUT=$("$SESSION_INIT" 2>/dev/null || true)

    # Check that output contains all three items
    if ! echo "$OUTPUT" | grep -q "Community: PR #1 on repo1"; then
        fail_test "Three items" "Missing PR #1 in output"
        teardown
        return
    fi

    if ! echo "$OUTPUT" | grep -q "Community: PR #2 on repo2"; then
        fail_test "Three items" "Missing PR #2 in output"
        teardown
        return
    fi

    if ! echo "$OUTPUT" | grep -q "Community: Issue #3 on repo3"; then
        fail_test "Three items" "Missing Issue #3 in output"
        teardown
        return
    fi

    pass_test "Three items show details correctly"
    teardown
}

# Test 4: Status "active" with >3 items - shows summary
test_many_items() {
    run_test
    echo "Test 4: More than 3 items show summary counts"

    setup

    cat > "$HOME/.claude/.community-status" << 'EOF'
{
  "status": "active",
  "checked_at": 1234567890,
  "total_prs": 3,
  "total_issues": 2,
  "items": [
    {"type": "pr", "repo": "repo1", "number": 1, "title": "PR 1", "author": "user1"},
    {"type": "pr", "repo": "repo2", "number": 2, "title": "PR 2", "author": "user2"},
    {"type": "pr", "repo": "repo3", "number": 3, "title": "PR 3", "author": "user3"},
    {"type": "issue", "repo": "repo4", "number": 4, "title": "Issue 4", "author": "user4"},
    {"type": "issue", "repo": "repo5", "number": 5, "title": "Issue 5", "author": "user5"}
  ]
}
EOF

    # Run session-init.sh and capture output
    OUTPUT=$("$SESSION_INIT" 2>/dev/null || true)

    # Check that output contains summary counts, not individual items
    if ! echo "$OUTPUT" | grep -q "Community: 3 open PRs + 2 issues across your repos"; then
        fail_test "Many items summary" "Expected summary counts but got: $OUTPUT"
        teardown
        return
    fi

    pass_test "More than 3 items show summary correctly"
    teardown
}

# Test 5: Only PRs (no issues)
test_only_prs() {
    run_test
    echo "Test 5: Only PRs (no issues) shows correct summary"

    setup

    cat > "$HOME/.claude/.community-status" << 'EOF'
{
  "status": "active",
  "checked_at": 1234567890,
  "total_prs": 5,
  "total_issues": 0,
  "items": [
    {"type": "pr", "repo": "repo1", "number": 1, "title": "PR 1", "author": "user1"},
    {"type": "pr", "repo": "repo2", "number": 2, "title": "PR 2", "author": "user2"},
    {"type": "pr", "repo": "repo3", "number": 3, "title": "PR 3", "author": "user3"},
    {"type": "pr", "repo": "repo4", "number": 4, "title": "PR 4", "author": "user4"},
    {"type": "pr", "repo": "repo5", "number": 5, "title": "PR 5", "author": "user5"}
  ]
}
EOF

    # Run session-init.sh and capture output
    OUTPUT=$("$SESSION_INIT" 2>/dev/null || true)

    # Check that output shows only PRs
    if ! echo "$OUTPUT" | grep -q "Community: 5 open PRs across your repos"; then
        fail_test "Only PRs" "Expected 'Community: 5 open PRs across your repos' but got: $OUTPUT"
        teardown
        return
    fi

    pass_test "Only PRs shows correct summary"
    teardown
}

# Test 6: Only issues (no PRs)
test_only_issues() {
    run_test
    echo "Test 6: Only issues (no PRs) shows correct summary"

    setup

    cat > "$HOME/.claude/.community-status" << 'EOF'
{
  "status": "active",
  "checked_at": 1234567890,
  "total_prs": 0,
  "total_issues": 4,
  "items": [
    {"type": "issue", "repo": "repo1", "number": 1, "title": "Issue 1", "author": "user1"},
    {"type": "issue", "repo": "repo2", "number": 2, "title": "Issue 2", "author": "user2"},
    {"type": "issue", "repo": "repo3", "number": 3, "title": "Issue 3", "author": "user3"},
    {"type": "issue", "repo": "repo4", "number": 4, "title": "Issue 4", "author": "user4"}
  ]
}
EOF

    # Run session-init.sh and capture output
    OUTPUT=$("$SESSION_INIT" 2>/dev/null || true)

    # Check that output shows only issues
    if ! echo "$OUTPUT" | grep -q "Community: 4 open issues across your repos"; then
        fail_test "Only issues" "Expected 'Community: 4 open issues across your repos' but got: $OUTPUT"
        teardown
        return
    fi

    pass_test "Only issues shows correct summary"
    teardown
}

# Run all tests
echo "Running session-init.sh community integration tests..."
echo ""

test_status_none
test_single_item
test_three_items
test_many_items
test_only_prs
test_only_issues

# Summary
echo ""
echo "========================================="
echo "Test Summary"
echo "========================================="
echo "Tests run:    $TESTS_RUN"
echo -e "${GREEN}Passed:       $TESTS_PASSED${NC}"
if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "${RED}Failed:       $TESTS_FAILED${NC}"
    exit 1
else
    echo "Failed:       0"
    echo ""
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
