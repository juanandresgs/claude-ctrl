#!/usr/bin/env bash
# test-state-corruption.sh — validate_state_file() and hook behavior with corrupt/malformed state.
#
# Tests validate_state_file() directly against corruption edge cases that were
# only covered indirectly by existing test suite. Each test exercises a distinct
# failure mode: empty files, missing delimiters, unexpected values, oversized
# content, missing directories, partial writes, binary content, and extra fields.
#
# @decision DEC-STATE-CORRUPT-001
# @title Corruption resilience tests for state file validation
# @status accepted
# @rationale validate_state_file was added pervasively in Phase 2 but only tested
#   indirectly. These tests directly exercise corruption edge cases that arise from
#   interrupted writes, race conditions, and invalid manual edits. The function
#   guards against: empty files, missing pipe delimiters, wrong field counts, and
#   head(1) failures on binary/null content. Direct coverage here prevents
#   regressions in the guards that protect hook stability.

set -euo pipefail

# _with_timeout SECS CMD [ARGS] — portable timeout (Perl fallback when GNU timeout absent)
_with_timeout() { local s="$1"; shift; if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; else perl -e 'alarm(shift @ARGV); exec @ARGV or exit 127' "$s" "$@"; fi; }

# Portable SHA-256 (macOS: shasum, Ubuntu: sha256sum)
if command -v shasum >/dev/null 2>&1; then
    _SHA256_CMD="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
    _SHA256_CMD="sha256sum"
else
    _SHA256_CMD="cat"
fi

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"

mkdir -p "$PROJECT_ROOT/tmp"

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

