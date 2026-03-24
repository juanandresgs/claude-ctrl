#!/usr/bin/env bash
# test-dispatch-queue.sh: exercises the dispatch helpers for enqueue/next/
# start/complete round-trip via dispatch-helpers.sh and cc-policy directly.
#
# @decision DEC-DISPATCH-003
# @title Test dispatch queue FIFO ordering and lifecycle transitions
# @status accepted
# @rationale The dispatch queue implements a claim-execute-ack pattern:
#   pending → active → done. FIFO ordering is required so the canonical flow
#   (planner→implementer→tester→guardian) proceeds in insertion order.
#   These tests exercise the full round-trip through dispatch-helpers.sh so
#   the shell wrappers are validated against the live SQLite backend, not
#   mocked. This is the compound-interaction test that crosses dispatch_queue
#   table rows, dispatch-helpers.sh wrappers, and runtime-bridge.sh.
set -euo pipefail

TEST_NAME="test-dispatch-queue"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPERS="$REPO_ROOT/hooks/lib/dispatch-helpers.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/state.db"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR"

# Ensure helpers file exists
if [[ ! -f "$HELPERS" ]]; then
    echo "FAIL: $TEST_NAME — hooks/lib/dispatch-helpers.sh not found"
    exit 1
fi

RUNTIME_ROOT="${CLAUDE_RUNTIME_ROOT:-$HOME/.claude/runtime}"
CC="python3 $RUNTIME_ROOT/cli.py"

# Use isolated test db for all operations
export CLAUDE_POLICY_DB="$TEST_DB"

FAILURES=0

# Source helpers so we can call dispatch_status, dispatch_cycle_start, etc.
# The helpers source runtime-bridge.sh which calls cc_policy(), and cc_policy()
# uses CLAUDE_POLICY_DB env var — already set above.
source "$HELPERS" 2>/dev/null || {
    echo "  FAIL: could not source dispatch-helpers.sh"
    FAILURES=$((FAILURES + 1))
}

# -----------------------------------------------------------------------
# Test 1: empty queue reports "queue empty"
# -----------------------------------------------------------------------
status=$(dispatch_status 2>/dev/null || echo "error")
if [[ "$status" != "queue empty" ]]; then
    echo "  FAIL: empty queue — expected 'queue empty', got: '$status'"
    FAILURES=$((FAILURES + 1))
fi

# -----------------------------------------------------------------------
# Test 2: enqueue two items, verify FIFO ordering via dispatch next
# -----------------------------------------------------------------------
id1=$($CC dispatch enqueue "implementer" 2>/dev/null | jq -r '.id // empty')
id2=$($CC dispatch enqueue "tester" 2>/dev/null | jq -r '.id // empty')

if [[ -z "$id1" || -z "$id2" ]]; then
    echo "  FAIL: enqueue — could not enqueue items (id1=$id1, id2=$id2)"
    FAILURES=$((FAILURES + 1))
fi

# Next should be the first enqueued item (implementer)
next_role=$($CC dispatch next 2>/dev/null | jq -r '.role // empty')
if [[ "$next_role" != "implementer" ]]; then
    echo "  FAIL: FIFO order — expected 'implementer' first, got: '$next_role'"
    FAILURES=$((FAILURES + 1))
fi

# dispatch_status helper should now report the next role
helper_status=$(dispatch_status 2>/dev/null || echo "error")
if [[ "$helper_status" != "next: implementer" ]]; then
    echo "  FAIL: dispatch_status — expected 'next: implementer', got: '$helper_status'"
    FAILURES=$((FAILURES + 1))
fi

# -----------------------------------------------------------------------
# Test 3: start → item transitions to active, next shifts to second item
# -----------------------------------------------------------------------
next_id=$($CC dispatch next 2>/dev/null | jq -r '.id // empty')
$CC dispatch start "$next_id" >/dev/null 2>&1

# After starting the first item, next_pending should return the second (tester)
next_role_2=$($CC dispatch next 2>/dev/null | jq -r '.role // empty')
if [[ "$next_role_2" != "tester" ]]; then
    echo "  FAIL: after start — expected 'tester' as next pending, got: '$next_role_2'"
    FAILURES=$((FAILURES + 1))
fi

# -----------------------------------------------------------------------
# Test 4: complete first item → queue advances, complete second → empty
# -----------------------------------------------------------------------
$CC dispatch complete "$next_id" >/dev/null 2>&1

next_id_2=$($CC dispatch next 2>/dev/null | jq -r '.id // empty')
$CC dispatch start "$next_id_2" >/dev/null 2>&1
$CC dispatch complete "$next_id_2" >/dev/null 2>&1

# Queue now empty
final_status=$(dispatch_status 2>/dev/null || echo "error")
if [[ "$final_status" != "queue empty" ]]; then
    echo "  FAIL: after complete — expected 'queue empty', got: '$final_status'"
    FAILURES=$((FAILURES + 1))
fi

# -----------------------------------------------------------------------
# Test 5: dispatch_cycle_start + dispatch_cycle_current round-trip
# -----------------------------------------------------------------------
dispatch_cycle_start "INIT-002" 2>/dev/null || {
    echo "  FAIL: dispatch_cycle_start — returned non-zero"
    FAILURES=$((FAILURES + 1))
}

cycle_info=$(dispatch_cycle_current 2>/dev/null || echo "")
if [[ -z "$cycle_info" ]]; then
    echo "  FAIL: dispatch_cycle_current — returned empty"
    FAILURES=$((FAILURES + 1))
else
    initiative=$(echo "$cycle_info" | jq -r '.initiative // empty' 2>/dev/null || echo "")
    if [[ "$initiative" != "INIT-002" ]]; then
        echo "  FAIL: cycle initiative — expected 'INIT-002', got: '$initiative'"
        FAILURES=$((FAILURES + 1))
    fi
fi

# -----------------------------------------------------------------------
# Test 6: compound interaction — full planner→implementer flow via helpers
# This tests the exact production sequence post-task.sh would trigger:
#   1. agent completes (planner)
#   2. post-task enqueues implementer
#   3. next dispatch item is implementer
#   4. item is claimed and completed
# -----------------------------------------------------------------------
# Re-use an isolated db segment by enqueuing from scratch in the same db
$CC dispatch enqueue "implementer" >/dev/null 2>&1
$CC dispatch enqueue "tester"      >/dev/null 2>&1

# Simulate implementer being dispatched and completing
impl_id=$($CC dispatch next 2>/dev/null | jq -r '.id // empty')
$CC dispatch start    "$impl_id" >/dev/null 2>&1
$CC dispatch complete "$impl_id" >/dev/null 2>&1

# Now tester should be next
after_impl=$($CC dispatch next 2>/dev/null | jq -r '.role // empty')
if [[ "$after_impl" != "tester" ]]; then
    echo "  FAIL: compound — after implementer done, expected 'tester', got: '$after_impl'"
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
