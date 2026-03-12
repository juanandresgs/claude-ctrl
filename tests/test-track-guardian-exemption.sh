#!/usr/bin/env bash
# test-track-guardian-exemption.sh — Tests for Guardian-active proof invalidation bypass (#49)
#
# Purpose: Verify that post-write.sh does NOT reset .proof-status from verified→pending
#   when a Guardian agent is active. This prevents a deadlock where Guardian's own
#   commit/merge workflow (which may trigger Write/Edit events) invalidates the proof
#   mid-commit and causes pre-bash.sh Check 8 to block the commit.
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
# @title Guardian-active guard in post-write.sh (issue #49)
# @status accepted
# @rationale post-write.sh fires on every Write/Edit, including writes during Guardian's
#   commit/merge workflow. Without agent awareness, a Write during Guardian's
#   conflict-resolution step resets verified→pending, causing pre-bash.sh Check 8 to
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
TRACK_SH="${HOOKS_DIR}/post-write.sh"

# Ensure tmp directory exists
mkdir -p "$PROJECT_ROOT/tmp"

# Cleanup trap (DEC-PROD-002): collect temp dirs and remove on exit
_CLEANUP_DIRS=()
trap '[[ ${#_CLEANUP_DIRS[@]} -gt 0 ]] && rm -rf "${_CLEANUP_DIRS[@]}" 2>/dev/null; true' EXIT

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
# Helper: write_proof — write proof status to the canonical path that
# resolve_proof_file() will find. Uses the new state/{phash}/proof-status format.
# ---------------------------------------------------------------------------
write_proof() {
    local repo="$1" status="$2"
    local phash
    phash=$(echo "$repo" | ${_SHA256_CMD:-shasum -a 256} | cut -c1-8)
    local proof_dir="$repo/.claude/state/${phash}"
    mkdir -p "$proof_dir"
    echo "${status}|$(date +%s)" > "${proof_dir}/proof-status"
    # Also write to legacy path for backward compat
    echo "${status}|$(date +%s)" > "$repo/.claude/.proof-status-${phash}"
    # Backdate proof files so epoch reset can work (monotonic lattice)
    touch -t 202601010000 "${proof_dir}/proof-status" "$repo/.claude/.proof-status-${phash}"
    # DEC-STATE-DOTFILE-001: proof-epoch flat file removed — epoch state is SQLite-only.
    # post-write.sh calls proof_epoch_reset() directly when current status is verified.
}

# ---------------------------------------------------------------------------
# Helper: read_proof — read the proof status from the canonical path
# ---------------------------------------------------------------------------
read_proof() {
    local repo="$1"
    local phash
    phash=$(echo "$repo" | ${_SHA256_CMD:-shasum -a 256} | cut -c1-8)
    local proof_file="$repo/.claude/state/${phash}/proof-status"
    if [[ -f "$proof_file" ]]; then
        cut -d'|' -f1 "$proof_file"
    else
        # Fallback to legacy
        proof_file="$repo/.claude/.proof-status-${phash}"
        if [[ -f "$proof_file" ]]; then
            cut -d'|' -f1 "$proof_file"
        else
            echo "missing"
        fi
    fi
}

# Portable SHA-256
if command -v shasum >/dev/null 2>&1; then
    _SHA256_CMD="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
    _SHA256_CMD="sha256sum"
else
    _SHA256_CMD="cat"
fi

# ---------------------------------------------------------------------------
# Helper: run_track — invoke post-write.sh simulating a Write event.
# Args:
#   $1 = file_path written
#   $2 = repo path (CLAUDE_PROJECT_DIR)
#   $3 = TRACE_STORE path (separate from repo, so guardian markers are isolated)
# Returns: post-write.sh stdout (usually empty)
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
_CLEANUP_DIRS+=("$REPO")
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-tge-trace-XXXXXX")
_CLEANUP_DIRS+=("$TRACE")
# No .active-guardian-* files in TRACE_STORE
write_proof "$REPO" "verified"

