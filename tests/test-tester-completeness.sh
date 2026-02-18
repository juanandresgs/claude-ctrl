#!/usr/bin/env bash
# Tests for tester completeness gate in check-tester.sh (Check 3)
#
# @decision DEC-TEST-COMPLETENESS-001
# @title Tester completeness gate test suite
# @status accepted
# @rationale Validates that check-tester.sh Check 3 correctly detects partial
#   tester runs and blocks the approval flow.
#
#   Key implementation detail: check-tester.sh calls finalize_trace() (Check 2)
#   BEFORE Check 3 runs. finalize_trace() re-derives manifest.json outcome from
#   artifacts — so Signal 1 (outcome == "partial") only fires when finalize_trace
#   writes "partial" (no test-output.txt and no .test-status found). Signal 2
#   (verification-output.txt absent) is the primary reliable gate.
#
#   Practically: a tester that wrote verification-output.txt also wrote
#   test-output.txt, so finalize_trace sets outcome="success" and Signal 1
#   is dormant. A tester with no artifacts gets outcome="partial" from
#   finalize_trace AND triggers Signal 2. Both signals correctly align.
#
#   context-lib.sh sets TRACE_STORE="$HOME/.claude/traces" unconditionally,
#   so tests must use the real TRACE_STORE with test-scoped IDs.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"
REAL_TRACE_STORE="$HOME/.claude/traces"

mkdir -p "$PROJECT_ROOT/tmp"
mkdir -p "$REAL_TRACE_STORE"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test-scoped session ID — avoids collisions with real active traces
TEST_SESSION_ID="test-completeness-$$"

run_test() {
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "Running: $1"
}

pass_test() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  PASS"
}

fail_test() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL: $1"
}

# ---------------------------------------------------------------------------
# Helper: create a mock trace in the real TRACE_STORE
#
# Args:
#   $1 - has_verification_output: "yes" or "no"
#   $2 - has_test_output: "yes" or "no" (controls finalize_trace outcome)
#   $3 - has_summary: "yes" or "no" (prevents finalize overriding to "crashed")
#
# finalize_trace re-derives outcome from artifacts:
#   test-output.txt with "passed" → outcome="success"
#   no test-output.txt, no .test-status → outcome="partial"
#   no summary.md → outcome overridden to "crashed"
#
# Sets $MOCK_TRACE_ID and $MOCK_TRACE_DIR; plants .active-tester marker.
# ---------------------------------------------------------------------------
make_trace() {
    local has_verification="${1:-yes}"
    local has_test_output="${2:-yes}"
    local has_summary="${3:-yes}"

    MOCK_TRACE_ID="test-completeness-$(date +%s%3N)-$$-${TESTS_RUN}"
    MOCK_TRACE_DIR="$REAL_TRACE_STORE/$MOCK_TRACE_ID"
    mkdir -p "$MOCK_TRACE_DIR/artifacts"

    # Write a base manifest (finalize_trace will update it)
    printf '{"trace_id":"%s","outcome":"unknown","agent":"tester"}\n' \
        "$MOCK_TRACE_ID" > "$MOCK_TRACE_DIR/manifest.json"

    if [[ "$has_verification" == "yes" ]]; then
        printf 'Feature works as expected.\n' \
            > "$MOCK_TRACE_DIR/artifacts/verification-output.txt"
    fi

    if [[ "$has_test_output" == "yes" ]]; then
        # "passed" keyword → finalize_trace sets outcome="success"
        printf 'All tests passed.\n' \
            > "$MOCK_TRACE_DIR/artifacts/test-output.txt"
    fi

    if [[ "$has_summary" == "yes" ]]; then
        # summary.md present → finalize_trace does NOT override to "crashed"
        printf '# Tester summary\nStatus: complete\n' \
            > "$MOCK_TRACE_DIR/summary.md"
    fi

    # Plant active marker so detect_active_trace() finds this trace by session ID
    printf '%s\n' "$MOCK_TRACE_ID" \
        > "$REAL_TRACE_STORE/.active-tester-$TEST_SESSION_ID"
}

cleanup_trace() {
    rm -f "$REAL_TRACE_STORE/.active-tester-$TEST_SESSION_ID"
    if [[ -n "${MOCK_TRACE_DIR:-}" && -d "${MOCK_TRACE_DIR:-}" ]]; then
        rm -rf "$MOCK_TRACE_DIR"
    fi
    MOCK_TRACE_DIR=""
    MOCK_TRACE_ID=""
}

