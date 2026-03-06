#!/usr/bin/env bash
# plan-lib.sh — MASTER_PLAN.md status and drift utilities for Claude Code hooks.
#
# Loaded on demand via: require_plan (defined in source-lib.sh)
# Depends on: core-lib.sh (must be loaded first; uses append_audit)
#
# @decision DEC-SPLIT-001 (see core-lib.sh for full rationale)
#
# Provides:
#   get_plan_status   - Populate PLAN_* globals from MASTER_PLAN.md
#   get_drift_data    - Populate DRIFT_* globals from .plan-drift
#   get_research_status - Populate RESEARCH_* globals from research-log.md
#   archive_plan      - Move MASTER_PLAN.md to archived-plans/
#   compress_initiative - Move completed initiative to Completed section

# Guard against double-sourcing
[[ -n "${_PLAN_LIB_LOADED:-}" ]] && return 0

_PLAN_LIB_VERSION=1

# --- MASTER_PLAN.md status ---
# @decision DEC-PLAN-003
# @title Initiative-level lifecycle replaces document-level
# @status accepted
# @rationale PLAN_LIFECYCLE becomes none/active/dormant based on ### Initiative: headers
#   and their **Status:** fields. "dormant" replaces "completed" — the living plan is
#   never "completed." Old format (## Phase N:) still supported for backward compatibility.
#   New format (### Initiative:): active if any initiative has Status: active,
#   dormant if all initiatives have Status: completed or Active section is empty.
#   PLAN_ACTIVE_INITIATIVES: count of ### Initiative: blocks with Status: active.
get_plan_status() {
    local root="$1"
    PLAN_EXISTS=false
    PLAN_PHASE=""
    PLAN_TOTAL_PHASES=0
    PLAN_COMPLETED_PHASES=0
    PLAN_IN_PROGRESS_PHASES=0
    PLAN_ACTIVE_INITIATIVES=0
    PLAN_TOTAL_INITIATIVES=0
    PLAN_AGE_DAYS=0
    PLAN_COMMITS_SINCE=0
    PLAN_CHANGED_SOURCE_FILES=0
    PLAN_TOTAL_SOURCE_FILES=0
    PLAN_SOURCE_CHURN_PCT=0
    PLAN_REQ_COUNT=0
    PLAN_P0_COUNT=0
    PLAN_NOGO_COUNT=0
    PLAN_LIFECYCLE="none"
    PLAN_ACTIVE_INITIATIVE_NAME=""
    PLAN_IN_PROGRESS_PHASE=""

    [[ ! -f "$root/MASTER_PLAN.md" ]] && return

    PLAN_EXISTS=true

    PLAN_PHASE=$(grep -iE '^\#.*phase|^\*\*Phase' "$root/MASTER_PLAN.md" 2>/dev/null | tail -1 || echo "")
    PLAN_REQ_COUNT=$(grep -coE 'REQ-[A-Z0-9]+-[0-9]+' "$root/MASTER_PLAN.md" 2>/dev/null || true)
    PLAN_REQ_COUNT=${PLAN_REQ_COUNT:-0}
    PLAN_P0_COUNT=$(grep -coE 'REQ-P0-[0-9]+' "$root/MASTER_PLAN.md" 2>/dev/null || true)
    PLAN_P0_COUNT=${PLAN_P0_COUNT:-0}
    PLAN_NOGO_COUNT=$(grep -coE 'REQ-NOGO-[0-9]+' "$root/MASTER_PLAN.md" 2>/dev/null || true)
    PLAN_NOGO_COUNT=${PLAN_NOGO_COUNT:-0}

    # --- Lifecycle detection: new format (### Initiative:) takes priority ---
    # New format is identified by "## Active Initiatives" or "## Completed Initiatives"
    # section headers. Using section headers as the discriminator (not just ### Initiative:
    # counts) means an empty Active Initiatives section is still recognized as new-format
    # and returns "dormant" rather than falling through to the old-format path which
    # defaults to "active". This fixes the edge case where all initiatives have been
    # compressed into the Completed table, leaving an empty Active section.
    local _has_initiatives _is_new_format
    # grep -cE can return "0\n0" on macOS (binary/text split) — take first line only
    _has_initiatives=$(grep -cE '^\#\#\#\s+Initiative:' "$root/MASTER_PLAN.md" 2>/dev/null | head -1 || echo "0")
    _has_initiatives=${_has_initiatives:-0}
    [[ "$_has_initiatives" =~ ^[0-9]+$ ]] || _has_initiatives=0

    # New format also detected by section-level headers even when Active section is empty
    _is_new_format=$(grep -cE '^## (Active|Completed) Initiatives' "$root/MASTER_PLAN.md" 2>/dev/null | head -1 || echo "0")
    _is_new_format=${_is_new_format:-0}
    [[ "$_is_new_format" =~ ^[0-9]+$ ]] || _is_new_format=0

    if [[ "$_has_initiatives" -gt 0 || "$_is_new_format" -gt 0 ]]; then
        # New living-document format: parse ### Initiative: blocks with Status fields.
        # Extract only the Active Initiatives section (stops at ## Completed Initiatives).
        local _active_section
        _active_section=$(awk '/^## Active Initiatives/{f=1} f && /^## Completed Initiatives/{exit} f{print}' \
            "$root/MASTER_PLAN.md" 2>/dev/null || echo "")

        # Count initiative blocks in Active Initiatives section
        PLAN_TOTAL_INITIATIVES=$(echo "$_active_section" | grep -cE '^\#\#\#\s+Initiative:' 2>/dev/null || echo "0")
        PLAN_TOTAL_INITIATIVES=${PLAN_TOTAL_INITIATIVES:-0}

        # Count active initiatives: ### Initiative: blocks with **Status:** active
        # Parse sequentially: enter initiative block on ### Initiative:, capture first Status line
        # Also capture the first active initiative's name for statusline display.
        PLAN_ACTIVE_INITIATIVES=0
        local _completed_count=0
        if [[ -n "$_active_section" ]]; then
            local _in_init=false _init_status="" _init_name=""
            while IFS= read -r _line; do
                # Pattern B: [[ =~ ]] replaces echo "$_line" | grep -qE (DEC-SIGPIPE-001).
                # Each grep in a tight read loop spawns a subshell+pipe; when the section
                # is large (1000+ lines), any broken pipe propagates exit 141 under pipefail.
                if [[ "$_line" =~ ^'###'[[:space:]]+'Initiative:' ]]; then
                    # Finalize previous initiative
                    if [[ "$_in_init" == "true" ]]; then
                        if [[ "$_init_status" == "active" ]]; then
                            PLAN_ACTIVE_INITIATIVES=$((PLAN_ACTIVE_INITIATIVES + 1))
                            # Capture first active initiative name
                            if [[ -z "$PLAN_ACTIVE_INITIATIVE_NAME" ]]; then
                                PLAN_ACTIVE_INITIATIVE_NAME="$_init_name"
                            fi
                        elif [[ "$_init_status" == "completed" ]]; then
                            _completed_count=$((_completed_count + 1))
                        fi
                    fi
                    _in_init=true
                    _init_status=""
                    # Extract name: everything after "### Initiative: "
                    _init_name="${_line#*Initiative: }"
                elif [[ "$_in_init" == "true" && -z "$_init_status" && "$_line" =~ ^\*\*Status:\*\* ]]; then
                    # First Status line after the Initiative header is the initiative status
                    # Case-insensitive match via [[ =~ ]] — bash 3.2 compatible (no ${var,,}).
                    # macOS ships bash 3.2 which lacks ,, (lowercase) operator.
                    if [[ "$_line" =~ [Aa]ctive ]]; then
                        _init_status="active"
                    elif [[ "$_line" =~ [Cc]ompleted ]]; then
                        _init_status="completed"
                    fi
                fi
            done <<< "$_active_section"
            # Finalize last initiative
            if [[ "$_in_init" == "true" ]]; then
                if [[ "$_init_status" == "active" ]]; then
                    PLAN_ACTIVE_INITIATIVES=$((PLAN_ACTIVE_INITIATIVES + 1))
                    # Capture first active initiative name
                    if [[ -z "$PLAN_ACTIVE_INITIATIVE_NAME" ]]; then
                        PLAN_ACTIVE_INITIATIVE_NAME="$_init_name"
                    fi
                elif [[ "$_init_status" == "completed" ]]; then
                    _completed_count=$((_completed_count + 1))
                fi
            fi
        fi

        # Second pass: find the first in-progress phase within the captured active initiative.
        # Also counts total phases within that initiative for the banner display.
        # Uses _active_section already in memory — no new file I/O.
        # @decision DEC-STATUSLINE-004
        # @title Per-initiative phase count for banner display
        # @status accepted
        # @rationale The banner shows "Phase N/M" where M is the total phases in the
        # active initiative (not across all initiatives). We count #### Phase headers
        # within the target initiative block during the same second-pass loop that finds
        # the in-progress phase — no additional file I/O. PLAN_TOTAL_PHASES is overwritten
        # from the global count (all active phases) to the per-initiative count when a
        # target initiative is found.
        if [[ -n "$PLAN_ACTIVE_INITIATIVE_NAME" && -n "$_active_section" ]]; then
            local _p2_in_target=false _p2_current_phase="" _p2_done=false _p2_phase_count=0 _p2_first_phase=""
            while IFS= read -r _line; do
                # Enter target initiative block
                if [[ "$_line" == "### Initiative: ${PLAN_ACTIVE_INITIATIVE_NAME}" ]]; then
                    _p2_in_target=true
                    continue
                fi
                # Leave target initiative block on next ### Initiative: or ## header
                if [[ "$_p2_in_target" == "true" ]]; then
                    if [[ "$_line" =~ ^'### Initiative:'|^'## ' ]]; then
                        break
                    fi
                    # Track phase headers: "#### Phase N:" — capture the full header and count
                    if [[ "$_line" =~ ^'####'[[:space:]]+'Phase'[[:space:]][0-9] ]]; then
                        _p2_current_phase="$_line"
                        _p2_phase_count=$(( _p2_phase_count + 1 ))
                        # Capture first phase header encountered for planned-phase fallback
                        [[ -z "$_p2_first_phase" ]] && _p2_first_phase="$_line"
                    fi
                    # When Status: in-progress follows a phase header, capture it (continue counting)
                    if [[ -n "$_p2_current_phase" && "$_p2_done" == "false" && "$_line" =~ ^\*\*Status:\*\*.*[Ii]n-[Pp]rogress ]]; then
                        PLAN_IN_PROGRESS_PHASE="$_p2_current_phase"
                        _p2_done=true
                    fi
                fi
            done <<< "$_active_section"
            # Fallback: if no in-progress phase but phases exist, use first phase with (planned) marker.
            # @decision DEC-PLANLIB-PLANNED-PHASE-001
            # @title Planned-phase fallback for initiative banner
            # @status accepted
            # @rationale When an initiative has only planned phases (none in-progress), the banner
            # previously showed no phase info. We capture the first phase header during the loop
            # and emit it with a " (planned)" suffix so statusline.sh can render it with dim styling.
            if [[ "$_p2_done" == "false" && -n "$_p2_first_phase" ]]; then
                # COUPLING: the " (planned)" suffix is detected by statusline.sh
                # (scripts/statusline.sh ~line 348: `*"(planned)"` glob).
                # If you change this marker, update the detection in statusline.sh too.
                PLAN_IN_PROGRESS_PHASE="${_p2_first_phase} (planned)"
            fi
            # Override global phase count with per-initiative count for banner accuracy
            if [[ "$_p2_in_target" == "true" && "$_p2_phase_count" -gt 0 ]]; then
                PLAN_TOTAL_PHASES="$_p2_phase_count"
            fi
        fi

        # Phase counts within Active Initiatives section (for status display)
        # head -1 guard: grep -cE can return "0\n0" on macOS when content triggers binary
        # detection (large sections with non-ASCII chars). Matches the head -1 guard on
        # _has_initiatives (line 98). Without it, arithmetic at write_statusline_cache
        # line 754 crashes: "0\n0: syntax error in expression".
        PLAN_TOTAL_PHASES=$(echo "$_active_section" | grep -cE '^\#\#\#\#\s+Phase\s+[0-9]' 2>/dev/null | head -1 || echo "0")
        PLAN_TOTAL_PHASES=${PLAN_TOTAL_PHASES:-0}
        [[ "$PLAN_TOTAL_PHASES" =~ ^[0-9]+$ ]] || PLAN_TOTAL_PHASES=0
        # Completed/in-progress counts: count phase-level Status lines only (#### Phase lines)
        # We count all Status: lines in active section; initiative Status lines are also counted
        # but that's acceptable for display purposes (plan-check uses PLAN_LIFECYCLE, not these)
        PLAN_COMPLETED_PHASES=$(echo "$_active_section" | grep -cE '\*\*Status:\*\*\s*completed' 2>/dev/null | head -1 || echo "0")
        PLAN_COMPLETED_PHASES=${PLAN_COMPLETED_PHASES:-0}
        [[ "$PLAN_COMPLETED_PHASES" =~ ^[0-9]+$ ]] || PLAN_COMPLETED_PHASES=0
        PLAN_IN_PROGRESS_PHASES=$(echo "$_active_section" | grep -cE '\*\*Status:\*\*\s*in-progress' 2>/dev/null | head -1 || echo "0")
        PLAN_IN_PROGRESS_PHASES=${PLAN_IN_PROGRESS_PHASES:-0}
        [[ "$PLAN_IN_PROGRESS_PHASES" =~ ^[0-9]+$ ]] || PLAN_IN_PROGRESS_PHASES=0

        # Lifecycle: active if any initiative is active, dormant otherwise
        if [[ "$PLAN_ACTIVE_INITIATIVES" -gt 0 ]]; then
            PLAN_LIFECYCLE="active"
        else
            # All initiatives in Active section are completed, or section is empty
            PLAN_LIFECYCLE="dormant"
        fi
    else
        # Old format: ## Phase N: headers at document level (backward compatibility)
        PLAN_TOTAL_PHASES=$(grep -cE '^\#\#\s+Phase\s+[0-9]' "$root/MASTER_PLAN.md" 2>/dev/null || true)
        PLAN_TOTAL_PHASES=${PLAN_TOTAL_PHASES:-0}
        PLAN_COMPLETED_PHASES=$(grep -cE '\*\*Status:\*\*\s*completed' "$root/MASTER_PLAN.md" 2>/dev/null || true)
        PLAN_COMPLETED_PHASES=${PLAN_COMPLETED_PHASES:-0}
        PLAN_IN_PROGRESS_PHASES=$(grep -cE '\*\*Status:\*\*\s*in-progress' "$root/MASTER_PLAN.md" 2>/dev/null || true)
        PLAN_IN_PROGRESS_PHASES=${PLAN_IN_PROGRESS_PHASES:-0}

        # Old format lifecycle: "dormant" replaces "completed" (DEC-PLAN-003)
        if [[ "$PLAN_TOTAL_PHASES" -gt 0 && "$PLAN_COMPLETED_PHASES" -eq "$PLAN_TOTAL_PHASES" ]]; then
            PLAN_LIFECYCLE="dormant"
        else
            PLAN_LIFECYCLE="active"
        fi
    fi

    # Plan age
    local plan_mod
    plan_mod=$(stat -c '%Y' "$root/MASTER_PLAN.md" 2>/dev/null || stat -f '%m' "$root/MASTER_PLAN.md" 2>/dev/null || echo "0")
    if [[ "$plan_mod" -gt 0 ]]; then
        local now
        now=$(date +%s)
        PLAN_AGE_DAYS=$(( (now - plan_mod) / 86400 ))

        # Commits since last plan update
        # @decision DEC-CHURN-CACHE-001
        # @title Cache plan churn calculation keyed on HEAD+plan_mod
        # @status accepted
        # @rationale git rev-list + git log + git ls-files cost 0.5-1s on each
        # startup. HEAD and plan_mod are stable between sessions unless the user
        # commits or edits MASTER_PLAN.md. Cache format:
        #   HEAD_SHORT|PLAN_MOD_EPOCH|COMMITS_SINCE|CHURN_PCT|CHANGED_FILES|TOTAL_FILES
        # Invalidated automatically when either key changes. Written atomically.
        if [[ -d "$root/.git" ]]; then
            local plan_date
            plan_date=$(date -r "$plan_mod" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@$plan_mod" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")
            if [[ -n "$plan_date" ]]; then
                local _churn_cache="$root/.claude/.plan-churn-cache"
                local _head_short
                _head_short=$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo "")
                local _cache_hit=false

                # Try cache read: compare HEAD_SHORT and plan_mod against stored keys
                if [[ -n "$_head_short" && -f "$_churn_cache" ]]; then
                    local _cached_line
                    _cached_line=$(cat "$_churn_cache" 2>/dev/null || echo "")
                    if [[ -n "$_cached_line" ]]; then
                        local _c_head _c_mod _c_commits _c_churn_pct _c_changed _c_total
                        IFS='|' read -r _c_head _c_mod _c_commits _c_churn_pct _c_changed _c_total <<< "$_cached_line"
                        if [[ "$_c_head" == "$_head_short" && "$_c_mod" == "$plan_mod" ]]; then
                            PLAN_COMMITS_SINCE="${_c_commits:-0}"
                            PLAN_SOURCE_CHURN_PCT="${_c_churn_pct:-0}"
                            PLAN_CHANGED_SOURCE_FILES="${_c_changed:-0}"
                            PLAN_TOTAL_SOURCE_FILES="${_c_total:-0}"
                            _cache_hit=true
                        fi
                    fi
                fi

                if [[ "$_cache_hit" == "false" ]]; then
                    PLAN_COMMITS_SINCE=$(git -C "$root" rev-list --count --after="$plan_date" HEAD 2>/dev/null || echo "0")

                    # Source file churn since plan update (primary staleness signal)
                    PLAN_CHANGED_SOURCE_FILES=$(git -C "$root" log --after="$plan_date" \
                        --name-only --format="" HEAD 2>/dev/null \
                        | sort -u \
                        | grep -cE "\.($SOURCE_EXTENSIONS)$" 2>/dev/null) || PLAN_CHANGED_SOURCE_FILES=0

                    PLAN_TOTAL_SOURCE_FILES=$(git -C "$root" ls-files 2>/dev/null \
                        | grep -cE "\.($SOURCE_EXTENSIONS)$" 2>/dev/null) || PLAN_TOTAL_SOURCE_FILES=0

                    if [[ "$PLAN_TOTAL_SOURCE_FILES" -gt 0 ]]; then
                        PLAN_SOURCE_CHURN_PCT=$((PLAN_CHANGED_SOURCE_FILES * 100 / PLAN_TOTAL_SOURCE_FILES))
                    fi

                    # Write cache (atomic via temp file)
                    if [[ -n "$_head_short" ]]; then
                        mkdir -p "$root/.claude"
                        local _tmp_cache
                        _tmp_cache=$(mktemp "$root/.claude/.plan-churn-cache.XXXXXX" 2>/dev/null) || true
                        if [[ -n "$_tmp_cache" ]]; then
                            printf '%s|%s|%s|%s|%s|%s\n' \
                                "$_head_short" "$plan_mod" \
                                "$PLAN_COMMITS_SINCE" "$PLAN_SOURCE_CHURN_PCT" \
                                "$PLAN_CHANGED_SOURCE_FILES" "$PLAN_TOTAL_SOURCE_FILES" \
                                > "$_tmp_cache" && mv "$_tmp_cache" "$_churn_cache" || rm -f "$_tmp_cache"
                        fi
                    fi
                fi
            fi
        fi
    fi
}

