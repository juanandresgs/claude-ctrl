#!/usr/bin/env bash
# Test guard.sh Check 0.5 (Universal CWD recovery) — detects invalid Bash CWD
# caused by a subagent deleting the orchestrator's worktree, and rewrites the
# command to start with `cd <recovery_dir> &&` to restore a valid working directory.
#
# Also tests the canary-file (Path B) recovery for the case where .cwd is absent
# or valid but a prior worktree deletion wrote a canary to signal recovery needed.
#
# @decision DEC-GUARD-CWD-001
# @title Test suite for guard.sh Check 0.5 CWD recovery (Path A + Path B canary)
# @status accepted
# @rationale When Guardian removes a worktree, the orchestrator's Bash CWD still
#   points to the deleted directory. All subsequent orchestrator Bash commands fail
#   with ENOENT. Unlike the subagent's own shell (which source-lib.sh line 25 fixes),
#   the orchestrator's Bash tool shell cannot be repaired by the subagent.
#   guard.sh's rewrite() mechanism propagates the fix because the rewritten command
#   executes in the Bash tool's shell. Check 0.5 intercepts the first command after
#   CWD death and prepends `cd <recovery>` to restore valid state.
#   Path A (existing): .cwd field provided and broken → directed recovery to git root.
#   Path B (new): canary file at $HOME/.claude/.cwd-recovery-needed → inline guard
#   prepended to command, canary consumed (one-shot), other checks continue.
#   These tests verify: both paths work correctly, nuclear deny still fires first,
#   canary is one-shot (consumed on read), false alarms are ignored, and git
#   checks still run correctly after the inline guard is prepended.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"
CANARY_FILE="$HOME/.claude/.cwd-recovery-needed"

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

# Cleanup: ensure canary is removed before and after each canary test
cleanup_canary() {
    rm -f "$CANARY_FILE"
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
run_test "Check0.5 Path A: broken CWD + 'ls' → rewrite with 'cd' prefix"

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
run_test "Check0.5 Path A: broken CWD + 'git status' → rewrite with 'cd' prefix"

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

# --- Test 6: Empty .cwd field + no canary → passthrough ---
# When .cwd is absent and no canary exists, Check 0.5 must be a complete no-op.
run_test "Check0.5: missing .cwd field + no canary → passthrough (no rewrite)"

cleanup_canary
CMD="ls"
INPUT_JSON=$(make_input "$CMD")  # No cwd argument

OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

assert_passthrough "$OUTPUT" "missing cwd no canary passthrough"

# --- Test 7: Recovery finds parent git root ---
# When .cwd is /repo/root/.worktrees/deleted (nonexistent),
# the walker should find /repo/root as the git ancestor.
run_test "Check0.5 Path A: broken CWD inside git repo → recovery uses git root"

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
run_test "Check0.5 Path A: broken CWD with no git ancestor → recovery uses HOME"

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

# =============================================================================
# NEW: Path B (canary) tests — Tests 9-12
# These test the canary file detection path added in the canary-cwd feature.
# =============================================================================

# --- Test 9: Canary exists + no .cwd → inline guard prepended, canary consumed ---
# The primary canary scenario: .cwd is absent (framework's CWD is always valid,
# so Claude Code doesn't put a broken .cwd in the hook input). The canary from
# a prior worktree deletion signals that recovery is needed.
run_test "Check0.5 Path B: canary exists + no .cwd → inline guard prepended, canary consumed"

cleanup_canary
# Create a fake "deleted" worktree path in the canary
FAKE_DELETED="/tmp/fake-deleted-worktree-$$-path"
echo "$FAKE_DELETED" > "$CANARY_FILE"

CMD="ls"
INPUT_JSON=$(make_input "$CMD")  # No cwd — simulates framework CWD (always valid)

OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

# Check 1: canary was consumed (one-shot)
CANARY_CONSUMED=false
if [[ ! -f "$CANARY_FILE" ]]; then
    CANARY_CONSUMED=true
fi

# Check 2: output is a rewrite with inline cd guard
if echo "$OUTPUT" | grep -q '"permissionDecision": "allow"' && \
   echo "$OUTPUT" | grep -q '"updatedInput"' && \
   echo "$OUTPUT" | grep -qE 'cd \.' && \
   [[ "$CANARY_CONSUMED" == true ]]; then
    pass_test
elif [[ "$CANARY_CONSUMED" == false ]]; then
    fail_test "canary was NOT consumed (one-shot failed). Output: $OUTPUT"
elif [[ -z "$OUTPUT" ]]; then
    fail_test "expected rewrite but got passthrough (canary not detected). Canary consumed: $CANARY_CONSUMED"
else
    fail_test "expected rewrite with inline guard. Got: $OUTPUT (canary consumed: $CANARY_CONSUMED)"
fi
cleanup_canary

# --- Test 10: Canary exists but deleted path still exists → false alarm, passthrough ---
# If the path in the canary actually exists, the deletion didn't happen (false alarm).
# Canary should be consumed but no guard prepended.
# Note: guard.sh emits a log_info diagnostic to stderr on false alarm — this is
# expected and harmless. We capture stdout only to check for JSON output.
run_test "Check0.5 Path B: canary path still exists → false alarm, canary consumed, passthrough"

cleanup_canary
# Use a path that actually exists
EXISTING_DIR="$PROJECT_ROOT"
echo "$EXISTING_DIR" > "$CANARY_FILE"

CMD="ls"
INPUT_JSON=$(make_input "$CMD")  # No cwd

# Capture stdout only (log_info writes diagnostics to stderr — expected, not an error)
STDOUT_OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>/dev/null) || true

