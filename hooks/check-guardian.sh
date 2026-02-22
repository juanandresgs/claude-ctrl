#!/usr/bin/env bash
# check-guardian.sh — SubagentStop:guardian hook
#
# Purpose: Deterministic post-guardian validation. Checks MASTER_PLAN.md recency,
# git cleanliness, test status, and approval-loop state after each guardian run.
# Cleans up .proof-status after a successful commit to reset the verification cycle.
# Advisory only (exit 0 always). Reports findings via additionalContext.
#
# Hook type: SubagentStop
# Trigger: After any Task tool invocation that ran the guardian agent
# Input: JSON on stdin with agent response text
# Output: JSON { "additionalContext": "..." } with validation findings
#
# @decision DEC-GUARDIAN-001
# @title Deterministic guardian validation replacing AI agent hook
# @status accepted
# @rationale AI agent hooks have non-deterministic runtime and cascade risk.
# File stat + git status complete in <1s with zero cascade risk. Post-commit
# .proof-status cleanup (Phase B) ensures the verification gate resets cleanly
# for the next implementation cycle, preventing stale "verified" state from
# bypassing the proof gate on subsequent tasks.

set -euo pipefail

source "$(dirname "$0")/source-lib.sh"

# Capture stdin (contains agent response)
AGENT_RESPONSE=$(read_input 2>/dev/null || echo "{}")

# Diagnostic: log SubagentStop payload keys for field-name investigation (Issue #TBD)
if [[ -n "$AGENT_RESPONSE" && "$AGENT_RESPONSE" != "{}" ]]; then
    PAYLOAD_KEYS=$(echo "$AGENT_RESPONSE" | jq -r 'keys[]' 2>/dev/null | tr '\n' ',' || echo "unknown")
    PAYLOAD_SIZE=${#AGENT_RESPONSE}
    echo "check-guardian: SubagentStop payload keys=[$PAYLOAD_KEYS] size=${PAYLOAD_SIZE}" >&2
fi

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)
PLAN="$PROJECT_ROOT/MASTER_PLAN.md"

# Track subagent completion
track_subagent_stop "$PROJECT_ROOT" "guardian"
append_session_event "agent_stop" "{\"type\":\"guardian\"}" "$PROJECT_ROOT"

# --- W3-1: Emit `commit` event if Guardian advanced HEAD ---
# subagent-start.sh saves HEAD SHA when Guardian is spawned.
# We compare here (after Guardian ran) to detect whether a commit occurred.
# This is more reliable than parsing response text for commit keywords.
START_SHA_FILE="${CLAUDE_DIR}/.guardian-start-sha"
if [[ -f "$START_SHA_FILE" ]]; then
    START_SHA=$(cat "$START_SHA_FILE" 2>/dev/null || echo "")
    CURRENT_SHA=$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "")
    if [[ -n "$START_SHA" && -n "$CURRENT_SHA" && "$START_SHA" != "$CURRENT_SHA" ]]; then
        LAST_MSG=$(git -C "$PROJECT_ROOT" log -1 --format=%s 2>/dev/null || echo "")
        append_session_event "commit" \
            "$(jq -cn --arg sha "$CURRENT_SHA" --arg msg "$LAST_MSG" '{sha:$sha,message:$msg}')" \
            "$PROJECT_ROOT"
        log_info "CHECK-GUARDIAN" "Emitted commit event: sha=${CURRENT_SHA:0:8} msg=$LAST_MSG"
    fi
    rm -f "$START_SHA_FILE"
fi

# Extract agent's response text early (needed for summary.md fallback and advisory checks below).
# Field name confirmed from Claude Code docs: SubagentStop payload uses `last_assistant_message`.
# `.response` kept as fallback for backward compatibility with any non-standard payloads.
RESPONSE_TEXT=$(echo "$AGENT_RESPONSE" | jq -r '.last_assistant_message // .response // empty' 2>/dev/null || echo "")

