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

# --- Syntax gate: validate shared libraries before sourcing ---
# Catches corruption (merge conflicts, partial writes) before all hooks break.
_HOOKS_DIR="$(dirname "$0")"
for _lib in source-lib.sh log.sh context-lib.sh; do
    if ! bash -n "$_HOOKS_DIR/$_lib" 2>/dev/null; then
        _SYNTAX_ERR=$(bash -n "$_HOOKS_DIR/$_lib" 2>&1 | head -3)
        _HAS_MARKERS=$(grep -c '^<\{7\}\|^=\{7\}\|^>\{7\}' "$_HOOKS_DIR/$_lib" 2>/dev/null || echo 0)
        _REMEDIATION="Run: bash -n ~/.claude/hooks/$_lib"
        [[ "$_HAS_MARKERS" -gt 0 ]] && _REMEDIATION="Merge conflict markers detected in $_lib. Remove <<<<<<< ======= >>>>>>> lines."
        cat <<SYNTAX_EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "CRITICAL: hooks/$_lib has syntax errors — ALL hooks impaired. Error: ${_SYNTAX_ERR}. Fix: ${_REMEDIATION}. Do this BEFORE any other work."
  }
}
SYNTAX_EOF
        exit 0
    fi
done

source "$(dirname "$0")/source-lib.sh"

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)
CONTEXT_PARTS=()

# --- Fix 1: Read update status from previous session's check (one-shot display) ---
# @decision DEC-UPDATE-BG-001
# @title Background update-check with previous-session result display
# @status accepted
# @rationale update-check.sh runs `git fetch` which blocks up to 5s on slow
# networks or during rapid session cycling. The fix: read the .update-status
# file written by the PREVIOUS session's background check, display it (one-shot),
# then launch a new background check for the NEXT session. This makes startup
# completely non-blocking for update notifications — the user sees the previous
# check result immediately (usually <1s stale) and the new check runs concurrently
# in the background without delaying the session.
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
    # One-shot: remove after reading so next session starts clean
    rm -f "$UPDATE_STATUS_FILE"
fi

# Launch update-check in background for the next session (non-blocking)
UPDATE_SCRIPT="$HOME/.claude/scripts/update-check.sh"
if [[ -x "$UPDATE_SCRIPT" ]]; then
    "$UPDATE_SCRIPT" >/dev/null 2>/dev/null &
    disown 2>/dev/null || true
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
            CONTEXT_PARTS+=("WARNING: $STALE_COUNT stale worktree(s) detected. Run \`worktree-roster.sh cleanup --dry-run\` to review before removing.")
        fi
    fi
fi

# --- Run community check in background (non-blocking, 1-hour TTL) ---
# The .community-status file will be ready by the time statusline renders.
# Display moved to statusline.sh and todo.sh for better visibility.
#
# @decision DEC-COMMUNITY-003
# @title Rate-limit community-check.sh to 1-hour TTL to prevent redundant API calls
# @status accepted
# @rationale community-check.sh makes GitHub API requests (gh issue list per repo)
# that add 0.5-2s of startup latency during rapid session cycling (/clear, /compact,
# terminal re-attach). A 1-hour TTL reuses the previous result within the window —
# community contributions don't change on sub-minute timescales, so freshness is not
# meaningfully compromised. The TTL is read from .community-status "checked_at" field,
# which community-check.sh already writes. If the file is absent or malformed, the
# check always runs. Users who need immediate refresh can delete .community-status.
# NOTE: session-init.sh runs at top-level (not inside a function), so _COMM_ prefix
# is used instead of `local` to avoid polluting the function-local namespace.
COMMUNITY_SCRIPT="$HOME/.claude/scripts/community-check.sh"
_COMM_STATUS_FILE="$HOME/.claude/.community-status"
_COMM_TTL=3600  # 1 hour in seconds
_COMM_SHOULD_RUN=true

if [[ -x "$COMMUNITY_SCRIPT" ]]; then
    if [[ -f "$_COMM_STATUS_FILE" ]]; then
        _COMM_CHECKED_AT=$(jq -r '.checked_at // 0' "$_COMM_STATUS_FILE" 2>/dev/null || echo "0")
        _COMM_NOW=$(date +%s)
        _COMM_AGE=$(( _COMM_NOW - _COMM_CHECKED_AT ))
        if [[ "$_COMM_AGE" -lt "$_COMM_TTL" ]]; then
            _COMM_SHOULD_RUN=false
        fi
    fi
    if [[ "$_COMM_SHOULD_RUN" == "true" ]]; then
        "$COMMUNITY_SCRIPT" 2>/dev/null &
        disown 2>/dev/null || true
    fi
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

# --- Doc freshness status ---
# Advisory injection — stale docs surfaced alongside plan staleness.
# get_doc_freshness uses cached results (DEC-DOCFRESH-002) so startup cost is
# one cache-file read on warm runs, not a suite of git log calls.
get_doc_freshness "$PROJECT_ROOT"
if [[ "$DOC_STALE_COUNT" -gt 0 ]]; then
    CONTEXT_PARTS+=("$DOC_FRESHNESS_SUMMARY")
