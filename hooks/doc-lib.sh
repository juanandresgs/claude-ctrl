#!/usr/bin/env bash
# doc-lib.sh — Documentation freshness detection for Claude Code hooks.
#
# Loaded on demand via: require_doc (defined in source-lib.sh)
# Depends on: core-lib.sh (must be loaded first)
#
# @decision DEC-SPLIT-001 (see core-lib.sh for full rationale)
#
# Provides:
#   get_doc_freshness - Populate DOC_STALE_COUNT, DOC_STALE_WARN, DOC_STALE_DENY,
#                       DOC_MOD_ADVISORY, DOC_FRESHNESS_SUMMARY

# Guard against double-sourcing
[[ -n "${_DOC_LIB_LOADED:-}" ]] && return 0

_DOC_LIB_VERSION=1

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
    _doc_mod_hash=$(echo "$_doc_keys" | ${_SHA256_CMD:-shasum -a 256} 2>/dev/null | cut -c1-8 || echo "x")

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

export -f get_doc_freshness

_DOC_LIB_LOADED=1
