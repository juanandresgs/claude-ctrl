#!/usr/bin/env bash
set -euo pipefail

# Subagent context injection at spawn time.
# SubagentStart hook — matcher: (all agent types)
#
# Injects current project state into every subagent so Planner,
# Implementer, and Guardian agents always have fresh context:
#   - Current git branch and dirty state
#   - MASTER_PLAN.md existence and active phase
#   - Active worktrees
#   - Agent-type-specific guidance

source "$(dirname "$0")/log.sh"

HOOK_INPUT=$(read_input)
AGENT_TYPE=$(echo "$HOOK_INPUT" | jq -r '.agent_type // empty' 2>/dev/null)

PROJECT_ROOT=$(detect_project_root)
CONTEXT_PARTS=()

# --- Git state ---
if [[ -d "$PROJECT_ROOT/.git" ]]; then
    BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    CONTEXT_PARTS+=("Git branch: $BRANCH")

    DIRTY_COUNT=$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$DIRTY_COUNT" -gt 0 ]]; then
        CONTEXT_PARTS+=("Uncommitted changes: $DIRTY_COUNT files")
    fi

    # Active worktrees
    WORKTREES=$(git -C "$PROJECT_ROOT" worktree list 2>/dev/null | grep -v "(bare)" | tail -n +2)
    if [[ -n "$WORKTREES" ]]; then
        WT_COUNT=$(echo "$WORKTREES" | wc -l | tr -d ' ')
        CONTEXT_PARTS+=("Active worktrees: $WT_COUNT")
        while IFS= read -r line; do
            CONTEXT_PARTS+=("  $line")
        done <<< "$WORKTREES"
    fi
fi

# --- MASTER_PLAN.md ---
if [[ -f "$PROJECT_ROOT/MASTER_PLAN.md" ]]; then
    PHASE=$(grep -iE '^\#.*phase|^\*\*Phase' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null | tail -1 || echo "")
    if [[ -n "$PHASE" ]]; then
        CONTEXT_PARTS+=("MASTER_PLAN.md: active ($PHASE)")
    else
        CONTEXT_PARTS+=("MASTER_PLAN.md: exists")
    fi
else
    CONTEXT_PARTS+=("MASTER_PLAN.md: not found")
fi

# --- Agent-type-specific context ---
case "$AGENT_TYPE" in
    planner|Plan)
        CONTEXT_PARTS+=("Role: Planner — create MASTER_PLAN.md before any code. Include rationale, architecture, git issues, worktree strategy.")
        ;;
    implementer)
        CONTEXT_PARTS+=("Role: Implementer — test-first development in isolated worktrees. Add @decision annotations to 50+ line files. Never work on main.")
        ;;
    guardian)
        CONTEXT_PARTS+=("Role: Guardian — REQUIRED: After merge approval, update MASTER_PLAN.md: mark phase status as completed, append decision log with @decision IDs from merged code, present plan update diff to user for approval before applying. The merge is not done until the plan is updated. Also: verify @decision annotations before merge. Check for staged secrets. Require explicit approval for commits/merges.")
        ;;
    Bash|Explore)
        # Lightweight agents — minimal context
        ;;
    *)
        CONTEXT_PARTS+=("Agent type: ${AGENT_TYPE:-unknown}")
        ;;
esac

# --- Output ---
if [[ ${#CONTEXT_PARTS[@]} -gt 0 ]]; then
    CONTEXT=$(printf '%s\n' "${CONTEXT_PARTS[@]}")
    ESCAPED=$(echo "$CONTEXT" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SubagentStart",
    "additionalContext": $ESCAPED
  }
}
EOF
fi

exit 0
