#!/usr/bin/env bash
# test-session-label.sh — Tests for session-specific Line 3 label in statusline.
#
# Verifies:
#   1. track_subagent_start() writes ACTIVE record with 4th field (label)
#   2. get_subagent_status() populates SUBAGENT_ACTIVE_LABEL from tracker
#   3. write_statusline_cache() includes session_label field in JSON
#   4. statusline.sh renders session_label on Line 3 when present
#   5. statusline.sh falls back to initiative when no session_label
#
# @decision DEC-SESSION-LABEL-TEST-001
# @title Test session-specific Line 3 label via tracker → cache → statusline flow
# @status accepted
# @rationale The data flows through 3 files (session-lib.sh, statusline.sh, tracker).
# Testing each layer independently ensures each contract is met. Testing statusline.sh
# end-to-end (via controlled cache file) ensures the rendering is correct.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="${WORKTREE_ROOT}/hooks"
STATUSLINE="${WORKTREE_ROOT}/scripts/statusline.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass_test() { TESTS_PASSED=$(( TESTS_PASSED + 1 )); echo -e "${GREEN}PASS${NC} $1"; }
fail_test() { TESTS_FAILED=$(( TESTS_FAILED + 1 )); echo -e "${RED}FAIL${NC} $1"; echo -e "  ${YELLOW}Details:${NC} $2"; }
run_test()  { TESTS_RUN=$(( TESTS_RUN + 1 )); }

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# Load session-lib via source-lib.sh (the standard way used by all hooks)
source_session_lib() {
    # shellcheck disable=SC1090
    source "$HOOKS_DIR/source-lib.sh" 2>/dev/null || {
        echo "ERROR: Could not source $HOOKS_DIR/source-lib.sh" >&2
        exit 1
    }
    require_session
}

# Setup: isolated temp project root
setup_test_env() {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.claude"
    echo "$tmpdir"
}

cleanup_test_env() {
    local tmpdir="$1"
    rm -rf "$tmpdir"
}

# -------------------------------------------------------------------
# Test 1: track_subagent_start writes ACTIVE record with label (4-field format)
# -------------------------------------------------------------------
run_test
test_track_subagent_start_label() {
    local tmpdir
    tmpdir=$(setup_test_env)
    local sid="sess-label-t1-$$"

    (
        source_session_lib
        CLAUDE_SESSION_ID="$sid" track_subagent_start "$tmpdir" "implementer" "my-worktree"
    )

    local tracker="${tmpdir}/.claude/.subagent-tracker-${sid}"
    if [[ ! -f "$tracker" ]]; then
        fail_test "track_subagent_start with label: tracker file not created"
        cleanup_test_env "$tmpdir"
        return
    fi

    local record
    record=$(cat "$tracker")
    # Expect 4-field format: ACTIVE|implementer|<epoch>|my-worktree
    if echo "$record" | grep -qE "^ACTIVE\|implementer\|[0-9]+\|my-worktree$"; then
        pass_test "track_subagent_start writes 4-field ACTIVE record with label"
    else
        fail_test "track_subagent_start with label: record format wrong" "Got: '${record}'"
    fi

    cleanup_test_env "$tmpdir"
}
test_track_subagent_start_label

# -------------------------------------------------------------------
# Test 2: track_subagent_start backward compat — no label still writes 3-field
# -------------------------------------------------------------------
run_test
test_track_subagent_start_no_label() {
    local tmpdir
    tmpdir=$(setup_test_env)
    local sid="sess-label-t2-$$"

    (
        source_session_lib
        CLAUDE_SESSION_ID="$sid" track_subagent_start "$tmpdir" "implementer"
    )

    local tracker="${tmpdir}/.claude/.subagent-tracker-${sid}"
    if [[ ! -f "$tracker" ]]; then
        fail_test "track_subagent_start without label: tracker file not created"
        cleanup_test_env "$tmpdir"
        return
    fi

    local record
    record=$(cat "$tracker")
    # Old 3-field format: ACTIVE|implementer|<epoch>  (no 4th field)
    if echo "$record" | grep -qE "^ACTIVE\|implementer\|[0-9]+$"; then
        pass_test "track_subagent_start without label: writes 3-field record (backward compat)"
    else
        fail_test "track_subagent_start without label: unexpected record format" "Got: '${record}'"
    fi

    cleanup_test_env "$tmpdir"
}
test_track_subagent_start_no_label

