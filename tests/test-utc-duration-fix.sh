#!/usr/bin/env bash
# test-utc-duration-fix.sh — Tests for SUG-001: UTC timezone bug in finalize_trace
#
# Purpose: Verify that date parsing in finalize_trace correctly interprets UTC
#          timestamps. Before the fix, `date -j -f` without `-u` interpreted UTC
#          strings as local time, causing negative or zero durations for all traces.
#
# @decision DEC-CTX-UTC-001
# @title Verify UTC flag in date parsing for trace duration calculation
# @status accepted
# @rationale The `-u` flag forces date(1) to interpret the format string as UTC.
#             Without it, a "2026-01-01T12:00:00Z" timestamp is treated as local
#             time, making start_epoch wrong by the UTC offset. On macOS (date -j -f),
#             the offset is typically 7-8 hours, producing a large positive start_epoch
#             that exceeds now_epoch, resulting in duration=0 (guarded by the >0 check).
#
# Usage: bash tests/test-utc-duration-fix.sh
# Returns: 0 if all tests pass, 1 if any fail

set -euo pipefail

WORKTREE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_DIR="${WORKTREE_DIR}/hooks"
CONTEXT_LIB="${HOOKS_DIR}/context-lib.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== SUG-001: UTC Timezone Fix Tests ==="
echo "Testing: ${CONTEXT_LIB}"
echo ""

# --- Test 1: date -u -j -f correctly parses a known UTC timestamp (macOS) ---
echo "=== Test 1: macOS date -u -j -f parses UTC timestamp correctly ==="
KNOWN_UTC="2026-01-01T12:00:00Z"
# Compute the expected epoch dynamically so test is portable across environments
EXPECTED_EPOCH=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$KNOWN_UTC" +%s 2>/dev/null || echo "0")

# Cross-check: verify it's > Jan 1, 2026 00:00:00 UTC (1767225600) and < Jan 2, 2026
JAN1_EPOCH=1767225600
JAN2_EPOCH=1767312000

if [[ "$EXPECTED_EPOCH" -gt "$JAN1_EPOCH" && "$EXPECTED_EPOCH" -lt "$JAN2_EPOCH" ]]; then
    pass "date -u -j -f parses $KNOWN_UTC → $EXPECTED_EPOCH (within expected Jan 1, 2026 range)"
else
    fail "date -u -j -f parsed $KNOWN_UTC → $EXPECTED_EPOCH (not in expected 2026-01-01 range: $JAN1_EPOCH to $JAN2_EPOCH)"
fi

# --- Test 2: WITHOUT -u flag produces wrong epoch (proves the bug existed) ---
echo ""
echo "=== Test 2: date WITHOUT -u flag produces wrong epoch (demonstrates the bug) ==="
BUGGY_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$KNOWN_UTC" +%s 2>/dev/null || echo "0")
if [[ "$BUGGY_EPOCH" -ne "$EXPECTED_EPOCH" ]]; then
    pass "Confirmed: date without -u misparses UTC timestamp ($BUGGY_EPOCH ≠ $EXPECTED_EPOCH) — bug existed"
else
    # This can happen if TZ=UTC — note it but don't fail
    echo "NOTE: date without -u gave same result ($BUGGY_EPOCH) — TZ may be UTC in this environment"
    pass "TZ=UTC environment: both forms produce correct result"
fi

# --- Test 3: Verify the fixed line in context-lib.sh uses -u flag ---
echo ""
echo "=== Test 3: context-lib.sh contains the -u flag fix ==="
if grep -q 'date -u -j -f "%Y-%m-%dT%H:%M:%SZ"' "$CONTEXT_LIB"; then
    pass "context-lib.sh has 'date -u -j -f' (macOS path fixed)"
else
    fail "context-lib.sh missing 'date -u -j -f' — fix not applied"
fi

# --- Test 4: Verify Linux fallback also has -u flag ---
echo ""
echo "=== Test 4: context-lib.sh Linux fallback also has -u flag ==="
# The line pattern: date -u -j -f ... || date -u -d ... || echo "0"
if grep -qE 'date -u -j.*\|\| date -u -d' "$CONTEXT_LIB"; then
    pass "context-lib.sh has 'date -u -d' in Linux fallback (both paths fixed)"
else
    fail "context-lib.sh missing 'date -u -d' in Linux fallback"
fi

# --- Test 5: Integration — finalize_trace produces positive duration ---
echo ""
echo "=== Test 5: finalize_trace produces positive duration for recent start time ==="

# Create a temporary trace environment
TRACE_TMP=$(mktemp -d)
trap "rm -rf $TRACE_TMP" EXIT

export TRACE_STORE="$TRACE_TMP"
export CLAUDE_SESSION_ID="test-session-utc-fix"

# Create a fake trace directory with manifest
FAKE_TRACE_ID="test-utc-trace-001"
FAKE_TRACE_DIR="${TRACE_TMP}/${FAKE_TRACE_ID}"
mkdir -p "${FAKE_TRACE_DIR}/artifacts"

# Set started_at to 60 seconds ago in UTC
STARTED_AT=$(date -u -v-60S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '60 seconds ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)

printf '{\n  "trace_id": "%s",\n  "agent_type": "implementer",\n  "started_at": "%s",\n  "session_id": "test-session-utc-fix",\n  "project_root": "/tmp/test-project"\n}\n' \
    "$FAKE_TRACE_ID" "$STARTED_AT" > "${FAKE_TRACE_DIR}/manifest.json"

# Write summary.md so trace_status = "completed" (not "crashed")
printf '# Test trace summary\n' > "${FAKE_TRACE_DIR}/summary.md"

# Run finalize_trace in a subshell. TRACE_STORE must be set AFTER sourcing context-lib
# because context-lib.sh unconditionally sets TRACE_STORE="$HOME/.claude/traces" at
# module load time, overwriting any exported env var.
(
    set +e
    source "$CONTEXT_LIB" 2>/dev/null
    # Override TRACE_STORE after sourcing (context-lib sets it at load time)
    TRACE_STORE="$TRACE_TMP"
    finalize_trace "$FAKE_TRACE_ID" "/tmp/test-project" "implementer" 2>/dev/null
    exit 0
)

# Read the updated manifest — duration_seconds should be >0 after the UTC fix
if [[ -f "${FAKE_TRACE_DIR}/manifest.json" ]]; then
    DURATION=$(jq -r '.duration_seconds // 0' "${FAKE_TRACE_DIR}/manifest.json" 2>/dev/null || echo "0")
    if [[ "$DURATION" =~ ^[0-9]+$ ]] && [[ "$DURATION" -gt 0 ]]; then
        pass "finalize_trace produced positive duration: ${DURATION}s (UTC fix working)"
    else
        fail "finalize_trace produced duration='$DURATION' (expected >0 — UTC fix may not be working)"
        echo "  Manifest contents: $(cat "${FAKE_TRACE_DIR}/manifest.json" 2>/dev/null)"
    fi
else
    fail "Manifest not updated by finalize_trace"
fi

# --- Test 6: Verify no regression — context-lib.sh syntax is valid ---
echo ""
echo "=== Test 6: context-lib.sh syntax is valid bash ==="
if bash -n "$CONTEXT_LIB" 2>/dev/null; then
    pass "context-lib.sh passes bash syntax check"
else
    fail "context-lib.sh has syntax errors"
fi

# --- Summary ---
echo ""
echo "====================================="
echo "RESULTS: $PASS passed, $FAIL failed"
echo "====================================="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
