#!/usr/bin/env bash
# statusline.sh — Rich 3-line ANSI HUD backed by cc-policy runtime.
#
# Reads stdin JSON from Claude Code (model, workspace, cost, context window,
# tokens), reads runtime state via cc-policy CLI (proof, agents, worktrees,
# dispatch, tokens, todos), and outputs exactly 3 ANSI-formatted lines each
# independently truncated to terminal width.
#
# Input:  stdin — Claude Code JSON
# Output: exactly 3 newline-separated ANSI lines
#
# Line layout:
#   Line 1 (repo):   workspace │ N uncommitted +N/-N lines │ N worktrees │ marker: impl (2m)
#   Line 2 (model):  model [████████░░░░] 52% │ 145K tks │ ∑1.2M tks │ cache hit 78% │ session 12m
#   Line 3 (meta):   eval: ✓ ready (wf-123) │ next: tester (ready_for_guardian) │ ✓codex │ todos: 3p 10g
#
# State source: cc-policy CLI (runtime/cli.py) — NOT runtime-bridge.sh.
# statusline.sh is standalone; it invokes python3 directly.
#
# @decision DEC-SL-002
# @title Rich 3-line runtime-backed statusline
# @status accepted
# @rationale Replaces the single-line v1 statusline with a domain-grouped
#   3-line layout. State comes from cc-policy CLI (SQLite-backed). stdin JSON
#   provides model/workspace/context metrics from Claude Code. Five ported
#   helpers from claude-config-pro: build_context_bar (single-color),
#   format_duration, format_tokens, truncate_ansi, ansi_visible_width.
#   Responsive drop loops shed lowest-priority segments at narrow terminals.
#   Always emits exactly 3 newlines for stable HUD height.
set -euo pipefail

# ---------------------------------------------------------------------------
# Runtime CLI helper — direct python3 call, no runtime-bridge.sh dependency
# ---------------------------------------------------------------------------
RUNTIME_ROOT="${CLAUDE_RUNTIME_ROOT:-$HOME/.claude/runtime}"

# Ensure project DB scoping for direct CLI calls (DEC-SELF-003).
# config.py can detect via git (step 3), but exporting CLAUDE_PROJECT_DIR
# here satisfies step 2 and avoids a git subprocess per _cc invocation.
# statusline.sh does not source log.sh, so the export must be done here.
if [[ -z "${CLAUDE_PROJECT_DIR:-}" && -z "${CLAUDE_POLICY_DB:-}" ]]; then
    _sl_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -n "$_sl_root" && -d "$_sl_root/.claude" ]]; then
        export CLAUDE_PROJECT_DIR="$_sl_root"
    fi
    unset _sl_root
fi

_cc() { python3 "$RUNTIME_ROOT/cli.py" "$@"; }

# ---------------------------------------------------------------------------
# stdin — single jq call to extract all fields as tab-separated values
# ---------------------------------------------------------------------------
input=$(cat)

