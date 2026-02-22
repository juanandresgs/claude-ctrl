#!/usr/bin/env bash
# test-guard-worktree-removal.sh — Tests for guard.sh CWD-conditional worktree removal
#
# Purpose: Verify that guard.sh Checks 5 and 5b only deny worktree removal commands
#   when the current working directory is INSIDE a .worktrees/ path. Previously both
#   checks denied unconditionally, creating an infinite denial loop: the corrected
#   command (with "cd <safe_path> &&" prefix) still matched the pattern, so every
#   resubmission was denied again with another cd prepended.
#
# The fix: both checks now gate the deny on CWD containing "/.worktrees/" — when
#   CWD is already safe (project root, home, etc.), the removal is allowed through.
#
# Contracts verified:
#   1. rm -rf .worktrees/foo with CWD inside a worktree  → DENIED
#   2. rm -rf .worktrees/foo with CWD at project root    → ALLOWED
#   3. git worktree remove with CWD inside a worktree    → DENIED
#   4. git worktree remove with CWD at project root      → ALLOWED
#   5. rm -rf .worktrees/foo with CWD at a DIFFERENT worktree → DENIED (still inside .worktrees/)
#   6. git worktree remove --force outside Guardian      → DENIED (regardless of CWD)
#   7. Regression: cd .worktrees/foo still denied by Check 0.75 (unchanged)
#
# @decision DEC-GUARD-002
# @title Two-tier worktree CWD safety: conditional deny based on CWD location
# @status accepted
# @rationale Unconditional deny created an infinite loop: the corrected command
#   (cd <safe> && rm -rf .worktrees/...) still matches the rm+.worktrees/ pattern,
#   so every resubmission gets denied with another cd prepended. The fix: deny only
#   when CWD is inside .worktrees/ (the dangerous case). When CWD is already safe,
#   allow the removal — the posix_spawn ENOENT risk only applies when the shell's
#   persistent CWD is the deleted directory.
#
# Usage: bash tests/test-guard-worktree-removal.sh
# Returns: 0 if all tests pass, 1 if any fail

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="${PROJECT_ROOT}/hooks"
GUARD_SH="${HOOKS_DIR}/guard.sh"
TRACE_STORE="${PROJECT_ROOT}/tmp"

# Ensure tmp directory exists
mkdir -p "$PROJECT_ROOT/tmp"

# ---------------------------------------------------------------------------
# Test tracking
# ---------------------------------------------------------------------------
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
    echo "  PASS"
}

fail_test() {
    local reason="$1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL: $reason"
}

# ---------------------------------------------------------------------------
# Helper: run_guard — invoke guard.sh with a controlled JSON input.
# Args:
#   $1 = command string
#   $2 = cwd to inject into the hook input JSON
#   $3 = optional TRACE_STORE path (for Guardian marker control)
# Returns: guard.sh stdout (JSON decision or empty)
# ---------------------------------------------------------------------------
run_guard() {
    local cmd="$1"
    local cwd="$2"
    local trace_store="${3:-$TRACE_STORE}"

    local input_json
    # Escape the command and cwd for embedding in JSON
    input_json=$(jq -cn \
        --arg cmd "$cmd" \
        --arg cwd "$cwd" \
        '{"tool_name":"Bash","tool_input":{"command":$cmd},"cwd":$cwd}')

    ( export CLAUDE_PROJECT_DIR="$PROJECT_ROOT"
      export TRACE_STORE="$trace_store"
      echo "$input_json" | bash "$GUARD_SH" 2>/dev/null
    ) || true
}

# Helper: check if output is a deny decision
is_denied() {
    local output="$1"
    echo "$output" | grep -q '"permissionDecision": *"deny"'
}

# Helper: check if output is NOT a deny (allowed = empty output or no deny)
is_allowed() {
    local output="$1"
    ! echo "$output" | grep -q '"permissionDecision": *"deny"'
}

# ---------------------------------------------------------------------------
# Prerequisite: guard.sh must exist and be valid bash
# ---------------------------------------------------------------------------
run_test "Syntax: guard.sh is valid bash"
if bash -n "$GUARD_SH"; then
    pass_test
else
    fail_test "guard.sh has syntax errors"
fi

# ===========================================================================
# Test 1: rm -rf .worktrees/foo with CWD INSIDE a worktree → DENIED
# Contract: CWD is /.worktrees/... — the dangerous case — deny fires.
# ===========================================================================

run_test "Check 5b: rm -rf .worktrees/foo with CWD inside worktree → DENIED"
RESULT=$(run_guard \
    "rm -rf /Users/turla/.claude/.worktrees/fix-guard-loop" \
    "/Users/turla/.claude/.worktrees/fix-guard-loop")

if is_denied "$RESULT"; then
    pass_test
else
    fail_test "Expected DENIED when CWD is inside .worktrees/, got: $(echo "$RESULT" | head -5)"
fi

# ===========================================================================
# Test 2: rm -rf .worktrees/foo with CWD at project root → ALLOWED
# Contract: CWD is the safe project root — deny must NOT fire.
# This is the infinite-loop fix: the corrected "cd root && rm -rf .worktrees/..."
# must pass through on resubmission.
# ===========================================================================

run_test "Check 5b: rm -rf .worktrees/foo with CWD at project root → ALLOWED"
RESULT=$(run_guard \
    "rm -rf /Users/turla/.claude/.worktrees/fix-guard-loop" \
    "/Users/turla/.claude")

if is_allowed "$RESULT"; then
    pass_test
