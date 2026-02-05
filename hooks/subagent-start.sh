#!/usr/bin/env bash
set -euo pipefail

# Subagent context injection at spawn time.
# SubagentStart hook — matcher: (all agent types)
#
# Injects current project state into every subagent so Planner,
# Implementer, and Guardian agents always have fresh context:
#   - Current git branch and dirty state
#   - MASTER_PLAN.md existence and active phase
#   - Active worktrees
#   - Agent-type-specific guidance

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

HOOK_INPUT=$(read_input)
AGENT_TYPE=$(echo "$HOOK_INPUT" | jq -r '.agent_type // empty' 2>/dev/null)

PROJECT_ROOT=$(detect_project_root)
CONTEXT_PARTS=()

# --- Git + Plan state (one line) ---
get_git_state "$PROJECT_ROOT"
get_plan_status "$PROJECT_ROOT"

CTX_LINE="Context:"
[[ -n "$GIT_BRANCH" ]] && CTX_LINE="$CTX_LINE $GIT_BRANCH"
[[ "$GIT_DIRTY_COUNT" -gt 0 ]] && CTX_LINE="$CTX_LINE | $GIT_DIRTY_COUNT dirty"
[[ "$GIT_WT_COUNT" -gt 0 ]] && CTX_LINE="$CTX_LINE | $GIT_WT_COUNT worktrees"
if [[ "$PLAN_EXISTS" == "true" ]]; then
    [[ -n "$PLAN_PHASE" ]] && CTX_LINE="$CTX_LINE | Plan: $PLAN_PHASE" || CTX_LINE="$CTX_LINE | Plan: exists"
else
    CTX_LINE="$CTX_LINE | Plan: not found"
fi
CONTEXT_PARTS+=("$CTX_LINE")

# --- Agent-type-specific context ---
case "$AGENT_TYPE" in
    planner|Plan)
        CONTEXT_PARTS+=("Role: Planner — create MASTER_PLAN.md before any code. Include rationale, architecture, git issues, worktree strategy.")
        get_research_status "$PROJECT_ROOT"
        if [[ "$RESEARCH_EXISTS" == "true" ]]; then
            CONTEXT_PARTS+=("Research: $RESEARCH_ENTRY_COUNT entries ($RESEARCH_RECENT_TOPICS). Read .claude/research-log.md before researching — avoid duplicates.")
        else
            CONTEXT_PARTS+=("No prior research. /deep-research for tech comparisons, /last30days for community sentiment.")
        fi
        ;;
    implementer)
        # Check if any worktrees exist for this project
        if [[ "$GIT_WT_COUNT" -eq 0 ]]; then
            CONTEXT_PARTS+=("CRITICAL FIRST ACTION: No worktree detected. You MUST create a git worktree BEFORE writing any code. Run: git worktree add ../\<feature-name\> -b \<feature-name\> main — then cd into the worktree and work there. Do NOT write source code on main.")
        fi
        CONTEXT_PARTS+=("Role: Implementer — test-first development in isolated worktrees. Add @decision annotations to 50+ line files. NEVER work on main. The branch-guard hook will DENY any source file writes on main.")
        # Inject test status
        TEST_STATUS_FILE="${PROJECT_ROOT}/.claude/.test-status"
        if [[ -f "$TEST_STATUS_FILE" ]]; then
            TS_RESULT=$(cut -d'|' -f1 "$TEST_STATUS_FILE")
            TS_FAILS=$(cut -d'|' -f2 "$TEST_STATUS_FILE")
            if [[ "$TS_RESULT" == "fail" ]]; then
                CONTEXT_PARTS+=("WARNING: Tests currently FAILING ($TS_FAILS failures). Fix before proceeding.")
            fi
        fi
        get_research_status "$PROJECT_ROOT"
        if [[ "$RESEARCH_EXISTS" == "true" ]]; then
            CONTEXT_PARTS+=("Research log: $RESEARCH_ENTRY_COUNT entries. Check .claude/research-log.md before researching APIs or libraries.")
        fi
        CONTEXT_PARTS+=("VERIFICATION: Before committing, discover project MCP tools and use them to verify. Present verification checkpoint to user with live test instructions. User must confirm before commit.")
        ;;
    guardian)
        CONTEXT_PARTS+=("Role: Guardian — Update MASTER_PLAN.md ONLY at phase boundaries: when a merge completes a phase, update status to completed, populate Decision Log, present diff to user. For non-phase-completing merges, do NOT update the plan — close the relevant GitHub issues instead. Always: verify @decision annotations, check for staged secrets, require explicit approval.")
        # Inject test status
        TEST_STATUS_FILE="${PROJECT_ROOT}/.claude/.test-status"
        if [[ -f "$TEST_STATUS_FILE" ]]; then
            TS_RESULT=$(cut -d'|' -f1 "$TEST_STATUS_FILE")
            TS_FAILS=$(cut -d'|' -f2 "$TEST_STATUS_FILE")
            if [[ "$TS_RESULT" == "fail" ]]; then
                CONTEXT_PARTS+=("CRITICAL: Tests FAILING ($TS_FAILS failures). Do NOT commit/merge until tests pass.")
            fi
        fi
        ;;
    Bash|Explore)
        # Lightweight agents — minimal context
        ;;
    *)
        CONTEXT_PARTS+=("Agent type: ${AGENT_TYPE:-unknown}")
        ;;
esac

# --- Output ---
if [[ ${#CONTEXT_PARTS[@]} -gt 0 ]]; then
    CONTEXT=$(printf '%s\n' "${CONTEXT_PARTS[@]}")
    ESCAPED=$(echo "$CONTEXT" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SubagentStart",
    "additionalContext": $ESCAPED
  }
}
EOF
fi

exit 0
