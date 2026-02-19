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
# @decision DEC-WORKTREE-003
# @title Three-way sweep reconciliation: filesystem vs git vs registry
# @status accepted
# @rationale Guardian cleans up worktrees on merge, but orphaned directories
# accumulate when cleanup is missed (crash, manual branch deletion, etc.).
# The roster registry alone can't detect these — it only knows what was registered.
# Three-way reconciliation (scan filesystem, cross-ref git worktree list, cross-ref
# registry) classifies every directory in .worktrees/ as husk/orphan/unregistered/ghost.
# Husks (empty dirs) are auto-removed as safe. Orphans (content dirs not in git) warn
# or remove depending on mode. Unregistered (in git but not registry) auto-register.
# Ghosts (in registry but dir gone) prune from registry. This closes the gap where
# Guardian-missed cleanup was invisible until the next roster command.
#
# Registry: ~/.claude/.worktree-roster.tsv
# Format: worktree_path<TAB>branch<TAB>issue_number<TAB>session_id<TAB>pid<TAB>created_at
#
# Commands:
#   register <path> [--issue=N] [--session=ID]  Register new worktree (idempotent)
#   list [--json]                                Show all worktrees with status
#   stale                                        List stale worktrees (PID dead, dir exists)
#   cleanup [--dry-run] [--confirm] [--force]    Remove stale worktrees
#   prune                                        Remove orphaned registry entries
#   sweep [--dry-run|--auto|--confirm]           Three-way reconciliation of filesystem/git/registry
#
# Status types:
#   active   - Lockfile present (<24h) or PID is alive
#   stale    - PID is dead and no fresh lockfile; directory exists
#   orphaned - Registry entry but directory gone
#
# Sweep classifications:
#   husk         - Empty dir (no real files), not in git worktree list — safe to auto-remove
#   orphan       - Has content files, not in git worktree list — needs review
#   unregistered - In git worktree list but not in roster — auto-register
#   ghost        - In roster but directory doesn't exist — prune from registry

set -euo pipefail

# Allow override for testing
REGISTRY="${REGISTRY:-$HOME/.claude/.worktree-roster.tsv}"

# Allow override for testing sweep's filesystem scan target
WORKTREE_DIR="${WORKTREE_DIR:-$HOME/.claude/.worktrees}"

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
# Lockfile (.claude-active) takes precedence over PID for active detection.
# A fresh lockfile (mtime < 24h) means the session is considered active even
# if the PID field is 0 (new registrations) or stale.
get_worktree_status() {
    local path="$1"
    local pid="$2"

    if [[ ! -d "$path" ]]; then
        echo "orphaned"
    elif [[ -f "$path/.claude-active" ]]; then
        # Lockfile present — check freshness (24h = 86400s)
        local mtime now age
        mtime=$(stat -f %m "$path/.claude-active" 2>/dev/null || stat -c %Y "$path/.claude-active" 2>/dev/null || echo 0)
        now=$(date +%s)
        age=$((now - mtime))
        if [[ $age -lt 86400 ]]; then
            echo "active"
        else
            echo "stale"
        fi
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
    local pid="0"

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
#
# @decision DEC-WORKTREE-002
# @title CWD-safe cleanup with lockfile protection and --force override
# @status accepted
# @rationale Deleting a directory while the shell CWD is inside it causes
# posix_spawn ENOENT on all subsequent Bash calls — the "CWD death spiral".
# This is fixed by resolving the main worktree and cd-ing there before any
# rm or git worktree remove call. Lockfile protection (.claude-active) prevents
# cleanup from removing worktrees with active sessions; --force overrides.
# pid=0 registrations (new default) no longer trigger false-stale detection —
# the lockfile is now the primary liveness signal.
cmd_cleanup() {
    local dry_run=true
    local confirm=false
    local force=false

    for arg in "$@"; do
        case "$arg" in
            --dry-run)
                dry_run=true
                ;;
            --confirm)
                confirm=true
                dry_run=false
                ;;
            --force)
                force=true
                ;;
        esac
    done

    init_registry

    if [[ ! -s "$REGISTRY" ]]; then
        echo "No registered worktrees."
        return
    fi

    # Collect stale entries, skipping lockfile-protected ones unless --force
    local stale_paths=()
    while IFS=$'\t' read -r path branch issue session pid created_at; do
        local status
        status=$(get_worktree_status "$path" "$pid")

        if [[ "$status" == "stale" ]]; then
            # Skip lockfile-protected worktrees unless --force
            if [[ -f "$path/.claude-active" ]] && ! $force; then
                local mtime now age
                mtime=$(stat -f %m "$path/.claude-active" 2>/dev/null || stat -c %Y "$path/.claude-active" 2>/dev/null || echo 0)
                now=$(date +%s)
                age=$((now - mtime))
                echo "Skipping $path (lockfile present, age ${age}s — use --force to override)"
                continue
            fi
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

    # Resolve main worktree for CWD safety
    local main_wt
    main_wt=$(git worktree list 2>/dev/null | awk '{print $1; exit}')
    main_wt="${main_wt:-$(pwd)}"

    # Remove worktrees (CWD-safe)
    local removed=0
    for path in "${stale_paths[@]}"; do
        echo "Removing: $path"

        # CWD safety: if shell is inside target, cd out first
        if [[ "$PWD" == "$path"* ]]; then
            cd "$main_wt" || cd "$HOME"
        fi

        # Write CWD recovery canary before deletion so Check 0.5 Path B can
        # recover the orchestrator's Bash tool CWD on the next command.
        echo "$path" > "$HOME/.claude/.cwd-recovery-needed" 2>/dev/null || true

        # Remove via git worktree remove (from main worktree for safety)
        if (cd "$main_wt" && git worktree remove "$path" 2>/dev/null); then
            removed=$((removed + 1))
        elif [[ -d "$path" ]]; then
            # Force removal if git worktree remove failed
            rm -rf "$path"
            # Remove from git config
            (cd "$main_wt" && git worktree prune 2>/dev/null) || true
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

