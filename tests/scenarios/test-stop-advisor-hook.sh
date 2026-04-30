#!/usr/bin/env bash
# test-stop-advisor-hook.sh — deterministic regular Stop obvious-action triage.

set -euo pipefail

TEST_NAME="test-stop-advisor-hook"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/stop-advisor.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
FAILURES=0

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

mkdir -p "$TMP_DIR"

run_hook() {
    local label="$1"
    local payload="$2"
    set +e
    printf '%s' "$payload" | "$HOOK" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"
    local code=$?
    set -e
    printf '%s\n' "$code" >"$TMP_DIR/$label.code"
}

assert_block_contains() {
    local label="$1"
    local expected="$2"
    local out
    out="$(cat "$TMP_DIR/$label.out")"
    if [[ "$(cat "$TMP_DIR/$label.code")" == "0" ]] \
        && printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1 \
        && [[ "$out" == *"$expected"* ]]; then
        pass "$label blocks with $expected"
    else
        fail "$label blocks with $expected (out=$out err=$(cat "$TMP_DIR/$label.err"))"
    fi
}

assert_passes_empty() {
    local label="$1"
    local out
    out="$(cat "$TMP_DIR/$label.out")"
    if [[ "$(cat "$TMP_DIR/$label.code")" == "0" && -z "$out" ]]; then
        pass "$label passes without output"
    else
        fail "$label passes without output (out=$out err=$(cat "$TMP_DIR/$label.err"))"
    fi
}

echo "=== $TEST_NAME ==="

run_hook "backlog" '{"hook_event_name":"Stop","last_assistant_message":"Worth filing in /backlog. Want me to file those four /backlog items now, or stop here?"}'
assert_block_contains "backlog" "obvious bookkeeping"

run_hook "guardian-git" '{"hook_event_name":"Stop","last_assistant_message":"Tests are green. Want me to commit and push this?"}'
assert_block_contains "guardian-git" "Route the operation to Guardian"

run_hook "dispatch" '{"hook_event_name":"Stop","last_assistant_message":"Reviewer is ready. Should I dispatch guardian next?"}'
assert_block_contains "dispatch" "routine canonical dispatch"

run_hook "mixed-summary-no-bookkeeping-ask" '{"hook_event_name":"Stop","last_assistant_message":"Verdict: ready. Should I tighten the token-consume atomicity now? The two minor items above are worth filing as follow-ups but do not block landing."}'
assert_passes_empty "mixed-summary-no-bookkeeping-ask"

run_hook "user-boundary" '{"hook_event_name":"Stop","last_assistant_message":"This requires a force push history rewrite. Do you want to approve it?"}'
assert_passes_empty "user-boundary"

run_hook "normal-summary" '{"hook_event_name":"Stop","last_assistant_message":"Implemented the deterministic Stop advisor and updated tests."}'
assert_passes_empty "normal-summary"

run_hook "recursive-stop" '{"hook_event_name":"Stop","stop_hook_active":true,"last_assistant_message":"Want me to file the backlog?"}'
assert_passes_empty "recursive-stop"

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
    echo "PASS: $TEST_NAME"
    exit 0
fi

echo "FAIL: $TEST_NAME — $FAILURES check(s) failed"
exit 1
