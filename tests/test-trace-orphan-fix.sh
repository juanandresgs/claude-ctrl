#!/usr/bin/env bash
# Tests for trace orphan finalization fixes.
# Validates: check-explore.sh calls finalize_trace, check-general-purpose.sh
# exists and calls finalize_trace, refinalize_trace repairs orphaned "active"
# status, and settings.json has general-purpose matcher registered.
#
# Issue #123: Updated to verify that empty-detection (no trace initialized)
# does NOT log trace_orphan in check-explore.sh (removed — Explore agents never
# have traces per subagent-start.sh line 39), and logs trace_skip (not
# trace_orphan) in check-general-purpose.sh and check-tester.sh (informational,
# not indicative of a real orphan). Also verifies check-tester.sh Phase 1
# auto-verify path finalizes the active trace before exiting.
#
# @decision DEC-TEST-ORPHAN-001
# @title Test suite for trace orphan finalization fixes
# @status accepted
# @rationale Three bugs caused permanently orphaned traces: missing finalize_trace
#   in check-explore.sh, no SubagentStop handler for general-purpose agents, and
#   refinalize_trace being unable to repair active status. These tests verify all
#   three fixes and the timeout-ordering change in check-implementer/planner.
#   Issue #123 adds four more assertions: explore empty-detection no longer emits
#   trace_orphan, general-purpose and tester empty-detection emit trace_skip, and
#   tester Phase 1 auto-verify path calls finalize_trace before exiting.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(dirname "$SCRIPT_DIR")/hooks"
SETTINGS_FILE="$(dirname "$SCRIPT_DIR")/settings.json"

PASS=0
FAIL=0

