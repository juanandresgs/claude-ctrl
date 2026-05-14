#!/usr/bin/env bash
# Test post-task.sh background-dispatch guard (DEC-POST-TASK-BG-DISPATCH-001).
#
# The bug: when a subagent is dispatched with run_in_background=true, PostToolUse:Task
# fires immediately (the tool returns an agentId) while the subagent keeps running.
# The fallback finalize block (lines 183-209) was calling finalize_trace on the just-
# created active trace — deleting the .active-<type>-<sid>-<phash> marker. The subagent
# then continues without a marker. pre-write.sh Gate 1.5 sees no marker and blocks
# source writes with "orchestrator context" error.
#
# Fix: detect tool_input.run_in_background == true and skip finalize_trace for bg
# dispatches. SubagentStop is the canonical finalize for background subagents.
#
# Validates:
#   1. Background dispatch (run_in_background=true): finalize_trace NOT called, marker survives
#   2. Foreground dispatch (run_in_background absent/false): existing fallback path still fires
#   3. post-task.sh has @decision DEC-POST-TASK-BG-DISPATCH-001 annotation
#   4. Smoke test: hook syntax still valid after fix
#
# @decision DEC-TEST-POST-TASK-BG-DISPATCH-001
# @title Test suite for background-dispatch finalization guard in post-task.sh
# @status accepted
# @rationale The bg-dispatch bug blocked every background-dispatched implementer from
#   writing source code. These tests verify the fix: bg dispatches skip finalize_trace
#   (marker survives for the subagent's full duration), while foreground dispatches
#   continue through the existing fallback path unchanged. Tests run against the actual
#   post-task.sh code — no mocks of internal functions — with a real TRACE_STORE
#   fixture matching the marker format used by subagent-start.sh. Issue: bg-dispatch bug.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"

# Ensure tmp directory exists
mkdir -p "$PROJECT_ROOT/tmp"

# Cleanup trap: collect temp dirs and remove on exit
_CLEANUP_DIRS=()
trap '[[ ${#_CLEANUP_DIRS[@]} -gt 0 ]] && rm -rf "${_CLEANUP_DIRS[@]}" 2>/dev/null; true' EXIT

# Track test results
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

# Helper: compute project_hash for a given path (same algorithm as source-lib.sh)
# Uses the actual hook source to guarantee consistency.
compute_phash() {
    local path="$1"
    bash -c "source '$HOOKS_DIR/source-lib.sh' && project_hash '$path'" 2>/dev/null || echo "testhash"
}

# Helper: set up a real fake trace environment with active marker.
# Uses the actual REAL_PROJECT_ROOT (what detect_project_root would return) so
# that post-task.sh's detect_project_root() → detect_active_trace() chain finds
# the marker. The manifest project field must match this root.
#
# Args: agent_type test_dir session_id
# Returns (stdout): trace_id
setup_bg_trace_env() {
    local agent_type="$1"
    local test_dir="$2"
    local session_id="$3"
    # post-task.sh calls detect_project_root() which returns the real ~/.claude root,
    # not the worktree. Use the real root for the project field in manifest.json so
    # detect_active_trace() can find the trace by project match.
    local real_root
    real_root=$(bash -c "source '$HOOKS_DIR/source-lib.sh' && detect_project_root 2>/dev/null" 2>/dev/null \
        || echo "$PROJECT_ROOT")

    export TRACE_STORE="$test_dir/traces"
    export CLAUDE_SESSION_ID="$session_id"
    mkdir -p "$TRACE_STORE"

    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local trace_id="${agent_type}-${timestamp}-bgtest"
    local trace_dir="${TRACE_STORE}/${trace_id}"
    mkdir -p "${trace_dir}/artifacts"

    cat > "${trace_dir}/manifest.json" <<MANIFEST
{
  "version": "1",
  "trace_id": "${trace_id}",
  "agent_type": "${agent_type}",
  "session_id": "${session_id}",
  "project": "${real_root}",
  "project_name": ".claude",
  "branch": "main",
  "start_commit": "",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "active"
}
MANIFEST

    # Write .active-<agent_type>-<session_id>-<phash> marker (project-scoped format)
    local phash
    phash=$(compute_phash "$real_root")
    echo "${trace_id}" > "${TRACE_STORE}/.active-${agent_type}-${session_id}-${phash}"

    echo "$trace_id"
}

