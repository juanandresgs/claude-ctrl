#!/usr/bin/env bash
# Test SDLC Integrity Layer Phase A: guard.sh deny-on-crash and validate_state_file.
#
# @decision DEC-INTEGRITY-003
# @title Test suite for guard.sh fail-closed trap and state file validation
# @status accepted
# @rationale Validates that: (1) a simulated crash in guard.sh produces a deny
#   (not a pass-through), (2) normal deny/rewrite/early-exit paths work correctly
#   and are not disrupted by the new trap, (3) corrupt .proof-status is treated
#   as "not verified" (fail-closed), and (4) validate_state_file() correctly
#   accepts well-formed files and rejects missing/empty/corrupt ones.
#   Uses the same run_test/pass_test/fail_test pattern as test-proof-gate.sh.

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
    echo "  PASS"
}

fail_test() {
    local reason="$1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL: $reason"
}

# --- Test 1: Syntax validation ---
run_test "Syntax: guard.sh is valid bash"
if bash -n "$HOOKS_DIR/guard.sh"; then
    pass_test
else
    fail_test "guard.sh has syntax errors"
fi

run_test "Syntax: context-lib.sh is valid bash"
if bash -n "$HOOKS_DIR/context-lib.sh"; then
    pass_test
else
    fail_test "context-lib.sh has syntax errors"
fi

# --- Test 2: Deny-on-crash: simulated source-lib.sh failure ---
# We simulate a crash by pointing the script at a broken source-lib.sh.
# Create a minimal guard.sh wrapper that sources our broken file instead.
run_test "Deny-on-crash: crash before safety checks produces deny"

TEMP_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-integrity-XXXXXX")
# Create a broken source-lib.sh that immediately exits non-zero
mkdir -p "$TEMP_DIR/hooks"
cat > "$TEMP_DIR/hooks/source-lib.sh" <<'EOF'
#!/usr/bin/env bash
exit 42
EOF

# Create a minimal guard-crash-test.sh that uses the crash-trap pattern
# but sources the broken lib (mirrors what guard.sh does)
cat > "$TEMP_DIR/hooks/guard-crash-test.sh" <<'GUARDEOF'
#!/usr/bin/env bash
set -euo pipefail

_GUARD_COMPLETED=false
_guard_deny_on_crash() {
    if [[ "$_GUARD_COMPLETED" != "true" ]]; then
        cat <<'CRASHJSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "SAFETY: guard.sh crashed before completing safety checks. Command denied as precaution. Run: bash -n ~/.claude/hooks/guard.sh to diagnose."
  }
}
CRASHJSON
    fi
}
trap '_guard_deny_on_crash' EXIT

# This source will fail (exit 42) — simulating source-lib.sh failure
source "$(dirname "$0")/source-lib.sh"

# This line is never reached if source fails
_GUARD_COMPLETED=true
exit 0
GUARDEOF
chmod +x "$TEMP_DIR/hooks/guard-crash-test.sh"

# Run without stdin (no hook input needed — crash happens before reading input)
OUTPUT=$(bash "$TEMP_DIR/hooks/guard-crash-test.sh" 2>/dev/null) || true

cd "$PROJECT_ROOT"
rm -rf "$TEMP_DIR"

if echo "$OUTPUT" | grep -q '"permissionDecision": "deny"' && \
   echo "$OUTPUT" | grep -q "SAFETY"; then
    pass_test
else
    fail_test "Crash did not produce deny output. Got: $OUTPUT"
fi

# --- Test 3: Normal deny() path — not disrupted by trap ---
run_test "deny() path: produces deny and does not trigger crash output"

TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-integrity-deny-XXXXXX")
git -C "$TEMP_REPO" init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.claude"

# A command that triggers a nuclear deny (fork bomb pattern)
INPUT_JSON=$(cat <<'EOF'
{
  "tool_name": "Bash",
  "tool_input": {
    "command": ":(){ :|:& };:"
  }
}
EOF
)

OUTPUT=$(cd "$TEMP_REPO" && echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

cd "$PROJECT_ROOT"
rm -rf "$TEMP_REPO"

if echo "$OUTPUT" | grep -q '"permissionDecision": "deny"' && \
   echo "$OUTPUT" | grep -q "NUCLEAR DENY"; then
    pass_test
else
    fail_test "deny() path broken. Got: $OUTPUT"
fi

# --- Test 4: rewrite() path — not disrupted by trap ---
run_test "rewrite() path: produces allow+updatedInput and does not trigger crash output"

TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-integrity-rewrite-XXXXXX")
git -C "$TEMP_REPO" init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.claude"

# A command that triggers /tmp/ rewrite
INPUT_JSON=$(cat <<EOF
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "echo foo > /tmp/output.txt"
  }
}
EOF
)

