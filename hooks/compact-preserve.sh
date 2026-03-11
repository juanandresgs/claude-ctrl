#!/usr/bin/env bash
set -euo pipefail

# Pre-compaction context preservation.
# PreCompact hook
#
# Two outputs:
#   1. Persistent file: .claude/.preserved-context (survives compaction, read by session-init.sh)
#   2. additionalContext: injected into the system message before compaction
#
# The additionalContext includes a directive instructing Claude to generate
# a structured context summary (per context-preservation skill) as part of
# the compaction. This ensures session intent (not just project state) survives.

source "$(dirname "$0")/source-lib.sh"

require_session
require_git
require_plan
require_trace  # for TRACE_STORE (active trace listing at compaction time)
require_state  # W5-1: needed for proof_state_get

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)
CONTEXT_PARTS=()

# --- Git state (via shared library) ---
get_git_state "$PROJECT_ROOT"

if [[ -n "$GIT_BRANCH" ]]; then
    GIT_LINE="Git: $GIT_BRANCH | $GIT_DIRTY_COUNT uncommitted"
    [[ "$GIT_WT_COUNT" -gt 0 ]] && GIT_LINE="$GIT_LINE | $GIT_WT_COUNT worktrees"
    CONTEXT_PARTS+=("$GIT_LINE")

    # Include worktree details (branch names help resume context)
    if [[ -n "$GIT_WORKTREES" ]]; then
        while IFS= read -r wt_line; do
            CONTEXT_PARTS+=("  worktree: $wt_line")
        done <<< "$GIT_WORKTREES"
    fi
fi

