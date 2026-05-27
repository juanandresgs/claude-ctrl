#!/usr/bin/env bash
set -euo pipefail

# Subagent context injection at spawn time.
# SubagentStart hook — matcher: (all agent types)
#
# Injects current project state into every subagent so Planner,
# Implementer, Tester, and Guardian agents always have fresh context:
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
PAYLOAD_AGENT_ID=$(echo "$HOOK_INPUT" | jq -r '.agent_id // empty' 2>/dev/null || echo "")

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

_ticket_from_subagent_transcript() {
    local parent_transcript="$1"
    local child_agent_id="$2"
    [[ -n "$parent_transcript" && -n "$child_agent_id" ]] || return 0
    local parent_dir child_transcript
    parent_dir="$(dirname "$parent_transcript")"
    child_transcript="$parent_dir/subagents/agent-${child_agent_id}.jsonl"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [[ -s "$child_transcript" ]] && break
        sleep 0.1
    done
    [[ -s "$child_transcript" ]] || return 0
    python3 - "$child_transcript" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    for raw in fh:
        try:
            item = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if item.get("type") != "user":
            continue
        content = (item.get("message") or {}).get("content", "")
        if isinstance(content, str):
            print(content)
            raise SystemExit(0)
        if isinstance(content, list):
            parts = []
            for part in content:
                if isinstance(part, dict) and part.get("type") == "text":
                    parts.append(str(part.get("text") or ""))
            print("\n".join(parts))
            raise SystemExit(0)
        break
PY
}

_tool_use_id_from_subagent_meta() {
    local parent_transcript="$1"
    local child_agent_id="$2"
    [[ -n "$parent_transcript" && -n "$child_agent_id" ]] || return 0
    local parent_dir meta_path
    parent_dir="$(dirname "$parent_transcript")"
    meta_path="$parent_dir/subagents/agent-${child_agent_id}.meta.json"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [[ -s "$meta_path" ]] && break
        sleep 0.1
    done
    [[ -s "$meta_path" ]] || return 0
    jq -r '.toolUseId // .tool_use_id // empty' "$meta_path" 2>/dev/null || true
}

_marker_agent_id() {
    if [[ -n "${PAYLOAD_AGENT_ID:-}" ]]; then
        printf 'agent-%s\n' "$PAYLOAD_AGENT_ID"
    else
        printf 'agent-%s\n' "$$"
    fi
}

_start_role_marker() {
    local role="$1"
    local workflow_id="${2:-}"
    local marker_id
    marker_id=$(_marker_agent_id)
    _local_cc_policy dispatch agent-start \
        "$role" "$marker_id" \
        --project-root "$PROJECT_ROOT" \
        ${workflow_id:+--workflow-id "$workflow_id"} \
        >/dev/null 2>&1 || true
}

