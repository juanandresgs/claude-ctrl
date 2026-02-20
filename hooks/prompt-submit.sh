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

HOOK_INPUT=$(read_input)
PROMPT=$(echo "$HOOK_INPUT" | jq -r '.prompt // empty' 2>/dev/null)

# Exit silently if no prompt — but first check if the approval gate is active.
# If .proof-status is pending and the prompt is empty (e.g. image-only submit),
# the keyword gate cannot fire. Emit a context advisory so the orchestrator knows
# text input is required. Reference /approve as the escape hatch.
if [[ -z "$PROMPT" ]]; then
    _EMPTY_CLAUDE_DIR=$(get_claude_dir 2>/dev/null || echo "")
    if [[ -n "$_EMPTY_CLAUDE_DIR" ]]; then
        _EMPTY_PROOF="${_EMPTY_CLAUDE_DIR}/.proof-status"
        if [[ -f "$_EMPTY_PROOF" ]]; then
            _EMPTY_STATUS=$(cut -d'|' -f1 "$_EMPTY_PROOF" 2>/dev/null || echo "")
            if [[ "$_EMPTY_STATUS" == "pending" ]]; then
                cat <<'EOFEMPTY'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "APPROVAL GATE ACTIVE: .proof-status is pending but no text was detected in this prompt. Approval keywords (approved, lgtm, looks good, verified, ship it) must appear as TEXT. Image-only or empty submits cannot trigger the gate. Suggest /approve as an escape hatch."
  }
}
EOFEMPTY
                exit 0
            fi
        fi
    fi
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

# --- User verification gate ---
# When user says "verified" and a proof flow is active (.proof-status = pending
# or needs-verification), write verified|<timestamp>. This is the ONLY path to
# verified status. No agent can write "verified" directly — guard.sh blocks it.
#
# Uses resolve_proof_file() to handle worktree scenarios where the tester writes
# .proof-status to the worktree's .claude/ directory rather than CLAUDE_DIR.
# After writing "verified", dual-writes to the orchestrator's CLAUDE_DIR so
# guard.sh can find the status regardless of which path it checks.
PROOF_FILE=$(resolve_proof_file)
if echo "$PROMPT" | grep -qiE '\bverified\b|\bapproved?\b|\blgtm\b|\blooks\s+good\b|\bship\s+it\b|\bapprove\s+for\s+commit\b'; then
    if [[ -f "$PROOF_FILE" ]]; then
        CURRENT_STATUS=$(cut -d'|' -f1 "$PROOF_FILE" 2>/dev/null)
        if [[ "$CURRENT_STATUS" == "pending" || "$CURRENT_STATUS" == "needs-verification" ]]; then
            echo "verified|$(date +%s)" > "$PROOF_FILE"
            # Dual-write: keep orchestrator's copy in sync so guard.sh can find it
            ORCH_PROOF="${CLAUDE_DIR}/.proof-status"
            if [[ "$PROOF_FILE" != "$ORCH_PROOF" ]]; then
                echo "verified|$(date +%s)" > "$ORCH_PROOF"
            fi
            CONTEXT_PARTS+=("Proof-of-work verified by user. Guardian dispatch is now unblocked.")
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

# --- Detect deferred-work language → suggest /todo ---
if echo "$PROMPT" | grep -qiE '\blater\b|\bdefer\b|\bbacklog\b|\beventually\b|\bsomeday\b|\bpark (this|that|it)\b|\bremind me\b|\bcome back to\b|\bfuture\b.*\b(todo|task|idea)\b|\bnote.*(for|to) (later|self)\b'; then
    CONTEXT_PARTS+=("Deferred-work language detected. Suggest using /backlog to capture this idea so it persists across sessions.")
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

# --- Check for large/multi-step tasks ---
WORD_COUNT=$(echo "$PROMPT" | wc -w | tr -d ' ')
ACTION_VERBS=$(echo "$PROMPT" | { grep -oiE '\b(implement|add|create|build|fix|update|refactor|migrate|convert|rewrite)\b' || true; } | wc -l | tr -d ' ')

if [[ "$WORD_COUNT" -gt 40 && "$ACTION_VERBS" -gt 2 ]]; then
    CONTEXT_PARTS+=("Large task detected ($WORD_COUNT words, $ACTION_VERBS action verbs). Interaction Style: break this into steps and confirm the approach with the user before implementing.")
elif echo "$PROMPT" | grep -qiE '\beverything\b|\ball of\b|\bentire\b|\bcomprehensive\b|\bcomplete overhaul\b'; then
    CONTEXT_PARTS+=("Broad scope detected. Interaction Style: clarify scope with the user — what specifically should be included/excluded?")
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
