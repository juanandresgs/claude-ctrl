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

# --- Pending agent findings ---
FINDINGS_FILE="${PROJECT_ROOT}/.claude/.agent-findings"
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
rm -f "$PROJECT_ROOT/.claude/.prompt-count-"*
rm -f "$PROJECT_ROOT/.claude/.session-start-epoch"
rm -f "$PROJECT_ROOT/.claude/.subagent-tracker"

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
