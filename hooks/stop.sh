#!/usr/bin/env bash
# Consolidated Stop hook — merges surface.sh, session-summary.sh, forward-motion.sh.
# Runs when Claude finishes responding (Stop event).
#
# Replaces (in order of execution):
#   1. surface.sh       — @decision audit, plan reconciliation, DECISIONS.md generation
#   2. session-summary.sh — files changed, git state, test status, trajectory narrative
#   3. forward-motion.sh  — response ends with question/offer/suggestion check
#
# Produces a single systemMessage combining all three outputs into a structured
# summary for the model's next context window.
#
# @decision DEC-CONSOLIDATE-005
# @title Merge 3 Stop hooks into stop.sh
# @status accepted
# @rationale Each Stop hook previously re-sourced source-lib.sh (log.sh + context-lib.sh,
#   ~2,220 lines) independently. With three hooks, this added 180-480ms of parse overhead
#   per session end, plus three subprocess spawns. Merging into a single process with one
#   library source reduces this to ~60ms and eliminates 2 extra subprocess spawns.
#   All logic is preserved unchanged; only the process boundary is removed.
#   Output buffering (DEC-META-001): all systemMessage content is accumulated in an array
#   and emitted as a single combined JSON at exit — prevents partial-parse bugs where only
#   the first JSON object is processed by Claude Code.
#   Execution order: surface (most important context first) → session summary → forward motion.
#
# @decision DEC-META-001
# @title Output buffering for multi-JSON prevention (Stop hook)
# @status accepted
# @rationale Multiple sections produce systemMessage content independently.
#   Claude Code parses only the first JSON object emitted to stdout. Buffering all
#   parts into _SUMMARY_PARTS[] and emitting a single combined JSON at exit guarantees
#   exactly one JSON object per hook invocation. The forward-motion exit-2 (feedback)
#   is the only early-exit path; all others accumulate into the buffer.
#
# @decision DEC-PERF-004
# @title Warm-path caching for get_plan_status, get_git_state, deferred requires
# @status accepted
# @rationale Phase 1 (DEC-PERF-003) eliminated the cold-path cost with TTL sentinels.
#   Phase 2 targets the remaining ~385ms/turn on the warm path (Section 2 only):
#   1. Plan cache (.stop-plan-cache-{SESSION_ID}): get_plan_status runs 10+ greps
#      on MASTER_PLAN.md. Cached for STOP_SURFACE_TTL (300s). Plan doesn't change
#      between consecutive agent turns.
#   2. Git cache (.stop-git-cache-{SESSION_ID}): get_git_state spawns 3 git subprocesses.
#      Cached for 60s (shorter — implementer writes can change dirty count).
#   3. Duplicate get_session_changes() eliminated: saved before Section 1 removes CHANGES.
#   4. require_trace and require_doc deferred to inside their gated blocks.
#   5. resolve_proof_file fast path: reads .proof-status directly when present in
#      CLAUDE_DIR (the common non-worktree case), skipping breadcrumb chain.
#   6. Two get_field jq calls merged into one at the top of the hook.
#   Net result: warm-path cost drops from ~385ms to ~50ms per turn.

set -euo pipefail

# Pre-set hook identity before source-lib.sh auto-detection.
_HOOK_NAME="stop"
_HOOK_EVENT_TYPE="Stop"

source "$(dirname "$0")/source-lib.sh"

require_git
require_plan
require_session
# require_trace and require_doc deferred to inside their gated blocks (DEC-PERF-004)

HOOK_INPUT=$(read_input)

# ============================================================================
# Re-firing guard — stop_hook_active prevents infinite Stop→generate→Stop loops
# OPT-6: Merge two get_field jq calls into one (saves ~18ms)
# ============================================================================

# Parse both fields in a single jq invocation at the top.
_PARSED_FIELDS=$(echo "$HOOK_INPUT" | jq -r '(.stop_hook_active // "false"), (.assistant_response // "")' 2>/dev/null || printf 'false\n')
STOP_ACTIVE=$(printf '%s' "$_PARSED_FIELDS" | head -1)
STOP_ACTIVE="${STOP_ACTIVE:-false}"
if [[ "$STOP_ACTIVE" == "true" ]]; then
    exit 0
fi
# Extract assistant_response from the pre-parsed fields (line 2 onwards, handle multi-line)
RESPONSE=$(printf '%s' "$_PARSED_FIELDS" | tail -n +2)

# ============================================================================
# Shared context (used by all three sections)
# ============================================================================

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)

# Find session tracking file via shared library (DEC-V3-005)
# OPT-3: Call get_session_changes once here and save the file path.
# Section 1 may rm -f "$CHANGES"; Section 2 previously re-called get_session_changes()
# to detect that. Now we save the path before Section 1 and pass it through.
get_session_changes "$PROJECT_ROOT"
CHANGES="${SESSION_FILE:-}"
# _CHANGES_SAVED holds the original path — used after Section 1 may have deleted it.
_CHANGES_SAVED="$CHANGES"

# Output accumulator — all parts appended here, emitted once at the end
_SUMMARY_PARTS=()

# --- TTL rate-limiting helpers ---
# @decision DEC-PERF-003 (see core-lib.sh for full rationale)
# Sentinel files store epoch timestamps. If the file's epoch + TTL > now, skip.
# Session-scoped sentinels include CLAUDE_SESSION_ID and auto-reset per session.
# Global sentinels persist across sessions (backup, todo refresh).