# v6 runtime-ticket context path. Canonical seats must have been claimed by
# pre-agent.sh before the harness spawned the child. No canonical role may fall
# back to user-visible ticket ceremony; the runtime ledger is best-effort
# context, while SubagentStart's marker is the write-policy identity authority.
case "${AGENT_TYPE:-}" in
    planner|implementer|critic|reviewer|guardian)
        V6_CLAIM_TOKEN=$(printf '%s' "$HOOK_INPUT" | jq -r '.v6_claim_token // .claim_token // empty' 2>/dev/null || echo "")
        V6_TICKET_ID=$(printf '%s' "$HOOK_INPUT" | jq -r '.ticket_id // empty' 2>/dev/null || echo "")
        PARENT_TRANSCRIPT=$(printf '%s' "$HOOK_INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")
        if [[ -z "$V6_TICKET_ID" ]]; then
            CHILD_PROMPT=$(_ticket_from_subagent_transcript "$PARENT_TRANSCRIPT" "$PAYLOAD_AGENT_ID" || true)
            if [[ -n "$CHILD_PROMPT" ]]; then
                V6_PARSE=$(printf '%s' "$CHILD_PROMPT" | _local_cc_policy stage ticket-parse --stdin 2>/dev/null || true)
                V6_TICKET_ID=$(printf '%s' "${V6_PARSE:-}" | jq -r '.ticket_id // empty' 2>/dev/null || echo "")
            fi
        fi
        V6_AGENT_REF=$(_tool_use_id_from_subagent_meta "$PARENT_TRANSCRIPT" "$PAYLOAD_AGENT_ID" || true)
        V6_WF_ID=$(current_workflow_id "$PROJECT_ROOT" 2>/dev/null || echo "default")
        V6_CTX=$(printf '%s' "${CHILD_PROMPT:-}" | _local_cc_policy stage start-context \
            --subagent-type "$AGENT_TYPE" \
            --workflow-id "$V6_WF_ID" \
            --worktree-path "$PROJECT_ROOT" \
            ${SESSION_ID:+--session-id "$SESSION_ID"} \
            ${PAYLOAD_AGENT_ID:+--agent-id "$PAYLOAD_AGENT_ID"} \
            ${V6_AGENT_REF:+--agent-ref "$V6_AGENT_REF"} \
            ${V6_CLAIM_TOKEN:+--claim-token "$V6_CLAIM_TOKEN"} \
            ${V6_TICKET_ID:+--ticket-id "$V6_TICKET_ID"} \
            --stdin 2>/dev/null || true)
        V6_FOUND=$(printf '%s' "${V6_CTX:-}" | jq -r '.found // false' 2>/dev/null || echo "false")
        if [[ "$V6_FOUND" == "true" ]]; then
            V6_STAGE=$(printf '%s' "$V6_CTX" | jq -r '.stage_run.stage_id // empty' 2>/dev/null || echo "")
            V6_RUN_ID=$(printf '%s' "$V6_CTX" | jq -r '.stage_run.id // empty' 2>/dev/null || echo "")
            V6_WORKFLOW_ID=$(printf '%s' "$V6_CTX" | jq -r '.stage_run.workflow_id // empty' 2>/dev/null || echo "")
            _start_role_marker "$AGENT_TYPE" "$V6_WORKFLOW_ID"
            if [[ "$V6_STAGE" == "guardian:land" && -n "$V6_RUN_ID" ]]; then
                _local_cc_policy stage landing-ready "$V6_RUN_ID" >/dev/null 2>&1 || true
                V6_CTX=$(printf '%s' "${CHILD_PROMPT:-}" | _local_cc_policy stage start-context \
                    --subagent-type "$AGENT_TYPE" \
                    --workflow-id "$V6_WF_ID" \
                    --worktree-path "$PROJECT_ROOT" \
                    ${SESSION_ID:+--session-id "$SESSION_ID"} \
                    ${PAYLOAD_AGENT_ID:+--agent-id "$PAYLOAD_AGENT_ID"} \
                    ${V6_AGENT_REF:+--agent-ref "$V6_AGENT_REF"} \
                    ${V6_CLAIM_TOKEN:+--claim-token "$V6_CLAIM_TOKEN"} \
                    ${V6_TICKET_ID:+--ticket-id "$V6_TICKET_ID"} \
                    --stdin 2>/dev/null || true)
            fi
            V6_TEXT=$(printf '%s' "$V6_CTX" | jq -r '.context_text // empty' 2>/dev/null || echo "")
            ESCAPED=$(printf '%s' "$V6_TEXT" | jq -Rs .)
            cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SubagentStart",
    "additionalContext": $ESCAPED
  }
}
EOF
            exit 0
        fi
        ;;
esac

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
case "${AGENT_TYPE:-}" in
    planner|Plan|implementer|tester|guardian|critic|reviewer)
        _IS_DISPATCH_ROLE=true
        ;;
esac

if [[ "$_IS_DISPATCH_ROLE" == "true" ]]; then
    # Pass project_root and workflow_id for per-project scoping (W-CONV-2).
    # workflow_id is derived from the current branch via current_workflow_id()
    # so the marker is queryable via get_active(project_root=X, workflow_id=W).
    _WF_ID_FOR_MARKER=$(current_workflow_id "$PROJECT_ROOT" 2>/dev/null || true)
    _start_role_marker "${AGENT_TYPE:-unknown}" "$_WF_ID_FOR_MARKER"
fi

