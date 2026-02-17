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

source "$(dirname "$0")/source-lib.sh"

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)
CONTEXT_PARTS=()

# --- Run update check first (guarantees .update-status exists) ---
# Previously a separate SessionStart hook that raced with this script.
# Inlined to ensure .update-status is written before we read it below.
UPDATE_SCRIPT="$HOME/.claude/scripts/update-check.sh"
if [[ -x "$UPDATE_SCRIPT" ]]; then
    "$UPDATE_SCRIPT" >/dev/null 2>/dev/null || true
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

    # Stale worktree detection
    ROSTER_SCRIPT="$HOME/.claude/scripts/worktree-roster.sh"
    if [[ -x "$ROSTER_SCRIPT" ]]; then
        "$ROSTER_SCRIPT" prune 2>/dev/null || true
        STALE_COUNT=$("$ROSTER_SCRIPT" stale 2>/dev/null | wc -l || echo "0")
        STALE_COUNT=$(echo "$STALE_COUNT" | tr -d ' ')
        if [[ "$STALE_COUNT" -gt 0 ]]; then
            CONTEXT_PARTS+=("WARNING: $STALE_COUNT stale worktree(s) detected. Run \`worktree-roster.sh cleanup\` to review.")
        fi
    fi
fi

# --- Harness update status ---
UPDATE_STATUS_FILE="$HOME/.claude/.update-status"
if [[ -f "$UPDATE_STATUS_FILE" && -s "$UPDATE_STATUS_FILE" ]]; then
    IFS='|' read -r UPD_STATUS UPD_LOCAL_VER UPD_REMOTE_VER UPD_COUNT UPD_TS UPD_SUMMARY < "$UPDATE_STATUS_FILE"
    case "$UPD_STATUS" in
        updated)
            CONTEXT_PARTS+=("Harness updated (v${UPD_LOCAL_VER} → v${UPD_REMOTE_VER}, ${UPD_COUNT} commits). To disable: \`touch ~/.claude/.disable-auto-update\`")
            ;;
        breaking)
            CONTEXT_PARTS+=("Harness update available (v${UPD_LOCAL_VER} → v${UPD_REMOTE_VER}, BREAKING). Review CHANGELOG.md then \`cd ~/.claude && git pull --autostash --rebase\`. To disable: \`touch ~/.claude/.disable-auto-update\`")
            ;;
        conflict)
            CONTEXT_PARTS+=("Harness auto-update failed (merge conflict with local changes). Run \`cd ~/.claude && git pull --autostash --rebase\` to resolve. To disable: \`touch ~/.claude/.disable-auto-update\`")
            ;;
    esac
    # One-shot: remove after reading
    rm -f "$UPDATE_STATUS_FILE"
fi

# --- Run community check in background (non-blocking) ---
# The .community-status file will be ready by the time statusline renders.
# Display moved to statusline.sh and todo.sh for better visibility.
COMMUNITY_SCRIPT="$HOME/.claude/scripts/community-check.sh"
if [[ -x "$COMMUNITY_SCRIPT" ]]; then
    "$COMMUNITY_SCRIPT" 2>/dev/null &
fi

# --- MASTER_PLAN.md preamble: project identity ---
if [[ -f "$PROJECT_ROOT/MASTER_PLAN.md" ]]; then
    PREAMBLE=$(awk '/^---$|^## Original Intent/{exit} {print}' "$PROJECT_ROOT/MASTER_PLAN.md" | head -30)
    if [[ -n "$PREAMBLE" ]]; then
        CONTEXT_PARTS+=("$PREAMBLE")
    fi
fi

# --- MASTER_PLAN.md ---
get_plan_status "$PROJECT_ROOT"
write_statusline_cache "$PROJECT_ROOT"

if [[ "$PLAN_EXISTS" == "true" ]]; then
    if [[ "$PLAN_LIFECYCLE" == "completed" ]]; then
        CONTEXT_PARTS+=("WARNING: MASTER_PLAN.md is COMPLETED (all $PLAN_TOTAL_PHASES phases done). Source writes are BLOCKED until a new plan is created. Archive the completed plan first.")
    else
        PLAN_LINE="Plan:"
        [[ "$PLAN_TOTAL_PHASES" -gt 0 ]] && PLAN_LINE="$PLAN_LINE $PLAN_COMPLETED_PHASES/$PLAN_TOTAL_PHASES phases"
        [[ -n "$PLAN_PHASE" ]] && PLAN_LINE="$PLAN_LINE | active: $PLAN_PHASE"
        [[ "$PLAN_AGE_DAYS" -gt 0 ]] && PLAN_LINE="$PLAN_LINE | age: ${PLAN_AGE_DAYS}d"
        CONTEXT_PARTS+=("$PLAN_LINE")

        if [[ "$PLAN_SOURCE_CHURN_PCT" -ge 10 ]]; then
            CONTEXT_PARTS+=("WARNING: Plan may be stale (${PLAN_SOURCE_CHURN_PCT}% source file churn since last update)")
        fi
    fi
