#!/usr/bin/env bash
# test-tester-gate-heal.sh — Tests for self-healing tester gate (Gate B orphan detection)
#
# Purpose: Verify that Gate B in task-track.sh correctly detects and auto-heals stale
#          implementer traces instead of blocking tester dispatch permanently. Covers
#          three scenarios: stale trace auto-heals, fresh trace still blocks, and marker
#          cleanup after auto-heal.
#
# @decision DEC-TESTER-GATE-HEAL-001
# @title Test suite for self-healing tester dispatch gate
# @status accepted
# @rationale When finalize_trace fails (timeout race, crash, session interruption),
#   Gate B in task-track.sh detects an active implementer trace and denies tester
#   dispatch permanently — a deadlock. The self-healing fix calls refinalize_trace
#   on traces older than 5 minutes and forces status: "completed" (refinalize_trace
#   alone does not write status). These tests verify: (1) stale traces are auto-healed
#   and tester is allowed, (2) fresh traces still block tester, (3) markers are cleaned
#   up after auto-heal, and (4) new tests at the 5-min boundary and status flip.
#   See DEC-TESTER-GATE-HEAL-002 for threshold reduction rationale (issues #127, #128).
#
# Usage: bash tests/test-tester-gate-heal.sh
# Returns: 0 if all tests pass, 1 if any fail

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="${WORKTREE_ROOT}/hooks"
TASK_TRACK="${HOOKS_DIR}/task-track.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

# Suppress hook library stderr during source
exec 3>&2
exec 2>/dev/null

# Source log.sh and context-lib to get refinalize_trace, TRACE_STORE, etc.
# shellcheck source=/dev/null
source "${HOOKS_DIR}/log.sh"
# shellcheck source=/dev/null
source "${HOOKS_DIR}/context-lib.sh"

# Override TRACE_STORE with a temp dir AFTER sourcing (sourcing resets it)
FAKE_TRACE_STORE=$(mktemp -d)
export TRACE_STORE="$FAKE_TRACE_STORE"
cleanup_dirs=("$FAKE_TRACE_STORE")
trap 'rm -rf "${cleanup_dirs[@]}"' EXIT

# Restore stderr for test output
exec 2>&3
exec 3>&-

# ============================================================
# Helper: create a fake implementer trace manifest
# Arguments:
#   $1 — trace_id
#   $2 — started_at (ISO 8601 UTC, e.g. "2025-01-01T00:00:00Z")
#   $3 — status (e.g. "active")
# ============================================================
make_impl_trace() {
    local trace_id="$1"
    local started_at="$2"
    local status="${3:-active}"

    local trace_dir="${FAKE_TRACE_STORE}/${trace_id}"
    mkdir -p "${trace_dir}/artifacts"

    # Write a summary and artifact so refinalize_trace has something to inspect
    echo "Implementer summary" > "${trace_dir}/summary.md"
    echo "Tests: passed" > "${trace_dir}/artifacts/test-output.txt"

    cat > "${trace_dir}/manifest.json" <<MANIFEST
{
  "trace_id": "${trace_id}",
  "agent_type": "implementer",
  "project_name": "test-project",
  "session_id": "test-session-123",
  "started_at": "${started_at}",
  "status": "${status}",
  "outcome": "unknown",
  "test_result": "unknown",
  "files_changed": 0,
  "duration_seconds": 0
}
MANIFEST
}

# ============================================================
# Helper: make_started_at — compute an ISO 8601 UTC timestamp
# Arguments:
#   $1 — seconds_offset (negative = in the past, e.g. -2700 for 45 min ago)
# ============================================================
make_started_at() {
    local offset="${1:-0}"
    local epoch
    epoch=$(( $(date -u +%s) + offset ))
    # macOS (BSD date) and Linux (GNU date) differ in epoch formatting
    date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || echo "2000-01-01T00:00:00Z"
}

