#!/usr/bin/env bash
set -euo pipefail

# Dynamic context injection based on user prompt content.
# UserPromptSubmit hook
#
# Injects contextual information when the user's prompt references:
#   - File paths → inject that file's @decision status
#   - "plan" or "implement" → inject MASTER_PLAN.md phase status
#   - "merge" or "commit" → inject git dirty state

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

HOOK_INPUT=$(read_input)
PROMPT=$(echo "$HOOK_INPUT" | jq -r '.prompt // empty' 2>/dev/null)

# Exit silently if no prompt
[[ -z "$PROMPT" ]] && exit 0

PROJECT_ROOT=$(detect_project_root)
CONTEXT_PARTS=()
SESSION_ID=$(canonical_session_id)

# --- Proof verification removed (TKT-024) ---
# User prompt "verified" no longer flips readiness state.
# Guardian eligibility is now gated on reviewer completion_records and
# evaluation_state, written by SubagentStop hooks (check-reviewer.sh et al).
# @decision DEC-EVAL-004
# @title prompt-submit.sh no longer writes any readiness state
# @status accepted
# @rationale Ceremony (user typing "verified") is not technical proof.
#   evaluation_state, written by SubagentStop check hooks, is the sole authority.
#   (Phase 8 Slice 10 retired the legacy tester producer path; the same rule
#   applies to the reviewer-driven readiness pipeline.)

# --- First-prompt mitigation for session-init bug (Issue #10373) ---
PROMPT_COUNT_FILE="${PROJECT_ROOT}/.claude/.prompt-count-${SESSION_ID}"
if [[ ! -f "$PROMPT_COUNT_FILE" ]]; then
    mkdir -p "${PROJECT_ROOT}/.claude"
    echo "1" > "$PROMPT_COUNT_FILE"
    echo "$(date +%s)" > "${PROJECT_ROOT}/.claude/.session-start-epoch"
    # Inject full session context (same as session-init.sh)
    get_git_state "$PROJECT_ROOT"
    get_plan_status "$PROJECT_ROOT"
    # write_statusline_cache removed (TKT-018): statusline reads runtime directly.
    [[ -n "$GIT_BRANCH" ]] && CONTEXT_PARTS+=("Git: branch=$GIT_BRANCH, $GIT_DIRTY_COUNT uncommitted")
    [[ "$PLAN_EXISTS" == "true" ]] && CONTEXT_PARTS+=("MASTER_PLAN.md: $PLAN_COMPLETED_PHASES/$PLAN_TOTAL_PHASES phases done")
    [[ "$PLAN_EXISTS" == "false" ]] && CONTEXT_PARTS+=("MASTER_PLAN.md: not found (required before implementation)")

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
    # --- Enforcement gap surfacing (first-prompt path) ---
    GAPS_FILE_PS="${PROJECT_ROOT}/.claude/.enforcement-gaps"
    if [[ -f "$GAPS_FILE_PS" && -s "$GAPS_FILE_PS" ]]; then
        while IFS='|' read -r gap_type ext tool _first _count; do
            [[ -z "$gap_type" ]] && continue
            if [[ "$gap_type" == "unsupported" ]]; then
                CONTEXT_PARTS+=("ENFORCEMENT DEGRADED: No linter profile for .${ext} files. Writes to .${ext} source files are not linted.")
            else
                CONTEXT_PARTS+=("ENFORCEMENT DEGRADED: Linter '${tool}' for .${ext} files is not installed. Install it to restore enforcement.")
            fi
        done < "$GAPS_FILE_PS"
    fi
fi

# --- Inject agent findings from previous subagent runs (runtime events) ---
# @decision DEC-FINDINGS-001
# @title Agent findings read from runtime event store, not flat file
# @status accepted
# @rationale .agent-findings flat file writers were migrated to rt_event_emit
#   (agent_finding events) in A5. Readers must use the same authority: the
#   runtime event store. Flat-file reads removed here to eliminate dual-authority.
#   One-shot delivery semantics preserved by querying a bounded recent window
#   (limit 5) rather than clearing a file — events are append-only in the store.
FINDINGS_JSON=$(cc_policy event query --type "agent_finding" --limit 5 2>/dev/null || echo '{"items":[],"count":0}')
FINDINGS_COUNT=$(printf '%s' "$FINDINGS_JSON" | jq -r '.count // 0' 2>/dev/null || echo "0")
if [[ "$FINDINGS_COUNT" -gt 0 ]]; then
    CONTEXT_PARTS+=("Previous agent findings (unresolved):")
    while IFS= read -r detail; do
        [[ -z "$detail" ]] && continue
        agent="${detail%%|*}"
        issues="${detail#*|}"
        CONTEXT_PARTS+=("  ${agent}: ${issues}")
    done < <(printf '%s' "$FINDINGS_JSON" | jq -r '.items[]?.detail // empty' 2>/dev/null)
fi

# --- Auto-claim: detect issue references in action prompts ---
TODO_SCRIPT="$HOME/.claude/scripts/todo.sh"
if [[ -x "$TODO_SCRIPT" ]]; then
    ISSUE_REF=$(echo "$PROMPT" | grep -oiE '\b(work|fix|implement|tackle|start|handle|address)\b.*#([0-9]+)' | grep -oE '#[0-9]+' | head -1 || true)
    if [[ -n "$ISSUE_REF" ]]; then
        ISSUE_NUM="${ISSUE_REF#\#}"
        # Auto-claim — fire and forget, don't block the prompt
        # Fix #465: use -e (exists) instead of -d; in a worktree .git is a file.
        if [[ -e "$PROJECT_ROOT/.git" ]]; then
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
        PLAN_LINE="Plan:"
        [[ "$PLAN_TOTAL_PHASES" -gt 0 ]] && PLAN_LINE="$PLAN_LINE $PLAN_COMPLETED_PHASES/$PLAN_TOTAL_PHASES phases done"
        [[ -n "$PLAN_PHASE" ]] && PLAN_LINE="$PLAN_LINE | active: $PLAN_PHASE"
        [[ "$PLAN_AGE_DAYS" -gt 0 ]] && PLAN_LINE="$PLAN_LINE | age: ${PLAN_AGE_DAYS}d"
        get_session_changes "$PROJECT_ROOT"
        [[ "$SESSION_CHANGED_COUNT" -gt 0 ]] && PLAN_LINE="$PLAN_LINE | $SESSION_CHANGED_COUNT files changed"
        CONTEXT_PARTS+=("$PLAN_LINE")
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

# --- Compaction heuristic (opt-in) ---
# @decision DEC-COMPACT-001
# @title Compaction suggestion hook is explicitly opt-in
# @status accepted
# @rationale The previous fixed-threshold compaction hints added drag in
# long-context sessions (e.g. Opus 1M) where no compaction was needed.
# Suggestions now run only when CLAUDEX_ENABLE_COMPACTION_HINTS=1.
if [[ "${CLAUDEX_ENABLE_COMPACTION_HINTS:-0}" == "1" && -f "$PROMPT_COUNT_FILE" ]]; then
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
    EPOCH_FILE="${PROJECT_ROOT}/.claude/.session-start-epoch"
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
