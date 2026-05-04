#!/usr/bin/env bash
set -euo pipefail

# Pre-compaction context preservation.
# PreCompact hook
#
# Two outputs:
#   1. SQLite preserved_contexts row (survives compaction, read by session-init.sh)
#   2. additionalContext: injected into the system message before compaction
#
# The additionalContext includes a directive instructing Claude to generate
# a structured context summary (per context-preservation skill) as part of
# the compaction. This ensures session intent (not just project state) survives.

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

PROJECT_ROOT=$(detect_project_root)
SESSION_ID=$(canonical_session_id)
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

# --- MASTER_PLAN.md (via shared library) ---
get_plan_status "$PROJECT_ROOT"

if [[ "$PLAN_EXISTS" == "true" ]]; then
    PLAN_LINE="Plan: $PLAN_COMPLETED_PHASES/$PLAN_TOTAL_PHASES phases done"
    [[ -n "$PLAN_PHASE" ]] && PLAN_LINE="$PLAN_LINE | active: $PLAN_PHASE"
    CONTEXT_PARTS+=("$PLAN_LINE")
fi

# --- Session file changes ---
get_session_changes "$PROJECT_ROOT"
CHANGES_TEXT="${SESSION_CHANGES_TEXT:-}"

if [[ -n "$CHANGES_TEXT" ]]; then
    FILE_COUNT=$(printf '%s\n' "$CHANGES_TEXT" | sort -u | wc -l | tr -d ' ')
    FILE_LIST=$(printf '%s\n' "$CHANGES_TEXT" | sort -u | head -5 | xargs -I{} basename {} | paste -sd', ' -)
    REMAINING=$((FILE_COUNT - 5))
    if [[ "$REMAINING" -gt 0 ]]; then
        CONTEXT_PARTS+=("Modified this session: $FILE_LIST (+$REMAINING more)")
    else
        CONTEXT_PARTS+=("Modified this session: $FILE_LIST")
    fi

    # Full paths for context (written to file, not displayed)
    FULL_PATHS=$(printf '%s\n' "$CHANGES_TEXT" | sort -u | head -10)

    # --- Key @decisions made this session ---
    DECISIONS_FOUND=()
    while IFS= read -r file; do
        [[ ! -f "$file" ]] && continue
        decision_line=$(grep -oE '@decision\s+[A-Z]+-[A-Z0-9-]+' "$file" 2>/dev/null | head -1 || echo "")
        if [[ -n "$decision_line" ]]; then
            DECISIONS_FOUND+=("$decision_line ($(basename "$file"))")
        fi
    done < <(printf '%s\n' "$CHANGES_TEXT" | sort -u)

    if [[ ${#DECISIONS_FOUND[@]} -gt 0 ]]; then
        DECISIONS_LINE=$(printf '%s, ' "${DECISIONS_FOUND[@]:0:5}")
        CONTEXT_PARTS+=("Decisions: ${DECISIONS_LINE%, }")
    fi
fi

# --- Test status (WS3: reads SQLite test_state, not flat file) ---
_CP_TS_JSON=$(rt_test_state_get "$PROJECT_ROOT") || _CP_TS_JSON=""
_CP_TS_FOUND=$(printf '%s' "${_CP_TS_JSON:-}" | jq -r 'if .found then "yes" else "no" end' 2>/dev/null || echo "no")
if [[ "$_CP_TS_FOUND" == "yes" ]]; then
    _CP_TS_STATUS=$(printf '%s' "$_CP_TS_JSON" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
    _CP_TS_FAILS=$(printf '%s' "$_CP_TS_JSON" | jq -r '.fail_count // 0' 2>/dev/null || echo "0")
    CONTEXT_PARTS+=("Test status: ${_CP_TS_STATUS} (${_CP_TS_FAILS} failures)")
fi

# --- Agent findings (unresolved issues from subagents, runtime event store) ---
# @decision DEC-FINDINGS-001 (see prompt-submit.sh for full rationale)
# Flat-file .agent-findings removed; query runtime event store instead.
FINDINGS_JSON=$(cc_policy event query --type "agent_finding" --limit 5 2>/dev/null || echo '{"items":[],"count":0}')
FINDINGS_COUNT=$(printf '%s' "$FINDINGS_JSON" | jq -r '.count // 0' 2>/dev/null || echo "0")
if [[ "$FINDINGS_COUNT" -gt 0 ]]; then
    CONTEXT_PARTS+=("Unresolved agent findings:")
    while IFS= read -r detail; do
        [[ -z "$detail" ]] && continue
        CONTEXT_PARTS+=("  $detail")
    done < <(printf '%s' "$FINDINGS_JSON" | jq -r '.items[]?.detail // empty' 2>/dev/null)
fi

# --- Audit trail (last 5) ---
AUDIT_LOG="${PROJECT_ROOT}/.claude/.audit-log"
if [[ -f "$AUDIT_LOG" && -s "$AUDIT_LOG" ]]; then
    CONTEXT_PARTS+=("Recent audit (last 5):")
    while IFS= read -r line; do
        CONTEXT_PARTS+=("  $line")
    done < <(tail -5 "$AUDIT_LOG")
fi

# --- Persist handoff in state.db ---
# This row survives compaction and is read by session-init.sh on the
# SessionStart(compact) event. Belt-and-suspenders: even if the
# additionalContext is lost during compaction, session-init.sh can
# re-inject this data without a project-local flatfile authority.
if [[ ${#CONTEXT_PARTS[@]} -gt 0 ]]; then
    PRESERVED_TEXT=$(
        {
        echo "# Preserved context from pre-compaction ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
        printf '%s\n' "${CONTEXT_PARTS[@]}"
        # Include full file paths for re-navigation
        if [[ -n "${FULL_PATHS:-}" ]]; then
            echo ""
            echo "# Full paths of session-modified files:"
            echo "$FULL_PATHS"
        fi
        }
    )
    printf '%s' "$PRESERVED_TEXT" | cc_policy preserved-context save \
        --project-root "$PROJECT_ROOT" \
        --session-id "$SESSION_ID" >/dev/null 2>&1 || true
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
