#!/usr/bin/env bash
# statusline.sh — Rich ANSI HUD sourced from runtime snapshot and Claude Code stdin.
#
# Reads stdin JSON provided by Claude Code (model, workspace, version) and
# combines it with the cc-policy statusline snapshot (SQLite) to render a
# single-line ANSI-coloured HUD. Replaces the bare key:value interim version.
#
# Input:  stdin — Claude Code JSON with model/workspace/version fields
# Output: single-line ANSI HUD string, no trailing newline
#
# @decision DEC-SL-001
# @title Runtime-backed statusline renderer
# @status accepted
# @rationale All state comes from cc-policy statusline snapshot (SQLite).
#   stdin provides model/workspace/version from Claude Code. No flat files
#   except .todo-count (backlog #139 to migrate). Replaces the v2 bootstrap
#   cache-reading version AND the bare key:value interim version.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../hooks/lib/runtime-bridge.sh"

# Read stdin JSON from Claude Code
input=$(cat)
model=$(echo "$input" | jq -r '.model.display_name // "claude"')
workspace=$(basename "$(echo "$input" | jq -r '.workspace.current_dir // "."')")
version=$(echo "$input" | jq -r '.version // "?"')
workspace_dir=$(echo "$input" | jq -r '.workspace.current_dir // "."')
timestamp=$(date '+%H:%M:%S')

sep='\033[2m│\033[0m'

# Try runtime snapshot
SNAPSHOT=$(rt_statusline_snapshot 2>/dev/null) || SNAPSHOT=""

if [[ -n "$SNAPSHOT" ]] && echo "$SNAPSHOT" | jq -e '.status == "ok"' >/dev/null 2>&1; then
    proof=$(echo "$SNAPSHOT" | jq -r '.proof_status // "idle"')
    agent=$(echo "$SNAPSHOT" | jq -r '.active_agent // empty')
    wt_count=$(echo "$SNAPSHOT" | jq -r '.worktree_count // 0')
    dispatch=$(echo "$SNAPSHOT" | jq -r '.dispatch_status // empty')

    dirty=$(git -C "$workspace_dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

    # Base: model│workspace│time
    line=$(printf '\033[2m%s\033[0m \033[1;36m%s\033[0m %b \033[33m%s\033[0m' \
        "$model" "$workspace" "$sep" "$timestamp")

    # Dirty (red, if >0)
    [[ "$dirty" -gt 0 ]] && \
        line=$(printf '%s %b \033[31m%d dirty\033[0m' "$line" "$sep" "$dirty")

    # Worktrees (cyan, if >0)
    [[ "$wt_count" -gt 0 ]] && \
        line=$(printf '%s %b \033[36mWT:%d\033[0m' "$line" "$sep" "$wt_count")

    # Proof (green=verified, yellow=pending, skip idle)
    case "$proof" in
        verified) line=$(printf '%s %b \033[32m✓ proof\033[0m' "$line" "$sep") ;;
        pending)  line=$(printf '%s %b \033[33m⏳ proof\033[0m' "$line" "$sep") ;;
    esac

    # Active agent (yellow, if present)
    [[ -n "$agent" && "$agent" != "null" ]] && \
        line=$(printf '%s %b \033[33m⚡%s\033[0m' "$line" "$sep" "$agent")

    # Dispatch next (magenta, if pending)
    [[ -n "$dispatch" && "$dispatch" != "null" ]] && \
        line=$(printf '%s %b \033[35mnext:%s\033[0m' "$line" "$sep" "$dispatch")

    # Todos (magenta, if >0)
    TODO_CACHE="$HOME/.claude/.todo-count"
    if [[ -f "$TODO_CACHE" ]]; then
        tc=$(cat "$TODO_CACHE" 2>/dev/null || echo 0)
        [[ "$tc" =~ ^[0-9]+$ ]] || tc=0
        if [[ "$tc" -gt 0 ]]; then
            s=""; [[ "$tc" -ne 1 ]] && s="s"
            line=$(printf '%s %b \033[35m%d todo%s\033[0m' "$line" "$sep" "$tc" "$s")
        fi
    fi

    # Version (green)
    line=$(printf '%s %b \033[32m%s\033[0m' "$line" "$sep" "$version")

    printf '%s' "$line"
else
    # Fallback — no runtime
    line=$(printf '\033[2m%s\033[0m \033[1;36m%s\033[0m %b \033[33m%s\033[0m %b \033[32m%s\033[0m %b \033[2m(no runtime)\033[0m' \
        "$model" "$workspace" "$sep" "$timestamp" "$sep" "$version" "$sep")
    printf '%s' "$line"
fi
