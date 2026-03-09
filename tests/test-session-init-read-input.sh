#!/usr/bin/env bash
# test-session-init-read-input.sh — Tests for the two-part lifetime_tokens=0 fix.
#
# Purpose: Verifies:
#   Part 1 — session-init.sh explicitly extracts CLAUDE_SESSION_ID from HOOK_INPUT
#             in the parent shell (not inside read_input() subshell).
#   Part 2 — write_statusline_cache() cross-PID sibling-cache fallback: when the
#             PID-keyed cache file doesn't exist but a sibling does with lifetime
#             values, inherit them rather than defaulting to 0.
#
# Root cause: HOOK_INPUT=$(read_input) runs read_input() in a command-substitution
# subshell. export CLAUDE_SESSION_ID inside read_input() doesn't propagate back.
# Every hook process uses ${CLAUDE_SESSION_ID:-$$}, creating separate files per
# PID. DEC-LIFETIME-PERSIST-001 fallback reads from the PID-keyed file — which
# doesn't exist for each new process — so lifetime_tokens always defaults to 0.
#
# @decision DEC-SESSION-INIT-SID-001
# @title Two-part fix: explicit SID extraction + cross-PID sibling cache fallback
# @status accepted
# @rationale The single-part fix (HOOK_INPUT=$(read_input)) was correct but
#   insufficient. Part 1 extracts CLAUDE_SESSION_ID in the parent shell so that
#   session-init.sh itself gets a stable cache file name. Part 2 makes
#   write_statusline_cache() resilient to PID-variation by inheriting from the
#   most recent sibling cache when the own file has no lifetime values.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_INIT="${SCRIPT_DIR}/../hooks/session-init.sh"
SESSION_LIB="${SCRIPT_DIR}/../hooks/session-lib.sh"
SOURCE_LIB="${SCRIPT_DIR}/../hooks/source-lib.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass_test() { TESTS_PASSED=$(( TESTS_PASSED + 1 )); echo -e "${GREEN}OK${NC} $1"; }
fail_test() { TESTS_FAILED=$(( TESTS_FAILED + 1 )); echo -e "${RED}FAIL${NC} $1"; echo -e "  ${YELLOW}Details:${NC} $2"; }
run_test()  { TESTS_RUN=$(( TESTS_RUN + 1 )); }

_CLEANUP_DIRS=()
trap '[[ ${#_CLEANUP_DIRS[@]} -gt 0 ]] && rm -rf "${_CLEANUP_DIRS[@]}" 2>/dev/null; true' EXIT

# ============================================================================
# Part 1: session-init.sh — explicit CLAUDE_SESSION_ID extraction
# ============================================================================

test_explicit_sid_extraction_present() {
    run_test
    # The fix requires explicit extraction of CLAUDE_SESSION_ID from HOOK_INPUT
    # in the parent shell — not relying on read_input()'s subshell export.
    # Pattern: CLAUDE_SESSION_ID=$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id ...')
    if grep -qE 'CLAUDE_SESSION_ID=.*jq.*session_id' "$SESSION_INIT"; then
        pass_test "session-init.sh contains explicit CLAUDE_SESSION_ID jq extraction"
    else
        fail_test "session-init.sh missing explicit CLAUDE_SESSION_ID extraction" \
            "Add: CLAUDE_SESSION_ID=\$(printf '%s' \"\$HOOK_INPUT\" | jq -r '.session_id // empty') after HOOK_INPUT=\$(read_input)"
    fi
}

test_explicit_sid_extraction_after_hook_input() {
    run_test
    # Extraction must come after HOOK_INPUT=$(read_input) (non-comment line)
    local ri_line sid_line
    ri_line=$(grep -n 'HOOK_INPUT=$(read_input)' "$SESSION_INIT" | grep -v '^[^:]*:#' | head -1 | cut -d: -f1)
    sid_line=$(grep -n 'CLAUDE_SESSION_ID=.*jq.*session_id' "$SESSION_INIT" | head -1 | cut -d: -f1)

    if [[ -z "$ri_line" ]]; then
        fail_test "HOOK_INPUT=\$(read_input) not found — cannot check ordering" ""
        return
    fi
    if [[ -z "$sid_line" ]]; then
        fail_test "CLAUDE_SESSION_ID jq extraction not found — cannot check ordering" ""
        return
    fi
    if [[ "$sid_line" -gt "$ri_line" ]]; then
        pass_test "CLAUDE_SESSION_ID extraction (line $sid_line) after HOOK_INPUT=\$(read_input) (line $ri_line)"
    else
        fail_test "CLAUDE_SESSION_ID extraction (line $sid_line) appears BEFORE HOOK_INPUT=\$(read_input) (line $ri_line)" \
            "Must extract after read_input() so HOOK_INPUT contains the JSON"
    fi
}