# --- Trace protocol: finalize BEFORE advisory checks to beat 5s timeout ---
# @decision DEC-STALE-MARKER-001
# @title Order finalize_trace before advisory checks to prevent stale .active-* markers
# @status accepted
# @rationale The 5s SubagentStop hook timeout means any code after the budget is consumed
#   is silently skipped. If get_git_state, get_plan_status, and ~150 lines of advisory
#   checks run before finalize_trace, the .active-guardian-* marker is never removed on
#   timeout. Stale markers from previous guardian runs can interfere with future dispatch.
#   Fix: detect trace, write summary.md fallback (which finalize_trace depends on), call
#   finalize_trace, THEN run advisory checks. Auto-capture (commit-info.txt) stays after
#   finalize_trace since it's best-effort artifact enrichment, not marker cleanup.
TRACE_ID=$(detect_active_trace "$PROJECT_ROOT" "guardian" 2>/dev/null || echo "")
TRACE_DIR=""
if [[ -n "$TRACE_ID" ]]; then
    TRACE_DIR="${TRACE_STORE}/${TRACE_ID}"
fi

if [[ -n "$TRACE_ID" ]]; then
    # Fallback: if agent didn't write summary.md or wrote a near-empty file (e.g. 1-byte \n),
    # save response excerpt or a diagnostic message.
    # Must run before finalize_trace — finalize reads summary.md to determine crashed vs completed.
    # Using 10-byte minimum instead of -s (size>0) — see DEC-GUARDIAN-STOP-001 below.
    #
    # @decision DEC-GUARDIAN-STOP-001
    # @title Use 10-byte minimum threshold for guardian summary.md fallback check
    # @status accepted
    # @rationale Same root cause as DEC-IMPL-STOP-003: the -s check (size > 0) passes for
    #   a 1-byte newline written when RESPONSE_TEXT is empty (max_turns exhausted or
    #   force-stopped). The 10-byte threshold catches both missing and trivially empty
    #   summary files. When RESPONSE_TEXT is empty, a diagnostic message is written
    #   instead so the orchestrator has context about why the guardian stopped without
    #   completing its commit/merge cycle.
    _sum_size=$(wc -c < "$TRACE_DIR/summary.md" 2>/dev/null || echo 0)
    if [[ ! -f "$TRACE_DIR/summary.md" ]] || [[ "$_sum_size" -lt 10 ]]; then
        if [[ -z "${RESPONSE_TEXT// /}" ]]; then
            {
                echo "# Agent returned empty response ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
                echo "Agent type: guardian"
                echo "Duration: ${SECONDS:-unknown}s"
                echo "Likely cause: max_turns exhausted or force-stopped"
            } > "$TRACE_DIR/summary.md" 2>/dev/null || true
        else
            echo "$RESPONSE_TEXT" | head -c 4000 > "$TRACE_DIR/summary.md" 2>/dev/null || true
        fi
    fi

    # finalize_trace MUST run before advisory checks (get_git_state etc.) to prevent stale markers.
    # See DEC-STALE-MARKER-001: advisory checks can consume the 5s budget before this runs.
    finalize_trace "$TRACE_ID" "$PROJECT_ROOT" "guardian" || true
fi

get_git_state "$PROJECT_ROOT"
get_plan_status "$PROJECT_ROOT"
write_statusline_cache "$PROJECT_ROOT"

ISSUES=()

# Detect plan completion state from actual plan content (not fragile response text matching)
get_plan_status "$PROJECT_ROOT"

# Detect if this was a phase-completing merge by looking for phase-completion language
IS_PHASE_COMPLETING=""
if [[ -n "$RESPONSE_TEXT" ]]; then
    IS_PHASE_COMPLETING=$(echo "$RESPONSE_TEXT" | grep -iE 'phase.*(complete|done|finished)|marking phase.*completed|status.*completed|phase completion' || echo "")
fi

# Content-based: detect dormant plan (all initiatives completed) or specific initiative completion.
# Living-document format: PLAN_LIFECYCLE=dormant means all initiatives are completed.
# Legacy format: PLAN_LIFECYCLE=dormant (was "completed") means all phases done.
if [[ "$PLAN_LIFECYCLE" == "dormant" ]]; then
    ISSUES+=("All initiatives are completed — plan is dormant. Start a new initiative before implementing, or compress a completed initiative with compress_initiative().")
