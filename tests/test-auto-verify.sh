#!/usr/bin/env bash
# Test auto-verify logic in check-tester.sh
#
# @decision DEC-TEST-AUTO-VERIFY-001
# @title Auto-verify test suite for check-tester.sh
# @status accepted
# @rationale Tests the auto-verify feature which bypasses manual approval for
#   clean e2e verifications (High confidence, full coverage, no caveats).
#   Validates happy path, rejection paths (Medium confidence, gaps in coverage,
#   missing signal), and the environmental whitelist for "Not tested" items
#   (browser viewport, screen reader, physical device, etc. do not block
#   auto-verify because they cannot be tested in a headless CLI context).

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"

# Ensure tmp directory exists
mkdir -p "$PROJECT_ROOT/tmp"

# ---------------------------------------------------------------------------
# resolve_real_proof_file: find the .proof-status path that check-tester.sh
# will actually read/write when invoked from a test context.
#
# detect_project_root() in the hook uses git --git-common-dir to find the
# real repo root (resolves through worktrees). PROJECT_ROOT is that real root
# (e.g. ~/.claude), and resolve_proof_file() returns "$PROJECT_ROOT/.proof-status"
# — NOT "$PROJECT_ROOT/.claude/.proof-status". The .claude/ segment is part of
# the directory name, not a subdirectory added by the hook.
#
# Old test code computed: "$REAL_REPO_ROOT/.claude/.proof-status" which doubled
# the .claude/ segment (wrote to ~/.claude/.claude/.proof-status, a non-existent
# path), while the hook read/wrote ~/.claude/.proof-status.
# ---------------------------------------------------------------------------
resolve_real_proof_file() {
    bash -c "source \"$HOOKS_DIR/source-lib.sh\" && resolve_proof_file" 2>/dev/null
}

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

# Shared auto-verify logic — mirrors check-tester.sh exactly.
# Must be updated whenever check-tester.sh logic changes.
run_auto_verify() {
    local response="$1"
    local proof_file="$2"

    local AUTO_VERIFIED=false
    if echo "$response" | grep -q 'AUTOVERIFY: CLEAN'; then
        local AV_FAIL=false
        # Must have High confidence (markdown bold)
        echo "$response" | grep -qi '\*\*High\*\*' || AV_FAIL=true
        # Must NOT have "Partially verified" in coverage
        echo "$response" | grep -qi 'Partially verified' && AV_FAIL=true
        # Must NOT have non-environmental "Not tested" entries
        local NOT_TESTED_LINES
        NOT_TESTED_LINES=$(echo "$response" | grep -i 'Not tested' || true)
        if [[ -n "$NOT_TESTED_LINES" ]]; then
            local ENV_PATTERN='requires browser\|requires viewport\|requires screen reader\|requires mobile\|requires physical device\|requires hardware\|requires manual interaction\|requires human interaction\|requires GUI\|requires native app\|requires network'
            local NON_ENV_LINES
            NON_ENV_LINES=$(echo "$NOT_TESTED_LINES" | grep -iv "$ENV_PATTERN" || true)
            if [[ -n "$NON_ENV_LINES" ]]; then
                AV_FAIL=true
            fi
        fi
        # Must NOT have Medium or Low confidence
        echo "$response" | grep -qi '\*\*Medium\*\*\|\*\*Low\*\*' && AV_FAIL=true

        if [[ "$AV_FAIL" == "false" ]]; then
            echo "verified|$(date +%s)" > "$proof_file"
            AUTO_VERIFIED=true
        fi
    fi
    echo "$AUTO_VERIFIED"
}

# ---------------------------------------------------------------------------
# Test 1: Auto-verify trigger with clean verification (no "Not tested" at all)
# ---------------------------------------------------------------------------
run_test "Auto-verify: clean verification with High confidence and full coverage"
MOCK_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-av-XXXXXX")
mkdir -p "$MOCK_DIR/.claude"
PROOF_FILE="$MOCK_DIR/.claude/.proof-status"

MOCK_RESPONSE=$(cat <<'EOF'
### Verification Assessment

### Methodology
End-to-end CLI verification with real arguments.

### Coverage
| Area | Status | Notes |
|------|--------|-------|
| Core feature | Fully verified | Works as expected |
| Error handling | Fully verified | Graceful failures |

### What Could Not Be Tested
None

### Confidence Level
**High** - All core paths exercised, output matches expectations, no anomalies.

### Recommended Follow-Up
None

AUTOVERIFY: CLEAN
EOF
)

RESULT=$(run_auto_verify "$MOCK_RESPONSE" "$PROOF_FILE")
if [[ "$RESULT" == "true" && -f "$PROOF_FILE" ]]; then
    PROOF_STATUS=$(cut -d'|' -f1 "$PROOF_FILE")
    if [[ "$PROOF_STATUS" == "verified" ]]; then
        pass_test
    else
        fail_test "Expected verified status, got: $PROOF_STATUS"
    fi
