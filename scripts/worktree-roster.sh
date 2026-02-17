#!/usr/bin/env bash
# worktree-roster.sh — Worktree lifecycle tracking and cleanup management.
#
# Purpose: Tracks git worktrees with associated metadata (issue, session, PID)
# to enable stale detection, orphan cleanup, and lifecycle visibility.
#
# @decision DEC-WORKTREE-001
# @title Worktree lifecycle tracking via TSV registry
# @status accepted
# @rationale Worktrees accumulate without tracking. No visibility into which
# session created a worktree, whether it's still active, or if the issue was
# closed. A simple TSV registry (path|branch|issue|session|pid|created_at)
# enables stale detection (PID dead), orphan pruning (directory gone), and
# integration with session-init/statusline for proactive cleanup reminders.
# TSV chosen over JSON for simplicity and grep-friendliness.
#
# Registry: ~/.claude/.worktree-roster.tsv
# Format: worktree_path<TAB>branch<TAB>issue_number<TAB>session_id<TAB>pid<TAB>created_at
#
# Commands:
#   register <path> [--issue=N] [--session=ID]  Register new worktree (idempotent)
#   list [--json]                                Show all worktrees with status
#   stale                                        List stale worktrees (PID dead, dir exists)
#   cleanup [--dry-run] [--confirm]              Remove stale worktrees
#   prune                                        Remove orphaned registry entries
#
# Status types:
#   active   - PID is alive
#   stale    - PID is dead but directory exists
#   orphaned - Registry entry but directory gone

set -euo pipefail

# Allow override for testing
REGISTRY="${REGISTRY:-$HOME/.claude/.worktree-roster.tsv}"

# Ensure registry exists
init_registry() {
    if [[ ! -f "$REGISTRY" ]]; then
        touch "$REGISTRY"
    fi
}

# Check if PID is alive
is_pid_alive() {
    local pid="$1"
    [[ -z "$pid" || "$pid" == "0" ]] && return 1
    kill -0 "$pid" 2>/dev/null
}

# Get status for a worktree entry
get_worktree_status() {
    local path="$1"
    local pid="$2"

    if [[ ! -d "$path" ]]; then
        echo "orphaned"
    elif is_pid_alive "$pid"; then
        echo "active"
    else
        echo "stale"
    fi
}

# Register a worktree (idempotent)
cmd_register() {
    local path=""
    local issue=""
    local session="${CLAUDE_SESSION_ID:-}"
    local pid="$$"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --issue=*)
                issue="${1#*=}"
                shift
                ;;
            --session=*)
                session="${1#*=}"
                shift
                ;;
            *)
                path="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$path" ]]; then
        echo "Usage: worktree-roster.sh register <path> [--issue=N] [--session=ID]" >&2
        exit 1
    fi

    # Normalize path
    path=$(cd "$path" && pwd)

    # Get branch name
    local branch=""
    if [[ -d "$path/.git" ]] || [[ -f "$path/.git" ]]; then
        branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    fi

    init_registry

    # Remove existing entry if present (idempotent)
    if grep -q "^${path}" "$REGISTRY" 2>/dev/null; then
        grep -v "^${path}" "$REGISTRY" > "${REGISTRY}.tmp" || true
        mv "${REGISTRY}.tmp" "$REGISTRY"
    fi

    # Add new entry
    local created_at
    created_at=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${path}\t${branch}\t${issue}\t${session}\t${pid}\t${created_at}" >> "$REGISTRY"
}