# Three-way filesystem/git/registry reconciliation
#
# Scans WORKTREE_DIR for all subdirectories, then classifies each:
#   husk         - empty dir not tracked by git — auto-removable
#   orphan       - has content files, not tracked by git — needs review
#   unregistered - tracked by git but missing from roster — auto-register
#   ghost        - in roster but directory gone — prune from registry
#
# Modes:
#   --dry-run (default): report classifications, no side effects
#   --auto:    remove husks, warn orphans, register unregistered, prune ghosts
#   --confirm: remove husks AND orphans, register unregistered, prune ghosts
#
# CWD-safe: cd to main worktree before any rm (same pattern as cmd_cleanup).
cmd_sweep() {
    local mode="dry-run"

    for arg in "$@"; do
        case "$arg" in
            --dry-run) mode="dry-run" ;;
            --auto)    mode="auto"    ;;
            --confirm) mode="confirm" ;;
        esac
    done

    init_registry

    # Resolve main worktree for CWD safety
    local main_wt
    main_wt=$(git worktree list 2>/dev/null | awk '{print $1; exit}' || echo "")
    main_wt="${main_wt:-$HOME}"

    # Collect git-tracked worktree paths (portable: no process substitution)
    local git_wt_paths_raw
    git_wt_paths_raw=$(git worktree list --porcelain 2>/dev/null | grep '^worktree ' | sed 's/^worktree //' || echo "")

    local husks=()
    local orphans=()
    local unregistered=()
    local ghosts=()
    local removed_count=0
    local registered_count=0

    # --- Scan filesystem ---
    if [[ -d "$WORKTREE_DIR" ]]; then
        for wt_dir in "$WORKTREE_DIR"/*/; do
            [[ ! -d "$wt_dir" ]] && continue
            local wt_path="${wt_dir%/}"  # strip trailing slash

            # Check if tracked by git
            if echo "$git_wt_paths_raw" | grep -qF "$wt_path"; then
                # Tracked by git — check roster
                if ! grep -qF "$wt_path" "$REGISTRY" 2>/dev/null; then
                    unregistered+=("$wt_path")
                fi
                continue
            fi

            # Not in git worktree list — classify by content
            local file_count
            file_count=$(find "$wt_path" -not -name '.git' -not -path '*/.git/*' -type f 2>/dev/null | wc -l | tr -d ' ')

            if [[ "$file_count" -eq 0 ]]; then
                husks+=("$wt_path")
            else
                orphans+=("$wt_path")
            fi
        done
    fi

    # --- Find ghosts in registry (entries whose directory is gone) ---
    local ghosts=()
    if [[ -s "$REGISTRY" ]]; then
        while IFS=$'\t' read -r path branch issue session pid created_at; do
            [[ -z "$path" ]] && continue
            if [[ ! -d "$path" ]]; then
                ghosts+=("$path")
            fi
        done < "$REGISTRY"
    fi

    # --- Report ---
    echo "Sweep report (mode: $mode):"
    echo ""

    local husk_count="${#husks[@]}"
    local orphan_count_r="${#orphans[@]}"
    local unreg_count="${#unregistered[@]}"
    local ghost_count_r="${#ghosts[@]}"

    if [[ "$husk_count" -gt 0 ]]; then
        echo "Husks (empty dirs, not in git — safe to remove):"
        for p in "${husks[@]+"${husks[@]}"}"; do echo "  $p"; done
    else
        echo "Husks: none"
    fi

    if [[ "$orphan_count_r" -gt 0 ]]; then
        echo "Orphans (content dirs, not in git — review needed):"
        for p in "${orphans[@]+"${orphans[@]}"}"; do
            local fc
            fc=$(find "$p" -not -name '.git' -not -path '*/.git/*' -type f 2>/dev/null | wc -l | tr -d ' ')
            echo "  $p ($fc file(s))"
        done
    else
        echo "Orphans: none"
    fi

    if [[ "$unreg_count" -gt 0 ]]; then
        echo "Unregistered (in git, not in roster — will auto-register):"
        for p in "${unregistered[@]+"${unregistered[@]}"}"; do echo "  $p"; done
    else
        echo "Unregistered: none"
    fi

    if [[ "$ghost_count_r" -gt 0 ]]; then
        echo "Ghosts (in roster, dir gone — will prune):"
        for p in "${ghosts[@]+"${ghosts[@]}"}"; do echo "  $p"; done
    else
        echo "Ghosts: none"
    fi

    if [[ "$mode" == "dry-run" ]]; then
        echo ""
        echo "Dry-run: no changes made. Re-run with --auto or --confirm to apply."
        return 0
    fi

    echo ""

    # --- Apply changes ---
    # Note: all array iterations use ${arr[@]+"${arr[@]}"} to be safe with
    # set -u when arrays may be empty (bash compat: empty array is unbound under -u).

    # Remove husks (safe in all non-dry-run modes)
    for wt_path in "${husks[@]+"${husks[@]}"}"; do
        # CWD safety: cd out before rm
        if [[ "$PWD" == "$wt_path"* ]]; then
            cd "$main_wt" || cd "$HOME"
        fi
        rm -rf "$wt_path" 2>/dev/null || true
        echo "Removed husk: $wt_path"
        removed_count=$((removed_count + 1))
        # Remove from registry if present
        if grep -qF "$wt_path" "$REGISTRY" 2>/dev/null; then
            grep -vF "$wt_path" "$REGISTRY" > "${REGISTRY}.tmp" || true
            mv "${REGISTRY}.tmp" "$REGISTRY"
        fi
    done

    # Remove orphans only in --confirm mode
    local orphan_count="${#orphans[@]}"
    if [[ "$mode" == "confirm" ]]; then
        for wt_path in "${orphans[@]+"${orphans[@]}"}"; do
            if [[ "$PWD" == "$wt_path"* ]]; then
                cd "$main_wt" || cd "$HOME"
            fi
            rm -rf "$wt_path" 2>/dev/null || true
            echo "Removed orphan: $wt_path"
            removed_count=$((removed_count + 1))
            if grep -qF "$wt_path" "$REGISTRY" 2>/dev/null; then
                grep -vF "$wt_path" "$REGISTRY" > "${REGISTRY}.tmp" || true
                mv "${REGISTRY}.tmp" "$REGISTRY"
            fi
        done
    elif [[ "$mode" == "auto" && "$orphan_count" -gt 0 ]]; then
        echo "WARN: $orphan_count orphan(s) with content skipped — re-run with --confirm to remove:"
        for p in "${orphans[@]+"${orphans[@]}"}"; do echo "  $p"; done
    fi

    # Auto-register unregistered git worktrees
    for wt_path in "${unregistered[@]+"${unregistered[@]}"}"; do
        if [[ -d "$wt_path" ]]; then
            cmd_register "$wt_path" 2>/dev/null || true
            echo "Registered: $wt_path"
            registered_count=$((registered_count + 1))
        fi
    done

    # Prune ghosts from registry
    local ghost_count="${#ghosts[@]}"
    if [[ "$ghost_count" -gt 0 ]]; then
        cmd_prune 2>/dev/null || true
        echo "Pruned $ghost_count ghost(s) from registry"
    fi

    # Clean empty .worktrees/ parent directory after last child deleted
    if [[ -d "$WORKTREE_DIR" ]] && [[ -z "$(ls -A "$WORKTREE_DIR" 2>/dev/null)" ]]; then
        rmdir "$WORKTREE_DIR" 2>/dev/null || true
        echo "Removed empty $WORKTREE_DIR"
    fi

    echo ""
    echo "Sweep complete: removed=$removed_count registered=$registered_count ghosts_pruned=$ghost_count"
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
    sweep)
        shift
        cmd_sweep "$@"
        ;;
    *)
        cat >&2 <<EOF
Usage: worktree-roster.sh <command> [options]

Commands:
  register <path> [--issue=N] [--session=ID]   Register a worktree
  list [--json]                                 List all worktrees with status
  stale                                         List stale worktrees (PID dead)
  cleanup [--dry-run] [--confirm] [--force]     Remove stale worktrees
  prune                                         Remove orphaned registry entries
  sweep [--dry-run|--auto|--confirm]            Three-way filesystem/git/registry reconciliation

Status types:
  active   - Lockfile present (<24h) or PID is alive
  stale    - PID is dead and no fresh lockfile; directory exists
  orphaned - Registry entry but directory gone

Sweep classifications:
  husk         - Empty dir, not in git worktree list — safe to auto-remove
  orphan       - Has content files, not in git worktree list — needs review
  unregistered - In git worktree list but not in roster — auto-register
  ghost        - In roster but directory doesn't exist — prune from registry
EOF
        exit 1
        ;;
esac
