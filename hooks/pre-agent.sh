#!/usr/bin/env bash
# pre-agent.sh — Agent tool PreToolUse guard.
#
# Denies Agent tool invocations that request harness-managed worktree
# isolation (`isolation: "worktree"`). Guardian is the sole worktree
# lifecycle authority; harness-created worktrees in /tmp bypass:
#   - Guardian lease at PROJECT_ROOT
#   - Implementer lease at worktree_path
#   - Workflow binding
#   - Scope manifest
# Allowing them silently produces dispatch chains where the implementer
# subagent runs with no lease, no scope, and no policy enforcement.
#
# @decision DEC-PREAGENT-001
# @title pre-agent.sh blocks Agent(isolation:"worktree") (ENFORCE-RCA-8 / #29)
# @status accepted
# @rationale bash_worktree_creation (priority 350) catches `git worktree add`
#   from the Bash tool, but does NOT fire for harness-managed worktree creation
#   via the Agent tool's `isolation` parameter. The harness creates the
#   worktree in /tmp outside pre-bash.sh's reach. Debug capture on 2026-04-07
#   confirmed the Agent tool's matcher name is `Agent` and that
#   `tool_input.isolation` (when set) is exposed to PreToolUse hooks. This
#   hook denies at that boundary so the only sanctioned worktree creation
#   path remains `cc-policy worktree provision` executed by Guardian.
#
# Fails closed on malformed input: if jq cannot parse the hook input, deny.

set -euo pipefail

source "$(dirname "$0")/log.sh"
# Source runtime-bridge.sh for _resolve_policy_db (DEC-CLAUDEX-SA-UNIFIED-DB-ROUTING-001).
# context-lib.sh is not sourced here (forbidden per scope manifest for pre-agent.sh);
# runtime-bridge.sh is the self-contained authority for the DB resolver.
_HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$_HOOK_DIR/lib/runtime-bridge.sh"

_deny() {
    local reason="$1"
    local escaped
    escaped=$(printf '%s' "$reason" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "blockingHook": "pre-agent.sh",
    "permissionDecisionReason": $escaped
  }
}
EOF
    exit 0
}

_python_authority() {
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
elif mode == "dispatch_bootstrap_guidance":
    result = sp.dispatch_bootstrap_guidance(value or None)
else:
    raise SystemExit(2)

print("" if result is None else result)
PY
}

# Read hook input from stdin
HOOK_INPUT=$(cat 2>/dev/null || echo "")

# If input is empty or not JSON, fail closed
if [[ -z "$HOOK_INPUT" ]] || ! printf '%s' "$HOOK_INPUT" | jq -e . >/dev/null 2>&1; then
    _deny "BLOCKED: pre-agent.sh received malformed input. Fail-closed guard."
fi

# Extract tool_name and tool_input.isolation
TOOL_NAME=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
ISOLATION=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.isolation // empty' 2>/dev/null || echo "")

# Only guard the Agent/Task tool; other tools pass through unchanged.
# Empirical capture on 2026-04-07 confirmed `Agent` is the tool_name in this
# Claude Code version (~/.claude/runtime/dispatch-debug.jsonl). `Task` is
# accepted defensively in case the harness ever renames or earlier/later
# versions emit a different name — costs nothing and prevents silent no-op.
if [[ "$TOOL_NAME" != "Agent" && "$TOOL_NAME" != "Task" ]]; then
    exit 0
fi

