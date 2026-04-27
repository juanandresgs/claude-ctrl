#!/usr/bin/env bash
set -euo pipefail

# Subagent context injection at spawn time.
# SubagentStart hook — matcher: (all agent types)
#
# Injects current project state into every subagent so Planner,
# Implementer, Guardian, and Reviewer agents always have fresh context:
#   - Current git branch and dirty state
#   - MASTER_PLAN.md existence and active phase
#   - Active worktrees
#   - Agent-type-specific guidance
#   - Tracks subagent spawn in runtime marker store (rt_marker_set)

# shellcheck source=hooks/log.sh
source "$(dirname "$0")/log.sh"
# shellcheck source=hooks/context-lib.sh
source "$(dirname "$0")/context-lib.sh"

HOOK_INPUT=$(read_input)
AGENT_TYPE=$(echo "$HOOK_INPUT" | jq -r '.agent_type // empty' 2>/dev/null)
SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
# DEC-CLAUDEX-SA-IDENTITY-001: payload agent_id is the sole authority for marker+lease seating.
# Shell PID (agent-$$) is per-process and unreachable from downstream cc-policy context role
# resolvers. Extract once here; all seating calls below use this variable exclusively.
_PAYLOAD_AGENT_ID=$(echo "$HOOK_INPUT" | jq -r '.agent_id // empty' 2>/dev/null || echo "")

PROJECT_ROOT=$(detect_project_root)
CONTEXT_PARTS=()

# --- Git + Plan state (one line) ---
get_git_state "$PROJECT_ROOT"
get_plan_status "$PROJECT_ROOT"

# ---------------------------------------------------------------------------
# Local runtime resolution — see post-task.sh DEC-BRIDGE-002 for rationale.
# Must resolve here too so agent-start reaches the in-worktree CLI.
# ---------------------------------------------------------------------------
_HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
_LOCAL_RUNTIME_ROOT="$_HOOK_DIR/../runtime"
_local_cc_policy() {
    # @decision DEC-CLAUDEX-SA-MARKER-RELIABILITY-001
    # Title: SubagentStart marker-seating is authoritative and failures are observable
    # Status: accepted — DB routing now delegates to _resolve_policy_db (shared helper).
    # Rationale: CLAUDE_POLICY_DB must be deterministically routed to the
    #   in-project state.db regardless of whether CLAUDE_PROJECT_DIR is present
    #   in the SubagentStart env invocation. The 3-tier fallback logic (CLAUDE_POLICY_DB
    #   → CLAUDE_PROJECT_DIR → git rev-parse) now lives exclusively in _resolve_policy_db
    #   (DEC-CLAUDEX-SA-UNIFIED-DB-ROUTING-001) so both the carrier consume block and
    #   the marker-seating CLI call share the same authoritative path resolution.
    #   Any seating failure is captured and emitted as a CONTEXT_PARTS breadcrumb.
    #   Extends DEC-CLAUDEX-SA-IDENTITY-001.
    # Chain: _resolve_policy_db → CLAUDE_POLICY_DB → cc-policy dispatch agent-start
    #   → agent_markers → context role
    if [[ -z "${CLAUDE_POLICY_DB:-}" ]]; then
        _resolve_policy_db >/dev/null
    fi
    cc_policy_local_runtime "$_LOCAL_RUNTIME_ROOT" "$@"
}

_authority_python() {
    local mode="$1"
    local value="$2"
    "$(_resolve_runtime_python)" - "$_HOOK_DIR/.." "$mode" "$value" <<'PY'
import sys
repo_root, mode, value = sys.argv[1:4]
sys.path.insert(0, repo_root)
from runtime.core import authority_registry as ar
from runtime.core import stage_packet as sp

if mode == "dispatch_subagent_type_for_stage":
    result = ar.dispatch_subagent_type_for_stage(value)
elif mode == "canonical_dispatch_subagent_type":
    result = ar.canonical_dispatch_subagent_type(value)
elif mode == "canonical_stage_id":
    result = ar.canonical_stage_id(value)
elif mode == "dispatch_bootstrap_guidance":
    result = sp.dispatch_bootstrap_guidance(value or None)
else:
    raise SystemExit(2)

print("" if result is None else result)
PY
}

