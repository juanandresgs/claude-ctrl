#!/usr/bin/env bash
# Shared context-building library for Claude Code hooks.
# Source this file from hooks that need project context:
#   source "$(dirname "$0")/context-lib.sh"
#
# DECISION: Consolidate duplicate context code. Rationale: session-init.sh,
# prompt-submit.sh, and subagent-start.sh all duplicate git state, plan status,
# and worktree listing code. A shared library eliminates drift and reduces
# maintenance surface. Status: accepted.
#
# Provides:
#   get_git_state <project_root>     - Populates GIT_BRANCH, GIT_DIRTY_COUNT,
#                                      GIT_WORKTREES, GIT_WT_COUNT
#   get_plan_status <project_root>   - Populates PLAN_EXISTS, PLAN_PHASE,
#                                      PLAN_TOTAL_PHASES, PLAN_COMPLETED_PHASES,
#                                      PLAN_AGE_DAYS, PLAN_COMMITS_SINCE
#   get_session_changes <project_root> - Populates SESSION_CHANGED_COUNT

# --- Git state ---
get_git_state() {
    local root="$1"
    GIT_BRANCH=""
    GIT_DIRTY_COUNT=0
    GIT_WORKTREES=""
    GIT_WT_COUNT=0

    [[ ! -d "$root/.git" ]] && return

    GIT_BRANCH=$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    GIT_DIRTY_COUNT=$(git -C "$root" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

    GIT_WORKTREES=$(git -C "$root" worktree list 2>/dev/null | grep -v "(bare)" | tail -n +2 || echo "")
    if [[ -n "$GIT_WORKTREES" ]]; then
        GIT_WT_COUNT=$(echo "$GIT_WORKTREES" | wc -l | tr -d ' ')
    fi
}

# --- MASTER_PLAN.md status ---
get_plan_status() {
    local root="$1"
    PLAN_EXISTS=false
    PLAN_PHASE=""
    PLAN_TOTAL_PHASES=0
    PLAN_COMPLETED_PHASES=0
    PLAN_IN_PROGRESS_PHASES=0
    PLAN_AGE_DAYS=0
    PLAN_COMMITS_SINCE=0

    [[ ! -f "$root/MASTER_PLAN.md" ]] && return

    PLAN_EXISTS=true

    PLAN_PHASE=$(grep -iE '^\#.*phase|^\*\*Phase' "$root/MASTER_PLAN.md" 2>/dev/null | tail -1 || echo "")
    PLAN_TOTAL_PHASES=$(grep -cE '^\#\#\s+Phase\s+[0-9]' "$root/MASTER_PLAN.md" 2>/dev/null || echo "0")
    PLAN_COMPLETED_PHASES=$(grep -cE '\*\*Status:\*\*\s*completed' "$root/MASTER_PLAN.md" 2>/dev/null || echo "0")
    PLAN_IN_PROGRESS_PHASES=$(grep -cE '\*\*Status:\*\*\s*in-progress' "$root/MASTER_PLAN.md" 2>/dev/null || echo "0")

    # Plan age
    local plan_mod
    plan_mod=$(stat -f '%m' "$root/MASTER_PLAN.md" 2>/dev/null || stat -c '%Y' "$root/MASTER_PLAN.md" 2>/dev/null || echo "0")
    if [[ "$plan_mod" -gt 0 ]]; then
        local now
        now=$(date +%s)
        PLAN_AGE_DAYS=$(( (now - plan_mod) / 86400 ))

        # Commits since last plan update
        if [[ -d "$root/.git" ]]; then
            local plan_date
            plan_date=$(date -r "$plan_mod" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@$plan_mod" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")
            if [[ -n "$plan_date" ]]; then
                PLAN_COMMITS_SINCE=$(git -C "$root" rev-list --count --after="$plan_date" HEAD 2>/dev/null || echo "0")
            fi
        fi
    fi
}

# --- Session tracking ---
get_session_changes() {
    local root="$1"
    SESSION_CHANGED_COUNT=0
    SESSION_FILE=""

    local session_id="${CLAUDE_SESSION_ID:-}"
    if [[ -n "$session_id" && -f "$root/.claude/.session-changes-${session_id}" ]]; then
        SESSION_FILE="$root/.claude/.session-changes-${session_id}"
    elif [[ -f "$root/.claude/.session-changes" ]]; then
        SESSION_FILE="$root/.claude/.session-changes"
    fi

    if [[ -n "$SESSION_FILE" && -f "$SESSION_FILE" ]]; then
        SESSION_CHANGED_COUNT=$(sort -u "$SESSION_FILE" | wc -l | tr -d ' ')
    fi
}

# Export for subshells
export -f get_git_state get_plan_status get_session_changes