# Allow Agent calls without isolation=worktree (the common case).
# Before exiting, attempt to extract a CLAUDEX_CONTRACT_BLOCK from the prompt
# and write it to pending_agent_requests so subagent-start.sh can consume it
# at SubagentStart time (DEC-CLAUDEX-SA-CARRIER-001).
if [[ "$ISOLATION" != "worktree" ]]; then
    _PROMPT_TEXT=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.prompt // empty' 2>/dev/null || echo "")
    _SESSION_ID=$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
    _SUBAGENT_TYPE=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null || echo "")
    _BLOCK_LINE=$(printf '%s' "$_PROMPT_TEXT" | grep '^CLAUDEX_CONTRACT_BLOCK:' 2>/dev/null | head -1 || echo "")
    _CANONICAL_DISPATCH_TYPE=""
    _BOOTSTRAP_GUIDANCE=$(_python_authority "dispatch_bootstrap_guidance" "" 2>/dev/null || echo "")
    if [[ -n "$_SUBAGENT_TYPE" ]]; then
        _CANONICAL_DISPATCH_TYPE=$(_python_authority "canonical_dispatch_subagent_type" "$_SUBAGENT_TYPE" 2>/dev/null || echo "")
    fi
    if [[ -z "$_BLOCK_LINE" ]]; then
        # Objective runtime-owned check: dispatch-significant subagent_types
        # are named by canonical_dispatch_subagent_type() in the runtime
        # authority surface. When the subagent_type resolves to a canonical
        # dispatch role but the contract block is absent, deny — this is
        # a runtime-owned classification, not shell-side intent inference.
        if [[ -n "$_CANONICAL_DISPATCH_TYPE" ]]; then
            _deny "BLOCKED: dispatch-significant subagent '${_SUBAGENT_TYPE}' launched without CLAUDEX_CONTRACT_BLOCK. ${_BOOTSTRAP_GUIDANCE}"
        fi
        # No runtime-declared dispatch-significance and no contract block:
        # let the Agent call proceed as an orchestrator/general-purpose
        # invocation. Shell-side keyword-intent classification was retired
        # per DEC-HOOK-ADAPTER-HARDENING (hooks are adapters, not policy
        # engines).
        exit 0
    fi

    _CONTRACT_JSON=$(printf '%s' "$_BLOCK_LINE" | sed 's/^CLAUDEX_CONTRACT_BLOCK://')
    if ! printf '%s' "$_CONTRACT_JSON" | jq -e . >/dev/null 2>&1; then
        _deny "BLOCKED: CLAUDEX_CONTRACT_BLOCK is not valid JSON (contract_block_malformed_json). Dispatch-significant subagents must carry a valid runtime-issued contract block."
    fi

    # A8: six-field shape validation before any stage/subagent_type checks.
    # Classification of canonical seats is resolved via _python_authority so
    # the shell hook remains a thin adapter (no local seat tables or arrays).
    # fail-closed on every missing or malformed field with a stable reason-code
    # substring (DEC-CLAUDEX-AGENT-CONTRACT-AUTHENTICITY-A8-001).
    _WF_ID_FIELD=$(printf '%s' "$_CONTRACT_JSON" | jq -r '.workflow_id // "__MISSING__"' 2>/dev/null || echo "__MISSING__")
    if [[ "$_WF_ID_FIELD" == "__MISSING__" ]]; then
        _deny "BLOCKED: CLAUDEX_CONTRACT_BLOCK is missing required field workflow_id (contract_block_missing_workflow_id). ${_BOOTSTRAP_GUIDANCE}"
    fi
    if [[ -z "${_WF_ID_FIELD// /}" ]]; then
        _deny "BLOCKED: CLAUDEX_CONTRACT_BLOCK has empty workflow_id (contract_block_empty_workflow_id). ${_BOOTSTRAP_GUIDANCE}"
    fi

    _STAGE_ID=$(printf '%s' "$_CONTRACT_JSON" | jq -r '.stage_id // empty' 2>/dev/null || echo "")
    if [[ -z "$_STAGE_ID" ]]; then
        _deny "BLOCKED: CLAUDEX_CONTRACT_BLOCK is missing stage_id (contract_block_missing_stage). ${_BOOTSTRAP_GUIDANCE}"
    fi
    _BOOTSTRAP_GUIDANCE=$(_python_authority "dispatch_bootstrap_guidance" "$_STAGE_ID" 2>/dev/null || echo "$_BOOTSTRAP_GUIDANCE")

    _GOAL_ID_FIELD=$(printf '%s' "$_CONTRACT_JSON" | jq -r '.goal_id // "__MISSING__"' 2>/dev/null || echo "__MISSING__")
    if [[ "$_GOAL_ID_FIELD" == "__MISSING__" ]] || [[ "$_GOAL_ID_FIELD" == "null" ]]; then
        _deny "BLOCKED: CLAUDEX_CONTRACT_BLOCK is missing required field goal_id (contract_block_missing_goal_id). ${_BOOTSTRAP_GUIDANCE}"
    fi
    if [[ -z "${_GOAL_ID_FIELD// /}" ]]; then
        _deny "BLOCKED: CLAUDEX_CONTRACT_BLOCK has empty goal_id (contract_block_missing_goal_id). ${_BOOTSTRAP_GUIDANCE}"
    fi

    _WI_ID_FIELD=$(printf '%s' "$_CONTRACT_JSON" | jq -r '.work_item_id // "__MISSING__"' 2>/dev/null || echo "__MISSING__")
    if [[ "$_WI_ID_FIELD" == "__MISSING__" ]] || [[ "$_WI_ID_FIELD" == "null" ]]; then
        _deny "BLOCKED: CLAUDEX_CONTRACT_BLOCK is missing required field work_item_id (contract_block_missing_work_item_id). ${_BOOTSTRAP_GUIDANCE}"
    fi
    if [[ -z "${_WI_ID_FIELD// /}" ]]; then
        _deny "BLOCKED: CLAUDEX_CONTRACT_BLOCK has empty work_item_id (contract_block_missing_work_item_id). ${_BOOTSTRAP_GUIDANCE}"
    fi

    _DS_FIELD=$(printf '%s' "$_CONTRACT_JSON" | jq -r '.decision_scope // "__MISSING__"' 2>/dev/null || echo "__MISSING__")
    if [[ "$_DS_FIELD" == "__MISSING__" ]] || [[ "$_DS_FIELD" == "null" ]]; then
        _deny "BLOCKED: CLAUDEX_CONTRACT_BLOCK is missing required field decision_scope (contract_block_missing_decision_scope). ${_BOOTSTRAP_GUIDANCE}"
    fi
    if [[ -z "${_DS_FIELD// /}" ]]; then
        _deny "BLOCKED: CLAUDEX_CONTRACT_BLOCK has empty decision_scope (contract_block_missing_decision_scope). ${_BOOTSTRAP_GUIDANCE}"
    fi

    # generated_at: must be present + integer (not bool in JSON) + >0.
    # JSON booleans serialize as 'true'/'false' in jq -r output — they are NOT
    # valid timestamps. A missing or null field serializes as empty string via
    # `jq -r '.generated_at // empty'`. We handle boolean separately by checking
    # the raw JSON type.
    _GA_TYPE=$(printf '%s' "$_CONTRACT_JSON" | jq -r 'if has("generated_at") then (.generated_at | type) else "__MISSING__" end' 2>/dev/null || echo "__MISSING__")
    if [[ "$_GA_TYPE" == "__MISSING__" ]]; then
        _deny "BLOCKED: CLAUDEX_CONTRACT_BLOCK is missing required field generated_at (contract_block_missing_generated_at). ${_BOOTSTRAP_GUIDANCE}"
    fi
    if [[ "$_GA_TYPE" == "boolean" || "$_GA_TYPE" == "null" || "$_GA_TYPE" == "string" || "$_GA_TYPE" == "array" || "$_GA_TYPE" == "object" ]]; then
        _deny "BLOCKED: CLAUDEX_CONTRACT_BLOCK has invalid generated_at type '${_GA_TYPE}' (contract_block_invalid_generated_at). Must be a positive integer timestamp."
    fi
    _GA_VALUE=$(printf '%s' "$_CONTRACT_JSON" | jq -r '.generated_at' 2>/dev/null || echo "0")
    if ! [[ "$_GA_VALUE" =~ ^[0-9]+$ ]] || (( _GA_VALUE <= 0 )); then
        _deny "BLOCKED: CLAUDEX_CONTRACT_BLOCK has invalid generated_at value '${_GA_VALUE}' (contract_block_invalid_generated_at). Must be a positive integer timestamp."
    fi

    # End A8 shape validation — proceed to stage/subagent_type checks.

    _EXPECTED_SUBAGENT_TYPE=$(_python_authority "dispatch_subagent_type_for_stage" "$_STAGE_ID" 2>/dev/null || echo "")
    if [[ -z "$_EXPECTED_SUBAGENT_TYPE" ]]; then
        _deny "BLOCKED: stage_id '${_STAGE_ID}' is not a known active dispatch stage (contract_block_unknown_stage). Dispatch-significant subagents must use a runtime-owned stage id."
    fi
    if [[ -z "$_SUBAGENT_TYPE" ]]; then
        _deny "BLOCKED: CLAUDEX dispatch for stage '${_STAGE_ID}' omitted tool_input.subagent_type (contract_block_missing_subagent_type). Use canonical subagent_type '${_EXPECTED_SUBAGENT_TYPE}' so Claude loads agents/${_EXPECTED_SUBAGENT_TYPE}.md."
    fi
    if [[ "$_SUBAGENT_TYPE" != "$_EXPECTED_SUBAGENT_TYPE" ]]; then
        _deny "BLOCKED: stage '${_STAGE_ID}' must launch with subagent_type='${_EXPECTED_SUBAGENT_TYPE}', not '${_SUBAGENT_TYPE}' (contract_block_stage_subagent_type_mismatch). Generic or alias seats bypass the repo-owned stage prompt and weaken WHO checks-and-balances."
    fi

    if [[ -n "$_SESSION_ID" ]]; then
        _CARRIER_MODULE="$_HOOK_DIR/../runtime/core/pending_agent_requests.py"
        # Use shared 3-tier resolver — replaces former 2-tier (CLAUDE_POLICY_DB →
        # CLAUDE_PROJECT_DIR) that silently skipped the write when both were absent.
        # (DEC-CLAUDEX-SA-UNIFIED-DB-ROUTING-001)
        _CARRIER_DB="$(_resolve_policy_db)"
        _ATTEMPT_TIMEOUT_SECONDS="${CLAUDEX_DISPATCH_ATTEMPT_TIMEOUT_SECONDS:-2700}"
        _ATTEMPT_TIMEOUT_AT=""
        if [[ "$_ATTEMPT_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] && (( _ATTEMPT_TIMEOUT_SECONDS > 0 )); then
            _ATTEMPT_TIMEOUT_AT="$(( $(date +%s) + _ATTEMPT_TIMEOUT_SECONDS ))"
        fi
        # A8: fail-closed on carrier-write failure for canonical seats.
        # _CARRIER_DB must resolve via _resolve_policy_db (3-tier). If all three
        # tiers fail (no env vars, no git tree), deny rather than silently skip —
        # a canonical seat launched without a DB cannot deliver its contract to
        # subagent-start.sh. (DEC-CLAUDEX-AGENT-CONTRACT-AUTHENTICITY-A8-001)
        if [[ -z "$_CARRIER_DB" ]]; then
            _deny "BLOCKED: carrier write failed for canonical seat '${_EXPECTED_SUBAGENT_TYPE}' (carrier_write_failed). No policy DB path could be resolved (CLAUDE_POLICY_DB and CLAUDE_PROJECT_DIR are unset and no git toplevel found). Set CLAUDE_POLICY_DB or run from inside a git repo."
        fi
        if [[ -n "$_CARRIER_DB" && -f "$_CARRIER_MODULE" ]]; then
            if ! "$(_resolve_runtime_python)" "$_CARRIER_MODULE" write "$_CARRIER_DB" "$_SESSION_ID" "$_EXPECTED_SUBAGENT_TYPE" "$_CONTRACT_JSON" >/dev/null 2>&1; then
                _deny "BLOCKED: carrier write failed for canonical seat '${_EXPECTED_SUBAGENT_TYPE}' (carrier_write_failed). The pending_agent_requests row could not be written; the subagent-start.sh carrier path cannot deliver the contract. Check DB health and retry."
            fi
            # Issue a pending dispatch_attempts row for delivery tracking
            # (DEC-CLAUDEX-HOOK-WIRING-001). Best-effort: never blocks dispatch.
            _LOCAL_RUNTIME_ROOT="$_HOOK_DIR/../runtime"
            _DISPATCH_WF_ID=$(printf '%s' "$_CONTRACT_JSON" | jq -r '.workflow_id // empty' 2>/dev/null || echo "")
            CLAUDE_POLICY_DB="$_CARRIER_DB" cc_policy_local_runtime "$_LOCAL_RUNTIME_ROOT" dispatch attempt-issue \
                --session-id "$_SESSION_ID" \
                --agent-type "$_EXPECTED_SUBAGENT_TYPE" \
                --instruction "$_BLOCK_LINE" \
                ${_DISPATCH_WF_ID:+--workflow-id "$_DISPATCH_WF_ID"} \
                ${_ATTEMPT_TIMEOUT_AT:+--timeout-at "$_ATTEMPT_TIMEOUT_AT"} \
                >/dev/null 2>&1 || true
        fi
    fi
    exit 0
fi

# Deny: Agent(isolation:"worktree") bypasses Guardian worktree authority.
_deny "BLOCKED: Agent(isolation:\"worktree\") creates worktrees in /tmp via the harness, bypassing Guardian worktree authority (no lease, no workflow binding, no scope manifest). Use the dispatch chain instead: planner → guardian(provision) → implementer. Guardian runs 'cc-policy worktree provision' to create a properly-leased worktree under .worktrees/feature-<name>."
