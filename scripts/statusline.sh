#!/usr/bin/env bash
# statusline.sh — Claude Code two-line status HUD.
#
# Purpose: Reads JSON from stdin (model, workspace, cost, context window, tokens),
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
# Added: context window bar, cost (~$X.XX), duration (ms to human), lines
# changed, cache %, token count (tokens: Nk).
#
# @decision DEC-STATUSLINE-001
# @title Domain clustering for line 1 segments
# @status accepted
# @rationale Grouping related segments with explicit labels reduces cognitive
# load when scanning the statusline. Line 1 clusters: model+workspace ("where
# am I"), git state with dirty:/wt: labels ("repo state"), agents: with type
# list ("what work is active"), todos: count ("pending work"). Labels make
# numeric values unambiguous — "8 dirty" is less clear than "dirty: 8".
#
# @decision DEC-STATUSLINE-002
# @title Token count segment with K/M notation and usage-based color
# @status accepted
# @rationale Token consumption is a leading indicator of context pressure.
# Showing total tokens in K/M notation alongside the context bar gives the
# user an absolute number to complement the percentage bar. Color thresholds
# (dim <50k, default 50k-500k, yellow >500k) provide progressive warning
# without false alarm at low usage levels.
#
# Input (stdin): JSON with .model.display_name, .workspace.current_dir,
#   .cost.*, .context_window.*
# Output (stdout): Two ANSI-formatted lines (newline-separated)
#
# Line 1: model+workspace | dirty: N  wt: N | agents: N (types) | todos: N
# Line 2: context bar | tokens: Nk | ~$cost | duration | +lines/-lines | cache %
#
# @decision DEC-STATUSLINE-DEPS-001
# @title Statusline configuration dependency chain
# @status accepted
# @rationale Five runtime dependencies feed the statusline, audited 2026-03-02:
#   1. stdin JSON (12 fields) — written by Claude Code runtime, read by single jq call (line ~54)
#   2. .statusline-cache — written by write_statusline_cache() in session-lib.sh (6 hooks),
#      read for git dirty/worktrees, agents, todo split, lifetime cost. JSON schema.
#   3. .todo-count — written by todo.sh, read as legacy fallback only (Phase 2 split supersedes).
#      Plain text integer. No staleness guard (acceptable: fallback-only path).
#   4. .session-cost-history — written by session-end.sh, read by session-init.sh for lifetime
#      cost summation. Pipe-delimited: ts|cost|sid. Runtime data, never committed.
#   5. .subagent-tracker-* — written by track_subagent_start/stop(), read by get_subagent_status().
#      Line text: ACTIVE|type|epoch. Session-scoped, cleaned on exit.
#   Stale consumers removed: .community-status (dead), .worktree-roster.tsv (corrupt).
#   See also: DEC-CACHE-RESEARCH-001 (cache % semantics), DEC-TODO-SPLIT-002/003 (todo split).
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
  (.context_window.current_usage.cache_creation_input_tokens // 0 | tostring),
  ((.context_window.total_input_tokens // 0) + (.context_window.total_output_tokens // 0) | tostring)
] | join("\t")' 2>/dev/null || printf 'Claude\t\t\t0\t0\t0\t0\t-1\t0\t0\t0\t0')

IFS=$'\t' read -r model workspace workspace_dir cost_usd duration_ms \
  lines_add lines_rm ctx_pct cache_read input_tokens cache_create total_tokens <<< "$read_vars"

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
cache_todo_project=-1
cache_todo_global=-1
cache_lifetime_cost=0
cache_lifetime_tokens=0
cache_subagent_tokens=0
cache_initiative=""
cache_phase=""
cache_active_inits=0

if [[ -f "$CACHE_FILE" ]]; then
  cache_dirty=$(jq -r '.dirty // 0' "$CACHE_FILE" 2>/dev/null || echo 0)
  cache_wt=$(jq -r '.worktrees // 0' "$CACHE_FILE" 2>/dev/null || echo 0)
  cache_agents=$(jq -r '.agents_active // 0' "$CACHE_FILE" 2>/dev/null || echo 0)
  cache_agents_types=$(jq -r '.agents_types // ""' "$CACHE_FILE" 2>/dev/null || echo "")
  # @decision DEC-TODO-SPLIT-002
  # @title Read todo_project/todo_global from cache with -1 sentinel for absent fields
  # @status accepted
  # @rationale Cache fields may be absent on old cache files (backward compat). Using -1
  # as sentinel lets the todo segment detect "cache doesn't have split data" and fall back
  # to the legacy .todo-count file. When both fields are 0+ the split display takes over.
  cache_todo_project=$(jq -r 'if has("todo_project") then .todo_project else -1 end' "$CACHE_FILE" 2>/dev/null || echo -1)
  cache_todo_global=$(jq -r 'if has("todo_global") then .todo_global else -1 end' "$CACHE_FILE" 2>/dev/null || echo -1)
  cache_lifetime_cost=$(jq -r '.lifetime_cost // 0' "$CACHE_FILE" 2>/dev/null || echo 0)
  cache_lifetime_tokens=$(jq -r '.lifetime_tokens // 0' "$CACHE_FILE" 2>/dev/null || echo 0)
  cache_subagent_tokens=$(jq -r '.subagent_tokens // 0' "$CACHE_FILE" 2>/dev/null || echo 0)
  cache_initiative=$(jq -r '.initiative // ""' "$CACHE_FILE" 2>/dev/null || echo "")
  cache_phase=$(jq -r '.phase // ""' "$CACHE_FILE" 2>/dev/null || echo "")
  cache_active_inits=$(jq -r '.active_initiatives // 0' "$CACHE_FILE" 2>/dev/null || echo 0)
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

# format_tokens count — convert raw token count to K/M notation
# < 1000: raw (e.g. 500)
# 1000-999999: Nk (e.g. 145k)
# >= 1000000: N.NM (e.g. 1.5M)
format_tokens() {
  local count=$1
  # Ensure integer (strip decimals if any)
  count="${count%.*}"
  count=$(( count ))

  if   (( count >= 1000000 )); then
    # M notation with one decimal: count / 100000 gives tenths
    local tenths=$(( count / 100000 ))
    local whole=$(( tenths / 10 ))
    local frac=$(( tenths % 10 ))
    printf '%d.%dM' "$whole" "$frac"
  elif (( count >= 1000 )); then
    printf '%dk' "$(( count / 1000 ))"
  else
    printf '%d' "$count"
  fi
}

# ---------------------------------------------------------------------------
# Cache efficiency: cache_read / (input + cache_read + cache_create) * 100
# @decision DEC-CACHE-RESEARCH-001
# @title Prompt cache semantics and the cache % statusline segment
# @status accepted
# @rationale The cache % segment shows per-turn cache read ratio:
#   cache_read / (input + cache_read + cache_create) * 100.
# This fluctuates per-turn because:
#   - Cache key is cumulative hash of all previous blocks (tools → system → messages)
#   - 5-minute TTL (refreshed on hit), no cross-session persistence
#   - Conversation history grows monotonically → earlier turns always cache-hit
# What users CAN influence: CLAUDE.md stability (stable prefix → better cache hits).
# What users CANNOT influence: TTL, server-side eviction, cross-session persistence.
# The KV cache is server-side and ephemeral. A new session = cache miss on first call.
# Cache read pricing is 0.1x base (90% discount on Opus), so high cache % = cost savings.
# No code changes needed — the metric is correctly calculated and informative.
# ---------------------------------------------------------------------------
cache_efficiency=-1
total_input=$(( input_tokens + cache_read + cache_create ))
if (( total_input > 0 && cache_read > 0 )); then
  cache_efficiency=$(( cache_read * 100 / total_input ))
fi

# ---------------------------------------------------------------------------
# LINE 1: Project context — domain-clustered with labels
# ---------------------------------------------------------------------------

# Cluster A: Model + workspace
line1=$(printf '\033[2m%s\033[0m \033[1;36m%s\033[0m' "$model" "$workspace")

# Cluster A.5: Initiative context — shows active initiative name and current phase
# @decision DEC-STATUSLINE-003
# @title Initiative segment placement between workspace and git state
# @status accepted
# @rationale Placing the initiative segment immediately after workspace (Cluster A) groups
# "where am I / what am I working on" context together before git state. Initiative names
# are truncated to their first word when longer than 20 characters (e.g. "Backlog Auto-Capture"
# → "Backlog") to minimize statusline width impact. Phase is extracted as PN notation from
# "#### Phase N:" headers. When multiple initiatives are active, "+N" suffix shows the
# overflow count. The segment is omitted entirely when no active initiative exists, matching
# the conditional pattern used by other optional segments (agents, todos, dirty).
# Color: cyan (same as workspace segment) to visually link "context" clusters.
if [[ -n "$cache_initiative" ]]; then
  # Truncate initiative name: use first word if longer than 20 chars
  _init_display="$cache_initiative"
  if [[ ${#_init_display} -gt 20 ]]; then
    _init_display="${_init_display%% *}"
  fi

  # Extract phase number from "#### Phase N:" header → "PN"
  _phase_display=""
  if [[ -n "$cache_phase" ]]; then
    # Match digits after "Phase " in the header
    if [[ "$cache_phase" =~ Phase[[:space:]]([0-9]+) ]]; then
      _phase_display="P${BASH_REMATCH[1]}"
    fi
  fi

  # Build initiative display string
  _init_str="$_init_display"
  # Append +N suffix when multiple active initiatives (active_inits - 1 overflow)
  _extra_inits=$(( cache_active_inits - 1 ))
  if (( _extra_inits > 0 )); then
    _init_str="${_init_str}+${_extra_inits}"
  fi
  # Append phase if available
  if [[ -n "$_phase_display" ]]; then
    _init_str="${_init_str}:${_phase_display}"
  fi

  line1=$(printf '%s %b \033[36m%s\033[0m' "$line1" "$sep" "$_init_str")
fi

# Cluster B: Git state — dirty: N  wt: N (combined segment, only if either > 0)
if (( cache_dirty > 0 || cache_wt > 0 )); then
  git_parts=""
  if (( cache_dirty > 0 )); then
    git_parts=$(printf '\033[31mdirty: %d\033[0m' "$cache_dirty")
  fi
  if (( cache_wt > 0 )); then
    wt_str=$(printf '\033[36mwt: %d\033[0m' "$cache_wt")
    if [[ -n "$git_parts" ]]; then
      git_parts=$(printf '%s  %s' "$git_parts" "$wt_str")
    else
      git_parts="$wt_str"
    fi
  fi
  line1=$(printf '%s %b %s' "$line1" "$sep" "$git_parts")
fi

# Cluster C: Agents — agents: N (type1,type2), only if active > 0
if (( cache_agents > 0 )); then
  if [[ -n "$cache_agents_types" ]]; then
    line1=$(printf '%s %b \033[33magents: %d (%s)\033[0m' \
      "$line1" "$sep" "$cache_agents" "$cache_agents_types")
  else
    line1=$(printf '%s %b \033[33magents: %d\033[0m' "$line1" "$sep" "$cache_agents")
  fi
fi

# Cluster D: Todos — split display or legacy fallback
# @decision DEC-TODO-SPLIT-003
# @title Todo segment: split project/global display with legacy fallback
# @status accepted
# @rationale When cache has todo_project/todo_global fields (>= 0), show split format:
# "todos: 3p 7g" (both), "todos: 3p" (project only), "todos: 7g" (global only).
# 'p' and 'g' suffixes are dim; counts are magenta. When cache fields are absent
# (-1 sentinel), fall back to legacy .todo-count single number.
if (( cache_todo_project >= 0 || cache_todo_global >= 0 )); then
  # New split mode — use cache fields
  _tp=$(( cache_todo_project > 0 ? cache_todo_project : 0 ))
  _tg=$(( cache_todo_global > 0 ? cache_todo_global : 0 ))
  if (( _tp > 0 && _tg > 0 )); then
    line1=$(printf '%s %b \033[35mtodos: %d\033[2mp\033[0m\033[35m %d\033[2mg\033[0m' \
      "$line1" "$sep" "$_tp" "$_tg")
  elif (( _tp > 0 )); then
    line1=$(printf '%s %b \033[35mtodos: %d\033[2mp\033[0m' "$line1" "$sep" "$_tp")
  elif (( _tg > 0 )); then
    line1=$(printf '%s %b \033[35mtodos: %d\033[2mg\033[0m' "$line1" "$sep" "$_tg")
  fi
  # Both 0: no segment shown
elif (( todo_count > 0 )); then
  # Legacy fallback: single count from .todo-count
  line1=$(printf '%s %b \033[35mtodos: %d\033[0m' "$line1" "$sep" "$todo_count")
fi

# ---------------------------------------------------------------------------
# LINE 2: Session metrics
# ---------------------------------------------------------------------------

# Context bar (always shown)
line2=$(build_context_bar "$ctx_pct")

# Token count segment with subagent breakdown and project lifetime
# @decision DEC-LIFETIME-TOKENS-001
# @title Display token usage as: tks: Nk(+Sk) │ ΣTk — main, subagent, and project total
# @status accepted
# @rationale New format separates subagent contribution in-line (+Sk dim suffix) and
# places the project lifetime Σ as a distinct segment after a separator. This is more
# scannable than the previous (Σ) parenthetical: the eye lands on the current session
# total first, the subagent cost is a minor annotation, and the cumulative Σ only
# appears when there is genuine history (past sessions). The shorter "tks:" label saves
# horizontal space. Supersedes DEC-SUBAGENT-TOKENS-004 and the inline (Σ) from v1.
total_tokens_int="${total_tokens%.*}"
total_tokens_int=$(( total_tokens_int ))
tokens_str=$(format_tokens "$total_tokens_int")
if   (( total_tokens_int > 500000 )); then tokens_color="33"  # yellow
elif (( total_tokens_int > 50000  )); then tokens_color="0"   # default
else                                        tokens_color="2"   # dim
fi

# Resolve subagent and lifetime from already-loaded cache variables
cache_subagent_tokens_int="${cache_subagent_tokens%.*}"
cache_subagent_tokens_int=$(( ${cache_subagent_tokens_int:-0} ))
cache_lifetime_tokens_int="${cache_lifetime_tokens%.*}"
cache_lifetime_tokens_int=$(( ${cache_lifetime_tokens_int:-0} ))

# Build token display: tks: Nk  or  tks: Nk(+Sk)
if (( cache_subagent_tokens_int > 0 )); then
  subagent_str=$(format_tokens "$cache_subagent_tokens_int")
  tokens_display=$(printf '\033[%smtks: %s\033[2m(+%s)\033[0m' "$tokens_color" "$tokens_str" "$subagent_str")
else
  tokens_display=$(printf '\033[%smtks: %s\033[0m' "$tokens_color" "$tokens_str")
fi
line2=$(printf '%s %b %s' "$line2" "$sep" "$tokens_display")

# Project lifetime total as separate segment: Σ750k
# Only shown when there are past sessions (grand total > current session total).
_token_grand_total=$(( cache_lifetime_tokens_int + total_tokens_int + cache_subagent_tokens_int ))
if (( _token_grand_total > total_tokens_int + cache_subagent_tokens_int && _token_grand_total > 0 )); then
  grand_total_str=$(format_tokens "$_token_grand_total")
  line2=$(printf '%s %b \033[2mΣ%s\033[0m' "$line2" "$sep" "$grand_total_str")
fi

# Persist main session token count for session-end.sh to read as fallback.
# .session-main-tokens lets session-end capture the most recent token count even
# when the session-end JSON doesn't include context_window token fields.
# Written to the same .claude dir as the cache file, cleaned up by session-end.sh.
if [[ -n "${CACHE_FILE:-}" ]]; then
  printf '%d' "$total_tokens_int" > "${CACHE_FILE%/*}/.session-main-tokens" 2>/dev/null || true
fi

# Cost (always shown, ~$X.XX, green <$1, yellow $1-5, red >$5)
# If lifetime_cost > 0, show as: ~$0.53 (Σ~$12.40)
# @decision DEC-LIFETIME-COST-002
# @title Display lifetime cost as Σ annotation next to session cost
# @status accepted
# @rationale Appending lifetime cost as "(Σ~$N.NN)" after the session cost keeps the
# display compact and contextual — the user sees session cost at a glance and can
# recognize the running total from the Σ symbol. Dim rendering avoids visual noise.
# Σ = past sessions (cache_lifetime_cost) + current session (cost_usd), so the grand
# total is always accurate and never lower than the session cost shown beside it.
cost_int=${cost_usd%.*}  # integer part for threshold comparison
if   (( cost_int >= 5 )); then cost_color="31"
elif (( cost_int >= 1 )); then cost_color="33"
else                           cost_color="32"
fi
cost_display=$(printf '\033[%sm~$%.2f\033[0m' "$cost_color" "$cost_usd")
# Append lifetime sum if > 0: Σ = past sessions + current session
_lifetime_int="${cache_lifetime_cost%.*}"
_lifetime_int="${_lifetime_int:-0}"
if (( _lifetime_int > 0 )) 2>/dev/null; then
  _grand_cost=$(awk "BEGIN {printf \"%.2f\", $cache_lifetime_cost + $cost_usd}")
  cost_display=$(printf '%s \033[2m(Σ~$%s)\033[0m' "$cost_display" "$_grand_cost")
fi
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
