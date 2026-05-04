#!/usr/bin/env bash
# test-statusline-snapshot.sh — scenario test for `cc-policy statusline snapshot`.
#
# Verifies that the CLI path returns a JSON object containing all canonical
# statusline fields, and that evaluation, worktree_count, dispatch_status,
# and active_agent fields reflect state mutations made through other cc-policy
# subcommands.
#
# Production sequence exercised:
#   1. Schema ensured (auto-provisioned on first call)
#   2. State populated via cc-policy marker/worktree/completion/event
#   3. cc-policy statusline snapshot called
#   4. JSON output validated for key presence and correct values
#
# Uses a temp DB scoped to this test run via CLAUDE_POLICY_DB so the real
# ~/.claude/state.db is never touched.
#
# @decision DEC-RT-011
# @title Statusline snapshot is a read-only projection across all runtime tables
# @status accepted
# @rationale Scenario tests validate the CLI entry point (cc-policy statusline
#   snapshot) end-to-end, exercising the full stack: arg parsing, domain
#   module queries, JSON serialisation. They complement the unit tests in
#   tests/runtime/test_statusline.py which test snapshot() directly. Both
#   suites are required: unit tests cover edge cases cheaply; scenario tests
#   prove the production CLI path is wired correctly.
set -euo pipefail

TEST_NAME="test-statusline-snapshot"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$REPO_ROOT/runtime/cli.py"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
DB="$TMP_DIR/state.db"
PASS=0
FAIL=0

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR"

# ---------------------------------------------------------------------------
# Helper: run cc-policy with the test DB, print stdout
# ---------------------------------------------------------------------------
policy() {
    CLAUDE_POLICY_DB="$DB" PYTHONPATH="$REPO_ROOT" python3 "$CLI" "$@"
}

