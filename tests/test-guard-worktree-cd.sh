#!/usr/bin/env bash
# Test guard.sh Check 0.75 (Deny ALL cd/pushd into .worktrees/).
#
# Check 0.75 intercepts ALL Bash commands that contain `cd` or `pushd` targeting a
# .worktrees/ path — both bare cd and chained commands. Such commands would leave
# the Bash tool CWD inside a deletable worktree directory — when the worktree is
# later removed ALL hooks fail (posix_spawn ENOENT on macOS).
#
# Prevention strategy: deny ALL cd/pushd into .worktrees/ and include the correct
# subshell or git -C pattern in the deny reason. updatedInput (rewrite) is NOT
# supported in PreToolUse hooks — only in PermissionRequest hooks — so rewrite()
# silently fails and denial is the only reliable fix.
# Commands already wrapped in a subshell ("( ...") pass through immediately.
#
# @decision DEC-GUARD-CWD-003
# @title Test suite for guard.sh Check 0.75 — deny ALL cd/pushd into .worktrees/
# @status accepted
# @rationale posix_spawn returns ENOENT on macOS when the parent process CWD is a
#   deleted directory. The canary approach (Path B, now removed) only recovered
#   PreToolUse:Bash; Edit hooks, Stop hooks, and SessionEnd hooks cannot be recovered.
#   Prevention is the only reliable fix. This test suite validates that:
#   (1) chained cd-into-worktree commands are denied with CWD protection message,
#   (2) bare cd-into-worktree commands are ALSO denied (exemption removed),
#   (3) already-subshell-wrapped commands pass through (correct resubmit path),
#   (4) subshell-wrapped cd commands pass through (( cd .worktrees/x && cmd )),
#   (5) git -C .worktrees/x commands pass through (safe pattern), and
#   (6) commands that mention .worktrees/ without cd/pushd are not affected.

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

# Helper: build JSON hook input for guard.sh (no .cwd field needed for these tests)
make_input() {
    local cmd="$1"
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
        "$(printf '%s' "$cmd" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
}

# Helper: assert output is a deny with the subshell suggestion in the reason
assert_deny_with_suggestion() {
    local output="$1"
    local label="$2"
    if echo "$output" | grep -q '"permissionDecision": "deny"' && \
       echo "$output" | grep -q 'CWD protection'; then
        pass_test
    elif echo "$output" | grep -q '"permissionDecision": "deny"' && \
         echo "$output" | grep -q "SAFETY"; then
        fail_test "$label: deny-on-crash triggered instead of deny-with-suggestion. Output: $output"
    elif echo "$output" | grep -q '"permissionDecision": "deny"'; then
        fail_test "$label: denied but missing 'CWD protection' in reason. Output: $output"
    elif echo "$output" | grep -q '"updatedInput"'; then
        fail_test "$label: got rewrite (updatedInput) instead of deny — updatedInput is not supported in PreToolUse. Output: $output"
    else
        fail_test "$label: expected deny with subshell suggestion. Got: $output"
    fi
}

# Helper: assert output is empty (passthrough — guard has no opinion)
assert_passthrough() {
    local output="$1"
    local label="$2"
    if [[ -z "$output" ]]; then
        pass_test
    elif echo "$output" | grep -q '"permissionDecision": "allow"' && \
         echo "$output" | grep -q '"updatedInput"'; then
        local rewritten
        rewritten=$(echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["hookSpecificOutput"]["updatedInput"]["command"])' 2>/dev/null || echo "")
        fail_test "$label: unexpected rewrite (want passthrough/empty). Rewritten to: $rewritten"
    elif echo "$output" | grep -q '"permissionDecision": "deny"'; then
        fail_test "$label: unexpected deny (want passthrough/empty). Got: $output"
    else
        fail_test "$label: unexpected output (want empty). Got: $output"
    fi
}

# --- Test 0: Syntax check ---
run_test "Syntax: guard.sh is valid bash"
if bash -n "$HOOKS_DIR/guard.sh"; then
    pass_test
else
    fail_test "guard.sh has syntax errors"
fi

# --- Test 1: cd .worktrees/foo && git status → DENY with suggestion ---
# The most common orchestrator anti-pattern: cd into worktree then run a command.
# This would leave the orchestrator's Bash CWD inside a deletable directory.
run_test "Check0.75: 'cd .worktrees/foo && git status' → DENY with subshell suggestion"

CMD="cd .worktrees/foo && git status"
INPUT_JSON=$(make_input "$CMD")
OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>/dev/null) || true

assert_deny_with_suggestion "$OUTPUT" "cd relative .worktrees + git status"

# --- Test 2: cd /abs/.worktrees/foo && python3 -c "test" → DENY with suggestion ---
# Absolute path variant — the pattern must work regardless of path style.
run_test "Check0.75: 'cd /abs/.worktrees/foo && python3 -c ...' → DENY with subshell suggestion"

CMD='cd /home/user/.worktrees/feature-x && python3 -c "import sys; print(sys.version)"'
INPUT_JSON=$(make_input "$CMD")
OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>/dev/null) || true

assert_deny_with_suggestion "$OUTPUT" "cd absolute .worktrees + python3"

