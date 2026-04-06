#!/usr/bin/env bash
set -euo pipefail

# SubagentStop:guardian — deterministic validation of guardian actions.
# Replaces AI agent hook. Checks MASTER_PLAN.md recency and git cleanliness.
# Advisory only (exit 0 always). Reports findings via additionalContext.
#
# DECISION: Deterministic guardian validation. Rationale: AI agent hooks have
# non-deterministic runtime and cascade risk. File stat + git status complete
# in <1s with zero cascade risk. Status: accepted.

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

# Capture stdin (contains agent response)
AGENT_RESPONSE=$(read_input 2>/dev/null || echo "{}")
AGENT_TYPE=$(printf '%s' "$AGENT_RESPONSE" | jq -r '.agent_type // empty' 2>/dev/null || true)

PROJECT_ROOT=$(detect_project_root)
PLAN="$PROJECT_ROOT/MASTER_PLAN.md"

# Record hook start time for observatory duration metric.
_HOOK_START_AT=$(date +%s)

# ---------------------------------------------------------------------------
# Local runtime resolution — see post-task.sh DEC-BRIDGE-002 for rationale.
# ---------------------------------------------------------------------------
_HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
_LOCAL_RUNTIME_CLI="$_HOOK_DIR/../runtime/cli.py"
_local_cc_policy() {
    if [[ -n "${CLAUDE_PROJECT_DIR:-}" && -z "${CLAUDE_POLICY_DB:-}" ]]; then
        export CLAUDE_POLICY_DB="$CLAUDE_PROJECT_DIR/.claude/state.db"
    fi
    python3 "$_LOCAL_RUNTIME_CLI" "$@"
}

# track_subagent_stop removed (TKT-008): .subagent-tracker no longer written.

# Deactivate runtime marker via lifecycle authority (DEC-LIFECYCLE-003).
# cc-policy lifecycle on-stop is the single authority for role-matched
# marker deactivation. It queries the active marker, matches its role to
# AGENT_TYPE, and deactivates — all in Python. No bash-side query needed.
if [[ -n "$AGENT_TYPE" ]]; then
    _local_cc_policy lifecycle on-stop "$AGENT_TYPE" >/dev/null 2>&1 || true
fi

ISSUES=()

# Extract agent's response text first (needed for phase-boundary detection)
RESPONSE_TEXT=$(echo "$AGENT_RESPONSE" | jq -r '.assistant_response // .response // .result // .output // empty' 2>/dev/null || echo "")

# --- Completion contract submission (Phase 2: DEC-COMPLETION-001) ---
# Parse LANDING_RESULT and OPERATION_CLASS from guardian response text.
# Submit a structured completion record for the guardian role.
# Advisory in v1: the commit already happened, so we record but do not block.
# The purpose is to populate completion_records for routing decisions in
# post-task.sh and for audit purposes.
_GD_LANDING_RESULT=""
_GD_OP_CLASS=""
if [[ -n "$RESPONSE_TEXT" ]]; then
    _GD_LANDING_RESULT=$(printf '%s' "$RESPONSE_TEXT" \
        | grep -oE '^LANDING_RESULT:[[:space:]]*[a-z_]+' \
        | head -1 \
        | sed 's/LANDING_RESULT:[[:space:]]*//' || true)
    _GD_OP_CLASS=$(printf '%s' "$RESPONSE_TEXT" \
        | grep -oE '^OPERATION_CLASS:[[:space:]]*[a-z_]+' \
        | head -1 \
        | sed 's/OPERATION_CLASS:[[:space:]]*//' || true)
fi