read_vars=$(printf '%s' "$input" | jq -r '[
  (.model.display_name // "Claude"),
  (.workspace.current_dir // "" | split("/") | last),
  (.workspace.current_dir // ""),
  (.cost.total_duration_ms // 0 | tostring),
  (.cost.total_lines_added // 0 | tostring),
  (.cost.total_lines_removed // 0 | tostring),
  (.context_window.used_percentage // -1 | tostring),
  (.context_window.current_usage.cache_read_input_tokens // 0 | tostring),
  (.context_window.current_usage.input_tokens // 0 | tostring),
  (.context_window.current_usage.cache_creation_input_tokens // 0 | tostring),
  ((.context_window.total_input_tokens // 0) + (.context_window.total_output_tokens // 0) | tostring)
] | join("\t")' 2>/dev/null || printf 'Claude\t\t\t0\t0\t0\t-1\t0\t0\t0\t0')

IFS=$'\t' read -r model workspace workspace_dir duration_ms lines_add lines_rm \
  ctx_pct cache_read input_tokens cache_create total_tokens <<< "$read_vars"

# ---------------------------------------------------------------------------
# Runtime state reads via cc-policy
# ---------------------------------------------------------------------------

# Project hash — 8-char SHA-256 prefix, matches project_hash() in hooks
project_hash=""
if [[ -n "${workspace_dir:-}" ]]; then
    if command -v shasum >/dev/null 2>&1; then
        project_hash=$(echo "${workspace_dir}" | shasum -a 256 2>/dev/null | cut -c1-8 || echo "unknown")
    elif command -v sha256sum >/dev/null 2>&1; then
        project_hash=$(echo "${workspace_dir}" | sha256sum 2>/dev/null | cut -c1-8 || echo "unknown")
    fi
fi
[[ -z "$project_hash" ]] && project_hash="unknown"

# Statusline snapshot (proof, agents, worktrees, dispatch)
snapshot=$(_cc statusline snapshot) || snapshot=""

# Lifetime token total for this project
lifetime_total=0
if [[ -n "$project_hash" && "$project_hash" != "unknown" ]]; then
    _lt=$(_cc tokens lifetime "$project_hash") && \
        lifetime_total=$(printf '%s' "$_lt" | jq -r '.total // 0' 2>/dev/null) || lifetime_total=0
fi
[[ "${lifetime_total:-0}" =~ ^[0-9]+$ ]] || lifetime_total=0

# Todo counts for this project
todo_project=0
todo_global=0
if [[ -n "$project_hash" && "$project_hash" != "unknown" ]]; then
    _td=$(_cc todos get "$project_hash") && \
        todo_project=$(printf '%s' "$_td" | jq -r '.project // 0' 2>/dev/null) && \
        todo_global=$(printf '%s' "$_td" | jq -r '.global // 0' 2>/dev/null) || true
fi
[[ "${todo_project:-0}" =~ ^[0-9]+$ ]] || todo_project=0
[[ "${todo_global:-0}" =~  ^[0-9]+$ ]] || todo_global=0

# Persist current session token count for lifetime accumulation
total_tokens_int="${total_tokens%.*}"
total_tokens_int=$(( total_tokens_int + 0 )) 2>/dev/null || total_tokens_int=0
if (( total_tokens_int > 0 )) && [[ -n "$project_hash" && "$project_hash" != "unknown" ]]; then
    _cc tokens upsert "pid:${PPID:-$$}" "$project_hash" "$total_tokens_int" >/dev/null || true
fi

# Dirty count
dirty=0
if [[ -n "${workspace_dir:-}" ]]; then
    dirty=$(git -C "$workspace_dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ') || dirty=0
fi
[[ "${dirty:-0}" =~ ^[0-9]+$ ]] || dirty=0

# Extract snapshot fields (safe defaults when snapshot unavailable)
eval_status="idle"
eval_workflow=""
active_agent=""
marker_age_seconds=0
wt_count=0
dispatch_next=""
dispatch_from_verdict=""
review_reviewed="false"
review_verdict=""
review_reviewer=""
snapshot_status="ok"
if [[ -n "$snapshot" ]]; then
    eval_status=$(printf '%s' "$snapshot" | jq -r '.eval_status // "idle"' 2>/dev/null) || eval_status="idle"
    eval_workflow=$(printf '%s' "$snapshot" | jq -r '.eval_workflow // empty' 2>/dev/null) || eval_workflow=""
    active_agent=$(printf '%s' "$snapshot" | jq -r '.active_agent // empty' 2>/dev/null) || active_agent=""
    marker_age_seconds=$(printf '%s' "$snapshot" | jq -r '.marker_age_seconds // 0' 2>/dev/null) || marker_age_seconds=0
    wt_count=$(printf '%s' "$snapshot"    | jq -r '.worktree_count // 0' 2>/dev/null)    || wt_count=0
    dispatch_next=$(printf '%s' "$snapshot" | jq -r '.dispatch_status // empty' 2>/dev/null) || dispatch_next=""
    dispatch_from_verdict=$(printf '%s' "$snapshot" | jq -r '.dispatch_from_verdict // empty' 2>/dev/null) || dispatch_from_verdict=""
    review_reviewed=$(printf '%s' "$snapshot" | jq -r '.last_review.reviewed // false' 2>/dev/null) || review_reviewed="false"
    review_verdict=$(printf '%s' "$snapshot" | jq -r '.last_review.verdict // empty' 2>/dev/null) || review_verdict=""
    review_reviewer=$(printf '%s' "$snapshot" | jq -r '.last_review.reviewer // empty' 2>/dev/null) || review_reviewer=""
    snapshot_status=$(printf '%s' "$snapshot" | jq -r '.status // "ok"' 2>/dev/null) || snapshot_status="ok"
fi
[[ "${wt_count:-0}" =~ ^[0-9]+$ ]] || wt_count=0
[[ "${marker_age_seconds:-0}" =~ ^[0-9]+$ ]] || marker_age_seconds=0
[[ "$active_agent"   == "null" ]] && active_agent=""
[[ "$eval_workflow"  == "null" ]] && eval_workflow=""
[[ "$dispatch_next"  == "null" ]] && dispatch_next=""
[[ "$dispatch_from_verdict" == "null" ]] && dispatch_from_verdict=""
[[ "$review_verdict"  == "null" ]] && review_verdict=""
[[ "$review_reviewer" == "null" ]] && review_reviewer=""
[[ "$snapshot_status"  == "null" ]] && snapshot_status="ok"

# ---------------------------------------------------------------------------
# Terminal width
# @decision DEC-STATUSLINE-TERMWIDTH-003
# @title Reserve 15 chars for Claude Code right-panel, clamp floor to 60
# @status accepted
# @rationale Claude Code renders right-aligned info on the same lines,
#   consuming ~60-70 visible chars. 15-char buffer guards without hiding content.
# ---------------------------------------------------------------------------
term_w="${COLUMNS:-0}"
(( term_w > 15 )) && term_w=$(( term_w - 15 )) || term_w=60
(( term_w < 60 )) && term_w=60
(( term_w > 200 )) && term_w=200

# ---------------------------------------------------------------------------
# Separator and helpers
# ---------------------------------------------------------------------------
sep='\033[2m│\033[0m'

# build_context_bar pct — render 12-char progress bar (single-color mode).
# Ported verbatim from claude-config-pro/scripts/statusline.sh lines 372-430,
# single-color path only (no dual-color baseline; this repo has no baseline file).
#
# @decision DEC-SL-003
# @title Single-color context bar — no baseline dual-color in this repo
# @status accepted
# @rationale The dual-color baseline feature requires a .statusline-baseline flat
#   file per workspace, written by the upstream hook infrastructure. This repo
#   does not ship that infrastructure, so only the single-color fallback path is
#   used. The dual-color logic is preserved upstream; this script stays simple.
build_context_bar() {
  local pct=$1

  if [[ "$pct" == "-1" || "$pct" == "" ]]; then
    printf '\033[2m[░░░░░░░░░░░░] --\033[0m'
    return
  fi

  local pct_int="${pct%.*}"
  (( pct_int < 0 )) && pct_int=0
  (( pct_int > 100 )) && pct_int=100

  local filled=$(( pct_int * 12 / 100 ))
  local empty=$(( 12 - filled ))

  local color
  if   (( pct_int >= 90 )); then color="1;31"
  elif (( pct_int >= 75 )); then color="31"
  elif (( pct_int >= 50 )); then color="33"
  else                           color="32"
  fi

  local bar_fill="" bar_empty="" i
  for (( i=0; i<filled; i++ )); do bar_fill+="█"; done
  for (( i=0; i<empty;  i++ )); do bar_empty+="░"; done
  printf '\033[%sm[%s%s] %d%%\033[0m' "$color" "$bar_fill" "$bar_empty" "$pct_int"
}

# format_duration ms — convert milliseconds to human-readable string.
# Ported verbatim from claude-config-pro/scripts/statusline.sh lines 433-445.
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

# format_tokens count — convert raw token count to K/M notation.
# Ported verbatim from claude-config-pro/scripts/statusline.sh lines 451-468.
format_tokens() {
  local count=$1
  count="${count%.*}"
  count=$(( count ))

  if   (( count >= 1000000 )); then
    local tenths=$(( count / 100000 ))
    local whole=$(( tenths / 10 ))
    local frac=$(( tenths % 10 ))
    printf '%d.%dM' "$whole" "$frac"
  elif (( count >= 1000 )); then
    printf '%dK' "$(( count / 1000 ))"
  else
    printf '%d' "$count"
  fi
}

# truncate_ansi str max_width — truncate ANSI string to fit terminal width.
# Ported verbatim from claude-config-pro/scripts/statusline.sh lines 479-498.
#
# @decision DEC-SL-004
# @title Per-line ANSI-aware truncation
# @status accepted
# @rationale Each of the 3 output lines is independently truncated. Truncation
#   must skip escape sequences when counting visible characters. awk handles
#   the slow path to avoid O(n²) bash string concatenation on wide terminals.
truncate_ansi() {
  local str="$1" max_w="$2"
  local stripped
  stripped=$(printf '%s' "$str" | sed $'s/\033\[[0-9;]*m//g')
  if (( ${#stripped} <= max_w )); then
    printf '%s' "$str"
    return
  fi
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

# ansi_visible_width str — count visible characters, skipping ANSI sequences.
# Ported verbatim from claude-config-pro/scripts/statusline.sh lines 510-525.
# Sets result in global _AVW to avoid subshell overhead.
#
# @decision DEC-RESPONSIVE-001
# @title Pure-bash ANSI width counter for responsive segment dropping
# @status accepted
# @rationale Responsive layout needs per-segment width to decide which to drop.
#   A sed-subshell per segment adds ~5ms each; with 8 segments that's 40ms.
#   Pure-bash character loop adds ~0ms. Result stored in _AVW global.
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
# Derived metrics
# ---------------------------------------------------------------------------

# Cache efficiency: cache_read / (input + cache_read + cache_create) * 100
cache_efficiency=-1
total_input=$(( input_tokens + cache_read + cache_create ))
if (( total_input > 0 && cache_read > 0 )); then
  cache_efficiency=$(( cache_read * 100 / total_input ))
fi

# Token display for session total
tokens_str=$(format_tokens "$total_tokens_int")
if   (( total_tokens_int > 500000 )); then tokens_color="33"
elif (( total_tokens_int > 50000  )); then tokens_color="0"
else                                        tokens_color="2"
fi
tokens_display=$(printf '\033[%sm%s tks\033[0m' "$tokens_color" "$tokens_str")

# Lifetime token display (shown only when lifetime > session total)
lifetime_int="${lifetime_total%.*}"
lifetime_int=$(( lifetime_int + 0 )) 2>/dev/null || lifetime_int=0
grand_total_display=""
if (( lifetime_int > total_tokens_int && lifetime_int > 0 )); then
  grand_str=$(format_tokens "$lifetime_int")
  grand_total_display=$(printf '\033[2m∑%s tks\033[0m' "$grand_str")
fi

# Cache hit display
cache_display=""
if (( cache_efficiency >= 0 )); then
  if   (( cache_efficiency >= 60 )); then cache_color="32"
  elif (( cache_efficiency >= 30 )); then cache_color="33"
  else                                    cache_color="2"
  fi
  cache_display=$(printf '\033[%smcache hit %d%%\033[0m' "$cache_color" "$cache_efficiency")
fi

# Session duration
duration_display=$(printf '\033[2msession %s\033[0m' "$(format_duration "$duration_ms")")

# ---------------------------------------------------------------------------
# LINE 1 (repo context): workspace │ N uncommitted +N/-N │ N worktrees │ marker: impl (2m)
#
# Priority table (lower = higher priority, dropped last):
#   1 = workspace (never dropped)
#   2 = N uncommitted +N/-N lines
#   3 = N worktrees
#   4 = marker: <role> (<age>) (drops first)
#
# @decision DEC-SL-006
# @title Replace ⚡impl actor-implying label with marker: impl (age) conservative label
# @status accepted
# @rationale TKT-023: ⚡impl implied current tool-call actor, which it cannot
#   know. The label now shows subagent marker state explicitly: role and age.
#   A ? suffix fires at >=300s to signal that the marker may be stale. Omit
#   the segment entirely when no marker is active — no empty placeholder.
# ---------------------------------------------------------------------------

_p1_t_0=""; _p1_w_0=0
_p1_t_1=""; _p1_w_1=0
_p1_t_2=""; _p1_w_2=0
_p1_t_3=""; _p1_w_3=0
# P1.0: workspace (priority 1)
# Bug #3 fix: append [!] indicator when snapshot status is partial_failure.
if [[ "$snapshot_status" == "partial_failure" ]]; then
  _s=$(printf '\033[1;36m%s\033[0m \033[1;31m[!]\033[0m' "$workspace")
else
  _s=$(printf '\033[1;36m%s\033[0m' "$workspace")
fi
ansi_visible_width "$_s"; _p1_w_0=$_AVW; _p1_t_0="$_s"

# P1.1: dirty + lines changed (priority 2, conditional)
if (( dirty > 0 )); then
  total_lines_l1=$(( lines_add + lines_rm ))
  if (( total_lines_l1 > 0 )); then
    _s=$(printf '\033[31m%d uncommitted\033[0m \033[32m+%d\033[0m/\033[31m-%d\033[0m \033[2mlines\033[0m' \
      "$dirty" "$lines_add" "$lines_rm")
  else
    _s=$(printf '\033[31m%d uncommitted\033[0m' "$dirty")
  fi
  ansi_visible_width "$_s"; _p1_w_1=$_AVW; _p1_t_1="$_s"
fi

# P1.2: worktrees (priority 3, conditional)
if (( wt_count > 0 )); then
  _s=$(printf '\033[36m%d worktrees\033[0m' "$wt_count")
  ansi_visible_width "$_s"; _p1_w_2=$_AVW; _p1_t_2="$_s"
fi

# P1.3: active marker label (priority 4, conditional)
# Shows "marker: <role>[?] (<age>)" — conservative label, not actor claim.
# ? suffix appears when age >= stale threshold (default 300s, configurable via
# CC_STALE_MARKER_THRESHOLD env var). DEC-SL-160: configurable stale threshold.
_stale_threshold="${CC_STALE_MARKER_THRESHOLD:-300}"
[[ "${_stale_threshold}" =~ ^[0-9]+$ ]] || _stale_threshold=300
if [[ -n "$active_agent" ]]; then
  _age_s="${marker_age_seconds:-0}"
  _age_display=""
  if (( _age_s >= 3600 )); then
    _age_display="$(( _age_s / 3600 ))h"
  elif (( _age_s >= 60 )); then
    _age_display="$(( _age_s / 60 ))m"
  else
    _age_display="${_age_s}s"
  fi
  _stale_suffix=""
  if (( _age_s >= _stale_threshold )); then
    _stale_suffix="?"
  fi
  _s=$(printf '\033[33mmarker: %s%s (%s)\033[0m' "$active_agent" "$_stale_suffix" "$_age_display")
  ansi_visible_width "$_s"; _p1_w_3=$_AVW; _p1_t_3="$_s"
fi

# Responsive drop loop for Line 1
_p1_drop_0=0; _p1_drop_1=0; _p1_drop_2=0; _p1_drop_3=0

_compute_p1_width() {
  local total=0 seg_count=0
  [[ $_p1_drop_0 -eq 0 && -n "$_p1_t_0" ]] && total=$(( total + _p1_w_0 )) && (( seg_count++ )) || true
  [[ $_p1_drop_1 -eq 0 && -n "$_p1_t_1" ]] && total=$(( total + _p1_w_1 )) && (( seg_count++ )) || true
  [[ $_p1_drop_2 -eq 0 && -n "$_p1_t_2" ]] && total=$(( total + _p1_w_2 )) && (( seg_count++ )) || true
  [[ $_p1_drop_3 -eq 0 && -n "$_p1_t_3" ]] && total=$(( total + _p1_w_3 )) && (( seg_count++ )) || true
  (( seg_count > 1 )) && total=$(( total + (seg_count - 1) * 3 )) || true
  _P1_TOTAL=$total
}

_P1_TOTAL=0
_compute_p1_width
if (( _P1_TOTAL > term_w )) && [[ -n "$_p1_t_3" ]]; then _p1_drop_3=1; _compute_p1_width; fi
if (( _P1_TOTAL > term_w )) && [[ -n "$_p1_t_2" ]]; then _p1_drop_2=1; _compute_p1_width; fi
if (( _P1_TOTAL > term_w )) && [[ -n "$_p1_t_1" ]]; then _p1_drop_1=1; _compute_p1_width; fi

line1=""
_p1_first=1
_append_p1_seg() {
  local txt="$1"
  [[ -z "$txt" ]] && return
  if (( _p1_first )); then
    line1="$txt"; _p1_first=0
  else
    line1=$(printf '%s %b %s' "$line1" "$sep" "$txt")
  fi
}
[[ $_p1_drop_0 -eq 0 ]] && _append_p1_seg "$_p1_t_0"
[[ $_p1_drop_1 -eq 0 ]] && _append_p1_seg "$_p1_t_1"
[[ $_p1_drop_2 -eq 0 ]] && _append_p1_seg "$_p1_t_2"
[[ $_p1_drop_3 -eq 0 ]] && _append_p1_seg "$_p1_t_3"

# ---------------------------------------------------------------------------
# LINE 2 (model & resources): model [ctx] % │ Nk tks │ ∑NM tks │ cache hit N% │ session Nm
#
# Priority table (lower = higher priority, dropped last):
#   1 = [ctx bar] (never dropped)
#   2 = NK tks (session tokens)
#   3 = ∑NM tks (lifetime, conditional)
#   4 = cache hit N%
#   5 = session Nm (duration)
#   6 = model name (drops first)
# ---------------------------------------------------------------------------

_l2_0=""; _l2w0=0
_l2_1=""; _l2w1=0
_l2_2=""; _l2w2=0
_l2_3=""; _l2w3=0
_l2_4=""; _l2w4=0
_l2_5=""; _l2w5=0

# L2.0: model + ctx bar (priority 1 — ctx bar never drops; model attached here for visual grouping)
_ctx_bar=$(build_context_bar "$ctx_pct")
_l2_0=$(printf '\033[2m%s\033[0m %s' "$model" "$_ctx_bar")
ansi_visible_width "$_l2_0"; _l2w0=$_AVW

# L2.1: NK tks (session, priority 2)
_l2_1="$tokens_display"
ansi_visible_width "$_l2_1"; _l2w1=$_AVW

# L2.2: ∑NM tks (lifetime, priority 3, conditional)
_l2_2="$grand_total_display"
ansi_visible_width "$_l2_2"; _l2w2=$_AVW

# L2.3: cache hit N% (priority 4, conditional)
_l2_3="$cache_display"
ansi_visible_width "$_l2_3"; _l2w3=$_AVW

# L2.4: session duration (priority 5)
_l2_4="$duration_display"
ansi_visible_width "$_l2_4"; _l2w4=$_AVW

# Responsive drop loop for Line 2 (L2.0 = ctx bar, never dropped)
_l2d0=0; _l2d1=0; _l2d2=0; _l2d3=0; _l2d4=0

_compute_l2_width() {
  local total=0 seg_count=0
  [[ $_l2d0 -eq 0 && -n "$_l2_0" ]] && total=$(( total + _l2w0 )) && (( seg_count++ )) || true
  [[ $_l2d1 -eq 0 && -n "$_l2_1" ]] && total=$(( total + _l2w1 )) && (( seg_count++ )) || true
  [[ $_l2d2 -eq 0 && -n "$_l2_2" ]] && total=$(( total + _l2w2 )) && (( seg_count++ )) || true
  [[ $_l2d3 -eq 0 && -n "$_l2_3" ]] && total=$(( total + _l2w3 )) && (( seg_count++ )) || true
  [[ $_l2d4 -eq 0 && -n "$_l2_4" ]] && total=$(( total + _l2w4 )) && (( seg_count++ )) || true
  (( seg_count > 1 )) && total=$(( total + (seg_count - 1) * 3 )) || true
  _L2_TOTAL=$total
}

_L2_TOTAL=0
_compute_l2_width
# Drop order: duration (5) → cache hit (4) → ∑lifetime (3) → tokens (2). Ctx bar never drops.
if (( _L2_TOTAL > term_w && _l2w4 > 0 )); then _l2d4=1; _compute_l2_width; fi
if (( _L2_TOTAL > term_w && _l2w3 > 0 )); then _l2d3=1; _compute_l2_width; fi
if (( _L2_TOTAL > term_w && _l2w2 > 0 )); then _l2d2=1; _compute_l2_width; fi
if (( _L2_TOTAL > term_w && _l2w1 > 0 )); then _l2d1=1; _compute_l2_width; fi

line2=""
_l2_first=1
_append_l2_seg() {
  local txt="$1"
  [[ -z "$txt" ]] && return
  if (( _l2_first )); then
    line2="$txt"; _l2_first=0
  else
    line2=$(printf '%s %b %s' "$line2" "$sep" "$txt")
  fi
}
[[ $_l2d0 -eq 0 ]] && _append_l2_seg "$_l2_0"
[[ $_l2d1 -eq 0 ]] && _append_l2_seg "$_l2_1"
[[ $_l2d2 -eq 0 ]] && _append_l2_seg "$_l2_2"
[[ $_l2d3 -eq 0 ]] && _append_l2_seg "$_l2_3"
[[ $_l2d4 -eq 0 ]] && _append_l2_seg "$_l2_4"

# ---------------------------------------------------------------------------
# LINE 3 (meta): eval: ✓ ready (wf-123) │ next: tester (ready_for_guardian) │ ✓codex │ todos: 3p 10g
#
# Priority table (lower = higher priority, dropped last):
#   1 = evaluation readiness indicator + workflow (gate signal — most critical)
#   2 = next dispatch role + from_verdict (routing state)
#   3 = review indicator (Codex/Gemini review status, DEC-SL-160)
#   4 = todos (project state — drops first before eval)
#
# @decision DEC-SL-160-DROP
# @title todos drop before eval on Line 3
# @status accepted
# @rationale W-SL-160: eval readiness is the most critical signal on Line 3.
#   At narrow terminals, todos should shed first so eval and dispatch remain
#   visible. Review indicator sheds before todos since it is informational.
# ---------------------------------------------------------------------------

_l3_0=""; _l3w0=0
_l3_1=""; _l3w1=0
_l3_2=""; _l3w2=0
_l3_3=""; _l3w3=0

# L3.0: evaluation readiness indicator + workflow (priority 1, shown for non-idle eval)
# TKT-024: evaluation_state is the sole readiness authority. proof_status is
# no longer read or rendered here.
# W-SL-160: eval_workflow shown in parentheses when available.
case "$eval_status" in
  ready_for_guardian)
    _wf_suffix=""
    [[ -n "$eval_workflow" ]] && _wf_suffix=$(printf ' \033[2m(%s)\033[32m' "$eval_workflow")
    _s=$(printf '\033[32meval: ✓ ready%s\033[0m' "$_wf_suffix")
    ansi_visible_width "$_s"; _l3w0=$_AVW; _l3_0="$_s"
    ;;
  pending)
    _wf_suffix=""
    [[ -n "$eval_workflow" ]] && _wf_suffix=$(printf ' \033[2m(%s)\033[33m' "$eval_workflow")
    _s=$(printf '\033[33meval: ⏳ pending%s\033[0m' "$_wf_suffix")
    ansi_visible_width "$_s"; _l3w0=$_AVW; _l3_0="$_s"
    ;;
  needs_changes)
    _wf_suffix=""
    [[ -n "$eval_workflow" ]] && _wf_suffix=$(printf ' \033[2m(%s)\033[31m' "$eval_workflow")
    _s=$(printf '\033[31meval: ✗ needs_changes%s\033[0m' "$_wf_suffix")
    ansi_visible_width "$_s"; _l3w0=$_AVW; _l3_0="$_s"
    ;;
  blocked_by_plan)
    _wf_suffix=""
    [[ -n "$eval_workflow" ]] && _wf_suffix=$(printf ' \033[2m(%s)\033[31m' "$eval_workflow")
    _s=$(printf '\033[31meval: ⚠ blocked_by_plan%s\033[0m' "$_wf_suffix")
    ansi_visible_width "$_s"; _l3w0=$_AVW; _l3_0="$_s"
    ;;
esac

# L3.1: next dispatch role + from_verdict (priority 2, conditional)
# W-SL-160: dispatch_from_verdict shown in parentheses when available.
if [[ -n "$dispatch_next" ]]; then
  _verdict_suffix=""
  [[ -n "$dispatch_from_verdict" ]] && _verdict_suffix=$(printf ' \033[2m(%s)\033[0m' "$dispatch_from_verdict")
  _s=$(printf '\033[35mnext: %s%s\033[0m' "$dispatch_next" "$_verdict_suffix")
  ansi_visible_width "$_s"; _l3w1=$_AVW; _l3_1="$_s"
fi

# L3.2: review indicator (priority 3, conditional — DEC-SL-160)
# Shows review status from last_review snapshot field when reviewed=true.
# Bug #3 fix: read reviewer name from snapshot JSON instead of hardcoding.
_review_label="${review_reviewer:-codex}"
if [[ "$review_reviewed" == "true" ]]; then
  case "$review_verdict" in
    ALLOW)
      _s=$(printf '\033[32m✓%s\033[0m' "$_review_label")
      ;;
    BLOCK)
      _s=$(printf '\033[31m✗%s\033[0m' "$_review_label")
      ;;
    *)
      _s=$(printf '\033[33m⏳%s\033[0m' "$_review_label")
      ;;
  esac
  ansi_visible_width "$_s"; _l3w2=$_AVW; _l3_2="$_s"
fi

# L3.3: todos (priority 4, conditional — shown when any count > 0)
# W-SL-160: todos now drop before eval (priority 4, not 1).
if (( todo_project > 0 && todo_global > 0 )); then
  _s=$(printf '\033[35mtodos: %d\033[2mp\033[0m\033[35m %d\033[2mg\033[0m' \
    "$todo_project" "$todo_global")
  ansi_visible_width "$_s"; _l3w3=$_AVW; _l3_3="$_s"
elif (( todo_project > 0 )); then
  _s=$(printf '\033[35mtodos: %d\033[2mp\033[0m' "$todo_project")
  ansi_visible_width "$_s"; _l3w3=$_AVW; _l3_3="$_s"
elif (( todo_global > 0 )); then
  _s=$(printf '\033[35mtodos: %d\033[2mg\033[0m' "$todo_global")
  ansi_visible_width "$_s"; _l3w3=$_AVW; _l3_3="$_s"
fi

# Responsive drop loop for Line 3
# Drop order: todos (4) → review (3) → dispatch (2). Eval never drops.
_l3d0=0; _l3d1=0; _l3d2=0; _l3d3=0

_compute_l3_width() {
  local total=0 seg_count=0
  [[ $_l3d0 -eq 0 && -n "$_l3_0" ]] && total=$(( total + _l3w0 )) && (( seg_count++ )) || true
  [[ $_l3d1 -eq 0 && -n "$_l3_1" ]] && total=$(( total + _l3w1 )) && (( seg_count++ )) || true
  [[ $_l3d2 -eq 0 && -n "$_l3_2" ]] && total=$(( total + _l3w2 )) && (( seg_count++ )) || true
  [[ $_l3d3 -eq 0 && -n "$_l3_3" ]] && total=$(( total + _l3w3 )) && (( seg_count++ )) || true
  (( seg_count > 1 )) && total=$(( total + (seg_count - 1) * 3 )) || true
  _L3_TOTAL=$total
}

_L3_TOTAL=0
_compute_l3_width
if (( _L3_TOTAL > term_w && _l3w3 > 0 )); then _l3d3=1; _compute_l3_width; fi
if (( _L3_TOTAL > term_w && _l3w2 > 0 )); then _l3d2=1; _compute_l3_width; fi
if (( _L3_TOTAL > term_w && _l3w1 > 0 )); then _l3d1=1; _compute_l3_width; fi

line3=""
_l3_first=1
_append_l3_seg() {
  local txt="$1"
  [[ -z "$txt" ]] && return
  if (( _l3_first )); then
    line3="$txt"; _l3_first=0
  else
    line3=$(printf '%s %b %s' "$line3" "$sep" "$txt")
  fi
}
[[ $_l3d0 -eq 0 ]] && _append_l3_seg "$_l3_0"
[[ $_l3d1 -eq 0 ]] && _append_l3_seg "$_l3_1"
[[ $_l3d2 -eq 0 ]] && _append_l3_seg "$_l3_2"
[[ $_l3d3 -eq 0 ]] && _append_l3_seg "$_l3_3"

# ---------------------------------------------------------------------------
# Output — always exactly 3 lines for stable HUD height.
#
# @decision DEC-SL-005
# @title Always emit exactly 3 newlines for stable HUD height
# @status accepted
# @rationale Stable line count prevents terminal resize flicker when runtime
#   data is absent or a line would otherwise be empty. Each line is independently
#   truncated. A fallback "no runtime" marker on Line 3 confirms degraded state.
# ---------------------------------------------------------------------------

# Line 1: repo context
if [[ -n "$snapshot" ]]; then
  truncate_ansi "$line1" "$term_w"
else
  # Fallback: workspace only + no-runtime marker
  truncate_ansi "$(printf '\033[1;36m%s\033[0m %b \033[2m(no runtime)\033[0m' "$workspace" "$sep")" "$term_w"
fi
printf '\n'

# Line 2: model & resources (always shown — ctx bar is always present)
truncate_ansi "$line2" "$term_w"
printf '\n'

# Line 3: meta
truncate_ansi "$line3" "$term_w"