elif [[ -n "$DOC_MOD_ADVISORY" ]]; then
    CONTEXT_PARTS+=("Doc freshness: advisory — high modification churn in: $DOC_MOD_ADVISORY")
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

# --- Trace count canary: warn if significant drop since last session ---
# check_trace_count_canary() compares current directory count against the
# value written at last session end. >30% drop triggers a warning.
# Runs wrapped in set +e: non-fatal, and find may return non-zero on permission errors.
set +e
_CANARY_WARNING=$(check_trace_count_canary 2>/dev/null || echo "")
set -e
if [[ -n "$_CANARY_WARNING" ]]; then
    CONTEXT_PARTS+=("$_CANARY_WARNING")
fi

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

    # Clean orphaned .proof-status (crash recovery)
    # At session start, if proof-status is NOT verified and no agents are active
    # (active markers just cleaned above), the file is stale from a crashed session.
    PROOF_FILE="${CLAUDE_DIR}/.proof-status"
    if [[ -f "$PROOF_FILE" ]]; then
        PROOF_VAL=$(cut -d'|' -f1 "$PROOF_FILE" 2>/dev/null || echo "")
        if [[ "$PROOF_VAL" != "verified" ]]; then
            ACTIVE_MARKERS=$(ls "$TRACE_STORE"/.active-* 2>/dev/null | wc -l | tr -d ' ' || echo "0")
            if [[ "$ACTIVE_MARKERS" -eq 0 ]]; then
                rm -f "$PROOF_FILE"
                CONTEXT_PARTS+=("Cleaned stale .proof-status ($PROOF_VAL) — no active agents, likely from crashed session")
            fi
        fi
    fi

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

    # --- Development Log Digest (issue #110) ---
    # Build a compact digest of the last 5 traces for the current project.
    # Each line shows: date, agent type, outcome, duration, files changed, branch.
    # Omitted when fewer than 2 project traces exist (not enough history to be useful).
    #
    # @decision DEC-OBS-P2-110
    # @title Compact development log digest injected at session start
    # @status accepted
    # @rationale New sessions start with minimal context about recent development
    #   activity. Injecting a structured digest of the last 5 traces lets the agent
    #   quickly orient: what was recently done, what branch it was on, and whether
    #   prior work succeeded. Limited to 5 traces and 7 output lines to avoid context
    #   bloat. Requires at least 2 project traces to have meaningful "recent activity"
    #   (single-trace sessions have the "Last trace:" line above for coverage).
    #   Fix for issue #110.
    if [[ -f "$TRACE_STORE/index.jsonl" ]]; then
        _DEV_PROJECT_NAME=$(basename "$PROJECT_ROOT")
        # Collect last 5 project traces (most recent first via tail)
        _DEV_TRACES=$(grep "\"project_name\":\"${_DEV_PROJECT_NAME}\"" "$TRACE_STORE/index.jsonl" 2>/dev/null | tail -5 | tac 2>/dev/null || true)
        _DEV_TRACE_COUNT=$(echo "$_DEV_TRACES" | grep -c . 2>/dev/null || echo "0")

        if [[ "$_DEV_TRACE_COUNT" -ge 2 ]]; then
            _DEV_LOG_LINES=()
            while IFS= read -r trace_entry; do
                [[ -z "$trace_entry" ]] && continue
                _DL_DATE=$(echo "$trace_entry" | jq -r '.started_at // ""' 2>/dev/null | cut -c1-10)
                _DL_AGENT=$(echo "$trace_entry" | jq -r '.agent_type // "?"' 2>/dev/null)
                _DL_OUTCOME=$(echo "$trace_entry" | jq -r '.outcome // "?"' 2>/dev/null)
                _DL_DUR=$(echo "$trace_entry" | jq -r '.duration_seconds // ""' 2>/dev/null)
                _DL_FILES=$(echo "$trace_entry" | jq -r '.files_changed // ""' 2>/dev/null)
                _DL_BRANCH=$(echo "$trace_entry" | jq -r '.branch // ""' 2>/dev/null)

                # Format duration: show as Xm Ys if >= 60s, else just Xs
                _DL_DUR_FMT=""
                if [[ -n "$_DL_DUR" && "$_DL_DUR" =~ ^[0-9]+$ && "$_DL_DUR" -gt 0 ]]; then
                    if [[ "$_DL_DUR" -ge 60 ]]; then
                        _DL_DUR_FMT="$(( _DL_DUR / 60 ))m$(( _DL_DUR % 60 ))s"
                    else
                        _DL_DUR_FMT="${_DL_DUR}s"
                    fi
                fi

                # Build compact line
                _DL_LINE="${_DL_DATE} | ${_DL_AGENT} | ${_DL_OUTCOME}"
                [[ -n "$_DL_DUR_FMT" ]] && _DL_LINE="${_DL_LINE} | ${_DL_DUR_FMT}"
                [[ -n "$_DL_FILES" ]] && _DL_LINE="${_DL_LINE} | ${_DL_FILES} files"
                [[ -n "$_DL_BRANCH" && "$_DL_BRANCH" != "unknown" ]] && _DL_LINE="${_DL_LINE} | ${_DL_BRANCH}"
                _DEV_LOG_LINES+=("  ${_DL_LINE}")
            done <<< "$_DEV_TRACES"

            if [[ "${#_DEV_LOG_LINES[@]}" -ge 2 ]]; then
                CONTEXT_PARTS+=("Development Log (last ${#_DEV_LOG_LINES[@]} sessions for ${_DEV_PROJECT_NAME}):")
                for _dl in "${_DEV_LOG_LINES[@]}"; do
                    CONTEXT_PARTS+=("$_dl")
                done
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