# Canary must be consumed (one-shot, even on false alarm)
CANARY_CONSUMED=false
if [[ ! -f "$CANARY_FILE" ]]; then
    CANARY_CONSUMED=true
fi

if [[ "$CANARY_CONSUMED" == true ]]; then
    # Stdout should be empty (no rewrite needed, path exists)
    assert_passthrough "$STDOUT_OUTPUT" "false alarm: existing path, canary consumed, should be passthrough"
else
    fail_test "false alarm: canary was NOT consumed. Stdout: $STDOUT_OUTPUT"
fi
cleanup_canary

# --- Test 11: Canary exists + .cwd also broken → Path A fires first, canary consumed ---
# When both .cwd is broken AND canary exists, Path A (directed recovery to git root)
# should fire and exit. The canary should be consumed so it doesn't re-trigger.
run_test "Check0.5: canary + broken .cwd → Path A fires (directed recovery), canary consumed"

cleanup_canary
FAKE_DELETED2="/tmp/fake-deleted-canary-$$-combined"
echo "$FAKE_DELETED2" > "$CANARY_FILE"

NONEXISTENT_DIR4="/tmp/nonexistent-worktree-$$-path-a-priority"
CMD="ls"
INPUT_JSON=$(make_input "$CMD" "$NONEXISTENT_DIR4")  # .cwd is broken

OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

# Path A fires: should produce a rewrite with directed cd (to git root or HOME)
# Canary must be consumed (regardless of which path fires)
CANARY_CONSUMED=false
if [[ ! -f "$CANARY_FILE" ]]; then
    CANARY_CONSUMED=true
fi

if echo "$OUTPUT" | grep -q '"permissionDecision": "allow"' && \
   echo "$OUTPUT" | grep -q '"updatedInput"' && \
   echo "$OUTPUT" | grep -qE '"command"[[:space:]]*:[[:space:]]*"cd '; then
    if [[ "$CANARY_CONSUMED" == true ]]; then
        pass_test
    else
        fail_test "Path A fired correctly but canary was NOT consumed. Output: $OUTPUT"
    fi
elif echo "$OUTPUT" | grep -q '"permissionDecision": "deny"' && \
     echo "$OUTPUT" | grep -q "SAFETY"; then
    fail_test "deny-on-crash triggered. Output: $OUTPUT"
else
    fail_test "expected Path A rewrite with 'cd' prefix. Got: $OUTPUT (canary consumed: $CANARY_CONSUMED)"
fi
cleanup_canary

# --- Test 12: Canary exists + git command → inline guard prepended, git checks run ---
# The inline guard must not confuse pattern matching in later checks (git, rm, etc).
# The guard string `{ cd . 2>/dev/null || cd "$HOME" 2>/dev/null || cd /; };`
# should not trigger any other check's deny patterns.
run_test "Check0.5 Path B: canary + non-destructive git command → inline guard + git checks run, no deny"

cleanup_canary
FAKE_DELETED3="/tmp/fake-deleted-canary-$$-git-check"
echo "$FAKE_DELETED3" > "$CANARY_FILE"

# git status is safe — no other check should deny it
CMD="git status"
INPUT_JSON=$(make_input "$CMD")  # No cwd (framework CWD is always valid)

OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

CANARY_CONSUMED=false
if [[ ! -f "$CANARY_FILE" ]]; then
    CANARY_CONSUMED=true
fi

# Expected: rewrite with inline guard prepended, canary consumed, no deny
if echo "$OUTPUT" | grep -q '"permissionDecision": "allow"' && \
   echo "$OUTPUT" | grep -q '"updatedInput"' && \
   echo "$OUTPUT" | grep -qE 'cd \.' && \
   [[ "$CANARY_CONSUMED" == true ]]; then
    pass_test
elif echo "$OUTPUT" | grep -q '"permissionDecision": "deny"'; then
    fail_test "unexpected deny for safe git command with inline guard. Output: $OUTPUT"
elif [[ "$CANARY_CONSUMED" == false ]]; then
    fail_test "canary was NOT consumed. Output: $OUTPUT"
elif [[ -z "$OUTPUT" ]]; then
    fail_test "expected rewrite with inline guard, got passthrough (canary not detected)"
else
    fail_test "expected rewrite with inline guard. Got: $OUTPUT (canary consumed: $CANARY_CONSUMED)"
fi
cleanup_canary

# --- Summary ---
echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
