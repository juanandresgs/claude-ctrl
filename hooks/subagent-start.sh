#!/usr/bin/env bash
set -euo pipefail

# Subagent context injection at spawn time.
# SubagentStart hook — matcher: (all agent types)
#
# Injects current project state into every subagent so Planner,
# Implementer, and Guardian agents always have fresh context:
#   - Current git branch and dirty state
#   - MASTER_PLAN.md existence and active phase
#   - Active worktrees
#   - Agent-type-specific guidance
#   - Tracks subagent spawn in .subagent-tracker for status bar

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

HOOK_INPUT=$(read_input)
AGENT_TYPE=$(echo "$HOOK_INPUT" | jq -r '.agent_type // empty' 2>/dev/null)

PROJECT_ROOT=$(detect_project_root)
CONTEXT_PARTS=()

# --- Git + Plan state (one line) ---
get_git_state "$PROJECT_ROOT"
get_plan_status "$PROJECT_ROOT"

# Track subagent spawn
track_subagent_start "$PROJECT_ROOT" "${AGENT_TYPE:-unknown}"

# --- Trace protocol: initialize trace directory ---
TRACE_ID=""
TRACE_DIR=""
case "$AGENT_TYPE" in
    Bash|Explore)
        # Lightweight agents — no trace
        ;;
    *)
        TRACE_ID=$(init_trace "$PROJECT_ROOT" "${AGENT_TYPE:-unknown}" 2>/dev/null || echo "")
        if [[ -n "$TRACE_ID" ]]; then
            TRACE_DIR="${TRACE_STORE}/${TRACE_ID}"
        fi
        ;;
