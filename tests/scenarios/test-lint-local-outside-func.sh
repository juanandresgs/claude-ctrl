#!/usr/bin/env bash
# test-lint-local-outside-func.sh: Write a .sh file with `local` outside a
# function — shellcheck must catch it (exit 2).
#
# @decision DEC-LINT-TEST-002
# @title Shell lint scenario: local-outside-function is caught by shellcheck
# @status accepted
# @rationale Verifies that shellcheck actually runs and catches real errors.
#   SC2039/SC3043 fires on `local` used at script top-level. This proves
#   the feedback loop is wired correctly: lint.sh exits 2, which triggers
#   Claude to auto-fix the file.
set -euo pipefail

TEST_NAME="test-lint-local-outside-func"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/lint.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

if ! command -v shellcheck &>/dev/null; then
    echo "PASS: $TEST_NAME (skipped — shellcheck not installed)"
    exit 0
fi

mkdir -p "$TMP_DIR/.claude"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" config user.email "test@test.com"
git -C "$TMP_DIR" config user.name "Test"

# Write a shell script with `local` used at the top level (outside a function).
# shellcheck SC2039/SC3043 catches this with #!/bin/bash.
TARGET="$TMP_DIR/bad.sh"
cat > "$TARGET" <<'SHELL_EOF'
#!/bin/bash
# bad script — local used outside function
local x=1
echo "$x"
SHELL_EOF

PAYLOAD=$(jq -n \
    --arg tool_name "Write" \
    --arg file_path "$TARGET" \
    --arg content "$(cat "$TARGET")" \
    '{tool_name: $tool_name, tool_input: {file_path: $file_path, content: $content}}')

exit_code=0
output=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$TMP_DIR" "$HOOK" 2>&1) || exit_code=$?

if [[ "$exit_code" -ne 2 ]]; then
    echo "FAIL: $TEST_NAME — expected exit 2 from shellcheck, got $exit_code"
    echo "  output: $output"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
