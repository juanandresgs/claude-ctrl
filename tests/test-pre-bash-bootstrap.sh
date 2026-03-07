#!/usr/bin/env bash
# test-pre-bash-bootstrap.sh — Tests for #150: pre-bash.sh Check 2 bootstrap exception
#
# Validates that the Check 2 bootstrap exception correctly uses output-content
# detection (not exit-code) to determine whether MASTER_PLAN.md is tracked by HEAD.
#
# The bug: git ls-tree returns exit 0 even when a file is absent from HEAD.
# Only the output differs — empty string means not tracked, non-empty means tracked.
#
# Tests:
#   TB01: git ls-tree returns empty output for untracked MASTER_PLAN.md
#         (bootstrap case — allow the first commit)
#   TB02: git ls-tree returns non-empty output for tracked MASTER_PLAN.md
#         (deny — already committed, must use worktree)
#   TB03: output-content check (fixed logic) correctly distinguishes both cases
#   TB04: exit-code check (broken logic) fails to distinguish — returns 0 for both
#
# @decision DEC-BOOTSTRAP-CHECK-001
# @title Validate output-content vs exit-code for git ls-tree bootstrap detection
# @status accepted
# @rationale git ls-tree exits 0 for absent paths, breaking the exit-code guard
#   in pre-bash.sh Check 2. These tests prove the broken behavior and validate
#   the fix. See issue #150.
#
# Usage: bash tests/test-pre-bash-bootstrap.sh
# Sacred Practice #3: temp dirs use tmp/ in project root, not /tmp/

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"

# Ensure tmp directory exists (Sacred Practice #3: no /tmp/)
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
# Setup: isolated temp git repo, cleaned up on EXIT
# ---------------------------------------------------------------------------
TMPDIR_BASE="$PROJECT_ROOT/tmp/test-pre-bash-bootstrap-$$"
mkdir -p "$TMPDIR_BASE"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Create a temp git repo with an initial commit (no MASTER_PLAN.md)
REPO="$TMPDIR_BASE/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@test.com"
git -C "$REPO" config user.name "Test"

# Create initial commit with a different file (so HEAD exists but no MASTER_PLAN.md)
echo "hello" > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "Initial commit"

# ---------------------------------------------------------------------------
# TB01: git ls-tree output is empty when MASTER_PLAN.md not in HEAD
#
# After the initial commit, MASTER_PLAN.md is NOT tracked. ls-tree should
# produce no output (empty string). This is the bootstrap case — allow through.
# ---------------------------------------------------------------------------
run_test "TB01: ls-tree output is empty for untracked MASTER_PLAN.md (bootstrap case)"

TB01_OUTPUT=$(git -C "$REPO" ls-tree HEAD -- MASTER_PLAN.md 2>/dev/null)
if [[ -z "$TB01_OUTPUT" ]]; then
    pass_test
else
    fail_test "Expected empty output for untracked file, got: '$TB01_OUTPUT'"
fi

# ---------------------------------------------------------------------------
# TB02: git ls-tree output is non-empty when MASTER_PLAN.md is in HEAD
#
# After committing MASTER_PLAN.md, ls-tree should produce output (the tree
# entry line). This is the deny case — file already tracked, must use worktree.
# ---------------------------------------------------------------------------
run_test "TB02: ls-tree output is non-empty for tracked MASTER_PLAN.md (deny case)"

# Stage and commit MASTER_PLAN.md
echo "# Master Plan" > "$REPO/MASTER_PLAN.md"
git -C "$REPO" add MASTER_PLAN.md
git -C "$REPO" commit -q -m "Add MASTER_PLAN.md"

TB02_OUTPUT=$(git -C "$REPO" ls-tree HEAD -- MASTER_PLAN.md 2>/dev/null)
if [[ -n "$TB02_OUTPUT" ]]; then
    pass_test
else
    fail_test "Expected non-empty output for tracked file, got empty string"
fi

# ---------------------------------------------------------------------------
# TB03: Output-content check (FIXED logic) correctly distinguishes both cases
#
# Simulates the fixed pre-bash.sh Check 2 logic using the output-content check:
#   if [[ -n "$(git -C "$TARGET_DIR" ls-tree HEAD -- MASTER_PLAN.md 2>/dev/null)" ]]
#
# For the bootstrap case (MASTER_PLAN.md not yet in HEAD), output is empty =>
# condition is false => no deny => bootstrap allowed.
#
# For the deny case (MASTER_PLAN.md already in HEAD), output is non-empty =>
# condition is true => emit_deny fires.
# ---------------------------------------------------------------------------
run_test "TB03: output-content check correctly identifies bootstrap vs deny cases"

