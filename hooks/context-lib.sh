#!/usr/bin/env bash
# Shared context-building library for Claude Code hooks.
# Source this file from hooks that need project context:
#   source "$(dirname "$0")/context-lib.sh"
#
# @decision DEC-CTXLIB-001
# @title Shared context library consolidates duplicate hook code
# @status accepted
# @rationale session-init.sh, prompt-submit.sh, and subagent-start.sh all
#   duplicated git state, plan status, and worktree listing code. A shared
#   library eliminates drift and reduces maintenance surface. Functions are
#   exported for subshell access. Cache keyed on HEAD+mod_time for performance.
#
# @decision DEC-SIGPIPE-001
# @title Replace echo|grep and awk|head pipe patterns with SIGPIPE-safe equivalents
# @status accepted
# @rationale Under set -euo pipefail, any pipe where the reader closes before the
#   writer finishes (SIGPIPE) propagates exit 141 and kills the hook. Two patterns
#   were dangerous: (1) `echo "$var" | grep -qE` in tight while-read loops over
#   large plan sections — each spawns a subshell+pipe, and on macOS the shell
#   delivers SIGPIPE to the writer when grep exits early; (2) multi-stage pipes
#   like `grep | tail | sed | paste` in get_research_status(). Fixes applied:
#   Pattern B — replace `echo "$_line" | grep -qE 'pat'` with `[[ "$_line" =~ pat ]]`
#   (no subshell, no pipe). Pattern E — replace multi-stage pipe with a single awk
#   program that collects, filters, and formats in one process. See DEC-SIGPIPE-001
#   in session-init.sh for Pattern A (awk|head → inline awk limit) and Pattern C
#   (echo|sed → bash parameter expansion).
#
# Provides:
#   get_git_state <project_root>     - Populates GIT_BRANCH, GIT_DIRTY_COUNT,
#                                      GIT_WORKTREES, GIT_WT_COUNT
#   get_plan_status <project_root>   - Populates PLAN_EXISTS, PLAN_PHASE,
#                                      PLAN_TOTAL_PHASES, PLAN_COMPLETED_PHASES,
#                                      PLAN_AGE_DAYS, PLAN_COMMITS_SINCE,
#                                      PLAN_CHANGED_SOURCE_FILES,
#                                      PLAN_TOTAL_SOURCE_FILES,
#                                      PLAN_SOURCE_CHURN_PCT,
#                                      PLAN_REQ_COUNT, PLAN_P0_COUNT,
#                                      PLAN_NOGO_COUNT, PLAN_LIFECYCLE
#   get_doc_freshness <project_root> - Populates DOC_STALE_COUNT,
#                                      DOC_STALE_WARN, DOC_STALE_DENY,
#                                      DOC_MOD_ADVISORY, DOC_FRESHNESS_SUMMARY
#   get_session_changes <project_root> - Populates SESSION_CHANGED_COUNT
#   get_drift_data <project_root>    - Populates DRIFT_UNPLANNED_COUNT,
#                                      DRIFT_UNIMPLEMENTED_COUNT,
#                                      DRIFT_MISSING_DECISIONS,
#                                      DRIFT_LAST_AUDIT_EPOCH

# project_hash — compute deterministic 8-char hash of a project root path.
# Duplicated from log.sh so context-lib.sh can be sourced independently.
# Both definitions are identical; double-sourcing is safe (last definition wins).
# @decision DEC-ISOLATION-001 (see log.sh for full rationale)
project_hash() {
    echo "${1:?project_hash requires a path argument}" | shasum -a 256 | cut -c1-8
}

