#!/usr/bin/env bash
# test-pre-bash-git-who-deny.sh: non-guardian issues git-commit via pre-bash.sh
# — WHO guard must deny.
set -euo pipefail
TEST_NAME="test-pre-bash-git-who-deny"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/pre-bash.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
mkdir -p "$TMP_DIR/.claude"
(cd "$TMP_DIR" && git init -q && git commit --allow-empty -m init -q)
PAYLOAD=$(jq -n \
    --arg tool_name "Bash" \
    --arg command "git commit -m wip" \
    --arg cwd "$TMP_DIR" \
    '{tool_name: $tool_name, tool_input: {command: $command}, cwd: $cwd}')
output=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$TMP_DIR" "$HOOK" 2>/dev/null) || {
    echo "FAIL: $TEST_NAME — hook exited nonzero"; exit 1
}
[[ -z "$output" ]] && { echo "FAIL: $TEST_NAME — no output (expected deny)"; exit 1; }
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" != "deny" ]]; then
    echo "FAIL: $TEST_NAME — expected deny, got: '$decision'"; echo "  output: $output"; exit 1
fi
echo "PASS: $TEST_NAME"
exit 0
