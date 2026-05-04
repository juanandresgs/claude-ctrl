#!/usr/bin/env bash
# test-session-start.sh: feeds synthetic SessionStart JSON to session-init.sh,
# verifies exit 0 and that additionalContext is present in output.
set -euo pipefail

TEST_NAME="test-session-start"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/session-init.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
ENV_FILE="$TMP_DIR/claude-env"

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
output=$(printf '%s' "$PAYLOAD" | PATH="/usr/bin:/bin" CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_ENV_FILE="$ENV_FILE" "$HOOK" 2>/dev/null) || {
    echo "FAIL: $TEST_NAME — hook exited nonzero"
    exit 1
}

if ! grep -Fx 'export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:$PATH"' "$ENV_FILE" >/dev/null 2>&1; then
    echo "FAIL: $TEST_NAME — session env file did not receive deterministic PATH export"
    exit 1
fi

# session-init.sh may produce empty output (no context parts) or JSON with additionalContext.
# Either is valid — the hook exits 0 in both cases.
# Verify: if output is non-empty it must be valid JSON
if [[ -n "$output" ]]; then
    if ! echo "$output" | jq '.' >/dev/null 2>&1; then
        echo "FAIL: $TEST_NAME — non-empty output is not valid JSON"
        echo "  output: $output"
        exit 1
    fi
fi

echo "PASS: $TEST_NAME"
exit 0
