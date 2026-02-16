#!/usr/bin/env bash
set -euo pipefail

# Pre-compaction context preservation.
# PreCompact hook
#
# Two outputs:
#   1. Persistent file: .claude/.preserved-context (survives compaction, read by session-init.sh)
#   2. additionalContext: injected into the system message before compaction
#
# The additionalContext includes a directive instructing Claude to generate
# a structured context summary (per context-preservation skill) as part of
# the compaction. This ensures session intent (not just project state) survives.

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)
CONTEXT_PARTS=()

# --- Git state (via shared library) ---
get_git_state "$PROJECT_ROOT"

if [[ -n "$GIT_BRANCH" ]]; then
    GIT_LINE="Git: $GIT_BRANCH | $GIT_DIRTY_COUNT uncommitted"
    [[ "$GIT_WT_COUNT" -gt 0 ]] && GIT_LINE="$GIT_LINE | $GIT_WT_COUNT worktrees"
    CONTEXT_PARTS+=("$GIT_LINE")

    # Include worktree details (branch names help resume context)
    if [[ -n "$GIT_WORKTREES" ]]; then
        while IFS= read -r wt_line; do
            CONTEXT_PARTS+=("  worktree: $wt_line")
        done <<< "$GIT_WORKTREES"
    fi
fi

# --- MASTER_PLAN.md preamble: preserve for post-compaction context ---
if [[ -f "$PROJECT_ROOT/MASTER_PLAN.md" ]]; then
    PREAMBLE=$(awk '/^---$|^## Original Intent/{exit} {print}' "$PROJECT_ROOT/MASTER_PLAN.md" | head -30)
    if [[ -n "$PREAMBLE" ]]; then
        CONTEXT_PARTS+=("$PREAMBLE")
    fi
fi

# --- MASTER_PLAN.md (via shared library) ---
get_plan_status "$PROJECT_ROOT"

if [[ "$PLAN_EXISTS" == "true" ]]; then
    PLAN_LINE="Plan: $PLAN_COMPLETED_PHASES/$PLAN_TOTAL_PHASES phases done"
    [[ -n "$PLAN_PHASE" ]] && PLAN_LINE="$PLAN_LINE | active: $PLAN_PHASE"
    CONTEXT_PARTS+=("$PLAN_LINE")
fi

# --- Session file changes ---
get_session_changes "$PROJECT_ROOT"

if [[ -n "$SESSION_FILE" && -f "$SESSION_FILE" ]]; then
    FILE_COUNT=$(sort -u "$SESSION_FILE" | wc -l | tr -d ' ')
    FILE_LIST=$(sort -u "$SESSION_FILE" | head -5 | xargs -I{} basename {} | paste -sd', ' -)
    REMAINING=$((FILE_COUNT - 5))
    if [[ "$REMAINING" -gt 0 ]]; then
        CONTEXT_PARTS+=("Modified this session: $FILE_LIST (+$REMAINING more)")
    else
        CONTEXT_PARTS+=("Modified this session: $FILE_LIST")
    fi

    # Full paths for context (written to file, not displayed)
    FULL_PATHS=$(sort -u "$SESSION_FILE" | head -10)

    # --- Key @decisions made this session ---
    DECISIONS_FOUND=()
    while IFS= read -r file; do
        [[ ! -f "$file" ]] && continue
        decision_line=$(grep -oE '@decision\s+[A-Z]+-[A-Z0-9-]+' "$file" 2>/dev/null | head -1 || echo "")
        if [[ -n "$decision_line" ]]; then
            DECISIONS_FOUND+=("$decision_line ($(basename "$file"))")
        fi
    done < <(sort -u "$SESSION_FILE")

    if [[ ${#DECISIONS_FOUND[@]} -gt 0 ]]; then
        DECISIONS_LINE=$(printf '%s, ' "${DECISIONS_FOUND[@]:0:5}")
        CONTEXT_PARTS+=("Decisions: ${DECISIONS_LINE%, }")
    fi
fi

# --- Test status ---
TEST_STATUS="${CLAUDE_DIR}/.test-status"
if [[ -f "$TEST_STATUS" ]]; then
    TS_RESULT=$(cut -d'|' -f1 "$TEST_STATUS")
    TS_FAILS=$(cut -d'|' -f2 "$TEST_STATUS")
    CONTEXT_PARTS+=("Test status: ${TS_RESULT} (${TS_FAILS} failures)")
fi

# --- Agent findings (unresolved issues from subagents) ---
FINDINGS_FILE="${CLAUDE_DIR}/.agent-findings"
if [[ -f "$FINDINGS_FILE" && -s "$FINDINGS_FILE" ]]; then
    CONTEXT_PARTS+=("Unresolved agent findings:")
    while IFS= read -r line; do
        CONTEXT_PARTS+=("  $line")
    done < "$FINDINGS_FILE"
fi

# --- Active traces ---
if [[ -d "$TRACE_STORE" ]]; then
    for marker in "$TRACE_STORE"/.active-*; do
        [[ ! -f "$marker" ]] && continue
        active_trace_id=$(cat "$marker" 2>/dev/null || echo "")
        if [[ -n "$active_trace_id" ]]; then
            CONTEXT_PARTS+=("Active trace: $active_trace_id (agent still running). TRACE_DIR=~/.claude/traces/$active_trace_id")
        fi
    done
fi

# --- Audit trail (last 5) ---
AUDIT_LOG="${CLAUDE_DIR}/.audit-log"
if [[ -f "$AUDIT_LOG" && -s "$AUDIT_LOG" ]]; then
    CONTEXT_PARTS+=("Recent audit (last 5):")
    while IFS= read -r line; do
        CONTEXT_PARTS+=("  $line")
    done < <(tail -5 "$AUDIT_LOG")
fi

# --- Write persistent file ---
# This file survives compaction and is read by session-init.sh on the
# SessionStart(compact) event. Belt-and-suspenders: even if the
# additionalContext is lost during compaction, session-init.sh can
# re-inject this data.
PRESERVE_FILE="${CLAUDE_DIR}/.preserved-context"
if [[ ${#CONTEXT_PARTS[@]} -gt 0 ]]; then
    mkdir -p "$PROJECT_ROOT/.claude"
    {
        echo "# Preserved context from pre-compaction ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
        printf '%s\n' "${CONTEXT_PARTS[@]}"
        # Include full file paths for re-navigation
        if [[ -n "${FULL_PATHS:-}" ]]; then
            echo ""
            echo "# Full paths of session-modified files:"
            echo "$FULL_PATHS"
        fi
    } > "$PRESERVE_FILE"
fi

# --- Output additionalContext ---
# Includes both the project state AND a directive for Claude to generate
# a structured context summary during compaction.
if [[ ${#CONTEXT_PARTS[@]} -gt 0 ]]; then
    DIRECTIVE="COMPACTION CONTEXT PRESERVATION: Before summarizing, generate a structured context summary following the context-preservation format: (1) Current Objective & Status — what is the goal, what is done, what is the immediate next step; (2) Active Context — absolute file paths being worked on, recent changes with function names; (3) Constraints & Decisions — user preferences, discarded approaches, architectural rules; (4) Continuity Handoff — 'When resuming, the first thing to do is...' with a specific actionable instruction. Include this summary in your compaction output so the next session can continue seamlessly."

    CONTEXT=$(printf '%s\n' "${CONTEXT_PARTS[@]}")
    FULL_OUTPUT="${DIRECTIVE}

--- Project State ---
${CONTEXT}"
    ESCAPED=$(echo "$FULL_OUTPUT" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreCompact",
    "additionalContext": $ESCAPED
  }
}
EOF
fi

exit 0
