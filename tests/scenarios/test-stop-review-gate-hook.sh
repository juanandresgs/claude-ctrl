#!/usr/bin/env bash
# test-stop-review-gate-hook.sh — regular Stop review visibility and retired
# SubagentStop broad review behavior.
#
# Production path exercised:
#   Stop payload -> stop-review-gate-hook.mjs -> codex_stop_review event
#   SubagentStop payload -> stop-review-gate-hook.mjs -> immediate no-op
#
# Codex itself is overridden with CLAUDEX_STOP_REVIEW_TEST_RESPONSE so this
# stays deterministic and does not require a live Codex login.

set -euo pipefail

TEST_NAME="test-stop-review-gate-hook"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/sidecars/codex-review/scripts/stop-review-gate-hook.mjs"
RUNTIME="$REPO_ROOT/runtime/cli.py"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/state.db"
WORKTREE="$TMP_DIR/repo"
PLUGIN_DATA="$TMP_DIR/plugin-data"
FAILURES=0

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

mkdir -p "$WORKTREE" "$PLUGIN_DATA"
git -C "$WORKTREE" init >/dev/null 2>&1
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME" schema ensure >/dev/null 2>&1

run_hook() {
    local label="$1"
    local payload="$2"
    local review="$3"
    set +e
    printf '%s' "$payload" \
        | CLAUDE_PROJECT_DIR="$WORKTREE" \
          CLAUDE_POLICY_DB="$TEST_DB" \
          CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" \
          CLAUDEX_STOP_REVIEW_TEST_RESPONSE="$review" \
          node "$HOOK" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"
    local code=$?
    set -e
    printf '%s\n' "$code" >"$TMP_DIR/$label.code"
}

latest_review_detail() {
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME" event query --type codex_stop_review --limit 1 \
        | jq -r '.items[0].detail // ""'
}

review_count() {
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME" event query --type codex_stop_review --limit 20 \
        | jq -r '.count // (.items | length)'
}

echo "=== $TEST_NAME ==="

STOP_PAYLOAD='{"hook_event_name":"Stop","workflow_id":"wf-stop-gate","last_assistant_message":"Implemented the requested cleanup."}'
run_hook "pass" "$STOP_PAYLOAD" $'Verified the requested cleanup.\nVERDICT: PASS — complete'

if [[ "$(cat "$TMP_DIR/pass.code")" == "0" ]]; then
    pass "PASS review exits 0"
else
    fail "PASS review exits 0"
fi

PASS_DETAIL="$(latest_review_detail)"
if [[ "$PASS_DETAIL" == *"VERDICT: ALLOW"* && "$PASS_DETAIL" == *"workflow=wf-stop-gate"* ]]; then
    pass "PASS review emits ALLOW codex_stop_review event"
else
    fail "PASS review emits ALLOW event (got: $PASS_DETAIL)"
fi

run_hook "continue" "$STOP_PAYLOAD" $'Missing the regression test.\nVERDICT: CONTINUE — add coverage'
CONTINUE_OUT="$(cat "$TMP_DIR/continue.out")"
if printf '%s' "$CONTINUE_OUT" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    pass "CONTINUE review blocks ordinary Stop"
else
    fail "CONTINUE review blocks ordinary Stop (got: $CONTINUE_OUT)"
fi

BLOCK_DETAIL="$(latest_review_detail)"
if [[ "$BLOCK_DETAIL" == *"VERDICT: BLOCK"* && "$BLOCK_DETAIL" == *"workflow=wf-stop-gate"* ]]; then
    pass "CONTINUE review emits BLOCK codex_stop_review event"
else
    fail "CONTINUE review emits BLOCK event (got: $BLOCK_DETAIL)"
fi

COUNT_BEFORE="$(review_count)"
SUBAGENT_PAYLOAD='{"hook_event_name":"SubagentStop","agent_type":"implementer","workflow_id":"wf-stop-gate"}'
run_hook "subagent" "$SUBAGENT_PAYLOAD" $'Should not run.\nVERDICT: CONTINUE — should not matter'
COUNT_AFTER="$(review_count)"
SUBAGENT_OUT="$(cat "$TMP_DIR/subagent.out")"
SUBAGENT_ERR="$(cat "$TMP_DIR/subagent.err")"
if [[ "$SUBAGENT_OUT" == "" && "$COUNT_BEFORE" == "$COUNT_AFTER" && "$SUBAGENT_ERR" == *"SubagentStop broad review retired"* ]]; then
    pass "SubagentStop broad review is a no-op"
else
    fail "SubagentStop broad review is a no-op (before=$COUNT_BEFORE after=$COUNT_AFTER out=$SUBAGENT_OUT err=$SUBAGENT_ERR)"
fi

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
    echo "PASS: $TEST_NAME"
    exit 0
fi

echo "FAIL: $TEST_NAME — $FAILURES check(s) failed"
exit 1
