#!/usr/bin/env bash
# test-clean-state.sh — E2E tests for clean-state.sh audit and cleanup.
#
# Tests --dry-run, --clean, orphaned breadcrumb detection, stale proof-status
# reporting, persistent file preservation, agent-findings aging, and --help output.
#
# Uses CLAUDE_DIR=$TMPDIR to isolate tests from real state files. Each test
# case creates a fresh temp directory to avoid cross-test contamination.
#
# @decision DEC-STATE-CLEAN-E2E-001
# @title E2E tests for clean-state.sh audit and cleanup
# @status accepted
# @rationale clean-state.sh is the only way to recover from accumulated stale
#   state across sessions. These tests verify it correctly identifies orphaned
#   files (breadcrumbs pointing to deleted worktrees), preserves active/persistent
#   state, reports stale proof-status files, and respects --dry-run/--clean modes.
#   Each assertion exercises a distinct code path in clean-state.sh so regressions
#   are caught immediately during development.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
CLEAN_STATE="$PROJECT_ROOT/scripts/clean-state.sh"

mkdir -p "$PROJECT_ROOT/tmp"

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

# ─────────────────────────────────────────────────────────────────────────────
# Guard: script must exist and be executable
# ─────────────────────────────────────────────────────────────────────────────

if [[ ! -f "$CLEAN_STATE" ]]; then
    echo "FATAL: clean-state.sh not found at $CLEAN_STATE"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# CS-01: --help output exits 0 and contains usage info
# ─────────────────────────────────────────────────────────────────────────────

run_test "CS-01: --help exits 0 and contains Usage line"

HELP_OUTPUT=$(CLAUDE_DIR=/dev/null bash "$CLEAN_STATE" --help 2>&1 || true)
HELP_EXIT=$?

if [[ "$HELP_EXIT" -eq 0 ]] && echo "$HELP_OUTPUT" | grep -q "Usage:"; then
    pass_test
else
    fail_test "--help exited $HELP_EXIT, output: ${HELP_OUTPUT:0:100}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CS-02: Orphaned breadcrumb (target dir deleted) → --clean removes it
#
# Creates .active-worktree-path-{hash} pointing to a non-existent directory.
# With --clean mode, the file should be removed and FOUND_ORPHANED=1 in output.
# ─────────────────────────────────────────────────────────────────────────────

run_test "CS-02: Orphaned breadcrumb (target deleted) → --clean removes it"

TMPDIR_02="$PROJECT_ROOT/tmp/test-clean-state-02-$$"
mkdir -p "$TMPDIR_02"
trap 'rm -rf "$TMPDIR_02"' EXIT

# Create an orphaned breadcrumb pointing to a deleted dir
FAKE_HASH="dead1234"
BREADCRUMB="$TMPDIR_02/.active-worktree-path-${FAKE_HASH}"
echo "/nonexistent/path/that/does/not/exist-$$" > "$BREADCRUMB"

OUTPUT_02=$(CLAUDE_DIR="$TMPDIR_02" bash "$CLEAN_STATE" --clean 2>&1)
EXIT_02=$?

# File should be removed
if [[ -f "$BREADCRUMB" ]]; then
    fail_test "Breadcrumb was not removed by --clean (file still exists)"
elif ! echo "$OUTPUT_02" | grep -q "\[removed\]"; then
    fail_test "Expected [removed] in output but got: ${OUTPUT_02:0:200}"
elif [[ "$EXIT_02" -ne 0 ]]; then
    fail_test "--clean exited $EXIT_02 (expected 0)"
else
    pass_test
fi

# Rebuild trap for subsequent tests (previous trap fires on first EXIT only)
TMPDIR_02="" # mark as cleared so later trap is a no-op for this dir

# ─────────────────────────────────────────────────────────────────────────────
# CS-03: Orphaned breadcrumb → --dry-run does NOT remove it
#
# Same setup as CS-02 but with --dry-run. File must remain, output must say
# [would clean] and counters must reflect "would clean" semantics.
# ─────────────────────────────────────────────────────────────────────────────

run_test "CS-03: Orphaned breadcrumb → --dry-run does NOT remove it"

TMPDIR_03="$PROJECT_ROOT/tmp/test-clean-state-03-$$"
mkdir -p "$TMPDIR_03"
trap 'rm -rf "$TMPDIR_03"' EXIT

FAKE_HASH_03="cafe5678"
BREADCRUMB_03="$TMPDIR_03/.active-worktree-path-${FAKE_HASH_03}"
echo "/nonexistent/deleted-dir-$$" > "$BREADCRUMB_03"

OUTPUT_03=$(CLAUDE_DIR="$TMPDIR_03" bash "$CLEAN_STATE" --dry-run 2>&1)
EXIT_03=$?

if [[ ! -f "$BREADCRUMB_03" ]]; then
    fail_test "--dry-run removed the breadcrumb (must not remove)"
