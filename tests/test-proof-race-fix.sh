#!/usr/bin/env bash
# test-proof-race-fix.sh — Tests for the dispatch-time race condition fix (Issue #151)
#
# Purpose: Verify that task-track.sh pre-creates the .active-guardian-* marker when
#   Guardian dispatch is allowed (proof = verified). Without the marker, any Write/Edit
#   between Gate A pass and SubagentStart's init_trace() fires track.sh, which resets
#   proof verified→pending — deadlocking Guardian at guard.sh Check 8.
#
# Contracts verified:
#   1. Baseline (bug): verified proof + NO guardian marker + source write → proof resets to pending
#      (documents the original race condition)
#   2. Fix: After Gate A allows Guardian dispatch (verified proof), guardian marker is
#      written to TRACE_STORE immediately.
#   3. Fix end-to-end: With the marker created at dispatch time, a subsequent source
#      Write no longer resets verified→pending.
#   4. Non-guardian dispatch (implementer): no marker is created.
#   5. Non-verified proof (pending): Gate A denies AND no marker is created.
#   6. Marker naming convention: marker matches .active-guardian-{session}-{phash} pattern.
#
# @decision DEC-PROOF-RACE-001
# @title Pre-create guardian marker in task-track.sh to close dispatch race
# @status accepted
# @rationale See hooks/task-track.sh Gate A for full rationale. These tests validate
#   (a) the baseline race is real (no marker → proof reset), (b) the fix creates a marker
#   at Gate A time, (c) the marker prevents track.sh from resetting proof, (d) the fix
#   is scoped to guardian dispatch only.
#
# Usage: bash tests/test-proof-race-fix.sh
# Returns: 0 if all tests pass, 1 if any fail

set -euo pipefail
# Portable SHA-256 (macOS: shasum, Ubuntu: sha256sum)
if command -v shasum >/dev/null 2>&1; then
    _SHA256_CMD="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
    _SHA256_CMD="sha256sum"
else
    _SHA256_CMD="cat"
fi

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="${PROJECT_ROOT}/hooks"
TRACK_SH="${HOOKS_DIR}/post-write.sh"
TASK_TRACK_SH="${HOOKS_DIR}/task-track.sh"

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
# Helper: make_temp_repo — create isolated git repo + claude dir.
# Returns path via stdout. Caller is responsible for cleanup.
# ---------------------------------------------------------------------------
make_temp_repo() {
    local tmp_dir
    tmp_dir=$(mktemp -d "$PROJECT_ROOT/tmp/test-prr-XXXXXX")
    git -C "$tmp_dir" init -q 2>/dev/null
    mkdir -p "$tmp_dir/.claude"
    echo "$tmp_dir"
}

# ---------------------------------------------------------------------------
# Helper: make_temp_trace — create isolated TRACE_STORE directory.
# Returns path via stdout. Caller is responsible for cleanup.
# ---------------------------------------------------------------------------
make_temp_trace() {
    mktemp -d "$PROJECT_ROOT/tmp/test-prr-trace-XXXXXX"
}

# ---------------------------------------------------------------------------
# Helper: run_track — invoke track.sh simulating a Write event.
# ---------------------------------------------------------------------------
run_track() {
    local file_path="$1"
    local repo="$2"
    local trace_store="$3"

    local input_json
    input_json=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$file_path")

    ( export CLAUDE_PROJECT_DIR="$repo"
      export TRACE_STORE="$trace_store"
      echo "$input_json" | bash "$TRACK_SH" 2>/dev/null
    ) || true
}

# ---------------------------------------------------------------------------
# Helper: run_task_track_guardian — invoke task-track.sh simulating Guardian dispatch.
# Sets up proof-status, runs the hook, returns exit code.
# Args: $1=repo $2=trace_store $3=proof_content ("missing" or "verified|12345" etc.)
# ---------------------------------------------------------------------------
run_task_track_guardian() {
    local repo="$1"
    local trace_store="$2"
    local proof_content="$3"

    local phash
    phash=$(echo "$repo" | $_SHA256_CMD | cut -c1-8)

    if [[ "$proof_content" != "missing" ]]; then
        echo "$proof_content" > "$repo/.claude/.proof-status-${phash}"
    fi

    local input_json
    input_json=$(printf '{"tool_name":"Agent","tool_input":{"subagent_type":"guardian","instructions":"Test guardian dispatch"}}')

    ( export CLAUDE_PROJECT_DIR="$repo"
      export TRACE_STORE="$trace_store"
      export CLAUDE_SESSION_ID="test-session-race-001"
      echo "$input_json" | bash "$TASK_TRACK_SH" 2>/dev/null
    ) || true
}

