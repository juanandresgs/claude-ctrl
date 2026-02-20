#!/usr/bin/env bash
# test-track-guardian-exemption.sh — Tests for Guardian-active proof invalidation bypass (#49)
#
# Purpose: Verify that track.sh does NOT reset .proof-status from verified→pending
#   when a Guardian agent is active. This prevents a deadlock where Guardian's own
#   commit/merge workflow (which may trigger Write/Edit events) invalidates the proof
#   mid-commit and causes guard.sh Check 8 to block the commit.
#
# Contracts verified:
#   1. No guardian marker + source write + verified proof → proof resets to pending
#      (existing behaviour preserved)
#   2. Guardian marker present + source write + verified proof → proof stays verified
#      (the fix: guardian exemption)
#   3. Guardian marker present + source write + non-verified proof → no change
#      (exemption only applies when status is "verified"; other states unaffected)
#
# @decision DEC-TRACK-GUARDIAN-001
# @title Guardian-active guard in track.sh (issue #49)
# @status accepted
# @rationale track.sh fires on every Write/Edit, including writes during Guardian's
#   commit/merge workflow. Without agent awareness, a Write during Guardian's
#   conflict-resolution step resets verified→pending, causing guard.sh Check 8 to
#   block the commit. Wrapping the invalidation block in a guardian-active check
#   (via .active-guardian-* marker files in TRACE_STORE) prevents this deadlock.
#   These tests validate: (a) non-guardian path still invalidates, (b) guardian path
#   is exempt, (c) non-verified statuses are not affected by the new guard.
#
# Usage: bash tests/test-track-guardian-exemption.sh
# Returns: 0 if all tests pass, 1 if any fail

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="${PROJECT_ROOT}/hooks"
TRACK_SH="${HOOKS_DIR}/track.sh"

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
# Helper: make_temp_repo — create an isolated git repo + TRACE_STORE for testing.
# Returns path via stdout. Caller is responsible for cleanup.
# ---------------------------------------------------------------------------
make_temp_repo() {
    local tmp_dir
    tmp_dir=$(mktemp -d "$PROJECT_ROOT/tmp/test-tge-XXXXXX")
    git -C "$tmp_dir" init -q 2>/dev/null
    mkdir -p "$tmp_dir/.claude"
    echo "$tmp_dir"
}

# ---------------------------------------------------------------------------
# Helper: run_track — invoke track.sh simulating a Write event.
# Args:
#   $1 = file_path written
#   $2 = repo path (CLAUDE_PROJECT_DIR)
#   $3 = TRACE_STORE path (separate from repo, so guardian markers are isolated)
# Returns: track.sh stdout (usually empty)
# ---------------------------------------------------------------------------
run_track() {
    local file_path="$1"
    local repo="$2"
    local trace_store="${3:-}"

    local input_json
    input_json=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$file_path")

    ( export CLAUDE_PROJECT_DIR="$repo"
      [[ -n "$trace_store" ]] && export TRACE_STORE="$trace_store"
      cd "$repo"
      echo "$input_json" | bash "$TRACK_SH" 2>/dev/null
    ) || true
}

# ===========================================================================
# Test 1: No guardian marker — source write invalidates verified proof
# Contract: existing behaviour is preserved when guardian is NOT active.
# ===========================================================================

run_test "No guardian marker: source write resets verified→pending"
REPO=$(make_temp_repo)
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-tge-trace-XXXXXX")
# No .active-guardian-* files in TRACE_STORE
echo "verified|$(date +%s)" > "$REPO/.claude/.proof-status"

run_track "$REPO/main.sh" "$REPO" "$TRACE"

if [[ -f "$REPO/.claude/.proof-status" ]]; then
    STATUS=$(cut -d'|' -f1 "$REPO/.claude/.proof-status")
    if [[ "$STATUS" == "pending" ]]; then
        pass_test
    else
        fail_test "Expected 'pending' after source write without guardian, got '$STATUS'"
    fi
else
    fail_test ".proof-status was deleted instead of set to pending"
fi
rm -rf "$REPO" "$TRACE"

# ===========================================================================
# Test 2: Guardian marker present — source write does NOT reset verified proof
# Contract: the fix — guardian is exempt from proof invalidation.
# ===========================================================================

run_test "Guardian marker present: source write does NOT reset verified proof"
REPO=$(make_temp_repo)
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-tge-trace-XXXXXX")
# Create a guardian marker in TRACE_STORE (simulates an active Guardian agent)
touch "$TRACE/.active-guardian-test-session-001"
echo "verified|$(date +%s)" > "$REPO/.claude/.proof-status"