if ! is_claude_meta_repo "$PROJECT_ROOT"; then
    # WS1: use lease_context() to derive workflow_id from the active lease.
    # When a lease is active its workflow_id is authoritative over branch-derived id.
    _GD_LEASE_CTX=$(lease_context "$PROJECT_ROOT")
    _GD_LEASE_FOUND=$(printf '%s' "$_GD_LEASE_CTX" | jq -r '.found' 2>/dev/null || echo "false")
    if [[ "$_GD_LEASE_FOUND" == "true" ]]; then
        _GD_LEASE_ID=$(printf '%s' "$_GD_LEASE_CTX" | jq -r '.lease_id // empty' 2>/dev/null || true)
        _GD_WF_ID=$(printf '%s' "$_GD_LEASE_CTX" | jq -r '.workflow_id // empty' 2>/dev/null || true)
    else
        _GD_LEASE_ID=""
        _GD_WF_ID=""
    fi
    [[ -z "$_GD_WF_ID" ]] && _GD_WF_ID=$(current_workflow_id "$PROJECT_ROOT")

    if [[ -n "$_GD_LEASE_ID" ]]; then
        _GD_PAYLOAD=$(jq -n \
            --arg lr "${_GD_LANDING_RESULT:-}" \
            --arg oc "${_GD_OP_CLASS:-}" \
            '{LANDING_RESULT:$lr, OPERATION_CLASS:$oc}')
        _GD_CT_RESULT=$(rt_completion_submit "$_GD_LEASE_ID" "$_GD_WF_ID" "guardian" "$_GD_PAYLOAD")
        _GD_CT_VALID=$(printf '%s' "${_GD_CT_RESULT:-}" | jq -r '.valid // "false"' 2>/dev/null || echo "false")
        if [[ "$_GD_CT_VALID" != "true" ]]; then
            _GD_CT_MISSING=$(printf '%s' "$_GD_CT_RESULT" | jq -r '.missing_fields | join(", ")' 2>/dev/null || echo "unknown")
            # Advisory only in v1 — the git operation already completed.
            ISSUES+=("COMPLETION CONTRACT (advisory): Guardian completion record INVALID. Missing: $_GD_CT_MISSING. Add LANDING_RESULT and OPERATION_CLASS trailers to guardian responses.")
        fi
    fi

    # WS2: Reset evaluation state to idle ONLY after confirmed landing.
    # guard.sh used to reset eval BEFORE the merge ran (pre-merge), meaning
    # a denied merge would consume the readiness clearance. Now the reset
    # happens here, after the guardian completes, conditioned on LANDING_RESULT.
    #
    # @decision DEC-WS2-001
    # @title Eval state reset moves from guard.sh (pre-merge) to check-guardian.sh (post-landing)
    # @status accepted
    # @rationale guard.sh:355 reset evaluation_state to idle before the merge
    #   command executed. If the merge was subsequently denied (scope violation,
    #   approval missing, etc.) the eval readiness was consumed with no landing.
    #   The tester would need to re-run to re-issue ready_for_guardian. Fix:
    #   remove the pre-merge reset from guard.sh; add a post-landing reset here
    #   gated on LANDING_RESULT=committed|merged so only real landings consume
    #   the clearance.
    if [[ "$_GD_LANDING_RESULT" == "committed" || "$_GD_LANDING_RESULT" == "merged" ]]; then
        rt_eval_set "$_GD_WF_ID" "idle" 2>/dev/null || true
        rt_event_emit "eval_consumed" "Landing confirmed: $_GD_LANDING_RESULT for $_GD_WF_ID" || true
    fi
fi

# Detect if this was a phase-completing merge by looking for phase-completion language
IS_PHASE_COMPLETING=""
if [[ -n "$RESPONSE_TEXT" ]]; then
    IS_PHASE_COMPLETING=$(echo "$RESPONSE_TEXT" | grep -iE 'phase.*(complete|done|finished)|marking phase.*completed|status.*completed|phase completion' || echo "")
fi

