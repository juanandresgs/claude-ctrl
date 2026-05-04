#!/usr/bin/env bash
# test-lint-scratchlane-skip.sh: scratchlane source-looking files are temp
# artifacts, so lint.sh must not record enforcement gaps for them.
set -euo pipefail

TEST_NAME="test-lint-scratchlane-skip"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/lint.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/.claude/state.db"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude"
TARGET="$TMP_DIR/tmp/ad-hoc/Hello.java"
mkdir -p "$(dirname "$TARGET")"
cat > "$TARGET" <<'JAVA_EOF'
public class Hello {}
JAVA_EOF

CLAUDE_POLICY_DB="$TEST_DB" PYTHONPATH="$REPO_ROOT" python3 "$REPO_ROOT/runtime/cli.py" \
    scratchlane grant --project-root "$TMP_DIR" --task-slug ad-hoc >/dev/null

PAYLOAD=$(jq -n \
    --arg tool_name "Write" \
    --arg file_path "$TARGET" \
    --arg content "$(cat "$TARGET")" \
    '{tool_name: $tool_name, tool_input: {file_path: $file_path, content: $content}}')

exit_code=0
output=$(printf '%s' "$PAYLOAD" | HOME="$TMP_DIR" CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_RUNTIME_ROOT="$REPO_ROOT/runtime" CLAUDE_POLICY_DB="$TEST_DB" "$HOOK" 2>&1) || exit_code=$?

if [[ "$exit_code" -ne 0 ]]; then
    echo "FAIL: $TEST_NAME — expected scratchlane lint skip exit 0, got $exit_code"
    echo "  output: $output"
    exit 1
fi

if echo "$output" | grep -q "ENFORCEMENT GAP"; then
    echo "FAIL: $TEST_NAME — scratchlane write produced enforcement gap output"
    echo "  output: $output"
    exit 1
fi

GAP_COUNT=$(CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TEST_DB" python3 "$REPO_ROOT/runtime/cli.py" \
    enforcement-gap count --project-root "$TMP_DIR" --gap-type unsupported --ext java \
    2>/dev/null | jq -r '.count // 0')
if [[ "$GAP_COUNT" -ne 0 ]]; then
    echo "FAIL: $TEST_NAME — scratchlane write recorded enforcement gap in state.db (count=$GAP_COUNT)"
    exit 1
fi

UNAPPROVED_TARGET="$TMP_DIR/tmp/unapproved/Hello.java"
mkdir -p "$(dirname "$UNAPPROVED_TARGET")"
cp "$TARGET" "$UNAPPROVED_TARGET"
UNAPPROVED_PAYLOAD=$(jq -n \
    --arg tool_name "Write" \
    --arg file_path "$UNAPPROVED_TARGET" \
    --arg content "$(cat "$UNAPPROVED_TARGET")" \
    '{tool_name: $tool_name, tool_input: {file_path: $file_path, content: $content}}')

unapproved_output=$(printf '%s' "$UNAPPROVED_PAYLOAD" | HOME="$TMP_DIR" CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_RUNTIME_ROOT="$REPO_ROOT/runtime" CLAUDE_POLICY_DB="$TEST_DB" "$HOOK" 2>&1) || {
    echo "FAIL: $TEST_NAME — unapproved tmp write hook exited nonzero"
    exit 1
}

if ! echo "$unapproved_output" | grep -q "ENFORCEMENT GAP"; then
    echo "FAIL: $TEST_NAME — unapproved tmp source write was silently skipped"
    echo "  output: $unapproved_output"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