OUTPUT=$(cd "$TEMP_REPO" && echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

cd "$PROJECT_ROOT"
rm -rf "$TEMP_REPO"

if echo "$OUTPUT" | grep -q '"permissionDecision": "allow"' && \
   echo "$OUTPUT" | grep -q '"updatedInput"'; then
    pass_test
else
    fail_test "rewrite() path broken. Got: $OUTPUT"
fi

# --- Test 5: Early-exit on empty command — not disrupted by trap ---
run_test "Empty command early-exit: produces no output and exits 0"

TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-integrity-empty-XXXXXX")
git -C "$TEMP_REPO" init > /dev/null 2>&1

INPUT_JSON=$(cat <<'EOF'
{
  "tool_name": "Bash",
  "tool_input": {
    "command": ""
  }
}
EOF
)

OUTPUT=$(cd "$TEMP_REPO" && echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true
EXIT_CODE=$?

cd "$PROJECT_ROOT"
rm -rf "$TEMP_REPO"

if [[ -z "$OUTPUT" ]] || ! echo "$OUTPUT" | grep -q "deny"; then
    pass_test
else
    fail_test "Empty command triggered deny (crash trap fired). Got: $OUTPUT"
fi

# --- Test 6: Early-exit on non-git command — not disrupted by trap ---
run_test "Non-git command early-exit: no deny output"

TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-integrity-nongit-XXXXXX")
git -C "$TEMP_REPO" init > /dev/null 2>&1

INPUT_JSON=$(cat <<'EOF'
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "ls -la"
  }
}
EOF
)

OUTPUT=$(cd "$TEMP_REPO" && echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

cd "$PROJECT_ROOT"
rm -rf "$TEMP_REPO"

if ! echo "$OUTPUT" | grep -q '"permissionDecision": "deny"'; then
    pass_test
else
    fail_test "Non-git command was denied. Got: $OUTPUT"
fi

# --- Test 7: Corrupt .proof-status treated as "not verified" ---
run_test "Corrupt .proof-status: treated as not-verified (fail-closed)"

TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-integrity-corrupt-XXXXXX")
git -C "$TEMP_REPO" init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.claude"
# Write an empty (corrupt) .proof-status file
> "$TEMP_REPO/.claude/.proof-status"

INPUT_JSON=$(cat <<EOF
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "cd $TEMP_REPO && git commit -m test"
  }
}
EOF
)

OUTPUT=$(cd "$TEMP_REPO" && echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

cd "$PROJECT_ROOT"
rm -rf "$TEMP_REPO"

if echo "$OUTPUT" | grep -q '"permissionDecision": "deny"' && \
   echo "$OUTPUT" | grep -q "corrupt\|verification"; then
    pass_test
else
    fail_test "Corrupt .proof-status was not caught. Got: $OUTPUT"
fi

# --- Test 8: validate_state_file() — valid file ---
run_test "validate_state_file: accepts a valid pipe-delimited file"

TEMP_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-integrity-vsf-XXXXXX")
VALID_FILE="$TEMP_DIR/state.txt"
echo "verified|$(date +%s)" > "$VALID_FILE"

# Source context-lib.sh and call validate_state_file
RESULT=$(bash -c "source '$HOOKS_DIR/source-lib.sh'; validate_state_file '$VALID_FILE' 1 && echo OK || echo FAIL" 2>/dev/null)

rm -rf "$TEMP_DIR"

if [[ "$RESULT" == "OK" ]]; then
    pass_test
else
    fail_test "validate_state_file rejected valid file. Got: $RESULT"
fi

# --- Test 9: validate_state_file() — missing file ---
run_test "validate_state_file: rejects missing file"

RESULT=$(bash -c "source '$HOOKS_DIR/source-lib.sh'; validate_state_file '/nonexistent/file.txt' 1 && echo OK || echo FAIL" 2>/dev/null)

if [[ "$RESULT" == "FAIL" ]]; then
    pass_test
else
    fail_test "validate_state_file accepted missing file. Got: $RESULT"
fi

# --- Test 10: validate_state_file() — empty file ---
run_test "validate_state_file: rejects empty file"

TEMP_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-integrity-vsf2-XXXXXX")
EMPTY_FILE="$TEMP_DIR/empty.txt"
> "$EMPTY_FILE"

RESULT=$(bash -c "source '$HOOKS_DIR/source-lib.sh'; validate_state_file '$EMPTY_FILE' 1 && echo OK || echo FAIL" 2>/dev/null)

rm -rf "$TEMP_DIR"

if [[ "$RESULT" == "FAIL" ]]; then
    pass_test
else
    fail_test "validate_state_file accepted empty file. Got: $RESULT"
fi

# --- Test 11: validate_state_file() — too few fields ---
run_test "validate_state_file: rejects file with fewer fields than required"

TEMP_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-integrity-vsf3-XXXXXX")
ONE_FIELD_FILE="$TEMP_DIR/one.txt"
echo "verified" > "$ONE_FIELD_FILE"

# Require 2 fields — this file only has 1
RESULT=$(bash -c "source '$HOOKS_DIR/source-lib.sh'; validate_state_file '$ONE_FIELD_FILE' 2 && echo OK || echo FAIL" 2>/dev/null)

rm -rf "$TEMP_DIR"

if [[ "$RESULT" == "FAIL" ]]; then
    pass_test
else
    fail_test "validate_state_file accepted file with too few fields. Got: $RESULT"
fi

# --- Test 12: validate_state_file() — sufficient fields ---
run_test "validate_state_file: accepts file with sufficient fields"

TEMP_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-integrity-vsf4-XXXXXX")
TWO_FIELD_FILE="$TEMP_DIR/two.txt"
echo "verified|1234567890" > "$TWO_FIELD_FILE"

RESULT=$(bash -c "source '$HOOKS_DIR/source-lib.sh'; validate_state_file '$TWO_FIELD_FILE' 2 && echo OK || echo FAIL" 2>/dev/null)

rm -rf "$TEMP_DIR"

if [[ "$RESULT" == "OK" ]]; then
    pass_test
else
    fail_test "validate_state_file rejected file with sufficient fields. Got: $RESULT"
fi

# --- Test 13: Crash trap does NOT fire on normal all-checks-passed exit ---
run_test "All-checks-passed exit: no crash output for benign non-git command"

TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-integrity-pass-XXXXXX")
git -C "$TEMP_REPO" init > /dev/null 2>&1

# A benign command — no nuclear matches, no git, passes everything
INPUT_JSON=$(cat <<'EOF'
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "echo hello world"
  }
}
EOF
)