elif [[ "$PLAN_LIFECYCLE" == "completed" ]]; then
    # Legacy format backward compat
    ISSUES+=("All plan phases completed ($PLAN_COMPLETED_PHASES/$PLAN_TOTAL_PHASES) — plan should be archived or a new initiative started.")
fi

# Check for initiative completion: detect when response mentions completing a specific initiative.
# Suggest compress_initiative() when appropriate.
if [[ -n "$RESPONSE_TEXT" ]]; then
    HAS_INITIATIVE_COMPLETE=$(echo "$RESPONSE_TEXT" | grep -iE 'initiative.*(complete|done|finished)|all phases.*initiative.*done|initiative.*all phases' || echo "")
    if [[ -n "$HAS_INITIATIVE_COMPLETE" && -f "$PLAN" ]]; then
        # Extract active initiative names for context
        ACTIVE_NAMES=$(grep -E '^\#\#\#\s+Initiative:' "$PLAN" 2>/dev/null | \
            while IFS= read -r hdr; do
                name=$(echo "$hdr" | sed 's/^###\s*Initiative:\s*//')
                # Check if this initiative has status: active in the next few lines
                echo "$name"
            done | head -3 | paste -sd', ' - || echo "")
        if [[ -n "$ACTIVE_NAMES" ]]; then
            ISSUES+=("Initiative completion detected. Run compress_initiative('<name>') to move it to Completed Initiatives in MASTER_PLAN.md.")
        fi
    fi
fi

# Check 1: MASTER_PLAN.md freshness — only for phase-completing merges
if [[ -n "$IS_PHASE_COMPLETING" ]]; then
    if [[ -f "$PLAN" ]]; then
        # Get modification time in epoch seconds
        if [[ "$(uname)" == "Darwin" ]]; then
            MOD_TIME=$(stat -f %m "$PLAN" 2>/dev/null || echo "0")
        else
            MOD_TIME=$(stat -c %Y "$PLAN" 2>/dev/null || echo "0")
        fi
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
if [[ -n "$RESPONSE_TEXT" ]]; then
    # Check if response ends with an approval question
    HAS_APPROVAL_QUESTION=$(echo "$RESPONSE_TEXT" | grep -iE 'do you (approve|confirm|want me to proceed)|shall I (proceed|continue|merge)|ready to (merge|commit|proceed)\?' || echo "")
    # Check if response also contains execution confirmation
    HAS_EXECUTION=$(echo "$RESPONSE_TEXT" | grep -iE 'executing|done|merged|committed|completed|pushed|created branch|worktree created' || echo "")

    if [[ -n "$HAS_APPROVAL_QUESTION" && -z "$HAS_EXECUTION" ]]; then
        ISSUES+=("Agent ended with approval question but no execution confirmation — may need follow-up")
    fi
fi

# Check 5: Test status for git operations
if read_test_status "$PROJECT_ROOT"; then
    if [[ "$TEST_RESULT" == "fail" && "$TEST_AGE" -lt 1800 ]]; then
        HAS_GIT_OP=$(echo "$RESPONSE_TEXT" | grep -iE 'merged|committed|git merge|git commit' || echo "")
        if [[ -n "$HAS_GIT_OP" ]]; then
            ISSUES+=("CRITICAL: Tests failing ($TEST_FAILS) when git operations were performed")
        else
            ISSUES+=("Tests failing ($TEST_FAILS failures) — address before next git operation")
        fi
    fi
else
    ISSUES+=("No test results found — verify tests were run before committing")
fi

