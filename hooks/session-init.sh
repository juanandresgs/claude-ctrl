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

    # Plan age and staleness detection
    PLAN_MOD=$(stat -f '%m' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null || stat -c '%Y' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null || echo "0")
    if [[ "$PLAN_MOD" -gt 0 ]]; then
        NOW=$(date +%s)
        PLAN_AGE_DAYS=$(( (NOW - PLAN_MOD) / 86400 ))
        if [[ "$PLAN_AGE_DAYS" -gt 0 ]]; then
            CONTEXT_PARTS+=("Plan age: ${PLAN_AGE_DAYS}d since last update")
        fi

        # Count commits since plan was last modified
        if [[ -d "$PROJECT_ROOT/.git" ]]; then
            PLAN_DATE=$(date -r "$PLAN_MOD" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@$PLAN_MOD" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")
            if [[ -n "$PLAN_DATE" ]]; then
                COMMITS_SINCE=$(git -C "$PROJECT_ROOT" rev-list --count --after="$PLAN_DATE" HEAD 2>/dev/null || echo "0")
                if [[ "$COMMITS_SINCE" -ge 5 ]]; then
                    CONTEXT_PARTS+=("MASTER_PLAN.md may be stale (last updated ${PLAN_AGE_DAYS}d ago, $COMMITS_SINCE commits since)")
                fi
            fi
        fi
    fi

    # Phase progress tracking
    TOTAL_PHASES=$(grep -cE '^\#\#\s+Phase\s+[0-9]' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null || echo "0")
    COMPLETED_PHASES=$(grep -cE '\*\*Status:\*\*\s*completed' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null || echo "0")
    if [[ "$TOTAL_PHASES" -gt 0 ]]; then
        CONTEXT_PARTS+=("Plan progress: $COMPLETED_PHASES/$TOTAL_PHASES phases completed")
    fi
else
    CONTEXT_PARTS+=("MASTER_PLAN.md: not found (required before implementation)")
fi

# --- Stale session files ---
# Check both new and legacy filenames
for pattern in "$PROJECT_ROOT/.claude/.session-changes"* "$PROJECT_ROOT/.claude/.session-decisions"*; do
    if [[ -f "$pattern" ]]; then
        STALE_COUNT=$(wc -l < "$pattern" | tr -d ' ')
        STALE_NAME=$(basename "$pattern")
        CONTEXT_PARTS+=("Stale session file: $STALE_NAME ($STALE_COUNT entries from previous session)")
    fi
done

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
