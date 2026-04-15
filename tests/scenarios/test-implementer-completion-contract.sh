#!/usr/bin/env bash
# test-implementer-completion-contract.sh: Verifies the implementer completion
# contract end-to-end. When IMPL_STATUS and IMPL_HEAD_SHA trailers are present
# in the implementer response, check-implementer.sh submits a completion record,
# and dispatch_engine (via post-task.sh) prefers the contract over the heuristic
# for agent_complete vs agent_stopped.
#
# Production sequence tested:
#   1. An implementer lease is issued with an explicit workflow_id
#   2. check-implementer.sh runs with IMPL_STATUS=complete → submits valid record
#   3. post-task.sh fires → process_agent_stop → reads contract → agent_complete
#   4. next_role = reviewer (routing unchanged)
#   5. Malformed IMPL_STATUS → invalid record, impl_contract_invalid event emitted
#   6. Missing trailers → no record submitted, heuristic fallback applies
#
# @decision DEC-IMPL-CONTRACT-003
# @title Scenario: implementer completion contract overrides stop-assessment heuristic
# @status accepted
# @rationale End-to-end proof of DEC-IMPL-CONTRACT-001: the structured contract
#   (IMPL_STATUS + IMPL_HEAD_SHA) is the authoritative source for agent_complete
#   vs agent_stopped when present and valid. This test exercises the full path
#   from check-implementer.sh trailer parsing through dispatch_engine routing,
#   confirming that routing stays fixed at implementer → reviewer regardless.
set -euo pipefail

TEST_NAME="test-implementer-completion-contract"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
POST_TASK_HOOK="$REPO_ROOT/hooks/post-task.sh"
CHECK_IMPL_HOOK="$REPO_ROOT/hooks/check-implementer.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/state.db"
TMP_GIT="$TMP_DIR/git-repo"

trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR" "$TMP_GIT"

# Initialize a minimal git repo on a feature branch
git -C "$TMP_GIT" init -q 2>/dev/null
git -C "$TMP_GIT" checkout -b feature/impl-contract-test 2>/dev/null
git -C "$TMP_GIT" -c user.email="t@t.com" -c user.name="T" commit --allow-empty -m "init" -q 2>/dev/null

CC="python3 $REPO_ROOT/runtime/cli.py"
export CLAUDE_POLICY_DB="$TEST_DB"
export CLAUDE_PROJECT_DIR="$TMP_GIT"
export CLAUDE_RUNTIME_ROOT="$REPO_ROOT/runtime"

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "=== $TEST_NAME ==="

# Bootstrap schema
$CC schema ensure >/dev/null 2>&1

# ---------------------------------------------------------------------------
# Test 1: Valid IMPL_STATUS=complete → agent_complete event, next_role=reviewer
# ---------------------------------------------------------------------------
LEASE_WF_ID="wf-impl-contract-scenario-001"
ISSUE_OUT=$($CC lease issue-for-dispatch "implementer" \
    --worktree-path "$TMP_GIT" \
    --workflow-id "$LEASE_WF_ID" \
    --allowed-ops '["routine_local"]' 2>/dev/null)
LEASE_ID=$(printf '%s' "$ISSUE_OUT" | jq -r '.lease.lease_id // empty' 2>/dev/null || true)

if [[ -n "$LEASE_ID" ]]; then
    pass "implementer lease issued (workflow_id=$LEASE_WF_ID, lease_id=$LEASE_ID)"
else
    fail "implementer lease issued — cannot proceed"
    echo "FAIL: $TEST_NAME — cannot set up lease"
    exit 1
fi

# Build a fake implementer response with valid IMPL_STATUS and IMPL_HEAD_SHA trailers
IMPL_RESPONSE="Implementation complete. All tests pass.

IMPL_STATUS: complete
IMPL_HEAD_SHA: deadbeef
IMPL_SCOPE_OK: yes"

CI_PAYLOAD=$(jq -n \
    --arg r "$IMPL_RESPONSE" \
    --arg at "implementer" \
    '{agent_type: $at, response: $r}')

# Run check-implementer.sh — should parse trailers and submit completion record
CI_OUTPUT=$(printf '%s' "$CI_PAYLOAD" \
    | CLAUDE_PROJECT_DIR="$TMP_GIT" CLAUDE_POLICY_DB="$TEST_DB" "$CHECK_IMPL_HOOK" 2>/dev/null || true)

echo "  [debug] check-implementer output: $CI_OUTPUT"

CI_CTX=$(printf '%s' "$CI_OUTPUT" | jq -r '.additionalContext // empty' 2>/dev/null || true)
if [[ "$CI_CTX" == *"IMPL_STATUS=complete"* && "$CI_CTX" == *"valid, submitted"* ]]; then
    pass "check-implementer submitted completion record (IMPL_STATUS=complete)"
