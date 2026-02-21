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

# Also clear the legacy .proof-status so the backward-compat fallback in
# resolve_proof_file() doesn't return a stale "verified" from a prior test.
# DEC-ISOLATION-001: resolve_proof_file() falls back to .proof-status when no
# scoped file exists — the dedup guard in check-tester.sh would fire on it.
_LEGACY_PROOF="$(dirname "$REAL_PROOF_FILE")/.proof-status"
_SAVED_LEGACY=""
if [[ -f "$_LEGACY_PROOF" ]]; then
    _SAVED_LEGACY=$(cat "$_LEGACY_PROOF")
    rm -f "$_LEGACY_PROOF"
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

# Restore scoped file
if [[ -n "$SAVED_PROOF" ]]; then
    echo "$SAVED_PROOF" > "$REAL_PROOF_FILE"
else
    rm -f "$REAL_PROOF_FILE"
fi
# Restore legacy file
if [[ -n "$_SAVED_LEGACY" ]]; then
    echo "$_SAVED_LEGACY" > "$_LEGACY_PROOF"
else
    rm -f "$_LEGACY_PROOF"
fi

if [[ "$PROOF_AFTER" == "pending" ]]; then
    pass_test
else
    fail_test "Safety net did not write pending. proof-status='${PROOF_AFTER}'. Output: $HOOK_OUTPUT"
fi

# ---------------------------------------------------------------------------
# Test 10: Dedup guard — second SubagentStop with already-verified proof-status
# does NOT add another auto_verify audit entry. (Fix #124)
#
# Simulates: tester stops (first SubagentStop auto-verifies, writes verified),
# tester is resumed and stops again (second SubagentStop fires check-tester.sh).
# The second run must exit 0 without appending to the audit log.
# ---------------------------------------------------------------------------
run_test "Fix #124 dedup: second SubagentStop with verified proof-status skips audit"

REAL_PROOF_FILE=$(resolve_real_proof_file)
SAVED_PROOF=""
if [[ -f "$REAL_PROOF_FILE" ]]; then
    SAVED_PROOF=$(cat "$REAL_PROOF_FILE")
fi

# Determine audit log path the same way context-lib.sh does:
# append_audit writes to "$root/.claude/.audit-log" where root = detect_project_root().
AUDIT_LOG="$(bash -c "source \"$HOOKS_DIR/source-lib.sh\" && detect_project_root" 2>/dev/null)/.claude/.audit-log"

# Record audit log auto_verify line count before the test
AUDIT_BEFORE=0
if [[ -f "$AUDIT_LOG" ]]; then
    AUDIT_BEFORE=$(grep -c "auto_verify" "$AUDIT_LOG" 2>/dev/null || echo "0")
fi

# Write "verified" to simulate that a previous SubagentStop already auto-verified
echo "verified|$(date +%s)" > "$REAL_PROOF_FILE"

# Build a clean AUTOVERIFY response (would trigger auto-verify if dedup guard absent)
DEDUP_RESP_TEXT="### Verification Assessment
### Confidence Level
**High** - All core paths exercised.
### Coverage
| Area | Status |
|------|--------|
| Core | Fully verified |
AUTOVERIFY: CLEAN"
MOCK_JSON=$(jq -n --arg r "$DEDUP_RESP_TEXT" '{"last_assistant_message": $r}')

HOOK_OUTPUT=$(echo "$MOCK_JSON" | bash "$HOOKS_DIR/check-tester.sh" 2>/dev/null || true)

# Count auto_verify entries after the second run
AUDIT_AFTER=0
if [[ -f "$AUDIT_LOG" ]]; then
    AUDIT_AFTER=$(grep -c "auto_verify" "$AUDIT_LOG" 2>/dev/null || echo "0")
fi

# Restore proof-status
if [[ -n "$SAVED_PROOF" ]]; then
    echo "$SAVED_PROOF" > "$REAL_PROOF_FILE"
