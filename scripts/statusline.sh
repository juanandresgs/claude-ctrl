#!/usr/bin/env bash
# statusline.sh — Claude Code status line with enriched HUD segments.
#
# Purpose: Reads JSON from stdin (model, workspace, version), reads cached
# todo count and .statusline-cache, and outputs ANSI-formatted status line.
# Extracted from the inline command in settings.json for maintainability.
#
# @decision DEC-CACHE-002
# @title Status bar enrichment with cached hook data
# @status accepted
# @rationale Hooks compute git/plan/test state on every prompt and session start.
# Cache that data so the status bar can display rich context without re-computing.
# Segments show dirty count (red), worktrees (cyan), plan phase (blue/dim), test
# status (green/red/dim), active agents (yellow). Only shown when relevant (dirty>0, etc).
#
# Input (stdin): JSON with .model.display_name, .workspace.current_dir, .version
# Output (stdout): ANSI-formatted status line
#
# Segments: model | workspace | time | dirty (if >0) | worktrees (if >0) | plan | tests | agents (if >0) | todos (if >0) | version
set -euo pipefail

TODO_CACHE="$HOME/.claude/.todo-count"

# Read JSON from stdin
input=$(cat)

# Extract fields
model=$(echo "$input" | jq -r '.model.display_name')
workspace=$(basename "$(echo "$input" | jq -r '.workspace.current_dir')")
version=$(echo "$input" | jq -r '.version')
timestamp=$(date '+%H:%M:%S')

# Read cached todo count
todo_count=0
if [[ -f "$TODO_CACHE" ]]; then
    todo_count=$(cat "$TODO_CACHE" 2>/dev/null || echo 0)
    # Sanitize: ensure it's a number
    [[ "$todo_count" =~ ^[0-9]+$ ]] || todo_count=0
fi

# Read statusline cache
workspace_dir=$(echo "$input" | jq -r '.workspace.current_dir')
CACHE_FILE="$workspace_dir/.claude/.statusline-cache"
cache_dirty=0
cache_wt=0
cache_plan=""
cache_test=""
cache_agents=0
cache_agents_types=""
cache_agents_total=0
if [[ -f "$CACHE_FILE" ]]; then
    cache_dirty=$(jq -r '.dirty // 0' "$CACHE_FILE" 2>/dev/null || echo 0)
    cache_wt=$(jq -r '.worktrees // 0' "$CACHE_FILE" 2>/dev/null || echo 0)
    cache_plan=$(jq -r '.plan // ""' "$CACHE_FILE" 2>/dev/null || echo "")
    cache_test=$(jq -r '.test // ""' "$CACHE_FILE" 2>/dev/null || echo "")
    cache_agents=$(jq -r '.agents_active // 0' "$CACHE_FILE" 2>/dev/null || echo 0)
    cache_agents_types=$(jq -r '.agents_types // ""' "$CACHE_FILE" 2>/dev/null || echo "")
    cache_agents_total=$(jq -r '.agents_total // 0' "$CACHE_FILE" 2>/dev/null || echo 0)
fi

# Build status line
# Colors: dim=model, bold cyan=workspace, yellow=time, magenta=todos, green=version
# \033[2m = dim, \033[1;36m = bold cyan, \033[33m = yellow
# \033[35m = magenta, \033[32m = green, \033[0m = reset

sep='\033[2m│\033[0m'

line=$(printf '\033[2m%s\033[0m \033[1;36m%s\033[0m %b \033[33m%s\033[0m' \
    "$model" "$workspace" "$sep" "$timestamp")

# Git dirty (red, only if > 0)
if [[ "$cache_dirty" -gt 0 ]]; then
    line=$(printf '%s %b \033[31m%d dirty\033[0m' "$line" "$sep" "$cache_dirty")
fi

# Worktrees (cyan, only if > 0)
if [[ "$cache_wt" -gt 0 ]]; then
    line=$(printf '%s %b \033[36mWT:%d\033[0m' "$line" "$sep" "$cache_wt")
fi

# Plan phase (blue or dim)
if [[ -n "$cache_plan" && "$cache_plan" != "no plan" ]]; then
    line=$(printf '%s %b \033[34m%s\033[0m' "$line" "$sep" "$cache_plan")
elif [[ "$cache_plan" == "no plan" ]]; then
    line=$(printf '%s %b \033[2m%s\033[0m' "$line" "$sep" "$cache_plan")
fi

# Test status (green=pass, red=fail, dim=unknown)
if [[ "$cache_test" == "pass" ]]; then
    line=$(printf '%s %b \033[32m✓ tests\033[0m' "$line" "$sep" )
elif [[ "$cache_test" == "fail" ]]; then
    line=$(printf '%s %b \033[31m✗ tests\033[0m' "$line" "$sep")
fi

# Subagents (yellow, only if active > 0)
if [[ "$cache_agents" -gt 0 && -n "$cache_agents_types" ]]; then
    line=$(printf '%s %b \033[33m⚡%d agents (%s)\033[0m' "$line" "$sep" "$cache_agents" "$cache_agents_types")
elif [[ "$cache_agents" -gt 0 ]]; then
    line=$(printf '%s %b \033[33m⚡%d agents\033[0m' "$line" "$sep" "$cache_agents")
fi

# Add todo segment only if count > 0
if [[ "$todo_count" -gt 0 ]]; then
    local_s=""
    [[ "$todo_count" -ne 1 ]] && local_s="s"
    line=$(printf '%s %b \033[35m%d todo%s\033[0m' "$line" "$sep" "$todo_count" "$local_s")
fi

# Community segment (read from .community-status)
COMMUNITY_STATUS_FILE="$HOME/.claude/.community-status"
if [[ -f "$COMMUNITY_STATUS_FILE" ]]; then
    comm_status=$(jq -r '.status // "none"' "$COMMUNITY_STATUS_FILE" 2>/dev/null || echo "none")
    if [[ "$comm_status" == "active" ]]; then
        comm_prs=$(jq -r '.total_prs // 0' "$COMMUNITY_STATUS_FILE" 2>/dev/null || echo "0")
        comm_issues=$(jq -r '.total_issues // 0' "$COMMUNITY_STATUS_FILE" 2>/dev/null || echo "0")

        if [[ "$comm_prs" -gt 0 || "$comm_issues" -gt 0 ]]; then
            comm_text=""
            if [[ "$comm_prs" -gt 0 && "$comm_issues" -gt 0 ]]; then
                pr_s=""; [[ "$comm_prs" -ne 1 ]] && pr_s="s"
                issue_s=""; [[ "$comm_issues" -ne 1 ]] && issue_s="s"
                comm_text="${comm_prs} PR${pr_s} + ${comm_issues} issue${issue_s}"
            elif [[ "$comm_prs" -gt 0 ]]; then
                pr_s=""; [[ "$comm_prs" -ne 1 ]] && pr_s="s"
                comm_text="${comm_prs} PR${pr_s}"
            else
                issue_s=""; [[ "$comm_issues" -ne 1 ]] && issue_s="s"
                comm_text="${comm_issues} issue${issue_s}"
            fi
            # Use bold white (1;37m) to distinguish from magenta todos
            line=$(printf '%s %b \033[1;37m%s\033[0m' "$line" "$sep" "$comm_text")
        fi
    fi
fi

# Version
line=$(printf '%s %b \033[32m%s\033[0m' "$line" "$sep" "$version")

printf '%s' "$line"
