#!/usr/bin/env bash
set -euo pipefail

# Project-aware file change tracking.
# PostToolUse hook — matcher: Write|Edit
#
# Tracks file changes per-session in the PROJECT's .claude directory.
# Uses CLAUDE_PROJECT_DIR when available, falls back to git root detection.
# Session-scoped to avoid collisions with concurrent sessions.

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

HOOK_INPUT=$(read_input)
FILE_PATH=$(get_field '.tool_input.file_path')

# Exit silently if no file path
[[ -z "$FILE_PATH" ]] && exit 0

# Exit silently if parent directory doesn't exist
[[ ! -e "$(dirname "$FILE_PATH")" ]] && exit 0

# Detect project root (prefers CLAUDE_PROJECT_DIR)
PROJECT_ROOT=$(detect_project_root)

# Session-scoped tracking file (tracks file changes, not decisions)
SESSION_ID=$(canonical_session_id)
TRACKING_DIR="$PROJECT_ROOT/.claude"
TRACKING_FILE="$TRACKING_DIR/.session-changes-${SESSION_ID}"

# Create tracking directory if needed
mkdir -p "$TRACKING_DIR"

# Atomic append: write to temp then append (safer than direct >>)
TMPFILE=$(mktemp "${TRACKING_DIR}/.track.XXXXXX")
echo "$FILE_PATH" > "$TMPFILE"
cat "$TMPFILE" >> "$TRACKING_FILE"
rm -f "$TMPFILE"

# --- Invalidate evaluation_state when source files change after clearance ---
# If evaluation_state is ready_for_guardian and source code changes, the
# evaluator clearance is stale. Reset to pending so a new tester pass is
# required before Guardian can proceed. (TKT-024: proof invalidation removed)
#
# @decision DEC-EVAL-005
# @title track.sh is the sole invalidator of evaluation_state
# @status accepted
# @rationale Source writes after evaluator clearance invalidate readiness.
#   This enforces that the evaluated HEAD and the committed HEAD are the same.
#   invalidate_if_ready() is a targeted atomic update — it only fires when
#   status is exactly ready_for_guardian, so pending/idle writes are no-ops.
if is_source_file "$FILE_PATH" && ! is_skippable_path "$FILE_PATH"; then
    _WF_ID=$(current_workflow_id "$PROJECT_ROOT")
    _INVALIDATED=$(rt_eval_invalidate "$_WF_ID" 2>/dev/null || echo "false")
    if [[ "$_INVALIDATED" == "true" ]]; then
        append_audit "$PROJECT_ROOT" "eval_reset" "$FILE_PATH"
    fi
fi

exit 0
