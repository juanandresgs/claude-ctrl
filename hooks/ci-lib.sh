#!/usr/bin/env bash
# ci-lib.sh — CI status domain library for Claude Code hooks.
#
# Loaded on demand via: require_ci (defined in source-lib.sh)
# Depends on: core-lib.sh (must be loaded first via source-lib.sh chain)
#
# @decision DEC-CI-002
# @title Convention-based local CI discovery priority
# @status accepted
# @rationale Local CI scripts follow an ordered discovery priority to support
#   diverse project setups without requiring configuration: (1) .githooks/pre-push
#   is the canonical Git hook location (set via core.hooksPath); (2) .claude/pre-push.sh
#   is the Claude-specific convention for projects that don't use githooks; (3)
#   Makefile ci-local target is the generic task-runner convention. This ordering
#   ensures the most-specific and most-standard path wins, falling back to more
#   generic conventions. If none found, the gate silently passes rather than
#   blocking all pushes for projects without local CI.
#
# @decision DEC-CI-003
# @title Background CI watcher with lock file and exponential backoff
# @status accepted
# @rationale Polling GitHub Actions from within a hook is too slow (gh run list
#   can take 2-5s). A background watcher (ci-watch.sh) polls asynchronously and
#   writes results to a state file. Hooks read the state file (fast path).
#   Lock file prevents concurrent watchers; exponential backoff (30s→60s→120s→300s)
#   reduces API calls without sacrificing responsiveness on fast pipelines.
#   30-minute total timeout prevents orphaned watchers.
#
# @decision DEC-CI-004
# @title Three-tier CI awareness (state-file → live query → skip)
# @status accepted
# @rationale session-init.sh uses a two-tier system: (1) read watcher state file
#   for near-real-time status without network calls, (2) fall back to gh run list
#   only when state file is missing or stale. This ensures session startup stays
#   fast (<250ms) while still surfacing actionable CI failures. The stale threshold
#   is 1hr for success, 30min for pending — shorter for pending to re-check sooner.
#
# State file format (9 pipe-delimited fields):
#   status|run_id|conclusion|branch|workflow|started_at|updated_at|url|write_timestamp
#   status values: pending, success, failure, error
#
# Provides:
#   find_local_ci      - Find local CI script by convention-based priority
#   has_github_actions - Check if gh CLI + .github/workflows/ exist (no network)
#   ci_status_file     - Return path to project-scoped CI status file
#   write_ci_status    - Atomically write CI status to state file
#   read_ci_status     - Read state file into CI_* globals
#   format_ci_summary  - Format CI_* globals as single-line human summary

# Guard against double-sourcing
[[ -n "${_CI_LIB_LOADED:-}" ]] && return 0

_CI_LIB_VERSION=1

# --- Local CI discovery ---
# find_local_ci — Return path to local CI script or empty string.
# Priority: .githooks/pre-push > .claude/pre-push.sh > Makefile ci-local target
# Usage: ci_script=$(find_local_ci "$PROJECT_ROOT")
find_local_ci() {
    local root="${1:-.}"

    # Priority 1: .githooks/pre-push (canonical Git hook location)
    if [[ -f "$root/.githooks/pre-push" && -x "$root/.githooks/pre-push" ]]; then
        echo "$root/.githooks/pre-push"
        return 0
    fi

    # Priority 2: .claude/pre-push.sh (Claude-specific convention)
    if [[ -f "$root/.claude/pre-push.sh" && -x "$root/.claude/pre-push.sh" ]]; then
        echo "$root/.claude/pre-push.sh"
        return 0
    fi

    # Priority 3: Makefile ci-local target
    if [[ -f "$root/Makefile" ]] && grep -qE '^ci-local[[:space:]]*:' "$root/Makefile" 2>/dev/null; then
        echo "$root/Makefile:ci-local"
        return 0
    fi

    # Not found
    echo ""
    return 1
}

# --- GitHub Actions detection (no network) ---
# has_github_actions — Return 0 if gh CLI exists AND .github/workflows/ exists.
# This is a local-only check — no network call.
# Usage: if has_github_actions "$PROJECT_ROOT"; then ...
has_github_actions() {
    local root="${1:-.}"
    command -v gh >/dev/null 2>&1 || return 1
    [[ -d "$root/.github/workflows" ]] || return 1
    return 0
}