else
    CONTEXT_PARTS+=("Plan: not found (required before implementation)")
fi

# --- Research status ---
get_research_status "$PROJECT_ROOT"
if [[ "$RESEARCH_EXISTS" == "true" ]]; then
    CONTEXT_PARTS+=("Research: $RESEARCH_ENTRY_COUNT entries | recent: $RESEARCH_RECENT_TOPICS")
fi

# --- Preserved context from pre-compaction ---
# compact-preserve.sh writes .preserved-context before compaction.
# Re-inject it here so the post-compaction session has full context
# even if the additionalContext from PreCompact was lost in summarization.
#
# Resume directive logic: the preserved-context file may contain a
# "RESUME DIRECTIVE:" block (computed by build_resume_directive in context-lib.sh).
# This block is extracted and injected as the FIRST context element so it takes
# priority over all other context. The remainder is injected after.
_WAS_COMPACTION=false
PRESERVE_FILE="${CLAUDE_DIR}/.preserved-context"
if [[ -f "$PRESERVE_FILE" && -s "$PRESERVE_FILE" ]]; then
    _WAS_COMPACTION=true

    # Extract resume directive block (lines starting with "RESUME DIRECTIVE:" and
    # following indented lines that are part of the same block).
    RESUME_BLOCK=""
    _in_resume=false
    while IFS= read -r line; do
        # Skip file-level header comments
        [[ "$line" =~ ^#.* ]] && continue
        if [[ "$line" =~ ^RESUME\ DIRECTIVE: ]]; then
            _in_resume=true
            RESUME_BLOCK="${line}"
        elif [[ "$_in_resume" == "true" && "$line" =~ ^[[:space:]] ]]; then
            RESUME_BLOCK="${RESUME_BLOCK}
${line}"
        elif [[ "$_in_resume" == "true" ]]; then
            _in_resume=false
        fi
    done < "$PRESERVE_FILE"

    # Inject resume directive as first element (highest priority)
    if [[ -n "$RESUME_BLOCK" ]]; then
        # Prepend before all other CONTEXT_PARTS by building a new array
        PRIORITY_CONTEXT=("ACTION REQUIRED — session resumed after compaction. ${RESUME_BLOCK}")
        CONTEXT_PARTS=("${PRIORITY_CONTEXT[@]}" "${CONTEXT_PARTS[@]}")
    fi

    # Inject remaining metadata (everything except header comments and resume block)
    _in_resume=false
    _saw_resume=false
    CONTEXT_PARTS+=("Preserved context from before compaction:")
    while IFS= read -r line; do
        [[ "$line" =~ ^#.* ]] && continue
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^RESUME\ DIRECTIVE: ]]; then
            _saw_resume=true
            _in_resume=true
            continue
        elif [[ "$_in_resume" == "true" && "$line" =~ ^[[:space:]] ]]; then
            continue  # skip indented resume block lines
        else
            _in_resume=false
        fi
        CONTEXT_PARTS+=("  $line")
    done < "$PRESERVE_FILE"

    # One-time use: remove after injecting so it doesn't persist across sessions
    rm -f "$PRESERVE_FILE"
fi

# --- Stale session files ---
STALE_FILE_COUNT=0
for pattern in "${CLAUDE_DIR}/.session-changes"* "${CLAUDE_DIR}/.session-decisions"*; do
    [[ -f "$pattern" ]] && STALE_FILE_COUNT=$((STALE_FILE_COUNT + 1))
done
[[ "$STALE_FILE_COUNT" -gt 0 ]] && CONTEXT_PARTS+=("Stale session files: $STALE_FILE_COUNT from previous session")

# --- Trace protocol: surface incomplete and recent traces ---
if [[ -d "$TRACE_STORE" ]]; then
    # Clean up stale active markers (agent crashed without SubagentStop)
    for marker in "$TRACE_STORE"/.active-*; do
        [[ ! -f "$marker" ]] && continue
        local_trace_id=$(cat "$marker" 2>/dev/null || echo "")
        if [[ -n "$local_trace_id" ]]; then
            local_manifest="$TRACE_STORE/$local_trace_id/manifest.json"
            if [[ -f "$local_manifest" ]]; then
                # Check if marker is stale (>2 hours)
                if [[ "$(uname)" == "Darwin" ]]; then
                    marker_age=$(( $(date +%s) - $(stat -f %m "$marker" 2>/dev/null || echo "0") ))
                else
                    marker_age=$(( $(date +%s) - $(stat -c %Y "$marker" 2>/dev/null || echo "0") ))
                fi
                if [[ "$marker_age" -gt 7200 ]]; then
                    # Mark as crashed and finalize
                    (jq '.status = "crashed" | .outcome = "crashed"' "$local_manifest" > "${local_manifest}.tmp" 2>/dev/null && mv "${local_manifest}.tmp" "$local_manifest") || true
                    index_trace "$local_trace_id"
                    rm -f "$marker"
                    CONTEXT_PARTS+=("Crashed trace detected: $local_trace_id (stale ${marker_age}s). Read summary: ~/.claude/traces/$local_trace_id/summary.md")
                fi
            else
                rm -f "$marker"
            fi
        fi
    done

    # Surface last completed trace for current project
    if [[ -f "$TRACE_STORE/index.jsonl" ]]; then
        PROJECT_NAME=$(basename "$PROJECT_ROOT")
        LAST_TRACE=$(grep "\"project_name\":\"${PROJECT_NAME}\"" "$TRACE_STORE/index.jsonl" 2>/dev/null | tail -1 || echo "")
        if [[ -n "$LAST_TRACE" ]]; then
            LT_ID=$(echo "$LAST_TRACE" | jq -r '.trace_id // empty' 2>/dev/null)
            LT_OUTCOME=$(echo "$LAST_TRACE" | jq -r '.outcome // "unknown"' 2>/dev/null)
            LT_TYPE=$(echo "$LAST_TRACE" | jq -r '.agent_type // "unknown"' 2>/dev/null)
            if [[ -n "$LT_ID" ]]; then
                CONTEXT_PARTS+=("Last trace: ${LT_TYPE} ${LT_OUTCOME} — ~/.claude/traces/${LT_ID}/summary.md")
            fi
        fi
    fi
fi

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

# --- Pending agent findings ---
FINDINGS_FILE="${CLAUDE_DIR}/.agent-findings"
if [[ -f "$FINDINGS_FILE" && -s "$FINDINGS_FILE" ]]; then
    CONTEXT_PARTS+=("Unresolved agent findings from previous session:")
    while IFS= read -r line; do
        CONTEXT_PARTS+=("  $line")
    done < "$FINDINGS_FILE"
fi

# --- Reset prompt-count so first-prompt fallback re-fires after /clear ---
# The first-prompt path in prompt-submit.sh is the reliable HUD injection point.
# Without this reset, /clear leaves the old prompt-count file and the fallback
# never triggers again, so the HUD disappears.
rm -f "${CLAUDE_DIR}/.prompt-count-"*
rm -f "${CLAUDE_DIR}/.session-start-epoch"
rm -f "${CLAUDE_DIR}/.subagent-tracker"

# --- Clear stale test status from previous session ---
# .test-status is now a hard gate for commits (guard.sh Checks 6/7).
# Stale passing results from a previous session must not satisfy the gate.
# test-runner.sh will regenerate it after the first Write/Edit in this session.
TEST_STATUS="${CLAUDE_DIR}/.test-status"
if [[ -f "$TEST_STATUS" ]]; then
    TS_RESULT=$(cut -d'|' -f1 "$TEST_STATUS")
    TS_FAILS=$(cut -d'|' -f2 "$TEST_STATUS")
    if [[ "$TS_RESULT" == "fail" ]]; then
        CONTEXT_PARTS+=("WARNING: Last test run FAILED ($TS_FAILS failures). test-gate.sh will block source writes until tests pass.")
    fi
    rm -f "$TEST_STATUS"
fi

# --- Clean stale hook-library caches (crashed sessions) ---
# Caches older than 24h belong to sessions that exited without running session-end.sh.
find "${HOME}/.claude/.hook-cache" -maxdepth 1 -type d -mmin +1440 -exec rm -rf {} + 2>/dev/null || true

# --- Initialize session event log ---
# After compaction, preserve the event log — the trajectory is still relevant
# context for the resumed session. Only reset for fresh sessions (/clear, startup).
SESSION_EVENT_FILE="${CLAUDE_DIR}/.session-events.jsonl"
if [[ "${_WAS_COMPACTION:-false}" != "true" ]]; then
    rm -f "$SESSION_EVENT_FILE"  # Fresh log each non-compaction session
fi
append_session_event "session_start" "{\"project\":\"$(basename "$PROJECT_ROOT")\",\"branch\":\"${GIT_BRANCH:-unknown}\"}" "$PROJECT_ROOT"

# --- Prior session context (cross-session learning) ---
# Only inject when 3+ sessions exist; get_prior_sessions returns empty otherwise.
PRIOR_SESSIONS=$(get_prior_sessions "$PROJECT_ROOT" 2>/dev/null || echo "")
if [[ -n "$PRIOR_SESSIONS" ]]; then
    while IFS= read -r line; do
        CONTEXT_PARTS+=("$line")
    done <<< "$PRIOR_SESSIONS"
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
