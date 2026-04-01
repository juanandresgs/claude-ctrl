#!/usr/bin/env bash
# test-lint-unsupported-type.sh: Write a .java file in a project with no Java
# linter config — lint.sh must emit an enforcement gap (exit 2, gap recorded).
#
# @decision DEC-LINT-TEST-003
# @title Unsupported-type gap scenario: .java with no linter config fires gap
# @status accepted
# @rationale Verifies that the "none -> exit 0" silent-pass path is gone.
#   A .java file is in SOURCE_EXTENSIONS but has no linter profile in a
#   blank project. lint.sh must exit 2, output must contain "ENFORCEMENT GAP"
#   and "unsupported", and .enforcement-gaps must have an entry for java.
set -euo pipefail

TEST_NAME="test-lint-unsupported-type"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/lint.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" config user.email "test@test.com"
git -C "$TMP_DIR" config user.name "Test"

# Write a .java file — no pom.xml, no build.gradle, no Java linter config
TARGET="$TMP_DIR/Hello.java"
cat > "$TARGET" <<'JAVA_EOF'
public class Hello {
    public static void main(String[] args) {
        System.out.println("Hello");
    }
}
JAVA_EOF

PAYLOAD=$(jq -n \
    --arg tool_name "Write" \
    --arg file_path "$TARGET" \
    --arg content "$(cat "$TARGET")" \
    '{tool_name: $tool_name, tool_input: {file_path: $file_path, content: $content}}')

exit_code=0
# HOME override prevents real todo.sh from filing GitHub issues during tests
output=$(printf '%s' "$PAYLOAD" | HOME="$TMP_DIR" CLAUDE_PROJECT_DIR="$TMP_DIR" "$HOOK" 2>&1) || exit_code=$?

# Must exit 2
if [[ "$exit_code" -ne 2 ]]; then
    echo "FAIL: $TEST_NAME — expected exit 2 for unsupported .java type, got $exit_code"
    echo "  output: $output"
    exit 1
fi

# Output must contain ENFORCEMENT GAP
if ! echo "$output" | grep -q "ENFORCEMENT GAP"; then
    echo "FAIL: $TEST_NAME — output missing 'ENFORCEMENT GAP'"
    echo "  output: $output"
    exit 1
fi

# Output must contain "unsupported"
if ! echo "$output" | grep -q "unsupported"; then
    echo "FAIL: $TEST_NAME — output missing 'unsupported'"
    echo "  output: $output"
    exit 1
fi

# .enforcement-gaps must exist with a java entry
GAPS_FILE="$TMP_DIR/.claude/.enforcement-gaps"
if [[ ! -f "$GAPS_FILE" ]]; then
    echo "FAIL: $TEST_NAME — .enforcement-gaps file not created"
    exit 1
fi

if ! grep -q "unsupported|java" "$GAPS_FILE"; then
    echo "FAIL: $TEST_NAME — .enforcement-gaps missing 'unsupported|java' entry"
    echo "  gaps: $(cat "$GAPS_FILE")"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
