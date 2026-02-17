#!/usr/bin/env bash
set -euo pipefail

# Structural validation of MASTER_PLAN.md on write/edit.
# PostToolUse hook — matcher: Write|Edit (filtered to MASTER_PLAN.md)
#
# Validates:
#   - Each phase has a Status field (planned/in-progress/completed)
#   - Completed phases have a non-empty Decision Log section
#   - Original intent section exists and wasn't deleted
#   - Decision IDs follow the DEC-COMPONENT-NNN format
#   - REQ-ID format: REQ-{CATEGORY}-{NNN} where CATEGORY in GOAL|NOGO|UJ|P0|P1|P2|MET
#   - New sections exist: Goals, Non-Goals, Requirements (with P0s) — WARNING only
#   - Completed phases reference REQ-IDs in their DoD — WARNING only
#
# Exit 2 triggers feedback loop (same as lint.sh) with fix instructions.

source "$(dirname "$0")/source-lib.sh"

HOOK_INPUT=$(read_input)
FILE_PATH=$(echo "$HOOK_INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

# Only validate MASTER_PLAN.md
if [[ ! "$FILE_PATH" =~ MASTER_PLAN\.md$ ]]; then
    exit 0
fi

# Resolve to absolute path if needed
if [[ ! "$FILE_PATH" = /* ]]; then
    PROJECT_ROOT=$(detect_project_root)
    FILE_PATH="$PROJECT_ROOT/$FILE_PATH"
fi

# File must exist to validate
if [[ ! -f "$FILE_PATH" ]]; then
    exit 0
fi

ISSUES=()

# --- Check for original intent section ---
if ! grep -qiE '^\#.*intent|^\#.*vision|^\#.*user.*request|^\#.*original' "$FILE_PATH" 2>/dev/null; then
    ISSUES+=("Missing original intent/vision section. MASTER_PLAN.md must preserve the user's original request.")
fi

# --- Extract phases and validate structure ---
PHASE_HEADERS=$(grep -nE '^\#\#\s+Phase\s+[0-9]' "$FILE_PATH" 2>/dev/null || echo "")

if [[ -n "$PHASE_HEADERS" ]]; then
    while IFS= read -r phase_line; do
        PHASE_NUM=$(echo "$phase_line" | grep -oE 'Phase\s+[0-9]+' | grep -oE '[0-9]+')
        LINE_NUM=$(echo "$phase_line" | cut -d: -f1)
        PHASE_NAME="${phase_line#*:}"

        # Find the next phase header line number (or end of file)
        NEXT_LINE=$(grep -nE '^\#\#\s+Phase\s+[0-9]' "$FILE_PATH" 2>/dev/null | \
            awk -F: -v curr="$LINE_NUM" '$1 > curr {print $1; exit}')
        if [[ -z "$NEXT_LINE" ]]; then
            NEXT_LINE=$(wc -l < "$FILE_PATH" | tr -d ' ')
        fi

        # Extract phase content between this header and the next
        PHASE_CONTENT=$(sed -n "${LINE_NUM},${NEXT_LINE}p" "$FILE_PATH" 2>/dev/null)

        # Check for Status field
        if ! echo "$PHASE_CONTENT" | grep -qE '\*\*Status:\*\*\s*(planned|in-progress|completed)'; then
            ISSUES+=("Phase $PHASE_NUM: Missing or invalid Status field. Must be one of: planned, in-progress, completed")
        fi

        # Check completed phases have Decision Log content
        if echo "$PHASE_CONTENT" | grep -qE '\*\*Status:\*\*\s*completed'; then
            # Look for Decision Log section with actual content (not just the comment placeholder)
            if ! echo "$PHASE_CONTENT" | grep -qE '###\s+Decision\s+Log'; then
                ISSUES+=("Phase $PHASE_NUM: Completed phase missing Decision Log section")
            else
                # Check that Decision Log has content beyond the placeholder comment
                LOG_SECTION=$(echo "$PHASE_CONTENT" | sed -n '/### *Decision *Log/,/^###/p' | tail -n +2)
                NON_COMMENT=$(echo "$LOG_SECTION" | grep -v '^\s*$' | grep -v '<!--' | grep -v -e '-->' || echo "")
                if [[ -z "$NON_COMMENT" ]]; then
                    ISSUES+=("Phase $PHASE_NUM: Completed phase has empty Decision Log — Guardian must append decision entries")
                fi
            fi
        fi
    done <<< "$PHASE_HEADERS"
fi

# --- Validate Decision ID format ---
DECISION_IDS=$(grep -oE 'DEC-[A-Z]+-[0-9]+' "$FILE_PATH" 2>/dev/null | sort -u || echo "")
if [[ -n "$DECISION_IDS" ]]; then
    while IFS= read -r dec_id; do
        if ! echo "$dec_id" | grep -qE '^DEC-[A-Z]{2,}-[0-9]{3}$'; then
            ISSUES+=("Decision ID '$dec_id' doesn't follow DEC-COMPONENT-NNN format (e.g., DEC-AUTH-001)")
        fi
    done <<< "$DECISION_IDS"
fi

# --- Validate REQ-ID format ---
WARNINGS=()
REQ_IDS=$(grep -oE 'REQ-[A-Z0-9]+-[0-9]+' "$FILE_PATH" 2>/dev/null | sort -u || echo "")
if [[ -n "$REQ_IDS" ]]; then
    while IFS= read -r req_id; do
        if ! echo "$req_id" | grep -qE '^REQ-(GOAL|NOGO|UJ|P0|P1|P2|MET)-[0-9]{3}$'; then
            ISSUES+=("Requirement ID '$req_id' doesn't follow REQ-{CATEGORY}-NNN format (CATEGORY: GOAL|NOGO|UJ|P0|P1|P2|MET)")
        fi
    done <<< "$REQ_IDS"
fi

# --- Advisory: check for new requirements sections (WARNING only) ---
# These are advisory — existing plans without these sections still work.
if ! grep -qiE '^\#\#\s*(Goals|Goals\s*&\s*Non.Goals)' "$FILE_PATH" 2>/dev/null; then
    WARNINGS+=("Missing Goals & Non-Goals section — consider adding structured requirements")
fi
if ! grep -qiE '^\#\#\#\s*Must.Have|^\#\#\s*Requirements' "$FILE_PATH" 2>/dev/null; then
    WARNINGS+=("Missing Requirements section with P0/P1/P2 prioritization")
elif ! grep -qE 'REQ-P0-[0-9]' "$FILE_PATH" 2>/dev/null; then
    WARNINGS+=("Requirements section has no P0 (Must-Have) requirements")
fi
if ! grep -qiE '^\#\#\s*Success\s*Metrics' "$FILE_PATH" 2>/dev/null; then
    WARNINGS+=("Missing Success Metrics section")
fi

# --- Advisory: completed phases should reference REQ-IDs in DoD ---
if [[ -n "$PHASE_HEADERS" ]]; then
    while IFS= read -r phase_line; do
        PHASE_NUM=$(echo "$phase_line" | grep -oE 'Phase\s+[0-9]+' | grep -oE '[0-9]+')
        LINE_NUM=$(echo "$phase_line" | cut -d: -f1)
        NEXT_LINE=$(grep -nE '^\#\#\s+Phase\s+[0-9]' "$FILE_PATH" 2>/dev/null | \
            awk -F: -v curr="$LINE_NUM" '$1 > curr {print $1; exit}')
        [[ -z "$NEXT_LINE" ]] && NEXT_LINE=$(wc -l < "$FILE_PATH" | tr -d ' ')
        PHASE_CONTENT=$(sed -n "${LINE_NUM},${NEXT_LINE}p" "$FILE_PATH" 2>/dev/null)

        if echo "$PHASE_CONTENT" | grep -qE '\*\*Status:\*\*\s*completed'; then
            if ! echo "$PHASE_CONTENT" | grep -qE 'REQ-[A-Z0-9]+-[0-9]+'; then
                WARNINGS+=("Phase $PHASE_NUM: Completed phase does not reference any REQ-IDs")
            fi
        fi
    done <<< "$PHASE_HEADERS"
fi

# Log warnings (advisory only, do not block)
if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    for warn in "${WARNINGS[@]}"; do
        log_info "PLAN-VALIDATE" "WARNING: $warn"
    done
fi

# --- Report ---
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    FEEDBACK="MASTER_PLAN.md structural issues found:\n"
    for issue in "${ISSUES[@]}"; do
        FEEDBACK+="  - $issue\n"
    done
    FEEDBACK+="\nFix these issues to maintain plan integrity."

    log_info "PLAN-VALIDATE" "$(echo -e "$FEEDBACK")"

    # Exit 2 triggers feedback loop
    ESCAPED=$(echo -e "$FEEDBACK" | jq -Rs .)
    cat <<EOF
{
  "decision": "block",
  "reason": $ESCAPED
}
EOF
    exit 2
fi

exit 0