# -------------------------------------------------------------------
# Test 3: get_subagent_status populates SUBAGENT_ACTIVE_LABEL from 4-field tracker
# -------------------------------------------------------------------
run_test
test_get_subagent_status_label() {
    local tmpdir
    tmpdir=$(setup_test_env)
    local sid="sess-label-t3-$$"

    # Write a 4-field tracker record directly
    echo "ACTIVE|implementer|1700000000|eff-noise-reduction" > "${tmpdir}/.claude/.subagent-tracker-${sid}"

    local label
    label=$(
        source_session_lib
        CLAUDE_SESSION_ID="$sid" get_subagent_status "$tmpdir"
        echo "${SUBAGENT_ACTIVE_LABEL:-}"
    )

    if [[ "$label" == "eff-noise-reduction" ]]; then
        pass_test "get_subagent_status populates SUBAGENT_ACTIVE_LABEL from 4-field record"
    else
        fail_test "get_subagent_status SUBAGENT_ACTIVE_LABEL wrong" "Expected 'eff-noise-reduction', got '${label}'"
    fi

    cleanup_test_env "$tmpdir"
}
test_get_subagent_status_label

# -------------------------------------------------------------------
# Test 4: get_subagent_status returns empty label for 3-field (old format) records
# -------------------------------------------------------------------
run_test
test_get_subagent_status_no_label() {
    local tmpdir
    tmpdir=$(setup_test_env)
    local sid="sess-label-t4-$$"

    # Write a 3-field record (old format without label)
    echo "ACTIVE|implementer|1700000000" > "${tmpdir}/.claude/.subagent-tracker-${sid}"

    local label
    label=$(
        source_session_lib
        CLAUDE_SESSION_ID="$sid" get_subagent_status "$tmpdir"
        echo "${SUBAGENT_ACTIVE_LABEL:-}"
    )

    if [[ -z "$label" ]]; then
        pass_test "get_subagent_status returns empty label for 3-field (old format) records"
    else
        fail_test "get_subagent_status: expected empty label for 3-field record" "Got: '${label}'"
    fi

    cleanup_test_env "$tmpdir"
}
test_get_subagent_status_no_label

# -------------------------------------------------------------------
# Test 5: get_subagent_status uses MOST RECENT (last) active entry's label
# -------------------------------------------------------------------
run_test
test_get_subagent_status_last_label() {
    local tmpdir
    tmpdir=$(setup_test_env)
    local sid="sess-label-t5-$$"

    # Multiple active entries — last one wins
    {
        printf 'ACTIVE|implementer|1700000001|first-label\n'
        printf 'ACTIVE|tester|1700000002|second-label\n'
    } > "${tmpdir}/.claude/.subagent-tracker-${sid}"

    local label
    label=$(
        source_session_lib
        CLAUDE_SESSION_ID="$sid" get_subagent_status "$tmpdir"
        echo "${SUBAGENT_ACTIVE_LABEL:-}"
    )

    if [[ "$label" == "second-label" ]]; then
        pass_test "get_subagent_status uses last active entry's label"
    else
        fail_test "get_subagent_status: expected 'second-label' from last entry" "Got: '${label}'"
    fi

    cleanup_test_env "$tmpdir"
}
test_get_subagent_status_last_label

# -------------------------------------------------------------------
# Test 5b: labeled entry followed by unlabeled entry (the actual bug)
# -------------------------------------------------------------------
run_test
test_get_subagent_status_labeled_then_unlabeled() {
    local tmpdir
    tmpdir=$(setup_test_env)
    local sid="sess-label-t5b-$$"

    # Bug scenario: implementer dispatched with worktree label, then Explore
    # dispatched without one. The original tail -1 | cut returned empty.
    {
        printf 'ACTIVE|implementer|1700000001|my-worktree\n'
        printf 'ACTIVE|Explore|1700000002\n'
    } > "${tmpdir}/.claude/.subagent-tracker-${sid}"

    local label
    label=$(
        source_session_lib
        CLAUDE_SESSION_ID="$sid" get_subagent_status "$tmpdir"
        echo "${SUBAGENT_ACTIVE_LABEL:-}"
    )

    if [[ "$label" == "my-worktree" ]]; then
        pass_test "get_subagent_status preserves label when later entry has none"
    else
        fail_test "get_subagent_status: labeled+unlabeled should return 'my-worktree'" "Got: '${label}'"
    fi

    cleanup_test_env "$tmpdir"
}
test_get_subagent_status_labeled_then_unlabeled

