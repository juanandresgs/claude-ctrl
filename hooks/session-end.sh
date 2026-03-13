#!/usr/bin/env bash
# session-end.sh — SessionEnd hook
#
# Purpose: Cleans up session-scoped files when Claude Code session terminates.
# Releases active todo claims, kills orphaned async processes, and removes
# temporary tracking files that don't persist across sessions.
#
# Hook type: SessionEnd
# Trigger: Session termination (any reason)
# Input: JSON on stdin with reason field
# Output: None (cleanup only)
#
# Cleans up:
#   - Session tracking files (.session-changes-*, .session-decisions-*)
#   - Lint cache files (.lint-cache)
#   - Test gate strikes and warnings
#   - Temporary tracking artifacts (.track.*)
#   - Skill result files (.skill-result*)
#   - Async test-runner processes
#   - Session-scoped subagent tracker (.subagent-tracker-<SESSION_ID>)
#
# Persists (does NOT delete):
#   - .audit-log — persistent audit trail
#   - .agent-findings — pending agent issues
#   - .lint-breaker — circuit breaker state
#   - .plan-drift — decision drift data
#   - .test-status — cleared at session START, not here
#
# @decision DEC-SUBAGENT-002
# @title Session-scoped subagent tracker cleanup on exit
# @status accepted
# @rationale Issue #73: Each session now owns .subagent-tracker-${CLAUDE_SESSION_ID:-$$}.
# Deleting it on SessionEnd prevents any file accumulation on clean exits.
# If the session crashes, the stale file is harmless because future sessions
# read their own scoped file — no phantom agent counts in the statusline.
#
# @decision DEC-V2-PHASE4-002
# @title Session index entry written at session-end for cross-session learning
# @status accepted
# @rationale session-end.sh already has the session event log and project hash in
# scope. Writing the index entry here (after archiving events) avoids a separate
# hook and ensures the index is only written for sessions that produced real events.
# The 20-entry trim keeps disk usage bounded without losing meaningful history.
# Outcome is derived from .proof-status (verified→committed) then .test-status
# (pass/fail) as a fallback, giving the most accurate signal for cross-session
# context injection.

set -euo pipefail

source "$(dirname "$0")/source-lib.sh"

require_session
require_state

# Redirect stderr to /dev/null — log_info writes to stderr, and Claude Code
# treats any stderr output from SessionEnd hooks as a failure even when exit
# code is 0. Nobody reads diagnostic messages at session termination anyway.
exec 2>/dev/null

# Capture stdin once so we can extract multiple fields from it.
# The session-end JSON is small (just {reason, cost fields}) so capturing
# into a variable is safe — no session history, unlike session event logs.
# @decision DEC-COST-PERSIST-001
# @title Capture session-end stdin to extract both reason and cost fields
# @status accepted
# @rationale The original code streamed stdin directly to jq for reason extraction.
# Since we also need cost.total_cost_usd for .session-cost-history persistence
# (REQ-P1-001), we capture stdin once. The session-end JSON is small (no event
# history) so variable capture is safe. Both extractions re-use the variable.
_SESSION_END_INPUT=$(cat)
REASON=$(printf '%s' "$_SESSION_END_INPUT" | jq -r '.reason // "unknown"' 2>/dev/null || echo "unknown")

# Extract session_id from hook input (mirrors DEC-SESSION-ID-001 in log.sh)
# session-end.sh does NOT use read_input() — it captures stdin directly above.
# Repeat the extraction here so CLAUDE_SESSION_ID is available for archive naming
# and subagent tracker cleanup below.
if [[ -z "${CLAUDE_SESSION_ID:-}" ]]; then
    CLAUDE_SESSION_ID=$(printf '%s' "$_SESSION_END_INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
    export CLAUDE_SESSION_ID
fi

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)

log_info "SESSION-END" "Session ending (reason: $REASON)"

# Todo claim release removed (requires todo.sh — personal component)

# --- Kill lingering async test-runner processes ---
# test-runner.sh runs async (PostToolUse). If it's still running when the session
# ends, its output will never be consumed. Kill it to prevent orphaned processes.
if pgrep -f "test-runner\\.sh" >/dev/null 2>&1; then
    pkill -f "test-runner\\.sh" 2>/dev/null || true
    log_info "SESSION-END" "Killed lingering test-runner process(es)"
