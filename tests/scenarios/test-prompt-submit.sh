#!/usr/bin/env bash
# test-prompt-submit.sh: feeds synthetic UserPromptSubmit JSON to
# prompt-submit.sh, verifies exit 0.
set -euo pipefail

TEST_NAME="test-prompt-submit"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/prompt-submit.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" commit --allow-empty -m "init" -q

PAYLOAD='{"prompt":"What is the current plan status?"}'

output=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$TMP_DIR" "$HOOK" 2>/dev/null) || {
    echo "FAIL: $TEST_NAME — hook exited nonzero"
    exit 1
}

# Output may be empty (no context triggered) or valid JSON
if [[ -n "$output" ]]; then
    if ! echo "$output" | jq '.' >/dev/null 2>&1; then
        echo "FAIL: $TEST_NAME — non-empty output is not valid JSON"
        exit 1
    fi
fi

echo "PASS: $TEST_NAME"
exit 0