# ============================================================
# Helper: run_gate_b — simulate Gate B logic from task-track.sh
#
# We exercise Gate B directly (not by invoking the full hook) because:
#   - task-track.sh calls track_subagent_start which writes to live TRACE_STORE
#   - The full hook flow requires valid git repo context and proof-status files
#   - We want to test only Gate B's staleness logic in isolation
#
# Returns: "denied" or "allowed"
# ============================================================
run_gate_b() {
    local trace_id="$1"

    local impl_manifest="${FAKE_TRACE_STORE}/${trace_id}/manifest.json"
    local impl_status
    impl_status=$(jq -r '.status // "unknown"' "$impl_manifest" 2>/dev/null || echo "unknown")

    if [[ "$impl_status" != "active" ]]; then
        echo "allowed"
        return 0
    fi

    # Staleness check (mirrors task-track.sh Gate B logic)
    local impl_started
    impl_started=$(jq -r '.started_at // empty' "$impl_manifest" 2>/dev/null)
    local impl_start_epoch=0
    if [[ -n "$impl_started" ]]; then
        impl_start_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$impl_started" +%s 2>/dev/null \
            || date -u -d "$impl_started" +%s 2>/dev/null \
            || echo "0")
    fi
    local now_epoch
    now_epoch=$(date -u +%s)
    local stale_threshold=300  # 5 minutes — matches check-implementer.sh timeout (15s) with margin

    if [[ "$impl_start_epoch" -gt 0 && $(( now_epoch - impl_start_epoch )) -gt "$stale_threshold" ]]; then
        # Stale — auto-heal
        refinalize_trace "$trace_id" 2>/dev/null || true
        # Force status to "completed" — refinalize_trace does NOT write status field
        jq '. + {status: "completed"}' "$impl_manifest" > "${impl_manifest}.tmp" 2>/dev/null \
            && mv "${impl_manifest}.tmp" "$impl_manifest" 2>/dev/null || true
        # Clean markers (wildcard because session suffix may differ)
        rm -f "${FAKE_TRACE_STORE}/.active-implementer-"* 2>/dev/null || true
        # Re-read status after repair
        impl_status=$(jq -r '.status // "unknown"' "$impl_manifest" 2>/dev/null || echo "unknown")
    fi

    if [[ "$impl_status" == "active" ]]; then
        echo "denied"
    else
        echo "allowed"
    fi
}

# ============================================================
# Test 1: Syntax — task-track.sh is valid bash
# ============================================================
echo "Running: Syntax: task-track.sh is valid bash"
if bash -n "$TASK_TRACK" 2>/dev/null; then
    pass "Syntax: task-track.sh is valid bash"
else
    fail "Syntax: task-track.sh is valid bash" "syntax error in task-track.sh"
fi

# ============================================================
# Test 2: Gate B code — staleness check exists in task-track.sh
# ============================================================
echo "Running: task-track.sh Gate B: contains staleness check"
if grep -q 'STALE_THRESHOLD\|staleness\|stale_threshold\|IMPL_START_EPOCH' "$TASK_TRACK" 2>/dev/null; then
    pass "task-track.sh Gate B: contains staleness check"
else
    fail "task-track.sh Gate B: contains staleness check" "staleness variables not found in Gate B"
fi

# ============================================================
# Test 3: Gate B code — calls refinalize_trace on stale traces
# ============================================================
echo "Running: task-track.sh Gate B: calls refinalize_trace for stale traces"
if grep -q 'refinalize_trace.*IMPL_TRACE\|refinalize_trace.*\$IMPL_TRACE' "$TASK_TRACK" 2>/dev/null; then
    pass "task-track.sh Gate B: calls refinalize_trace for stale traces"
else
    fail "task-track.sh Gate B: calls refinalize_trace for stale traces" "refinalize_trace call not found in Gate B"
fi

# ============================================================
# Test 4: Gate B code — cleans .active-implementer-* markers
# ============================================================
echo "Running: task-track.sh Gate B: cleans .active-implementer-* markers after heal"
if grep -q '\.active-implementer-\*\|active-implementer-.*\*' "$TASK_TRACK" 2>/dev/null; then
    pass "task-track.sh Gate B: cleans .active-implementer-* markers after heal"
else
    fail "task-track.sh Gate B: cleans .active-implementer-* markers after heal" "wildcard marker cleanup not found"
fi

# ============================================================
# Test 5: Gate B code — has DEC-TESTER-GATE-HEAL-001 annotation
# ============================================================
echo "Running: task-track.sh Gate B: has DEC-TESTER-GATE-HEAL-001 annotation"
if grep -q 'DEC-TESTER-GATE-HEAL-001' "$TASK_TRACK" 2>/dev/null; then
    pass "task-track.sh Gate B: has DEC-TESTER-GATE-HEAL-001 annotation"
else
    fail "task-track.sh Gate B: has DEC-TESTER-GATE-HEAL-001 annotation" "annotation not found"
fi

