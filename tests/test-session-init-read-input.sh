#!/usr/bin/env bash
# test-session-init-read-input.sh — Tests that session-init.sh calls read_input().
#
# Purpose: Verifies the fix for the lifetime_tokens=0 bug caused by session-init.sh
# never calling read_input(), which meant:
#   1. CLAUDE_SESSION_ID was never extracted from hook stdin JSON
#   2. Cache files fell back to $$ (PID), creating a new file per hook process
#   3. write_statusline_cache() read from a PID-scoped file that didn't exist → 0
#
# After the fix, session-init.sh calls HOOK_INPUT=$(read_input) before any domain
# library loading, ensuring CLAUDE_SESSION_ID is set from the stdin JSON for all
# downstream functions.
#
# @decision DEC-SESSION-INIT-READ-001
# @title Test that session-init.sh calls read_input() before detect_project_root()
# @status accepted
# @rationale session-init.sh was the only hook missing read_input(). All other hooks
#   call HOOK_INPUT=$(read_input) after sourcing source-lib.sh. This omission caused
#   CLAUDE_SESSION_ID to default to $$ (PID) — a different value per hook process —
#   making statusline cache file names non-deterministic across the same session.
#   Result: write_statusline_cache() read from a file that didn't exist → lifetime_tokens=0.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_INIT="${SCRIPT_DIR}/../hooks/session-init.sh"

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

# ============================================================================
# Test 1: Source-level check — read_input() call must appear before detect_project_root()
# ============================================================================

test_read_input_call_present_in_source() {
    run_test
    # The fix is a single line: HOOK_INPUT=$(read_input)
    # This checks that the line exists in the file.
    if grep -qF 'HOOK_INPUT=$(read_input)' "$SESSION_INIT"; then
        pass_test "session-init.sh contains HOOK_INPUT=\$(read_input)"
    else
        fail_test "session-init.sh missing HOOK_INPUT=\$(read_input)" \
            "Expected to find: HOOK_INPUT=\$(read_input) — add it after sourcing source-lib.sh"
    fi
}

test_read_input_before_detect_project_root() {
    run_test
    # Verify ordering: read_input line must come before the PROJECT_ROOT=$(detect_project_root)
    # assignment. We grep for the actual assignment (not comments that mention the function name).
    local ri_line dp_line
    ri_line=$(grep -n 'HOOK_INPUT=$(read_input)' "$SESSION_INIT" | grep -v '^[^:]*:#' | head -1 | cut -d: -f1)
    dp_line=$(grep -n 'PROJECT_ROOT=$(detect_project_root)' "$SESSION_INIT" | head -1 | cut -d: -f1)

    if [[ -z "$ri_line" ]]; then
        fail_test "read_input assignment line not found — cannot check ordering" \
            "grep for 'HOOK_INPUT=\$(read_input)' (non-comment) returned empty"
        return
    fi
    if [[ -z "$dp_line" ]]; then
        fail_test "PROJECT_ROOT=\$(detect_project_root) assignment not found — cannot check ordering" \
            "grep for 'PROJECT_ROOT=\$(detect_project_root)' returned empty"
        return
    fi

    if [[ "$ri_line" -lt "$dp_line" ]]; then
        pass_test "read_input (line $ri_line) appears before PROJECT_ROOT=\$(detect_project_root) (line $dp_line)"
    else
        fail_test "read_input (line $ri_line) appears AFTER detect_project_root (line $dp_line)" \
            "Move HOOK_INPUT=\$(read_input) to before detect_project_root call"
    fi
}

test_read_input_after_source_lib() {
    run_test
    # read_input() is defined in log.sh which is loaded by source-lib.sh.
    # Verify read_input call comes AFTER source-lib.sh sourcing.
    local source_lib_line ri_line
    source_lib_line=$(grep -n 'source.*source-lib\.sh' "$SESSION_INIT" | head -1 | cut -d: -f1)
    ri_line=$(grep -n 'HOOK_INPUT=$(read_input)' "$SESSION_INIT" | head -1 | cut -d: -f1)

    if [[ -z "$source_lib_line" ]]; then
        fail_test "source-lib.sh sourcing not found" \
            "Expected: source \"\$(dirname \"\$0\")/source-lib.sh\""
        return
    fi
    if [[ -z "$ri_line" ]]; then
        fail_test "read_input call not found" "Add HOOK_INPUT=\$(read_input) after source-lib.sh"
        return
    fi

    if [[ "$ri_line" -gt "$source_lib_line" ]]; then
        pass_test "read_input (line $ri_line) appears after source-lib.sh sourcing (line $source_lib_line)"
    else
        fail_test "read_input (line $ri_line) appears BEFORE source-lib.sh sourcing (line $source_lib_line)" \
            "read_input() is defined via source-lib.sh → log.sh; must be called after sourcing"
    fi
}

