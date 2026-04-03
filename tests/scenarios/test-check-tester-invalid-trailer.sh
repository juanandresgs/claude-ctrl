#!/usr/bin/env bash
# test-check-tester-invalid-trailer.sh: proves check-tester.sh fails closed.
#
# Three sub-cases exercised:
#   A: no EVAL_* trailers at all  → needs_changes
#   B: invalid EVAL_VERDICT value → needs_changes
#   C: ready_for_guardian but EVAL_TESTS_PASS=false → needs_changes (degraded)
#   D: ready_for_guardian but EVAL_HEAD_SHA missing → needs_changes (degraded)
#
# Evaluation Contract check 6:
#   "fails closed on invalid/missing trailer"
#
# @decision DEC-EVAL-002
# @title check-tester.sh is the sole writer of evaluation_state verdicts
# @status accepted
# @rationale Fail-closed semantics prevent silent bypass when the tester
#   produces malformed output. Any ambiguity must block Guardian.
set -euo pipefail

TEST_NAME="test-check-tester-invalid-trailer"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/check-tester.sh"
RUNTIME_ROOT="$REPO_ROOT/runtime"

run_case() {
    local sub_case="$1"
    local response_body="$2"
    local expected_status="$3"
    local TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-${sub_case}-$$"
    local TEST_DB="$TMP_DIR/.claude/state.db"
    local BRANCH="feature/invalid-trailer-${sub_case}"
    local WF_ID="feature-invalid-trailer-${sub_case}"

    sub_cleanup() { rm -rf "$TMP_DIR"; }
    trap sub_cleanup EXIT

    mkdir -p "$TMP_DIR/.claude"
    git -C "$TMP_DIR" init -q
    git -C "$TMP_DIR" config user.email "t@t.com"
    git -C "$TMP_DIR" config user.name "T"
    git -C "$TMP_DIR" commit --allow-empty -m "init" -q
    git -C "$TMP_DIR" checkout -b "$BRANCH" -q

    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1

    PAYLOAD=$(jq -n \
        --arg agent_type "tester" \
        --arg response "$response_body" \
        '{agent_type: $agent_type, response: $response}')

    printf '%s' "$PAYLOAD" \
        | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TEST_DB" \
          CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" "$HOOK" 2>/dev/null || true

    EVAL_ROW=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation get "$WF_ID" 2>/dev/null)
    EVAL_STATUS=$(printf '%s' "$EVAL_ROW" | jq -r '.status // "idle"' 2>/dev/null || echo "idle")

    if [[ "$EVAL_STATUS" != "$expected_status" ]]; then
        echo "FAIL: $TEST_NAME [$sub_case] — expected '$expected_status', got '$EVAL_STATUS'"
        echo "  eval_row: $EVAL_ROW"
        exit 1
    fi

    echo "PASS: $TEST_NAME [$sub_case] — correctly wrote '$EVAL_STATUS'"
    rm -rf "$TMP_DIR"
    trap - EXIT
}

# Case A: no trailers at all
run_case "no-trailers" \
    "The tests look fine. Everything seems to work." \
    "needs_changes"

# Case B: invalid EVAL_VERDICT value (not a recognised status)
run_case "invalid-verdict" \
    "EVAL_VERDICT: approved
EVAL_TESTS_PASS: true
EVAL_NEXT_ROLE: guardian
EVAL_HEAD_SHA: abc1234" \
    "needs_changes"

# Case C: ready_for_guardian claimed but EVAL_TESTS_PASS=false → degraded
run_case "tests-not-pass" \
    "EVAL_VERDICT: ready_for_guardian
EVAL_TESTS_PASS: false
EVAL_NEXT_ROLE: guardian
EVAL_HEAD_SHA: abc1234" \
    "needs_changes"

# Case D: ready_for_guardian claimed but no EVAL_HEAD_SHA → degraded
run_case "missing-sha" \
    "EVAL_VERDICT: ready_for_guardian
EVAL_TESTS_PASS: true
EVAL_NEXT_ROLE: guardian" \
    "needs_changes"

echo "PASS: $TEST_NAME (all sub-cases)"
exit 0