# --- Observatory suggestions ---
OBS_STATE="$HOME/.claude/observatory/state.json"
if [[ -f "$OBS_STATE" ]]; then
    OBS_PENDING=$(jq -r 'select(.pending_suggestion != null) | "\(.pending_title) (priority: \(.pending_priority))"' "$OBS_STATE" 2>/dev/null)
    [[ -n "$OBS_PENDING" ]] && CONTEXT_PARTS+=("Observatory: improvement ready — $OBS_PENDING. Run /observatory to review.")
fi

# --- Reset prompt-count so first-prompt fallback re-fires after /clear ---
# The first-prompt path in prompt-submit.sh is the reliable HUD injection point.
# Without this reset, /clear leaves the old prompt-count file and the fallback
# never triggers again, so the HUD disappears.
rm -f "${CLAUDE_DIR}/.prompt-count-"*
rm -f "${CLAUDE_DIR}/.session-start-epoch"
rm -f "${CLAUDE_DIR}/.subagent-tracker"
# Prune orphaned session-scoped tracker files from crashed sessions.
# Each tracker is named .subagent-tracker-<SESSION_ID_or_PID>.
# If the PID portion is numeric and the process is dead, the file is stale.
for tracker_file in "${CLAUDE_DIR}/.subagent-tracker-"*; do
    [[ ! -f "$tracker_file" ]] && continue
    tracker_id="${tracker_file##*-}"
    # If tracker_id looks like a PID (all digits), check if process is alive
    if [[ "$tracker_id" =~ ^[0-9]+$ ]]; then
        if ! kill -0 "$tracker_id" 2>/dev/null; then
            rm -f "$tracker_file"
        fi
    else
        # CLAUDE_SESSION_ID format — skip if it matches the current session
        if [[ "$tracker_id" != "${CLAUDE_SESSION_ID:-}" ]]; then
            # Age check: if older than 2 hours, safe to prune
            if [[ "$(uname)" == "Darwin" ]]; then
                tracker_age=$(( $(date +%s) - $(stat -f %m "$tracker_file" 2>/dev/null || echo "0") ))
            else
                tracker_age=$(( $(date +%s) - $(stat -c %Y "$tracker_file" 2>/dev/null || echo "0") ))
            fi
            if [[ "$tracker_age" -gt 7200 ]]; then
                rm -f "$tracker_file"
            fi
        fi
    fi
done

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

# --- Smoke test: validate library sourcing ---
# Verifies that log.sh and context-lib.sh can be sourced without error.
# Catches corruption early (e.g., partial writes during git merge) before
# all 29 hooks fail silently. Runs in a subshell so failures don't kill this hook.
if ! (source "$(dirname "$0")/source-lib.sh") 2>/dev/null; then
    CONTEXT_PARTS+=("WARNING: Hook library smoke test FAILED. log.sh or context-lib.sh may be corrupted. Run: bash -n ~/.claude/hooks/log.sh && bash -n ~/.claude/hooks/context-lib.sh")
fi

# --- Preflight integrity checks ---
# Fast validation of libraries, state files, and hook registration.
# diagnose.sh --quick completes in <250ms. Failures inject warnings;
# a crash of preflight itself does NOT block the session.
DIAGNOSE_SCRIPT="$HOME/.claude/skills/diagnose/scripts/diagnose.sh"
if [[ -x "$DIAGNOSE_SCRIPT" ]]; then
    PREFLIGHT_OUTPUT=$("$DIAGNOSE_SCRIPT" --quick 2>/dev/null) || true
    if [[ -n "$PREFLIGHT_OUTPUT" ]]; then
        # Extract WARN and FAIL lines only — PASS lines are noise in session context
        PREFLIGHT_ISSUES=$(echo "$PREFLIGHT_OUTPUT" | grep -E '^\[(WARN|FAIL)\]' || true)
        if [[ -n "$PREFLIGHT_ISSUES" ]]; then
            CONTEXT_PARTS+=("Preflight checks:")
            while IFS= read -r line; do
                CONTEXT_PARTS+=("  $line")
            done <<< "$PREFLIGHT_ISSUES"
        fi
    fi
fi

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
