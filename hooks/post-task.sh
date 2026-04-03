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
# Release active lease for this worktree on agent completion
# ---------------------------------------------------------------------------

_PROJECT_ROOT=$(detect_project_root 2>/dev/null || echo "")
if [[ -n "$_PROJECT_ROOT" ]]; then
    _ACTIVE_LEASE=$(cc_policy lease current --worktree-path "$_PROJECT_ROOT" 2>/dev/null) || _ACTIVE_LEASE=""
    _RELEASE_ID=$(printf '%s' "${_ACTIVE_LEASE:-}" | jq -r '.lease_id // empty' 2>/dev/null || true)
    [[ -n "$_RELEASE_ID" ]] && cc_policy lease release "$_RELEASE_ID" 2>/dev/null || true
fi

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
_DISPATCH_ERROR=""
case "$AGENT_TYPE" in
    planner|Plan)  NEXT_ROLE="implementer" ;;
    implementer)   NEXT_ROLE="tester"      ;;
    tester)
        # Route based on completion record verdict (Phase 2: DEC-COMPLETION-001).
        # check-tester.sh has already submitted a completion record and written
        # evaluation_state by the time post-task.sh fires for tester completion.
        # Prefer completion record verdict for deterministic routing.
        # Fall back to evaluation_state read when no lease/completion exists
        # (legacy path — no active lease issued for this workflow).
        _TESTER_NEXT_ROLE=""
        _TESTER_ROUTED=false

        # Attempt completion-record-based routing first.
        if [[ -n "$_WF_ID" ]]; then
            _TESTER_LEASE_JSON=$(rt_lease_current "${_PROJECT_ROOT:-}")
            _TESTER_LEASE_ID=$(printf '%s' "${_TESTER_LEASE_JSON:-}" | jq -r '.lease_id // empty' 2>/dev/null || true)
            if [[ -n "$_TESTER_LEASE_ID" ]]; then
                _TESTER_COMP=$(rt_completion_latest "$_TESTER_LEASE_ID")
                _TESTER_COMP_FOUND=$(printf '%s' "${_TESTER_COMP:-}" | jq -r '.found // "false"' 2>/dev/null || echo "false")
                _TESTER_COMP_VALID=$(printf '%s' "${_TESTER_COMP:-}" | jq -r '.valid // 0' 2>/dev/null || echo "0")
                if [[ "$_TESTER_COMP_FOUND" == "true" ]]; then
                    if [[ "$_TESTER_COMP_VALID" != "1" && "$_TESTER_COMP_VALID" != "true" ]]; then
                        # Completion record exists but is invalid — hard process error.
                        # Do NOT enqueue next role; surface as error event.
                        rt_event_emit "post_task_error" "tester completion record invalid for workflow $_WF_ID" || true
                        _TESTER_ROUTED=true  # prevent fallback
                        _DISPATCH_ERROR="PROCESS ERROR: Tester completion record invalid for workflow $_WF_ID lease $_TESTER_LEASE_ID. Contract not fulfilled."
                    else
                        _TESTER_VERDICT=$(printf '%s' "$_TESTER_COMP" | jq -r '.verdict // empty' 2>/dev/null || true)
                        case "${_TESTER_VERDICT:-}" in
                            ready_for_guardian) _TESTER_NEXT_ROLE="guardian"    ;;
                            needs_changes)      _TESTER_NEXT_ROLE="implementer" ;;
                            blocked_by_plan)    _TESTER_NEXT_ROLE="planner"     ;;
                            *)                  _TESTER_NEXT_ROLE="guardian"    ;;
                        esac
                        _TESTER_ROUTED=true
                        # Release lease now that routing is determined.
                        rt_lease_release "$_TESTER_LEASE_ID" || true
                    fi
                else
                    # Lease exists but no completion record — tester did not fulfill contract.
                    rt_event_emit "completion_missing" "tester lease $_TESTER_LEASE_ID has no completion record for workflow $_WF_ID" || true
                    _TESTER_ROUTED=true  # prevent legacy fallback
                    _DISPATCH_ERROR="PROCESS ERROR: Tester completed with active lease $_TESTER_LEASE_ID but no completion record. Contract not fulfilled."
                fi
            fi
        fi

        # Legacy fallback: no active lease → use evaluation_state directly.
        if [[ "$_TESTER_ROUTED" != "true" ]]; then
            _EVAL_STATUS=""
            if [[ -n "$_WF_ID" ]]; then
                _EVAL_STATUS=$(rt_eval_get "$_WF_ID" 2>/dev/null || echo "idle")
            fi
            case "${_EVAL_STATUS:-idle}" in
                ready_for_guardian) _TESTER_NEXT_ROLE="guardian"    ;;
                needs_changes)      _TESTER_NEXT_ROLE="implementer" ;;
                blocked_by_plan)    _TESTER_NEXT_ROLE="planner"     ;;
                *)                  _TESTER_NEXT_ROLE="guardian"    ;;
            esac
        fi
        NEXT_ROLE="$_TESTER_NEXT_ROLE"
        ;;
    guardian)
        # Route based on completion record verdict (Phase 2: DEC-COMPLETION-001).
        # Guardian completion is advisory in v1 but informs routing.
        _GUARDIAN_NEXT_ROLE=""
        _GUARDIAN_ROUTED=false

        if [[ -n "$_WF_ID" ]]; then
            _GUARDIAN_LEASE_JSON=$(rt_lease_current "${_PROJECT_ROOT:-}")
            _GUARDIAN_LEASE_ID=$(printf '%s' "${_GUARDIAN_LEASE_JSON:-}" | jq -r '.lease_id // empty' 2>/dev/null || true)
            if [[ -n "$_GUARDIAN_LEASE_ID" ]]; then
                _GUARDIAN_COMP=$(rt_completion_latest "$_GUARDIAN_LEASE_ID")
                _GUARDIAN_COMP_FOUND=$(printf '%s' "${_GUARDIAN_COMP:-}" | jq -r '.found // "false"' 2>/dev/null || echo "false")
                _GUARDIAN_COMP_VALID=$(printf '%s' "${_GUARDIAN_COMP:-}" | jq -r '.valid // 0' 2>/dev/null || echo "0")
                if [[ "$_GUARDIAN_COMP_FOUND" == "true" ]]; then
                    if [[ "$_GUARDIAN_COMP_VALID" != "1" && "$_GUARDIAN_COMP_VALID" != "true" ]]; then
                        rt_event_emit "post_task_error" "guardian completion record invalid for workflow $_WF_ID" || true
                        _GUARDIAN_ROUTED=true  # prevent fallback, cycle is terminal anyway
                        _DISPATCH_ERROR="PROCESS ERROR: Guardian completion record invalid for workflow $_WF_ID lease $_GUARDIAN_LEASE_ID. Contract not fulfilled."
                    else
                        _GUARDIAN_VERDICT=$(printf '%s' "$_GUARDIAN_COMP" | jq -r '.verdict // empty' 2>/dev/null || true)
                        case "${_GUARDIAN_VERDICT:-}" in
                            committed|merged) _GUARDIAN_NEXT_ROLE=""          ;;  # cycle complete
                            denied|skipped)   _GUARDIAN_NEXT_ROLE="implementer" ;;
                            *)                _GUARDIAN_NEXT_ROLE=""          ;;
                        esac
                        _GUARDIAN_ROUTED=true
                        rt_lease_release "$_GUARDIAN_LEASE_ID" || true
                    fi
                else
                    # Lease exists but no completion record — guardian did not fulfill contract.
                    rt_event_emit "completion_missing" "guardian lease $_GUARDIAN_LEASE_ID has no completion record for workflow $_WF_ID" || true
                    _GUARDIAN_ROUTED=true  # prevent fallback
                    _DISPATCH_ERROR="PROCESS ERROR: Guardian completed with active lease $_GUARDIAN_LEASE_ID but no completion record. Contract not fulfilled."
                fi
            fi
        fi

        NEXT_ROLE="${_GUARDIAN_NEXT_ROLE:-}"  # empty = dispatch cycle complete
        ;;
    *)             exit 0                  ;;  # unknown type — stay silent
esac

# ---------------------------------------------------------------------------
# Enqueue the next role (when applicable) and emit a context suggestion
# ---------------------------------------------------------------------------

if [[ -n "${_DISPATCH_ERROR:-}" ]]; then
    # Hard process error — surface in additionalContext so the orchestrator sees it.
    ESCAPED=$(printf '%s' "$_DISPATCH_ERROR" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SubagentStop",
    "additionalContext": $ESCAPED
  }
}
EOF
elif [[ -n "$NEXT_ROLE" ]]; then
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
