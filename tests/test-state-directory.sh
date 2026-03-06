#!/usr/bin/env bash
# test-state-directory.sh — Phase 3 unified state directory migration tests
#
# Validates all state directory functions introduced in W3-0 through W3-4:
#   - state_dir()              creates $CLAUDE_DIR/state/{phash}/ (state-lib.sh)
#   - state_locks_dir()        returns $CLAUDE_DIR/state/locks/ (state-lib.sh)
#   - resolve_proof_file()     new-first fallback (log.sh)
#   - write_proof_status()     dual-write to new + old paths (log.sh)
#   - read_test_status()       new-first fallback (core-lib.sh)
#   - is_protected_state_file() matches state/* paths (core-lib.sh)
#   - Session-end sweep logic  covers state/{phash}/proof-status
#
# @decision DEC-RSM-STATEDIR-TEST-001
# @title Migration test suite for Phase 3 unified state directory
# @status accepted
# @rationale Phase 3 migrates scattered dotfiles into $CLAUDE_DIR/state/{phash}/.
#   Tests verify the dual-write (both new and old paths), new-first fallback reads,
#   protected file registry expansion, lock directory creation, and session-end
#   sweep coverage of the new state directory layout. Each test uses an isolated
#   temp repo to prevent cross-contamination. Subshell pattern ensures sourced
#   hook state does not leak between tests.
#
# Usage: bash tests/test-state-directory.sh
# Scope: --scope state in run-hooks.sh (also runs in default full suite)

set -euo pipefail

# _file_mtime FILE — cross-platform mtime (Linux-first; mirrors core-lib.sh)
_file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# Portable SHA-256 (macOS: shasum, Ubuntu: sha256sum)
if command -v shasum >/dev/null 2>&1; then
    _SHA256_CMD="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
    _SHA256_CMD="sha256sum"
else
    _SHA256_CMD="cat"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"

# Ensure tmp directory exists (Sacred Practice: no /tmp/)
mkdir -p "$PROJECT_ROOT/tmp"

# ---------------------------------------------------------------------------
# Test tracking
# ---------------------------------------------------------------------------
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
    local test_name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo ""
    echo "Running: $test_name"
}

pass_test() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  PASS"
}

fail_test() {
    local reason="${1:-}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL: $reason"
}

# ---------------------------------------------------------------------------
# Setup: isolated temp dir, cleaned up on EXIT
# ---------------------------------------------------------------------------
TMPDIR_BASE="$PROJECT_ROOT/tmp/test-state-directory-$$"
mkdir -p "$TMPDIR_BASE"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ---------------------------------------------------------------------------
# Helper: make a clean isolated environment with git repo + .claude dir
# Returns path via stdout
# ---------------------------------------------------------------------------
make_temp_env() {
    local dir
    dir="$TMPDIR_BASE/env-$RANDOM"
    mkdir -p "$dir/.claude"
    git -C "$dir" init -q 2>/dev/null || true
    echo "$dir"
}

# ---------------------------------------------------------------------------
# Helper: compute project_hash — same as log.sh / core-lib.sh
# ---------------------------------------------------------------------------
compute_phash() {
    echo "$1" | ${_SHA256_CMD} | cut -c1-8 2>/dev/null || echo "00000000"
}

# ---------------------------------------------------------------------------
# Source hook libraries for unit-style testing
# Pre-set _HOOK_NAME to avoid unbound variable error in source-lib.sh EXIT trap
# ---------------------------------------------------------------------------
_HOOK_NAME="test-state-directory"
source "$HOOKS_DIR/log.sh" 2>/dev/null
source "$HOOKS_DIR/source-lib.sh" 2>/dev/null
require_state


# ===========================================================================
# T01: state_dir() creates directory
#
# Call state_dir() with a temp project root. Verify the directory is created
# at $CLAUDE_DIR/state/{phash}/ and the path is returned on stdout.
# ===========================================================================
run_test "T01: state_dir() creates \$CLAUDE_DIR/state/{phash}/ and returns path"

T01_ENV=$(make_temp_env)
T01_CLAUDE="$T01_ENV/.claude"
T01_PHASH=$(compute_phash "$T01_ENV")

