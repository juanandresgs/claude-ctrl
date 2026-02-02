#!/usr/bin/env bash
set -euo pipefail

# Stop hook: deterministic session summary.
# Replaces AI agent Stop hook. Reads session tracking, produces concise summary.
# Bounded runtime (<2s). Reports via systemMessage.
#
# DECISION: Deterministic session summary. Rationale: AI agent Stop hooks cause
# "stuck on Stop hooks 2/3" lockup due to non-deterministic inference time.
# Every metric here is a wc/grep that completes instantly. Status: accepted.

source "$(dirname "$0")/log.sh"

HOOK_INPUT=$(read_input)

# Prevent re-firing loops
STOP_ACTIVE=$(echo "$HOOK_INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
if [[ "$STOP_ACTIVE" == "true" ]]; then
    exit 0
fi

PROJECT_ROOT=$(detect_project_root)

# Find session tracking file
SESSION_ID="${CLAUDE_SESSION_ID:-}"
CHANGES=""
if [[ -n "$SESSION_ID" && -f "$PROJECT_ROOT/.claude/.session-changes-${SESSION_ID}" ]]; then
    CHANGES="$PROJECT_ROOT/.claude/.session-changes-${SESSION_ID}"
elif [[ -f "$PROJECT_ROOT/.claude/.session-changes" ]]; then
    CHANGES="$PROJECT_ROOT/.claude/.session-changes"
else
    # Glob fallback
    CHANGES=$(ls "$PROJECT_ROOT/.claude/.session-changes"* 2>/dev/null | head -1 || echo "")
fi

# No tracking file → no summary needed
if [[ -z "$CHANGES" || ! -f "$CHANGES" ]]; then
    exit 0
fi

# Count unique files changed
TOTAL_FILES=$(sort -u "$CHANGES" | wc -l | tr -d ' ')

# Count source vs non-source
SOURCE_EXTS='(ts|tsx|js|jsx|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php|sh|bash|zsh)'
SOURCE_COUNT=$(sort -u "$CHANGES" | grep -cE "\\.${SOURCE_EXTS}$" 2>/dev/null) || SOURCE_COUNT=0
CONFIG_COUNT=$(( TOTAL_FILES - SOURCE_COUNT ))

# Check for @decision annotations added this session
DECISIONS_ADDED=0
DECISION_PATTERN='@decision|# DECISION:|// DECISION\('
while IFS= read -r file; do
    [[ ! -f "$file" ]] && continue
    if grep -qE "$DECISION_PATTERN" "$file" 2>/dev/null; then
        ((DECISIONS_ADDED++)) || true
    fi
done < <(sort -u "$CHANGES")

# Build summary (3-4 lines max)
SUMMARY="Session: $TOTAL_FILES file(s) changed"
if [[ "$SOURCE_COUNT" -gt 0 ]]; then
    SUMMARY+=" ($SOURCE_COUNT source, $CONFIG_COUNT config/other)"
fi
if [[ "$DECISIONS_ADDED" -gt 0 ]]; then
    SUMMARY+=". $DECISIONS_ADDED file(s) with @decision annotations."
fi

# Git state
BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
DIRTY=$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
if [[ "$DIRTY" -gt 0 ]]; then
    SUMMARY+="\nGit: branch=$BRANCH, $DIRTY uncommitted change(s)."
else
    SUMMARY+="\nGit: branch=$BRANCH, clean."
fi

# Output as systemMessage
ESCAPED=$(echo -e "$SUMMARY" | jq -Rs .)
cat <<EOF
{
  "systemMessage": $ESCAPED
}
EOF

exit 0
