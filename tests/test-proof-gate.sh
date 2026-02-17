#!/usr/bin/env bash
# Test proof-status gate bootstrapping and state machine
#
# @decision DEC-TEST-PROOF-GATE-001
# @title Proof-status gate bootstrapping test suite
# @status accepted
# @rationale Tests the proof-status gate state machine which prevents commits
#   without verification while avoiding bootstrap deadlock. Validates that
#   missing .proof-status allows commits (bootstrap path), implementer dispatch
#   activates the gate, and only verified status allows Guardian dispatch.
#   Also validates the guard.sh Check 10 which blocks deletion of active gates.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"

# Ensure tmp directory exists
mkdir -p "$PROJECT_ROOT/tmp"

# Track test results
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
    local test_name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "Running: $test_name"
}

pass_test() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  ✓ PASS"
}

fail_test() {
    local reason="$1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  ✗ FAIL: $reason"
}

# --- Test 1: Syntax validation ---
run_test "Syntax: guard.sh is valid bash"
if bash -n "$HOOKS_DIR/guard.sh"; then
    pass_test
else
    fail_test "guard.sh has syntax errors"
fi

run_test "Syntax: task-track.sh is valid bash"
if bash -n "$HOOKS_DIR/task-track.sh"; then
    pass_test
else
    fail_test "task-track.sh has syntax errors"
fi

# --- Test 2-9: task-track.sh Gate A (Guardian dispatch) ---
# These tests validate the Guardian gate behavior in task-track.sh

# Helper to run task-track.sh with mock input
run_task_track() {
    local agent_type="$1"
    local proof_file="$2"  # Path to .proof-status or "missing"

    # Create a temp git repo (not meta-repo)
    local TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-pg-repo-XXXXXX")
    git -C "$TEMP_REPO" init > /dev/null 2>&1
    mkdir -p "$TEMP_REPO/.claude"

    # Set up .proof-status if not missing
    if [[ "$proof_file" != "missing" ]]; then
        echo "$proof_file" > "$TEMP_REPO/.claude/.proof-status"
    fi

    # Mock input JSON
    local INPUT_JSON=$(cat <<EOF
{
  "tool_name": "Task",
  "tool_input": {
    "subagent_type": "$agent_type",
    "instructions": "Test task"
  }
}
EOF
)

    # Run hook with mocked environment
    local OUTPUT
    OUTPUT=$(cd "$TEMP_REPO" && \
             CLAUDE_PROJECT_DIR="$TEMP_REPO" \
             echo "$INPUT_JSON" | bash "$HOOKS_DIR/task-track.sh" 2>&1)
    local EXIT_CODE=$?

    # Cleanup - ensure we're not in TEMP_REPO before deleting
    cd "$PROJECT_ROOT"
    rm -rf "$TEMP_REPO"

    # Return output and exit code
    echo "$OUTPUT"
    return $EXIT_CODE
}

run_test "Gate A: Missing .proof-status allows Guardian dispatch (bootstrap)"
OUTPUT=$(run_task_track "guardian" "missing" 2>&1) || true
if echo "$OUTPUT" | grep -q "deny"; then
    fail_test "Guardian blocked when .proof-status missing (should allow)"
else
    pass_test
fi

run_test "Gate A: needs-verification blocks Guardian dispatch"
OUTPUT=$(run_task_track "guardian" "needs-verification|12345" 2>&1) || true
if echo "$OUTPUT" | grep -q "deny" && echo "$OUTPUT" | grep -q "needs-verification"; then
    pass_test
else
    fail_test "Guardian allowed with needs-verification status"
fi

run_test "Gate A: pending blocks Guardian dispatch"
OUTPUT=$(run_task_track "guardian" "pending|12345" 2>&1) || true
if echo "$OUTPUT" | grep -q "deny" && echo "$OUTPUT" | grep -q "pending"; then
    pass_test
else
    fail_test "Guardian allowed with pending status"
fi

run_test "Gate A: verified allows Guardian dispatch"
OUTPUT=$(run_task_track "guardian" "verified|12345" 2>&1) || true
if echo "$OUTPUT" | grep -q "deny"; then
    fail_test "Guardian blocked with verified status (should allow)"
else
    pass_test
fi

# --- Test 10: task-track.sh Gate C (Implementer activation) ---
run_test "Gate C: Implementer dispatch creates needs-verification"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-pg-impl-XXXXXX")
git -C "$TEMP_REPO" init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.claude"