test_explicit_sid_extraction_functional() {
    run_test
    # Pipe JSON with session_id through a subprocess that applies the fix pattern.
    # Verify CLAUDE_SESSION_ID is set in the parent shell context.
    local tmpscript
    tmpscript=$(mktemp /tmp/test-sid-XXXXXX.sh)
    # shellcheck disable=SC2064
    trap "rm -f '$tmpscript'" RETURN

    cat > "$tmpscript" <<'SCRIPT'
source "$1" 2>/dev/null || true
# shellcheck disable=SC2034
HOOK_INPUT=$(read_input)
# Explicit parent-shell extraction (the Part 1 fix)
if [[ -z "${CLAUDE_SESSION_ID:-}" && -n "$HOOK_INPUT" ]]; then
    CLAUDE_SESSION_ID=$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
    export CLAUDE_SESSION_ID
fi
echo "${CLAUDE_SESSION_ID:-UNSET}"
SCRIPT

    local result
    result=$(echo '{"session_id": "sid-explicit-test", "cwd": "/tmp"}' \
        | bash "$tmpscript" "$SOURCE_LIB" 2>/dev/null || echo "ERROR")

    if [[ "$result" == "sid-explicit-test" ]]; then
        pass_test "explicit extraction sets CLAUDE_SESSION_ID='sid-explicit-test' in parent shell"
    else
        fail_test "explicit extraction failed" "expected 'sid-explicit-test', got '$result'"
    fi
}

test_sid_guards_on_empty_hook_input() {
    run_test
    # When HOOK_INPUT is empty (no stdin), guard prevents jq crash and CLAUDE_SESSION_ID stays unset.
    local tmpscript
    tmpscript=$(mktemp /tmp/test-sid-XXXXXX.sh)
    # shellcheck disable=SC2064
    trap "rm -f '$tmpscript'" RETURN

    cat > "$tmpscript" <<'SCRIPT'
HOOK_INPUT=""  # simulate no stdin
if [[ -z "${CLAUDE_SESSION_ID:-}" && -n "$HOOK_INPUT" ]]; then
    CLAUDE_SESSION_ID=$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
    export CLAUDE_SESSION_ID
fi
echo "${CLAUDE_SESSION_ID:-UNSET}"
SCRIPT

    local result
    result=$(bash "$tmpscript" 2>/dev/null || echo "ERROR")

    if [[ "$result" == "UNSET" ]]; then
        pass_test "empty HOOK_INPUT guard: CLAUDE_SESSION_ID stays UNSET when no stdin"
    else
        fail_test "guard failed" "expected UNSET, got '$result'"
    fi
}

# ============================================================================
# Part 2: session-lib.sh — cross-PID sibling cache fallback
# ============================================================================

test_sibling_fallback_present_in_source() {
    run_test
    # The fix adds a cross-PID sibling search when own cache has no lifetime values.
    # Check for the ls glob pattern that discovers sibling cache files.
    if grep -qE 'ls.*statusline-cache' "$SESSION_LIB"; then
        pass_test "session-lib.sh contains sibling cache discovery (ls .statusline-cache-*)"
    else
        fail_test "session-lib.sh missing sibling cache discovery" \
            "Add: _any_cache=\$(ls -t \"\$root/.claude/.statusline-cache-\"* ...) fallback in write_statusline_cache()"
    fi
}

