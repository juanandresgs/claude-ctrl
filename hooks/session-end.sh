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
source "$(dirname "$0")/context-lib.sh"

# Optimization: Stream input directly to jq to avoid loading potentially
# large session history into a Bash variable (which consumes ~3-4x RAM).
# HOOK_INPUT=$(read_input) <- removing this
REASON=$(jq -r '.reason // "unknown"' 2>/dev/null || echo "unknown")

PROJECT_ROOT=$(detect_project_root)

log_info "SESSION-END" "Session ending (reason: $REASON)"

# --- Release active todo claims for this session ---
TODO_SCRIPT="$HOME/.claude/scripts/todo.sh"
if [[ -x "$TODO_SCRIPT" ]]; then
    "$TODO_SCRIPT" unclaim --session="$(canonical_session_id)" 2>/dev/null || true
fi

# --- Kill lingering async test-runner processes ---
# test-runner.sh runs async (PostToolUse). If it's still running when the session
# ends, its output will never be consumed. Kill it to prevent orphaned processes.
if pgrep -f "test-runner\\.sh" >/dev/null 2>&1; then
    pkill -f "test-runner\\.sh" 2>/dev/null || true
    log_info "SESSION-END" "Killed lingering test-runner process(es)"
fi

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
#   .lint-breaker    — circuit breaker state
# NOTE: .test-status is cleared at session START (session-init.sh), not here.
# It must survive session-end so session-init can read it for context injection,
# then clears it to prevent stale results from satisfying the commit gate.
#
# TKT-008 removals — these flat files are no longer written and need no trimming:
#   .audit-log       — audit trail now lives in SQLite (runtime event store)
#   .agent-findings  — findings emitted via rt_event_emit "agent_finding"
#   .plan-drift      — drift scoring removed; commit-count heuristic used instead

log_info "SESSION-END" "Cleanup complete"
exit 0
