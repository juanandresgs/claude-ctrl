#!/usr/bin/env bash
# test-lint-gap-dedup.sh: Run lint.sh twice for an unsupported type — the
# state.db enforcement_gaps must have exactly one entry with count=2.
#
# @decision DEC-LINT-TEST-006
# @title Gap deduplication scenario: repeated gaps increment count, not lines
# @status accepted
# @rationale Verifies the upsert semantics of record_enforcement_gap. Two
#   consecutive encounters of the same gap must produce one DB row with
#   encounter_count=2, not duplicate rows. This prevents unbounded growth and
#   ensures count-based escalation is accurate.
set -euo pipefail

TEST_NAME="test-lint-gap-dedup"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/lint.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude"
TEST_DB="$TMP_DIR/.claude/state.db"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" config user.email "test@test.com"
git -C "$TMP_DIR" config user.name "Test"

TARGET="$TMP_DIR/Hello.java"
cat > "$TARGET" <<'JAVA_EOF'
public class Hello {}
JAVA_EOF

PAYLOAD=$(jq -n \
    --arg tool_name "Write" \
    --arg file_path "$TARGET" \
    --arg content "$(cat "$TARGET")" \
    '{tool_name: $tool_name, tool_input: {file_path: $file_path, content: $content}}')

# HOME override prevents real todo.sh from filing GitHub issues during tests
# First run
printf '%s' "$PAYLOAD" | HOME="$TMP_DIR" CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_RUNTIME_ROOT="$REPO_ROOT/runtime" CLAUDE_POLICY_DB="$TEST_DB" "$HOOK" >/dev/null 2>&1 || true

# Second run (same file, same project)
printf '%s' "$PAYLOAD" | HOME="$TMP_DIR" CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_RUNTIME_ROOT="$REPO_ROOT/runtime" CLAUDE_POLICY_DB="$TEST_DB" "$HOOK" >/dev/null 2>&1 || true

# Must have exactly one open java row
GAPS_JSON=$(CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TEST_DB" python3 "$REPO_ROOT/runtime/cli.py" \
    enforcement-gap list --project-root "$TMP_DIR" 2>/dev/null)
LINE_COUNT=$(printf '%s' "$GAPS_JSON" | jq -r '[.items[]? | select(.ext == "java")] | length')
if [[ "$LINE_COUNT" -ne 1 ]]; then
    echo "FAIL: $TEST_NAME — expected 1 java row in state.db, got $LINE_COUNT"
    echo "  gaps: $GAPS_JSON"
    exit 1
fi

# The single row must have count=2
COUNT=$(printf '%s' "$GAPS_JSON" | jq -r '.items[]? | select(.ext == "java") | .encounter_count')
if [[ "$COUNT" -ne 2 ]]; then
    echo "FAIL: $TEST_NAME — expected encounter_count=2, got $COUNT"
    echo "  gaps: $GAPS_JSON"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
