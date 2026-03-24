#!/usr/bin/env bash
# test-statusline-render.sh — scenario test for scripts/statusline.sh HUD rendering.
#
# Verifies that statusline.sh renders the correct HUD segments when the runtime
# snapshot is available (runtime path), and falls back gracefully to branch/dirty
# output when the runtime is unavailable (fallback path).
#
# Production sequence exercised (compound-interaction test):
#   1. Runtime DB provisioned with proof, agent marker, worktree, dispatch cycle
#   2. statusline.sh invoked with CLAUDE_POLICY_DB pointing to test DB
#   3. HUD output checked for expected key:value segments
#   4. Runtime made unavailable (bad CLAUDE_RUNTIME_ROOT path)
#   5. statusline.sh invoked again → fallback output contains branch: and dirty:
#
# @decision DEC-SL-001
# @title Runtime-backed statusline renderer
# @status accepted
# @rationale The statusline must be a read model over canonical runtime state,
#   not a second authority. All data comes from cc-policy statusline snapshot.
#   Flat-file fallback exists for graceful degradation only. This test exercises
#   the production path end-to-end: shell script → runtime-bridge.sh →
#   cc-policy CLI → SQLite snapshot → HUD line output, and validates the
#   fallback path when the runtime is not reachable.
set -euo pipefail

TEST_NAME="test-statusline-render"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/statusline.sh"
CLI="$REPO_ROOT/runtime/cli.py"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/state.db"
GIT_DIR="$TMP_DIR/project"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR" "$GIT_DIR"

# ---------------------------------------------------------------------------
# Helper: run cc-policy with the test DB
# ---------------------------------------------------------------------------
policy() {
    CLAUDE_POLICY_DB="$TEST_DB" PYTHONPATH="$REPO_ROOT" python3 "$CLI" "$@"
}

