#!/usr/bin/env bash
# Test guard.sh Check 5 (worktree removal CWD safety rewrite) with paths containing spaces.
#
# @decision DEC-GUARD-CHECK5-001
# @title Test suite for guard.sh Check 5 space-path crash fix
# @status accepted
# @rationale Regression tests for the two bugs in Check 5:
#   (1) sed pattern mismatch when `git -C "path"` precedes `worktree remove`,
#       causing WT_PATH to leak the full command string (sed finds no match,
#       the entire input passes through as WT_PATH), the [[ -n ]] guard passes
#       on the garbled value, then bare git worktree list runs.
#   (2) bare `git worktree list` without -C crashes with exit 128 under
#       set -euo pipefail when the hook CWD is not inside any git repo.
#   The fix replaces the fragile sed+xargs+bare-git approach with
#   extract_git_target_dir() (handles -C "quoted path") and
#   git -C "$CHECK5_DIR" worktree list (targets the correct repo regardless
#   of hook CWD), with || echo "" to prevent crash under pipefail.

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

# Helper: build JSON hook input for guard.sh
make_input() {
    local cmd="$1"
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
        "$(printf '%s' "$cmd" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
}

# Helper: assert output is a rewrite (allow+updatedInput), not a crash
assert_rewrite() {
    local output="$1"
    local label="$2"
    if echo "$output" | grep -q '"permissionDecision": "allow"' && \
       echo "$output" | grep -q '"updatedInput"'; then
        pass_test
    elif echo "$output" | grep -q '"permissionDecision": "deny"' && \
         echo "$output" | grep -q "SAFETY"; then
        fail_test "$label: deny-on-crash triggered. Output: $output"
    else
        fail_test "$label: unexpected output (want allow+updatedInput). Got: $output"
    fi
}

# --- Test 1: Syntax check ---
run_test "Syntax: guard.sh is valid bash"
if bash -n "$HOOKS_DIR/guard.sh"; then
    pass_test
else
    fail_test "guard.sh has syntax errors"
fi

# --- Test 2: Bug 2 reproduction: non-git CWD + simple worktree remove ---
# The original bare `git worktree list` exits 128 when CWD is not a git repo.
# The fix uses git -C "$CHECK5_DIR" which targets the correct repo.
run_test "Check5 Bug2: non-git CWD + git worktree remove does not crash"

TARGET_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-check5-target-XXXXXX")
NON_GIT_CWD=$(mktemp -d "$PROJECT_ROOT/tmp/test-check5-nongit-XXXXXX")
git -C "$TARGET_REPO" init > /dev/null 2>&1

CMD="git -C $TARGET_REPO worktree remove $TARGET_REPO/wt"
INPUT_JSON=$(make_input "$CMD")

# Run from NON_GIT_CWD — bare `git worktree list` would exit 128 here
OUTPUT=$(cd "$NON_GIT_CWD" && echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

cd "$PROJECT_ROOT"
rm -rf "$TARGET_REPO" "$NON_GIT_CWD"

assert_rewrite "$OUTPUT" "non-git CWD"

# --- Test 3: Bug 1 reproduction: git -C "path with spaces" worktree remove ---
# The original sed `s/.*git worktree remove.../` doesn't match when -C "path"
# appears between git and worktree. The full command leaks as WT_PATH,
# then bare git worktree list runs from wrong CWD.
run_test "Check5 Bug1: git -C 'path with spaces' worktree remove does not crash"

SPACED_DIR="$PROJECT_ROOT/tmp/test repo with spaces"
NON_GIT_CWD2=$(mktemp -d "$PROJECT_ROOT/tmp/test-check5-nongit2-XXXXXX")
mkdir -p "$SPACED_DIR"
git -C "$SPACED_DIR" init > /dev/null 2>&1

CMD="git -C \"$SPACED_DIR\" worktree remove \"$SPACED_DIR/.worktrees/some-feature\""
INPUT_JSON=$(make_input "$CMD")

# Run from non-git CWD to expose both bugs simultaneously
OUTPUT=$(cd "$NON_GIT_CWD2" && echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

cd "$PROJECT_ROOT"
rm -rf "$SPACED_DIR" "$NON_GIT_CWD2"

assert_rewrite "$OUTPUT" "path-with-spaces + non-git CWD"

# --- Test 4: Simple git worktree remove still gets rewritten (regression) ---
run_test "Check5 Regression: simple 'git worktree remove /path' still rewritten"

SIMPLE_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-check5-simple-XXXXXX")
git -C "$SIMPLE_REPO" init > /dev/null 2>&1

CMD="git worktree remove $SIMPLE_REPO/some-wt"
INPUT_JSON=$(make_input "$CMD")

OUTPUT=$(cd "$SIMPLE_REPO" && echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

cd "$PROJECT_ROOT"
rm -rf "$SIMPLE_REPO"

assert_rewrite "$OUTPUT" "simple path"

# --- Test 5: git -C /no-spaces worktree remove /wt is rewritten ---
run_test "Check5 Regression: git -C /no-spaces worktree remove /wt is rewritten"

NOSPACE_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-check5-nospace-XXXXXX")
NON_GIT_CWD3=$(mktemp -d "$PROJECT_ROOT/tmp/test-check5-nongit3-XXXXXX")
git -C "$NOSPACE_REPO" init > /dev/null 2>&1

CMD="git -C $NOSPACE_REPO worktree remove $NOSPACE_REPO/wt"
INPUT_JSON=$(make_input "$CMD")

OUTPUT=$(cd "$NON_GIT_CWD3" && echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

cd "$PROJECT_ROOT"
rm -rf "$NOSPACE_REPO" "$NON_GIT_CWD3"

assert_rewrite "$OUTPUT" "no-spaces -C path from non-git CWD"

# --- Test 6: Rewritten command starts with 'cd' to main worktree ---
run_test "Check5: rewritten command starts with 'cd' to main worktree"

REWRITE_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-check5-rewrite-XXXXXX")
git -C "$REWRITE_REPO" init > /dev/null 2>&1

CMD="git worktree remove $REWRITE_REPO/a-wt"
INPUT_JSON=$(make_input "$CMD")

OUTPUT=$(cd "$REWRITE_REPO" && echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

cd "$PROJECT_ROOT"
rm -rf "$REWRITE_REPO"

if echo "$OUTPUT" | grep -qE '"command"[[:space:]]*:[[:space:]]*"cd '; then
    pass_test
elif echo "$OUTPUT" | grep -q '"permissionDecision": "deny"' && \
     echo "$OUTPUT" | grep -q "SAFETY"; then
    fail_test "Crashed instead of rewriting. Output: $OUTPUT"
else
    fail_test "Rewritten command does not contain 'cd' prefix. Got: $OUTPUT"
fi

# --- Summary ---
echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
