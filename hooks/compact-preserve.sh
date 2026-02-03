#!/usr/bin/env bash
set -euo pipefail

# Pre-compaction context preservation.
# PreCompact hook
#
# Injects project state into additionalContext before compaction so the
# compacted context retains:
#   - Current git branch and status
#   - Files modified this session
#   - MASTER_PLAN.md existence and active phase
#   - Active worktrees

source "$(dirname "$0")/log.sh"

PROJECT_ROOT=$(detect_project_root)
CONTEXT_PARTS=()

# --- Git state ---
if [[ -d "$PROJECT_ROOT/.git" ]]; then
    BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    CONTEXT_PARTS+=("Current branch: $BRANCH")

    DIRTY_COUNT=$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$DIRTY_COUNT" -gt 0 ]]; then
        CONTEXT_PARTS+=("Uncommitted changes: $DIRTY_COUNT files")
    fi

    # Recent commits on this branch
    RECENT=$(git -C "$PROJECT_ROOT" log --oneline -3 2>/dev/null || echo "")
    if [[ -n "$RECENT" ]]; then
        CONTEXT_PARTS+=("Recent commits:")
        while IFS= read -r line; do
            CONTEXT_PARTS+=("  $line")
        done <<< "$RECENT"
    fi

    # Active worktrees
    WORKTREES=$(git -C "$PROJECT_ROOT" worktree list 2>/dev/null | grep -v "(bare)" | tail -n +2)
    if [[ -n "$WORKTREES" ]]; then
        CONTEXT_PARTS+=("Active worktrees:")
        while IFS= read -r line; do
            CONTEXT_PARTS+=("  $line")
        done <<< "$WORKTREES"
    fi
fi

# --- MASTER_PLAN.md ---
if [[ -f "$PROJECT_ROOT/MASTER_PLAN.md" ]]; then
    # Try to extract active phase
    PHASE=$(grep -iE '^\#.*phase|^\*\*Phase' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null | tail -1 || echo "")
    if [[ -n "$PHASE" ]]; then
        CONTEXT_PARTS+=("MASTER_PLAN.md: active ($PHASE)")
    else
        CONTEXT_PARTS+=("MASTER_PLAN.md: exists")
    fi
fi

# --- Session file changes (mirrors surface.sh fallback logic) ---
SESSION_ID="${CLAUDE_SESSION_ID:-}"
SESSION_FILE=""
if [[ -n "$SESSION_ID" && -f "$PROJECT_ROOT/.claude/.session-changes-${SESSION_ID}" ]]; then
    SESSION_FILE="$PROJECT_ROOT/.claude/.session-changes-${SESSION_ID}"
elif [[ -f "$PROJECT_ROOT/.claude/.session-changes" ]]; then
    SESSION_FILE="$PROJECT_ROOT/.claude/.session-changes"
else
    # Glob fallback for any session file (legacy or mismatched ID)
    SESSION_FILE=$(ls "$PROJECT_ROOT/.claude/.session-changes"* 2>/dev/null | head -1 || echo "")
    # Also check legacy name
    if [[ -z "$SESSION_FILE" ]]; then
        SESSION_FILE=$(ls "$PROJECT_ROOT/.claude/.session-decisions"* 2>/dev/null | head -1 || echo "")
    fi
fi

if [[ -n "$SESSION_FILE" && -f "$SESSION_FILE" ]]; then
    FILE_COUNT=$(sort -u "$SESSION_FILE" | wc -l | tr -d ' ')
    CONTEXT_PARTS+=("Files modified this session: $FILE_COUNT")
    # List unique files
    while IFS= read -r f; do
        CONTEXT_PARTS+=("  $f")
    done < <(sort -u "$SESSION_FILE" | head -20)

    # --- Key @decisions made this session ---
    # Scan modified files for @decision annotations to preserve decision context
    DECISION_PATTERN='@decision|# DECISION:|// DECISION\('
    DECISIONS_FOUND=()
    while IFS= read -r file; do
        [[ ! -f "$file" ]] && continue
        # Extract decision IDs/titles from this file
        decision_line=$(grep -oE '@decision\s+[A-Z]+-[A-Z0-9-]+|# DECISION:\s*[^.]+|// DECISION\([^)]+\)' "$file" 2>/dev/null | head -1 || echo "")
        if [[ -n "$decision_line" ]]; then
            DECISIONS_FOUND+=("$(basename "$file"): $decision_line")
        fi
    done < <(sort -u "$SESSION_FILE")

    if [[ ${#DECISIONS_FOUND[@]} -gt 0 ]]; then
        CONTEXT_PARTS+=("Key @decisions this session:")
        for dec in "${DECISIONS_FOUND[@]:0:10}"; do
            CONTEXT_PARTS+=("  $dec")
        done
    fi
fi

# --- Feedback spine state ---
TEST_STATUS="${PROJECT_ROOT}/.claude/.test-status"
if [[ -f "$TEST_STATUS" ]]; then
    TS_RESULT=$(cut -d'|' -f1 "$TEST_STATUS")
    TS_FAILS=$(cut -d'|' -f2 "$TEST_STATUS")
    CONTEXT_PARTS+=("Test status: ${TS_RESULT} (${TS_FAILS} failures)")
fi

AUDIT_LOG="${PROJECT_ROOT}/.claude/.audit-log"
if [[ -f "$AUDIT_LOG" && -s "$AUDIT_LOG" ]]; then
    CONTEXT_PARTS+=("Recent audit (last 5):")
    while IFS= read -r line; do
        CONTEXT_PARTS+=("  $line")
    done < <(tail -5 "$AUDIT_LOG")
fi

# --- Output ---
if [[ ${#CONTEXT_PARTS[@]} -gt 0 ]]; then
    CONTEXT=$(printf '%s\n' "${CONTEXT_PARTS[@]}")
    ESCAPED=$(echo "$CONTEXT" | jq -Rs .)
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
