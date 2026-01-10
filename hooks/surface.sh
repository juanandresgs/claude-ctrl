#!/usr/bin/env bash
set -euo pipefail

# @decision DEC-HOOKS-004
# @title Session-end documentation surfacing
# @status accepted
# @rationale Automatically validates and reports on decision annotations when
#            Claude Code sessions end. Uses project-local tracking to identify
#            which files changed and reports status to guide documentation updates.
# @consequences Users see documentation status at end of each session

source "$(dirname "$0")/status.sh"

# Get the project root from the current working directory
PROJECT_ROOT="${PWD}"
CHANGES="$PROJECT_ROOT/.claude/.session-decisions"

# Exit silently if no changes tracked this session
[[ ! -f "$CHANGES" ]] && exit 0

# Count source file changes (common programming extensions)
SOURCE_COUNT=$(grep -cE '\.(ts|tsx|js|jsx|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php)$' "$CHANGES" 2>/dev/null || echo 0)

if [[ $SOURCE_COUNT -eq 0 ]]; then
    rm -f "$CHANGES"
    exit 0
fi

status "DECISION" "$SOURCE_COUNT source files updated this session"

# Determine source directory (common patterns)
if [[ -d "$PROJECT_ROOT/src" ]]; then
    SRC_DIR="src/"
elif [[ -d "$PROJECT_ROOT/lib" ]]; then
    SRC_DIR="lib/"
elif [[ -d "$PROJECT_ROOT/app" ]]; then
    SRC_DIR="app/"
else
    SRC_DIR="./"
fi

status "SURFACE" "Extracting decisions from $PROJECT_ROOT/$SRC_DIR"

# Count decisions in the codebase (simple grep-based detection)
DECISION_COUNT=$(grep -rE '@decision|# DECISION:|// DECISION:' "$PROJECT_ROOT/$SRC_DIR" 2>/dev/null | wc -l | tr -d ' ' || echo 0)

# Check for new decisions in changed files
NEW_COUNT=0
while IFS= read -r file; do
    if [[ -f "$file" ]] && grep -qE '@decision|# DECISION:|// DECISION:' "$file" 2>/dev/null; then
        ((NEW_COUNT++)) || true
    fi
done < "$CHANGES"

status "SURFACE" "$DECISION_COUNT decisions found, $NEW_COUNT in changed files"

# Check if docs/decisions exists
if [[ -d "$PROJECT_ROOT/docs/decisions" ]]; then
    status "SURFACE" "docs/decisions/ exists — ready to regenerate"
    status "OUTCOME" "Documentation current. Run /project:surface to publish."
else
    status "SURFACE" "docs/decisions/ not found — will be created on first surface"
    status "OUTCOME" "Run /project:surface to initialize documentation."
fi

# Clean up session tracking
rm -f "$CHANGES"
exit 0