# Check 6: CHANGELOG.md merge advisory
# On merge to main/master, note if CHANGELOG.md was not updated.
# Advisory only — never blocks. guardian.md instructs Guardian to update CHANGELOG.
if [[ -n "$RESPONSE_TEXT" ]]; then
    HAS_MERGE_OP=$(echo "$RESPONSE_TEXT" | grep -iE 'merged|git merge|merge.*complete|merge.*main|merge.*master' || echo "")
    if [[ -n "$HAS_MERGE_OP" ]]; then
        CURRENT_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
        if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
            # Check if the merge diff includes CHANGELOG.md
            MERGE_HEAD_FILE=$(git -C "$PROJECT_ROOT" rev-parse --absolute-git-dir 2>/dev/null)/ORIG_HEAD
            if [[ -f "$MERGE_HEAD_FILE" ]]; then
                ORIG_HEAD=$(cat "$MERGE_HEAD_FILE" 2>/dev/null || echo "")
                if [[ -n "$ORIG_HEAD" ]]; then
                    CHANGELOG_IN_MERGE=$(git -C "$PROJECT_ROOT" diff --name-only "${ORIG_HEAD}" HEAD 2>/dev/null | grep -c '^CHANGELOG\.md$' || echo "0")
                    if [[ "$CHANGELOG_IN_MERGE" -eq 0 ]]; then
                        ISSUES+=("Advisory: CHANGELOG.md not updated in this merge — consider adding a changelog entry for the merged feature")
                    fi
                fi
            fi
        fi
    fi
fi

# Check 7: CWD staleness advisory + canary write after worktree cleanup
# When Guardian removes a worktree, the orchestrator's Bash CWD may now point to
# a deleted directory. guard.sh Check 0.5 auto-recovers on the next command.
# We also write a canary so Path B recovery triggers even when .cwd is absent
# from the hook input (which is the common case — framework CWD is always valid).
if [[ -n "$RESPONSE_TEXT" ]]; then
    HAS_WORKTREE_CLEANUP=$(echo "$RESPONSE_TEXT" | grep -iE 'worktree.*remov|removed worktree|git worktree remove|cleaned up worktree' || echo "")
    if [[ -n "$HAS_WORKTREE_CLEANUP" ]]; then
        ISSUES+=("Guardian removed a worktree. CWD recovery canary written if path confirmed deleted.")
        # Read .active-worktree-path breadcrumb written by task-track.sh at implementer dispatch.
        # If that path is now gone, write the canary for Check 0.5 Path B.
        BREADCRUMB="${CLAUDE_DIR}/.active-worktree-path"
        if [[ -f "$BREADCRUMB" ]]; then
            DELETED_WT=$(head -1 "$BREADCRUMB" 2>/dev/null | tr -d '[:space:]' || echo "")
            if [[ -n "$DELETED_WT" && ! -d "$DELETED_WT" ]]; then
                echo "$DELETED_WT" > "$HOME/.claude/.cwd-recovery-needed" 2>/dev/null || true
                log_info "CHECK-GUARDIAN" "CWD canary written for deleted worktree: $DELETED_WT"
            fi
        fi
    fi
fi