else
    REASON=$(echo "$RESULT" | grep -o '"permissionDecisionReason":.*' | head -1 || echo "(no reason)")
    fail_test "Expected ALLOWED when CWD is at project root. Got deny. Reason: $REASON"
fi

# ===========================================================================
# Test 3: git worktree remove with CWD inside a worktree → DENIED
# Contract: CWD is /.worktrees/... — deny fires.
# ===========================================================================

run_test "Check 5: git worktree remove with CWD inside worktree → DENIED"
RESULT=$(run_guard \
    "git worktree remove /Users/turla/.claude/.worktrees/fix-guard-loop" \
    "/Users/turla/.claude/.worktrees/fix-guard-loop")

if is_denied "$RESULT"; then
    pass_test
else
    fail_test "Expected DENIED when CWD is inside .worktrees/, got: $(echo "$RESULT" | head -5)"
fi

# ===========================================================================
# Test 4: git worktree remove with CWD at project root → ALLOWED
# Contract: CWD is safe — deny must NOT fire.
# This is the primary fix: "cd root && git worktree remove ..." passes through.
# ===========================================================================

run_test "Check 5: git worktree remove with CWD at project root → ALLOWED"
RESULT=$(run_guard \
    "git worktree remove /Users/turla/.claude/.worktrees/fix-guard-loop" \
    "/Users/turla/.claude")

if is_allowed "$RESULT"; then
    pass_test
else
    REASON=$(echo "$RESULT" | grep -o '"permissionDecisionReason":.*' | head -1 || echo "(no reason)")
    fail_test "Expected ALLOWED when CWD is at project root. Got deny. Reason: $REASON"
fi

# ===========================================================================
# Test 5: rm -rf .worktrees/foo with CWD at a DIFFERENT worktree → DENIED
# Contract: even if CWD is not THE worktree being removed, it's still inside
# .worktrees/ — still dangerous, still denied.
# ===========================================================================

run_test "Check 5b: rm -rf .worktrees/foo with CWD at DIFFERENT worktree → DENIED"
RESULT=$(run_guard \
    "rm -rf /Users/turla/.claude/.worktrees/fix-guard-loop" \
    "/Users/turla/.claude/.worktrees/some-other-worktree")

if is_denied "$RESULT"; then
    pass_test
else
    fail_test "Expected DENIED when CWD is inside .worktrees/ (different worktree), got: $(echo "$RESULT" | head -5)"
fi

# ===========================================================================
# Test 6: git worktree remove --force outside Guardian → DENIED (regardless of CWD)
# Contract: --force check fires before the CWD check, regardless of where CWD is.
# ===========================================================================

run_test "Check 5: git worktree remove --force outside Guardian → DENIED (CWD safe)"
TRACE_TMP=$(mktemp -d "$PROJECT_ROOT/tmp/test-gwrm-trace-XXXXXX")
# No guardian marker — force remove outside Guardian context
RESULT=$(run_guard \
    "git worktree remove --force /Users/turla/.claude/.worktrees/fix-guard-loop" \
    "/Users/turla/.claude" \
    "$TRACE_TMP")

if is_denied "$RESULT"; then
    pass_test
else
    fail_test "Expected DENIED for --force worktree removal outside Guardian context"
fi
rm -rf "$TRACE_TMP"

# ===========================================================================
# Test 7: Regression — cd .worktrees/foo still denied by Check 0.75 (unchanged)
# Contract: the fix to Checks 5/5b must not affect Check 0.75's cd denial.
# ===========================================================================

run_test "Regression Check 0.75: cd .worktrees/foo still denied"
RESULT=$(run_guard \
    "cd .worktrees/fix-guard-loop" \
    "/Users/turla/.claude")

if is_denied "$RESULT"; then
    pass_test
else
    fail_test "Expected DENIED for cd .worktrees/foo (Check 0.75 regression)"
fi

# ===========================================================================
# Test 8: rm -rf .worktrees/foo with CWD at /tmp (completely outside project) → ALLOWED
# Contract: CWD outside the project entirely, no .worktrees/ in path → allowed.
# ===========================================================================

run_test "Check 5b: rm -rf .worktrees/foo with CWD at /tmp → ALLOWED"
RESULT=$(run_guard \
    "rm -rf /Users/turla/.claude/.worktrees/fix-guard-loop" \
    "/tmp")

if is_allowed "$RESULT"; then
    pass_test
else
    REASON=$(echo "$RESULT" | grep -o '"permissionDecisionReason":.*' | head -1 || echo "(no reason)")
    fail_test "Expected ALLOWED when CWD is /tmp. Got deny. Reason: $REASON"
fi

# ===========================================================================
# Test 9: git worktree remove with CWD at /tmp → ALLOWED
# ===========================================================================

run_test "Check 5: git worktree remove with CWD at /tmp → ALLOWED"
RESULT=$(run_guard \
    "git worktree remove /Users/turla/.claude/.worktrees/fix-guard-loop" \
    "/tmp")

if is_allowed "$RESULT"; then
    pass_test
else
    REASON=$(echo "$RESULT" | grep -o '"permissionDecisionReason":.*' | head -1 || echo "(no reason)")
    fail_test "Expected ALLOWED when CWD is /tmp. Got deny. Reason: $REASON"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "=========================================="
echo "Test Results: $TESTS_PASSED/$TESTS_RUN passed"
echo "=========================================="

if [[ $TESTS_FAILED -gt 0 ]]; then
    echo "FAILED: $TESTS_FAILED test(s) failed"
    exit 1
else
    echo "SUCCESS: All $TESTS_PASSED tests passed"
    exit 0
fi
