#!/usr/bin/env bash
# statusline.sh — Claude Code 3-line status bar with per-line ANSI-aware truncation.
#
# Purpose: Reads JSON from stdin (model, workspace, cost, context window, tokens),
# reads .statusline-cache-<SESSION_ID> for git/agent state, reads .todo-count for todos,
# and outputs 2-3 ANSI-formatted lines, each independently truncated to terminal width.
#
# @decision DEC-CACHE-002
# @title Three-line status bar: metrics (Line 1) + project context (Line 2) + initiative banner (Line 3)
# @status accepted
# @rationale Single-line statuslines on wide monitors are hard to scan because
# project context and session metrics compete for the same horizontal space.
# Splitting into lines gives each domain its own visual lane:
#   Line 1 (metrics): model, context bar, tokens, cost, duration, lines, cache %
#   Line 2 (project): workspace, git state, agents, todos
#   Line 3 (initiative highlight bar, conditional): bold cyan banner at the bottom
# Line 3 is omitted when no active initiative exists so the display stays 2 lines
# for idle/non-plan sessions. Each line independently truncates with "..." at
# terminal width — no single-line compromise needed.
# Removed: time (HH:MM:SS), plan phase inline segment, test status, community
# segment, version, worktree-roster stale detection (PID-based).
# Added: context window bar, cost (~$X.XX), duration (ms to human), lines
# changed, cache %, token count (tokens: Nk), initiative highlight bar (bottom).
#
# @decision DEC-STATUSLINE-001
# @title Domain clustering for project-context line (Line 2) segments
# @status accepted
# @rationale Grouping related segments with explicit labels reduces cognitive
# load when scanning the statusline. Line 2 clusters: workspace ("where am I"),
# git state with dirty:/wt: labels ("repo state"), agents: with type list
# ("what work is active"), todos: count ("pending work"). Labels make numeric
# values unambiguous — "8 dirty" is less clear than "dirty: 8". Model display
# name moved to Line 1 (metrics line) so the project line stays workspace-focused.
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
# Output (stdout): 2-3 ANSI-formatted lines, each truncated to terminal width with ...
#
# Line layout (top to bottom):
#   Line 1 (metrics):  model │ [context bar] │ tks: Nk │ ~$cost │ duration │ +lines/-lines │ cache %
#   Line 2 (project):  workspace │ dirty: N  wt: N │ agents: N (types) │ todos: Np Ng
#   Line 3 (highlight bar, conditional): Initiative Name (Phase N/M): Phase Title  ← bold cyan, bottom
#
# @decision DEC-STATUSLINE-DEPS-001
# @title Statusline configuration dependency chain
# @status accepted
# @rationale Five runtime dependencies feed the statusline, audited 2026-03-02:
#   1. stdin JSON (12 fields) — written by Claude Code runtime, read by single jq call (line ~54)
#   2. .statusline-cache-<SESSION_ID> — written by write_statusline_cache() in session-lib.sh (6 hooks),
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

# _file_mtime FILE — cross-platform mtime (Linux-first; mirrors core-lib.sh)
# Defined locally because statusline.sh is standalone (no source-lib.sh).
_file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

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
CACHE_FILE="${workspace_dir:+$workspace_dir/.claude/.statusline-cache-${CLAUDE_SESSION_ID:-$$}}"
# Fallback to home .claude if workspace_dir is empty
[[ -z "$workspace_dir" ]] && CACHE_FILE="$HOME/.claude/.statusline-cache-${CLAUDE_SESSION_ID:-$$}"

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
cache_total_phases=0

