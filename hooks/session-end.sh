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

# --- Kill THIS session's async test-runner process (scoped by lock file) ---
# test-runner.sh runs async (PostToolUse) and writes its PID to
# $PROJECT_ROOT/.claude/.test-runner.lock so that only this session's process
# is killed, not test-runners belonging to concurrent sessions in other
# project worktrees (#132-134: blanket pkill -f was cross-session unsafe).
#
# @decision DEC-SESEND-001
# @title Kill test-runner via lock file PID, not blanket pkill
# @status accepted
# @rationale pgrep/pkill -f "test-runner.sh" matches ALL test-runner processes
#   across every concurrently active session. For multi-worktree setups one
#   session ending would kill another project's test-runner. Scoping the kill
#   to the lock file PID (which is project-root-specific) makes the operation
#   safe under concurrent worktree usage. Fixes #132-134.
_TR_LOCK="$PROJECT_ROOT/.claude/.test-runner.lock"
if [[ -f "$_TR_LOCK" ]]; then
    _TR_PID=$(cat "$_TR_LOCK" 2>/dev/null || echo "")
    if [[ -n "$_TR_PID" ]] && kill -0 "$_TR_PID" 2>/dev/null; then
        # Kill child processes first, then the runner itself
        pkill -P "$_TR_PID" 2>/dev/null || true
        kill "$_TR_PID" 2>/dev/null || true
        log_info "SESSION-END" "Killed test-runner PID $_TR_PID for $PROJECT_ROOT"
    fi
    rm -f "$_TR_LOCK"
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