else
    fail "check-implementer submitted completion record — ctx: $CI_CTX"
fi

# Verify the completion record was actually written to DB
COMP_JSON=$($CC completion latest --lease-id "$LEASE_ID" 2>/dev/null || echo '{}')
COMP_VALID=$(printf '%s' "$COMP_JSON" | jq -r 'if .valid == 1 or .valid == true then "true" else "false" end' 2>/dev/null || echo "false")
COMP_VERDICT=$(printf '%s' "$COMP_JSON" | jq -r '.verdict // "none"' 2>/dev/null || echo "none")
if [[ "$COMP_VALID" == "true" && "$COMP_VERDICT" == "complete" ]]; then
    pass "completion record stored: valid=true, verdict=complete"
else
    fail "completion record stored — valid=$COMP_VALID verdict=$COMP_VERDICT"
fi

# Run post-task.sh — should emit agent_complete (not agent_stopped), next_role=reviewer
HOOK_PAYLOAD=$(printf '{"hook_event_name":"SubagentStop","agent_type":"implementer"}')
HOOK_OUTPUT=$(printf '%s' "$HOOK_PAYLOAD" \
    | CLAUDE_PROJECT_DIR="$TMP_GIT" CLAUDE_POLICY_DB="$TEST_DB" "$POST_TASK_HOOK" 2>/dev/null || true)

echo "  [debug] post-task output: $HOOK_OUTPUT"

