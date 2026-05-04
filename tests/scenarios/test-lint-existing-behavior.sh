#!/usr/bin/env bash
# test-lint-existing-behavior.sh: Write a .py file in a project with
# [tool.ruff] in pyproject.toml — verify per-ext cache is stored in state.db
# and detection resolves to "ruff". If ruff is missing, verify the
# missing_dep gap fires instead of silent pass.
#
# @decision DEC-LINT-TEST-008
# @title Existing-behavior regression: Python/ruff detection uses DB per-ext cache
# @status accepted
# @rationale Verifies two things: (1) the per-extension cache rename did not
#   break existing Python detection (old flatfile cache -> state.db),
#   and (2) missing ruff fires a gap instead of silent exit 0. This is the
#   compound-interaction test: it crosses detection, caching, and gap
#   infrastructure in a single run.
set -euo pipefail

TEST_NAME="test-lint-existing-behavior"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/lint.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude"
TEST_DB="$TMP_DIR/.claude/state.db"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" config user.email "test@test.com"
git -C "$TMP_DIR" config user.name "Test"

# Write pyproject.toml with [tool.ruff] so detect_linter returns "ruff"
cat > "$TMP_DIR/pyproject.toml" <<'TOML_EOF'
[tool.ruff]
line-length = 88
TOML_EOF

TARGET="$TMP_DIR/app.py"
cat > "$TARGET" <<'PY_EOF'
# simple module
def hello():
    return "hello"
PY_EOF

PAYLOAD=$(jq -n \
    --arg tool_name "Write" \
    --arg file_path "$TARGET" \
    --arg content "$(cat "$TARGET")" \
    '{tool_name: $tool_name, tool_input: {file_path: $file_path, content: $content}}')

exit_code=0
output=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TEST_DB" "$HOOK" 2>&1) || exit_code=$?

# The per-ext cache must be stored in state.db, not project-local flatfiles.
CACHE_JSON=$(CLAUDE_POLICY_DB="$TEST_DB" PYTHONPATH="$REPO_ROOT" python3 "$REPO_ROOT/runtime/cli.py" \
    lint-state cache-get --project-root "$TMP_DIR" --ext py --config-mtime 0)
CACHE_FOUND=$(printf '%s' "$CACHE_JSON" | jq -r 'if .found then "yes" else "no" end')
if [[ "$CACHE_FOUND" != "yes" ]]; then
    echo "FAIL: $TEST_NAME — linter cache was not stored in state.db"
    echo "  cache_json: $CACHE_JSON"
    exit 1
fi

CACHED_LINTER=$(printf '%s' "$CACHE_JSON" | jq -r '.linter // empty')
if [[ "$CACHED_LINTER" != "ruff" ]]; then
    echo "FAIL: $TEST_NAME — expected cached linter 'ruff', got '$CACHED_LINTER'"
    exit 1
fi

if compgen -G "$TMP_DIR/.claude/.lint-cache*" >/dev/null || compgen -G "$TMP_DIR/.claude/.lint-breaker*" >/dev/null; then
    echo "FAIL: $TEST_NAME — lint hook created retired flatfile state"
    ls -la "$TMP_DIR/.claude"
    exit 1
fi

# If ruff is installed: expect exit 0 (lint passed) or exit 2 (lint errors — acceptable)
# If ruff is NOT installed: expect exit 0 with ENFORCEMENT GAP / missing_dep (DEC-LINT-002)
if command -v ruff &>/dev/null; then
    # ruff present — should not be a gap (exit 0 or 2 from lint results, not gap)
    if echo "$output" | grep -q "ENFORCEMENT GAP"; then
        echo "FAIL: $TEST_NAME — unexpected ENFORCEMENT GAP when ruff is installed"
        echo "  output: $output"
        exit 1
    fi
    echo "PASS: $TEST_NAME (ruff installed, lint ran, DB cache correct)"
else
    # ruff absent — must be a missing_dep gap (DEC-LINT-002: exit 0 advisory, not exit 2)
    if [[ "$exit_code" -ne 0 ]]; then
        echo "FAIL: $TEST_NAME — expected exit 0 for missing ruff (DEC-LINT-002), got $exit_code"
        exit 1
    fi
    if ! echo "$output" | grep -q "missing_dep"; then
        echo "FAIL: $TEST_NAME — expected missing_dep gap when ruff absent"
        echo "  output: $output"
        exit 1
    fi
    echo "PASS: $TEST_NAME (ruff absent, missing_dep gap fired, DB cache correct)"
fi

exit 0
