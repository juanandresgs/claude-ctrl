#!/usr/bin/env bash
# Integration tests for session-init.sh community status handling
#
# Purpose: Validate that session-init.sh correctly backgrounds community-check.sh
# and does NOT display community status (display moved to statusline.sh and todo.sh).
#
# Rationale: After the performance fix, session-init.sh only triggers the background
# check but does not wait for or display results. This test verifies that community
# status does NOT appear in session-init.sh output, confirming the display logic
# has been successfully moved to statusline and backlog.
#
# @decision DEC-COMMUNITY-002
# @title Integration tests for session-init.sh community background check
# @status accepted
# @rationale Tests validate that session-init.sh backgrounds the check and does
#   not display community status, which is now handled by statusline.sh and todo.sh.
#   Uses isolated temp directories to avoid side effects. Real git repo created
#   in each test to satisfy session-init.sh requirements.

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

# Test 1: Community display removed from session-init.sh
test_no_community_display() {
    run_test
    echo "Test 1: session-init.sh does not display community status"

    setup

    cat > "$HOME/.claude/.community-status" << 'EOF'
{
  "status": "active",
  "checked_at": 1234567890,
  "total_prs": 5,
  "total_issues": 3,
  "items": [
    {"type": "pr", "repo": "repo1", "number": 1, "title": "PR 1", "author": "user1"}
  ]
}
EOF

    # Run session-init.sh and capture output
    OUTPUT=$("$SESSION_INIT" 2>/dev/null || true)

    # Check that "Community:" does NOT appear in output (moved to statusline/todo)
    if echo "$OUTPUT" | grep -q "Community:"; then
        fail_test "No community display" "Community status should not appear in session-init.sh output"
        teardown
        return
    fi

    pass_test "session-init.sh does not display community status (moved to statusline/todo)"
    teardown
}

# Test 2: Verify background job actually runs
test_background_job_executes() {
    run_test
    echo "Test 3: Background check actually executes and creates status file"

    setup

    # Mock community-check.sh that writes a marker file
    mkdir -p "$HOME/.claude/scripts"
    cat > "$HOME/.claude/scripts/community-check.sh" << 'EOF'
#!/usr/bin/env bash
echo '{"status":"active","checked_at":1234567890,"total_prs":2,"total_issues":1,"items":[]}' > "$HOME/.claude/.community-status"
EOF
    chmod +x "$HOME/.claude/scripts/community-check.sh"

    # Remove any existing status file
    rm -f "$HOME/.claude/.community-status"

    # Run session-init.sh
    OUTPUT=$("$SESSION_INIT" 2>/dev/null || true)

    # Wait a moment for background job to complete
    sleep 0.5

    # Check that status file was created by the background job
    if [[ ! -f "$HOME/.claude/.community-status" ]]; then
        fail_test "Background job execution" "Status file not created by background job"
        teardown
        return
    fi

    # Verify content
    STATUS=$(jq -r '.status' "$HOME/.claude/.community-status" 2>/dev/null || echo "")
    if [[ "$STATUS" != "active" ]]; then
        fail_test "Background job execution" "Status file has unexpected content: $STATUS"
        teardown
        return
    fi

    pass_test "Background check executes and creates status file"
    teardown
}

# Run all tests
echo "Running session-init.sh community integration tests..."
echo ""

test_no_community_display
test_background_job_executes

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
