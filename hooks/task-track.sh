#!/usr/bin/env bash
# PreToolUse:Task — track subagent spawns for status bar.
#
# Fires before every Task tool dispatch. Extracts subagent_type
# from tool_input and updates .subagent-tracker + .statusline-cache.
#
# Gate C also writes .active-worktree-path breadcrumb at implementer dispatch
# so resolve_proof_file() (log.sh) can locate the active .proof-status in
# worktree scenarios where tester writes its status to a different directory
# than the orchestrator's CLAUDE_DIR.
#
# @decision DEC-CACHE-003
# @title Use PreToolUse:Task as SubagentStart replacement
# @status accepted
# @rationale SubagentStart hooks don't fire in Claude Code v2.1.38.
#   PreToolUse:Task demonstrably fires before every Task dispatch.

set -euo pipefail

source "$(dirname "$0")/source-lib.sh"

HOOK_INPUT=$(read_input)
AGENT_TYPE=$(echo "$HOOK_INPUT" | jq -r '.tool_input.subagent_type // "unknown"' 2>/dev/null)

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)

# Track spawn and refresh statusline cache
track_subagent_start "$PROJECT_ROOT" "$AGENT_TYPE"
get_git_state "$PROJECT_ROOT"
get_plan_status "$PROJECT_ROOT"
write_statusline_cache "$PROJECT_ROOT"

# Emit PreToolUse deny response with reason, then exit.
deny() {
    local reason="$1"
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "$reason"
  }
}
EOF
    exit 0
}

# --- Concurrency guard: prevent context exhaustion from too many agent forks ---
# Hard deny at 3+ concurrent agents. Prevents the crash scenario where
# implementer + tester + additional dispatch exhaust the context window.
ACTIVE_COUNT=$(ls "$TRACE_STORE"/.active-* 2>/dev/null | wc -l | tr -d ' ')
if [[ "$ACTIVE_COUNT" -ge 3 ]]; then
    deny "Cannot dispatch $AGENT_TYPE: $ACTIVE_COUNT agents already active. Wait for agents to complete before dispatching more."
fi

# --- Gate A: Guardian requires .proof-status = verified (when active) ---
# Gate is only active when .proof-status file exists (created by implementer dispatch).
# Missing file = no implementation in progress = allow (fixes bootstrap deadlock).
if [[ "$AGENT_TYPE" == "guardian" ]]; then
    PROOF_FILE="${CLAUDE_DIR}/.proof-status"
    if [[ -f "$PROOF_FILE" ]]; then
        PROOF_STATUS=$(cut -d'|' -f1 "$PROOF_FILE")
        if [[ "$PROOF_STATUS" != "verified" ]]; then
            deny "Cannot dispatch Guardian: proof-of-work is '$PROOF_STATUS' (requires 'verified'). Dispatch tester or complete verification before dispatching Guardian."
        fi
    fi
    # File missing → no implementation in progress → allow (bootstrap path)
fi

# --- Gate B: Tester requires implementer trace (advisory) ---
# Prevents premature tester dispatch before implementer has returned.
if [[ "$AGENT_TYPE" == "tester" ]]; then
    IMPL_TRACE=$(detect_active_trace "$PROJECT_ROOT" "implementer" 2>/dev/null || echo "")
    if [[ -n "$IMPL_TRACE" ]]; then
        # Active trace means implementer hasn't returned yet
        IMPL_MANIFEST="${TRACE_STORE}/${IMPL_TRACE}/manifest.json"
        IMPL_STATUS=$(jq -r '.status // "unknown"' "$IMPL_MANIFEST" 2>/dev/null || echo "unknown")
        if [[ "$IMPL_STATUS" == "active" ]]; then
            deny "Cannot dispatch tester: implementer trace '$IMPL_TRACE' is still active. Wait for the implementer to return before verifying."
        fi
    fi
fi

# --- Gate C: Implementer dispatch activates proof gate ---
# Creates .proof-status = needs-verification when implementer is dispatched.
# This activates Gate A — Guardian will be blocked until verification completes.
#
# Also writes .active-worktree-path breadcrumb when a linked worktree exists.
# The tester agent runs inside the worktree and writes its proof-status there.
# The breadcrumb lets resolve_proof_file() (in log.sh) find the correct path
# so prompt-submit.sh, check-tester.sh, and guard.sh all operate on the same file.
#
# Gate C.1: Block implementer on main/master (Sacred Practice #2).
# @decision DEC-TASK-GATE-001
# @title Block implementer dispatch on main/master unless worktree exists
# @status accepted
# @rationale Sacred Practice #2 states feature work must happen in worktrees, never on
#   main. Enforcing this at dispatch time prevents agents from accidentally writing
#   source files to main. The gate checks for linked worktrees — if any non-main
#   worktree exists, the orchestrator followed the practice (created worktree first).
#   branch-guard.sh provides primary protection (blocks source edits on main).
#   This gate is defense-in-depth: deny only when NO worktrees exist at all.
if [[ "$AGENT_TYPE" == "implementer" ]]; then
    # Gate C.1: Block implementer on main/master (Sacred Practice #2).
    CURRENT_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
        # Allow if linked worktrees exist — evidence of Sacred Practice #2 compliance.
        # The orchestrator creates the worktree first, then dispatches the implementer.
        # branch-guard.sh provides primary protection against source edits on main.
        WORKTREE_COUNT=$(git -C "$PROJECT_ROOT" worktree list --porcelain 2>/dev/null \
            | grep -c '^worktree ' || echo "0")
        if [[ "$WORKTREE_COUNT" -le 1 ]]; then
            deny "Cannot dispatch implementer on '$CURRENT_BRANCH' branch. Sacred Practice #2: create a worktree first. Use: git worktree add .worktrees/<name> -b feature/<name>"
        fi
    fi

    # Gate C.2: Activate proof gate — creates .proof-status = needs-verification.
    # This activates Gate A, blocking Guardian until verification completes.
    PROOF_FILE="${CLAUDE_DIR}/.proof-status"
    if [[ ! -f "$PROOF_FILE" ]]; then
        mkdir -p "$(dirname "$PROOF_FILE")"
        echo "needs-verification|$(date +%s)" > "$PROOF_FILE"
    fi

    # Write breadcrumb: detect the most recent worktree (excluding main).
    # git worktree list --porcelain outputs blocks separated by blank lines;
    # the first block is always the main worktree. We capture the last
    # non-main worktree path seen in the output.
    ACTIVE_WORKTREE=$(git -C "$PROJECT_ROOT" worktree list --porcelain 2>/dev/null \
        | awk -v main="$PROJECT_ROOT" '/^worktree /{path=$2} path && path != main {last=path} END{print last}' \
        || echo "")
    if [[ -n "$ACTIVE_WORKTREE" && -d "$ACTIVE_WORKTREE" ]]; then
        echo "$ACTIVE_WORKTREE" > "${CLAUDE_DIR}/.active-worktree-path"
        log_info "TASK-TRACK" "Breadcrumb written: active worktree is $ACTIVE_WORKTREE"
    fi
fi

exit 0
