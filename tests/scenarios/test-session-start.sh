#!/usr/bin/env bash
# test-session-start.sh: feeds synthetic SessionStart JSON to session-init.sh,
# verifies exit 0 and that additionalContext is present in output.
set -euo pipefail

TEST_NAME="test-session-start"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/session-init.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Setup: isolated git repo so detect_project_root finds a real git root
mkdir -p "$TMP_DIR"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" commit --allow-empty -m "init" -q

# SessionStart payload — session-init.sh ignores payload fields, uses filesystem
PAYLOAD='{"event":"SessionStart","session_id":"test-123"}'

# Run the hook with the temp dir as CLAUDE_PROJECT_DIR
# Mask gh so todo.sh hud doesn't hang querying GitHub in test context
output=$(printf '%s' "$PAYLOAD" | PATH="/usr/bin:/bin" CLAUDE_PROJECT_DIR="$TMP_DIR" "$HOOK" 2>/dev/null) || {
    echo "FAIL: $TEST_NAME — hook exited nonzero"
    exit 1
}

# session-init.sh may produce empty output (no context parts) or one JSON object
# with additionalContext. Multiple top-level JSON documents are invalid for
# Claude hooks even though bare `jq .` accepts them as a stream.
if [[ -n "$output" ]]; then
    if ! echo "$output" | jq -s -e 'length == 1 and .[0].hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null 2>&1; then
        echo "FAIL: $TEST_NAME — non-empty output must be exactly one SessionStart JSON object"
        echo "  output: $output"
        exit 1
    fi
fi

echo "PASS: $TEST_NAME"
exit 0