# ---------------------------------------------------------------------------
# Helper: run check-tester.sh with a controlled project environment
# Args:
#   $1 - proof_status: content for .proof-status, or "missing"
# Sets $HOOK_EXIT_CODE and $HOOK_OUTPUT.
# ---------------------------------------------------------------------------
run_check_tester() {
    local proof_status="$1"

    local TEMP_REPO
    TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-ct-XXXXXX")
    git -C "$TEMP_REPO" init > /dev/null 2>&1
    mkdir -p "$TEMP_REPO/.claude"

    if [[ "$proof_status" != "missing" ]]; then
        printf '%s\n' "$proof_status" > "$TEMP_REPO/.claude/.proof-status"
    fi

    printf '{"response": "Tester verification complete."}\n' \
        > "$TEMP_REPO/input.json"

    local OUTPUT
    local EXIT_CODE=0
    OUTPUT=$(cd "$TEMP_REPO" && \
             CLAUDE_PROJECT_DIR="$TEMP_REPO" \
             CLAUDE_SESSION_ID="$TEST_SESSION_ID" \
             bash "$HOOKS_DIR/check-tester.sh" < input.json 2>&1) || EXIT_CODE=$?

    cd /Users/turla/.claude
    rm -rf "$TEMP_REPO"

    HOOK_OUTPUT="$OUTPUT"
    HOOK_EXIT_CODE="$EXIT_CODE"
}

# ---------------------------------------------------------------------------
# Test 1: No artifacts at all (neither verification nor test-output)
#   → finalize_trace sets outcome="partial" (no test-output.txt)
#   → Signal 2 fires (no verification-output.txt)
#   → exit 2, INCOMPLETE
# ---------------------------------------------------------------------------
run_test "Check 3: no artifacts at all → exit 2 INCOMPLETE"

make_trace "no" "no" "yes"
HOOK_OUTPUT="" ; HOOK_EXIT_CODE=0
run_check_tester "pending"
cleanup_trace

if [[ "$HOOK_EXIT_CODE" -eq 2 ]]; then
    if echo "$HOOK_OUTPUT" | grep -q "INCOMPLETE"; then
        pass_test
    else
        fail_test "exit 2 but INCOMPLETE directive missing. Got: $HOOK_OUTPUT"
    fi
else
    fail_test "Expected exit 2, got exit $HOOK_EXIT_CODE. Output: $HOOK_OUTPUT"
fi

# ---------------------------------------------------------------------------
# Test 2: verification-output.txt missing, test-output.txt present
#   → finalize_trace sets outcome="success" (test-output has "passed")
#   → Signal 1 does not fire (outcome=success after finalize)
#   → Signal 2 fires (no verification-output.txt)
#   → exit 2, INCOMPLETE
# ---------------------------------------------------------------------------
run_test "Check 3: missing verification-output.txt (test-output present) → exit 2 INCOMPLETE"

make_trace "no" "yes" "yes"
HOOK_OUTPUT="" ; HOOK_EXIT_CODE=0
run_check_tester "pending"
cleanup_trace

if [[ "$HOOK_EXIT_CODE" -eq 2 ]]; then
    if echo "$HOOK_OUTPUT" | grep -q "INCOMPLETE"; then
        pass_test
    else
        fail_test "exit 2 but INCOMPLETE directive missing. Got: $HOOK_OUTPUT"
    fi
else
    fail_test "Expected exit 2 for missing verification-output.txt, got exit $HOOK_EXIT_CODE"
fi

# ---------------------------------------------------------------------------
# Test 3: Complete tester — verification-output.txt + test-output.txt present
#   → finalize_trace sets outcome="success"
#   → Signal 1 does not fire
#   → Signal 2 does not fire (verification-output.txt present)
#   → exit 0, normal pending/manual flow
# ---------------------------------------------------------------------------
run_test "Check 3: complete trace (both artifacts present) → exit 0 normal flow"

make_trace "yes" "yes" "yes"
HOOK_OUTPUT="" ; HOOK_EXIT_CODE=0
run_check_tester "pending"
cleanup_trace

if [[ "$HOOK_EXIT_CODE" -eq 0 ]]; then
    if echo "$HOOK_OUTPUT" | grep -q "INCOMPLETE"; then
        fail_test "Complete tester incorrectly got INCOMPLETE directive. Output: $HOOK_OUTPUT"
    else
        pass_test
    fi
