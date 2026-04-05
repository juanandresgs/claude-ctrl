#!/usr/bin/env bash
# test-sidecar-shadow.sh — scenario tests for shadow-mode sidecars (TKT-015).
#
# Tests the full CLI path: cc-policy sidecar observatory, search, and list.
# Verifies that sidecars:
#   1. Produce valid JSON output
#   2. Return correct field structure
#   3. Return search results for known data
#   4. Do NOT add rows to any canonical table
#
# Production sequence exercised:
#   1. Populate db with proof, marker, event, worktree, dispatch, trace data
#   2. Run cc-policy sidecar observatory    — verify JSON health report
#   3. Run cc-policy sidecar search <term> — verify matching results
#   4. Run cc-policy sidecar list           — verify registry output
#   5. Compare table row counts before/after — verify read-only enforcement
#
# @decision DEC-SIDECAR-001
# @title Sidecars are read-only consumers of the canonical SQLite runtime
# @status accepted
# @rationale Scenario test exercises the real CLI dispatch path through
#   runtime/cli.py → _handle_sidecar → Observatory/SearchIndex.observe() →
#   SELECT queries. Row-count comparison proves no writes occurred.
set -euo pipefail

TEST_NAME="test-sidecar-shadow"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/state.db"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR"

RUNTIME_ROOT="${CLAUDE_RUNTIME_ROOT:-$HOME/.claude/runtime}"
CC="python3 $RUNTIME_ROOT/cli.py"

export CLAUDE_POLICY_DB="$TEST_DB"

FAILURES=0

SESSION_ID="sidecar-test-$$"

# -----------------------------------------------------------------------
# Setup: populate all canonical tables via cc-policy write commands
# -----------------------------------------------------------------------
$CC schema ensure >/dev/null 2>&1

$CC proof set   "wf-sidecar-test" pending >/dev/null 2>&1
$CC marker set  "agent-sidecar-test" "implementer" >/dev/null 2>&1
$CC event emit  "test_event" --source "test-sidecar-shadow.sh" \
                             --detail "setup event for sidecar test" >/dev/null 2>&1
$CC worktree register "/tmp/wt-sidecar-test" "feature/tkt-015" \
                      --ticket "TKT-015" >/dev/null 2>&1
# DEC-WS6-001: dispatch_queue enqueue removed (non-authoritative). Sidecar
# test does not depend on dispatch state; this line was setup noise.
$CC dispatch cycle-start "TKT-015" >/dev/null 2>&1
$CC trace start "$SESSION_ID" --role "implementer" --ticket "TKT-015" >/dev/null 2>&1
$CC trace manifest "$SESSION_ID" file_write \
    --path "sidecars/observatory/observe.py" \
    --detail "created observatory sidecar" >/dev/null 2>&1
$CC trace end "$SESSION_ID" --summary "TKT-015 sidecars implemented" >/dev/null 2>&1

