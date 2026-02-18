#!/usr/bin/env bash
# test-finalize-trace-teststatus.sh — Unit tests for finalize_trace() .test-status fallback
#
# Purpose: Verify that finalize_trace() falls back to reading .test-status when
#          test-output.txt is absent, and that test-output.txt takes priority when both exist.
#
# @decision DEC-OBS-SUG002
# @title Test .test-status fallback in finalize_trace()
# @status accepted
# @rationale Most agents write .test-status to the project root instead of
#             test-output.txt in the trace artifacts dir. Without a fallback,
#             97.8% of traces show unknown test_result. These tests verify the
#             fallback logic works correctly without mocking internal functions.
#             We exercise finalize_trace() directly via sourcing context-lib.sh.
#
# Usage: bash tests/test-finalize-trace-teststatus.sh
# Returns: 0 if all tests pass, 1 if any fail

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_LIB="${WORKTREE_ROOT}/hooks/log.sh"
CONTEXT_LIB="${WORKTREE_ROOT}/hooks/context-lib.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Suppress hook log output during tests
exec 2>/dev/null

# Source log.sh first (provides get_claude_dir, detect_project_root)
# shellcheck source=/dev/null
source "$LOG_LIB"

# Source context-lib (sets TRACE_STORE=$HOME/.claude/traces unconditionally)
# shellcheck source=/dev/null
source "$CONTEXT_LIB"

# Override TRACE_STORE with a temp dir AFTER sourcing so finalize_trace() uses it
TRACE_STORE=$(mktemp -d)
export TRACE_STORE
cleanup_dirs=("$TRACE_STORE")
trap 'rm -rf "${cleanup_dirs[@]}"' EXIT

# Re-enable stderr for test output
exec 2>&1

# --- Helpers ---

# Create a minimal valid trace dir + manifest, returns trace_id
make_trace() {
    local label="$1"
    local project_root="$2"
    local trace_id="test-${label}-$$"
    local trace_dir="${TRACE_STORE}/${trace_id}"
    mkdir -p "${trace_dir}/artifacts"
    # Minimal manifest with started_at so duration calculation works
    cat > "${trace_dir}/manifest.json" << EOF
{
  "trace_id": "${trace_id}",
  "agent_type": "implementer",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "project_root": "${project_root}",
  "session_id": "test-session"
}
EOF
    # Write summary.md so it doesn't look like a crash
    echo "# Test summary" > "${trace_dir}/summary.md"
    echo "$trace_id"
}

get_test_result() {
    local trace_id="$1"
    local manifest="${TRACE_STORE}/${trace_id}/manifest.json"
    jq -r '.test_result // "not-set"' "$manifest" 2>/dev/null
}

make_project() {
    local d
    d=$(mktemp -d)
    cleanup_dirs+=("$d")
    echo "$d"
}

# --- Test 1: No test-output.txt and no .test-status → test_result stays unknown ---
echo ""
echo "=== Test 1: No artifacts → test_result=unknown ==="
PR1=$(make_project)
TRACE1=$(make_trace "no-artifacts" "$PR1")
finalize_trace "$TRACE1" "$PR1" "implementer" 2>/dev/null
RESULT1=$(get_test_result "$TRACE1")
if [[ "$RESULT1" == "unknown" ]]; then
    pass "No artifacts → test_result=unknown"
else
    fail "No artifacts → expected unknown, got: $RESULT1"
fi

# --- Test 2: .test-status=pass in project root → test_result=pass ---
echo ""
echo "=== Test 2: project_root/.test-status=pass → test_result=pass ==="
PR2=$(make_project)
echo "pass" > "${PR2}/.test-status"
TRACE2=$(make_trace "root-pass" "$PR2")
finalize_trace "$TRACE2" "$PR2" "implementer" 2>/dev/null
RESULT2=$(get_test_result "$TRACE2")
if [[ "$RESULT2" == "pass" ]]; then
    pass "project_root/.test-status=pass → test_result=pass"