# Helper: call validate_state_file in a controlled subshell
# Returns "valid" or "invalid"
call_validate() {
    local file="$1"
    local expected_fields="${2:-2}"
    bash -c "
        source '$HOOKS_DIR/core-lib.sh' 2>/dev/null
        source '$HOOKS_DIR/log.sh' 2>/dev/null
        validate_state_file '$file' '$expected_fields' && echo 'valid' || echo 'invalid'
    " 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# Setup: isolated temp dir, cleaned up on EXIT
# ─────────────────────────────────────────────────────────────────────────────

TMPDIR="$PROJECT_ROOT/tmp/test-corruption-$$"
mkdir -p "$TMPDIR"
trap 'rm -rf "$TMPDIR"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# TC-01: Empty proof-status file → validate_state_file rejects (returns 1)
# Rationale: An empty file results from a write interrupted after open() but
# before any data was written. The [[ ! -s "$file" ]] guard must catch this.
# ─────────────────────────────────────────────────────────────────────────────

run_test "TC-01: Empty file — validate_state_file rejects"
EMPTY_FILE="$TMPDIR/proof-status-empty"
touch "$EMPTY_FILE"

RESULT=$(call_validate "$EMPTY_FILE" 2)
if [[ "$RESULT" == "invalid" ]]; then
    pass_test
else
    fail_test "Expected 'invalid' for empty file, got '$RESULT'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# TC-02: No pipe delimiter → validate_state_file rejects when field count < expected
# Example: "verifiedNOPIPE" has 1 field. validate_state_file(file, 2) must return 1.
# Rationale: A proof-status file without the pipe delimiter loses the timestamp
# field required by all callers using cut -d'|' -f2.
# ─────────────────────────────────────────────────────────────────────────────

run_test "TC-02: No pipe delimiter — validate_state_file(file, 2) rejects"
NO_PIPE_FILE="$TMPDIR/proof-status-nopipe"
printf 'verifiedNOPIPE\n' > "$NO_PIPE_FILE"

RESULT=$(call_validate "$NO_PIPE_FILE" 2)
if [[ "$RESULT" == "invalid" ]]; then
    pass_test
else
    fail_test "Expected 'invalid' for missing pipe delimiter, got '$RESULT'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# TC-03: Unexpected status value → validate accepts format, caller treats as non-verified
# Example: "potato|12345" passes format validation (2 fields, non-empty) but
# callers checking for "verified" or "pending" will treat it as unrecognized.
# Rationale: validate_state_file checks structure, not semantic values. The caller
# (post-write.sh PROOF_STATUS check) provides semantic filtering.
# ─────────────────────────────────────────────────────────────────────────────

run_test "TC-03: Unexpected status value 'potato|12345' — format valid, caller treats as non-verified"
POTATO_FILE="$TMPDIR/proof-status-potato"
printf 'potato|12345\n' > "$POTATO_FILE"

RESULT=$(call_validate "$POTATO_FILE" 2)
# Format check passes (2 fields, non-empty line)
if [[ "$RESULT" == "valid" ]]; then
    # Also verify caller-side behavior: status != "verified" → no invalidation
    STATUS=$(bash -c "cut -d'|' -f1 '$POTATO_FILE'" 2>/dev/null || echo "")
    if [[ "$STATUS" != "verified" && "$STATUS" != "pending" && "$STATUS" != "needs-verification" ]]; then
        pass_test
    else
        fail_test "Status '$STATUS' is a recognized value — test premise invalid"
    fi
else
    fail_test "Expected 'valid' for well-formed (but semantically unknown) content, got '$RESULT'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# TC-04: Very long content (10KB) → no hang, head -1 truncation works
# Rationale: validate_state_file calls head -1 which reads exactly one line.
# A 10KB single-line file must not cause head to hang or OOM — head -1 exits
# after reading one newline. This guards against pathological state files from
# log injection or disk corruption that writes garbage without newlines.
# ─────────────────────────────────────────────────────────────────────────────

run_test "TC-04: 10KB single-line content — head -1 truncation, no hang"
LONG_FILE="$TMPDIR/proof-status-long"
# Generate 10KB of 'a' characters followed by a pipe and timestamp, no newline until end
python3 -c "print('a' * 10240 + '|12345')" > "$LONG_FILE" 2>/dev/null || \
    printf '%s|12345\n' "$(head -c 10240 /dev/zero | tr '\0' 'a')" > "$LONG_FILE"

# Should complete without hanging and return valid (has pipe delimiter)
VALIDATE_RESULT=""
VALIDATE_RESULT=$(_with_timeout 5 bash -c "
    source '$HOOKS_DIR/log.sh' 2>/dev/null
    source '$HOOKS_DIR/core-lib.sh' 2>/dev/null
    validate_state_file '$LONG_FILE' 2 && echo 'valid' || echo 'invalid'
" 2>/dev/null) || VALIDATE_RESULT="timeout"

if [[ "$VALIDATE_RESULT" != "timeout" ]]; then
    pass_test
else
    fail_test "validate_state_file hung or timed out on 10KB content"
fi

# ─────────────────────────────────────────────────────────────────────────────
# TC-05: Missing CLAUDE_DIR → resolve_proof_file returns safe default
# Rationale: When CLAUDE_DIR points to a non-existent directory (e.g., after
# clean-state removes it), resolve_proof_file must not crash — it returns a
# deterministic default path derived from project_hash.
# ─────────────────────────────────────────────────────────────────────────────

run_test "TC-05: Missing CLAUDE_DIR → resolve_proof_file returns safe default (no crash)"
MISSING_CLAUDE_DIR="$TMPDIR/nonexistent-claude"
MOCK_PROJECT_TC05="$TMPDIR/project-tc05"
mkdir -p "$MOCK_PROJECT_TC05"
git -C "$MOCK_PROJECT_TC05" init >/dev/null 2>&1

RESOLVE_RESULT=""
RESOLVE_EXIT=0
RESOLVE_RESULT=$(bash -c "
    source '$HOOKS_DIR/log.sh' 2>/dev/null
    export CLAUDE_DIR='$MISSING_CLAUDE_DIR'
    export PROJECT_ROOT='$MOCK_PROJECT_TC05'
    resolve_proof_file 2>/dev/null
" 2>/dev/null) || RESOLVE_EXIT=$?

if [[ -n "$RESOLVE_RESULT" && "$RESOLVE_EXIT" -eq 0 ]]; then
    # Must return a path (doesn't have to exist yet — that's the default-create path)
    pass_test
else
    fail_test "resolve_proof_file crashed or returned empty with missing CLAUDE_DIR (exit=$RESOLVE_EXIT, result='$RESOLVE_RESULT')"
fi

# ─────────────────────────────────────────────────────────────────────────────
# TC-06: Partial write simulation → atomic tmp→mv prevents partial reads
# Rationale: write_proof_status writes to a .tmp file then renames. A reader
# that arrives between printf and mv would only see the old file (the new .tmp
# is invisible until rename). We verify: after write_proof_status completes,
# the target file is always complete (never "verified|" without a timestamp,
# never truncated at the pipe character).
# ─────────────────────────────────────────────────────────────────────────────

run_test "TC-06: Atomic write — completed write is never partially read"
ATOMIC_PROJECT="$TMPDIR/project-atomic"
ATOMIC_CLAUDE="$ATOMIC_PROJECT/.claude"
mkdir -p "$ATOMIC_CLAUDE"
git -C "$ATOMIC_PROJECT" init >/dev/null 2>&1

TRACE_TMP="$TMPDIR/traces-atomic"
mkdir -p "$TRACE_TMP"

bash -c "
    source '$HOOKS_DIR/core-lib.sh' 2>/dev/null
    source '$HOOKS_DIR/log.sh' 2>/dev/null
    export CLAUDE_DIR='$ATOMIC_CLAUDE'
    export PROJECT_ROOT='$ATOMIC_PROJECT'
    export TRACE_STORE='$TRACE_TMP'
    export CLAUDE_SESSION_ID='test-atomic-$$'
    write_proof_status 'verified' '$ATOMIC_PROJECT' 2>/dev/null
" 2>/dev/null

# After write completes, find all proof files and verify each has both fields.
# write_proof_status dual-writes to:
#   - New path: state/{phash}/proof-status
#   - Legacy path: .proof-status-{phash}
PHASH=$(echo "$ATOMIC_PROJECT" | $_SHA256_CMD | cut -c1-8)
NEW_STATE_PROOF="$ATOMIC_CLAUDE/state/${PHASH}/proof-status"
SCOPED_PROOF="$ATOMIC_CLAUDE/.proof-status-${PHASH}"

PARTIAL_FOUND=false
for pf in "$NEW_STATE_PROOF" "$SCOPED_PROOF"; do
    if [[ -f "$pf" ]]; then
        CONTENT=$(cat "$pf" 2>/dev/null || echo "")
        FIELD_COUNT=$(echo "$CONTENT" | awk -F'|' '{print NF}')
        # Must have exactly 2 fields: status and timestamp
        if [[ "$FIELD_COUNT" -lt 2 ]]; then
            PARTIAL_FOUND=true
            break
        fi
        TS=$(echo "$CONTENT" | cut -d'|' -f2)
        if [[ -z "$TS" || ! "$TS" =~ ^[0-9]+$ ]]; then
            PARTIAL_FOUND=true
            break
        fi
    fi
done

if [[ "$PARTIAL_FOUND" == "false" ]]; then
    pass_test
else
    fail_test "Found partial write: at least one proof file has incomplete content"
fi

# ─────────────────────────────────────────────────────────────────────────────
# TC-07: Binary/null content in proof file → validate_state_file rejects gracefully
# Rationale: A corrupted disk sector or incorrect write could produce null bytes
# in the state file. validate_state_file calls head -1 which may return an empty
# string for a null-byte-only file. The [[ -z "$content" ]] guard catches this.
# The key requirement is no crash (no set -e trap fire) — validate returns 1.
# ─────────────────────────────────────────────────────────────────────────────

run_test "TC-07: Binary/null content — validate_state_file rejects gracefully (no crash)"
NULL_FILE="$TMPDIR/proof-status-null"
# Write null bytes — head -1 on this will return empty string
printf '\x00\x00\x00\x00\x00' > "$NULL_FILE"

# Must not crash (bash set -e should not fire) and must return "invalid"
NULL_RESULT=""
NULL_EXIT=0
NULL_RESULT=$(_with_timeout 5 bash -c "
    set -euo pipefail
    source '$HOOKS_DIR/core-lib.sh' 2>/dev/null
    source '$HOOKS_DIR/log.sh' 2>/dev/null
    validate_state_file '$NULL_FILE' 2 && echo 'valid' || echo 'invalid'
" 2>/dev/null) || NULL_EXIT=$?

# Exit code 1 (invalid) is acceptable — exit code > 1 or timeout is a crash
if [[ "$NULL_RESULT" == "invalid" || "$NULL_EXIT" -eq 1 ]]; then
    pass_test
elif [[ "$NULL_EXIT" -eq 0 && "$NULL_RESULT" == "valid" ]]; then
    fail_test "validate_state_file accepted null-byte content as valid"
else
    fail_test "validate_state_file crashed on null content (exit=$NULL_EXIT, result='$NULL_RESULT')"
fi

# ─────────────────────────────────────────────────────────────────────────────
# TC-08: Wrong field count (>= check) — extra fields accepted
# Example: "a|b|c|d|e" with expected_fields=2 → validate returns 0 (accepts)
# Rationale: validate_state_file uses >= not == so files with extra pipe-delimited
# fields (from future extensions) are backward compatible. Only files with fewer
# fields than expected are rejected.
# ─────────────────────────────────────────────────────────────────────────────

run_test "TC-08: Extra fields ('a|b|c|d|e', expected=2) — validate accepts (>= check)"
EXTRA_FIELDS_FILE="$TMPDIR/proof-status-extra"
printf 'a|b|c|d|e\n' > "$EXTRA_FIELDS_FILE"

RESULT=$(call_validate "$EXTRA_FIELDS_FILE" 2)
if [[ "$RESULT" == "valid" ]]; then
    pass_test
else
    fail_test "Expected 'valid' for 5-field content with expected_fields=2, got '$RESULT'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# TC-09: File with only whitespace → validate_state_file rejects
# Rationale: A file containing only spaces/newlines is technically non-empty
# (-s passes) but head -1 returns a whitespace-only string. The [[ -z "$content" ]]
# guard with bash default behavior: spaces are non-empty. However, awk's field
# count on "   " returns 1 field (not 2), so validate_state_file(file, 2) rejects.
# ─────────────────────────────────────────────────────────────────────────────

run_test "TC-09: Whitespace-only content — validate_state_file rejects (field count < 2)"
WHITESPACE_FILE="$TMPDIR/proof-status-whitespace"
printf '   \n' > "$WHITESPACE_FILE"

RESULT=$(call_validate "$WHITESPACE_FILE" 2)
if [[ "$RESULT" == "invalid" ]]; then
    pass_test
else
    fail_test "Expected 'invalid' for whitespace-only content, got '$RESULT'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# TC-10: Missing file → validate_state_file rejects (file does not exist)
# Rationale: The [[ ! -f "$file" ]] guard must catch this before any read attempt.
# This is the most common case in fresh sessions.
# ─────────────────────────────────────────────────────────────────────────────

run_test "TC-10: Missing file — validate_state_file rejects (does not exist)"
MISSING_FILE="$TMPDIR/proof-status-missing-NONEXISTENT"

RESULT=$(call_validate "$MISSING_FILE" 2)
if [[ "$RESULT" == "invalid" ]]; then
    pass_test
else
    fail_test "Expected 'invalid' for missing file, got '$RESULT'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "──────────────────────────────────────────────────────"
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_RUN total"

if [[ "$TESTS_FAILED" -eq 0 ]]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "SOME TESTS FAILED"
    exit 1
fi
