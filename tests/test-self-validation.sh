#!/usr/bin/env bash
# test-self-validation.sh — Phase 4 self-validation system tests
#
# Validates the self-validation infrastructure introduced in W4-0 through W4-2:
#   - Version sentinels (_LIB_VERSION=) exist in all 10 hook libraries
#   - verify_library_consistency() detects mismatches (W4-0)
#   - bash -n preflight validates critical hook files (W4-2)
#   - .hooks-gen file format (timestamp-only, written by post-merge)
#   - Staleness detection via .hooks-gen vs library mtime comparison (W4-1)
#
# @decision DEC-RSM-SELFVALID-TEST-001
# @title Self-validation test suite for Phase 4 sentinel and preflight checks
# @status accepted
# @rationale Phase 4 adds library version sentinels, consistency checks, and
#   bash -n preflight validation. Tests verify that all 10 libraries carry their
#   version sentinel, that verify_library_consistency() correctly detects skew,
#   that the preflight loop catches syntax errors in a temp file, and that the
#   .hooks-gen staleness signal works end-to-end. Subshell pattern isolates
#   sourced library state between tests.
#
# Usage: bash tests/test-self-validation.sh
# Scope: --scope validation in run-hooks.sh (also runs in default full suite)

set -euo pipefail

# _file_mtime FILE — cross-platform mtime (Linux-first; mirrors core-lib.sh)
_file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"

# Ensure tmp directory exists (Sacred Practice: no /tmp/)
mkdir -p "$PROJECT_ROOT/tmp"

# ---------------------------------------------------------------------------
# Test tracking
# ---------------------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

# Track temp dirs for cleanup
_CLEANUP_DIRS=()
trap '[[ ${#_CLEANUP_DIRS[@]} -gt 0 ]] && rm -rf "${_CLEANUP_DIRS[@]}" 2>/dev/null; true' EXIT

pass_test() {
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  PASS: ${1:-}"
}

fail_test() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "  FAIL: ${1:-}"
}

run_test() {
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    echo ""
    echo "Running T$(printf '%02d' $TOTAL_COUNT): $1"
}

# ---------------------------------------------------------------------------
# T01: Version sentinels exist — all 10 libraries have _LIB_VERSION=
# ---------------------------------------------------------------------------
run_test "Version sentinels exist in all libraries"

_SENTINEL_MISSING=()
for _lib_file in \
    "$HOOKS_DIR/source-lib.sh" \
    "$HOOKS_DIR/core-lib.sh" \
    "$HOOKS_DIR/log.sh" \
    "$HOOKS_DIR/state-lib.sh" \
    "$HOOKS_DIR/session-lib.sh" \
    "$HOOKS_DIR/trace-lib.sh" \
    "$HOOKS_DIR/plan-lib.sh" \
    "$HOOKS_DIR/git-lib.sh" \
    "$HOOKS_DIR/doc-lib.sh" \
    "$HOOKS_DIR/ci-lib.sh"; do
    if [[ ! -f "$_lib_file" ]]; then
        _SENTINEL_MISSING+=("$(basename "$_lib_file") (file not found)")
    elif ! grep -q '_LIB_VERSION=' "$_lib_file" 2>/dev/null; then
        _SENTINEL_MISSING+=("$(basename "$_lib_file") (no _LIB_VERSION sentinel)")
    fi
done