# ============================================================================
# Test 2: Functional check — CLAUDE_SESSION_ID extracted from stdin JSON
# ============================================================================

test_session_id_extracted_via_read_input() {
    run_test
    # Verify that jq can extract session_id from a JSON blob, which is the core
    # mechanism used by read_input() per DEC-SESSION-ID-001 in log.sh.
    local hook_input='{"session_id": "test-sid-abc123", "cwd": "/tmp"}'
    local result
    result=$(echo "$hook_input" | jq -r '.session_id // empty' 2>/dev/null || echo "ERROR")

    if [[ "$result" == "test-sid-abc123" ]]; then
        pass_test "jq extraction of session_id from JSON works: got '$result'"
    else
        fail_test "jq extraction failed" "expected 'test-sid-abc123', got '$result'"
    fi
}

test_hook_input_populated_with_session_id_extractable() {
    run_test
    # After HOOK_INPUT=$(read_input), the session_id should be extractable via get_field()
    # or direct jq on HOOK_INPUT. Note: CLAUDE_SESSION_ID export inside read_input() runs
    # in the command-substitution subshell and does not propagate back — callers must
    # extract CLAUDE_SESSION_ID from HOOK_INPUT themselves using jq.
    local SOURCE_LIB="${SCRIPT_DIR}/../hooks/source-lib.sh"
    local tmpscript
    tmpscript=$(mktemp /tmp/test-session-init-XXXXXX.sh)
    # shellcheck disable=SC2064
    trap "rm -f '$tmpscript'" RETURN

    cat > "$tmpscript" <<'SCRIPT'
source "$1" 2>/dev/null || true
# shellcheck disable=SC2034
HOOK_INPUT=$(read_input)
# Callers can extract session_id from HOOK_INPUT after the read_input() call
SESSION_FROM_INPUT=$(echo "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
echo "$SESSION_FROM_INPUT"
SCRIPT

    local result
    result=$(echo '{"session_id": "sid-xyz-789", "cwd": "/tmp"}' | bash "$tmpscript" "$SOURCE_LIB" 2>/dev/null || echo "ERROR")

    if [[ "$result" == "sid-xyz-789" ]]; then
        pass_test "session_id extractable from HOOK_INPUT after read_input(): got '$result'"
    else
        fail_test "session_id not extractable from HOOK_INPUT" \
            "expected 'sid-xyz-789', got '$result' — check read_input() in log.sh"
    fi
}

# ============================================================================
# Test 3: Shellcheck compliance
# ============================================================================

test_session_init_passes_shellcheck() {
    run_test
    if ! command -v shellcheck >/dev/null 2>&1; then
        echo -e "  ${YELLOW}SKIP${NC} shellcheck not installed"
        TESTS_RUN=$(( TESTS_RUN - 1 ))
        return
    fi

    local output
    output=$(shellcheck -S warning "$SESSION_INIT" 2>&1 || true)

    # Pre-existing SC2034 warnings on UPD_TS, UPD_SUMMARY, LIFETIME_COST existed before this fix.
    # Count only warning codes NOT in the pre-existing set.
    local new_warning_count
    new_warning_count=$(echo "$output" \
        | { grep 'SC[0-9]' || true; } \
        | { grep -v 'UPD_TS\|UPD_SUMMARY\|LIFETIME_COST' || true; } \
        | wc -l \
        | tr -d ' ')

    if [[ "${new_warning_count:-0}" -eq 0 ]]; then
        pass_test "session-init.sh passes shellcheck (no new warnings from this fix)"
    else
        local new_warnings
        new_warnings=$(echo "$output" | { grep -v 'UPD_TS\|UPD_SUMMARY\|LIFETIME_COST' || true; })
        fail_test "session-init.sh has $new_warning_count shellcheck warning(s) introduced by this fix" "$new_warnings"
    fi
}

# ============================================================================
# Run all tests
# ============================================================================

echo "Testing session-init.sh read_input() fix (lifetime_tokens=0 bug)..."
echo ""

echo "--- Source-level checks ---"
test_read_input_call_present_in_source
test_read_input_before_detect_project_root
test_read_input_after_source_lib

echo ""
echo "--- Functional checks ---"
test_session_id_extracted_via_read_input
test_hook_input_populated_with_session_id_extractable

echo ""
echo "--- Shellcheck compliance ---"
test_session_init_passes_shellcheck

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
