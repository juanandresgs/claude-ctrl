#!/usr/bin/env bash
set -euo pipefail

# @decision DEC-HOOKS-002
# @title Project-aware file change tracking
# @status accepted
# @rationale Tracks file changes per-session in the PROJECT's .claude directory,
#            not the global ~/.claude. Uses git root detection to ensure correct
#            project identification even when called from global hooks.

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty')

# Exit silently if no file path
[[ -z "$FILE" ]] && exit 0

# Exit silently if file doesn't exist (safety check for path)
[[ ! -e "$(dirname "$FILE")" ]] && exit 0

# Detect project root (git root or file's directory)
PROJECT_ROOT=$(git -C "$(dirname "$FILE")" rev-parse --show-toplevel 2>/dev/null || dirname "$FILE")

# Create session tracking in PROJECT's .claude directory
mkdir -p "$PROJECT_ROOT/.claude"
echo "$FILE" >> "$PROJECT_ROOT/.claude/.session-decisions"
exit 0
