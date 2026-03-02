#!/usr/bin/env bash
# statusline.sh — Claude Code two-line status HUD.
#
# Purpose: Reads JSON from stdin (model, workspace, cost, context window),
# reads .statusline-cache for git/agent state, reads .todo-count for todos,
# and outputs two ANSI-formatted status lines separated by a newline.
#
# @decision DEC-CACHE-002
# @title Two-line status bar with session metrics on line 2
# @status accepted
# @rationale Single-line statuslines on wide monitors are hard to scan because
# project context and session metrics compete for the same horizontal space.
# Splitting into two lines gives each domain its own visual lane: line 1 is
# "where am I / what's happening", line 2 is "how much have I spent / is the
# context getting full". Removed: time (HH:MM:SS), plan phase, test status,
# community segment, version, worktree-roster stale detection (PID-based).
# Added: context window bar, cost, duration (ms to human), lines changed, cache %.
#
# Input (stdin): JSON with .model.display_name, .workspace.current_dir,
#   .cost.*, .context_window.*
# Output (stdout): Two ANSI-formatted lines (newline-separated)
#
# Line 1: model | workspace | dirty/WT (if any) | agents (if active) | todos (if any)
# Line 2: context bar | cost | duration | +lines/-lines (if any) | cache % (if any)
#
set -euo pipefail

TODO_CACHE="$HOME/.claude/.todo-count"

# ---------------------------------------------------------------------------
# Single jq call to extract all stdin fields as tab-separated values
# ---------------------------------------------------------------------------
input=$(cat)

