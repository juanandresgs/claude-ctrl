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
#   _cached_git_state    - Cache-aware wrapper for get_git_state (5s TTL, DEC-EFF-012)
#   get_session_changes  - Populate SESSION_CHANGED_COUNT, SESSION_FILE

# Guard against double-sourcing
[[ -n "${_GIT_LIB_LOADED:-}" ]] && return 0

_GIT_LIB_VERSION=1

# --- Git state cache ---
# @decision DEC-EFF-012
# @title Shared git state cache across hooks (5s TTL)
# @status accepted
# @rationale Git state is computed by 5 hooks per event cycle. Within a
#   single event (e.g., PreToolUse), git state doesn't change between hooks.
#   5-second TTL ensures freshness across event boundaries while eliminating
#   redundant git commands within the same cycle. ~250ms saved per multi-hook event.
#   Safety invariant: 5s TTL means stale data is at most 5 seconds old;
#   deny gates that check branch use the cached value which is correct
#   within the event cycle.
#   Cache file: CLAUDE_DIR/.git-state-cache (key=value format, no SID suffix —
#   shared across hooks within a single session; cleaned by session-end.sh).
#   Fallback: if cache read fails for any reason, falls back to fresh computation.
#
# _cached_git_state ROOT [CLAUDE_DIR]
#   Populates GIT_BRANCH, GIT_DIRTY_COUNT, GIT_WORKTREES, GIT_WT_COUNT.
#   CLAUDE_DIR defaults to ROOT/.claude when not provided.
_cached_git_state() {
    local root="$1"
    local claude_dir="${2:-${CLAUDE_DIR:-$root/.claude}}"
    local cache_file="$claude_dir/.git-state-cache"
    local cache_ttl=5  # seconds — within a single event cycle

    # Initialize defaults (safe if cache or computation fails)
    GIT_BRANCH=""
    GIT_DIRTY_COUNT=0
    GIT_WORKTREES=""
    GIT_WT_COUNT=0

    # --- Cache hit check ---
    if [[ -f "$cache_file" ]]; then
        local cache_mtime now_epoch cache_age
        cache_mtime=$(_file_mtime "$cache_file")
        now_epoch=$(date +%s)
        cache_age=$(( now_epoch - cache_mtime ))

        if [[ "$cache_age" -le "$cache_ttl" ]]; then
            # Cache hit — read values
            local _branch _dirty _wt_count
            _branch=$(grep '^GIT_BRANCH=' "$cache_file" 2>/dev/null | cut -d= -f2- || echo "")
            _dirty=$(grep '^GIT_DIRTY_COUNT=' "$cache_file" 2>/dev/null | cut -d= -f2 || echo "0")
            _wt_count=$(grep '^GIT_WT_COUNT=' "$cache_file" 2>/dev/null | cut -d= -f2 || echo "0")

            # Validate: if branch is non-empty, the cache is usable
            if [[ -n "$_branch" ]]; then
                GIT_BRANCH="$_branch"
                GIT_DIRTY_COUNT="${_dirty:-0}"
                GIT_WT_COUNT="${_wt_count:-0}"
                # GIT_WORKTREES not cached (too large); callers that need it use get_git_state directly
                return 0
            fi
            # Empty branch in cache → fall through to fresh computation
        fi
    fi

    # --- Cache miss: compute fresh state ---
    get_git_state "$root"

    # Write cache (atomic: write to tmp then move)
    if [[ -n "$GIT_BRANCH" ]]; then
        mkdir -p "$claude_dir" 2>/dev/null || true
        local tmp_cache
        tmp_cache="${cache_file}.tmp.$$"
        {
            printf 'GIT_BRANCH=%s\n' "$GIT_BRANCH"
            printf 'GIT_DIRTY_COUNT=%s\n' "${GIT_DIRTY_COUNT:-0}"
            printf 'GIT_WT_COUNT=%s\n' "${GIT_WT_COUNT:-0}"
        } > "$tmp_cache" 2>/dev/null && mv "$tmp_cache" "$cache_file" 2>/dev/null || \
            rm -f "$tmp_cache" 2>/dev/null || true
    fi
}

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

export -f get_git_state _cached_git_state get_session_changes

_GIT_LIB_LOADED=1
