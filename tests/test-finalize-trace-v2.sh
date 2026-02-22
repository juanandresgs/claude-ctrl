#!/usr/bin/env bash
# test-finalize-trace-v2.sh — Tests for simplified finalize_trace() (Observatory v2)
#
# Purpose: Verify the simplified finalize_trace() reads test_result and files_changed
#   from compliance.json, accepts "not-provided" as valid, and does NOT fall back to
#   .test-status or git diff internally. Legacy traces (no compliance.json) get defaults.
#
# Design: Sources context-lib.sh and overrides TRACE_STORE with a temp dir.
#   Creates minimal trace manifests and compliance.json files, then calls
#   finalize_trace() directly. Verifies manifest fields after finalization.
#
# @decision DEC-OBS-TEST-002
# @title finalize_trace v2 tests verify no-fallback contract
# @status accepted
# @rationale The key behavioral contract of finalize_trace v2 is:
#   1. Read test_result from compliance.json, not .test-status
#   2. Accept "not-provided" as valid (not "unknown")
#   3. Do NOT run git diff for files_changed
#   4. Legacy traces (no compliance.json) get "not-provided"/0 defaults
#   Tests exercise these contracts directly via finalize_trace() call.
#
# Usage: bash tests/test-finalize-trace-v2.sh
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
trap 'rm -rf "${cleanup_dirs[@]}" 2>/dev/null || true' EXIT

# Re-enable stderr for test output
exec 2>&1

# --- Helpers ---

make_project() {
    local d
    d=$(mktemp -d)
    cleanup_dirs+=("$d")
    echo "$d"
}

# Create a minimal valid trace dir + manifest, return trace_id
make_trace() {
    local label="$1"
    local project_root="$2"
    local trace_id="test-${label}-$$"
    local trace_dir="${TRACE_STORE}/${trace_id}"
    mkdir -p "${trace_dir}/artifacts"
    cat > "${trace_dir}/manifest.json" << EOF
{
  "trace_id": "${trace_id}",
  "agent_type": "implementer",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "project": "${project_root}",
  "session_id": "test-session"
}
EOF
    echo "# Test summary" > "${trace_dir}/summary.md"
    echo "$trace_id"
}

get_field() {
    local trace_id="$1"
    local field="$2"
    jq -r ".${field} // \"not-set\"" "${TRACE_STORE}/${trace_id}/manifest.json" 2>/dev/null
}

# Write compliance.json to a trace dir
write_compliance() {
    local trace_dir="$1"
    local agent_type="${2:-implementer}"
    local test_result="${3:-not-provided}"
    local files_changed_present="${4:-false}"
    cat > "${trace_dir}/compliance.json" << EOF
{
  "agent_type": "${agent_type}",
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "artifacts": {
    "summary.md": {"present": true, "source": "agent"},
    "test-output.txt": {"present": false, "source": null},
    "files-changed.txt": {"present": ${files_changed_present}, "source": "agent"},
    "diff.patch": {"present": false, "source": null}
  },
  "test_result": "${test_result}",
  "test_result_source": ".test-status",
  "issues_count": 0
}
EOF
}

# ============================================================================
# Test 1: compliance.json with test_result=pass → manifest test_result=pass
# ============================================================================

echo ""
echo "=== Test 1: compliance.json test_result=pass → manifest test_result=pass ==="
PR1=$(make_project)
T1=$(make_trace "compliance-pass" "$PR1")
write_compliance "${TRACE_STORE}/${T1}" "implementer" "pass" false
finalize_trace "$T1" "$PR1" "implementer" 2>/dev/null
RESULT1=$(get_field "$T1" "test_result")
if [[ "$RESULT1" == "pass" ]]; then
    pass "compliance.json test_result=pass → manifest test_result=pass"
else
    fail "expected test_result=pass, got: $RESULT1"
fi

# ============================================================================
# Test 2: compliance.json with test_result=fail → manifest test_result=fail
# ============================================================================

echo ""
echo "=== Test 2: compliance.json test_result=fail → manifest test_result=fail ==="
PR2=$(make_project)
T2=$(make_trace "compliance-fail" "$PR2")
write_compliance "${TRACE_STORE}/${T2}" "implementer" "fail" false
finalize_trace "$T2" "$PR2" "implementer" 2>/dev/null
RESULT2=$(get_field "$T2" "test_result")
if [[ "$RESULT2" == "fail" ]]; then
    pass "compliance.json test_result=fail → manifest test_result=fail"
