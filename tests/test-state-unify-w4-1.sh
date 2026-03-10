#!/usr/bin/env bash
# test-state-unify-w4-1.sh — Tests for Event Ledger + Checkpoint System (W4-1).
#
# Validates:
#   - events table created on first state operation
#   - event_checkpoints table created on first state operation
#   - state_emit() writes event and returns sequence number
#   - state_emit() auto-increments sequence numbers
#   - state_events_since() returns events after consumer's checkpoint
#   - state_events_since() with type filter
#   - state_events_since() with workflow_id filter
#   - state_checkpoint() updates consumer position
#   - state_events_since() returns empty after checkpoint catches up
#   - state_events_count() returns correct count
#   - state_gc_events() removes events all consumers have seen
#   - state_gc_events() preserves events some consumers haven't seen
#   - state_gc_events() with max_age removes old events
#   - Multiple consumers with independent checkpoints
#   - Concurrent state_emit (10 parallel, all get unique sequence numbers)
#
# Usage: bash tests/test-state-unify-w4-1.sh
#
# Test environment: each test gets its own isolated CLAUDE_DIR to prevent
# cross-test contamination. The _setup() helper creates a git repo to satisfy
# detect_project_root(). All grep/sqlite3 calls use || true to prevent
# set -euo pipefail from aborting the script on non-match exits.
#
# @decision DEC-STATE-UNIFY-W4-1-TEST-001
# @title Isolated temp DB per test for event ledger tests
# @status accepted
# @rationale Event ledger tests must be hermetic: each test needs a fresh DB
#   so sequence numbers start from 1 and consumer checkpoints are not carried
#   across tests. Per-test CLAUDE_DIR isolation follows the pattern established
#   in DEC-SQLITE-TEST-001 and DEC-STATE-UNIFY-W1-2-TEST-001. Concurrent write
#   tests (T15) use a shared DB because they exercise multi-writer behavior.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT_OUTER="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT_OUTER/hooks"

# Resolve the main repo root. When running from a worktree, git's commondir
# points to the main .git — use that to find the main repo tmp/ dir so that
# CLAUDE_DIR and PROJECT_ROOT paths never contain ".worktrees/" (which the
# pre-bash hook blocks).
_MAIN_GIT_COMMON=$(git -C "$PROJECT_ROOT_OUTER" rev-parse --git-common-dir 2>/dev/null || echo "")
if [[ -n "$_MAIN_GIT_COMMON" && "$_MAIN_GIT_COMMON" != ".git" ]]; then
    _MAIN_REPO_ROOT="${_MAIN_GIT_COMMON%/.git}"
else
    _MAIN_REPO_ROOT="$PROJECT_ROOT_OUTER"
fi
# Fallback: strip .worktrees suffix if still present
if [[ "$_MAIN_REPO_ROOT" == *"/.worktrees"* ]]; then
    _MAIN_REPO_ROOT="${_MAIN_REPO_ROOT%%/.worktrees*}"
fi

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

# Global tmp dir — use main repo tmp/ to avoid .worktrees/ path restriction.
# Cleaned on EXIT.
TMPDIR_BASE="${_MAIN_REPO_ROOT}/tmp/test-state-unify-w4-1-$$"
mkdir -p "$TMPDIR_BASE"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# _run_state — execute state-lib operations in an isolated bash subshell.
# Usage: _run_state CLAUDE_DIR PROJECT_ROOT_PATH "bash code using state functions"
_run_state() {
    local _rcd="$1"
    local _rpr="$2"
    local _rcode="$3"
    bash -c "
source '${HOOKS_DIR}/source-lib.sh' 2>/dev/null
require_state
_STATE_SCHEMA_INITIALIZED=''
_WORKFLOW_ID=''
export CLAUDE_DIR='${_rcd}'
export PROJECT_ROOT='${_rpr}'
export CLAUDE_SESSION_ID='test-session-\$\$'
${_rcode}
" 2>/dev/null
}