# -------------------------------------------------------------------
# Test 6: write_statusline_cache includes session_label field in JSON
# -------------------------------------------------------------------
run_test
test_write_statusline_cache_session_label() {
    local tmpdir
    tmpdir=$(setup_test_env)
    local sid="sess-label-t6-$$"

    # Write a 4-field tracker so get_subagent_status picks up the label
    echo "ACTIVE|implementer|1700000000|my-worktree" > "${tmpdir}/.claude/.subagent-tracker-${sid}"

    (
        source_session_lib
        GIT_DIRTY_COUNT=0 GIT_WT_COUNT=1 CLAUDE_SESSION_ID="$sid" \
            write_statusline_cache "$tmpdir"
    )

    local cache_file="${tmpdir}/.claude/.statusline-cache-${sid}"
    if [[ ! -f "$cache_file" ]]; then
        fail_test "write_statusline_cache: cache file not created at ${cache_file}"
        cleanup_test_env "$tmpdir"
        return
    fi

    local session_label
    session_label=$(jq -r '.session_label // ""' "$cache_file" 2>/dev/null)

    if [[ "$session_label" == "my-worktree" ]]; then
        pass_test "write_statusline_cache includes session_label field in JSON"
    else
        fail_test "write_statusline_cache: session_label field wrong" \
            "Expected 'my-worktree', got '${session_label}'. Cache: $(cat "$cache_file" 2>/dev/null | head -c 300)"
    fi

    cleanup_test_env "$tmpdir"
}
test_write_statusline_cache_session_label

# -------------------------------------------------------------------
# Test 7: write_statusline_cache session_label is empty when no agents active
# -------------------------------------------------------------------
run_test
test_write_statusline_cache_empty_label() {
    local tmpdir
    tmpdir=$(setup_test_env)
    local sid="sess-label-t7-$$"

    # No tracker file = no active agents
    (
        source_session_lib
        GIT_DIRTY_COUNT=0 GIT_WT_COUNT=0 CLAUDE_SESSION_ID="$sid" \
            write_statusline_cache "$tmpdir"
    )

    local cache_file="${tmpdir}/.claude/.statusline-cache-${sid}"
    if [[ ! -f "$cache_file" ]]; then
        fail_test "write_statusline_cache (empty): cache file not created"
        cleanup_test_env "$tmpdir"
        return
    fi

    local session_label
    session_label=$(jq -r '.session_label // ""' "$cache_file" 2>/dev/null)

    if [[ -z "$session_label" ]]; then
        pass_test "write_statusline_cache session_label is empty when no agents active"
    else
        fail_test "write_statusline_cache: expected empty session_label" "Got: '${session_label}'"
    fi

    cleanup_test_env "$tmpdir"
}
test_write_statusline_cache_empty_label

# -------------------------------------------------------------------
# Test 8: statusline.sh renders session_label on Line 3 (instead of initiative)
# -------------------------------------------------------------------
run_test
test_statusline_renders_session_label() {
    local tmpdir
    tmpdir=$(setup_test_env)
    local sid="test-statusline-label-$$"

    local cache_file="${tmpdir}/.claude/.statusline-cache-${sid}"
    jq -n '{
        dirty: 0,
        worktrees: 1,
        updated: 0,
        agents_active: 1,
        agents_types: "implementer",
        agents_total: 1,
        todo_project: 0,
        todo_global: 0,
        lifetime_cost: 0,
        lifetime_tokens: 0,
        initiative: "Governor Subagent",
        phase: "Phase 1: Initial",
        active_initiatives: 1,
        total_phases: 3,
        session_label: "eff-noise-reduction"
    }' > "$cache_file"

    local json
    json=$(printf '{"model":{"display_name":"claude-sonnet-4-5"},"workspace":{"current_dir":"%s"},"cost":{"total_cost_usd":0.01,"total_duration_ms":1000,"total_lines_added":5,"total_lines_removed":2},"context_window":{"used_percentage":10,"current_usage":{"cache_read_input_tokens":0,"input_tokens":10000,"cache_creation_input_tokens":0},"total_input_tokens":10000,"total_output_tokens":500}}' "$tmpdir")

    local output
    output=$(printf '%s' "$json" | COLUMNS=200 HOME="$tmpdir" CLAUDE_SESSION_ID="$sid" bash "$STATUSLINE" 2>/dev/null | strip_ansi)

    local line3
    line3=$(echo "$output" | tail -1)

    if echo "$line3" | grep -q "eff-noise-reduction"; then
        pass_test "statusline renders session_label on Line 3 when present"
    else
        fail_test "statusline Line 3 should show session_label" \
            "Line 3: '${line3}'"
    fi

    # Verify it does NOT show the initiative name when session_label is set
    if ! echo "$line3" | grep -q "Governor Subagent"; then
        pass_test "statusline Line 3 does NOT show initiative when session_label is set"
    else
        fail_test "statusline Line 3 should NOT show initiative when session_label set" "Line 3: '${line3}'"
    fi

    cleanup_test_env "$tmpdir"
}
test_statusline_renders_session_label

