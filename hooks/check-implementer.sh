#!/usr/bin/env bash
set -euo pipefail

# SubagentStop:implementer — deterministic validation of implementer output.
# Replaces AI agent hook. Checks worktree usage and @decision annotation coverage.
# Advisory only (exit 0 always). Reports findings via additionalContext.
#
# DECISION: Deterministic implementer validation. Rationale: AI agent hooks have
# non-deterministic runtime and cascade risk. Branch check is git rev-parse,
# @decision check is grep. Both complete in <1s. Status: accepted.

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

# Capture stdin (contains agent response)
AGENT_RESPONSE=$(read_input 2>/dev/null || echo "{}")
AGENT_TYPE=$(printf '%s' "$AGENT_RESPONSE" | jq -r '.agent_type // empty' 2>/dev/null || true)

PROJECT_ROOT=$(detect_project_root)

# track_subagent_stop removed (TKT-008): .subagent-tracker no longer written.

# Deactivate runtime marker for this completing agent.
# SubagentStart sets markers as "agent-$$" (current PID); SubagentStop runs
# in a different process so $$ does not match. We resolve by querying the
# active marker and comparing its role to the stopping agent type, then
# deactivating by the stored agent_id. No-op when role does not match (guards
# against clearing a concurrently active marker of a different role).
if [[ -n "$AGENT_TYPE" ]]; then
    _active_json=$(cc_policy marker get-active 2>/dev/null) || _active_json=""
    if [[ -n "$_active_json" ]]; then
        _active_role=$(printf '%s' "$_active_json" | jq -r 'if .found then .role else empty end' 2>/dev/null)
        _active_id=$(printf '%s' "$_active_json" | jq -r 'if .found then .agent_id else empty end' 2>/dev/null)
        if [[ "$_active_role" == "$AGENT_TYPE" && -n "$_active_id" ]]; then
            rt_marker_deactivate "$_active_id" 2>/dev/null || true
        fi
    fi
fi

ISSUES=()

# Check 1: Current branch is NOT main/master (worktree was used)
CURRENT_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
    ISSUES+=("Implementation on $CURRENT_BRANCH branch — worktree should have been used")
fi

# Check 2: Scan session-changes for 50+ line source files missing @decision
get_session_changes "$PROJECT_ROOT"
CHANGES="${SESSION_FILE:-}"

MISSING_COUNT=0
MISSING_FILES=""
DECISION_PATTERN='@decision|# DECISION:|// DECISION\('

if [[ -n "$CHANGES" && -f "$CHANGES" ]]; then
    while IFS= read -r file; do
        [[ ! -f "$file" ]] && continue
        # Only check source files
        [[ ! "$file" =~ \.(ts|tsx|js|jsx|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php|sh)$ ]] && continue
        # Skip test/config
        [[ "$file" =~ (\.test\.|\.spec\.|__tests__|\.config\.|node_modules|vendor|dist|\.git|\.claude) ]] && continue

        # Check line count
        line_count=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
        if [[ "$line_count" -ge 50 ]]; then
            if ! grep -qE "$DECISION_PATTERN" "$file" 2>/dev/null; then
                ((MISSING_COUNT++)) || true
                MISSING_FILES+="  - $(basename "$file") ($line_count lines)\n"
            fi
        fi
    done < <(sort -u "$CHANGES")
fi

if [[ "$MISSING_COUNT" -gt 0 ]]; then
    ISSUES+=("$MISSING_COUNT source file(s) ≥50 lines missing @decision annotation")
fi

# Check 3: Approval-loop detection — agent should not end with unanswered question
RESPONSE_TEXT=$(echo "$AGENT_RESPONSE" | jq -r '.response // .result // .output // empty' 2>/dev/null || echo "")
if [[ -n "$RESPONSE_TEXT" ]]; then
    HAS_APPROVAL_QUESTION=$(echo "$RESPONSE_TEXT" | grep -iE 'do you (approve|confirm|want me to proceed)|shall I (proceed|continue)|ready to (test|review|commit)\?' || echo "")
    HAS_EXECUTION=$(echo "$RESPONSE_TEXT" | grep -iE 'tests pass|implementation complete|done|finished|all tests|ready for review' || echo "")

    if [[ -n "$HAS_APPROVAL_QUESTION" && -z "$HAS_EXECUTION" ]]; then
        ISSUES+=("Agent ended with approval question but no completion confirmation — may need follow-up")
    fi
fi

# Check 4: Test status verification
TEST_STATUS_FILE="${PROJECT_ROOT}/.claude/.test-status"
if [[ -f "$TEST_STATUS_FILE" ]]; then
    TEST_RESULT=$(cut -d'|' -f1 "$TEST_STATUS_FILE")
    TEST_FAILS=$(cut -d'|' -f2 "$TEST_STATUS_FILE")
    TEST_TIME=$(cut -d'|' -f3 "$TEST_STATUS_FILE")
    NOW=$(date +%s)
    AGE=$(( NOW - TEST_TIME ))
    if [[ "$TEST_RESULT" == "fail" && "$AGE" -lt 1800 ]]; then
        ISSUES+=("Tests failing ($TEST_FAILS failures, ${AGE}s ago) — implementation not complete")
    fi
