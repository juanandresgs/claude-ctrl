#!/usr/bin/env bash
set -euo pipefail

# Dynamic context injection based on user prompt content.
# UserPromptSubmit hook
#
# Injects contextual information when the user's prompt references:
#   - File paths → inject that file's @decision status
#   - "plan" or "implement" → inject MASTER_PLAN.md phase status
#   - "merge" or "commit" → inject git dirty state

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

HOOK_INPUT=$(read_input)
PROMPT=$(echo "$HOOK_INPUT" | jq -r '.prompt // empty' 2>/dev/null)

# Exit silently if no prompt
[[ -z "$PROMPT" ]] && exit 0

PROJECT_ROOT=$(detect_project_root)
CONTEXT_PARTS=()

# --- First-prompt mitigation for session-init bug (Issue #10373) ---
PROMPT_COUNT_FILE="${PROJECT_ROOT}/.claude/.prompt-count-${CLAUDE_SESSION_ID:-$$}"
if [[ ! -f "$PROMPT_COUNT_FILE" ]]; then
    mkdir -p "${PROJECT_ROOT}/.claude"
    echo "1" > "$PROMPT_COUNT_FILE"
    # Inject full session context (same as session-init.sh)
    get_git_state "$PROJECT_ROOT"
    get_plan_status "$PROJECT_ROOT"
    [[ -n "$GIT_BRANCH" ]] && CONTEXT_PARTS+=("Git: branch=$GIT_BRANCH, $GIT_DIRTY_COUNT uncommitted")
    [[ "$PLAN_EXISTS" == "true" ]] && CONTEXT_PARTS+=("MASTER_PLAN.md: $PLAN_COMPLETED_PHASES/$PLAN_TOTAL_PHASES phases done")
    [[ "$PLAN_EXISTS" == "false" ]] && CONTEXT_PARTS+=("MASTER_PLAN.md: not found (required before implementation)")
fi

# --- Inject agent findings from previous subagent runs ---
FINDINGS_FILE="${PROJECT_ROOT}/.claude/.agent-findings"
if [[ -f "$FINDINGS_FILE" && -s "$FINDINGS_FILE" ]]; then
    CONTEXT_PARTS+=("Previous agent findings (unresolved):")
    while IFS='|' read -r agent issues; do
        [[ -z "$agent" ]] && continue
        CONTEXT_PARTS+=("  ${agent}: ${issues}")
    done < "$FINDINGS_FILE"
    # Clear after injection (one-shot delivery)
    rm -f "$FINDINGS_FILE"
fi

# --- Inject recent audit trail ---
AUDIT_LOG="${PROJECT_ROOT}/.claude/.audit-log"
if [[ -f "$AUDIT_LOG" && -s "$AUDIT_LOG" ]]; then
    RECENT=$(tail -5 "$AUDIT_LOG")
    if [[ -n "$RECENT" ]]; then
        CONTEXT_PARTS+=("Recent audit events:")
        while IFS= read -r line; do
            CONTEXT_PARTS+=("  $line")
        done <<< "$RECENT"
    fi
fi

# --- Check for plan/implement/status keywords ---
if echo "$PROMPT" | grep -qiE '\bplan\b|\bimplement\b|\bphase\b|\bmaster.plan\b|\bstatus\b|\bprogress\b|\bdemo\b'; then
    get_plan_status "$PROJECT_ROOT"

    if [[ "$PLAN_EXISTS" == "true" ]]; then
        if [[ "$PLAN_TOTAL_PHASES" -gt 0 ]]; then
            CONTEXT_PARTS+=("Plan progress: $PLAN_COMPLETED_PHASES/$PLAN_TOTAL_PHASES phases completed, $PLAN_IN_PROGRESS_PHASES in-progress")
        fi

        if [[ "$PLAN_AGE_DAYS" -gt 0 ]]; then
            CONTEXT_PARTS+=("MASTER_PLAN.md last updated: ${PLAN_AGE_DAYS}d ago")
        fi

        if [[ -n "$PLAN_PHASE" ]]; then
            CONTEXT_PARTS+=("MASTER_PLAN.md active phase: $PLAN_PHASE")
        else
            CONTEXT_PARTS+=("MASTER_PLAN.md exists (no phase markers found)")
        fi

        get_session_changes "$PROJECT_ROOT"
        if [[ "$SESSION_CHANGED_COUNT" -gt 0 ]]; then
            CONTEXT_PARTS+=("Files changed this session: $SESSION_CHANGED_COUNT")
        fi
    else
        CONTEXT_PARTS+=("No MASTER_PLAN.md found — Core Dogma requires planning before implementation.")
    fi
fi

# --- Check for merge/commit keywords ---
if echo "$PROMPT" | grep -qiE '\bmerge\b|\bcommit\b|\bpush\b|\bPR\b|\bpull.request\b'; then
    get_git_state "$PROJECT_ROOT"

    if [[ -n "$GIT_BRANCH" ]]; then
        CONTEXT_PARTS+=("Git: branch=$GIT_BRANCH, $GIT_DIRTY_COUNT uncommitted changes")

        if [[ "$GIT_BRANCH" == "main" || "$GIT_BRANCH" == "master" ]]; then
            CONTEXT_PARTS+=("WARNING: Currently on $GIT_BRANCH. Sacred Practice #2: Main is sacred.")
        fi
    fi
fi

# --- Check for large/multi-step tasks ---
WORD_COUNT=$(echo "$PROMPT" | wc -w | tr -d ' ')
ACTION_VERBS=$(echo "$PROMPT" | { grep -oiE '\b(implement|add|create|build|fix|update|refactor|migrate|convert|rewrite)\b' || true; } | wc -l | tr -d ' ')

if [[ "$WORD_COUNT" -gt 40 && "$ACTION_VERBS" -gt 2 ]]; then
    CONTEXT_PARTS+=("Large task detected ($WORD_COUNT words, $ACTION_VERBS action verbs). Interaction Style: break this into steps and confirm the approach with the user before implementing.")
elif echo "$PROMPT" | grep -qiE '\beverything\b|\ball of\b|\bentire\b|\bcomprehensive\b|\bcomplete overhaul\b'; then
    CONTEXT_PARTS+=("Broad scope detected. Interaction Style: clarify scope with the user — what specifically should be included/excluded?")
fi

# --- Output ---
if [[ ${#CONTEXT_PARTS[@]} -gt 0 ]]; then
    CONTEXT=$(printf '%s\n' "${CONTEXT_PARTS[@]}")
    ESCAPED=$(echo "$CONTEXT" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": $ESCAPED
  }
}
EOF
fi

exit 0