# --- Git state ---
get_git_state() {
    local root="$1"
    GIT_BRANCH=""
    GIT_DIRTY_COUNT=0
    GIT_WORKTREES=""
    GIT_WT_COUNT=0

    [[ ! -d "$root/.git" ]] && return

    GIT_BRANCH=$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    GIT_DIRTY_COUNT=$(git -C "$root" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

    GIT_WORKTREES=$(git -C "$root" worktree list 2>/dev/null | grep -v "(bare)" | tail -n +2 || echo "")
    if [[ -n "$GIT_WORKTREES" ]]; then
        GIT_WT_COUNT=$(echo "$GIT_WORKTREES" | wc -l | tr -d ' ')
    fi
}

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
        PLAN_ACTIVE_INITIATIVES=0
        local _completed_count=0
        if [[ -n "$_active_section" ]]; then
            local _in_init=false _init_status=""
            while IFS= read -r _line; do
                # Pattern B: [[ =~ ]] replaces echo "$_line" | grep -qE (DEC-SIGPIPE-001).
                # Each grep in a tight read loop spawns a subshell+pipe; when the section
                # is large (1000+ lines), any broken pipe propagates exit 141 under pipefail.
                if [[ "$_line" =~ ^'###'[[:space:]]+'Initiative:' ]]; then
                    # Finalize previous initiative
                    if [[ "$_in_init" == "true" ]]; then
                        if [[ "$_init_status" == "active" ]]; then
                            PLAN_ACTIVE_INITIATIVES=$((PLAN_ACTIVE_INITIATIVES + 1))
                        elif [[ "$_init_status" == "completed" ]]; then
                            _completed_count=$((_completed_count + 1))
                        fi
                    fi
                    _in_init=true
                    _init_status=""
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
                elif [[ "$_init_status" == "completed" ]]; then
                    _completed_count=$((_completed_count + 1))
                fi
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

# --- Documentation freshness detection ---
# @decision DEC-DOCFRESH-001
# @title get_doc_freshness uses structural churn (add/delete) not modification churn for block decisions
# @status accepted
# @rationale Modification churn (a file was edited) is a noisy signal — it includes
#   refactors, bug fixes, and typos that don't require doc updates. Structural churn
#   (new files added, files deleted) definitively signals scope change that docs MUST
#   capture. Calendar age is a secondary signal for docs that haven't been touched
#   regardless of code changes. Modification churn is kept as advisory-only.
#
# @decision DEC-DOCFRESH-002
# @title Doc freshness cache keyed on HEAD+doc_mod_times (same as plan churn cache)
# @status accepted
# @rationale git log calls cost 0.2-0.5s each. With 4 docs and 2 git log calls each,
#   uncached this adds 1.6-4s to every hook invocation. The HEAD+doc_mod_times cache
#   key is stable unless a commit lands or a doc is edited — identical to the plan
#   churn cache pattern (DEC-CHURN-CACHE-001). Cache format (pipe-delimited):
#   HEAD_SHORT|DOC_MOD_TIMES_HASH|STALE_COUNT|WARN_LIST|DENY_LIST|MOD_ADVISORY|SUMMARY
#   Written atomically. Invalidated when key changes.
#
# Populates globals:
#   DOC_STALE_COUNT     — number of docs in warn or deny tier
#   DOC_STALE_WARN[]    — docs in warn tier (array, bash 3.2: space-sep string)
#   DOC_STALE_DENY[]    — docs in deny tier (array, bash 3.2: space-sep string)
#   DOC_MOD_ADVISORY[]  — docs with high modification churn (advisory only)
#   DOC_FRESHNESS_SUMMARY — one-line human summary
get_doc_freshness() {
    local root="$1"
    DOC_STALE_COUNT=0
    DOC_STALE_WARN=""
    DOC_STALE_DENY=""
    DOC_MOD_ADVISORY=""
    DOC_FRESHNESS_SUMMARY="Doc freshness: OK"

    [[ ! -d "$root/.git" ]] && return

    local scope_map="$root/hooks/doc-scope.json"
    # Worktree path may be under .worktrees/ — check parent repo
    if [[ ! -f "$scope_map" ]]; then
        local common_dir
        common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null || echo "")
        if [[ -n "$common_dir" && "$common_dir" != /* ]]; then
            common_dir=$(cd "$root" && cd "$common_dir" && pwd)
        fi
        local repo_root="${common_dir%/.git}"
        [[ -f "$repo_root/hooks/doc-scope.json" ]] && scope_map="$repo_root/hooks/doc-scope.json"
    fi
    [[ ! -f "$scope_map" ]] && return

    local _head_short
    _head_short=$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo "")
    [[ -z "$_head_short" ]] && return

    # Build cache key: HEAD + modification times of all docs in scope map
    local _doc_keys
    _doc_keys=$(jq -r 'keys[]' "$scope_map" 2>/dev/null | sort | while read -r doc; do
        local doc_path="$root/$doc"
        if [[ -f "$doc_path" ]]; then
            stat -c '%Y' "$doc_path" 2>/dev/null || stat -f '%m' "$doc_path" 2>/dev/null || echo "0"
        else
            echo "missing"
        fi
    done | tr '\n' ':')
    local _doc_mod_hash
    _doc_mod_hash=$(echo "$_doc_keys" | shasum -a 256 2>/dev/null | cut -c1-8 || echo "x")

    local _cache_file="$root/.claude/.doc-freshness-cache"

    # Try cache read
    if [[ -f "$_cache_file" ]]; then
        local _cached_line
        _cached_line=$(head -1 "$_cache_file" 2>/dev/null || echo "")
        if [[ -n "$_cached_line" ]]; then
            local _c_head _c_hash _c_count _c_warn _c_deny _c_advisory _c_summary
            IFS='|' read -r _c_head _c_hash _c_count _c_warn _c_deny _c_advisory _c_summary <<< "$_cached_line"
            if [[ "$_c_head" == "$_head_short" && "$_c_hash" == "$_doc_mod_hash" ]]; then
                DOC_STALE_COUNT="${_c_count:-0}"
                DOC_STALE_WARN="${_c_warn:-}"
                DOC_STALE_DENY="${_c_deny:-}"
                DOC_MOD_ADVISORY="${_c_advisory:-}"
                DOC_FRESHNESS_SUMMARY="${_c_summary:-Doc freshness: OK}"
                return
            fi
        fi
    fi

    # Cache miss — compute freshness
    local now
    now=$(date +%s)
    local warn_list="" deny_list="" advisory_list=""
    local stale_count=0

    # Read each doc from scope map
    local doc_names
    doc_names=$(jq -r 'keys[]' "$scope_map" 2>/dev/null | sort)

    while IFS= read -r doc; do
        [[ -z "$doc" ]] && continue

        local trigger
        trigger=$(jq -r --arg d "$doc" '.[$d].trigger // "structural_churn"' "$scope_map" 2>/dev/null)

        # CHANGELOG.md: advisory only, no structural analysis
        if [[ "$trigger" == "advisory_only" ]]; then
            continue
        fi

        local warn_thresh block_thresh min_scope
        warn_thresh=$(jq -r --arg d "$doc" '.[$d].warn_threshold // 2' "$scope_map" 2>/dev/null)
        block_thresh=$(jq -r --arg d "$doc" '.[$d].block_threshold // 5' "$scope_map" 2>/dev/null)
        min_scope=$(jq -r --arg d "$doc" '.[$d].min_scope_size // 5' "$scope_map" 2>/dev/null)

        local doc_path="$root/$doc"
        [[ ! -f "$doc_path" ]] && continue

        # Resolve scope globs to tracked file list
        local scope_globs
        scope_globs=$(jq -r --arg d "$doc" '.[$d].scope[]? // empty' "$scope_map" 2>/dev/null)
        [[ -z "$scope_globs" ]] && continue

        local scope_files=""
        while IFS= read -r glob; do
            [[ -z "$glob" ]] && continue
            local glob_files
            glob_files=$(git -C "$root" ls-files "$glob" 2>/dev/null || echo "")
            if [[ -n "$glob_files" ]]; then
                scope_files="${scope_files}${glob_files}"$'\n'
            fi
        done <<< "$scope_globs"

        # Handle excludes
        local excludes
        excludes=$(jq -r --arg d "$doc" '.[$d].exclude[]? // empty' "$scope_map" 2>/dev/null)
        if [[ -n "$excludes" ]]; then
            while IFS= read -r excl; do
                [[ -z "$excl" ]] && continue
                scope_files=$(echo "$scope_files" | grep -v "^$excl$" || true)
            done <<< "$excludes"
        fi

        # Count files in scope (after dedup)
        local scope_count
        scope_count=$(echo "$scope_files" | sort -u | grep -c '.' 2>/dev/null || echo "0")

        # Skip if scope is too small
        if [[ "$scope_count" -lt "$min_scope" ]]; then
            continue
        fi

        # Get doc's last commit SHA and epoch (use %at = Unix timestamp).
        # @decision DEC-DOCFRESH-007
        # @title Use git log --format='%at' (epoch) and SHA range instead of --after=ISO8601
        # @status accepted
        # @rationale Two bugs in the original approach:
        #   (1) git log --format='%aI' returns timezone with colon (e.g. +00:00). macOS
        #       date -j -f '%z' expects +0000 (no colon), so parsing fails and doc_epoch=0.
        #       age_days = (now - 0) / 86400 ≈ 20000 — every doc triggers calendar-age deny.
        #       Fix: use %at (Unix epoch) to skip date string parsing entirely.
        #   (2) git log --after="ISO_DATE" is inclusive of commits at the exact same second
        #       as the doc commit. Files added in the doc commit itself (e.g. hooks/existing.sh
        #       created alongside the doc) appear as "Added" in --diff-filter=AD results,
        #       causing false structural churn even when no changes occurred after the doc.
        #       Fix: use SHA range DOC_SHA..HEAD which is strictly exclusive of the doc commit.
        local doc_sha
        doc_sha=$(git -C "$root" log -1 --format='%H' -- "$doc" 2>/dev/null | head -1)
        [[ -z "$doc_sha" ]] && continue

        local doc_epoch
        doc_epoch=$(git -C "$root" log -1 --format='%at' -- "$doc" 2>/dev/null | head -1)
        [[ -z "$doc_epoch" ]] && continue

        # Calendar age of doc
        local age_days=0
        if [[ "$doc_epoch" -gt 0 ]]; then
            age_days=$(( (now - doc_epoch) / 86400 ))
        fi

        # Count structural changes (added/deleted files) in scope since doc's last commit.
        # Use SHA range (DOC_SHA..HEAD) — strictly excludes the doc commit itself, unlike
        # --after=DATE which is inclusive of the exact same second.
        local structural_count=0
        local added_deleted_raw
        added_deleted_raw=$(git -C "$root" log --diff-filter=AD --name-only --format="" \
            "${doc_sha}..HEAD" 2>/dev/null | sort -u | grep -v '^$' || true)

        if [[ -n "$added_deleted_raw" && -n "$scope_files" ]]; then
            # Filter to only files in our scope set
            local scope_sorted
            scope_sorted=$(echo "$scope_files" | sort -u | grep -v '^$')
            while IFS= read -r f; do
                [[ -z "$f" ]] && continue
                if echo "$scope_sorted" | grep -qxF "$f" 2>/dev/null; then
                    structural_count=$(( structural_count + 1 ))
                fi
            done <<< "$added_deleted_raw"
        fi

        # Count modified files in scope since doc's last commit (advisory only).
        # Also uses SHA range for consistency.
        local mod_count=0
        local modified_raw
        modified_raw=$(git -C "$root" log --diff-filter=M --name-only --format="" \
            "${doc_sha}..HEAD" 2>/dev/null | sort -u | grep -v '^$' || true)

        if [[ -n "$modified_raw" && -n "$scope_files" ]]; then
            local scope_sorted2
            scope_sorted2=$(echo "$scope_files" | sort -u | grep -v '^$')
            while IFS= read -r f; do
                [[ -z "$f" ]] && continue
                if echo "$scope_sorted2" | grep -qxF "$f" 2>/dev/null; then
                    mod_count=$(( mod_count + 1 ))
                fi
            done <<< "$modified_raw"
        fi

        # Compute modification churn percentage
        local mod_pct=0
        if [[ "$scope_count" -gt 0 && "$mod_count" -gt 0 ]]; then
            mod_pct=$(( mod_count * 100 / scope_count ))
        fi

        # --- Classify tier ---
        local tier="ok"

        # Structural churn takes precedence for block/warn
        if [[ "$structural_count" -ge "$block_thresh" ]]; then
            tier="deny"
        elif [[ "$structural_count" -ge "$warn_thresh" ]]; then
            tier="warn"
        fi

        # Calendar age: secondary signal
        if [[ "$tier" == "ok" ]]; then
            if [[ "$age_days" -ge 60 ]]; then
                tier="deny"
            elif [[ "$age_days" -ge 30 ]]; then
                tier="warn"
            fi
        fi

        # Accumulate results
        case "$tier" in
            deny)
                stale_count=$(( stale_count + 1 ))
                deny_list="${deny_list:+$deny_list }$doc"
                ;;
            warn)
                stale_count=$(( stale_count + 1 ))
                warn_list="${warn_list:+$warn_list }$doc"
                ;;
        esac

        # Modification advisory (>60% churn): always advisory, never blocks
        if [[ "$mod_pct" -gt 60 ]]; then
            advisory_list="${advisory_list:+$advisory_list }$doc"
        fi

    done <<< "$doc_names"

    DOC_STALE_COUNT="$stale_count"
    DOC_STALE_WARN="$warn_list"
    DOC_STALE_DENY="$deny_list"
    DOC_MOD_ADVISORY="$advisory_list"

    # Build summary
    if [[ "$stale_count" -eq 0 && -z "$advisory_list" ]]; then
        DOC_FRESHNESS_SUMMARY="Doc freshness: OK"
    elif [[ "$stale_count" -gt 0 ]]; then
        DOC_FRESHNESS_SUMMARY="Doc freshness: ${stale_count} doc(s) stale"
        [[ -n "$deny_list" ]] && DOC_FRESHNESS_SUMMARY="${DOC_FRESHNESS_SUMMARY} [BLOCK: ${deny_list}]"
        [[ -n "$warn_list" ]] && DOC_FRESHNESS_SUMMARY="${DOC_FRESHNESS_SUMMARY} [WARN: ${warn_list}]"
    else
        DOC_FRESHNESS_SUMMARY="Doc freshness: OK (mod advisory: ${advisory_list})"
    fi

    # Write cache (atomic)
    mkdir -p "$root/.claude"
    local _tmp_cache
    _tmp_cache=$(mktemp "$root/.claude/.doc-freshness-cache.XXXXXX" 2>/dev/null) || true
    if [[ -n "$_tmp_cache" ]]; then
        printf '%s|%s|%s|%s|%s|%s|%s\n' \
            "$_head_short" "$_doc_mod_hash" \
            "$DOC_STALE_COUNT" "$DOC_STALE_WARN" "$DOC_STALE_DENY" \
            "$DOC_MOD_ADVISORY" "$DOC_FRESHNESS_SUMMARY" \
            > "$_tmp_cache" && mv "$_tmp_cache" "$_cache_file" || rm -f "$_tmp_cache"
    fi
}

# --- Session tracking ---
# @decision DEC-V3-005
# @title Robust session file lookup with glob fallback and legacy name support
# @status accepted
# @rationale surface.sh had the most complete implementation: session-ID lookup,
#   generic fallback, glob fallback, and legacy .session-decisions support. The
#   shared library had only session-ID + generic fallback — missing the glob and
#   legacy paths. Porting the full implementation here eliminates divergence and
#   ensures all callers (compact-preserve.sh, surface.sh, session-summary.sh)
#   use the same lookup order. Zero behavioral change for callers already using
#   get_session_changes().
get_session_changes() {
    local root="$1"
    SESSION_CHANGED_COUNT=0
    SESSION_FILE=""

    local claude_dir="$root/.claude"
    local session_id="${CLAUDE_SESSION_ID:-}"

    if [[ -n "$session_id" && -f "${claude_dir}/.session-changes-${session_id}" ]]; then
        SESSION_FILE="${claude_dir}/.session-changes-${session_id}"
    elif [[ -f "${claude_dir}/.session-changes" ]]; then
        SESSION_FILE="${claude_dir}/.session-changes"
    else
        # Glob fallback for any session file (e.g. from a different session ID)
        # shellcheck disable=SC2012
        SESSION_FILE=$(ls "${claude_dir}/.session-changes"* 2>/dev/null | head -1 || echo "")
        # Also check legacy name (.session-decisions)
        if [[ -z "$SESSION_FILE" ]]; then
            # shellcheck disable=SC2012
            SESSION_FILE=$(ls "${claude_dir}/.session-decisions"* 2>/dev/null | head -1 || echo "")
        fi
    fi

    if [[ -n "$SESSION_FILE" && -f "$SESSION_FILE" ]]; then
        SESSION_CHANGED_COUNT=$(sort -u "$SESSION_FILE" | wc -l | tr -d ' ')
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

# --- Constants ---
# Single source of truth for thresholds and patterns across all hooks.
# DECISION: Consolidated constants. Rationale: Magic numbers duplicated across
# hooks create drift risk when requirements change. Status: accepted.
DECISION_LINE_THRESHOLD=50
TEST_STALENESS_THRESHOLD=600    # 10 minutes in seconds
SESSION_STALENESS_THRESHOLD=1800 # 30 minutes in seconds

# --- Source file detection ---
# Single source of truth for source file extensions across all hooks.
# DECISION: Consolidated extension list. Rationale: Source file regex was
# copy-pasted in 8+ hooks creating drift risk. Status: accepted.
SOURCE_EXTENSIONS='ts|tsx|js|jsx|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php|sh|bash|zsh'

# Check if a file is a source file by extension
is_source_file() {
    local file="$1"
    [[ "$file" =~ \.($SOURCE_EXTENSIONS)$ ]]
}

# Check if a file should be skipped (test, config, generated, vendor)
is_skippable_path() {
    local file="$1"
    # Skip config files, test files, generated files
    [[ "$file" =~ (\.config\.|\.test\.|\.spec\.|__tests__|\.generated\.|\.min\.) ]] && return 0
    # Skip vendor/build directories
    [[ "$file" =~ (node_modules|vendor|dist|build|\.next|__pycache__|\.git) ]] && return 0
    return 1
}

# Check if a file is a test file by path and naming convention
is_test_file() {
    local file="$1"
    [[ "$file" =~ \.test\. ]] && return 0
    [[ "$file" =~ \.spec\. ]] && return 0
    [[ "$file" =~ __tests__/ ]] && return 0
    [[ "$file" =~ _test\.go$ ]] && return 0
    [[ "$file" =~ _test\.py$ ]] && return 0
    [[ "$file" =~ test_[^/]*\.py$ ]] && return 0
    [[ "$file" =~ /tests/ ]] && return 0
    [[ "$file" =~ /test/ ]] && return 0
    return 1
}

# Read .test-status and populate TEST_RESULT, TEST_FAILS, TEST_TIME, TEST_AGE globals.
# Returns 0 on success, 1 if status file doesn't exist.
# Usage: read_test_status "$PROJECT_ROOT"
read_test_status() {
    local root="${1:-.}"
    local status_file="$root/.claude/.test-status"
    TEST_RESULT="" TEST_FAILS="" TEST_TIME="" TEST_AGE=""
    [[ -f "$status_file" ]] || return 1
    TEST_RESULT=$(cut -d'|' -f1 < "$status_file")
    TEST_FAILS=$(cut -d'|' -f2 < "$status_file")
    TEST_TIME=$(cut -d'|' -f3 < "$status_file")
    local now; now=$(date +%s)
    TEST_AGE=$(( now - TEST_TIME ))
    return 0
}

# --- State file validation ---
# @decision DEC-INTEGRITY-001
# @title validate_state_file guards corrupt-file reads in guard.sh
# @status accepted
# @rationale guard.sh reads .proof-status and .test-status via cut. A corrupt
#   or empty file causes cut to return an empty string, which then falls through
#   to unexpected code paths. Worse, a missing file guarded only by -f can still
#   fail if the inode is deleted between the check and the read. validate_state_file
#   validates existence, non-emptiness, and minimum field count before any caller
#   reads the file — preventing spurious ERR-trap fires that would otherwise cause
#   deny-on-crash to block legitimate commands.
# Validate a pipe-delimited state file has expected format.
# Usage: validate_state_file "/path/to/file" field_count
# Returns 0 if valid, 1 if invalid/missing/corrupt.
validate_state_file() {
    local file="$1"
    local expected_fields="${2:-1}"
    [[ ! -f "$file" ]] && return 1
    [[ ! -s "$file" ]] && return 1
    local content
    content=$(head -1 "$file" 2>/dev/null) || return 1
    [[ -z "$content" ]] && return 1
    # Count pipe-delimited fields
    local actual_fields
    actual_fields=$(echo "$content" | awk -F'|' '{print NF}')
    [[ "$actual_fields" -ge "$expected_fields" ]] || return 1
    return 0
}

# --- Atomic file writer ---
# @decision DEC-INTEGRITY-004
# @title Atomic write via temp-file-then-mv for state file safety
# @status accepted
# @rationale Writing state files directly (echo > file) can produce truncated or
# empty files if the process is killed mid-write (e.g., SIGKILL, power loss).
# temp-file-then-mv is atomic on POSIX filesystems: the destination either has
# the old content or the new content, never a partial write. The .tmp.$$ suffix
# makes temp files unique per-process so concurrent writers don't collide.
#
# Usage: atomic_write "/path/to/file" "content"
# Or:    echo "content" | atomic_write "/path/to/file"
atomic_write() {
    local target="$1"
    local content="${2:-}"
    local tmp="${target}.tmp.$$"
    mkdir -p "$(dirname "$target")"
    if [[ -n "$content" ]]; then
        printf '%s\n' "$content" > "$tmp"
    else
        cat > "$tmp"
    fi
    mv "$tmp" "$target"
}

# --- Safe directory cleanup ---
# Prevents CWD-deletion bug: if the shell's CWD is inside the target,
# posix_spawn fails with ENOENT for all subsequent commands (including
# Stop hooks). Always cd out before deleting.
# Usage: safe_cleanup "/path/to/delete" "$PROJECT_ROOT"
safe_cleanup() {
    local target="$1"
    local fallback="${2:-$HOME}"
    if [[ "$PWD" == "$target"* ]]; then
        cd "$fallback" || cd "$HOME" || cd /
    fi
    rm -rf "$target"
}

# --- Audit trail ---
append_audit() {
    local root="$1" event="$2" detail="$3"
    local audit_file="$root/.claude/.audit-log"
    mkdir -p "$root/.claude"
    echo "$(date -u +%Y-%m-%dT%H:%M:%S)|${event}|${detail}" >> "$audit_file"
}

# --- Statusline cache writer ---
# @decision DEC-CACHE-001
# @title Statusline cache for status bar enrichment
# @status accepted
# @rationale Hooks already compute git/plan/test state. Cache it so statusline.sh
# can render rich status bar without re-computing or re-parsing. Atomic writes
# prevent race conditions. JSON format for extensibility.
write_statusline_cache() {
    local root="$1"
    local cache_file="$root/.claude/.statusline-cache"
    mkdir -p "$root/.claude"

    # Plan phase display
    local plan_display="no plan"
    if [[ "$PLAN_EXISTS" == "true" && "$PLAN_TOTAL_PHASES" -gt 0 ]]; then
        local current_phase=$((PLAN_COMPLETED_PHASES + PLAN_IN_PROGRESS_PHASES))
        [[ "$current_phase" -eq 0 ]] && current_phase=1
        plan_display="Phase ${current_phase}/${PLAN_TOTAL_PHASES}"
    fi

    # Test status
    local test_display="unknown"
    local ts_file="$root/.claude/.test-status"
    if [[ -f "$ts_file" ]]; then
        test_display=$(cut -d'|' -f1 "$ts_file")
    fi

    # Subagent status
    get_subagent_status "$root"

    # Atomic write
    local tmp_cache="${cache_file}.tmp.$$"
    jq -n \
        --arg dirty "${GIT_DIRTY_COUNT:-0}" \
        --arg wt "${GIT_WT_COUNT:-0}" \
        --arg plan "$plan_display" \
        --arg test "$test_display" \
        --arg ts "$(date +%s)" \
        --arg sa_count "${SUBAGENT_ACTIVE_COUNT:-0}" \
        --arg sa_types "${SUBAGENT_ACTIVE_TYPES:-}" \
        --arg sa_total "${SUBAGENT_TOTAL_COUNT:-0}" \
        '{dirty:($dirty|tonumber),worktrees:($wt|tonumber),plan:$plan,test:$test,updated:($ts|tonumber),agents_active:($sa_count|tonumber),agents_types:$sa_types,agents_total:($sa_total|tonumber)}' \
        > "$tmp_cache" && mv "$tmp_cache" "$cache_file"
}

# --- Subagent tracking ---
# @decision DEC-SUBAGENT-001
# @title Subagent lifecycle tracking via state file
# @status accepted
# @rationale SubagentStart/Stop hooks fire per-event but don't aggregate.
# A JSON state file tracks active agents, total count, and types so the
# status bar can display real-time agent activity. Token usage not available
# from hooks — tracked as backlog item cc-todos#37.
#
# @decision DEC-SUBAGENT-002
# @title Session-scoped subagent tracker files
# @status accepted
# @rationale Issue #73: A global .subagent-tracker file accumulates stale
# ACTIVE records if a session crashes without cleanup, causing phantom agent
# counts in the statusline. Scoping to .subagent-tracker-${CLAUDE_SESSION_ID:-$$}
# isolates each session's state. When the session ends normally, session-end.sh
# cleans up the file. If it crashes, the stale file is harmless because future
# sessions read their own scoped file. CLAUDE_SESSION_ID is used when set;
# $$ (current PID) is the fallback for environments without it.

track_subagent_start() {
    local root="$1" agent_type="$2"
    local tracker="$root/.claude/.subagent-tracker-${CLAUDE_SESSION_ID:-$$}"
    mkdir -p "$root/.claude"

    # Append start record (line-based for simplicity and atomicity)
    echo "ACTIVE|${agent_type}|$(date +%s)" >> "$tracker"
}

track_subagent_stop() {
    local root="$1" agent_type="$2"
    local tracker="$root/.claude/.subagent-tracker-${CLAUDE_SESSION_ID:-$$}"
    [[ ! -f "$tracker" ]] && return

    # Remove the OLDEST matching ACTIVE entry for this type (FIFO)
    # Use sed to delete first matching line only
    local tmp="${tracker}.tmp.$$"
    local found=false
    while IFS= read -r line; do
        if [[ "$found" == "false" && "$line" == "ACTIVE|${agent_type}|"* ]]; then
            # Convert to DONE record
            local start_epoch="${line##*|}"
            local now_epoch
            now_epoch=$(date +%s)
            local duration=$((now_epoch - start_epoch))
            echo "DONE|${agent_type}|${start_epoch}|${duration}" >> "$tmp"
            found=true
        else
            echo "$line" >> "$tmp"
        fi
    done < "$tracker"

    # If we didn't find a match (e.g., Bash/Explore agents that don't have SubagentStop matchers),
    # just keep the original
    if [[ "$found" == "true" ]]; then
        mv "$tmp" "$tracker"
    else
        rm -f "$tmp"
    fi
}

get_subagent_status() {
    local root="$1"
    local tracker="$root/.claude/.subagent-tracker-${CLAUDE_SESSION_ID:-$$}"

    SUBAGENT_ACTIVE_COUNT=0
    SUBAGENT_ACTIVE_TYPES=""
    SUBAGENT_TOTAL_COUNT=0

    [[ ! -f "$tracker" ]] && return

    # Count active agents
    SUBAGENT_ACTIVE_COUNT=$(grep -c '^ACTIVE|' "$tracker" 2>/dev/null || true)
    SUBAGENT_ACTIVE_COUNT=${SUBAGENT_ACTIVE_COUNT:-0}

    # Get unique active types
    SUBAGENT_ACTIVE_TYPES=$(grep '^ACTIVE|' "$tracker" 2>/dev/null | cut -d'|' -f2 | sort | uniq -c | sed 's/^ *//' | while read -r count type; do
        if [[ "$count" -gt 1 ]]; then
            echo "${type}x${count}"
        else
            echo "$type"
        fi
    done | paste -sd ',' - 2>/dev/null || echo "")

    # Total = active + done
    SUBAGENT_TOTAL_COUNT=$(wc -l < "$tracker" 2>/dev/null | tr -d ' ')
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

# --- Trace protocol ---
# Universal trace store for cross-project agent trajectory tracking.
# Each agent run gets a unique trace directory with manifest, summary, and artifacts.
# Traces survive session crashes, compactions, and context overflows.

TRACE_STORE="${TRACE_STORE:-$HOME/.claude/traces}"

# Initialize a trace directory for a new agent run.
# Usage: init_trace "/path/to/project" "implementer"
# Returns: trace_id (or empty on failure)
init_trace() {
    local project_root="$1"
    local agent_type="${2:-unknown}"
    local session_id="${CLAUDE_SESSION_ID:-$(date +%s)}"

    # Normalize agent_type for consistency
    # @decision DEC-OBS-018
    # @title Normalize agent_type in init_trace
    # @status accepted
    # @rationale The Task tool's subagent_type uses capitalized names like "Plan"
    #             and "Explore" but trace analysis expects lowercase names like
    #             "planner" and "explore". Normalizing at trace creation ensures
    #             consistent agent_type values across all traces.
    case "$agent_type" in
        Plan|plan)       agent_type="planner" ;;
        Explore|explore) agent_type="explore" ;;
        Bash|bash)       agent_type="bash" ;;
    esac

    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local hash
    hash=$(echo "${session_id}" | shasum -a 256 2>/dev/null | cut -c1-6)
    local trace_id="${agent_type}-${timestamp}-${hash}"
    local trace_dir="${TRACE_STORE}/${trace_id}"

    mkdir -p "${trace_dir}/artifacts" || return 1

    # Write initial manifest
    local project_name
    project_name=$(basename "$project_root")
    local branch
    # @decision DEC-OBS-019
    # @title Distinguish no-git from branch capture failures
    # @status accepted
    # @rationale 'unknown' conflates non-git projects with git failures.
    #             'no-git' for non-repos lets analysis filter them separately.
    if git -C "$project_root" rev-parse --git-dir > /dev/null 2>&1; then
        branch=$(git -C "$project_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    else
        branch="no-git"
    fi

    # Capture start_commit for retrospective analysis.
    # Paired with end_commit (captured in finalize_trace), brackets the agent's work.
    # @decision DEC-OBS-COMMIT-001
    # @title Robust start_commit capture with fallback and diagnostic logging
    # @status accepted
    # @rationale 6 traces missing start_commit because git rev-parse fails silently
    #   (e.g., empty repo, detached HEAD in some environments). Try git -C project_root
    #   first, then bare git rev-parse as fallback. Log a diagnostic when both fail
    #   so the cause is discoverable without breaking the trace. Issue #105.
    local start_commit=""
    if [[ "$branch" != "no-git" ]]; then
        start_commit=$(git -C "$project_root" rev-parse HEAD 2>/dev/null)
        if [[ -z "$start_commit" ]]; then
            # Fallback: bare git rev-parse (may succeed if CWD is inside the repo)
            start_commit=$(git rev-parse HEAD 2>/dev/null || echo "")
        fi
        if [[ -z "$start_commit" ]]; then
            echo "WARN: init_trace: could not capture start_commit for $project_root (git rev-parse failed)" >&2
        fi
    fi

    # Clean up stale .active-* markers older than 2 hours
    # @decision DEC-OBS-020
    # @title Age-based cleanup of orphaned .active-* markers
    # @status accepted
    # @rationale Agents that crash leave behind .active-* markers that can
    #             cause false "agent already running" blocks. Cleaning markers
    #             older than 2 hours on every init_trace() call is safe because
    #             no legitimate agent runs for more than 2 hours.
    local stale_threshold=7200  # 2 hours in seconds
    local now_epoch
    now_epoch=$(date +%s)
    for marker in "${TRACE_STORE}/.active-"*; do
        [[ -f "$marker" ]] || continue
        local marker_mtime
        marker_mtime=$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null || echo "0")
        if (( now_epoch - marker_mtime > stale_threshold )); then
            rm -f "$marker"
        fi
    done

    cat > "${trace_dir}/manifest.json" <<MANIFEST
{
  "version": "1",
  "trace_id": "${trace_id}",
  "agent_type": "${agent_type}",
  "session_id": "${session_id}",
  "project": "${project_root}",
  "project_name": "${project_name}",
  "branch": "${branch}",
  "start_commit": "${start_commit}",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "active"
}
MANIFEST

    # Active marker for detection — scoped to project hash to prevent cross-project contamination
    # @decision DEC-ISOLATION-002
    # @title Project-scoped active markers in init_trace
    # @status accepted
    # @rationale Without project scoping, a marker from Project A blocks or misleads
    #   detection logic in Project B sessions. The phash suffix isolates each project's
    #   markers. detect_active_trace() uses three-tier lookup: scoped first, old format
    #   with manifest validation, then ls -t fallback with manifest validation.
    local phash
    phash=$(project_hash "$project_root")
    echo "${trace_id}" > "${TRACE_STORE}/.active-${agent_type}-${session_id}-${phash}"

    echo "${trace_id}"
}

