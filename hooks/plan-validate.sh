#!/usr/bin/env bash
set -euo pipefail

# Structural validation of MASTER_PLAN.md on write/edit.
# PostToolUse hook — matcher: Write|Edit (filtered to MASTER_PLAN.md)
#
# @decision DEC-PLAN-003
# @title Initiative-level structure validation for living plan format
# @status accepted
# @rationale New living-document format uses ### Initiative: headers with #### Phase N:
#   inside initiatives. Old format (## Phase N: at document level) still supported for
#   backward compatibility. Validation adapts: new format checks ## Identity + ## Active
#   Initiatives sections and ### Initiative: Status fields; old format checks ## Phase N:
#   Status fields. Advisory warning (not error) for empty Decision Log.
#
# Validates (new format — ### Initiative: present):
#   - ## Identity section exists
#   - ## Active Initiatives section exists
#   - Each ### Initiative: has a **Status:** field (active|completed)
#   - Original intent/vision section preserved
#   - Decision IDs follow DEC-COMPONENT-NNN format
#   - REQ-ID format valid
#   - Decision Log non-empty — advisory WARNING only
#
# Validates (old format — ## Phase N: at document level):
#   - Each phase has a Status field (planned/in-progress/completed)
#   - Completed phases have a non-empty Decision Log section
#   - Original intent/vision section preserved
#   - Decision IDs follow DEC-COMPONENT-NNN format
#   - REQ-ID format valid
#
# Exit 2 triggers feedback loop (same as lint.sh) with fix instructions.

source "$(dirname "$0")/source-lib.sh"

HOOK_INPUT=$(read_input)
FILE_PATH=$(get_field '.tool_input.file_path')

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
WARNINGS=()

# --- Detect format: new (### Initiative:) vs old (## Phase N:) ---
HAS_INITIATIVES=$(grep -cE '^\#\#\#\s+Initiative:' "$FILE_PATH" 2>/dev/null || echo "0")
HAS_OLD_PHASES=$(grep -cE '^\#\#\s+Phase\s+[0-9]' "$FILE_PATH" 2>/dev/null || echo "0")

# --- Check for original intent section (required in both formats) ---
if ! grep -qiE '^\#.*intent|^\#.*vision|^\#.*user.*request|^\#.*original' "$FILE_PATH" 2>/dev/null; then
    ISSUES+=("Missing original intent/vision section. MASTER_PLAN.md must preserve the user's original request.")
fi

# Initialize PHASE_HEADERS before format branches — only assigned in old-format branch.
# Without this, referencing $PHASE_HEADERS at line 199 with set -u crashes when the
# new format is detected (### Initiative: present, old ## Phase N: absent).
PHASE_HEADERS=""

