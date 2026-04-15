#!/usr/bin/env bash
# test-trace-lite.sh: exercises the cc-policy trace CLI commands end-to-end.
#
# Production sequence exercised:
#   1. trace start   -- register a session
#   2. trace manifest -- record file_read, file_write, decision, command entries
#   3. trace end     -- close with summary
#   4. trace get     -- retrieve with manifest, verify structure
#   5. trace recent  -- list appears and is newest first
#
# @decision DEC-TRACE-001
# @title Trace-lite uses dedicated tables, not the events table
# @status accepted
# @rationale Scenario test crosses cc-policy CLI → runtime/core/traces.py →
#   SQLite trace + trace_manifest tables. This is the compound-interaction
#   test that validates the real production sequence a session-init hook
#   (start_trace) and post-task hook (end_trace) would trigger, with manifest
#   entries that intermediate agent activity would add.
set -euo pipefail

TEST_NAME="test-trace-lite"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/state.db"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR"

RUNTIME_ROOT="${CLAUDE_RUNTIME_ROOT:-$HOME/.claude/runtime}"
CC="python3 $RUNTIME_ROOT/cli.py"

# Use an isolated DB for all operations
export CLAUDE_POLICY_DB="$TEST_DB"

FAILURES=0

SESSION_A="trace-test-sess-a-$$"
SESSION_B="trace-test-sess-b-$$"

# -----------------------------------------------------------------------
# Test 1: trace start — registers a session
# -----------------------------------------------------------------------
result=$($CC trace start "$SESSION_A" --role implementer --ticket TKT-013 2>/dev/null)
sid=$(echo "$result" | jq -r '.session_id // empty' 2>/dev/null)
status=$(echo "$result" | jq -r '.status // empty' 2>/dev/null)

if [[ "$sid" != "$SESSION_A" || "$status" != "ok" ]]; then
    echo "  FAIL: trace start — expected session_id=$SESSION_A status=ok, got: $result"
    FAILURES=$((FAILURES + 1))
fi

# -----------------------------------------------------------------------
# Test 2: trace manifest — add multiple entry types
# -----------------------------------------------------------------------
$CC trace manifest "$SESSION_A" file_read  --path "runtime/schemas.py"          >/dev/null 2>&1
$CC trace manifest "$SESSION_A" file_write --path "runtime/core/traces.py" \
    --detail "created domain module"                                              >/dev/null 2>&1
$CC trace manifest "$SESSION_A" decision   --detail "DEC-TRACE-001 accepted"    >/dev/null 2>&1
$CC trace manifest "$SESSION_A" command    --detail "python3 -m pytest"         >/dev/null 2>&1

# Verify last manifest call returned ok
last=$(  $CC trace manifest "$SESSION_A" event --detail "schema confirmed" 2>/dev/null)
mstatus=$(echo "$last" | jq -r '.status // empty' 2>/dev/null)
if [[ "$mstatus" != "ok" ]]; then
    echo "  FAIL: trace manifest — expected status=ok, got: $last"
    FAILURES=$((FAILURES + 1))
fi

# -----------------------------------------------------------------------
# Test 3: trace end — closes with summary
# -----------------------------------------------------------------------
end_result=$($CC trace end "$SESSION_A" \
    --summary "TKT-013 trace domain implemented" 2>/dev/null)
end_status=$(echo "$end_result" | jq -r '.status // empty' 2>/dev/null)
end_sid=$(echo "$end_result" | jq -r '.session_id // empty' 2>/dev/null)

if [[ "$end_status" != "ok" || "$end_sid" != "$SESSION_A" ]]; then
    echo "  FAIL: trace end — expected status=ok session_id=$SESSION_A, got: $end_result"
    FAILURES=$((FAILURES + 1))
fi

# -----------------------------------------------------------------------
# Test 4: trace get — returns trace with manifest
# -----------------------------------------------------------------------
get_result=$($CC trace get "$SESSION_A" 2>/dev/null)
get_status=$(echo "$get_result" | jq -r '.status // empty' 2>/dev/null)
get_found=$(echo "$get_result"  | jq -r '.found | tostring' 2>/dev/null)
get_role=$(echo "$get_result"   | jq -r '.agent_role // empty' 2>/dev/null)
get_ticket=$(echo "$get_result" | jq -r '.ticket // empty' 2>/dev/null)
get_summary=$(echo "$get_result" | jq -r '.summary // empty' 2>/dev/null)
get_ended=$(echo "$get_result"  | jq -r '.ended_at // empty' 2>/dev/null)
manifest_count=$(echo "$get_result" | jq '.manifest | length' 2>/dev/null)

if [[ "$get_status" != "ok" ]]; then
    echo "  FAIL: trace get — status not ok: $get_result"
    FAILURES=$((FAILURES + 1))
fi

if [[ "$get_found" != "true" ]]; then
    echo "  FAIL: trace get — found not true: $get_result"
    FAILURES=$((FAILURES + 1))
fi