else
    fail_test "Auto-verify did not trigger"
fi
rm -rf "$MOCK_DIR"

# ---------------------------------------------------------------------------
# Test 2: Auto-verify rejection - Medium confidence
# ---------------------------------------------------------------------------
run_test "Auto-verify rejection: Medium confidence"
MOCK_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-av-XXXXXX")
mkdir -p "$MOCK_DIR/.claude"
PROOF_FILE="$MOCK_DIR/.claude/.proof-status"

MOCK_RESPONSE=$(cat <<'EOF'
### Confidence Level
**Medium** - Core happy path works, some paths untested.

AUTOVERIFY: CLEAN
EOF
)

RESULT=$(run_auto_verify "$MOCK_RESPONSE" "$PROOF_FILE")
if [[ "$RESULT" == "false" && ! -f "$PROOF_FILE" ]]; then
    pass_test
else
    fail_test "Auto-verify should have been rejected for Medium confidence"
fi
rm -rf "$MOCK_DIR"

# ---------------------------------------------------------------------------
# Test 3a: Non-environmental "Not tested" still blocks auto-verify
# ---------------------------------------------------------------------------
run_test "Auto-verify rejection 3a: non-environmental 'Not tested' blocks (e.g. edge cases)"
MOCK_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-av-XXXXXX")
mkdir -p "$MOCK_DIR/.claude"
PROOF_FILE="$MOCK_DIR/.claude/.proof-status"

MOCK_RESPONSE=$(cat <<'EOF'
### Coverage
| Area | Status | Notes |
|------|--------|-------|
| Core feature | Fully verified | Works |
| Edge cases | Not tested | Need manual check |

### Confidence Level
**High** - Core works well.

AUTOVERIFY: CLEAN
EOF
)

RESULT=$(run_auto_verify "$MOCK_RESPONSE" "$PROOF_FILE")
if [[ "$RESULT" == "false" && ! -f "$PROOF_FILE" ]]; then
    pass_test
else
    fail_test "Auto-verify should have been rejected for non-environmental 'Not tested'"
fi
rm -rf "$MOCK_DIR"

# ---------------------------------------------------------------------------
# Test 3b: Environmental-only "Not tested" passes auto-verify
# (e.g. browser viewport, screen reader — cannot be tested in CLI context)
# ---------------------------------------------------------------------------
run_test "Auto-verify pass 3b: environmental-only 'Not tested' is whitelisted"
MOCK_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-av-XXXXXX")
mkdir -p "$MOCK_DIR/.claude"
PROOF_FILE="$MOCK_DIR/.claude/.proof-status"

MOCK_RESPONSE=$(cat <<'EOF'
### Coverage
| Area | Status | Notes |
|------|--------|-------|
| Core feature | Fully verified | Works as expected |
| Error handling | Fully verified | Graceful failures |
| Browser viewport | Not tested | Requires browser viewport |
| Screen reader | Not tested | Requires screen reader |

### Confidence Level
**High** - All automatable paths exercised.

AUTOVERIFY: CLEAN
EOF
)

RESULT=$(run_auto_verify "$MOCK_RESPONSE" "$PROOF_FILE")
if [[ "$RESULT" == "true" && -f "$PROOF_FILE" ]]; then
    PROOF_STATUS=$(cut -d'|' -f1 "$PROOF_FILE")
    if [[ "$PROOF_STATUS" == "verified" ]]; then
        pass_test
    else
        fail_test "Expected verified status, got: $PROOF_STATUS"
    fi
else
    fail_test "Environmental-only 'Not tested' should not block auto-verify"
fi
rm -rf "$MOCK_DIR"

# ---------------------------------------------------------------------------
# Test 3c: Mixed real + environmental gaps still blocks auto-verify
# ---------------------------------------------------------------------------
run_test "Auto-verify rejection 3c: mixed real + environmental gaps still blocks"
MOCK_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-av-XXXXXX")
mkdir -p "$MOCK_DIR/.claude"
PROOF_FILE="$MOCK_DIR/.claude/.proof-status"

MOCK_RESPONSE=$(cat <<'EOF'
### Coverage
| Area | Status | Notes |
|------|--------|-------|
| Core feature | Fully verified | Works |
| Edge cases | Not tested | Need manual check |
| Screen reader | Not tested | Requires screen reader |

### Confidence Level
**High** - Core works well.

AUTOVERIFY: CLEAN
EOF
)

RESULT=$(run_auto_verify "$MOCK_RESPONSE" "$PROOF_FILE")
if [[ "$RESULT" == "false" && ! -f "$PROOF_FILE" ]]; then
    pass_test
