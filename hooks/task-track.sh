#!/usr/bin/env bash
# PreToolUse:Task — track subagent spawns for status bar.
#
# Fires before every Task tool dispatch. Extracts subagent_type
# from tool_input and updates .subagent-tracker + .statusline-cache.
#
# Gate C activates the proof gate at implementer dispatch by writing
# .proof-status-{phash} = needs-verification. The canonical proof-status
# file in CLAUDE_DIR is shared across all worktrees — no breadcrumb needed.
#
# @decision DEC-CACHE-003
# @title Use PreToolUse:Task as SubagentStart replacement
# @status accepted
# @rationale SubagentStart hooks don't fire in Claude Code v2.1.38.
#   PreToolUse:Task demonstrably fires before every Task dispatch.

set -euo pipefail

source "$(dirname "$0")/source-lib.sh"

require_session
require_git
require_plan
require_trace

enable_fail_closed "task-track"

HOOK_INPUT=$(read_input)
AGENT_TYPE=$(get_field '.tool_input.subagent_type')
AGENT_TYPE="${AGENT_TYPE:-unknown}"

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)

# Load domain libraries needed below
require_git
require_plan
require_trace
require_session

# Track spawn and refresh statusline cache
track_subagent_start "$PROJECT_ROOT" "$AGENT_TYPE"
get_git_state "$PROJECT_ROOT"
get_plan_status "$PROJECT_ROOT"
write_statusline_cache "$PROJECT_ROOT"

# In scan mode: emit all gate declarations and exit cleanly.
if [[ "${HOOK_GATE_SCAN:-}" == "1" ]]; then
    declare_gate "guardian-proof-gate" "Guardian requires .proof-status = verified" "deny"
    declare_gate "tester-impl-gate" "Tester requires implementer to have returned" "advisory"
    declare_gate "implementer-worktree-gate" "Implementer must run in linked worktree, not main checkout" "deny"
    emit_flush
    exit 0
fi

# --- Gate A.0: Duplicate guardian detection ---
# Prevents burst dispatch: if another Guardian is already active for this project,
# deny the new dispatch. Fixes RC7 — 5 guardians spawned in 38 seconds.
if [[ "$AGENT_TYPE" == "guardian" ]]; then
    _PHASH_A0=$(project_hash "$PROJECT_ROOT")
    _EXISTING_MARKER=$(find "$TRACE_STORE" -name ".active-guardian-*-${_PHASH_A0}" -newer "$TRACE_STORE" -mmin -10 2>/dev/null | head -1)
    if [[ -n "$_EXISTING_MARKER" ]]; then
        # Check if the marker is within TTL (600s)
        _MARKER_AGE=$(( $(date +%s) - $(stat -f %m "$_EXISTING_MARKER" 2>/dev/null || stat -c %Y "$_EXISTING_MARKER" 2>/dev/null || echo "0") ))
        if [[ "$_MARKER_AGE" -lt 600 ]]; then
            emit_deny "Cannot dispatch Guardian: another Guardian is already active for this project (marker: $(basename "$_EXISTING_MARKER"), age: ${_MARKER_AGE}s). Wait for it to complete or clean stale markers."
        fi
    fi
fi

