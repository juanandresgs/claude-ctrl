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

HOOK_INPUT=$(read_input)
PROMPT=$(echo "$HOOK_INPUT" | jq -r '.prompt // empty' 2>/dev/null)

# Exit silently if no prompt
[[ -z "$PROMPT" ]] && exit 0

PROJECT_ROOT=$(detect_project_root)
CONTEXT_PARTS=()

# --- Check for plan/implement/status keywords ---
if echo "$PROMPT" | grep -qiE '\bplan\b|\bimplement\b|\bphase\b|\bmaster.plan\b|\bstatus\b|\bprogress\b|\bwhat\b|\bwhere\b|\bshow\b|\bdemo\b'; then
    if [[ -f "$PROJECT_ROOT/MASTER_PLAN.md" ]]; then
        # Phase progress summary
        TOTAL_PHASES=$(grep -cE '^\#\#\s+Phase\s+[0-9]' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null || echo "0")
        COMPLETED_PHASES=$(grep -cE '\*\*Status:\*\*\s*completed' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null || echo "0")
        IN_PROGRESS_PHASES=$(grep -cE '\*\*Status:\*\*\s*in-progress' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null || echo "0")

        if [[ "$TOTAL_PHASES" -gt 0 ]]; then
            CONTEXT_PARTS+=("Plan progress: $COMPLETED_PHASES/$TOTAL_PHASES phases completed, $IN_PROGRESS_PHASES in-progress")
        fi

        # Last update staleness
        PLAN_MOD=$(stat -f '%m' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null || stat -c '%Y' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null || echo "0")
        if [[ "$PLAN_MOD" -gt 0 ]]; then
            NOW=$(date +%s)
            PLAN_AGE_DAYS=$(( (NOW - PLAN_MOD) / 86400 ))
            CONTEXT_PARTS+=("MASTER_PLAN.md last updated: ${PLAN_AGE_DAYS}d ago")
        fi

        PHASE=$(grep -iE '^\#.*phase|^\*\*Phase' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null | tail -1 || echo "")
        if [[ -n "$PHASE" ]]; then
            CONTEXT_PARTS+=("MASTER_PLAN.md active phase: $PHASE")
        else
            CONTEXT_PARTS+=("MASTER_PLAN.md exists (no phase markers found)")
        fi

        # Session files changed (if track.sh session file exists)
        SESSION_ID="${CLAUDE_SESSION_ID:-}"
        SESSION_FILE=""
        if [[ -n "$SESSION_ID" && -f "$PROJECT_ROOT/.claude/.session-changes-${SESSION_ID}" ]]; then
            SESSION_FILE="$PROJECT_ROOT/.claude/.session-changes-${SESSION_ID}"
        elif [[ -f "$PROJECT_ROOT/.claude/.session-changes" ]]; then
            SESSION_FILE="$PROJECT_ROOT/.claude/.session-changes"
        fi
        if [[ -n "$SESSION_FILE" && -f "$SESSION_FILE" ]]; then
            CHANGED_COUNT=$(sort -u "$SESSION_FILE" | wc -l | tr -d ' ')
            CONTEXT_PARTS+=("Files changed this session: $CHANGED_COUNT")
        fi
    else
        CONTEXT_PARTS+=("No MASTER_PLAN.md found — Core Dogma requires planning before implementation.")
    fi
fi

# --- Check for merge/commit keywords ---
if echo "$PROMPT" | grep -qiE '\bmerge\b|\bcommit\b|\bpush\b|\bPR\b|\bpull.request\b'; then
    if [[ -d "$PROJECT_ROOT/.git" ]]; then
        BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        DIRTY_COUNT=$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        CONTEXT_PARTS+=("Git: branch=$BRANCH, $DIRTY_COUNT uncommitted changes")

        if [[ "$BRANCH" == "main" || "$BRANCH" == "master" ]]; then
            CONTEXT_PARTS+=("WARNING: Currently on $BRANCH. Sacred Practice #2: Main is sacred.")
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