fi

# --- Archive session event log ---
SESSION_EVENT_FILE="${CLAUDE_DIR}/.session-events.jsonl"
if [[ -f "$SESSION_EVENT_FILE" && -s "$SESSION_EVENT_FILE" ]]; then
    # Create project-specific archive directory
    PROJECT_HASH=$(echo "$PROJECT_ROOT" | ${_SHA256_CMD:-shasum -a 256} 2>/dev/null | cut -c1-12)
    ARCHIVE_DIR="$HOME/.claude/sessions/${PROJECT_HASH}"
    mkdir -p "$ARCHIVE_DIR"

    # Generate session ID
    SESSION_ID="${CLAUDE_SESSION_ID:-$(date +%s)}"
    ARCHIVE_FILE="${ARCHIVE_DIR}/${SESSION_ID}.jsonl"

    # Archive
    cp "$SESSION_EVENT_FILE" "$ARCHIVE_FILE"
    log_info "SESSION-END" "Archived session events to $ARCHIVE_FILE"

    # --- Write session index entry for cross-session learning ---
    get_session_trajectory "$PROJECT_ROOT"

    # Collect files touched this session
    FILES_TOUCHED=$(grep '"event":"write"' "$SESSION_EVENT_FILE" 2>/dev/null | jq -r '.file // empty' 2>/dev/null | sort -u | jq -Rsc 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")

    # Collect friction: test failures and gate blocks
    FRICTION_JSON="[]"
    TEST_FAIL_MSG=$(grep '"event":"test_run"' "$SESSION_EVENT_FILE" 2>/dev/null | grep '"result":"fail"' | jq -r '.assertion // empty' 2>/dev/null | sort -u | head -3 | jq -Rsc 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")
    if [[ "$TEST_FAIL_MSG" != "[]" && "$TEST_FAIL_MSG" != "" ]]; then
        FRICTION_JSON="$TEST_FAIL_MSG"
    fi

    # Determine session outcome from proof-status or test-status.
    # Use resolve_proof_file() for worktree-aware resolution (replaces inline project_hash).
    OUTCOME="unknown"
    PROOF_FILE=$(resolve_proof_file)
    [[ ! -f "$PROOF_FILE" ]] && PROOF_FILE=""
    # Check new path (state/{phash}/test-status) first, fall back to legacy
    _PHASH_SE=$(project_hash "$PROJECT_ROOT")
    TEST_STATUS_FILE="${CLAUDE_DIR}/state/${_PHASH_SE}/test-status"
    if [[ ! -f "$TEST_STATUS_FILE" ]]; then
        TEST_STATUS_FILE="${CLAUDE_DIR}/.test-status"
    fi
    if [[ -n "$PROOF_FILE" && -f "$PROOF_FILE" ]]; then
        if validate_state_file "$PROOF_FILE" 2; then
            PS_VAL=$(cut -d'|' -f1 "$PROOF_FILE" 2>/dev/null || echo "")
        else
            PS_VAL=""  # corrupt — skip proof status derivation
        fi
        [[ "$PS_VAL" == "verified" ]] && OUTCOME="committed"
        # Clean proof-status after reading — prevents stale files surviving normal session-end (Bug D)
        [[ -n "$PROOF_FILE" && -f "$PROOF_FILE" ]] && rm -f "$PROOF_FILE"
    fi
    if [[ "$OUTCOME" == "unknown" && -f "$TEST_STATUS_FILE" ]]; then
        TS_VAL=$(cut -d'|' -f1 "$TEST_STATUS_FILE" 2>/dev/null || echo "")
        if [[ "$TS_VAL" == "pass" ]]; then
            OUTCOME="tests-passing"
        elif [[ "$TS_VAL" == "fail" ]]; then
            OUTCOME="tests-failing"
        fi
    fi

    # Build index entry JSON — compact (-c) for JSONL format (one object per line)
    INDEX_ENTRY=$(jq -cn \
        --arg id "$SESSION_ID" \
        --arg project "$(basename "$PROJECT_ROOT")" \
        --arg started "$(head -1 "$SESSION_EVENT_FILE" 2>/dev/null | jq -r '.ts // empty' 2>/dev/null || echo "")" \
        --argjson duration_min "${TRAJ_ELAPSED_MIN:-0}" \
        --argjson files_touched "$FILES_TOUCHED" \
        --argjson tool_calls "${TRAJ_TOOL_CALLS:-0}" \
        --argjson checkpoints "${TRAJ_CHECKPOINTS:-0}" \
        --argjson pivots "${TRAJ_PIVOTS:-0}" \
        --argjson friction "$FRICTION_JSON" \
        --arg outcome "$OUTCOME" \
        '{id:$id,project:$project,started:$started,duration_min:$duration_min,files_touched:$files_touched,tool_calls:$tool_calls,checkpoints:$checkpoints,pivots:$pivots,friction:$friction,outcome:$outcome}' \
        2>/dev/null || echo "")

    if [[ -n "$INDEX_ENTRY" ]]; then
        INDEX_FILE="${ARCHIVE_DIR}/index.jsonl"
        echo "$INDEX_ENTRY" >> "$INDEX_FILE"

        # Trim index to last 20 entries (prevent unbounded growth)
        LINE_COUNT=$(wc -l < "$INDEX_FILE" 2>/dev/null | tr -d ' ')
        if [[ "${LINE_COUNT:-0}" -gt 20 ]]; then
            tail -20 "$INDEX_FILE" > "${INDEX_FILE}.tmp"
            mv "${INDEX_FILE}.tmp" "$INDEX_FILE"
        fi

        log_info "SESSION-END" "Session index updated (outcome: $OUTCOME)"
    fi
fi

# --- Persist session cost to .session-cost-history (REQ-P1-001) ---
# @decision DEC-COST-PERSIST-002
# @title Append session cost to pipe-delimited history file at session-end
# @status accepted
# @rationale A simple pipe-delimited file (timestamp|cost_usd|session_id) is
# the lowest-overhead persistence format: append-only, awk-summable, human-readable.
# Cost is read from cost.total_cost_usd in the session-end JSON. This field is
# available from Claude Code's SessionEnd hook when the model exposes it; if absent
# (null or missing), we write 0.00 as a placeholder so the file structure is always
# consistent. session-init.sh sums the cost column with awk for lifetime display.
_SESSION_COST=$(printf '%s' "$_SESSION_END_INPUT" | jq -r '.cost.total_cost_usd // 0' 2>/dev/null || echo "0")
_SESSION_COST="${_SESSION_COST:-0}"
_COST_HISTORY="${CLAUDE_DIR}/.session-cost-history"
_COST_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)
echo "${_COST_TS}|${_SESSION_COST}|${CLAUDE_SESSION_ID:-unknown}" >> "$_COST_HISTORY"
log_info "SESSION-END" "Persisted session cost: ${_SESSION_COST}"

# --- Persist session tokens to .session-token-history ---
# @decision DEC-LIFETIME-TOKENS-002
# @title Append session tokens to pipe-delimited history file at session-end
# @status accepted
# @rationale Mirrors DEC-COST-PERSIST-002 for tokens. A pipe-delimited file is the
# lowest-overhead persistence format: append-only, awk-summable, human-readable.
# Format: timestamp|total_tokens|main_tokens|subagent_tokens|session_id|project_hash|project_name
# (7 columns; previously 5 — columns 6+7 added in issue #160 to enable per-project filtering).
# main_tokens are read from .session-main-tokens (written by statusline.sh on
# each render — most recent value before session ends). subagent_tokens are summed
# from the session-scoped .subagent-tokens-<SESSION_ID> file (field 7 = total).
# The subagent tokens file MUST be read before it is deleted in the cleanup section.
# session-init.sh sums the total_tokens column filtered by project_hash (column 6) for
# per-project lifetime display, with backward compat for old 5-column entries (no filter).
# @decision DEC-PROJECT-TOKEN-HISTORY-001
# @title Add project_hash and project_name as columns 6+7 of .session-token-history
# @status accepted
# @rationale Before this change, all sessions for all projects accumulated into one
# sum, conflating work across projects. Adding the project hash (8-char SHA-256 of
# PROJECT_ROOT) as column 6 lets session-init.sh filter by project. project_name
# (basename of PROJECT_ROOT) is column 7 for human readability. Both are already
# available in session-end.sh via PROJECT_ROOT and project_hash(). Old 5-column
# entries are treated as "unscoped" and included in all project sums (backward compat).
# Backfill script: scripts/backfill-token-history.sh retroactively adds these columns
# using trace timestamps to identify the most likely project.
_SUBAGENT_TOKEN_FILE="${CLAUDE_DIR}/.subagent-tokens-${CLAUDE_SESSION_ID:-$$}"
_SUBAGENT_TOTAL=0
if [[ -f "$_SUBAGENT_TOKEN_FILE" ]]; then
    # Sum the 'total' column (field 7) from all lines
    _SUBAGENT_TOTAL=$(awk -F'|' '{sum += $7} END {print sum+0}' "$_SUBAGENT_TOKEN_FILE" 2>/dev/null || echo "0")
fi

# Main session tokens from .session-main-tokens (written by statusline.sh each render)
_MAIN_TOKENS=0
_MAIN_TOKEN_FILE="${CLAUDE_DIR}/.session-main-tokens"
if [[ -f "$_MAIN_TOKEN_FILE" ]]; then
    _MAIN_TOKENS=$(cat "$_MAIN_TOKEN_FILE" 2>/dev/null || echo "0")
    _MAIN_TOKENS="${_MAIN_TOKENS%.*}"
    _MAIN_TOKENS=$(( ${_MAIN_TOKENS:-0} ))
fi

# Fallback: try context_window fields from session-end JSON
if [[ "$_MAIN_TOKENS" -eq 0 ]]; then
    _MAIN_IN=$(printf '%s' "$_SESSION_END_INPUT" | jq -r '.context_window.total_input_tokens // 0' 2>/dev/null || echo "0")
    _MAIN_OUT=$(printf '%s' "$_SESSION_END_INPUT" | jq -r '.context_window.total_output_tokens // 0' 2>/dev/null || echo "0")
    _MAIN_TOKENS=$(( ${_MAIN_IN:-0} + ${_MAIN_OUT:-0} ))
fi

_SESSION_TOKENS=$(( _MAIN_TOKENS + _SUBAGENT_TOTAL ))
if [[ "$_SESSION_TOKENS" -gt 0 ]]; then
    _TOKEN_HISTORY="${CLAUDE_DIR}/.session-token-history"
    _TOKEN_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)
    # Columns 6+7: project_hash and project_name for per-project filtering in session-init.sh
    _TOKEN_PHASH=$(project_hash "${PROJECT_ROOT:-}" 2>/dev/null || echo "")
    _TOKEN_PNAME=$(basename "${PROJECT_ROOT:-unknown}" 2>/dev/null || echo "unknown")
    # @decision DEC-NO-TRIM-001
    # @title Remove 100-line trim from session history files
    # @status accepted
    # @rationale Each entry is ~80 bytes. Even 10,000 entries (3 years at 10 sessions/day)
    #   is under 1MB. The trim was destroying valuable historical data (token spending,
    #   cost tracking) for negligible disk savings. Users should never lose history they
    #   might want to analyze. If size management is ever needed, annual rotation is
    #   more appropriate than aggressive trimming.
    echo "${_TOKEN_TS}|${_SESSION_TOKENS}|${_MAIN_TOKENS}|${_SUBAGENT_TOTAL}|${CLAUDE_SESSION_ID:-unknown}|${_TOKEN_PHASH}|${_TOKEN_PNAME}" >> "$_TOKEN_HISTORY"
