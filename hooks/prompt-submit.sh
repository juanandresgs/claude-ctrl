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

_HOOK_NAME="prompt-submit"
source "$(dirname "$0")/source-lib.sh"

HOOK_INPUT=$(read_input)
PROMPT=$(get_field '.prompt')

# --- Verification fast path ---
# @decision DEC-PROMPT-FAST-001
# @title Early-exit fast path for approval keywords
# @status accepted
# @rationale The verification gate at its original position (line 280) ran after
#   5 require_*() calls parsing ~1,600 lines of domain libraries. With a 5s timeout,
#   the hook was frequently killed before reaching the gate. The fast path checks
#   approval keywords immediately after reading input, loads only require_state
#   (~200 lines), and completes CAS in <500ms. Fixes #104.
if [[ -n "$PROMPT" ]] && echo "$PROMPT" | grep -qiE '\bverified\b|\bapproved?\b|\blgtm\b|\blooks\s+good\b|\bship\s+it\b|\bapprove\s+for\s+commit\b'; then
    require_state
    PROJECT_ROOT=$(detect_project_root)
    CLAUDE_DIR=$(get_claude_dir)
    _STATE_DIR="${CLAUDE_DIR}/state/$(project_hash "$PROJECT_ROOT")"
    mkdir -p "$_STATE_DIR" 2>/dev/null || true

    # --- cas_proof_status (hoisted for fast path access) ---
    # cas_proof_status EXPECTED NEW_STATUS
    #   Attempt to transition proof-status from EXPECTED to NEW_STATUS atomically.
    #   Returns 0 on success, 1 if current status doesn't match EXPECTED, 2 on lock failure.
    #
    #   @decision DEC-PROOF-CAS-ATOMIC-001
    #   @title cas_proof_status() holds single lock across check-and-write (true atomic CAS)
    #   @status accepted
    #   @rationale Uses a single subshell that holds fd 9 across the entire check-and-write
    #     operation. The write is done directly (not via write_proof_status) because calling
    #     it would deadlock on the same lock file. Lock timeout reduced from 5s to 2s to
    #     avoid consuming the entire hook budget. Stale lock cleanup added for locks >10s old.
    cas_proof_status() {
        local expected="$1"
        local new_val="$2"
        # New lock path: state/locks/proof.lock
        local locks_dir="${CLAUDE_DIR}/state/locks"
        mkdir -p "$locks_dir" 2>/dev/null || true
        local lockfile="${locks_dir}/proof.lock"
        local proof_file
        proof_file=$(resolve_proof_file)

        mkdir -p "$(dirname "$lockfile")" 2>/dev/null || return 2

        # Stale lock cleanup: if lock mtime > 10s, remove it
        if [[ -f "$lockfile" ]]; then
            local lock_age=0
            local lock_mtime now_epoch
            lock_mtime=$(_file_mtime "$lockfile")
            now_epoch=$(date +%s)
            lock_age=$(( now_epoch - lock_mtime ))
            if [[ "$lock_age" -gt 10 ]]; then
                rm -f "$lockfile" 2>/dev/null || true
                log_info "cas_proof_status" "removed stale lock (age=${lock_age}s)" 2>/dev/null || true
            fi
        fi

        # Pre-check (unlocked fast path — avoids lock contention)
        local current="none"
        if [[ -f "$proof_file" ]]; then
            validate_state_file "$proof_file" 2 2>/dev/null || return 1
            current=$(cut -d'|' -f1 "$proof_file" 2>/dev/null || echo "none")
        fi
        [[ "$current" != "$expected" ]] && return 1

        # Atomic CAS: hold lock across re-check AND write
        local _result=0
        (
            trap 'exit 2' TERM INT HUP
            if ! _lock_fd 2 9; then
                log_info "cas_proof_status" "lock timeout" 2>/dev/null || true
                exit 2
            fi
            # Re-read under lock (the actual CAS check)
            local locked_current="none"
            if [[ -f "$proof_file" ]]; then
                locked_current=$(cut -d'|' -f1 "$proof_file" 2>/dev/null || echo "none")
            fi
            if [[ "$locked_current" != "$expected" ]]; then
                log_info "cas_proof_status" "CAS failed under lock: expected=${expected} actual=${locked_current}" 2>/dev/null || true
                exit 1
            fi
            # Write directly — we hold the lock that write_proof_status would acquire
            local timestamp; timestamp=$(date +%s)
            printf '%s\n' "${new_val}|${timestamp}" > "${proof_file}.tmp" && mv "${proof_file}.tmp" "$proof_file"
            # Dual-write to other location (migration period)
            local phash; phash=$(project_hash "$PROJECT_ROOT")
            local _state_proof="${CLAUDE_DIR}/state/${phash}/proof-status"
            local _old_proof="${CLAUDE_DIR}/.proof-status-${phash}"
            if [[ "$proof_file" == *"/state/"* ]]; then
                # proof_file is new path — also write old
                printf '%s\n' "${new_val}|${timestamp}" > "${_old_proof}.tmp" && mv "${_old_proof}.tmp" "$_old_proof"
            else
                # proof_file is old path — also write new
                mkdir -p "$(dirname "$_state_proof")"
                printf '%s\n' "${new_val}|${timestamp}" > "${_state_proof}.tmp" && mv "${_state_proof}.tmp" "$_state_proof"
            fi
            # Pre-create guardian marker (same as write_proof_status)
            if [[ "$new_val" == "verified" ]]; then
                local trace_store="${TRACE_STORE:-$HOME/.claude/traces}"
                local session="${CLAUDE_SESSION_ID:-$$}"
                echo "pre-verified|${timestamp}" > "${trace_store}/.active-guardian-${session}-${phash}" 2>/dev/null || true
            fi
            log_info "cas_proof_status" "CAS succeeded: ${expected} → ${new_val}" 2>/dev/null || true
            # Dual-write to state.json
            type state_update &>/dev/null && state_update ".proof.status" "$new_val" "cas_proof_status" || true
            exit 0
        ) 9>"$lockfile"
        _result=$?
        return $_result
    }

    # Check for .proof-gate-pending breadcrumb from interrupted previous attempt
    # Check new state dir location first, fall back to old dotfile
    _GATE_PENDING="${_STATE_DIR}/proof-gate-pending"
    if [[ ! -f "$_GATE_PENDING" ]]; then
        _GATE_PENDING="${CLAUDE_DIR}/.proof-gate-pending"
    fi
    if [[ -f "$_GATE_PENDING" ]]; then
        _GATE_TS=$(cat "$_GATE_PENDING" 2>/dev/null || echo "0")
        [[ "$_GATE_TS" =~ ^[0-9]+$ ]] || _GATE_TS=0
        _NOW=$(date +%s)
        _GATE_AGE=$(( _NOW - _GATE_TS ))
        if [[ "$_GATE_AGE" -gt 3 ]]; then
            # Previous verification was interrupted — clean up, user is retrying
            rm -f "${_STATE_DIR}/proof-gate-pending" "${CLAUDE_DIR}/.proof-gate-pending" 2>/dev/null || true
        fi
    fi

    PROOF_FILE=$(resolve_proof_file)
    if [[ -f "$PROOF_FILE" ]]; then
        if validate_state_file "$PROOF_FILE" 2; then
            CURRENT_STATUS=$(cut -d'|' -f1 "$PROOF_FILE" 2>/dev/null)
        else
            CURRENT_STATUS=""  # corrupt — skip approval transition
        fi
        if [[ "$CURRENT_STATUS" == "pending" || "$CURRENT_STATUS" == "needs-verification" ]]; then
            # Write breadcrumb before CAS attempt (new state dir location)
            date +%s > "${_STATE_DIR}/proof-gate-pending" 2>/dev/null || true

            if cas_proof_status "$CURRENT_STATUS" "verified"; then
                # Success — remove breadcrumb, reset CAS failure counter, emit dispatch
                rm -f "${_STATE_DIR}/proof-gate-pending" "${CLAUDE_DIR}/.proof-gate-pending" 2>/dev/null || true
                rm -f "${_STATE_DIR}/cas-failures" "${CLAUDE_DIR}/.cas-failures" 2>/dev/null || true
                cat <<EOFVERIFY
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "DISPATCH GUARDIAN NOW with AUTO-VERIFY-APPROVED: User verified proof-of-work. proof-status=verified. Auto-dispatch Guardian per CLAUDE.md with AUTO-VERIFY-APPROVED in the prompt — the user has already approved. Guardian MUST skip its Interactive Approval Protocol and execute the merge cycle directly."
  }
}
EOFVERIFY
                exit 0
            else
                # CAS failed — remove breadcrumb and fall through
                rm -f "${_STATE_DIR}/proof-gate-pending" "${CLAUDE_DIR}/.proof-gate-pending" 2>/dev/null || true
                # --- M1: CAS failure diagnostic counter ---
                # @decision DEC-BOOTSTRAP-PARADOX-001
                # @title CAS failure counter warns after repeated verification failures
                # @status accepted
                # @rationale When cas_proof_status fails 2+ consecutive times for the same
                #   transition, the gate infrastructure itself may be broken (e.g., a fix
                #   targeting cas_proof_status is on a branch while old broken code is on main).
                #   The counter file format: count|expected|new_val|timestamp. On success, it
                #   is deleted. Warns after 2+ failures so the orchestrator can take action.
                #   Fixes bootstrap paradox symptom from Phase 2 merge. See #105.
                # Use new state dir location with migration fallback for cas-failures
                _CAS_FAIL_FILE="${_STATE_DIR}/cas-failures"
                _CAS_FAIL_COUNT=1
                _CAS_PREV_EXP=""
                _CAS_PREV_NEW=""
                if [[ -f "$_CAS_FAIL_FILE" ]]; then
                    _CAS_PREV_COUNT=$(cut -d'|' -f1 "$_CAS_FAIL_FILE" 2>/dev/null || echo "0")
                    _CAS_PREV_EXP=$(cut -d'|' -f2 "$_CAS_FAIL_FILE" 2>/dev/null || echo "")
                    _CAS_PREV_NEW=$(cut -d'|' -f3 "$_CAS_FAIL_FILE" 2>/dev/null || echo "")
                    # Only increment if same transition (same expected+new_val)
                    if [[ "$_CAS_PREV_EXP" == "$CURRENT_STATUS" && "$_CAS_PREV_NEW" == "verified" ]]; then
                        _CAS_FAIL_COUNT=$(( _CAS_PREV_COUNT + 1 ))
                    fi
                elif [[ -f "${CLAUDE_DIR}/.cas-failures" ]]; then
                    # Migration fallback: read from old location
                    _CAS_PREV_COUNT=$(cut -d'|' -f1 "${CLAUDE_DIR}/.cas-failures" 2>/dev/null || echo "0")
                    _CAS_PREV_EXP=$(cut -d'|' -f2 "${CLAUDE_DIR}/.cas-failures" 2>/dev/null || echo "")
                    _CAS_PREV_NEW=$(cut -d'|' -f3 "${CLAUDE_DIR}/.cas-failures" 2>/dev/null || echo "")
                    if [[ "$_CAS_PREV_EXP" == "$CURRENT_STATUS" && "$_CAS_PREV_NEW" == "verified" ]]; then
                        _CAS_FAIL_COUNT=$(( _CAS_PREV_COUNT + 1 ))
                    fi
                fi
                printf '%s\n' "${_CAS_FAIL_COUNT}|${CURRENT_STATUS}|verified|$(date +%s)" > "$_CAS_FAIL_FILE" 2>/dev/null || true
            fi
        fi
    fi
    # No proof file or wrong status — fall through to normal flow
