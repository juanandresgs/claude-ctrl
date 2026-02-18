#!/usr/bin/env bash
# Test guard.sh Check 0.5 (Universal CWD recovery) — detects invalid Bash CWD
# caused by a subagent deleting the orchestrator's worktree, and rewrites the
# command to start with `cd <recovery_dir> &&` to restore a valid working directory.
#
# @decision DEC-GUARD-CWD-001
# @title Test suite for guard.sh Check 0.5 CWD recovery
# @status accepted
# @rationale When Guardian removes a worktree, the orchestrator's Bash CWD still
#   points to the deleted directory. All subsequent orchestrator Bash commands fail
#   with ENOENT. Unlike the subagent's own shell (which source-lib.sh line 25 fixes),
#   the orchestrator's Bash tool shell cannot be repaired by the subagent.
#   guard.sh's rewrite() mechanism propagates the fix because the rewritten command
#   executes in the Bash tool's shell. Check 0.5 intercepts the first command after
#   CWD death and prepends `cd <recovery>` to restore valid state.
#   These tests verify: broken CWD triggers rewrite, valid CWD is a no-op,
#   nuclear-deny still fires before CWD check, git-root traversal finds parent repo,
#   and HOME fallback works when no git root is found.

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
# The .cwd field represents the Bash tool's actual working directory
# (a top-level field in the hook input, not inside .tool_input).
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

