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
#
# Persists (does NOT delete):
#   - .audit-log — persistent audit trail
#   - .agent-findings — pending agent issues
#   - .lint-breaker — circuit breaker state
#   - .plan-drift — decision drift data
#   - .test-status — cleared at session START, not here

set -euo pipefail

source "$(dirname "$0")/log.sh"

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

# --- Clean up session-scoped files (these don't persist) ---
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