_emit_context_only() {
    local message="$1"
    local escaped
    escaped=$(printf '%s' "$message" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SubagentStart",
    "additionalContext": $escaped
  }
}
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Carrier consume: augment HOOK_INPUT with contract fields written by
# pre-agent.sh (PreToolUse:Agent) into pending_agent_requests
# (DEC-CLAUDEX-SA-CARRIER-001).
#
# Atomically reads and deletes the row keyed by (session_id, agent_type).
# When the row exists, the six contract fields are merged into HOOK_INPUT
# so the _HAS_CONTRACT check below sees them as payload-native fields and
# the runtime-first path fires in production — not just in tests.
# ---------------------------------------------------------------------------
if [[ -n "$SESSION_ID" && -n "$AGENT_TYPE" ]]; then
    _CARRIER_MODULE="$_HOOK_DIR/../runtime/core/pending_agent_requests.py"
    # Use shared 3-tier resolver — replaces former 2-tier (CLAUDE_POLICY_DB →
    # CLAUDE_PROJECT_DIR) that silently skipped the consume when both were absent.
    # (DEC-CLAUDEX-SA-UNIFIED-DB-ROUTING-001)
    _CARRIER_DB="$(_resolve_policy_db)"
    if [[ -n "$_CARRIER_DB" && -f "$_CARRIER_MODULE" ]]; then
        _CARRIER_AGENT_TYPE=$(_authority_python "canonical_dispatch_subagent_type" "${AGENT_TYPE:-}" 2>/dev/null || echo "")
        [[ -z "$_CARRIER_AGENT_TYPE" ]] && _CARRIER_AGENT_TYPE="$AGENT_TYPE"
        _CARRIER_JSON=$("$(_resolve_runtime_python)" "$_CARRIER_MODULE" consume "$_CARRIER_DB" "$SESSION_ID" "$_CARRIER_AGENT_TYPE" 2>/dev/null || echo "")
        if [[ -n "$_CARRIER_JSON" ]]; then
            HOOK_INPUT=$(echo "$HOOK_INPUT" | jq --argjson c "$_CARRIER_JSON" '. + $c')
            # Claim delivery only when the carrier-backed correlation path matched
            # (DEC-CLAUDEX-HOOK-WIRING-001). A bare SubagentStart with no carrier
            # row must NOT claim a pending attempt — there is no PreToolUse proof.
            # Best-effort: never blocks subagent start.
            _local_cc_policy dispatch attempt-claim \
                --session-id "$SESSION_ID" \
                --agent-type "$_CARRIER_AGENT_TYPE" \
                >/dev/null 2>&1 || true
        fi
    fi
fi