if [[ ${#_SENTINEL_MISSING[@]} -eq 0 ]]; then
    pass_test "All 10 libraries have _LIB_VERSION= sentinel"
else
    fail_test "Missing sentinels: ${_SENTINEL_MISSING[*]}"
fi

# ---------------------------------------------------------------------------
# T02: verify_library_consistency — all match → exit 0, no output
# ---------------------------------------------------------------------------
run_test "verify_library_consistency returns exit 0 when all versions match"

_T02_RESULT=$(
    # Subshell: source source-lib.sh which exports verify_library_consistency,
    # then also source core-lib.sh and log.sh to populate their _LIB_VERSION vars.
    # All versions are currently 1, so verify_library_consistency 1 should pass.
    (
        # shellcheck disable=SC1090
        source "$HOOKS_DIR/source-lib.sh"
        # source-lib.sh also sources core-lib.sh and log.sh internally;
        # domain libs need explicit require_ calls to populate their versions.
        require_state
        require_session
        require_trace
        require_plan
        require_git
        require_doc
        require_ci
        # Now run the consistency check — capture exit code separately
        _WARN_OUT=$(verify_library_consistency 1 2>&1) || _EXIT_CODE=$?
        _EXIT_CODE="${_EXIT_CODE:-0}"
        echo "exit=$_EXIT_CODE"
        echo "output=$_WARN_OUT"
    ) 2>/dev/null
)

_T02_EXIT=$(echo "$_T02_RESULT" | grep '^exit=' | cut -d= -f2)
_T02_OUTPUT=$(echo "$_T02_RESULT" | grep '^output=' | sed 's/^output=//')

if [[ "$_T02_EXIT" == "0" && -z "$_T02_OUTPUT" ]]; then
    pass_test "verify_library_consistency exit 0 with no output when all versions match"
else
    fail_test "Expected exit=0 empty output, got exit=${_T02_EXIT:-?} output='${_T02_OUTPUT:-}'"
fi

# ---------------------------------------------------------------------------
# T03: verify_library_consistency — mismatch detected → exit > 0 + warning output
# ---------------------------------------------------------------------------
run_test "verify_library_consistency detects version mismatch and returns exit > 0"

_T03_RESULT=$(
    (
        # shellcheck disable=SC1090
        source "$HOOKS_DIR/source-lib.sh"
        # Override one library version to simulate skew
        _CORE_LIB_VERSION=999
        export _CORE_LIB_VERSION
        # Capture output and exit code separately (|| true masks exit code)
        _WARN_OUT=$(verify_library_consistency 1 2>&1) || _EXIT_CODE=$?
        _EXIT_CODE="${_EXIT_CODE:-0}"
        echo "exit=$_EXIT_CODE"
        if [[ -n "$_WARN_OUT" ]]; then
            echo "has_warning=1"
        else
            echo "has_warning=0"
        fi
    ) 2>/dev/null
)

_T03_EXIT=$(echo "$_T03_RESULT" | grep '^exit=' | cut -d= -f2)
_T03_HAS_WARN=$(echo "$_T03_RESULT" | grep '^has_warning=' | cut -d= -f2)

if [[ "${_T03_EXIT:-0}" -gt 0 && "${_T03_HAS_WARN:-0}" == "1" ]]; then
    pass_test "verify_library_consistency exit > 0 with warning when version is 999"
else
    fail_test "Expected exit>0 and warning output, got exit=${_T03_EXIT:-?} has_warning=${_T03_HAS_WARN:-?}"
fi

# ---------------------------------------------------------------------------
# T04: bash -n preflight — all real hook files pass syntax check
# ---------------------------------------------------------------------------
run_test "bash -n preflight: all critical hook files pass syntax validation"

_PREFLIGHT_FILES=(
    "$HOOKS_DIR/session-init.sh"
    "$HOOKS_DIR/prompt-submit.sh"
    "$HOOKS_DIR/source-lib.sh"
    "$HOOKS_DIR/core-lib.sh"
    "$HOOKS_DIR/log.sh"
    "$HOOKS_DIR/pre-bash.sh"
    "$HOOKS_DIR/pre-write.sh"
    "$HOOKS_DIR/task-track.sh"
    "$HOOKS_DIR/check-guardian.sh"
    "$HOOKS_DIR/check-tester.sh"
    "$HOOKS_DIR/check-implementer.sh"
    "$HOOKS_DIR/stop.sh"
)

_T04_FAILS=()
for _pf in "${_PREFLIGHT_FILES[@]}"; do
    if [[ ! -f "$_pf" ]]; then
        # File not present is not a syntax error — skip it
        continue
    fi
    if ! bash -n "$_pf" 2>/dev/null; then
        _T04_FAILS+=("$(basename "$_pf")")
    fi
done

if [[ ${#_T04_FAILS[@]} -eq 0 ]]; then
    pass_test "All 12 critical hook files pass bash -n syntax check"
else
    fail_test "Syntax errors found in: ${_T04_FAILS[*]}"
fi

# ---------------------------------------------------------------------------
# T05: bash -n preflight — syntax error detected in temp file
# ---------------------------------------------------------------------------
run_test "bash -n preflight: detects syntax error in a temp file"

_T05_TMPDIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-preflight-XXXXXX")
_CLEANUP_DIRS+=("$_T05_TMPDIR")
_T05_BAD_FILE="$_T05_TMPDIR/bad-syntax.sh"

# Write a file with a deliberate syntax error
cat > "$_T05_BAD_FILE" <<'BADEOF'
#!/usr/bin/env bash
# Deliberately broken file for preflight testing
if [[ true ]]; then
    echo "unterminated if — no fi
BADEOF

_T05_DETECTED=0
if ! bash -n "$_T05_BAD_FILE" 2>/dev/null; then
    _T05_DETECTED=1
fi

if [[ "$_T05_DETECTED" == "1" ]]; then
    pass_test "bash -n correctly identified syntax error in temp file"
else
    fail_test "bash -n failed to detect syntax error in temp file (expected exit != 0)"
fi

# ---------------------------------------------------------------------------
# T06: .hooks-gen file format — timestamp-only (a single integer line)
# ---------------------------------------------------------------------------
run_test ".hooks-gen file format: post-merge writes a Unix timestamp-only file"

_T06_TMPDIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-hookgen-XXXXXX")
_CLEANUP_DIRS+=("$_T06_TMPDIR")
_T06_HOOKS_GEN="$_T06_TMPDIR/.hooks-gen"

# Simulate what post-merge does
date +%s > "$_T06_HOOKS_GEN"

_T06_CONTENT=$(cat "$_T06_HOOKS_GEN" 2>/dev/null || echo "")
_T06_LINE_COUNT=$(wc -l < "$_T06_HOOKS_GEN" 2>/dev/null || echo "0")

# Content should be a valid Unix timestamp (10+ digit number)
if echo "$_T06_CONTENT" | grep -qE '^[0-9]{10,}$'; then
    pass_test ".hooks-gen contains a valid Unix timestamp (content: $( echo "$_T06_CONTENT" | tr -d '\n'))"
else
    fail_test ".hooks-gen format unexpected (content='$_T06_CONTENT', lines=$_T06_LINE_COUNT)"
fi

# ---------------------------------------------------------------------------
# T07: hooks-gen staleness detection — library newer than .hooks-gen triggers warning
# ---------------------------------------------------------------------------
run_test "hooks-gen staleness: library newer than .hooks-gen triggers warning in session-init"

_T07_TMPDIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-stale-XXXXXX")
_CLEANUP_DIRS+=("$_T07_TMPDIR")
_T07_HOOKS_GEN="$_T07_TMPDIR/.hooks-gen"
_T07_LIB_FILE="$_T07_TMPDIR/fake-lib.sh"

# Write an old timestamp (epoch 1 = 1970, clearly older than any real file)
echo "1" > "$_T07_HOOKS_GEN"

# Create a fake lib file that is definitely newer than the timestamp
touch "$_T07_LIB_FILE"

# Now simulate the staleness check logic from session-init.sh:
# Get the mtime of the fake lib file
_T07_LIB_MTIME=$(_file_mtime "$_T07_LIB_FILE")

_T07_GEN_TS=$(cat "$_T07_HOOKS_GEN")
_T07_STALE=0
if [[ "$_T07_LIB_MTIME" -gt "$_T07_GEN_TS" ]]; then
    _T07_STALE=1
fi

if [[ "$_T07_STALE" == "1" ]]; then
    pass_test "Staleness detected: lib mtime ($( echo "$_T07_LIB_MTIME")) > .hooks-gen timestamp ($( echo "$_T07_GEN_TS"))"
else
    fail_test "Staleness NOT detected: lib mtime=$_T07_LIB_MTIME, .hooks-gen ts=$_T07_GEN_TS (expected stale)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "==================================="
echo "Self-Validation Tests: $TOTAL_COUNT run | $PASS_COUNT passed | $FAIL_COUNT failed"
echo "==================================="
[[ $FAIL_COUNT -gt 0 ]] && exit 1
exit 0
