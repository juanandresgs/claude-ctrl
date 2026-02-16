#!/usr/bin/env bash
set -euo pipefail

# Session-end decision validation and audit.
# Stop hook — runs when Claude finishes responding.
#
# Performs the full /surface pipeline: extract → validate → report.
# No external documentation is generated (Code is Truth).
# Reports: files changed, @decision coverage, validation issues,
#   REQ-ID traceability (P0s addressed by DEC-IDs), non-goal violations.
#
# Checks stop_hook_active to prevent re-firing loops.

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

HOOK_INPUT=$(read_input)

# --- Prevent re-firing loops ---
# stop_hook_active is true if this Stop hook already ran and produced output
STOP_ACTIVE=$(echo "$HOOK_INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
if [[ "$STOP_ACTIVE" == "true" ]]; then
    exit 0
fi

# Get project root (prefers CLAUDE_PROJECT_DIR)
PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)

# Find session tracking file (try session-scoped first, fall back to legacy)
SESSION_ID="${CLAUDE_SESSION_ID:-}"
if [[ -n "$SESSION_ID" && -f "${CLAUDE_DIR}/.session-changes-${SESSION_ID}" ]]; then
    CHANGES="${CLAUDE_DIR}/.session-changes-${SESSION_ID}"
elif [[ -f "${CLAUDE_DIR}/.session-changes" ]]; then
    CHANGES="${CLAUDE_DIR}/.session-changes"
else
    # Glob fallback for any session file
    # shellcheck disable=SC2012
    CHANGES=$(ls "${CLAUDE_DIR}/.session-changes"* 2>/dev/null | head -1 || echo "")
    # Also check legacy name
    if [[ -z "$CHANGES" ]]; then
        # shellcheck disable=SC2012
        CHANGES=$(ls "${CLAUDE_DIR}/.session-decisions"* 2>/dev/null | head -1 || echo "")
    fi
fi

# Exit silently if no changes tracked
[[ -z "$CHANGES" || ! -f "$CHANGES" ]] && exit 0

# --- Count source file changes ---
# Uses SOURCE_EXTENSIONS from context-lib.sh
SOURCE_EXTS="($SOURCE_EXTENSIONS)"
SOURCE_COUNT=$(grep -cE "\\.${SOURCE_EXTS}$" "$CHANGES" 2>/dev/null) || SOURCE_COUNT=0

if [[ "$SOURCE_COUNT" -eq 0 ]]; then
    rm -f "$CHANGES"
    exit 0
fi

log_info "SURFACE" "$SOURCE_COUNT source files modified this session"

# --- Extract: find all @decision annotations in the project ---
# Determine source directories to scan
SCAN_DIRS=()
for dir in src lib app pkg cmd internal; do
    [[ -d "$PROJECT_ROOT/$dir" ]] && SCAN_DIRS+=("$PROJECT_ROOT/$dir")
