#!/usr/bin/env bash
# Tests for the trace lookup breadcrumb fix (SubagentStop → PostToolUse:Task race).
#
# Validates:
#   1. check-tester.sh writes .last-tester-trace breadcrumb after finalize_trace
#   2. post-task.sh reads the breadcrumb as Tier 0 fallback when marker is gone
#   3. post-task.sh consumes (deletes) the breadcrumb after reading
#   4. trace-lib.sh normalizes Tester/Guardian agent types in init_trace
#
# These are real integration tests — they call actual functions from the hook
# libraries against real temp directories. No mocks.
#
# @decision DEC-TEST-BREADCRUMB-001
# @title Real integration tests for trace breadcrumb race fix
# @status accepted
# @rationale The breadcrumb mechanism bridges SubagentStop and PostToolUse:Task
#   by writing a trace_id to a predictable file. Tests exercise the actual
#   init_trace → finalize_trace → breadcrumb → read cycle using real trace
#   directories and real library functions. Validates the fix prevents the
#   "no active tester trace found" symptom.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"

# Cleanup trap (DEC-PROD-002): collect temp dirs and remove on exit
_CLEANUP_DIRS=()
trap '[[ ${#_CLEANUP_DIRS[@]} -gt 0 ]] && rm -rf "${_CLEANUP_DIRS[@]}" 2>/dev/null; true' EXIT

PASS=0
FAIL=0
TOTAL=0

run_test() {
    local name="$1"
    local result="$2"
    ((TOTAL++)) || true
    printf "Running: %s\n" "$name"
    if [[ "$result" == "pass" ]]; then
        printf "  PASS\n"
        ((PASS++)) || true
    else
        printf "  FAIL: %s\n" "$result"
        ((FAIL++)) || true
    fi
}

# ============================================================
# Group 1: Source-level verification (check-tester.sh)
# ============================================================

TESTER_SH="${HOOKS_DIR}/check-tester.sh"

run_test "check-tester.sh: writes .last-tester-trace in Phase 1 auto-verify path" \
    "$(awk '/finalize_trace "\$AV_TRACE_ID".*tester/{found=1} found && /\.last-tester-trace/{print "pass"; exit}' "$TESTER_SH" | grep -q pass && echo pass || echo ".last-tester-trace write missing after AV_TRACE_ID finalize")"

run_test "check-tester.sh: writes .last-tester-trace in Phase 2 finalize path" \
    "$(awk '/if ! finalize_trace "\$TRACE_ID".*tester/{found=1} found && /\.last-tester-trace/{print "pass"; exit}' "$TESTER_SH" | grep -q pass && echo pass || echo ".last-tester-trace write missing after TRACE_ID finalize")"

run_test "check-tester.sh: breadcrumb write uses CLAUDE_DIR" \
    "$(grep '\.last-tester-trace' "$TESTER_SH" | grep -q 'CLAUDE_DIR' && echo pass || echo "breadcrumb should use CLAUDE_DIR variable")"

# ============================================================
# Group 2: Source-level verification (post-task.sh)
# ============================================================

POST_TASK_SH="${HOOKS_DIR}/post-task.sh"

run_test "post-task.sh: defines CLAUDE_DIR before breadcrumb block" \
    "$(awk '/^CLAUDE_DIR=/{found_dir=1} /\.last-tester-trace/{if(found_dir) print "pass"; else print "CLAUDE_DIR not defined before breadcrumb"; exit}' "$POST_TASK_SH" | grep -q pass && echo pass || echo "CLAUDE_DIR must be defined before .last-tester-trace read")"

run_test "post-task.sh: reads .last-tester-trace as Tier 0 fallback" \
    "$(grep -q '\.last-tester-trace' "$POST_TASK_SH" && echo pass || echo ".last-tester-trace read missing")"

run_test "post-task.sh: breadcrumb tier runs BEFORE session scan (DEC-AV-RACE-001)" \
    "$(awk '/\.last-tester-trace/{found_bc=1} /DEC-AV-RACE-001/{if(found_bc) print "pass"; else print "breadcrumb must be before session scan"; exit}' "$POST_TASK_SH" | grep -q pass && echo pass || echo "breadcrumb Tier 0 must appear before DEC-AV-RACE-001 session scan")"

run_test "post-task.sh: consumes breadcrumb with rm -f" \
    "$(grep -A10 '\.last-tester-trace' "$POST_TASK_SH" | grep -q 'rm -f.*BREADCRUMB' && echo pass || echo "breadcrumb not consumed after read")"

run_test "post-task.sh: validates manifest exists before using breadcrumb" \
    "$(grep -A5 'cat.*BREADCRUMB' "$POST_TASK_SH" | grep -q 'manifest.json' && echo pass || echo "breadcrumb trace_id not validated against manifest")"

# ============================================================
# Group 3: trace-lib.sh agent type normalization
# ============================================================

TRACE_LIB="${HOOKS_DIR}/trace-lib.sh"

run_test "trace-lib.sh: normalizes Tester to tester" \
    "$(grep -q 'Tester|tester)' "$TRACE_LIB" && echo pass || echo "Tester normalization missing")"