else
    rm -f "$REAL_PROOF_FILE"
fi

# Verify: audit log count must not have increased (dedup guard fired)
if [[ "$AUDIT_AFTER" -eq "$AUDIT_BEFORE" ]]; then
    pass_test
else
    NEW_ENTRIES=$((AUDIT_AFTER - AUDIT_BEFORE))
    fail_test "Dedup guard failed: ${NEW_ENTRIES} new auto_verify audit entry/entries added on second SubagentStop. Output: $HOOK_OUTPUT"
fi

# ---------------------------------------------------------------------------
# Test 11: Dedup guard — hook output for already-verified contains Guardian directive
# The early-exit must still produce valid JSON with Guardian unblocked message.
# ---------------------------------------------------------------------------
run_test "Fix #124 dedup: already-verified early exit emits valid JSON with Guardian directive"

REAL_PROOF_FILE=$(resolve_real_proof_file)
SAVED_PROOF=""
if [[ -f "$REAL_PROOF_FILE" ]]; then
    SAVED_PROOF=$(cat "$REAL_PROOF_FILE")
fi

echo "verified|$(date +%s)" > "$REAL_PROOF_FILE"

MOCK_JSON=$(jq -n --arg r "any response" '{"last_assistant_message": $r}')
HOOK_OUTPUT=$(echo "$MOCK_JSON" | bash "$HOOKS_DIR/check-tester.sh" 2>/dev/null || true)

# Restore
if [[ -n "$SAVED_PROOF" ]]; then
    echo "$SAVED_PROOF" > "$REAL_PROOF_FILE"
else
    rm -f "$REAL_PROOF_FILE"
fi

# Must produce valid JSON
if echo "$HOOK_OUTPUT" | jq -e '.additionalContext' >/dev/null 2>&1; then
    # Must contain Guardian unblocked signal
    if echo "$HOOK_OUTPUT" | jq -r '.additionalContext' | grep -q 'Guardian dispatch is unblocked'; then
        pass_test
    else
        fail_test "additionalContext exists but missing Guardian directive. Output: $HOOK_OUTPUT"
    fi
else
    fail_test "Hook output is not valid JSON with additionalContext. Output: $HOOK_OUTPUT"
fi

# ---------------------------------------------------------------------------
# Test 12: Diagnostic logging — stderr contains RESPONSE_TEXT length line
# W6-1 (DEC-V3-001, Issue #129): Check that the diagnostic logging block in
# check-tester.sh emits the expected stderr output on every tester stop.
# Verifies: "check-tester: RESPONSE_TEXT length=N" appears in stderr.
# ---------------------------------------------------------------------------
run_test "W6-1 diagnostic: RESPONSE_TEXT length appears in stderr"

REAL_PROOF_FILE=$(resolve_real_proof_file)
SAVED_PROOF=""
if [[ -f "$REAL_PROOF_FILE" ]]; then
    SAVED_PROOF=$(cat "$REAL_PROOF_FILE")
fi
echo "pending|$(date +%s)" > "$REAL_PROOF_FILE"

DIAG_RESP_TEXT="### Verification Assessment
### Confidence Level
**High** - All paths exercised.
AUTOVERIFY: CLEAN"
MOCK_JSON=$(jq -n --arg r "$DIAG_RESP_TEXT" '{"last_assistant_message": $r}')

# Capture stderr (diagnostic output) separately from stdout (JSON output)
HOOK_STDERR=$(echo "$MOCK_JSON" | bash "$HOOKS_DIR/check-tester.sh" 2>&1 1>/dev/null || true)

# Restore
if [[ -n "$SAVED_PROOF" ]]; then
    echo "$SAVED_PROOF" > "$REAL_PROOF_FILE"
else
    rm -f "$REAL_PROOF_FILE"
fi