# ---------------------------------------------------------------------------
# Helper: assert a jq expression is truthy on the given JSON
# ---------------------------------------------------------------------------
assert_jq() {
    local label="$1"
    local json="$2"
    local expr="$3"
    local result
    result=$(printf '%s' "$json" | jq -r "$expr" 2>/dev/null)
    if [[ "$result" == "true" || ( -n "$result" && "$result" != "null" && "$result" != "false" ) ]]; then
        printf '  PASS: %s\n' "$label"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s (got: %s)\n' "$label" "$result"
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---------------------------------------------------------------------------
# Helper: assert a jq field equals an expected value
# ---------------------------------------------------------------------------
assert_eq() {
    local label="$1"
    local json="$2"
    local expr="$3"
    local expected="$4"
    local result
    result=$(printf '%s' "$json" | jq -r "$expr" 2>/dev/null)
    if [[ "$result" == "$expected" ]]; then
        printf '  PASS: %s\n' "$label"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s (expected %s, got %s)\n' "$label" "$expected" "$result"
        FAIL=$(( FAIL + 1 ))
    fi
}

echo "=== $TEST_NAME ==="

# ---------------------------------------------------------------------------
# Test 1: Empty DB returns all required keys with safe defaults
# ---------------------------------------------------------------------------
echo ""
echo "-- 1: empty DB snapshot has all required keys and safe defaults"

snap=$(policy statusline snapshot)

# W-CONV-4: proof_status/proof_workflow removed from snapshot
# DEC-SL-160: last_review and errors are new required fields
for key in active_agent active_agent_id \
           eval_status eval_workflow eval_head_sha marker_age_seconds \
           worktree_count worktrees dispatch_status dispatch_workflow \
           dispatch_from_role dispatch_from_verdict dispatch_initiative \
           dispatch_cycle_id recent_event_count recent_events \
           last_review critic_run snapshot_at status errors; do
    assert_jq "key '$key' present" "$snap" "has(\"$key\")"
done

assert_jq "proof_status absent (W-CONV-4)" "$snap" "(has(\"proof_status\") | not)"
assert_jq "proof_workflow absent (W-CONV-4)" "$snap" "(has(\"proof_workflow\") | not)"
assert_eq "worktree_count defaults to 0"    "$snap" ".worktree_count" "0"
assert_eq "active_agent defaults to null"   "$snap" ".active_agent"   "null"
assert_eq "status is ok"                    "$snap" ".status"         "ok"
assert_eq "errors defaults to []"           "$snap" "(.errors | length)" "0"
assert_eq "last_review.reviewed is false"   "$snap" ".last_review.reviewed" "false"
assert_eq "critic_run.found is false"       "$snap" ".critic_run.found" "false"

# ---------------------------------------------------------------------------
# Test 3: active_agent reflects marker
# ---------------------------------------------------------------------------
echo ""
echo "-- 3: active_agent reflects active marker"

# Phase 8 Slice 11: use a live role (reviewer) — ``tester`` is retired and
# markers set with role="tester" are rejected by ensure_schema cleanup.
policy marker set "agent-sc-001" "reviewer" >/dev/null

snap=$(policy statusline snapshot)
assert_eq "active_agent is reviewer"          "$snap" ".active_agent"    "reviewer"
assert_eq "active_agent_id is agent-sc-001"   "$snap" ".active_agent_id" "agent-sc-001"

# ---------------------------------------------------------------------------
# Test 4: worktree_count and worktrees list reflect registered worktrees
# ---------------------------------------------------------------------------
echo ""
echo "-- 4: worktree_count and worktrees list reflect registered worktrees"

policy worktree register "/wt/scenario-a" "feature/scenario-a" --ticket "TKT-011" >/dev/null
policy worktree register "/wt/scenario-b" "feature/scenario-b" >/dev/null

snap=$(policy statusline snapshot)
assert_eq "worktree_count is 2"             "$snap" ".worktree_count"       "2"
assert_eq "worktrees list length is 2"      "$snap" "(.worktrees | length)" "2"
assert_jq "worktrees contains /wt/scenario-a" "$snap" \
    '[.worktrees[].path] | any(. == "/wt/scenario-a")'
assert_eq "ticket populated on scenario-a"  "$snap" \
    '(.worktrees[] | select(.path == "/wt/scenario-a") | .ticket)' "TKT-011"

# Soft-delete scenario-b; count must drop to 1
policy worktree remove "/wt/scenario-b" >/dev/null
snap=$(policy statusline snapshot)
assert_eq "worktree_count drops to 1 after remove" "$snap" ".worktree_count" "1"

# ---------------------------------------------------------------------------
# Test 5: dispatch_status reflects latest valid completion record
# ---------------------------------------------------------------------------
echo ""
echo "-- 5: dispatch_status derives from completion records"

review_payload=$(jq -nc '{
    REVIEW_VERDICT: "ready_for_guardian",
    REVIEW_HEAD_SHA: "abc123",
    REVIEW_FINDINGS_JSON: ({findings: [{severity: "note", title: "ok", detail: "looks good"}]} | tojson)
}')

policy completion submit \
    --lease-id "lease-sc-001" \
    --workflow-id "wf-sc-001" \
    --role "reviewer" \
    --payload "$review_payload" >/dev/null

# DEC-WS6-001: dispatch_queue/cycle storage is retired. dispatch_status now
# derives from the latest valid completion record; cycle fields remain present
# with null defaults for compatibility.
snap=$(policy statusline snapshot)
assert_eq "dispatch_status is guardian"        "$snap" ".dispatch_status"       "guardian"
assert_eq "dispatch_workflow matches"          "$snap" ".dispatch_workflow"     "wf-sc-001"
assert_eq "dispatch_from_role is reviewer"     "$snap" ".dispatch_from_role"    "reviewer"
assert_eq "dispatch_from_verdict matches"      "$snap" ".dispatch_from_verdict" "ready_for_guardian"
assert_eq "dispatch_initiative remains null"   "$snap" ".dispatch_initiative"   "null"
assert_eq "dispatch_cycle_id remains null"     "$snap" ".dispatch_cycle_id"     "null"

# ---------------------------------------------------------------------------
# Test 6: recent_events list populated
# ---------------------------------------------------------------------------
echo ""
echo "-- 6: recent_events list populated"

policy event emit "scenario.probe" --detail "test run" >/dev/null
policy event emit "scenario.check" --detail "verify"   >/dev/null

snap=$(policy statusline snapshot)
assert_eq "recent_event_count is 2"            "$snap" ".recent_event_count"        "2"
assert_eq "recent_events list length is 2"     "$snap" "(.recent_events | length)"  "2"
# newest first
assert_eq "first event type is scenario.check" "$snap" ".recent_events[0].type"    "scenario.check"
assert_jq "first event has created_at"         "$snap" "(.recent_events[0].created_at > 0)"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== $TEST_NAME results: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
