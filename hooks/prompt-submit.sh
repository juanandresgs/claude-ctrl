#!/usr/bin/env bash
# Dynamic context injection based on user prompt content.
# UserPromptSubmit hook
#
# Injects contextual information when the user's prompt references:
#   - File paths → inject that file's @decision status
#   - "plan" or "implement" → inject MASTER_PLAN.md phase status
#   - "merge" or "commit" → inject git dirty state
#
# @decision DEC-PROMPT-001
# @title User verification gate and dynamic context injection
# @status accepted
# @rationale This hook serves two critical functions: (1) it's the ONLY path for user
#   verification to reach .proof-status (no agent can write "verified"), and (2) it
#   injects contextual hints based on prompt keywords. Uses get_claude_dir() to handle
#   ~/.claude special case (Fix #77).

set -euo pipefail

source "$(dirname "$0")/source-lib.sh"

require_session
require_git
require_plan
require_ci

HOOK_INPUT=$(read_input)
PROMPT=$(get_field '.prompt')

# Handle empty prompt (Enter-only submit).
# @decision DEC-PROMPT-002
# @title Treat Enter-only submits as continuation, not errors
# @status accepted
# @rationale The model was interpreting text-free turns as "empty sends" and
#   commenting on it, frustrating the user. Root cause: no guidance was injected
#   for empty prompts (silent exit on non-proof path, alarming advisory on proof
#   path). Fix: always inject a short hint telling the model to treat Enter as
#   approval/continuation. Proof gate path still notes the keyword requirement
#   but without the "error" framing.
if [[ -z "$PROMPT" ]]; then
    _EMPTY_HINT="User pressed Enter without text. This is normal interaction — treat as approval or continuation of the current flow. Do NOT comment on the empty message."
    _EMPTY_CLAUDE_DIR=$(get_claude_dir 2>/dev/null || echo "")
    if [[ -n "$_EMPTY_CLAUDE_DIR" ]]; then
        _EMPTY_PROOF=$(resolve_proof_file)
        [[ ! -f "$_EMPTY_PROOF" ]] && _EMPTY_PROOF=""
        if [[ -n "$_EMPTY_PROOF" && -f "$_EMPTY_PROOF" ]]; then
            if validate_state_file "$_EMPTY_PROOF" 2; then
                _EMPTY_STATUS=$(cut -d'|' -f1 "$_EMPTY_PROOF" 2>/dev/null || echo "")
            else
                _EMPTY_STATUS=""  # corrupt — skip hint
            fi
            if [[ "$_EMPTY_STATUS" == "pending" ]]; then
                _EMPTY_HINT="User pressed Enter without text. Approval gate is active (.proof-status=pending) — approval keywords must appear as text. Remind the user to type 'approved' or use /approve. Do NOT comment on the message being empty."
            fi
        fi
    fi
    cat <<EOFEMPTY
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "$_EMPTY_HINT"
  }
}
EOFEMPTY
    exit 0
fi

PROJECT_ROOT=$(detect_project_root)
CONTEXT_PARTS=()

