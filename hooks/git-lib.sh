#!/usr/bin/env bash
# git-lib.sh — Git state utilities for Claude Code hooks.
#
# Loaded on demand via: require_git (defined in source-lib.sh)
# Depends on: core-lib.sh (must be loaded first)
#
# @decision DEC-SPLIT-001 (see core-lib.sh for full rationale)
#
# Provides:
#   get_git_state        - Populate GIT_BRANCH, GIT_DIRTY_COUNT, GIT_WORKTREES, GIT_WT_COUNT
#   get_session_changes  - Populate SESSION_CHANGED_COUNT, SESSION_FILE

# Guard against double-sourcing
[[ -n "${_GIT_LIB_LOADED:-}" ]] && return 0

_GIT_LIB_VERSION=1

# --- Git state ---
get_git_state() {
    local root="$1"
    GIT_BRANCH=""
    GIT_DIRTY_COUNT=0
    GIT_WORKTREES=""
    GIT_WT_COUNT=0

    # Support both regular repos (.git dir) and git worktrees (.git file).
    # rev-parse --git-dir is the canonical check — works for both.
    git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || return

    GIT_BRANCH=$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    GIT_DIRTY_COUNT=$(git -C "$root" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

    GIT_WORKTREES=$(git -C "$root" worktree list 2>/dev/null | grep -v "(bare)" | tail -n +2 || echo "")
    if [[ -n "$GIT_WORKTREES" ]]; then
        GIT_WT_COUNT=$(echo "$GIT_WORKTREES" | wc -l | tr -d ' ')
    fi
}

# --- Session tracking ---
# @decision DEC-V3-005
# @title Robust session file lookup with glob fallback and legacy name support
# @status accepted
# @rationale surface.sh had the most complete implementation: session-ID lookup,
#   generic fallback, glob fallback, and legacy .session-decisions support. The
#   shared library had only session-ID + generic fallback — missing the glob and
#   legacy paths. Porting the full implementation here eliminates divergence and
#   ensures all callers (compact-preserve.sh, surface.sh, session-summary.sh)
#   use the same lookup order. Zero behavioral change for callers already using
#   get_session_changes().
get_session_changes() {
    local root="$1"
    SESSION_CHANGED_COUNT=0
    SESSION_FILE=""

    local claude_dir="$root/.claude"
    local session_id="${CLAUDE_SESSION_ID:-}"

    if [[ -n "$session_id" && -f "${claude_dir}/.session-changes-${session_id}" ]]; then
        SESSION_FILE="${claude_dir}/.session-changes-${session_id}"
    elif [[ -f "${claude_dir}/.session-changes" ]]; then
        SESSION_FILE="${claude_dir}/.session-changes"
    else
        # Glob fallback for any session file (e.g. from a different session ID)
        # shellcheck disable=SC2012
        SESSION_FILE=$(ls "${claude_dir}/.session-changes"* 2>/dev/null | head -1 || echo "")
        # Also check legacy name (.session-decisions)
        if [[ -z "$SESSION_FILE" ]]; then
            # shellcheck disable=SC2012
            SESSION_FILE=$(ls "${claude_dir}/.session-decisions"* 2>/dev/null | head -1 || echo "")
        fi
    fi

    if [[ -n "$SESSION_FILE" && -f "$SESSION_FILE" ]]; then
        SESSION_CHANGED_COUNT=$(sort -u "$SESSION_FILE" | wc -l | tr -d ' ')
    fi
}

export -f get_git_state get_session_changes

_GIT_LIB_LOADED=1