# Check 1: MASTER_PLAN.md freshness — only for phase-completing merges
if [[ -n "$IS_PHASE_COMPLETING" ]]; then
    if [[ -f "$PLAN" ]]; then
        MOD_TIME=$(file_mtime "$PLAN")
        NOW=$(date +%s)
        AGE=$(( NOW - MOD_TIME ))

        if [[ "$AGE" -gt 300 ]]; then
            ISSUES+=("MASTER_PLAN.md not updated recently (${AGE}s ago) — expected update after phase-completing merge")
        fi
    else
        ISSUES+=("MASTER_PLAN.md not found — should exist before guardian merges")
    fi
elif [[ ! -f "$PLAN" ]]; then
    # Even for non-phase merges, flag if plan doesn't exist at all
    ISSUES+=("MASTER_PLAN.md not found — should exist before guardian merges")
fi

# Check 2: Git status is clean (no uncommitted changes)
DIRTY_COUNT=$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
if [[ "$DIRTY_COUNT" -gt 0 ]]; then
    ISSUES+=("$DIRTY_COUNT uncommitted change(s) remaining after guardian operation")
fi

# Check 3: Current branch info for context
CURRENT_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
LAST_COMMIT=$(git -C "$PROJECT_ROOT" log --oneline -1 2>/dev/null || echo "none")

# Check 4: Approval-loop detection — agent should not end with unanswered question
#
# INVESTIGATION NOTE (#145 — approval provenance):
#   This check examines the GUARDIAN'S OWN response text (RESPONSE_TEXT is
#   extracted from SubagentStop input — what the guardian said, not user input).
#   HAS_APPROVAL_QUESTION detects whether the guardian asked a question like
#   "do you approve?" or "shall I proceed?".  It does NOT detect the user's
#   response, and is NOT confused by the word "Approved" appearing in assistant
#   output.  The check correctly detects an approval-loop REGRESSION: Guardian
#   requesting user permission for a local landing that should auto-execute
#   under DEC-GUARD-AUTOLAND.
#
#   The approvals table `granted_by` field (schemas.py:188) has a default of
#   'user'. rt_approval_grant() is defined in runtime-bridge.sh and exported,
#   but has ZERO callers in the hook layer — grants only flow through the CLI
#   (`cc-policy approval grant`), which is invoked interactively by the user.
#   No hook writes a fake approval; the provenance concern in #145 is NOT
#   present in the running code.
#
#   @decision DEC-GUARD-CHECK4
#   @title Check 4 is not-a-bug — it detects auto-land regressions, not fake approvals
#   @status accepted
#   @rationale RESPONSE_TEXT is the guardian's output, not user input. Approval
#     provenance (granted_by) is clean: the only grant path is the user running
#     `cc-policy approval grant` explicitly. No code path produces a synthetic
#     approval. Issue #145 is closed as not-a-bug.
if [[ -n "$RESPONSE_TEXT" ]]; then
    # Check if response ends with an approval question
    HAS_APPROVAL_QUESTION=$(echo "$RESPONSE_TEXT" | grep -iE 'do you (approve|confirm|want me to proceed)|shall I (proceed|continue|merge)|ready to (merge|commit|proceed)\?' || echo "")
    # Check if response also contains execution confirmation
    HAS_EXECUTION=$(echo "$RESPONSE_TEXT" | grep -iE 'executing|done|merged|committed|completed|pushed|created branch|worktree created' || echo "")

    if [[ -n "$HAS_APPROVAL_QUESTION" && -z "$HAS_EXECUTION" ]]; then
        # Under auto-land policy (DEC-GUARD-AUTOLAND), approval questions are
        # expected only for high-risk ops (push, rebase, reset, force, destructive).
        # For local landing (commit, merge without push), an approval question
        # without execution is a regression — Guardian should auto-land.
        HAS_HIGH_RISK_OP=$(echo "$RESPONSE_TEXT" | grep -iE 'push|rebase|reset|force|delet' || echo "")
        if [[ -z "$HAS_HIGH_RISK_OP" ]]; then
            ISSUES+=("Auto-land regression: Guardian asked for approval on a local landing instead of executing automatically (DEC-GUARD-AUTOLAND)")
        fi
    fi
