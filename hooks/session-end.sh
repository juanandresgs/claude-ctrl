#!/usr/bin/env bash
set -euo pipefail

# Session cleanup on termination.
# SessionEnd hook — runs once when session actually ends.
#
# Cleans up:
#   - Session tracking files (.session-changes-*)
#   - Lint cache files (.lint-cache)
#   - Temporary tracking artifacts

source "$(dirname "$0")/log.sh"

HOOK_INPUT=$(read_input)
REASON=$(echo "$HOOK_INPUT" | jq -r '.reason // "unknown"' 2>/dev/null)

PROJECT_ROOT=$(detect_project_root)

log_info "SESSION-END" "Session ending (reason: $REASON)"

# --- Clean up session tracking files ---
SESSION_ID="${CLAUDE_SESSION_ID:-}"
if [[ -n "$SESSION_ID" ]]; then
    rm -f "$PROJECT_ROOT/.claude/.session-changes-${SESSION_ID}"
else
    # Clean all session files if no specific ID
    rm -f "$PROJECT_ROOT/.claude/.session-changes"*
fi

# Also clean legacy-named files
rm -f "$PROJECT_ROOT/.claude/.session-decisions"*

# --- Clean up lint cache ---
rm -f "$PROJECT_ROOT/.claude/.lint-cache"

# --- Clean up temp tracking artifacts ---
rm -f "$PROJECT_ROOT/.claude/.track."*

log_info "SESSION-END" "Cleanup complete"
exit 0
