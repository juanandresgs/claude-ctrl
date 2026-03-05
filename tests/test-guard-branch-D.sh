#!/usr/bin/env bash
# Test suite: guard.sh Check 4 — git branch -D Guardian merge-verification gate.
#
# @decision DEC-GUARD-BRANCH-D-001
# @title Test suite for Check 4 conditional -D with Guardian merge verification
# @status accepted
# @rationale Validates that: (1) git branch -D is hard-denied when no Guardian
#   is active (unchanged behavior), (2) git branch -D is allowed when Guardian
#   is active AND the branch is fully merged into HEAD, (3) git branch -D is
#   denied even for an active Guardian when the branch has unmerged commits,
#   (4) git branch -d (lowercase) behavior is unchanged — still requires Guardian
#   but does not require merge verification since git enforces it natively.
#   Uses the same run_test/pass_test/fail_test pattern as test-integrity-layer.sh.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"
TRACE_STORE="${TRACE_STORE:-$HOME/.claude/traces}"

mkdir -p "$PROJECT_ROOT/tmp"

# Cleanup trap (DEC-PROD-002): collect temp dirs and remove on exit
_CLEANUP_DIRS=()
trap '[[ ${#_CLEANUP_DIRS[@]} -gt 0 ]] && rm -rf "${_CLEANUP_DIRS[@]}" 2>/dev/null; true' EXIT

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

# Helper: build hook input JSON for a command
make_input() {
    local cmd="$1"
    jq -n --arg cmd "$cmd" '{"tool_name":"Bash","tool_input":{"command":$cmd}}'
}

# Helper: run guard.sh in a given repo directory (without cd-ing into it)
run_guard() {
    local repo_dir="$1"
    local input_json="$2"
    echo "$input_json" | (cd "$repo_dir" && bash "$HOOKS_DIR/pre-bash.sh" 2>&1) || true
}

# ============================================================
# Syntax check
# ============================================================

run_test "Syntax: guard.sh is valid bash after the change"
if bash -n "$HOOKS_DIR/pre-bash.sh"; then
    pass_test
else
    fail_test "guard.sh has syntax errors"
fi

# ============================================================
# Test 1: git branch -D denied when no Guardian active
# ============================================================

run_test "Check 4: git branch -D denied with no Guardian active"

REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-branch-D-no-guardian-XXXXXX")
_CLEANUP_DIRS+=("$REPO")
git -C "$REPO" init -q
git -C "$REPO" commit --allow-empty -m "root" -q

# Ensure no active guardian markers for this test (clean TRACE_STORE for test isolation)
# We point TRACE_STORE at a temp dir with no .active-guardian-* files
FAKE_TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-branch-D-trace-XXXXXX")
_CLEANUP_DIRS+=("$FAKE_TRACE")

OUTPUT=$(TRACE_STORE="$FAKE_TRACE" run_guard "$REPO" "$(make_input 'git branch -D some-branch')")

rm -rf "$REPO" "$FAKE_TRACE"

if echo "$OUTPUT" | grep -q '"permissionDecision": "deny"'; then
    pass_test
else
    fail_test "Expected deny when no Guardian active. Got: $OUTPUT"
fi

# ============================================================
# Test 2: git branch -D allowed when Guardian active AND branch is merged
# ============================================================

run_test "Check 4: git branch -D allowed when Guardian active and branch is merged"

REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-branch-D-merged-XXXXXX")
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@test.com"
git -C "$REPO" config user.name "Test"

# Create a commit on main/default branch
git -C "$REPO" commit --allow-empty -m "root" -q

# Create a feature branch, make a commit, then merge it back into HEAD
git -C "$REPO" checkout -b feature/test-merged -q
git -C "$REPO" commit --allow-empty -m "feature commit" -q
git -C "$REPO" checkout - -q
git -C "$REPO" merge --no-ff feature/test-merged -m "merge feature" -q

# Create a fake Guardian active marker
FAKE_TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-branch-D-trace-XXXXXX")
touch "$FAKE_TRACE/.active-guardian-test-session-123"

OUTPUT=$(TRACE_STORE="$FAKE_TRACE" run_guard "$REPO" "$(make_input "git -C $REPO branch -D feature/test-merged")")

rm -rf "$REPO" "$FAKE_TRACE"