# --- Gate A: Guardian requires .proof-status = verified (when active) ---
# Gate is only active when .proof-status file exists (created by implementer dispatch).
# Missing file = no implementation in progress = allow (fixes bootstrap deadlock).
# Checks project-scoped file first, falls back to unscoped for backward compat.
declare_gate "guardian-proof-gate" "Guardian requires .proof-status = verified" "deny"
if [[ "$AGENT_TYPE" == "guardian" ]]; then
    _PHASH=$(project_hash "$PROJECT_ROOT")  # keep — needed for guardian marker filename
    PROOF_FILE=$(resolve_proof_file)
    [[ ! -f "$PROOF_FILE" ]] && PROOF_FILE=""
    if [[ -n "$PROOF_FILE" && -f "$PROOF_FILE" ]]; then
        if validate_state_file "$PROOF_FILE" 2; then
            PROOF_STATUS=$(cut -d'|' -f1 "$PROOF_FILE")
        else
            PROOF_STATUS="corrupt"
        fi
        if [[ "$PROOF_STATUS" != "verified" ]]; then
            emit_deny "Cannot dispatch Guardian: proof-of-work is '$PROOF_STATUS' (requires 'verified'). Dispatch tester or complete verification before dispatching Guardian."
        fi
        # Proof is verified — pre-create guardian marker to close dispatch race (Issue #151).
        # track.sh (PostToolUse:Write|Edit) checks .active-guardian-* to skip proof
        # invalidation during Guardian's merge cycle. Without this, any Write/Edit between
        # Gate A pass (PreToolUse:Task) and SubagentStart's init_trace() (which normally
        # creates the marker) fires track.sh which resets proof verified→pending —
        # deadlocking Guardian at guard.sh Check 8.
        # Creating the marker HERE (at dispatch time) closes that race window entirely.
        # init_trace() overwrites with the real trace_id (harmless).
        # finalize_trace() cleans all .active-guardian-* markers regardless of format.
        #
        # @decision DEC-PROOF-RACE-001
        # @title Pre-create guardian marker in task-track.sh to close dispatch race
        # @status accepted
        # @rationale The .active-guardian-* marker was previously only created by
        #   init_trace() in subagent-start.sh — AFTER the agent spawns. Any source
        #   file Write between PreToolUse:Task (Gate A pass) and SubagentStart fires
        #   track.sh, which resets proof verified→pending because no marker exists.
        #   Creating the marker at Gate A time (PreToolUse:Task) closes this window.
        #   init_trace() overwrites with the real trace_id (harmless). finalize_trace()
        #   cleans all markers regardless of format. Fixes #151.
        _SESSION="${CLAUDE_SESSION_ID:-$$}"
        mkdir -p "$TRACE_STORE" 2>/dev/null || true
        # Guardian is taking over — auto-verify protection no longer needed.
        # Clean project-scoped auto-verify markers before creating the guardian marker.
        rm -f "${TRACE_STORE}/.active-autoverify-"*"-${_PHASH}" 2>/dev/null || true
        _GUARDIAN_MARKER="${TRACE_STORE}/.active-guardian-${_SESSION}-${_PHASH}"
        echo "pre-dispatch|$(date +%s)" > "$_GUARDIAN_MARKER"

        # Heartbeat: touch the marker every 60s so the 600s TTL window stays fresh
        # during long Guardian operations (multi-file commit, push, PR creation).
        # Background subshell exits automatically when the marker disappears
        # (finalize_trace removes it) — no zombie process risk.
        #
        # @decision DEC-GUARDIAN-HEARTBEAT-001
        # @title Background heartbeat keeps guardian marker fresh during long operations
        # @status accepted
        # @rationale With TTL extended to 600s (W0-3), a Guardian that takes >10 min
        #   (e.g., large repo push + CI wait) would have its marker expire mid-operation,
        #   allowing post-write.sh to reset proof verified→pending. The heartbeat touches
        #   the marker every 60s, keeping its timestamp fresh. The || break ensures the
        #   loop terminates when finalize_trace() removes the marker.
        #
        # @decision DEC-GUARDIAN-HEARTBEAT-002
        # @title Existence check + 5-min ceiling replaces broken touch-based exit
        # @status accepted
        # @rationale Two bugs: (1) touch creates the file if missing, so the original
        #   `touch ... || break` never fires — finalize_trace removes the marker, touch
        #   recreates it, heartbeat runs forever. Fix: `[[ -f marker ]] || break` checks
        #   existence without side effects. (2) When guardian agents fail to start (API
        #   rate limit), SubagentStop never fires, marker is never removed. Found 26
        #   orphaned heartbeats. Fix: 5-iteration ceiling (5 × 60s = 5 min) — extended
        #   from 3 to 5 to accommodate Guardian max_turns=35 long operations (CHANGELOG
        #   update on feature branch, push with CI, worktree cleanup). Both exit paths
        #   are verified by e2e test.
        # FD inheritance fix: redirect stdout/stderr to /dev/null before backgrounding.
        # Without this, $() command substitution in test harnesses inherits the pipe's
        # write-end FDs through the background subshell, causing the substitution to block
        # until the heartbeat exits (5 min). The heartbeat produces no output — this is
        # purely to sever FD inheritance. See test-proof-gate.sh Test 5 timing assertion.
        # @decision DEC-GUARDIAN-HEARTBEAT-002
        ( _hb_count=0; while sleep 60; do _hb_count=$((_hb_count+1)); [[ $_hb_count -ge 5 ]] && break; [[ -f "$_GUARDIAN_MARKER" ]] || break; touch "$_GUARDIAN_MARKER"; done ) >/dev/null 2>&1 &
    fi
    # File missing → no implementation in progress → allow (bootstrap path)