T01_RESULT=$(
    export PROJECT_ROOT="$T01_ENV"
    export CLAUDE_DIR="$T01_CLAUDE"
    export CLAUDE_SESSION_ID="t01-session-$$"
    export _HOOK_NAME="test-state-directory"
    state_dir "$T01_ENV" 2>/dev/null
)

T01_EXPECTED="$T01_CLAUDE/state/$T01_PHASH"

if [[ -d "$T01_EXPECTED" ]] && [[ "$T01_RESULT" == "$T01_EXPECTED" ]]; then
    pass_test
else
    fail_test "Expected dir '$T01_EXPECTED' to exist and be returned; got '$T01_RESULT' (dir exists: $([ -d "$T01_EXPECTED" ] && echo yes || echo no))"
fi

unset PROJECT_ROOT CLAUDE_DIR CLAUDE_SESSION_ID TRACE_STORE 2>/dev/null || true


# ===========================================================================
# T02: resolve_proof_file() prefers new path when both exist
#
# Create both state/{phash}/proof-status and .proof-status-{phash}.
# Verify resolve_proof_file() returns the new path.
# ===========================================================================
run_test "T02: resolve_proof_file() returns new path when both old and new exist"

T02_ENV=$(make_temp_env)
T02_CLAUDE="$T02_ENV/.claude"
T02_PHASH=$(compute_phash "$T02_ENV")

# Create both old and new proof-status files
mkdir -p "$T02_CLAUDE/state/$T02_PHASH"
echo "needs-verification|$(date +%s)" > "$T02_CLAUDE/state/$T02_PHASH/proof-status"
echo "needs-verification|$(date +%s)" > "$T02_CLAUDE/.proof-status-$T02_PHASH"

T02_RESULT=$(
    export PROJECT_ROOT="$T02_ENV"
    export CLAUDE_DIR="$T02_CLAUDE"
    export CLAUDE_SESSION_ID="t02-session-$$"
    export _HOOK_NAME="test-state-directory"
    resolve_proof_file 2>/dev/null
)

T02_EXPECTED="$T02_CLAUDE/state/$T02_PHASH/proof-status"

if [[ "$T02_RESULT" == "$T02_EXPECTED" ]]; then
    pass_test
else
    fail_test "Expected new path '$T02_EXPECTED'; got '$T02_RESULT'"
fi

unset PROJECT_ROOT CLAUDE_DIR CLAUDE_SESSION_ID TRACE_STORE 2>/dev/null || true


# ===========================================================================
# T03: resolve_proof_file() falls back to old path when only old exists
#
# Create only .proof-status-{phash} (not the new state dir path).
# Verify resolve_proof_file() returns the old dotfile path.
# ===========================================================================
run_test "T03: resolve_proof_file() falls back to old .proof-status-{phash} when new missing"

T03_ENV=$(make_temp_env)
T03_CLAUDE="$T03_ENV/.claude"
T03_PHASH=$(compute_phash "$T03_ENV")

# Create ONLY the old path
echo "pending|$(date +%s)" > "$T03_CLAUDE/.proof-status-$T03_PHASH"

T03_RESULT=$(
    export PROJECT_ROOT="$T03_ENV"
    export CLAUDE_DIR="$T03_CLAUDE"
    export CLAUDE_SESSION_ID="t03-session-$$"
    export _HOOK_NAME="test-state-directory"
    resolve_proof_file 2>/dev/null
)

T03_EXPECTED="$T03_CLAUDE/.proof-status-$T03_PHASH"

if [[ "$T03_RESULT" == "$T03_EXPECTED" ]]; then
    pass_test
else
    fail_test "Expected old fallback '$T03_EXPECTED'; got '$T03_RESULT'"
fi

unset PROJECT_ROOT CLAUDE_DIR CLAUDE_SESSION_ID TRACE_STORE 2>/dev/null || true


# ===========================================================================
# T04: resolve_proof_file() returns new path when neither exists
#
# With no proof files at all, verify resolve_proof_file() returns the new
# state/{phash}/proof-status path (where new writes will go).
# ===========================================================================
run_test "T04: resolve_proof_file() returns new path when neither old nor new exists"

T04_ENV=$(make_temp_env)
T04_CLAUDE="$T04_ENV/.claude"
T04_PHASH=$(compute_phash "$T04_ENV")