INPUT_JSON=$(cat <<'EOF'
{
  "tool_name": "Task",
  "tool_input": {
    "subagent_type": "implementer",
    "instructions": "Test implementation"
  }
}
EOF
)

cd "$TEMP_REPO" && \
    CLAUDE_PROJECT_DIR="$TEMP_REPO" \
    echo "$INPUT_JSON" | bash "$HOOKS_DIR/task-track.sh" > /dev/null 2>&1

if [[ -f "$TEMP_REPO/.claude/.proof-status" ]]; then
    STATUS=$(cut -d'|' -f1 "$TEMP_REPO/.claude/.proof-status")
    if [[ "$STATUS" == "needs-verification" ]]; then
        pass_test
    else
        fail_test "Created .proof-status with wrong status: $STATUS"
    fi
else
    fail_test "Implementer did not create .proof-status"
fi

rm -rf "$TEMP_REPO"

# --- Test 11: gate activation only when missing ---
run_test "Gate C: Implementer does not overwrite existing .proof-status"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-pg-exist-XXXXXX")
git -C "$TEMP_REPO" init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.claude"
echo "pending|99999" > "$TEMP_REPO/.claude/.proof-status"

cd "$TEMP_REPO" && \
    CLAUDE_PROJECT_DIR="$TEMP_REPO" \
    echo "$INPUT_JSON" | bash "$HOOKS_DIR/task-track.sh" > /dev/null 2>&1

STATUS=$(cut -d'|' -f1 "$TEMP_REPO/.claude/.proof-status")
TIMESTAMP=$(cut -d'|' -f2 "$TEMP_REPO/.claude/.proof-status")

if [[ "$STATUS" == "pending" && "$TIMESTAMP" == "99999" ]]; then
    pass_test
else
    fail_test "Implementer overwrote existing .proof-status"
fi

rm -rf "$TEMP_REPO"

# --- Tests 12-15: guard.sh Check 6-7 (test-status gate inversion) ---

# Helper to run guard.sh with mock input
run_guard() {
    local command="$1"
    local test_file="$2"  # Path to .test-status or "missing"

    # Create a temp git repo
    local TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-pg-guard-XXXXXX")
    git -C "$TEMP_REPO" init > /dev/null 2>&1
    mkdir -p "$TEMP_REPO/.claude"

    # Set up .test-status if not missing
    if [[ "$test_file" != "missing" ]]; then
        echo "$test_file" > "$TEMP_REPO/.claude/.test-status"
    fi

    # Mock input JSON
    local INPUT_JSON=$(cat <<EOF
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "cd $TEMP_REPO && $command"
  }
}
EOF
)

    # Run hook — cd into temp repo so detect_project_root finds it (not meta-repo)
    local OUTPUT
    OUTPUT=$(cd "$TEMP_REPO" && \
             echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1)
    local EXIT_CODE=$?

    # Cleanup - ensure we're not in TEMP_REPO before deleting
    cd "$PROJECT_ROOT"
    rm -rf "$TEMP_REPO"

    echo "$OUTPUT"
    return $EXIT_CODE
}

run_test "Check 7: Missing .test-status allows commit (bootstrap)"
OUTPUT=$(run_guard "git commit -m test" "missing" 2>&1) || true
if echo "$OUTPUT" | grep -q "deny"; then
    fail_test "Commit blocked when .test-status missing (should allow)"
else
    pass_test
fi

run_test "Check 6: Missing .test-status allows merge (bootstrap)"
OUTPUT=$(run_guard "git merge feature" "missing" 2>&1) || true
if echo "$OUTPUT" | grep -q "deny"; then
    fail_test "Merge blocked when .test-status missing (should allow)"
else
    pass_test
fi

run_test "Check 7: fail test-status blocks commit"
RECENT_TIME=$(date +%s)
OUTPUT=$(run_guard "git commit -m test" "fail|2|$RECENT_TIME|10" 2>&1) || true
if echo "$OUTPUT" | grep -q "deny" && echo "$OUTPUT" | grep -q "failing"; then
    pass_test
else
    fail_test "Commit allowed with failing tests"
fi

run_test "Check 6: fail test-status blocks merge"
RECENT_TIME=$(date +%s)
OUTPUT=$(run_guard "git merge feature" "fail|2|$RECENT_TIME|10" 2>&1) || true
if echo "$OUTPUT" | grep -q "deny" && echo "$OUTPUT" | grep -q "failing"; then
    pass_test
else
    fail_test "Merge allowed with failing tests"
fi

# --- Tests 16-17: guard.sh Check 8 (proof-status gate inversion) ---