# ============================================================
# Test 5b: Gate B code — has DEC-TESTER-GATE-HEAL-002 annotation (issues #127, #128)
# ============================================================
echo "Running: task-track.sh Gate B: has DEC-TESTER-GATE-HEAL-002 annotation"
if grep -q 'DEC-TESTER-GATE-HEAL-002' "$TASK_TRACK" 2>/dev/null; then
    pass "task-track.sh Gate B: has DEC-TESTER-GATE-HEAL-002 annotation"
else
    fail "task-track.sh Gate B: has DEC-TESTER-GATE-HEAL-002 annotation" "annotation not found"
fi

# ============================================================
# Test 5c: Gate B code — STALE_THRESHOLD is 300 (5 min), not 1800 (30 min)
# ============================================================
echo "Running: task-track.sh Gate B: STALE_THRESHOLD=300 (not 1800)"
if grep -q 'STALE_THRESHOLD=300' "$TASK_TRACK" 2>/dev/null; then
    pass "task-track.sh Gate B: STALE_THRESHOLD=300 (not 1800)"
else
    fail "task-track.sh Gate B: STALE_THRESHOLD=300 (not 1800)" \
         "STALE_THRESHOLD=300 not found — threshold may not have been reduced from 1800"
fi

# ============================================================
# Test 5d: Gate B code — forces status flip via jq after refinalize_trace
# ============================================================
echo "Running: task-track.sh Gate B: contains jq status flip after refinalize_trace"
if grep -q 'status.*completed.*refinalize\|refinalize.*status.*completed\|jq.*status.*completed\|completed.*jq.*IMPL_MANIFEST' "$TASK_TRACK" 2>/dev/null \
    || grep -q 'status: "completed"' "$TASK_TRACK" 2>/dev/null \
    || (grep -q 'jq.*completed' "$TASK_TRACK" 2>/dev/null && grep -q 'IMPL_MANIFEST' "$TASK_TRACK" 2>/dev/null); then
    pass "task-track.sh Gate B: contains jq status flip after refinalize_trace"
else
    fail "task-track.sh Gate B: contains jq status flip after refinalize_trace" \
         "jq status flip not found in task-track.sh"
fi

# ============================================================
# Test 6: Functional — stale trace (45 min old) auto-heals
# Verifies: refinalize_trace is called, status transitions to completed,
# and gate logic allows tester dispatch.
# ============================================================
echo "Running: Functional: stale trace (45 min ago) auto-heals and gate allows tester"
STALE_TRACE_ID="impl-stale-$(date +%s)"
STALE_STARTED=$(make_started_at -2700)  # 45 minutes ago
make_impl_trace "$STALE_TRACE_ID" "$STALE_STARTED" "active"

RESULT=$(run_gate_b "$STALE_TRACE_ID")
if [[ "$RESULT" == "allowed" ]]; then
    pass "Functional: stale trace (45 min ago) auto-heals and gate allows tester"
else
    fail "Functional: stale trace (45 min ago) auto-heals and gate allows tester" \
         "gate returned '$RESULT' — expected 'allowed'"
fi

# ============================================================
# Test 7: Functional — stale trace status repaired to completed
# After auto-heal, manifest.status must be "completed", not "active"
# ============================================================
echo "Running: Functional: stale trace manifest status repaired to completed"
REPAIRED_STATUS=$(jq -r '.status // "unknown"' \
    "${FAKE_TRACE_STORE}/${STALE_TRACE_ID}/manifest.json" 2>/dev/null)
if [[ "$REPAIRED_STATUS" == "completed" ]]; then
    pass "Functional: stale trace manifest status repaired to completed"
else
    fail "Functional: stale trace manifest status repaired to completed" \
         "status is '$REPAIRED_STATUS' — expected 'completed'"
fi

# ============================================================
# Test 8: Functional — fresh trace (exactly at 5-min boundary) still blocks tester
# Threshold condition is strictly greater-than (> 300), so a trace started exactly
# 300 seconds ago is NOT stale yet — the gate must deny.
# ============================================================
echo "Running: Functional: fresh trace (exactly 5 min ago) still blocks tester dispatch"
FRESH_TRACE_ID="impl-fresh-$(date +%s)-$$"
FRESH_STARTED=$(make_started_at -300)  # exactly 5 minutes ago — not yet stale
make_impl_trace "$FRESH_TRACE_ID" "$FRESH_STARTED" "active"

FRESH_RESULT=$(run_gate_b "$FRESH_TRACE_ID")
if [[ "$FRESH_RESULT" == "denied" ]]; then
    pass "Functional: fresh trace (exactly 5 min ago) still blocks tester dispatch"
else
    fail "Functional: fresh trace (exactly 5 min ago) still blocks tester dispatch" \
         "gate returned '$FRESH_RESULT' — expected 'denied'"