# --- Plan drift data (from previous session's surface audit) ---
get_drift_data() {
    local root="$1"
    DRIFT_UNPLANNED_COUNT=0
    DRIFT_UNIMPLEMENTED_COUNT=0
    DRIFT_MISSING_DECISIONS=0
    DRIFT_LAST_AUDIT_EPOCH=0

    local drift_file="$root/.claude/.plan-drift"
    [[ ! -f "$drift_file" ]] && return

    DRIFT_UNPLANNED_COUNT=$(grep '^unplanned_count=' "$drift_file" 2>/dev/null | cut -d= -f2) || DRIFT_UNPLANNED_COUNT=0
    DRIFT_UNIMPLEMENTED_COUNT=$(grep '^unimplemented_count=' "$drift_file" 2>/dev/null | cut -d= -f2) || DRIFT_UNIMPLEMENTED_COUNT=0
    DRIFT_MISSING_DECISIONS=$(grep '^missing_decisions=' "$drift_file" 2>/dev/null | cut -d= -f2) || DRIFT_MISSING_DECISIONS=0
    DRIFT_LAST_AUDIT_EPOCH=$(grep '^audit_epoch=' "$drift_file" 2>/dev/null | cut -d= -f2) || DRIFT_LAST_AUDIT_EPOCH=0
}

