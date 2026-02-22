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
AGENT_TYPE=$(get_field '.tool_input.subagent_type')
AGENT_TYPE="${AGENT_TYPE:-unknown}"

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

# --- Gate A: Guardian requires .proof-status = verified (when active) ---
# Gate is only active when .proof-status file exists (created by implementer dispatch).
# Missing file = no implementation in progress = allow (fixes bootstrap deadlock).
# Checks project-scoped file first, falls back to unscoped for backward compat.
if [[ "$AGENT_TYPE" == "guardian" ]]; then
    _PHASH=$(project_hash "$PROJECT_ROOT")
    SCOPED_PROOF_FILE="${CLAUDE_DIR}/.proof-status-${_PHASH}"
    LEGACY_PROOF_FILE="${CLAUDE_DIR}/.proof-status"
    if [[ -f "$SCOPED_PROOF_FILE" ]]; then
        PROOF_FILE="$SCOPED_PROOF_FILE"
    elif [[ -f "$LEGACY_PROOF_FILE" ]]; then
        PROOF_FILE="$LEGACY_PROOF_FILE"
    else
        PROOF_FILE=""
    fi
    if [[ -n "$PROOF_FILE" && -f "$PROOF_FILE" ]]; then
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
        IMPL_MANIFEST="${TRACE_STORE}/${IMPL_TRACE}/manifest.json"
        IMPL_STATUS=$(jq -r '.status // "unknown"' "$IMPL_MANIFEST" 2>/dev/null || echo "unknown")
        if [[ "$IMPL_STATUS" == "completed" || "$IMPL_STATUS" == "crashed" ]]; then
            # @decision DEC-STALE-MARKER-003
            # @title Clean stale markers when trace already finalized in Gate B
            # @status accepted
            # @rationale When a marker exists but the trace manifest shows completed/crashed,
            #   the marker is stale (finalize_trace's cleanup failed — e.g. timeout race).
            #   The marker was not cleaned by finalize_trace or refinalize_trace yet.
            #   Clean it here and allow tester dispatch rather than falling through to the
            #   5-minute staleness check. This is the fast path: manifest already shows done,
            #   so no refinalize needed — just rm the stale marker and allow dispatch.
            rm -f "${TRACE_STORE}/.active-implementer-"* 2>/dev/null || true
            # Fall through — no deny needed, tester dispatch is allowed
        elif [[ "$IMPL_STATUS" == "active" ]]; then
            # Check staleness before denying — orphaned traces shouldn't block forever
            # @decision DEC-TESTER-GATE-HEAL-001
            # @title Self-healing staleness check in tester dispatch gate
            # @status accepted
            # @rationale Gate B blocks tester dispatch when it detects an active implementer trace.
            #   But if finalize_trace failed (timeout race, crash, session interruption), the trace
            #   stays "active" forever, creating a permanent deadlock. Adding a staleness check (>5min)
            #   with inline refinalize_trace repair unblocks the gate automatically. The 5-min threshold
            #   is chosen to exceed the longest expected implementer hook run while being short enough
            #   to avoid blocking tester dispatch on legitimately stuck traces. Marker cleanup uses
            #   wildcard rm because the marker's session_id suffix may not match the current session.
            #   See DEC-TESTER-GATE-HEAL-002 for why the threshold was reduced from 30 to 5 minutes.
            IMPL_STARTED=$(jq -r '.started_at // empty' "$IMPL_MANIFEST" 2>/dev/null)
            IMPL_START_EPOCH=0
            if [[ -n "$IMPL_STARTED" ]]; then
                IMPL_START_EPOCH=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$IMPL_STARTED" +%s 2>/dev/null \
                    || date -u -d "$IMPL_STARTED" +%s 2>/dev/null \
                    || echo "0")
            fi
            NOW_EPOCH=$(date -u +%s)
            STALE_THRESHOLD=300  # 5 minutes — matches check-implementer.sh timeout (15s) with margin

            if [[ "$IMPL_START_EPOCH" -gt 0 && $(( NOW_EPOCH - IMPL_START_EPOCH )) -gt "$STALE_THRESHOLD" ]]; then
                # Trace is stale — force status to "completed" to unblock tester dispatch.
                # Observatory v2: refinalize_trace() was deleted; status repair is done directly here.
                # @decision DEC-TESTER-GATE-HEAL-002
                # @title Reduce staleness threshold and fix status flip in tester dispatch gate
                # @status accepted
                # @rationale DEC-TESTER-GATE-HEAL-001 added staleness self-heal but used a 30-minute
                #   threshold (too long for 5s hook timeout orphans). Reducing to 5 minutes and forcing
                #   the status flip makes the self-heal actually work. Issues #127, #128.
                #   Observatory v2 (DEC-OBS-V2-002) removed refinalize_trace — status is flipped
                #   directly here since that was the meaningful part of the repair.
                jq '. + {status: "completed"}' "$IMPL_MANIFEST" > "${IMPL_MANIFEST}.tmp" 2>/dev/null \
                    && mv "${IMPL_MANIFEST}.tmp" "$IMPL_MANIFEST" 2>/dev/null || true
                # Clean the marker so future checks don't hit this path
                rm -f "${TRACE_STORE}/.active-implementer-"* 2>/dev/null || true
                # Re-read status after repair
                IMPL_STATUS=$(jq -r '.status // "unknown"' "$IMPL_MANIFEST" 2>/dev/null || echo "unknown")
            fi

            if [[ "$IMPL_STATUS" == "active" ]]; then
                deny "Cannot dispatch tester: implementer trace '$IMPL_TRACE' is still active. Wait for the implementer to return before verifying."
            fi
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

    # Gate C.2: Activate proof gate — creates .proof-status-{phash} = needs-verification.
    # This activates Gate A, blocking Guardian until verification completes.
    # Writes to project-scoped file to prevent cross-project contamination.
    _PHASH=$(project_hash "$PROJECT_ROOT")
    PROOF_FILE="${CLAUDE_DIR}/.proof-status-${_PHASH}"
    if [[ ! -f "$PROOF_FILE" ]]; then
        mkdir -p "$(dirname "$PROOF_FILE")"
        echo "needs-verification|$(date +%s)" > "$PROOF_FILE"
    fi

    # Write breadcrumb: detect the most recent worktree (excluding main).
    # Uses project-scoped file name to prevent cross-project contamination.
    # git worktree list --porcelain outputs blocks separated by blank lines;
    # the first block is always the main worktree. We capture the last
    # non-main worktree path seen in the output.
    ACTIVE_WORKTREE=$(git -C "$PROJECT_ROOT" worktree list --porcelain 2>/dev/null \
        | awk -v main="$PROJECT_ROOT" '/^worktree /{path=$2} path && path != main {last=path} END{print last}' \
        || echo "")
    if [[ -n "$ACTIVE_WORKTREE" && -d "$ACTIVE_WORKTREE" ]]; then
        echo "$ACTIVE_WORKTREE" > "${CLAUDE_DIR}/.active-worktree-path-${_PHASH}"
        log_info "TASK-TRACK" "Breadcrumb written (scoped): active worktree is $ACTIVE_WORKTREE"
    fi
fi

exit 0