# @decision DEC-TODO-SPLIT-002
# @title Read todo_project/todo_global from cache with -1 sentinel for absent fields
# @status accepted
# @rationale Cache fields may be absent on old cache files (backward compat). Using -1
# as sentinel lets the todo segment detect "cache doesn't have split data" and fall back
# to the legacy .todo-count file. When both fields are 0+ the split display takes over.
# Consolidated into a single jq call (was 13 separate subprocess invocations) to reduce
# ~100ms startup latency and eliminate per-field variable subprocess overhead.
if [[ -f "$CACHE_FILE" ]]; then
  # Use ASCII unit separator (\u001f / \x1f) as delimiter — unlike tab, it is not a
  # bash whitespace IFS character, so consecutive empty fields (e.g. agents_types="")
  # are preserved correctly by `read -r`. Tab IFS collapses adjacent delimiters.
  cache_vars=$(jq -r '[
    (.dirty // 0 | tostring),
    (.worktrees // 0 | tostring),
    (.agents_active // 0 | tostring),
    (.agents_types // ""),
    (if has("todo_project") then .todo_project else -1 end | tostring),
    (if has("todo_global") then .todo_global else -1 end | tostring),
    (.lifetime_cost // 0 | tostring),
    (.lifetime_tokens // 0 | tostring),
    (.subagent_tokens // 0 | tostring),
    (.initiative // ""),
    (.phase // ""),
    (.active_initiatives // 0 | tostring),
    (.total_phases // 0 | tostring)
  ] | join("\u001f")' "$CACHE_FILE" 2>/dev/null \
    || printf '0\x1f0\x1f0\x1f\x1f-1\x1f-1\x1f0\x1f0\x1f0\x1f\x1f\x1f0\x1f0')
  IFS=$'\x1f' read -r cache_dirty cache_wt cache_agents cache_agents_types \
    cache_todo_project cache_todo_global cache_lifetime_cost cache_lifetime_tokens \
    cache_subagent_tokens cache_initiative cache_phase \
    cache_active_inits cache_total_phases <<< "$cache_vars"
fi

# ---------------------------------------------------------------------------
# Read todo count (legacy fallback — superseded by cache split display)
# .todo-count format: "proj|glob" (written by session-init.sh cache-first path).
# For the legacy single-number fallback, read field 1 (proj count).
# ---------------------------------------------------------------------------
todo_count=0
if [[ -f "$TODO_CACHE" ]]; then
  _raw_todo=$(cat "$TODO_CACHE" 2>/dev/null || echo 0)
  # Support both plain integer (old format) and pipe-delimited proj|glob (new format)
  todo_count=$(printf '%s' "$_raw_todo" | cut -d'|' -f1)
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

# truncate_ansi str max_width — truncate ANSI string to fit terminal width
# @decision DEC-STATUSLINE-004
# @title Per-line ANSI-aware truncation for 3-line status bar
# @status accepted
# @rationale Each of the 3 output lines is independently truncated to terminal width
# using this function. Truncation must skip escape sequences when counting visible
# characters to avoid breaking ANSI codes or misreporting width. awk is used for
# the slow path to avoid O(n²) bash string concatenation on wide terminals with
# many segments. Supersedes the single-line truncation approach (DEC-CACHE-002 v1).
truncate_ansi() {
  local str="$1" max_w="$2"
  # Fast path: strip ANSI, check if it fits
  local stripped
  stripped=$(printf '%s' "$str" | sed $'s/\033\[[0-9;]*m//g')
  if (( ${#stripped} <= max_w )); then
    printf '%s' "$str"
    return
  fi
  # Slow path: ANSI-aware truncation via awk
  printf '%s\n' "$str" | awk -v t="$(( max_w - 3 ))" '{
    v = 0; e = 0; n = length($0)
    for (i = 1; i <= n; i++) {
      c = substr($0, i, 1)
      if (c == "\033") { e = 1; printf "%s", c }
      else if (e) { printf "%s", c; if (c == "m") e = 0 }
      else { if (v >= t) { printf "\033[0m..."; exit } printf "%s", c; v++ }
    }
  }'
}

# ansi_visible_width str — count visible characters, skipping ANSI escape sequences.
# @decision DEC-RESPONSIVE-001
# @title Pure-bash ANSI width counter for responsive segment dropping
# @status accepted
# @rationale Responsive layout needs per-segment width to decide which segments to drop.
# A sed-subshell per segment adds ~5ms each; with 8 segments on Line 2 that's 40ms.
# Pure-bash character loop adds ~0ms. The function sets the result in the global
# _AVW (ansi_visible_width result) to avoid a subshell. Caller must read _AVW
# immediately after calling ansi_visible_width because it is overwritten on next call.
# Bash 3.2 compatible: no associative arrays, no namerefs.
_AVW=0
ansi_visible_width() {
  local s="$1"
  local n=${#s} i in_esc=0 w=0 c
  for (( i=0; i<n; i++ )); do
    c="${s:$i:1}"
    if (( in_esc )); then
      [[ "$c" == "m" ]] && in_esc=0
    elif [[ "$c" == $'\033' ]]; then
      in_esc=1
    else
      (( w++ )) || true
    fi
  done
  _AVW=$w
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
# LINE 3 (bottom): Initiative highlight bar (conditional — only when active initiative exists)
# @decision DEC-STATUSLINE-003
# @title Full initiative banner as bottom highlight bar (Line 3)
# @status accepted
# @rationale The former inline Cluster A.5 segment showed a cryptic "Robust+1:P0"
# label that required mental decoding. Rendering the initiative as a dedicated
# bottom highlight bar (Line 3) lets the full initiative name and phase title
# be shown without truncation pressure from other segments. It anchors visually
# at the bottom of the status display — the eye naturally reads top-to-bottom,
# so "metrics → project → what I'm working on" follows a logical information
# hierarchy. Format: "Initiative Name (Phase N/M): Phase Title" where N/M is
# the current/total phase count and the title uses em dashes for readability
# (-- in MASTER_PLAN.md → — in display). When no active initiative exists,
# Line 3 is omitted and output stays 2 lines (backward compatible).
# When multiple initiatives are active, "(+N more)" suffix is appended.
# Color: bold cyan — visually prominent but not alarming.
# ---------------------------------------------------------------------------
line0=""
if [[ -n "$cache_initiative" ]]; then
  _banner="$cache_initiative"

  # Extract phase number and title from "#### Phase N: Title -- Subtitle"
  # Detect "(planned)" fallback marker appended by plan-lib.sh when no in-progress phase exists.
  # @decision DEC-STATUSLINE-PLANNED-PHASE-001
  # @title Planned-phase banner fallback rendering
  # @status accepted
  # @rationale When all phases are planned (none in-progress), plan-lib.sh appends " (planned)"
  # to the phase string so the banner can still show phase context. We strip the marker before
  # parsing, then re-inject it as a dim "[planned]" label in the rendered line0.
  if [[ -n "$cache_phase" ]]; then
    _phase_planned=false
    _phase_str="$cache_phase"
    # COUPLING: the " (planned)" suffix is emitted by plan-lib.sh get_plan_status()
    # (hooks/plan-lib.sh ~line 191). If you change that marker, update this detection too.
    if [[ "$_phase_str" == *"(planned)" ]]; then
      _phase_planned=true
      _phase_str="${_phase_str% (planned)}"
    fi

    if [[ "$_phase_str" =~ Phase[[:space:]]([0-9]+):[[:space:]]*(.*) ]]; then
      _phase_num="${BASH_REMATCH[1]}"
      _phase_title="${BASH_REMATCH[2]}"
      # Strip leading #### prefix if present (e.g. "#### Phase 0: Title")
      _phase_title="${_phase_title## }"
      _phase_title="${_phase_title%% }"
      # Replace -- with — (em dash) for display
      _phase_title="${_phase_title//--/—}"

      _banner="${_banner} (Phase ${_phase_num}/${cache_total_phases}): ${_phase_title}"
    fi
  fi

  # If multiple active initiatives, note the overflow
  _extra=$(( cache_active_inits - 1 ))
  if (( _extra > 0 )); then
    _banner="${_banner}  (+${_extra} more)"
  fi

  if [[ "${_phase_planned:-false}" == "true" ]]; then
    line0=$(printf '\033[1;36m%s \033[2m[planned]\033[0m' "$_banner")
  else
    line0=$(printf '\033[1;36m%s\033[0m' "$_banner")
  fi
fi

# Terminal width — must be resolved before the responsive layout sections below.
# @decision DEC-STATUSLINE-TERMWIDTH-002
# @title Clamp small COLUMNS to 120 — let Claude Code UI handle final clipping
# @status accepted
# @rationale Claude Code provides COLUMNS for the statusline display area, but small
# values (including 0 from subprocess context) cause aggressive responsive dropping that
# removes useful segments. At term_w=120 the full metrics line (~94 chars) fits with zero
# drops. Display order already puts most-important segments first (context bar → tks →
# cost), so natural UI clipping shows the best content when the area is narrow.
term_w="${COLUMNS:-0}"
(( term_w < 80 )) && term_w=120
(( term_w > 200 )) && term_w=200

# ---------------------------------------------------------------------------
# LINE 2 (project): Workspace + git + agents + todos
# Responsive layout: build segments as parallel arrays, drop lowest priority
# segments first when total width exceeds terminal width.
#
# Priority table (lower number = higher priority, dropped last):
#   1 = workspace (always shown)
#   2 = dirty: N
#   3 = wt: N
#   4 = agents: N (types)
#   5 = todos: Np Ng  (drops first)
# ---------------------------------------------------------------------------

# Build project line segments into parallel arrays (bash 3.2 compat, no namerefs)
_p1_count=0

# --- Segment P1.1: workspace (priority 1) ---
_s=$(printf '\033[1;36m%s\033[0m' "$workspace")
ansi_visible_width "$_s"; _p1_w_0=$_AVW; _p1_t_0="$_s"; _p1_p_0=1
_p1_count=1

# --- Segment P1.2: dirty (priority 2, conditional) ---
_p1_t_1=""; _p1_w_1=0; _p1_p_1=2
if (( cache_dirty > 0 )); then
  _s=$(printf '\033[31mdirty: %d\033[0m' "$cache_dirty")
  ansi_visible_width "$_s"; _p1_w_1=$_AVW; _p1_t_1="$_s"
fi
_p1_count=2

# --- Segment P1.3: wt (priority 3, conditional) ---
_p1_t_2=""; _p1_w_2=0; _p1_p_2=3
if (( cache_wt > 0 )); then
  _s=$(printf '\033[36mwt: %d\033[0m' "$cache_wt")
  ansi_visible_width "$_s"; _p1_w_2=$_AVW; _p1_t_2="$_s"
fi
_p1_count=3

# --- Segment P1.4: agents (priority 4, conditional) ---
# @decision DEC-AGENT-PROGRESS-001
# @title Enriched agent progress segment: type + elapsed + file count + current file
# @status accepted
# @rationale The generic "agents: 1 (implementer)" gave no insight into agent progress
# during long-running foreground agents (max_turns=85, potentially 40+ minutes). The
# enriched format "impl 8m 5f guard.sh" shows agent type abbreviation, elapsed time,
# files touched count, and current file basename — all derived from existing on-disk
# state files with no new hooks needed. Data sources: .subagent-tracker-* (elapsed),
# .session-changes-* (file count), .agent-progress (current file, written by post-write.sh).
_p1_t_3=""; _p1_w_3=0; _p1_p_3=4
if (( cache_agents > 0 )); then
  # Read subagent tracker for elapsed time and type
  _agent_type="" _agent_elapsed=""
  _tracker_file="${workspace_dir:+$workspace_dir/.claude/.subagent-tracker-${CLAUDE_SESSION_ID:-$$}}"
  [[ -z "$workspace_dir" ]] && _tracker_file="$HOME/.claude/.subagent-tracker-${CLAUDE_SESSION_ID:-$$}"
  if [[ -f "$_tracker_file" ]]; then
    _active_line=$(grep '^ACTIVE|' "$_tracker_file" 2>/dev/null | head -1)
    if [[ -n "$_active_line" ]]; then
      _agent_type=$(echo "$_active_line" | cut -d'|' -f2)
      _start_epoch=$(echo "$_active_line" | cut -d'|' -f3)
      if [[ "$_start_epoch" =~ ^[0-9]+$ ]]; then
        _now=$(date +%s)
        _elapsed_s=$(( _now - _start_epoch ))
        _elapsed_m=$(( _elapsed_s / 60 ))
        if (( _elapsed_m >= 60 )); then
          _agent_elapsed="$(( _elapsed_m / 60 ))h$(( _elapsed_m % 60 ))m"
        elif (( _elapsed_m > 0 )); then
          _agent_elapsed="${_elapsed_m}m"
        else
          _agent_elapsed="<1m"
        fi
      fi
    fi
  fi

  # Abbreviate agent type
  _type_abbr=""
  case "$_agent_type" in
    implementer) _type_abbr="impl" ;;
    tester)      _type_abbr="test" ;;
    guardian)     _type_abbr="guard" ;;
    planner)     _type_abbr="plan" ;;
    *)           _type_abbr="${_agent_type:0:4}" ;;
  esac

  # Read file count from .session-changes-*
  _file_count=""
  _changes_file="${workspace_dir:+$workspace_dir/.claude/.session-changes-${CLAUDE_SESSION_ID:-$$}}"
  [[ -z "$workspace_dir" ]] && _changes_file="$HOME/.claude/.session-changes-${CLAUDE_SESSION_ID:-$$}"
  if [[ -f "$_changes_file" ]]; then
    _fc=$(wc -l < "$_changes_file" 2>/dev/null | tr -d ' ')
    [[ "${_fc:-0}" -gt 0 ]] && _file_count="${_fc}f"
  fi

  # Read current file from .agent-progress (stale guard: ignore if >30min old)
  _current_file=""
  _progress_file="${workspace_dir:+$workspace_dir/.claude/.agent-progress}"
  [[ -z "$workspace_dir" ]] && _progress_file="$HOME/.claude/.agent-progress"
  if [[ -f "$_progress_file" ]]; then
    _progress_mtime=$(_file_mtime "$_progress_file")
    _now=${_now:-$(date +%s)}
    if (( _now - _progress_mtime < 1800 )); then
      _current_file=$(basename "$(cat "$_progress_file" 2>/dev/null)" 2>/dev/null || echo "")
    fi
  fi

  # Build enriched segment: "impl 8m 5f guard.sh"
  if [[ -n "$_type_abbr" && -n "$_agent_elapsed" ]]; then
    _s=$(printf '\033[33m%s\033[0m \033[2m%s\033[0m' "$_type_abbr" "$_agent_elapsed")
    [[ -n "$_file_count" ]] && _s=$(printf '%s %s' "$_s" "$_file_count")
    [[ -n "$_current_file" ]] && _s=$(printf '%s \033[36m%s\033[0m' "$_s" "$_current_file")
  elif [[ -n "$cache_agents_types" ]]; then
    _s=$(printf '\033[33magents: %d (%s)\033[0m' "$cache_agents" "$cache_agents_types")
  else
    _s=$(printf '\033[33magents: %d\033[0m' "$cache_agents")
  fi
  ansi_visible_width "$_s"; _p1_w_3=$_AVW; _p1_t_3="$_s"
fi
_p1_count=4

# --- Segment P1.5: todos (priority 5, drops first) ---
# @decision DEC-TODO-SPLIT-003
# @title Todo segment: split project/global display with legacy fallback
# @status accepted
# @rationale When cache has todo_project/todo_global fields (>= 0), show split format:
# "todos: 3p 7g" (both), "todos: 3p" (project only), "todos: 7g" (global only).
# 'p' and 'g' suffixes are dim; counts are magenta. When cache fields are absent
# (-1 sentinel), fall back to legacy .todo-count single number.
_p1_t_4=""; _p1_w_4=0; _p1_p_4=5
if (( cache_todo_project >= 0 || cache_todo_global >= 0 )); then
  _tp=$(( cache_todo_project > 0 ? cache_todo_project : 0 ))
  _tg=$(( cache_todo_global > 0 ? cache_todo_global : 0 ))
  if (( _tp > 0 && _tg > 0 )); then
    _s=$(printf '\033[35mtodos: %d\033[2mp\033[0m\033[35m %d\033[2mg\033[0m' "$_tp" "$_tg")
    ansi_visible_width "$_s"; _p1_w_4=$_AVW; _p1_t_4="$_s"
  elif (( _tp > 0 )); then
    _s=$(printf '\033[35mtodos: %d\033[2mp\033[0m' "$_tp")
    ansi_visible_width "$_s"; _p1_w_4=$_AVW; _p1_t_4="$_s"
  elif (( _tg > 0 )); then
    _s=$(printf '\033[35mtodos: %d\033[2mg\033[0m' "$_tg")
    ansi_visible_width "$_s"; _p1_w_4=$_AVW; _p1_t_4="$_s"
  fi
elif (( todo_count > 0 )); then
  _s=$(printf '\033[35mtodos: %d\033[0m' "$todo_count")
  ansi_visible_width "$_s"; _p1_w_4=$_AVW; _p1_t_4="$_s"
fi
_p1_count=5

# --- Responsive drop loop for Line 2 ---
# Count visible segments (non-empty text), compute total width with separators.
# Separator " │ " = 3 visible chars. Drop from priority 5 down until it fits.
_p1_drop_0=0; _p1_drop_1=0; _p1_drop_2=0; _p1_drop_3=0; _p1_drop_4=0

_compute_p1_width() {
  local total=0 seg_count=0
  [[ $_p1_drop_0 -eq 0 && -n "$_p1_t_0" ]] && total=$(( total + _p1_w_0 )) && (( seg_count++ )) || true
  [[ $_p1_drop_1 -eq 0 && -n "$_p1_t_1" ]] && total=$(( total + _p1_w_1 )) && (( seg_count++ )) || true
  [[ $_p1_drop_2 -eq 0 && -n "$_p1_t_2" ]] && total=$(( total + _p1_w_2 )) && (( seg_count++ )) || true
  [[ $_p1_drop_3 -eq 0 && -n "$_p1_t_3" ]] && total=$(( total + _p1_w_3 )) && (( seg_count++ )) || true
  [[ $_p1_drop_4 -eq 0 && -n "$_p1_t_4" ]] && total=$(( total + _p1_w_4 )) && (( seg_count++ )) || true
  # Each separator between adjacent segments is 3 chars
  (( seg_count > 1 )) && total=$(( total + (seg_count - 1) * 3 )) || true
  _P1_TOTAL=$total
}

_P1_TOTAL=0
_compute_p1_width
# Drop from max priority (5) down to 2; never drop workspace (priority 1)
# Use [[ ]] for string non-empty check, (( )) for numeric comparison
if (( _P1_TOTAL > term_w )) && [[ -n "$_p1_t_4" ]]; then _p1_drop_4=1; _compute_p1_width; fi
if (( _P1_TOTAL > term_w )) && [[ -n "$_p1_t_3" ]]; then _p1_drop_3=1; _compute_p1_width; fi
if (( _P1_TOTAL > term_w )) && [[ -n "$_p1_t_2" ]]; then _p1_drop_2=1; _compute_p1_width; fi
if (( _P1_TOTAL > term_w )) && [[ -n "$_p1_t_1" ]]; then _p1_drop_1=1; _compute_p1_width; fi

# Assemble Line 2 from remaining segments
line1=""
_p1_first=1
_append_p1_seg() {
  local txt="$1"
  [[ -z "$txt" ]] && return
  if (( _p1_first )); then
    line1="$txt"
    _p1_first=0
  else
    line1=$(printf '%s %b %s' "$line1" "$sep" "$txt")
  fi
}
[[ $_p1_drop_0 -eq 0 ]] && _append_p1_seg "$_p1_t_0"
[[ $_p1_drop_1 -eq 0 ]] && _append_p1_seg "$_p1_t_1"
[[ $_p1_drop_2 -eq 0 ]] && _append_p1_seg "$_p1_t_2"
[[ $_p1_drop_3 -eq 0 ]] && _append_p1_seg "$_p1_t_3"
[[ $_p1_drop_4 -eq 0 ]] && _append_p1_seg "$_p1_t_4"

# ---------------------------------------------------------------------------
# LINE 1 (metrics): Model + context bar + tokens + cost + duration + lines + cache
# Responsive layout: build segments as parallel arrays, drop lowest priority
# segments first when total width exceeds terminal width.
#
# Priority table (lower number = higher priority, dropped last):
#   1 = [context bar] N%     (drives user behavior)
#   2 = tks: Nk(+Sk)        (token consumption)
#   3 = ~$cost (Σ~$total)   (cost with lifetime)
#   4 = ΣNk lifetime tokens  (cumulative across sessions)
#   5 = model name           (usually known, nice-to-have)
#   6 = cache N%             (efficiency metric)
#   7 = duration             (session time)
#   8 = +N/-N lines          (drops first)
# ---------------------------------------------------------------------------

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

# Persist main session token count for session-end.sh to read as fallback.
# Uses workspace_dir with double-nesting guard (same logic as get_claude_dir):
# ~/.claude projects already ARE the .claude dir, so don't append .claude again.
# @decision DEC-STATUSLINE-TOKEN-PATH-001
# @title Token persistence path aligned with get_claude_dir()
# @status accepted
# @rationale CACHE_FILE%/* resolves to $workspace_dir/.claude for normal projects but
# to ~/.claude/.claude for the ~/.claude project itself (double-nesting). session-end.sh
# reads from get_claude_dir() which correctly strips the second .claude. Fix: mirror
# that logic here — use workspace_dir directly for ~/.claude projects, append .claude otherwise.
if [[ -n "${workspace_dir:-}" ]]; then
  _token_dir="$workspace_dir/.claude"
  [[ "$workspace_dir" == "$HOME/.claude" ]] && _token_dir="$workspace_dir"
  printf '%d' "$total_tokens_int" > "${_token_dir}/.session-main-tokens" 2>/dev/null || true
fi

# Build token display: tks: Nk  or  tks: Nk(+Sk)
if (( cache_subagent_tokens_int > 0 )); then
  subagent_str=$(format_tokens "$cache_subagent_tokens_int")
  tokens_display=$(printf '\033[%smtks: %s\033[2m(+%s)\033[0m' "$tokens_color" "$tokens_str" "$subagent_str")
else
  tokens_display=$(printf '\033[%smtks: %s\033[0m' "$tokens_color" "$tokens_str")
fi

# Compute lifetime token grand total segment
_token_grand_total=$(( cache_lifetime_tokens_int + total_tokens_int + cache_subagent_tokens_int ))
grand_total_display=""
if (( _token_grand_total > total_tokens_int + cache_subagent_tokens_int && _token_grand_total > 0 )); then
  grand_total_str=$(format_tokens "$_token_grand_total")
  grand_total_display=$(printf '\033[2mΣ%s\033[0m' "$grand_total_str")
fi

# Build cost display
# @decision DEC-LIFETIME-COST-002
# @title Display lifetime cost as Σ annotation next to session cost
# @status accepted
# @rationale Appending lifetime cost as "(Σ~$N.NN)" after the session cost keeps the
# display compact and contextual — the user sees session cost at a glance and can
# recognize the running total from the Σ symbol. Dim rendering avoids visual noise.
cost_int=${cost_usd%.*}
if   (( cost_int >= 5 )); then cost_color="31"
elif (( cost_int >= 1 )); then cost_color="33"
else                           cost_color="32"
fi
cost_display=$(printf '\033[%sm~$%.2f\033[0m' "$cost_color" "$cost_usd")
_lifetime_int="${cache_lifetime_cost%.*}"
_lifetime_int="${_lifetime_int:-0}"
if (( _lifetime_int > 0 )) 2>/dev/null; then
  _grand_cost=$(awk "BEGIN {printf \"%.2f\", $cache_lifetime_cost + $cost_usd}")
  cost_display=$(printf '%s \033[2m(Σ~$%s)\033[0m' "$cost_display" "$_grand_cost")
fi

# Cache efficiency display
cache_display=""
if (( cache_efficiency >= 0 )); then
  if   (( cache_efficiency >= 60 )); then cache_color="32"
  elif (( cache_efficiency >= 30 )); then cache_color="33"
  else                                    cache_color="2"
  fi
  cache_display=$(printf '\033[%smcache %d%%\033[0m' "$cache_color" "$cache_efficiency")
fi

# Lines changed display
lines_display=""
total_lines=$(( lines_add + lines_rm ))
if (( total_lines > 0 )); then
  lines_display=$(printf '\033[32m+%d\033[0m/\033[31m-%d\033[0m' "$lines_add" "$lines_rm")
fi

# Duration display
duration_display=$(printf '\033[2m%s\033[0m' "$(format_duration "$duration_ms")")

# Build metrics line segments (priorities 1-8)
# P2.0: context bar (priority 1)
_m0=$(build_context_bar "$ctx_pct")
ansi_visible_width "$_m0"; _mw0=$_AVW; _mp0=1

# P2.1: model name (priority 5)
_m1=$(printf '\033[2m%s\033[0m' "$model")
ansi_visible_width "$_m1"; _mw1=$_AVW; _mp1=5

# P2.2: tks: Nk(+Sk) (priority 2)
_m2="$tokens_display"
ansi_visible_width "$_m2"; _mw2=$_AVW; _mp2=2

# P2.3: ~$cost (Σ~$total) (priority 3)
_m3="$cost_display"
ansi_visible_width "$_m3"; _mw3=$_AVW; _mp3=3

# P2.4: ΣNk lifetime tokens (priority 4, conditional)
_m4="$grand_total_display"
ansi_visible_width "$_m4"; _mw4=$_AVW; _mp4=4

# P2.5: cache N% (priority 6, conditional)
_m5="$cache_display"
ansi_visible_width "$_m5"; _mw5=$_AVW; _mp5=6

# P2.6: duration (priority 7)
_m6="$duration_display"
ansi_visible_width "$_m6"; _mw6=$_AVW; _mp6=7

# P2.7: +N/-N lines (priority 8, drops first, conditional)
_m7="$lines_display"
ansi_visible_width "$_m7"; _mw7=$_AVW; _mp7=8

# Responsive drop loop for Line 1 (metrics)
_md0=0; _md1=0; _md2=0; _md3=0; _md4=0; _md5=0; _md6=0; _md7=0

_compute_m_width() {
  local total=0 seg_count=0
  [[ $_md0 -eq 0 && -n "$_m0" ]] && total=$(( total + _mw0 )) && (( seg_count++ )) || true
  [[ $_md1 -eq 0 && -n "$_m1" ]] && total=$(( total + _mw1 )) && (( seg_count++ )) || true
  [[ $_md2 -eq 0 && -n "$_m2" ]] && total=$(( total + _mw2 )) && (( seg_count++ )) || true
  [[ $_md3 -eq 0 && -n "$_m3" ]] && total=$(( total + _mw3 )) && (( seg_count++ )) || true
  [[ $_md4 -eq 0 && -n "$_m4" ]] && total=$(( total + _mw4 )) && (( seg_count++ )) || true
  [[ $_md5 -eq 0 && -n "$_m5" ]] && total=$(( total + _mw5 )) && (( seg_count++ )) || true
  [[ $_md6 -eq 0 && -n "$_m6" ]] && total=$(( total + _mw6 )) && (( seg_count++ )) || true
  [[ $_md7 -eq 0 && -n "$_m7" ]] && total=$(( total + _mw7 )) && (( seg_count++ )) || true
  (( seg_count > 1 )) && total=$(( total + (seg_count - 1) * 3 )) || true
  _M_TOTAL=$total
}

_M_TOTAL=0
_compute_m_width
# Drop from priority 8 down to 1 (context bar always stays)
if (( _M_TOTAL > term_w && _mw7 > 0 )); then _md7=1; _compute_m_width; fi
if (( _M_TOTAL > term_w && _mw6 > 0 )); then _md6=1; _compute_m_width; fi
if (( _M_TOTAL > term_w && _mw5 > 0 )); then _md5=1; _compute_m_width; fi
if (( _M_TOTAL > term_w && _mw4 > 0 )); then _md4=1; _compute_m_width; fi
if (( _M_TOTAL > term_w && _mw1 > 0 )); then _md1=1; _compute_m_width; fi
if (( _M_TOTAL > term_w && _mw3 > 0 )); then _md3=1; _compute_m_width; fi
if (( _M_TOTAL > term_w && _mw2 > 0 )); then _md2=1; _compute_m_width; fi

# Assemble Line 1 from remaining segments (display order: context bar, tks, cost, Σ, model, cache, duration, lines)
line2=""
_m_first=1
_append_m_seg() {
  local txt="$1"
  [[ -z "$txt" ]] && return
  if (( _m_first )); then
    line2="$txt"
    _m_first=0
  else
    line2=$(printf '%s %b %s' "$line2" "$sep" "$txt")
  fi
}
[[ $_md0 -eq 0 ]] && _append_m_seg "$_m0"
[[ $_md2 -eq 0 ]] && _append_m_seg "$_m2"
[[ $_md3 -eq 0 ]] && _append_m_seg "$_m3"
[[ $_md4 -eq 0 ]] && _append_m_seg "$_m4"
[[ $_md1 -eq 0 ]] && _append_m_seg "$_m1"
[[ $_md5 -eq 0 ]] && _append_m_seg "$_m5"
[[ $_md6 -eq 0 ]] && _append_m_seg "$_m6"
[[ $_md7 -eq 0 ]] && _append_m_seg "$_m7"

# ---------------------------------------------------------------------------
# Output: 3-line layout — each line independently truncated to terminal width.
#   Line 1 (top):    project   — workspace, git, agents, todos
#   Line 2 (middle): metrics   — model, context bar, tokens, cost, duration, lines, cache %
#   Line 3 (bottom): highlight — initiative banner (conditional, bold cyan)
# @decision DEC-STATUSLINE-004 (output section — see truncate_ansi above for function annotation)
# @title Three-line status bar with per-line ANSI-aware truncation
# @status accepted
# @rationale Each domain gets its own line and its own truncation boundary.
# Line 1 (project) is shorter and fits easily at the top — workspace context is
# the first thing the eye should land on. Line 2 (metrics) is longer and benefits
# from being below the shorter project line. Line 3 (initiative highlight)
# renders at the bottom as a visual anchor — bold cyan so it reads as a banner,
# not inline noise. When no active initiative exists, only lines 1+2 are emitted.
# ---------------------------------------------------------------------------

# Line 1: project context (workspace + git + agents + todos)
truncate_ansi "$line1" "$term_w"
printf '\n'

# Line 2: metrics (model + context bar + tokens + cost + duration + lines + cache)
truncate_ansi "$line2" "$term_w"

# Line 3: initiative highlight bar (always allocated to prevent resize flicker)
# @decision DEC-STATUSLINE-005
# @title Always emit Line 3 newline regardless of initiative presence
# @status accepted
# @rationale Previously the status bar conditionally emitted 2 or 3 lines. During startup,
# session-init.sh writes the cache after the first statusline render (which had no initiative).
# When the cache then populated initiative data, the next render emitted an extra line,
# causing the terminal to resize the status bar and shift all content above — producing
# the visible "flicker" in the Claude Code startup banner. By always emitting the Line 3
# newline, the status bar height is stable at 3 lines, regardless of cache state.
printf '\n'
if [[ -n "$line0" ]]; then
  truncate_ansi "$line0" "$term_w"
fi
