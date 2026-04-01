#!/usr/bin/env bash
# post-task.sh — Dispatch emission after agent completion.
# SubagentStop hook — fires when a named agent task ends.
#
# Records the completion in the SQLite event store and enqueues the next
# role in the canonical dispatch flow (planner→implementer→tester→guardian).
# Returns an additionalContext suggestion so the orchestrator sees the next
# dispatch step in its context window without requiring manual tracking.
#
# @decision DEC-DISPATCH-001
# @title Dispatch queue emission on agent stop
# @status accepted
# @rationale The canonical flow (planner→implementer→tester→guardian) was
#   previously prompt-driven with no persistent queue. This hook records
#   completions in SQLite via cc-policy and suggests next steps, making
#   the flow visible and auditable without forcing automatic dispatch.
#   The guardian case produces no suggestion because the cycle is complete.
#   Unknown/absent agent_type exits silently — hooks must not interfere
#   with inputs they do not own.
set -euo pipefail

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

# ---------------------------------------------------------------------------
# Read and validate hook input
# ---------------------------------------------------------------------------

HOOK_INPUT=$(read_input)

# Tolerate both snake_case and camelCase field names for agent type
AGENT_TYPE=$(echo "$HOOK_INPUT" | jq -r '
    .agent_type //
    .agentType  //
    empty
' 2>/dev/null || true)

# Exit silently when agent_type is absent or empty; this hook only acts on
# named agent completions in the canonical flow.
[[ -z "$AGENT_TYPE" ]] && exit 0

# ---------------------------------------------------------------------------
# Record completion event in the audit store
# ---------------------------------------------------------------------------

rt_event_emit "agent_complete" "Agent $AGENT_TYPE completed" || true

# ---------------------------------------------------------------------------
# Evaluate-state writes (TKT-024)
# ---------------------------------------------------------------------------

_PROJECT_ROOT=$(detect_project_root 2>/dev/null || echo "")
_WF_ID=""
if [[ -n "$_PROJECT_ROOT" ]]; then
    _WF_ID=$(current_workflow_id "$_PROJECT_ROOT" 2>/dev/null || echo "")
fi

# Implementer completion: set evaluation_state = pending so tester knows
# fresh work awaits evaluation. This is the sole post-task writer for pending.
if [[ "$AGENT_TYPE" == "implementer" && -n "$_WF_ID" ]]; then
    if ! is_claude_meta_repo "${_PROJECT_ROOT:-/}"; then
        rt_eval_set "$_WF_ID" "pending" || true
        rt_event_emit "eval_pending" "$_WF_ID" || true
    fi
fi

# ---------------------------------------------------------------------------
# Determine the next role in the canonical dispatch flow
# ---------------------------------------------------------------------------

NEXT_ROLE=""
case "$AGENT_TYPE" in
    planner|Plan)  NEXT_ROLE="implementer" ;;
    implementer)   NEXT_ROLE="tester"      ;;
    tester)
        # Route based on evaluator verdict (TKT-024).
        # check-tester.sh has already written evaluation_state by the time
        # post-task.sh fires for tester completion.
        _EVAL_STATUS=""
        if [[ -n "$_WF_ID" ]]; then
            _EVAL_STATUS=$(rt_eval_get "$_WF_ID" 2>/dev/null || echo "idle")
        fi
        case "${_EVAL_STATUS:-idle}" in
            ready_for_guardian) NEXT_ROLE="guardian"    ;;
            needs_changes)      NEXT_ROLE="implementer" ;;
            blocked_by_plan)    NEXT_ROLE="planner"     ;;
            *)                  NEXT_ROLE="guardian"    ;;  # safe default
        esac
        ;;
    guardian)      NEXT_ROLE=""            ;;  # dispatch cycle complete
    *)             exit 0                  ;;  # unknown type — stay silent
esac

# ---------------------------------------------------------------------------
# Enqueue the next role (when applicable) and emit a context suggestion
# ---------------------------------------------------------------------------

if [[ -n "$NEXT_ROLE" ]]; then
    # Enqueue into the persistent dispatch queue; failure is non-fatal so a
    # degraded runtime does not block the agent conversation.
    _rt_ensure_schema
    cc_policy dispatch enqueue "$NEXT_ROLE" >/dev/null 2>&1 || true

    # Include workflow_id in dispatch context so the orchestrator can pass it
    # to the next agent without re-deriving from CWD (DEC-WF-001).
    SUGGESTION="Canonical flow suggests dispatching: $NEXT_ROLE"
    [[ -n "$_WF_ID" ]] && SUGGESTION="$SUGGESTION (workflow_id=$_WF_ID)"
    # For tester routing, surface the evaluation verdict in the suggestion
    if [[ "$AGENT_TYPE" == "tester" && -n "${_EVAL_STATUS:-}" ]]; then
        SUGGESTION="$SUGGESTION [eval=$_EVAL_STATUS]"
    fi
    ESCAPED=$(printf '%s' "$SUGGESTION" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SubagentStop",
    "additionalContext": $ESCAPED
  }
}
EOF
else
    # Guardian is the terminal role — record cycle completion and stay silent
    # (no additionalContext output so the orchestrator is not given a phantom
    # next step).
    rt_event_emit "cycle_complete" "Guardian completed — dispatch cycle done" || true
fi

exit 0