# Create a fresh repo — MASTER_PLAN.md not yet in HEAD
REPO3="$TMPDIR_BASE/repo3"
mkdir -p "$REPO3"
git -C "$REPO3" init -q
git -C "$REPO3" config user.email "test@test.com"
git -C "$REPO3" config user.name "Test"
echo "hello" > "$REPO3/README.md"
git -C "$REPO3" add README.md
git -C "$REPO3" commit -q -m "Initial commit"

# Simulate fixed check 2 logic for bootstrap case (MASTER_PLAN.md not in HEAD)
_fixed_check() {
    local target_dir="$1"
    if [[ -n "$(git -C "$target_dir" ls-tree HEAD -- MASTER_PLAN.md 2>/dev/null)" ]]; then
        echo "DENY"  # Already tracked — not bootstrap
    else
        echo "ALLOW" # Not tracked yet — bootstrap
    fi
}

BOOTSTRAP_RESULT=$(_fixed_check "$REPO3")
if [[ "$BOOTSTRAP_RESULT" == "ALLOW" ]]; then
    # Now commit MASTER_PLAN.md and verify it switches to DENY
    echo "# Master Plan" > "$REPO3/MASTER_PLAN.md"
    git -C "$REPO3" add MASTER_PLAN.md
    git -C "$REPO3" commit -q -m "Add MASTER_PLAN.md"

    TRACKED_RESULT=$(_fixed_check "$REPO3")
    if [[ "$TRACKED_RESULT" == "DENY" ]]; then
        pass_test
    else
        fail_test "After MASTER_PLAN.md committed, expected DENY but got: '$TRACKED_RESULT'"
    fi
else
    fail_test "Before MASTER_PLAN.md committed, expected ALLOW but got: '$BOOTSTRAP_RESULT'"
fi

# ---------------------------------------------------------------------------
# TB04: Exit-code check (BROKEN logic) fails to distinguish both cases
#
# Simulates the broken pre-bash.sh Check 2 logic using the exit-code check:
#   if git -C "$TARGET_DIR" ls-tree HEAD -- MASTER_PLAN.md &>/dev/null
#
# Both bootstrap (file absent) and deny (file present) cases return exit 0.
# The broken logic always sees the condition as true, denying the bootstrap.
# ---------------------------------------------------------------------------
run_test "TB04: exit-code check (broken) returns exit 0 for BOTH absent and present files"

REPO4="$TMPDIR_BASE/repo4"
mkdir -p "$REPO4"
git -C "$REPO4" init -q
git -C "$REPO4" config user.email "test@test.com"
git -C "$REPO4" config user.name "Test"
echo "hello" > "$REPO4/README.md"
git -C "$REPO4" add README.md
git -C "$REPO4" commit -q -m "Initial commit"

# Check exit code when MASTER_PLAN.md is NOT in HEAD (bootstrap case)
if git -C "$REPO4" ls-tree HEAD -- MASTER_PLAN.md &>/dev/null; then
    ABSENT_EXIT=0
else
    ABSENT_EXIT=1
fi

# Commit MASTER_PLAN.md
echo "# Master Plan" > "$REPO4/MASTER_PLAN.md"
git -C "$REPO4" add MASTER_PLAN.md
git -C "$REPO4" commit -q -m "Add MASTER_PLAN.md"

# Check exit code when MASTER_PLAN.md IS in HEAD (deny case)
if git -C "$REPO4" ls-tree HEAD -- MASTER_PLAN.md &>/dev/null; then
    PRESENT_EXIT=0
else
    PRESENT_EXIT=1
fi

# The broken behavior: both exit 0 (exit code does NOT distinguish the cases)
if [[ "$ABSENT_EXIT" -eq 0 && "$PRESENT_EXIT" -eq 0 ]]; then
    # Both return 0 — confirms the broken behavior that TB03's fix resolves
    pass_test
else
    fail_test "Expected both absent and present to return exit 0 (proving the bug), got absent=$ABSENT_EXIT present=$PRESENT_EXIT"
fi

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
