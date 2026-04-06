#!/usr/bin/env bash
# post-task.sh — Thin dispatch adapter after agent completion.
# SubagentStop hook — fires when a named agent task ends.
#
# Delegates all routing logic to Python via cc-policy dispatch process-stop.
# This script is intentionally minimal: read agent_type from hook input,
# forward to the runtime, echo the hookSpecificOutput result.
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
#
# @decision DEC-DISPATCH-ENGINE-001
# @title dispatch_engine.process_agent_stop is the authoritative dispatch state machine
# @status accepted
# @rationale All routing logic (lease resolution, completion-record lookup,
#   eval_state mutation, routing table) has been ported from this file into
#   runtime/core/dispatch_engine.py, which is called via cc-policy dispatch
#   process-stop. This adapter is the only bash remaining in the dispatch path.
#   It is fail-closed: if the runtime is unavailable or returns malformed output,
#   it emits a hookSpecificOutput error so the orchestrator sees the failure
#   rather than silently continuing. dispatch-helpers.sh has been deleted
#   (DEC-WS6-001 — no callers remain after this cutover).
set -euo pipefail

# shellcheck source=hooks/log.sh
source "$(dirname "$0")/log.sh"
# shellcheck source=hooks/context-lib.sh
source "$(dirname "$0")/context-lib.sh"

# ---------------------------------------------------------------------------
# Local runtime resolution (DEC-BRIDGE-002)
#
# cc_policy() in runtime-bridge.sh resolves the CLI via CLAUDE_RUNTIME_ROOT,
# which defaults to $HOME/.claude/runtime — the installed runtime, not this
# worktree's runtime. New subcommands (dispatch process-stop, dispatch
# agent-start, dispatch agent-stop) added in a feature branch are only
# present in the worktree's runtime/cli.py, not in the installed copy.
#
# This local helper resolves the CLI relative to the hook file itself
# (hooks/../runtime/cli.py) so it always reaches the in-worktree runtime,
# both in isolated worktrees before merge and on main after merge.
#
# The existing cc_policy() function in runtime-bridge.sh is NOT modified —
# it is used by many hooks for existing subcommands and works correctly for
# those. Only calls to NEW subcommands use this local resolution.
# ---------------------------------------------------------------------------

_HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
_LOCAL_RUNTIME_CLI="$_HOOK_DIR/../runtime/cli.py"

_local_cc_policy() {
    if [[ -n "${CLAUDE_PROJECT_DIR:-}" && -z "${CLAUDE_POLICY_DB:-}" ]]; then
        export CLAUDE_POLICY_DB="$CLAUDE_PROJECT_DIR/.claude/state.db"
    fi
    python3 "$_LOCAL_RUNTIME_CLI" "$@"
}

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
# Resolve project root for the runtime (used for lease context lookup)
# ---------------------------------------------------------------------------

PROJECT_ROOT=$(detect_project_root 2>/dev/null || echo "")

# ---------------------------------------------------------------------------
# Delegate to Python runtime via dispatch process-stop (local CLI resolution)
# ---------------------------------------------------------------------------

DISPATCH_INPUT=$(jq -n \
    --arg type "$AGENT_TYPE" \
    --arg root "${PROJECT_ROOT:-}" \
    '{agent_type: $type, project_root: $root}')

RESULT=$(printf '%s' "$DISPATCH_INPUT" | _local_cc_policy dispatch process-stop 2>/dev/null) || RESULT=""

# Fail-closed: if runtime unavailable or output malformed, surface error.
if [[ -z "$RESULT" ]] || ! printf '%s' "$RESULT" | jq -e '.hookSpecificOutput' >/dev/null 2>&1; then
    ESCAPED=$(printf 'PROCESS ERROR: dispatch process-stop unavailable or returned malformed output for agent_type=%s' "$AGENT_TYPE" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SubagentStop",
    "additionalContext": $ESCAPED
  }
}
EOF
    exit 0
fi

# Echo the hookSpecificOutput wrapper produced by the runtime.
printf '%s' "$RESULT" | jq '{hookSpecificOutput: .hookSpecificOutput}'

# Observatory: emit review_verdict metric from the most recent codex_stop_review event (W-OBS-2).
# Queries the event store for the latest codex_stop_review event and parses VERDICT from its
# detail string (format: "VERDICT: ALLOW — ..." or "VERDICT: BLOCK — ...").
# Non-fatal: || true ensures metric emission never prevents the hook from exiting cleanly.
_review_raw=$(_local_cc_policy event query --type codex_stop_review --limit 1 2>/dev/null || echo "")
_review_event=$(printf '%s' "$_review_raw" \
    | jq -r '.items[0].detail // "" ' 2>/dev/null || echo "")
_review_created=$(printf '%s' "$_review_raw" \
    | jq -r '.items[0].created_at // "" ' 2>/dev/null || echo "")
if [[ -n "$_review_event" ]]; then
    _review_verdict=$(printf '%s' "$_review_event" \
        | grep -oE 'VERDICT: (ALLOW|BLOCK)' | head -1 | awk '{print $2}' || echo "")
    if [[ -n "$_review_verdict" ]]; then
        _review_value=0
        [[ "$_review_verdict" == "ALLOW" ]] && _review_value=1
        rt_obs_metric review_verdict "$_review_value" \
            "{\"provider\":\"codex\",\"verdict\":\"${_review_verdict}\"}" \
            "" "${AGENT_TYPE:-}" || true
        # EC-11: emit review_duration_s from event created_at to now
        if [[ -n "$_review_created" && "$_review_created" =~ ^[0-9]+$ ]]; then
            _review_duration=$(( $(date +%s) - _review_created ))
            rt_obs_metric review_duration_s "$_review_duration" \
                "{\"provider\":\"codex\"}" "" "${AGENT_TYPE:-}" || true
        fi
    fi
    # EC-12: emit review_infra_failure when event detail contains "infra failure"
    if printf '%s' "$_review_event" | grep -qi "infra.failure\|infra_failure\|INFRA_FAILURE"; then
        rt_obs_metric review_infra_failure 1 \
            "{\"provider\":\"codex\",\"error_type\":\"infra_failure\"}" \
            "" "${AGENT_TYPE:-}" || true
    fi
fi

exit 0