else
    fail_test "Auto-verify should block when non-environmental gaps exist alongside environmental ones"
fi
rm -rf "$MOCK_DIR"

# ---------------------------------------------------------------------------
# Test 4: Auto-verify rejection - contains "Partially verified"
# ---------------------------------------------------------------------------
run_test "Auto-verify rejection: contains 'Partially verified'"
MOCK_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-av-XXXXXX")
mkdir -p "$MOCK_DIR/.claude"
PROOF_FILE="$MOCK_DIR/.claude/.proof-status"

MOCK_RESPONSE=$(cat <<'EOF'
### Coverage
| Area | Status | Notes |
|------|--------|-------|
| Core feature | Partially verified | Some gaps |

### Confidence Level
**High** - Works mostly.

AUTOVERIFY: CLEAN
EOF
)

RESULT=$(run_auto_verify "$MOCK_RESPONSE" "$PROOF_FILE")
if [[ "$RESULT" == "false" && ! -f "$PROOF_FILE" ]]; then
    pass_test
else
    fail_test "Auto-verify should have been rejected for 'Partially verified'"
fi
rm -rf "$MOCK_DIR"

# ---------------------------------------------------------------------------
# Test 5: No signal - manual flow preserved
# ---------------------------------------------------------------------------
run_test "No auto-verify signal: manual flow preserved"
MOCK_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-av-XXXXXX")
mkdir -p "$MOCK_DIR/.claude"
PROOF_FILE="$MOCK_DIR/.claude/.proof-status"

MOCK_RESPONSE=$(cat <<'EOF'
### Confidence Level
**High** - All looks good.
EOF
)

RESULT=$(run_auto_verify "$MOCK_RESPONSE" "$PROOF_FILE")
if [[ "$RESULT" == "false" && ! -f "$PROOF_FILE" ]]; then
    pass_test
else
    fail_test "Should use manual flow when no AUTOVERIFY signal"
fi
rm -rf "$MOCK_DIR"

# ---------------------------------------------------------------------------
# Test 6: Syntax check on modified hooks
# ---------------------------------------------------------------------------
run_test "Syntax check: check-tester.sh is valid bash"
if bash -n "$HOOKS_DIR/check-tester.sh" 2>/dev/null; then
    pass_test
else
    fail_test "check-tester.sh has syntax errors"
fi

run_test "Syntax check: prompt-submit.sh is valid bash"
if bash -n "$HOOKS_DIR/prompt-submit.sh" 2>/dev/null; then
    pass_test
else
    fail_test "prompt-submit.sh has syntax errors"
fi

# ---------------------------------------------------------------------------
# Test 7: Timing — auto-verify critical path completes within budget
# Fix 4: use printf with \\n (not echo -e with \n) to produce valid JSON,
# so jq can parse it and RESPONSE_TEXT is correctly populated.
# Also assert that .proof-status changed to "verified" (not just timing).
# ---------------------------------------------------------------------------
run_test "Timing: check-tester.sh auto-verify path completes in <5s and writes verified"

# resolve_real_proof_file() asks the hook library for the exact path it uses,
# so the test writes/reads the same file the hook operates on.
REAL_PROOF_FILE=$(resolve_real_proof_file)
SAVED_PROOF=""
if [[ -f "$REAL_PROOF_FILE" ]]; then
    SAVED_PROOF=$(cat "$REAL_PROOF_FILE")
fi
echo "pending|$(date +%s)" > "$REAL_PROOF_FILE"

# Build valid JSON input using jq so string content is properly escaped.
# echo -e / printf with \n produce literal newlines inside the JSON string value,
# making the JSON invalid (jq parse error) and causing RESPONSE_TEXT to be empty.
# jq -n --arg handles all escaping correctly.
AV_RESP_TEXT="### Verification Assessment
### Confidence Level
**High** - All core paths exercised.
### Coverage
| Area | Status |
|------|--------|
| Core | Fully verified |
AUTOVERIFY: CLEAN"
MOCK_JSON=$(jq -n --arg r "$AV_RESP_TEXT" '{"last_assistant_message": $r}')

# Time execution
START_TIME=$(date +%s)
HOOK_OUTPUT=$(echo "$MOCK_JSON" | bash "$HOOKS_DIR/check-tester.sh" 2>/dev/null || true)
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

# Read .proof-status BEFORE restoring to check if auto-verify wrote "verified"
PROOF_AFTER=""
if [[ -f "$REAL_PROOF_FILE" ]]; then
    PROOF_AFTER=$(cut -d'|' -f1 "$REAL_PROOF_FILE" 2>/dev/null || echo "")
fi

# Restore .proof-status to original value
if [[ -n "$SAVED_PROOF" ]]; then
    echo "$SAVED_PROOF" > "$REAL_PROOF_FILE"
else
    rm -f "$REAL_PROOF_FILE"