_HAS_CONTRACT=$(echo "$HOOK_INPUT" | jq -r '
  if (has("workflow_id") and has("stage_id") and has("goal_id") and
      has("work_item_id") and has("decision_scope") and has("generated_at"))
  then "yes" else "no" end
' 2>/dev/null || echo "no")

_CANONICAL_SUBAGENT_TYPE=$(_authority_python "canonical_dispatch_subagent_type" "${AGENT_TYPE:-}" 2>/dev/null || echo "")
_EFFECTIVE_STAGE_ID=""
_EFFECTIVE_LEASE_ROLE="$AGENT_TYPE"
_MARKER_ROLE="$AGENT_TYPE"

if [[ "$_HAS_CONTRACT" == "yes" ]]; then
    _EFFECTIVE_STAGE_ID=$(echo "$HOOK_INPUT" | jq -r '.stage_id // empty' 2>/dev/null || echo "")
    _EXPECTED_SUBAGENT_TYPE=$(_authority_python "dispatch_subagent_type_for_stage" "$_EFFECTIVE_STAGE_ID" 2>/dev/null || echo "")
    if [[ -n "$_EXPECTED_SUBAGENT_TYPE" && "$AGENT_TYPE" != "$_EXPECTED_SUBAGENT_TYPE" ]]; then
        _emit_context_only "Runtime dispatch contract rejected: stage '${_EFFECTIVE_STAGE_ID}' requires subagent_type '${_EXPECTED_SUBAGENT_TYPE}', but the harness started '${AGENT_TYPE}'. This launch bypasses the repo-owned stage prompt and is not trusted."
    fi
    if [[ -n "$_EXPECTED_SUBAGENT_TYPE" ]]; then
        _EFFECTIVE_LEASE_ROLE="$_EXPECTED_SUBAGENT_TYPE"
        _MARKER_ROLE="$_EFFECTIVE_STAGE_ID"
    fi
elif [[ -n "$_CANONICAL_SUBAGENT_TYPE" ]]; then
    # A8: canonical seat without a carrier-backed contract is a bypass attempt.
    # If the subagent_type resolves to a canonical dispatch seat but the six-field
    # contract is NOT present (carrier row was missing, or the row had missing/empty
    # required fields so _HAS_CONTRACT is "no"), deny fail-closed via additionalContext
    # with reason canonical_seat_no_carrier_contract.  Do NOT fall through to the
    # shell guidance path — that would silently misguide a forged/stripped launch.
    # (DEC-CLAUDEX-AGENT-CONTRACT-AUTHENTICITY-A8-001)
    _BOOTSTRAP_GUIDANCE=$(_authority_python "dispatch_bootstrap_guidance" "$AGENT_TYPE" 2>/dev/null || echo "")
    _emit_context_only "BLOCKED: canonical dispatch seat '${AGENT_TYPE}' reached SubagentStart without a carrier-backed contract (canonical_seat_no_carrier_contract). pre-agent.sh must write a pending_agent_requests row before the harness starts this seat. Either the orchestrator bypassed pre-agent.sh, or the carrier write failed. ${_BOOTSTRAP_GUIDANCE}"
fi

# Track subagent spawn via lifecycle authority (DEC-LIFECYCLE-002).
# Calls dispatch agent-start (lifecycle.py) via local CLI resolution so
# this reaches the in-worktree runtime in isolated worktrees before merge.
# rt_marker_set direct call removed — lifecycle.py is the sole authority.
#
# @decision DEC-CLAUDEX-SA-IDENTITY-001
# Title: Payload agent_id is sole authority for SubagentStart marker+lease seating
# Status: accepted
# Rationale: The harness delivers the subagent's canonical agent_id in the
#   SubagentStart payload (HOOK_INPUT.agent_id). Shell PID (agent-$$) is
#   per-process and unstable across SubagentStart/SubagentStop boundaries;
#   it is unreachable from any downstream cc-policy context role resolver.
#   Single source of truth: HOOK_INPUT.agent_id → agent_markers.agent_id →
#   dispatch_leases.agent_id. Empty payload agent_id = fail-closed with
#   no_payload_agent_id (seating skipped, lease claim skipped, exit 0 clean).
#   Hard sweep of stale markers deferred to GS1-F-3 per planner risk #3
#   (CLI surface marker deactivate-stale does not exist); this slice adds
#   observatory-only diagnostic breadcrumbs in CONTEXT_PARTS when a stale
#   active marker of a different role is detected before seating.
#
# W-CONV-2 (DEC-CONV-002): Only dispatch-significant roles write markers.
# Explore, Bash, and general-purpose agents are lightweight coordinators
# that have no SubagentStop check-*.sh hook to deactivate their marker, so
# any marker they write accumulates indefinitely as a ghost marker and
# contaminates actor-role inference in build_context(). The filter below
# prevents that by skipping agent-start entirely for non-dispatch roles.
# The schemas.py cleanup migration handles markers that already accumulated.
_IS_DISPATCH_ROLE=false
case "${_MARKER_ROLE:-}" in
    planner|implementer|guardian|guardian:provision|guardian:land|reviewer)
        _IS_DISPATCH_ROLE=true
        ;;
esac