fi
log_info "SESSION-END" "Persisted session tokens: main=${_MAIN_TOKENS} subagent=${_SUBAGENT_TOTAL} total=${_SESSION_TOKENS}"

# --- Age-based .agent-findings cleanup ---
# Findings accumulate from agent hooks and are surfaced in session-init.
# Clear stale findings so resolved issues stop re-surfacing.
# No per-entry timestamp exists, so we age the whole file: if the file is
# older than 3 days (~3+ sessions), it likely contains stale noise.
FINDINGS_FILE="${CLAUDE_DIR}/.agent-findings"
if [[ -f "$FINDINGS_FILE" ]]; then
    FINDINGS_AGE=$(( $(date +%s) - $(_file_mtime "$FINDINGS_FILE") ))
    # Clear if older than 3 days (259200 seconds) — roughly 3+ sessions
    if [[ "$FINDINGS_AGE" -gt 259200 ]]; then
        rm -f "$FINDINGS_FILE"
        log_info "SESSION-END" "Cleaned stale .agent-findings (${FINDINGS_AGE}s old)"
    fi
fi

# --- Clean up .active-* trace markers for this session ---
# Active markers are named .active-TYPE-SESSION_ID-PHASH. When a session ends normally,
# finalize_trace() already removes the marker via the SubagentStop hook. But if
# the session ends without SubagentStop firing (crash, /clear, early exit), the
# marker lingers indefinitely, accumulating as an orphan. Cleaning all markers
# for the current session here ensures they are always removed on clean exits.
#
# The glob uses a trailing * after SESSION_ID to match the phash suffix introduced
# in DEC-ISOLATION-002: .active-TYPE-SESSION-PHASH
#
# @decision DEC-OBS-OVERHAUL-005
# @title Clean session .active-* markers in session-end.sh
# @status accepted
# @rationale Issue #102: 4 orphaned markers accumulated because SubagentStop
#   didn't fire (or fired after a race). session-end.sh always fires on clean
#   exit and provides a reliable second cleanup path. We remove only markers
#   for the current CLAUDE_SESSION_ID, leaving other sessions' markers intact.
#   The init_trace 2-hour age-based cleanup remains the backstop for crashed
#   sessions where even session-end doesn't fire.
#   Updated: trailing * on glob matches phash suffix (.active-TYPE-SESSION-PHASH).
SESSION_TRACE_STORE="${TRACE_STORE:-$HOME/.claude/traces}"
if [[ -n "${CLAUDE_SESSION_ID:-}" && -d "$SESSION_TRACE_STORE" ]]; then
    for _active_marker in "${SESSION_TRACE_STORE}/.active-"*"-${CLAUDE_SESSION_ID}"*; do
        [[ -f "$_active_marker" ]] && rm -f "$_active_marker" && \
            log_info "SESSION-END" "Removed active marker: $(basename "$_active_marker")"
    done