run_test() {
    local name="$1"
    local result="$2"
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
# Group 1: check-explore.sh contains finalize_trace
# ============================================================

EXPLORE_SH="${HOOKS_DIR}/check-explore.sh"

run_test "check-explore.sh: exists" \
    "$([[ -f "$EXPLORE_SH" ]] && echo pass || echo "file not found")"

run_test "check-explore.sh: calls finalize_trace" \
    "$( grep -q 'finalize_trace' "$EXPLORE_SH" 2>/dev/null && echo pass || echo "finalize_trace call missing")"

run_test "check-explore.sh: calls detect_active_trace for explore" \
    "$(grep -q 'detect_active_trace.*explore' "$EXPLORE_SH" 2>/dev/null && echo pass || echo "detect_active_trace for explore missing")"

# Issue #123 Fix 1: Explore agents NEVER have traces (subagent-start.sh skips
# trace init for Bash|Explore). No trace_orphan should be logged on empty
# detect_active_trace — that is normal behavior, not an orphan.
run_test "check-explore.sh: does NOT log trace_orphan on empty TRACE_ID (Fix #123)" \
    "$(grep -q 'trace_orphan.*detect_active_trace returned empty for explore' "$EXPLORE_SH" 2>/dev/null \
        && echo "FAIL: trace_orphan still logged for empty explore TRACE_ID" \
        || echo pass)"

run_test "check-explore.sh: logs finalize_trace failure to audit" \
    "$(grep -q 'trace_orphan.*finalize_trace failed for explore' "$EXPLORE_SH" 2>/dev/null && echo pass || echo "audit log for finalize_trace failure missing")"

run_test "check-explore.sh: finalize runs before overflow detection (ordering)" \
    "$(awk '/finalize_trace|TRACE_ID.*detect_active_trace/{found_fin=1} /WORD_COUNT.*-gt.*1200/{if(found_fin) print "pass"; else print "overflow before finalize"; exit}' "$EXPLORE_SH" 2>/dev/null | grep -q pass && echo pass || echo "finalize not before overflow check")"

run_test "check-explore.sh: has DEC-EXPLORE-STOP-002 annotation" \
    "$(grep -q 'DEC-EXPLORE-STOP-002' "$EXPLORE_SH" 2>/dev/null && echo pass || echo "DEC-EXPLORE-STOP-002 annotation missing")"

# ============================================================
# Group 2: check-general-purpose.sh exists and is correct
# ============================================================

GP_SH="${HOOKS_DIR}/check-general-purpose.sh"

run_test "check-general-purpose.sh: exists" \
    "$([[ -f "$GP_SH" ]] && echo pass || echo "file not found")"

run_test "check-general-purpose.sh: is executable" \
    "$([[ -x "$GP_SH" ]] && echo pass || echo "not executable")"

run_test "check-general-purpose.sh: has documentation header" \
    "$(head -3 "$GP_SH" 2>/dev/null | grep -q '^#' && echo pass || echo "documentation header missing")"

run_test "check-general-purpose.sh: sources source-lib.sh" \
    "$(grep -q 'source.*source-lib.sh' "$GP_SH" 2>/dev/null && echo pass || echo "source-lib.sh not sourced")"

run_test "check-general-purpose.sh: calls track_subagent_stop" \
    "$(grep -q 'track_subagent_stop' "$GP_SH" 2>/dev/null && echo pass || echo "track_subagent_stop missing")"

run_test "check-general-purpose.sh: calls append_session_event" \
    "$(grep -q 'append_session_event' "$GP_SH" 2>/dev/null && echo pass || echo "append_session_event missing")"

run_test "check-general-purpose.sh: calls finalize_trace" \
    "$(grep -q 'finalize_trace' "$GP_SH" 2>/dev/null && echo pass || echo "finalize_trace call missing")"

run_test "check-general-purpose.sh: calls detect_active_trace for general-purpose" \
    "$(grep -q 'detect_active_trace.*general-purpose' "$GP_SH" 2>/dev/null && echo pass || echo "detect_active_trace for general-purpose missing")"

# Issue #123 Fix 2: general-purpose agents DO get trace init (fall-through to *
# in subagent-start.sh), but init_trace can fail silently. Empty detection is
# informational — use trace_skip, not trace_orphan.
run_test "check-general-purpose.sh: logs trace_skip (not trace_orphan) on empty TRACE_ID (Fix #123)" \
    "$(grep -q 'trace_skip.*detect_active_trace returned empty for general-purpose' "$GP_SH" 2>/dev/null && echo pass || echo "trace_skip log for empty TRACE_ID missing")"

run_test "check-general-purpose.sh: does NOT log trace_orphan on empty TRACE_ID (Fix #123)" \
    "$(grep -q 'trace_orphan.*detect_active_trace returned empty for general-purpose' "$GP_SH" 2>/dev/null \
        && echo "FAIL: trace_orphan still logged for empty general-purpose TRACE_ID" \
        || echo pass)"

run_test "check-general-purpose.sh: valid bash syntax" \
    "$(bash -n "$GP_SH" 2>/dev/null && echo pass || echo "syntax error")"

run_test "check-general-purpose.sh: has DEC-GENERAL-STOP-001 annotation" \
    "$(grep -q 'DEC-GENERAL-STOP-001' "$GP_SH" 2>/dev/null && echo pass || echo "DEC-GENERAL-STOP-001 annotation missing")"

# ============================================================
# Group 3: settings.json has general-purpose matcher
# ============================================================

run_test "settings.json: general-purpose matcher registered" \
    "$(jq -e '.hooks.SubagentStop[]? | select(.matcher == "general-purpose")' "$SETTINGS_FILE" 2>/dev/null | grep -q 'matcher' && echo pass || echo "general-purpose matcher not found in SubagentStop")"

run_test "settings.json: general-purpose handler points to check-general-purpose.sh" \
    "$(jq -r '.hooks.SubagentStop[]? | select(.matcher == "general-purpose") | .hooks[0].command' "$SETTINGS_FILE" 2>/dev/null | grep -q 'check-general-purpose.sh' && echo pass || echo "wrong command for general-purpose handler")"

run_test "settings.json: general-purpose handler has timeout" \
    "$(jq -e '.hooks.SubagentStop[]? | select(.matcher == "general-purpose") | .hooks[0].timeout' "$SETTINGS_FILE" 2>/dev/null | grep -qE '^[0-9]+$' && echo pass || echo "no timeout set for general-purpose handler")"

run_test "settings.json: valid JSON after edit" \
    "$(jq '.' "$SETTINGS_FILE" >/dev/null 2>&1 && echo pass || echo "settings.json is invalid JSON")"

# ============================================================
# Group 4: check-implementer.sh — finalize runs before git checks
# ============================================================

IMPL_SH="${HOOKS_DIR}/check-implementer.sh"

run_test "check-implementer.sh: finalize_trace error logged to audit" \
    "$(grep -q 'trace_orphan.*finalize_trace failed for implementer' "$IMPL_SH" 2>/dev/null && echo pass || echo "audit log for finalize failure missing")"

run_test "check-implementer.sh: finalize runs before get_git_state" \
    "$(awk '/finalize_trace/{found_fin=1} /get_git_state/{if(found_fin) print "pass"; else print "get_git_state before finalize"; exit}' "$IMPL_SH" 2>/dev/null | grep -q pass && echo pass || echo "finalize not before get_git_state")"

run_test "check-implementer.sh: finalize runs before get_plan_status" \
    "$(awk '/finalize_trace/{found_fin=1} /get_plan_status/{if(found_fin) print "pass"; else print "get_plan_status before finalize"; exit}' "$IMPL_SH" 2>/dev/null | grep -q pass && echo pass || echo "finalize not before get_plan_status")"

run_test "check-implementer.sh: has DEC-IMPL-STOP-002 annotation" \
    "$(grep -q 'DEC-IMPL-STOP-002' "$IMPL_SH" 2>/dev/null && echo pass || echo "DEC-IMPL-STOP-002 annotation missing")"

# ============================================================
# Group 5: check-planner.sh — finalize runs before git checks
# ============================================================

PLANNER_SH="${HOOKS_DIR}/check-planner.sh"

run_test "check-planner.sh: finalize_trace error logged to audit" \
    "$(grep -q 'trace_orphan.*finalize_trace failed for planner' "$PLANNER_SH" 2>/dev/null && echo pass || echo "audit log for finalize failure missing")"

run_test "check-planner.sh: finalize runs before get_git_state" \
    "$(awk '/finalize_trace/{found_fin=1} /get_git_state/{if(found_fin) print "pass"; else print "get_git_state before finalize"; exit}' "$PLANNER_SH" 2>/dev/null | grep -q pass && echo pass || echo "finalize not before get_git_state")"

run_test "check-planner.sh: has DEC-PLANNER-STOP-002 annotation" \
    "$(grep -q 'DEC-PLANNER-STOP-002' "$PLANNER_SH" 2>/dev/null && echo pass || echo "DEC-PLANNER-STOP-002 annotation missing")"

# ============================================================
# Group 6: check-tester.sh — empty-detection is trace_skip, Phase 1 finalizes
# ============================================================

TESTER_SH="${HOOKS_DIR}/check-tester.sh"

# Issue #123 Fix 3: tester empty-detection is informational (init can fail
# silently). Use trace_skip, not trace_orphan.
run_test "check-tester.sh: logs trace_skip (not trace_orphan) on empty TRACE_ID (Fix #123)" \
    "$(grep -q 'trace_skip.*detect_active_trace returned empty for tester' "$TESTER_SH" 2>/dev/null && echo pass || echo "trace_skip log for empty tester TRACE_ID missing")"

run_test "check-tester.sh: does NOT log trace_orphan on empty TRACE_ID (Fix #123)" \
    "$(grep -q 'trace_orphan.*detect_active_trace returned empty for tester' "$TESTER_SH" 2>/dev/null \
        && echo "FAIL: trace_orphan still logged for empty tester TRACE_ID" \
        || echo pass)"

run_test "check-tester.sh: finalize_trace failure logged to audit" \
    "$(grep -q 'trace_orphan.*finalize_trace failed for tester' "$TESTER_SH" 2>/dev/null && echo pass || echo "audit log for finalize failure missing")"

# Issue #123 Fix 4: Phase 1 auto-verify path must call detect_active_trace and
# finalize_trace before the early exit to prevent stale active markers in
# TRACE_STORE. We check that within the AUTO_VERIFIED==true block, both calls
# appear before the exit 0.
run_test "check-tester.sh: Phase 1 auto-verify block calls detect_active_trace (Fix #123)" \
    "$(awk '/if \[\[ "\$AUTO_VERIFIED" == "true" \]\]/,/^fi$/{print}' "$TESTER_SH" 2>/dev/null \
        | grep -q 'detect_active_trace' && echo pass \
        || echo "detect_active_trace not in Phase 1 auto-verify block")"

run_test "check-tester.sh: Phase 1 auto-verify block calls finalize_trace (Fix #123)" \
    "$(awk '/if \[\[ "\$AUTO_VERIFIED" == "true" \]\]/,/^fi$/{print}' "$TESTER_SH" 2>/dev/null \
        | grep -q 'finalize_trace' && echo pass \
        || echo "finalize_trace not in Phase 1 auto-verify block")"

run_test "check-tester.sh: has DEC-TESTER-005 annotation (Fix #123)" \
    "$(grep -q 'DEC-TESTER-005' "$TESTER_SH" 2>/dev/null && echo pass || echo "DEC-TESTER-005 annotation missing")"

# ============================================================
# Group 7: refinalize_trace status repair in context-lib.sh
# ============================================================

CTXLIB="${HOOKS_DIR}/context-lib.sh"

run_test "context-lib.sh: refinalize_trace reads cur_status from manifest" \
    "$(grep -A5 'refinalize_trace()' "$CTXLIB" 2>/dev/null | grep -q 'cur_status\|\.status' || grep -q 'cur_status' "$CTXLIB" 2>/dev/null && echo pass || echo "cur_status read missing")"

run_test "context-lib.sh: refinalize_trace transitions active→completed for orphans" \
    "$(grep -q 'new_status.*completed\|completed.*new_status' "$CTXLIB" 2>/dev/null && echo pass || echo "active→completed transition missing")"

run_test "context-lib.sh: refinalize_trace uses 30-minute orphan threshold" \
    "$(grep -q 'orphan_threshold.*1800\|1800.*orphan_threshold' "$CTXLIB" 2>/dev/null && echo pass || echo "30-minute threshold missing")"

run_test "context-lib.sh: refinalize_trace estimates finished_at from artifact mtime" \
    "$(grep -q 'latest_artifact\|artifact.*mtime\|stat.*artifacts' "$CTXLIB" 2>/dev/null && echo pass || echo "artifact mtime estimation missing")"

run_test "context-lib.sh: refinalize_trace includes status in change detection" \
    "$(grep -E 'new_status.*cur_status|changed=true.*status' "$CTXLIB" 2>/dev/null | grep -q 'changed' && echo pass || echo "status change detection missing")"

run_test "context-lib.sh: refinalize_trace writes status to manifest" \
    "$(awk '/^refinalize_trace\(\)/,/^}/' "$CTXLIB" 2>/dev/null | grep -q 'new_status\|status.*new_status' && echo pass || echo "status not written to manifest")"

run_test "context-lib.sh: refinalize_trace writes finished_at when estimated" \
    "$(awk '/^refinalize_trace\(\)/,/^}/' "$CTXLIB" 2>/dev/null | grep -q 'new_finished_at\|finished_at.*new_finished' && echo pass || echo "finished_at not written to manifest")"

run_test "context-lib.sh: has DEC-REFINALIZE-007 annotation" \
    "$(grep -q 'DEC-REFINALIZE-007' "$CTXLIB" 2>/dev/null && echo pass || echo "DEC-REFINALIZE-007 annotation missing")"

# ============================================================
# Group 8: Functional test — refinalize_trace fixes an orphaned trace
# ============================================================

# Create a fake orphaned trace and verify refinalize_trace repairs it
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

FAKE_TRACE_STORE="$TMPDIR_TEST/traces"
FAKE_TRACE_ID="test-orphan-$(date +%s)"
FAKE_TRACE_DIR="$FAKE_TRACE_STORE/$FAKE_TRACE_ID"
mkdir -p "$FAKE_TRACE_DIR/artifacts"

# Write a summary.md and a fake artifact so outcome won't be skipped/crashed
echo "Test summary" > "$FAKE_TRACE_DIR/summary.md"
echo "Test output: passed" > "$FAKE_TRACE_DIR/artifacts/test-output.txt"

# Write manifest with status="active" and started_at 45 minutes ago
STARTED_AT=$(date -u -r $(( $(date -u +%s) - 2700 )) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "-45 minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || echo "2000-01-01T00:00:00Z")

cat > "$FAKE_TRACE_DIR/manifest.json" <<MANIFEST
{
  "trace_id": "$FAKE_TRACE_ID",
  "agent_type": "explore",
  "project_name": "test",
  "started_at": "$STARTED_AT",
  "status": "active",
  "outcome": "unknown",
  "test_result": "unknown",
  "files_changed": 0,
  "duration_seconds": 0
}
MANIFEST

# Source context-lib — it hardcodes TRACE_STORE=$HOME/.claude/traces at line 528,
# so we must override TRACE_STORE AFTER sourcing, not before.
TRACE_STORE_ORIG="${TRACE_STORE:-}"
# shellcheck disable=SC1090
source "$CTXLIB" 2>/dev/null || true
# Override TRACE_STORE to point at our temp fixture (sourcing resets it)
TRACE_STORE="$FAKE_TRACE_STORE"
export TRACE_STORE

# Run refinalize_trace
refinalize_trace "$FAKE_TRACE_ID" 2>/dev/null || true

# Check if status was repaired
REPAIRED_STATUS=$(jq -r '.status // "unknown"' "$FAKE_TRACE_DIR/manifest.json" 2>/dev/null)
run_test "functional: refinalize_trace repairs active→completed for 45-min-old orphan" \
    "$([[ "$REPAIRED_STATUS" == "completed" ]] && echo pass || echo "status still '$REPAIRED_STATUS', expected 'completed'")"

REPAIRED_OUTCOME=$(jq -r '.outcome // "unknown"' "$FAKE_TRACE_DIR/manifest.json" 2>/dev/null)
run_test "functional: refinalize_trace sets outcome=success (test-output has 'passed')" \
    "$([[ "$REPAIRED_OUTCOME" == "success" ]] && echo pass || echo "outcome='$REPAIRED_OUTCOME', expected 'success'")"

# Restore TRACE_STORE
if [[ -n "$TRACE_STORE_ORIG" ]]; then
    export TRACE_STORE="$TRACE_STORE_ORIG"
else
    unset TRACE_STORE
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "Results: $((PASS+FAIL))/$((PASS+FAIL)) run, $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