# Detect active trace for current session and agent type.
# Usage: detect_active_trace "/path/to/project" "implementer"
# Returns: trace_id (or empty if none active)
detect_active_trace() {
    # @decision DEC-OBS-OVERHAUL-002
    # @title Session-specific marker validation in detect_active_trace
    # @status accepted
    # @rationale The original ls -t glob fallback races when concurrent same-type
    #   agents run: ls -t picks the most recently modified marker, which may belong
    #   to a different session. The fix validates CLAUDE_SESSION_ID as the primary
    #   path. When the session-specific marker (named .active-TYPE-SESSION_ID) doesn't
    #   exist, we iterate all candidate markers and read the manifest session_id to
    #   find the one belonging to our session. Only when CLAUDE_SESSION_ID is
    #   unavailable do we fall back to ls -t (with a warning). Issue #101.
    #
    # @decision DEC-ISOLATION-003
    # @title Three-tier project-scoped lookup in detect_active_trace
    # @status accepted
    # @rationale Adding project hash to markers (DEC-ISOLATION-002) requires updating
    #   detection to find the new format first. Three tiers ensure backward compat:
    #   1. Scoped: .active-TYPE-SESSION-PHASH (new format, exact match for this project)
    #   2. Old format: .active-TYPE-SESSION — validate manifest.project == project_root
    #   3. ls -t fallback (no session ID) — validate manifest.project == project_root
    #   This prevents cross-project contamination while supporting pre-migration markers.
    local project_root="$1"
    local agent_type="${2:-unknown}"
    local session_id="${CLAUDE_SESSION_ID:-}"
    local phash
    phash=$(project_hash "$project_root")

    # Primary path: session-specific scoped marker (new format: .active-TYPE-SESSION-PHASH)
    if [[ -n "$session_id" ]]; then
        local scoped_marker="${TRACE_STORE}/.active-${agent_type}-${session_id}-${phash}"
        if [[ -f "$scoped_marker" ]]; then
            cat "$scoped_marker"
            return 0
        fi

        # Secondary path: old format marker .active-TYPE-SESSION (no phash)
        # Validate that the manifest project matches our project_root.
        local old_marker="${TRACE_STORE}/.active-${agent_type}-${session_id}"
        if [[ -f "$old_marker" ]]; then
            local old_trace_id
            old_trace_id=$(cat "$old_marker" 2>/dev/null)
            if [[ -n "$old_trace_id" ]]; then
                local old_manifest="${TRACE_STORE}/${old_trace_id}/manifest.json"
                if [[ -f "$old_manifest" ]]; then
                    local manifest_project
                    manifest_project=$(jq -r '.project // empty' "$old_manifest" 2>/dev/null)
                    if [[ "$manifest_project" == "$project_root" ]]; then
                        echo "$old_trace_id"
                        return 0
                    fi
                fi
            fi
        fi

        # Tertiary path: iterate all markers for this agent type.
        # Validate both session_id AND project from manifest.
        local candidate
        for candidate in "${TRACE_STORE}/.active-${agent_type}-"*; do
            [[ -f "$candidate" ]] || continue
            local candidate_trace_id
            candidate_trace_id=$(cat "$candidate" 2>/dev/null) || continue
            [[ -n "$candidate_trace_id" ]] || continue
            local candidate_manifest="${TRACE_STORE}/${candidate_trace_id}/manifest.json"
            [[ -f "$candidate_manifest" ]] || continue
            local manifest_session manifest_project
            manifest_session=$(jq -r '.session_id // empty' "$candidate_manifest" 2>/dev/null)
            manifest_project=$(jq -r '.project // empty' "$candidate_manifest" 2>/dev/null)
            if [[ "$manifest_session" == "$session_id" && "$manifest_project" == "$project_root" ]]; then
                echo "$candidate_trace_id"
                return 0
            fi
        done

        # No marker matched our session_id and project — return not found
        return 1
    fi

    # CLAUDE_SESSION_ID is unavailable: fall back to ls -t (most recent marker).
    # Validate manifest project to avoid cross-project contamination.
    # Log a warning so operators know the session-safe path was bypassed.
    echo "WARNING: detect_active_trace: CLAUDE_SESSION_ID not set — using ls -t fallback with project validation" >&2
    local mf_path
    for mf_path in $(ls -t "${TRACE_STORE}/.active-${agent_type}-"* 2>/dev/null); do
        [[ -f "$mf_path" ]] || continue
        local fallback_trace_id
        fallback_trace_id=$(cat "$mf_path" 2>/dev/null)
        [[ -n "$fallback_trace_id" ]] || continue
        local fallback_manifest="${TRACE_STORE}/${fallback_trace_id}/manifest.json"
        [[ -f "$fallback_manifest" ]] || continue
        local fb_project
        fb_project=$(jq -r '.project // empty' "$fallback_manifest" 2>/dev/null)
        if [[ "$fb_project" == "$project_root" ]]; then
            echo "$fallback_trace_id"
            return 0
        fi
    done

    return 1
}