run_track "$REPO/main.sh" "$REPO" "$TRACE"

STATUS=$(read_proof "$REPO")
if [[ "$STATUS" == "pending" ]]; then
    pass_test
else
    fail_test "Expected 'pending' after source write without guardian, got '$STATUS'"
fi

# ===========================================================================
# Test 2: Guardian marker present — source write does NOT reset verified proof
# Contract: the fix — guardian is exempt from proof invalidation.
# ===========================================================================

run_test "Guardian marker present: source write does NOT reset verified proof"
REPO=$(make_temp_repo)
_CLEANUP_DIRS+=("$REPO")
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-tge-trace-XXXXXX")
_CLEANUP_DIRS+=("$TRACE")
# Create a guardian marker with valid timestamp format (TTL-based check)
echo "pre-dispatch|$(date +%s)" > "$TRACE/.active-guardian-test-session-001"
write_proof "$REPO" "verified"

run_track "$REPO/main.sh" "$REPO" "$TRACE"

STATUS=$(read_proof "$REPO")
if [[ "$STATUS" == "verified" ]]; then
    pass_test
else
    fail_test "Expected 'verified' with guardian active, got '$STATUS' (proof was invalidated)"
fi

# ===========================================================================
# Test 3: Guardian marker present, proof is needs-verification — no change
# ===========================================================================

run_test "Guardian marker present: needs-verification proof unchanged by source write"
REPO=$(make_temp_repo)
_CLEANUP_DIRS+=("$REPO")
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-tge-trace-XXXXXX")
_CLEANUP_DIRS+=("$TRACE")
echo "pre-dispatch|$(date +%s)" > "$TRACE/.active-guardian-test-session-002"
write_proof "$REPO" "needs-verification"

run_track "$REPO/main.sh" "$REPO" "$TRACE"

STATUS=$(read_proof "$REPO")
if [[ "$STATUS" == "needs-verification" ]]; then
    pass_test
else
    fail_test "needs-verification proof changed: status='$STATUS' (expected unchanged)"
fi

# ===========================================================================
# Test 4: Guardian marker present, proof is pending — no change
# ===========================================================================

run_test "Guardian marker present: pending proof unchanged by source write"
REPO=$(make_temp_repo)
_CLEANUP_DIRS+=("$REPO")
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-tge-trace-XXXXXX")
_CLEANUP_DIRS+=("$TRACE")
echo "pre-dispatch|$(date +%s)" > "$TRACE/.active-guardian-test-session-003"
write_proof "$REPO" "pending"

run_track "$REPO/main.sh" "$REPO" "$TRACE"

STATUS=$(read_proof "$REPO")
if [[ "$STATUS" == "pending" ]]; then
    pass_test
else
    fail_test "Pending proof changed to '$STATUS' while guardian was active (expected pending)"
fi

# ===========================================================================
# Test 5: Guardian marker removed — invalidation resumes normally
# ===========================================================================

run_test "After guardian marker removed: source write resumes invalidation"
REPO=$(make_temp_repo)
_CLEANUP_DIRS+=("$REPO")
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-tge-trace-XXXXXX")
_CLEANUP_DIRS+=("$TRACE")
# Create then immediately remove the guardian marker (simulates guardian completing)
echo "pre-dispatch|$(date +%s)" > "$TRACE/.active-guardian-test-session-004"
rm -f "$TRACE/.active-guardian-test-session-004"
write_proof "$REPO" "verified"

run_track "$REPO/main.sh" "$REPO" "$TRACE"

STATUS=$(read_proof "$REPO")
if [[ "$STATUS" == "pending" ]]; then
    pass_test
else
    fail_test "Expected 'pending' after guardian marker removed, got '$STATUS'"
fi

# ===========================================================================
# Test 6: Syntax check — post-write.sh is valid bash
# ===========================================================================

run_test "Syntax: post-write.sh is valid bash"
if bash -n "$TRACK_SH"; then
    pass_test
else
    fail_test "post-write.sh has syntax errors"
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