# -------------------------------------------------------------------
# Test 9: statusline.sh falls back to initiative when session_label is empty
# -------------------------------------------------------------------
run_test
test_statusline_falls_back_to_initiative() {
    local tmpdir
    tmpdir=$(setup_test_env)
    local sid="test-statusline-label-$$"

    local cache_file="${tmpdir}/.claude/.statusline-cache-${sid}"
    jq -n '{
        dirty: 0,
        worktrees: 1,
        updated: 0,
        agents_active: 0,
        agents_types: "",
        agents_total: 0,
        todo_project: 0,
        todo_global: 0,
        lifetime_cost: 0,
        lifetime_tokens: 0,
        initiative: "Governor Subagent",
        phase: "Phase 1: Initial",
        active_initiatives: 1,
        total_phases: 3,
        session_label: ""
    }' > "$cache_file"

    local json
    json=$(printf '{"model":{"display_name":"claude-sonnet-4-5"},"workspace":{"current_dir":"%s"},"cost":{"total_cost_usd":0.01,"total_duration_ms":1000,"total_lines_added":5,"total_lines_removed":2},"context_window":{"used_percentage":10,"current_usage":{"cache_read_input_tokens":0,"input_tokens":10000,"cache_creation_input_tokens":0},"total_input_tokens":10000,"total_output_tokens":500}}' "$tmpdir")

    local output
    output=$(printf '%s' "$json" | COLUMNS=200 HOME="$tmpdir" CLAUDE_SESSION_ID="$sid" bash "$STATUSLINE" 2>/dev/null | strip_ansi)

    local line3
    line3=$(echo "$output" | tail -1)

    if echo "$line3" | grep -q "Governor Subagent"; then
        pass_test "statusline falls back to initiative when session_label is empty"
    else
        fail_test "statusline should fall back to initiative" "Line 3: '${line3}', Full output: $(echo "$output" | head -c 300)"
    fi

    cleanup_test_env "$tmpdir"
}
test_statusline_falls_back_to_initiative

# -------------------------------------------------------------------
# Test 10: track_subagent_stop still works with 4-field ACTIVE records
# -------------------------------------------------------------------
run_test
test_track_subagent_stop_4field() {
    local tmpdir
    tmpdir=$(setup_test_env)
    local sid="sess-label-t10-$$"

    echo "ACTIVE|implementer|1700000000|my-worktree" > "${tmpdir}/.claude/.subagent-tracker-${sid}"

    (
        source_session_lib
        CLAUDE_SESSION_ID="$sid" track_subagent_stop "$tmpdir" "implementer"
    )

    local tracker="${tmpdir}/.claude/.subagent-tracker-${sid}"

    # After stop, should have a DONE record (not ACTIVE)
    local done_record
    done_record=$(grep "^DONE|implementer|" "$tracker" 2>/dev/null || echo "")

    if [[ -n "$done_record" ]]; then
        pass_test "track_subagent_stop converts 4-field ACTIVE to DONE record"
    else
        fail_test "track_subagent_stop: DONE record not found after stopping 4-field entry" \
            "Tracker: $(cat "$tracker" 2>/dev/null)"
    fi

    # Verify no ACTIVE records remain
    local active_lines
    active_lines=$(grep "^ACTIVE|" "$tracker" 2>/dev/null || true)
    if [[ -z "$active_lines" ]]; then
        pass_test "track_subagent_stop: no ACTIVE records remain after stop"
    else
        fail_test "track_subagent_stop: ACTIVE records still present" "Records: ${active_lines}"
    fi

    cleanup_test_env "$tmpdir"
}
test_track_subagent_stop_4field

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
echo ""
echo "Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed out of ${TESTS_RUN} tests"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