# --- CI status file path ---
# ci_status_file — Return path to project-scoped CI status file.
# Uses project_hash() from core-lib.sh for project isolation.
# Usage: status_file=$(ci_status_file "$PROJECT_ROOT")
ci_status_file() {
    local root="${1:-.}"
    local phash
    phash=$(project_hash "$root")
    local claude_dir="${CLAUDE_DIR:-$HOME/.claude}"
    echo "${claude_dir}/.ci-status-${phash}"
}

# --- Write CI status ---
# write_ci_status — Atomically write CI status to state file.
# All failures write 'error' status — never leaves state file missing.
# Usage: write_ci_status root status run_id conclusion branch workflow started updated url
write_ci_status() {
    local root="${1:-.}"
    local status="${2:-error}"
    local run_id="${3:-}"
    local conclusion="${4:-}"
    local branch="${5:-}"
    local workflow="${6:-}"
    local started="${7:-}"
    local updated="${8:-}"
    local url="${9:-}"
    local write_timestamp
    write_timestamp=$(date +%s)

    local state_file
    state_file=$(ci_status_file "$root")

    local content="${status}|${run_id}|${conclusion}|${branch}|${workflow}|${started}|${updated}|${url}|${write_timestamp}"
    atomic_write "$state_file" "$content"
}

# --- Read CI status ---
# read_ci_status — Populate CI_* globals from state file.
# Returns 0 on success, 1 if state file doesn't exist or is invalid.
# Globals set: CI_STATUS, CI_RUN_ID, CI_CONCLUSION, CI_BRANCH, CI_WORKFLOW,
#              CI_URL, CI_AGE (seconds since write_timestamp)
read_ci_status() {
    local root="${1:-.}"
    CI_STATUS="" CI_RUN_ID="" CI_CONCLUSION="" CI_BRANCH="" CI_WORKFLOW=""
    CI_URL="" CI_AGE=0

    local state_file
    state_file=$(ci_status_file "$root")

    # Validate state file has expected format (9 fields)
    validate_state_file "$state_file" 9 || return 1

    local content
    content=$(head -1 "$state_file" 2>/dev/null) || return 1
    [[ -z "$content" ]] && return 1

    CI_STATUS=$(echo "$content"     | cut -d'|' -f1)
    CI_RUN_ID=$(echo "$content"     | cut -d'|' -f2)
    CI_CONCLUSION=$(echo "$content" | cut -d'|' -f3)
    CI_BRANCH=$(echo "$content"     | cut -d'|' -f4)
    CI_WORKFLOW=$(echo "$content"   | cut -d'|' -f5)
    # fields 6 and 7: started_at, updated_at (not used directly in globals)
    CI_URL=$(echo "$content"        | cut -d'|' -f8)
    local write_ts
    write_ts=$(echo "$content"      | cut -d'|' -f9)

    local now
    now=$(date +%s)
    if [[ -n "$write_ts" && "$write_ts" =~ ^[0-9]+$ ]]; then
        CI_AGE=$(( now - write_ts ))
    else
        CI_AGE=0
    fi

    return 0
}

# --- Format CI summary ---
# format_ci_summary — Format CI_* globals as single-line human-readable string.
# Callers must call read_ci_status first to populate CI_* globals.
# Usage: summary=$(format_ci_summary)
format_ci_summary() {
    local age_str=""
    if [[ "$CI_AGE" -gt 0 ]]; then
        if [[ "$CI_AGE" -lt 60 ]]; then
            age_str="${CI_AGE}s ago"
        elif [[ "$CI_AGE" -lt 3600 ]]; then
            age_str="$((CI_AGE / 60))m ago"
        else
            age_str="$((CI_AGE / 3600))h ago"
        fi
    fi

    local branch_str=""
    [[ -n "$CI_BRANCH" ]] && branch_str=" on ${CI_BRANCH}"

    local workflow_str=""
    [[ -n "$CI_WORKFLOW" ]] && workflow_str=" [${CI_WORKFLOW}]"

    local age_part=""
    [[ -n "$age_str" ]] && age_part=" (${age_str})"

    case "$CI_STATUS" in
        success)
            echo "CI: PASSING${branch_str}${workflow_str}${age_part}"
            ;;
        failure)
            echo "CI: FAILING${branch_str}${workflow_str}${age_part}"
            ;;
        pending)
            echo "CI: IN PROGRESS${branch_str}${workflow_str}${age_part}"
            ;;
        error)
            echo "CI: ERROR${branch_str}${age_part}"
            ;;
        *)
            echo "CI: ${CI_STATUS}${branch_str}${age_part}"
            ;;
    esac
}

export -f find_local_ci has_github_actions ci_status_file write_ci_status read_ci_status format_ci_summary

_CI_LIB_LOADED=1