if [[ "$get_role" != "implementer" ]]; then
    echo "  FAIL: trace get — agent_role expected 'implementer', got: '$get_role'"
    FAILURES=$((FAILURES + 1))
fi

if [[ "$get_ticket" != "TKT-013" ]]; then
    echo "  FAIL: trace get — ticket expected 'TKT-013', got: '$get_ticket'"
    FAILURES=$((FAILURES + 1))
fi

if [[ "$get_summary" != "TKT-013 trace domain implemented" ]]; then
    echo "  FAIL: trace get — summary mismatch, got: '$get_summary'"
    FAILURES=$((FAILURES + 1))
fi

if [[ -z "$get_ended" || "$get_ended" == "null" ]]; then
    echo "  FAIL: trace get — ended_at not set"
    FAILURES=$((FAILURES + 1))
fi

# 5 manifest entries: file_read, file_write, decision, command, event
if [[ "$manifest_count" -ne 5 ]]; then
    echo "  FAIL: trace get — expected 5 manifest entries, got: $manifest_count"
    FAILURES=$((FAILURES + 1))
fi

# Verify manifest entry types in order
first_type=$(echo "$get_result"  | jq -r '.manifest[0].entry_type // empty' 2>/dev/null)
second_type=$(echo "$get_result" | jq -r '.manifest[1].entry_type // empty' 2>/dev/null)
if [[ "$first_type" != "file_read" ]]; then
    echo "  FAIL: manifest[0] entry_type expected 'file_read', got: '$first_type'"
    FAILURES=$((FAILURES + 1))
fi
if [[ "$second_type" != "file_write" ]]; then
    echo "  FAIL: manifest[1] entry_type expected 'file_write', got: '$second_type'"
    FAILURES=$((FAILURES + 1))
fi

# -----------------------------------------------------------------------
# Test 5: trace get for unknown session — found=false
# -----------------------------------------------------------------------
miss_result=$($CC trace get "no-such-session-$$" 2>/dev/null)
miss_found=$(echo "$miss_result" | jq -r '.found | tostring' 2>/dev/null)
if [[ "$miss_found" != "false" ]]; then
    echo "  FAIL: trace get unknown — expected found=false, got: $miss_result"
    FAILURES=$((FAILURES + 1))
fi

# -----------------------------------------------------------------------
# Test 6: trace recent — returns newest first, respects limit
# -----------------------------------------------------------------------
# Create a second session to test ordering
$CC trace start "$SESSION_B" --role reviewer >/dev/null 2>&1

recent_result=$($CC trace recent --limit 5 2>/dev/null)
recent_status=$(echo "$recent_result" | jq -r '.status // empty' 2>/dev/null)
recent_count=$(echo "$recent_result"  | jq -r '.count // 0'      2>/dev/null)

if [[ "$recent_status" != "ok" ]]; then
    echo "  FAIL: trace recent — status not ok: $recent_result"
    FAILURES=$((FAILURES + 1))
fi

if [[ "$recent_count" -lt 2 ]]; then
    echo "  FAIL: trace recent — expected at least 2 items, got: $recent_count"
    FAILURES=$((FAILURES + 1))
fi

# Both SESSION_A and SESSION_B must appear in the recent results.
# We do not assert strict position because started_at has second granularity
# and two inserts within the same second are tied. Ordering correctness is
# proven by the unit tests (test_recent_traces_ordering) which force distinct
# timestamps via SQL UPDATE.
sess_a_present=$(echo "$recent_result" | jq -r --arg s "$SESSION_A" \
    '[.items[].session_id] | index($s) != null | tostring' 2>/dev/null)
sess_b_present=$(echo "$recent_result" | jq -r --arg s "$SESSION_B" \
    '[.items[].session_id] | index($s) != null | tostring' 2>/dev/null)
if [[ "$sess_a_present" != "true" ]]; then
    echo "  FAIL: trace recent — SESSION_A '$SESSION_A' not found in results"
    FAILURES=$((FAILURES + 1))
fi
if [[ "$sess_b_present" != "true" ]]; then
    echo "  FAIL: trace recent — SESSION_B '$SESSION_B' not found in results"
    FAILURES=$((FAILURES + 1))
fi

# -----------------------------------------------------------------------
# Test 7: trace recent default limit (no --limit flag)
# -----------------------------------------------------------------------
# Create 12 sessions to exceed the default limit of 10
for i in $(seq 1 12); do
    $CC trace start "trace-bulk-$$-$i" >/dev/null 2>&1
done
default_recent=$($CC trace recent 2>/dev/null)
default_count=$(echo "$default_recent" | jq '.items | length' 2>/dev/null)
if [[ "$default_count" -ne 10 ]]; then
    echo "  FAIL: trace recent default limit — expected 10 items, got: $default_count"
    FAILURES=$((FAILURES + 1))
fi

# -----------------------------------------------------------------------
# Results
# -----------------------------------------------------------------------
if [[ "$FAILURES" -gt 0 ]]; then
    echo "FAIL: $TEST_NAME — $FAILURES check(s) failed"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
