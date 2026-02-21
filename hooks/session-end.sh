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

# Redirect stderr to /dev/null — log_info writes to stderr, and Claude Code
# treats any stderr output from SessionEnd hooks as a failure even when exit
# code is 0. Nobody reads diagnostic messages at session termination anyway.
exec 2>/dev/null

# Optimization: Stream input directly to jq to avoid loading potentially
# large session history into a Bash variable (which consumes ~3-4x RAM).
# HOOK_INPUT=$(read_input) <- removing this
REASON=$(jq -r '.reason // "unknown"' 2>/dev/null || echo "unknown")

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)

log_info "SESSION-END" "Session ending (reason: $REASON)"

# --- Release active todo claims for this session ---
TODO_SCRIPT="$HOME/.claude/scripts/todo.sh"
if [[ -x "$TODO_SCRIPT" ]]; then
    "$TODO_SCRIPT" unclaim --session="${CLAUDE_SESSION_ID:-$$}" 2>/dev/null || true
fi

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
    PROJECT_HASH=$(echo "$PROJECT_ROOT" | shasum -a 256 2>/dev/null | cut -c1-12)
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
    # Check scoped proof-status first, fall back to legacy for backward compat.
    OUTCOME="unknown"
    _SES_PHASH=$(project_hash "$PROJECT_ROOT")
    _SCOPED_PROOF="${CLAUDE_DIR}/.proof-status-${_SES_PHASH}"
    if [[ -f "$_SCOPED_PROOF" ]]; then
        PROOF_FILE="$_SCOPED_PROOF"
    elif [[ -f "${CLAUDE_DIR}/.proof-status" ]]; then
        PROOF_FILE="${CLAUDE_DIR}/.proof-status"
    else
        PROOF_FILE=""
    fi
    TEST_STATUS_FILE="${CLAUDE_DIR}/.test-status"
    if [[ -n "$PROOF_FILE" && -f "$PROOF_FILE" ]]; then
        PS_VAL=$(cut -d'|' -f1 "$PROOF_FILE" 2>/dev/null || echo "")
        [[ "$PS_VAL" == "verified" ]] && OUTCOME="committed"
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

# --- Age-based .agent-findings cleanup ---
# Findings accumulate from agent hooks and are surfaced in session-init.
# Clear stale findings so resolved issues stop re-surfacing.
# No per-entry timestamp exists, so we age the whole file: if the file is
# older than 3 days (~3+ sessions), it likely contains stale noise.
FINDINGS_FILE="${CLAUDE_DIR}/.agent-findings"
if [[ -f "$FINDINGS_FILE" ]]; then
    if [[ "$(uname)" == "Darwin" ]]; then
        FINDINGS_AGE=$(( $(date +%s) - $(stat -f %m "$FINDINGS_FILE" 2>/dev/null || echo "0") ))
    else
        FINDINGS_AGE=$(( $(date +%s) - $(stat -c %Y "$FINDINGS_FILE" 2>/dev/null || echo "0") ))
    fi
    # Clear if older than 3 days (259200 seconds) — roughly 3+ sessions
    if [[ "$FINDINGS_AGE" -gt 259200 ]]; then
        rm -f "$FINDINGS_FILE"
        log_info "SESSION-END" "Cleaned stale .agent-findings (${FINDINGS_AGE}s old)"
    fi
fi

# --- Clean up .active-* trace markers for this session ---
# Active markers are named .active-TYPE-SESSION_ID. When a session ends normally,
# finalize_trace() already removes the marker via the SubagentStop hook. But if
# the session ends without SubagentStop firing (crash, /clear, early exit), the
# marker lingers indefinitely, accumulating as an orphan. Cleaning all markers
# for the current session here ensures they are always removed on clean exits.
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
SESSION_TRACE_STORE="${TRACE_STORE:-$HOME/.claude/traces}"
if [[ -n "${CLAUDE_SESSION_ID:-}" && -d "$SESSION_TRACE_STORE" ]]; then
    for _active_marker in "${SESSION_TRACE_STORE}/.active-"*"-${CLAUDE_SESSION_ID}"; do
        [[ -f "$_active_marker" ]] && rm -f "$_active_marker" && \
            log_info "SESSION-END" "Removed active marker: $(basename "$_active_marker")"
    done
fi

# --- Clean up session-scoped files (these don't persist) ---
rm -f "${CLAUDE_DIR}/.session-events.jsonl"
rm -f "${CLAUDE_DIR}/.session-changes"*
rm -f "${CLAUDE_DIR}/.session-decisions"*
rm -f "${CLAUDE_DIR}/.prompt-count-"*
rm -f "${CLAUDE_DIR}/.lint-cache"
rm -f "${CLAUDE_DIR}/.test-runner."*
rm -f "${CLAUDE_DIR}/.test-gate-strikes"
rm -f "${CLAUDE_DIR}/.test-gate-cold-warned"
rm -f "${CLAUDE_DIR}/.mock-gate-strikes"
rm -f "${CLAUDE_DIR}/.track."*
rm -f "${CLAUDE_DIR}/.skill-result"*
rm -f "${CLAUDE_DIR}/.subagent-tracker-${CLAUDE_SESSION_ID:-$$}"
rm -f "${CLAUDE_DIR}/.active-worktree-path"*
rm -f "${CLAUDE_DIR}/.cwd-recovery-needed"

# DO NOT delete (cross-session state):
#   .audit-log       — persistent audit trail
#   .agent-findings  — pending agent issues
#   .lint-breaker    — circuit breaker state
#   .plan-drift      — decision drift data from last surface audit
# NOTE: .test-status is cleared at session START (session-init.sh), not here.
# It must survive session-end so session-init can read it for context injection,
# then clears it to prevent stale results from satisfying the commit gate.

# --- Trim audit log to prevent unbounded growth (keep last 100 entries) ---
AUDIT_LOG="${CLAUDE_DIR}/.audit-log"
if [[ -f "$AUDIT_LOG" ]]; then
    LINES=$(wc -l < "$AUDIT_LOG" | tr -d ' ')
    if [[ "$LINES" -gt 100 ]]; then
        tail -100 "$AUDIT_LOG" > "${AUDIT_LOG}.tmp"
        mv "${AUDIT_LOG}.tmp" "$AUDIT_LOG"
    fi
fi

log_info "SESSION-END" "Cleanup complete"
exit 0
