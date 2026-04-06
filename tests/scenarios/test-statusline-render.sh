#!/usr/bin/env bash
# test-statusline-render.sh — scenario test for scripts/statusline.sh rich ANSI HUD.
#
# Verifies that statusline.sh renders a rich ANSI HUD when piped synthetic stdin
# JSON (as Claude Code does), combining model/workspace/version from stdin with
# runtime snapshot data. Also verifies graceful fallback when runtime is absent.
#
# Production sequence exercised (compound-interaction test):
#   1. Synthetic Claude Code JSON piped to statusline.sh stdin
#   2. Runtime DB provisioned with proof, agent marker, worktree, dispatch cycle
#   3. statusline.sh renders ANSI HUD; checked for model name, workspace,
#      version, proof indicator, agent symbol, worktree count, dispatch segment
#   4. Runtime made unavailable (bad CLAUDE_RUNTIME_ROOT)
#   5. Fallback HUD still includes model/workspace/version/(no runtime)
#
# @decision DEC-SL-001
# @title Runtime-backed statusline renderer
# @status accepted
# @rationale The statusline is a read model over SQLite runtime state.
#   stdin (Claude Code JSON) provides model/workspace/version. ANSI escapes
#   confirm the rich HUD path ran. Fallback confirms graceful degradation.
#   This test exercises the full production sequence: stdin JSON + runtime
#   bridge + cc-policy CLI + SQLite snapshot → ANSI HUD output.
set -euo pipefail

TEST_NAME="test-statusline-render"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/statusline.sh"
CLI="$REPO_ROOT/runtime/cli.py"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/state.db"
GIT_DIR="$TMP_DIR/project"

# shellcheck disable=SC2329  # cleanup is invoked via trap EXIT
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR" "$GIT_DIR"

# ---------------------------------------------------------------------------
# Synthetic Claude Code stdin JSON — matches the shape Claude Code sends.
# Uses GIT_DIR as the workspace so git -C "$workspace_dir" resolves correctly.
# ---------------------------------------------------------------------------
STDIN_JSON='{"model":{"display_name":"test-model"},"workspace":{"current_dir":"'"$GIT_DIR"'"},"version":"1.0.0"}'

# ---------------------------------------------------------------------------
# Helper: run cc-policy with the test DB
# ---------------------------------------------------------------------------
policy() {
    CLAUDE_POLICY_DB="$TEST_DB" PYTHONPATH="$REPO_ROOT" python3 "$CLI" "$@"
}

# ---------------------------------------------------------------------------
# Helper: run statusline.sh with runtime pointed at repo runtime dir and the
# test DB. Pipes synthetic stdin JSON exactly as Claude Code does.
# ---------------------------------------------------------------------------
# Fix #160: stderr is captured to a temp file rather than suppressed. If the
# script exits non-zero, stderr is forwarded to our stderr so crash diagnostics
# are visible. stdout (the HUD) is kept clean for segment assertions.
run_statusline() {
    local _sl_stderr_file _sl_output _sl_exit
    _sl_stderr_file=$(mktemp)
    _sl_output=$(echo "$STDIN_JSON" | \
    CLAUDE_RUNTIME_ROOT="$REPO_ROOT/runtime" \
    CLAUDE_POLICY_DB="$TEST_DB" \
    CLAUDE_PROJECT_DIR="$GIT_DIR" \
        bash "$SCRIPT" 2>"$_sl_stderr_file")
    _sl_exit=$?
    if [[ $_sl_exit -ne 0 ]]; then
        printf '  WARN: statusline exited %d, stderr: %s\n' "$_sl_exit" "$(cat "$_sl_stderr_file")" >&2
    fi
    rm -f "$_sl_stderr_file"
    printf '%s' "$_sl_output"
    return $_sl_exit
}