done
# Fall back to project root if no standard dirs found
[[ ${#SCAN_DIRS[@]} -eq 0 ]] && SCAN_DIRS=("$PROJECT_ROOT")

DECISION_PATTERN='@decision|# DECISION:|// DECISION\('
TOTAL_DECISIONS=0
DECISIONS_IN_CHANGED=0
MISSING_DECISIONS=()
VALIDATION_ISSUES=()

# Count total decisions in codebase (use ripgrep for 10-100x speedup)
for dir in "${SCAN_DIRS[@]}"; do
    if command -v rg &>/dev/null; then
        count=$(rg -l "$DECISION_PATTERN" "$dir" \
            --glob '*.ts' --glob '*.tsx' --glob '*.js' --glob '*.jsx' \
            --glob '*.py' --glob '*.rs' --glob '*.go' --glob '*.java' \
            --glob '*.c' --glob '*.cpp' --glob '*.h' --glob '*.hpp' \
            --glob '*.sh' --glob '*.rb' --glob '*.php' \
            2>/dev/null | wc -l | tr -d ' ') || count=0
    else
        count=$(grep -rlE "$DECISION_PATTERN" "$dir" \
            --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' \
            --include='*.py' --include='*.rs' --include='*.go' --include='*.java' \
            --include='*.c' --include='*.cpp' --include='*.h' --include='*.hpp' \
            --include='*.sh' --include='*.rb' --include='*.php' \
            2>/dev/null | wc -l | tr -d ' ') || count=0
    fi
    TOTAL_DECISIONS=$((TOTAL_DECISIONS + count))
done

# --- Validate: check changed files ---
while IFS= read -r file; do
    [[ ! -f "$file" ]] && continue
    # Only check source files (uses shared is_source_file from context-lib.sh)
    is_source_file "$file" || continue
    # Skip test/config/generated
    is_skippable_path "$file" && continue

    # Check if file has @decision
    if grep -qE "$DECISION_PATTERN" "$file" 2>/dev/null; then
        ((DECISIONS_IN_CHANGED++)) || true

        # Validate decision has rationale
        if ! grep -qE '@rationale|Rationale:' "$file" 2>/dev/null; then
            VALIDATION_ISSUES+=("$file: @decision missing rationale")
        fi
    else
        # Check if file is significant
        line_count=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
        if [[ "$line_count" -ge "$DECISION_LINE_THRESHOLD" ]]; then
            MISSING_DECISIONS+=("$file ($line_count lines, no @decision)")
        fi
    fi
done < <(sort -u "$CHANGES")

# --- Report ---
log_info "SURFACE" "Scanned project: $TOTAL_DECISIONS @decision annotations found"
log_info "SURFACE" "$DECISIONS_IN_CHANGED decisions in files changed this session"

if [[ ${#MISSING_DECISIONS[@]} -gt 0 ]]; then
    log_info "SURFACE" "Missing annotations in significant files:"
    for missing in "${MISSING_DECISIONS[@]}"; do
        log_info "SURFACE" "  - $missing"
    done
fi

if [[ ${#VALIDATION_ISSUES[@]} -gt 0 ]]; then
    log_info "SURFACE" "Validation issues:"
    for issue in "${VALIDATION_ISSUES[@]}"; do
        log_info "SURFACE" "  - $issue"
    done
fi

# Summary
TOTAL_CHANGED=$(sort -u "$CHANGES" | grep -cE "\\.${SOURCE_EXTS}$" 2>/dev/null) || TOTAL_CHANGED=0
MISSING_COUNT=${#MISSING_DECISIONS[@]}
ISSUE_COUNT=${#VALIDATION_ISSUES[@]}

if [[ "$MISSING_COUNT" -eq 0 && "$ISSUE_COUNT" -eq 0 ]]; then
    log_info "OUTCOME" "Documentation complete. $TOTAL_CHANGED source files changed, all properly annotated."
else
    log_info "OUTCOME" "$TOTAL_CHANGED source files changed. $MISSING_COUNT need @decision, $ISSUE_COUNT have validation issues."
fi

# --- Plan Reconciliation Audit ---
if [[ -f "$PROJECT_ROOT/MASTER_PLAN.md" ]]; then
    log_info "PLAN-SYNC" "Running plan reconciliation audit..."

    # Extract DEC-* IDs from MASTER_PLAN.md
    PLAN_DECS=$(grep -oE 'DEC-[A-Z]+-[0-9]+' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null | sort -u || echo "")

    # Extract DEC-* IDs from code (all source files in scan dirs)
    CODE_DECS=""
    for dir in "${SCAN_DIRS[@]}"; do
        if command -v rg &>/dev/null; then
            dir_decs=$(rg -oN 'DEC-[A-Z]+-[0-9]+' "$dir" \
                --glob '*.ts' --glob '*.tsx' --glob '*.js' --glob '*.jsx' \
                --glob '*.py' --glob '*.rs' --glob '*.go' --glob '*.java' \
                --glob '*.c' --glob '*.cpp' --glob '*.h' --glob '*.hpp' \
                --glob '*.sh' --glob '*.rb' --glob '*.php' \
                2>/dev/null || echo "")
        else
            dir_decs=$(grep -roE 'DEC-[A-Z]+-[0-9]+' "$dir" \
                --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' \
                --include='*.py' --include='*.rs' --include='*.go' --include='*.java' \
                --include='*.c' --include='*.cpp' --include='*.h' --include='*.hpp' \
                --include='*.sh' --include='*.rb' --include='*.php' \
                2>/dev/null || echo "")
        fi
        if [[ -n "$dir_decs" ]]; then
            CODE_DECS+="$dir_decs"$'\n'
        fi
    done
    CODE_DECS=$(echo "$CODE_DECS" | sort -u | grep -v '^$' || echo "")

    # --- Decision status awareness ---
    # Extract deprecated/superseded decisions from code (@status deprecated/superseded)
    DEPRECATED_DECS=""
    for dir in "${SCAN_DIRS[@]}"; do
        if command -v rg &>/dev/null; then
            dir_dep=$(rg -oN '@status\s+(deprecated|superseded)' "$dir" \
                --glob '*.ts' --glob '*.tsx' --glob '*.js' --glob '*.jsx' \
                --glob '*.py' --glob '*.rs' --glob '*.go' --glob '*.java' \
                --glob '*.sh' --glob '*.rb' --glob '*.php' \
                2>/dev/null || echo "")
            # Also check inline format: Status: deprecated
            dir_dep2=$(rg -oN 'Status:\s*(deprecated|superseded)' "$dir" \
                --glob '*.ts' --glob '*.tsx' --glob '*.js' --glob '*.jsx' \
                --glob '*.py' --glob '*.rs' --glob '*.go' --glob '*.java' \
                --glob '*.sh' --glob '*.rb' --glob '*.php' \
                2>/dev/null || echo "")
        else
            dir_dep=$(grep -roE '@status\s+(deprecated|superseded)' "$dir" \
                --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' \
                --include='*.py' --include='*.rs' --include='*.go' --include='*.java' \
                --include='*.sh' --include='*.rb' --include='*.php' \
                2>/dev/null || echo "")
            dir_dep2=$(grep -roE 'Status:\s*(deprecated|superseded)' "$dir" \
                --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' \
                --include='*.py' --include='*.rs' --include='*.go' --include='*.java' \
                --include='*.sh' --include='*.rb' --include='*.php' \
                2>/dev/null || echo "")
        fi
    done

    # Extract DEC-* IDs that are explicitly deprecated in the plan
    PLAN_DEPRECATED=$(grep -B2 -iE 'status.*deprecated|status.*superseded' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null | grep -oE 'DEC-[A-Z]+-[0-9]+' | sort -u || echo "")

    # Compare: decisions in code not in plan
    CODE_NOT_PLAN=""
    if [[ -n "$CODE_DECS" ]]; then
        while IFS= read -r dec; do
            [[ -z "$dec" ]] && continue
            if [[ -z "$PLAN_DECS" ]] || ! echo "$PLAN_DECS" | grep -qF "$dec"; then
                CODE_NOT_PLAN+="$dec "
            fi
        done <<< "$CODE_DECS"
    fi

    # Compare: decisions in plan not in code — distinguish unimplemented from deprecated
    PLAN_NOT_CODE=""
    PLAN_DEPRECATED_SKIP=""
    if [[ -n "$PLAN_DECS" ]]; then
        while IFS= read -r dec; do
            [[ -z "$dec" ]] && continue
            if [[ -z "$CODE_DECS" ]] || ! echo "$CODE_DECS" | grep -qF "$dec"; then
                # Check if this decision is deprecated in the plan — don't flag it
                if [[ -n "$PLAN_DEPRECATED" ]] && echo "$PLAN_DEPRECATED" | grep -qF "$dec"; then
                    PLAN_DEPRECATED_SKIP+="$dec "
                else
                    PLAN_NOT_CODE+="$dec "
                fi
            fi
        done <<< "$PLAN_DECS"
    fi

    # Phase status summary
    TOTAL_PHASES=$(grep -cE '^\#\#\s+Phase\s+[0-9]' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null || echo "0")
    COMPLETED_PHASES=$(grep -cE '\*\*Status:\*\*\s*completed' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null || echo "0")

    if [[ -n "$CODE_NOT_PLAN" ]]; then
        log_info "PLAN-SYNC" "Decisions in code not in plan (unplanned work): $CODE_NOT_PLAN"
        log_info "PLAN-SYNC" "  Action: Guardian should add these to MASTER_PLAN.md at next phase boundary."
    fi
    if [[ -n "$PLAN_NOT_CODE" ]]; then
        log_info "PLAN-SYNC" "Plan decisions not in code (unimplemented): $PLAN_NOT_CODE"
    fi
    if [[ -n "$PLAN_DEPRECATED_SKIP" ]]; then
        log_info "PLAN-SYNC" "Deprecated decisions skipped (correctly absent from code): $PLAN_DEPRECATED_SKIP"
    fi
    if [[ -z "$CODE_NOT_PLAN" && -z "$PLAN_NOT_CODE" ]]; then
        log_info "PLAN-SYNC" "Plan and code are in sync — all decision IDs match."
    fi
    if [[ "$TOTAL_PHASES" -gt 0 ]]; then
        log_info "PLAN-SYNC" "Phase status: $COMPLETED_PHASES/$TOTAL_PHASES completed"
    fi

    # --- REQ-ID traceability audit ---
    # Extract P0 REQ-IDs from MASTER_PLAN.md
    PLAN_P0_REQS=$(grep -oE 'REQ-P0-[0-9]+' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null | sort -u || echo "")
    UNADDRESSED_P0S=""
    if [[ -n "$PLAN_P0_REQS" && -n "$PLAN_DECS" ]]; then
        # For each P0, check if any DEC-ID has "Addresses: ...REQ-P0-NNN"
        while IFS= read -r req; do
            [[ -z "$req" ]] && continue
            if ! grep -qE "Addresses:.*$req" "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null; then
                UNADDRESSED_P0S+="$req "
            fi
        done <<< "$PLAN_P0_REQS"
    fi
    if [[ -n "$UNADDRESSED_P0S" ]]; then
        log_info "REQ-TRACE" "Unaddressed P0 requirements (no DEC-ID with Addresses:): $UNADDRESSED_P0S"
    fi

    # --- Non-goal violation check ---
    # Extract non-goal keywords from MASTER_PLAN.md Non-Goals section
    NOGO_VIOLATIONS=""
    NOGO_SECTION=$(sed -n '/^## *Non-Goals\|^### *Non-Goals/,/^##[^#]/p' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null | head -20 || echo "")
    PLAN_NOGOS=$(echo "$NOGO_SECTION" | grep -oE 'REQ-NOGO-[0-9]+' 2>/dev/null | sort -u || echo "")
    # Advisory: just count non-goals for drift data
    NOGO_COUNT=0
    if [[ -n "$PLAN_NOGOS" ]]; then
        NOGO_COUNT=$(echo "$PLAN_NOGOS" | wc -l | tr -d ' ')
    fi
fi

# --- Decision Registry Generation ---
# Auto-generate DECISIONS.md from @decision annotations in source code.
# Groups by component, links to originating plans, survives plan archival.
REGISTRY="$PROJECT_ROOT/DECISIONS.md"
REGISTRY_TMP="${REGISTRY}.tmp.$$"
DEC_IDS_FILE=$(mktemp)

# Collect all DEC-IDs from source
for dir in "${SCAN_DIRS[@]}"; do
    if command -v rg &>/dev/null; then
        rg -oN 'DEC-[A-Z]+-[0-9]+' "$dir" \
            --glob '*.{ts,tsx,js,jsx,py,rs,go,java,c,cpp,h,hpp,sh,rb,php}' \
            2>/dev/null >> "$DEC_IDS_FILE" || true
    else
        grep -roE 'DEC-[A-Z]+-[0-9]+' "$dir" \
            --include='*.sh' --include='*.ts' --include='*.py' --include='*.js' \
            2>/dev/null | sed 's/.*://' >> "$DEC_IDS_FILE" || true
    fi
done
sort -u "$DEC_IDS_FILE" -o "$DEC_IDS_FILE"

{
    echo "# Decision Registry"
    echo "> Auto-generated by surface.sh from @decision annotations in source code."
    echo "> Last updated: $(date '+%Y-%m-%d %H:%M')"
    echo ""
    echo "## By Component"
} > "$REGISTRY_TMP"

CURRENT_COMPONENT=""
while IFS= read -r dec_id; do
    [[ -z "$dec_id" ]] && continue
    # Extract component from DEC-ID (e.g., DEC-CACHE-001 -> CACHE)
    # shellcheck disable=SC2001
    component=$(echo "$dec_id" | sed 's/DEC-\([A-Z]*\)-.*/\1/')

    if [[ "$component" != "$CURRENT_COMPONENT" ]]; then
        CURRENT_COMPONENT="$component"
        echo "### $CURRENT_COMPONENT" >> "$REGISTRY_TMP"
    fi

    # Find the source file containing this decision
    source_file=""
    for sdir in "${SCAN_DIRS[@]}"; do
        if command -v rg &>/dev/null; then
            source_file=$(rg -l "@decision $dec_id" "$sdir" \
                --glob '*.{ts,tsx,js,jsx,py,rs,go,java,c,cpp,h,hpp,sh,rb,php}' \
                2>/dev/null | head -1 || true)
        else
            source_file=$(grep -rl "@decision $dec_id" "$sdir" \
                --include='*.sh' --include='*.ts' --include='*.py' --include='*.js' \
                2>/dev/null | head -1 || true)
        fi
        [[ -n "$source_file" ]] && break
    done

    if [[ -n "$source_file" ]]; then
        dec_title=$(grep -A1 "@decision $dec_id" "$source_file" 2>/dev/null | grep '@title' | sed 's/.*@title //' || echo "")
        dec_status=$(grep -A3 "@decision $dec_id" "$source_file" 2>/dev/null | grep '@status' | sed 's/.*@status //' || echo "unknown")
        rel_source="${source_file#"$PROJECT_ROOT"/}"
        # shellcheck disable=SC2129
        echo "- **$dec_id**: ${dec_title:-[untitled]}" >> "$REGISTRY_TMP"
        echo "  - Source: \`$rel_source\`" >> "$REGISTRY_TMP"
        echo "  - Status: ${dec_status}" >> "$REGISTRY_TMP"
    else
        echo "- **$dec_id**: [source not found]" >> "$REGISTRY_TMP"
    fi
    echo "" >> "$REGISTRY_TMP"
done < "$DEC_IDS_FILE"

# Add unplanned decisions section
if [[ -n "${CODE_NOT_PLAN:-}" ]]; then
    {
        echo "## Unplanned Decisions (in code, not in any MASTER_PLAN)"
        for dec in $CODE_NOT_PLAN; do
            echo "- $dec"
        done
        echo ""
    } >> "$REGISTRY_TMP"
fi

# Write registry if decisions found
if [[ -s "$DEC_IDS_FILE" ]]; then
    mv "$REGISTRY_TMP" "$REGISTRY"
else
    rm -f "$REGISTRY_TMP"
fi
rm -f "$DEC_IDS_FILE"

# --- Append key findings to audit log ---
AUDIT_LOG="${CLAUDE_DIR}/.audit-log"
if [[ "$MISSING_COUNT" -gt 0 ]]; then
    append_audit "$PROJECT_ROOT" "decision_gap" "$MISSING_COUNT files missing @decision"
fi
if [[ -n "${CODE_NOT_PLAN:-}" ]]; then
    append_audit "$PROJECT_ROOT" "plan_drift" "unplanned decisions: $CODE_NOT_PLAN"
fi
if [[ -n "${PLAN_NOT_CODE:-}" ]]; then
    append_audit "$PROJECT_ROOT" "plan_drift" "unimplemented decisions: $PLAN_NOT_CODE"
fi

# --- Persist structured drift data for next session's plan-check ---
DRIFT_FILE="${CLAUDE_DIR}/.plan-drift"
{
    echo "audit_epoch=$(date +%s)"
    echo "unplanned_count=$(echo "${CODE_NOT_PLAN:-}" | wc -w | tr -d ' ')"
    echo "unimplemented_count=$(echo "${PLAN_NOT_CODE:-}" | wc -w | tr -d ' ')"
    echo "missing_decisions=${MISSING_COUNT:-0}"
    echo "total_decisions=${TOTAL_DECISIONS:-0}"
    echo "source_files_changed=${TOTAL_CHANGED:-0}"
    echo "unaddressed_p0s=$(echo "${UNADDRESSED_P0S:-}" | wc -w | tr -d ' ')"
    echo "nogo_count=${NOGO_COUNT:-0}"
} > "$DRIFT_FILE"

# --- Emit systemMessage so findings reach the model on next turn ---
# Stop hooks use systemMessage (not hookSpecificOutput, which is PreToolUse/PostToolUse only)
SUMMARY_PARTS=()
SUMMARY_PARTS+=("$TOTAL_CHANGED source files changed, $MISSING_COUNT need @decision")
if [[ -n "${CODE_NOT_PLAN:-}" || -n "${PLAN_NOT_CODE:-}" ]]; then
    DRIFT_PARTS=""
    [[ -n "${CODE_NOT_PLAN:-}" ]] && DRIFT_PARTS="$(echo "$CODE_NOT_PLAN" | wc -w | tr -d ' ') decisions in code not in plan"
    [[ -n "${PLAN_NOT_CODE:-}" ]] && {
        [[ -n "$DRIFT_PARTS" ]] && DRIFT_PARTS="$DRIFT_PARTS, "
        DRIFT_PARTS="${DRIFT_PARTS}$(echo "$PLAN_NOT_CODE" | wc -w | tr -d ' ') in plan not in code"
    }
    SUMMARY_PARTS+=("Plan drift: $DRIFT_PARTS")
fi
if [[ "${TOTAL_PHASES:-0}" -gt 0 ]]; then
    SUMMARY_PARTS+=("Phase status: $COMPLETED_PHASES/$TOTAL_PHASES completed")
fi
if [[ -n "${UNADDRESSED_P0S:-}" ]]; then
    SUMMARY_PARTS+=("Unaddressed P0 reqs: $UNADDRESSED_P0S")
fi

SUMMARY=$(printf '%s\n' "${SUMMARY_PARTS[@]}")
ESCAPED_SUMMARY=$(echo "$SUMMARY" | jq -Rs .)
cat <<HOOK_EOF
{
  "systemMessage": $ESCAPED_SUMMARY
}
HOOK_EOF

# Clean up session tracking
rm -f "$CHANGES"
exit 0
