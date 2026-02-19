#!/usr/bin/env bash
# @file test-guard-commit-msg.sh
# @description Regression tests for Issue #126/#91: commit message content triggering
#   git-specific guards. guard.sh must NOT deny git commands where the forbidden
#   pattern appears only inside the quoted commit message, not in the command structure.
#
# @decision DEC-GUARD-001
# @title Quoted-string stripping prevents commit message content from triggering checks
# @status accepted
# @rationale The root cause of #126: downstream checks (2-10) matched against raw
#   $COMMAND, so `git commit -m "fix branch -D handling"` triggered the branch-D deny
#   in Check 4. The fix computes $_stripped_cmd (quotes removed) early and uses it
#   for all pattern-matching. Raw $COMMAND is kept only for command construction.
#   These tests verify:
#   (1) False positive cases: git operations with forbidden text only in the message
#       must NOT be denied.
#   (2) True positive cases: real destructive operations must STILL be denied.

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

# Helper: assert output is a deny (safety block)
assert_deny() {
    local output="$1"
    local label="$2"
    if echo "$output" | grep -q '"permissionDecision": "deny"'; then
        if echo "$output" | grep -q "SAFETY: guard.sh crashed"; then
            fail_test "$label: deny-on-crash triggered (guard.sh crashed). Output: $output"
        else
            pass_test
        fi
    else
        fail_test "$label: expected deny but got allow. Output: $output"
    fi
}

# Helper: assert output is NOT a deny (command should pass through)
# guard.sh exits 0 with no output when a command is allowed.
assert_allow() {
    local output="$1"
    local label="$2"
    if echo "$output" | grep -q '"permissionDecision": "deny"'; then
        # Extract the reason for a useful failure message
        local reason
        reason=$(echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["hookSpecificOutput"]["permissionDecisionReason"])' 2>/dev/null || echo "(could not parse reason)")
        fail_test "$label: was denied but should be allowed. Reason: $reason"
    else
        pass_test
    fi
}

# --- Test 1: Syntax check ---
run_test "Syntax: guard.sh is valid bash"
if bash -n "$HOOKS_DIR/guard.sh"; then
    pass_test
else
    fail_test "guard.sh has syntax errors"
fi

# --- Test 2: Dead code removed — rewrite() must not exist ---
run_test "Dead code: rewrite() function is removed"
if grep -n 'rewrite()' "$HOOKS_DIR/guard.sh" | grep -v '#' | grep -q 'rewrite()'; then
    fail_test "rewrite() function still present in guard.sh"
else
    pass_test
fi

# --- Test 3: Dead code removed — is_same_project() must not exist ---
run_test "Dead code: is_same_project() function is removed"
if grep -n 'is_same_project()' "$HOOKS_DIR/guard.sh" | grep -v '#' | grep -q 'is_same_project()'; then
    fail_test "is_same_project() function still present in guard.sh"
else
    pass_test
fi

# --- Test 4: is_guardian_active() helper must exist ---
run_test "Helper: is_guardian_active() function is present"
if grep -q 'is_guardian_active()' "$HOOKS_DIR/guard.sh"; then
    pass_test
else
    fail_test "is_guardian_active() function not found in guard.sh"
fi

# --- Test 5: is_guardian_active() called at least 3 times (replaced 3 copy-paste blocks) ---
run_test "Helper: is_guardian_active() called 3+ times (deduplication)"
CALL_COUNT=$(grep -c 'is_guardian_active' "$HOOKS_DIR/guard.sh" || true)
# Count includes: 1 definition + 3 calls minimum
if [[ "$CALL_COUNT" -ge 4 ]]; then
    pass_test
else
    fail_test "is_guardian_active() found $CALL_COUNT times (need 4+: 1 def + 3 calls)"
fi

# --- Test 6: False positive — "fix branch -D handling" in commit message (#126 regression) ---
# This is the exact issue reported in #126. Check 4 was falsely denying this.
run_test "Issue #126: git commit -m 'fix branch -D handling' must NOT be denied by Check 4"

# We need a git repo on a non-main branch for the commit check to pass through
COMMIT_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-commitmsg-XXXXXX")
git -C "$COMMIT_REPO" init > /dev/null 2>&1
git -C "$COMMIT_REPO" checkout -b feature-test > /dev/null 2>&1
# Create a file so there's something to commit
echo "test" > "$COMMIT_REPO/file.txt"
git -C "$COMMIT_REPO" add file.txt > /dev/null 2>&1
git -C "$COMMIT_REPO" config user.email "test@test.com" > /dev/null 2>&1
git -C "$COMMIT_REPO" config user.name "Test" > /dev/null 2>&1

CMD="git -C $COMMIT_REPO commit -m \"fix branch -D handling\""
INPUT_JSON=$(make_input "$CMD")

OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

rm -rf "$COMMIT_REPO"

assert_allow "$OUTPUT" "commit msg with 'branch -D'"

# --- Test 7: False positive — "don't commit on main" in commit message (Check 2) ---
run_test "Issue #91: git commit -m 'don't commit on main' must NOT be denied by Check 2"

COMMIT_REPO2=$(mktemp -d "$PROJECT_ROOT/tmp/test-commitmsg2-XXXXXX")
git -C "$COMMIT_REPO2" init > /dev/null 2>&1
git -C "$COMMIT_REPO2" checkout -b feature-test2 > /dev/null 2>&1
echo "test2" > "$COMMIT_REPO2/file2.txt"
git -C "$COMMIT_REPO2" add file2.txt > /dev/null 2>&1
git -C "$COMMIT_REPO2" config user.email "test@test.com" > /dev/null 2>&1
git -C "$COMMIT_REPO2" config user.name "Test" > /dev/null 2>&1