# ---------------------------------------------------------------------------
# Helper: run_task_track_agent — generic agent dispatch via task-track.sh.
# ---------------------------------------------------------------------------
run_task_track_agent() {
    local repo="$1"
    local trace_store="$2"
    local agent_type="$3"
    local proof_content="${4:-missing}"

    local phash
    phash=$(echo "$repo" | $_SHA256_CMD | cut -c1-8)

    if [[ "$proof_content" != "missing" ]]; then
        echo "$proof_content" > "$repo/.claude/.proof-status-${phash}"
    fi

    local input_json
    input_json=$(printf '{"tool_name":"Agent","tool_input":{"subagent_type":"%s","instructions":"Test dispatch"}}' "$agent_type")

    ( export CLAUDE_PROJECT_DIR="$repo"
      export TRACE_STORE="$trace_store"
      export CLAUDE_SESSION_ID="test-session-race-002"
      echo "$input_json" | bash "$TASK_TRACK_SH" 2>/dev/null
    ) || true
}

# ===========================================================================
# Test 1: Baseline race condition — verified proof, no guardian marker,
#   source write resets proof to pending.
#   This documents the original bug behavior (before the fix).
#   Since track.sh has NOT changed, this still works: track.sh resets
#   proof when no marker exists. The fix is in task-track.sh.
# ===========================================================================

run_test "Baseline race: no guardian marker + source write → proof resets to pending"
REPO=$(make_temp_repo)
_CLEANUP_DIRS+=("${REPO}")
TRACE=$(make_temp_trace)
_CLEANUP_DIRS+=("${TRACE}")
BASELINE_PHASH=$(echo "$REPO" | $_SHA256_CMD | cut -c1-8)
# No .active-guardian-* files in TRACE_STORE — simulates the race window.
# Use the new canonical path: state/{phash}/proof-status
BASELINE_STATE_DIR="$REPO/.claude/state/${BASELINE_PHASH}"
mkdir -p "$BASELINE_STATE_DIR"
# DEC-STATE-DOTFILE-001: .proof-epoch flat file removed — epoch state is SQLite-only.
# The original mtime-based setup (touch proof-epoch + backdate proof-status) is no longer
# valid. post-write.sh calls proof_epoch_reset() directly when current status is verified.
# This test setup writes directly to the flat proof-status file; since W5-2 post-write.sh
# reads SQLite, this test no longer exercises the intended behavior.
# TODO: Rewrite test setup to use proof_state_set("verified") via SQLite when flat-file
#   fallback in resolve_proof_file() is removed.
_PAST_TS=$(( $(date +%s) - 60 ))
printf '%s\n' "verified|${_PAST_TS}" > "$BASELINE_STATE_DIR/proof-status"
# (proof-epoch file no longer written — removed per DEC-STATE-DOTFILE-001)

run_track "$REPO/main.sh" "$REPO" "$TRACE"

# post-write.sh dual-writes to both new and old paths — check new canonical path
PROOF_FILE="$BASELINE_STATE_DIR/proof-status"
OLD_PROOF_FILE="$REPO/.claude/.proof-status-${BASELINE_PHASH}"
_STATUS=""
if [[ -f "$PROOF_FILE" ]]; then
    _STATUS=$(cut -d'|' -f1 "$PROOF_FILE")
elif [[ -f "$OLD_PROOF_FILE" ]]; then
    _STATUS=$(cut -d'|' -f1 "$OLD_PROOF_FILE")
fi
if [[ "$_STATUS" == "pending" ]]; then
    pass_test
elif [[ -z "$_STATUS" ]]; then
    fail_test "proof-status file missing after run_track"
else
    fail_test "Expected 'pending' (race condition baseline), got '$_STATUS'"
fi
rm -rf "$REPO" "$TRACE"

# ===========================================================================
# Test 2: Fix verification — Gate A (verified proof) creates guardian marker.
#   task-track.sh must write .active-guardian-{session}-{phash} to TRACE_STORE
#   when Guardian dispatch is allowed.
# ===========================================================================

run_test "Fix: Gate A creates .active-guardian-* marker when proof is verified"
REPO=$(make_temp_repo)
_CLEANUP_DIRS+=("${REPO}")
TRACE=$(make_temp_trace)
_CLEANUP_DIRS+=("${TRACE}")
PHASH=$(echo "$REPO" | $_SHA256_CMD | cut -c1-8)

run_task_track_guardian "$REPO" "$TRACE" "verified|$(date +%s)"