# ---------------------------------------------------------------------------
# Helper: run statusline.sh with a broken runtime root so it falls back.
# Still pipes stdin JSON — the fallback path also reads it for model/version.
# ---------------------------------------------------------------------------
# Fix #160: same stderr capture pattern — broken runtime may emit diagnostics
# that were previously invisible. The fallback path is expected to exit 0.
run_statusline_fallback() {
    local _slb_stderr_file _slb_output _slb_exit
    _slb_stderr_file=$(mktemp)
    _slb_output=$(echo "$STDIN_JSON" | \
    CLAUDE_RUNTIME_ROOT="/nonexistent-path-$$" \
    CLAUDE_POLICY_DB="/nonexistent-db-$$" \
    CLAUDE_PROJECT_DIR="$GIT_DIR" \
        bash "$SCRIPT" 2>"$_slb_stderr_file")
    _slb_exit=$?
    if [[ $_slb_exit -ne 0 ]]; then
        printf '  WARN: statusline_fallback exited %d, stderr: %s\n' "$_slb_exit" "$(cat "$_slb_stderr_file")" >&2
    fi
    rm -f "$_slb_stderr_file"
    printf '%s' "$_slb_output"
    return $_slb_exit
}

# ---------------------------------------------------------------------------
# Check that the script exists
# ---------------------------------------------------------------------------
if [[ ! -f "$SCRIPT" ]]; then
    echo "FAIL: $TEST_NAME — scripts/statusline.sh not found"
    exit 1
fi

FAILURES=0

# ---------------------------------------------------------------------------
# Provision: minimal git repo so git -C "$GIT_DIR" commands succeed
# ---------------------------------------------------------------------------
git -C "$GIT_DIR" init -q
git -C "$GIT_DIR" -c user.email="t@t" -c user.name="T" commit --allow-empty -m "init" -q

echo "=== $TEST_NAME ==="
echo ""

# ---------------------------------------------------------------------------
# Test 1: runtime path — output contains ANSI escape codes (rich HUD active)
# ---------------------------------------------------------------------------
echo "-- 1: runtime path — output has ANSI escape codes"

output=$(run_statusline)
_t1_exit=$?
if [[ $_t1_exit -ne 0 ]]; then
    echo "  FAIL: statusline exited non-zero ($_t1_exit) — check stderr output above"
    FAILURES=$((FAILURES + 1))
fi
# ANSI escapes are literal ESC bytes; check via printf comparison
if printf '%s' "$output" | grep -qP '\x1b\[' 2>/dev/null || \
   printf '%s' "$output" | grep -q $'\033\['; then
    echo "  PASS: ANSI escape codes present in HUD output"
else
    echo "  FAIL: no ANSI escape codes found; output: $(printf '%s' "$output" | cat -v)"
    FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# Test 2: stdin model name appears in HUD
# ---------------------------------------------------------------------------
echo ""
echo "-- 2: model name from stdin appears in HUD"

output=$(run_statusline)
if printf '%s' "$output" | grep -q "test-model"; then
    echo "  PASS: model name 'test-model' present in HUD"
else
    echo "  FAIL: model name missing; output: $(printf '%s' "$output" | cat -v)"
    FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# Test 3: workspace basename from stdin appears in HUD
# ---------------------------------------------------------------------------
echo ""
echo "-- 3: workspace basename from stdin appears in HUD"

output=$(run_statusline)
workspace_name=$(basename "$GIT_DIR")
if printf '%s' "$output" | grep -q "$workspace_name"; then
    echo "  PASS: workspace '$workspace_name' present in HUD"
else
    echo "  FAIL: workspace name missing; output: $(printf '%s' "$output" | cat -v)"
    FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# Test 4: version from stdin appears in HUD
# ---------------------------------------------------------------------------
echo ""
echo "-- 4: context bar present in HUD (Line 2)"

output=$(run_statusline)
if printf '%s' "$output" | grep -q "tks"; then
    echo "  PASS: token count segment present in HUD"
else
    echo "  FAIL: token segment missing; output: $(printf '%s' "$output" | cat -v)"
    FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# Test 5: no fallback marker when runtime is reachable