# --- First-prompt mitigation for session-init bug (Issue #10373) ---
CLAUDE_DIR=$(get_claude_dir)
PROMPT_COUNT_FILE="${CLAUDE_DIR}/.prompt-count-${CLAUDE_SESSION_ID:-$$}"
if [[ ! -f "$PROMPT_COUNT_FILE" ]]; then
    mkdir -p "${CLAUDE_DIR}"
    echo "1" > "$PROMPT_COUNT_FILE"
    date +%s > "${CLAUDE_DIR}/.session-start-epoch"
    # Inject full session context (same as session-init.sh)
    get_git_state "$PROJECT_ROOT"
    get_plan_status "$PROJECT_ROOT"
    write_statusline_cache "$PROJECT_ROOT"
    [[ -n "$GIT_BRANCH" ]] && CONTEXT_PARTS+=("Git: branch=$GIT_BRANCH, $GIT_DIRTY_COUNT uncommitted")
    if [[ "$PLAN_EXISTS" == "true" ]]; then
        if [[ "$PLAN_LIFECYCLE" == "dormant" ]]; then
            # @decision DEC-PLAN-003: "dormant" replaces "completed" for living plans
            CONTEXT_PARTS+=("WARNING: MASTER_PLAN.md is dormant — all initiatives completed. Source writes BLOCKED. Add a new initiative before writing code.")
        elif [[ "$PLAN_ACTIVE_INITIATIVES" -gt 0 ]]; then
            # New format: show initiative count and phase progress
            _PS_LINE="Plan: ${PLAN_ACTIVE_INITIATIVES} active initiative(s)"
            [[ "$PLAN_TOTAL_PHASES" -gt 0 ]] && _PS_LINE="$_PS_LINE | ${PLAN_COMPLETED_PHASES}/${PLAN_TOTAL_PHASES} phases done"
            [[ "$PLAN_AGE_DAYS" -gt 0 ]] && _PS_LINE="$_PS_LINE | age: ${PLAN_AGE_DAYS}d"
            CONTEXT_PARTS+=("$_PS_LINE")
        else
            # Old format: show phase count
            CONTEXT_PARTS+=("Plan: $PLAN_COMPLETED_PHASES/$PLAN_TOTAL_PHASES phases done")
        fi
    else
        CONTEXT_PARTS+=("MASTER_PLAN.md: not found (required before implementation)")
    fi

    # Inject todo HUD (same as session-init)
    TODO_SCRIPT="$HOME/.claude/scripts/todo.sh"
    if [[ -x "$TODO_SCRIPT" ]] && command -v gh >/dev/null 2>&1; then
        HUD_OUTPUT=$("$TODO_SCRIPT" hud 2>/dev/null || echo "")
        if [[ -n "$HUD_OUTPUT" ]]; then
            while IFS= read -r line; do
                CONTEXT_PARTS+=("$line")
            done <<< "$HUD_OUTPUT"
        fi
    fi

    # --- First-encounter plan assessment ---
    # When plan is stale, scan @decision coverage and inject assessment
    if [[ "$PLAN_EXISTS" == "true" && "$PLAN_SOURCE_CHURN_PCT" -ge 10 ]]; then
        DECISION_PATTERN='@decision|# DECISION:|// DECISION\('
        DECISION_FILE_COUNT=0
        TOTAL_SOURCE_COUNT=0
        SCAN_DIRS=()
        for dir in src lib app pkg cmd internal; do
            [[ -d "$PROJECT_ROOT/$dir" ]] && SCAN_DIRS+=("$PROJECT_ROOT/$dir")
        done
        [[ ${#SCAN_DIRS[@]} -eq 0 ]] && SCAN_DIRS=("$PROJECT_ROOT")

        for dir in "${SCAN_DIRS[@]}"; do
            if command -v rg &>/dev/null; then
                dec_count=$(rg -l "$DECISION_PATTERN" "$dir" \
                    --glob '*.{ts,tsx,js,jsx,py,rs,go,java,c,cpp,h,hpp,sh,rb,php}' \
                    2>/dev/null | wc -l | tr -d ' ') || dec_count=0
                src_count=$(rg --files "$dir" \
                    --glob '*.{ts,tsx,js,jsx,py,rs,go,java,c,cpp,h,hpp,sh,rb,php}' \
                    2>/dev/null | wc -l | tr -d ' ') || src_count=0
            else
                dec_count=$(grep -rlE "$DECISION_PATTERN" "$dir" \
                    --include='*.ts' --include='*.py' --include='*.js' --include='*.sh' \
                    2>/dev/null | wc -l | tr -d ' ') || dec_count=0
                src_count=$(find "$dir" -type f \( -name '*.ts' -o -name '*.py' -o -name '*.js' -o -name '*.sh' \) \
                    2>/dev/null | wc -l | tr -d ' ') || src_count=0
            fi
            DECISION_FILE_COUNT=$((DECISION_FILE_COUNT + dec_count))
            TOTAL_SOURCE_COUNT=$((TOTAL_SOURCE_COUNT + src_count))
        done

        COVERAGE_PCT=0
        [[ "$TOTAL_SOURCE_COUNT" -gt 0 ]] && COVERAGE_PCT=$((DECISION_FILE_COUNT * 100 / TOTAL_SOURCE_COUNT))

        if [[ "$COVERAGE_PCT" -lt 30 || "$PLAN_SOURCE_CHURN_PCT" -ge 20 ]]; then
            CONTEXT_PARTS+=("Plan assessment: ${PLAN_SOURCE_CHURN_PCT}% source file churn since plan update. @decision coverage: $DECISION_FILE_COUNT/$TOTAL_SOURCE_COUNT source files (${COVERAGE_PCT}%). Review the plan and scan for @decision gaps before implementing.")
        fi
    fi
fi

# --- Active agent detection for Task Interruption Protocol ---
# @decision DEC-INTERRUPT-001
# @title Active agent detection in prompt-submit.sh
# @status accepted
# @rationale When a user gives a new task while agents are still running,
#   the orchestrator needs visibility into active agents to apply the Task
#   Interruption Protocol (CLAUDE.md). Advisory only — no deny, no blocking.
TRACKER_FILE="${CLAUDE_DIR}/.subagent-tracker-${CLAUDE_SESSION_ID:-$$}"
if [[ -f "$TRACKER_FILE" ]]; then
    # Skip injection if prompt matches approval keywords (those go to verification gate)
    if ! echo "$PROMPT" | grep -qiE '\bverified\b|\bapproved?\b|\blgtm\b|\blooks\s+good\b|\bship\s+it\b'; then
        ACTIVE_LINES=()
        NOW_EPOCH=$(date +%s)
        while IFS='|' read -r status agent_type start_epoch _rest; do
            if [[ "$status" == "ACTIVE" && -n "$agent_type" && -n "$start_epoch" ]]; then
                elapsed=$(( NOW_EPOCH - start_epoch ))
                if [[ "$elapsed" -ge 60 ]]; then
                    elapsed_str="$(( elapsed / 60 ))m$(( elapsed % 60 ))s"
                else
                    elapsed_str="${elapsed}s"
                fi
                ACTIVE_LINES+=("  - ${agent_type} agent running for ${elapsed_str}")
            fi
        done < "$TRACKER_FILE"
        if [[ ${#ACTIVE_LINES[@]} -gt 0 ]]; then
            CONTEXT_PARTS+=("ACTIVE AGENTS from previous dispatch (Task Interruption Protocol applies):")
            for line in "${ACTIVE_LINES[@]}"; do
                CONTEXT_PARTS+=("$line")
            done
            CONTEXT_PARTS+=("To pivot, you MUST create a /backlog issue for the interrupted work before proceeding.")
        fi
    fi
fi

# --- User verification gate ---
# When user says "verified" and a proof flow is active (.proof-status = pending
# or needs-verification), write verified|<timestamp>. This is the ONLY path to
# verified status. No agent can write "verified" directly — guard.sh blocks it.
#
# Uses resolve_proof_file() to handle worktree scenarios where the tester writes
# .proof-status to the worktree's .claude/ directory rather than CLAUDE_DIR.
# After writing "verified", dual-writes to the orchestrator's CLAUDE_DIR so
# guard.sh can find the status regardless of which path it checks.
#
# @decision DEC-PROOF-CAS-001
# @title CAS (compare-and-swap) wrapper for proof-status verification in prompt-submit.sh
# @status accepted
# @rationale The original code read .proof-status (CURRENT_STATUS) and then called
#   write_proof_status() without re-checking — a classic TOCTOU race. If two concurrent
#   hook invocations both read "pending" and both called write_proof_status("verified"),
#   the second write would now be rejected by the monotonic lattice (verified→verified
#   is a no-op at the ordinal level). But the CAS pattern here makes the intent explicit:
#   check expected state under the lock, only write if it matches. The lock in
#   write_proof_status() (DEC-PROOF-LOCK-001) provides the mutual exclusion. This
#   function adds the compare step as a safety net before calling into write_proof_status.

# cas_proof_status EXPECTED NEW_STATUS
#   Attempt to transition proof-status from EXPECTED to NEW_STATUS atomically.
#   Returns 0 on success, 1 if current status doesn't match EXPECTED, 2 on lock failure.
cas_proof_status() {
    local expected="$1"
    local new_val="$2"
    local lockfile="${CLAUDE_DIR}/.proof-status.lock"

    mkdir -p "$(dirname "$lockfile")" 2>/dev/null || return 2

    local _cas_result=1
    (
        # Use _portable_flock if available, fall back to bare flock, then proceed unlocked
        local _lock_ok=true
        if type _portable_flock &>/dev/null; then
            _portable_flock 5 9 || _lock_ok=false
        elif command -v flock &>/dev/null; then
            flock -w 5 9 || _lock_ok=false
        fi
        if [[ "$_lock_ok" == "false" ]]; then return 2; fi

        # Re-read under lock to avoid TOCTOU
        local proof_file
        proof_file=$(resolve_proof_file)
        local current="none"
        if [[ -f "$proof_file" ]]; then
            if validate_state_file "$proof_file" 2 2>/dev/null; then
                current=$(cut -d'|' -f1 "$proof_file" 2>/dev/null || echo "none")
            else
                current="corrupt"
            fi
        fi

        if [[ "$current" != "$expected" ]]; then
            log_info "cas_proof_status" "CAS failed: expected=${expected} actual=${current}" 2>/dev/null || true
            exit 1
        fi

        # write_proof_status acquires its own lock on the same lockfile — reentrant on macOS
        # (BSD flock is not reentrant, so we call it from outside the lock context below)
        exit 0
    ) 9>"$lockfile"
    _cas_result=$?

    if [[ "$_cas_result" -eq 0 ]]; then
        # Lock released — now call write_proof_status (which acquires its own lock)
        write_proof_status "$new_val" "$PROJECT_ROOT" && return 0 || return 1
    fi
    return $_cas_result
}

PROOF_FILE=$(resolve_proof_file)
if echo "$PROMPT" | grep -qiE '\bverified\b|\bapproved?\b|\blgtm\b|\blooks\s+good\b|\bship\s+it\b|\bapprove\s+for\s+commit\b'; then
    if [[ -f "$PROOF_FILE" ]]; then
        if validate_state_file "$PROOF_FILE" 2; then
            CURRENT_STATUS=$(cut -d'|' -f1 "$PROOF_FILE" 2>/dev/null)
        else
            CURRENT_STATUS=""  # corrupt — skip approval transition
        fi
        if [[ "$CURRENT_STATUS" == "pending" || "$CURRENT_STATUS" == "needs-verification" ]]; then
            if cas_proof_status "$CURRENT_STATUS" "verified"; then
                CONTEXT_PARTS+=("DISPATCH GUARDIAN NOW: User verified proof-of-work. proof-status=verified. Auto-dispatch Guardian per CLAUDE.md. Do NOT ask 'should I commit?' — Guardian owns the approval cycle.")
            fi
        fi
    fi
fi

# --- Inject agent findings from previous subagent runs ---
FINDINGS_FILE="${CLAUDE_DIR}/.agent-findings"
if [[ -f "$FINDINGS_FILE" && -s "$FINDINGS_FILE" ]]; then
    CONTEXT_PARTS+=("Previous agent findings (unresolved):")
    while IFS='|' read -r agent issues; do
        [[ -z "$agent" ]] && continue
        CONTEXT_PARTS+=("  ${agent}: ${issues}")
    done < "$FINDINGS_FILE"
    # Clear after injection (one-shot delivery)
    rm -f "$FINDINGS_FILE"
fi

# --- Auto-claim: detect issue references in action prompts ---
TODO_SCRIPT="$HOME/.claude/scripts/todo.sh"
if [[ -x "$TODO_SCRIPT" ]]; then
    ISSUE_REF=$(echo "$PROMPT" | grep -oiE '\b(work|fix|implement|tackle|start|handle|address)\b.*#([0-9]+)' | grep -oE '#[0-9]+' | head -1 || true)
    if [[ -n "$ISSUE_REF" ]]; then
        ISSUE_NUM="${ISSUE_REF#\#}"
        # Auto-claim — fire and forget, don't block the prompt
        if [[ -d "$PROJECT_ROOT/.git" ]]; then
            "$TODO_SCRIPT" claim "$ISSUE_NUM" --auto 2>/dev/null || true
        else
            "$TODO_SCRIPT" claim "$ISSUE_NUM" --global --auto 2>/dev/null || true
        fi
        CONTEXT_PARTS+=("Auto-claimed todo #${ISSUE_NUM} for this session.")
    fi
fi

# --- Detect deferred-work language → auto-capture as backlog issue ---
# @decision DEC-BL-CAPTURE-001
# @title Fire-and-forget auto-capture in prompt-submit.sh
# @status accepted
# @rationale prompt-submit.sh must stay <100ms. Auto-capturing to the backlog
#   adds persistent value (deferred ideas survive session end) at zero latency
#   cost: the gh issue create call runs in the background with & so it never
#   blocks the prompt pipeline. The model is informed of the auto-capture so
#   it can confirm or offer to refine the issue.
if echo "$PROMPT" | grep -qiE '\blater\b|\bdefer\b|\bbacklog\b|\beventually\b|\bsomeday\b|\bpark (this|that|it)\b|\bremind me\b|\bcome back to\b|\bfuture\b.*\b(todo|task|idea)\b|\bnote.*(for|to) (later|self)\b'; then
    # Extract the deferral sentence (the sentence containing the trigger word)
    DEFERRAL_TEXT=$(echo "$PROMPT" | grep -oiE '[^.!?]*(\blater\b|\bdefer\b|\bbacklog\b|\beventually\b|\bsomeday\b|\bpark (this|that|it)\b|\bremind me\b|\bcome back to\b|\bfuture\b.*\b(todo|task|idea)\b|\bnote.*(for|to) (later|self)\b)[^.!?]*' | head -1 | xargs || echo "${PROMPT:0:100}")
    # Fire-and-forget auto-capture — MUST be backgrounded for <100ms compliance
    # @decision DEC-BL-TRIGGER-001
    # @title Immediate fire-and-forget auto-capture on deferral detection
    # @status accepted
    # @rationale Batching risks data loss on crash; immediate is reliable and
    #   simple. Background & ensures zero latency impact on the prompt pipeline.
    TODO_SCRIPT_DEFER="$HOME/.claude/scripts/todo.sh"
    if [[ -x "$TODO_SCRIPT_DEFER" ]]; then
        "$TODO_SCRIPT_DEFER" create "$DEFERRAL_TEXT" --context "session:auto-captured" >/dev/null 2>&1 &
    fi
    CONTEXT_PARTS+=("Deferred-work language detected. Auto-captured as backlog issue. Use /backlog to review or refine.")
fi

# --- Mid-session CI status injection ---
# When the user's prompt mentions CI-related keywords, inject cached CI status.
# Reads state file only — no network call. Fast path for CI awareness mid-session.
if echo "$PROMPT" | grep -qiE '\bci\b|\bpipeline\b|\bactions?\b|\bbuild\b.*\bfail|\bdeploy\b'; then
    require_ci
    if read_ci_status "$PROJECT_ROOT"; then
        CONTEXT_PARTS+=("Current CI status: $(format_ci_summary)")
    fi
fi

# --- Check for plan/implement/status keywords ---
if echo "$PROMPT" | grep -qiE '\bplan\b|\bimplement\b|\bphase\b|\bmaster.plan\b|\bstatus\b|\bprogress\b|\bdemo\b'; then
    get_plan_status "$PROJECT_ROOT"

    if [[ "$PLAN_EXISTS" == "true" ]]; then
        if [[ "$PLAN_LIFECYCLE" == "dormant" ]]; then
            # @decision DEC-PLAN-003: "dormant" replaces "completed" for living plans
            CONTEXT_PARTS+=("WARNING: MASTER_PLAN.md is dormant — all initiatives completed. Source writes are BLOCKED. Add a new initiative before writing code.")
        elif [[ "$PLAN_ACTIVE_INITIATIVES" -gt 0 ]]; then
            # New living-plan format: show initiative count and names
            PLAN_LINE="Plan: ${PLAN_ACTIVE_INITIATIVES} active initiative(s)"
            [[ "$PLAN_TOTAL_PHASES" -gt 0 ]] && PLAN_LINE="$PLAN_LINE | ${PLAN_COMPLETED_PHASES}/${PLAN_TOTAL_PHASES} phases done"
            [[ "$PLAN_AGE_DAYS" -gt 0 ]] && PLAN_LINE="$PLAN_LINE | age: ${PLAN_AGE_DAYS}d"
            get_session_changes "$PROJECT_ROOT"
            [[ "$SESSION_CHANGED_COUNT" -gt 0 ]] && PLAN_LINE="$PLAN_LINE | $SESSION_CHANGED_COUNT files changed"
            CONTEXT_PARTS+=("$PLAN_LINE")
        else
            # Old format: phase-level progress
            PLAN_LINE="Plan:"
            [[ "$PLAN_TOTAL_PHASES" -gt 0 ]] && PLAN_LINE="$PLAN_LINE $PLAN_COMPLETED_PHASES/$PLAN_TOTAL_PHASES phases done"
            [[ -n "$PLAN_PHASE" ]] && PLAN_LINE="$PLAN_LINE | active: $PLAN_PHASE"
            [[ "$PLAN_AGE_DAYS" -gt 0 ]] && PLAN_LINE="$PLAN_LINE | age: ${PLAN_AGE_DAYS}d"
            get_session_changes "$PROJECT_ROOT"
            [[ "$SESSION_CHANGED_COUNT" -gt 0 ]] && PLAN_LINE="$PLAN_LINE | $SESSION_CHANGED_COUNT files changed"
            CONTEXT_PARTS+=("$PLAN_LINE")
        fi
    else
        CONTEXT_PARTS+=("No MASTER_PLAN.md found — Core Dogma requires planning before implementation.")
    fi
fi

# --- Check for merge/commit keywords ---
if echo "$PROMPT" | grep -qiE '\bmerge\b|\bcommit\b|\bpush\b|\bPR\b|\bpull.request\b'; then
    get_git_state "$PROJECT_ROOT"

    if [[ -n "$GIT_BRANCH" ]]; then
        CONTEXT_PARTS+=("Git: branch=$GIT_BRANCH, $GIT_DIRTY_COUNT uncommitted changes")

        if [[ "$GIT_BRANCH" == "main" || "$GIT_BRANCH" == "master" ]]; then
            CONTEXT_PARTS+=("WARNING: Currently on $GIT_BRANCH. Sacred Practice #2: Main is sacred.")
        fi
    fi
fi

# --- Research-worthy prompt detection ---
if echo "$PROMPT" | grep -qiE '\bresearch\b|\bcompare\b|\bwhat.*(people|community|reddit)\b|\brecent\b|\btrending\b|\bdeep dive\b|\bwhich is better\b|\bpros and cons\b'; then
    get_research_status "$PROJECT_ROOT"
    if [[ "$RESEARCH_EXISTS" == "true" ]]; then
        CONTEXT_PARTS+=("Research log: $RESEARCH_ENTRY_COUNT entries. Check .claude/research-log.md before invoking /deep-research or /last30days.")
    else
        CONTEXT_PARTS+=("No prior research. /deep-research for deep analysis, /last30days for recent community discussions.")
    fi
fi

# --- Increment prompt counter ---
if [[ -f "$PROMPT_COUNT_FILE" ]]; then
    CURRENT_COUNT=$(cat "$PROMPT_COUNT_FILE" 2>/dev/null || echo "0")
    [[ "$CURRENT_COUNT" =~ ^[0-9]+$ ]] || CURRENT_COUNT=0
    echo "$((CURRENT_COUNT + 1))" > "$PROMPT_COUNT_FILE"
fi

# --- Compaction heuristic ---
# @decision DEC-COMPACT-001
# @title Smart compaction suggestions based on prompts and session duration
# @status accepted
# @rationale Proactively suggest /compact at predictable checkpoints (35, 60 prompts
# or 45, 90 minutes) to prevent context overflow. Primary trigger is prompt count
# (more reliable). Secondary is session duration (catches long sessions with fewer
# prompts). Narrow time windows prevent spam across multiple prompts.
if [[ -f "$PROMPT_COUNT_FILE" ]]; then
    PROMPT_NUM=$(cat "$PROMPT_COUNT_FILE" 2>/dev/null || echo "0")
    [[ "$PROMPT_NUM" =~ ^[0-9]+$ ]] || PROMPT_NUM=0

    SUGGEST_COMPACT=false
    COMPACT_REASON=""

    # Primary: prompt count thresholds
    if [[ "$PROMPT_NUM" -eq 35 || "$PROMPT_NUM" -eq 60 ]]; then
        SUGGEST_COMPACT=true
        COMPACT_REASON="$PROMPT_NUM prompts in this session"
    fi

    # Secondary: session duration
    EPOCH_FILE="${CLAUDE_DIR}/.session-start-epoch"
    if [[ "$SUGGEST_COMPACT" == "false" && -f "$EPOCH_FILE" ]]; then
        START_EPOCH=$(cat "$EPOCH_FILE" 2>/dev/null || echo "0")
        NOW_EPOCH=$(date +%s)
        ELAPSED_MIN=$(( (NOW_EPOCH - START_EPOCH) / 60 ))
        if [[ "$ELAPSED_MIN" -ge 45 && "$ELAPSED_MIN" -le 47 ]] || \
           [[ "$ELAPSED_MIN" -ge 90 && "$ELAPSED_MIN" -le 92 ]]; then
            SUGGEST_COMPACT=true
            COMPACT_REASON="${ELAPSED_MIN} minutes into session"
        fi
    fi

    if [[ "$SUGGEST_COMPACT" == "true" ]]; then
        CONTEXT_PARTS+=("Context management: ${COMPACT_REASON}. Consider running /compact to preserve context and free up the context window.")
    fi
fi

# --- Output ---
if [[ ${#CONTEXT_PARTS[@]} -gt 0 ]]; then
    CONTEXT=$(printf '%s\n' "${CONTEXT_PARTS[@]}")
    ESCAPED=$(echo "$CONTEXT" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": $ESCAPED
  }
}
EOF
fi

exit 0
