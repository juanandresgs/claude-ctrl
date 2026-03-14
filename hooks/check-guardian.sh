#!/usr/bin/env bash
# check-guardian.sh — SubagentStop:guardian hook
#
# Purpose: Deterministic post-guardian validation. Checks MASTER_PLAN.md recency,
# git cleanliness, test status, and approval-loop state after each guardian run.
# Cleans up the canonical .proof-status-{phash} after a successful commit to reset
# the verification cycle. Advisory only (exit 0 always). Reports findings via additionalContext.
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

require_session
require_trace
require_git
require_plan
require_ci

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

# Track subagent completion and tokens
track_subagent_stop "$PROJECT_ROOT" "guardian"
track_agent_tokens "$AGENT_RESPONSE"
append_session_event "agent_stop" "{\"type\":\"guardian\"}" "$PROJECT_ROOT"
rm -f "${CLAUDE_DIR}/.agent-progress"

# W6-1: Emit governor.assessment event into SQLite event ledger.
# Governor is parked (DEC-PERF-006) but events are retained for future restoration.
# Guardians are major lifecycle milestones (merge/commit) — high-value signals.
# Best-effort: must never break the hook.
# require_state loads state-lib.sh (state_emit, workflow_id) before the emit.
require_state 2>/dev/null || true
_CG_WF_GOV=$(workflow_id 2>/dev/null || echo "main")
_CG_BRANCH_GOV=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
state_emit "governor.assessment" "{\"type\":\"merge_complete\",\"branch\":\"${_CG_BRANCH_GOV}\",\"workflow\":\"${_CG_WF_GOV}\"}" >/dev/null 2>/dev/null || true

# --- W3-1: Emit `commit` event if Guardian advanced HEAD ---
# subagent-start.sh saves HEAD SHA when Guardian is spawned.
# We compare here (after Guardian ran) to detect whether a commit occurred.
# This is more reliable than parsing response text for commit keywords.
_PHASH_CGS=$(project_hash "$PROJECT_ROOT")
START_SHA_FILE="${CLAUDE_DIR}/state/${_PHASH_CGS}/guardian-start-sha"
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
    rm -f "${CLAUDE_DIR}/state/${_PHASH_CGS}/guardian-start-sha"
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

    # @decision DEC-COMPLIANCE-INIT-001
    # @title Initialize compliance.json before finalize_trace to prevent read-before-write
    # @status accepted
    # @rationale finalize_trace() reads compliance.json to obtain test_result and
    #   files_changed. In check-guardian.sh, compliance.json is written AFTER
    #   finalize_trace (post-commit artifact capture). Without initialization, finalize
    #   reads a missing file and defaults to "not-provided"/0 — but more critically,
    #   if a previous stale compliance.json exists from a prior trace sharing the same
    #   directory, finalize reads wrong data. Writing a default before finalize ensures
    #   the file always has valid guardian-appropriate defaults (no test_result since
    #   guardians don't run tests). The commit-info.txt capture block updates the file
    #   after finalize with richer artifact data via a second compliance.json write.
    if [[ -d "$TRACE_DIR/artifacts" ]]; then
        _gd_sm_present=false
        [[ -f "$TRACE_DIR/summary.md" ]] && _gd_sm_present=true
        cat > "$TRACE_DIR/compliance.json" << COMPLIANCE_GUARDIAN_INIT_EOF
{
  "agent_type": "guardian",
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "artifacts": {
    "summary.md": {"present": $_gd_sm_present, "source": "agent"},
    "commit-info.txt": {"present": false, "source": null}
  },
  "test_result": "not-provided",
  "test_result_source": null,
  "issues_count": 0
}
COMPLIANCE_GUARDIAN_INIT_EOF
    fi

    # finalize_trace MUST run before advisory checks (get_git_state etc.) to prevent stale markers.
    # See DEC-STALE-MARKER-001: advisory checks can consume the 5s budget before this runs.
    finalize_trace "$TRACE_ID" "$PROJECT_ROOT" "guardian" || true

    # --- W3-2: PRIMARY — SQLite marker_update to 'completed' (DEC-STATE-UNIFY-004) ---
    # finalize_trace already cleaned the dotfile marker (.active-guardian-*).
    # Update the SQLite marker to 'completed' so marker_query reflects the transition.
    # Uses session+workflow_id to scope the update. require_state is idempotent.
    require_state 2>/dev/null || true
    _CG_SESSION="${CLAUDE_SESSION_ID:-$$}"
    _CG_WF_ID=$(workflow_id 2>/dev/null || echo "main")
    marker_update "guardian" "$_CG_SESSION" "$_CG_WF_ID" "completed" "${TRACE_ID}" 2>/dev/null || true
