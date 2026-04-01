#!/usr/bin/env bash
# test-check-tester-valid-trailer.sh: feeds a synthetic SubagentStop:tester
# response containing valid EVAL_* trailers to check-tester.sh and verifies
# that evaluation_state is written as "ready_for_guardian".
#
# Production sequence exercised:
#   1. Tester agent stops with EVAL_VERDICT=ready_for_guardian trailer
#   2. check-tester.sh parses the trailer and writes evaluation_state
#   3. evaluation_state row reflects the verdict and head_sha
#
# @decision DEC-EVAL-002
# @title check-tester.sh is the sole writer of evaluation_state verdicts
# @status accepted
# @rationale Valid trailer must produce exactly the specified evaluation_state
#   row. This test proves the write path works end-to-end for the allow case.
set -euo pipefail

TEST_NAME="test-check-tester-valid-trailer"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/check-tester.sh"
RUNTIME_ROOT="$REPO_ROOT/runtime"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/.claude/state.db"
BRANCH="feature/check-tester-valid"
WF_ID="feature-check-tester-valid"
TEST_SHA="abc1234def5678"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" config user.email "t@t.com"
git -C "$TMP_DIR" config user.name "T"
git -C "$TMP_DIR" commit --allow-empty -m "init" -q
git -C "$TMP_DIR" checkout -b "$BRANCH" -q

# Provision schema
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1

# Build a tester response with valid EVAL_* trailers
RESPONSE_BODY="Evidence section: tests pass, feature verified manually.

EVAL_VERDICT: ready_for_guardian
EVAL_TESTS_PASS: true
EVAL_NEXT_ROLE: guardian
EVAL_HEAD_SHA: ${TEST_SHA}"

PAYLOAD=$(jq -n \
    --arg agent_type "tester" \
    --arg response "$RESPONSE_BODY" \
    '{agent_type: $agent_type, response: $response}')

output=$(printf '%s' "$PAYLOAD" \
    | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TEST_DB" \
      CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" "$HOOK" 2>/dev/null) || {
    echo "FAIL: $TEST_NAME — hook exited nonzero"
    exit 1
}

# Hook must exit 0 (advisory only)
if ! printf '%s' "$output" | jq '.' >/dev/null 2>&1; then
    # Empty output is also acceptable (advisory hook)
    if [[ -n "$output" ]]; then
        echo "FAIL: $TEST_NAME — non-empty output is not valid JSON"
        exit 1
    fi
fi

# Verify evaluation_state was written correctly
EVAL_ROW=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    evaluation get "$WF_ID" 2>/dev/null)

EVAL_STATUS=$(printf '%s' "$EVAL_ROW" | jq -r '.status // "idle"' 2>/dev/null || echo "idle")
EVAL_SHA=$(printf '%s' "$EVAL_ROW" | jq -r '.head_sha // empty' 2>/dev/null || echo "")

if [[ "$EVAL_STATUS" != "ready_for_guardian" ]]; then
    echo "FAIL: $TEST_NAME — expected evaluation_state=ready_for_guardian, got '$EVAL_STATUS'"
    echo "  eval_row: $EVAL_ROW"
    exit 1
fi

if [[ "$EVAL_SHA" != "$TEST_SHA" ]]; then
    echo "FAIL: $TEST_NAME — expected head_sha='$TEST_SHA', got '$EVAL_SHA'"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