# Finalize a trace after agent completion.
# Updates manifest with outcome, duration, test results. Indexes the trace.
# Usage: finalize_trace "trace_id" "/path/to/project" "implementer"
# finalize_trace() — Seal a trace manifest with metrics and clean up active markers.
#
# Observatory v2 design: reads test_result and files_changed from compliance.json
# written by check-*.sh hooks. No fallback chains. If compliance.json doesn't exist
# (legacy traces), values default to "not-provided"/0. Accept "not-provided" as valid.
#
# @decision DEC-OBS-V2-002
# @title finalize_trace reads compliance.json — no fallback chains
# @status accepted
# @rationale The old finalize_trace had ~150 lines of fallback logic (.test-status
#   chains, git diff fallback, verification-output.txt heuristics) to reconstruct
#   what agents should have recorded. Observatory v2 inverts this: check-*.sh hooks
#   record compliance.json at the agent boundary with authoritative source attribution.
#   finalize_trace reads compliance.json directly. If compliance.json doesn't exist
#   (legacy trace), defaults are "not-provided"/0 — NOT reconstructed. This eliminates
#   the broken feedback loop: observatory now detects missing compliance recording
#   rather than silently reconstructing it.
finalize_trace() {
    local trace_id="$1"
    local project_root="$2"
    local agent_type="${3:-unknown}"
    local trace_dir="${TRACE_STORE}/${trace_id}"
    local manifest="${trace_dir}/manifest.json"

    [[ ! -f "$manifest" ]] && return 1

    # Calculate duration
    local started_at
    started_at=$(jq -r '.started_at // empty' "$manifest" 2>/dev/null)
    local duration=0
    if [[ -n "$started_at" ]]; then
        local start_epoch
        start_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_at" +%s 2>/dev/null || date -u -d "$started_at" +%s 2>/dev/null || echo "0")
        local now_epoch
        # @decision DEC-OBS-DURATION-001
        # @title Use date -u +%s for now_epoch to match start_epoch UTC parsing
        # @status accepted
        # @rationale start_epoch is parsed with date -u (UTC). now_epoch uses plain
        #   date +%s which is epoch seconds (UTC) on most systems, but adding -u
        #   makes the intent explicit and prevents negative durations in environments
        #   where date +%s behavior differs from UTC. Issue #90.
        now_epoch=$(date -u +%s)
        if [[ "$start_epoch" -gt 0 ]]; then
            duration=$(( now_epoch - start_epoch ))
        fi
    fi

    # Read test_result and files_changed from compliance.json (Observatory v2).
    # compliance.json is written by check-*.sh hooks with authoritative source attribution.
    # If compliance.json doesn't exist (legacy trace), use defaults — do NOT reconstruct.
    local test_result="not-provided"
    local files_changed=0
    local compliance_file="${trace_dir}/compliance.json"

    if [[ -f "$compliance_file" ]]; then
        local compliance_test_result
        compliance_test_result=$(jq -r '.test_result // "not-provided"' "$compliance_file" 2>/dev/null)
        [[ -n "$compliance_test_result" ]] && test_result="$compliance_test_result"

        # Read files_changed from compliance artifacts if present
        if jq -e '.artifacts["files-changed.txt"].present == true' "$compliance_file" >/dev/null 2>&1; then
            if [[ -f "${trace_dir}/artifacts/files-changed.txt" ]]; then
                files_changed=$(wc -l < "${trace_dir}/artifacts/files-changed.txt" | tr -d ' ')
            fi
        fi
    fi

    # Check proof status from project
    # Prefer the local .claude/.proof-status; fall back to get_claude_dir() to
    # handle the ~/.claude meta-repo case (avoids double-nesting ~/.claude/.claude/).
    local proof_status="unknown"
    local proof_file="${project_root}/.claude/.proof-status"
    if [[ ! -f "$proof_file" ]]; then
        proof_file="$(get_claude_dir)/.proof-status"
    fi
    if [[ -f "$proof_file" ]]; then
        local ps
        ps=$(cut -d'|' -f1 "$proof_file")
        if [[ "$ps" == "verified" ]]; then
            proof_status="verified"
        elif [[ "$ps" == "pending" ]]; then
            proof_status="pending"
        fi
    fi

    # Determine overall outcome
    # @decision DEC-OBS-OUTCOME-001
    # @title Expand outcome classification with timeout and skipped states
    # @status accepted
    # @rationale The original three-outcome model (success/failure/partial) collapsed
    #   two distinct failure modes into "partial": (1) agents that ran long but produced
    #   nothing (timeout), and (2) traces with no artifacts at all (skipped/crashed before
    #   writing anything). Distinguishing these enables the observatory to surface
    #   actionable signals — timeout patterns indicate agent loops; skipped patterns
    #   indicate hook or dispatch failures. Order matters: timeout check uses duration
    #   which is already computed; skipped checks the artifacts dir existence.
    local outcome="unknown"
    if [[ "$test_result" == "pass" ]]; then
        outcome="success"
    elif [[ "$test_result" == "fail" ]]; then
        outcome="failure"
    elif [[ "$duration" -gt 600 && "$test_result" == "not-provided" ]]; then
        outcome="timeout"
    elif [[ ! -d "${trace_dir}/artifacts" ]]; then
        outcome="skipped"
    elif [[ -z "$(ls -A "${trace_dir}/artifacts" 2>/dev/null)" ]]; then
        outcome="skipped"
    else
        outcome="partial"
    fi

    # Check if summary exists; if not, it's likely a crash.
    # Do not override "skipped" — skipped means no artifacts at all (never started),
    # which is a distinct state from crashed (started but failed to produce summary.md).
    local trace_status="completed"
    if [[ ! -f "${trace_dir}/summary.md" ]]; then
        trace_status="crashed"
        if [[ "$outcome" != "skipped" ]]; then
            outcome="crashed"
        fi
    fi

    # Capture end_commit for retrospective analysis.
    # @decision DEC-OBS-COMMIT-002
    # @title Robust end_commit capture with fallback and diagnostic logging
    # @status accepted
    # @rationale 10 traces missing end_commit because git rev-parse fails silently when
    #   the worktree was already deleted before finalize_trace runs, or when the git dir
    #   check passes but HEAD is not readable. Try git -C project_root first, then bare
    #   git rev-parse as fallback. Log a diagnostic when both fail. Issue #105.
    local end_commit=""
    if [[ -n "$project_root" ]] && git -C "$project_root" rev-parse --git-dir >/dev/null 2>&1; then
        end_commit=$(git -C "$project_root" rev-parse HEAD 2>/dev/null)
        if [[ -z "$end_commit" ]]; then
            # Fallback: bare git rev-parse (may succeed if CWD is inside the repo)
            end_commit=$(git rev-parse HEAD 2>/dev/null || echo "")
        fi
        if [[ -z "$end_commit" ]]; then
            echo "WARN: finalize_trace: could not capture end_commit for $project_root (git rev-parse failed)" >&2
        fi
    fi

    # Update manifest with jq (merge new fields)
    # @decision DEC-OBS-OVERHAUL-003
    # @title jq error propagation in manifest writes
    # @status accepted
    # @rationale The previous code used `2>/dev/null` which silently swallowed jq
    #   parse errors. If the manifest was malformed (corrupt write, encoding issue),
    #   the update would silently fail with no indication. The fix captures jq stderr,
    #   checks the exit code, validates the tmp_manifest is non-empty before mv,
    #   and logs an explicit error to the audit trail so failures are discoverable.
    #   Issue #100.
    local tmp_manifest="${manifest}.tmp"
    local jq_err_file="${manifest}.jqerr"
    jq --arg finished_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --argjson duration "$duration" \
       --arg trace_status "$trace_status" \
       --arg outcome "$outcome" \
       --arg test_result "$test_result" \
       --arg proof_status "$proof_status" \
       --argjson files_changed "$files_changed" \
       --arg end_commit "$end_commit" \
       '. + {
         finished_at: $finished_at,
         duration_seconds: $duration,
         status: $trace_status,
         outcome: $outcome,
         test_result: $test_result,
         proof_status: $proof_status,
         files_changed: $files_changed,
         end_commit: $end_commit
       }' "$manifest" > "$tmp_manifest" 2>"$jq_err_file" || {
        local jq_err_msg
        jq_err_msg=$(cat "$jq_err_file" 2>/dev/null)
        echo "ERROR: finalize_trace: jq failed to update manifest for trace $trace_id: $jq_err_msg" >&2
        rm -f "$tmp_manifest" "$jq_err_file"
        return 1
    }
    rm -f "$jq_err_file"
    # Validate tmp_manifest is non-empty before replacing the real manifest
    if [[ ! -s "$tmp_manifest" ]]; then
        echo "ERROR: finalize_trace: jq produced empty manifest for trace $trace_id — not replacing" >&2
        rm -f "$tmp_manifest"
        return 1
    fi
    mv "$tmp_manifest" "$manifest"

    # Clean active marker — remove both scoped and unscoped variants for full cleanup
    # @decision DEC-ISOLATION-004
    # @title finalize_trace cleans both scoped and unscoped markers
    # @status accepted
    # @rationale Markers may exist in old format (no phash) from pre-migration sessions,
    #   or in new format (with phash). Cleaning both ensures no orphaned markers linger
    #   regardless of which format init_trace used. The wildcard loop catches any
    #   content-matched markers regardless of their name format.
    local session_id="${CLAUDE_SESSION_ID:-}"
    local phash
    phash=$(project_hash "$project_root")
    # Remove new scoped format
    rm -f "${TRACE_STORE}/.active-${agent_type}-${session_id}-${phash}" 2>/dev/null
    # Remove old unscoped format
    rm -f "${TRACE_STORE}/.active-${agent_type}-${session_id}" 2>/dev/null
    # Wildcard cleanup: any marker whose content matches this trace_id (any format)
    for marker in "${TRACE_STORE}/.active-${agent_type}-"*; do
        if [[ -f "$marker" ]]; then
            local marker_trace
            marker_trace=$(cat "$marker" 2>/dev/null)
            if [[ "$marker_trace" == "$trace_id" ]]; then
                rm -f "$marker"
            fi
        fi
    done

    # Index the trace
    index_trace "$trace_id"
}