# _setup — create isolated env for a test.
# Outputs: sets _CD (CLAUDE_DIR) and _PR (PROJECT_ROOT) for the test.
_setup() {
    local test_id="$1"
    _CD="${TMPDIR_BASE}/${test_id}/claude"
    _PR="${TMPDIR_BASE}/${test_id}/project"
    mkdir -p "${_CD}/state" "${_PR}"
    git -C "${_PR}" init -q 2>/dev/null || true
}

# _sqlite — run sqlite3 against a DB, suppressing errors, never failing.
# Usage: _sqlite DB SQL
_sqlite() {
    sqlite3 "$1" "$2" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# T01: events table created on first state operation
# ─────────────────────────────────────────────────────────────────────────────
run_test "T01: events table created on first state operation"
_setup t01

_run_state "$_CD" "$_PR" "state_update 'bootstrap' 'yes' 'test'" || true

_T01_DB="${_CD}/state/state.db"
_T01_FAIL=""

if [[ ! -f "$_T01_DB" ]]; then
    _T01_FAIL="state.db was not created"
else
    _T01_COUNT=$(_sqlite "$_T01_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='events';" || true)
    _T01_COUNT="${_T01_COUNT//[[:space:]]/}"
    if [[ "${_T01_COUNT:-0}" -ne 1 ]]; then
        _T01_FAIL="events table not found (tables: $(_sqlite "$_T01_DB" ".tables"))"
    fi
fi

[[ -z "$_T01_FAIL" ]] && pass_test || fail_test "$_T01_FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T02: event_checkpoints table created on first state operation
# ─────────────────────────────────────────────────────────────────────────────
run_test "T02: event_checkpoints table created on first state operation"
_setup t02

_run_state "$_CD" "$_PR" "state_update 'bootstrap' 'yes' 'test'" || true

_T02_DB="${_CD}/state/state.db"
_T02_FAIL=""

if [[ ! -f "$_T02_DB" ]]; then
    _T02_FAIL="state.db was not created"
else
    _T02_COUNT=$(_sqlite "$_T02_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='event_checkpoints';" || true)
    _T02_COUNT="${_T02_COUNT//[[:space:]]/}"
    if [[ "${_T02_COUNT:-0}" -ne 1 ]]; then
        _T02_FAIL="event_checkpoints table not found (tables: $(_sqlite "$_T02_DB" ".tables"))"
    fi
fi

[[ -z "$_T02_FAIL" ]] && pass_test || fail_test "$_T02_FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T03: state_emit writes event and returns sequence number
# ─────────────────────────────────────────────────────────────────────────────
run_test "T03: state_emit writes event and returns sequence number"
_setup t03

_T03_SEQ=$(_run_state "$_CD" "$_PR" "state_emit 'test.event' '{\"key\":\"val\"}'" || true)
_T03_SEQ="${_T03_SEQ//[[:space:]]/}"

_T03_DB="${_CD}/state/state.db"
_T03_FAIL=""

if [[ -z "$_T03_SEQ" ]]; then
    _T03_FAIL="state_emit returned empty (expected a sequence number)"
elif ! [[ "$_T03_SEQ" =~ ^[0-9]+$ ]]; then
    _T03_FAIL="state_emit returned non-numeric: '$_T03_SEQ'"
elif [[ "$_T03_SEQ" -lt 1 ]]; then
    _T03_FAIL="state_emit returned seq < 1: '$_T03_SEQ'"
else
    # Verify the event exists in the DB
    _T03_COUNT=$(_sqlite "$_T03_DB" "SELECT COUNT(*) FROM events WHERE type='test.event';" || true)
    _T03_COUNT="${_T03_COUNT//[[:space:]]/}"
    if [[ "${_T03_COUNT:-0}" -ne 1 ]]; then
        _T03_FAIL="event not found in DB (count=${_T03_COUNT})"
    fi
fi

[[ -z "$_T03_FAIL" ]] && pass_test || fail_test "$_T03_FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T04: state_emit auto-increments sequence numbers
# ─────────────────────────────────────────────────────────────────────────────
run_test "T04: state_emit auto-increments sequence numbers"
_setup t04

_T04_RESULT=$(_run_state "$_CD" "$_PR" "
seq1=\$(state_emit 'evt.a' 'payload1')
seq2=\$(state_emit 'evt.b' 'payload2')
seq3=\$(state_emit 'evt.c' 'payload3')
echo \"\${seq1} \${seq2} \${seq3}\"
" || true)

_T04_FAIL=""
read -r _T04_S1 _T04_S2 _T04_S3 <<< "$_T04_RESULT" || true

if [[ -z "$_T04_S1" || -z "$_T04_S2" || -z "$_T04_S3" ]]; then
    _T04_FAIL="did not get 3 sequence numbers (got: '$_T04_RESULT')"
elif [[ "$_T04_S1" -ge "$_T04_S2" ]] || [[ "$_T04_S2" -ge "$_T04_S3" ]]; then
    _T04_FAIL="sequences not strictly increasing: $_T04_S1 $\_T04_S2 $_T04_S3"
fi

[[ -z "$_T04_FAIL" ]] && pass_test || fail_test "$_T04_FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T05: state_events_since returns events after consumer's checkpoint
# ─────────────────────────────────────────────────────────────────────────────
run_test "T05: state_events_since returns events after consumer's checkpoint"
_setup t05

_T05_RESULT=$(_run_state "$_CD" "$_PR" "
state_emit 'workflow.step' 'step1' >/dev/null
state_emit 'workflow.step' 'step2' >/dev/null
state_emit 'workflow.step' 'step3' >/dev/null
state_events_since 'consumer-a'
" || true)

_T05_FAIL=""
_T05_LINES=$(echo "$_T05_RESULT" | grep -c '^[0-9]' || true)

if [[ "${_T05_LINES:-0}" -ne 3 ]]; then
    _T05_FAIL="expected 3 events, got ${_T05_LINES} (output: '$_T05_RESULT')"
fi

[[ -z "$_T05_FAIL" ]] && pass_test || fail_test "$_T05_FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T06: state_events_since with type filter
# ─────────────────────────────────────────────────────────────────────────────
run_test "T06: state_events_since with type filter"
_setup t06

_T06_RESULT=$(_run_state "$_CD" "$_PR" "
state_emit 'type.alpha' 'a1' >/dev/null
state_emit 'type.beta'  'b1' >/dev/null
state_emit 'type.alpha' 'a2' >/dev/null
state_emit 'type.beta'  'b2' >/dev/null
state_events_since 'consumer-x' 'type.alpha'
" || true)

_T06_FAIL=""
_T06_LINES=$(echo "$_T06_RESULT" | grep -c '^[0-9]' || true)

if [[ "${_T06_LINES:-0}" -ne 2 ]]; then
    _T06_FAIL="expected 2 type.alpha events, got ${_T06_LINES} (output: '$_T06_RESULT')"
else
    # Verify only type.alpha events appear
    _T06_BETA=$(echo "$_T06_RESULT" | grep -c 'type.beta' || true)
    if [[ "${_T06_BETA:-0}" -ne 0 ]]; then
        _T06_FAIL="type filter leaked type.beta events into output"
    fi
fi

[[ -z "$_T06_FAIL" ]] && pass_test || fail_test "$_T06_FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T07: state_events_since with workflow_id filter
# ─────────────────────────────────────────────────────────────────────────────
run_test "T07: state_events_since with workflow_id filter"
_setup t07

_T07_RESULT=$(_run_state "$_CD" "$_PR" "
state_emit 'task.done' 'msg1' 'wf-aaa' >/dev/null
state_emit 'task.done' 'msg2' 'wf-bbb' >/dev/null
state_emit 'task.done' 'msg3' 'wf-aaa' >/dev/null
# Filter: consumer 'c1', no type filter (pass empty string), workflow 'wf-aaa'
state_events_since 'c1' '' 'wf-aaa'
" || true)

_T07_FAIL=""
_T07_LINES=$(echo "$_T07_RESULT" | grep -c '^[0-9]' || true)

if [[ "${_T07_LINES:-0}" -ne 2 ]]; then
    _T07_FAIL="expected 2 wf-aaa events, got ${_T07_LINES} (output: '$_T07_RESULT')"
else
    _T07_BBB=$(echo "$_T07_RESULT" | grep -c 'wf-bbb' || true)
    if [[ "${_T07_BBB:-0}" -ne 0 ]]; then
        _T07_FAIL="workflow filter leaked wf-bbb events into output"
    fi
fi

[[ -z "$_T07_FAIL" ]] && pass_test || fail_test "$_T07_FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T08: state_checkpoint updates consumer position
# ─────────────────────────────────────────────────────────────────────────────
run_test "T08: state_checkpoint updates consumer position"
_setup t08

_run_state "$_CD" "$_PR" "
state_emit 'ev' 'a' >/dev/null
state_emit 'ev' 'b' >/dev/null
state_checkpoint 'my-consumer' 2
" || true

_T08_DB="${_CD}/state/state.db"
_T08_SEQ=$(_sqlite "$_T08_DB" "SELECT last_seq FROM event_checkpoints WHERE consumer='my-consumer';" || true)
_T08_SEQ="${_T08_SEQ//[[:space:]]/}"

if [[ "${_T08_SEQ:-}" == "2" ]]; then
    pass_test
else
    fail_test "expected last_seq=2, got '${_T08_SEQ}'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T09: state_events_since returns empty after checkpoint catches up
# ─────────────────────────────────────────────────────────────────────────────
run_test "T09: state_events_since returns empty after checkpoint catches up"
_setup t09

_T09_RESULT=$(_run_state "$_CD" "$_PR" "
seq1=\$(state_emit 'item' 'first')
seq2=\$(state_emit 'item' 'second')
state_checkpoint 'consumer-done' \"\$seq2\"
state_events_since 'consumer-done'
" || true)

_T09_LINES=$(echo "$_T09_RESULT" | grep -c '^[0-9]' || true)

if [[ "${_T09_LINES:-0}" -eq 0 ]]; then
    pass_test
else
    fail_test "expected 0 events after checkpoint, got ${_T09_LINES} (output: '$_T09_RESULT')"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T10: state_events_count returns correct count
# ─────────────────────────────────────────────────────────────────────────────
run_test "T10: state_events_count returns correct count"
_setup t10

_T10_RESULT=$(_run_state "$_CD" "$_PR" "
state_emit 'batch' 'e1' >/dev/null
state_emit 'batch' 'e2' >/dev/null
state_emit 'batch' 'e3' >/dev/null
state_emit 'other' 'e4' >/dev/null
# Count all events for fresh consumer (no checkpoint)
count_all=\$(state_events_count 'fresh-consumer')
# Count only 'batch' type
count_batch=\$(state_events_count 'fresh-consumer' 'batch')
echo \"\${count_all} \${count_batch}\"
" || true)

_T10_FAIL=""
read -r _T10_ALL _T10_BATCH <<< "$_T10_RESULT" || true

if [[ "${_T10_ALL:-}" != "4" ]]; then
    _T10_FAIL="expected count_all=4, got '${_T10_ALL}' (output: '$_T10_RESULT')"
elif [[ "${_T10_BATCH:-}" != "3" ]]; then
    _T10_FAIL="expected count_batch=3, got '${_T10_BATCH}' (output: '$_T10_RESULT')"
fi

[[ -z "$_T10_FAIL" ]] && pass_test || fail_test "$_T10_FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T11: state_gc_events removes events all consumers have seen
# ─────────────────────────────────────────────────────────────────────────────
run_test "T11: state_gc_events removes events all consumers have seen"
_setup t11

_T11_RESULT=$(_run_state "$_CD" "$_PR" "
state_emit 'gc.test' 'msg1' >/dev/null
state_emit 'gc.test' 'msg2' >/dev/null
state_emit 'gc.test' 'msg3' >/dev/null
# Both consumers checkpoint at seq 2 (saw first 2 events)
state_checkpoint 'consumer-1' 2
state_checkpoint 'consumer-2' 2
# GC: should delete events 1 and 2 (all consumers saw them)
deleted=\$(state_gc_events)
echo \"\$deleted\"
" || true)

_T11_DB="${_CD}/state/state.db"
_T11_REMAINING=$(_sqlite "$_T11_DB" "SELECT COUNT(*) FROM events;" || true)
_T11_REMAINING="${_T11_REMAINING//[[:space:]]/}"
_T11_DELETED="${_T11_RESULT//[[:space:]]/}"

_T11_FAIL=""
if [[ "${_T11_DELETED:-0}" -ne 2 ]]; then
    _T11_FAIL="expected 2 deleted events, got '${_T11_DELETED}'"
elif [[ "${_T11_REMAINING:-}" != "1" ]]; then
    _T11_FAIL="expected 1 remaining event, got '${_T11_REMAINING}'"
fi

[[ -z "$_T11_FAIL" ]] && pass_test || fail_test "$_T11_FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T12: state_gc_events preserves events some consumers haven't seen
# ─────────────────────────────────────────────────────────────────────────────
run_test "T12: state_gc_events preserves events some consumers haven't seen"
_setup t12

_T12_RESULT=$(_run_state "$_CD" "$_PR" "
state_emit 'item' 'e1' >/dev/null
state_emit 'item' 'e2' >/dev/null
state_emit 'item' 'e3' >/dev/null
# consumer-1 has seen all 3, consumer-2 has only seen 1
state_checkpoint 'consumer-1' 3
state_checkpoint 'consumer-2' 1
# GC: minimum checkpoint is 1, so only seq 1 can be deleted...
# But min_checkpoint = 1 means seq <= 1 can be deleted
deleted=\$(state_gc_events)
echo \"\$deleted\"
" || true)

_T12_DB="${_CD}/state/state.db"
_T12_REMAINING=$(_sqlite "$_T12_DB" "SELECT COUNT(*) FROM events;" || true)
_T12_REMAINING="${_T12_REMAINING//[[:space:]]/}"
_T12_DELETED="${_T12_RESULT//[[:space:]]/}"

_T12_FAIL=""
# min_checkpoint = 1, so events with seq <= 1 are deleted (1 event)
if [[ "${_T12_DELETED:-}" != "1" ]]; then
    _T12_FAIL="expected 1 deleted event (min checkpoint=1), got '${_T12_DELETED}'"
elif [[ "${_T12_REMAINING:-}" != "2" ]]; then
    _T12_FAIL="expected 2 remaining events, got '${_T12_REMAINING}'"
fi

[[ -z "$_T12_FAIL" ]] && pass_test || fail_test "$_T12_FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T13: state_gc_events with max_age removes old events
# ─────────────────────────────────────────────────────────────────────────────
run_test "T13: state_gc_events with max_age removes old events"
_setup t13

_T13_RESULT=$(_run_state "$_CD" "$_PR" "
# Bootstrap schema first so events table exists for direct INSERT
state_update 'bootstrap' 'ready' 'test' >/dev/null 2>&1
# Insert an event with a very old timestamp directly
_db=\$(_state_db_path)
sqlite3 \"\$_db\" \"INSERT INTO events (type, workflow_id, session_id, payload, created_at) VALUES ('old.event', 'wf-test', NULL, 'old', strftime('%s','now') - 7200);\" 2>/dev/null
state_emit 'new.event' 'recent' >/dev/null
# GC with max_age=3600 (1 hour) — old event should be deleted
deleted=\$(state_gc_events 3600)
echo \"\$deleted\"
" || true)

_T13_DB="${_CD}/state/state.db"
_T13_REMAINING=$(_sqlite "$_T13_DB" "SELECT COUNT(*) FROM events;" || true)
_T13_REMAINING="${_T13_REMAINING//[[:space:]]/}"
_T13_DELETED="${_T13_RESULT//[[:space:]]/}"

_T13_FAIL=""
# The old event (2h old) should be deleted by max_age=3600s (1h)
if [[ "${_T13_DELETED:-0}" -lt 1 ]]; then
    _T13_FAIL="expected >= 1 deleted event (max_age=3600), got '${_T13_DELETED}'"
elif [[ "${_T13_REMAINING:-}" != "1" ]]; then
    _T13_FAIL="expected 1 remaining (recent) event, got '${_T13_REMAINING}'"
fi

[[ -z "$_T13_FAIL" ]] && pass_test || fail_test "$_T13_FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T14: Multiple consumers with independent checkpoints
# ─────────────────────────────────────────────────────────────────────────────
run_test "T14: Multiple consumers with independent checkpoints"
_setup t14

_T14_RESULT=$(_run_state "$_CD" "$_PR" "
state_emit 'step' 's1' >/dev/null
state_emit 'step' 's2' >/dev/null
state_emit 'step' 's3' >/dev/null
state_checkpoint 'consumer-A' 2
state_checkpoint 'consumer-B' 1
# consumer-A has seen 2, should see 1 more
a_count=\$(state_events_count 'consumer-A')
# consumer-B has seen 1, should see 2 more
b_count=\$(state_events_count 'consumer-B')
echo \"\${a_count} \${b_count}\"
" || true)

_T14_FAIL=""
read -r _T14_A _T14_B <<< "$_T14_RESULT" || true

if [[ "${_T14_A:-}" != "1" ]]; then
    _T14_FAIL="consumer-A: expected count=1, got '${_T14_A}' (output: '$_T14_RESULT')"
elif [[ "${_T14_B:-}" != "2" ]]; then
    _T14_FAIL="consumer-B: expected count=2, got '${_T14_B}' (output: '$_T14_RESULT')"
fi

[[ -z "$_T14_FAIL" ]] && pass_test || fail_test "$_T14_FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T15: Concurrent state_emit (10 parallel, all get unique sequence numbers)
# ─────────────────────────────────────────────────────────────────────────────
run_test "T15: Concurrent state_emit (10 parallel, all get unique sequence numbers)"

# Use a shared setup for concurrency test
_T15_CD="${TMPDIR_BASE}/t15/claude"
_T15_PR="${TMPDIR_BASE}/t15/project"
mkdir -p "${_T15_CD}/state" "${_T15_PR}"
git -C "${_T15_PR}" init -q 2>/dev/null || true

# Bootstrap schema first (sequential)
_run_state "$_T15_CD" "$_T15_PR" "state_update 'bootstrap' 'ready' 'test'" 2>/dev/null || true

# Launch 10 parallel state_emit calls — check the DB afterwards for uniqueness.
# We use subshells to avoid array-in-background issues.
for i in $(seq 1 10); do
    (
        _run_state "$_T15_CD" "$_T15_PR" "state_emit 'concurrent.test' 'batch-${i}' 'wf-concurrent'" 2>/dev/null || true
    ) &
done
wait

_T15_DB="${_T15_CD}/state/state.db"
_T15_TOTAL=$(_sqlite "$_T15_DB" "SELECT COUNT(*) FROM events WHERE type='concurrent.test';" || true)
_T15_TOTAL="${_T15_TOTAL//[[:space:]]/}"
_T15_UNIQUE=$(_sqlite "$_T15_DB" "SELECT COUNT(DISTINCT seq) FROM events WHERE type='concurrent.test';" || true)
_T15_UNIQUE="${_T15_UNIQUE//[[:space:]]/}"

_T15_FAIL=""
# We launched 10 parallel emits. Check that unique seqs == total events (no collisions).
if [[ -z "$_T15_TOTAL" ]] || [[ "$_T15_TOTAL" -lt 10 ]]; then
    _T15_FAIL="expected >= 10 events from concurrent emits, got '${_T15_TOTAL}'"
elif [[ "${_T15_UNIQUE:-0}" -ne "${_T15_TOTAL:-0}" ]]; then
    _T15_FAIL="sequence number collision detected: total=${_T15_TOTAL}, unique=${_T15_UNIQUE}"
fi

[[ -z "$_T15_FAIL" ]] && pass_test || fail_test "$_T15_FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
