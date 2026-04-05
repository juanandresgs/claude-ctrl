#!/usr/bin/env bash
# test-runtime-consistency.sh — Verify that all runtime state domains are
# consistent: what is written through one path is readable through another.
#
# Four round-trip sequences tested:
#   1. Write proof via context-lib.sh write_proof_status
#      -> read via cc-policy proof get -> same value
#   2. Write marker via cc-policy marker set
#      -> read via cc-policy marker get-active -> same role
#   3. Emit event via cc-policy event emit
#      -> query via cc-policy event query -> event present
#   4. Populate runtime state (proof + marker + worktree + dispatch + events)
#      -> cc-policy statusline snapshot reflects all of the above
#
# Each test uses an isolated DB (CLAUDE_POLICY_DB) so the real state.db is
# never touched and tests are fully repeatable.
#
# @decision DEC-ACC-003
# @title Runtime consistency tests exercise the full read-write round trip
# @status accepted
# @rationale The runtime bridge (runtime-bridge.sh) calls cc-policy CLI which
#   writes to SQLite. The statusline snapshot reads from the same SQLite tables.
#   A bug anywhere in the chain (bridge, CLI, domain module, statusline) would
#   produce inconsistent state. These tests prove the chain is end-to-end
#   coherent by writing through one surface and reading through another.
#
# Usage:  bash tests/acceptance/test-runtime-consistency.sh
# Exit:   0 all pass, 1 any fail
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLI="$REPO_ROOT/runtime/cli.py"
BRIDGE="$REPO_ROOT/hooks/lib/runtime-bridge.sh"
CONTEXT_LIB="$REPO_ROOT/hooks/context-lib.sh"
TMP_DIR="$REPO_ROOT/tmp/rt-consistency-$$"
DB="$TMP_DIR/state.db"

PASS=0
FAIL=0
FAILED_CASES=()

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR"

# cc-policy helper scoped to the test DB
policy() {
    CLAUDE_POLICY_DB="$DB" PYTHONPATH="$REPO_ROOT" python3 "$CLI" "$@"
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — expected "%s", got "%s"\n' "$label" "$expected" "$actual"
        FAIL=$(( FAIL + 1 )); FAILED_CASES+=("$label")
    fi
}