# List all worktrees
cmd_list() {
    local json=false

    if [[ "${1:-}" == "--json" ]]; then
        json=true
    fi

    init_registry

    if [[ ! -s "$REGISTRY" ]]; then
        if $json; then
            echo "[]"
        else
            echo "No registered worktrees."
        fi
        return
    fi

    # Get all worktrees from git for cross-reference
    local git_worktrees
    git_worktrees=$(git worktree list 2>/dev/null | tail -n +2 | awk '{print $1}' || echo "")

    if $json; then
        echo "["
        local first=true
        while IFS=$'\t' read -r path branch issue session pid created_at; do
            local status
            status=$(get_worktree_status "$path" "$pid")

            if ! $first; then
                echo ","
            fi
            first=false

            # Check if in git worktree list
            local in_git=false
            if echo "$git_worktrees" | grep -qF "$path"; then
                in_git=true
            fi

            cat <<EOF
  {
    "path": "$path",
    "branch": "$branch",
    "issue": "$issue",
    "session": "$session",
    "pid": "$pid",
    "created_at": "$created_at",
    "status": "$status",
    "in_git": $in_git
  }
EOF
        done < "$REGISTRY"
        echo ""
        echo "]"
    else
        printf "%-40s %-20s %-8s %-10s %-20s %s\n" "PATH" "BRANCH" "STATUS" "ISSUE" "SESSION" "CREATED"
        printf "%s\n" "$(printf '%.0s-' {1..150})"

        while IFS=$'\t' read -r path branch issue session pid created_at; do
            local status
            status=$(get_worktree_status "$path" "$pid")

            # Truncate long paths
            local short_path="$path"
            if [[ ${#path} -gt 38 ]]; then
                short_path="...${path: -35}"
            fi

            # Truncate session ID
            local short_session="${session:0:8}"
            [[ -n "$session" && ${#session} -gt 8 ]] && short_session="${short_session}..."

            printf "%-40s %-20s %-8s %-10s %-20s %s\n" \
                "$short_path" "$branch" "$status" "${issue:-—}" "$short_session" "$created_at"
        done < "$REGISTRY"

        # Show unregistered worktrees
        local unregistered=()
        while IFS= read -r wt_path; do
            if ! grep -qF "$wt_path" "$REGISTRY" 2>/dev/null; then
                unregistered+=("$wt_path")
            fi
        done <<< "$git_worktrees"

        if [[ ${#unregistered[@]} -gt 0 ]]; then
            echo ""
            echo "Unregistered worktrees (not in roster):"
            for wt in "${unregistered[@]}"; do
                local wt_branch
                wt_branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
                echo "  $wt [$wt_branch]"
            done
        fi
    fi
}

# List only stale worktrees
cmd_stale() {
    init_registry

    if [[ ! -s "$REGISTRY" ]]; then
        return
    fi

    local found_stale=false
    while IFS=$'\t' read -r path branch issue session pid created_at; do
        local status
        status=$(get_worktree_status "$path" "$pid")

        if [[ "$status" == "stale" ]]; then
            found_stale=true

            # Calculate age
            local age_str=""
            if [[ -d "$path" ]]; then
                local created_epoch
                created_epoch=$(date -j -f '%Y-%m-%d %H:%M:%S' "$created_at" '+%s' 2>/dev/null || echo "0")
                if [[ "$created_epoch" -gt 0 ]]; then
                    local now
                    now=$(date '+%s')
                    local age_days=$(( (now - created_epoch) / 86400 ))
                    age_str=" (${age_days}d old)"
                fi
            fi

            echo "$path [$branch]${age_str}${issue:+ issue #$issue}"
        fi
    done < "$REGISTRY"

    if ! $found_stale; then
        return 1
    fi
}

# Cleanup stale worktrees
cmd_cleanup() {
    local dry_run=true
    local confirm=false

    for arg in "$@"; do
        case "$arg" in
            --dry-run)
                dry_run=true
                ;;
            --confirm)
                confirm=true
                dry_run=false
                ;;
        esac
    done

    init_registry

    if [[ ! -s "$REGISTRY" ]]; then
        echo "No registered worktrees."
        return
    fi

    # Collect stale entries
    local stale_paths=()
    while IFS=$'\t' read -r path branch issue session pid created_at; do
        local status
        status=$(get_worktree_status "$path" "$pid")

        if [[ "$status" == "stale" ]]; then
            stale_paths+=("$path")
        fi
    done < "$REGISTRY"

    if [[ ${#stale_paths[@]} -eq 0 ]]; then
        echo "No stale worktrees found."
        return
    fi

    echo "Stale worktrees:"
    for path in "${stale_paths[@]}"; do
        echo "  $path"
    done
    echo ""

    if $dry_run; then
        echo "Dry-run mode. Re-run with --confirm to actually remove these worktrees."
        exit 0
    fi

    if ! $confirm; then
        echo "Re-run with --confirm to remove these worktrees."
        exit 0
    fi

    # Remove worktrees
    local removed=0
    for path in "${stale_paths[@]}"; do
        echo "Removing: $path"

        # Remove via git worktree remove
        if git worktree remove "$path" 2>/dev/null; then
            removed=$((removed + 1))
        elif [[ -d "$path" ]]; then
            # Force removal if git worktree remove failed
            rm -rf "$path"
            # Remove from git config
            git worktree prune 2>/dev/null || true
            removed=$((removed + 1))
        fi

        # Remove from registry
        grep -v "^${path}" "$REGISTRY" > "${REGISTRY}.tmp" || true
        mv "${REGISTRY}.tmp" "$REGISTRY"
    done

    echo ""
    echo "Removed $removed stale worktree(s)."
}

# Prune orphaned entries
cmd_prune() {
    init_registry

    if [[ ! -s "$REGISTRY" ]]; then
        return
    fi

    local pruned=0
    local tmp="${REGISTRY}.tmp"
    > "$tmp"

    while IFS=$'\t' read -r path branch issue session pid created_at; do
        if [[ -d "$path" ]]; then
            # Keep entry
            echo -e "${path}\t${branch}\t${issue}\t${session}\t${pid}\t${created_at}" >> "$tmp"
        else
            pruned=$((pruned + 1))
        fi
    done < "$REGISTRY"

    mv "$tmp" "$REGISTRY"

    if [[ "$pruned" -gt 0 ]]; then
        echo "Pruned $pruned orphaned registry entries." >&2
    fi
}

# Main dispatch
case "${1:-}" in
    register)
        shift
        cmd_register "$@"
        ;;
    list)
        shift
        cmd_list "$@"
        ;;
    stale)
        cmd_stale
        ;;
    cleanup)
        shift
        cmd_cleanup "$@"
        ;;
    prune)
        cmd_prune
        ;;
    *)
        cat >&2 <<EOF
Usage: worktree-roster.sh <command> [options]

Commands:
  register <path> [--issue=N] [--session=ID]   Register a worktree
  list [--json]                                 List all worktrees with status
  stale                                         List stale worktrees (PID dead)
  cleanup [--dry-run] [--confirm]               Remove stale worktrees
  prune                                         Remove orphaned registry entries

Status types:
  active   - PID is alive
  stale    - PID is dead but directory exists
  orphaned - Registry entry but directory gone
EOF
        exit 1
        ;;
esac
