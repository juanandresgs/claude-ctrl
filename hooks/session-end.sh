#!/usr/bin/env bash
set -euo pipefail

# Session cleanup on termination.
# SessionEnd hook — runs once when session actually ends.
#
# Marks DB-backed session activity ended and cleans up retired legacy flatfiles
# plus process-local temp/lock artifacts.

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

# Optimization: stream input directly to jq to avoid loading potentially
# large session history into a Bash variable (which consumes ~3-4x RAM).
_SESSION_META=$(jq -r '[.reason // "unknown", .session_id // ""] | @tsv' 2>/dev/null || printf 'unknown\t')
IFS=$'\t' read -r REASON HOOK_SESSION_ID <<< "$_SESSION_META"
SESSION_ID="${HOOK_SESSION_ID:-$(canonical_session_id)}"

PROJECT_ROOT=$(detect_project_root)

log_info "SESSION-END" "Session ending (reason: $REASON)"

# --- Release active todo claims for this session ---
TODO_SCRIPT="$HOME/.claude/scripts/todo.sh"
if [[ -x "$TODO_SCRIPT" ]]; then
    "$TODO_SCRIPT" unclaim --session="$SESSION_ID" 2>/dev/null || true
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

# Observatory: emit session_summary metric from DB-backed session activity.
_obs_session_id="$SESSION_ID"
_obs_session_json=$(cc_policy session-activity get \
    --project-root "$PROJECT_ROOT" \
    --session-id "$_obs_session_id" 2>/dev/null || echo '{"prompt_count":0,"started_at":0}')
_obs_start_epoch=$(printf '%s' "$_obs_session_json" | jq -r '.started_at // 0' 2>/dev/null || echo "0")
_obs_prompt_count=$(printf '%s' "$_obs_session_json" | jq -r '.prompt_count // 0' 2>/dev/null || echo "0")
_obs_now=$(date +%s)
_obs_session_duration=0
if [[ "$_obs_start_epoch" -gt 0 ]]; then
    _obs_session_duration=$(( _obs_now - _obs_start_epoch ))
fi
rt_obs_metric session_summary "$_obs_session_duration" \
    "{\"prompt_count\":${_obs_prompt_count:-0}}" "" "" || true
cc_policy session-activity end \
    --project-root "$PROJECT_ROOT" \
    --session-id "$_obs_session_id" >/dev/null 2>&1 || true

# --- Clean up retired legacy session flatfiles and ephemeral process files ---
rm -f "$PROJECT_ROOT/.claude/.session-changes"* "$PROJECT_ROOT/.claude/.session-decisions"*
rm -f "$PROJECT_ROOT/.claude/.prompt-count-"* "$PROJECT_ROOT/.claude/.session-start-epoch"
rm -f "$PROJECT_ROOT/.claude/.lint-cache" "$PROJECT_ROOT/.claude/.lint-cache-"*
rm -f "$PROJECT_ROOT/.claude/.test-runner."*
rm -f "$PROJECT_ROOT/.claude/.test-gate-strikes"
rm -f "$PROJECT_ROOT/.claude/.test-gate-cold-warned"
rm -f "$PROJECT_ROOT/.claude/.mock-gate-strikes"
rm -f "$PROJECT_ROOT/.claude/.track."*

# --- Clean up empty scratchlane roots for this completed session ---
# The runtime cleanup is deliberately rmdir-only: it only targets active
# scratchlane permit roots under PROJECT_ROOT/tmp for this session, ignores
# known local clutter such as .DS_Store, and preserves any substantive content.
_SCRATCH_CLEANUP=$(cc_policy scratchlane cleanup-empty \
    --project-root "$PROJECT_ROOT" \
    --session-id "$SESSION_ID" \
    2>/dev/null || echo '{"removed_count":0}')
_SCRATCH_REMOVED=$(printf '%s' "$_SCRATCH_CLEANUP" | jq -r '.removed_count // 0' 2>/dev/null || echo "0")
if [[ "$_SCRATCH_REMOVED" -gt 0 ]]; then
    log_info "SESSION-END" "Removed $_SCRATCH_REMOVED empty scratchlane root(s) for $PROJECT_ROOT"
fi

# Durable cross-session state lives in state.db. Do not delete it here.
#
# TKT-008 removals — these flat files are no longer written and need no trimming:
#   .audit-log       — audit trail now lives in SQLite (runtime event store)
#   .agent-findings  — findings emitted via rt_event_emit "agent_finding"
#   .plan-drift      — drift scoring removed; commit-count heuristic used instead

log_info "SESSION-END" "Cleanup complete"
exit 0