# Helper to run guard.sh with proof-status mock
run_guard_proof() {
    local command="$1"
    local proof_file="$2"  # Path to .proof-status or "missing"

    local TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-pg-proof-XXXXXX")
    git -C "$TEMP_REPO" init > /dev/null 2>&1
    mkdir -p "$TEMP_REPO/.claude"

    if [[ "$proof_file" != "missing" ]]; then
        echo "$proof_file" > "$TEMP_REPO/.claude/.proof-status"
    fi

    local INPUT_JSON=$(cat <<EOF
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "cd $TEMP_REPO && $command"
  }
}
EOF
)

    # Run hook — cd into temp repo so detect_project_root finds it (not meta-repo)
    local OUTPUT
    OUTPUT=$(cd "$TEMP_REPO" && \
             echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1)
    local EXIT_CODE=$?

    # Cleanup - ensure we're not in TEMP_REPO before deleting
    cd "$PROJECT_ROOT"
    rm -rf "$TEMP_REPO"

    echo "$OUTPUT"
    return $EXIT_CODE
}

run_test "Check 8: Missing .proof-status allows commit (bootstrap)"
OUTPUT=$(run_guard_proof "git commit -m test" "missing" 2>&1) || true
if echo "$OUTPUT" | grep -q "deny"; then
    fail_test "Commit blocked when .proof-status missing (should allow)"
else
    pass_test
fi

run_test "Check 8: needs-verification blocks commit"
OUTPUT=$(run_guard_proof "git commit -m test" "needs-verification|12345" 2>&1) || true
if echo "$OUTPUT" | grep -q "deny" && echo "$OUTPUT" | grep -q "needs-verification"; then
    pass_test
else
    fail_test "Commit allowed with needs-verification status"
fi

# --- Tests 18-20: guard.sh Check 10 (block .proof-status deletion) ---

run_test "Check 10: Block rm .proof-status when needs-verification"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-pg-del-XXXXXX")
git -C "$TEMP_REPO" init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.claude"
echo "needs-verification|12345" > "$TEMP_REPO/.claude/.proof-status"

INPUT_JSON=$(cat <<EOF
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "rm $TEMP_REPO/.claude/.proof-status"
  }
}
EOF
)

OUTPUT=$(cd "$TEMP_REPO" && \
         echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

if echo "$OUTPUT" | grep -q "deny" && echo "$OUTPUT" | grep -q "verification is active"; then
    pass_test
else
    fail_test "Deletion allowed when needs-verification"
fi

cd "$PROJECT_ROOT"  # Ensure we're not in TEMP_REPO before deleting
rm -rf "$TEMP_REPO"

run_test "Check 10: Block rm .proof-status when pending"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-pg-pend-XXXXXX")
git -C "$TEMP_REPO" init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.claude"
echo "pending|12345" > "$TEMP_REPO/.claude/.proof-status"

INPUT_JSON=$(cat <<EOF
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "rm $TEMP_REPO/.claude/.proof-status"
  }
}
EOF
)

OUTPUT=$(cd "$TEMP_REPO" && \
         echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

if echo "$OUTPUT" | grep -q "deny" && echo "$OUTPUT" | grep -q "verification is active"; then
    pass_test
else
    fail_test "Deletion allowed when pending"
fi

cd "$PROJECT_ROOT"  # Ensure we're not in TEMP_REPO before deleting
rm -rf "$TEMP_REPO"

run_test "Check 10: Allow rm .proof-status when verified"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-pg-ver-XXXXXX")
git -C "$TEMP_REPO" init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.claude"
echo "verified|12345" > "$TEMP_REPO/.claude/.proof-status"

INPUT_JSON=$(cat <<EOF
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "rm $TEMP_REPO/.claude/.proof-status"
  }
}
EOF
)

OUTPUT=$(cd "$TEMP_REPO" && \
         echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

if echo "$OUTPUT" | grep -q "deny"; then
    fail_test "Deletion blocked when verified (should allow)"
else
    pass_test
fi

cd "$PROJECT_ROOT"  # Ensure we're not in TEMP_REPO before deleting
rm -rf "$TEMP_REPO"

# --- Summary ---
echo ""
echo "=========================================="
echo "Test Results: $TESTS_PASSED/$TESTS_RUN passed"
echo "=========================================="

if [[ $TESTS_FAILED -gt 0 ]]; then
    echo "FAILED: $TESTS_FAILED tests failed"
    exit 1
else
    echo "SUCCESS: All tests passed"
    exit 0
fi