if printf '%s' "$HOOK_OUTPUT" | jq '.' >/dev/null 2>&1; then
    PT_CTX=$(printf '%s' "$HOOK_OUTPUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)
    if [[ "$PT_CTX" == *"reviewer"* ]]; then
        pass "dispatch context suggests reviewer (routing correct)"
    else
        fail "dispatch context suggests reviewer — got: $PT_CTX"
    fi
else
    fail "post-task hook output is valid JSON (got: $HOOK_OUTPUT)"
fi

# Verify agent_complete event was emitted (not agent_stopped)
EVENTS_JSON=$($CC event query --type agent_complete --limit 5 2>/dev/null || echo '{"items":[],"count":0}')
COMPLETE_COUNT=$(printf '%s' "$EVENTS_JSON" | jq '.count // (.items | length) // 0' 2>/dev/null || echo "0")
if [[ "$COMPLETE_COUNT" -ge 1 ]]; then
    pass "agent_complete event emitted (contract=complete)"
else
    fail "agent_complete event emitted — found $COMPLETE_COUNT events"
fi

# ---------------------------------------------------------------------------
# Test 2: Malformed IMPL_STATUS → invalid contract, impl_contract_invalid event
# ---------------------------------------------------------------------------
LEASE_WF_ID2="wf-impl-contract-scenario-002"
ISSUE_OUT2=$($CC lease issue-for-dispatch "implementer" \
    --worktree-path "$TMP_GIT" \
    --workflow-id "$LEASE_WF_ID2" \
    --allowed-ops '["routine_local"]' 2>/dev/null)
LEASE_ID2=$(printf '%s' "$ISSUE_OUT2" | jq -r '.lease.lease_id // empty' 2>/dev/null || true)

if [[ -n "$LEASE_ID2" ]]; then
    pass "second implementer lease issued for malformed-contract test"
else
    fail "second implementer lease issued"
fi

IMPL_RESPONSE_BAD="Implementation done.

IMPL_STATUS: bogus_verdict
IMPL_HEAD_SHA: deadbeef"

CI_PAYLOAD2=$(jq -n \
    --arg r "$IMPL_RESPONSE_BAD" \
    --arg at "implementer" \
    '{agent_type: $at, response: $r}')

CI_OUTPUT2=$(printf '%s' "$CI_PAYLOAD2" \
    | CLAUDE_PROJECT_DIR="$TMP_GIT" CLAUDE_POLICY_DB="$TEST_DB" "$CHECK_IMPL_HOOK" 2>/dev/null || true)

echo "  [debug] check-implementer (bad trailer) output: $CI_OUTPUT2"

CI_CTX2=$(printf '%s' "$CI_OUTPUT2" | jq -r '.additionalContext // empty' 2>/dev/null || true)
if [[ "$CI_CTX2" == *"invalid"* || "$CI_CTX2" == *"bogus_verdict"* ]]; then
    pass "malformed trailer flagged as invalid in check-implementer output"
else
    fail "malformed trailer flagged — ctx: $CI_CTX2"
fi

# Run post-task.sh for the malformed case — should emit impl_contract_invalid
HOOK_PAYLOAD2=$(printf '{"hook_event_name":"SubagentStop","agent_type":"implementer"}')
HOOK_OUTPUT2=$(printf '%s' "$HOOK_PAYLOAD2" \
    | CLAUDE_PROJECT_DIR="$TMP_GIT" CLAUDE_POLICY_DB="$TEST_DB" "$POST_TASK_HOOK" 2>/dev/null || true)

echo "  [debug] post-task output (bad contract): $HOOK_OUTPUT2"

INVALID_EVENTS=$($CC event query --type impl_contract_invalid --limit 5 2>/dev/null || echo '{"items":[],"count":0}')
INVALID_COUNT=$(printf '%s' "$INVALID_EVENTS" | jq '.count // (.items | length) // 0' 2>/dev/null || echo "0")
if [[ "$INVALID_COUNT" -ge 1 ]]; then
    pass "impl_contract_invalid event emitted for malformed contract"
else
    fail "impl_contract_invalid event emitted — found $INVALID_COUNT events"
fi

# Routing still → reviewer even for invalid contract
if printf '%s' "$HOOK_OUTPUT2" | jq '.' >/dev/null 2>&1; then
    PT_CTX2=$(printf '%s' "$HOOK_OUTPUT2" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)
    if [[ "$PT_CTX2" == *"reviewer"* ]]; then
        pass "dispatch still routes to reviewer for invalid contract"
    else
        fail "dispatch routes to reviewer for invalid contract — got: $PT_CTX2"
    fi
else
    fail "post-task hook output is valid JSON for bad-contract case"
fi

# ---------------------------------------------------------------------------
# Test 3: Missing trailers → no record submitted, heuristic fallback
# ---------------------------------------------------------------------------
LEASE_WF_ID3="wf-impl-contract-scenario-003"
ISSUE_OUT3=$($CC lease issue-for-dispatch "implementer" \
    --worktree-path "$TMP_GIT" \
    --workflow-id "$LEASE_WF_ID3" \
    --allowed-ops '["routine_local"]' 2>/dev/null)
LEASE_ID3=$(printf '%s' "$ISSUE_OUT3" | jq -r '.lease.lease_id // empty' 2>/dev/null || true)

if [[ -n "$LEASE_ID3" ]]; then
    pass "third implementer lease issued for missing-trailers test"
else
    fail "third implementer lease issued"
fi

IMPL_RESPONSE_NO_TRAILERS="Implementation done. No structured trailers here."

CI_PAYLOAD3=$(jq -n \
    --arg r "$IMPL_RESPONSE_NO_TRAILERS" \
    --arg at "implementer" \
    '{agent_type: $at, response: $r}')

printf '%s' "$CI_PAYLOAD3" \
    | CLAUDE_PROJECT_DIR="$TMP_GIT" CLAUDE_POLICY_DB="$TEST_DB" "$CHECK_IMPL_HOOK" >/dev/null 2>&1 || true

# No completion record should have been submitted for this lease
COMP_JSON3=$($CC completion latest --lease-id "$LEASE_ID3" 2>/dev/null || echo '{"found":false}')
COMP3_FOUND=$(printf '%s' "$COMP_JSON3" | jq -r 'if .found == true then "yes" else "no" end' 2>/dev/null || echo "no")
if [[ "$COMP3_FOUND" == "no" ]]; then
    pass "no completion record submitted when trailers absent (heuristic fallback)"
else
    COMP_ROLE=$(printf '%s' "$COMP_JSON3" | jq -r '.role // "none"' 2>/dev/null || echo "none")
    fail "no completion record submitted for missing-trailer case — got role=$COMP_ROLE"
fi

# Run post-task.sh — routing still → reviewer (heuristic fallback, no interruption signal)
HOOK_PAYLOAD3=$(printf '{"hook_event_name":"SubagentStop","agent_type":"implementer"}')
HOOK_OUTPUT3=$(printf '%s' "$HOOK_PAYLOAD3" \
    | CLAUDE_PROJECT_DIR="$TMP_GIT" CLAUDE_POLICY_DB="$TEST_DB" "$POST_TASK_HOOK" 2>/dev/null || true)

if printf '%s' "$HOOK_OUTPUT3" | jq '.' >/dev/null 2>&1; then
    PT_CTX3=$(printf '%s' "$HOOK_OUTPUT3" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)
    if [[ "$PT_CTX3" == *"reviewer"* ]]; then
        pass "dispatch routes to reviewer with no trailers (heuristic fallback)"
    else
        fail "dispatch routes to reviewer with no trailers — got: $PT_CTX3"
    fi
else
    fail "post-task hook output is valid JSON for no-trailer case"
fi

# --- Results ---
TOTAL=16
echo ""
echo "Results: $((TOTAL - FAILURES))/$TOTAL passed"
if [[ "$FAILURES" -gt 0 ]]; then
    echo "FAIL: $TEST_NAME — $FAILURES check(s) failed"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
