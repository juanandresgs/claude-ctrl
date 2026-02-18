#!/usr/bin/env bash
# Test guard.sh CWD handling — validates that nuclear deny fires even with broken
# CWD, and that valid/missing CWD doesn't trigger false positives.
#
# Check 0.5 (Path A + Path B canary recovery) has been REMOVED because rewrite()
# (updatedInput) is not supported in PreToolUse hooks — it silently fails.
# Prevention (Check 0.75: deny all cd into .worktrees/) is the only reliable fix.
#
# These tests validate the remaining CWD-related behaviors:
#   (1) nuclear deny fires first regardless of CWD state,
#   (2) valid CWD passes through normally,
#   (3) missing .cwd field passes through normally.
#
# @decision DEC-GUARD-CWD-001
# @title Test suite for guard.sh CWD handling after Check 0.5 removal
# @status accepted
# @rationale Check 0.5 (Path A directed recovery + Path B canary recovery) was removed
#   because updatedInput/rewrite() is not supported in PreToolUse hooks — it silently
#   fails and the original command runs unmodified. Prevention via Check 0.75 (deny all
#   cd into .worktrees/) is now the only CWD safety strategy. These tests validate the
#   remaining CWD-related behaviors: nuclear deny priority, valid CWD passthrough, and
#   missing .cwd field passthrough.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"

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

# Helper: build JSON hook input for guard.sh, with optional .cwd field.
make_input() {
    local cmd="$1"
    local cwd="${2:-}"
    local cmd_json
    cmd_json=$(printf '%s' "$cmd" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
    if [[ -n "$cwd" ]]; then
        local cwd_json
        cwd_json=$(printf '%s' "$cwd" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
        printf '{"tool_name":"Bash","tool_input":{"command":%s},"cwd":%s}' "$cmd_json" "$cwd_json"
    else
        printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$cmd_json"
    fi
}

# Helper: assert output is a deny
assert_deny() {
    local output="$1"
    local label="$2"
    if echo "$output" | grep -q '"permissionDecision": "deny"'; then
        pass_test
    else
        fail_test "$label: expected deny but got: $output"
    fi
}

# Helper: assert output is empty (guard.sh exits silently for allowed commands)
assert_passthrough() {
    local output="$1"
    local label="$2"
    if [[ -z "$output" ]]; then
        pass_test
    elif echo "$output" | grep -q '"permissionDecision": "allow"' && \
         echo "$output" | grep -q '"updatedInput"'; then
        fail_test "$label: unexpected rewrite (want passthrough/empty). Got: $output"
    elif echo "$output" | grep -q '"permissionDecision": "deny"'; then
        fail_test "$label: unexpected deny (want passthrough/empty). Got: $output"
    else
        fail_test "$label: unexpected output (want empty). Got: $output"
    fi
}

# --- Test 1: Syntax check ---
run_test "Syntax: guard.sh is valid bash"
if bash -n "$HOOKS_DIR/guard.sh"; then
    pass_test
else
    fail_test "guard.sh has syntax errors"
fi

# --- Test 2: Broken CWD + nuclear-deny command → DENY (nuclear fires first) ---
# Nuclear denies (Check 0) fire BEFORE any CWD handling.
# Even with a broken CWD, catastrophic commands must still be denied.
run_test "Broken CWD + nuclear command → deny (nuclear fires first)"

NONEXISTENT_DIR="/tmp/nonexistent-worktree-$$-nuclear"
CMD=':(){ :|:& };:'
INPUT_JSON=$(make_input "$CMD" "$NONEXISTENT_DIR")

OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

assert_deny "$OUTPUT" "nuclear deny with broken CWD"

# --- Test 3: Valid CWD + any command → passthrough ---
# When CWD exists, no CWD-related checks should interfere.
run_test "Valid CWD + 'ls' → passthrough (no interference)"

VALID_DIR="$PROJECT_ROOT"
CMD="ls"
INPUT_JSON=$(make_input "$CMD" "$VALID_DIR")

OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

assert_passthrough "$OUTPUT" "valid CWD passthrough"

# --- Test 4: Missing .cwd field → passthrough ---
# When .cwd is absent, no CWD-related checks should interfere.
run_test "Missing .cwd field → passthrough (no interference)"

CMD="ls"
INPUT_JSON=$(make_input "$CMD")  # No cwd argument

OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

assert_passthrough "$OUTPUT" "missing cwd passthrough"

# --- Summary ---
echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