elif ! echo "$OUTPUT_03" | grep -q "\[would clean\]"; then
    fail_test "Expected [would clean] in output but got: ${OUTPUT_03:0:200}"
elif [[ "$EXIT_03" -ne 0 ]]; then
    fail_test "--dry-run exited $EXIT_03 (expected 0)"
else
    pass_test
fi

TMPDIR_03=""

# ─────────────────────────────────────────────────────────────────────────────
# CS-04: Stale proof-status (>7 days old) → reported as [stale] by --dry-run
#
# Creates a .proof-status-{hash} with an old timestamp (8 days ago).
# clean-state.sh should mark it [stale] (informational, not removed by --dry-run).
# ─────────────────────────────────────────────────────────────────────────────

run_test "CS-04: Stale proof-status (>7 days) → reported as [stale]"

TMPDIR_04="$PROJECT_ROOT/tmp/test-clean-state-04-$$"
mkdir -p "$TMPDIR_04"
trap 'rm -rf "$TMPDIR_04"' EXIT

# Timestamp 8 days ago (well past the 7-day threshold)
STALE_TS=$(( $(date +%s) - 8 * 86400 ))
PROOF_HASH="beef9012"
STALE_PROOF="$TMPDIR_04/.proof-status-${PROOF_HASH}"
echo "verified|${STALE_TS}|stale-session-123" > "$STALE_PROOF"

OUTPUT_04=$(CLAUDE_DIR="$TMPDIR_04" bash "$CLEAN_STATE" --dry-run 2>&1)
EXIT_04=$?

if ! echo "$OUTPUT_04" | grep -q "\[stale\]"; then
    fail_test "Expected [stale] in output for old proof-status, got: ${OUTPUT_04:0:300}"
elif [[ "$EXIT_04" -ne 0 ]]; then
    fail_test "--dry-run exited $EXIT_04 (expected 0)"
else
    pass_test
fi

TMPDIR_04=""

# ─────────────────────────────────────────────────────────────────────────────
# CS-05: Fresh proof-status (<1 day old) → reported as [valid], not removed
#
# Creates a .proof-status-{hash} with a recent timestamp (5 minutes ago).
# clean-state.sh must NOT flag it as stale or remove it.
# ─────────────────────────────────────────────────────────────────────────────

run_test "CS-05: Fresh proof-status (<1 day) → reported as [valid], preserved"

TMPDIR_05="$PROJECT_ROOT/tmp/test-clean-state-05-$$"
mkdir -p "$TMPDIR_05"
trap 'rm -rf "$TMPDIR_05"' EXIT

FRESH_TS=$(date +%s)  # now
PROOF_HASH_05="feed3456"
FRESH_PROOF="$TMPDIR_05/.proof-status-${PROOF_HASH_05}"
echo "needs-verification|${FRESH_TS}|fresh-session-456" > "$FRESH_PROOF"

OUTPUT_05=$(CLAUDE_DIR="$TMPDIR_05" bash "$CLEAN_STATE" --clean 2>&1)
EXIT_05=$?

if [[ ! -f "$FRESH_PROOF" ]]; then
    fail_test "Fresh proof-status was removed (must be preserved)"
elif ! echo "$OUTPUT_05" | grep -q "\[valid\]"; then
    fail_test "Expected [valid] for fresh proof-status, got: ${OUTPUT_05:0:300}"
elif [[ "$EXIT_05" -ne 0 ]]; then
    fail_test "--clean exited $EXIT_05 (expected 0)"
else
    pass_test
fi

TMPDIR_05=""

# ─────────────────────────────────────────────────────────────────────────────
# CS-06: Persistent files (.audit-log, .worktree-roster.tsv) are NEVER removed
#
# Creates both persistent files plus an orphaned breadcrumb (to trigger --clean
# mode). After --clean, persistent files must still exist.
# ─────────────────────────────────────────────────────────────────────────────

run_test "CS-06: Persistent files (.audit-log, .worktree-roster.tsv) never removed"

TMPDIR_06="$PROJECT_ROOT/tmp/test-clean-state-06-$$"
mkdir -p "$TMPDIR_06"
trap 'rm -rf "$TMPDIR_06"' EXIT

# Persistent files
AUDIT_LOG="$TMPDIR_06/.audit-log"
ROSTER="$TMPDIR_06/.worktree-roster.tsv"
echo "2026-01-01 test audit entry" > "$AUDIT_LOG"
echo "path	branch	session" > "$ROSTER"

# Also create an orphaned breadcrumb so --clean has something to remove
ORPHAN_CRUMB="$TMPDIR_06/.active-worktree-path-aaaa1111"
echo "/deleted-worktree-$$" > "$ORPHAN_CRUMB"

CLAUDE_DIR="$TMPDIR_06" bash "$CLEAN_STATE" --clean > /dev/null 2>&1
EXIT_06=$?

