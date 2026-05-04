#!/usr/bin/env bash
# test-lint-missing-dep.sh: Write a .sh file with the linter binary removed
# from PATH — lint.sh must emit an advisory missing_dep gap (exit 0).
#
# @decision DEC-LINT-TEST-004
# @title Missing-dep gap scenario: linter not on PATH fires advisory gap
# @status accepted
# @rationale DEC-LINT-002: enforcement-gap deny moved to the policy engine
#   (write_enforcement_gap.py). detect_linter returns "shellcheck" for .sh
#   files, but check_linter_available fails when the binary is absent from
#   PATH. lint.sh records the gap, emits advisory context, and exits 0.
#   Hard DENY for persistent gaps lives in the policy engine, not lint.sh.
set -euo pipefail

TEST_NAME="test-lint-missing-dep"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/lint.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

# shellcheck disable=SC2329  # cleanup is invoked via trap EXIT
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude"
TEST_DB="$TMP_DIR/.claude/state.db"
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
    HOME="$TMP_DIR" PATH=/usr/bin:/bin CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_RUNTIME_ROOT="$REPO_ROOT/runtime" CLAUDE_POLICY_DB="$TEST_DB" "$HOOK" 2>&1) || exit_code=$?

# Must exit 0 — DEC-LINT-002: gap detection is advisory; hard DENY is in the
# policy engine (write_enforcement_gap.py), not in lint.sh.
if [[ "$exit_code" -ne 0 ]]; then
    echo "FAIL: $TEST_NAME — expected exit 0 for missing dep (advisory gap), got $exit_code"
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

# state.db must have the missing_dep sh gap entry
GAP_COUNT=$(CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TEST_DB" python3 "$REPO_ROOT/runtime/cli.py" \
    enforcement-gap count --project-root "$TMP_DIR" --gap-type missing_dep --ext sh \
    2>/dev/null | jq -r '.count // 0')
if [[ "$GAP_COUNT" -lt 1 ]]; then
    echo "FAIL: $TEST_NAME — state.db missing missing_dep sh gap (count=$GAP_COUNT)"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
