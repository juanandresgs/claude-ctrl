#!/usr/bin/env bash
# test-session-kv.sh — Unit tests for session_start_epoch and prompt_count KV migration
#
# Validates DEC-STATE-KV-002: migrating .session-start-epoch and .prompt-count-{SESSION_ID}
# from flat files to SQLite KV store (state_update/state_read/state_delete).
#
# Tests:
#   T01: state_update/state_read cycle for session_start_epoch
#   T02: state_update/state_read cycle for prompt_count
#   T03: state_delete cleans both keys
#   T04: First-prompt detection — key absent → first prompt; key present → not first
#
# @decision DEC-STATE-KV-002
# @title Migrate session_start_epoch and prompt_count to SQLite KV store
# @status accepted
# @rationale These two dotfiles are written together in the first-prompt block of
#   prompt-submit.sh and cleaned together in session-init.sh and session-end.sh.
#   Migrating them to SQLite provides atomic writes and eliminates race conditions
#   between concurrent processes. Flat-file dual-write retained during migration
#   window for backward compatibility.
#
# Usage: bash tests/test-session-kv.sh
# Scope: --scope session-kv in run-hooks.sh

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"

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
# Setup: isolated temp dir, cleaned up on EXIT
# ---------------------------------------------------------------------------
TMPDIR_BASE="$PROJECT_ROOT/tmp/test-session-kv-$$"
mkdir -p "$TMPDIR_BASE"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ---------------------------------------------------------------------------
# Helper: isolated env with git repo + .claude dir
# ---------------------------------------------------------------------------
make_temp_env() {
    local dir
    dir="$TMPDIR_BASE/env-$RANDOM"
    mkdir -p "$dir/.claude"
    git -C "$dir" init -q 2>/dev/null || true
    echo "$dir"
}

# ---------------------------------------------------------------------------
# Source hook libraries
# ---------------------------------------------------------------------------
_HOOK_NAME="test-session-kv"
source "$HOOKS_DIR/log.sh" 2>/dev/null
source "$HOOKS_DIR/source-lib.sh" 2>/dev/null
require_state

# ===========================================================================
# T01: state_update/state_read cycle for session_start_epoch
# ===========================================================================
run_test "T01: state_update/state_read for session_start_epoch"

ENV1=$(make_temp_env)
export HOME="$ENV1"
export CLAUDE_DIR="$ENV1/.claude"
export PROJECT_ROOT_OVERRIDE="$ENV1"

EPOCH_VAL="$(date +%s)"
state_update "session_start_epoch" "$EPOCH_VAL" "test-session-kv" 2>/dev/null || true

RESULT=$(state_read "session_start_epoch" 2>/dev/null || echo "")
if [[ "$RESULT" == "$EPOCH_VAL" ]]; then
    pass_test
else
    fail_test "Expected '$EPOCH_VAL', got '$RESULT'"
fi

# ===========================================================================
# T02: state_update/state_read cycle for prompt_count
# ===========================================================================
run_test "T02: state_update/state_read for prompt_count"

# Writing "1" simulates first prompt initialization
state_update "prompt_count" "1" "test-session-kv" 2>/dev/null || true

RESULT=$(state_read "prompt_count" 2>/dev/null || echo "")
if [[ "$RESULT" == "1" ]]; then
    pass_test
else
    fail_test "Expected '1', got '$RESULT'"
fi

# Also verify increment: write "2" and read it back
state_update "prompt_count" "2" "test-session-kv" 2>/dev/null || true
RESULT=$(state_read "prompt_count" 2>/dev/null || echo "")
if [[ "$RESULT" == "2" ]]; then
    pass_test
else
    fail_test "After increment: Expected '2', got '$RESULT'"
    TESTS_RUN=$((TESTS_RUN + 1))  # extra assertion counted
fi

# ===========================================================================
# T03: state_delete cleans both keys
# ===========================================================================
run_test "T03: state_delete cleans session_start_epoch and prompt_count"

# Ensure both keys are present before delete
state_update "session_start_epoch" "$(date +%s)" "test-session-kv" 2>/dev/null || true
state_update "prompt_count" "5" "test-session-kv" 2>/dev/null || true

# Delete both
state_delete "session_start_epoch" 2>/dev/null || true
state_delete "prompt_count" 2>/dev/null || true

EPOCH_AFTER=$(state_read "session_start_epoch" 2>/dev/null || echo "")
COUNT_AFTER=$(state_read "prompt_count" 2>/dev/null || echo "")

if [[ -z "$EPOCH_AFTER" && -z "$COUNT_AFTER" ]]; then
    pass_test
else
    fail_test "After delete: session_start_epoch='$EPOCH_AFTER', prompt_count='$COUNT_AFTER' (both should be empty)"
fi

# ===========================================================================
# T04: First-prompt detection — key absent → first prompt; key present → not first
#
# After T03 deleted prompt_count, the key is absent. We verify:
#   (a) state_read returns empty → first-prompt path would fire
#   (b) After state_update, state_read returns the value → subsequent prompts skip first-prompt
# ===========================================================================
run_test "T04: first-prompt detection via prompt_count key presence"

# (a) T03 already deleted prompt_count — verify key is absent
ABSENT=$(state_read "prompt_count" 2>/dev/null || echo "")
if [[ -z "$ABSENT" ]]; then
    # Simulate first-prompt: write prompt_count=1
    state_update "prompt_count" "1" "test-session-kv" 2>/dev/null || true
    # (b) Now key is present — subsequent prompts should NOT enter first-prompt block
    PRESENT=$(state_read "prompt_count" 2>/dev/null || echo "")
    if [[ -n "$PRESENT" ]]; then
        pass_test
    else
        fail_test "After state_update prompt_count=1, state_read returned empty (not-first-prompt detection broken)"
    fi
else
    fail_test "Expected absent prompt_count after T03 cleanup, got '$ABSENT'"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