# --- Trace protocol: auto-capture commit-info.txt (best-effort, runs after finalize) ---
# finalize_trace already ran above (before advisory checks). This block enriches
# the trace artifacts retrospectively — it does NOT affect marker cleanup.
if [[ -n "$TRACE_ID" && -d "$TRACE_DIR/artifacts" ]]; then
    # --- Observatory Phase 1: Snapshot pre-capture artifact existence ---
    # @decision DEC-OBS-V2-001
    # @title Snapshot artifact existence before auto-capture for compliance attribution
    # @status accepted
    # @rationale The observatory needs to know whether agents wrote artifacts themselves
    #   or whether the check hook had to reconstruct them. Snapshotting before auto-capture
    #   is the only reliable way to make this distinction.
    GUARDIAN_PRE_SUMMARY=false
    GUARDIAN_PRE_COMMIT_INFO=false
    [[ -f "$TRACE_DIR/summary.md" ]] && GUARDIAN_PRE_SUMMARY=true
    [[ -f "$TRACE_DIR/artifacts/commit-info.txt" ]] && GUARDIAN_PRE_COMMIT_INFO=true

    # Auto-capture commit-info.txt: last commit subject + diff stat.
    # Provides concrete evidence of what the guardian committed without requiring
    # the agent to explicitly write an artifact. Uses || true — git may fail on
    # non-git roots or when HEAD~1 doesn't exist (first commit).
    {
        git -C "$PROJECT_ROOT" log --oneline -1 2>/dev/null || true
        git -C "$PROJECT_ROOT" diff --stat HEAD~1..HEAD 2>/dev/null || true
    } > "$TRACE_DIR/artifacts/commit-info.txt" 2>/dev/null || true

    # --- Observatory Phase 1: Write compliance.json after auto-capture ---
    _gd_sm_present=false; _gd_sm_source="null"
    _gd_ci_present=false; _gd_ci_source="null"

    [[ -f "$TRACE_DIR/summary.md" ]] && _gd_sm_present=true
    [[ -f "$TRACE_DIR/artifacts/commit-info.txt" ]] && _gd_ci_present=true

    $_gd_sm_present && { $GUARDIAN_PRE_SUMMARY && _gd_sm_source='"agent"' || _gd_sm_source='"auto-capture"'; }
    $_gd_ci_present && { $GUARDIAN_PRE_COMMIT_INFO && _gd_ci_source='"agent"' || _gd_ci_source='"auto-capture"'; }

    cat > "$TRACE_DIR/compliance.json" << COMPLIANCE_GUARDIAN_EOF
{
  "agent_type": "guardian",
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "artifacts": {
    "summary.md": {"present": $_gd_sm_present, "source": $_gd_sm_source},
    "commit-info.txt": {"present": $_gd_ci_present, "source": $_gd_ci_source}
  },
  "test_result": "not-provided",
  "test_result_source": null,
  "issues_count": 0
}
COMPLIANCE_GUARDIAN_EOF
fi

# Response size advisory
if [[ -n "$RESPONSE_TEXT" ]]; then
    WORD_COUNT=$(echo "$RESPONSE_TEXT" | wc -w | tr -d ' ')
    if [[ "$WORD_COUNT" -gt 1200 ]]; then
        ISSUES+=("Agent response too large (~${WORD_COUNT} words). Use TRACE_DIR for verbose output.")
    fi
fi