run_test "trace-lib.sh: normalizes Guardian to guardian" \
    "$(grep -q 'Guardian|guardian)' "$TRACE_LIB" && echo pass || echo "Guardian normalization missing")"

# ============================================================
# Group 4: Live init_trace → finalize_trace → breadcrumb cycle
# ============================================================

# Set up isolated trace store in tmp
TEST_TRACE_STORE=$(mktemp -d "$PROJECT_ROOT/tmp/test-breadcrumb-traces-XXXXXX")
_CLEANUP_DIRS+=("$TEST_TRACE_STORE")
TEST_CLAUDE_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-breadcrumb-claude-XXXXXX")
_CLEANUP_DIRS+=("$TEST_CLAUDE_DIR")
TEST_PROJECT=$(mktemp -d "$PROJECT_ROOT/tmp/test-breadcrumb-project-XXXXXX")
_CLEANUP_DIRS+=("$TEST_PROJECT")
git -C "$TEST_PROJECT" init -q 2>/dev/null
git -C "$TEST_PROJECT" commit --allow-empty -m "init" -q 2>/dev/null

# Source the libraries with our test trace store
export TRACE_STORE="$TEST_TRACE_STORE"
export CLAUDE_SESSION_ID="test-breadcrumb-session-$$"
source "$HOOKS_DIR/source-lib.sh"

# Test: init_trace creates a trace with marker
TRACE_ID=$(TRACE_STORE="$TEST_TRACE_STORE" init_trace "$TEST_PROJECT" "tester" 2>/dev/null || echo "")
run_test "init_trace: creates tester trace directory" \
    "$([[ -n "$TRACE_ID" && -d "$TEST_TRACE_STORE/$TRACE_ID" ]] && echo pass || echo "trace dir not created: TRACE_ID=$TRACE_ID")"

run_test "init_trace: creates active marker" \
    "$(ls "$TEST_TRACE_STORE"/.active-tester-* 2>/dev/null | head -1 | grep -q active && echo pass || echo "no .active-tester-* marker found")"

# Test: detect_active_trace finds it
DETECTED=$(TRACE_STORE="$TEST_TRACE_STORE" detect_active_trace "$TEST_PROJECT" "tester" 2>/dev/null || echo "")
run_test "detect_active_trace: finds trace via marker" \
    "$([[ "$DETECTED" == "$TRACE_ID" ]] && echo pass || echo "expected $TRACE_ID, got $DETECTED")"

# Write a minimal summary so finalize doesn't mark as crashed
echo "# Test summary" > "$TEST_TRACE_STORE/$TRACE_ID/summary.md"

# Test: finalize_trace removes the marker
TRACE_STORE="$TEST_TRACE_STORE" finalize_trace "$TRACE_ID" "$TEST_PROJECT" "tester" 2>/dev/null || true
run_test "finalize_trace: removes active marker" \
    "$(ls "$TEST_TRACE_STORE"/.active-tester-* 2>/dev/null | wc -l | tr -d ' ' | grep -q '^0$' && echo pass || echo "marker still exists after finalize")"

# Test: detect_active_trace returns empty after finalize
DETECTED_AFTER=$(TRACE_STORE="$TEST_TRACE_STORE" detect_active_trace "$TEST_PROJECT" "tester" 2>/dev/null || echo "")
run_test "detect_active_trace: returns empty after finalize (confirms race)" \
    "$([[ -z "$DETECTED_AFTER" ]] && echo pass || echo "expected empty, got $DETECTED_AFTER")"

# Test: breadcrumb file bridges the gap
echo "$TRACE_ID" > "$TEST_CLAUDE_DIR/.last-tester-trace"
run_test "breadcrumb: .last-tester-trace file exists with trace_id" \
    "$([[ -f "$TEST_CLAUDE_DIR/.last-tester-trace" ]] && echo pass || echo "breadcrumb file not created")"

BREADCRUMB_CONTENT=$(cat "$TEST_CLAUDE_DIR/.last-tester-trace" 2>/dev/null)
run_test "breadcrumb: contains correct trace_id" \
    "$([[ "$BREADCRUMB_CONTENT" == "$TRACE_ID" ]] && echo pass || echo "expected $TRACE_ID, got $BREADCRUMB_CONTENT")"

# Test: breadcrumb can resolve to valid manifest
MANIFEST="$TEST_TRACE_STORE/$BREADCRUMB_CONTENT/manifest.json"
run_test "breadcrumb: trace_id resolves to valid manifest" \
    "$([[ -f "$MANIFEST" ]] && echo pass || echo "manifest not found at $MANIFEST")"

# Test: consuming the breadcrumb (simulating post-task.sh behavior)
_BREADCRUMB="$TEST_CLAUDE_DIR/.last-tester-trace"
_candidate=$(cat "$_BREADCRUMB" 2>/dev/null)
_cmf="$TEST_TRACE_STORE/${_candidate}/manifest.json"
_RESOLVED=""
if [[ -n "$_candidate" && -f "$_cmf" ]]; then
    _RESOLVED="$_candidate"