test_sibling_fallback_inherits_lifetime_tokens() {
    run_test
    # PID-A writes cache with LIFETIME_TOKENS=5000000.
    # PID-B (different CLAUDE_SESSION_ID, no own cache) must inherit 5000000 from sibling.
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    mkdir -p "$tmpdir/.claude"

    local fake_sid_a="test-pid-a-99999"
    bash -c "
        export CLAUDE_SESSION_ID='$fake_sid_a'
        export LIFETIME_TOKENS=5000000
        export LIFETIME_COST=25.00
        source '${SOURCE_LIB}' 2>/dev/null || true
        require_session 2>/dev/null || true
        [[ \"\$(type -t write_statusline_cache)\" == 'function' ]] || source '${SESSION_LIB}'
        write_statusline_cache '${tmpdir}'
    " 2>/dev/null

    local pid_a_file="${tmpdir}/.claude/.statusline-cache-${fake_sid_a}"
    if [[ ! -f "$pid_a_file" ]]; then
        fail_test "setup failed: PID-A cache file not created" ""
        return
    fi

    # Ensure PID-A file is older so ls -t puts PID-B first when PID-B is created
    # Sleep 1s to guarantee mtime ordering
    sleep 1

    local fake_sid_b="test-pid-b-88888"
    bash -c "
        export CLAUDE_SESSION_ID='$fake_sid_b'
        source '${SOURCE_LIB}' 2>/dev/null || true
        require_session 2>/dev/null || true
        [[ \"\$(type -t write_statusline_cache)\" == 'function' ]] || source '${SESSION_LIB}'
        write_statusline_cache '${tmpdir}'
    " 2>/dev/null

    local pid_b_file="${tmpdir}/.claude/.statusline-cache-${fake_sid_b}"
    if [[ ! -f "$pid_b_file" ]]; then
        fail_test "PID-B cache file not created" ""
        return
    fi

    local b_tokens
    b_tokens=$(jq -r '.lifetime_tokens // 0' "$pid_b_file" 2>/dev/null || echo "0")

    if [[ "$b_tokens" == "5000000" ]]; then
        pass_test "cross-PID sibling fallback: PID-B cache inherits lifetime_tokens=5000000 from PID-A"
    else
        fail_test "cross-PID sibling fallback NOT working" \
            "PID-B cache has lifetime_tokens=$b_tokens (expected 5000000 from PID-A sibling)"
    fi
}

test_sibling_fallback_inherits_lifetime_cost() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    mkdir -p "$tmpdir/.claude"

    local fake_sid_a="test-cost-pid-a-77777"
    bash -c "
        export CLAUDE_SESSION_ID='$fake_sid_a'
        export LIFETIME_TOKENS=1000000
        export LIFETIME_COST=42.50
        source '${SOURCE_LIB}' 2>/dev/null || true
        require_session 2>/dev/null || true
        [[ \"\$(type -t write_statusline_cache)\" == 'function' ]] || source '${SESSION_LIB}'
        write_statusline_cache '${tmpdir}'
    " 2>/dev/null

    sleep 1

    local fake_sid_b="test-cost-pid-b-66666"
    bash -c "
        export CLAUDE_SESSION_ID='$fake_sid_b'
        source '${SOURCE_LIB}' 2>/dev/null || true
        require_session 2>/dev/null || true
        [[ \"\$(type -t write_statusline_cache)\" == 'function' ]] || source '${SESSION_LIB}'
        write_statusline_cache '${tmpdir}'
    " 2>/dev/null

    local pid_b_file="${tmpdir}/.claude/.statusline-cache-${fake_sid_b}"
    local b_cost
    b_cost=$(jq -r '.lifetime_cost // 0' "$pid_b_file" 2>/dev/null || echo "0")

    if [[ "$b_cost" == "42.5" || "$b_cost" == "42.50" ]]; then
        pass_test "cross-PID sibling fallback: lifetime_cost=42.50 inherited from sibling"
    else
        fail_test "lifetime_cost NOT inherited from sibling" \
            "got '$b_cost', expected 42.5"
    fi
}

test_sibling_fallback_does_not_override_explicit_set() {
    run_test
    # When the caller explicitly sets LIFETIME_TOKENS, the sibling value must NOT win.
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    mkdir -p "$tmpdir/.claude"

    local fake_sid_a="test-override-pid-a-55555"
    bash -c "
        export CLAUDE_SESSION_ID='$fake_sid_a'
        export LIFETIME_TOKENS=5000000
        source '${SOURCE_LIB}' 2>/dev/null || true
        require_session 2>/dev/null || true
        [[ \"\$(type -t write_statusline_cache)\" == 'function' ]] || source '${SESSION_LIB}'
        write_statusline_cache '${tmpdir}'
    " 2>/dev/null

    sleep 1

    local fake_sid_b="test-override-pid-b-44444"
    bash -c "
        export CLAUDE_SESSION_ID='$fake_sid_b'
        export LIFETIME_TOKENS=9999999
        source '${SOURCE_LIB}' 2>/dev/null || true
        require_session 2>/dev/null || true
        [[ \"\$(type -t write_statusline_cache)\" == 'function' ]] || source '${SESSION_LIB}'
        write_statusline_cache '${tmpdir}'
    " 2>/dev/null

    local pid_b_file="${tmpdir}/.claude/.statusline-cache-${fake_sid_b}"
    local b_tokens
    b_tokens=$(jq -r '.lifetime_tokens // 0' "$pid_b_file" 2>/dev/null || echo "0")

    if [[ "$b_tokens" == "9999999" ]]; then
        pass_test "explicit LIFETIME_TOKENS=9999999 wins over sibling's 5000000"
    else
        fail_test "explicit LIFETIME_TOKENS was overridden by sibling" \
            "got $b_tokens, expected 9999999"
    fi
}

test_sibling_fallback_no_false_positives_fresh_cache() {
    run_test
    # No sibling cache files → lifetime_tokens must default to 0 (no invented values).
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    mkdir -p "$tmpdir/.claude"

    local fake_sid="test-fresh-no-siblings-33333"
    bash -c "
        export CLAUDE_SESSION_ID='$fake_sid'
        source '${SOURCE_LIB}' 2>/dev/null || true
        require_session 2>/dev/null || true
        [[ \"\$(type -t write_statusline_cache)\" == 'function' ]] || source '${SESSION_LIB}'
        write_statusline_cache '${tmpdir}'
    " 2>/dev/null

    local cache_file="${tmpdir}/.claude/.statusline-cache-${fake_sid}"
    local tokens
    tokens=$(jq -r '.lifetime_tokens // 0' "$cache_file" 2>/dev/null || echo "0")

    if [[ "$tokens" == "0" ]]; then
        pass_test "fresh cache (no siblings) correctly defaults to lifetime_tokens=0"
    else
        fail_test "fresh cache has non-zero lifetime_tokens" \
            "got $tokens, expected 0 — sibling fallback must not invent values"
    fi
}

# ============================================================================
# Regression: DEC-LIFETIME-PERSIST-001 unchanged (own cache file primary)
# ============================================================================

test_own_cache_file_still_read_when_exists() {
    run_test
    # Same CLAUDE_SESSION_ID → own cache file → DEC-LIFETIME-PERSIST-001 behavior unchanged.
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    mkdir -p "$tmpdir/.claude"

    local stable_sid="test-stable-sid-22222"
    bash -c "
        export CLAUDE_SESSION_ID='$stable_sid'
        export LIFETIME_TOKENS=3000000
        source '${SOURCE_LIB}' 2>/dev/null || true
        require_session 2>/dev/null || true
        [[ \"\$(type -t write_statusline_cache)\" == 'function' ]] || source '${SESSION_LIB}'
        write_statusline_cache '${tmpdir}'
    " 2>/dev/null

    bash -c "
        export CLAUDE_SESSION_ID='$stable_sid'
        source '${SOURCE_LIB}' 2>/dev/null || true
        require_session 2>/dev/null || true
        [[ \"\$(type -t write_statusline_cache)\" == 'function' ]] || source '${SESSION_LIB}'
        write_statusline_cache '${tmpdir}'
    " 2>/dev/null

    local cache_file="${tmpdir}/.claude/.statusline-cache-${stable_sid}"
    local tokens
    tokens=$(jq -r '.lifetime_tokens // 0' "$cache_file" 2>/dev/null || echo "0")

    if [[ "$tokens" == "3000000" ]]; then
        pass_test "DEC-LIFETIME-PERSIST-001 unchanged: own cache preserves lifetime_tokens=3000000"
    else
        fail_test "DEC-LIFETIME-PERSIST-001 regression" \
            "got $tokens, expected 3000000"
    fi
}

# ============================================================================
# Shellcheck compliance
# ============================================================================

test_session_init_shellcheck() {
    run_test
    if ! command -v shellcheck >/dev/null 2>&1; then
        echo -e "  ${YELLOW}SKIP${NC} shellcheck not installed"
        TESTS_RUN=$(( TESTS_RUN - 1 ))
        return
    fi
    local output
    output=$(shellcheck -S warning "$SESSION_INIT" 2>&1 || true)
    local new_count
    new_count=$(echo "$output" \
        | { grep 'SC[0-9]' || true; } \
        | { grep -v 'UPD_TS\|UPD_SUMMARY\|LIFETIME_COST' || true; } \
        | wc -l | tr -d ' ')
    if [[ "${new_count:-0}" -eq 0 ]]; then
        pass_test "session-init.sh: no new shellcheck warnings"
    else
        local new_warnings
        new_warnings=$(echo "$output" | { grep -v 'UPD_TS\|UPD_SUMMARY\|LIFETIME_COST' || true; })
        fail_test "session-init.sh has $new_count new shellcheck warning(s)" "$new_warnings"
    fi
}

test_session_lib_shellcheck() {
    run_test
    if ! command -v shellcheck >/dev/null 2>&1; then
        echo -e "  ${YELLOW}SKIP${NC} shellcheck not installed"
        TESTS_RUN=$(( TESTS_RUN - 1 ))
        return
    fi
    local output
    output=$(shellcheck -S warning "$SESSION_LIB" 2>&1 || true)
    # Pre-existing warnings in session-lib.sh (present on main before this fix):
    #   SC2034 on PIVOT_COUNT, PIVOT_FILES, PIVOT_ASSERTIONS (globals set for callers)
    #   SC2034 on id (used in jq extraction loop)
    local new_count
    new_count=$(echo "$output" \
        | { grep 'SC[0-9]' || true; } \
        | { grep -v 'PIVOT_COUNT\|PIVOT_FILES\|PIVOT_ASSERTIONS\|SC2034.*id ' || true; } \
        | wc -l | tr -d ' ')
    if [[ "${new_count:-0}" -eq 0 ]]; then
        pass_test "session-lib.sh: no new shellcheck warnings from this fix"
    else
        local new_warnings
        new_warnings=$(echo "$output" | { grep -v 'PIVOT_COUNT\|PIVOT_FILES\|PIVOT_ASSERTIONS' || true; })
        fail_test "session-lib.sh has $new_count new shellcheck warning(s) from this fix" "$new_warnings"
    fi
}

# ============================================================================
# Run all tests
# ============================================================================

echo "Testing two-part fix: explicit SID extraction + cross-PID sibling cache fallback"
echo ""

echo "--- Part 1: session-init.sh explicit CLAUDE_SESSION_ID extraction ---"
test_explicit_sid_extraction_present
test_explicit_sid_extraction_after_hook_input
test_explicit_sid_extraction_functional
test_sid_guards_on_empty_hook_input

echo ""
echo "--- Part 2: session-lib.sh cross-PID sibling cache fallback ---"
test_sibling_fallback_present_in_source
test_sibling_fallback_inherits_lifetime_tokens
test_sibling_fallback_inherits_lifetime_cost
test_sibling_fallback_does_not_override_explicit_set
test_sibling_fallback_no_false_positives_fresh_cache

echo ""
echo "--- Regression: DEC-LIFETIME-PERSIST-001 unchanged ---"
test_own_cache_file_still_read_when_exists

echo ""
echo "--- Shellcheck compliance ---"
test_session_init_shellcheck
test_session_lib_shellcheck

echo ""
echo "========================================="
echo "Test Results:"
echo "  Total:  $TESTS_RUN"
echo -e "  ${GREEN}Passed: $TESTS_PASSED${NC}"
if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "  ${RED}Failed: $TESTS_FAILED${NC}"
else
    echo "  Failed: 0"
fi
echo "========================================="

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi
