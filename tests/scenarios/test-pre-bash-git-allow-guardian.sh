#!/usr/bin/env bash
# test-pre-bash-git-allow-guardian.sh: guardian+proof+tests issues git-commit
# via pre-bash.sh — expects allow (no deny output).
#
# @decision DEC-TKT008-002
# @title Compound allow path: all three bash-policy gates satisfied
# @status accepted
# @rationale Validates pre-bash.sh chains bp_git_who+bp_test_gate+bp_proof_gate
# and exits 0 when all three pass — the real production allow sequence.
set -euo pipefail
TEST_NAME="test-pre-bash-git-allow-guardian"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/pre-bash.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
mkdir -p "$TMP_DIR/.claude"
(cd "$TMP_DIR" && git init -q && git commit --allow-empty -m init -q && git checkout -b feature/ready -q)
echo "ACTIVE|guardian|$(date +%s)" > "$TMP_DIR/.claude/.subagent-tracker"
echo "pass|0|$(date +%s)" > "$TMP_DIR/.claude/.test-status"
echo "verified|$(date +%s)" > "$TMP_DIR/.claude/.proof-status-feature-ready"
CMD="git -C \"$TMP_DIR\" commit --allow-empty -m done"
PAYLOAD=$(jq -n \
    --arg tool_name "Bash" \
    --arg command "$CMD" \
    --arg cwd "$TMP_DIR" \
    '{tool_name: $tool_name, tool_input: {command: $command}, cwd: $cwd}')
output=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$TMP_DIR" "$HOOK" 2>/dev/null) || {
    echo "FAIL: $TEST_NAME — hook exited nonzero"; exit 1
}
if [[ -n "$output" ]]; then
    decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    if [[ "$decision" == "deny" ]]; then
        reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
        echo "FAIL: $TEST_NAME — unexpected deny: $reason"; exit 1
    fi
fi
echo "PASS: $TEST_NAME"
exit 0