# Verify diagnostic logging fired
if echo "$HOOK_STDERR" | grep -q 'check-tester: RESPONSE_TEXT length='; then
    pass_test
else
    fail_test "Expected 'check-tester: RESPONSE_TEXT length=' in stderr. Got: $HOOK_STDERR"
fi

# ---------------------------------------------------------------------------
# Test 13: Diagnostic logging — AUTOVERIFY signal count appears in stderr
# When AUTOVERIFY: CLEAN is present, the diagnostic block must log the signal
# count and secondary validation results.
# ---------------------------------------------------------------------------
run_test "W6-1 diagnostic: AUTOVERIFY signal count and secondary validation in stderr"

REAL_PROOF_FILE=$(resolve_real_proof_file)
SAVED_PROOF=""
if [[ -f "$REAL_PROOF_FILE" ]]; then
    SAVED_PROOF=$(cat "$REAL_PROOF_FILE")
fi
echo "pending|$(date +%s)" > "$REAL_PROOF_FILE"

DIAG_RESP_TEXT2="### Confidence Level
**High** - All paths exercised.
### Coverage
| Area | Status |
|------|--------|
| Core | Fully verified |
AUTOVERIFY: CLEAN"
MOCK_JSON2=$(jq -n --arg r "$DIAG_RESP_TEXT2" '{"last_assistant_message": $r}')

HOOK_STDERR2=$(echo "$MOCK_JSON2" | bash "$HOOKS_DIR/check-tester.sh" 2>&1 1>/dev/null || true)

# Restore
if [[ -n "$SAVED_PROOF" ]]; then
    echo "$SAVED_PROOF" > "$REAL_PROOF_FILE"
else
    rm -f "$REAL_PROOF_FILE"
fi

# Should log signal count=1 and secondary validation
if echo "$HOOK_STDERR2" | grep -q 'AUTOVERIFY signal count=1'; then
    if echo "$HOOK_STDERR2" | grep -q 'secondary validation:'; then
        pass_test
    else
        fail_test "Signal count found but secondary validation missing in stderr. Got: $HOOK_STDERR2"
    fi
else
    fail_test "Expected 'AUTOVERIFY signal count=1' in stderr. Got: $HOOK_STDERR2"
fi

# ---------------------------------------------------------------------------
# Test 14: Diagnostic logging — empty RESPONSE_TEXT emits WARNING line
# When last_assistant_message is empty (empty JSON object), the diagnostic
# block must emit the WARNING line with payload keys.
# ---------------------------------------------------------------------------
run_test "W6-1 diagnostic: empty RESPONSE_TEXT emits WARNING in stderr"

REAL_PROOF_FILE=$(resolve_real_proof_file)
SAVED_PROOF=""
if [[ -f "$REAL_PROOF_FILE" ]]; then
    SAVED_PROOF=$(cat "$REAL_PROOF_FILE")
fi
echo "pending|$(date +%s)" > "$REAL_PROOF_FILE"

# Empty last_assistant_message — jq returns empty string for null/missing
MOCK_JSON_EMPTY=$(jq -n '{"last_assistant_message": ""}')

HOOK_STDERR_EMPTY=$(echo "$MOCK_JSON_EMPTY" | bash "$HOOKS_DIR/check-tester.sh" 2>&1 1>/dev/null || true)

# Restore
if [[ -n "$SAVED_PROOF" ]]; then
    echo "$SAVED_PROOF" > "$REAL_PROOF_FILE"
else
    rm -f "$REAL_PROOF_FILE"
fi

if echo "$HOOK_STDERR_EMPTY" | grep -q 'check-tester: WARNING'; then
    pass_test
else
    fail_test "Expected 'check-tester: WARNING' in stderr for empty response. Got: $HOOK_STDERR_EMPTY"
fi