else
    # No test results at all — warn (project may not have tests, so advisory)
    ISSUES+=("No test results found — verify tests were run before declaring done")
fi

# Check 5: Evaluator-state handoff status (TKT-024)
# Reports evaluation_state language instead of proof-era language.
EVAL_STATUS=$(read_evaluation_status "$PROJECT_ROOT")
case "$EVAL_STATUS" in
    ready_for_guardian)
        VERIFICATION_NOTE="Evaluation state: ready_for_guardian — Guardian may proceed."
        ;;
    needs_changes)
        VERIFICATION_NOTE="Evaluation state: needs_changes — Tester found issues. Address them before re-dispatching Tester."
        ;;
    blocked_by_plan)
        VERIFICATION_NOTE="Evaluation state: blocked_by_plan — Tester flagged a plan gap. Dispatch Planner to resolve."
        ;;
    pending)
        VERIFICATION_NOTE="Evaluation state: pending — dispatch Tester to evaluate this implementation."
        ;;
    *)
        VERIFICATION_NOTE="Evaluation state: idle — dispatch Tester after implementation evidence is prepared."
        ;;
esac

# Check 6: Workflow scope compliance (advisory — guard.sh enforces the hard deny)
# Get changed files relative to base branch (uses workflow binding if available).
_WF_ID=$(current_workflow_id "$PROJECT_ROOT")
_CHANGED_FILES_JSON="[]"
_BASE_BRANCH="main"

# Try to get base_branch from binding
_BINDING_JSON=$(cc_policy workflow get "$_WF_ID" 2>/dev/null) || _BINDING_JSON=""
if [[ -n "$_BINDING_JSON" ]]; then
    _FOUND=$(printf '%s' "$_BINDING_JSON" | jq -r 'if .found then "yes" else "no" end' 2>/dev/null || echo "no")
    if [[ "$_FOUND" == "yes" ]]; then
        _BASE_BRANCH=$(printf '%s' "$_BINDING_JSON" | jq -r '.base_branch // "main"' 2>/dev/null || echo "main")
    fi
fi

# Collect changed files vs base branch
_CHANGED_RAW=$(git -C "$PROJECT_ROOT" diff --name-only "$_BASE_BRANCH"...HEAD 2>/dev/null || echo "")
if [[ -n "$_CHANGED_RAW" ]]; then
    _CHANGED_FILES_JSON=$(printf '%s\n' "$_CHANGED_RAW" | jq -Rs 'split("\n") | map(select(. != ""))' 2>/dev/null || echo "[]")
fi

# Check compliance (advisory only — exit 0 regardless)
_SCOPE_RESULT=$(rt_workflow_scope_check "$_WF_ID" "$_CHANGED_FILES_JSON") || _SCOPE_RESULT=""
if [[ -n "$_SCOPE_RESULT" ]]; then
    _COMPLIANT=$(printf '%s' "$_SCOPE_RESULT" | jq -r '.compliant // "true"' 2>/dev/null || echo "true")
    if [[ "$_COMPLIANT" == "false" ]]; then
        _VIOLATIONS=$(printf '%s' "$_SCOPE_RESULT" | jq -r '.violations[]? // empty' 2>/dev/null || echo "")
        ISSUES+=("Workflow scope violations detected (advisory — guard.sh will enforce on commit):")
        while IFS= read -r viol; do
            [[ -n "$viol" ]] && ISSUES+=("  $viol")
        done <<< "$_VIOLATIONS"
    fi
    _NOTE=$(printf '%s' "$_SCOPE_RESULT" | jq -r '.note // empty' 2>/dev/null || echo "")
    if [[ -n "$_NOTE" ]]; then
        ISSUES+=("Scope note: $_NOTE")
    fi
elif [[ -z "$_BINDING_JSON" || "$_FOUND" != "yes" ]]; then
    ISSUES+=("No workflow binding found for '$_WF_ID' — guard.sh will deny commit without binding.")
fi

# Build context message
CONTEXT=""
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    CONTEXT="Implementer validation: ${#ISSUES[@]} issue(s)."
    for issue in "${ISSUES[@]}"; do
        CONTEXT+="\n- $issue"
    done
    if [[ -n "$MISSING_FILES" ]]; then
        CONTEXT+="\nFiles needing @decision:\n$MISSING_FILES"
    fi
else
    CONTEXT="Implementer validation: branch=$CURRENT_BRANCH, @decision coverage OK."
fi
CONTEXT+="\n$VERIFICATION_NOTE"

# Emit findings to runtime event store (TKT-008: .agent-findings flat file removed).
# Events are queryable via cc-policy and surface through the runtime event log.
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    for issue in "${ISSUES[@]}"; do
        rt_event_emit "agent_finding" "implementer|$issue" || true
        append_audit "$PROJECT_ROOT" "agent_implementer" "$issue"
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