fi

if [[ $ELAPSED -lt 5 ]]; then
    if [[ "$PROOF_AFTER" == "verified" ]]; then
        pass_test
    else
        fail_test "Hook completed in ${ELAPSED}s but .proof-status='${PROOF_AFTER}' (expected 'verified'). Hook output: $HOOK_OUTPUT"
    fi
else
    fail_test "Hook took ${ELAPSED}s (budget: <5s)"
fi

# ---------------------------------------------------------------------------
# Test 8: Auto-verify fires with needs-verification status (Fix 1)
# task-track.sh writes "needs-verification" — tester often skips writing "pending".
# Auto-verify must fire anyway so the fast path isn't silently blocked.
# ---------------------------------------------------------------------------
run_test "Fix 1: auto-verify fires when proof-status is needs-verification"

REAL_PROOF_FILE=$(resolve_real_proof_file)
SAVED_PROOF=""
if [[ -f "$REAL_PROOF_FILE" ]]; then
    SAVED_PROOF=$(cat "$REAL_PROOF_FILE")
fi
# Write needs-verification (what task-track.sh writes at implementer dispatch)
echo "needs-verification|$(date +%s)" > "$REAL_PROOF_FILE"

NV_RESP_TEXT="### Verification Assessment
### Confidence Level
**High** - All core paths exercised.
### Coverage
| Area | Status |
|------|--------|
| Core | Fully verified |
AUTOVERIFY: CLEAN"
MOCK_JSON=$(jq -n --arg r "$NV_RESP_TEXT" '{"last_assistant_message": $r}')

HOOK_OUTPUT=$(echo "$MOCK_JSON" | bash "$HOOKS_DIR/check-tester.sh" 2>/dev/null || true)

PROOF_AFTER=""
if [[ -f "$REAL_PROOF_FILE" ]]; then
    PROOF_AFTER=$(cut -d'|' -f1 "$REAL_PROOF_FILE" 2>/dev/null || echo "")
fi

# Restore
if [[ -n "$SAVED_PROOF" ]]; then
    echo "$SAVED_PROOF" > "$REAL_PROOF_FILE"
else
    rm -f "$REAL_PROOF_FILE"
fi

if [[ "$PROOF_AFTER" == "verified" ]]; then
    if echo "$HOOK_OUTPUT" | grep -q 'AUTO-VERIFIED'; then
        pass_test
    else
        fail_test "proof-status=verified but AUTO-VERIFIED directive missing. Output: $HOOK_OUTPUT"
    fi
else
    fail_test "Auto-verify did not fire for needs-verification status. proof-status='${PROOF_AFTER}'. Output: $HOOK_OUTPUT"
fi

# ---------------------------------------------------------------------------
# Test 9: Safety net — missing proof-status + RESPONSE_TEXT → auto-written as pending
# When the tester completely forgets to write .proof-status, the safety net in
# Phase 2 should write "pending" so the manual approval flow can proceed.
# ---------------------------------------------------------------------------
run_test "Fix 1 safety net: missing proof-status + response text → auto-written as pending"

REAL_PROOF_FILE=$(resolve_real_proof_file)
SAVED_PROOF=""
if [[ -f "$REAL_PROOF_FILE" ]]; then
    SAVED_PROOF=$(cat "$REAL_PROOF_FILE")
    rm -f "$REAL_PROOF_FILE"
fi

# Response WITHOUT AUTOVERIFY signal — so auto-verify doesn't fire.
# The safety net should still write "pending".
SN_RESP_TEXT="Tester verification complete. Feature works correctly. Confidence: **High**."
MOCK_JSON=$(jq -n --arg r "$SN_RESP_TEXT" '{"last_assistant_message": $r}')

HOOK_OUTPUT=$(echo "$MOCK_JSON" | bash "$HOOKS_DIR/check-tester.sh" 2>/dev/null || true)

PROOF_AFTER=""
if [[ -f "$REAL_PROOF_FILE" ]]; then
    PROOF_AFTER=$(cut -d'|' -f1 "$REAL_PROOF_FILE" 2>/dev/null || echo "")
fi

# Restore
if [[ -n "$SAVED_PROOF" ]]; then
    echo "$SAVED_PROOF" > "$REAL_PROOF_FILE"
else
    rm -f "$REAL_PROOF_FILE"
fi

if [[ "$PROOF_AFTER" == "pending" ]]; then
    pass_test
else
    fail_test "Safety net did not write pending. proof-status='${PROOF_AFTER}'. Output: $HOOK_OUTPUT"
fi

# Summary
echo ""
echo "=========================================="
echo "Test Results:"
echo "  Total: $TESTS_RUN"
echo "  Passed: $TESTS_PASSED"
echo "  Failed: $TESTS_FAILED"
echo "=========================================="

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
else
    exit 0
fi