fi

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

PROJECT_ROOT="${PROJECT_ROOT:-$(detect_project_root)}"
CLAUDE_DIR="${CLAUDE_DIR:-$(get_claude_dir)}"
# Compute state dir for per-project state file lookups in main body
_STATE_DIR_MAIN="${CLAUDE_DIR}/state/$(project_hash "$PROJECT_ROOT")"
CONTEXT_PARTS=()

# --- Check for orphaned .proof-gate-pending breadcrumb from interrupted verification ---
# @decision DEC-PROMPT-BREADCRUMB-001
# @title Breadcrumb-based retroactive notification for interrupted verifications
# @status accepted
# @rationale When the hook is killed mid-verification (timeout), the user gets no
#   feedback. The breadcrumb (.proof-gate-pending) is written before CAS and removed
#   after success or fall-through. If it persists >3s, the next hook invocation warns
#   the user to retry. Fixes the silent-failure symptom of #104.
# Check new state dir location first, fall back to old dotfile
_GATE_PENDING_CHECK="${_STATE_DIR_MAIN}/proof-gate-pending"
[[ ! -f "$_GATE_PENDING_CHECK" ]] && _GATE_PENDING_CHECK="${CLAUDE_DIR}/.proof-gate-pending"
if [[ -f "$_GATE_PENDING_CHECK" ]]; then
    _GATE_TS_CHECK=$(cat "$_GATE_PENDING_CHECK" 2>/dev/null || echo "0")
    [[ "$_GATE_TS_CHECK" =~ ^[0-9]+$ ]] || _GATE_TS_CHECK=0
    _NOW_CHECK=$(date +%s)
    _GATE_AGE_CHECK=$(( _NOW_CHECK - _GATE_TS_CHECK ))
    if [[ "$_GATE_AGE_CHECK" -gt 3 ]]; then
        CONTEXT_PARTS+=("WARNING: A previous verification attempt was interrupted. Please type 'approved' again.")
        rm -f "$_GATE_PENDING_CHECK" "${CLAUDE_DIR}/.proof-gate-pending" 2>/dev/null || true
    fi