# Append a compact JSON line to the trace index for querying.
# Usage: index_trace "trace_id"
index_trace() {
    local trace_id="$1"
    local manifest="${TRACE_STORE}/${trace_id}/manifest.json"

    [[ ! -f "$manifest" ]] && return 1

    # Extract fields for compact index entry
    local entry
    entry=$(jq -c '{
      trace_id: .trace_id,
      agent_type: .agent_type,
      project_name: .project_name,
      branch: .branch,
      started_at: .started_at,
      duration_seconds: (.duration_seconds // 0),
      outcome: (.outcome // "unknown"),
      test_result: (.test_result // "unknown"),
      files_changed: (.files_changed // 0)
    }' "$manifest" 2>/dev/null)

    if [[ -n "$entry" ]]; then
        echo "$entry" >> "${TRACE_STORE}/index.jsonl"
    fi
}


# refinalize_trace() and refinalize_stale_traces() were deleted in Observatory v2.
# Replaced by compliance.json recording in check-*.sh hooks. (DEC-OBS-V2-002)
# Deleted: 2026-02-21 (Observatory v2 Phase 1). Remove from call sites.

# Rebuild the trace index from scratch by reading every manifest.json.
# Writes a fresh index.jsonl sorted by started_at.
# Atomically replaces the existing index to avoid partial reads.
#
# @decision DEC-REFINALIZE-003
# @title Atomic tmp-then-mv index rebuild with started_at sort
# @status accepted
# @rationale The index may be read by analyze.sh at any moment. A non-atomic
#   write (truncate then write) would expose a partial file to concurrent readers.
#   Writing to index.jsonl.tmp then mv-ing is atomic on POSIX filesystems.
#   Sorting by started_at gives chronological order, matching how index_trace()
#   appends (oldest traces were appended first). Sorting makes the rebuilt index
#   match the append-order semantics that suggest.sh and analyze.sh expect.
#
# Usage: rebuild_index
# Returns: 0 always
rebuild_index() {
    local tmp_index="${TRACE_STORE}/index.jsonl.tmp"
    local entries=()

    for manifest in "${TRACE_STORE}"/*/manifest.json; do
        [[ ! -f "$manifest" ]] && continue

        local entry
        entry=$(jq -c '{
          trace_id: (.trace_id // "unknown"),
          agent_type: (.agent_type // "unknown"),
          project_name: (.project_name // "unknown"),
          branch: (.branch // "unknown"),
          started_at: (.started_at // ""),
          duration_seconds: (.duration_seconds // 0),
          outcome: (.outcome // "unknown"),
          test_result: (.test_result // "unknown"),
          files_changed: (.files_changed // 0)
        }' "$manifest" 2>/dev/null)

        [[ -n "$entry" ]] && entries+=("$entry")
    done

    # Write sorted entries (by started_at) to tmp, then atomic mv
    if [[ "${#entries[@]}" -gt 0 ]]; then
        printf '%s\n' "${entries[@]}" \
            | jq -s 'sort_by(.started_at) | .[]' \
            | jq -c . \
            > "$tmp_index" 2>/dev/null
    else
        : > "$tmp_index"
    fi

    mv "$tmp_index" "${TRACE_STORE}/index.jsonl"
    return 0
}

# --- Meta-repo detection ---
# Check if a directory is the ~/.claude meta-infrastructure repo.
# Uses --git-common-dir so worktrees of ~/.claude are correctly recognized.
# Usage: is_claude_meta_repo "/path/to/dir"
# Returns: 0 if meta-repo, 1 otherwise
is_claude_meta_repo() {
    local dir="$1"
    local common_dir
    common_dir=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null || echo "")
    # Resolve to absolute if relative
    if [[ -n "$common_dir" && "$common_dir" != /* ]]; then
        common_dir=$(cd "$dir" && cd "$common_dir" && pwd)
    fi
    # common_dir for ~/.claude is ~/.claude/.git (strip trailing /.git)
    [[ "${common_dir%/.git}" == */.claude ]]
}

# --- Session event log ---
# Append-only JSONL event log for session observability.
# @decision DEC-V2-001
# @title Session events as JSONL append-only log
# @status accepted
# @rationale JSONL is atomic (one write per line), grep-friendly, doesn't require
# parsing entire file to append.

append_session_event() {
    local event_type="$1"
    local detail_json="${2:-"{}"}"
    local project_root="${3:-}"

    # Auto-detect project root if not provided
    if [[ -z "$project_root" ]]; then
        project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
    fi

    local event_file="$project_root/.claude/.session-events.jsonl"
    mkdir -p "$(dirname "$event_file")"

    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Build event JSON: merge timestamp and event type into detail
    local event_line
    event_line=$(jq -c --arg ts "$ts" --arg evt "$event_type" '. + {ts: $ts, event: $evt}' <<< "$detail_json" 2>/dev/null)

    # Fallback if jq fails (detail_json was malformed)
    if [[ -z "$event_line" ]]; then
        event_line="{\"ts\":\"$ts\",\"event\":\"$event_type\"}"
    fi

    # Atomic append via temp file
    local tmp
    tmp=$(mktemp "${event_file}.XXXXXX")
    echo "$event_line" > "$tmp"
    cat "$tmp" >> "$event_file"
    rm -f "$tmp"
}

# --- Approach pivot detection ---
# @decision DEC-V2-PIVOT-001
# @title detect_approach_pivots reads JSONL event log for edit->fail loops
# @status accepted
# @rationale The edit->test_fail->edit->test_fail cycle on the same file indicates
# the agent is stuck. By detecting this pattern in the session event log we can
# provide precise, actionable guidance: which file is looping, which assertion
# keeps failing, and how many times the cycle has repeated. This converts a generic
# "tests failing" message into "you have edited compute.py 4 times and test_compute
# keeps failing — read the test to understand what it expects."
# Implementation uses awk for bash 3.2 compatibility (macOS ships bash 3.2;
# associative arrays require bash 4+).
# Variables set: PIVOT_COUNT (int), PIVOT_FILES (space-sep list), PIVOT_ASSERTIONS (comma-sep list)
detect_approach_pivots() {
    local project_root="${1:-$(detect_project_root)}"
    local claude_dir="${project_root}/.claude"
    local events_file="${claude_dir}/.session-events.jsonl"

    PIVOT_COUNT=0
    PIVOT_FILES=""
    PIVOT_ASSERTIONS=""

    [[ ! -f "$events_file" ]] && return 0

    # Extract writes and test_fail events with ordering preserved.
    # Output format per line:  WRITE:<file>  or  FAIL:<assertion>
    local event_sequence
    event_sequence=$(jq -r '
        if .event == "write" and .file != null then
            "WRITE:" + .file
        elif .event == "test_run" and .result == "fail" then
            "FAIL:" + (.assertion // "unknown")
        else
            empty
        end
    ' "$events_file" 2>/dev/null) || return 0

    [[ -z "$event_sequence" ]] && return 0

    # Use awk to detect pivot pattern (bash 3.2 safe — no associative arrays).
    # A pivot is defined as: a file that was written, then a test_fail occurred,
    # then the same file was written again. awk tracks this per-file.
    # Output format: one line per pivoting file: "<file>|<assertion1>,<assertion2>"
    local pivot_lines
    pivot_lines=$(echo "$event_sequence" | awk '
        BEGIN { saw_fail = 0; last_assertion = ""; }
        /^WRITE:/ {
            fname = substr($0, 7)
            write_count[fname]++
            if (saw_fail) {
                post_fail_writes[fname]++
                if (last_assertion != "" && last_assertion != "unknown") {
                    # Append assertion for this file (space-separated, dedup later)
                    if (file_assertions[fname] == "") {
                        file_assertions[fname] = last_assertion
                    } else if (index(file_assertions[fname], last_assertion) == 0) {
                        file_assertions[fname] = file_assertions[fname] "," last_assertion
                    }
                }
            }
        }
        /^FAIL:/ {
            saw_fail = 1
            last_assertion = substr($0, 6)
        }
        END {
            for (fname in post_fail_writes) {
                if (post_fail_writes[fname] >= 1 && write_count[fname] >= 2) {
                    print fname "|" file_assertions[fname]
                }
            }
        }
    ' 2>/dev/null) || return 0

    [[ -z "$pivot_lines" ]] && return 0

    # Parse awk output into shell variables
    local pivot_count=0
    local pivot_files_list=""
    local pivot_assertions_list=""

    while IFS='|' read -r fname assertions; do
        [[ -z "$fname" ]] && continue
        pivot_count=$(( pivot_count + 1 ))
        pivot_files_list="${pivot_files_list:+$pivot_files_list }$fname"
        pivot_assertions_list="${pivot_assertions_list:+$pivot_assertions_list,}${assertions:-}"
    done <<< "$pivot_lines"

    PIVOT_COUNT="$pivot_count"
    PIVOT_FILES="$pivot_files_list"
    PIVOT_ASSERTIONS="$pivot_assertions_list"

    return 0
}
export -f detect_approach_pivots

get_session_trajectory() {
    local project_root="${1:-}"
    if [[ -z "$project_root" ]]; then
        project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
    fi

    local event_file="$project_root/.claude/.session-events.jsonl"

    # Initialize trajectory variables
    TRAJ_TOOL_CALLS=0
    TRAJ_FILES_MODIFIED=0
    TRAJ_GATE_BLOCKS=0
    TRAJ_AGENTS=""
    TRAJ_ELAPSED_MIN=0
    TRAJ_PIVOTS=0
    TRAJ_TEST_FAILURES=0
    TRAJ_CHECKPOINTS=0
    TRAJ_REWINDS=0

    [[ ! -f "$event_file" ]] && return

    # Count events by type using grep (fast, no jq needed for aggregates)
    # grep -c exits 1 when count is 0, so use subshell to capture output and default
    TRAJ_TOOL_CALLS=$(grep -c '"event":"write"' "$event_file" 2>/dev/null) || true
    TRAJ_TOOL_CALLS=${TRAJ_TOOL_CALLS:-0}
    TRAJ_FILES_MODIFIED=$(grep '"event":"write"' "$event_file" 2>/dev/null | jq -r '.file // empty' 2>/dev/null | sort -u | wc -l | tr -d ' ')
    TRAJ_GATE_BLOCKS=$(grep '"result":"block"' "$event_file" 2>/dev/null | wc -l | tr -d ' ')
    TRAJ_TEST_FAILURES=$(grep '"event":"test_run"' "$event_file" 2>/dev/null | grep '"result":"fail"' | wc -l | tr -d ' ')
    TRAJ_CHECKPOINTS=$(grep -c '"event":"checkpoint"' "$event_file" 2>/dev/null) || true
    TRAJ_CHECKPOINTS=${TRAJ_CHECKPOINTS:-0}
    TRAJ_REWINDS=$(grep -c '"event":"rewind"' "$event_file" 2>/dev/null) || true
    TRAJ_REWINDS=${TRAJ_REWINDS:-0}

    # Extract unique agent types
    TRAJ_AGENTS=$(grep '"event":"agent_start"' "$event_file" 2>/dev/null | jq -r '.type // empty' 2>/dev/null | sort -u | paste -sd ',' - 2>/dev/null || echo "")

    # Calculate elapsed time from first to last event
    local first_ts last_ts
    first_ts=$(head -1 "$event_file" 2>/dev/null | jq -r '.ts // empty' 2>/dev/null)
    last_ts=$(tail -1 "$event_file" 2>/dev/null | jq -r '.ts // empty' 2>/dev/null)
    if [[ -n "$first_ts" && -n "$last_ts" ]]; then
        local first_epoch last_epoch
        first_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$first_ts" +%s 2>/dev/null || date -d "$first_ts" +%s 2>/dev/null || echo "0")
        last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_ts" +%s 2>/dev/null || date -d "$last_ts" +%s 2>/dev/null || echo "0")
        if [[ "$first_epoch" -gt 0 && "$last_epoch" -gt 0 ]]; then
            TRAJ_ELAPSED_MIN=$(( (last_epoch - first_epoch) / 60 ))
        fi
    fi

    # Detect pivots: same file edited multiple times with intervening test failures
    # (Simplified: count files edited more than twice with test failures between edits)
    TRAJ_PIVOTS=0
    if [[ "$TRAJ_TEST_FAILURES" -gt 0 ]]; then
        local repeated_files
        repeated_files=$(grep '"event":"write"' "$event_file" 2>/dev/null | jq -r '.file // empty' 2>/dev/null | sort | uniq -c | sort -rn | awk '$1 > 2 {print $2}' | head -5)
        if [[ -n "$repeated_files" ]]; then
            TRAJ_PIVOTS=$(echo "$repeated_files" | wc -l | tr -d ' ')
        fi
    fi
}

# @decision DEC-V2-005
# @title Session context in commits as structured text
# @status accepted
# @rationale Structured Key: Value format is scannable in git log, parseable by tools,
# and consistent with conventional commit trailers. A single-line prose summary was
# insufficient — structured output lets Guardian selectively include stats, friction,
# and agent trajectory context in commit messages without manual formatting effort.
# Trivial sessions (<3 events) return empty to avoid noise in minor commits.
get_session_summary_context() {
    local project_root="${1:-}"
    if [[ -z "$project_root" ]]; then
        project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
    fi

    get_session_trajectory "$project_root"

    local event_file="$project_root/.claude/.session-events.jsonl"
    [[ ! -f "$event_file" ]] && return

    # Count total events for triviality check
    local total_events
    total_events=$(wc -l < "$event_file" 2>/dev/null | tr -d ' ')
    total_events=${total_events:-0}

    # Trivial sessions (<3 events) produce no context — avoid noise in minor commits
    [[ "$total_events" -lt 3 ]] && return

    # Build structured output block
    local stats_line="${TRAJ_TOOL_CALLS} tool calls | ${TRAJ_FILES_MODIFIED} files | ${TRAJ_CHECKPOINTS} checkpoints | ${TRAJ_PIVOTS} pivots | ${TRAJ_ELAPSED_MIN} minutes"

    printf '%s\n' '--- Session Context ---'
    printf 'Stats: %s\n' "$stats_line"

    if [[ -n "$TRAJ_AGENTS" ]]; then
        printf 'Agents: %s\n' "$TRAJ_AGENTS"
    fi

    if [[ "$TRAJ_TEST_FAILURES" -gt 0 ]]; then
        # Extract most-failed assertion for friction context
        local top_assertion
        top_assertion=$(grep '"event":"test_run"' "$event_file" 2>/dev/null | grep '"result":"fail"' | jq -r '.assertion // empty' 2>/dev/null | sort | uniq -c | sort -rn | head -1 | sed 's/^[[:space:]]*[0-9]* //')
        if [[ -n "$top_assertion" ]]; then
            printf 'Friction: %d test failure(s) — most common: %s\n' "$TRAJ_TEST_FAILURES" "$top_assertion"
        else
            printf 'Friction: %d test failure(s)\n' "$TRAJ_TEST_FAILURES"
        fi
    fi

    if [[ "$TRAJ_GATE_BLOCKS" -gt 0 ]]; then
        printf 'Friction: %d gate block(s) — agent corrected course\n' "$TRAJ_GATE_BLOCKS"
    fi

    if [[ "$TRAJ_PIVOTS" -gt 0 ]]; then
        # Extract pivot details: files edited most often
        local pivot_files
        pivot_files=$(grep '"event":"write"' "$event_file" 2>/dev/null | jq -r '.file // empty' 2>/dev/null | sort | uniq -c | sort -rn | awk '$1 > 2 {print $2}' | head -3 | paste -sd ', ' - 2>/dev/null || echo "")
        if [[ -n "$pivot_files" ]]; then
            printf 'Approach: %d pivot(s) detected on: %s\n' "$TRAJ_PIVOTS" "$pivot_files"
        else
            printf 'Approach: %d pivot(s) detected\n' "$TRAJ_PIVOTS"
        fi
    fi

    if [[ "$TRAJ_REWINDS" -gt 0 ]]; then
        printf 'Rewinds: %d checkpoint rewind(s)\n' "$TRAJ_REWINDS"
    fi
}

# --- Cross-session learning ---
# @decision DEC-V2-PHASE4-001
# @title get_prior_sessions reads session index for cross-session context injection
# @status accepted
# @rationale New sessions start cold with no memory of prior work on the same project.
# The session index (index.jsonl) captures outcome, files touched, and friction per
# session. Injecting the last 3 summaries + recurring friction patterns into session-
# init gives Claude immediate context on what was done, what failed repeatedly, and
# what the current state of the project is. Threshold of 3 sessions avoids noisy
# context for brand-new projects. Returns empty string when insufficient data exists
# so callers can safely skip injection.
get_prior_sessions() {
    local project_root="${1:-}"
    if [[ -z "$project_root" ]]; then
        project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
    fi

    local project_hash
    project_hash=$(echo "$project_root" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "")
    [[ -z "$project_hash" ]] && return 0

    local index_file="$HOME/.claude/sessions/${project_hash}/index.jsonl"
    [[ ! -f "$index_file" ]] && return 0

    # Count valid JSON lines
    local session_count
    session_count=$(grep -c '.' "$index_file" 2>/dev/null || true)
    session_count=${session_count:-0}

    # Require at least 3 sessions to avoid noise on new projects
    [[ "$session_count" -lt 3 ]] && return 0

    # Build output: last 3 session summaries
    local output=""
    output+="Prior sessions on this project ($session_count total):"$'\n'

    # Read last 3 entries (tail -3 for most recent)
    local last3
    last3=$(tail -3 "$index_file" 2>/dev/null || echo "")
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local id started duration outcome files_count
        id=$(echo "$entry" | jq -r '.id // "unknown"' 2>/dev/null)
        started=$(echo "$entry" | jq -r '.started // ""' 2>/dev/null | cut -c1-10)
        duration=$(echo "$entry" | jq -r '.duration_min // 0' 2>/dev/null)
        outcome=$(echo "$entry" | jq -r '.outcome // "unknown"' 2>/dev/null)
        files_count=$(echo "$entry" | jq -r '(.files_touched // []) | length' 2>/dev/null)
        output+="  - ${started} | ${duration}min | ${outcome} | ${files_count} files"$'\n'
    done <<< "$last3"

    # Detect recurring friction: strings appearing in 2+ sessions
    local all_friction
    all_friction=$(jq -r '.friction[]? // empty' "$index_file" 2>/dev/null | sort | uniq -c | sort -rn | awk '$1 >= 2 {$1=""; print $0}' | sed 's/^ //' || echo "")

    if [[ -n "$all_friction" ]]; then
        output+="Recurring friction:"$'\n'
        while IFS= read -r friction_item; do
            [[ -z "$friction_item" ]] && continue
            output+="  - ${friction_item}"$'\n'
        done <<< "$all_friction"
    fi

    printf '%s' "$output"
}

# --- Resume directive builder ---
# @decision DEC-RESUME-001
# @title Compute actionable resume directive from session state in bash
# @status accepted
# @rationale After context compaction, the model loses track of what it was doing.
# Computing the directive in bash (not relying on the model to remember) is the only
# reliable way to survive compaction. Priority ladder: active agents > proof status >
# test failures > git branch state > plan fallback. Sets RESUME_DIRECTIVE and
# RESUME_FILES globals.
build_resume_directive() {
    local project_root="${1:-}"
    if [[ -z "$project_root" ]]; then
        project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
    fi

    RESUME_DIRECTIVE=""
    RESUME_FILES=""

    # Use the same double-nesting guard as get_claude_dir():
    # when project_root IS ~/.claude, don't append /.claude again.
    local home_claude="${HOME}/.claude"
    local claude_dir
    if [[ "$project_root" == "$home_claude" ]]; then
        claude_dir="$project_root"
    else
        claude_dir="$project_root/.claude"
    fi

    # --- Priority 1: Active agent in progress ---
    # Use session-scoped tracker per DEC-SUBAGENT-002 (not the old global path)
    local tracker="$claude_dir/.subagent-tracker-${CLAUDE_SESSION_ID:-$$}"
    if [[ -f "$tracker" ]]; then
        local active_count
        active_count=$(grep -c '^ACTIVE|' "$tracker" 2>/dev/null) || active_count=0
        if [[ "$active_count" -gt 0 ]]; then
            local active_type
            active_type=$(grep '^ACTIVE|' "$tracker" | head -1 | cut -d'|' -f2)
            local trace_path=""
            # Find the most recent active trace for this agent type
            for marker in "${TRACE_STORE:-$HOME/.claude/traces}"/.active-"${active_type}"-*; do
                [[ -f "$marker" ]] || continue
                trace_path="$HOME/.claude/traces/$(cat "$marker" 2>/dev/null)"
                break
            done
            local directive_body="An ${active_type} agent was in progress. Resume or re-dispatch."
            [[ -n "$trace_path" ]] && directive_body="$directive_body Trace: $trace_path"
            RESUME_DIRECTIVE="$directive_body"
        fi
    fi

    # --- Priority 2: Proof status signals ---
    local proof_file="$claude_dir/.proof-status"
    if [[ -z "$RESUME_DIRECTIVE" && -f "$proof_file" ]]; then
        local proof_status
        proof_status=$(cut -d'|' -f1 "$proof_file" 2>/dev/null || echo "")
        if [[ "$proof_status" == "needs-verification" ]]; then
            RESUME_DIRECTIVE="Implementation complete but unverified. Dispatch tester."
        elif [[ "$proof_status" == "verified" ]]; then
            # Verified + dirty = ready for Guardian
            get_git_state "$project_root"
            if [[ "${GIT_DIRTY_COUNT:-0}" -gt 0 ]]; then
                RESUME_DIRECTIVE="Verified implementation ready. Dispatch Guardian to commit."
            fi
        fi
    fi

    # --- Priority 3: Tests failing ---
    if [[ -z "$RESUME_DIRECTIVE" ]]; then
        if read_test_status "$project_root"; then
            if [[ "${TEST_RESULT:-}" == "fail" ]]; then
                RESUME_DIRECTIVE="Tests failing (${TEST_FAILS:-?} failures). Fix tests before proceeding."
            fi
        fi
    fi

    # --- Priority 4: On feature branch with dirty files ---
    if [[ -z "$RESUME_DIRECTIVE" ]]; then
        get_git_state "$project_root"
        if [[ -n "${GIT_BRANCH:-}" && "$GIT_BRANCH" != "main" && "$GIT_BRANCH" != "master" && "${GIT_DIRTY_COUNT:-0}" -gt 0 ]]; then
            RESUME_DIRECTIVE="Implementation in progress on ${GIT_BRANCH}. Continue editing."
        fi
    fi

    # --- Priority 5: On main with worktrees ---
    if [[ -z "$RESUME_DIRECTIVE" ]]; then
        get_git_state "$project_root"
        if [[ ("${GIT_BRANCH:-}" == "main" || "${GIT_BRANCH:-}" == "master") && "${GIT_WT_COUNT:-0}" -gt 0 ]]; then
            RESUME_DIRECTIVE="Work in worktrees. Check active worktree branches."
        fi
    fi

    # --- Fallback: Plan status ---
    if [[ -z "$RESUME_DIRECTIVE" ]]; then
        get_plan_status "$project_root"
        if [[ "$PLAN_EXISTS" == "true" && "$PLAN_LIFECYCLE" == "active" ]]; then
            local phase_num=$(( PLAN_COMPLETED_PHASES + PLAN_IN_PROGRESS_PHASES ))
            [[ "$phase_num" -eq 0 ]] && phase_num=1
            RESUME_DIRECTIVE="Working on Phase ${phase_num}/${PLAN_TOTAL_PHASES}. Check plan for next steps."
        fi
    fi

    # --- Compute top modified files ---
    if [[ -n "$RESUME_DIRECTIVE" ]]; then
        get_session_trajectory "$project_root"
        local event_file="$project_root/.claude/.session-events.jsonl"
        if [[ -f "$event_file" ]]; then
            RESUME_FILES=$(grep '"event":"write"' "$event_file" 2>/dev/null \
                | jq -r '.file // empty' 2>/dev/null \
                | while IFS= read -r f; do echo "$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null || echo 0) $f"; done \
                | sort -rn \
                | head -3 \
                | awk '{print $2}' \
                | xargs -I{} basename {} 2>/dev/null \
                | paste -sd', ' - 2>/dev/null || echo "")
        fi

        # Get trajectory one-liner for the session field
        local traj_oneliner
        traj_oneliner=$(get_session_summary_context "$project_root" 2>/dev/null || echo "")

        # Format the multi-line directive block
        local formatted="RESUME DIRECTIVE: ${RESUME_DIRECTIVE}"
        [[ -n "$RESUME_FILES" ]] && formatted="${formatted}
  Active work: ${RESUME_FILES}"
        [[ -n "$traj_oneliner" ]] && formatted="${formatted}
  Session: ${traj_oneliner}"
        formatted="${formatted}
  Next action: ${RESUME_DIRECTIVE}"

        RESUME_DIRECTIVE="$formatted"
    fi
}

# --- Trace manifest backup ---
#
# @decision DEC-TRACE-PROT-002
# @title Periodic compressed backup of trace manifests
# @status accepted
# @rationale Trace directories can be deleted by `git worktree prune`, disk
#   cleanup scripts, or accidental rm -rf. Manifests are the most compact
#   representation of trace metadata (name, outcome, timestamps) and are what
#   rebuild_index() needs to reconstruct the index. Backing them up at session
#   end ensures that even after trace loss, the index can be rebuilt from the
#   backup. Archives are stored inside TRACE_STORE (which is already gitignored)
#   so they never get committed. Rotation to 3 keeps disk usage bounded at ~3x
#   manifest size (well under 1 MB for 500 traces).
backup_trace_manifests() {
    local store="${TRACE_STORE:-$HOME/.claude/traces}"
    [[ ! -d "$store" ]] && return 0

    # Collect all manifest paths relative to store root
    local rel_paths=()
    while IFS= read -r m; do
        [[ -f "$m" ]] && rel_paths+=("${m#"${store}/"}")
    done < <(find "$store" -maxdepth 2 -name 'manifest.json' -type f 2>/dev/null | sort)

    [[ "${#rel_paths[@]}" -eq 0 ]] && return 0

    # Create archive named by date+timestamp
    local archive="${store}/.manifest-backup-$(date +%Y-%m-%dT%H%M%S).tar.gz"

    # tar from store root with relative paths
    tar -czf "$archive" -C "$store" "${rel_paths[@]}" 2>/dev/null || {
        rm -f "$archive" 2>/dev/null || true
        return 0
    }

    # Rotate: keep only the 3 newest backups.
    # Use while-read instead of mapfile — mapfile requires bash 4+ and macOS
    # ships bash 3.2 as the system shell. ls -t sorts newest-first; we skip
    # the first 3 (keepers) and delete the rest.
    local _backup_count=0
    while IFS= read -r _old_backup; do
        _backup_count=$(( _backup_count + 1 ))
        if [[ "$_backup_count" -gt 3 ]]; then
            rm -f "$_old_backup" 2>/dev/null || true
        fi
    done < <(ls -t "$store"/.manifest-backup-*.tar.gz 2>/dev/null)
}

# --- Trace count canary ---
#
# @decision DEC-TRACE-PROT-003
# @title Session-start trace count canary for data loss detection
# @status accepted
# @rationale Recording the trace count at session end and comparing at next
#   session start provides an early warning when traces are deleted between
#   sessions. A >30% drop is statistically unlikely from normal operation
#   (agents complete 1-5 traces per session) but characteristic of a rm -rf
#   or disk failure. The canary file is stored in TRACE_STORE (gitignored) and
#   uses a simple count|epoch format for fast I/O. Returns warning string
#   (non-empty) when a significant drop is detected; empty string otherwise.
check_trace_count_canary() {
    local store="${TRACE_STORE:-$HOME/.claude/traces}"
    local canary_file="${store}/.trace-count-canary"

    # Count current trace directories (exclude hidden dirs/files)
    local current_count
    current_count=$(find "$store" -maxdepth 1 -mindepth 1 -type d ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
    current_count="${current_count:-0}"

    if [[ -f "$canary_file" ]]; then
        local prev_count prev_epoch
        IFS='|' read -r prev_count prev_epoch < "$canary_file" 2>/dev/null || true
        prev_count="${prev_count:-0}"

        # Only warn if previous count was meaningful and drop exceeds 30%
        if [[ "$prev_count" -gt 0 && "$current_count" -lt "$prev_count" ]]; then
            local drop_pct=$(( (prev_count - current_count) * 100 / prev_count ))
            if [[ "$drop_pct" -gt 30 ]]; then
                echo "WARNING: Trace count dropped from ${prev_count} to ${current_count} since last session (${drop_pct}% drop). Possible data loss."
            fi
        fi
    fi
    # Always update canary with current count
    echo "${current_count}|$(date +%s)" > "$canary_file" 2>/dev/null || true
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

# Export for subshells
export TRACE_STORE SOURCE_EXTENSIONS DECISION_LINE_THRESHOLD TEST_STALENESS_THRESHOLD SESSION_STALENESS_THRESHOLD
export -f get_git_state get_plan_status get_doc_freshness get_session_changes get_drift_data get_research_status is_source_file is_skippable_path is_test_file read_test_status validate_state_file atomic_write append_audit write_statusline_cache track_subagent_start track_subagent_stop get_subagent_status safe_cleanup archive_plan compress_initiative init_trace detect_active_trace finalize_trace index_trace rebuild_index is_claude_meta_repo append_session_event get_session_trajectory get_session_summary_context build_resume_directive get_prior_sessions backup_trace_manifests check_trace_count_canary