# --- Test 3: pushd .worktrees/foo && make → DENY with suggestion ---
# pushd is equivalent to cd for CWD persistence — must be caught too.
run_test "Check0.75: 'pushd .worktrees/foo && make' → DENY with subshell suggestion"

CMD="pushd .worktrees/feature-build && make test"
INPUT_JSON=$(make_input "$CMD")
OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>/dev/null) || true

assert_deny_with_suggestion "$OUTPUT" "pushd .worktrees + make"

# --- Test 4: cd .worktrees/foo ; echo done → DENY with suggestion (semicolon) ---
# Semicolons are also command separators — chained commands after ; must trigger deny.
run_test "Check0.75: 'cd .worktrees/foo ; echo done' → DENY with subshell suggestion (semicolon)"

CMD="cd .worktrees/my-feature ; echo done"
INPUT_JSON=$(make_input "$CMD")
OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>/dev/null) || true

assert_deny_with_suggestion "$OUTPUT" "cd .worktrees + semicolon + echo"

# --- Test 5: cd .worktrees/foo (bare) → DENY (bare-cd exemption removed) ---
# Bare cd into a worktree is now denied — persistent CWD in a deletable
# directory causes posix_spawn ENOENT if the worktree is later removed.
# The previous exemption for subagents is removed; use subshell or git -C instead.
run_test "Check0.75: 'cd .worktrees/foo' (bare) → DENY (no more bare-cd exemption)"

CMD="cd .worktrees/feature-mywork"
INPUT_JSON=$(make_input "$CMD")
OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>/dev/null) || true

assert_deny_with_suggestion "$OUTPUT" "bare cd .worktrees (now denied)"

# --- Test 6: ls .worktrees/foo → PASSTHROUGH (no cd detected) ---
# Commands that reference .worktrees/ paths without cd/pushd must not be affected.
run_test "Check0.75: 'ls .worktrees/foo' → PASSTHROUGH (not a cd command)"

CMD="ls .worktrees/feature-x"
INPUT_JSON=$(make_input "$CMD")
OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>/dev/null) || true

assert_passthrough "$OUTPUT" "ls .worktrees (not a cd)"

# --- Test 7: git -C .worktrees/foo status → PASSTHROUGH (git -C, not cd) ---
# git -C changes directory internally but does NOT change the shell CWD.
# This is the preferred pattern (per CLAUDE.md) and must never be blocked.
run_test "Check0.75: 'git -C .worktrees/foo status' → PASSTHROUGH (git -C is safe)"

CMD="git -C .worktrees/feature-foo status"
INPUT_JSON=$(make_input "$CMD")
OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>/dev/null) || true

assert_passthrough "$OUTPUT" "git -C .worktrees (no cd)"

# --- Test 8: export FOO=1 && cd .worktrees/x && cmd → DENY with suggestion ---
# Complex multi-step command: the entire original command must appear in the suggestion.
run_test "Check0.75: 'export FOO=1 && cd .worktrees/x && cmd' → DENY with subshell suggestion"

CMD="export FOO=bar && cd .worktrees/feature-complex && bash run.sh"
INPUT_JSON=$(make_input "$CMD")
OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>/dev/null) || true

assert_deny_with_suggestion "$OUTPUT" "export + cd .worktrees + bash run.sh"

# Verify the suggested subshell in the deny reason contains the full original command
EXPECTED_SUGGESTION="( $CMD )"
if echo "$OUTPUT" | grep -qF "$EXPECTED_SUGGESTION"; then
    echo "  NOTE: content check passed — suggested subshell contains full original command"
else
    echo "  NOTE: content check: deny reason does not contain expected suggestion '$EXPECTED_SUGGESTION'"
fi

# --- Test 9: cd .worktrees/foo || exit 1 → DENY with suggestion (|| separator) ---
# Logical OR after the worktree path — || also indicates chained commands.
run_test "Check0.75: 'cd .worktrees/foo || exit 1' → DENY with subshell suggestion (|| separator)"

CMD="cd .worktrees/feature-fallback || exit 1"
INPUT_JSON=$(make_input "$CMD")
OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>/dev/null) || true

assert_deny_with_suggestion "$OUTPUT" "cd .worktrees + || exit"

# --- Test 10: ( cd .worktrees/foo && ls ) → PASSTHROUGH (already subshell-wrapped) ---
# Model resubmit path: after a deny the model wraps in subshell and resubmits.
# This must pass through immediately — no double-deny loop.
run_test "Check0.75: '( cd .worktrees/foo && ls )' → PASSTHROUGH (already subshell-wrapped)"

CMD="( cd .worktrees/feature-mywork && ls )"
INPUT_JSON=$(make_input "$CMD")
OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>/dev/null) || true

assert_passthrough "$OUTPUT" "already subshell-wrapped (model resubmit)"

# --- Test 11: ( cd .worktrees/foo && npm install ) → PASSTHROUGH (subshell safe) ---
# Subshell pattern is the correct way to operate in a worktree.
# The outer shell CWD never changes, so framework CWD stays safe.
run_test "Check0.75: '( cd .worktrees/foo && npm install )' → PASSTHROUGH (subshell safe)"

CMD="( cd .worktrees/feature-deps && npm install )"
INPUT_JSON=$(make_input "$CMD")
OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>/dev/null) || true

assert_passthrough "$OUTPUT" "subshell cd .worktrees + npm install"

# --- Summary ---
echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
