#!/usr/bin/env bash
# Shell-based integration tests for cc-policy CLI.
# Invokes `python3 runtime/cli.py` directly and validates JSON output.
#
# Usage:
#   bash tests/runtime/test_cc_policy.sh
#
# Exit: 0 if all tests pass, 1 if any fail.
#
# @decision DEC-RT-001
# Title: Canonical SQLite schema for all shared workflow state
# Status: accepted
# Rationale: Shell tests verify that cc-policy is invocable from bash
#   (the runtime-bridge.sh caller context) and that every subcommand
#   produces parseable JSON. Python unit tests cover domain logic;
#   these tests cover the CLI surface and latency SLA.
set -euo pipefail

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLI="$PROJECT_ROOT/runtime/cli.py"
TEST_DB="$(mktemp /tmp/cc-policy-test-XXXXXX.db)"

PASS=0
FAIL=0

cleanup() {
    rm -f "$TEST_DB"
}
trap cleanup EXIT

cc() {
    CLAUDE_POLICY_DB="$TEST_DB" PYTHONPATH="$PROJECT_ROOT" python3 "$CLI" "$@"
}

assert_ok() {
    local label="$1" output="$2"
    local status
    status=$(echo "$output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','MISSING'))" 2>/dev/null || echo "PARSE_ERROR")
    if [[ "$status" == "ok" || "$status" == "idle" || "$status" == "pending" || "$status" == "verified" || "$status" == "active" ]]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label  (status=$status)"
        echo "        output: $output"
        FAIL=$((FAIL + 1))
    fi
}

assert_field() {
    local label="$1" output="$2" field="$3" expected="$4"
    local actual
    actual=$(echo "$output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$field','__MISSING__'))" 2>/dev/null || echo "PARSE_ERROR")
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label  ($field: expected='$expected' got='$actual')"
        echo "        output: $output"
        FAIL=$((FAIL + 1))
    fi
}

assert_json_parseable() {
    local label="$1" output="$2"
    if echo "$output" | python3 -m json.tool > /dev/null 2>&1; then
        echo "  PASS: $label (valid JSON)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (invalid JSON: $output)"
        FAIL=$((FAIL + 1))
    fi
}

# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------
echo ""
echo "--- Schema ---"

OUT=$(cc schema ensure)
assert_ok "schema ensure" "$OUT"

# Idempotent second call
OUT=$(cc schema ensure)
assert_ok "schema ensure idempotent" "$OUT"

