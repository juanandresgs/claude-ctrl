#!/usr/bin/env bash
# test-lint-gap-dedup.sh: Run lint.sh twice for an unsupported type — the
# .enforcement-gaps file must have exactly one entry with count=2, not two lines.
#
# @decision DEC-LINT-TEST-006
# @title Gap deduplication scenario: repeated gaps increment count, not lines
# @status accepted
# @rationale Verifies the upsert semantics of record_enforcement_gap. Two
#   consecutive encounters of the same gap must produce one line with
#   encounter_count=2, not two separate lines. This prevents the gap file
#   from growing unboundedly and ensures count-based escalation is accurate.
set -euo pipefail

TEST_NAME="test-lint-gap-dedup"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/lint.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude"
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
printf '%s' "$PAYLOAD" | HOME="$TMP_DIR" CLAUDE_PROJECT_DIR="$TMP_DIR" "$HOOK" >/dev/null 2>&1 || true

# Second run (same file, same project)
printf '%s' "$PAYLOAD" | HOME="$TMP_DIR" CLAUDE_PROJECT_DIR="$TMP_DIR" "$HOOK" >/dev/null 2>&1 || true

GAPS_FILE="$TMP_DIR/.claude/.enforcement-gaps"

if [[ ! -f "$GAPS_FILE" ]]; then
    echo "FAIL: $TEST_NAME — .enforcement-gaps not created"
    exit 1
fi

# Must have exactly one line for java
LINE_COUNT=$(grep -c "java" "$GAPS_FILE" 2>/dev/null || echo "0")
if [[ "$LINE_COUNT" -ne 1 ]]; then
    echo "FAIL: $TEST_NAME — expected 1 java line in .enforcement-gaps, got $LINE_COUNT"
    echo "  gaps: $(cat "$GAPS_FILE")"
    exit 1
fi

# The single line must have count=2
COUNT=$(grep "java" "$GAPS_FILE" | cut -d'|' -f5)
if [[ "$COUNT" -ne 2 ]]; then
    echo "FAIL: $TEST_NAME — expected encounter_count=2, got $COUNT"
    echo "  gaps: $(cat "$GAPS_FILE")"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
