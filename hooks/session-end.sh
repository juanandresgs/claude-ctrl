#!/usr/bin/env bash
set -euo pipefail

# Session cleanup on termination.
# SessionEnd hook — runs once when session actually ends.
#
# Cleans up:
#   - Session tracking files (.session-changes-*)
#   - Lint cache files (.lint-cache)
#   - Temporary tracking artifacts

source "$(dirname "$0")/log.sh"

# Optimization: Stream input directly to jq to avoid loading potentially
# large session history into a Bash variable (which consumes ~3-4x RAM).
# HOOK_INPUT=$(read_input) <- removing this
REASON=$(jq -r '.reason // "unknown"' 2>/dev/null || echo "unknown")

PROJECT_ROOT=$(detect_project_root)

log_info "SESSION-END" "Session ending (reason: $REASON)"

# --- Clean up session-scoped files (these don't persist) ---
rm -f "$PROJECT_ROOT/.claude/.session-changes"*
rm -f "$PROJECT_ROOT/.claude/.session-decisions"*
rm -f "$PROJECT_ROOT/.claude/.prompt-count-"*
rm -f "$PROJECT_ROOT/.claude/.lint-cache"
rm -f "$PROJECT_ROOT/.claude/.test-runner."*
rm -f "$PROJECT_ROOT/.claude/.test-gate-strikes"
rm -f "$PROJECT_ROOT/.claude/.test-gate-cold-warned"
rm -f "$PROJECT_ROOT/.claude/.mock-gate-strikes"
rm -f "$PROJECT_ROOT/.claude/.track."*

# DO NOT delete (cross-session state):
#   .audit-log       — persistent audit trail
#   .agent-findings  — pending agent issues
#   .lint-breaker    — circuit breaker state
# NOTE: .test-status is cleared at session START (session-init.sh), not here.
# It must survive session-end so session-init can read it for context injection,
# then clears it to prevent stale results from satisfying the commit gate.

# --- Trim audit log to prevent unbounded growth (keep last 100 entries) ---
AUDIT_LOG="$PROJECT_ROOT/.claude/.audit-log"
if [[ -f "$AUDIT_LOG" ]]; then
    LINES=$(wc -l < "$AUDIT_LOG" | tr -d ' ')
    if [[ "$LINES" -gt 100 ]]; then
        tail -100 "$AUDIT_LOG" > "${AUDIT_LOG}.tmp"
        mv "${AUDIT_LOG}.tmp" "$AUDIT_LOG"
    fi
fi

log_info "SESSION-END" "Cleanup complete"
exit 0