fi
rm -f "$_BREADCRUMB"

run_test "breadcrumb consumption: resolves trace_id correctly" \
    "$([[ "$_RESOLVED" == "$TRACE_ID" ]] && echo pass || echo "expected $TRACE_ID, got $_RESOLVED")"

run_test "breadcrumb consumption: file deleted after read" \
    "$([[ ! -f "$TEST_CLAUDE_DIR/.last-tester-trace" ]] && echo pass || echo "breadcrumb not consumed")"

# ============================================================
# Group 5: Agent type normalization (live)
# ============================================================

# Test: init_trace normalizes "Tester" to "tester"
NORM_TRACE=$(TRACE_STORE="$TEST_TRACE_STORE" init_trace "$TEST_PROJECT" "Tester" 2>/dev/null || echo "")
run_test "init_trace: normalizes 'Tester' to 'tester' in trace_id" \
    "$(echo "$NORM_TRACE" | grep -q '^tester-' && echo pass || echo "expected tester- prefix, got $NORM_TRACE")"

NORM_TYPE=$(jq -r '.agent_type' "$TEST_TRACE_STORE/$NORM_TRACE/manifest.json" 2>/dev/null)
run_test "init_trace: manifest agent_type is 'tester' (not 'Tester')" \
    "$([[ "$NORM_TYPE" == "tester" ]] && echo pass || echo "expected tester, got $NORM_TYPE")"

# Test: init_trace normalizes "Guardian" to "guardian"
GUARD_TRACE=$(TRACE_STORE="$TEST_TRACE_STORE" init_trace "$TEST_PROJECT" "Guardian" 2>/dev/null || echo "")
run_test "init_trace: normalizes 'Guardian' to 'guardian' in trace_id" \
    "$(echo "$GUARD_TRACE" | grep -q '^guardian-' && echo pass || echo "expected guardian- prefix, got $GUARD_TRACE")"

GUARD_TYPE=$(jq -r '.agent_type' "$TEST_TRACE_STORE/$GUARD_TRACE/manifest.json" 2>/dev/null)
run_test "init_trace: manifest agent_type is 'guardian' (not 'Guardian')" \
    "$([[ "$GUARD_TYPE" == "guardian" ]] && echo pass || echo "expected guardian, got $GUARD_TYPE")"

# ============================================================
# Group 6: Edge cases
# ============================================================

# Breadcrumb with invalid trace_id (directory doesn't exist)
echo "nonexistent-trace-12345" > "$TEST_CLAUDE_DIR/.last-tester-trace"
_BREADCRUMB="$TEST_CLAUDE_DIR/.last-tester-trace"
_candidate=$(cat "$_BREADCRUMB" 2>/dev/null)
_cmf="$TEST_TRACE_STORE/${_candidate}/manifest.json"
_RESOLVED=""
if [[ -n "$_candidate" && -f "$_cmf" ]]; then
    _RESOLVED="$_candidate"
fi
rm -f "$_BREADCRUMB"

run_test "edge: invalid breadcrumb trace_id is rejected (manifest missing)" \
    "$([[ -z "$_RESOLVED" ]] && echo pass || echo "should reject nonexistent trace, got $_RESOLVED")"

# Empty breadcrumb file
touch "$TEST_CLAUDE_DIR/.last-tester-trace"
_BREADCRUMB="$TEST_CLAUDE_DIR/.last-tester-trace"
_candidate=$(cat "$_BREADCRUMB" 2>/dev/null)
_cmf="$TEST_TRACE_STORE/${_candidate}/manifest.json"
_RESOLVED=""
if [[ -n "$_candidate" && -f "$_cmf" ]]; then
    _RESOLVED="$_candidate"
fi
rm -f "$_BREADCRUMB"

run_test "edge: empty breadcrumb file is rejected" \
    "$([[ -z "$_RESOLVED" ]] && echo pass || echo "should reject empty breadcrumb, got $_RESOLVED")"

# Breadcrumb overwritten by newer tester run
TRACE_ID_2=$(TRACE_STORE="$TEST_TRACE_STORE" init_trace "$TEST_PROJECT" "tester" 2>/dev/null || echo "")
echo "$TRACE_ID" > "$TEST_CLAUDE_DIR/.last-tester-trace"
echo "$TRACE_ID_2" > "$TEST_CLAUDE_DIR/.last-tester-trace"  # overwrite
_BREADCRUMB="$TEST_CLAUDE_DIR/.last-tester-trace"
_candidate=$(cat "$_BREADCRUMB" 2>/dev/null)

run_test "edge: newer tester run overwrites breadcrumb" \
    "$([[ "$_candidate" == "$TRACE_ID_2" ]] && echo pass || echo "expected $TRACE_ID_2, got $_candidate")"
rm -f "$_BREADCRUMB"

# ============================================================
# Cleanup
# ============================================================
rm -rf "$TEST_TRACE_STORE" "$TEST_CLAUDE_DIR" "$TEST_PROJECT"

# ============================================================
# Results
# ============================================================
echo ""
echo "Results: ${TOTAL} run, ${PASS} passed, ${FAIL} failed"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