assert_jq_true() {
    local label="$1" json="$2" expr="$3"
    local result
    result=$(printf '%s' "$json" | jq -r "$expr" 2>/dev/null || true)
    if [[ "$result" == "true" || ( -n "$result" && "$result" != "null" && "$result" != "false" ) ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — expr "%s" returned "%s"\n' "$label" "$expr" "$result"
        FAIL=$(( FAIL + 1 )); FAILED_CASES+=("$label")
    fi
}

# ---------------------------------------------------------------------------
# Test 1: proof round-trip through runtime-bridge.sh
#   write_proof_status (context-lib.sh) -> rt_proof_set (bridge) -> cc-policy
#   proof get -> same status string
# ---------------------------------------------------------------------------
printf '\n-- 1: proof round-trip (bridge write -> CLI read)\n'

# Source the bridge and write proof through it
WORKFLOW="wf-consistency-test"
(
    CLAUDE_POLICY_DB="$DB"
    export CLAUDE_POLICY_DB
    # shellcheck source=/dev/null
    source "$BRIDGE"
    rt_proof_set "$WORKFLOW" "verified"
)

result=$(policy proof get "$WORKFLOW")
status=$(printf '%s' "$result" | jq -r '.status // empty')
assert_eq "proof round-trip: status is verified" "verified" "$status"

found=$(printf '%s' "$result" | jq -r '.found // false')
assert_eq "proof round-trip: found is true" "true" "$found"

# ---------------------------------------------------------------------------
# Test 2: marker round-trip
#   cc-policy marker set -> cc-policy marker get-active -> same role
# ---------------------------------------------------------------------------
printf '\n-- 2: marker round-trip (CLI write -> CLI read)\n'

policy marker set "agent-rt-001" "tester" >/dev/null
result=$(policy marker get-active)

role=$(printf '%s' "$result" | jq -r '.role // empty')
agent_id=$(printf '%s' "$result" | jq -r '.agent_id // empty')
assert_eq "marker round-trip: role is tester"           "tester"       "$role"
assert_eq "marker round-trip: agent_id matches"         "agent-rt-001" "$agent_id"
assert_eq "marker round-trip: found is true"            "true" \
    "$(printf '%s' "$result" | jq -r '.found // false')"

# ---------------------------------------------------------------------------
# Test 3: event round-trip
#   cc-policy event emit -> cc-policy event query -> event present with detail
# ---------------------------------------------------------------------------
printf '\n-- 3: event round-trip (emit -> query)\n'

policy event emit "acceptance.probe" --detail "consistency-check" >/dev/null
result=$(policy event query --type "acceptance.probe" --limit 1)

count=$(printf '%s' "$result" | jq -r '.count // 0')
assert_jq_true "event round-trip: count >= 1"        "$result" "(.count >= 1)"

detail=$(printf '%s' "$result" | jq -r '.items[0].detail // empty')
assert_eq "event round-trip: detail preserved" "consistency-check" "$detail"

ev_type=$(printf '%s' "$result" | jq -r '.items[0].type // empty')
assert_eq "event round-trip: type preserved" "acceptance.probe" "$ev_type"

# ---------------------------------------------------------------------------
# Test 4: statusline snapshot reflects all populated state
# ---------------------------------------------------------------------------
printf '\n-- 4: statusline snapshot reflects populated runtime state\n'

# Add a worktree and a dispatch cycle so snapshot has non-default values
policy worktree register "/tmp/rt-wt-a" "feature/rt-a" --ticket "TKT-014" >/dev/null
cycle_json=$(policy dispatch cycle-start "INIT-RT-TEST")

# DEC-WS6-001: dispatch_status is derived from the latest completion record via
# determine_next_role(role, verdict), not from dispatch_queue. Issue a tester
# lease and submit a completion with verdict=ready_for_guardian so the snapshot
# returns dispatch_status=guardian.
RT_WORKFLOW="wf-rt-dispatch-test"
policy workflow bind "$RT_WORKFLOW" "$TMP_DIR" "feature/rt-test" >/dev/null 2>&1 || true
policy workflow scope-set "$RT_WORKFLOW" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1 || true
TESTER_LEASE_OUT=$(policy lease issue-for-dispatch "tester" \
    --worktree-path "$TMP_DIR" \
    --workflow-id "$RT_WORKFLOW" \
    --allowed-ops '["routine_local"]' 2>/dev/null || echo '{}')
TESTER_LEASE_ID=$(printf '%s' "$TESTER_LEASE_OUT" | jq -r '.lease.lease_id // empty' 2>/dev/null || true)
if [[ -n "$TESTER_LEASE_ID" ]]; then
    COMP_PAYLOAD='{"EVAL_VERDICT":"ready_for_guardian","EVAL_TESTS_PASS":"true","EVAL_NEXT_ROLE":"guardian","EVAL_HEAD_SHA":"abc123"}'
    policy completion submit \
        --lease-id "$TESTER_LEASE_ID" \
        --workflow-id "$RT_WORKFLOW" \
        --role "tester" \
        --payload "$COMP_PAYLOAD" >/dev/null 2>&1 || true
fi

snap=$(policy statusline snapshot)

assert_eq "snapshot: status ok"           "ok"       "$(printf '%s' "$snap" | jq -r '.status')"
assert_eq "snapshot: proof is verified"   "verified" "$(printf '%s' "$snap" | jq -r '.proof_status')"
assert_eq "snapshot: proof workflow"      "$WORKFLOW" "$(printf '%s' "$snap" | jq -r '.proof_workflow')"
assert_eq "snapshot: active_agent tester" "tester"   "$(printf '%s' "$snap" | jq -r '.active_agent')"
assert_jq_true "snapshot: worktree_count >= 1" "$snap" "(.worktree_count >= 1)"
assert_eq "snapshot: dispatch_status guardian" "guardian" \
    "$(printf '%s' "$snap" | jq -r '.dispatch_status')"
assert_eq "snapshot: dispatch_initiative" "INIT-RT-TEST" \
    "$(printf '%s' "$snap" | jq -r '.dispatch_initiative')"
assert_jq_true "snapshot: recent_event_count >= 1" "$snap" "(.recent_event_count >= 1)"
assert_jq_true "snapshot: snapshot_at is positive epoch" "$snap" "(.snapshot_at > 0)"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n=== test-runtime-consistency: %d passed, %d failed ===\n' "$PASS" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
    printf 'Failed cases:\n'
    for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
    printf '\nFAIL: test-runtime-consistency\n'
    exit 1
fi

printf 'PASS: test-runtime-consistency\n'
exit 0