# --- MASTER_PLAN.md preamble: preserve for post-compaction context ---
# Living-document format: extract ## Identity + ## Architecture sections (bounded, ~25 lines).
# Legacy format: extract pre-`---` or pre-`## Original Intent` preamble.
if [[ -f "$PROJECT_ROOT/MASTER_PLAN.md" ]]; then
    HAS_INITIATIVES=$(grep -cE '^\#\#\#\s+Initiative:' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null || echo "0")
    if [[ "$HAS_INITIATIVES" -gt 0 ]]; then
        # Living-document format: bounded extraction of permanent sections
        IDENTITY_SECTION=$(awk '/^## Identity/{f=1; next} f && /^## /{exit} f{print}' \
            "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null | head -12)
        ARCH_SECTION=$(awk '/^## Architecture/{f=1; next} f && /^## /{exit} f{print}' \
            "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null | head -10)
        PREAMBLE=""
        [[ -n "$IDENTITY_SECTION" ]] && PREAMBLE="## Identity
${IDENTITY_SECTION}"
        [[ -n "$ARCH_SECTION" ]] && PREAMBLE="${PREAMBLE}
## Architecture
${ARCH_SECTION}"

        # Extract active initiative names for post-compaction resume context
        ACTIVE_INIT_NAMES=$(awk '
            /^## Active Initiatives/{in_active=1; next}
            in_active && /^## /{in_active=0; next}
            in_active && /^\#\#\# Initiative:/ { name=substr($0, index($0,":")+2) }
            in_active && /^\*\*Status:\*\* active/ { print name }
        ' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null | head -5 | paste -sd', ' - || echo "")
        if [[ -n "$ACTIVE_INIT_NAMES" ]]; then
            PREAMBLE="${PREAMBLE}
Active initiatives: ${ACTIVE_INIT_NAMES}"
        fi
    else
        # Legacy format: extract pre-`---` or pre-`## Original Intent` preamble
        PREAMBLE=$(awk '/^---$|^## Original Intent/{exit} {print}' "$PROJECT_ROOT/MASTER_PLAN.md" | head -30)
    fi
    if [[ -n "$PREAMBLE" ]]; then
        CONTEXT_PARTS+=("$PREAMBLE")
    fi
fi

# --- MASTER_PLAN.md (via shared library) ---
get_plan_status "$PROJECT_ROOT"

if [[ "$PLAN_EXISTS" == "true" ]]; then
    PLAN_LINE="Plan: $PLAN_COMPLETED_PHASES/$PLAN_TOTAL_PHASES phases done"
    [[ -n "$PLAN_PHASE" ]] && PLAN_LINE="$PLAN_LINE | active: $PLAN_PHASE"
    CONTEXT_PARTS+=("$PLAN_LINE")
fi

# --- Session file changes ---
get_session_changes "$PROJECT_ROOT"

if [[ -n "$SESSION_FILE" && -f "$SESSION_FILE" ]]; then
    FILE_COUNT=$(sort -u "$SESSION_FILE" | wc -l | tr -d ' ')
    FILE_LIST=$(sort -u "$SESSION_FILE" | head -5 | xargs -I{} basename {} | paste -sd', ' -)
    REMAINING=$((FILE_COUNT - 5))
    if [[ "$REMAINING" -gt 0 ]]; then
        CONTEXT_PARTS+=("Modified this session: $FILE_LIST (+$REMAINING more)")
    else
        CONTEXT_PARTS+=("Modified this session: $FILE_LIST")
    fi

    # Full paths for context (written to file, not displayed)
    FULL_PATHS=$(sort -u "$SESSION_FILE" | head -10)

    # --- Key @decisions made this session ---
    DECISIONS_FOUND=()
    while IFS= read -r file; do
        [[ ! -f "$file" ]] && continue
        decision_line=$(grep -oE '@decision\s+[A-Z]+-[A-Z0-9-]+' "$file" 2>/dev/null | head -1 || echo "")
        if [[ -n "$decision_line" ]]; then
            DECISIONS_FOUND+=("$decision_line ($(basename "$file"))")
        fi
    done < <(sort -u "$SESSION_FILE")

    if [[ ${#DECISIONS_FOUND[@]} -gt 0 ]]; then
        DECISIONS_LINE=$(printf '%s, ' "${DECISIONS_FOUND[@]:0:5}")
        CONTEXT_PARTS+=("Decisions: ${DECISIONS_LINE%, }")
    fi
fi

# --- Proof state ---
# W5-1: Primary read via proof_state_get (SQLite). Falls back to flat files.
# W5-2: Remove flat-file fallback when all readers use proof_state_get.
_PHASH_CP=$(project_hash "$PROJECT_ROOT")
_CP_PROOF_VAL=""
_CP_PSG=$(proof_state_get "$PROJECT_ROOT" 2>/dev/null || true)
if [[ -n "$_CP_PSG" ]]; then
    _CP_PROOF_VAL=$(printf '%s' "$_CP_PSG" | cut -d'|' -f1)
else
    # Flat-file fallback (W5-2 remove)
    _CP_NEW_PROOF="${CLAUDE_DIR}/state/${_PHASH_CP}/proof-status"  # W5-2 remove
    _CP_OLD_PROOF="${CLAUDE_DIR}/.proof-status-${_PHASH_CP}"        # W5-2 remove
    if [[ -f "$_CP_NEW_PROOF" ]]; then
        _CP_PROOF_VAL=$(cut -d'|' -f1 "$_CP_NEW_PROOF" 2>/dev/null || echo "")
    elif [[ -f "$_CP_OLD_PROOF" ]]; then
        _CP_PROOF_VAL=$(cut -d'|' -f1 "$_CP_OLD_PROOF" 2>/dev/null || echo "")
    fi
fi
if [[ -n "$_CP_PROOF_VAL" && "$_CP_PROOF_VAL" != "none" ]]; then
    CONTEXT_PARTS+=("Proof status: ${_CP_PROOF_VAL}")
fi

# --- Test status ---
# Check new path (state/{phash}/test-status) first, fall back to legacy .test-status
TEST_STATUS="${CLAUDE_DIR}/state/${_PHASH_CP}/test-status"
if [[ ! -f "$TEST_STATUS" ]]; then
    TEST_STATUS="${CLAUDE_DIR}/.test-status"
fi
if [[ -f "$TEST_STATUS" ]]; then
    TS_RESULT=$(cut -d'|' -f1 "$TEST_STATUS")
    TS_FAILS=$(cut -d'|' -f2 "$TEST_STATUS")
    CONTEXT_PARTS+=("Test status: ${TS_RESULT} (${TS_FAILS} failures)")
fi

# --- Agent findings (unresolved issues from subagents) ---
FINDINGS_FILE="${CLAUDE_DIR}/.agent-findings"
if [[ -f "$FINDINGS_FILE" && -s "$FINDINGS_FILE" ]]; then
    CONTEXT_PARTS+=("Unresolved agent findings:")
    while IFS= read -r line; do
        CONTEXT_PARTS+=("  $line")
    done < "$FINDINGS_FILE"
fi

# --- Active traces ---
if [[ -d "$TRACE_STORE" ]]; then
    for marker in "$TRACE_STORE"/.active-*; do
        [[ ! -f "$marker" ]] && continue
        active_trace_id=$(cat "$marker" 2>/dev/null || echo "")
        if [[ -n "$active_trace_id" ]]; then
            CONTEXT_PARTS+=("Active trace: $active_trace_id (agent still running). TRACE_DIR=~/.claude/traces/$active_trace_id")
        fi
    done
fi

# --- Audit trail (last 5) ---
AUDIT_LOG="${CLAUDE_DIR}/.audit-log"
if [[ -f "$AUDIT_LOG" && -s "$AUDIT_LOG" ]]; then
    CONTEXT_PARTS+=("Recent audit (last 5):")
    while IFS= read -r line; do
        CONTEXT_PARTS+=("  $line")
    done < <(tail -5 "$AUDIT_LOG")
fi

# --- Session trajectory ---
TRAJ_SUMMARY=$(get_session_summary_context "$PROJECT_ROOT")
if [[ -n "$TRAJ_SUMMARY" ]]; then
    CONTEXT_PARTS+=("$TRAJ_SUMMARY")
fi

# --- Resume directive ---
build_resume_directive "$PROJECT_ROOT"
if [[ -n "$RESUME_DIRECTIVE" ]]; then
    CONTEXT_PARTS+=("")
    CONTEXT_PARTS+=("$RESUME_DIRECTIVE")
fi

# --- Write persistent file ---
# This file survives compaction and is read by session-init.sh on the
# SessionStart(compact) event. Belt-and-suspenders: even if the
# additionalContext is lost during compaction, session-init.sh can
# re-inject this data.
PRESERVE_FILE="${CLAUDE_DIR}/.preserved-context"
if [[ ${#CONTEXT_PARTS[@]} -gt 0 ]]; then
    mkdir -p "$PROJECT_ROOT/.claude"
    {
        echo "# Preserved context from pre-compaction ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
        printf '%s\n' "${CONTEXT_PARTS[@]}"
        # Include full file paths for re-navigation
        if [[ -n "${FULL_PATHS:-}" ]]; then
            echo ""
            echo "# Full paths of session-modified files:"
            echo "$FULL_PATHS"
        fi
    } > "$PRESERVE_FILE"
fi

# --- Output additionalContext ---
# Includes both the project state AND a directive for Claude to generate
# a structured context summary during compaction.
if [[ ${#CONTEXT_PARTS[@]} -gt 0 ]]; then
    DIRECTIVE="POST-COMPACTION: The RESUME DIRECTIVE below was computed from session state. Preserve it verbatim in the summary — it tells the next session what to do."

    CONTEXT=$(printf '%s\n' "${CONTEXT_PARTS[@]}")
    FULL_OUTPUT="${DIRECTIVE}

--- Project State ---
${CONTEXT}"
    ESCAPED=$(echo "$FULL_OUTPUT" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreCompact",
    "additionalContext": $ESCAPED
  }
}
EOF
fi

exit 0
