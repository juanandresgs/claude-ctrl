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

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

HOOK_INPUT=$(read_input)
AGENT_TYPE=$(echo "$HOOK_INPUT" | jq -r '.agent_type // empty' 2>/dev/null)

PROJECT_ROOT=$(detect_project_root)
CONTEXT_PARTS=()

# --- Git + Plan state (one line) ---
get_git_state "$PROJECT_ROOT"
get_plan_status "$PROJECT_ROOT"

# Track subagent spawn in runtime marker store (sole authority, TKT-008).
# Using PID as the agent_id gives a stable per-process key that the
# check-*.sh SubagentStop hooks can match when deactivating the marker.
# .subagent-tracker flat-file write removed.
rt_marker_set "agent-$$" "${AGENT_TYPE:-unknown}" || true

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
        # Check if any worktrees exist for this project
        if [[ "$GIT_WT_COUNT" -eq 0 ]]; then
            CONTEXT_PARTS+=("CRITICAL FIRST ACTION: No worktree detected. You MUST create a git worktree BEFORE writing any code. Run: git worktree add ../\<feature-name\> -b \<feature-name\> main — then cd into the worktree and work there. Do NOT write source code on main.")
        fi
        CONTEXT_PARTS+=("Role: Implementer — test-first development in isolated worktrees. Add @decision annotations to 50+ line files. NEVER work on main. The branch-guard hook will DENY any source file writes on main.")

        # Bind workflow to runtime so guard.sh Check 12 and later roles can
        # discover the worktree path without inferring from CWD or git state.
        # workflow_id is derived from the branch (current_workflow_id).
        # After binding, check if scope exists for this workflow_id; if not
        # but scope exists for a different workflow_id on the same worktree,
        # emit a mismatch warning.
        _WF_ID=$(current_workflow_id "$PROJECT_ROOT")
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

        # Inject test status
        TEST_STATUS_FILE="${PROJECT_ROOT}/.claude/.test-status"
        if [[ -f "$TEST_STATUS_FILE" ]]; then
            TS_RESULT=$(cut -d'|' -f1 "$TEST_STATUS_FILE")
            TS_FAILS=$(cut -d'|' -f2 "$TEST_STATUS_FILE")
            if [[ "$TS_RESULT" == "fail" ]]; then
                CONTEXT_PARTS+=("WARNING: Tests currently FAILING ($TS_FAILS failures). Fix before proceeding.")
            fi
        fi
        get_research_status "$PROJECT_ROOT"
        if [[ "$RESEARCH_EXISTS" == "true" ]]; then
            CONTEXT_PARTS+=("Research log: $RESEARCH_ENTRY_COUNT entries. Check .claude/research-log.md before researching APIs or libraries.")
        fi
        CONTEXT_PARTS+=("HANDOFF: Implementers do not own proof-of-work anymore. Gather test output, capture how to run the feature, and hand off to Tester for independent verification before Guardian commits.")
        ;;
    tester)
        # Inject current evaluation state so the tester knows the context.
        # proof_state write removed (TKT-024): evaluation_state is the authority.
        if ! is_claude_meta_repo "$PROJECT_ROOT"; then
            _EVAL_WF=$(current_workflow_id "$PROJECT_ROOT")
            _EVAL_STATUS=$(rt_eval_get "$_EVAL_WF" 2>/dev/null || echo "idle")
            CONTEXT_PARTS+=("Evaluation state: workflow=$_EVAL_WF status=$_EVAL_STATUS")
        fi
        CONTEXT_PARTS+=("Role: Tester — you are the separation between builder and judge. Verify in the SAME worktree, do not modify source, surface exact evidence.")
        CONTEXT_PARTS+=("Scope: Read the implementer's changes, run tests, perform at least one live or real-entry-point verification, and spot-check one adjacent or compound interaction.")
        CONTEXT_PARTS+=("REQUIRED OUTPUT TRAILERS: Your final response MUST include these lines verbatim (replace values):")
        CONTEXT_PARTS+=("  EVAL_VERDICT: ready_for_guardian|needs_changes|blocked_by_plan")
        CONTEXT_PARTS+=("  EVAL_TESTS_PASS: true|false")
        CONTEXT_PARTS+=("  EVAL_NEXT_ROLE: guardian|implementer|planner")
        CONTEXT_PARTS+=("  EVAL_HEAD_SHA: <current HEAD git sha>")
        CONTEXT_PARTS+=("These trailers are machine-parsed by check-tester.sh to set evaluation_state. Missing or invalid trailers fail-closed to needs_changes.")
        ;;
    guardian)
        CONTEXT_PARTS+=("Role: Guardian — Update MASTER_PLAN.md ONLY at phase boundaries: when a merge completes a phase, update status to completed, populate Decision Log, present diff to user. For non-phase-completing merges, do NOT update the plan — close the relevant GitHub issues instead. Always: verify @decision annotations, check for staged secrets, require explicit approval.")
        CONTEXT_PARTS+=("Authority: Only Guardian may run git commit, merge, or push. Before doing so, require passing tests and evaluation_state = ready_for_guardian (set by Tester via EVAL_VERDICT trailer).")
        # Inject test status
        TEST_STATUS_FILE="${PROJECT_ROOT}/.claude/.test-status"
        if [[ -f "$TEST_STATUS_FILE" ]]; then
            TS_RESULT=$(cut -d'|' -f1 "$TEST_STATUS_FILE")
            TS_FAILS=$(cut -d'|' -f2 "$TEST_STATUS_FILE")
            if [[ "$TS_RESULT" == "fail" ]]; then
                CONTEXT_PARTS+=("CRITICAL: Tests FAILING ($TS_FAILS failures). Do NOT commit/merge until tests pass.")
            fi
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
