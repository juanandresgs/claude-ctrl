#!/usr/bin/env bash
# test-event-schema.sh — Schema compliance tests for session event log (W3-5)
#
# Purpose: Validates that every event type emitted by append_session_event()
# conforms to the v2 session event schema. Tests structural requirements:
# required fields, value constraints, and graceful degradation on malformed input.
# Also validates get_session_trajectory() aggregate counts and the `commit` event
# emitted by check-guardian.sh (W3-1).
#
# Hook type: Test suite (standalone)
# Trigger: Run directly: bash tests/test-event-schema.sh
# Input: None (uses synthetic temp dirs, no live session state)
# Output: Pass/fail per test + summary counts
#
# @decision DEC-V2-SCHEMA-001
# @title Schema compliance tests validate event structure at unit level
# @status accepted
# @rationale The session event log is consumed by get_session_trajectory(),
# get_session_summary_context(), detect_approach_pivots(), and the session
# archive. These consumers rely on specific field names and value constraints.
# Unit tests here catch schema drift early — before hook integration tests
# would catch it — and document the contract explicitly. Tests write raw JSON
# directly (not via append_session_event) to avoid subshell/export-f stdout
# pollution when sourcing context-lib.sh. Only get_session_trajectory() and
# get_session_summary_context() are tested via the lib (they need the full
# parsing logic).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTEXT_LIB="${SCRIPT_DIR}/../hooks/context-lib.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0

# Cleanup trap (DEC-PROD-002): collect temp dirs and remove on exit
_CLEANUP_DIRS=()
trap '[[ ${#_CLEANUP_DIRS[@]} -gt 0 ]] && rm -rf "${_CLEANUP_DIRS[@]}" 2>/dev/null; true' EXIT
TESTS_FAILED=0

pass_test() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}PASS${NC} $1"
}

fail_test() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}FAIL${NC} $1"
    echo -e "  ${YELLOW}Details:${NC} $2"
}

run_test() {
    TESTS_RUN=$((TESTS_RUN + 1))
}

# Create a temp project root with .claude/ dir
make_project() {
    local dir
    dir=$(mktemp -d)
    mkdir -p "$dir/.claude"
    echo "$dir"
}

# Write a raw event line directly to the event log
# This mirrors what append_session_event() produces, allowing us to test
# consumers without triggering subshell/export-f stdout pollution.
emit_raw() {
    local dir="$1"
    local json="$2"
    echo "$json" >> "$dir/.claude/.session-events.jsonl"
}

# Emit via append_session_event() by running it in a clean child process.
# Uses a wrapper script to avoid exporting function bodies to stdout.
emit_via_lib() {
    local dir="$1"
    local event_type="$2"
    local detail="${3:-'{}'}"
    bash -c "
        source '$CONTEXT_LIB' >/dev/null 2>&1
        append_session_event '$event_type' '$detail' '$dir' >/dev/null 2>&1
    " 2>/dev/null
}

# Call get_session_trajectory in a clean child process, capturing KEY=VALUE output
call_trajectory() {
    local dir="$1"
    bash -c "
        source '$CONTEXT_LIB' >/dev/null 2>&1
        get_session_trajectory '$dir' >/dev/null 2>&1
        echo \"TRAJ_TOOL_CALLS=\${TRAJ_TOOL_CALLS:-0}\"
        echo \"TRAJ_FILES_MODIFIED=\${TRAJ_FILES_MODIFIED:-0}\"
        echo \"TRAJ_GATE_BLOCKS=\${TRAJ_GATE_BLOCKS:-0}\"
        echo \"TRAJ_TEST_FAILURES=\${TRAJ_TEST_FAILURES:-0}\"
        echo \"TRAJ_CHECKPOINTS=\${TRAJ_CHECKPOINTS:-0}\"
        echo \"TRAJ_REWINDS=\${TRAJ_REWINDS:-0}\"
        echo \"TRAJ_AGENTS=\${TRAJ_AGENTS:-}\"
    " 2>/dev/null
}

# Extract a jq field from a JSON string
get_field() {
    local json="$1"
    local field="$2"
    echo "$json" | jq -r "$field // empty" 2>/dev/null
}

# ============================================================================
# Test 1: Every event emitted by append_session_event has `ts` and `event`
# ============================================================================