# Tables must exist in the DB
TABLES=$(CLAUDE_POLICY_DB="$TEST_DB" python3 -c "
import sqlite3, os
conn = sqlite3.connect(os.environ['CLAUDE_POLICY_DB'])
tables = {r[0] for r in conn.execute(\"SELECT name FROM sqlite_master WHERE type='table'\").fetchall()}
print(','.join(sorted(tables)))
" 2>/dev/null || echo "ERROR")
# sqlite_sequence is auto-created by SQLite for AUTOINCREMENT columns
EXPECTED="agent_markers,dispatch_cycles,dispatch_queue,events,proof_state,session_tokens,sqlite_sequence,todo_state,trace_manifest,traces,worktrees"
if [[ "$TABLES" == "$EXPECTED" ]]; then
    echo "  PASS: all tables present"
    PASS=$((PASS + 1))
else
    echo "  FAIL: tables mismatch (got: $TABLES)"
    FAIL=$((FAIL + 1))
fi

# WAL mode must be active
WAL_MODE=$(CLAUDE_POLICY_DB="$TEST_DB" python3 -c "
import sqlite3, os
conn = sqlite3.connect(os.environ['CLAUDE_POLICY_DB'])
print(conn.execute('PRAGMA journal_mode').fetchone()[0])
" 2>/dev/null || echo "ERROR")
if [[ "$WAL_MODE" == "wal" ]]; then
    echo "  PASS: WAL mode active"
    PASS=$((PASS + 1))
else
    echo "  FAIL: WAL mode not active (got: $WAL_MODE)"
    FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# Proof
# ---------------------------------------------------------------------------
echo ""
echo "--- Proof ---"

OUT=$(cc proof get wf-missing)
assert_field "proof get missing returns found=False" "$OUT" "found" "False"

OUT=$(cc proof set wf-1 pending)
assert_field "proof set returns workflow_id" "$OUT" "workflow_id" "wf-1"

OUT=$(cc proof get wf-1)
assert_field "proof get returns correct status" "$OUT" "status" "pending"
assert_field "proof get returns found=True" "$OUT" "found" "True"

OUT=$(cc proof set wf-1 verified)
OUT=$(cc proof get wf-1)
assert_field "proof set upserts status" "$OUT" "status" "verified"

cc proof set wf-2 idle > /dev/null
cc proof set wf-3 pending > /dev/null
OUT=$(cc proof list)
assert_field "proof list count" "$OUT" "count" "3"

# ---------------------------------------------------------------------------
# Marker
# ---------------------------------------------------------------------------
echo ""
echo "--- Marker ---"

OUT=$(cc marker get-active)
assert_field "marker get-active empty returns found=False" "$OUT" "found" "False"

OUT=$(cc marker set agent-1 implementer)
assert_field "marker set returns agent_id" "$OUT" "agent_id" "agent-1"

OUT=$(cc marker get-active)
assert_field "marker get-active returns role" "$OUT" "role" "implementer"
assert_field "marker get-active returns found=True" "$OUT" "found" "True"

OUT=$(cc marker deactivate agent-1)
assert_ok "marker deactivate" "$OUT"

OUT=$(cc marker get-active)
assert_field "marker get-active after deactivate returns found=False" "$OUT" "found" "False"

# ---------------------------------------------------------------------------
# Event
# ---------------------------------------------------------------------------
echo ""
echo "--- Event ---"

OUT=$(cc event emit tkt.started --source tkt-006 --detail "work began")
assert_json_parseable "event emit returns JSON" "$OUT"
assert_ok "event emit status" "$OUT"

OUT=$(cc event query)
assert_field "event query count" "$OUT" "count" "1"

cc event emit tkt.other > /dev/null
OUT=$(cc event query --type tkt.started)
assert_field "event query type filter" "$OUT" "count" "1"

for i in $(seq 1 5); do cc event emit evt.bulk > /dev/null; done
OUT=$(cc event query --limit 2)
assert_field "event query limit" "$OUT" "count" "2"

# ---------------------------------------------------------------------------
# Worktree
# ---------------------------------------------------------------------------
echo ""
echo "--- Worktree ---"

OUT=$(cc worktree register /path/wt-a feature/a --ticket TKT-006)
assert_ok "worktree register" "$OUT"

OUT=$(cc worktree list)
assert_field "worktree list count after register" "$OUT" "count" "1"

OUT=$(cc worktree remove /path/wt-a)
assert_ok "worktree remove" "$OUT"

OUT=$(cc worktree list)
assert_field "worktree list count after remove" "$OUT" "count" "0"

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
echo ""
echo "--- Dispatch ---"

OUT=$(cc dispatch cycle-start INIT-002)
assert_json_parseable "dispatch cycle-start returns JSON" "$OUT"
assert_ok "dispatch cycle-start status" "$OUT"

OUT=$(cc dispatch cycle-current)
assert_field "dispatch cycle-current returns found=True" "$OUT" "found" "True"
assert_field "dispatch cycle-current initiative" "$OUT" "initiative" "INIT-002"

OUT=$(cc dispatch enqueue implementer --ticket TKT-006)
QID=$(echo "$OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null)
assert_field "dispatch enqueue role" "$OUT" "role" "implementer"

OUT=$(cc dispatch next)
assert_field "dispatch next returns found=True" "$OUT" "found" "True"

OUT=$(cc dispatch start "$QID")
assert_ok "dispatch start" "$OUT"

OUT=$(cc dispatch next)
assert_field "dispatch next empty after start" "$OUT" "found" "False"

OUT=$(cc dispatch complete "$QID")
assert_ok "dispatch complete" "$OUT"

# ---------------------------------------------------------------------------
# Statusline
# ---------------------------------------------------------------------------
echo ""
echo "--- Statusline ---"

OUT=$(cc statusline snapshot)
assert_json_parseable "statusline snapshot valid JSON" "$OUT"
for KEY in proof_status active_agent worktree_count dispatch_status recent_event_count snapshot_at; do
    if echo "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert '$KEY' in d" 2>/dev/null; then
        echo "  PASS: statusline has key '$KEY'"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: statusline missing key '$KEY'"
        FAIL=$((FAIL + 1))
    fi
done

# ---------------------------------------------------------------------------
# Tokens
# ---------------------------------------------------------------------------
echo ""
echo "--- Tokens ---"

OUT=$(cc tokens upsert "pid:1234" "proj-abc1" 50000)
assert_ok "tokens upsert returns ok" "$OUT"

OUT=$(cc tokens lifetime "proj-abc1")
assert_ok "tokens lifetime returns ok" "$OUT"
assert_field "tokens lifetime total" "$OUT" "total" "50000"

# Second upsert replaces — no double-count
OUT=$(cc tokens upsert "pid:1234" "proj-abc1" 80000)
OUT=$(cc tokens lifetime "proj-abc1")
assert_field "tokens upsert replaces (no double-count)" "$OUT" "total" "80000"

# Two sessions sum correctly
OUT=$(cc tokens upsert "pid:5678" "proj-abc1" 20000)
OUT=$(cc tokens lifetime "proj-abc1")
assert_field "tokens two sessions sum" "$OUT" "total" "100000"

# Unknown project returns 0
OUT=$(cc tokens lifetime "unknown-hash")
assert_field "tokens lifetime unknown project=0" "$OUT" "total" "0"

# ---------------------------------------------------------------------------
# Todos
# ---------------------------------------------------------------------------
echo ""
echo "--- Todos ---"

OUT=$(cc todos set "proj-td1" 3 10)
assert_ok "todos set returns ok" "$OUT"

OUT=$(cc todos get "proj-td1")
assert_ok "todos get returns ok" "$OUT"
assert_field "todos get project count" "$OUT" "project" "3"
assert_field "todos get global count" "$OUT" "global" "10"
assert_field "todos get found=True" "$OUT" "found" "True"

# Upsert replaces
OUT=$(cc todos set "proj-td1" 1 5)
OUT=$(cc todos get "proj-td1")
assert_field "todos set replaces project count" "$OUT" "project" "1"
assert_field "todos set replaces global count" "$OUT" "global" "5"

# Missing project returns zeros
OUT=$(cc todos get "no-such-project")
assert_field "todos get missing found=False" "$OUT" "found" "False"
assert_field "todos get missing project=0" "$OUT" "project" "0"
assert_field "todos get missing global=0" "$OUT" "global" "0"

# ---------------------------------------------------------------------------
# Latency
# ---------------------------------------------------------------------------
echo ""
echo "--- Latency ---"

cc proof set wf-lat idle > /dev/null
START_NS=$(python3 -c "import time; print(int(time.perf_counter()*1000000))")
cc proof get wf-lat > /dev/null
END_NS=$(python3 -c "import time; print(int(time.perf_counter()*1000000))")

# Use shell arithmetic for ms measurement via date
START_MS=$(python3 -c "import time; t=time.perf_counter(); __import__('subprocess').run(['python3', '$CLI', 'proof', 'get', 'wf-lat'], capture_output=True, env={**__import__('os').environ, 'CLAUDE_POLICY_DB': '$TEST_DB', 'PYTHONPATH': '$PROJECT_ROOT'}); print(f'{(time.perf_counter()-t)*1000:.1f}')" 2>/dev/null || echo "0")
echo "  proof get latency: ${START_MS}ms"
LATENCY_OK=$(python3 -c "print('yes' if float('${START_MS}') < 100 else 'no')" 2>/dev/null || echo "no")
if [[ "$LATENCY_OK" == "yes" ]]; then
    echo "  PASS: latency ${START_MS}ms < 100ms"
    PASS=$((PASS + 1))
else
    echo "  FAIL: latency ${START_MS}ms >= 100ms"
    FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "========================================"

[[ "$FAIL" -eq 0 ]]