# --- Lease claim: bind this agent to an active dispatch lease if one exists ---
# Phase 2 (DEC-LEASE-002): At spawn time, attempt to claim any active lease
# for this worktree. If found, inject the lease context so the agent knows
# its role, allowed ops, and next step without re-inferring from environment.
# If no lease exists, inject a warning — high-risk git ops will be denied by
# guard.sh Check 3 (validate_op fallback path) when no lease is active.
_CLAIM=$(rt_lease_claim "$(_marker_agent_id)" "$PROJECT_ROOT" "$AGENT_TYPE")
_LEASE_ID=$(printf '%s' "${_CLAIM:-}" | jq -r '.lease.lease_id // .lease_id // empty' 2>/dev/null || true)
if [[ -n "$_LEASE_ID" ]]; then
    _L_ROLE=$(printf '%s' "$_CLAIM" | jq -r '.lease.role // .role // empty' 2>/dev/null || true)
    _L_OPS=$(printf '%s' "$_CLAIM" | jq -r '.lease.allowed_ops_json // .allowed_ops_json // empty' 2>/dev/null || true)
    _L_NS=$(printf '%s' "$_CLAIM" | jq -r '.lease.next_step // .next_step // empty' 2>/dev/null || true)
    CONTEXT_PARTS+=("Lease: id=$_LEASE_ID role=$_L_ROLE ops=$_L_OPS${_L_NS:+ next=$_L_NS}")
else
    CONTEXT_PARTS+=("WARNING: No active lease for worktree $PROJECT_ROOT. High-risk git ops will be denied.")
fi

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
        # so that subsequent reviewer/guardian policy checks
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
        CONTEXT_PARTS+=("HANDOFF: Implementers do not own proof-of-work anymore. Gather test output and emit the v6 result contract; runtime routes through critic and reviewer before Guardian landing.")
        ;;
    tester)
        # Legacy tester context retained for historical/manual runs only. Active
        # v6 readiness uses reviewer + claude_ctrl_result.
        if ! is_claude_meta_repo "$PROJECT_ROOT"; then
            _EVAL_WF=$(current_workflow_id "$PROJECT_ROOT")
            _EVAL_STATUS=$(rt_eval_get "$_EVAL_WF" 2>/dev/null || echo "idle")
            CONTEXT_PARTS+=("Evaluation state: workflow=$_EVAL_WF status=$_EVAL_STATUS")
        fi
        CONTEXT_PARTS+=("Role: Tester is legacy. Active v6 readiness uses reviewer with claude_ctrl_result; do not use tester for new readiness decisions.")
        ;;
    guardian)
        CONTEXT_PARTS+=("Role: Guardian — Update MASTER_PLAN.md ONLY at phase boundaries: when a merge completes a phase, update status to completed, populate Decision Log, present diff to user. For non-phase-completing merges, do NOT update the plan — close the relevant GitHub issues instead. Always: verify @decision annotations, check for staged secrets, require explicit approval for high-risk operations.")
        CONTEXT_PARTS+=("Authority: Only Guardian may run git commit, merge, or push. In canonical v6, landing is gated by v6_landing_readiness assembled from reviewer/test/scope/SHA/lease evidence; legacy evaluation_state is migration-only.")
        CONTEXT_PARTS+=("Small-source mode: apply directly only for <=2 files, no runtime/hooks/scripts/sidecars authority paths, no secrets, and focused tests passing. If the proposal expands, reject it and require Guardian provision -> implementer.")
        # Inject test status (WS3: via rt_test_state_get from SQLite authority)
        _TS_JSON=$(rt_test_state_get "$PROJECT_ROOT") || _TS_JSON=""
        _TS_STATUS=$(printf '%s' "${_TS_JSON:-}" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
        _TS_FAILS=$(printf '%s' "${_TS_JSON:-}" | jq -r '.fail_count // 0' 2>/dev/null || echo "0")
        if [[ "$_TS_STATUS" == "fail" ]]; then
            CONTEXT_PARTS+=("CRITICAL: Tests FAILING ($_TS_FAILS failures). Do NOT commit/merge until tests pass.")
        fi
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