# ---------------------------------------------------------------------------
# Test 1: Background dispatch (run_in_background=true) does NOT finalize trace
#
# The active marker must survive after post-task.sh runs, because the subagent
# is still running. finalize_trace deletes the marker — if we skip finalize,
# the marker file remains.
# ---------------------------------------------------------------------------
run_test "BG dispatch: active marker survives (finalize_trace skipped)"

TEST_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-ptbg-XXXXXX")
_CLEANUP_DIRS+=("$TEST_DIR")
SESSION_ID="test-bg-marker-$$"

TRACE_ID=$(setup_bg_trace_env "implementer" "$TEST_DIR" "$SESSION_ID")

# Compute the expected marker path
REAL_ROOT=$(bash -c "source '$HOOKS_DIR/source-lib.sh' && detect_project_root 2>/dev/null" 2>/dev/null || echo "$PROJECT_ROOT")
PHASH=$(compute_phash "$REAL_ROOT")
MARKER_PATH="${TEST_DIR}/traces/.active-implementer-${SESSION_ID}-${PHASH}"

# Verify marker exists before
if [[ ! -f "$MARKER_PATH" ]]; then
    fail_test "precondition: marker not created at $MARKER_PATH"
else
    # Run post-task.sh with run_in_background=true
    printf '{"tool_name":"Agent","tool_input":{"subagent_type":"implementer","run_in_background":true},"cwd":"%s"}' \
        "$REAL_ROOT" \
        | env TRACE_STORE="${TEST_DIR}/traces" \
              CLAUDE_SESSION_ID="$SESSION_ID" \
              CLAUDE_DIR="$TEST_DIR/.claude" \
          bash "$HOOKS_DIR/post-task.sh" >/dev/null 2>&1 || true

    # Marker must still exist after bg dispatch return
    if [[ -f "$MARKER_PATH" ]]; then
        pass_test
    else
        fail_test "marker was deleted for bg dispatch! Gate 1.5 would block source writes. Path: $MARKER_PATH"
    fi
fi

# ---------------------------------------------------------------------------
# Test 2: Foreground dispatch (run_in_background absent) DOES go through fallback
#
# For a foreground dispatch, the existing fallback path should still detect the
# active trace and write a diagnostic summary.md (just as before the fix).
# ---------------------------------------------------------------------------
run_test "FG dispatch: fallback path still fires (summary.md written)"

TEST_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-ptbg-XXXXXX")
_CLEANUP_DIRS+=("$TEST_DIR")
SESSION_ID="test-fg-fallback-$$"

TRACE_ID=$(setup_bg_trace_env "guardian" "$TEST_DIR" "$SESSION_ID")
TRACE_DIR_FG="${TEST_DIR}/traces/${TRACE_ID}"

REAL_ROOT=$(bash -c "source '$HOOKS_DIR/source-lib.sh' && detect_project_root 2>/dev/null" 2>/dev/null || echo "$PROJECT_ROOT")

printf '{"tool_name":"Agent","tool_input":{"subagent_type":"guardian"},"cwd":"%s"}' \
    "$REAL_ROOT" \
    | env TRACE_STORE="${TEST_DIR}/traces" \
          CLAUDE_SESSION_ID="$SESSION_ID" \
          CLAUDE_DIR="$TEST_DIR/.claude" \
      bash "$HOOKS_DIR/post-task.sh" >/dev/null 2>&1 || true

if [[ -f "${TRACE_DIR_FG}/summary.md" ]]; then
    if grep -q "Guardian Summary\|Agent Summary" "${TRACE_DIR_FG}/summary.md" 2>/dev/null; then
        pass_test
    else
        fail_test "summary.md written but unexpected content: $(head -2 "${TRACE_DIR_FG}/summary.md")"
    fi
else
    fail_test "fallback did not write summary.md for foreground guardian dispatch at ${TRACE_DIR_FG}/summary.md"
fi

# ---------------------------------------------------------------------------
# Test 3: Foreground dispatch with run_in_background=false behaves same as absent
# ---------------------------------------------------------------------------
run_test "FG dispatch: run_in_background=false also goes through fallback"

TEST_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-ptbg-XXXXXX")
_CLEANUP_DIRS+=("$TEST_DIR")
SESSION_ID="test-fg-false-$$"