test_required_fields_ts_event() {
    run_test

    local dir
    dir=$(make_project)
    trap "rm -rf '$dir'" RETURN

    # Use raw emit with a known-good ISO8601 timestamp
    emit_raw "$dir" '{"ts":"2026-02-19T10:00:00Z","event":"write","file":"hooks/guard.sh"}'

    local line
    line=$(tail -1 "$dir/.claude/.session-events.jsonl" 2>/dev/null || echo "")

    local ts event
    ts=$(get_field "$line" ".ts")
    event=$(get_field "$line" ".event")

    if [[ -z "$ts" || -z "$event" ]]; then
        fail_test "Required fields ts/event" "ts='$ts' event='$event' line='$line'"
        return
    fi

    # ISO8601 format: YYYY-MM-DDTHH:MM:SSZ
    if ! echo "$ts" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
        fail_test "ts field ISO8601 format" "ts='$ts' does not match YYYY-MM-DDTHH:MM:SSZ"
        return
    fi

    pass_test "Every event has ts (ISO8601) and event fields"
}

# ============================================================================
# Test 2: append_session_event produces valid ISO8601 ts via lib
# ============================================================================

test_lib_produces_valid_ts() {
    run_test

    local dir
    dir=$(make_project)
    trap "rm -rf '$dir'" RETURN

    emit_via_lib "$dir" "write" '{"file":"hooks/guard.sh"}'

    if [[ ! -f "$dir/.claude/.session-events.jsonl" ]]; then
        fail_test "append_session_event creates event file" "File not created"
        return
    fi

    local line
    line=$(tail -1 "$dir/.claude/.session-events.jsonl" 2>/dev/null || echo "")

    if [[ -z "$line" ]]; then
        fail_test "append_session_event writes a line" "File is empty"
        return
    fi

    local ts event
    ts=$(get_field "$line" ".ts")
    event=$(get_field "$line" ".event")

    if ! echo "$ts" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
        fail_test "append_session_event ts is ISO8601" "ts='$ts'"
        return
    fi

    if [[ "$event" != "write" ]]; then
        fail_test "append_session_event event field correct" "event='$event'"
        return
    fi

    pass_test "append_session_event produces valid ISO8601 ts via lib"
}

# ============================================================================
# Test 3: `write` events have `file` field (string)
# ============================================================================

test_write_event_has_file() {
    run_test

    local dir
    dir=$(make_project)
    trap "rm -rf '$dir'" RETURN

    emit_raw "$dir" '{"ts":"2026-02-19T10:00:00Z","event":"write","file":"hooks/guard.sh"}'

    local line
    line=$(tail -1 "$dir/.claude/.session-events.jsonl")

    local file_val
    file_val=$(get_field "$line" ".file")

    if [[ "$file_val" == "hooks/guard.sh" ]]; then
        pass_test "write event has file field (string)"
    else
        fail_test "write event missing file field" "file='$file_val' line='$line'"
    fi
}

# ============================================================================
# Test 4: `test_run` events have `result` (pass|fail) and `failures` (number)
# ============================================================================

test_test_run_event_schema() {
    run_test

    local dir
    dir=$(make_project)
    trap "rm -rf '$dir'" RETURN

    emit_raw "$dir" '{"ts":"2026-02-19T10:00:00Z","event":"test_run","result":"fail","failures":3,"assertion":"test_auth"}'

    local line
    line=$(tail -1 "$dir/.claude/.session-events.jsonl")

    local result failures
    result=$(get_field "$line" ".result")
    failures=$(get_field "$line" ".failures")

    if [[ "$result" != "fail" && "$result" != "pass" ]]; then
        fail_test "test_run result is pass|fail" "result='$result' line='$line'"
        return
    fi

    if ! echo "$failures" | grep -qE '^[0-9]+$'; then
        fail_test "test_run failures is a number" "failures='$failures' line='$line'"
        return
    fi

    pass_test "test_run event has result (pass|fail) and failures (number)"
}

# ============================================================================
# Test 5: `gate_eval` events have `hook` and `result` (allow|block)
# ============================================================================

