#!/usr/bin/env bash
# Test auto-verify logic in check-tester.sh
#
# @decision DEC-TEST-AUTO-VERIFY-001
# @title Auto-verify test suite for check-tester.sh
# @status accepted
# @rationale Tests the auto-verify feature which bypasses manual approval for
#   clean e2e verifications (High confidence, full coverage, no caveats).
#   Validates both the happy path (signal triggers) and rejection paths
#   (Medium confidence, gaps in coverage, missing signal).

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"

# Ensure tmp directory exists
mkdir -p "$PROJECT_ROOT/tmp"

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
    echo "  ✓ PASS"
}

fail_test() {
    local reason="$1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  ✗ FAIL: $reason"
}

# Test 1: Auto-verify trigger with clean verification
run_test "Auto-verify: clean verification with High confidence and full coverage"
MOCK_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-av-XXXXXX")
mkdir -p "$MOCK_DIR/.claude"
PROOF_FILE="$MOCK_DIR/.claude/.proof-status"

# Create mock response with auto-verify signal
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

# Simulate the auto-verify logic (extracted from check-tester.sh)
AUTO_VERIFIED=false
if echo "$MOCK_RESPONSE" | grep -q 'AUTOVERIFY: CLEAN'; then
    AV_FAIL=false
    echo "$MOCK_RESPONSE" | grep -qi '\*\*High\*\*' || AV_FAIL=true
    echo "$MOCK_RESPONSE" | grep -qi 'Not tested\|Partially verified' && AV_FAIL=true
    echo "$MOCK_RESPONSE" | grep -qi '\*\*Medium\*\*\|\*\*Low\*\*' && AV_FAIL=true

    if [[ "$AV_FAIL" == "false" ]]; then
        echo "verified|$(date +%s)" > "$PROOF_FILE"
        AUTO_VERIFIED=true
    fi
fi

if [[ "$AUTO_VERIFIED" == "true" && -f "$PROOF_FILE" ]]; then
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

# Test 2: Auto-verify rejection - Medium confidence
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

AUTO_VERIFIED=false
if echo "$MOCK_RESPONSE" | grep -q 'AUTOVERIFY: CLEAN'; then
    AV_FAIL=false
    echo "$MOCK_RESPONSE" | grep -qi '\*\*High\*\*' || AV_FAIL=true
    echo "$MOCK_RESPONSE" | grep -qi 'Not tested\|Partially verified' && AV_FAIL=true
    echo "$MOCK_RESPONSE" | grep -qi '\*\*Medium\*\*\|\*\*Low\*\*' && AV_FAIL=true

    if [[ "$AV_FAIL" == "false" ]]; then
        echo "verified|$(date +%s)" > "$PROOF_FILE"
        AUTO_VERIFIED=true
    fi
fi

if [[ "$AUTO_VERIFIED" == "false" && ! -f "$PROOF_FILE" ]]; then
    pass_test
else
    fail_test "Auto-verify should have been rejected for Medium confidence"
fi
rm -rf "$MOCK_DIR"

# Test 3: Auto-verify rejection - contains "Not tested"
run_test "Auto-verify rejection: contains 'Not tested' in coverage"
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

AUTO_VERIFIED=false
if echo "$MOCK_RESPONSE" | grep -q 'AUTOVERIFY: CLEAN'; then
    AV_FAIL=false
    echo "$MOCK_RESPONSE" | grep -qi '\*\*High\*\*' || AV_FAIL=true
    echo "$MOCK_RESPONSE" | grep -qi 'Not tested\|Partially verified' && AV_FAIL=true
    echo "$MOCK_RESPONSE" | grep -qi '\*\*Medium\*\*\|\*\*Low\*\*' && AV_FAIL=true

    if [[ "$AV_FAIL" == "false" ]]; then
        echo "verified|$(date +%s)" > "$PROOF_FILE"
        AUTO_VERIFIED=true
    fi
fi

if [[ "$AUTO_VERIFIED" == "false" && ! -f "$PROOF_FILE" ]]; then
    pass_test
else
    fail_test "Auto-verify should have been rejected for 'Not tested'"
fi
rm -rf "$MOCK_DIR"

# Test 4: Auto-verify rejection - contains "Partially verified"
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

AUTO_VERIFIED=false
if echo "$MOCK_RESPONSE" | grep -q 'AUTOVERIFY: CLEAN'; then
    AV_FAIL=false
    echo "$MOCK_RESPONSE" | grep -qi '\*\*High\*\*' || AV_FAIL=true
    echo "$MOCK_RESPONSE" | grep -qi 'Not tested\|Partially verified' && AV_FAIL=true
    echo "$MOCK_RESPONSE" | grep -qi '\*\*Medium\*\*\|\*\*Low\*\*' && AV_FAIL=true

    if [[ "$AV_FAIL" == "false" ]]; then
        echo "verified|$(date +%s)" > "$PROOF_FILE"
        AUTO_VERIFIED=true
    fi
fi

if [[ "$AUTO_VERIFIED" == "false" && ! -f "$PROOF_FILE" ]]; then
    pass_test
else
    fail_test "Auto-verify should have been rejected for 'Partially verified'"
fi
rm -rf "$MOCK_DIR"

# Test 5: No signal - manual flow
run_test "No auto-verify signal: manual flow preserved"
MOCK_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-av-XXXXXX")
mkdir -p "$MOCK_DIR/.claude"
PROOF_FILE="$MOCK_DIR/.claude/.proof-status"

MOCK_RESPONSE=$(cat <<'EOF'
### Confidence Level
**High** - All looks good.
EOF
)

AUTO_VERIFIED=false
if echo "$MOCK_RESPONSE" | grep -q 'AUTOVERIFY: CLEAN'; then
    AV_FAIL=false
    echo "$MOCK_RESPONSE" | grep -qi '\*\*High\*\*' || AV_FAIL=true
    echo "$MOCK_RESPONSE" | grep -qi 'Not tested\|Partially verified' && AV_FAIL=true
    echo "$MOCK_RESPONSE" | grep -qi '\*\*Medium\*\*\|\*\*Low\*\*' && AV_FAIL=true

    if [[ "$AV_FAIL" == "false" ]]; then
        echo "verified|$(date +%s)" > "$PROOF_FILE"
        AUTO_VERIFIED=true
    fi
fi

if [[ "$AUTO_VERIFIED" == "false" && ! -f "$PROOF_FILE" ]]; then
    pass_test
else
    fail_test "Should use manual flow when no AUTOVERIFY signal"
fi
rm -rf "$MOCK_DIR"

# Test 6: Syntax check on modified hook
run_test "Syntax check: check-tester.sh is valid bash"
if bash -n "$HOOKS_DIR/check-tester.sh" 2>/dev/null; then
    pass_test
else
    fail_test "check-tester.sh has syntax errors"
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