fi

# --- M1: Bootstrap paradox diagnostic — inject warning if CAS has failed repeatedly ---
# @decision DEC-BOOTSTRAP-PARADOX-001
# @title CAS failure counter injects warning after 2+ consecutive failures
# @status accepted
# @rationale When cas_proof_status fails 2+ consecutive times for the same
#   transition, the gate infrastructure itself may be broken (e.g., a fix
#   to cas_proof_status is on a branch while old broken code runs on main).
#   The counter file is written by the fast-path on CAS failure and deleted on
#   success. This main-body check injects the warning into CONTEXT_PARTS so the
#   orchestrator sees it. Fixes #105.
# Check new state dir location first, fall back to old dotfile
_CAS_FAIL_CHECK="${_STATE_DIR_MAIN}/cas-failures"
[[ ! -f "$_CAS_FAIL_CHECK" ]] && _CAS_FAIL_CHECK="${CLAUDE_DIR}/.cas-failures"
if [[ -f "$_CAS_FAIL_CHECK" ]]; then
    _CAS_WARN_COUNT=$(cut -d'|' -f1 "$_CAS_FAIL_CHECK" 2>/dev/null || echo "0")
    _CAS_WARN_EXP=$(cut -d'|' -f2 "$_CAS_FAIL_CHECK" 2>/dev/null || echo "unknown")
    _CAS_WARN_NEW=$(cut -d'|' -f3 "$_CAS_FAIL_CHECK" 2>/dev/null || echo "unknown")
    if [[ "$_CAS_WARN_COUNT" =~ ^[0-9]+$ ]] && [[ "$_CAS_WARN_COUNT" -ge 2 ]]; then
        CONTEXT_PARTS+=("BOOTSTRAP PARADOX WARNING: cas_proof_status has failed ${_CAS_WARN_COUNT} times to transition ${_CAS_WARN_EXP} → ${_CAS_WARN_NEW}. The gate infrastructure may be broken. If you are merging a gate fix, manual proof-status override may be required. See #105.")
    fi