read_vars=$(printf '%s' "$input" | jq -r '[
  (.model.display_name // "Claude"),
  (.workspace.current_dir // "" | split("/") | last),
  (.workspace.current_dir // ""),
  (.cost.total_cost_usd // 0 | tostring),
  (.cost.total_duration_ms // 0 | tostring),
  (.cost.total_lines_added // 0 | tostring),
  (.cost.total_lines_removed // 0 | tostring),
  (.context_window.used_percentage // -1 | tostring),
  (.context_window.current_usage.cache_read_input_tokens // 0 | tostring),
  (.context_window.current_usage.input_tokens // 0 | tostring),
  (.context_window.current_usage.cache_creation_input_tokens // 0 | tostring)
] | join("\t")' 2>/dev/null || printf 'Claude\t\t\t0\t0\t0\t0\t-1\t0\t0\t0')

IFS=$'\t' read -r model workspace workspace_dir cost_usd duration_ms \
  lines_add lines_rm ctx_pct cache_read input_tokens cache_create <<< "$read_vars"

# ---------------------------------------------------------------------------
# Read .statusline-cache (git state + agents)
# ---------------------------------------------------------------------------
CACHE_FILE="${workspace_dir:+$workspace_dir/.claude/.statusline-cache}"
# Fallback to home .claude if workspace_dir is empty
[[ -z "$workspace_dir" ]] && CACHE_FILE="$HOME/.claude/.statusline-cache"

cache_dirty=0
cache_wt=0
cache_agents=0
cache_agents_types=""

if [[ -f "$CACHE_FILE" ]]; then
  cache_dirty=$(jq -r '.dirty // 0' "$CACHE_FILE" 2>/dev/null || echo 0)
  cache_wt=$(jq -r '.worktrees // 0' "$CACHE_FILE" 2>/dev/null || echo 0)
  cache_agents=$(jq -r '.agents_active // 0' "$CACHE_FILE" 2>/dev/null || echo 0)
  cache_agents_types=$(jq -r '.agents_types // ""' "$CACHE_FILE" 2>/dev/null || echo "")
fi

# ---------------------------------------------------------------------------
# Read todo count
# ---------------------------------------------------------------------------
todo_count=0
if [[ -f "$TODO_CACHE" ]]; then
  todo_count=$(cat "$TODO_CACHE" 2>/dev/null || echo 0)
  [[ "$todo_count" =~ ^[0-9]+$ ]] || todo_count=0
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
sep='\033[2m│\033[0m'

# build_context_bar pct — render 12-char progress bar with color
build_context_bar() {
  local pct=$1

  if [[ "$pct" == "-1" || "$pct" == "" ]]; then
    # Before first API call: all-empty bar, dim
    printf '\033[2m[░░░░░░░░░░░░] --\033[0m'
    return
  fi

  # Truncate any decimal portion from jq (e.g. "42.5" -> "42")
  local pct_int="${pct%.*}"
  # Clamp 0-100
  (( pct_int < 0 )) && pct_int=0
  (( pct_int > 100 )) && pct_int=100

  local filled=$(( pct_int * 12 / 100 ))
  local empty=$(( 12 - filled ))

  local bar_fill="" bar_empty="" i
  for (( i=0; i<filled; i++ )); do bar_fill+="█"; done
  for (( i=0; i<empty;  i++ )); do bar_empty+="░"; done

  local color
  if   (( pct_int >= 90 )); then color="1;31"
  elif (( pct_int >= 75 )); then color="31"
  elif (( pct_int >= 50 )); then color="33"
  else                           color="32"
  fi

  printf '\033[%sm[%s%s] %d%%\033[0m' "$color" "$bar_fill" "$bar_empty" "$pct_int"
}

# format_duration ms — convert milliseconds to human-readable string
format_duration() {
  local ms=$1
  local secs=$(( ms / 1000 ))
  local mins=$(( secs / 60 ))
  local hours=$(( mins / 60 ))
  local rem_mins=$(( mins % 60 ))

  if   (( hours > 0 )); then printf '%dh %dm' "$hours" "$rem_mins"
  elif (( mins  > 0 )); then printf '%dm' "$mins"
  else                       printf '<1m'
  fi
}

# ---------------------------------------------------------------------------
# Cache efficiency: cache_read / (input + cache_read + cache_create) * 100
# ---------------------------------------------------------------------------
cache_efficiency=-1
total_input=$(( input_tokens + cache_read + cache_create ))
if (( total_input > 0 && cache_read > 0 )); then
  cache_efficiency=$(( cache_read * 100 / total_input ))
fi

# ---------------------------------------------------------------------------
# LINE 1: Project context
# ---------------------------------------------------------------------------
line1=$(printf '\033[2m%s\033[0m \033[1;36m%s\033[0m' "$model" "$workspace")

# Dirty + WT (combined segment)
if (( cache_dirty > 0 || cache_wt > 0 )); then
  dirty_part="" wt_part=""
  (( cache_dirty > 0 )) && dirty_part=$(printf '\033[31m%d dirty\033[0m' "$cache_dirty")
  (( cache_wt    > 0 )) && wt_part=$(printf '\033[36mWT:%d\033[0m' "$cache_wt")

  if [[ -n "$dirty_part" && -n "$wt_part" ]]; then
    line1=$(printf '%s %b %s  %s' "$line1" "$sep" "$dirty_part" "$wt_part")
  elif [[ -n "$dirty_part" ]]; then
    line1=$(printf '%s %b %s' "$line1" "$sep" "$dirty_part")
  else
    line1=$(printf '%s %b %s' "$line1" "$sep" "$wt_part")
  fi
fi

# Agents (yellow, only if active > 0)
if (( cache_agents > 0 )); then
  if [[ -n "$cache_agents_types" ]]; then
    line1=$(printf '%s %b \033[33m⚡%d agents (%s)\033[0m' \
      "$line1" "$sep" "$cache_agents" "$cache_agents_types")
  else
    line1=$(printf '%s %b \033[33m⚡%d agents\033[0m' "$line1" "$sep" "$cache_agents")
  fi
fi

# Todos (magenta, only if count > 0)
if (( todo_count > 0 )); then
  line1=$(printf '%s %b \033[35m%d todos\033[0m' "$line1" "$sep" "$todo_count")
fi

# ---------------------------------------------------------------------------
# LINE 2: Session metrics
# ---------------------------------------------------------------------------

# Context bar (always shown)
line2=$(build_context_bar "$ctx_pct")

# Cost (always shown, green <$1, yellow $1-5, red >$5)
cost_int=${cost_usd%.*}  # integer part for threshold comparison
if   (( cost_int >= 5 )); then cost_color="31"
elif (( cost_int >= 1 )); then cost_color="33"
else                           cost_color="32"
fi
cost_display=$(printf '\033[%sm$%.2f\033[0m' "$cost_color" "$cost_usd")
line2=$(printf '%s %b %s' "$line2" "$sep" "$cost_display")

# Duration (always shown, dim)
duration_display=$(format_duration "$duration_ms")
line2=$(printf '%s %b \033[2m%s\033[0m' "$line2" "$sep" "$duration_display")

# Lines changed (conditional: only if added + removed > 0)
total_lines=$(( lines_add + lines_rm ))
if (( total_lines > 0 )); then
  lines_display=$(printf '\033[32m+%d\033[0m/\033[31m-%d\033[0m' "$lines_add" "$lines_rm")
  line2=$(printf '%s %b %s' "$line2" "$sep" "$lines_display")
fi

# Cache efficiency (conditional: only if cache tokens > 0)
if (( cache_efficiency >= 0 )); then
  if   (( cache_efficiency >= 60 )); then cache_color="32"
  elif (( cache_efficiency >= 30 )); then cache_color="33"
  else                                    cache_color="2"
  fi
  line2=$(printf '%s %b \033[%smcache %d%%\033[0m' \
    "$line2" "$sep" "$cache_color" "$cache_efficiency")
fi

# ---------------------------------------------------------------------------
# Output: two lines separated by newline
# ---------------------------------------------------------------------------
printf '%s\n%s' "$line1" "$line2"