# ---------------------------------------------------------------------------
# Helper: run statusline.sh with runtime pointed at repo runtime dir and the
# test DB. Captures stdout only; stderr goes to /dev/null.
# ---------------------------------------------------------------------------
run_statusline() {
    CLAUDE_RUNTIME_ROOT="$REPO_ROOT/runtime" \
    CLAUDE_POLICY_DB="$TEST_DB" \
    CLAUDE_PROJECT_DIR="$GIT_DIR" \
        bash "$SCRIPT" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Helper: run statusline.sh with a broken runtime root so it falls back.
# Runs inside $GIT_DIR so git commands inside statusline.sh resolve against
# the test git repo, not the caller's working directory (which may be the
# worktree on a different branch).
# ---------------------------------------------------------------------------
run_statusline_fallback() {
    (
        cd "$GIT_DIR"
        CLAUDE_RUNTIME_ROOT="/nonexistent-path-$$" \
        CLAUDE_POLICY_DB="$TEST_DB" \
        CLAUDE_PROJECT_DIR="$GIT_DIR" \
            bash "$SCRIPT" 2>/dev/null
    )
}

# ---------------------------------------------------------------------------
# Check that the script exists and is executable
# ---------------------------------------------------------------------------
if [[ ! -f "$SCRIPT" ]]; then
    echo "FAIL: $TEST_NAME — scripts/statusline.sh not found"
    exit 1
fi

FAILURES=0

# ---------------------------------------------------------------------------
# Provision: set up a minimal git repo in TMP_DIR/project for fallback test
# ---------------------------------------------------------------------------
git -C "$GIT_DIR" init -q
git -C "$GIT_DIR" commit --allow-empty -m "init" -q

# ---------------------------------------------------------------------------
# Test 1: runtime path — empty DB returns proof:idle
# ---------------------------------------------------------------------------
echo "=== $TEST_NAME ==="
echo ""
echo "-- 1: empty DB — HUD includes proof:idle"

output=$(run_statusline)
if [[ "$output" == *"proof:idle"* ]]; then
    echo "  PASS: proof:idle present in empty-db HUD"
else
    echo "  FAIL: expected 'proof:idle' in output, got: $output"
    FAILURES=$((FAILURES + 1))
fi

# HUD must not contain "(no runtime)" when runtime is reachable
if [[ "$output" == *"(no runtime)"* ]]; then
    echo "  FAIL: HUD shows fallback marker when runtime should be available: $output"
    FAILURES=$((FAILURES + 1))
else
    echo "  PASS: no fallback marker when runtime is reachable"
fi

# ---------------------------------------------------------------------------
# Test 2: pending proof shows proof:pending
# ---------------------------------------------------------------------------
echo ""
echo "-- 2: pending proof — HUD shows proof:pending"

policy proof set "wf-sl-test" "pending" >/dev/null

output=$(run_statusline)
if [[ "$output" == *"proof:pending"* ]]; then
    echo "  PASS: proof:pending present"
else
    echo "  FAIL: expected 'proof:pending', got: $output"
    FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# Test 3: active agent shows agent:<role>
# ---------------------------------------------------------------------------
echo ""
echo "-- 3: active agent marker — HUD shows agent:<role>"

policy marker set "agent-sl-001" "tester" >/dev/null

output=$(run_statusline)
if [[ "$output" == *"agent:tester"* ]]; then
    echo "  PASS: agent:tester present"
else
    echo "  FAIL: expected 'agent:tester', got: $output"
    FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# Test 4: registered worktree shows wt:<count>
# ---------------------------------------------------------------------------
echo ""
echo "-- 4: worktree registered — HUD shows wt:<count>"

policy worktree register "/wt/sl-feature-a" "feature/sl-a" --ticket "TKT-012" >/dev/null

output=$(run_statusline)
if [[ "$output" == *"wt:1"* ]]; then
    echo "  PASS: wt:1 present"
else
    echo "  FAIL: expected 'wt:1', got: $output"
    FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# Test 5: dispatch cycle shows next:<role> and init:<initiative>
# ---------------------------------------------------------------------------
echo ""
echo "-- 5: dispatch cycle — HUD shows next:<role> and init:<initiative>"

policy dispatch cycle-start "TKT012-CYCLE" >/dev/null
policy dispatch enqueue "implementer" --ticket "TKT-012" >/dev/null

output=$(run_statusline)
if [[ "$output" == *"next:implementer"* ]]; then
    echo "  PASS: next:implementer present"
else
    echo "  FAIL: expected 'next:implementer', got: $output"
    FAILURES=$((FAILURES + 1))
fi

if [[ "$output" == *"init:TKT012-CYCLE"* ]]; then
    echo "  PASS: init:TKT012-CYCLE present"
else
    echo "  FAIL: expected 'init:TKT012-CYCLE', got: $output"
    FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# Test 6: compound — all segments appear together in a single-line HUD
# The full runtime state should yield: proof, agent, wt, next, init all in one line
# ---------------------------------------------------------------------------
echo ""
echo "-- 6: compound — all segments in one-line HUD"

output=$(run_statusline)
line_count=$(printf '%s' "$output" | wc -l | tr -d ' ')
if [[ "$line_count" -eq 0 || "$line_count" -eq 1 ]]; then
    echo "  PASS: HUD is a single line (line_count=$line_count)"
else
    echo "  FAIL: HUD spans multiple lines (got $line_count lines): $output"
    FAILURES=$((FAILURES + 1))
fi

# All five key segments must be present
for segment in "proof:" "agent:" "wt:" "next:" "init:"; do
    if [[ "$output" == *"$segment"* ]]; then
        echo "  PASS: segment '$segment' present in compound HUD"
    else
        echo "  FAIL: segment '$segment' missing from compound HUD, got: $output"
        FAILURES=$((FAILURES + 1))
    fi
done

# ---------------------------------------------------------------------------
# Test 7: fallback path — broken runtime root yields branch:<name> dirty:<n>
# ---------------------------------------------------------------------------
echo ""
echo "-- 7: fallback path — broken runtime yields branch/dirty output"

# Add a dirty file to the git repo so dirty count > 0
echo "dirty" > "$GIT_DIR/untracked.txt"

output=$(run_statusline_fallback)
if [[ "$output" == *"(no runtime)"* ]]; then
    echo "  PASS: fallback marker '(no runtime)' present"
else
    echo "  FAIL: expected '(no runtime)' in fallback output, got: $output"
    FAILURES=$((FAILURES + 1))
fi

if [[ "$output" == *"branch:"* ]]; then
    echo "  PASS: branch: segment present in fallback"
else
    echo "  FAIL: expected 'branch:' in fallback output, got: $output"
    FAILURES=$((FAILURES + 1))
fi

if [[ "$output" == *"dirty:"* ]]; then
    echo "  PASS: dirty: segment present in fallback"
else
    echo "  FAIL: expected 'dirty:' in fallback output, got: $output"
    FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# Test 8: fallback — branch name is the actual current branch, not "?"
# ---------------------------------------------------------------------------
echo ""
echo "-- 8: fallback branch name is accurate"

output=$(run_statusline_fallback)
# The git repo created in $GIT_DIR starts on default branch (main or master)
branch=$(git -C "$GIT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
if [[ "$output" == *"branch:$branch"* ]]; then
    echo "  PASS: fallback shows correct branch name ($branch)"
else
    echo "  FAIL: expected 'branch:$branch', got: $output"
    FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== $TEST_NAME results: $(( $(echo "  PASS:" | wc -l) )) ==="

if [[ "$FAILURES" -gt 0 ]]; then
    echo "FAIL: $TEST_NAME — $FAILURES check(s) failed"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