# --- Research log status ---
get_research_status() {
    local root="$1"
    RESEARCH_EXISTS=false
    RESEARCH_ENTRY_COUNT=0
    RESEARCH_RECENT_TOPICS=""

    local log="$root/.claude/research-log.md"
    [[ ! -f "$log" ]] && return

    RESEARCH_EXISTS=true
    RESEARCH_ENTRY_COUNT=$(grep -c '^### \[' "$log" 2>/dev/null || true)
    RESEARCH_ENTRY_COUNT=${RESEARCH_ENTRY_COUNT:-0}
    # Pattern E: replace grep|tail|sed|paste multi-stage pipe with awk (DEC-SIGPIPE-001).
    # Multi-stage pipes under set -euo pipefail can SIGPIPE when upstream produces more
    # output than downstream reads. awk handles the full pipeline in one process: collect
    # matching lines into an array, print the last 3 joined by ', '.
    RESEARCH_RECENT_TOPICS=$(awk '/^\#\#\# \[/{
        # Strip the "### [date] " prefix: remove up to and including first "] "
        sub(/^\#\#\# \[[^]]*\] /, "")
        topics[++n] = $0
    }
    END {
        start = (n > 3) ? n - 2 : 1
        sep = ""
        for (i = start; i <= n; i++) { printf "%s%s", sep, topics[i]; sep = ", " }
        print ""
    }' "$log" 2>/dev/null || echo "")
}

# --- Plan archival ---
# Moves a completed MASTER_PLAN.md to archived-plans/ with date prefix.
# Creates breadcrumb for session-init to detect.
# Usage: archive_plan "/path/to/project"
archive_plan() {
    local root="$1"
    local plan="$root/MASTER_PLAN.md"
    [[ ! -f "$plan" ]] && return 1

    local archive_dir="$root/archived-plans"
    mkdir -p "$archive_dir"

    # Extract plan title for readable filename
    local title
    title=$(head -1 "$plan" | sed 's/^# //' | sed 's/[^a-zA-Z0-9 -]//g' | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
    local date_prefix
    date_prefix=$(date +%Y-%m-%d)
    local archive_name="${date_prefix}_${title}.md"

    cp "$plan" "$archive_dir/$archive_name"
    rm "$plan"

    # Breadcrumb for session-init
    mkdir -p "$root/.claude"
    echo "archived=$archive_name" > "$root/.claude/.last-plan-archived"
    echo "epoch=$(date +%s)" >> "$root/.claude/.last-plan-archived"

    append_audit "$root" "plan_archived" "$archive_name"
    echo "$archive_name"
}

# --- Initiative compression: move completed initiative to Completed Initiatives ---
# @decision DEC-PLAN-006
# @title compress_initiative() helper for initiative lifecycle transitions
# @status accepted
# @rationale When all phases of an initiative are done, Guardian (or the user) can call
#   compress_initiative() to move it from ## Active Initiatives to ## Completed Initiatives.
#   The compressed form is a table row: name, period, phase count, key decisions, archive ref.
#   This keeps the living plan readable as initiatives accumulate. The function is a pure
#   file transform — it reads MASTER_PLAN.md, removes the initiative block from the Active
#   section, and appends a compressed row to the Completed section. Idempotent: if the
#   initiative is already in Completed, it is not added again.
#
# Usage: compress_initiative <plan_file> <initiative_name>
#   <plan_file>       — absolute path to MASTER_PLAN.md
#   <initiative_name> — name exactly as it appears after "### Initiative: "
#
# Populates no globals. Modifies <plan_file> in place (atomic via temp file).
compress_initiative() {
    local plan_file="$1"
    local init_name="$2"

    [[ ! -f "$plan_file" ]] && return 1
    [[ -z "$init_name" ]] && return 1

    # Already compressed? If name appears in Completed Initiatives table, skip.
    local _completed_section
    _completed_section=$(awk '/^## Completed Initiatives/{f=1} f{print}' "$plan_file" 2>/dev/null || echo "")
    if echo "$_completed_section" | grep -qF "| $init_name "; then
        return 0  # idempotent
    fi

    # Extract the initiative block from Active Initiatives section
    # Block starts at "### Initiative: <name>" and ends before the next "### Initiative:" or "## "
    # Pattern B: [[ =~ ]] replaces echo "$_line" | grep -qE throughout this function (DEC-SIGPIPE-001).
    local _init_block=""
    local _in_block=false
    local _started_line
    while IFS= read -r _line; do
        if [[ "$_line" == "### Initiative: ${init_name}" ]]; then
            _in_block=true
            _init_block="${_line}"$'\n'
            continue
        fi
        if [[ "$_in_block" == "true" ]]; then
            # Stop at next ### Initiative: or ## section header
            if [[ "$_line" =~ ^'### Initiative:'|^'## ' ]]; then
                break
            fi
            _init_block+="${_line}"$'\n'
        fi
    done < "$plan_file"

    if [[ -z "$_init_block" ]]; then
        return 1  # initiative not found
    fi

    # Extract metadata from the block for the compressed row
    local _started _goal _dec_ids _phase_count
    _started=$(echo "$_init_block" | grep -iE '^\*\*Started:\*\*' | head -1 | sed 's/\*\*Started:\*\*[[:space:]]*//' | tr -d '\n')
    _goal=$(echo "$_init_block" | grep -iE '^\*\*Goal:\*\*' | head -1 | sed 's/\*\*Goal:\*\*[[:space:]]*//' | tr -d '\n')
    _phase_count=$(echo "$_init_block" | grep -cE '^#### Phase' 2>/dev/null || echo "0")
    _dec_ids=$(echo "$_init_block" | grep -oE 'DEC-[A-Z]+-[0-9]+' | sort -u | tr '\n' ',' | sed 's/,$//' || echo "—")
    [[ -z "$_dec_ids" ]] && _dec_ids="—"
    [[ -z "$_started" ]] && _started="unknown"

    # Build compressed row
    local _today
    _today=$(date '+%Y-%m-%d' 2>/dev/null || echo "unknown")
    local _period="${_started} — ${_today}"
    local _compressed_row="| ${init_name} | ${_period} | ${_phase_count} | ${_dec_ids} | — |"

    # Write updated file: remove initiative block from Active Initiatives, append to Completed
    local _tmp_file
    _tmp_file=$(mktemp "${plan_file}.compress.XXXXXX" 2>/dev/null) || return 1

    local _in_active=false _in_target=false _skip_block=false
    local _in_completed=false _completed_header_written=false
    local _appended=false

    while IFS= read -r _line; do
        # Track section boundaries — Pattern B: [[ =~ ]] replaces echo|grep-qE (DEC-SIGPIPE-001)
        if [[ "$_line" == "## Active Initiatives" ]]; then
            _in_active=true
            _in_completed=false
            printf '%s\n' "$_line" >> "$_tmp_file"
            continue
        fi
        if [[ "$_line" == "## Completed Initiatives" ]]; then
            _in_active=false
            _in_completed=true
            printf '%s\n' "$_line" >> "$_tmp_file"
            continue
        fi
        if [[ "$_line" =~ ^'## ' && "$_line" != "## Active Initiatives" && "$_line" != "## Completed Initiatives" ]]; then
            _in_active=false
            _in_completed=false
        fi

        # In Active section: skip the target initiative block
        if [[ "$_in_active" == "true" ]]; then
            if [[ "$_line" == "### Initiative: ${init_name}" ]]; then
                _skip_block=true
                continue
            fi
            if [[ "$_skip_block" == "true" ]]; then
                # End of block: next ### Initiative: or ## section header
                if [[ "$_line" =~ ^'### Initiative:'|^'## ' ]]; then
                    _skip_block=false
                    # Don't skip this line — it starts the next block
                    printf '%s\n' "$_line" >> "$_tmp_file"
                fi
                # Skip all lines within the target block
                continue
            fi
        fi

        # In Completed section: append compressed row after the table separator if not yet done
        if [[ "$_in_completed" == "true" && "$_appended" == "false" ]]; then
            printf '%s\n' "$_line" >> "$_tmp_file"
            # After the separator row (| --- | line), append the compressed row
            if [[ "$_line" =~ ^\|[-\ |]+\| ]]; then
                printf '%s\n' "$_compressed_row" >> "$_tmp_file"
                _appended=true
            fi
            continue
        fi

        printf '%s\n' "$_line" >> "$_tmp_file"
    done < "$plan_file"

    # If Completed section had no separator row yet, just append at end
    if [[ "$_appended" == "false" ]]; then
        printf '%s\n' "$_compressed_row" >> "$_tmp_file"
    fi

    mv "$_tmp_file" "$plan_file"
}

export -f get_plan_status get_drift_data get_research_status archive_plan compress_initiative

_PLAN_LIB_LOADED=1
