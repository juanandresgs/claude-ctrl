#!/usr/bin/env bash
# test-lint-missing-dep.sh: Write a .sh file with shellcheck excluded from
# PATH — lint.sh must emit a missing_dep enforcement gap (exit 2).
#
# @decision DEC-LINT-TEST-004
# @title Missing-dep gap scenario: shellcheck not on PATH fires gap
# @status accepted
# @rationale Verifies the dependency-check path. detect_linter returns
#   "shellcheck" for .sh files, but check_linter_available fails when
#   shellcheck is not on PATH. lint.sh must exit 2 with "ENFORCEMENT GAP"
#   and "missing_dep" in the output, and record the gap in .enforcement-gaps.
set -euo pipefail

TEST_NAME="test-lint-missing-dep"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/lint.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" config user.email "test@test.com"
git -C "$TMP_DIR" config user.name "Test"

TARGET="$TMP_DIR/script.sh"
cat > "$TARGET" <<'SHELL_EOF'
#!/usr/bin/env bash
# a shell script
echo "hello"
SHELL_EOF

PAYLOAD=$(jq -n \
    --arg tool_name "Write" \
    --arg file_path "$TARGET" \
    --arg content "$(cat "$TARGET")" \
    '{tool_name: $tool_name, tool_input: {file_path: $file_path, content: $content}}')

# Run with PATH restricted so shellcheck is not findable
# HOME override prevents real todo.sh from filing GitHub issues during tests
exit_code=0
output=$(printf '%s' "$PAYLOAD" | \
    HOME="$TMP_DIR" PATH=/usr/bin:/bin CLAUDE_PROJECT_DIR="$TMP_DIR" "$HOOK" 2>&1) || exit_code=$?

# Must exit 2
if [[ "$exit_code" -ne 2 ]]; then
    echo "FAIL: $TEST_NAME — expected exit 2 for missing shellcheck dep, got $exit_code"
    echo "  output: $output"
    exit 1
fi

# Output must contain ENFORCEMENT GAP
if ! echo "$output" | grep -q "ENFORCEMENT GAP"; then
    echo "FAIL: $TEST_NAME — output missing 'ENFORCEMENT GAP'"
    echo "  output: $output"
    exit 1
fi

# Output must contain missing_dep
if ! echo "$output" | grep -q "missing_dep"; then
    echo "FAIL: $TEST_NAME — output missing 'missing_dep'"
    echo "  output: $output"
    exit 1
fi

# Output must name the tool
if ! echo "$output" | grep -q "shellcheck"; then
    echo "FAIL: $TEST_NAME — output missing 'shellcheck' tool name"
    echo "  output: $output"
    exit 1
fi

# .enforcement-gaps must exist with a missing_dep|sh entry
GAPS_FILE="$TMP_DIR/.claude/.enforcement-gaps"
if [[ ! -f "$GAPS_FILE" ]]; then
    echo "FAIL: $TEST_NAME — .enforcement-gaps file not created"
    exit 1
fi

if ! grep -q "missing_dep|sh" "$GAPS_FILE"; then
    echo "FAIL: $TEST_NAME — .enforcement-gaps missing 'missing_dep|sh' entry"
    echo "  gaps: $(cat "$GAPS_FILE")"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