fi

# --- TTL-based trace directory cleanup (7 days) ---
# @decision DEC-TRACE-TTL-001
# @title Age-based trace directory cleanup runs at session-end
# @status accepted
# @rationale cleanup_stale_traces() (defined in trace-lib.sh) removes trace dirs
#   older than 7 days. Running it at session-end (once per session) is low-frequency
#   enough to avoid performance impact while preventing unbounded growth. The function
#   returns the count of cleaned dirs so we can log meaningful diagnostics.
require_trace
_TRACES_CLEANED=$(cleanup_stale_traces 2>/dev/null || echo "0")
if [[ "${_TRACES_CLEANED:-0}" -gt 0 ]]; then
    log_info "SESSION-END" "Cleaned $_TRACES_CLEANED stale trace(s) (>7 days)"
fi

# --- Log rotation (keep last 2000 lines) ---
# @decision DEC-LOG-ROTATE-001
# @title Rotate hook log files at session-end to prevent unbounded growth
# @status accepted
# @rationale .hook-timing.log and .hook-deny.log grow with every hook invocation.
#   A busy session (100+ prompts, each triggering 5-10 hooks) produces thousands
#   of log lines per session. 2000 lines keeps ~2-3 weeks of history under normal
#   usage while bounding disk usage to ~200KB per file. tail-then-mv is atomic
#   on POSIX filesystems (mv is atomic within the same filesystem).
for _log_file in "${CLAUDE_DIR}/.hook-timing.log" "${CLAUDE_DIR}/.hook-deny.log"; do
    if [[ -f "$_log_file" ]]; then
        _log_lines=$(wc -l < "$_log_file" 2>/dev/null | tr -d ' ')
        if [[ "${_log_lines:-0}" -gt 2000 ]]; then
            tail -2000 "$_log_file" > "${_log_file}.tmp" && mv "${_log_file}.tmp" "$_log_file"
        fi
    fi
