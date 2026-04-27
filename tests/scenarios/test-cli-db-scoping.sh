#!/usr/bin/env bash
# test-cli-db-scoping.sh: proves direct python3 runtime/cli.py invocations
# from inside a project CWD resolve to the project .claude/state.db without
# manually setting CLAUDE_POLICY_DB.
#
# @decision DEC-GUARD-016
# @title Direct CLI resolves to project DB via git-root detection
# @status accepted
# @rationale DEC-SELF-003 step 3: config.py detects git root with .claude/
#   dir and scopes to project DB. This covers script and manual CLI paths
#   where CLAUDE_PROJECT_DIR is not pre-exported by a hook.
set -euo pipefail

TEST_NAME="test-cli-db-scoping"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$REPO_ROOT/runtime/cli.py"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
PROJECT_DB="$TMP_DIR/.claude/state.db"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" config user.email "t@t.com"
git -C "$TMP_DIR" config user.name "T"
git -C "$TMP_DIR" commit --allow-empty -m "init" -q

# Bootstrap schema via explicit CLAUDE_POLICY_DB (step 1 — correct for setup)
CLAUDE_POLICY_DB="$PROJECT_DB" python3 "$CLI" schema ensure >/dev/null 2>&1

# Write evaluation state via direct CLI from project CWD WITHOUT CLAUDE_POLICY_DB or
# CLAUDE_PROJECT_DIR — must use step 3 (git-root detection) to find project DB.
(
    cd "$TMP_DIR"
    unset CLAUDE_POLICY_DB 2>/dev/null || true
    unset CLAUDE_PROJECT_DIR 2>/dev/null || true
    python3 "$CLI" evaluation set "test-wf" "ready_for_guardian" >/dev/null 2>&1
)

# Read it back via explicit CLAUDE_POLICY_DB to confirm it landed in project DB
result=$(CLAUDE_POLICY_DB="$PROJECT_DB" python3 "$CLI" evaluation get "test-wf" 2>&1)
status=$(printf '%s' "$result" | jq -r '.status // empty' 2>/dev/null || echo "")

if [[ "$status" != "ready_for_guardian" ]]; then
    echo "FAIL: $TEST_NAME — direct CLI evaluation write did not land in project DB"
    echo "  expected status=ready_for_guardian, got: $result"
    exit 1
fi

# Also verify it did NOT land in home DB.
# Guard: only run this check if the test repo is not ~/.claude itself.
home_db_path="$HOME/.claude/state.db"
if [[ "$PROJECT_DB" != "$home_db_path" ]]; then
    home_result=$(python3 "$CLI" evaluation get "test-wf" 2>&1) || true
    home_found=$(printf '%s' "$home_result" | jq -r '.found // false' 2>/dev/null || echo "false")
    if [[ "$home_found" == "true" ]]; then
        home_status=$(printf '%s' "$home_result" | jq -r '.status // empty' 2>/dev/null || echo "")
        if [[ "$home_status" == "ready_for_guardian" ]]; then
            echo "FAIL: $TEST_NAME — evaluation state also landed in home DB (split authority)"
            exit 1
        fi
    fi
fi

echo "PASS: $TEST_NAME"
exit 0