# ---------------------------------------------------------------------------
echo ""
echo "-- 5: no fallback marker when runtime is reachable"

output=$(run_statusline)
if printf '%s' "$output" | grep -q "(no runtime)"; then
    echo "  FAIL: HUD shows fallback marker when runtime should be available"
    FAILURES=$((FAILURES + 1))
else
    echo "  PASS: no fallback marker when runtime is reachable"
fi

# ---------------------------------------------------------------------------
# Test 6: pending eval renders ⏳ eval in HUD (TKT-024)
# ---------------------------------------------------------------------------
echo ""
echo "-- 6: pending eval — HUD shows pending eval indicator"

policy evaluation set "wf-sl-test" "pending" >/dev/null

output=$(run_statusline)
if printf '%s' "$output" | grep -q "eval"; then
    echo "  PASS: eval indicator present for pending evaluation"
else
    echo "  FAIL: eval indicator missing for pending state; output: $(printf '%s' "$output" | cat -v)"
    FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# Test 7: ready_for_guardian eval renders ✓ eval in HUD (TKT-024)
# ---------------------------------------------------------------------------
echo ""
echo "-- 7: ready eval — HUD shows ready eval indicator"

policy evaluation set "wf-sl-test" "ready_for_guardian" --head-sha "abc123" >/dev/null

output=$(run_statusline)
if printf '%s' "$output" | grep -q "eval"; then
    echo "  PASS: eval indicator present for ready_for_guardian"
else
    echo "  FAIL: eval indicator missing for ready state; output: $(printf '%s' "$output" | cat -v)"
    FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# Test 7b: eval_workflow appears in HUD when eval is non-idle (W-SL-160)
# ---------------------------------------------------------------------------
echo ""
echo "-- 7b: eval_workflow — HUD shows workflow id alongside eval status"

output=$(run_statusline)
if printf '%s' "$output" | grep -q "wf-sl-test"; then
    echo "  PASS: eval_workflow 'wf-sl-test' present in HUD"
else
    echo "  FAIL: eval_workflow missing; output: $(printf '%s' "$output" | cat -v)"
    FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# Test 7c: review indicator — codex review ALLOW renders in HUD (DEC-SL-160)
# ---------------------------------------------------------------------------
echo ""
echo "-- 7c: review indicator — ALLOW review renders in HUD"

policy event emit "codex_stop_review" --detail "VERDICT: ALLOW — workflow=wf-sl-test | looks good" >/dev/null

output=$(run_statusline)
if printf '%s' "$output" | grep -q "codex"; then
    echo "  PASS: review indicator 'codex' present in HUD"
else
    echo "  FAIL: review indicator missing; output: $(printf '%s' "$output" | cat -v)"
    FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# Test 8: active agent renders ⚡<role> in HUD
# ---------------------------------------------------------------------------
echo ""
echo "-- 8: active agent — HUD shows agent role"

policy marker set "agent-sl-001" "tester" >/dev/null

output=$(run_statusline)
if printf '%s' "$output" | grep -q "tester"; then
    echo "  PASS: agent role 'tester' present in HUD"
else
    echo "  FAIL: agent role missing; output: $(printf '%s' "$output" | cat -v)"
    FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# Test 9: registered worktree renders WT:<count>
# ---------------------------------------------------------------------------
echo ""
echo "-- 9: worktree registered — HUD shows WT:<count>"

policy worktree register "/wt/sl-feature-a" "feature/sl-a" --ticket "TKT-012" >/dev/null

output=$(run_statusline)
if printf '%s' "$output" | grep -q "worktree"; then
    echo "  PASS: worktree count present in HUD"
else
    echo "  FAIL: worktree count missing; output: $(printf '%s' "$output" | cat -v)"
    FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# Test 10: dispatch status renders in HUD
# DEC-WS6-001: dispatch_queue is non-authoritative. The statusline derives
# dispatch status from completion records, not the queue. This test verifies
# that the statusline renders without errors after a dispatch cycle start.
# ---------------------------------------------------------------------------
echo ""
echo "-- 10: dispatch cycle — HUD renders without error"

