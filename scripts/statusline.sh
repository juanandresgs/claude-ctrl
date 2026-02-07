#!/usr/bin/env bash
# statusline.sh — Claude Code status line with todo HUD segment.
#
# Purpose: Reads JSON from stdin (model, workspace, version), reads cached
# todo count, and outputs ANSI-formatted status line. Extracted from the
# inline command in settings.json for maintainability.
#
# @decision External script over inline command — the inline one-liner in
# settings.json became unreadable when adding the todo segment. A script
# is testable, lintable, and extensible. Status: accepted.
#
# Input (stdin): JSON with .model.display_name, .workspace.current_dir, .version
# Output (stdout): ANSI-formatted status line
#
# Segments: model | workspace | time | todos (if >0) | version
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

# Build status line
# Colors: dim=model, bold cyan=workspace, yellow=time, magenta=todos, green=version
# \033[2m = dim, \033[1;36m = bold cyan, \033[33m = yellow
# \033[35m = magenta, \033[32m = green, \033[0m = reset

sep='\033[2m│\033[0m'

line=$(printf '\033[2m%s\033[0m \033[1;36m%s\033[0m %b \033[33m%s\033[0m' \
    "$model" "$workspace" "$sep" "$timestamp")

# Add todo segment only if count > 0
if [[ "$todo_count" -gt 0 ]]; then
    local_s=""
    [[ "$todo_count" -ne 1 ]] && local_s="s"
    line=$(printf '%s %b \033[35m%d todo%s\033[0m' "$line" "$sep" "$todo_count" "$local_s")
fi

# Version
line=$(printf '%s %b \033[32m%s\033[0m' "$line" "$sep" "$version")

printf '%s' "$line"
