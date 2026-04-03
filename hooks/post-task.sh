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
#
# @decision DEC-ROUTING-002
# @title Lease released AFTER routing; rt_eval_get fallback deleted (TKT-STAB-A2)
# @status accepted
# @rationale The prior implementation released the lease unconditionally at
#   lines 52-57 BEFORE the routing block. Because rt_lease_current only returns
#   active leases, the completion-record routing path was unreachable dead code —
#   the hook always fell through to the rt_eval_get eval_state fallback.
#   Fix: (1) remove the early lease release; (2) read the lease inside each
#   role's routing block; (3) release the lease only AFTER routing is determined;
#   (4) delete the rt_eval_get fallback entirely (TKT-STAB-A2 cutover).
#   (5) routing is now exclusively via rt_completion_route (cc-policy completion
#   route <role> <verdict>), which delegates to determine_next_role() in
#   completions.py — the single authoritative routing table (DEC-COMPLETION-001).
#   No case statement in bash maps verdicts to roles; that logic lives only in
#   completions.py.
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
# Resolve project root and workflow_id (used by all routing blocks below)
#
# WS1: lease_context() is the identity source for leased paths.
# When a lease is active its workflow_id wins over the branch-derived one.
# Branch-derived id is the fallback only when no lease exists.
# ---------------------------------------------------------------------------

_PROJECT_ROOT=$(detect_project_root 2>/dev/null || echo "")
_WF_ID=""
_ACTIVE_LEASE_ID=""
if [[ -n "$_PROJECT_ROOT" ]]; then
    _LEASE_CTX=$(lease_context "${_PROJECT_ROOT:-}")
    _LEASE_FOUND=$(printf '%s' "$_LEASE_CTX" | jq -r '.found' 2>/dev/null || echo "false")
    if [[ "$_LEASE_FOUND" == "true" ]]; then
        _WF_ID=$(printf '%s' "$_LEASE_CTX" | jq -r '.workflow_id // empty' 2>/dev/null || true)
        _ACTIVE_LEASE_ID=$(printf '%s' "$_LEASE_CTX" | jq -r '.lease_id // empty' 2>/dev/null || true)
    fi
    [[ -z "$_WF_ID" ]] && _WF_ID=$(current_workflow_id "$_PROJECT_ROOT" 2>/dev/null || echo "")
fi

# ---------------------------------------------------------------------------
# Implementer completion: set evaluation_state = pending (TKT-024)
# ---------------------------------------------------------------------------

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
#
# Key invariant (DEC-ROUTING-002): The lease is read and released INSIDE each
# role's routing block, never before. rt_lease_current returns active leases
# only; releasing it early makes the completion record unreachable.
#
# For tester and guardian: routing is exclusively via rt_completion_route.
# No case statement maps verdicts to roles here — that logic lives in
# completions.py::determine_next_role() (DEC-COMPLETION-001).
# If no lease or no completion record: PROCESS ERROR (no fallback).
#
# For planner/implementer: fixed transitions — no completion record needed (v1).