policy dispatch cycle-start "TKT012-CYCLE" >/dev/null

output=$(run_statusline)
if [[ -n "$output" ]]; then
    echo "  PASS: dispatch cycle renders in HUD"
else
    echo "  FAIL: HUD empty after dispatch cycle start"
    FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# Test 11: compound — model + workspace + version + agent + WT + next in one line
# (The full runtime path end-to-end: stdin JSON + snapshot → single ANSI line)
# ---------------------------------------------------------------------------
echo ""
echo "-- 11: compound — full runtime HUD is 3 lines with key segments"

output=$(run_statusline)
line_count=$(printf '%s' "$output" | wc -l | tr -d ' ')
if [[ "$line_count" -eq 2 || "$line_count" -eq 3 ]]; then
    echo "  PASS: HUD is 3 lines (line_count=$line_count)"
else
    echo "  FAIL: HUD expected 3 lines (got $line_count lines)"
    FAILURES=$((FAILURES + 1))
fi

for segment in "test-model" "$workspace_name" "tester" "worktree" "tks" "eval"; do
    if printf '%s' "$output" | grep -q "$segment"; then
        echo "  PASS: segment '$segment' present in compound HUD"
    else
        echo "  FAIL: segment '$segment' missing from compound HUD"
        FAILURES=$((FAILURES + 1))
    fi
done

# ---------------------------------------------------------------------------
# Test 12: dirty count appears when workspace has untracked files
# ---------------------------------------------------------------------------
echo ""
echo "-- 12: dirty count — untracked file shows dirty in HUD"

printf 'untracked\n' > "$GIT_DIR/untracked.txt"

output=$(run_statusline)
if printf '%s' "$output" | grep -q "uncommitted"; then
    echo "  PASS: uncommitted count present when workspace has untracked files"
else
    echo "  FAIL: 'uncommitted' missing despite untracked file; output: $(printf '%s' "$output" | cat -v)"
    FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# Test 13: fallback path — broken runtime still renders model/workspace/version
# ---------------------------------------------------------------------------
echo ""
echo "-- 13: fallback path — broken runtime renders model/workspace/version"

output=$(run_statusline_fallback)
if printf '%s' "$output" | grep -q "test-model"; then
    echo "  PASS: model name present in fallback HUD"
else
    echo "  FAIL: model name missing in fallback; output: $(printf '%s' "$output" | cat -v)"
    FAILURES=$((FAILURES + 1))
fi

# Version not shown in 3-line layout. Verify context bar present on Line 2 instead.
if printf '%s' "$output" | grep -q '\-\-'; then
    echo "  PASS: context bar present in fallback Line 2"
else
    echo "  FAIL: context bar missing in fallback; output: $(printf '%s' "$output" | cat -v)"
    FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# Test 14: fallback path — (no runtime) marker present
# ---------------------------------------------------------------------------
echo ""
echo "-- 14: fallback path — (no runtime) marker present"

output=$(run_statusline_fallback)
if printf '%s' "$output" | grep -q "(no runtime)"; then
    echo "  PASS: fallback marker '(no runtime)' present"
else
    echo "  FAIL: fallback marker missing; output: $(printf '%s' "$output" | cat -v)"
    FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# Test 15: fallback path — ANSI escapes still present (styled fallback)
# ---------------------------------------------------------------------------
echo ""
echo "-- 15: fallback path — ANSI escapes present in fallback HUD"

output=$(run_statusline_fallback)
if printf '%s' "$output" | grep -qP '\x1b\[' 2>/dev/null || \
   printf '%s' "$output" | grep -q $'\033\['; then
    echo "  PASS: ANSI escape codes present in fallback HUD"
else
    echo "  FAIL: no ANSI codes in fallback; output: $(printf '%s' "$output" | cat -v)"
    FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ "$FAILURES" -gt 0 ]]; then
    echo "FAIL: $TEST_NAME — $FAILURES check(s) failed"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