# ---------------------------------------------------------------------------
# Test 15: W6-2 summary.md fallback — AUTOVERIFY found via trace summary.md
# When last_assistant_message is empty but the active trace's summary.md
# contains AUTOVERIFY: CLEAN, the fallback supplements RESPONSE_TEXT and
# auto-verify fires.
# ---------------------------------------------------------------------------
run_test "W6-2 summary.md fallback: auto-verify fires when signal is in summary.md only"

REAL_PROOF_FILE=$(resolve_real_proof_file)
SAVED_PROOF=""
if [[ -f "$REAL_PROOF_FILE" ]]; then
    SAVED_PROOF=$(cat "$REAL_PROOF_FILE")
fi
echo "pending|$(date +%s)" > "$REAL_PROOF_FILE"

# Create a fake active trace with summary.md containing AUTOVERIFY: CLEAN
TRACE_STORE_PATH="${TRACE_STORE:-$HOME/.claude/traces}"
FAKE_TRACE_ID="tester-$(date +%Y%m%d-%H%M%S)-test15"
FAKE_TRACE_DIR="${TRACE_STORE_PATH}/${FAKE_TRACE_ID}"
mkdir -p "${FAKE_TRACE_DIR}/artifacts"

# Write summary.md with AUTOVERIFY: CLEAN signal
cat > "${FAKE_TRACE_DIR}/summary.md" <<'SUMMARY_EOF'
### Verification Assessment
### Confidence Level
**High** - All core paths exercised.
### Coverage
| Area | Status |
|------|--------|
| Core | Fully verified |

AUTOVERIFY: CLEAN
SUMMARY_EOF

# Resolve the PROJECT_ROOT that check-tester.sh will compute (via detect_project_root →
# git rev-parse --show-toplevel). From a worktree CWD, --show-toplevel returns the worktree
# path (not the main repo root), which is exactly what CLAUDE_PROJECT_DIR=unset detect_project_root()
# returns. The manifest.project and phash must match this value for tier-1/tier-2 detection.
T15_PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PROJECT_ROOT")
T15_PROJECT_ROOT="${T15_PROJECT_ROOT%/}"