# Capture row counts before any sidecar runs
count_proof=$(python3 -c "
import sqlite3, os
db='$TEST_DB'
conn=sqlite3.connect(db)
print(conn.execute('SELECT COUNT(*) FROM proof_state').fetchone()[0])
conn.close()
")
count_markers=$(python3 -c "
import sqlite3
conn=sqlite3.connect('$TEST_DB')
print(conn.execute('SELECT COUNT(*) FROM agent_markers').fetchone()[0])
conn.close()
")
count_events=$(python3 -c "
import sqlite3
conn=sqlite3.connect('$TEST_DB')
print(conn.execute('SELECT COUNT(*) FROM events').fetchone()[0])
conn.close()
")
count_worktrees=$(python3 -c "
import sqlite3
conn=sqlite3.connect('$TEST_DB')
print(conn.execute('SELECT COUNT(*) FROM worktrees').fetchone()[0])
conn.close()
")
count_dispatch=$(python3 -c "
import sqlite3
conn=sqlite3.connect('$TEST_DB')
print(conn.execute('SELECT COUNT(*) FROM dispatch_queue').fetchone()[0])
conn.close()
")
count_traces=$(python3 -c "
import sqlite3
conn=sqlite3.connect('$TEST_DB')
print(conn.execute('SELECT COUNT(*) FROM traces').fetchone()[0])
conn.close()
")
count_manifest=$(python3 -c "
import sqlite3
conn=sqlite3.connect('$TEST_DB')
print(conn.execute('SELECT COUNT(*) FROM trace_manifest').fetchone()[0])
conn.close()
")

# -----------------------------------------------------------------------
# Test 1: cc-policy sidecar observatory — valid JSON health report
# -----------------------------------------------------------------------
obs_result=$($CC sidecar observatory 2>/dev/null)
obs_status=$(echo "$obs_result" | jq -r '.status // empty' 2>/dev/null)
obs_name=$(echo "$obs_result"   | jq -r '.name // empty'   2>/dev/null)
obs_health=$(echo "$obs_result" | jq -r '.health.ok | tostring' 2>/dev/null)
obs_at=$(echo "$obs_result"     | jq -r '.observed_at // 0' 2>/dev/null)
obs_proofs=$(echo "$obs_result" | jq -r '.proof_count // -1' 2>/dev/null)
obs_agents=$(echo "$obs_result" | jq -r '.active_agents // -1' 2>/dev/null)
obs_wts=$(echo "$obs_result"    | jq -r '.worktree_count // -1' 2>/dev/null)

if [[ "$obs_status" != "ok" ]]; then
    echo "  FAIL: observatory — status not ok: $obs_result"
    FAILURES=$((FAILURES + 1))
fi

if [[ "$obs_name" != "observatory" ]]; then
    echo "  FAIL: observatory — name expected 'observatory', got: '$obs_name'"
    FAILURES=$((FAILURES + 1))
fi

if [[ -z "$obs_health" || "$obs_health" == "null" ]]; then
    echo "  FAIL: observatory — health.ok missing: $obs_result"
    FAILURES=$((FAILURES + 1))
fi

if [[ "$obs_at" -le 0 ]]; then
    echo "  FAIL: observatory — observed_at missing or zero: $obs_result"
    FAILURES=$((FAILURES + 1))
fi

if [[ "$obs_proofs" -lt 1 ]]; then
    echo "  FAIL: observatory — proof_count expected >= 1, got: $obs_proofs"
    FAILURES=$((FAILURES + 1))
fi

if [[ "$obs_agents" -lt 1 ]]; then
    echo "  FAIL: observatory — active_agents expected >= 1, got: $obs_agents"
    FAILURES=$((FAILURES + 1))
fi

if [[ "$obs_wts" -lt 1 ]]; then
    echo "  FAIL: observatory — worktree_count expected >= 1, got: $obs_wts"
    FAILURES=$((FAILURES + 1))
fi

# -----------------------------------------------------------------------
# Test 2: cc-policy sidecar search <query> — returns matching results
# -----------------------------------------------------------------------
search_result=$($CC sidecar search "TKT-015" 2>/dev/null)
search_status=$(echo "$search_result" | jq -r '.status // empty' 2>/dev/null)
search_query=$(echo "$search_result"  | jq -r '.query // empty'  2>/dev/null)
search_count=$(echo "$search_result"  | jq -r '.count // 0'      2>/dev/null)

if [[ "$search_status" != "ok" ]]; then
    echo "  FAIL: search — status not ok: $search_result"
    FAILURES=$((FAILURES + 1))
fi

if [[ "$search_query" != "TKT-015" ]]; then
    echo "  FAIL: search — query echo expected 'TKT-015', got: '$search_query'"
    FAILURES=$((FAILURES + 1))
fi

if [[ "$search_count" -lt 1 ]]; then
    echo "  FAIL: search — expected at least 1 result for 'TKT-015', got: $search_count"
    FAILURES=$((FAILURES + 1))
fi

# At least one result should be a trace
has_trace=$(echo "$search_result" | jq -r '[.results[].type] | index("trace") != null | tostring' 2>/dev/null)
if [[ "$has_trace" != "true" ]]; then
    echo "  FAIL: search — expected at least one 'trace' result type, got: $search_result"
    FAILURES=$((FAILURES + 1))
fi

# -----------------------------------------------------------------------
# Test 3: cc-policy sidecar search with --limit
# -----------------------------------------------------------------------
# Create 15 more traces all containing "sidecar-limit-test"
for i in $(seq 1 15); do
    $CC trace start "sidecar-limit-$$-$i" --role "implementer" \
        --ticket "sidecar-limit-test" >/dev/null 2>&1
done

limit_result=$($CC sidecar search "sidecar-limit-test" --limit 5 2>/dev/null)
limit_count=$(echo "$limit_result" | jq -r '.count // 0' 2>/dev/null)

if [[ "$limit_count" -gt 5 ]]; then
    echo "  FAIL: search --limit 5 — expected <= 5 results, got: $limit_count"
    FAILURES=$((FAILURES + 1))
fi

# -----------------------------------------------------------------------
# Test 4: cc-policy sidecar search no-match — returns empty results
# -----------------------------------------------------------------------
nomatch_result=$($CC sidecar search "zzz-no-such-term-xyzabc" 2>/dev/null)
nomatch_status=$(echo "$nomatch_result" | jq -r '.status // empty' 2>/dev/null)
nomatch_count=$(echo "$nomatch_result"  | jq -r '.count // 0'      2>/dev/null)

if [[ "$nomatch_status" != "ok" ]]; then
    echo "  FAIL: search no-match — status not ok: $nomatch_result"
    FAILURES=$((FAILURES + 1))
fi

if [[ "$nomatch_count" -ne 0 ]]; then
    echo "  FAIL: search no-match — expected 0 results, got: $nomatch_count"
    FAILURES=$((FAILURES + 1))
fi

# -----------------------------------------------------------------------
# Test 5: cc-policy sidecar list — returns registry
# -----------------------------------------------------------------------
list_result=$($CC sidecar list 2>/dev/null)
list_status=$(echo "$list_result" | jq -r '.status // empty'  2>/dev/null)
list_count=$(echo "$list_result"  | jq -r '.count // 0'       2>/dev/null)
has_obs=$(echo "$list_result"   | jq -r '[.sidecars[].name] | index("observatory") != null | tostring' 2>/dev/null)
has_search=$(echo "$list_result" | jq -r '[.sidecars[].name] | index("search") != null | tostring' 2>/dev/null)

if [[ "$list_status" != "ok" ]]; then
    echo "  FAIL: sidecar list — status not ok: $list_result"
    FAILURES=$((FAILURES + 1))
fi

if [[ "$list_count" -lt 2 ]]; then
    echo "  FAIL: sidecar list — expected >= 2 sidecars, got: $list_count"
    FAILURES=$((FAILURES + 1))
fi

if [[ "$has_obs" != "true" ]]; then
    echo "  FAIL: sidecar list — 'observatory' not in registry: $list_result"
    FAILURES=$((FAILURES + 1))
fi

if [[ "$has_search" != "true" ]]; then
    echo "  FAIL: sidecar list — 'search' not in registry: $list_result"
    FAILURES=$((FAILURES + 1))
fi

# -----------------------------------------------------------------------
# Test 6: Read-only enforcement — row counts unchanged after sidecar runs
# -----------------------------------------------------------------------
new_proof=$(python3 -c "
import sqlite3
conn=sqlite3.connect('$TEST_DB')
print(conn.execute('SELECT COUNT(*) FROM proof_state').fetchone()[0])
conn.close()
")
new_markers=$(python3 -c "
import sqlite3
conn=sqlite3.connect('$TEST_DB')
print(conn.execute('SELECT COUNT(*) FROM agent_markers').fetchone()[0])
conn.close()
")
new_events=$(python3 -c "
import sqlite3
conn=sqlite3.connect('$TEST_DB')
print(conn.execute('SELECT COUNT(*) FROM events').fetchone()[0])
conn.close()
")
new_worktrees=$(python3 -c "
import sqlite3
conn=sqlite3.connect('$TEST_DB')
print(conn.execute('SELECT COUNT(*) FROM worktrees').fetchone()[0])
conn.close()
")
new_dispatch=$(python3 -c "
import sqlite3
conn=sqlite3.connect('$TEST_DB')
print(conn.execute('SELECT COUNT(*) FROM dispatch_queue').fetchone()[0])
conn.close()
")
new_traces=$(python3 -c "
import sqlite3
conn=sqlite3.connect('$TEST_DB')
print(conn.execute('SELECT COUNT(*) FROM traces').fetchone()[0])
conn.close()
")
new_manifest=$(python3 -c "
import sqlite3
conn=sqlite3.connect('$TEST_DB')
print(conn.execute('SELECT COUNT(*) FROM trace_manifest').fetchone()[0])
conn.close()
")

# proof_state, agent_markers, events, worktrees, dispatch_queue, trace_manifest
# must be unchanged. traces will have grown because we added 15 sidecar-limit-test
# traces above — those were written by cc-policy trace start (not sidecars), so
# we only check the tables that sidecars could potentially write to but shouldn't.

if [[ "$new_proof" -ne "$count_proof" ]]; then
    echo "  FAIL: read-only — proof_state rows changed: before=$count_proof after=$new_proof"
    FAILURES=$((FAILURES + 1))
fi

if [[ "$new_markers" -ne "$count_markers" ]]; then
    echo "  FAIL: read-only — agent_markers rows changed: before=$count_markers after=$new_markers"
    FAILURES=$((FAILURES + 1))
fi

if [[ "$new_events" -ne "$count_events" ]]; then
    echo "  FAIL: read-only — events rows changed: before=$count_events after=$new_events"
    FAILURES=$((FAILURES + 1))
fi

if [[ "$new_worktrees" -ne "$count_worktrees" ]]; then
    echo "  FAIL: read-only — worktrees rows changed: before=$count_worktrees after=$new_worktrees"
    FAILURES=$((FAILURES + 1))
fi

if [[ "$new_dispatch" -ne "$count_dispatch" ]]; then
    echo "  FAIL: read-only — dispatch_queue rows changed: before=$count_dispatch after=$new_dispatch"
    FAILURES=$((FAILURES + 1))
fi

if [[ "$new_manifest" -ne "$count_manifest" ]]; then
    echo "  FAIL: read-only — trace_manifest rows changed: before=$count_manifest after=$new_manifest"
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