# Ensure neither proof file exists
rm -f "$T04_CLAUDE/.proof-status-$T04_PHASH" 2>/dev/null || true
rm -f "$T04_CLAUDE/state/$T04_PHASH/proof-status" 2>/dev/null || true

T04_RESULT=$(
    export PROJECT_ROOT="$T04_ENV"
    export CLAUDE_DIR="$T04_CLAUDE"
    export CLAUDE_SESSION_ID="t04-session-$$"
    export _HOOK_NAME="test-state-directory"
    resolve_proof_file 2>/dev/null
)

T04_EXPECTED="$T04_CLAUDE/state/$T04_PHASH/proof-status"

if [[ "$T04_RESULT" == "$T04_EXPECTED" ]]; then
    pass_test
else
    fail_test "Expected new path '$T04_EXPECTED'; got '$T04_RESULT'"
fi

unset PROJECT_ROOT CLAUDE_DIR CLAUDE_SESSION_ID TRACE_STORE 2>/dev/null || true


# ===========================================================================
# T05: write_proof_status() dual-writes to both new and old paths
#
# Call write_proof_status "needs-verification". Verify BOTH
#   state/{phash}/proof-status  AND  .proof-status-{phash}
# exist and contain the same content.
# ===========================================================================
run_test "T05: write_proof_status() dual-writes to state/{phash}/proof-status AND .proof-status-{phash}"

T05_ENV=$(make_temp_env)
T05_CLAUDE="$T05_ENV/.claude"
T05_PHASH=$(compute_phash "$T05_ENV")
T05_TRACE="$TMPDIR_BASE/traces-t05"
mkdir -p "$T05_TRACE"

(
    export PROJECT_ROOT="$T05_ENV"
    export CLAUDE_DIR="$T05_CLAUDE"
    export CLAUDE_SESSION_ID="t05-session-$$"
    export TRACE_STORE="$T05_TRACE"
    export _HOOK_NAME="test-state-directory"
    write_proof_status "needs-verification" "$T05_ENV" 2>/dev/null
) 2>/dev/null || true

T05_NEW="$T05_CLAUDE/state/$T05_PHASH/proof-status"
T05_OLD="$T05_CLAUDE/.proof-status-$T05_PHASH"

T05_ERRORS=()
[[ -f "$T05_NEW" ]] || T05_ERRORS+=("new path missing: $T05_NEW")
[[ -f "$T05_OLD" ]] || T05_ERRORS+=("old path missing: $T05_OLD")

