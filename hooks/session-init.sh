#!/usr/bin/env bash
set -euo pipefail

# Session context injection at startup.
# SessionStart hook — matcher: startup|resume|clear|compact
#
# Injects project context into the session:
#   - Git state (branch, dirty files, on-main warning)
#   - MASTER_PLAN.md existence and status
#   - Active worktrees
#   - Stale session files from crashed sessions
#
# Known: SessionStart has a bug (Issue #10373) where output may not inject
# for brand-new sessions. Works for /clear, /compact, resume. Implement
# anyway — when it works it's valuable, when it doesn't there's no harm.

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

PROJECT_ROOT=$(detect_project_root)
CONTEXT_PARTS=()

# --- Git state ---
get_git_state "$PROJECT_ROOT"

if [[ -n "$GIT_BRANCH" ]]; then
    GIT_LINE="Git: branch=$GIT_BRANCH"
    [[ "$GIT_DIRTY_COUNT" -gt 0 ]] && GIT_LINE="$GIT_LINE | $GIT_DIRTY_COUNT uncommitted"
    [[ "$GIT_WT_COUNT" -gt 0 ]] && GIT_LINE="$GIT_LINE | $GIT_WT_COUNT worktrees"
    CONTEXT_PARTS+=("$GIT_LINE")

    if [[ "$GIT_BRANCH" == "main" || "$GIT_BRANCH" == "master" ]]; then
        CONTEXT_PARTS+=("WARNING: On $GIT_BRANCH branch. Sacred Practice #2: create a worktree before making changes.")
    fi
fi

# --- MASTER_PLAN.md ---
# write_statusline_cache removed (TKT-008): statusline.sh reads runtime directly.
get_plan_status "$PROJECT_ROOT"

if [[ "$PLAN_EXISTS" == "true" ]]; then
    PLAN_LINE="Plan:"
    [[ "$PLAN_TOTAL_PHASES" -gt 0 ]] && PLAN_LINE="$PLAN_LINE $PLAN_COMPLETED_PHASES/$PLAN_TOTAL_PHASES phases"
    [[ -n "$PLAN_PHASE" ]] && PLAN_LINE="$PLAN_LINE | active: $PLAN_PHASE"
    [[ "$PLAN_AGE_DAYS" -gt 0 ]] && PLAN_LINE="$PLAN_LINE | age: ${PLAN_AGE_DAYS}d"
    CONTEXT_PARTS+=("$PLAN_LINE")

    if [[ "$PLAN_SOURCE_CHURN_PCT" -ge 10 ]]; then
        CONTEXT_PARTS+=("WARNING: Plan may be stale (${PLAN_SOURCE_CHURN_PCT}% source file churn since last update)")
    fi
else
    CONTEXT_PARTS+=("Plan: not found (required before implementation)")
fi

# --- Research status ---
get_research_status "$PROJECT_ROOT"
if [[ "$RESEARCH_EXISTS" == "true" ]]; then
    CONTEXT_PARTS+=("Research: $RESEARCH_ENTRY_COUNT entries | recent: $RESEARCH_RECENT_TOPICS")
fi

# --- Expire stale leases and show active lease (Phase 2) ---
# Expire any TTL-exceeded leases so they do not block new dispatch.
# Then display the active lease (if any) for situational awareness.
rt_lease_expire_stale || true
if ! is_claude_meta_repo "$PROJECT_ROOT"; then
    _SESS_LEASE=$(rt_lease_current "$PROJECT_ROOT")
    _SESS_LEASE_FOUND=$(printf '%s' "${_SESS_LEASE:-}" | jq -r 'if .found then "yes" else "no" end' 2>/dev/null || echo "no")
    if [[ "$_SESS_LEASE_FOUND" == "yes" ]]; then
        _SESS_LEASE_ID=$(printf '%s' "$_SESS_LEASE" | jq -r '.lease_id // empty' 2>/dev/null || true)
        _SESS_LEASE_ROLE=$(printf '%s' "$_SESS_LEASE" | jq -r '.role // empty' 2>/dev/null || true)
        _SESS_LEASE_OPS=$(printf '%s' "$_SESS_LEASE" | jq -r '.allowed_ops_json // empty' 2>/dev/null || true)
        CONTEXT_PARTS+=("Active lease: id=${_SESS_LEASE_ID} role=${_SESS_LEASE_ROLE} ops=${_SESS_LEASE_OPS}")
    fi
    unset _SESS_LEASE _SESS_LEASE_FOUND _SESS_LEASE_ID _SESS_LEASE_ROLE _SESS_LEASE_OPS