fi

# Check 5: Test status for git operations (WS3: via rt_test_state_get from SQLite authority)
_TS_JSON=$(rt_test_state_get "$PROJECT_ROOT") || _TS_JSON=""
_TS_STATUS=$(printf '%s' "${_TS_JSON:-}" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
_TS_FAILS=$(printf '%s' "${_TS_JSON:-}" | jq -r '.fail_count // 0' 2>/dev/null || echo "0")
_TS_FOUND=$(printf '%s' "${_TS_JSON:-}" | jq -r 'if .found then "yes" else "no" end' 2>/dev/null || echo "no")
if [[ "$_TS_FOUND" != "yes" ]]; then
    ISSUES+=("No test results found — verify tests were run before committing")
elif [[ "$_TS_STATUS" == "fail" ]]; then
    HAS_GIT_OP=$(echo "$RESPONSE_TEXT" | grep -iE 'merged|committed|git\s+(\S+\s+)*merge|git\s+(\S+\s+)*commit' || echo "")
    if [[ -n "$HAS_GIT_OP" ]]; then
        ISSUES+=("CRITICAL: Tests failing ($_TS_FAILS) when git operations were performed")
    else
        ISSUES+=("Tests failing ($_TS_FAILS failures) — address before next git operation")
    fi
fi

# Check 6: Evaluation state for git operations (TKT-024)
# Validates evaluation_state instead of proof_state. Guardian should only
# operate when evaluation_state == "ready_for_guardian" (set by check-tester.sh).
EVAL_STATUS=$(read_evaluation_status "$PROJECT_ROOT" "$_GD_WF_ID")
HAS_GIT_OP=$(echo "$RESPONSE_TEXT" | grep -iE 'merged|committed|pushed|git\s+(\S+\s+)*merge|git\s+(\S+\s+)*commit|git\s+(\S+\s+)*push' || echo "")
if [[ -n "$HAS_GIT_OP" && "$EVAL_STATUS" != "ready_for_guardian" ]] && ! is_claude_meta_repo "$PROJECT_ROOT"; then
    ISSUES+=("Evaluation state is '$EVAL_STATUS' after git operation — Guardian should only proceed after Tester issues EVAL_VERDICT=ready_for_guardian")
fi

# Build context message
CONTEXT=""
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    CONTEXT="Guardian validation: ${#ISSUES[@]} issue(s)."
    for issue in "${ISSUES[@]}"; do
        CONTEXT+="\n- $issue"
    done
else
    CONTEXT="Guardian validation: clean. Branch=$CURRENT_BRANCH, last commit: $LAST_COMMIT"
fi

# Persist findings via runtime event store
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    rt_event_emit "agent_finding" "guardian: $(IFS='; '; echo "${ISSUES[*]}")" || true
    for issue in "${ISSUES[@]}"; do
        append_audit "$PROJECT_ROOT" "agent_guardian" "$issue"
    done
fi

# Observatory: emit agent duration and commit outcome metrics (W-OBS-2).
# _HOOK_START_AT is set near the top of this hook after PROJECT_ROOT is resolved.
# _GD_LANDING_RESULT and _GD_OP_CLASS are parsed from the guardian's LANDING_RESULT
# and OPERATION_CLASS trailers (empty strings when absent — guardian didn't land).
_obs_duration=$(( $(date +%s) - _HOOK_START_AT ))
rt_obs_metric agent_duration_s "$_obs_duration" \
    "{\"verdict\":\"${_GD_LANDING_RESULT:-unknown}\"}" "" "guardian" || true
rt_obs_metric commit_outcome 1 \
    "{\"result\":\"${_GD_LANDING_RESULT:-unknown}\",\"operation_class\":\"${_GD_OP_CLASS:-unknown}\"}" \
    "" "guardian" || true

# Output as additionalContext
ESCAPED=$(echo -e "$CONTEXT" | jq -Rs .)
cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF

exit 0