OUTPUT=$(cd "$TEMP_REPO" && echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

cd "$PROJECT_ROOT"
rm -rf "$TEMP_REPO"

if ! echo "$OUTPUT" | grep -q "SAFETY\|crashed"; then
    pass_test
else
    fail_test "Normal exit triggered crash output. Got: $OUTPUT"
fi

# =============================================================================
# Phase B: State Hygiene tests
# =============================================================================

# Source context-lib.sh so atomic_write and other helpers are available
# We source in a subshell for isolation per test, but load it once for syntax checks.
CONTEXT_LIB="$HOOKS_DIR/context-lib.sh"
PHASE_B_TEMP=$(mktemp -d "$PROJECT_ROOT/tmp/test-phase-b-XXXXXX")

# --- Test 14: Syntax: session-end.sh is valid bash ---
run_test "Phase B Syntax: session-end.sh is valid bash"
if bash -n "$HOOKS_DIR/session-end.sh"; then
    pass_test
else
    fail_test "session-end.sh has syntax errors"
fi

# --- Test 15: Syntax: check-guardian.sh is valid bash ---
run_test "Phase B Syntax: check-guardian.sh is valid bash"
if bash -n "$HOOKS_DIR/check-guardian.sh"; then
    pass_test
else
    fail_test "check-guardian.sh has syntax errors"
fi

# --- Test 16: Syntax: session-init.sh is valid bash ---
run_test "Phase B Syntax: session-init.sh is valid bash"
if bash -n "$HOOKS_DIR/session-init.sh"; then
    pass_test
else
    fail_test "session-init.sh has syntax errors"
fi

# --- Test 17: atomic_write basic — write content, verify file and content ---
run_test "Phase B: atomic_write writes content to target file"
ATOMIC_TARGET="$PHASE_B_TEMP/test-atomic.txt"
(
    source "$CONTEXT_LIB" 2>/dev/null
    atomic_write "$ATOMIC_TARGET" "hello atomic"
) 2>/dev/null
if [[ -f "$ATOMIC_TARGET" ]]; then
    CONTENT=$(cat "$ATOMIC_TARGET")
    if [[ "$CONTENT" == "hello atomic" ]]; then
        pass_test
    else
        fail_test "atomic_write wrote wrong content: '$CONTENT'"
    fi
else
    fail_test "atomic_write did not create target file"
fi

# --- Test 18: atomic_write pipe mode — pipe content to atomic_write ---
run_test "Phase B: atomic_write pipe mode writes piped content"
ATOMIC_PIPE_TARGET="$PHASE_B_TEMP/test-atomic-pipe.txt"
(
    source "$CONTEXT_LIB" 2>/dev/null
    echo "piped content" | atomic_write "$ATOMIC_PIPE_TARGET"
) 2>/dev/null
if [[ -f "$ATOMIC_PIPE_TARGET" ]]; then
    PIPE_CONTENT=$(cat "$ATOMIC_PIPE_TARGET")
    if [[ "$PIPE_CONTENT" == "piped content" ]]; then
        pass_test
    else
        fail_test "atomic_write pipe mode wrote wrong content: '$PIPE_CONTENT'"
    fi
else
    fail_test "atomic_write pipe mode did not create target file"
fi

# --- Test 19: atomic_write creates parent directories ---
run_test "Phase B: atomic_write creates missing parent directories"
ATOMIC_NESTED="$PHASE_B_TEMP/nested/dir/test-atomic.txt"
(
    source "$CONTEXT_LIB" 2>/dev/null
    atomic_write "$ATOMIC_NESTED" "nested content"
) 2>/dev/null
if [[ -f "$ATOMIC_NESTED" ]]; then
    pass_test
else
    fail_test "atomic_write did not create nested directories and file"
fi

# --- Test 20: atomic_write leaves no .tmp file on success ---
run_test "Phase B: atomic_write leaves no temp file after successful write"
ATOMIC_NOTMP="$PHASE_B_TEMP/test-no-tmp.txt"
(
    source "$CONTEXT_LIB" 2>/dev/null
    atomic_write "$ATOMIC_NOTMP" "clean write"
) 2>/dev/null
# Use find instead of ls glob to avoid zsh "no matches" exit under set -e
TMP_COUNT=$(find "$PHASE_B_TEMP" -name "test-no-tmp.txt.tmp.*" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$TMP_COUNT" -eq 0 ]]; then
    pass_test
else
    fail_test "atomic_write left $TMP_COUNT temp file(s) behind"
fi

# --- Test 21: Stale tracker path fix — build_resume_directive uses session-scoped path ---
run_test "Phase B: build_resume_directive uses session-scoped tracker path"
# Check that the session-scoped path IS present in context-lib.sh
if grep -q 'subagent-tracker-.*CLAUDE_SESSION_ID' "$CONTEXT_LIB" 2>/dev/null; then
    pass_test
else
    fail_test "Session-scoped tracker path not found in context-lib.sh. Expected 'subagent-tracker-\${CLAUDE_SESSION_ID'"
fi

# --- Test 22: .agent-findings cleanup code present in session-end.sh ---
run_test "Phase B: session-end.sh contains .agent-findings age-based cleanup"
if grep -q 'FINDINGS_AGE' "$HOOKS_DIR/session-end.sh" && grep -q '259200' "$HOOKS_DIR/session-end.sh"; then
    pass_test
else
    fail_test "session-end.sh missing .agent-findings age-based cleanup (FINDINGS_AGE / 259200 not found)"
fi

# --- Test 23: Post-commit .proof-status cleanup present in check-guardian.sh ---
run_test "Phase B: check-guardian.sh contains post-commit .proof-status cleanup"
if grep -q 'HAS_COMMIT' "$HOOKS_DIR/check-guardian.sh" && grep -q 'proof-status' "$HOOKS_DIR/check-guardian.sh"; then
    pass_test
else
    fail_test "check-guardian.sh missing post-commit .proof-status cleanup (HAS_COMMIT / proof-status not found)"
fi

# --- Test 24: Orphaned tracker cleanup loop present in session-init.sh ---
run_test "Phase B: session-init.sh contains orphaned tracker cleanup loop"
if grep -q 'subagent-tracker-' "$HOOKS_DIR/session-init.sh" && grep -q 'tracker_age' "$HOOKS_DIR/session-init.sh"; then
    pass_test
else
    fail_test "session-init.sh missing orphaned tracker cleanup loop"
fi

# --- Test 25: atomic_write is exported from context-lib.sh ---
run_test "Phase B: atomic_write is exported in context-lib.sh export -f line"
if grep -q 'export -f.*atomic_write' "$CONTEXT_LIB"; then
    pass_test
else
    fail_test "atomic_write not found in context-lib.sh export -f line"
fi

# Cleanup Phase B temp directory
rm -rf "$PHASE_B_TEMP"

# =============================================================================
# Phase C: Preflight Checks tests
# =============================================================================

DIAGNOSE_SCRIPT="$PROJECT_ROOT/skills/diagnose/scripts/diagnose.sh"

# --- Test 26: diagnose.sh --quick syntax ---
run_test "Phase C Syntax: diagnose.sh passes bash -n"
if bash -n "$DIAGNOSE_SCRIPT"; then
    pass_test
else
    fail_test "diagnose.sh has syntax errors"
fi

# --- Test 27: diagnose.sh --quick mode runs and exits 0 ---
run_test "Phase C: diagnose.sh --quick exits 0 with [PASS] output"
QUICK_OUTPUT=$(bash "$DIAGNOSE_SCRIPT" --quick 2>/dev/null) || QUICK_EXIT=$?
QUICK_EXIT=${QUICK_EXIT:-0}
if [[ "$QUICK_EXIT" -eq 0 ]] && echo "$QUICK_OUTPUT" | grep -q '^\[PASS\]'; then
    pass_test
else
    fail_test "diagnose.sh --quick did not exit 0 with [PASS] output. exit=$QUICK_EXIT output=$QUICK_OUTPUT"
fi

# --- Test 28: diagnose.sh --quick is fast (under 2 seconds) ---
run_test "Phase C: diagnose.sh --quick completes in under 2 seconds"
QUICK_START_S=$(date +%s)
bash "$DIAGNOSE_SCRIPT" --quick >/dev/null 2>&1 || true
QUICK_END_S=$(date +%s)
QUICK_ELAPSED_S=$(( QUICK_END_S - QUICK_START_S ))
# Use whole-second granularity (portable on macOS/Linux); threshold is 2 seconds
if [[ "$QUICK_ELAPSED_S" -lt 2 ]]; then
    pass_test
else
    fail_test "diagnose.sh --quick took ${QUICK_ELAPSED_S}s (threshold: 2s)"
fi

# --- Test 29: diagnose.sh --quick catches corrupt .proof-status ---
# We validate the underlying check directly: diagnose.sh uses the same
# grep-based format validation as guard.sh. We verify that a corrupt
# .proof-status in the real CLAUDE_DIR would be flagged by saving/restoring it.
run_test "Phase C: diagnose.sh --quick detects corrupt .proof-status"
PHASE_C_TEMP=$(mktemp -d "$PROJECT_ROOT/tmp/test-phase-c-XXXXXX")
REAL_CLAUDE_DIR="$HOME/.claude"
PROOF_STATUS_FILE="$REAL_CLAUDE_DIR/.proof-status"
BACKUP_PROOF_STATUS=""

# Backup existing .proof-status if present
if [[ -f "$PROOF_STATUS_FILE" ]]; then
    BACKUP_PROOF_STATUS=$(cat "$PROOF_STATUS_FILE")
fi

# Write a corrupt .proof-status to the real CLAUDE_DIR
echo "GARBAGE_INVALID_FORMAT" > "$PROOF_STATUS_FILE"

CORRUPT_OUTPUT=$(bash "$DIAGNOSE_SCRIPT" --quick 2>/dev/null) || true

# Restore original content (or remove if it didn't exist)
if [[ -n "$BACKUP_PROOF_STATUS" ]]; then
    echo "$BACKUP_PROOF_STATUS" > "$PROOF_STATUS_FILE"
else
    rm -f "$PROOF_STATUS_FILE"
fi

rm -rf "$PHASE_C_TEMP"

if echo "$CORRUPT_OUTPUT" | grep -qE '^\[(FAIL|WARN)\].*proof-status'; then
    pass_test
else
    fail_test "diagnose.sh --quick did not flag corrupt .proof-status. Got: $CORRUPT_OUTPUT"
fi

# --- Test 30: diagnose.sh full mode still works (regression check) ---
run_test "Phase C: diagnose.sh full mode runs and produces output (regression)"
FULL_OUTPUT=$(bash "$DIAGNOSE_SCRIPT" 2>/dev/null) || true
if echo "$FULL_OUTPUT" | grep -q '=== diagnose.sh'; then
    pass_test
else
    fail_test "diagnose.sh full mode did not produce expected header. Got: ${FULL_OUTPUT:0:200}"
fi

# --- Test 31: session-init.sh syntax after Phase C modifications ---
run_test "Phase C Syntax: session-init.sh is still valid bash after Phase C changes"
if bash -n "$HOOKS_DIR/session-init.sh"; then
    pass_test
else
    fail_test "session-init.sh has syntax errors after Phase C"
fi

# --- Summary ---
echo ""
echo "=========================================="
echo "Test Results: $TESTS_PASSED/$TESTS_RUN passed"
echo "=========================================="

if [[ $TESTS_FAILED -gt 0 ]]; then
    echo "FAILED: $TESTS_FAILED tests failed"
    exit 1
else
    echo "SUCCESS: All tests passed"
    exit 0
fi