fi

# --- Gate B: Tester requires implementer trace (advisory) ---
# Prevents premature tester dispatch before implementer has returned.
# Exception: CYCLE_MODE: auto-flow allows the implementer to dispatch the tester
# as a sub-agent while the implementer trace is still active (nested dispatch pattern).
#
# @decision DEC-GATE-B-AUTOFLOW-001
# @title Gate B allows tester dispatch in auto-flow (nested dispatch pattern)
# @status accepted
# @rationale When CYCLE_MODE: auto-flow is set, the implementer dispatches the tester
#   as a sub-agent after its tests pass. At that moment, the implementer trace is still
#   active — Gate B would deny the tester dispatch without this bypass. The bypass is
#   scoped to the dispatch prompt: only tester dispatches that carry the auto-flow flag
#   are allowed through while an implementer trace is active. All other tester dispatches
#   remain subject to the normal Gate B enforcement (implementer must have returned first).
declare_gate "tester-impl-gate" "Tester requires implementer to have returned" "advisory"
if [[ "$AGENT_TYPE" == "tester" ]]; then
    # Gate B bypass: auto-flow allows implementer to dispatch tester as sub-agent
    _PROMPT_TEXT=$(get_field '.tool_input.prompt' 2>/dev/null || echo "")
    if echo "$_PROMPT_TEXT" | grep -q 'CYCLE_MODE: auto-flow'; then
        log_info "GATE-B" "auto-flow bypass: allowing tester dispatch from active implementer (nested dispatch)"
        # Fall through — don't check implementer trace, allow dispatch
    else
    _PHASH=$(project_hash "$PROJECT_ROOT")
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
            #   Scoped to current project's phash to avoid deleting other projects' markers.
            rm -f "${TRACE_STORE}/.active-implementer-"*"-${_PHASH}" 2>/dev/null || true
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
                # Clean the marker so future checks don't hit this path.
                # Scoped to current project's phash to avoid deleting other projects' markers.
                rm -f "${TRACE_STORE}/.active-implementer-"*"-${_PHASH}" 2>/dev/null || true
                # Re-read status after repair
                IMPL_STATUS=$(jq -r '.status // "unknown"' "$IMPL_MANIFEST" 2>/dev/null || echo "unknown")
            fi

            if [[ "$IMPL_STATUS" == "active" ]]; then
                emit_deny "Cannot dispatch tester: implementer trace '$IMPL_TRACE' is still active. Wait for the implementer to return before verifying."
            fi
        fi
    fi

    fi  # end: else branch of auto-flow bypass

    # NOTE: tester trace initialization removed (DEC-AV-DUAL-002).
    # SubagentStart fires reliably for testers and creates the authoritative trace.
    # task-track.sh's init_trace created a competing trace with the orchestrator's
    # session_id, but the tester writes summary.md to the SubagentStart trace
    # (different session_id). This caused post-task.sh to find the wrong trace.
    # The active marker is now created by subagent-start.sh's init_trace.
    # If SubagentStart stops firing in the future, re-enable this block.
    # See also: DEC-AV-RACE-001 (session-based fallback in post-task.sh)
    # and DEC-AV-DUAL-001 (project-scoped summary scan as final fallback).
    #
    # @decision DEC-AV-DUAL-002
    # @title Remove duplicate tester trace init from task-track.sh
    # @status accepted
    # @rationale SubagentStart fires reliably for testers (proven by e2e evidence)
    #   and initializes the authoritative trace with the subagent's session_id.
    #   task-track.sh was creating a competing trace with the orchestrator's session_id,
    #   causing post-task.sh to find the wrong trace (no summary.md). Removing the
    #   duplicate eliminates the confusion. The DEC-AV-DUAL-001 project-scoped scan
    #   in post-task.sh provides resilience if SubagentStart regresses.
    #
    # DISABLED: TESTER_TRACE_ID=$(init_trace "$PROJECT_ROOT" "tester" 2>/dev/null || echo "")
    # DISABLED: if [[ -n "$TESTER_TRACE_ID" ]]; then
    # DISABLED:     log_info "TASK-TRACK" "initialized tester trace=${TESTER_TRACE_ID}"
    # DISABLED: fi