# Check that a guardian marker was created in TRACE_STORE
MARKER_COUNT=$(find "$TRACE" -maxdepth 1 -name ".active-guardian-*" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$MARKER_COUNT" -gt 0 ]]; then
    pass_test
else
    fail_test "No .active-guardian-* marker found in TRACE_STORE after Gate A allowed dispatch"
fi
rm -rf "$REPO" "$TRACE"

# ===========================================================================
# Test 3: Fix end-to-end — marker created at dispatch time protects proof.
#   Simulate the full flow:
#     (a) task-track.sh Gate A allows Guardian (verified proof) → marker created
#     (b) track.sh fires on source Write
#     (c) proof stays verified (marker blocks invalidation)
# ===========================================================================

run_test "Fix end-to-end: dispatch-time marker prevents verified→pending reset"
REPO=$(make_temp_repo)
_CLEANUP_DIRS+=("${REPO}")
TRACE=$(make_temp_trace)
_CLEANUP_DIRS+=("${TRACE}")
PHASH=$(echo "$REPO" | $_SHA256_CMD | cut -c1-8)

# Step 1: write verified proof (scoped)
echo "verified|$(date +%s)" > "$REPO/.claude/.proof-status-${PHASH}"

# Step 2: simulate Gate A — task-track.sh creates the marker
run_task_track_guardian "$REPO" "$TRACE" "missing"  # proof already written above
# Re-write proof to scoped file (run_task_track_guardian reads it, may need both)
echo "verified|$(date +%s)" > "$REPO/.claude/.proof-status-${PHASH}"
run_task_track_guardian "$REPO" "$TRACE" "missing"

# Step 3: confirm marker exists
MARKER_COUNT=$(find "$TRACE" -maxdepth 1 -name ".active-guardian-*" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$MARKER_COUNT" -eq 0 ]]; then
    fail_test "Pre-condition failed: no guardian marker after task-track dispatch"
    rm -rf "$REPO" "$TRACE"
    # continue to next test
else
    # Step 4: source write fires track.sh (with verified proof + guardian marker)
    echo "verified|$(date +%s)" > "$REPO/.claude/.proof-status"
    run_track "$REPO/main.sh" "$REPO" "$TRACE"

    if [[ -f "$REPO/.claude/.proof-status" ]]; then
        STATUS=$(cut -d'|' -f1 "$REPO/.claude/.proof-status")
        if [[ "$STATUS" == "verified" ]]; then
            pass_test
        else
            fail_test "Proof reset to '$STATUS' despite guardian marker (race fix failed)"
        fi
    else
        fail_test ".proof-status deleted unexpectedly"
    fi
    rm -rf "$REPO" "$TRACE"
fi

# ===========================================================================
# Test 4: No marker for non-guardian agents — implementer dispatch does not
#   create a guardian marker (marker is guardian-specific).
# ===========================================================================

run_test "Non-guardian dispatch (implementer): no .active-guardian-* marker created"
REPO=$(make_temp_repo)
_CLEANUP_DIRS+=("${REPO}")
TRACE=$(make_temp_trace)
_CLEANUP_DIRS+=("${TRACE}")

run_task_track_agent "$REPO" "$TRACE" "implementer" "missing"

MARKER_COUNT=$(find "$TRACE" -maxdepth 1 -name ".active-guardian-*" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$MARKER_COUNT" -eq 0 ]]; then
    pass_test
else
    fail_test "Guardian marker created for implementer dispatch (should not happen)"
fi
rm -rf "$REPO" "$TRACE"

# ===========================================================================
# Test 5: Gate A denies (pending proof) — no marker created.
#   When Gate A denies, Guardian is not dispatched. The marker must not be
#   created in the deny path, or track.sh would permanently exempt proof
#   invalidation after a failed Guardian dispatch attempt.
# ===========================================================================

run_test "Gate A denies (pending proof): no .active-guardian-* marker created"
REPO=$(make_temp_repo)
_CLEANUP_DIRS+=("${REPO}")
TRACE=$(make_temp_trace)
_CLEANUP_DIRS+=("${TRACE}")

run_task_track_guardian "$REPO" "$TRACE" "pending|12345"

MARKER_COUNT=$(find "$TRACE" -maxdepth 1 -name ".active-guardian-*" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$MARKER_COUNT" -eq 0 ]]; then
    pass_test
else
    fail_test "Guardian marker created despite Gate A deny (pending proof)"
fi
rm -rf "$REPO" "$TRACE"

# ===========================================================================
# Test 6: Marker naming — marker file matches expected pattern.
#   Pattern: .active-guardian-{CLAUDE_SESSION_ID}-{phash}
#   The pre-dispatch marker uses session ID and project hash, matching the
#   format that finalize_trace() uses for cleanup.
# ===========================================================================

run_test "Marker naming: .active-guardian-{session}-{phash} pattern"
REPO=$(make_temp_repo)
_CLEANUP_DIRS+=("${REPO}")
TRACE=$(make_temp_trace)
_CLEANUP_DIRS+=("${TRACE}")
PHASH=$(echo "$REPO" | $_SHA256_CMD | cut -c1-8)
EXPECTED_SESSION="test-session-race-001"

run_task_track_guardian "$REPO" "$TRACE" "verified|$(date +%s)"

EXPECTED_MARKER="${TRACE}/.active-guardian-${EXPECTED_SESSION}-${PHASH}"
if [[ -f "$EXPECTED_MARKER" ]]; then
    pass_test
else
    # Show what was actually created
    FOUND=$(find "$TRACE" -maxdepth 1 -name ".active-guardian-*" 2>/dev/null || echo "(none)")
    fail_test "Expected marker '$EXPECTED_MARKER' not found. Found: $FOUND"
fi
rm -rf "$REPO" "$TRACE"

# ===========================================================================
# Test 7: Syntax check — task-track.sh is valid bash after the fix
# ===========================================================================

run_test "Syntax: task-track.sh is valid bash after fix"
if bash -n "$TASK_TRACK_SH"; then
    pass_test
else
    fail_test "task-track.sh has syntax errors after fix"
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