_ttl_expired() {
    local file="$1" ttl="$2"
    [[ ! -f "$file" ]] && return 0
    local stamp
    stamp=$(cat "$file" 2>/dev/null) || return 0
    [[ ! "$stamp" =~ ^[0-9]+$ ]] && return 0
    local now
    now=$(date +%s)
    (( now - stamp >= ttl ))
}

_ttl_touch() {
    date +%s > "$1"
}

# ============================================================================
# SECTION 1: Surface — @decision audit, plan reconciliation, DECISIONS.md
# Ported from surface.sh (439L)
# ============================================================================

# Only run if there are tracked source-file changes
SOURCE_EXTS="($SOURCE_EXTENSIONS)"
_RUN_SURFACE=false
if [[ -n "$CHANGES" && -f "$CHANGES" ]]; then
    SOURCE_COUNT_SURFACE=$(grep -cE "\\.${SOURCE_EXTS}$" "$CHANGES" 2>/dev/null) || SOURCE_COUNT_SURFACE=0
    [[ "$SOURCE_COUNT_SURFACE" -gt 0 ]] && _RUN_SURFACE=true
fi

# @decision DEC-PROD-005
# @title Use CLAUDE_SESSION_ID for sentinel scoping to prevent cross-session TTL collisions
# @status accepted
# @rationale When multiple sessions run concurrently (e.g. parallel worktrees), using $$
#   (PID) causes each session to create its own TTL sentinel, defeating the rate limit.
#   CLAUDE_SESSION_ID is unique per Claude session and consistent across all turns within
#   a session — it provides correct scoping for session-bounded TTL sentinels.
_SESSION_KEY="${CLAUDE_SESSION_ID:-$$}"
_SURFACE_SENTINEL="${CLAUDE_DIR}/.stop-surface-${_SESSION_KEY}"
if $_RUN_SURFACE && _ttl_expired "$_SURFACE_SENTINEL" "$STOP_SURFACE_TTL"; then
    log_info "SURFACE" "$SOURCE_COUNT_SURFACE source files modified this session"

    # Determine source directories to scan
    SCAN_DIRS=()
    for dir in src lib app pkg cmd internal; do
        [[ -d "$PROJECT_ROOT/$dir" ]] && SCAN_DIRS+=("$PROJECT_ROOT/$dir")
    done
    [[ ${#SCAN_DIRS[@]} -eq 0 ]] && SCAN_DIRS=("$PROJECT_ROOT")

    DECISION_PATTERN='@decision|# DECISION:|// DECISION\('
    TOTAL_DECISIONS=0
    DECISIONS_IN_CHANGED=0
    MISSING_DECISIONS=()
    VALIDATION_ISSUES=()

    # Count total decisions in codebase
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

    # Validate changed files
    while IFS= read -r file; do
        [[ ! -f "$file" ]] && continue
        is_source_file "$file" || continue
        is_skippable_path "$file" && continue

        if grep -qE "$DECISION_PATTERN" "$file" 2>/dev/null; then
            ((DECISIONS_IN_CHANGED++)) || true
            if ! grep -qE '@rationale|Rationale:' "$file" 2>/dev/null; then
                VALIDATION_ISSUES+=("$file: @decision missing rationale")
            fi
        else
            line_count=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
            if [[ "$line_count" -ge "$DECISION_LINE_THRESHOLD" ]]; then
                MISSING_DECISIONS+=("$file ($line_count lines, no @decision)")
            fi
        fi
    done < <(sort -u "$CHANGES")

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

    TOTAL_CHANGED=$(sort -u "$CHANGES" | grep -cE "\\.${SOURCE_EXTS}$" 2>/dev/null) || TOTAL_CHANGED=0
    MISSING_COUNT=${#MISSING_DECISIONS[@]}
    ISSUE_COUNT=${#VALIDATION_ISSUES[@]}

    if [[ "$MISSING_COUNT" -eq 0 && "$ISSUE_COUNT" -eq 0 ]]; then
        log_info "OUTCOME" "Documentation complete. $TOTAL_CHANGED source files changed, all properly annotated."
    else
        log_info "OUTCOME" "$TOTAL_CHANGED source files changed. $MISSING_COUNT need @decision, $ISSUE_COUNT have validation issues."
    fi

    # --- Plan Reconciliation Audit ---
    CODE_NOT_PLAN=""
    PLAN_NOT_CODE=""
    PLAN_DEPRECATED_SKIP=""
    TOTAL_PHASES=0
    COMPLETED_PHASES=0
    UNADDRESSED_P0S=""
    NOGO_COUNT=0

    if [[ -f "$PROJECT_ROOT/MASTER_PLAN.md" ]]; then
        log_info "PLAN-SYNC" "Running plan reconciliation audit..."

        PLAN_DECS=$(grep -oE 'DEC-[A-Z]+-[0-9]+' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null | sort -u || echo "")

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

        PLAN_DEPRECATED=$(grep -B2 -iE 'status.*deprecated|status.*superseded' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null | grep -oE 'DEC-[A-Z]+-[0-9]+' | sort -u || echo "")

        if [[ -n "$CODE_DECS" ]]; then
            while IFS= read -r dec; do
                [[ -z "$dec" ]] && continue
                if [[ -z "$PLAN_DECS" ]] || ! echo "$PLAN_DECS" | grep -qF "$dec"; then
                    CODE_NOT_PLAN+="$dec "
                fi
            done <<< "$CODE_DECS"
        fi

        if [[ -n "$PLAN_DECS" ]]; then
            while IFS= read -r dec; do
                [[ -z "$dec" ]] && continue
                if [[ -z "$CODE_DECS" ]] || ! echo "$CODE_DECS" | grep -qF "$dec"; then
                    if [[ -n "$PLAN_DEPRECATED" ]] && echo "$PLAN_DEPRECATED" | grep -qF "$dec"; then
                        PLAN_DEPRECATED_SKIP+="$dec "
                    else
                        PLAN_NOT_CODE+="$dec "
                    fi
                fi
            done <<< "$PLAN_DECS"
        fi

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

        PLAN_P0_REQS=$(grep -oE 'REQ-P0-[0-9]+' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null | sort -u || echo "")
        UNADDRESSED_P0S=""
        if [[ -n "$PLAN_P0_REQS" && -n "$PLAN_DECS" ]]; then
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

        NOGO_SECTION=$(sed -n '/^## *Non-Goals\|^### *Non-Goals/,/^##[^#]/p' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null | head -20 || echo "")
        PLAN_NOGOS=$(echo "$NOGO_SECTION" | grep -oE 'REQ-NOGO-[0-9]+' 2>/dev/null | sort -u || echo "")
        NOGO_COUNT=0
        if [[ -n "$PLAN_NOGOS" ]]; then
            NOGO_COUNT=$(echo "$PLAN_NOGOS" | wc -l | tr -d ' ')
        fi
    fi

    # --- Decision Registry Generation ---
    REGISTRY="$PROJECT_ROOT/DECISIONS.md"
    REGISTRY_TMP="${REGISTRY}.tmp.$$"
    DEC_IDS_FILE=$(mktemp)

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
        echo "> Auto-generated by stop.sh from @decision annotations in source code."
        echo "> Last updated: $(date '+%Y-%m-%d %H:%M')"
        echo ""
        echo "## By Component"
    } > "$REGISTRY_TMP"

    CURRENT_COMPONENT=""
    while IFS= read -r dec_id; do
        [[ -z "$dec_id" ]] && continue
        # shellcheck disable=SC2001
        component=$(echo "$dec_id" | sed 's/DEC-\([A-Z]*\)-.*/\1/')

        if [[ "$component" != "$CURRENT_COMPONENT" ]]; then
            CURRENT_COMPONENT="$component"
            echo "### $CURRENT_COMPONENT" >> "$REGISTRY_TMP"
        fi

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

    if [[ -n "${CODE_NOT_PLAN:-}" ]]; then
        {
            echo "## Unplanned Decisions (in code, not in any MASTER_PLAN)"
            for dec in $CODE_NOT_PLAN; do
                echo "- $dec"
            done
            echo ""
        } >> "$REGISTRY_TMP"
    fi

    if [[ -s "$DEC_IDS_FILE" ]]; then
        mv "$REGISTRY_TMP" "$REGISTRY"
    else
        rm -f "$REGISTRY_TMP"
    fi
    rm -f "$DEC_IDS_FILE"

    # --- Audit log ---
    AUDIT_LOG="${CLAUDE_DIR}/.audit-log"
    if [[ "${MISSING_COUNT:-0}" -gt 0 ]]; then
        append_audit "$PROJECT_ROOT" "decision_gap" "$MISSING_COUNT files missing @decision"
    fi
    if [[ -n "${CODE_NOT_PLAN:-}" ]]; then
        append_audit "$PROJECT_ROOT" "plan_drift" "unplanned decisions: $CODE_NOT_PLAN"
    fi
    if [[ -n "${PLAN_NOT_CODE:-}" ]]; then
        append_audit "$PROJECT_ROOT" "plan_drift" "unimplemented decisions: $PLAN_NOT_CODE"
    fi

    # --- Persist structured drift data ---
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

    # --- Persist doc freshness data ---
    # OPT-4: require_doc deferred to inside the surface TTL block (only runs when surface is active)
    require_doc
    get_doc_freshness "$PROJECT_ROOT"
    DOC_DRIFT_FILE="${CLAUDE_DIR}/.doc-drift"
    _prev_bypass=0
    if [[ -f "$DOC_DRIFT_FILE" ]]; then
        _prev_bypass=$(grep '^bypass_count=' "$DOC_DRIFT_FILE" 2>/dev/null | cut -d= -f2 || echo "0")
    fi
    {
        echo "audit_epoch=$(date +%s)"
        echo "stale_count=${DOC_STALE_COUNT:-0}"
        echo "stale_docs=${DOC_STALE_DENY:-} ${DOC_STALE_WARN:-}"
        echo "bypass_count=${_prev_bypass:-0}"
    } > "$DOC_DRIFT_FILE"

    # Accumulate surface summary
    SURFACE_PARTS=()
    SURFACE_PARTS+=("${TOTAL_CHANGED:-0} source files changed, ${MISSING_COUNT:-0} need @decision")
    if [[ -n "${CODE_NOT_PLAN:-}" || -n "${PLAN_NOT_CODE:-}" ]]; then
        DRIFT_MSG=""
        [[ -n "${CODE_NOT_PLAN:-}" ]] && DRIFT_MSG="$(echo "$CODE_NOT_PLAN" | wc -w | tr -d ' ') decisions in code not in plan"
        [[ -n "${PLAN_NOT_CODE:-}" ]] && {
            [[ -n "$DRIFT_MSG" ]] && DRIFT_MSG="$DRIFT_MSG, "
            DRIFT_MSG="${DRIFT_MSG}$(echo "$PLAN_NOT_CODE" | wc -w | tr -d ' ') in plan not in code"
        }
        SURFACE_PARTS+=("Plan drift: $DRIFT_MSG")
    fi
    if [[ "${TOTAL_PHASES:-0}" -gt 0 ]]; then
        SURFACE_PARTS+=("Phase status: ${COMPLETED_PHASES:-0}/${TOTAL_PHASES} completed")
    fi
    if [[ -n "${UNADDRESSED_P0S:-}" ]]; then
        SURFACE_PARTS+=("Unaddressed P0 reqs: $UNADDRESSED_P0S")
    fi
    _SUMMARY_PARTS+=("$(printf '%s\n' "${SURFACE_PARTS[@]}")")

    # Clean up session tracking (surface.sh did this)
    rm -f "$CHANGES"
    _ttl_touch "$_SURFACE_SENTINEL"
elif $_RUN_SURFACE; then
    # TTL not expired — use cached .plan-drift for lightweight summary
    if [[ -f "${CLAUDE_DIR}/.plan-drift" ]]; then
        _cached_missing=$(grep '^missing_decisions=' "${CLAUDE_DIR}/.plan-drift" | cut -d= -f2)
        _cached_changed=$(grep '^source_files_changed=' "${CLAUDE_DIR}/.plan-drift" | cut -d= -f2)
        _SUMMARY_PARTS+=("${_cached_changed:-0} source files changed, ${_cached_missing:-0} need @decision (cached)")
    fi
    # Clear CHANGES so Section 2 doesn't re-process
    [[ -n "$CHANGES" && -f "$CHANGES" ]] && rm -f "$CHANGES"
fi

# ============================================================================
# SECTION 2: Session Summary — files changed, git state, test status, trajectory
# Ported from session-summary.sh (287L)
# ============================================================================

# OPT-3: Reuse _CHANGES_SAVED instead of re-calling get_session_changes().
# Section 1 may have rm -f'd the file; that's fine — we check -f below before use.
CHANGES_2="$_CHANGES_SAVED"

# Only run if there was something to track
_RUN_SUMMARY=false
TOTAL_FILES=0
if [[ -n "$CHANGES_2" && -f "$CHANGES_2" ]]; then
    TOTAL_FILES=$(sort -u "$CHANGES_2" 2>/dev/null | wc -l | tr -d ' ') || TOTAL_FILES=0
    [[ "$TOTAL_FILES" -gt 0 ]] && _RUN_SUMMARY=true
fi

# Also run if surface section ran (it removed CHANGES but we have context)
$_RUN_SURFACE && _RUN_SUMMARY=true

if $_RUN_SUMMARY; then
    # Observatory v2: refinalize_stale_traces() deleted (DEC-OBS-V2-002).
    # Compliance data recorded at agent boundaries by check-*.sh hooks.
    _BACKUP_SENTINEL="${CLAUDE_DIR}/.stop-backup-ttl"
    if _ttl_expired "$_BACKUP_SENTINEL" "$STOP_BACKUP_TTL"; then
        # OPT-4: require_trace deferred to inside the backup TTL block
        require_trace
        set +e
        backup_trace_manifests 2>/dev/null
        set -e
        _ttl_touch "$_BACKUP_SENTINEL"
    fi

    # Re-count files if CHANGES_2 still available
    SOURCE_COUNT_SUMMARY=0
    CONFIG_COUNT=0
    DECISIONS_ADDED=0
    if [[ -n "$CHANGES_2" && -f "$CHANGES_2" ]]; then
        TOTAL_FILES=$(sort -u "$CHANGES_2" 2>/dev/null | wc -l | tr -d ' ') || TOTAL_FILES=0
        SOURCE_EXTS_SUM="($SOURCE_EXTENSIONS)"
        SOURCE_COUNT_SUMMARY=$(sort -u "$CHANGES_2" 2>/dev/null | grep -cE "\\.${SOURCE_EXTS_SUM}$") || SOURCE_COUNT_SUMMARY=0
        CONFIG_COUNT=$(( TOTAL_FILES - SOURCE_COUNT_SUMMARY ))
        DECISION_PATTERN_SUM='@decision|# DECISION:|// DECISION\('
        while IFS= read -r file; do
            [[ ! -f "$file" ]] && continue
            if grep -qE "$DECISION_PATTERN_SUM" "$file" 2>/dev/null; then
                ((DECISIONS_ADDED++)) || true
            fi
        done < <(sort -u "$CHANGES_2" 2>/dev/null)
    elif $_RUN_SURFACE; then
        # Surface already processed the changes — use its counts
        TOTAL_FILES="${TOTAL_CHANGED:-0}"
        SOURCE_COUNT_SUMMARY="${SOURCE_COUNT_SURFACE:-0}"
        CONFIG_COUNT=0
        DECISIONS_ADDED="${DECISIONS_IN_CHANGED:-0}"
    fi

    SESS_SUMMARY="Session: $TOTAL_FILES file(s) changed"
    if [[ "$SOURCE_COUNT_SUMMARY" -gt 0 ]]; then
        SESS_SUMMARY+=" ($SOURCE_COUNT_SUMMARY source, $CONFIG_COUNT config/other)"
    fi
    if [[ "$DECISIONS_ADDED" -gt 0 ]]; then
        SESS_SUMMARY+=". $DECISIONS_ADDED file(s) with @decision annotations."
    fi

    # Git + plan state
    # OPT-2: Cache get_git_state() in .stop-git-cache-{SESSION_ID} (TTL=60s)
    # Git state can change from implementer writes, so TTL is kept short.
    # Note: _ttl_expired/_ttl_touch use a SEPARATE sentinel file from the data
    # cache, because _ttl_touch overwrites the file with just the epoch.
    _GIT_CACHE="${CLAUDE_DIR}/.stop-git-cache-${_SESSION_KEY}"
    _GIT_CACHE_SENT="${_GIT_CACHE}.ttl"
    _GIT_CACHE_TTL=60
    if _ttl_expired "$_GIT_CACHE_SENT" "$_GIT_CACHE_TTL"; then
        get_git_state "$PROJECT_ROOT"
        {
            echo "GIT_BRANCH=$(printf '%s' "${GIT_BRANCH:-}" | tr -d '\n')"
            echo "GIT_DIRTY_COUNT=${GIT_DIRTY_COUNT:-0}"
            echo "GIT_WT_COUNT=${GIT_WT_COUNT:-0}"
        } > "$_GIT_CACHE"
        _ttl_touch "$_GIT_CACHE_SENT"
    else
        GIT_BRANCH=$(grep '^GIT_BRANCH=' "$_GIT_CACHE" 2>/dev/null | cut -d= -f2- || echo "unknown")
        GIT_DIRTY_COUNT=$(grep '^GIT_DIRTY_COUNT=' "$_GIT_CACHE" 2>/dev/null | cut -d= -f2 || echo "0")
        GIT_WT_COUNT=$(grep '^GIT_WT_COUNT=' "$_GIT_CACHE" 2>/dev/null | cut -d= -f2 || echo "0")
    fi

    # OPT-1: Cache get_plan_status() in .stop-plan-cache-{SESSION_ID} (TTL=STOP_SURFACE_TTL)
    # Plan doesn't change between consecutive agent turns.
    _PLAN_CACHE="${CLAUDE_DIR}/.stop-plan-cache-${_SESSION_KEY}"
    _PLAN_CACHE_SENT="${_PLAN_CACHE}.ttl"
    if _ttl_expired "$_PLAN_CACHE_SENT" "$STOP_SURFACE_TTL"; then
        get_plan_status "$PROJECT_ROOT"
        {
            echo "PLAN_EXISTS=${PLAN_EXISTS:-false}"
            echo "PLAN_LIFECYCLE=$(printf '%s' "${PLAN_LIFECYCLE:-none}" | tr -d '\n')"
        } > "$_PLAN_CACHE"
        _ttl_touch "$_PLAN_CACHE_SENT"
    else
        PLAN_EXISTS=$(grep '^PLAN_EXISTS=' "$_PLAN_CACHE" 2>/dev/null | cut -d= -f2 || echo "false")
        PLAN_LIFECYCLE=$(grep '^PLAN_LIFECYCLE=' "$_PLAN_CACHE" 2>/dev/null | cut -d= -f2 || echo "none")
        # Default any unset plan vars that the NEXT_ACTION logic may reference
        GIT_WT_COUNT="${GIT_WT_COUNT:-0}"
    fi

    # Test status (staleness-guarded)
    TEST_RESULT="unknown"
    TEST_FAILS=0
    TEST_STATUS_FILE="${CLAUDE_DIR}/.test-status"

    # Sleep loop removed (DEC-PERF-003): waiting 0-3.5s per turn for test-runner.sh
    # is unacceptable overhead. If .test-status doesn't exist yet, TEST_RESULT stays
    # "unknown" — the next stop.sh call catches it. Max latency: 1 turn.

    if [[ -f "$TEST_STATUS_FILE" ]]; then
        FILE_MOD=$(stat -c '%Y' "$TEST_STATUS_FILE" 2>/dev/null || stat -f '%m' "$TEST_STATUS_FILE" 2>/dev/null || echo "0")
        NOW=$(date +%s)
        FILE_AGE=$(( NOW - FILE_MOD ))
        if [[ "$FILE_AGE" -le "$SESSION_STALENESS_THRESHOLD" ]]; then
            TEST_RESULT=$(cut -d'|' -f1 "$TEST_STATUS_FILE")
            TEST_FAILS=$(cut -d'|' -f2 "$TEST_STATUS_FILE")
        fi
    fi

    GIT_LINE="Git: branch=$GIT_BRANCH"
    if [[ "$GIT_DIRTY_COUNT" -gt 0 ]]; then
        GIT_LINE+=", $GIT_DIRTY_COUNT uncommitted"
    else
        GIT_LINE+=", clean"
    fi
    case "$TEST_RESULT" in
        pass)    GIT_LINE+=". Tests: passing." ;;
        fail)    GIT_LINE+=". Tests: FAILING ($TEST_FAILS failure(s))." ;;
        *)       GIT_LINE+=". Tests: not run this session." ;;
    esac
    SESS_SUMMARY+="\n$GIT_LINE"

    # Proof-of-work status
    # OPT-5: Fast path — when no active-worktree breadcrumb exists, read .proof-status
    # directly from CLAUDE_DIR (common non-worktree case). Skip the full breadcrumb
    # chain. Falls back to resolve_proof_file() when breadcrumbs are present.
    _PHASH=$(project_hash "$PROJECT_ROOT")
    _FAST_PROOF="${CLAUDE_DIR}/.proof-status-${_PHASH}"
    _FAST_DEFAULT="${CLAUDE_DIR}/.proof-status"
    _HAS_BREADCRUMB=false
    # Check for any active worktree breadcrumb (session-scoped or project-scoped)
    if ls "${CLAUDE_DIR}/.active-worktree-path"* 2>/dev/null | head -1 | grep -q .; then
        _HAS_BREADCRUMB=true
    fi
    if ! $_HAS_BREADCRUMB; then
        # No worktree breadcrumb — direct path is safe
        if [[ -f "$_FAST_PROOF" ]]; then
            PROOF_STATUS_FILE="$_FAST_PROOF"
        elif [[ -f "$_FAST_DEFAULT" ]]; then
            PROOF_STATUS_FILE="$_FAST_DEFAULT"
        else
            PROOF_STATUS_FILE=""
        fi
    else
        # Worktree scenario — use full breadcrumb resolution
        PROOF_STATUS_FILE=$(resolve_proof_file)
        [[ ! -f "$PROOF_STATUS_FILE" ]] && PROOF_STATUS_FILE=""
    fi
    if [[ -n "$PROOF_STATUS_FILE" && -f "$PROOF_STATUS_FILE" ]]; then
        if validate_state_file "$PROOF_STATUS_FILE" 2; then
            _PROOF_VAL=$(cut -d'|' -f1 "$PROOF_STATUS_FILE" 2>/dev/null || echo "")
        else
            _PROOF_VAL=""  # corrupt — skip
        fi
        case "$_PROOF_VAL" in
            verified)           SESS_SUMMARY+="\nProof: verified." ;;
            pending)            SESS_SUMMARY+="\nProof: PENDING." ;;
            needs-verification) SESS_SUMMARY+="\nProof: PENDING." ;;
            *)                  SESS_SUMMARY+="\nProof: not started." ;;
        esac
    else
        SESS_SUMMARY+="\nProof: not started."
    fi

    # Workflow phase → next-action guidance
    IS_MAIN=false
    [[ "$GIT_BRANCH" == "main" || "$GIT_BRANCH" == "master" ]] && IS_MAIN=true

    NEXT_ACTION=""
    if $IS_MAIN; then
        if [[ "$PLAN_EXISTS" != "true" ]]; then
            NEXT_ACTION="Create MASTER_PLAN.md before implementation."
        elif [[ "$GIT_WT_COUNT" -eq 0 ]]; then
            NEXT_ACTION="Use Guardian to create worktrees for implementation."
        else
            NEXT_ACTION="Continue implementation in active worktrees."
        fi
    else
        if [[ "$TEST_RESULT" == "fail" ]]; then
            NEXT_ACTION="Fix failing tests ($TEST_FAILS failure(s)) before proceeding."
        elif [[ "$TEST_RESULT" != "pass" ]]; then
            NEXT_ACTION="Run tests to verify implementation before committing."
        elif [[ "$GIT_DIRTY_COUNT" -gt 0 ]]; then
            NEXT_ACTION="Review changes with user, then commit in this worktree when approved."
        else
            NEXT_ACTION="User should test the feature. When satisfied, use Guardian to merge to main."
        fi
    fi

    # Pending todos — read cached .todo-count (written by session-init.sh's todo.sh hud).
    # Background refresh if TTL expired — never blocks the Stop hook.
    # @decision DEC-PERF-003 (see core-lib.sh)
    TODO_CACHE="${CLAUDE_DIR}/.todo-count"
    if [[ -f "$TODO_CACHE" ]]; then
        TODO_PROJECT=$(cut -d'|' -f1 "$TODO_CACHE" 2>/dev/null) || TODO_PROJECT=0
        TODO_GLOBAL=$(cut -d'|' -f2 "$TODO_CACHE" 2>/dev/null) || TODO_GLOBAL=0
        TODO_CONFIG=$(cut -d'|' -f3 "$TODO_CACHE" 2>/dev/null) || TODO_CONFIG=0
        TODO_TOTAL=$((TODO_PROJECT + TODO_GLOBAL + TODO_CONFIG))
        if [[ "$TODO_TOTAL" -gt 0 ]]; then
            SESS_SUMMARY+="\nTodos: ${TODO_PROJECT} project + ${TODO_GLOBAL} global + ${TODO_CONFIG} config pending."
        fi
    fi
    # Async refresh if stale
    _TODO_SENTINEL="${CLAUDE_DIR}/.stop-todo-ttl"
    TODO_SCRIPT="$HOME/.claude/scripts/todo.sh"
    if _ttl_expired "$_TODO_SENTINEL" "$STOP_TODO_TTL" && [[ -x "$TODO_SCRIPT" ]] && command -v gh >/dev/null 2>&1; then
        _ttl_touch "$_TODO_SENTINEL"
        "$TODO_SCRIPT" hud >/dev/null 2>&1 &
    fi

    SESS_SUMMARY+="\nNext: $NEXT_ACTION"

    # Trajectory narrative
    EVENTS_FILE="${CLAUDE_DIR}/.session-events.jsonl"
    if [[ -f "$EVENTS_FILE" ]]; then
        set +e
        get_session_trajectory "$PROJECT_ROOT"
        detect_approach_pivots "$PROJECT_ROOT"
        set -e

        TRAJ_LINE=""
        if [[ "${TRAJ_TOOL_CALLS:-0}" -gt 0 ]]; then
            TRAJ_LINE="Trajectory: ${TRAJ_TOOL_CALLS} write(s) across ${TRAJ_FILES_MODIFIED} file(s)."
        fi
        if [[ "${TRAJ_TEST_FAILURES:-0}" -gt 0 ]]; then
            TRAJ_LINE="$TRAJ_LINE ${TRAJ_TEST_FAILURES} test failure(s)."
            TOP_ASSERTION=$(grep '"event":"test_run"' "$EVENTS_FILE" 2>/dev/null \
                | grep '"result":"fail"' \
                | jq -r '.assertion // empty' 2>/dev/null \
                | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
            if [[ -n "$TOP_ASSERTION" && "$TOP_ASSERTION" != "null" && "$TOP_ASSERTION" != "unknown" ]]; then
                TRAJ_LINE="$TRAJ_LINE Most-failed: \`${TOP_ASSERTION}\`."
            fi
        fi
        if [[ "${PIVOT_COUNT:-0}" -gt 0 ]]; then
            TRAJ_LINE="$TRAJ_LINE ${PIVOT_COUNT} approach pivot(s) detected (edit->fail loop)."
            if [[ -n "${PIVOT_FILES:-}" ]]; then
                PIVOT_BASE=$(echo "$PIVOT_FILES" | tr ' ' '\n' | xargs -I{} basename {} 2>/dev/null | paste -sd ', ' - || echo "$PIVOT_FILES")
                TRAJ_LINE="$TRAJ_LINE Looping files: ${PIVOT_BASE}."
            fi
        fi
        if [[ "${TRAJ_GATE_BLOCKS:-0}" -gt 0 ]]; then
            TRAJ_LINE="$TRAJ_LINE ${TRAJ_GATE_BLOCKS} gate block(s)."
        fi
        if [[ -n "${TRAJ_AGENTS:-}" ]]; then
            TRAJ_LINE="$TRAJ_LINE Agents: ${TRAJ_AGENTS}."
        fi
        if [[ -n "$TRAJ_LINE" ]]; then
            SESS_SUMMARY+="\n$TRAJ_LINE"
        fi

        # Write structured retrospective to sessions dir
        SESSIONS_DIR="$HOME/.claude/sessions"
        if [[ -d "$SESSIONS_DIR" ]]; then
            PROJECT_HASH=$(echo "$PROJECT_ROOT" | ${_SHA256_CMD:-shasum -a 256} 2>/dev/null | cut -c1-8 || echo "unknown")
            SESSION_DIR="$SESSIONS_DIR/$PROJECT_HASH"
            mkdir -p "$SESSION_DIR"
            SESSION_LABEL="${CLAUDE_SESSION_ID:-$(date +%Y%m%d-%H%M%S)}"
            RETRO_FILE="$SESSION_DIR/${SESSION_LABEL}-summary.md"
            cat > "$RETRO_FILE" <<RETRO
# Session Retrospective

**Date:** $(date -u +%Y-%m-%dT%H:%M:%SZ)
**Project:** $PROJECT_ROOT
**Branch:** $GIT_BRANCH

## Changes
- Files changed: $TOTAL_FILES ($SOURCE_COUNT_SUMMARY source, $CONFIG_COUNT config/other)
- Decisions annotated: $DECISIONS_ADDED

## Test Status
- Result: $TEST_RESULT
- Failures: $TEST_FAILS

## Trajectory
- Writes: ${TRAJ_TOOL_CALLS:-0} across ${TRAJ_FILES_MODIFIED:-0} file(s)
- Test failures: ${TRAJ_TEST_FAILURES:-0}
- Gate blocks: ${TRAJ_GATE_BLOCKS:-0}
- Approach pivots: ${PIVOT_COUNT:-0}
- Pivot files: ${PIVOT_FILES:-none}
- Pivot assertions: ${PIVOT_ASSERTIONS:-none}
- Agents used: ${TRAJ_AGENTS:-none}
- Duration: ${TRAJ_ELAPSED_MIN:-0}m

## Next
$NEXT_ACTION
RETRO
        fi
    fi

    _SUMMARY_PARTS+=("$(echo -e "$SESS_SUMMARY")")
fi

# ============================================================================
# SECTION 3a: Evidence Gate — reject bare completion claims without evidence
# Fires when: agents ran AND response claims completion AND no evidence shown
#
# @decision DEC-EVGATE-001
# @title Evidence gate via response signature analysis
# @status accepted
# @rationale Detects evidence via code blocks, terminal output, test results,
#   diff markers, and git log output. Stateless, fast (~80ms), no cross-hook
#   coordination needed. Triple-gated to prevent false positives.
#
# @decision DEC-EVGATE-002
# @title Triple-gate prevents false positives on normal responses
# @status accepted
# @rationale Gate 1 (agents ran) skips non-agent sessions. Gate 2 (completion
#   claim) skips informational/transitional responses. Gate 3 (no evidence)
#   skips evidence-rich responses. Stop hook only fires on final turn response.
# ============================================================================

_EVIDENCE_GATE_FIRED=false
# OPT-6: RESPONSE already populated from the merged jq call at the top of the hook.

if [[ -n "$RESPONSE" ]]; then
    EVENTS_FILE_EG="${CLAUDE_DIR}/.session-events.jsonl"

    # Gate 1: Did agents run this session?
    _AGENTS_RAN=false
    if [[ -f "$EVENTS_FILE_EG" ]] && grep -q '"agent_stop"' "$EVENTS_FILE_EG" 2>/dev/null; then
        _AGENTS_RAN=true
    fi

    if $_AGENTS_RAN; then
        # Gate 2: Does response claim completion?
        _CLAIMS_DONE=false
        if echo "$RESPONSE" | grep -qiE '\b(done|finished|completed|merged|pushed|deployed|committed|all set|wrapped up|nothing left)\b'; then
            _CLAIMS_DONE=true
        fi

        if $_CLAIMS_DONE; then
            # Gate 3: Does response contain evidence markers?
            _HAS_EVIDENCE=false

            # Check for code blocks (``` or ~~~)
            echo "$RESPONSE" | grep -qE '^```|^~~~' && _HAS_EVIDENCE=true
            # Check for terminal output ($ ... or % ...)
            ! $_HAS_EVIDENCE && echo "$RESPONSE" | grep -qE '^\$ |^% ' && _HAS_EVIDENCE=true
            # Check for test results (PASS/FAIL/checkmarks/N passed)
            ! $_HAS_EVIDENCE && echo "$RESPONSE" | grep -qE '\bPASS\b|\bFAIL\b|[0-9]+ passed' && _HAS_EVIDENCE=true
            # Check for diff markers
            ! $_HAS_EVIDENCE && echo "$RESPONSE" | grep -qE '^\+\+\+|^---|^@@' && _HAS_EVIDENCE=true
            # Check for git log output
            ! $_HAS_EVIDENCE && echo "$RESPONSE" | grep -qE 'commit [0-9a-f]{7,}' && _HAS_EVIDENCE=true

            if ! $_HAS_EVIDENCE; then
                _EVIDENCE_GATE_FIRED=true

                # Inject trace artifacts from recent traces
                _EV_INJECT=""
                for _ev_dir in $(ls -1d "${TRACE_STORE:-$HOME/.claude/traces}/"*-* 2>/dev/null | sort -r | head -3); do
                    _ev_content=$(read_trace_evidence "$_ev_dir" 2000 2>/dev/null || echo "")
                    if [[ -n "$_ev_content" ]]; then
                        _ev_agent=$(basename "$_ev_dir" | sed 's/-.*//')
                        _EV_INJECT="${_EV_INJECT}
--- ${_ev_agent} evidence ($(basename "$_ev_dir")) ---
${_ev_content}
"
                    fi
                done

                _EV_MSG="Response claims completion but contains no evidence for the user."
                if [[ -n "$_EV_INJECT" ]]; then
                    _EV_MSG="${_EV_MSG} Recent trace evidence:
${_EV_INJECT}
Present this evidence to the user before declaring done."
                else
                    _EV_MSG="${_EV_MSG} No trace artifacts found. Show the user actual output, test results, or diffs before declaring completion."
                fi

                _SUMMARY_PARTS+=("$_EV_MSG")
            fi
        fi
    fi
fi

# ============================================================================
# SECTION 3: Forward Motion — check response ends with question/offer/suggestion
# Ported from forward-motion.sh (52L)
# ============================================================================

# Note: RESPONSE already set in Section 3a above
if [[ -n "$RESPONSE" ]]; then
    LAST_PARA=$(echo "$RESPONSE" | awk '
        BEGIN { para="" }
        /^[[:space:]]*$/ { if (para != "") prev=para; para=""; next }
        { para = (para == "") ? $0 : para "\n" $0 }
        END { if (para != "") print para; else if (prev != "") print prev }
    ')

    if [[ -n "$LAST_PARA" ]]; then
        # Check for forward motion indicators
        if ! echo "$LAST_PARA" | grep -qiE '\?|want me to|shall I|let me know|would you like|should I|next step|what do you think|ready to|happy to|I can also|feel free|go ahead'; then
            # Check for bare completion statements without forward motion
            if echo "$LAST_PARA" | grep -qiE '\b(done|finished|completed|all set|that.s it|wrapped up)\b'; then
                if ! echo "$LAST_PARA" | grep -qF '?'; then
                    _SUMMARY_PARTS+=("Response lacks forward motion. End with a question, suggestion, or offer to continue.")
                    # Emit combined summary before exit 2
                    if [[ ${#_SUMMARY_PARTS[@]} -gt 0 ]]; then
                        COMBINED=$(printf '%s\n\n' "${_SUMMARY_PARTS[@]}" | sed 's/[[:space:]]*$//')
                        ESCAPED=$(echo "$COMBINED" | jq -Rs .)
                        cat <<HOOK_EOF
{
  "systemMessage": $ESCAPED
}
HOOK_EOF
                    fi
                    exit 2
                fi
            fi
        fi
    fi
fi

# Evidence gate exit — emit feedback with injected trace evidence
if [[ "$_EVIDENCE_GATE_FIRED" == "true" ]]; then
    if [[ ${#_SUMMARY_PARTS[@]} -gt 0 ]]; then
        COMBINED=$(printf '%s\n\n' "${_SUMMARY_PARTS[@]}" | sed 's/[[:space:]]*$//')
        ESCAPED=$(echo "$COMBINED" | jq -Rs .)
        cat <<HOOK_EOF
{
  "systemMessage": $ESCAPED
}
HOOK_EOF
    fi
    exit 2
fi

# ============================================================================
# Emit single combined systemMessage
# ============================================================================

if [[ ${#_SUMMARY_PARTS[@]} -gt 0 ]]; then
    COMBINED=$(printf '%s\n\n' "${_SUMMARY_PARTS[@]}" | sed 's/[[:space:]]*$//')
    ESCAPED=$(echo "$COMBINED" | jq -Rs .)
    cat <<HOOK_EOF
{
  "systemMessage": $ESCAPED
}
HOOK_EOF
fi

exit 0