else
    fail_test "Expected exit 0 for complete trace, got exit $HOOK_EXIT_CODE. Output: $HOOK_OUTPUT"
fi

# ---------------------------------------------------------------------------
# Test 4: No active trace marker at all (TRACE_ID resolves empty)
#   → TRACE_DIR is empty, both signals skip
#   → exit 0, normal flow
# ---------------------------------------------------------------------------
run_test "Check 3: no active trace marker → skip completeness check, exit 0"

rm -f "$REAL_TRACE_STORE/.active-tester-$TEST_SESSION_ID"

HOOK_OUTPUT="" ; HOOK_EXIT_CODE=0
run_check_tester "pending"

if [[ "$HOOK_EXIT_CODE" -eq 0 ]]; then
    if echo "$HOOK_OUTPUT" | grep -q "INCOMPLETE"; then
        fail_test "Got INCOMPLETE when no active trace. Output: $HOOK_OUTPUT"
    else
        pass_test
    fi
else
    fail_test "Expected exit 0 with no active trace, got exit $HOOK_EXIT_CODE"
fi

# ---------------------------------------------------------------------------
# Test 5: INCOMPLETE directive content — must mention the outcome
#   Partial outcome (no artifacts): finalize writes "partial", message shows it
# ---------------------------------------------------------------------------
run_test "Check 3: INCOMPLETE directive includes trace outcome value"

make_trace "no" "no" "yes"
HOOK_OUTPUT="" ; HOOK_EXIT_CODE=0
run_check_tester "pending"
cleanup_trace

if [[ "$HOOK_EXIT_CODE" -eq 2 ]]; then
    # finalize_trace sets outcome="partial" when no test-output.txt
    if echo "$HOOK_OUTPUT" | grep -q "partial"; then
        pass_test
    else
        fail_test "INCOMPLETE directive missing outcome value. Got: $HOOK_OUTPUT"
    fi
else
    fail_test "Expected exit 2, got $HOOK_EXIT_CODE"
fi

# ---------------------------------------------------------------------------
# Test 6: Regression — verified proof-status still exits 0 even if trace is partial
#   A previously verified tester result should not be re-blocked by a stale partial trace.
#   (Check 3 runs BEFORE the proof-status decision gate, so if verified, it must
#   still pass through. But wait — Check 3 currently fires before proof-status
#   is examined. For verified status with a stale partial trace... we need to
#   verify the design: should completeness gate fire even when proof=verified?)
#   Design answer: yes — Check 3 is about the CURRENT tester run. If a new tester
#   run is partial but proof was previously verified by user, that's a config
#   issue outside this scope. Check 3 should fire regardless.
#   For this test: complete trace + pending → exit 0 (no regression in auto-verify path)
# ---------------------------------------------------------------------------
run_test "Regression: complete trace + pending proof → TESTER COMPLETE directive (not INCOMPLETE)"

make_trace "yes" "yes" "yes"
HOOK_OUTPUT="" ; HOOK_EXIT_CODE=0
run_check_tester "pending"
cleanup_trace

if [[ "$HOOK_EXIT_CODE" -eq 0 ]]; then
    if echo "$HOOK_OUTPUT" | grep -q "TESTER COMPLETE"; then
        pass_test
    else
        fail_test "Expected TESTER COMPLETE directive for complete trace. Got: $HOOK_OUTPUT"
    fi
else
    fail_test "Expected exit 0, got exit $HOOK_EXIT_CODE. Output: $HOOK_OUTPUT"
fi

# ---------------------------------------------------------------------------
# Test 7: Syntax check
# ---------------------------------------------------------------------------
run_test "Syntax: check-tester.sh is valid bash after modification"
if bash -n "$HOOKS_DIR/check-tester.sh" 2>/dev/null; then
    pass_test
else
    fail_test "check-tester.sh has syntax errors"
fi

# ---------------------------------------------------------------------------
# Cleanup: ensure no leftover marker
# ---------------------------------------------------------------------------
rm -f "$REAL_TRACE_STORE/.active-tester-$TEST_SESSION_ID"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n==========================================\n'
printf 'Test Results:\n'
printf '  Total:  %d\n' "$TESTS_RUN"
printf '  Passed: %d\n' "$TESTS_PASSED"
printf '  Failed: %d\n' "$TESTS_FAILED"
printf '==========================================\n'

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
else
    exit 0
fi