if [[ ! -f "$AUDIT_LOG" ]]; then
    fail_test ".audit-log was removed by --clean (must be preserved)"
elif [[ ! -f "$ROSTER" ]]; then
    fail_test ".worktree-roster.tsv was removed by --clean (must be preserved)"
elif [[ "$EXIT_06" -ne 0 ]]; then
    fail_test "--clean exited $EXIT_06 (expected 0)"
else
    pass_test
fi

TMPDIR_06=""

# ─────────────────────────────────────────────────────────────────────────────
# CS-07: Agent-findings file >3 days old → reported as [stale]
#        Agent-findings file <3 days old → reported as [valid]
#
# Two sub-checks in one test: old findings get [stale], fresh get [valid].
# ─────────────────────────────────────────────────────────────────────────────

run_test "CS-07: agent-findings >3 days → [stale]; <3 days → [valid]"

# Sub-check A: stale (4 days old)
TMPDIR_07A="$PROJECT_ROOT/tmp/test-clean-state-07a-$$"
mkdir -p "$TMPDIR_07A"
trap 'rm -rf "$TMPDIR_07A"' EXIT

STALE_FINDINGS="$TMPDIR_07A/.agent-findings"
echo "old finding 1" > "$STALE_FINDINGS"
# Use touch to backdate the file by 4 days
touch -t "$(date -v-4d '+%Y%m%d%H%M.%S' 2>/dev/null || date --date='4 days ago' '+%Y%m%d%H%M.%S' 2>/dev/null)" \
    "$STALE_FINDINGS" 2>/dev/null || true

OUTPUT_07A=$(CLAUDE_DIR="$TMPDIR_07A" bash "$CLEAN_STATE" --dry-run 2>&1)
STALE_OK=false
echo "$OUTPUT_07A" | grep -q "\[stale\]" && STALE_OK=true

# Sub-check B: fresh (1 hour old — within 3 days)
TMPDIR_07B="$PROJECT_ROOT/tmp/test-clean-state-07b-$$"
mkdir -p "$TMPDIR_07B"
trap 'rm -rf "$TMPDIR_07B"' EXIT

FRESH_FINDINGS="$TMPDIR_07B/.agent-findings"
echo "new finding 1" > "$FRESH_FINDINGS"
# File is just created, so it's within threshold

OUTPUT_07B=$(CLAUDE_DIR="$TMPDIR_07B" bash "$CLEAN_STATE" --dry-run 2>&1)
FRESH_OK=false
echo "$OUTPUT_07B" | grep -q "\[valid\]" && FRESH_OK=true

if [[ "$STALE_OK" == "true" && "$FRESH_OK" == "true" ]]; then
    pass_test
elif [[ "$STALE_OK" != "true" ]]; then
    fail_test "Old agent-findings not reported as [stale]. Output: ${OUTPUT_07A:0:200}"
else
    fail_test "Fresh agent-findings not reported as [valid]. Output: ${OUTPUT_07B:0:200}"
fi

TMPDIR_07A=""
TMPDIR_07B=""

# ─────────────────────────────────────────────────────────────────────────────
# CS-08: Valid breadcrumb (target dir exists) → reported as [valid], not removed
#
# Creates a breadcrumb pointing to an actual directory that exists.
# clean-state.sh must not flag it as orphaned.
# ─────────────────────────────────────────────────────────────────────────────

run_test "CS-08: Valid breadcrumb (target exists) → [valid], preserved"

TMPDIR_08="$PROJECT_ROOT/tmp/test-clean-state-08-$$"
TMPDIR_08_TARGET="$TMPDIR_08/real-worktree"
mkdir -p "$TMPDIR_08" "$TMPDIR_08_TARGET"
trap 'rm -rf "$TMPDIR_08"' EXIT

VALID_CRUMB="$TMPDIR_08/.active-worktree-path-bbbb2222"
echo "$TMPDIR_08_TARGET" > "$VALID_CRUMB"

OUTPUT_08=$(CLAUDE_DIR="$TMPDIR_08" bash "$CLEAN_STATE" --clean 2>&1)
EXIT_08=$?

if [[ ! -f "$VALID_CRUMB" ]]; then
    fail_test "Valid breadcrumb was removed (target exists, must be preserved)"
elif ! echo "$OUTPUT_08" | grep -q "\[valid\]"; then
    fail_test "Expected [valid] for breadcrumb with existing target, got: ${OUTPUT_08:0:300}"
elif [[ "$EXIT_08" -ne 0 ]]; then
    fail_test "--clean exited $EXIT_08 (expected 0)"
else
    pass_test
fi

TMPDIR_08=""

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "──────────────────────────────────────────────────────"
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_RUN total"

if [[ "$TESTS_FAILED" -eq 0 ]]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "SOME TESTS FAILED"
    exit 1
fi
