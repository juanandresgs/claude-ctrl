#!/usr/bin/env bash
# test-lint-gap-surfacing.sh: Pre-seed .enforcement-gaps, pipe a SessionStart
# payload to session-init.sh — output must contain "ENFORCEMENT DEGRADED".
#
# @decision DEC-LINT-TEST-007
# @title Gap surfacing scenario: session-init injects gap warnings into context
# @status accepted
# @rationale Verifies that persisted gaps survive session boundaries and are
#   surfaced to the model at session start. session-init.sh reads
#   .enforcement-gaps and adds "ENFORCEMENT DEGRADED" entries to
#   CONTEXT_PARTS, so the model knows enforcement is degraded before it
#   writes anything in the new session.
set -euo pipefail

TEST_NAME="test-lint-gap-surfacing"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/session-init.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" config user.email "test@test.com"
git -C "$TMP_DIR" config user.name "Test"
git -C "$TMP_DIR" commit --allow-empty -m "init" -q

# Pre-seed two enforcement gaps — one unsupported, one missing_dep
GAPS_FILE="$TMP_DIR/.claude/.enforcement-gaps"
printf 'unsupported|java|none|1711929600|3\n' > "$GAPS_FILE"
printf 'missing_dep|rs|clippy|1711929600|1\n' >> "$GAPS_FILE"

# SessionStart payload (no tool_input, just event type)
PAYLOAD='{"hookEventName":"SessionStart"}'

output=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$TMP_DIR" "$HOOK" 2>/dev/null) || true

if [[ -z "$output" ]]; then
    echo "FAIL: $TEST_NAME — session-init.sh produced no output"
    exit 1
fi

# Must contain ENFORCEMENT DEGRADED
if ! echo "$output" | grep -q "ENFORCEMENT DEGRADED"; then
    echo "FAIL: $TEST_NAME — output missing 'ENFORCEMENT DEGRADED'"
    echo "  output: $output"
    exit 1
fi

# Must mention java gap
if ! echo "$output" | grep -q "java"; then
    echo "FAIL: $TEST_NAME — output missing java gap"
    echo "  output: $output"
    exit 1
fi

# Must mention rs/clippy gap
if ! echo "$output" | grep -q "clippy"; then
    echo "FAIL: $TEST_NAME — output missing clippy gap"
    echo "  output: $output"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