fi

# --- First-prompt mitigation for session-init bug (Issue #10373) ---
PROMPT_COUNT_FILE="${CLAUDE_DIR}/.prompt-count-${CLAUDE_SESSION_ID:-$$}"
if [[ ! -f "$PROMPT_COUNT_FILE" ]]; then
    require_session
    require_git
    require_plan
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

# @decision DEC-EFF-010
# @title Cache keyword match results with state-based invalidation
# @status accepted
# @rationale Keyword detection runs grep -qiE regex on every user prompt (~50-100ms).
#   Results only change when git or plan state changes. Caching across
#   consecutive identical-context prompts eliminates redundant regex evaluation.
#   Safety invariant: Same signals produced, just served from cache.
#   Cache invalidated on git HEAD change, branch change, or plan mtime change.
#   CRITICAL: The PROOF-STATUS CAS section (fast path, lines above) is NOT cached.
#   Only the contextual keyword injections below are cached.
_KW_CACHE="${CLAUDE_DIR}/.keyword-cache-${CLAUDE_SESSION_ID:-$$}"

# Build cache fingerprint: branch|HEAD|plan_mtime|dirty_count
_KW_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
_KW_HEAD=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
_KW_PLAN_MTIME=0
[[ -f "$PROJECT_ROOT/MASTER_PLAN.md" ]] && _KW_PLAN_MTIME=$(stat -c '%Y' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null || stat -f '%m' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null || echo "0")
_KW_DIRTY=$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
_KW_FINGERPRINT="${_KW_BRANCH}|${_KW_HEAD}|${_KW_PLAN_MTIME}|${_KW_DIRTY}"

