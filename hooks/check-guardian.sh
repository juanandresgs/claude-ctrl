#!/usr/bin/env bash
# check-guardian.sh — SubagentStop:guardian hook
#
# Purpose: Deterministic post-guardian validation. Checks MASTER_PLAN.md recency,
# git cleanliness, test status, and approval-loop state after each guardian run.
# Cleans up .proof-status after a successful commit to reset the verification cycle.
# Advisory only (exit 0 always). Reports findings via additionalContext.
#
# Hook type: SubagentStop
# Trigger: After any Task tool invocation that ran the guardian agent
# Input: JSON on stdin with agent response text
# Output: JSON { "additionalContext": "..." } with validation findings
#
# @decision DEC-GUARDIAN-001
# @title Deterministic guardian validation replacing AI agent hook
# @status accepted
# @rationale AI agent hooks have non-deterministic runtime and cascade risk.
# File stat + git status complete in <1s with zero cascade risk. Post-commit
# .proof-status cleanup (Phase B) ensures the verification gate resets cleanly
# for the next implementation cycle, preventing stale "verified" state from
# bypassing the proof gate on subsequent tasks.

set -euo pipefail

source "$(dirname "$0")/source-lib.sh"

# Capture stdin (contains agent response)
AGENT_RESPONSE=$(read_input 2>/dev/null || echo "{}")

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)
PLAN="$PROJECT_ROOT/MASTER_PLAN.md"

# Track subagent completion
track_subagent_stop "$PROJECT_ROOT" "guardian"
append_session_event "agent_stop" "{\"type\":\"guardian\"}" "$PROJECT_ROOT"

# --- Trace protocol: detect and prepare for finalization ---
TRACE_ID=$(detect_active_trace "$PROJECT_ROOT" "guardian" 2>/dev/null || echo "")
TRACE_DIR=""
if [[ -n "$TRACE_ID" ]]; then
    TRACE_DIR="${TRACE_STORE}/${TRACE_ID}"
fi

get_git_state "$PROJECT_ROOT"
get_plan_status "$PROJECT_ROOT"
write_statusline_cache "$PROJECT_ROOT"

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
if read_test_status "$PROJECT_ROOT"; then
    if [[ "$TEST_RESULT" == "fail" && "$TEST_AGE" -lt 1800 ]]; then
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

# --- Trace protocol: finalize trace ---
if [[ -n "$TRACE_ID" ]]; then
    if [[ ! -f "$TRACE_DIR/summary.md" ]]; then
        echo "$RESPONSE_TEXT" | head -c 4000 > "$TRACE_DIR/summary.md" 2>/dev/null || true
    fi
    finalize_trace "$TRACE_ID" "$PROJECT_ROOT" "guardian"
fi

# Response size advisory
if [[ -n "$RESPONSE_TEXT" ]]; then
    WORD_COUNT=$(echo "$RESPONSE_TEXT" | wc -w | tr -d ' ')
    if [[ "$WORD_COUNT" -gt 1200 ]]; then
        ISSUES+=("Agent response too large (~${WORD_COUNT} words). Use TRACE_DIR for verbose output.")
    fi
fi

# --- Post-commit .proof-status cleanup ---
# When Guardian successfully committed, the verification cycle is complete.
# Clean .proof-status so it doesn't interfere with the next implementation cycle.
# This prevents stale "verified" state from bypassing the proof gate on the next task.
if [[ -n "$RESPONSE_TEXT" ]]; then
    HAS_COMMIT=$(echo "$RESPONSE_TEXT" | grep -iE 'committed|commit.*successful|pushed|merge.*complete' || echo "")
    if [[ -n "$HAS_COMMIT" ]]; then
        PROOF_FILE="${CLAUDE_DIR}/.proof-status"
        if [[ -f "$PROOF_FILE" ]]; then
            PROOF_VAL=$(cut -d'|' -f1 "$PROOF_FILE" 2>/dev/null || echo "")
            if [[ "$PROOF_VAL" == "verified" ]]; then
                rm -f "$PROOF_FILE"
                log_info "CHECK-GUARDIAN" "Cleaned .proof-status after successful commit"
            fi
        fi
    fi
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
    FINDINGS_FILE="${CLAUDE_DIR}/.agent-findings"
    mkdir -p "${PROJECT_ROOT}/.claude"
    FINDING="guardian|$(IFS=';'; echo "${ISSUES[*]}")"
    if ! grep -qxF "$FINDING" "$FINDINGS_FILE" 2>/dev/null; then
        echo "$FINDING" >> "$FINDINGS_FILE"
    fi
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