if [[ "$_IS_DISPATCH_ROLE" == "true" ]]; then
    # DEC-CLAUDEX-SA-IDENTITY-001: fail-closed when payload agent_id is absent.
    # Without a payload agent_id, marker+lease seating cannot be correlated to
    # the harness-delivered identity. Skip seating and append a diagnostic note
    # to CONTEXT_PARTS so orchestrators can detect the gap. The hook continues
    # to the runtime-first path so contract-present dispatches still receive
    # their prompt-pack even if the harness doesn't deliver agent_id yet.
    if [[ -z "$_PAYLOAD_AGENT_ID" ]]; then
        CONTEXT_PARTS+=("SubagentStart seating skipped (no_payload_agent_id): HOOK_INPUT.agent_id was empty or absent. Marker and lease will not be claimed for role '${_MARKER_ROLE:-unknown}'. Ensure the harness is delivering agent_id in the SubagentStart payload.")
    else
        # Observatory-only stale-marker breadcrumb (DEC-CLAUDEX-SA-IDENTITY-001).
        # If an active marker of a DIFFERENT role exists for this project_root,
        # append a warning. Hard deactivation is deferred to GS1-F-3.
        _STALE_MARKER_JSON=$(_local_cc_policy marker get-active \
            --project-root "$PROJECT_ROOT" 2>/dev/null || echo "")
        _STALE_FOUND=$(printf '%s' "${_STALE_MARKER_JSON:-}" | jq -r '.found // false' 2>/dev/null || echo "false")
        if [[ "$_STALE_FOUND" == "true" ]]; then
            _STALE_ROLE=$(printf '%s' "$_STALE_MARKER_JSON" | jq -r '.active_agent.role // empty' 2>/dev/null || true)
            _STALE_AID=$(printf '%s' "$_STALE_MARKER_JSON" | jq -r '.active_agent.agent_id // empty' 2>/dev/null || true)
            if [[ -n "$_STALE_ROLE" && "$_STALE_ROLE" != "${_MARKER_ROLE:-}" ]]; then
                CONTEXT_PARTS+=("stale active marker: role=${_STALE_ROLE} agent_id=${_STALE_AID} will be superseded by role=${_MARKER_ROLE:-unknown} agent_id=${_PAYLOAD_AGENT_ID}")
            fi
        fi

        # Pass project_root and workflow_id for per-project scoping (W-CONV-2).
        # workflow_id is derived from the current branch via current_workflow_id()
        # so the marker is queryable via get_active(project_root=X, workflow_id=W).
        _WF_ID_FOR_MARKER=$(current_workflow_id "$PROJECT_ROOT" 2>/dev/null || true)
        # Capture stderr to detect CLI failures; on nonzero exit emit a single-line
        # diagnostic breadcrumb into CONTEXT_PARTS (DEC-CLAUDEX-SA-MARKER-RELIABILITY-001).
        # The hook always exits 0 — seating failure is observable but never blocking.
        _MARKER_STDERR_FILE=$(mktemp)
        _local_cc_policy dispatch agent-start \
            "${_MARKER_ROLE:-unknown}" "$_PAYLOAD_AGENT_ID" \
            --project-root "$PROJECT_ROOT" \
            ${_WF_ID_FOR_MARKER:+--workflow-id "$_WF_ID_FOR_MARKER"} \
            >/dev/null 2>"$_MARKER_STDERR_FILE" && _MARKER_RC=0 || _MARKER_RC=$?
        if [[ "$_MARKER_RC" -ne 0 ]]; then
            _MARKER_STDERR_FIRST=$(head -1 "$_MARKER_STDERR_FILE" 2>/dev/null || echo "")
            _AGENT_ID_SHORT="${_PAYLOAD_AGENT_ID:0:12}"
            CONTEXT_PARTS+=("marker seating failed (role=${_MARKER_ROLE:-unknown} agent_id=${_AGENT_ID_SHORT} exit=${_MARKER_RC}): ${_MARKER_STDERR_FIRST:-no stderr}")
            log_json "marker_seating_failed" "role=${_MARKER_ROLE:-unknown} agent_id=${_PAYLOAD_AGENT_ID} exit=${_MARKER_RC} stderr=${_MARKER_STDERR_FIRST:-}" || true
        fi
        rm -f "$_MARKER_STDERR_FILE"
    fi
fi

# --- Lease claim: bind this agent to an active dispatch lease if one exists ---
# Phase 2 (DEC-LEASE-002): At spawn time, attempt to claim any active lease
# for this worktree. If found, inject the lease context so the agent knows
# its role, allowed ops, and next step without re-inferring from environment.
# If no lease exists, inject a warning — high-risk git ops will be denied by
# guard.sh Check 3 (validate_op fallback path) when no lease is active.
# DEC-CLAUDEX-SA-IDENTITY-001: use payload agent_id (not PID) for correlation.
# When agent_id is absent (no_payload_agent_id guard fired), skip lease claim
# so dispatch_leases.agent_id is never set to an empty or PID-shaped string.
if [[ "$_IS_DISPATCH_ROLE" == "true" ]]; then
    if [[ -n "$_PAYLOAD_AGENT_ID" ]]; then
        _CLAIM=$(rt_lease_claim "$_PAYLOAD_AGENT_ID" "$PROJECT_ROOT" "$_EFFECTIVE_LEASE_ROLE")
    else
        _CLAIM='{"found":false}'
    fi
    _LEASE_ID=$(printf '%s' "${_CLAIM:-}" | jq -r '.lease.lease_id // .lease_id // empty' 2>/dev/null || true)
    if [[ -n "$_LEASE_ID" ]]; then
        _L_ROLE=$(printf '%s' "$_CLAIM" | jq -r '.lease.role // .role // empty' 2>/dev/null || true)
        _L_OPS=$(printf '%s' "$_CLAIM" | jq -r '.lease.allowed_ops_json // .allowed_ops_json // empty' 2>/dev/null || true)
        _L_NS=$(printf '%s' "$_CLAIM" | jq -r '.lease.next_step // .next_step // empty' 2>/dev/null || true)
        CONTEXT_PARTS+=("Lease: id=$_LEASE_ID role=$_L_ROLE ops=$_L_OPS${_L_NS:+ next=$_L_NS}")
    else
        CONTEXT_PARTS+=("WARNING: No active lease for worktree $PROJECT_ROOT. High-risk git ops will be denied.")
    fi