fi

# --- Gate C: Implementer dispatch activates proof gate ---
# Creates .proof-status-{phash} = needs-verification when implementer is dispatched.
# This activates Gate A — Guardian will be blocked until verification completes.
#
# The canonical proof-status file lives in CLAUDE_DIR which is shared across all
# worktrees, so prompt-submit.sh, check-tester.sh, and guard.sh all read/write
# the same file regardless of which worktree the agent runs in.
#
# Gate C.1: Implementer must run in a linked worktree, not the main checkout.
# @decision DEC-TASK-GATE-001
# @title Block implementer dispatch on main/master unless worktree exists
# @status superseded
# @rationale Superseded by DEC-GATE-C1-002 which checks worktree identity
#   instead of branch name. The original gate only fired on main/master,
#   allowing bypass when the orchestrator was on a feature branch.
declare_gate "implementer-worktree-gate" "Implementer must run in linked worktree, not main checkout" "deny"
if [[ "$AGENT_TYPE" == "implementer" ]]; then
    # Gate C.1: Implementer must run in a linked worktree, not the main checkout.
    # Previous version only checked branch name (main/master), allowing bypass on
    # feature branches checked out in the main worktree. This version checks whether
    # we're in the main worktree itself (first entry in `git worktree list`).
    #
    # @decision DEC-GATE-C1-002
    # @title Expand Gate C.1 to enforce worktree isolation on all branches
    # @status accepted
    # @rationale The original Gate C.1 only fired when CURRENT_BRANCH was main/master.
    #   When the orchestrator was on a feature branch (e.g., feature/metanoia-deploy),
    #   the gate was completely bypassed — agents worked directly on the feature branch
    #   without worktree isolation. This caused monolithic commits and prevented parallel
    #   development. The fix checks the worktree identity (main vs linked) instead of the
    #   branch name. Implementer dispatched from a linked worktree passes. Implementer
    #   dispatched from the main worktree requires at least one linked worktree to exist.
    # Guard: git commands require a git repo. Non-git projects can't have worktrees.
    if ! git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree &>/dev/null; then
        emit_deny "Cannot dispatch implementer: '$PROJECT_ROOT' is not a git repository. Initialize with: git init"
    fi
    MAIN_WT=$(git -C "$PROJECT_ROOT" worktree list --porcelain 2>/dev/null \
        | awk '/^worktree /{print $2; exit}') || MAIN_WT=""
    CURRENT_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    # Resolve symlinks for comparison (macOS: /var → /private/var)
    RESOLVED_ROOT=$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P)
    RESOLVED_MAIN_WT=$(cd "$MAIN_WT" 2>/dev/null && pwd -P || echo "")
    RESOLVED_PWD=$(pwd -P 2>/dev/null || echo "$PWD")
    if [[ -n "$RESOLVED_MAIN_WT" && ( "$RESOLVED_ROOT" == "$RESOLVED_MAIN_WT" || "$RESOLVED_PWD" == "$RESOLVED_MAIN_WT"* ) ]]; then
        # We're in the main worktree — implementer must use isolation
        WORKTREE_COUNT=$(git -C "$PROJECT_ROOT" worktree list --porcelain 2>/dev/null \
            | grep -c '^worktree ' || echo "0")
        if [[ "$WORKTREE_COUNT" -le 1 ]]; then
            emit_deny "Cannot dispatch implementer from main worktree (branch: '$CURRENT_BRANCH'). Sacred Practice #2: create a worktree first. Use: git worktree add .worktrees/<name> -b feature/<name>"
        fi
    fi

    # Gate C.2: Activate proof gate — creates .proof-status-{phash} = needs-verification.
    # This activates Gate A, blocking Guardian until verification completes.
    # Writes to project-scoped file to prevent cross-project contamination.
    _PHASH=$(project_hash "$PROJECT_ROOT")
    PROOF_FILE="${CLAUDE_DIR}/.proof-status-${_PHASH}"
    if [[ ! -f "$PROOF_FILE" ]]; then
        write_proof_status "needs-verification" "$PROJECT_ROOT"
    fi
fi

emit_flush
exit 0
