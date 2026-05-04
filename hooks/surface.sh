#!/usr/bin/env bash
set -euo pipefail

# Session-end decision validation and audit.
# Stop hook — runs when Claude finishes responding.
#
# Performs the full /surface pipeline: extract → validate → report.
# No external documentation is generated (Code is Truth).
# Reports: files changed, @decision coverage, validation issues.
#
# Checks stop_hook_active to prevent re-firing loops.

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

HOOK_INPUT=$(read_input)
seed_project_dir_from_hook_payload_cwd "$HOOK_INPUT"

# --- Prevent re-firing loops ---
# stop_hook_active is true if this Stop hook already ran and produced output
STOP_ACTIVE=$(echo "$HOOK_INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
if [[ "$STOP_ACTIVE" == "true" ]]; then
    exit 0
fi

# Get project root (prefers CLAUDE_PROJECT_DIR)
PROJECT_ROOT=$(detect_project_root)

_critic_surface_message() {
    local latest found active run_id workflow_id status verdict provider summary detail
    local source surfaced_count review findings next_steps progress escaped_detail

    latest=$(cc_policy critic-run latest --role implementer 2>/dev/null || echo "")
    [[ -n "$latest" ]] || return 0
    found=$(printf '%s' "$latest" | jq -r '.found // false' 2>/dev/null || echo "false")
    [[ "$found" == "true" ]] || return 0

    active=$(printf '%s' "$latest" | jq -r '.active // false' 2>/dev/null || echo "false")
    # Completed critic outcomes are the conversation-visible contract. Active
    # progress remains in the statusline to avoid repeating transient updates.
    [[ "$active" == "true" ]] && return 0

    run_id=$(printf '%s' "$latest" | jq -r '.run_id // empty' 2>/dev/null || true)
    [[ -n "$run_id" ]] || return 0
    source="critic-run:$run_id"

    surfaced_count=$(cc_policy event query --type critic_surface --source "$source" --limit 1 2>/dev/null \
        | jq -r '.count // 0' 2>/dev/null || echo "0")
    [[ "$surfaced_count" =~ ^[0-9]+$ ]] || surfaced_count=0
    [[ "$surfaced_count" -gt 0 ]] && return 0

    workflow_id=$(printf '%s' "$latest" | jq -r '.workflow_id // empty' 2>/dev/null || true)
    status=$(printf '%s' "$latest" | jq -r '.status // empty' 2>/dev/null || true)
    verdict=$(printf '%s' "$latest" | jq -r '.verdict // empty' 2>/dev/null || true)
    provider=$(printf '%s' "$latest" | jq -r '.provider // empty' 2>/dev/null || true)
    summary=$(printf '%s' "$latest" | jq -r '.summary // empty' 2>/dev/null || true)
    detail=$(printf '%s' "$latest" | jq -r '.detail // empty' 2>/dev/null || true)
    progress=$(printf '%s' "$latest" | jq -r '[.progress[]?.message] | .[-5:][]?' 2>/dev/null || true)

    review=""
    if [[ -n "$workflow_id" ]]; then
        review=$(cc_policy critic-review latest --workflow-id "$workflow_id" --role implementer 2>/dev/null || echo "")
    fi
    findings=$(printf '%s' "$review" | jq -r '.metadata.findings[]? // empty' 2>/dev/null | head -4 || true)
    next_steps=$(printf '%s' "$review" | jq -r '.metadata.next_steps[]? // empty' 2>/dev/null | head -4 || true)
    {
        printf 'Codex critic review surfaced:\n'
        printf -- '- workflow: %s\n' "${workflow_id:-unknown}"
        printf -- '- status: %s\n' "${status:-unknown}"
        printf -- '- provider: %s\n' "${provider:-unknown}"
        printf -- '- verdict: %s\n' "${verdict:-unknown}"
        [[ -n "$summary" ]] && printf -- '- summary: %s\n' "$summary"
        if [[ -n "$detail" ]]; then
            escaped_detail=$(printf '%s' "$detail" | tr '\n' ' ')
            printf -- '- detail: %s\n' "$escaped_detail"
        fi
        if [[ -n "$findings" ]]; then
            printf 'Critic highlights:\n'
            while IFS= read -r item; do
                [[ -n "$item" ]] && printf -- '- %s\n' "$item"
            done <<< "$findings"
        fi
        if [[ -n "$next_steps" ]]; then
            printf 'Critic next steps:\n'
            while IFS= read -r item; do
                [[ -n "$item" ]] && printf -- '- %s\n' "$item"
            done <<< "$next_steps"
        fi
        if [[ -n "$progress" ]]; then
            printf 'Critic trace highlights:\n'
            while IFS= read -r item; do
                [[ -n "$item" ]] && printf -- '- %s\n' "$item"
            done <<< "$progress"
        fi
    }

    cc_policy event emit critic_surface --source "$source" \
        --detail "surfaced verdict=${verdict:-unknown}" >/dev/null 2>&1 || true
}

CRITIC_SURFACE_MESSAGE=$(_critic_surface_message || true)

_emit_system_message() {
    local message="${1:-}"
    [[ -n "$message" ]] || return 0
    local escaped
    escaped=$(printf '%s' "$message" | jq -Rs .)
    cat <<HOOK_EOF
{
  "systemMessage": $escaped
}
HOOK_EOF
}

# Load session changes from state.db.
get_session_changes "$PROJECT_ROOT"
CHANGES_TEXT="${SESSION_CHANGES_TEXT:-}"

# Exit silently if no changes tracked
if [[ -z "$CHANGES_TEXT" ]]; then
    _emit_system_message "$CRITIC_SURFACE_MESSAGE"
    exit 0
fi

# --- Count source file changes ---
# Uses SOURCE_EXTENSIONS from context-lib.sh
SOURCE_EXTS="($SOURCE_EXTENSIONS)"
SOURCE_COUNT=$(printf '%s\n' "$CHANGES_TEXT" | grep -cE "\\.${SOURCE_EXTS}$") || SOURCE_COUNT=0

if [[ "$SOURCE_COUNT" -eq 0 ]]; then
    _emit_system_message "$CRITIC_SURFACE_MESSAGE"
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
        # Check if file is significant (50+ lines)
        line_count=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
        if [[ "$line_count" -ge 50 ]]; then
            MISSING_DECISIONS+=("$file ($line_count lines, no @decision)")
        fi
    fi
done < <(printf '%s\n' "$CHANGES_TEXT" | sort -u)

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
TOTAL_CHANGED=$(printf '%s\n' "$CHANGES_TEXT" | sort -u | grep -cE "\\.${SOURCE_EXTS}$") || TOTAL_CHANGED=0
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
fi

# --- Append key findings to audit log ---
AUDIT_LOG="${PROJECT_ROOT}/.claude/.audit-log"
if [[ "$MISSING_COUNT" -gt 0 ]]; then
    append_audit "$PROJECT_ROOT" "decision_gap" "$MISSING_COUNT files missing @decision"
fi
if [[ -n "${CODE_NOT_PLAN:-}" ]]; then
    append_audit "$PROJECT_ROOT" "plan_drift" "unplanned decisions: $CODE_NOT_PLAN"
fi
if [[ -n "${PLAN_NOT_CODE:-}" ]]; then
    append_audit "$PROJECT_ROOT" "plan_drift" "unimplemented decisions: $PLAN_NOT_CODE"
fi

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

SUMMARY=$(printf '%s\n' "${SUMMARY_PARTS[@]}")
if [[ -n "$CRITIC_SURFACE_MESSAGE" ]]; then
    SUMMARY=$(printf '%s\n\n%s\n' "$CRITIC_SURFACE_MESSAGE" "$SUMMARY")
fi
_emit_system_message "$SUMMARY"

exit 0