test_gate_eval_event_schema() {
    run_test

    local dir
    dir=$(make_project)
    trap "rm -rf '$dir'" RETURN

    emit_raw "$dir" '{"ts":"2026-02-19T10:00:00Z","event":"gate_eval","hook":"guard.sh","result":"block"}'

    local line
    line=$(tail -1 "$dir/.claude/.session-events.jsonl")

    local hook result
    hook=$(get_field "$line" ".hook")
    result=$(get_field "$line" ".result")

    if [[ -z "$hook" ]]; then
        fail_test "gate_eval event has hook field" "hook='$hook' line='$line'"
        return
    fi

    if [[ "$result" != "allow" && "$result" != "block" ]]; then
        fail_test "gate_eval result is allow|block" "result='$result' line='$line'"
        return
    fi

    pass_test "gate_eval event has hook and result (allow|block)"
}

# ============================================================================
# Test 6: `agent_start` events have `type` field
# ============================================================================

test_agent_start_event_schema() {
    run_test

    local dir
    dir=$(make_project)
    trap "rm -rf '$dir'" RETURN

    emit_raw "$dir" '{"ts":"2026-02-19T10:00:00Z","event":"agent_start","type":"implementer"}'

    local line
    line=$(tail -1 "$dir/.claude/.session-events.jsonl")

    local type_val
    type_val=$(get_field "$line" ".type")

    if [[ -n "$type_val" ]]; then
        pass_test "agent_start event has type field"
    else
        fail_test "agent_start event missing type field" "line='$line'"
    fi
}

# ============================================================================
# Test 7: `checkpoint` events have `ref` field
# ============================================================================

test_checkpoint_event_schema() {
    run_test

    local dir
    dir=$(make_project)
    trap "rm -rf '$dir'" RETURN

    emit_raw "$dir" '{"ts":"2026-02-19T10:00:00Z","event":"checkpoint","ref":"claude/cp/feature-test/1"}'

    local line
    line=$(tail -1 "$dir/.claude/.session-events.jsonl")

    local ref_val
    ref_val=$(get_field "$line" ".ref")

    if [[ -n "$ref_val" ]]; then
        pass_test "checkpoint event has ref field"
    else
        fail_test "checkpoint event missing ref field" "line='$line'"
    fi
}

# ============================================================================
# Test 8: Malformed JSON detail gracefully degrades (jq fallback path)
# ============================================================================

test_malformed_json_graceful_fallback() {
    run_test

    local dir
    dir=$(make_project)
    trap "rm -rf '$dir'" RETURN

    # Pass malformed JSON to append_session_event — it should produce a
    # minimal fallback event with at least ts and event fields (not crash).
    bash -c "
        source '$CONTEXT_LIB' >/dev/null 2>&1
        append_session_event 'write' 'THIS IS NOT JSON' '$dir' >/dev/null 2>&1
    " 2>/dev/null

    if [[ ! -f "$dir/.claude/.session-events.jsonl" ]]; then
        fail_test "Malformed JSON fallback: event file created" "File not found"
        return
    fi

    local line
    line=$(tail -1 "$dir/.claude/.session-events.jsonl" 2>/dev/null || echo "")

    if [[ -z "$line" ]]; then
        fail_test "Malformed JSON fallback: line written" "File is empty"
        return
    fi

    # Fallback produces {"ts":"...","event":"write"} — must be valid JSON
    if ! echo "$line" | jq . >/dev/null 2>&1; then
        fail_test "Malformed JSON fallback: output is valid JSON" "line='$line'"
        return
    fi

    local ts_val event_val
    ts_val=$(get_field "$line" ".ts")
    event_val=$(get_field "$line" ".event")

    if [[ -n "$ts_val" && "$event_val" == "write" ]]; then
        pass_test "Malformed JSON detail gracefully degrades to fallback event"
    else
        fail_test "Malformed JSON fallback has ts+event" \
            "ts='$ts_val' event='$event_val' line='$line'"
    fi
}

# ============================================================================
# Test 9: get_session_trajectory() counts match expected for synthetic log
# ============================================================================