TRACE_ID=$(setup_bg_trace_env "planner" "$TEST_DIR" "$SESSION_ID")
TRACE_DIR_FALSE="${TEST_DIR}/traces/${TRACE_ID}"

REAL_ROOT=$(bash -c "source '$HOOKS_DIR/source-lib.sh' && detect_project_root 2>/dev/null" 2>/dev/null || echo "$PROJECT_ROOT")

printf '{"tool_name":"Agent","tool_input":{"subagent_type":"planner","run_in_background":false},"cwd":"%s"}' \
    "$REAL_ROOT" \
    | env TRACE_STORE="${TEST_DIR}/traces" \
          CLAUDE_SESSION_ID="$SESSION_ID" \
          CLAUDE_DIR="$TEST_DIR/.claude" \
      bash "$HOOKS_DIR/post-task.sh" >/dev/null 2>&1 || true

if [[ -f "${TRACE_DIR_FALSE}/summary.md" ]]; then
    if grep -q "Planner Summary\|Agent Summary" "${TRACE_DIR_FALSE}/summary.md" 2>/dev/null; then
        pass_test
    else
        fail_test "summary.md written but unexpected content: $(head -2 "${TRACE_DIR_FALSE}/summary.md")"
    fi
else
    fail_test "fallback did not write summary.md for fg planner (run_in_background=false) at ${TRACE_DIR_FALSE}/summary.md"
fi

# ---------------------------------------------------------------------------
# Test 4: BG dispatch does NOT write summary.md (the subagent will do that)
#
# The subagent is still running — writing a diagnostic summary now would be
# premature and could be overwritten when the real summary arrives.
# ---------------------------------------------------------------------------
run_test "BG dispatch: diagnostic summary NOT written (subagent still running)"

TEST_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-ptbg-XXXXXX")
_CLEANUP_DIRS+=("$TEST_DIR")
SESSION_ID="test-bg-nosummary-$$"

TRACE_ID=$(setup_bg_trace_env "implementer" "$TEST_DIR" "$SESSION_ID")
TRACE_DIR_BG="${TEST_DIR}/traces/${TRACE_ID}"

REAL_ROOT=$(bash -c "source '$HOOKS_DIR/source-lib.sh' && detect_project_root 2>/dev/null" 2>/dev/null || echo "$PROJECT_ROOT")

printf '{"tool_name":"Task","tool_input":{"subagent_type":"implementer","run_in_background":true},"cwd":"%s"}' \
    "$REAL_ROOT" \
    | env TRACE_STORE="${TEST_DIR}/traces" \
          CLAUDE_SESSION_ID="$SESSION_ID" \
          CLAUDE_DIR="$TEST_DIR/.claude" \
      bash "$HOOKS_DIR/post-task.sh" >/dev/null 2>&1 || true

# No summary.md should exist — the subagent will write it when it completes
if [[ ! -f "${TRACE_DIR_BG}/summary.md" ]]; then
    pass_test
else
    fail_test "diagnostic summary was written for bg dispatch (premature — subagent still running)"
fi

# ---------------------------------------------------------------------------
# Test 5: Static check — @decision annotation exists in post-task.sh
# ---------------------------------------------------------------------------
run_test "post-task.sh has @decision DEC-POST-TASK-BG-DISPATCH-001 annotation"
if grep -q 'DEC-POST-TASK-BG-DISPATCH-001' "$HOOKS_DIR/post-task.sh" 2>/dev/null; then
    pass_test
else
    fail_test "@decision DEC-POST-TASK-BG-DISPATCH-001 not found in post-task.sh"
fi

# ---------------------------------------------------------------------------
# Test 6: Static check — post-task.sh checks tool_input.run_in_background
# ---------------------------------------------------------------------------
run_test "post-task.sh reads tool_input.run_in_background to detect bg dispatch"
if grep -q 'run_in_background' "$HOOKS_DIR/post-task.sh" 2>/dev/null; then
    pass_test
else
    fail_test "post-task.sh does not check tool_input.run_in_background"
fi

# ---------------------------------------------------------------------------
# Test 7: Syntax check
# ---------------------------------------------------------------------------
run_test "post-task.sh: valid bash syntax after fix"
if bash -n "$HOOKS_DIR/post-task.sh" 2>/dev/null; then
    pass_test
else
    fail_test "post-task.sh has syntax errors after fix"
fi

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_RUN total"
echo ""

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi

exit 0