if [[ ${#T05_ERRORS[@]} -eq 0 ]]; then
    T05_NEW_VAL=$(cut -d'|' -f1 "$T05_NEW" 2>/dev/null || echo "")
    T05_OLD_VAL=$(cut -d'|' -f1 "$T05_OLD" 2>/dev/null || echo "")
    if [[ "$T05_NEW_VAL" == "needs-verification" && "$T05_OLD_VAL" == "needs-verification" ]]; then
        pass_test
    else
        fail_test "Content mismatch: new='$T05_NEW_VAL' old='$T05_OLD_VAL' (expected both 'needs-verification')"
    fi
else
    fail_test "${T05_ERRORS[*]}"
fi

unset PROJECT_ROOT CLAUDE_DIR CLAUDE_SESSION_ID TRACE_STORE 2>/dev/null || true
unset TRACE_STORE 2>/dev/null || true


# ===========================================================================
# T06: read_test_status() reads from new state/{phash}/test-status path
#
# Write test status only to state/{phash}/test-status (new path).
# Verify read_test_status() populates TEST_RESULT correctly.
# ===========================================================================
run_test "T06: read_test_status() reads from state/{phash}/test-status (new path)"

T06_ENV=$(make_temp_env)
T06_CLAUDE="$T06_ENV/.claude"
T06_PHASH=$(compute_phash "$T06_ENV")

# Write ONLY to new path
mkdir -p "$T06_CLAUDE/state/$T06_PHASH"
printf 'pass|0|%s\n' "$(date +%s)" > "$T06_CLAUDE/state/$T06_PHASH/test-status"

T06_RESULT=$(
    export PROJECT_ROOT="$T06_ENV"
    export CLAUDE_DIR="$T06_CLAUDE"
    export CLAUDE_SESSION_ID="t06-session-$$"
    export _HOOK_NAME="test-state-directory"
    # run read_test_status and capture TEST_RESULT
    (
        read_test_status "$T06_ENV" 2>/dev/null && echo "$TEST_RESULT"
    ) 2>/dev/null
)

if [[ "$T06_RESULT" == "pass" ]]; then
    pass_test
else
    fail_test "Expected TEST_RESULT='pass'; got '$T06_RESULT'"
fi

unset PROJECT_ROOT CLAUDE_DIR CLAUDE_SESSION_ID TRACE_STORE 2>/dev/null || true


# ===========================================================================
# T07: read_test_status() falls back to old .test-status path
#
# Write test status only to .test-status (old/legacy path).
# Verify read_test_status() still populates TEST_RESULT correctly.
# ===========================================================================
run_test "T07: read_test_status() falls back to .test-status when new path missing"

T07_ENV=$(make_temp_env)
T07_CLAUDE="$T07_ENV/.claude"
T07_PHASH=$(compute_phash "$T07_ENV")

# Write ONLY to old path
printf 'fail|3|%s\n' "$(date +%s)" > "$T07_CLAUDE/.test-status"
# Ensure new path does NOT exist
rm -f "$T07_CLAUDE/state/$T07_PHASH/test-status" 2>/dev/null || true

T07_RESULT=$(
    export PROJECT_ROOT="$T07_ENV"
    export CLAUDE_DIR="$T07_CLAUDE"
    export CLAUDE_SESSION_ID="t07-session-$$"
    export _HOOK_NAME="test-state-directory"
    (
        read_test_status "$T07_ENV" 2>/dev/null && echo "$TEST_RESULT"
    ) 2>/dev/null
)

if [[ "$T07_RESULT" == "fail" ]]; then
    pass_test
else
    fail_test "Expected TEST_RESULT='fail' from old .test-status fallback; got '$T07_RESULT'"
fi

unset PROJECT_ROOT CLAUDE_DIR CLAUDE_SESSION_ID TRACE_STORE 2>/dev/null || true


# ===========================================================================
# T08: is_protected_state_file() matches new state/ directory paths
#
# Verify that is_protected_state_file() returns 0 (match) for:
#   - "state/abc123/proof-status"
#   - "state/abc123/test-status"
#
# These are the clean-name files in the new state directory layout.
# The function matches via */state/* path pattern (W3-0).
# ===========================================================================
run_test "T08: is_protected_state_file() matches state/{phash}/proof-status and test-status"

T08_ERRORS=()

# Test new-style paths (no dot prefix, under state/ directory)
T08_NEW_PATHS=(
    "state/abc12345/proof-status"
    "/some/project/.claude/state/abc12345/proof-status"
    "state/abc12345/test-status"
    "/some/project/.claude/state/abc12345/test-status"
    "/some/project/.claude/state/locks/proof.lock"
    "/some/project/.claude/state/locks/state.lock"
)

for path in "${T08_NEW_PATHS[@]}"; do
    if is_protected_state_file "$path"; then
        : # expected
    else
        T08_ERRORS+=("$path should match but does not")
    fi
done

if [[ ${#T08_ERRORS[@]} -eq 0 ]]; then
    pass_test
else
    fail_test "${T08_ERRORS[*]}"
fi


# ===========================================================================
# T09: state_locks_dir() returns $CLAUDE_DIR/state/locks/ and creates it
#
# Call state_locks_dir() with an isolated CLAUDE_DIR. Verify the directory
# is created at $CLAUDE_DIR/state/locks/ and the path is returned.
# ===========================================================================
run_test "T09: state_locks_dir() creates and returns \$CLAUDE_DIR/state/locks/"

T09_ENV=$(make_temp_env)
T09_CLAUDE="$T09_ENV/.claude"

T09_RESULT=$(
    export PROJECT_ROOT="$T09_ENV"
    export CLAUDE_DIR="$T09_CLAUDE"
    export CLAUDE_SESSION_ID="t09-session-$$"
    export _HOOK_NAME="test-state-directory"
    state_locks_dir 2>/dev/null
)

T09_EXPECTED="$T09_CLAUDE/state/locks"

if [[ -d "$T09_EXPECTED" ]] && [[ "$T09_RESULT" == "$T09_EXPECTED" ]]; then
    pass_test
else
    fail_test "Expected dir '$T09_EXPECTED' to exist and be returned; got '$T09_RESULT' (dir exists: $([ -d "$T09_EXPECTED" ] && echo yes || echo no))"
fi

unset PROJECT_ROOT CLAUDE_DIR CLAUDE_SESSION_ID TRACE_STORE 2>/dev/null || true


# ===========================================================================
# T10: Session-end sweep logic cleans stale state/{phash}/proof-status
#
# Create state/{phash}/proof-status with an old mtime (>4h ago via touch -t).
# Run the session-end sweep logic inline. Verify the file is removed.
#
# This tests the new-format sweep loop added in W3-2d (session-end.sh).
# We replicate the sweep logic directly to avoid needing to invoke the full
# session-end hook (which requires hook input JSON and many env vars).
# ===========================================================================
run_test "T10: Session-end sweep removes state/{phash}/proof-status older than 4 hours"

T10_ENV=$(make_temp_env)
T10_CLAUDE="$T10_ENV/.claude"
T10_PHASH=$(compute_phash "$T10_ENV")
T10_STATE_DIR="$T10_CLAUDE/state/$T10_PHASH"

mkdir -p "$T10_STATE_DIR"
T10_PROOF="$T10_STATE_DIR/proof-status"
echo "needs-verification|$(date +%s)" > "$T10_PROOF"

# Set mtime to 5 hours ago (well past 4-hour TTL).
# Use perl utime — portable across macOS and Linux, no date format ambiguity.
# Fallback to touch -t with macOS/GNU date formats if perl unavailable.
if command -v perl >/dev/null 2>&1; then
    perl -e "utime(time()-18000, time()-18000, '$T10_PROOF');" 2>/dev/null || true
elif date -u -v-5H "+%Y%m%d%H%M.%S" >/dev/null 2>&1; then
    # macOS BSD date
    touch -t "$(date -u -v-5H "+%Y%m%d%H%M.%S")" "$T10_PROOF" 2>/dev/null || true
else
    # GNU date
    touch -t "$(date -u -d "5 hours ago" "+%Y%m%d%H%M.%S")" "$T10_PROOF" 2>/dev/null || true
fi

# Verify the file exists before sweep
if [[ ! -f "$T10_PROOF" ]]; then
    fail_test "Test setup failed: proof-status not created at $T10_PROOF"
else
    # Replicate the session-end.sh new-format sweep logic inline
    _NOW_EPOCH=$(date +%s)
    _SWEPT=false
    for _state_proj_dir in "$T10_CLAUDE/state/"*/; do
        [[ -d "$_state_proj_dir" ]] || continue
        _s_proof="${_state_proj_dir}proof-status"
        [[ -f "$_s_proof" ]] || continue
        _s_mtime=$(_file_mtime "$_s_proof")
        if (( _NOW_EPOCH - _s_mtime > 14400 )); then  # 4 hours
            rm -f "$_s_proof"
            rmdir "$_state_proj_dir" 2>/dev/null || true
            _SWEPT=true
        fi
    done

    if [[ "$_SWEPT" == "true" ]] && [[ ! -f "$T10_PROOF" ]]; then
        pass_test
    elif [[ "$_SWEPT" == "false" ]]; then
        # Check mtime: if touch -t didn't work, the mtime may be current
        T10_ACTUAL_MTIME=$(_file_mtime "$T10_PROOF")
        T10_AGE=$(( _NOW_EPOCH - T10_ACTUAL_MTIME ))
        fail_test "Sweep did not find file as stale; mtime age=${T10_AGE}s (need >14400s). touch -t may have failed."
    else
        fail_test "Sweep ran but file still exists at $T10_PROOF"
    fi
fi

unset PROJECT_ROOT CLAUDE_DIR CLAUDE_SESSION_ID TRACE_STORE 2>/dev/null || true


# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "==================================="
echo "State Directory Tests: $TESTS_RUN run | $TESTS_PASSED passed | $TESTS_FAILED failed"
echo "==================================="

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
exit 0