fi

# --- Stale marker advisory (TKT-023) ---
# If a subagent marker has been active for >=300s at session start, warn the
# incoming agent. The marker may belong to a crashed or abandoned subagent.
# Uses the same cc-policy CLI path as statusline.sh. Soft advisory only —
# no block, no write. Suppressed when the runtime is unavailable.
_RUNTIME_ROOT="${CLAUDE_RUNTIME_ROOT:-$HOME/.claude/runtime}"
if [[ -f "$_RUNTIME_ROOT/cli.py" ]]; then
    _snap=$(python3 "$_RUNTIME_ROOT/cli.py" statusline snapshot 2>/dev/null || true)
    if [[ -n "$_snap" ]]; then
        _active_agent=$(printf '%s' "$_snap" | jq -r '.active_agent // empty' 2>/dev/null || true)
        _marker_age=$(printf '%s' "$_snap" | jq -r '.marker_age_seconds // 0' 2>/dev/null || echo "0")
        [[ "$_active_agent" == "null" ]] && _active_agent=""
        [[ "${_marker_age:-0}" =~ ^[0-9]+$ ]] || _marker_age=0
        if [[ -n "$_active_agent" && "${_marker_age:-0}" -ge 300 ]]; then
            _age_min=$(( _marker_age / 60 ))
            CONTEXT_PARTS+=("WARNING: Active subagent marker ($_active_agent) is ${_age_min}m old and may be stale. If the previous subagent crashed, deactivate via: cc-policy marker deactivate <agent_id>")
        fi
    fi
fi
unset _RUNTIME_ROOT _snap _active_agent _marker_age _age_min

# --- Workflow evaluation state (TKT-024) ---
# Shows evaluation_state as the readiness display. proof_state is deprecated
# with zero enforcement effect and is no longer shown here.
if ! is_claude_meta_repo "$PROJECT_ROOT"; then
    _SESS_EVAL_STATUS=$(read_evaluation_status "$PROJECT_ROOT")
    case "$_SESS_EVAL_STATUS" in
        ready_for_guardian)
            CONTEXT_PARTS+=("Evaluation: ready_for_guardian — Guardian may proceed to commit/merge.")
            ;;
        needs_changes)
            CONTEXT_PARTS+=("Evaluation: needs_changes — Tester found issues. Implementer should address them.")
            ;;
        blocked_by_plan)
            CONTEXT_PARTS+=("Evaluation: blocked_by_plan — Tester flagged a plan gap. Dispatch Planner.")
            ;;
        pending)
            CONTEXT_PARTS+=("Evaluation: pending — awaiting Tester evaluation.")
            ;;
        # idle: no output (background noise)
    esac
    unset _SESS_EVAL_STATUS
fi

# --- Enforcement gaps ---
# Persist across sessions — surface any open gaps so the model knows
# enforcement is degraded before it writes anything.
GAPS_FILE="${PROJECT_ROOT}/.claude/.enforcement-gaps"
if [[ -f "$GAPS_FILE" && -s "$GAPS_FILE" ]]; then
    GAP_COUNT=0
    while IFS='|' read -r gap_type ext tool _first _count; do
        [[ -z "$gap_type" ]] && continue
        GAP_COUNT=$(( GAP_COUNT + 1 ))
        if [[ "$gap_type" == "unsupported" ]]; then
            CONTEXT_PARTS+=("ENFORCEMENT DEGRADED: No linter profile for .${ext} files (unsupported). Writes to .${ext} source files are not being linted. Add a linter config to restore enforcement.")
        else
            CONTEXT_PARTS+=("ENFORCEMENT DEGRADED: Linter '${tool}' for .${ext} files is not installed (missing_dep). Install '${tool}' to restore lint enforcement.")
        fi
    done < "$GAPS_FILE"