test_trajectory_counts_match() {
    run_test

    local dir
    dir=$(make_project)
    trap "rm -rf '$dir'" RETURN

    # Synthetic log: 4 writes (3 unique files), 2 checkpoints, 1 test_fail, 1 gate_block
    emit_raw "$dir" '{"ts":"2026-02-19T10:00:00Z","event":"write","file":"hooks/guard.sh"}'
    emit_raw "$dir" '{"ts":"2026-02-19T10:01:00Z","event":"write","file":"hooks/context-lib.sh"}'
    emit_raw "$dir" '{"ts":"2026-02-19T10:02:00Z","event":"checkpoint","ref":"claude/cp/feat/1"}'
    emit_raw "$dir" '{"ts":"2026-02-19T10:03:00Z","event":"write","file":"hooks/guard.sh"}'
    emit_raw "$dir" '{"ts":"2026-02-19T10:04:00Z","event":"test_run","result":"fail","failures":2,"assertion":"test_guard"}'
    emit_raw "$dir" '{"ts":"2026-02-19T10:05:00Z","event":"gate_eval","hook":"guard.sh","result":"block"}'
    emit_raw "$dir" '{"ts":"2026-02-19T10:06:00Z","event":"write","file":"tests/test-gate.sh"}'
    emit_raw "$dir" '{"ts":"2026-02-19T10:07:00Z","event":"checkpoint","ref":"claude/cp/feat/2"}'

    local traj_output
    traj_output=$(call_trajectory "$dir")

    local tool_calls files_mod gate_blocks test_fails checkpoints
    tool_calls=$(echo "$traj_output" | grep '^TRAJ_TOOL_CALLS=' | cut -d= -f2)
    files_mod=$(echo "$traj_output" | grep '^TRAJ_FILES_MODIFIED=' | cut -d= -f2)
    gate_blocks=$(echo "$traj_output" | grep '^TRAJ_GATE_BLOCKS=' | cut -d= -f2)
    test_fails=$(echo "$traj_output" | grep '^TRAJ_TEST_FAILURES=' | cut -d= -f2)
    checkpoints=$(echo "$traj_output" | grep '^TRAJ_CHECKPOINTS=' | cut -d= -f2)

    local errors=()
    [[ "${tool_calls:-0}" -ne 4 ]] && errors+=("TRAJ_TOOL_CALLS: expected 4, got '${tool_calls:-}'")
    [[ "${files_mod:-0}" -ne 3 ]] && errors+=("TRAJ_FILES_MODIFIED: expected 3, got '${files_mod:-}'")
    [[ "${gate_blocks:-0}" -ne 1 ]] && errors+=("TRAJ_GATE_BLOCKS: expected 1, got '${gate_blocks:-}'")
    [[ "${test_fails:-0}" -ne 1 ]] && errors+=("TRAJ_TEST_FAILURES: expected 1, got '${test_fails:-}'")
    [[ "${checkpoints:-0}" -ne 2 ]] && errors+=("TRAJ_CHECKPOINTS: expected 2, got '${checkpoints:-}'")

    if [[ ${#errors[@]} -eq 0 ]]; then
        pass_test "get_session_trajectory() counts match expected values"
    else
        fail_test "get_session_trajectory() count mismatch" \
            "$(IFS='; '; echo "${errors[*]}")"
    fi
}

# ============================================================================
# Test 10: `commit` events have `sha` and `message` fields (W3-1 validation)
# ============================================================================

test_commit_event_schema() {
    run_test

    local dir
    dir=$(make_project)
    trap "rm -rf '$dir'" RETURN

    emit_raw "$dir" '{"ts":"2026-02-19T10:00:00Z","event":"commit","sha":"abc123def456abc123def456abc123def456abc1","message":"feat(auth): add JWT validation"}'

    local line
    line=$(tail -1 "$dir/.claude/.session-events.jsonl")

    local sha_val msg_val event_val
    sha_val=$(get_field "$line" ".sha")
    msg_val=$(get_field "$line" ".message")
    event_val=$(get_field "$line" ".event")

    if [[ "$event_val" != "commit" ]]; then
        fail_test "commit event type field" "event='$event_val' line='$line'"
        return
    fi

    if [[ -z "$sha_val" ]]; then
        fail_test "commit event has sha field" "sha='$sha_val' line='$line'"
        return
    fi

    if [[ -z "$msg_val" ]]; then
        fail_test "commit event has message field" "message='$msg_val' line='$line'"
        return
    fi

    pass_test "commit event has sha and message fields (W3-1)"
}

# ============================================================================
# Test 11: Session archive index entry has all required schema fields (W3-6)
# ============================================================================

test_archive_index_entry_schema() {
    run_test

    local dir
    dir=$(make_project)
    trap "rm -rf '$dir'" RETURN

    # Build a representative event log
    emit_raw "$dir" '{"ts":"2026-02-19T10:00:00Z","event":"agent_start","type":"implementer"}'
    emit_raw "$dir" '{"ts":"2026-02-19T10:01:00Z","event":"write","file":"hooks/guard.sh"}'
    emit_raw "$dir" '{"ts":"2026-02-19T10:02:00Z","event":"write","file":"hooks/context-lib.sh"}'
    emit_raw "$dir" '{"ts":"2026-02-19T10:03:00Z","event":"checkpoint","ref":"claude/cp/feat/1"}'
    emit_raw "$dir" '{"ts":"2026-02-19T10:04:00Z","event":"test_run","result":"pass","failures":0}'
    emit_raw "$dir" '{"ts":"2026-02-19T10:05:00Z","event":"agent_stop","type":"implementer"}'

    local session_event_file="$dir/.claude/.session-events.jsonl"
    local session_id="test-session-12345"

    # Construct the index entry exactly as session-end.sh does
    local index_entry
    index_entry=$(bash -c "
        source '$CONTEXT_LIB' >/dev/null 2>&1
        get_session_trajectory '$dir' >/dev/null 2>&1

        files_touched=\$(grep '\"event\":\"write\"' '$session_event_file' 2>/dev/null \
            | jq -r '.file // empty' 2>/dev/null \
            | sort -u \
            | jq -Rsc 'split(\"\n\") | map(select(length > 0))' 2>/dev/null \
            || echo '[]')

        jq -cn \
            --arg id '$session_id' \
            --arg project 'test-project' \
            --arg started '2026-02-19T10:00:00Z' \
            --argjson duration_min \"\${TRAJ_ELAPSED_MIN:-0}\" \
            --argjson files_touched \"\$files_touched\" \
            --argjson tool_calls \"\${TRAJ_TOOL_CALLS:-0}\" \
            --argjson checkpoints \"\${TRAJ_CHECKPOINTS:-0}\" \
            --argjson pivots \"\${TRAJ_PIVOTS:-0}\" \
            --argjson friction '[]' \
            --arg outcome 'tests-passing' \
            '{id:\$id,project:\$project,started:\$started,duration_min:\$duration_min,
              files_touched:\$files_touched,tool_calls:\$tool_calls,
              checkpoints:\$checkpoints,pivots:\$pivots,
              friction:\$friction,outcome:\$outcome}' 2>/dev/null
    " 2>/dev/null)

    if [[ -z "$index_entry" ]]; then
        fail_test "Archive index entry construction produced output" "jq returned empty"
        return
    fi

    if ! echo "$index_entry" | jq . >/dev/null 2>&1; then
        fail_test "Archive index entry is valid JSON" "entry='$index_entry'"
        return
    fi

    # Validate all required fields are present and non-null
    local required_fields=("id" "project" "started" "duration_min"
                           "tool_calls" "checkpoints" "pivots" "outcome")
    local missing=()
    for field in "${required_fields[@]}"; do
        local val
        val=$(echo "$index_entry" | jq -r ".${field} // \"__null__\"" 2>/dev/null)
        [[ "$val" == "__null__" ]] && missing+=("$field")
    done

    # files_touched and friction must be arrays (may be empty)
    for arr_field in "files_touched" "friction"; do
        local arr_type
        arr_type=$(echo "$index_entry" | jq -r "(.${arr_field} | type) // \"missing\"" 2>/dev/null)
        [[ "$arr_type" != "array" ]] && missing+=("${arr_field}(array)")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        pass_test "Session archive index entry has all required schema fields (W3-6)"
    else
        fail_test "Archive index entry missing fields" \
            "Missing: $(IFS=', '; echo "${missing[*]}") — entry: $index_entry"
    fi
}

# ============================================================================
# Run all tests
# ============================================================================

echo "Running test-event-schema test suite (W3-5: Schema compliance)..."
echo ""

test_required_fields_ts_event
test_lib_produces_valid_ts
test_write_event_has_file
test_test_run_event_schema
test_gate_eval_event_schema
test_agent_start_event_schema
test_checkpoint_event_schema
test_malformed_json_graceful_fallback
test_trajectory_counts_match
test_commit_event_schema
test_archive_index_entry_schema

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
    exit 0
else
    exit 1
fi