CMD="git -C $COMMIT_REPO2 commit -m \"don't commit on main\""
INPUT_JSON=$(make_input "$CMD")

OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

rm -rf "$COMMIT_REPO2"

assert_allow "$OUTPUT" "commit msg with 'commit on main'"

# --- Test 8: False positive — "--force for deployment" in commit message (Check 3) ---
run_test "Issue #126: git commit -m 'use --force for deployment' must NOT be denied by Check 3"

COMMIT_REPO3=$(mktemp -d "$PROJECT_ROOT/tmp/test-commitmsg3-XXXXXX")
git -C "$COMMIT_REPO3" init > /dev/null 2>&1
git -C "$COMMIT_REPO3" checkout -b feature-test3 > /dev/null 2>&1
echo "test3" > "$COMMIT_REPO3/file3.txt"
git -C "$COMMIT_REPO3" add file3.txt > /dev/null 2>&1
git -C "$COMMIT_REPO3" config user.email "test@test.com" > /dev/null 2>&1
git -C "$COMMIT_REPO3" config user.name "Test" > /dev/null 2>&1

CMD="git -C $COMMIT_REPO3 commit -m \"use --force for deployment\""
INPUT_JSON=$(make_input "$CMD")

OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

rm -rf "$COMMIT_REPO3"

assert_allow "$OUTPUT" "commit msg with '--force'"

# --- Test 9: False positive — "clean -f the build" in commit message (Check 4) ---
run_test "Issue #126: git commit -m 'clean -f the build' must NOT be denied by Check 4"

COMMIT_REPO4=$(mktemp -d "$PROJECT_ROOT/tmp/test-commitmsg4-XXXXXX")
git -C "$COMMIT_REPO4" init > /dev/null 2>&1
git -C "$COMMIT_REPO4" checkout -b feature-test4 > /dev/null 2>&1
echo "test4" > "$COMMIT_REPO4/file4.txt"
git -C "$COMMIT_REPO4" add file4.txt > /dev/null 2>&1
git -C "$COMMIT_REPO4" config user.email "test@test.com" > /dev/null 2>&1
git -C "$COMMIT_REPO4" config user.name "Test" > /dev/null 2>&1

CMD="git -C $COMMIT_REPO4 commit -m \"clean -f the build\""
INPUT_JSON=$(make_input "$CMD")

OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

rm -rf "$COMMIT_REPO4"

assert_allow "$OUTPUT" "commit msg with 'clean -f'"

# --- Test 10: True positive — git branch -D on unmerged branch must still be denied ---
# When guardian IS active: guard.sh allows branch -D only if the branch is fully
# merged into HEAD. An unmerged branch is denied even for guardian callers.
# When guardian is NOT active: any -D is denied.
# Testing with an unmerged branch covers both cases reliably regardless of
# whether a guardian marker happens to be present in this environment.
run_test "Regression: git branch -D on unmerged branch still denied"

BRANCH_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-branchD-XXXXXX")
git -C "$BRANCH_REPO" init > /dev/null 2>&1
git -C "$BRANCH_REPO" config user.email "test@test.com" > /dev/null 2>&1
git -C "$BRANCH_REPO" config user.name "Test" > /dev/null 2>&1
echo "init" > "$BRANCH_REPO/init.txt"
git -C "$BRANCH_REPO" add init.txt > /dev/null 2>&1
git -C "$BRANCH_REPO" commit -m "init" > /dev/null 2>&1
# Create feature-branch with its own commit so it is NOT merged into main HEAD
git -C "$BRANCH_REPO" checkout -b feature-branch > /dev/null 2>&1
echo "unmerged" > "$BRANCH_REPO/unmerged.txt"
git -C "$BRANCH_REPO" add unmerged.txt > /dev/null 2>&1
git -C "$BRANCH_REPO" commit -m "unmerged commit" > /dev/null 2>&1
# Switch back to main so we can try to delete feature-branch
git -C "$BRANCH_REPO" checkout main > /dev/null 2>&1 || git -C "$BRANCH_REPO" checkout master > /dev/null 2>&1

CMD="git -C $BRANCH_REPO branch -D feature-branch"
INPUT_JSON=$(make_input "$CMD")

OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

rm -rf "$BRANCH_REPO"

assert_deny "$OUTPUT" "unmerged branch -D"

# --- Test 11: True positive — git push origin main --force still denied ---
run_test "Regression: git push origin main --force still denied"

CMD="git push origin main --force"
INPUT_JSON=$(make_input "$CMD")

OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

assert_deny "$OUTPUT" "force push to main"

# --- Test 12: True positive — git reset --hard HEAD~1 still denied ---
run_test "Regression: git reset --hard HEAD~1 still denied"

CMD="git reset --hard HEAD~1"
INPUT_JSON=$(make_input "$CMD")

OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

assert_deny "$OUTPUT" "git reset --hard"

# --- Test 13: True positive — git clean -f still denied (not in quotes) ---
run_test "Regression: git clean -f (not in quotes) still denied"

CMD="git clean -f"
INPUT_JSON=$(make_input "$CMD")

OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

assert_deny "$OUTPUT" "git clean -f"

# --- Summary ---
echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
