#!/usr/bin/env bash
# test-lint-shell.sh: Write a valid .sh file — shellcheck must pass (exit 0).
# Requires shellcheck to be installed. Skips gracefully if not found.
#
# @decision DEC-LINT-TEST-001
# @title Shell lint scenario: valid file exits 0 and creates no gap
# @status accepted
# @rationale Verifies the happy path for the new shellcheck profile: a
#   well-formed shell script must exit 0 (no enforcement gap, no lint error).
#   This anchors regression coverage so future changes cannot silently break
#   the shellcheck integration.
set -euo pipefail

TEST_NAME="test-lint-shell"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/lint.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Skip if shellcheck not available
if ! command -v shellcheck &>/dev/null; then
    echo "PASS: $TEST_NAME (skipped — shellcheck not installed)"
    exit 0
fi

mkdir -p "$TMP_DIR/.claude"
TEST_DB="$TMP_DIR/.claude/state.db"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" config user.email "test@test.com"
git -C "$TMP_DIR" config user.name "Test"

# Write a valid shell script (shellcheck-clean)
TARGET="$TMP_DIR/script.sh"
cat > "$TARGET" <<'SHELL_EOF'
#!/usr/bin/env bash
# A simple script.
set -euo pipefail
greet() {
    local name="$1"
    echo "Hello, ${name}"
}
greet "world"
SHELL_EOF

PAYLOAD=$(jq -n \
    --arg tool_name "Write" \
    --arg file_path "$TARGET" \
    --arg content "$(cat "$TARGET")" \
    '{tool_name: $tool_name, tool_input: {file_path: $file_path, content: $content}}')

exit_code=0
output=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TEST_DB" "$HOOK" 2>/dev/null) || exit_code=$?

if [[ "$exit_code" -ne 0 ]]; then
    echo "FAIL: $TEST_NAME — expected exit 0 for valid .sh file, got $exit_code"
    echo "  output: $output"
    exit 1
fi

# Confirm no enforcement-gap row was created for sh
GAP_JSON=$(CLAUDE_POLICY_DB="$TEST_DB" PYTHONPATH="$REPO_ROOT" python3 "$REPO_ROOT/runtime/cli.py" \
    enforcement-gap count --project-root "$TMP_DIR" --gap-type missing_dep --ext sh)
GAP_COUNT=$(printf '%s' "$GAP_JSON" | jq -r '.count // 0')
if [[ "$GAP_COUNT" != "0" ]]; then
    echo "FAIL: $TEST_NAME — unexpected enforcement gap for valid .sh file: $GAP_JSON"
    exit 1
fi

if [[ -e "$TMP_DIR/.claude/.enforcement-gaps" ]]; then
    echo "FAIL: $TEST_NAME — retired .enforcement-gaps flatfile was created"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
