#!/usr/bin/env bash
set -euo pipefail

# Session context injection at startup.
# SessionStart hook — matcher: startup
#
# Injects project context into the session:
#   - Git state (branch, dirty files, on-main warning)
#   - MASTER_PLAN.md existence and status
#   - Active worktrees
#   - Stale session files from crashed sessions
#
# Known: SessionStart has a bug (Issue #10373) where output may not inject
# for brand-new sessions. Works for /clear, /compact, resume. Implement
# anyway — when it works it's valuable, when it doesn't there's no harm.

source "$(dirname "$0")/log.sh"

PROJECT_ROOT=$(detect_project_root)
CONTEXT_PARTS=()

# --- Git state ---
if [[ -d "$PROJECT_ROOT/.git" ]]; then
    BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    DIRTY=$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | head -5)

    CONTEXT_PARTS+=("Git: branch=$BRANCH")

    if [[ "$BRANCH" == "main" || "$BRANCH" == "master" ]]; then
        CONTEXT_PARTS+=("WARNING: On $BRANCH branch. Sacred Practice #2: create a worktree before making changes.")
    fi

    if [[ -n "$DIRTY" ]]; then
        DIRTY_COUNT=$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        CONTEXT_PARTS+=("Working tree: $DIRTY_COUNT uncommitted changes")
    fi

    # Active worktrees
    WORKTREES=$(git -C "$PROJECT_ROOT" worktree list 2>/dev/null | grep -v "(bare)" | tail -n +2)
    if [[ -n "$WORKTREES" ]]; then
        WT_COUNT=$(echo "$WORKTREES" | wc -l | tr -d ' ')
        CONTEXT_PARTS+=("Active worktrees: $WT_COUNT")
    fi
fi

# --- MASTER_PLAN.md ---
if [[ -f "$PROJECT_ROOT/MASTER_PLAN.md" ]]; then
    # Extract status if present
    PLAN_STATUS=$(grep -i '^\*\*Status\*\*\|^Status:' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null | head -1 || echo "")
    if [[ -n "$PLAN_STATUS" ]]; then
        CONTEXT_PARTS+=("MASTER_PLAN.md: exists ($PLAN_STATUS)")
    else
        CONTEXT_PARTS+=("MASTER_PLAN.md: exists")
    fi
else
    CONTEXT_PARTS+=("MASTER_PLAN.md: not found (required before implementation)")
fi

# --- Stale session files ---
if [[ -f "$PROJECT_ROOT/.claude/.session-decisions" ]]; then
    STALE_COUNT=$(wc -l < "$PROJECT_ROOT/.claude/.session-decisions" | tr -d ' ')
    CONTEXT_PARTS+=("Stale session file: .session-decisions ($STALE_COUNT entries from previous session)")
fi

# --- Output as additionalContext ---
if [[ ${#CONTEXT_PARTS[@]} -gt 0 ]]; then
    CONTEXT=$(printf '%s\n' "${CONTEXT_PARTS[@]}")
    ESCAPED=$(echo "$CONTEXT" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": $ESCAPED
  }
}
EOF
fi

exit 0
