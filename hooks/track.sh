#!/usr/bin/env bash
set -euo pipefail

# Project-aware file change tracking.
# PostToolUse hook — matcher: Write|Edit
#
# Tracks file changes per-session in the PROJECT's .claude directory.
# Uses CLAUDE_PROJECT_DIR when available, falls back to git root detection.
# Session-scoped to avoid collisions with concurrent sessions.

source "$(dirname "$0")/source-lib.sh"

HOOK_INPUT=$(read_input)
FILE_PATH=$(get_field '.tool_input.file_path')

# Exit silently if no file path
[[ -z "$FILE_PATH" ]] && exit 0

# Exit silently if parent directory doesn't exist
[[ ! -e "$(dirname "$FILE_PATH")" ]] && exit 0

# Detect project root (prefers CLAUDE_PROJECT_DIR)
PROJECT_ROOT=$(detect_project_root)

# Session-scoped tracking file (tracks file changes, not decisions)
SESSION_ID="${CLAUDE_SESSION_ID:-$$}"
TRACKING_DIR="$PROJECT_ROOT/.claude"
TRACKING_FILE="$TRACKING_DIR/.session-changes-${SESSION_ID}"

# Create tracking directory if needed
mkdir -p "$TRACKING_DIR"

# Atomic append: write to temp then append (safer than direct >>)
TMPFILE=$(mktemp "${TRACKING_DIR}/.track.XXXXXX")
echo "$FILE_PATH" > "$TMPFILE"
cat "$TMPFILE" >> "$TRACKING_FILE"
rm -f "$TMPFILE"

# --- Log write event to session event log (skip trace artifacts — meta-infrastructure noise) ---
if [[ ! "$FILE_PATH" =~ /\.claude/traces/ ]]; then
    append_session_event "write" "{\"file\":\"$FILE_PATH\"}" "$PROJECT_ROOT"
fi

# --- Invalidate doc freshness cache when a .md file is written ---
# The cache key includes doc modification times. A direct write to a tracked .md
# file changes its mtime, which the next get_doc_freshness() call detects as a
# cache miss. Removing the cache here ensures recomputation within the same session.
if [[ "$FILE_PATH" == *.md ]]; then
    _DOC_CACHE="${TRACKING_DIR}/.doc-freshness-cache"
    rm -f "$_DOC_CACHE"
fi

# --- Invalidate proof-status when non-test source files change ---
# If user verified the feature and then source code changes, proof is stale.
PROOF_FILE="$TRACKING_DIR/.proof-status"
if [[ -f "$PROOF_FILE" ]]; then
    PROOF_STATUS=$(cut -d'|' -f1 "$PROOF_FILE")
    if [[ "$PROOF_STATUS" == "verified" ]]; then
        # Only invalidate for source file changes (not tests, config, docs)
        if [[ "$FILE_PATH" =~ \.(ts|tsx|js|jsx|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php|sh|bash|zsh)$ ]] \
           && [[ ! "$FILE_PATH" =~ (\.test\.|\.spec\.|__tests__|\.config\.|node_modules|vendor|dist|\.git|\.claude) ]]; then
            echo "pending|$(date +%s)" > "$PROOF_FILE"
        fi
    fi
fi

exit 0