done

# --- Orphaned .subagent-tokens-* cleanup (>4 hours) ---
# @decision DEC-TOKEN-SWEEP-001
# @title Age-based sweep of orphaned .subagent-tokens-* files
# @status accepted
# @rationale Each subagent invocation creates a session-scoped .subagent-tokens-<SESSION_ID>
#   file. The current session's file is cleaned in the session-scoped cleanup block below.
#   Files from crashed or interrupted sessions linger indefinitely. A sweep at session-end
#   removes any that are >4 hours old — long enough to not affect any legitimate concurrent
#   session, short enough to prevent accumulation. The 4-hour threshold is conservative:
#   no agent session legitimately runs for more than ~30 minutes (max_turns enforcement).
_NOW_EPOCH=$(date +%s)
for _stale_token_file in "${CLAUDE_DIR}/.subagent-tokens-"*; do
    [[ -f "$_stale_token_file" ]] || continue
    # Skip current session's file (already cleaned in session-scoped block below)
    [[ "$_stale_token_file" == *"-${CLAUDE_SESSION_ID:-$$}" ]] && continue
    _token_mtime=$(_file_mtime "$_stale_token_file")
    if (( _NOW_EPOCH - _token_mtime > 14400 )); then  # 4 hours
        rm -f "$_stale_token_file"
    fi
