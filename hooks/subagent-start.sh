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
_LOCAL_RUNTIME_CLI="$_HOOK_DIR/../runtime/cli.py"
_local_cc_policy() {
    if [[ -n "${CLAUDE_PROJECT_DIR:-}" && -z "${CLAUDE_POLICY_DB:-}" ]]; then
        export CLAUDE_POLICY_DB="$CLAUDE_PROJECT_DIR/.claude/state.db"
    fi
    python3 "$_LOCAL_RUNTIME_CLI" "$@"
}

_authority_python() {
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
elif mode == "canonical_stage_id":
    result = ar.canonical_stage_id(value)
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
    _CARRIER_DB="${CLAUDE_POLICY_DB:-}"
    if [[ -z "$_CARRIER_DB" && -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
        _CARRIER_DB="$CLAUDE_PROJECT_DIR/.claude/state.db"
    fi
    if [[ -n "$_CARRIER_DB" && -f "$_CARRIER_MODULE" ]]; then
        _CARRIER_AGENT_TYPE=$(_authority_python "canonical_dispatch_subagent_type" "${AGENT_TYPE:-}" 2>/dev/null || echo "")
        [[ -z "$_CARRIER_AGENT_TYPE" ]] && _CARRIER_AGENT_TYPE="$AGENT_TYPE"
        _CARRIER_JSON=$(python3 "$_CARRIER_MODULE" consume "$_CARRIER_DB" "$SESSION_ID" "$_CARRIER_AGENT_TYPE" 2>/dev/null || echo "")
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
    _EFFECTIVE_LEASE_ROLE="$_CANONICAL_SUBAGENT_TYPE"
    _LEGACY_STAGE_ID=$(_authority_python "canonical_stage_id" "$AGENT_TYPE" 2>/dev/null || echo "")
    [[ -n "$_LEGACY_STAGE_ID" ]] && _MARKER_ROLE="$_LEGACY_STAGE_ID"
fi

# Track subagent spawn via lifecycle authority (DEC-LIFECYCLE-002).
# Using PID as the agent_id gives a stable per-process key that the
# check-*.sh SubagentStop hooks can match when deactivating the marker.
# Calls dispatch agent-start (lifecycle.py) via local CLI resolution so
# this reaches the in-worktree runtime in isolated worktrees before merge.
# rt_marker_set direct call removed — lifecycle.py is the sole authority.
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
    # Pass project_root and workflow_id for per-project scoping (W-CONV-2).
    # workflow_id is derived from the current branch via current_workflow_id()
    # so the marker is queryable via get_active(project_root=X, workflow_id=W).
    _WF_ID_FOR_MARKER=$(current_workflow_id "$PROJECT_ROOT" 2>/dev/null || true)
    _local_cc_policy dispatch agent-start \
        "${_MARKER_ROLE:-unknown}" "agent-$$" \
        --project-root "$PROJECT_ROOT" \
        ${_WF_ID_FOR_MARKER:+--workflow-id "$_WF_ID_FOR_MARKER"} \
        >/dev/null 2>&1 || true
fi

# --- Lease claim: bind this agent to an active dispatch lease if one exists ---
# Phase 2 (DEC-LEASE-002): At spawn time, attempt to claim any active lease
# for this worktree. If found, inject the lease context so the agent knows
# its role, allowed ops, and next step without re-inferring from environment.
# If no lease exists, inject a warning — high-risk git ops will be denied by
# guard.sh Check 3 (validate_op fallback path) when no lease is active.
_CLAIM=$(rt_lease_claim "agent-$$" "$PROJECT_ROOT" "$_EFFECTIVE_LEASE_ROLE")
_LEASE_ID=$(printf '%s' "${_CLAIM:-}" | jq -r '.lease.lease_id // .lease_id // empty' 2>/dev/null || true)
if [[ -n "$_LEASE_ID" ]]; then
    _L_ROLE=$(printf '%s' "$_CLAIM" | jq -r '.lease.role // .role // empty' 2>/dev/null || true)
    _L_OPS=$(printf '%s' "$_CLAIM" | jq -r '.lease.allowed_ops_json // .allowed_ops_json // empty' 2>/dev/null || true)
    _L_NS=$(printf '%s' "$_CLAIM" | jq -r '.lease.next_step // .next_step // empty' 2>/dev/null || true)
    CONTEXT_PARTS+=("Lease: id=$_LEASE_ID role=$_L_ROLE ops=$_L_OPS${_L_NS:+ next=$_L_NS}")
else
    CONTEXT_PARTS+=("WARNING: No active lease for worktree $PROJECT_ROOT. High-risk git ops will be denied.")
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
# additionalContext. Do NOT fall back to the shell-built guidance path:
# the contract was present, so the caller expected runtime-produced output
# and the legacy path would silently inject unrelated guidance.
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
        # Invalid or error: do NOT fall back to legacy guidance path.
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
# Legacy compatibility path (transitional, non-authoritative).
# This path runs only when the incoming payload does NOT carry the full
# six-field request contract. It assembles context from shell helpers and
# git state.
#
# This is NOT a fallback for failed runtime compiles. It is reached only
# when the contract was never present — typically pre-Phase 3 dispatch
# paths that have not yet been updated to inject the request contract.
#
# TODO(Phase 3): Remove this path once all dispatch paths inject the full
# request contract at invocation time.
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

# --- Agent-type-specific context ---
case "$AGENT_TYPE" in
    planner|Plan)
        CONTEXT_PARTS+=("Role: Planner — create MASTER_PLAN.md before any code. Include rationale, architecture, git issues, worktree strategy.")
        get_research_status "$PROJECT_ROOT"
        if [[ "$RESEARCH_EXISTS" == "true" ]]; then
            CONTEXT_PARTS+=("Research: $RESEARCH_ENTRY_COUNT entries ($RESEARCH_RECENT_TOPICS). Read .claude/research-log.md before researching — avoid duplicates.")
        else
            CONTEXT_PARTS+=("No prior research. /deep-research for tech comparisons, /last30days for community sentiment.")
        fi
        ;;
    implementer)
        # Inject worktree path from lease context (DEC-GUARD-WT-003, W-GWT-3).
        # Guardian provisions the worktree and issues an implementer lease that
        # carries worktree_path. We surface it here so the agent knows its
        # working directory without re-inferring from environment.
        # If no lease was found (no worktree provisioned yet), warn — Guard.sh
        # will deny high-risk git ops and the orchestrator should dispatch
        # Guardian in provision mode before this implementer proceeds.
        if [[ -n "$_LEASE_ID" ]]; then
            _WT_PATH=$(printf '%s' "$_CLAIM" | jq -r '.lease.worktree_path // empty' 2>/dev/null || true)
            if [[ -n "$_WT_PATH" ]]; then
                CONTEXT_PARTS+=("Worktree: $_WT_PATH (provisioned by Guardian)")
            else
                CONTEXT_PARTS+=("WARNING: No worktree detected. Guardian should have provisioned one. Check dispatch context for worktree_path.")
            fi
        else
            CONTEXT_PARTS+=("WARNING: No worktree detected. Guardian should have provisioned one. Check dispatch context for worktree_path.")
        fi
        CONTEXT_PARTS+=("Role: Implementer — test-first development in isolated worktrees. Add @decision annotations to 50+ line files. NEVER work on main. The branch-guard hook will DENY any source file writes on main.")

        # Bind workflow to runtime so guard.sh Check 12 and later roles can
        # discover the worktree path without inferring from CWD or git state.
        # WS1: if a lease was claimed, use the lease's workflow_id for the binding
        # so that all subsequent hooks (check-reviewer, check-guardian, guard.sh)
        # see the same workflow_id. Branch-derived id is the fallback only when
        # no lease was claimed.
        _WF_ID=""
        if [[ -n "$_LEASE_ID" ]]; then
            _WF_ID=$(printf '%s' "$_CLAIM" | jq -r '.lease.workflow_id // .workflow_id // empty' 2>/dev/null || true)
        fi
        [[ -z "$_WF_ID" ]] && _WF_ID=$(current_workflow_id "$PROJECT_ROOT")
        _WF_WORKTREE="$PROJECT_ROOT"
        _WF_BRANCH="${GIT_BRANCH:-unknown}"
        rt_workflow_bind "$_WF_ID" "$_WF_WORKTREE" "$_WF_BRANCH" || true
        CONTEXT_PARTS+=("Workflow binding: id=$_WF_ID worktree=$_WF_WORKTREE branch=$_WF_BRANCH")

        # Check for workflow_id mismatch: scope loaded for different workflow_id
        _SCOPE_CHECK=$(cc_policy workflow scope-get "$_WF_ID" 2>/dev/null) || _SCOPE_CHECK=""
        _SCOPE_FOUND=$(printf '%s' "${_SCOPE_CHECK:-}" | jq -r 'if .found then "yes" else "no" end' 2>/dev/null || echo "no")
        if [[ "$_SCOPE_FOUND" != "yes" ]]; then
            CONTEXT_PARTS+=("WARNING: No scope manifest found for workflow_id '$_WF_ID'. Planner should set scope via 'cc-policy workflow scope-set' before commit. Guard.sh will deny commit without scope.")
        fi

        # Inject test status (WS3: via rt_test_state_get from SQLite authority)
        _TS_JSON=$(rt_test_state_get "$PROJECT_ROOT") || _TS_JSON=""
        _TS_STATUS=$(printf '%s' "${_TS_JSON:-}" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
        _TS_FAILS=$(printf '%s' "${_TS_JSON:-}" | jq -r '.fail_count // 0' 2>/dev/null || echo "0")
        if [[ "$_TS_STATUS" == "fail" ]]; then
            CONTEXT_PARTS+=("WARNING: Tests currently FAILING ($_TS_FAILS failures). Fix before proceeding.")
        fi
        get_research_status "$PROJECT_ROOT"
        if [[ "$RESEARCH_EXISTS" == "true" ]]; then
            CONTEXT_PARTS+=("Research log: $RESEARCH_ENTRY_COUNT entries. Check .claude/research-log.md before researching APIs or libraries.")
        fi
        CONTEXT_PARTS+=("HANDOFF: Implementers do not own proof-of-work anymore. Gather test output, capture how to run the feature, and hand off to Reviewer for independent verification before Guardian commits.")
        ;;
    guardian)
        CONTEXT_PARTS+=("Role: Guardian — Update MASTER_PLAN.md ONLY at phase boundaries: when a merge completes a phase, update status to completed, populate Decision Log, present diff to user. For non-phase-completing merges, do NOT update the plan — close the relevant GitHub issues instead. Always: verify @decision annotations, check for staged secrets, require explicit approval.")
        CONTEXT_PARTS+=("Authority: Only Guardian may run git commit, merge, or push. Before doing so, require passing tests and evaluation_state = ready_for_guardian (set by Reviewer via REVIEW_VERDICT trailer).")
        # Inject test status (WS3: via rt_test_state_get from SQLite authority)
        _TS_JSON=$(rt_test_state_get "$PROJECT_ROOT") || _TS_JSON=""
        _TS_STATUS=$(printf '%s' "${_TS_JSON:-}" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
        _TS_FAILS=$(printf '%s' "${_TS_JSON:-}" | jq -r '.fail_count // 0' 2>/dev/null || echo "0")
        if [[ "$_TS_STATUS" == "fail" ]]; then
            CONTEXT_PARTS+=("CRITICAL: Tests FAILING ($_TS_FAILS failures). Do NOT commit/merge until tests pass.")
        fi
        ;;
    reviewer)
        # Inject current evaluation state so the reviewer knows the context.
        if ! is_claude_meta_repo "$PROJECT_ROOT"; then
            _EVAL_WF=$(current_workflow_id "$PROJECT_ROOT")
            _EVAL_STATUS=$(rt_eval_get "$_EVAL_WF" 2>/dev/null || echo "idle")
            CONTEXT_PARTS+=("Evaluation state: workflow=$_EVAL_WF status=$_EVAL_STATUS")
        fi
        CONTEXT_PARTS+=("Role: Reviewer — you are the read-only technical readiness authority. Inspect the diff, run and verify required tests where possible, and produce structured findings. Do NOT modify source code or land git operations.")
        CONTEXT_PARTS+=("Scope: Read the implementer's changes, run tests, assess code quality, security, and architectural conformance. Produce per-finding structured assessments.")
        CONTEXT_PARTS+=("REQUIRED OUTPUT TRAILERS: Your final response MUST include these lines verbatim (replace values):")
        CONTEXT_PARTS+=("  REVIEW_VERDICT: ready_for_guardian|needs_changes|blocked_by_plan")
        CONTEXT_PARTS+=("  REVIEW_HEAD_SHA: <current HEAD git sha>")
        CONTEXT_PARTS+=("  REVIEW_FINDINGS_JSON: {\"findings\": [{\"severity\": \"<blocking|concern|note>\", \"title\": \"<short title>\", \"detail\": \"<explanation>\"}]}")
        CONTEXT_PARTS+=("These trailers are machine-parsed by check-reviewer.sh. Invalid or missing REVIEW_* trailers produce an invalid completion and post-task will not auto-dispatch.")
        ;;
    Bash|Explore)
        # Lightweight agents — minimal context
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
