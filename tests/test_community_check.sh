#!/usr/bin/env bash
# Unit tests for community-check.sh
#
# Purpose: Validate community contribution notification logic including
# disable toggle, output format, filtering, and gh CLI integration.
#
# Rationale: community-check.sh is user-facing and runs on every session start.
# Tests ensure it behaves correctly when gh is missing or disable toggle
# is set. Real gh API calls are avoided in tests.
#
# @decision DEC-COMMUNITY-001
# @title Unit tests with mock gh CLI for community-check.sh
# @status accepted
# @rationale Tests use a mock gh script to simulate API responses without
# hitting GitHub API rate limits. The test validates cache behavior, filtering
# logic (exclude self-authored, exclude claude-todo labels), and JSON output
# structure. Real integration tests would require API tokens and live repos.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMUNITY_CHECK="${SCRIPT_DIR}/../scripts/community-check.sh"

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
    echo -e "  ${YELLOW}Expected:${NC} $2"
    echo -e "  ${YELLOW}Got:${NC} $3"
}

run_test() {
    TESTS_RUN=$((TESTS_RUN + 1))
}

# Setup test environment
setup() {
    TEST_DIR=$(mktemp -d)
    export HOME="$TEST_DIR"
    mkdir -p "$TEST_DIR/.claude"

    # Create mock gh that we can control
    MOCK_GH="$TEST_DIR/bin/gh"
    mkdir -p "$TEST_DIR/bin"
    cat > "$MOCK_GH" << 'EOF'
#!/usr/bin/env bash
# Mock gh CLI for testing
case "$*" in
    "auth status")
        echo "Logged in to github.com as testuser"
        exit 0
        ;;
    "api user --jq .login")
        echo "testuser"
        exit 0
        ;;
    "repo list testuser --public --json name --limit 100")
        cat << 'REPOS'
[
  {"name": "repo1"},
  {"name": "repo2"}
]
REPOS
        exit 0
        ;;
    "pr list --repo testuser/repo1"*)
        cat << 'PRS'
[
  {"number": 1, "title": "Fix bug", "author": {"login": "contributor1"}, "createdAt": "2026-02-10T10:00:00Z"},
  {"number": 2, "title": "Add feature", "author": {"login": "testuser"}, "createdAt": "2026-02-11T10:00:00Z"}
]
PRS
        exit 0
        ;;
    "pr list --repo testuser/repo2"*)
        echo "[]"
        exit 0
        ;;
    "issue list --repo testuser/repo1"*)
        cat << 'ISSUES'
[
  {"number": 5, "title": "Bug report", "author": {"login": "contributor2"}, "labels": [], "createdAt": "2026-02-12T10:00:00Z"},
  {"number": 6, "title": "Todo item", "author": {"login": "contributor3"}, "labels": [{"name": "claude-todo"}], "createdAt": "2026-02-13T10:00:00Z"}
]
ISSUES
        exit 0
        ;;
    "issue list --repo testuser/repo2"*)
        echo "[]"
        exit 0
        ;;
    *)
        echo "Unknown command: $*" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$MOCK_GH"
    export PATH="$TEST_DIR/bin:$PATH"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# Test 1: Disable toggle - script exits silently
test_disable_toggle() {
    run_test
    echo "Test 1: Disable toggle prevents execution"

    setup
    touch "$HOME/.claude/.disable-community-check"

    # Run script - should exit 0 without creating status file
    "$COMMUNITY_CHECK" 2>/dev/null || true

    if [[ -f "$HOME/.claude/.community-status" ]]; then
        fail_test "Disable toggle" "no status file" "status file created"
        teardown
        return
    fi

    pass_test "Disable toggle works"
    teardown
}

# Test 2: Always refreshes - no cache, fresh data every session
test_always_refreshes() {
    run_test
    echo "Test 2: Always refreshes (no cache TTL)"

    setup

    # Create an existing status file with old timestamp
    OLD_TS=$(($(date +%s) - 60))
    cat > "$HOME/.claude/.community-status" << EOF
{
  "status": "none",
  "checked_at": ${OLD_TS},
  "total_prs": 0,
  "total_issues": 0,
  "items": []
}
EOF

    # Run script - should always refresh, even with recent status file
    "$COMMUNITY_CHECK" 2>/dev/null || true

    # Check that checked_at timestamp was updated (proves it re-ran)
    NEW_CHECKED_AT=$(jq -r '.checked_at' "$HOME/.claude/.community-status" 2>/dev/null || echo "0")

    if [[ "$NEW_CHECKED_AT" -le "$OLD_TS" ]]; then
        fail_test "Always refreshes" "updated timestamp" "timestamp not updated"
        teardown
        return
    fi

    pass_test "Always refreshes on every session"
    teardown
}

