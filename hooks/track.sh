#!/usr/bin/env bash
set -euo pipefail

# Project-aware file change tracking.
# PostToolUse hook — matcher: Write|Edit
#
# Tracks file changes per-session in the PROJECT's .claude directory.
# Uses CLAUDE_PROJECT_DIR when available, falls back to git root detection.
# Session-scoped to avoid collisions with concurrent sessions.

source "$(dirname "$0")/log.sh"

HOOK_INPUT=$(read_input)
FILE_PATH=$(get_field '.tool_input.file_path')

# Exit silently if no file path
[[ -z "$FILE_PATH" ]] && exit 0

# Exit silently if parent directory doesn't exist
[[ ! -e "$(dirname "$FILE_PATH")" ]] && exit 0

# Detect project root (prefers CLAUDE_PROJECT_DIR)
PROJECT_ROOT=$(detect_project_root)

# Session-scoped tracking file
SESSION_ID="${CLAUDE_SESSION_ID:-$$}"
TRACKING_DIR="$PROJECT_ROOT/.claude"
TRACKING_FILE="$TRACKING_DIR/.session-decisions-${SESSION_ID}"

# Create tracking directory if needed
mkdir -p "$TRACKING_DIR"

# Atomic append: write to temp then append (safer than direct >>)
TMPFILE=$(mktemp "${TRACKING_DIR}/.track.XXXXXX")
echo "$FILE_PATH" > "$TMPFILE"
cat "$TMPFILE" >> "$TRACKING_FILE"
rm -f "$TMPFILE"

exit 0