# Helper: assert output is a rewrite (allow+updatedInput), not a crash/deny
assert_rewrite() {
    local output="$1"
    local label="$2"
    if echo "$output" | grep -q '"permissionDecision": "allow"' && \
       echo "$output" | grep -q '"updatedInput"'; then
        pass_test
    elif echo "$output" | grep -q '"permissionDecision": "deny"' && \
         echo "$output" | grep -q "SAFETY"; then
        fail_test "$label: deny-on-crash triggered instead of rewrite. Output: $output"
    elif echo "$output" | grep -q '"permissionDecision": "deny"'; then
        fail_test "$label: denied instead of rewrite. Output: $output"
    else
        fail_test "$label: unexpected output (want allow+updatedInput). Got: $output"
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

# --- Test 2: Broken CWD + simple command → rewrite with cd prefix ---
# Simulates: orchestrator's Bash CWD is a deleted worktree directory.
# guard.sh should detect .cwd doesn't exist and rewrite command to cd first.
run_test "Check0.5: broken CWD + 'ls' → rewrite with 'cd' prefix"

NONEXISTENT_DIR="/tmp/nonexistent-worktree-$$-that-was-deleted"
CMD="ls"
INPUT_JSON=$(make_input "$CMD" "$NONEXISTENT_DIR")

OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

if echo "$OUTPUT" | grep -q '"permissionDecision": "allow"' && \
   echo "$OUTPUT" | grep -q '"updatedInput"' && \
   echo "$OUTPUT" | grep -qE '"command"[[:space:]]*:[[:space:]]*"cd '; then
    pass_test
elif echo "$OUTPUT" | grep -q '"permissionDecision": "deny"' && \
     echo "$OUTPUT" | grep -q "SAFETY"; then
    fail_test "deny-on-crash triggered. Output: $OUTPUT"
else
    fail_test "expected rewrite with 'cd' prefix. Got: $OUTPUT"
fi

# --- Test 3: Broken CWD + git command → rewrite with cd prefix ---
# git commands are non-trivial — guard.sh must not crash on git checks
# when the CWD is invalid. Check 0.5 fires BEFORE the early-exit gate.
run_test "Check0.5: broken CWD + 'git status' → rewrite with 'cd' prefix"

NONEXISTENT_DIR2="/tmp/nonexistent-worktree-$$-git-check"
CMD="git status"
INPUT_JSON=$(make_input "$CMD" "$NONEXISTENT_DIR2")

OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

if echo "$OUTPUT" | grep -q '"permissionDecision": "allow"' && \
   echo "$OUTPUT" | grep -q '"updatedInput"' && \
   echo "$OUTPUT" | grep -qE '"command"[[:space:]]*:[[:space:]]*"cd '; then
    pass_test
elif echo "$OUTPUT" | grep -q '"permissionDecision": "deny"' && \
     echo "$OUTPUT" | grep -q "SAFETY"; then
    fail_test "deny-on-crash triggered. Output: $OUTPUT"
else
    fail_test "expected rewrite with 'cd' prefix. Got: $OUTPUT"
fi

# --- Test 4: Broken CWD + nuclear-deny command → DENY (not rewrite) ---
# Nuclear denies (Check 0) fire BEFORE Check 0.5.
# Even with a broken CWD, catastrophic commands must still be denied.
run_test "Check0.5: broken CWD + nuclear command → deny (nuclear fires first)"

NONEXISTENT_DIR3="/tmp/nonexistent-worktree-$$-nuclear"
# Use Category 3 fork bomb — unambiguously nuclear
CMD=':(){ :|:& };:'
INPUT_JSON=$(make_input "$CMD" "$NONEXISTENT_DIR3")

OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

assert_deny "$OUTPUT" "nuclear deny with broken CWD"

# --- Test 5: Valid CWD + any command → no rewrite (passthrough) ---
# When CWD exists, Check 0.5 must be a complete no-op.
run_test "Check0.5: valid CWD + 'ls' → passthrough (no rewrite)"

VALID_DIR="$PROJECT_ROOT"
CMD="ls"
INPUT_JSON=$(make_input "$CMD" "$VALID_DIR")

OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

assert_passthrough "$OUTPUT" "valid CWD passthrough"

# --- Test 6: Empty .cwd field → no rewrite (passthrough) ---
# When .cwd is absent, Check 0.5 must not trigger (BASH_CWD will be empty).
run_test "Check0.5: missing .cwd field → passthrough (no rewrite)"

CMD="ls"
INPUT_JSON=$(make_input "$CMD")  # No cwd argument

OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

assert_passthrough "$OUTPUT" "missing cwd passthrough"

# --- Test 7: Recovery finds parent git root ---
# When .cwd is /repo/root/.worktrees/deleted (nonexistent),
# the walker should find /repo/root as the git ancestor.
run_test "Check0.5: broken CWD inside git repo → recovery uses git root"

TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-cwd-gitroot-XXXXXX")
git -C "$TEMP_REPO" init > /dev/null 2>&1

# The "deleted" worktree path — doesn't actually exist
DELETED_WT="${TEMP_REPO}/.worktrees/my-feature/src/subdir"

CMD="ls"
INPUT_JSON=$(make_input "$CMD" "$DELETED_WT")

OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

rm -rf "$TEMP_REPO"

# Check that the rewrite cd target includes the temp repo path (git root recovery)
if echo "$OUTPUT" | grep -q '"permissionDecision": "allow"' && \
   echo "$OUTPUT" | grep -q '"updatedInput"' && \
   echo "$OUTPUT" | grep -q "$TEMP_REPO"; then
    pass_test
elif echo "$OUTPUT" | grep -q '"permissionDecision": "deny"' && \
     echo "$OUTPUT" | grep -q "SAFETY"; then
    fail_test "deny-on-crash triggered. Output: $OUTPUT"
else
    fail_test "expected rewrite with git root '$TEMP_REPO' in cd target. Got: $OUTPUT"
fi

# --- Test 8: Recovery falls back to HOME when no git root ---
# When the broken CWD path has no git ancestor, fallback must be $HOME.
run_test "Check0.5: broken CWD with no git ancestor → recovery uses HOME"

# /tmp/nonexistent hierarchy — no git root anywhere above
DEEP_NONEXISTENT="/tmp/no-git-here-$$-very/deep/deleted/worktree/path"
CMD="ls"
INPUT_JSON=$(make_input "$CMD" "$DEEP_NONEXISTENT")

OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

if echo "$OUTPUT" | grep -q '"permissionDecision": "allow"' && \
   echo "$OUTPUT" | grep -q '"updatedInput"' && \
   echo "$OUTPUT" | grep -qF "Recovered to $HOME"; then
    pass_test
elif echo "$OUTPUT" | grep -q '"permissionDecision": "deny"' && \
     echo "$OUTPUT" | grep -q "SAFETY"; then
    fail_test "deny-on-crash triggered. Output: $OUTPUT"
else
    fail_test "expected rewrite with HOME='$HOME' as cd target. Got: $OUTPUT"
fi

# --- Summary ---
echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
