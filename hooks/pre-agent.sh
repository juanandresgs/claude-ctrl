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

_HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"

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
    python3 - "$_HOOK_DIR/.." "$mode" "$value" <<'PY'
import sys
repo_root, mode, value = sys.argv[1:4]
sys.path.insert(0, repo_root)
from runtime.core import authority_registry as ar

if mode == "dispatch_subagent_type_for_stage":
    result = ar.dispatch_subagent_type_for_stage(value)
elif mode == "canonical_dispatch_subagent_type":
    result = ar.canonical_dispatch_subagent_type(value)
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
            _deny "BLOCKED: dispatch-significant subagent '${_SUBAGENT_TYPE}' launched without CLAUDEX_CONTRACT_BLOCK. Use 'cc-policy dispatch agent-prompt --stage-id <stage>' and set subagent_type to the returned required_subagent_type."
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
        _deny "BLOCKED: CLAUDEX_CONTRACT_BLOCK is not valid JSON. Dispatch-significant subagents must carry a valid runtime-issued contract block."
    fi
    _STAGE_ID=$(printf '%s' "$_CONTRACT_JSON" | jq -r '.stage_id // empty' 2>/dev/null || echo "")
    if [[ -z "$_STAGE_ID" ]]; then
        _deny "BLOCKED: CLAUDEX_CONTRACT_BLOCK is missing stage_id. Dispatch-significant subagents must be launched from a runtime-issued contract."
    fi
    _EXPECTED_SUBAGENT_TYPE=$(_python_authority "dispatch_subagent_type_for_stage" "$_STAGE_ID" 2>/dev/null || echo "")
    if [[ -z "$_EXPECTED_SUBAGENT_TYPE" ]]; then
        _deny "BLOCKED: stage_id '${_STAGE_ID}' is not a known active dispatch stage. Dispatch-significant subagents must use a runtime-owned stage id."
    fi
    if [[ -z "$_SUBAGENT_TYPE" ]]; then
        _deny "BLOCKED: CLAUDEX dispatch for stage '${_STAGE_ID}' omitted tool_input.subagent_type. Use canonical subagent_type '${_EXPECTED_SUBAGENT_TYPE}' so Claude loads agents/${_EXPECTED_SUBAGENT_TYPE}.md."
    fi
    if [[ "$_SUBAGENT_TYPE" != "$_EXPECTED_SUBAGENT_TYPE" ]]; then
        _deny "BLOCKED: stage '${_STAGE_ID}' must launch with subagent_type='${_EXPECTED_SUBAGENT_TYPE}', not '${_SUBAGENT_TYPE}'. Generic or alias seats bypass the repo-owned stage prompt and weaken WHO checks-and-balances."
    fi

    if [[ -n "$_SESSION_ID" ]]; then
        _CARRIER_MODULE="$_HOOK_DIR/../runtime/core/pending_agent_requests.py"
        _CARRIER_DB="${CLAUDE_POLICY_DB:-}"
        _ATTEMPT_TIMEOUT_SECONDS="${CLAUDEX_DISPATCH_ATTEMPT_TIMEOUT_SECONDS:-2700}"
        _ATTEMPT_TIMEOUT_AT=""
        if [[ "$_ATTEMPT_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] && (( _ATTEMPT_TIMEOUT_SECONDS > 0 )); then
            _ATTEMPT_TIMEOUT_AT="$(( $(date +%s) + _ATTEMPT_TIMEOUT_SECONDS ))"
        fi
        if [[ -z "$_CARRIER_DB" && -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
            _CARRIER_DB="$CLAUDE_PROJECT_DIR/.claude/state.db"
        fi
        if [[ -n "$_CARRIER_DB" && -f "$_CARRIER_MODULE" ]]; then
            python3 "$_CARRIER_MODULE" write "$_CARRIER_DB" "$_SESSION_ID" "$_EXPECTED_SUBAGENT_TYPE" "$_CONTRACT_JSON" >/dev/null 2>&1 || true
            # Issue a pending dispatch_attempts row for delivery tracking
            # (DEC-CLAUDEX-HOOK-WIRING-001). Best-effort: never blocks dispatch.
            _LOCAL_RUNTIME_CLI="$_HOOK_DIR/../runtime/cli.py"
            _DISPATCH_WF_ID=$(printf '%s' "$_CONTRACT_JSON" | jq -r '.workflow_id // empty' 2>/dev/null || echo "")
            CLAUDE_POLICY_DB="$_CARRIER_DB" python3 "$_LOCAL_RUNTIME_CLI" dispatch attempt-issue \
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
