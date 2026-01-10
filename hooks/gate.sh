#!/usr/bin/env bash
set -euo pipefail

# @decision DEC-HOOKS-003
# @title Annotation enforcement gate with warn mode
# @status accepted
# @rationale Enforces decision annotations on significant source files (>50 lines)
#            while defaulting to warn mode to avoid disrupting existing workflows.
#            Users can opt-in to enforcement via GATE_MODE=enforce.
# @alternatives Considered: always-enforce, per-project config, file-size threshold only
# @consequences New source files will show warnings until annotated; CI can enforce

# Configuration: Set to "enforce" to block, "warn" to allow with warning
GATE_MODE="${GATE_MODE:-warn}"

source "$(dirname "$0")/status.sh"

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')

# Exit silently if no file path
[[ -z "$FILE" ]] && exit 0

# Only gate source files (common programming languages)
[[ ! "$FILE" =~ \.(ts|tsx|js|jsx|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php)$ ]] && exit 0

# Skip config files, test files, and generated files
[[ "$FILE" =~ (\.config\.|\.test\.|\.spec\.|__tests__|\.generated\.|\.min\.) ]] && exit 0

# Skip files in common non-source directories
[[ "$FILE" =~ (node_modules|vendor|dist|build|\.next|__pycache__|\.git) ]] && exit 0

# Count lines (handle empty content gracefully)
if [[ -z "$CONTENT" ]]; then
    exit 0
fi
LINES=$(echo "$CONTENT" | wc -l | tr -d ' ')
[[ $LINES -lt 50 ]] && exit 0

# Check for decision annotation patterns
if echo "$CONTENT" | grep -qE '@decision|# DECISION:|// DECISION:|/\*\* *\n? *\* *@decision'; then
    # Extract decision ID for reporting
    DECISION_ID=$(echo "$CONTENT" | grep -oE '(ADR|DEC)-[A-Z0-9]+-[0-9]+' | head -1)
    if [[ -n "$DECISION_ID" ]]; then
        status "GATE" "$FILE ready — $DECISION_ID documented"
    else
        status "GATE" "$FILE ready — decision annotation present"
    fi
    exit 0
fi

status "GATE" "$FILE requires decision annotation"

cat >&2 << 'EOF'
This source file requires a decision annotation. Add one of:

TypeScript/JavaScript block:
/**
 * @decision DEC-XXX-001
 * @title Brief description
 * @status accepted
 * @rationale Why this approach
 */

Python/Shell inline:
# DECISION: Title. Rationale: reason. Status: accepted.

Go/Rust inline:
// DECISION(DEC-XXX-001): Title. Rationale: reason.
EOF

# Warn mode: allow but warn; Enforce mode: block
if [[ "$GATE_MODE" == "enforce" ]]; then
    exit 2
else
    exit 0
fi