if [[ "$HAS_INITIATIVES" -gt 0 ]]; then
    # ================================================================
    # NEW FORMAT: living-document with ### Initiative: headers
    # ================================================================

    # --- Required sections ---
    if ! grep -qE '^\#\#\s+Identity' "$FILE_PATH" 2>/dev/null; then
        ISSUES+=("Missing '## Identity' section. New living-plan format requires Identity (type, root, dates).")
    fi

    if ! grep -qE '^\#\#\s+Active Initiatives' "$FILE_PATH" 2>/dev/null; then
        ISSUES+=("Missing '## Active Initiatives' section. New format requires this section.")
    fi

    # --- Validate each ### Initiative: has a **Status:** field ---
    INITIATIVE_HEADERS=$(grep -nE '^\#\#\#\s+Initiative:' "$FILE_PATH" 2>/dev/null || echo "")
    if [[ -n "$INITIATIVE_HEADERS" ]]; then
        while IFS= read -r init_line; do
            INIT_LINE_NUM=$(echo "$init_line" | cut -d: -f1)
            INIT_NAME=$(echo "$init_line" | sed 's/^[0-9]*:### Initiative: *//')

            # Find end of this initiative block (next ### Initiative: or ## section)
            NEXT_LINE=$(grep -nE '^\#\#\#\s+Initiative:|^\#\#\s+' "$FILE_PATH" 2>/dev/null | \
                awk -F: -v curr="$INIT_LINE_NUM" '$1 > curr {print $1; exit}')
            [[ -z "$NEXT_LINE" ]] && NEXT_LINE=$(wc -l < "$FILE_PATH" | tr -d ' ')

            INIT_CONTENT=$(sed -n "${INIT_LINE_NUM},${NEXT_LINE}p" "$FILE_PATH" 2>/dev/null)

            # Initiative must have a Status field
            if ! echo "$INIT_CONTENT" | grep -qE '^\*\*Status:\*\*\s*(active|completed|planned)'; then
                ISSUES+=("Initiative '$INIT_NAME': Missing or invalid **Status:** field. Must be: active, completed, or planned.")
            fi

            # Each #### Phase within this initiative must have a Status field
            PHASE_HEADERS_IN_INIT=$(echo "$INIT_CONTENT" | grep -nE '^\#\#\#\#\s+Phase\s+[0-9]' || echo "")
            if [[ -n "$PHASE_HEADERS_IN_INIT" ]]; then
                while IFS= read -r phase_line; do
                    PHASE_NUM=$(echo "$phase_line" | grep -oE 'Phase\s+[0-9]+' | grep -oE '[0-9]+')
                    PHASE_LINE_NUM=$(echo "$phase_line" | cut -d: -f1)
                    PHASE_NEXT=$(echo "$INIT_CONTENT" | grep -nE '^\#\#\#\#\s+Phase\s+[0-9]' | \
                        awk -F: -v curr="$PHASE_LINE_NUM" '$1 > curr {print $1; exit}')
                    [[ -z "$PHASE_NEXT" ]] && PHASE_NEXT=$(echo "$INIT_CONTENT" | wc -l | tr -d ' ')
                    PHASE_CONTENT=$(echo "$INIT_CONTENT" | sed -n "${PHASE_LINE_NUM},${PHASE_NEXT}p" 2>/dev/null)
                    if ! echo "$PHASE_CONTENT" | grep -qE '\*\*Status:\*\*\s*(planned|in-progress|completed)'; then
                        ISSUES+=("Initiative '$INIT_NAME' Phase $PHASE_NUM: Missing or invalid Status field.")
                    fi
                done <<< "$PHASE_HEADERS_IN_INIT"
            fi
        done <<< "$INITIATIVE_HEADERS"
    fi

    # --- Advisory: Decision Log should have entries ---
    DEC_LOG_SECTION=$(awk '/^## Decision Log/{f=1} f && /^---/{exit} f{print}' "$FILE_PATH" 2>/dev/null || echo "")
    DEC_LOG_ENTRIES=$(echo "$DEC_LOG_SECTION" | grep -cE '^\|\s+[0-9]{4}' 2>/dev/null || echo "0")
    if [[ "$DEC_LOG_ENTRIES" -eq 0 ]]; then
        WARNINGS+=("Decision Log has no entries yet. Append decisions as work progresses.")
    fi

elif [[ "$HAS_OLD_PHASES" -gt 0 ]]; then
    # ================================================================
    # OLD FORMAT: ## Phase N: at document level (backward compatibility)
    # ================================================================
    PHASE_HEADERS=$(grep -nE '^\#\#\s+Phase\s+[0-9]' "$FILE_PATH" 2>/dev/null || echo "")

    while IFS= read -r phase_line; do
        PHASE_NUM=$(echo "$phase_line" | grep -oE 'Phase\s+[0-9]+' | grep -oE '[0-9]+')
        LINE_NUM=$(echo "$phase_line" | cut -d: -f1)

        # Find the next phase header line number (or end of file)
        NEXT_LINE=$(grep -nE '^\#\#\s+Phase\s+[0-9]' "$FILE_PATH" 2>/dev/null | \
            awk -F: -v curr="$LINE_NUM" '$1 > curr {print $1; exit}')
        if [[ -z "$NEXT_LINE" ]]; then
            NEXT_LINE=$(wc -l < "$FILE_PATH" | tr -d ' ')
        fi

        PHASE_CONTENT=$(sed -n "${LINE_NUM},${NEXT_LINE}p" "$FILE_PATH" 2>/dev/null)

        # Check for Status field
        if ! echo "$PHASE_CONTENT" | grep -qE '\*\*Status:\*\*\s*(planned|in-progress|completed)'; then
            ISSUES+=("Phase $PHASE_NUM: Missing or invalid Status field. Must be one of: planned, in-progress, completed")
        fi

        # Check completed phases have Decision Log content
        if echo "$PHASE_CONTENT" | grep -qE '\*\*Status:\*\*\s*completed'; then
            if ! echo "$PHASE_CONTENT" | grep -qE '###\s+Decision\s+Log'; then
                ISSUES+=("Phase $PHASE_NUM: Completed phase missing Decision Log section")
            else
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
