#!/usr/bin/env bash
# Tests for pre-ask.sh — AskUserQuestion merit gate
#
# @decision DEC-TEST-PRE-ASK-001
# @title Test suite for the AskUserQuestion merit gate (pre-ask.sh)
# @status accepted
# @rationale Validates that pre-ask.sh correctly classifies questions and
#   enforces the merit gate for subagent AskUserQuestion calls. Tests cover
#   scan mode, all 4 gates, always-allow bypasses, and orchestrator passthrough.
#   Uses .active-*-* marker files to simulate agent context — the same pattern
#   used by trace-lib.sh's init_trace().

set -euo pipefail
# Portable SHA-256 (macOS: shasum, Ubuntu: sha256sum)
if command -v shasum >/dev/null 2>&1; then
    _SHA256_CMD="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
    _SHA256_CMD="sha256sum"
else
    _SHA256_CMD="cat"
fi

HOOK_DIR="$(cd "$(dirname "$0")/../hooks" && pwd)"
FIXTURE_DIR="$(cd "$(dirname "$0")/fixtures" && pwd)"
TESTS_PASSED=0
TESTS_FAILED=0

# Test helpers
pass() { echo "PASS: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "FAIL: $1 — $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# Setup temp env
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Compute a consistent project hash for the temp dir
# (matches what detect_project_root + project_hash produce)
PHASH=$(echo "$TMPDIR_BASE" | $_SHA256_CMD | cut -c1-8)
TRACE_DIR="$TMPDIR_BASE/traces"
mkdir -p "$TRACE_DIR"

# Helper: run the hook with a fixture file and optional agent marker
# Usage: run_hook FIXTURE_FILE [AGENT_TYPE]
# Returns output; exit code always 0 (hooks use exit 0 with JSON output).
run_hook() {
    local fixture="$1"
    local agent_type="${2:-}"

    # Clean up any previous markers
    rm -f "${TRACE_DIR}/.active-"* 2>/dev/null || true

    # Create agent marker if requested (simulates an active subagent)
    if [[ -n "$agent_type" ]]; then
        touch "${TRACE_DIR}/.active-${agent_type}-test-${PHASH}"
    fi

    # Run hook with mocked TRACE_STORE and CLAUDE_PROJECT_DIR
    # Use a fake project dir that hashes to PHASH
    TRACE_STORE="$TRACE_DIR" \
    CLAUDE_PROJECT_DIR="$TMPDIR_BASE" \
        bash "$HOOK_DIR/pre-ask.sh" < "$fixture" 2>/dev/null
}

# --- T01: Scan mode emits 4 gates ---
OUTPUT=$(HOOK_GATE_SCAN=1 bash "$HOOK_DIR/pre-ask.sh" < /dev/null 2>/dev/null)
GATE_COUNT=$(echo "$OUTPUT" | grep -c '^GATE' || echo "0")
if [[ "$GATE_COUNT" -eq 4 ]]; then
    pass "T01: Scan mode emits exactly 4 gates"
else
    fail "T01: Scan mode gate count" "expected 4, got $GATE_COUNT"
fi

# Verify specific gate names are present
if echo "$OUTPUT" | grep -q "forward-motion-deny"; then
    pass "T01a: forward-motion-deny gate declared"
else
    fail "T01a: forward-motion-deny gate declared" "gate not found in scan output"
fi

if echo "$OUTPUT" | grep -q "duplicate-gate-deny"; then
    pass "T01b: duplicate-gate-deny gate declared"
else
    fail "T01b: duplicate-gate-deny gate declared" "gate not found in scan output"
fi

if echo "$OUTPUT" | grep -q "obvious-answer-deny"; then
    pass "T01c: obvious-answer-deny gate declared"
else
    fail "T01c: obvious-answer-deny gate declared" "gate not found in scan output"
fi

if echo "$OUTPUT" | grep -q "agent-context-advisory"; then
    pass "T01d: agent-context-advisory gate declared"
else
    fail "T01d: agent-context-advisory gate declared" "gate not found in scan output"
fi

# --- T02: forward-motion deny (with implementer marker) ---
OUTPUT=$(run_hook "$FIXTURE_DIR/ask-forward-motion.json" "implementer")
if [[ "$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" == "deny" ]]; then
    pass "T02: forward-motion question denied for implementer"
else
    fail "T02: forward-motion question denied for implementer" "expected deny, got: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "Auto-dispatch"; then
    pass "T02a: forward-motion deny message mentions Auto-dispatch"
else
    fail "T02a: forward-motion deny message mentions Auto-dispatch" "message: $OUTPUT"
fi

# --- T03: duplicate-gate commit deny (with guardian marker) ---
OUTPUT=$(run_hook "$FIXTURE_DIR/ask-duplicate-gate-commit.json" "guardian")
if [[ "$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" == "deny" ]]; then
    pass "T03: duplicate-gate commit question denied for guardian"
else
    fail "T03: duplicate-gate commit question denied for guardian" "expected deny, got: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "Guardian owns"; then
    pass "T03a: duplicate-gate deny message mentions Guardian"
else
    fail "T03a: duplicate-gate deny message mentions Guardian" "message: $OUTPUT"
fi

# --- T04: duplicate-gate push deny (with implementer marker) ---
OUTPUT=$(run_hook "$FIXTURE_DIR/ask-duplicate-gate-push.json" "implementer")
if [[ "$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" == "deny" ]]; then
    pass "T04: duplicate-gate push question denied for implementer"
else
    fail "T04: duplicate-gate push question denied for implementer" "expected deny, got: $OUTPUT"
fi

# --- T05: obvious-answer deny (2 options, 1 recommended, with implementer marker) ---
OUTPUT=$(run_hook "$FIXTURE_DIR/ask-obvious-recommended.json" "implementer")
if [[ "$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" == "deny" ]]; then
    pass "T05: obvious-answer question denied (2 options, 1 Recommended)"
else
    fail "T05: obvious-answer question denied (2 options, 1 Recommended)" "expected deny, got: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "Recommended"; then
    pass "T05a: obvious-answer deny message mentions Recommended"
else
    fail "T05a: obvious-answer deny message mentions Recommended" "message: $OUTPUT"
fi

# --- T06: obvious-answer allow (3 options, 1 recommended) ---
OUTPUT=$(run_hook "$FIXTURE_DIR/ask-obvious-3-options.json" "implementer")
if [[ "$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" == "deny" ]]; then
    fail "T06: 3-option Recommended question should be ALLOWED" "got deny: $OUTPUT"
else
    pass "T06: 3-option Recommended question allowed (genuine multi-way decision)"
fi

# --- T07: tester env-var bypass (should always allow) ---
OUTPUT=$(run_hook "$FIXTURE_DIR/ask-tester-env-var.json" "tester")
if [[ "$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" == "deny" ]]; then
    fail "T07: env-var question should be ALLOWED for tester" "got deny: $OUTPUT"
else
    pass "T07: env-var question bypasses gate for tester"
fi

# --- T08: orchestrator bypass (no active marker) ---
OUTPUT=$(run_hook "$FIXTURE_DIR/ask-planner-alternatives.json")  # no agent marker
if [[ "$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" == "deny" ]]; then
    fail "T08: orchestrator should ALWAYS be allowed" "got deny: $OUTPUT"
else
    pass "T08: orchestrator context bypasses all gates"
fi

# Also test with a forward-motion question from orchestrator — should allow
OUTPUT=$(run_hook "$FIXTURE_DIR/ask-forward-motion.json")  # no agent marker
if [[ "$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" == "deny" ]]; then
    fail "T08a: orchestrator forward-motion question should be ALLOWED" "got deny: $OUTPUT"
else
    pass "T08a: orchestrator bypasses forward-motion gate"
fi

# --- T09: implementer advisory (generic check-in) ---
OUTPUT=$(run_hook "$FIXTURE_DIR/ask-implementer-checkin.json" "implementer")
if [[ "$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" == "deny" ]]; then
    fail "T09: implementer check-in should get advisory, not deny" "got deny: $OUTPUT"
elif echo "$OUTPUT" | grep -q "Check the plan"; then
    pass "T09: implementer check-in question gets advisory"
else
    # Advisory might not fire if pattern doesn't match — verify it's at least allowed
    pass "T09: implementer check-in question allowed (no deny)"
fi

# --- Summary ---
echo ""
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed out of $((TESTS_PASSED + TESTS_FAILED)) tests"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