# --- Post-commit .proof-status cleanup ---
# When Guardian successfully committed, the verification cycle is complete.
# Clean .proof-status so it doesn't interfere with the next implementation cycle.
# This prevents stale "verified" state from bypassing the proof gate on the next task.
#
# Worktree cleanup: also remove the worktree's .proof-status and the
# .active-worktree-path breadcrumb so future implementer dispatches start clean.
if [[ -n "$RESPONSE_TEXT" ]]; then
    HAS_COMMIT=$(echo "$RESPONSE_TEXT" | grep -iE 'committed|commit.*successful|pushed|merge.*complete' || echo "")
    if [[ -n "$HAS_COMMIT" ]]; then
        # Clean both scoped and legacy proof-status files after successful commit.
        # @decision DEC-ISOLATION-006
        # @title check-guardian cleans both scoped and legacy proof-status files
        # @status accepted
        # @rationale The scoped file (.proof-status-{phash}) is the primary write target
        #   since DEC-ISOLATION-001. The legacy file (.proof-status) may exist from
        #   pre-migration sessions or dual-writes. Cleaning both ensures the gate is
        #   fully reset for the next implementation cycle regardless of file format.
        _PHASH=$(project_hash "$PROJECT_ROOT")
        SCOPED_PROOF="${CLAUDE_DIR}/.proof-status-${_PHASH}"
        LEGACY_PROOF="${CLAUDE_DIR}/.proof-status"
        for PROOF_FILE in "$SCOPED_PROOF" "$LEGACY_PROOF"; do
            if [[ -f "$PROOF_FILE" ]]; then
                PROOF_VAL=$(cut -d'|' -f1 "$PROOF_FILE" 2>/dev/null || echo "")
                if [[ "$PROOF_VAL" == "verified" ]]; then
                    rm -f "$PROOF_FILE"
                    log_info "CHECK-GUARDIAN" "Cleaned $(basename "$PROOF_FILE") after successful commit"
                fi
            fi
        done

        # Check 7b: Post-merge worktree directory verification
        # If the breadcrumb exists AND directory still exists after merge, attempt cleanup.
        # This runs BEFORE the breadcrumb cleanup below so the breadcrumb is still readable.
        # Check scoped breadcrumb first, then legacy.
        BREADCRUMB_7B="${CLAUDE_DIR}/.active-worktree-path-${_PHASH}"
        [[ -f "$BREADCRUMB_7B" ]] || BREADCRUMB_7B="${CLAUDE_DIR}/.active-worktree-path"
        if [[ -f "$BREADCRUMB_7B" ]]; then
            WT_PATH_7B=$(cat "$BREADCRUMB_7B" 2>/dev/null | tr -d '[:space:]')
            if [[ -n "$WT_PATH_7B" && -d "$WT_PATH_7B" ]]; then
                # Check for uncommitted changes before attempting cleanup
                WT_DIRTY=$(git -C "$WT_PATH_7B" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
                if [[ "$WT_DIRTY" -gt 0 ]]; then
                    ISSUES+=("WARN: Worktree $WT_PATH_7B still exists with $WT_DIRTY uncommitted change(s) — manual cleanup needed")
                else
                    # Safe to auto-clean husks via sweep --auto
                    ROSTER_SCRIPT="$HOME/.claude/scripts/worktree-roster.sh"
                    if [[ -x "$ROSTER_SCRIPT" ]]; then
                        SWEEP_OUTPUT=$(WORKTREE_DIR="$(dirname "$WT_PATH_7B")" "$ROSTER_SCRIPT" sweep --auto 2>&1 || true)
                        if [[ -n "$SWEEP_OUTPUT" ]]; then
                            ISSUES+=("Post-merge cleanup: $SWEEP_OUTPUT")
                        fi
                    fi
                fi
            fi
        fi

        # Clean up all breadcrumb variants (scoped and legacy) and their worktree .proof-status
        for BREADCRUMB in "${CLAUDE_DIR}/.active-worktree-path-${_PHASH}" "${CLAUDE_DIR}/.active-worktree-path"; do
            if [[ -f "$BREADCRUMB" ]]; then
                WORKTREE_PATH=$(cat "$BREADCRUMB" 2>/dev/null | tr -d '[:space:]')
                if [[ -n "$WORKTREE_PATH" && -d "$WORKTREE_PATH" ]]; then
                    rm -f "${WORKTREE_PATH}/.claude/.proof-status"
                    log_info "CHECK-GUARDIAN" "Cleaned worktree .proof-status at $WORKTREE_PATH"
                fi
                rm -f "$BREADCRUMB"
                log_info "CHECK-GUARDIAN" "Cleaned breadcrumb: $(basename "$BREADCRUMB")"
            fi
        done
    fi
fi

# --- Post-guardian health check directive ---
# Suggest /diagnose when no other agents are active (prevents concurrent dispatch crash).
# Advisory only — injected into ISSUES array, orchestrator decides whether to invoke.
ACTIVE_MARKERS=$(ls "$TRACE_STORE"/.active-* 2>/dev/null | wc -l | tr -d ' ')
if [[ "$ACTIVE_MARKERS" -eq 0 ]]; then
    ISSUES+=("SUGGESTED ACTION: Run /diagnose to verify system health after guardian operation")
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

# Persist findings for next-prompt injection
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    FINDINGS_FILE="${CLAUDE_DIR}/.agent-findings"
    mkdir -p "${PROJECT_ROOT}/.claude"
    FINDING="guardian|$(IFS=';'; echo "${ISSUES[*]}")"
    if ! grep -qxF "$FINDING" "$FINDINGS_FILE" 2>/dev/null; then
        echo "$FINDING" >> "$FINDINGS_FILE"
    fi
    for issue in "${ISSUES[@]}"; do
        append_audit "$PROJECT_ROOT" "agent_guardian" "$issue"
    done
fi

# Output as additionalContext
ESCAPED=$(echo -e "$CONTEXT" | jq -Rs .)
cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF

exit 0
