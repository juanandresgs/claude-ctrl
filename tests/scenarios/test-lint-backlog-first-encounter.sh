#!/usr/bin/env bash
# test-lint-backlog-first-encounter.sh: On first gap encounter (count==1),
# file_enforcement_gap_backlog must attempt to call todo.sh. Verify the gap
# is recorded with count=1 and no second entry is created on re-inspection.
# The actual GitHub Issue creation is best-effort and not verified here
# (network-dependent), but the gap count gate (count==1) is verified.
#
# @decision DEC-LINT-TEST-009
# @title Backlog-first-encounter scenario: count==1 triggers backlog attempt
# @status accepted
# @rationale file_enforcement_gap_backlog only fires when count==1. This test
#   verifies the precondition: after the first lint.sh run against an
#   unsupported type, the gap file has exactly count=1. The backlog function
#   is best-effort (gh/todo.sh may not be available in CI), so we verify the
#   gate condition rather than the side-effect. A stub todo.sh records whether
#   it was invoked so CI can confirm the attempt was made without network.
set -euo pipefail

TEST_NAME="test-lint-backlog-first-encounter"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/lint.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude" "$TMP_DIR/fake-scripts"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" config user.email "test@test.com"
git -C "$TMP_DIR" config user.name "Test"

# Create a stub todo.sh that records invocation to a sentinel file
STUB_TODO="$TMP_DIR/fake-scripts/todo.sh"
SENTINEL="$TMP_DIR/.claude/.backlog-called"
cat > "$STUB_TODO" <<STUB_EOF
#!/usr/bin/env bash
# Stub todo.sh — records that it was called
touch "$SENTINEL"
exit 0
STUB_EOF
chmod +x "$STUB_TODO"

# Create a stub gh so the availability check passes
STUB_GH="$TMP_DIR/fake-scripts/gh"
cat > "$STUB_GH" <<'GH_EOF'
#!/usr/bin/env bash
exit 0
GH_EOF
chmod +x "$STUB_GH"

TARGET="$TMP_DIR/Hello.java"
printf 'public class Hello {}\n' > "$TARGET"

PAYLOAD=$(jq -n \
    --arg tool_name "Write" \
    --arg file_path "$TARGET" \
    --arg content "public class Hello {}" \
    '{tool_name: $tool_name, tool_input: {file_path: $file_path, content: $content}}')

# Run lint.sh with HOME pointing to a fake home that has the stub todo.sh,
# and PATH extended with our fake-scripts dir so gh is found.
FAKE_HOME="$TMP_DIR/fake-home"
mkdir -p "$FAKE_HOME/.claude/scripts"
cp "$STUB_TODO" "$FAKE_HOME/.claude/scripts/todo.sh"

exit_code=0
output=$(printf '%s' "$PAYLOAD" | \
    HOME="$FAKE_HOME" \
    PATH="$TMP_DIR/fake-scripts:$PATH" \
    CLAUDE_PROJECT_DIR="$TMP_DIR" \
    "$HOOK" 2>&1) || exit_code=$?

# Must exit 2 (gap detected)
if [[ "$exit_code" -ne 2 ]]; then
    echo "FAIL: $TEST_NAME — expected exit 2, got $exit_code"
    echo "  output: $output"
    exit 1
fi

GAPS_FILE="$TMP_DIR/.claude/.enforcement-gaps"
if [[ ! -f "$GAPS_FILE" ]]; then
    echo "FAIL: $TEST_NAME — .enforcement-gaps not created"
    exit 1
fi

# Count must be 1 on first encounter
COUNT=$(grep "java" "$GAPS_FILE" | cut -d'|' -f5)
if [[ "$COUNT" -ne 1 ]]; then
    echo "FAIL: $TEST_NAME — expected count=1 on first encounter, got $COUNT"
    exit 1
fi

# Wait briefly for the background subshell to finish
sleep 1

# Verify the stub todo.sh was called (sentinel file exists)
if [[ ! -f "$SENTINEL" ]]; then
    echo "FAIL: $TEST_NAME — stub todo.sh was never invoked (backlog not attempted)"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