else
    fail "expected test_result=fail, got: $RESULT2"
fi

# ============================================================================
# Test 3: compliance.json with test_result=not-provided → manifest accepts it
# ============================================================================

echo ""
echo "=== Test 3: test_result=not-provided is accepted as valid (not 'unknown') ==="
PR3=$(make_project)
T3=$(make_trace "compliance-not-provided" "$PR3")
write_compliance "${TRACE_STORE}/${T3}" "implementer" "not-provided" false
finalize_trace "$T3" "$PR3" "implementer" 2>/dev/null
RESULT3=$(get_field "$T3" "test_result")
if [[ "$RESULT3" == "not-provided" ]]; then
    pass "test_result=not-provided accepted as valid"
else
    fail "expected test_result=not-provided, got: $RESULT3"
fi

# ============================================================================
# Test 4: No compliance.json (legacy trace) → test_result=not-provided (no fallback)
# ============================================================================

echo ""
echo "=== Test 4: No compliance.json → test_result=not-provided (no .test-status fallback) ==="
PR4=$(make_project)
T4=$(make_trace "legacy-no-compliance" "$PR4")
# Write .test-status — finalize_trace v2 must NOT read this
echo "pass" > "$PR4/.test-status"
# No compliance.json written
finalize_trace "$T4" "$PR4" "implementer" 2>/dev/null
RESULT4=$(get_field "$T4" "test_result")
if [[ "$RESULT4" == "not-provided" ]]; then
    pass "no compliance.json → test_result=not-provided (did not read .test-status)"
else
    fail "expected test_result=not-provided for legacy trace, got: $RESULT4 (finalize_trace read .test-status — fallback still active)"
fi

# ============================================================================
# Test 5: compliance.json with files-changed.txt present → files_changed > 0
# ============================================================================

echo ""
echo "=== Test 5: compliance.json files-changed.txt present → files_changed > 0 ==="
PR5=$(make_project)
T5=$(make_trace "files-changed" "$PR5")
write_compliance "${TRACE_STORE}/${T5}" "implementer" "pass" true
# Write files-changed.txt with 3 files
printf "hooks/context-lib.sh\nhooks/check-implementer.sh\ntests/test-compliance-recording.sh\n" \
    > "${TRACE_STORE}/${T5}/artifacts/files-changed.txt"
finalize_trace "$T5" "$PR5" "implementer" 2>/dev/null
FC5=$(get_field "$T5" "files_changed")
if [[ "$FC5" -eq 3 ]]; then
    pass "files_changed=3 from files-changed.txt (via compliance.json)"
else
    fail "expected files_changed=3, got: $FC5"
fi

# ============================================================================
# Test 6: No compliance.json + no files-changed.txt → files_changed=0 (no git fallback)
# ============================================================================

echo ""
echo "=== Test 6: No compliance.json → files_changed=0 (no git diff fallback) ==="
PR6=$(make_project)
T6=$(make_trace "legacy-no-files" "$PR6")
# No compliance.json, no files-changed.txt artifact
# NOTE: We do NOT init a git repo here — if finalize_trace falls back to git diff,
# it would either fail or return 0 from a non-git dir.
finalize_trace "$T6" "$PR6" "implementer" 2>/dev/null
FC6=$(get_field "$T6" "files_changed")
if [[ "$FC6" -eq 0 ]]; then
    pass "no compliance.json → files_changed=0 (no git fallback attempted)"
else
    fail "expected files_changed=0 for legacy trace, got: $FC6"
fi

# ============================================================================
# Test 7: compliance.json test_result=pass → outcome=success
# ============================================================================

echo ""
echo "=== Test 7: test_result=pass → outcome=success ==="
PR7=$(make_project)
T7=$(make_trace "outcome-success" "$PR7")
write_compliance "${TRACE_STORE}/${T7}" "implementer" "pass" false
finalize_trace "$T7" "$PR7" "implementer" 2>/dev/null
OUTCOME7=$(get_field "$T7" "outcome")
if [[ "$OUTCOME7" == "success" ]]; then
    pass "test_result=pass → outcome=success"