fi

# --- Preserved context from pre-compaction ---
# compact-preserve.sh writes .preserved-context before compaction.
# Re-inject it here so the post-compaction session has full context
# even if the additionalContext from PreCompact was lost in summarization.
PRESERVE_FILE="${PROJECT_ROOT}/.claude/.preserved-context"
if [[ -f "$PRESERVE_FILE" && -s "$PRESERVE_FILE" ]]; then
    CONTEXT_PARTS+=("Preserved context from before compaction:")
    while IFS= read -r line; do
        # Skip the header comment
        [[ "$line" =~ ^#.* ]] && continue
        [[ -z "$line" ]] && continue
        CONTEXT_PARTS+=("  $line")
    done < "$PRESERVE_FILE"
    # One-time use: remove after injecting so it doesn't persist across sessions
    rm -f "$PRESERVE_FILE"
fi

# --- Stale session files ---
STALE_FILE_COUNT=0
for pattern in "$PROJECT_ROOT/.claude/.session-changes"* "$PROJECT_ROOT/.claude/.session-decisions"*; do
    [[ -f "$pattern" ]] && STALE_FILE_COUNT=$((STALE_FILE_COUNT + 1))
done
[[ "$STALE_FILE_COUNT" -gt 0 ]] && CONTEXT_PARTS+=("Stale session files: $STALE_FILE_COUNT from previous session")

# --- Todo HUD (listing with active-session annotations) ---
TODO_SCRIPT="$HOME/.claude/scripts/todo.sh"
if [[ -x "$TODO_SCRIPT" ]] && command -v gh >/dev/null 2>&1; then
    HUD_OUTPUT=$("$TODO_SCRIPT" hud 2>/dev/null || echo "")
    if [[ -n "$HUD_OUTPUT" ]]; then
        while IFS= read -r line; do
            CONTEXT_PARTS+=("$line")
        done <<< "$HUD_OUTPUT"
    fi
fi

# .agent-findings flat file removed (TKT-008): agent findings now flow through
# the runtime event store (rt_event_emit "agent_finding"). No file to inject.

# --- Reset prompt-count so first-prompt fallback re-fires after /clear ---
# The first-prompt path in prompt-submit.sh is the reliable HUD injection point.
# Without this reset, /clear leaves the old prompt-count file and the fallback
# never triggers again, so the HUD disappears.
rm -f "$PROJECT_ROOT/.claude/.prompt-count-"*
rm -f "$PROJECT_ROOT/.claude/.session-start-epoch"
# .subagent-tracker rm removed (TKT-008): file no longer written.

# --- Clear stale test status from previous session ---
# .test-status is now a hard gate for commits (guard.sh Checks 6/7).
# Stale passing results from a previous session must not satisfy the gate.
# test-runner.sh will regenerate it after the first Write/Edit in this session.
TEST_STATUS="${PROJECT_ROOT}/.claude/.test-status"
if [[ -f "$TEST_STATUS" ]]; then
    TS_RESULT=$(cut -d'|' -f1 "$TEST_STATUS")
    TS_FAILS=$(cut -d'|' -f2 "$TEST_STATUS")
    if [[ "$TS_RESULT" == "fail" ]]; then
        CONTEXT_PARTS+=("WARNING: Last test run FAILED ($TS_FAILS failures). test-gate.sh will block source writes until tests pass.")
    fi
    rm -f "$TEST_STATUS"
fi

# --- Output as additionalContext ---
if [[ ${#CONTEXT_PARTS[@]} -gt 0 ]]; then
    CONTEXT=$(printf '%s\n' "${CONTEXT_PARTS[@]}")
    ESCAPED=$(echo "$CONTEXT" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": $ESCAPED
  }
}
EOF
fi

exit 0