fi

get_git_state "$PROJECT_ROOT"
get_plan_status "$PROJECT_ROOT"
write_statusline_cache "$PROJECT_ROOT"

ISSUES=()

# Layer A: Surface trace context when agent response is short.
#
# @decision DEC-SILENT-RETURN-001
# @title Inject trace summary into ISSUES only when genuinely lost (no trace, no response)
# @status accepted
# @rationale (Revised) Short agent returns are NORMAL under the Trace Protocol — agents
#   write evidence to disk and keep return messages brief. The original 50-char threshold
#   flagged every short return as "minimal response" in ISSUES, which persisted as
#   "unresolved findings" across prompts and caused the model to complain about "empty
#   messages." Fix: when a trace summary exists, the agent completed normally — no issue.
#   Only flag as an issue when there's genuinely no trace AND no response (lost agent).
#   The orchestrator reads TRACE_DIR/summary.md on demand per CLAUDE.md.
if [[ ${#RESPONSE_TEXT} -lt 50 ]]; then
    _has_trace="false"
    if [[ -n "$TRACE_DIR" && -f "$TRACE_DIR/summary.md" ]]; then
        _trace_size=$(wc -c < "$TRACE_DIR/summary.md" 2>/dev/null || echo 0)
        [[ "$_trace_size" -gt 10 ]] && _has_trace="true"
    fi
    if [[ "$_has_trace" == "false" && -z "${RESPONSE_TEXT// /}" ]]; then
        ISSUES+=("Agent returned no response and no trace summary available. Check git log for what happened.")
    fi
fi

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
                name="${hdr#*'### Initiative: '}"
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
        MOD_TIME=$(_file_mtime "$PLAN")
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

# Check 6b: Shellcheck advisory on .sh files modified in the merge
# Run shellcheck on all .sh files changed in the last commit. Advisory only
# (never blocks). Surfaces lint issues for the next implementation cycle.
if [[ -n "$RESPONSE_TEXT" ]] && command -v shellcheck >/dev/null 2>&1; then
    HAS_COMMIT_6B=$(echo "$RESPONSE_TEXT" | grep -iE 'committed|pushed|merge.*complete' || echo "")
    if [[ -n "$HAS_COMMIT_6B" ]]; then
        # Get .sh files changed in the last commit
        _SC_FILES=$(git -C "$PROJECT_ROOT" diff --name-only HEAD~1..HEAD 2>/dev/null \
            | grep '\.sh$' | head -10 || echo "")
        if [[ -n "$_SC_FILES" ]]; then
            _SC_ISSUES=""
            while IFS= read -r _sc_file; do
                _sc_abs="${PROJECT_ROOT}/${_sc_file}"
                [[ -f "$_sc_abs" ]] || continue
                # Use hooks exclusion set for hooks/, scripts exclusion set otherwise
                if [[ "$_sc_file" == hooks/* ]]; then
                    _sc_excl="SC2034,SC1091,SC2002,SC2012,SC2015,SC2126,SC2317,SC2329"
                else
                    _sc_excl="SC2034,SC1091,SC2155,SC2011,SC2016,SC2030,SC2031,SC2010,SC2005,SC1007,SC2153,SC2064,SC2329,SC2086,SC1090,SC2129,SC2320,SC2188,SC2015,SC2162,SC2045,SC2001,SC2088,SC2012,SC2105,SC2126,SC2295,SC2002,SC2317,SC2164"
                fi
                _sc_out=$(shellcheck -e "$_sc_excl" "$_sc_abs" 2>&1) || {
                    _SC_ISSUES="${_SC_ISSUES}  ${_sc_file}: $(_SC_FIRST=$(echo "$_sc_out" | head -3 | tr '\n' ' '); echo "$_SC_FIRST")\n"
                }
            done <<< "$_SC_FILES"
            if [[ -n "$_SC_ISSUES" ]]; then
                ISSUES+=("Advisory: shellcheck found issues in committed .sh files:\n${_SC_ISSUES}Fix before next cycle.")
            fi
        fi
    fi
fi

# Check 7: CWD staleness advisory + canary write after worktree cleanup
# When Guardian removes a worktree, the orchestrator's Bash CWD may now point to
# a deleted directory. guard.sh Check 0.5 auto-recovers on the next command.
# We write a canary based on the hook's .cwd field when the worktree is detected
# as removed (breadcrumb system removed by DEC-PROOF-BREADCRUMB-001).
if [[ -n "$RESPONSE_TEXT" ]]; then
    HAS_WORKTREE_CLEANUP=$(echo "$RESPONSE_TEXT" | grep -iE 'worktree.*remov|removed worktree|git worktree remove|cleaned up worktree' || echo "")
    if [[ -n "$HAS_WORKTREE_CLEANUP" ]]; then
        ISSUES+=("Guardian removed a worktree. CWD recovery canary written if path confirmed deleted.")
        # Check if the hook's CWD (.cwd from hook input) no longer exists — if so, write the canary.
        _HOOK_CWD=$(echo "$AGENT_RESPONSE" | jq -r '.cwd // empty' 2>/dev/null || echo "")
        if [[ -n "$_HOOK_CWD" && ! -d "$_HOOK_CWD" ]]; then
            echo "$_HOOK_CWD" > "$HOME/.claude/.cwd-recovery-needed" 2>/dev/null || true
            log_info "CHECK-GUARDIAN" "CWD canary written for deleted path: $_HOOK_CWD"
        fi
    fi
fi

# --- Trace protocol: auto-capture commit-info.txt (best-effort, runs after finalize) ---
# finalize_trace already ran above (before advisory checks). This block enriches
# the trace artifacts retrospectively — it does NOT affect marker cleanup.
if [[ -n "$TRACE_ID" && -d "$TRACE_DIR/artifacts" ]]; then
    # Auto-capture commit-info.txt: last commit subject + diff stat.
    # Provides concrete evidence of what the guardian committed without requiring
    # the agent to explicitly write an artifact. Uses || true — git may fail on
    # non-git roots or when HEAD~1 doesn't exist (first commit).
    {
        git -C "$PROJECT_ROOT" log --oneline -1 2>/dev/null || true
        git -C "$PROJECT_ROOT" diff --stat HEAD~1..HEAD 2>/dev/null || true
    } > "$TRACE_DIR/artifacts/commit-info.txt" 2>/dev/null || true

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
# Clean the canonical .proof-status-{phash} so it doesn't interfere with the
# next implementation cycle. Prevents stale "verified" from bypassing the proof gate.
if [[ -n "$RESPONSE_TEXT" ]]; then
    HAS_COMMIT=$(echo "$RESPONSE_TEXT" | grep -iE 'committed|commit.*successful|pushed|merge.*complete' || echo "")
    if [[ -n "$HAS_COMMIT" ]]; then
        # Clean the canonical scoped proof-status file after successful commit.
        # @decision DEC-ISOLATION-006
        # @title check-guardian transitions proof state to committed after successful commit
        # @status accepted
        # @rationale W5-2: SQLite is the sole authority for proof state. After a successful
        #   commit, proof_state_set("committed") transitions the state in the proof_state table,
        #   preventing stale "verified" from bypassing the proof gate in the next cycle.
        #   Flat-file cleanup removed since flat-file writes were eliminated in W5-2.
        # Read current proof state from SQLite (sole authority since W5-2)
        PROOF_VAL=$(proof_state_get 2>/dev/null | cut -d'|' -f1 || echo "")
        if [[ "$PROOF_VAL" == "verified" ]]; then
            # Transition to committed in SQLite
            if ! PROJECT_ROOT="$PROJECT_ROOT" proof_state_set "committed" "check-guardian" 2>/dev/null; then
                log_info "check-guardian" "WARN: proof_state_set failed (status=committed, source=check-guardian)" 2>/dev/null || true
                append_audit "$PROJECT_ROOT" "proof_write_failed" "status=committed source=check-guardian hook=check-guardian" 2>/dev/null || true
            else
                log_info "CHECK-GUARDIAN" "Proof state set to committed after successful commit"
            fi
        fi

        # Check 7b: Post-merge worktree directory verification.
        # If linked worktrees exist after merge, check for uncommitted changes and
        # attempt cleanup via worktree-roster sweep. Uses git worktree list directly
        # (no breadcrumb needed — breadcrumb system removed by DEC-PROOF-BREADCRUMB-001).
        #
        # @decision DEC-SWEEP-DEDUP-001
        # @title Run worktree sweep once per merge, not once per worktree
        # @status accepted
        # @rationale Check 7b previously looped over all non-main worktrees, calling
        #   sweep --auto for each. sweep already scans all worktrees internally, so
        #   calling it N times produced N identical reports. With 6 worktrees, this was
        #   65+ lines of noise in additionalContext per merge.
        #   Fix: dirty-worktree detection still loops (each path must be individually
        #   checked), but sweep is called once after the loop using the standard
        #   WORKTREE_DIR (.worktrees/ parent). Empty sweep output is suppressed.
        GIT_WT_COUNT=$(git -C "$PROJECT_ROOT" worktree list --porcelain 2>/dev/null \
            | grep -c '^worktree ' || echo "0")
        if [[ "$GIT_WT_COUNT" -gt 1 ]]; then
            MAIN_WT=$(git -C "$PROJECT_ROOT" worktree list --porcelain 2>/dev/null \
                | awk '/^worktree /{print $2; exit}') || MAIN_WT=""
            while IFS= read -r _wt_path; do
                if [[ -d "$_wt_path" ]]; then
                    WT_DIRTY=$(git -C "$_wt_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
                    if [[ "$WT_DIRTY" -gt 0 ]]; then
                        ISSUES+=("WARN: Worktree $_wt_path still exists with $WT_DIRTY uncommitted change(s) — manual cleanup needed")
                    fi
                fi
            done < <(git -C "$PROJECT_ROOT" worktree list --porcelain 2>/dev/null \
                | awk -v main="$MAIN_WT" '/^worktree /{path=$2} path && path != main {print path}')

            # Run sweep ONCE (not per-worktree) — sweep already scans all worktrees.
            # --auto mode suppresses empty categories (Husks: none, Orphans: none, etc.)
            # so SWEEP_OUTPUT is non-empty only when there is something actionable.
            ROSTER_SCRIPT="$HOME/.claude/scripts/worktree-roster.sh"
            if [[ -x "$ROSTER_SCRIPT" ]]; then
                SWEEP_OUTPUT=$("$ROSTER_SCRIPT" sweep --auto 2>&1 || true)
                if [[ -n "$SWEEP_OUTPUT" ]]; then
                    ISSUES+=("Post-merge cleanup: Sweep report (mode: auto): $SWEEP_OUTPUT")
                fi
            fi
        fi
    fi
fi

# --- Spawn CI watcher after push (if GitHub Actions present) ---
# After a guardian push, start ci-watch.sh in background to monitor the CI run.
# Prevents duplicate watchers via lock file PID check in ci-watch.sh.
if has_github_actions "$PROJECT_ROOT"; then
    CI_WATCH_SCRIPT="$HOME/.claude/scripts/ci-watch.sh"
    if [[ -x "$CI_WATCH_SCRIPT" ]]; then
        # Check if a watcher is already live (avoid duplicate spawning)
        _CI_WATCH_PHASH=$(project_hash "$PROJECT_ROOT")
        _CI_WATCH_LOCK="${CLAUDE_DIR}/.ci-watch-${_CI_WATCH_PHASH}.lock"
        _WATCHER_LIVE=false
        if [[ -f "$_CI_WATCH_LOCK" ]]; then
            _LOCK_PID=$(cat "$_CI_WATCH_LOCK" 2>/dev/null || echo "")
            if [[ -n "$_LOCK_PID" ]] && kill -0 "$_LOCK_PID" 2>/dev/null; then
                _WATCHER_LIVE=true
            fi
        fi
        if [[ "$_WATCHER_LIVE" == "false" ]]; then
            _CI_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
            bash "$CI_WATCH_SCRIPT" "$PROJECT_ROOT" >/dev/null 2>&1 &
            ISSUES+=("CI watcher spawned — monitoring run on ${_CI_BRANCH}")
        fi
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

# Log issues to audit trail
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    for issue in "${ISSUES[@]}"; do
        append_audit "$PROJECT_ROOT" "agent_guardian" "$issue"
    done
fi

# Persist findings for next-prompt injection
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    FINDINGS_FILE="${CLAUDE_DIR}/.agent-findings"
    FINDING="guardian|$(IFS=';'; echo "${ISSUES[*]}")"
    if ! grep -qxF "$FINDING" "$FINDINGS_FILE" 2>/dev/null; then
        echo "$FINDING" >> "$FINDINGS_FILE"
    fi
    # @decision DEC-STATE-KV-007
    # @title Emit agent.finding events to SQLite audit trail alongside flat-file delivery
    # @status accepted
    # @rationale Per DEC-STATE-UNIFY-009, events are institutional memory — never deleted.
    #   The flat file uses consume-and-clear delivery (prompt-submit.sh reads and deletes).
    #   state_emit preserves a permanent audit trail in the events ledger without changing
    #   the delivery mechanism. Best-effort: 2>/dev/null || true ensures this never blocks.
    _GF_TEXT=$(printf '%s' "${ISSUES[*]}" | sed 's/"/\\"/g')
    state_emit "agent.finding" "{\"agent\":\"guardian\",\"text\":\"${_GF_TEXT}\"}" 2>/dev/null || true
fi

# Output as additionalContext
ESCAPED=$(echo -e "$CONTEXT" | jq -Rs .)
cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF

exit 0