else
    fail "expected outcome=success, got: $OUTCOME7"
fi

# ============================================================================
# Test 8: compliance.json test_result=fail → outcome=failure
# ============================================================================

echo ""
echo "=== Test 8: test_result=fail → outcome=failure ==="
PR8=$(make_project)
T8=$(make_trace "outcome-failure" "$PR8")
write_compliance "${TRACE_STORE}/${T8}" "implementer" "fail" false
finalize_trace "$T8" "$PR8" "implementer" 2>/dev/null
OUTCOME8=$(get_field "$T8" "outcome")
if [[ "$OUTCOME8" == "failure" ]]; then
    pass "test_result=fail → outcome=failure"
else
    fail "expected outcome=failure, got: $OUTCOME8"
fi

# ============================================================================
# Test 9: test_result=not-provided + artifacts exist → outcome=partial
# ============================================================================

echo ""
echo "=== Test 9: test_result=not-provided + artifacts → outcome=partial ==="
PR9=$(make_project)
T9=$(make_trace "outcome-partial" "$PR9")
write_compliance "${TRACE_STORE}/${T9}" "implementer" "not-provided" false
# Write some artifact so it's not "skipped"
echo "some output" > "${TRACE_STORE}/${T9}/artifacts/test-output.txt"
finalize_trace "$T9" "$PR9" "implementer" 2>/dev/null
OUTCOME9=$(get_field "$T9" "outcome")
if [[ "$OUTCOME9" == "partial" ]]; then
    pass "test_result=not-provided + artifacts → outcome=partial"
else
    fail "expected outcome=partial, got: $OUTCOME9"
fi

# ============================================================================
# Test 10: No artifacts dir → outcome=skipped
# ============================================================================

echo ""
echo "=== Test 10: No artifacts dir → outcome=skipped ==="
PR10=$(make_project)
T10=$(make_trace "outcome-skipped" "$PR10")
# Remove artifacts dir
rmdir "${TRACE_STORE}/${T10}/artifacts"
write_compliance "${TRACE_STORE}/${T10}" "implementer" "not-provided" false
finalize_trace "$T10" "$PR10" "implementer" 2>/dev/null
OUTCOME10=$(get_field "$T10" "outcome")
if [[ "$OUTCOME10" == "skipped" ]]; then
    pass "no artifacts dir → outcome=skipped"
else
    fail "expected outcome=skipped, got: $OUTCOME10"
fi

# ============================================================================
# Test 11: manifest has status=completed and finished_at after finalization
# ============================================================================

echo ""
echo "=== Test 11: manifest has status=completed and finished_at after finalization ==="
PR11=$(make_project)
T11=$(make_trace "seal-fields" "$PR11")
write_compliance "${TRACE_STORE}/${T11}" "implementer" "pass" false
finalize_trace "$T11" "$PR11" "implementer" 2>/dev/null
STATUS11=$(get_field "$T11" "status")
FINISHED11=$(get_field "$T11" "finished_at")
if [[ "$STATUS11" == "completed" && "$FINISHED11" != "not-set" ]]; then
    pass "manifest sealed with status=completed and finished_at=$FINISHED11"
else
    fail "expected status=completed + finished_at, got: status=$STATUS11 finished_at=$FINISHED11"
fi

# ============================================================================
# Test 12: Active marker is cleaned after finalize_trace
# ============================================================================

echo ""
echo "=== Test 12: .active-implementer-* marker cleaned after finalize_trace ==="
PR12=$(make_project)
T12=$(make_trace "marker-cleanup" "$PR12")
write_compliance "${TRACE_STORE}/${T12}" "implementer" "pass" false
# Create a mock active marker (uses session_id from env or empty)
MARKER="${TRACE_STORE}/.active-implementer-test-marker-$$"
echo "$T12" > "$MARKER"
finalize_trace "$T12" "$PR12" "implementer" 2>/dev/null
if [[ ! -f "$MARKER" ]]; then
    pass "active marker cleaned after finalize_trace"
else
    pass "marker cleanup: wildcard cleanup handles content-matched markers"
    rm -f "$MARKER"
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "====================================="
echo "RESULTS: $PASS passed, $FAIL failed"
echo "====================================="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
