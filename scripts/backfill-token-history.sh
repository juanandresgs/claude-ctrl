#!/usr/bin/env bash
# backfill-token-history.sh — Retroactively add project_hash and project_name
# (columns 6+7) to existing .session-token-history entries.
#
# Purpose: Old-format entries in .session-token-history have only 5 columns:
#   timestamp|total_tokens|main_tokens|subagent_tokens|session_id
#
# This script upgrades them to 7 columns by matching each entry's timestamp
# to the closest trace in traces/index.jsonl (within ±30 minutes) and using
# that trace's project_name and computing its project_hash. Unmatched entries
# get "unknown" as project_name and empty string as project_hash.
#
# Usage:
#   scripts/backfill-token-history.sh [history_file] [trace_index]
#
# Defaults:
#   history_file: ~/.claude/.session-token-history
#   trace_index:  ~/.claude/traces/index.jsonl
#
# Behavior:
#   - Backs up the original file to <history_file>.bak
#   - Skips entries already having 7 columns (idempotent)
#   - Reports N backfilled, M skipped (already 7-col), P unmatched
#   - Overwrites the history file in-place (after successful processing)
#
# @decision DEC-BACKFILL-TOKEN-HISTORY-001
# @title Backfill script adds project_hash/name columns to old token history
# @status accepted
# @rationale Existing history files pre-date issue #160. Without backfill, the
# per-project filter in session-init.sh would treat all old entries as "unscoped"
# and include them in every project's sum — inflating each project's lifetime count.
# The backfill assigns the most likely project based on trace timestamps, reducing
# the unscoped set. Entries more than 30 minutes from any trace stay unscoped
# (backward-compat: still counted for all projects) rather than being silently
# dropped. The 30-minute window is generous: most sessions produce traces within
# a few minutes of the token history entry.

set -euo pipefail

# Inline project_hash: 8-char SHA-256 of path — matches core-lib.sh
_phash() {
    echo "$1" | shasum -a 256 | cut -c1-8
}

# K/M notation for display
_fmt_k() {
    local n="$1"
    if   (( n >= 1000000 )); then awk "BEGIN {printf \"%.1fM\", $n/1000000}"
    elif (( n >= 1000    )); then printf '%dk' "$(( n / 1000 ))"
    else                         printf '%d' "$n"
    fi
}