# Test 3: Output format validation
test_output_format() {
    run_test
    echo "Test 3: JSON output format validation"

    setup

    # Remove any existing status file
    rm -f "$HOME/.claude/.community-status"

    # Run script
    "$COMMUNITY_CHECK" 2>/dev/null || true

    # Validate JSON structure
    if ! jq -e '.status' "$HOME/.claude/.community-status" >/dev/null 2>&1; then
        fail_test "JSON structure" "valid .status field" "missing or invalid"
        teardown
        return
    fi

    if ! jq -e '.checked_at' "$HOME/.claude/.community-status" >/dev/null 2>&1; then
        fail_test "JSON structure" "valid .checked_at field" "missing or invalid"
        teardown
        return
    fi

    if ! jq -e '.total_prs' "$HOME/.claude/.community-status" >/dev/null 2>&1; then
        fail_test "JSON structure" "valid .total_prs field" "missing or invalid"
        teardown
        return
    fi

    if ! jq -e '.total_issues' "$HOME/.claude/.community-status" >/dev/null 2>&1; then
        fail_test "JSON structure" "valid .total_issues field" "missing or invalid"
        teardown
        return
    fi

    if ! jq -e '.items' "$HOME/.claude/.community-status" >/dev/null 2>&1; then
        fail_test "JSON structure" "valid .items array" "missing or invalid"
        teardown
        return
    fi

    pass_test "JSON output format is valid"
    teardown
}

# Test 4: Filtering logic - self-authored items and claude-todo labels
test_filtering() {
    run_test
    echo "Test 4: Filtering self-authored and claude-todo items"

    setup

    # Remove any existing status file
    rm -f "$HOME/.claude/.community-status"

    # Run script
    "$COMMUNITY_CHECK" 2>/dev/null || true

    # Check results
    TOTAL_PRS=$(jq -r '.total_prs' "$HOME/.claude/.community-status" 2>/dev/null || echo "0")
    TOTAL_ISSUES=$(jq -r '.total_issues' "$HOME/.claude/.community-status" 2>/dev/null || echo "0")

    # Mock has 2 PRs (1 from testuser, 1 from contributor1) and 2 issues (1 normal, 1 with claude-todo)
    # Expected: 1 PR (contributor1) and 1 issue (contributor2, not claude-todo)

    if [[ "$TOTAL_PRS" != "1" ]]; then
        fail_test "PR filtering" "1 PR (excluding self-authored)" "$TOTAL_PRS PRs"
        teardown
        return
    fi

    if [[ "$TOTAL_ISSUES" != "1" ]]; then
        fail_test "Issue filtering" "1 issue (excluding claude-todo)" "$TOTAL_ISSUES issues"
        teardown
        return
    fi

    # Verify the item details
    PR_AUTHOR=$(jq -r '.items[] | select(.type=="pr") | .author' "$HOME/.claude/.community-status" 2>/dev/null || echo "")
    if [[ "$PR_AUTHOR" != "contributor1" ]]; then
        fail_test "PR author" "contributor1" "$PR_AUTHOR"
        teardown
        return
    fi

    ISSUE_AUTHOR=$(jq -r '.items[] | select(.type=="issue") | .author' "$HOME/.claude/.community-status" 2>/dev/null || echo "")
    if [[ "$ISSUE_AUTHOR" != "contributor2" ]]; then
        fail_test "Issue author" "contributor2" "$ISSUE_AUTHOR"
        teardown
        return
    fi

    pass_test "Filtering logic works correctly"
    teardown
}

# Test 5: Missing gh CLI - graceful exit
test_missing_gh() {
    run_test
    echo "Test 5: Missing gh CLI - graceful exit"

    # Create test dir WITHOUT mock gh
    TEST_DIR=$(mktemp -d)
    export HOME="$TEST_DIR"
    mkdir -p "$TEST_DIR/.claude"
    export PATH="/usr/bin:/bin"  # Remove our mock from PATH

    # Run script - should exit gracefully
    "$COMMUNITY_CHECK" 2>/dev/null || true

    # Should not create status file when gh is missing
    if [[ -f "$HOME/.claude/.community-status" ]]; then
        fail_test "Missing gh handling" "no status file" "status file created"
        rm -rf "$TEST_DIR"
        return
    fi

    pass_test "Missing gh CLI handled gracefully"
    rm -rf "$TEST_DIR"
}

# Run all tests
echo "Running community-check.sh tests..."
echo ""

test_disable_toggle
test_always_refreshes
test_output_format
test_filtering
test_missing_gh

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
