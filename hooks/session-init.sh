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
    CONTEXT_PARTS+=("Git: branch=$GIT_BRANCH")

    if [[ "$GIT_BRANCH" == "main" || "$GIT_BRANCH" == "master" ]]; then
        CONTEXT_PARTS+=("WARNING: On $GIT_BRANCH branch. Sacred Practice #2: create a worktree before making changes.")
    fi

    if [[ "$GIT_DIRTY_COUNT" -gt 0 ]]; then
        CONTEXT_PARTS+=("Working tree: $GIT_DIRTY_COUNT uncommitted changes")
    fi

    if [[ "$GIT_WT_COUNT" -gt 0 ]]; then
        CONTEXT_PARTS+=("Active worktrees: $GIT_WT_COUNT")
    fi
fi

# --- MASTER_PLAN.md ---
get_plan_status "$PROJECT_ROOT"

if [[ "$PLAN_EXISTS" == "true" ]]; then
    PLAN_STATUS_LINE=$(grep -i '^\*\*Status\*\*\|^Status:' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null | head -1 || echo "")
    if [[ -n "$PLAN_STATUS_LINE" ]]; then
        CONTEXT_PARTS+=("MASTER_PLAN.md: exists ($PLAN_STATUS_LINE)")
    else
        CONTEXT_PARTS+=("MASTER_PLAN.md: exists")
    fi

    if [[ "$PLAN_AGE_DAYS" -gt 0 ]]; then
        CONTEXT_PARTS+=("Plan age: ${PLAN_AGE_DAYS}d since last update")
    fi

    if [[ "$PLAN_COMMITS_SINCE" -ge 5 ]]; then
        CONTEXT_PARTS+=("MASTER_PLAN.md may be stale (last updated ${PLAN_AGE_DAYS}d ago, $PLAN_COMMITS_SINCE commits since)")
    fi

    if [[ "$PLAN_TOTAL_PHASES" -gt 0 ]]; then
        CONTEXT_PARTS+=("Plan progress: $PLAN_COMPLETED_PHASES/$PLAN_TOTAL_PHASES phases completed")
    fi
else
    CONTEXT_PARTS+=("MASTER_PLAN.md: not found (required before implementation)")
fi

# --- Stale session files ---
for pattern in "$PROJECT_ROOT/.claude/.session-changes"* "$PROJECT_ROOT/.claude/.session-decisions"*; do
    if [[ -f "$pattern" ]]; then
        STALE_COUNT=$(wc -l < "$pattern" | tr -d ' ')
        STALE_NAME=$(basename "$pattern")
        CONTEXT_PARTS+=("Stale session file: $STALE_NAME ($STALE_COUNT entries from previous session)")
    fi
done

# --- Previous session audit trail ---
AUDIT_LOG="${PROJECT_ROOT}/.claude/.audit-log"
if [[ -f "$AUDIT_LOG" && -s "$AUDIT_LOG" ]]; then
    ENTRY_COUNT=$(wc -l < "$AUDIT_LOG" | tr -d ' ')
    RECENT=$(tail -10 "$AUDIT_LOG")
    CONTEXT_PARTS+=("Audit trail ($ENTRY_COUNT entries, showing last 10):")
    while IFS= read -r line; do
        CONTEXT_PARTS+=("  $line")
    done <<< "$RECENT"
fi

# --- Pending agent findings ---
FINDINGS_FILE="${PROJECT_ROOT}/.claude/.agent-findings"
if [[ -f "$FINDINGS_FILE" && -s "$FINDINGS_FILE" ]]; then
    CONTEXT_PARTS+=("Unresolved agent findings from previous session:")
    while IFS= read -r line; do
        CONTEXT_PARTS+=("  $line")
    done < "$FINDINGS_FILE"
fi

# --- Last known test status ---
TEST_STATUS="${PROJECT_ROOT}/.claude/.test-status"
if [[ -f "$TEST_STATUS" ]]; then
    TS_RESULT=$(cut -d'|' -f1 "$TEST_STATUS")
    TS_FAILS=$(cut -d'|' -f2 "$TEST_STATUS")
    if [[ "$TS_RESULT" == "fail" ]]; then
        CONTEXT_PARTS+=("WARNING: Last test run FAILED ($TS_FAILS failures). test-gate.sh will block source writes until tests pass.")
    fi
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