# Write a basic manifest so detect_active_trace can find this trace.
# The "project" field must match the PROJECT_ROOT check-tester.sh will compute —
# otherwise the tier-2 validation in detect_active_trace rejects this marker.
SESSION_ID_FOR_TEST="${CLAUDE_SESSION_ID:-test-session-$$}"
cat > "${FAKE_TRACE_DIR}/manifest.json" <<MANIFEST_EOF
{"version":"1","trace_id":"${FAKE_TRACE_ID}","agent_type":"tester","session_id":"${SESSION_ID_FOR_TEST}","project":"${T15_PROJECT_ROOT}","status":"active","started_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
MANIFEST_EOF

# Create BOTH the scoped and old-format active markers.
# detect_active_trace() tier-1 checks the scoped marker (.active-tester-{session}-{phash});
# tier-2 checks the old-format marker and validates manifest.project.
# Creating both ensures the test works whether tier-1 or tier-2 succeeds first.
_T15_PHASH=$(echo "$T15_PROJECT_ROOT" | shasum -a 256 | cut -c1-8)
ACTIVE_MARKER="${TRACE_STORE_PATH}/.active-tester-${SESSION_ID_FOR_TEST}"
SCOPED_MARKER="${TRACE_STORE_PATH}/.active-tester-${SESSION_ID_FOR_TEST}-${_T15_PHASH}"
echo "$FAKE_TRACE_ID" > "$ACTIVE_MARKER"
echo "$FAKE_TRACE_ID" > "$SCOPED_MARKER"

# Empty last_assistant_message — should trigger fallback to summary.md
MOCK_JSON_FALLBACK=$(jq -n '{"last_assistant_message": ""}')

# Single run capturing stdout and stderr to separate temp files (avoids running hook twice
# which would consume the active marker on the first run, breaking the second).
_T15_STDOUT=$(mktemp "$PROJECT_ROOT/tmp/test-av-t15-XXXXXX")
_T15_STDERR=$(mktemp "$PROJECT_ROOT/tmp/test-av-t15-XXXXXX")
echo "$MOCK_JSON_FALLBACK" | bash "$HOOKS_DIR/check-tester.sh" >"$_T15_STDOUT" 2>"$_T15_STDERR" || true
HOOK_OUTPUT_FB=$(cat "$_T15_STDOUT")
HOOK_STDERR_FB=$(cat "$_T15_STDERR")
rm -f "$_T15_STDOUT" "$_T15_STDERR"

# Clean up fake trace and both markers (may already be gone if finalize_trace ran)
rm -f "$ACTIVE_MARKER" "$SCOPED_MARKER"
rm -rf "$FAKE_TRACE_DIR"

# Read proof status
PROOF_AFTER_FB=""
if [[ -f "$REAL_PROOF_FILE" ]]; then
    PROOF_AFTER_FB=$(cut -d'|' -f1 "$REAL_PROOF_FILE" 2>/dev/null || echo "")
fi

# Restore
if [[ -n "$SAVED_PROOF" ]]; then
    echo "$SAVED_PROOF" > "$REAL_PROOF_FILE"
else
    rm -f "$REAL_PROOF_FILE"
fi

# Check: auto-verify should have fired (proof=verified) and supplementing log should be in stderr
if [[ "$PROOF_AFTER_FB" == "verified" ]]; then
    if echo "$HOOK_STDERR_FB" | grep -q 'supplementing RESPONSE_TEXT from summary.md'; then
        if echo "$HOOK_OUTPUT_FB" | grep -q 'AUTO-VERIFIED'; then
            pass_test
        else
            fail_test "proof=verified and supplement logged but AUTO-VERIFIED missing from output. Output: $HOOK_OUTPUT_FB"
        fi
    else
        fail_test "proof=verified but supplement log missing. stderr: $HOOK_STDERR_FB"
    fi
else
    fail_test "Auto-verify did not fire via summary.md fallback. proof='${PROOF_AFTER_FB}'. stderr: $HOOK_STDERR_FB output: $HOOK_OUTPUT_FB"
fi

# ---------------------------------------------------------------------------
# Test 16: W6-2 fallback does NOT fire when last_assistant_message has signal
# When last_assistant_message already contains AUTOVERIFY: CLEAN, the fallback
# block must not run (no "supplementing" log entry).
# ---------------------------------------------------------------------------
run_test "W6-2 fallback: not triggered when signal already in last_assistant_message"

REAL_PROOF_FILE=$(resolve_real_proof_file)
SAVED_PROOF=""
if [[ -f "$REAL_PROOF_FILE" ]]; then
    SAVED_PROOF=$(cat "$REAL_PROOF_FILE")
fi
echo "pending|$(date +%s)" > "$REAL_PROOF_FILE"

NO_FALLBACK_TEXT="### Confidence Level
**High** - All paths exercised.
### Coverage
| Area | Status |
|------|--------|
| Core | Fully verified |
AUTOVERIFY: CLEAN"
MOCK_JSON_NF=$(jq -n --arg r "$NO_FALLBACK_TEXT" '{"last_assistant_message": $r}')

HOOK_STDERR_NF=$(echo "$MOCK_JSON_NF" | bash "$HOOKS_DIR/check-tester.sh" 2>&1 1>/dev/null || true)

# Restore
if [[ -n "$SAVED_PROOF" ]]; then
    echo "$SAVED_PROOF" > "$REAL_PROOF_FILE"
else
    rm -f "$REAL_PROOF_FILE"
fi

# Supplementing log must NOT appear
if echo "$HOOK_STDERR_NF" | grep -q 'supplementing RESPONSE_TEXT from summary.md'; then
    fail_test "Fallback triggered unnecessarily when signal was already present. stderr: $HOOK_STDERR_NF"
else
    pass_test
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