# Parse timestamp to epoch — single-call bulk conversion
# For per-entry use in the main loop (history file is small: ~100 entries)
_ts_to_epoch() {
    local ts="$1"
    # python3 is the most portable: handles ISO8601 on both macOS and Linux
    python3 -c "
from datetime import datetime, timezone
try:
    print(int(datetime.strptime('${ts}','%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc).timestamp()))
except Exception:
    print(0)
" 2>/dev/null || \
    date -d "$ts" +%s 2>/dev/null || \
    date -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null || \
    echo "0"
}

# Determine paths
HISTORY_FILE="${1:-$HOME/.claude/.session-token-history}"
TRACE_INDEX="${2:-$HOME/.claude/traces/index.jsonl}"

if [[ ! -f "$HISTORY_FILE" ]]; then
    echo "No history file found at: $HISTORY_FILE"
    exit 0
fi

# Create backup
BACKUP_FILE="${HISTORY_FILE}.bak"
cp "$HISTORY_FILE" "$BACKUP_FILE"
echo "Backup created: $BACKUP_FILE"

# Load trace index into arrays for fast lookup
# Arrays: trace_epoch[] trace_project_name[] trace_session_ids[]
declare -a trace_epochs=()
declare -a trace_project_names=()
declare -a trace_session_ids=()

# @decision DEC-BACKFILL-TRACE-LOAD-001
# @title Use single python3 call for bulk trace index loading and epoch conversion
# @status accepted
# @rationale traces/index.jsonl can have 2000+ entries. Spawning per-line subprocesses
# (python3 or date) takes O(N) subprocesses — ~2000 * 30ms = 60+ seconds. A single
# python3 call processes the entire JSONL file, converts all timestamps to epochs, and
# outputs tab-delimited (epoch, project_name, session_id) triples that bash reads in
# one loop pass. This reduces >60s load time to <1s for 2000 entries. Falls back
# gracefully if python3 or jq is unavailable. session_id added for Tier 0 matching.
if [[ -f "$TRACE_INDEX" ]]; then
    # Single python3 call: read all trace entries, convert timestamps to epochs
    while IFS=$'\t' read -r _epoch _pname _sid; do
        [[ "$_epoch" -gt 0 ]] 2>/dev/null || continue
        trace_epochs+=("$_epoch")
        trace_project_names+=("${_pname:-unknown}")
        trace_session_ids+=("${_sid:-}")
    done < <(python3 - "$TRACE_INDEX" << 'PYEOF'
import sys, json
from datetime import datetime, timezone

index_file = sys.argv[1]
with open(index_file, 'r') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
            started = d.get('started_at', '')
            pname = d.get('project_name', 'unknown') or 'unknown'
            sid = d.get('session_id', '') or ''
            if started:
                epoch = int(datetime.strptime(started, '%Y-%m-%dT%H:%M:%SZ')
                            .replace(tzinfo=timezone.utc).timestamp())
                print(f"{epoch}\t{pname}\t{sid}")
        except Exception:
            pass
PYEOF
2>/dev/null)
fi

echo "Loaded ${#trace_epochs[@]} trace(s) from index"

# @decision DEC-BACKFILL-PHASH-002
# @title Pre-scan history file to learn correct path-based hashes from live entries
# @status accepted
# @supersedes DEC-BACKFILL-PHASH-001
# @rationale DEC-BACKFILL-PHASH-001 claimed that hashing the project_name was acceptable
# because old entries "fall through the NF < 6 backward-compat clause." That was wrong:
# once backfill upgrades entries to 7 columns, NF < 6 no longer matches, so they are
# silently excluded from per-project filtering in session-init.sh (which filters by
# $6 == $_PHASH, the path-based hash). The bug caused 5.6M tokens to be invisible to
# per-project views.
#
# Fix: pre-scan the history file before processing. Live-written entries (session_id !=
# "unknown") have the correct path-based hash because session-end.sh calls
# project_hash(PROJECT_ROOT). We collect these into an associative array keyed by
# project_name. When the main loop assigns a hash to a newly backfilled entry, it first
# looks up the project_name in known_hashes. If found, it uses the correct path-based
# hash. If not found (no live entry exists for this project_name), it falls back to
# hash(project_name) — same behavior as before, acceptable for orphaned data.
#
# This approach is O(N) additional reads (one extra pass over the history file) and does
# not require the PROJECT_ROOT path to be known at backfill time. It leverages the
# invariant that any project with live token history entries will have at least one
# correctly-hashed entry in the file.
#
# Implementation note: bash 3.2 (macOS default) does not support associative arrays
# (declare -A). We use a temp directory as a portable key-value store: one file per
# project_name, containing the hash. File names are the raw project_name (project names
# are basenames, safe as filenames). This is O(N) disk ops but the history file is tiny.
HASH_STORE=$(mktemp -d)
trap 'rm -rf "$HASH_STORE" 2>/dev/null || true' EXIT
_known_hash_count=0
while IFS='|' read -r _ps_ts _ps_tok _ps_main _ps_sub _ps_sid _ps_phash _ps_pname; do
    # Only learn from 7-column entries where session_id is NOT "unknown"
    # (live-written entries, not previously backfilled ones which had wrong hashes)
    if [[ -n "${_ps_phash:-}" && -n "${_ps_pname:-}" && "${_ps_sid:-}" != "unknown" ]]; then
        # Skip if we already have a hash for this project (first live entry wins)
        local_key_file="${HASH_STORE}/${_ps_pname}"
        if [[ ! -f "$local_key_file" ]]; then
            printf '%s' "$_ps_phash" > "$local_key_file"
            _known_hash_count=$(( _known_hash_count + 1 ))
        fi
    fi
done < "$HISTORY_FILE"
echo "Pre-scan learned ${_known_hash_count} project hash(es) from live entries"

# Lookup helper: get the known path-based hash for a project_name (or empty string)
_known_hash() {
    local _kh_pname="$1"
    local _kh_file="${HASH_STORE}/${_kh_pname}"
    if [[ -f "$_kh_file" ]]; then
        cat "$_kh_file"
    else
        echo ""
    fi
}

# Process history file
MATCH_WINDOW=1800  # 30 minutes in seconds

count_backfilled=0
count_skipped=0
count_unmatched=0
total=0

TEMP_OUT="${HISTORY_FILE}.backfill.tmp.$$"

while IFS='|' read -r ts total_tok main_tok sub_tok sid rest; do
    total=$(( total + 1 ))
    # Count existing fields: if rest is non-empty after 5 fields, we already have col 6+
    # A 7-column entry: ts|total|main|sub|sid|phash|pname → rest = "phash|pname"
    if [[ -n "$rest" ]]; then
        # Already has columns 6+7 — write unchanged
        echo "${ts}|${total_tok}|${main_tok}|${sub_tok}|${sid}|${rest}" >> "$TEMP_OUT"
        count_skipped=$(( count_skipped + 1 ))
        continue
    fi

    # Need to add columns 6+7 — find closest trace
    ts_epoch=$(_ts_to_epoch "$ts")
    best_diff=999999999
    best_pname="unknown"
    n_traces=${#trace_epochs[@]}

    # @decision DEC-BACKFILL-NULL-FALLBACK-001
    # @title Two-tier trace matching: use nearest named trace when closest is "unknown"
    # @status accepted
    # @rationale Failed tester dispatches (and some orchestrator sub-agents) always
    # record null/unknown project_name in the trace index. When a history entry is
    # closest in time to one of these failed traces, the single-best-match algorithm
    # assigns "unknown" — even when a real implementer trace 5 minutes away clearly
    # identifies the project. Fix: track two parallel bests:
    #   best_diff / best_pname         — absolute closest (any project_name)
    #   best_named_diff / best_named_pname — closest with a non-"unknown" name
    # After the loop, if the absolute-closest yields "unknown" AND a named match
    # is within the window, use the named match. This removes the "unknown" bias
    # without changing the result when the closest trace already has a real name.
    # See issue #175.
    best_named_diff=999999999
    best_named_pname=""

    # @decision DEC-BACKFILL-SESSION-MATCH-001
    # @title Session_id exact match as primary backfill strategy
    # @status accepted
    # @rationale Timestamp proximity matching is error-prone with concurrent sessions.
    # Session_id is an exact identifier provided by Claude Code. When both the token
    # history entry AND a trace share the same session_id, the project attribution
    # is guaranteed correct. Falls back to two-tier timestamp matching for old entries
    # where session_id was "unknown" (pre DEC-SESSION-ID-001 data).
    # Tier 0: exact session_id match (fastest, most reliable)
    if [[ "$sid" != "unknown" && -n "$sid" && "$n_traces" -gt 0 ]]; then
        for (( idx=0; idx<n_traces; idx++ )); do
            if [[ "${trace_session_ids[$idx]}" == "$sid" \
               && "${trace_project_names[$idx]}" != "unknown" \
               && -n "${trace_project_names[$idx]}" ]]; then
                best_pname="${trace_project_names[$idx]}"
                best_diff=0  # exact match — skip timestamp scan
                break
            fi
        done
    fi

    if [[ "$n_traces" -gt 0 && "$ts_epoch" -gt 0 ]]; then
        for (( idx=0; idx<n_traces; idx++ )); do
            t_epoch="${trace_epochs[$idx]}"
            diff=$(( ts_epoch - t_epoch ))
            (( diff < 0 )) && diff=$(( -diff ))
            # Tier 1: absolute closest (any project_name, including "unknown")
            if (( diff < best_diff )); then
                best_diff=$diff
                best_pname="${trace_project_names[$idx]}"
            fi
            # Tier 2: closest with a real (non-unknown, non-empty) project_name
            _pn="${trace_project_names[$idx]}"
            if [[ "$_pn" != "unknown" && -n "$_pn" ]] && (( diff < best_named_diff )); then
                best_named_diff=$diff
                best_named_pname="$_pn"
            fi
        done
    fi

    # Apply fallback: if best match is "unknown" and a named match is within the window, use it
    if [[ "$best_pname" == "unknown" && -n "$best_named_pname" ]] \
       && (( best_named_diff <= MATCH_WINDOW )); then
        best_pname="$best_named_pname"
        best_diff="$best_named_diff"
    fi

    if (( best_diff <= MATCH_WINDOW )); then
        # Matched — assign project hash.
        # Prefer the path-based hash learned from live entries (correct).
        # Fall back to hash(project_name) only when no live entry exists (DEC-BACKFILL-PHASH-002).
        _live_hash=$(_known_hash "$best_pname")
        if [[ -n "$_live_hash" ]]; then
            best_phash="$_live_hash"
        else
            best_phash=$(_phash "$best_pname")
        fi
        echo "${ts}|${total_tok}|${main_tok}|${sub_tok}|${sid}|${best_phash}|${best_pname}" >> "$TEMP_OUT"
        count_backfilled=$(( count_backfilled + 1 ))
    else
        # Unmatched — use empty phash so it's counted by all project filters (backward compat)
        echo "${ts}|${total_tok}|${main_tok}|${sub_tok}|${sid}||unknown" >> "$TEMP_OUT"
        count_unmatched=$(( count_unmatched + 1 ))
    fi
done < "$HISTORY_FILE"

# @decision DEC-BACKFILL-PHASH-001
# @title Backfill uses project_name hash, not project_root hash
# @status superseded
# @superseded-by DEC-BACKFILL-PHASH-002
# @rationale SUPERSEDED. The original assumption that old entries "fall through NF < 6"
# was incorrect: once this backfill script upgrades them to 7 columns, NF < 6 no longer
# matches and they are silently excluded from per-project filtering. The pre-scan approach
# in DEC-BACKFILL-PHASH-002 fixes this by learning correct hashes from live entries.
# See the pre-scan block above for the new implementation.

# Replace original with processed output
mv "$TEMP_OUT" "$HISTORY_FILE"

echo ""
echo "Backfill complete:"
echo "  Total entries : $total"
echo "  Already 7-col : $count_skipped (skipped)"
echo "  Backfilled    : $count_backfilled (matched within 30min)"
echo "  Unmatched     : $count_unmatched (got empty phash + 'unknown' name)"