esac

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
        if [[ -n "$TRACE_DIR" ]]; then
            CONTEXT_PARTS+=("TRACE_DIR=$TRACE_DIR — Write verbose output to TRACE_DIR/artifacts/ (analysis.md, decisions.json). Write TRACE_DIR/summary.md before returning. Keep return message under 1500 tokens.")
        fi
        ;;
    implementer)
        # Check if any worktrees exist for this project
        if [[ "$GIT_WT_COUNT" -eq 0 ]]; then
            CONTEXT_PARTS+=("CRITICAL FIRST ACTION: No worktree detected. You MUST create a git worktree BEFORE writing any code. Run: git worktree add ../\<feature-name\> -b \<feature-name\> main — then cd into the worktree and work there. Do NOT write source code on main.")
        fi
        CONTEXT_PARTS+=("Role: Implementer — test-first development in isolated worktrees. Add @decision annotations to ${DECISION_LINE_THRESHOLD}+ line files. NEVER work on main. The branch-guard hook will DENY any source file writes on main.")
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
        CONTEXT_PARTS+=("After tests pass, return to orchestrator. The tester agent handles live verification — you do NOT demo or write .proof-status.")
        if [[ -n "$TRACE_DIR" ]]; then
            CONTEXT_PARTS+=("TRACE_DIR=$TRACE_DIR — Write verbose output to TRACE_DIR/artifacts/ (test-output.txt, diff.patch, files-changed.txt, proof-evidence.txt). Write TRACE_DIR/summary.md before returning. Keep return message under 1500 tokens.")
        fi
        ;;
    tester)
        CONTEXT_PARTS+=("Role: Tester — run the feature end-to-end, show the user actual output, write .proof-status = pending, ask user to say 'verified'. Do NOT modify source code. Do NOT write tests. Do NOT write 'verified' to .proof-status.")
        # Inject latest implementer trace path
        IMPL_TRACE=$(detect_active_trace "$PROJECT_ROOT" "implementer" 2>/dev/null || echo "")
        if [[ -z "$IMPL_TRACE" ]]; then
            # Try finding most recent completed implementer trace
            IMPL_TRACE=$(ls -t "${TRACE_STORE}"/implementer-*/manifest.json 2>/dev/null | head -1 | xargs -I{} dirname {} 2>/dev/null | xargs basename 2>/dev/null || echo "")
        fi
        if [[ -n "$IMPL_TRACE" ]]; then
            CONTEXT_PARTS+=("Implementer trace: ${TRACE_STORE}/${IMPL_TRACE} — read summary.md and artifacts/ to understand what was built.")
        fi
        # Inject worktree/branch context
        if [[ -n "$GIT_BRANCH" ]]; then
            CONTEXT_PARTS+=("Working on branch: $GIT_BRANCH — verify the feature on this branch, not main.")
        fi
        # Project type detection hints
        if [[ -f "$PROJECT_ROOT/package.json" ]]; then
            CONTEXT_PARTS+=("Project type hint: Node.js/web (package.json found). Try: npm run dev / npm start for dev server.")
        elif [[ -f "$PROJECT_ROOT/pyproject.toml" || -f "$PROJECT_ROOT/setup.py" ]]; then
            CONTEXT_PARTS+=("Project type hint: Python project. Look for CLI entrypoints or API servers.")
        elif [[ -f "$PROJECT_ROOT/Cargo.toml" ]]; then
            CONTEXT_PARTS+=("Project type hint: Rust project. Try: cargo run for CLI verification.")
        elif [[ -f "$PROJECT_ROOT/go.mod" ]]; then
            CONTEXT_PARTS+=("Project type hint: Go project. Try: go run . for CLI verification.")
        fi
        # Check for hook/script projects (like ~/.claude itself)
        if is_claude_meta_repo "$PROJECT_ROOT" 2>/dev/null; then
            CONTEXT_PARTS+=("Project type: Claude Code meta-infrastructure (hooks/scripts). Verify by running hooks with test input and checking output.")
        fi
        CONTEXT_PARTS+=("VERIFICATION PROTOCOL: 1. Run the feature live. 2. Paste actual output. 3. Write pending to .proof-status. 4. Ask user to say 'verified'.")
        if [[ -n "$TRACE_DIR" ]]; then
            CONTEXT_PARTS+=("TRACE_DIR=$TRACE_DIR — Write verbose output to TRACE_DIR/artifacts/ (verification-output.txt, verification-strategy.txt). Write TRACE_DIR/summary.md before returning. Keep return message under 1500 tokens.")
        fi
        ;;
    guardian)
        CONTEXT_PARTS+=("Role: Guardian — Update MASTER_PLAN.md ONLY at phase boundaries: when a merge completes a phase, update status to completed, populate Decision Log, present diff to user. For non-phase-completing merges, do NOT update the plan — close the relevant GitHub issues instead. Always: verify @decision annotations, check for staged secrets, require explicit approval.")
        # Inject test status
        TEST_STATUS_FILE="${PROJECT_ROOT}/.claude/.test-status"
        if [[ -f "$TEST_STATUS_FILE" ]]; then
            TS_RESULT=$(cut -d'|' -f1 "$TEST_STATUS_FILE")
            TS_FAILS=$(cut -d'|' -f2 "$TEST_STATUS_FILE")
            if [[ "$TS_RESULT" == "fail" ]]; then
                CONTEXT_PARTS+=("CRITICAL: Tests FAILING ($TS_FAILS failures). Do NOT commit/merge until tests pass.")
            fi
        fi
        if [[ -n "$TRACE_DIR" ]]; then
            CONTEXT_PARTS+=("TRACE_DIR=$TRACE_DIR — Write verbose output to TRACE_DIR/artifacts/ (merge-analysis.md). Write TRACE_DIR/summary.md before returning. Keep return message under 1500 tokens.")
        fi
        ;;
    Bash|Explore)
        # Lightweight agents — minimal context
        ;;
    *)
        CONTEXT_PARTS+=("Agent type: ${AGENT_TYPE:-unknown}")
        if [[ -n "$TRACE_DIR" ]]; then
            CONTEXT_PARTS+=("TRACE_DIR=$TRACE_DIR — Write verbose output to TRACE_DIR/artifacts/. Write TRACE_DIR/summary.md before returning. Keep return message under 1500 tokens.")
        fi
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
