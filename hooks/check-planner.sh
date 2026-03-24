#!/usr/bin/env bash
set -euo pipefail

# SubagentStop:planner — deterministic validation of planner output.
# Replaces AI agent hook. Checks MASTER_PLAN.md exists and has required structure.
# Advisory only (exit 0 always). Reports findings via additionalContext.
#
# DECISION: Deterministic planner validation. Rationale: AI agent hooks have
# non-deterministic runtime and cascade risk. Every check here is a grep/stat
# that completes in <1s. Status: accepted.

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

# Capture stdin (contains agent response)
AGENT_RESPONSE=$(read_input 2>/dev/null || echo "{}")
AGENT_TYPE=$(printf '%s' "$AGENT_RESPONSE" | jq -r '.agent_type // empty' 2>/dev/null || true)

PROJECT_ROOT=$(detect_project_root)
PLAN="$PROJECT_ROOT/MASTER_PLAN.md"

# Track subagent completion
track_subagent_stop "$PROJECT_ROOT" "planner"

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
CONTEXT=""

# Check 1: MASTER_PLAN.md exists
if [[ ! -f "$PLAN" ]]; then
    ISSUES+=("MASTER_PLAN.md not found in project root")
else
    # Check 2: Has phase headers
    PHASE_COUNT=$(grep -cE '^\#\#\s+Phase\s+[0-9]' "$PLAN" 2>/dev/null || echo "0")
    if [[ "$PHASE_COUNT" -eq 0 ]]; then
        ISSUES+=("MASTER_PLAN.md has no ## Phase headers")
    fi

    # Check 3: Has intent/vision/purpose section
    if ! grep -qiE '^\#\#\s*(intent|vision|purpose|problem|overview|goal)' "$PLAN" 2>/dev/null; then
        # Also check for common first-section patterns
        if ! grep -qiE '^\#\#\s*(what|why|background|summary)' "$PLAN" 2>/dev/null; then
            ISSUES+=("MASTER_PLAN.md may lack an intent/vision section")
        fi
    fi

    # Check 4: Has git issues or tasks
    if ! grep -qiE 'issue|task|TODO|work.?item' "$PLAN" 2>/dev/null; then
        ISSUES+=("MASTER_PLAN.md may lack git issues or task breakdown")
    fi
fi

# Check 5: Approval-loop detection — agent should not end with unanswered question
RESPONSE_TEXT=$(echo "$AGENT_RESPONSE" | jq -r '.response // .result // .output // empty' 2>/dev/null || echo "")
if [[ -n "$RESPONSE_TEXT" ]]; then
    HAS_APPROVAL_QUESTION=$(echo "$RESPONSE_TEXT" | grep -iE 'do you (approve|confirm|want me to proceed)|shall I (proceed|continue|write)|ready to (begin|start|implement)\?' || echo "")
    HAS_COMPLETION=$(echo "$RESPONSE_TEXT" | grep -iE 'plan (complete|ready|written)|MASTER_PLAN\.md (created|written|updated)|created.*issues|phases defined' || echo "")

    if [[ -n "$HAS_APPROVAL_QUESTION" && -z "$HAS_COMPLETION" ]]; then
        ISSUES+=("Agent ended with approval question but no plan completion confirmation — may need follow-up")
    fi
fi

# Build context message
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    CONTEXT="Planner validation: ${#ISSUES[@]} issue(s) found."
    for issue in "${ISSUES[@]}"; do
        CONTEXT+="\n- $issue"
    done
else
    CONTEXT="Planner validation: MASTER_PLAN.md looks good ($PHASE_COUNT phases defined)."
fi

# Persist findings for next-prompt injection
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    FINDINGS_FILE="${PROJECT_ROOT}/.claude/.agent-findings"
    mkdir -p "${PROJECT_ROOT}/.claude"
    echo "planner|$(IFS=';'; echo "${ISSUES[*]}")" >> "$FINDINGS_FILE"
    for issue in "${ISSUES[@]}"; do
        append_audit "$PROJECT_ROOT" "agent_planner" "$issue"
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