else
    fail "project_root/.test-status=pass → expected pass, got: $RESULT2"
fi

# --- Test 3: .test-status=fail in project root → test_result=fail ---
echo ""
echo "=== Test 3: project_root/.test-status=fail → test_result=fail ==="
PR3=$(make_project)
echo "fail" > "${PR3}/.test-status"
TRACE3=$(make_trace "root-fail" "$PR3")
finalize_trace "$TRACE3" "$PR3" "implementer" 2>/dev/null
RESULT3=$(get_test_result "$TRACE3")
if [[ "$RESULT3" == "fail" ]]; then
    pass "project_root/.test-status=fail → test_result=fail"
else
    fail "project_root/.test-status=fail → expected fail, got: $RESULT3"
fi

# --- Test 4: .claude/.test-status=pass → test_result=pass ---
echo ""
echo "=== Test 4: project_root/.claude/.test-status=pass → test_result=pass ==="
PR4=$(make_project)
mkdir -p "${PR4}/.claude"
echo "pass" > "${PR4}/.claude/.test-status"
TRACE4=$(make_trace "claude-pass" "$PR4")
finalize_trace "$TRACE4" "$PR4" "implementer" 2>/dev/null
RESULT4=$(get_test_result "$TRACE4")
if [[ "$RESULT4" == "pass" ]]; then
    pass "project_root/.claude/.test-status=pass → test_result=pass"
else
    fail "project_root/.claude/.test-status=pass → expected pass, got: $RESULT4"
fi

# --- Test 5: .test-status=passed (alternate spelling) → test_result=pass ---
echo ""
echo "=== Test 5: .test-status=passed (alternate spelling) → test_result=pass ==="
PR5=$(make_project)
printf "passed\n" > "${PR5}/.test-status"
TRACE5=$(make_trace "passed-spelling" "$PR5")
finalize_trace "$TRACE5" "$PR5" "implementer" 2>/dev/null
RESULT5=$(get_test_result "$TRACE5")
if [[ "$RESULT5" == "pass" ]]; then
    pass ".test-status=passed → test_result=pass"
else
    fail ".test-status=passed → expected pass, got: $RESULT5"
fi

# --- Test 6: test-output.txt takes priority over .test-status ---
echo ""
echo "=== Test 6: test-output.txt takes priority over .test-status ==="
# .test-status says fail, but test-output.txt says pass — should use test-output.txt
PR6=$(make_project)
echo "fail" > "${PR6}/.test-status"
TRACE6=$(make_trace "priority" "$PR6")
echo "All tests passed successfully" > "${TRACE_STORE}/${TRACE6}/artifacts/test-output.txt"
finalize_trace "$TRACE6" "$PR6" "implementer" 2>/dev/null
RESULT6=$(get_test_result "$TRACE6")
if [[ "$RESULT6" == "pass" ]]; then
    pass "test-output.txt=pass takes priority over .test-status=fail"
else
    fail "Priority check: expected pass (from test-output.txt), got: $RESULT6"
fi

# --- Test 7: project_root/.test-status takes priority over .claude/.test-status ---
echo ""
echo "=== Test 7: project_root/.test-status takes priority over .claude/.test-status ==="
PR7=$(make_project)
mkdir -p "${PR7}/.claude"
echo "pass" > "${PR7}/.test-status"
echo "fail" > "${PR7}/.claude/.test-status"
TRACE7=$(make_trace "root-priority" "$PR7")
finalize_trace "$TRACE7" "$PR7" "implementer" 2>/dev/null
RESULT7=$(get_test_result "$TRACE7")
if [[ "$RESULT7" == "pass" ]]; then
    pass "project_root/.test-status takes priority over .claude/.test-status"
else
    fail "project_root priority: expected pass, got: $RESULT7"
fi

# --- Summary ---
echo ""
echo "====================================="
echo "RESULTS: $PASS passed, $FAIL failed"
echo "====================================="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