done

# --- Stale state file cleanup ---
# @decision DEC-STATE-SWEEP-001
# @title Sweep stale state files: lock files, CI status, statusline temps
# @status accepted
# @rationale Lock files (.proof-status.lock, .state.lock) are scoped to a single
#   operation and should never survive a session exit. If the session ends normally,
#   the locking operation completed and the lock is no longer needed. If the session
#   crashes, the lock is a zombie — removing it on next session-end unblocks future
#   operations. CI status files (.ci-status-*) are per-run; files >24h are stale
#   because CI runs complete in minutes. Statusline temp files (.statusline-cache.tmp.*)
#   are left by interrupted statusline renders and have no utility after session-end.
rm -f "${CLAUDE_DIR}/.proof-status.lock" "${CLAUDE_DIR}/.state.lock"
rm -f "${CLAUDE_DIR}/state/locks/proof.lock" "${CLAUDE_DIR}/state/locks/state.lock" 2>/dev/null || true

# CI status files older than 24 hours
for _ci_file in "${CLAUDE_DIR}/.ci-status-"*; do
    [[ -f "$_ci_file" ]] || continue
    _ci_mtime=$(_file_mtime "$_ci_file")
    if (( _NOW_EPOCH - _ci_mtime > 86400 )); then  # 24 hours
        rm -f "$_ci_file"
    fi
done

# Proof-status files with no active markers (cross-project sweep)
# @decision DEC-PROOF-SWEEP-001
# @title Marker-based sweep of orphaned .proof-status-* files at session-end
# @status accepted
# @rationale TTL-based sweep (4h) was a time proxy for ownership — a concurrent session
#   idle >4h would have its proof file deleted. The marker-based approach checks if ANY
#   .active-*-{phash} marker exists in TRACE_STORE. No markers → orphaned → delete.
#   Empty-hash files (.proof-status- from Bug A) are always deleted (no valid phash).
#   Marker cleanup has its own age-based backstops (30min in init_trace, 15min in
#   session-init), so no TTL backstop is needed here. Supersedes the 4-hour TTL from
#   commit 0b1c20a.
for _proof_file in "${CLAUDE_DIR}/.proof-status-"*; do
    [[ -f "$_proof_file" ]] || continue
    [[ "$_proof_file" == *.lock ]] && continue

    # Extract phash from filename: .proof-status-{8hex}
    _proof_basename="${_proof_file##*/}"
    _proof_phash="${_proof_basename#.proof-status-}"

    # Bug A empty hash: always safe to delete (no project owns it)
    if [[ -z "$_proof_phash" ]]; then
        rm -f "$_proof_file"
        continue
    fi

    # Marker-based ownership: ANY active marker for this phash means "in use"
    _has_markers=false
    for _marker in "${SESSION_TRACE_STORE}/.active-"*"-${_proof_phash}"; do
        if [[ -f "$_marker" ]]; then
            _has_markers=true
            break
        fi
    done

    if [[ "$_has_markers" == "false" ]]; then
        rm -f "$_proof_file"
    fi
done
# New format sweep: state/{phash}/proof-status files older than 4 hours
for _state_proj_dir in "${CLAUDE_DIR}/state/"*/; do
    [[ -d "$_state_proj_dir" ]] || continue
    _s_proof="${_state_proj_dir}proof-status"
    [[ -f "$_s_proof" ]] || continue
    _s_mtime=$(_file_mtime "$_s_proof")
    if (( _NOW_EPOCH - _s_mtime > 14400 )); then  # 4 hours
        rm -f "$_s_proof"
        rmdir "$_state_proj_dir" 2>/dev/null || true  # Clean empty state dirs
    fi
done

# Stale statusline temp files (interrupted renders leave these behind)
rm -f "${CLAUDE_DIR}/.statusline-cache.tmp."*
# Session-scoped statusline cache (per-instance, cleaned on exit)
rm -f "${CLAUDE_DIR}/.statusline-cache-${CLAUDE_SESSION_ID:-$$}"

# Orphaned statusline cache files from crashed sessions (>4 hours)
for _stale_cache in "${CLAUDE_DIR}/.statusline-cache-"*; do
    [[ -f "$_stale_cache" ]] || continue
    [[ "$_stale_cache" == *.tmp.* ]] && continue
    _cache_mtime=$(_file_mtime "$_stale_cache")
    if (( _NOW_EPOCH - _cache_mtime > 14400 )); then  # 4 hours
        rm -f "$_stale_cache"
    fi
done

# --- Clean up session-scoped files (these don't persist) ---
# Clean up orchestrator session marker (written by session-init.sh at startup)
# Primary: delete from SQLite KV store (DEC-STATE-KV-001)
state_delete "orchestrator_sid" 2>/dev/null || true
# Fallback: remove flat-file for backward compat during migration (DEC-STATE-UNIFY-004)
rm -f "${CLAUDE_DIR}/.orchestrator-sid" 2>/dev/null || true
rm -f "${CLAUDE_DIR}/.session-events.jsonl"
rm -f "${CLAUDE_DIR}/.session-changes"*
rm -f "${CLAUDE_DIR}/.session-decisions"*
# DEC-STATE-KV-002: delete prompt_count and session_start_epoch from SQLite KV (primary)
state_delete "prompt_count" 2>/dev/null || true
state_delete "session_start_epoch" 2>/dev/null || true
# Flat-file fallback cleanup during migration window
rm -f "${CLAUDE_DIR}/.prompt-count-"*
rm -f "${CLAUDE_DIR}/.lint-cache"
rm -f "${CLAUDE_DIR}/.test-runner."*
rm -f "${CLAUDE_DIR}/.test-gate-strikes"
rm -f "${CLAUDE_DIR}/.test-gate-cold-warned"
rm -f "${CLAUDE_DIR}/.mock-gate-strikes"
rm -f "${CLAUDE_DIR}/.track."*
rm -f "${CLAUDE_DIR}/.skill-result"*
rm -f "${CLAUDE_DIR}/.subagent-tracker-${CLAUDE_SESSION_ID:-$$}"
rm -f "${CLAUDE_DIR}/.subagent-tokens-${CLAUDE_SESSION_ID:-$$}"
rm -f "${CLAUDE_DIR}/.agent-progress"
rm -f "${CLAUDE_DIR}/.session-main-tokens"
rm -f "${CLAUDE_DIR}/.cwd-recovery-needed"
# .proof-epoch flat file removed (DEC-STATE-DOTFILE-001) — epoch state in SQLite only
rm -f "${CLAUDE_DIR}/.stop-surface-"*
rm -f "${CLAUDE_DIR}/.stop-todo-ttl"
# .stop-backup-ttl intentionally persists (global, once per hour)
# DEC-PERF-004: warm-path caches — session-scoped, delete on exit
rm -f "${CLAUDE_DIR}/.stop-git-cache-"*
rm -f "${CLAUDE_DIR}/.stop-plan-cache-"*
# Migration cleanup: remove double-nested and tmp proof files (Bug E legacy paths)
rm -f "${CLAUDE_DIR}/.claude/.proof-status" 2>/dev/null
rm -f "${CLAUDE_DIR}/tmp/.proof-status" 2>/dev/null

# DO NOT delete (cross-session state):
#   .audit-log       — persistent audit trail
#   .agent-findings  — pending agent issues
#   .lint-breaker    — circuit breaker state
#   .plan-drift      — decision drift data from last surface audit
# NOTE: .test-status is cleared at session START (session-init.sh), not here.
# It must survive session-end so session-init can read it for context injection,
# then clears it to prevent stale results from satisfying the commit gate.

log_info "SESSION-END" "Cleanup complete"
exit 0
