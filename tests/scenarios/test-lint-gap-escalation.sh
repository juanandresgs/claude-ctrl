#!/usr/bin/env bash
# test-lint-gap-escalation.sh: Pre-seed .enforcement-gaps with count > 1 for
# a .java file, then pipe a Write payload to pre-write.sh — expect deny.
#
# @decision DEC-LINT-TEST-005
# @title Gap escalation scenario: repeated gap triggers PreToolUse deny
# @status accepted
# @rationale Verifies the repeated-write deny path. When encounter_count > 1
#   exists in .enforcement-gaps for the target file's extension,
#   check_enforcement_gap must return permissionDecision=deny. This is the
#   deterministic block that prevents undetected enforcement bypass across
#   multiple turns.
set -euo pipefail

TEST_NAME="test-lint-gap-escalation"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/pre-write.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude" "$TMP_DIR/src"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" config user.email "test@test.com"
git -C "$TMP_DIR" config user.name "Test"
git -C "$TMP_DIR" checkout -b feature/test -q 2>/dev/null || true
git -C "$TMP_DIR" commit --allow-empty -m "init" -q

# Set implementer role so write-guard passes
CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" \
    python3 "$REPO_ROOT/runtime/cli.py" schema ensure >/dev/null 2>&1 || true
CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" \
    python3 "$REPO_ROOT/runtime/cli.py" marker set "agent-test" "implementer" >/dev/null 2>&1 || true

# Add MASTER_PLAN.md so plan-check passes
echo "# Plan" > "$TMP_DIR/MASTER_PLAN.md"
git -C "$TMP_DIR" add MASTER_PLAN.md
git -C "$TMP_DIR" commit -m "add plan" -q

# Pre-seed .enforcement-gaps with encounter_count=2 for java (confirmed persistent gap)
GAPS_FILE="$TMP_DIR/.claude/.enforcement-gaps"
printf 'unsupported|java|none|1711929600|2\n' > "$GAPS_FILE"

TARGET_FILE="$TMP_DIR/src/Hello.java"

PAYLOAD=$(jq -n \
    --arg tool_name "Write" \
    --arg file_path "$TARGET_FILE" \
    --arg content "public class Hello {}" \
    '{tool_name: $tool_name, tool_input: {file_path: $file_path, content: $content}}')

exit_code=0
output=$(printf '%s' "$PAYLOAD" | \
    CLAUDE_PROJECT_DIR="$TMP_DIR" \
    CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" \
    "$HOOK" 2>/dev/null) || exit_code=$?

if [[ -z "$output" ]]; then
    echo "FAIL: $TEST_NAME — pre-write.sh produced no output (expected deny)"
    exit 1
fi

decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" != "deny" ]]; then
    echo "FAIL: $TEST_NAME — expected permissionDecision=deny, got: '$decision'"
    echo "  output: $output"
    exit 1
fi

reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if ! echo "$reason" | grep -q "enforcement gap"; then
    echo "FAIL: $TEST_NAME — deny reason missing 'enforcement gap': $reason"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
