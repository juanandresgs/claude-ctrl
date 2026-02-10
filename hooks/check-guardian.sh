#!/usr/bin/env bash
set -euo pipefail

# SubagentStop:guardian — deterministic validation of guardian actions.
# Replaces AI agent hook. Checks MASTER_PLAN.md recency and git cleanliness.
# Advisory only (exit 0 always). Reports findings via additionalContext.
#
# DECISION: Deterministic guardian validation. Rationale: AI agent hooks have
# non-deterministic runtime and cascade risk. File stat + git status complete
# in <1s with zero cascade risk. Status: accepted.

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

# Capture stdin (contains agent response)
AGENT_RESPONSE=$(read_input 2>/dev/null || echo "{}")

PROJECT_ROOT=$(detect_project_root)
PLAN="$PROJECT_ROOT/MASTER_PLAN.md"

# Track subagent completion
track_subagent_stop "$PROJECT_ROOT" "guardian"

ISSUES=()

# Extract agent's response text first (needed for phase-boundary detection)
RESPONSE_TEXT=$(echo "$AGENT_RESPONSE" | jq -r '.response // .result // .output // empty' 2>/dev/null || echo "")

# Detect plan completion state from actual plan content (not fragile response text matching)
get_plan_status "$PROJECT_ROOT"

# Detect if this was a phase-completing merge by looking for phase-completion language
IS_PHASE_COMPLETING=""
if [[ -n "$RESPONSE_TEXT" ]]; then
    IS_PHASE_COMPLETING=$(echo "$RESPONSE_TEXT" | grep -iE 'phase.*(complete|done|finished)|marking phase.*completed|status.*completed|phase completion' || echo "")
fi

# Content-based: if all plan phases are now completed, flag for archival
if [[ "$PLAN_LIFECYCLE" == "completed" ]]; then
    ISSUES+=("All plan phases completed ($PLAN_COMPLETED_PHASES/$PLAN_TOTAL_PHASES) — plan should be archived before new work begins.")
fi

# Check 1: MASTER_PLAN.md freshness — only for phase-completing merges
if [[ -n "$IS_PHASE_COMPLETING" ]]; then
    if [[ -f "$PLAN" ]]; then
        # Get modification time in epoch seconds
        if [[ "$(uname)" == "Darwin" ]]; then
            MOD_TIME=$(stat -f %m "$PLAN" 2>/dev/null || echo "0")
        else
            MOD_TIME=$(stat -c %Y "$PLAN" 2>/dev/null || echo "0")
        fi
        NOW=$(date +%s)
        AGE=$(( NOW - MOD_TIME ))

        if [[ "$AGE" -gt 300 ]]; then
            ISSUES+=("MASTER_PLAN.md not updated recently (${AGE}s ago) — expected update after phase-completing merge")
        fi
    else
        ISSUES+=("MASTER_PLAN.md not found — should exist before guardian merges")
    fi
elif [[ ! -f "$PLAN" ]]; then
    # Even for non-phase merges, flag if plan doesn't exist at all
    ISSUES+=("MASTER_PLAN.md not found — should exist before guardian merges")
fi

# Check 2: Git status is clean (no uncommitted changes)
DIRTY_COUNT=$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
if [[ "$DIRTY_COUNT" -gt 0 ]]; then
    ISSUES+=("$DIRTY_COUNT uncommitted change(s) remaining after guardian operation")
fi

# Check 3: Current branch info for context
CURRENT_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
LAST_COMMIT=$(git -C "$PROJECT_ROOT" log --oneline -1 2>/dev/null || echo "none")

# Check 4: Approval-loop detection — agent should not end with unanswered question
if [[ -n "$RESPONSE_TEXT" ]]; then
    # Check if response ends with an approval question
    HAS_APPROVAL_QUESTION=$(echo "$RESPONSE_TEXT" | grep -iE 'do you (approve|confirm|want me to proceed)|shall I (proceed|continue|merge)|ready to (merge|commit|proceed)\?' || echo "")
    # Check if response also contains execution confirmation
    HAS_EXECUTION=$(echo "$RESPONSE_TEXT" | grep -iE 'executing|done|merged|committed|completed|pushed|created branch|worktree created' || echo "")

    if [[ -n "$HAS_APPROVAL_QUESTION" && -z "$HAS_EXECUTION" ]]; then
        ISSUES+=("Agent ended with approval question but no execution confirmation — may need follow-up")
    fi
fi

# Check 5: Test status for git operations
TEST_STATUS_FILE="${PROJECT_ROOT}/.claude/.test-status"
if [[ -f "$TEST_STATUS_FILE" ]]; then
    TEST_RESULT=$(cut -d'|' -f1 "$TEST_STATUS_FILE")
    TEST_FAILS=$(cut -d'|' -f2 "$TEST_STATUS_FILE")
    TEST_TIME=$(cut -d'|' -f3 "$TEST_STATUS_FILE")
    NOW=$(date +%s)
    AGE=$(( NOW - TEST_TIME ))
    if [[ "$TEST_RESULT" == "fail" && "$AGE" -lt 1800 ]]; then
        HAS_GIT_OP=$(echo "$RESPONSE_TEXT" | grep -iE 'merged|committed|git merge|git commit' || echo "")
        if [[ -n "$HAS_GIT_OP" ]]; then
            ISSUES+=("CRITICAL: Tests failing ($TEST_FAILS) when git operations were performed")
        else
            ISSUES+=("Tests failing ($TEST_FAILS failures) — address before next git operation")
        fi
    fi
else
    ISSUES+=("No test results found — verify tests were run before committing")
fi

# Build context message
CONTEXT=""
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    CONTEXT="Guardian validation: ${#ISSUES[@]} issue(s)."
    for issue in "${ISSUES[@]}"; do
        CONTEXT+="\n- $issue"
    done
else
    CONTEXT="Guardian validation: clean. Branch=$CURRENT_BRANCH, last commit: $LAST_COMMIT"
fi

# Persist findings for next-prompt injection
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    FINDINGS_FILE="${PROJECT_ROOT}/.claude/.agent-findings"
    mkdir -p "${PROJECT_ROOT}/.claude"
    echo "guardian|$(IFS=';'; echo "${ISSUES[*]}")" >> "$FINDINGS_FILE"
    for issue in "${ISSUES[@]}"; do
        append_audit "$PROJECT_ROOT" "agent_guardian" "$issue"
    done
fi

# Output as additionalContext
ESCAPED=$(echo -e "$CONTEXT" | jq -Rs .)
cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF

exit 0
