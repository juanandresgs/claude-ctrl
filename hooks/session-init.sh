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
SESSION_ID=$(canonical_session_id)
CONTEXT_PARTS=()

# Claude Code's Bash tool inherits session-persisted environment from the
# SessionStart-only CLAUDE_ENV_FILE. Keep POSIX and Homebrew tool lookup stable
# even when the launching shell provides a sparse PATH.
if [[ -n "${CLAUDE_ENV_FILE:-}" ]]; then
    printf '%s\n' 'export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:$PATH"' >> "$CLAUDE_ENV_FILE"
fi

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
rt_lease_expire_stale 2>/dev/null || true
# Marker stale cleanup (TKT-STAB-A4): expire markers from crashed sessions.
python3 -m runtime.cli marker expire-stale 2>/dev/null || true
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

# --- Expire stale leases + show active lease ---
_SESSION_RUNTIME_ROOT="${CLAUDE_RUNTIME_ROOT:-$HOME/.claude/runtime}"
if [[ -f "$_SESSION_RUNTIME_ROOT/cli.py" ]]; then
    CLAUDE_RUNTIME_ROOT="$_SESSION_RUNTIME_ROOT" cc_policy lease expire-stale 2>/dev/null || true
    _LEASE_SUM=$(rt_lease_current "$PROJECT_ROOT")
    _LS_ROLE=$(printf '%s' "${_LEASE_SUM:-}" | jq -r '.role // empty' 2>/dev/null || true)
    if [[ -n "$_LS_ROLE" ]]; then
        _LS_NS=$(printf '%s' "$_LEASE_SUM" | jq -r '.next_step // empty' 2>/dev/null || true)
        CONTEXT_PARTS+=("Active lease: role=$_LS_ROLE${_LS_NS:+ next=$_LS_NS}")
    fi
fi
unset _SESSION_RUNTIME_ROOT _LEASE_SUM _LS_ROLE _LS_NS

# --- Workflow evaluation state (TKT-024) ---
# Shows evaluation_state as the readiness display. The legacy proof_state
# storage was retired under DEC-CATEGORY-C-PROOF-RETIRE-001.
# W-CONV-3: resolve workflow_id lease-first so session HUD shows the correct
# eval state when a lease is active with a different workflow_id than the branch.
if ! is_claude_meta_repo "$PROJECT_ROOT"; then
    _SESS_LEASE_CTX=$(lease_context "$PROJECT_ROOT")
    _SESS_LEASE_FOUND=$(printf '%s' "$_SESS_LEASE_CTX" | jq -r '.found' 2>/dev/null || echo "false")
    _SESS_WF_ID=""
    if [[ "$_SESS_LEASE_FOUND" == "true" ]]; then
        _SESS_WF_ID=$(printf '%s' "$_SESS_LEASE_CTX" | jq -r '.workflow_id // empty' 2>/dev/null || true)
    fi
    [[ -n "$_SESS_WF_ID" ]] || _SESS_WF_ID=$(current_workflow_id "$PROJECT_ROOT")
    _SESS_EVAL_STATUS=$(read_evaluation_status "$PROJECT_ROOT" "$_SESS_WF_ID")
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
    unset _SESS_EVAL_STATUS _SESS_LEASE_CTX _SESS_LEASE_FOUND _SESS_WF_ID
fi

# --- Enforcement gaps ---
# Persist across sessions — surface any open gaps so the model knows
# enforcement is degraded before it writes anything.
GAPS_JSON=$(cc_policy enforcement-gap list --project-root "$PROJECT_ROOT" 2>/dev/null || echo '{"items":[]}')
while IFS=$'\t' read -r gap_type ext tool; do
    [[ -z "$gap_type" ]] && continue
    if [[ "$gap_type" == "unsupported" ]]; then
        CONTEXT_PARTS+=("ENFORCEMENT DEGRADED: No linter profile for .${ext} files (unsupported). Writes to .${ext} source files are not being linted. Add a linter config to restore enforcement.")
    else
        CONTEXT_PARTS+=("ENFORCEMENT DEGRADED: Linter '${tool}' for .${ext} files is not installed (missing_dep). Install '${tool}' to restore lint enforcement.")
    fi
done < <(printf '%s' "$GAPS_JSON" | jq -r '.items[]? | [.gap_type, .ext, .tool] | @tsv' 2>/dev/null)

# --- Preserved context from pre-compaction ---
# compact-preserve.sh stores pre-compaction context in state.db. Re-inject it
# here so the post-compaction session has full context even if the
# additionalContext from PreCompact was lost in summarization.
PRESERVE_JSON=$(cc_policy preserved-context consume \
    --project-root "$PROJECT_ROOT" \
    --session-id "$SESSION_ID" 2>/dev/null || echo '{"found":false}')
PRESERVE_FOUND=$(printf '%s' "$PRESERVE_JSON" | jq -r 'if .found then "yes" else "no" end' 2>/dev/null || echo "no")
if [[ "$PRESERVE_FOUND" == "yes" ]]; then
    CONTEXT_PARTS+=("Preserved context from before compaction:")
    while IFS= read -r line; do
        # Skip the header comment
        [[ "$line" =~ ^#.* ]] && continue
        [[ -z "$line" ]] && continue
        CONTEXT_PARTS+=("  $line")
    done < <(printf '%s' "$PRESERVE_JSON" | jq -r '.context_text // empty' 2>/dev/null)
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

# --- Retired prompt-count flatfile cleanup ---
# Prompt counts now live in state.db. Remove stale historical files only.
rm -f "$PROJECT_ROOT/.claude/.prompt-count-"*
rm -f "$PROJECT_ROOT/.claude/.session-start-epoch"
# .subagent-tracker rm removed (TKT-008): file no longer written.

# --- Clear stale test status from previous session ---
# Stale passing results from a previous session must not satisfy the guard gate.
# WS3: read from SQLite (canonical), clear it, then remove any stale historical
# flat-file so older runs cannot confuse humans inspecting the tree.
_TS_JSON=$(rt_test_state_get "$PROJECT_ROOT" 2>/dev/null) || _TS_JSON=""
_TS_RESULT=$(printf '%s' "${_TS_JSON:-}" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
_TS_FAILS=$(printf '%s' "${_TS_JSON:-}" | jq -r '.fail_count // 0' 2>/dev/null || echo "0")
if [[ "$_TS_RESULT" == "fail" ]]; then
    CONTEXT_PARTS+=("WARNING: Last test run FAILED ($_TS_FAILS failures). test-gate.sh will block source writes until tests pass.")
fi
# Reset SQLite test state so stale pass does not satisfy guard this session.
rt_test_state_set "unknown" "$PROJECT_ROOT" >/dev/null 2>&1 || true
# Also clear the retired flat-file.
rm -f "${PROJECT_ROOT}/.claude/.test-status"

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