fi

# ============================================================
# Test 9: Functional — marker cleanup after auto-heal
# After auto-healing a stale trace, .active-implementer-* markers must be removed
# ============================================================
echo "Running: Functional: .active-implementer-* markers cleaned after auto-heal"
MARKER_TRACE_ID="impl-marker-$(date +%s)-$$"
MARKER_STARTED=$(make_started_at -3600)  # 60 minutes ago
make_impl_trace "$MARKER_TRACE_ID" "$MARKER_STARTED" "active"

# Create a fake marker (simulating what track_subagent_start would write)
MARKER_FILE="${FAKE_TRACE_STORE}/.active-implementer-test-session-marker"
echo "$MARKER_TRACE_ID" > "$MARKER_FILE"

# Run gate B — should heal and clean the marker
run_gate_b "$MARKER_TRACE_ID" > /dev/null

if [[ ! -f "$MARKER_FILE" ]]; then
    pass "Functional: .active-implementer-* markers cleaned after auto-heal"
else
    fail "Functional: .active-implementer-* markers cleaned after auto-heal" \
         "marker file still exists: $MARKER_FILE"
fi

# ============================================================
# Test 10: Functional — completed trace is never blocked
# Completed traces shouldn't trigger Gate B at all (status != active)
# ============================================================
echo "Running: Functional: completed trace (non-active) is allowed through gate"
DONE_TRACE_ID="impl-done-$(date +%s)-$$"
DONE_STARTED=$(make_started_at -120)  # 2 minutes ago (recent, but already completed)
make_impl_trace "$DONE_TRACE_ID" "$DONE_STARTED" "completed"

DONE_RESULT=$(run_gate_b "$DONE_TRACE_ID")
if [[ "$DONE_RESULT" == "allowed" ]]; then
    pass "Functional: completed trace (non-active) is allowed through gate"
else
    fail "Functional: completed trace (non-active) is allowed through gate" \
         "gate returned '$DONE_RESULT' — expected 'allowed'"
fi

# ============================================================
# Test 11: Functional — trace just over 5-min threshold auto-heals (DEC-TESTER-GATE-HEAL-002)
# A trace started 360 seconds ago (6 min) exceeds the 300-second threshold and must
# auto-heal. This validates the reduced threshold works at the near-boundary.
# ============================================================
echo "Running: Functional: trace just over 5-min threshold (6 min ago) auto-heals"
NEAR_STALE_TRACE_ID="impl-near-stale-$(date +%s)-$$"
NEAR_STALE_STARTED=$(make_started_at -360)  # 6 minutes ago — just over threshold
make_impl_trace "$NEAR_STALE_TRACE_ID" "$NEAR_STALE_STARTED" "active"

NEAR_RESULT=$(run_gate_b "$NEAR_STALE_TRACE_ID")
if [[ "$NEAR_RESULT" == "allowed" ]]; then
    pass "Functional: trace just over 5-min threshold (6 min ago) auto-heals"
else
    fail "Functional: trace just over 5-min threshold (6 min ago) auto-heals" \
         "gate returned '$NEAR_RESULT' — expected 'allowed'"
fi

# ============================================================
# Test 12: Functional — status flip actually writes "completed" to manifest
# Verifies DEC-TESTER-GATE-HEAL-002: the jq status flip must persist so
# re-reads after refinalize_trace see "completed" rather than "active".
# ============================================================
echo "Running: Functional: status flip writes completed to manifest (not just in-memory)"
FLIP_TRACE_ID="impl-flip-$(date +%s)-$$"
FLIP_STARTED=$(make_started_at -420)  # 7 minutes ago — stale
make_impl_trace "$FLIP_TRACE_ID" "$FLIP_STARTED" "active"

# Run gate B — triggers auto-heal + status flip
run_gate_b "$FLIP_TRACE_ID" > /dev/null

# Read manifest directly — not via run_gate_b — to confirm the flip persisted on disk
FLIP_STATUS=$(jq -r '.status // "unknown"' \
    "${FAKE_TRACE_STORE}/${FLIP_TRACE_ID}/manifest.json" 2>/dev/null)
if [[ "$FLIP_STATUS" == "completed" ]]; then
    pass "Functional: status flip writes completed to manifest (not just in-memory)"
else
    fail "Functional: status flip writes completed to manifest (not just in-memory)" \
         "manifest status is '$FLIP_STATUS' — expected 'completed'"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "Results: $((PASS+FAIL)) run, $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