NEXT_ROLE=""
_DISPATCH_ERROR=""
case "$AGENT_TYPE" in
    planner|Plan)  NEXT_ROLE="implementer" ;;
    implementer)   NEXT_ROLE="tester"      ;;
    tester)
        _TESTER_NEXT_ROLE=""

        if [[ -n "$_WF_ID" ]]; then
            # WS1: Use _ACTIVE_LEASE_ID resolved from lease_context() above.
            # lease_context() guarantees the lease ID matches the workflow_id
            # used by _WF_ID — no secondary rt_lease_current call needed.
            _TESTER_LEASE_ID="$_ACTIVE_LEASE_ID"

            if [[ -n "$_TESTER_LEASE_ID" ]]; then
                _TESTER_COMP=$(rt_completion_latest "$_TESTER_LEASE_ID")
                _TESTER_COMP_FOUND=$(printf '%s' "${_TESTER_COMP:-}" | jq -r '.found // "false"' 2>/dev/null || echo "false")
                _TESTER_COMP_VALID=$(printf '%s' "${_TESTER_COMP:-}" | jq -r '.valid // 0' 2>/dev/null || echo "0")

                if [[ "$_TESTER_COMP_FOUND" == "true" ]]; then
                    if [[ "$_TESTER_COMP_VALID" != "1" && "$_TESTER_COMP_VALID" != "true" ]]; then
                        # Completion record exists but is invalid — hard process error.
                        rt_event_emit "post_task_error" "tester completion record invalid for workflow $_WF_ID" || true
                        _DISPATCH_ERROR="PROCESS ERROR: Tester completion record invalid for workflow $_WF_ID lease $_TESTER_LEASE_ID. Contract not fulfilled."
                    else
                        # Valid completion — route via determine_next_role() (DEC-COMPLETION-001).
                        _TESTER_VERDICT=$(printf '%s' "$_TESTER_COMP" | jq -r '.verdict // empty' 2>/dev/null || true)
                        _ROUTE_RESULT=$(rt_completion_route "tester" "$_TESTER_VERDICT")
                        _TESTER_NEXT_ROLE=$(printf '%s' "$_ROUTE_RESULT" | jq -r '.next_role // empty' 2>/dev/null || true)
                    fi
                else
                    # Lease exists but no completion record — contract not fulfilled.
                    rt_event_emit "completion_missing" "tester lease $_TESTER_LEASE_ID has no completion record for workflow $_WF_ID" || true
                    _DISPATCH_ERROR="PROCESS ERROR: Tester completed with active lease $_TESTER_LEASE_ID but no completion record. Contract not fulfilled."
                fi

                # Release lease AFTER routing is determined (DEC-ROUTING-002).
                rt_lease_release "$_TESTER_LEASE_ID" || true
            else
                # No active lease — tester must run under a lease (no fallback).
                _DISPATCH_ERROR="PROCESS ERROR: Tester completed without an active lease for workflow $_WF_ID. Cannot route."
            fi
        fi

        NEXT_ROLE="$_TESTER_NEXT_ROLE"
        ;;
    guardian)
        _GUARDIAN_NEXT_ROLE=""

        if [[ -n "$_WF_ID" ]]; then
            # WS1: Use _ACTIVE_LEASE_ID resolved from lease_context() above.
            _GUARDIAN_LEASE_ID="$_ACTIVE_LEASE_ID"

            if [[ -n "$_GUARDIAN_LEASE_ID" ]]; then
                _GUARDIAN_COMP=$(rt_completion_latest "$_GUARDIAN_LEASE_ID")
                _GUARDIAN_COMP_FOUND=$(printf '%s' "${_GUARDIAN_COMP:-}" | jq -r '.found // "false"' 2>/dev/null || echo "false")
                _GUARDIAN_COMP_VALID=$(printf '%s' "${_GUARDIAN_COMP:-}" | jq -r '.valid // 0' 2>/dev/null || echo "0")

                if [[ "$_GUARDIAN_COMP_FOUND" == "true" ]]; then
                    if [[ "$_GUARDIAN_COMP_VALID" != "1" && "$_GUARDIAN_COMP_VALID" != "true" ]]; then
                        # Completion record invalid — hard process error.
                        rt_event_emit "post_task_error" "guardian completion record invalid for workflow $_WF_ID" || true
                        _DISPATCH_ERROR="PROCESS ERROR: Guardian completion record invalid for workflow $_WF_ID lease $_GUARDIAN_LEASE_ID. Contract not fulfilled."
                    else
                        # Valid completion — route via determine_next_role() (DEC-COMPLETION-001).
                        # Returns empty string for cycle-complete verdicts (committed/merged).
                        _GUARDIAN_VERDICT=$(printf '%s' "$_GUARDIAN_COMP" | jq -r '.verdict // empty' 2>/dev/null || true)
                        _GUARDIAN_ROUTE=$(rt_completion_route "guardian" "$_GUARDIAN_VERDICT")
                        _GUARDIAN_NEXT_ROLE=$(printf '%s' "$_GUARDIAN_ROUTE" | jq -r '.next_role // empty' 2>/dev/null || true)
                    fi
                else
                    # Lease exists but no completion record — contract not fulfilled.
                    rt_event_emit "completion_missing" "guardian lease $_GUARDIAN_LEASE_ID has no completion record for workflow $_WF_ID" || true
                    _DISPATCH_ERROR="PROCESS ERROR: Guardian completed with active lease $_GUARDIAN_LEASE_ID but no completion record. Contract not fulfilled."
                fi

                # Release lease AFTER routing is determined.
                rt_lease_release "$_GUARDIAN_LEASE_ID" || true
            else
                # No active lease — guardian must run under a lease (no fallback).
                _DISPATCH_ERROR="PROCESS ERROR: Guardian completed without an active lease for workflow $_WF_ID. Cannot route."
            fi
        fi

        NEXT_ROLE="${_GUARDIAN_NEXT_ROLE:-}"  # empty = dispatch cycle complete
        ;;
    *)  exit 0 ;;  # unknown type — stay silent
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
    # @decision DEC-WS6-001
    # dispatch_queue enqueue removed — routing is communicated via
    # hookSpecificOutput suggestion. Lease/completion state is the sole
    # routing authority. Queue was a write-only sink with no live readers
    # in the enforcement path.

    # Include workflow_id in dispatch context so the orchestrator can pass it
    # to the next agent without re-deriving from CWD (DEC-WF-001).
    SUGGESTION="Canonical flow suggests dispatching: $NEXT_ROLE"
    [[ -n "$_WF_ID" ]] && SUGGESTION="$SUGGESTION (workflow_id=$_WF_ID)"
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
    # Terminal state (guardian cycle complete or no workflow) — record completion
    # and stay silent so the orchestrator is not given a phantom next step.
    rt_event_emit "cycle_complete" "Guardian completed — dispatch cycle done" || true
fi

exit 0
