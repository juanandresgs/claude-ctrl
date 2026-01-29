#!/usr/bin/env bash
set -euo pipefail

# Pre-compaction context preservation.
# PreCompact hook
#
# Injects project state into additionalContext before compaction so the
# compacted context retains:
#   - Current git branch and status
#   - Files modified this session
#   - MASTER_PLAN.md existence and active phase
#   - Active worktrees

source "$(dirname "$0")/log.sh"

PROJECT_ROOT=$(detect_project_root)
CONTEXT_PARTS=()

# --- Git state ---
if [[ -d "$PROJECT_ROOT/.git" ]]; then
    BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    CONTEXT_PARTS+=("Current branch: $BRANCH")

    DIRTY_COUNT=$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$DIRTY_COUNT" -gt 0 ]]; then
        CONTEXT_PARTS+=("Uncommitted changes: $DIRTY_COUNT files")
    fi

    # Recent commits on this branch
    RECENT=$(git -C "$PROJECT_ROOT" log --oneline -3 2>/dev/null || echo "")
    if [[ -n "$RECENT" ]]; then
        CONTEXT_PARTS+=("Recent commits:")
        while IFS= read -r line; do
            CONTEXT_PARTS+=("  $line")
        done <<< "$RECENT"
    fi

    # Active worktrees
    WORKTREES=$(git -C "$PROJECT_ROOT" worktree list 2>/dev/null | grep -v "(bare)" | tail -n +2)
    if [[ -n "$WORKTREES" ]]; then
        CONTEXT_PARTS+=("Active worktrees:")
        while IFS= read -r line; do
            CONTEXT_PARTS+=("  $line")
        done <<< "$WORKTREES"
    fi
fi

# --- MASTER_PLAN.md ---
if [[ -f "$PROJECT_ROOT/MASTER_PLAN.md" ]]; then
    # Try to extract active phase
    PHASE=$(grep -iE '^\#.*phase|^\*\*Phase' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null | tail -1 || echo "")
    if [[ -n "$PHASE" ]]; then
        CONTEXT_PARTS+=("MASTER_PLAN.md: active ($PHASE)")
    else
        CONTEXT_PARTS+=("MASTER_PLAN.md: exists")
    fi
fi

# --- Session file changes ---
SESSION_FILE="$PROJECT_ROOT/.claude/.session-decisions"
if [[ -f "$SESSION_FILE" ]]; then
    FILE_COUNT=$(sort -u "$SESSION_FILE" | wc -l | tr -d ' ')
    CONTEXT_PARTS+=("Files modified this session: $FILE_COUNT")
    # List unique files
    while IFS= read -r f; do
        CONTEXT_PARTS+=("  $f")
    done < <(sort -u "$SESSION_FILE" | head -20)
fi

# --- Output ---
if [[ ${#CONTEXT_PARTS[@]} -gt 0 ]]; then
    CONTEXT=$(printf '%s\n' "${CONTEXT_PARTS[@]}")
    ESCAPED=$(echo "$CONTEXT" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreCompact",
    "additionalContext": $ESCAPED
  }
}
EOF
fi

exit 0