else
    _CLAIM='{"found":false}'
    _LEASE_ID=""
fi

# ---------------------------------------------------------------------------
# Runtime-first path: SubagentStart prompt-pack envelope delivery
# (DEC-CLAUDEX-PROMPT-PACK-SUBAGENT-START-001)
#
# When the incoming payload carries the full six-field request contract,
# delegate entirely to the runtime compiler. This hook is a thin transport
# adapter only — all validation and prompt-pack assembly live in
# runtime.core.prompt_pack (build_subagent_start_prompt_pack_response).
#
# If the runtime returns an invalid report, surface it clearly as an error
# additionalContext. Do NOT fall back to shell-built role guidance:
# the contract was present, so the caller expected runtime-produced output
# and shell role guidance would silently inject unrelated instructions.
# ---------------------------------------------------------------------------
if [[ "$_HAS_CONTRACT" == "yes" ]]; then
    _PP_PAYLOAD=$(echo "$HOOK_INPUT" | jq -c \
        '{workflow_id, stage_id, goal_id, work_item_id, decision_scope, generated_at}')
    _RT_STDERR_FILE=$(mktemp)
    _RT_STDOUT=$(_local_cc_policy prompt-pack subagent-start \
        --payload "$_PP_PAYLOAD" 2>"$_RT_STDERR_FILE") && _RT_RC=0 || _RT_RC=$?
    _RT_STDERR=$(cat "$_RT_STDERR_FILE"); rm -f "$_RT_STDERR_FILE"

    _RT_HEALTHY=$(echo "$_RT_STDOUT" | jq -r '.healthy // "false"' 2>/dev/null || echo "false")

    if [[ "$_RT_HEALTHY" == "true" ]]; then
        # Success: print the runtime-produced envelope verbatim and exit.
        echo "$_RT_STDOUT" | jq '.envelope'
        exit 0
    else
        # Invalid or error: do NOT fall back to shell role guidance.
        # Emit a clear error in additionalContext so the agent can see what failed.
        _ERR_VIOLATIONS=$(echo "$_RT_STDOUT" | jq -r '
          if (.violations | length) > 0 then
            "Violations: " + (.violations | join("; "))
          else "" end
        ' 2>/dev/null || echo "")
        _ERR_BACKEND=$(echo "$_RT_STDERR" | jq -r '.message // empty' 2>/dev/null || echo "")
        _ERR_PARTS=("Runtime prompt-pack compile failed for this SubagentStart.")
        [[ -n "$_ERR_VIOLATIONS" ]] && _ERR_PARTS+=("$_ERR_VIOLATIONS")
        [[ -n "$_ERR_BACKEND" ]] && _ERR_PARTS+=("Backend error: $_ERR_BACKEND")
        _ERR_CTX=$(printf '%s\n' "${_ERR_PARTS[@]}" | jq -Rs .)
        cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SubagentStart",
    "additionalContext": $_ERR_CTX
  }
}
EOF
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# Lightweight non-canonical context path.
#
# Canonical dispatch seats never reach this path:
#   - contract-bearing seats exit through the runtime prompt-pack path above
#   - canonical seats without a carrier-backed contract are blocked before
#     marker/lease seating
#
# This remaining path is deliberately sparse and non-authoritative. It exists
# only for helper/non-canonical agents that do not participate in the governed
# planner -> guardian -> implementer -> reviewer -> guardian chain.
# ---------------------------------------------------------------------------

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

case "$AGENT_TYPE" in
    ""|Bash|Explore|general-purpose|statusline-setup)
        # Lightweight agents — Context line only.
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