if ! echo "$OUTPUT" | grep -q '"permissionDecision": "deny"'; then
    pass_test
else
    fail_test "Expected allow when Guardian active and branch merged. Got: $OUTPUT"
fi

# ============================================================
# Test 3: git branch -D denied when Guardian active BUT branch is NOT merged
# ============================================================

run_test "Check 4: git branch -D denied when Guardian active but branch NOT merged"

REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-branch-D-unmerged-XXXXXX")
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@test.com"
git -C "$REPO" config user.name "Test"

# Create a commit on main
git -C "$REPO" commit --allow-empty -m "root" -q

# Create a feature branch with an unmerged commit
git -C "$REPO" checkout -b feature/unmerged-work -q
git -C "$REPO" commit --allow-empty -m "unmerged feature commit" -q
git -C "$REPO" checkout - -q
# Do NOT merge — leave feature/unmerged-work with commits not in HEAD

# Create a fake Guardian active marker
FAKE_TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-branch-D-trace-XXXXXX")
touch "$FAKE_TRACE/.active-guardian-test-session-456"

OUTPUT=$(TRACE_STORE="$FAKE_TRACE" run_guard "$REPO" "$(make_input "git -C $REPO branch -D feature/unmerged-work")")

rm -rf "$REPO" "$FAKE_TRACE"

if echo "$OUTPUT" | grep -q '"permissionDecision": "deny"' && \
   echo "$OUTPUT" | grep -qi "unmerged\|unmerged commits"; then
    pass_test
else
    fail_test "Expected deny with unmerged message when Guardian active but branch not merged. Got: $OUTPUT"
fi

# ============================================================
# Test 4: git branch -d (lowercase) still requires Guardian (unchanged)
# ============================================================

run_test "Check 4b: git branch -d still requires Guardian (behavior unchanged)"

REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-branch-d-requires-guardian-XXXXXX")
git -C "$REPO" init -q

FAKE_TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-branch-D-trace-XXXXXX")
# No guardian markers — empty FAKE_TRACE

OUTPUT=$(TRACE_STORE="$FAKE_TRACE" run_guard "$REPO" "$(make_input 'git branch -d some-branch')")

rm -rf "$REPO" "$FAKE_TRACE"

if echo "$OUTPUT" | grep -q '"permissionDecision": "deny"' && \
   echo "$OUTPUT" | grep -qi "Guardian\|guardian"; then
    pass_test
else
    fail_test "Expected Guardian-required deny for git branch -d without guardian. Got: $OUTPUT"
fi

# ============================================================
# Test 5: git branch -D with --delete --force still denied without Guardian
# ============================================================

run_test "Check 4: git branch --delete --force denied without Guardian active"

REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-branch-D-delete-force-XXXXXX")
git -C "$REPO" init -q

FAKE_TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-branch-D-trace-XXXXXX")

OUTPUT=$(TRACE_STORE="$FAKE_TRACE" run_guard "$REPO" "$(make_input 'git branch --delete --force some-branch')")

rm -rf "$REPO" "$FAKE_TRACE"

if echo "$OUTPUT" | grep -q '"permissionDecision": "deny"'; then
    pass_test
else
    fail_test "Expected deny for git branch --delete --force without Guardian. Got: $OUTPUT"
fi

# ============================================================
# Test 6: git branch -d with Guardian active — allowed through (git itself enforces merge)
# ============================================================

run_test "Check 4b: git branch -d with Guardian active — not denied by guard.sh"

REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-branch-d-guardian-XXXXXX")
git -C "$REPO" init -q

FAKE_TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-branch-D-trace-XXXXXX")
touch "$FAKE_TRACE/.active-guardian-test-session-789"

OUTPUT=$(TRACE_STORE="$FAKE_TRACE" run_guard "$REPO" "$(make_input 'git branch -d some-branch')")

rm -rf "$REPO" "$FAKE_TRACE"

# Should NOT be denied by guard.sh (git will handle the actual merge check)
if ! echo "$OUTPUT" | grep -q '"permissionDecision": "deny"'; then
    pass_test
else
    fail_test "git branch -d with Guardian active was denied by guard.sh. Got: $OUTPUT"
fi

# ============================================================
# Summary
# ============================================================

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