_KW_CACHE_HIT=false
_KW_CACHED_CONTEXT=""
if [[ -f "$_KW_CACHE" ]]; then
    _KW_STORED_FP=$(head -1 "$_KW_CACHE" 2>/dev/null || echo "")
    if [[ "$_KW_STORED_FP" == "$_KW_FINGERPRINT" ]]; then
        _KW_CACHED_CONTEXT=$(tail -n +2 "$_KW_CACHE" 2>/dev/null || echo "")
        _KW_CACHE_HIT=true
    fi
fi

if [[ "$_KW_CACHE_HIT" == "true" && -n "$_KW_CACHED_CONTEXT" ]]; then
    # Serve from cache — same git/plan state, no need to recompute
    while IFS= read -r _kw_line; do
        [[ -n "$_kw_line" ]] && CONTEXT_PARTS+=("$_kw_line")
    done <<< "$_KW_CACHED_CONTEXT"
else
    # Cache miss — compute keyword injections and cache results
    _KW_FRESH_PARTS=()

    # --- Mid-session CI status injection ---
    # When the user's prompt mentions CI-related keywords, inject cached CI status.
    # Reads state file only — no network call. Fast path for CI awareness mid-session.
    if echo "$PROMPT" | grep -qiE '\bci\b|\bpipeline\b|\bactions?\b|\bbuild\b.*\bfail|\bdeploy\b'; then
        require_ci
        if read_ci_status "$PROJECT_ROOT"; then
            _KW_FRESH_PARTS+=("Current CI status: $(format_ci_summary)")
        fi
    fi

    # --- Check for plan/implement/status keywords ---
    if echo "$PROMPT" | grep -qiE '\bplan\b|\bimplement\b|\bphase\b|\bmaster.plan\b|\bstatus\b|\bprogress\b|\bdemo\b'; then
        require_plan
        get_plan_status "$PROJECT_ROOT"

        if [[ "$PLAN_EXISTS" == "true" ]]; then
            if [[ "$PLAN_LIFECYCLE" == "dormant" ]]; then
                # @decision DEC-PLAN-003: "dormant" replaces "completed" for living plans
                _KW_FRESH_PARTS+=("WARNING: MASTER_PLAN.md is dormant — all initiatives completed. Source writes are BLOCKED. Add a new initiative before writing code.")
            elif [[ "$PLAN_ACTIVE_INITIATIVES" -gt 0 ]]; then
                # New living-plan format: show initiative count and names
                PLAN_LINE="Plan: ${PLAN_ACTIVE_INITIATIVES} active initiative(s)"
                [[ "$PLAN_TOTAL_PHASES" -gt 0 ]] && PLAN_LINE="$PLAN_LINE | ${PLAN_COMPLETED_PHASES}/${PLAN_TOTAL_PHASES} phases done"
                [[ "$PLAN_AGE_DAYS" -gt 0 ]] && PLAN_LINE="$PLAN_LINE | age: ${PLAN_AGE_DAYS}d"
                require_session
                get_session_changes "$PROJECT_ROOT"
                [[ "$SESSION_CHANGED_COUNT" -gt 0 ]] && PLAN_LINE="$PLAN_LINE | $SESSION_CHANGED_COUNT files changed"
                _KW_FRESH_PARTS+=("$PLAN_LINE")
            else
                # Old format: phase-level progress
                PLAN_LINE="Plan:"
                [[ "$PLAN_TOTAL_PHASES" -gt 0 ]] && PLAN_LINE="$PLAN_LINE $PLAN_COMPLETED_PHASES/$PLAN_TOTAL_PHASES phases done"
                [[ -n "$PLAN_PHASE" ]] && PLAN_LINE="$PLAN_LINE | active: $PLAN_PHASE"
                [[ "$PLAN_AGE_DAYS" -gt 0 ]] && PLAN_LINE="$PLAN_LINE | age: ${PLAN_AGE_DAYS}d"
                require_session
                get_session_changes "$PROJECT_ROOT"
                [[ "$SESSION_CHANGED_COUNT" -gt 0 ]] && PLAN_LINE="$PLAN_LINE | $SESSION_CHANGED_COUNT files changed"
                _KW_FRESH_PARTS+=("$PLAN_LINE")
            fi
        else
            _KW_FRESH_PARTS+=("No MASTER_PLAN.md found — Core Dogma requires planning before implementation.")
        fi
    fi

    # --- Check for merge/commit keywords ---
    if echo "$PROMPT" | grep -qiE '\bmerge\b|\bcommit\b|\bpush\b|\bPR\b|\bpull.request\b'; then
        require_git
        get_git_state "$PROJECT_ROOT"

        if [[ -n "$GIT_BRANCH" ]]; then
            _KW_FRESH_PARTS+=("Git: branch=$GIT_BRANCH, $GIT_DIRTY_COUNT uncommitted changes")

            if [[ "$GIT_BRANCH" == "main" || "$GIT_BRANCH" == "master" ]]; then
                _KW_FRESH_PARTS+=("WARNING: Currently on $GIT_BRANCH. Sacred Practice #2: Main is sacred.")
            fi
        fi
    fi

    # --- Research-worthy prompt detection ---
    if echo "$PROMPT" | grep -qiE '\bresearch\b|\bcompare\b|\bwhat.*(people|community|reddit)\b|\brecent\b|\btrending\b|\bdeep dive\b|\bwhich is better\b|\bpros and cons\b'; then
        require_session
        get_research_status "$PROJECT_ROOT"
        if [[ "$RESEARCH_EXISTS" == "true" ]]; then
            _KW_FRESH_PARTS+=("Research log: $RESEARCH_ENTRY_COUNT entries. Check .claude/research-log.md before invoking /deep-research or /last30days.")
        else
            _KW_FRESH_PARTS+=("No prior research. /deep-research for deep analysis, /last30days for recent community discussions.")
        fi
    fi

    # Write cache: fingerprint on line 1, results on subsequent lines
    if [[ ${#_KW_FRESH_PARTS[@]} -gt 0 ]]; then
        {
            echo "$_KW_FINGERPRINT"
            printf '%s\n' "${_KW_FRESH_PARTS[@]}"
        } > "$_KW_CACHE" 2>/dev/null || true
        for _kw_part in "${_KW_FRESH_PARTS[@]}"; do
            CONTEXT_PARTS+=("$_kw_part")
        done
    else
        # Still write fingerprint so next call can confirm cache hit with empty results
        echo "$_KW_FINGERPRINT" > "$_KW_CACHE" 2>/dev/null || true
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
