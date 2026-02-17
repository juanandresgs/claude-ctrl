#!/usr/bin/env bash
set -euo pipefail

# Multi-model code review via Multi-MCP server.
# PostToolUse hook — matcher: Write|Edit
#
# Triggers multi-model review on significant file changes (20+ lines).
# Requires Multi-MCP server to be configured and running.
# Falls back silently if Multi-MCP is unavailable.
#
# When active, sends the changed file to mcp__multi__codereview
# which orchestrates GPT-5.2-Codex, Gemini 3 Pro, and Claude
# in parallel. Returns findings as additionalContext.

source "$(dirname "$0")/source-lib.sh"

HOOK_INPUT=$(read_input)
FILE_PATH=$(echo "$HOOK_INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
TOOL_NAME=$(echo "$HOOK_INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Exit silently if no file path
[[ -z "$FILE_PATH" ]] && exit 0
[[ ! -f "$FILE_PATH" ]] && exit 0

# Only review source files (uses shared SOURCE_EXTENSIONS from context-lib.sh)
is_source_file "$FILE_PATH" || exit 0

# Skip non-source directories and test files
is_skippable_path "$FILE_PATH" && exit 0
[[ "$FILE_PATH" =~ \.claude ]] && exit 0

# Skip test files (review production code, not tests)
[[ "$FILE_PATH" =~ (_test\.go|_test\.py) ]] && exit 0

# Skip trivial files (< 20 lines)
LINE_COUNT=$(wc -l < "$FILE_PATH" 2>/dev/null | tr -d ' ')
[[ "$LINE_COUNT" -lt 20 ]] && exit 0

# --- Check if Multi-MCP is available ---
# Multi-MCP exposes tools via Claude's MCP protocol.
# This hook can't call MCP directly — it signals Claude to use the review tool.
# Instead, we inject context suggesting a review.

PROJECT_ROOT=$(detect_project_root)

# Get the diff if this was an edit (more useful than full file for review)
DIFF_CONTEXT=""
if [[ -d "$PROJECT_ROOT/.git" ]] && git -C "$PROJECT_ROOT" diff --quiet "$FILE_PATH" 2>/dev/null; then
    : # File is clean (no diff)
else
    DIFF_CONTEXT=$(git -C "$PROJECT_ROOT" diff "$FILE_PATH" 2>/dev/null | head -10 || echo "")
fi

# Build review request context
REVIEW_CONTEXT="File changed: $FILE_PATH ($LINE_COUNT lines)"
if [[ -n "$DIFF_CONTEXT" ]]; then
    REVIEW_CONTEXT="$REVIEW_CONTEXT\nRecent diff (first 10 lines):\n$DIFF_CONTEXT"
fi

ESCAPED=$(echo -e "$REVIEW_CONTEXT\n\nConsider running mcp__multi__codereview on this file for multi-model analysis if significant architectural changes were made." | jq -Rs .)

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": $ESCAPED
  }
}
EOF

exit 0