run_track "$REPO/main.sh" "$REPO" "$TRACE"

if [[ -f "$REPO/.claude/.proof-status" ]]; then
    STATUS=$(cut -d'|' -f1 "$REPO/.claude/.proof-status")
    if [[ "$STATUS" == "verified" ]]; then
        pass_test
    else
        fail_test "Expected 'verified' with guardian active, got '$STATUS' (proof was invalidated)"
    fi
else
    fail_test ".proof-status was deleted while guardian was active"
fi
rm -rf "$REPO" "$TRACE"

# ===========================================================================
# Test 3: Guardian marker present, proof is needs-verification — no change
# Contract: exemption only gates the verified→pending transition; other states
#   are unaffected (needs-verification stays needs-verification, etc.)
# ===========================================================================

run_test "Guardian marker present: needs-verification proof unchanged by source write"
REPO=$(make_temp_repo)
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-tge-trace-XXXXXX")
touch "$TRACE/.active-guardian-test-session-002"
ORIGINAL_TS=$(date +%s)
echo "needs-verification|${ORIGINAL_TS}" > "$REPO/.claude/.proof-status"

run_track "$REPO/main.sh" "$REPO" "$TRACE"

if [[ -f "$REPO/.claude/.proof-status" ]]; then
    STATUS=$(cut -d'|' -f1 "$REPO/.claude/.proof-status")
    TS=$(cut -d'|' -f2 "$REPO/.claude/.proof-status")
    if [[ "$STATUS" == "needs-verification" && "$TS" == "$ORIGINAL_TS" ]]; then
        pass_test
    else
        fail_test "needs-verification proof changed: status='$STATUS' ts='$TS' (expected unchanged)"
    fi
else
    fail_test ".proof-status was deleted (expected needs-verification to remain)"
fi
rm -rf "$REPO" "$TRACE"

# ===========================================================================
# Test 4: Guardian marker present, proof is pending — no change
# Contract: the invalidation block only runs when status==verified, so pending
#   should be unaffected regardless of guardian state.
# ===========================================================================

run_test "Guardian marker present: pending proof unchanged by source write"
REPO=$(make_temp_repo)
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-tge-trace-XXXXXX")
touch "$TRACE/.active-guardian-test-session-003"
ORIGINAL_TS="11111"
echo "pending|${ORIGINAL_TS}" > "$REPO/.claude/.proof-status"

run_track "$REPO/main.sh" "$REPO" "$TRACE"

if [[ -f "$REPO/.claude/.proof-status" ]]; then
    STATUS=$(cut -d'|' -f1 "$REPO/.claude/.proof-status")
    if [[ "$STATUS" == "pending" ]]; then
        pass_test
    else
        fail_test "Pending proof changed to '$STATUS' while guardian was active (expected pending)"
    fi
else
    fail_test ".proof-status was deleted (expected pending to remain)"
fi
rm -rf "$REPO" "$TRACE"

# ===========================================================================
# Test 5: Guardian marker removed — invalidation resumes normally
# Contract: once guardian finishes (marker removed), the next source write
#   does invalidate the proof again (no lingering exemption state).
# ===========================================================================

run_test "After guardian marker removed: source write resumes invalidation"
REPO=$(make_temp_repo)
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-tge-trace-XXXXXX")
# Create then immediately remove the guardian marker (simulates guardian completing)
touch "$TRACE/.active-guardian-test-session-004"
rm -f "$TRACE/.active-guardian-test-session-004"
echo "verified|$(date +%s)" > "$REPO/.claude/.proof-status"

run_track "$REPO/main.sh" "$REPO" "$TRACE"

if [[ -f "$REPO/.claude/.proof-status" ]]; then
    STATUS=$(cut -d'|' -f1 "$REPO/.claude/.proof-status")
    if [[ "$STATUS" == "pending" ]]; then
        pass_test
    else
        fail_test "Expected 'pending' after guardian marker removed, got '$STATUS'"
    fi
else
    fail_test ".proof-status was deleted (expected pending after marker removal)"
fi
rm -rf "$REPO" "$TRACE"

# ===========================================================================
# Test 6: Syntax check — track.sh is valid bash
# ===========================================================================

run_test "Syntax: track.sh is valid bash"
if bash -n "$TRACK_SH"; then
    pass_test
else
    fail_test "track.sh has syntax errors"
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
