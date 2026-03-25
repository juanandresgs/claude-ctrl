#!/usr/bin/env bash
# Shared context-building library for Claude Code hooks.
# Source this file from hooks that need project context:
#   source "$(dirname "$0")/context-lib.sh"
#
# DECISION: Consolidate duplicate context code. Rationale: session-init.sh,
# prompt-submit.sh, and subagent-start.sh all duplicate git state, plan status,
# and worktree listing code. A shared library eliminates drift and reduces
# maintenance surface. Status: accepted.
#
# @decision DEC-CTX-001
# @title Dual-write migration: runtime primary, flat-file fallback
# @status accepted
# @rationale TKT-007 migrates shared workflow state (proof, markers, audit)
#   from flat files to the SQLite runtime. During migration the flat files
#   remain as a fallback so nothing breaks if the runtime is temporarily
#   unavailable. State functions read runtime first; if the runtime call
#   returns empty they fall back to the flat file. All writes go to both
#   the runtime and the flat file. The flat-file deletion happens in TKT-008
#   once the thin hooks prove end-to-end correctness. This pattern means
#   every caller is insulated from both the old and new authority without
#   needing to know which is live.
#
# Provides:
#   get_git_state <project_root>     - Populates GIT_BRANCH, GIT_DIRTY_COUNT,
#                                      GIT_WORKTREES, GIT_WT_COUNT
#   get_plan_status <project_root>   - Populates PLAN_EXISTS, PLAN_PHASE,
#                                      PLAN_TOTAL_PHASES, PLAN_COMPLETED_PHASES,
#                                      PLAN_AGE_DAYS, PLAN_COMMITS_SINCE,
#                                      PLAN_CHANGED_SOURCE_FILES,
#                                      PLAN_TOTAL_SOURCE_FILES,
#                                      PLAN_SOURCE_CHURN_PCT
#   get_session_changes <project_root> - Populates SESSION_CHANGED_COUNT
#   get_drift_data <project_root>    - Populates DRIFT_UNPLANNED_COUNT,
#                                      DRIFT_UNIMPLEMENTED_COUNT,
#                                      DRIFT_MISSING_DECISIONS,
#                                      DRIFT_LAST_AUDIT_EPOCH

# Source the runtime bridge so rt_proof_*, rt_marker_*, rt_event_* are available.
# __CONTEXT_LIB_DIR is resolved once here; sourcing hooks set $0 differently so
# we cannot rely on $(dirname "$0") being stable when this library is sourced
# from multiple callers in the same process.
__CONTEXT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/runtime-bridge.sh
source "${__CONTEXT_LIB_DIR}/lib/runtime-bridge.sh"

# --- Git state ---
get_git_state() {
    local root="$1"
    GIT_BRANCH=""
    GIT_DIRTY_COUNT=0
    GIT_WORKTREES=""
    GIT_WT_COUNT=0

    # Fix #465: In a worktree .git is a FILE (gitdir pointer), not a directory.
    # Use git rev-parse to test git membership uniformly for both cases.
    git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return

    GIT_BRANCH=$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    GIT_DIRTY_COUNT=$(git -C "$root" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

    GIT_WORKTREES=$(git -C "$root" worktree list 2>/dev/null | grep -v "(bare)" | tail -n +2 || echo "")
    if [[ -n "$GIT_WORKTREES" ]]; then
        GIT_WT_COUNT=$(echo "$GIT_WORKTREES" | wc -l | tr -d ' ')
    fi
}

# --- MASTER_PLAN.md status ---
get_plan_status() {
    local root="$1"
    PLAN_EXISTS=false
    PLAN_PHASE=""
    PLAN_TOTAL_PHASES=0
    PLAN_COMPLETED_PHASES=0
    PLAN_IN_PROGRESS_PHASES=0
    PLAN_AGE_DAYS=0
    PLAN_COMMITS_SINCE=0
    PLAN_CHANGED_SOURCE_FILES=0
    PLAN_TOTAL_SOURCE_FILES=0
    PLAN_SOURCE_CHURN_PCT=0

    [[ ! -f "$root/MASTER_PLAN.md" ]] && return

    PLAN_EXISTS=true

    PLAN_PHASE=$(grep -iE '^\#.*phase|^\*\*Phase' "$root/MASTER_PLAN.md" 2>/dev/null | tail -1 || echo "")
    PLAN_TOTAL_PHASES=$(grep -cE '^\#\#\s+Phase\s+[0-9]' "$root/MASTER_PLAN.md" 2>/dev/null || echo "0")
    PLAN_COMPLETED_PHASES=$(grep -cE '\*\*Status:\*\*\s*completed' "$root/MASTER_PLAN.md" 2>/dev/null || echo "0")
    PLAN_IN_PROGRESS_PHASES=$(grep -cE '\*\*Status:\*\*\s*in-progress' "$root/MASTER_PLAN.md" 2>/dev/null || echo "0")

    # Plan age
    local plan_mod
    plan_mod=$(stat -f '%m' "$root/MASTER_PLAN.md" 2>/dev/null || stat -c '%Y' "$root/MASTER_PLAN.md" 2>/dev/null || echo "0")
    if [[ "$plan_mod" -gt 0 ]]; then
        local now
        now=$(date +%s)
        PLAN_AGE_DAYS=$(( (now - plan_mod) / 86400 ))

        # Commits since last plan update
        # Fix #465: use git rev-parse instead of -d .git; works in worktrees too.
        if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            local plan_date
            plan_date=$(date -r "$plan_mod" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@$plan_mod" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")
            if [[ -n "$plan_date" ]]; then
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
            fi
        fi
    fi
}

# --- Session tracking ---
get_session_changes() {
    local root="$1"
    SESSION_CHANGED_COUNT=0
    SESSION_FILE=""

    local session_id
    session_id=$(canonical_session_id)
    if [[ -n "$session_id" && -f "$root/.claude/.session-changes-${session_id}" ]]; then
        SESSION_FILE="$root/.claude/.session-changes-${session_id}"
    elif [[ -f "$root/.claude/.session-changes" ]]; then
        SESSION_FILE="$root/.claude/.session-changes"
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
    RESEARCH_ENTRY_COUNT=$(grep -c '^### \[' "$log" 2>/dev/null || echo "0")
    RESEARCH_RECENT_TOPICS=$(grep '^### \[' "$log" | tail -3 | sed 's/^### \[[^]]*\] //' | paste -sd ', ' - 2>/dev/null || echo "")
}

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

# --- Audit trail ---
# Dual-writes: runtime event store (primary) + flat file (fallback/compat).
append_audit() {
    local root="$1" event="$2" detail="${3:-}"
    # Runtime primary: emit to SQLite event store
    rt_event_emit "$event" "$detail" || true
    # Flat-file compat: keep appending during migration so nothing that reads
    # .audit-log directly breaks before TKT-008 removes it.
    local audit_file="$root/.claude/.audit-log"
    mkdir -p "$root/.claude"
    printf '%s|%s|%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S)" "$event" "$detail" >> "$audit_file" 2>/dev/null || true
}

# --- Session and workflow identity ---
canonical_session_id() {
    printf '%s\n' "${CLAUDE_SESSION_ID:-$$}"
}

sanitize_token() {
    local raw="${1:-}"
    raw=$(printf '%s' "$raw" | tr '/: ' '---' | tr -cd '[:alnum:]._-')
    [[ -n "$raw" ]] || raw="default"
    printf '%s\n' "$raw"
}

current_workflow_id() {
    local root="${1:-}"
    local branch=""

    [[ -n "$root" ]] || root=$(detect_project_root)
    branch=$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

    if [[ -n "$branch" && "$branch" != "HEAD" ]]; then
        sanitize_token "$branch"
    else
        sanitize_token "$(basename "$root")"
    fi
}

# --- Cross-platform filesystem helpers ---
file_mtime() {
    local path="$1"
    stat -f '%m' "$path" 2>/dev/null || stat -c '%Y' "$path" 2>/dev/null || echo "0"
}

# --- Proof-of-work state ---
resolve_proof_file() {
    local root="$1"
    local workflow_id="${2:-}"

    [[ -n "$workflow_id" ]] || workflow_id=$(current_workflow_id "$root")
    printf '%s\n' "$root/.claude/.proof-status-${workflow_id}"
}

read_proof_status_file() {
    local proof_file="$1"
    if [[ -f "$proof_file" ]]; then
        cut -d'|' -f1 "$proof_file" 2>/dev/null || echo "idle"
    else
        echo "idle"
    fi
}

read_proof_timestamp_file() {
    local proof_file="$1"
    if [[ -f "$proof_file" ]]; then
        cut -d'|' -f2 "$proof_file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

read_proof_status() {
    local root="$1"
    local workflow_id="${2:-}"
    local proof_file
    local status=""

    [[ -n "$workflow_id" ]] || workflow_id=$(current_workflow_id "$root")

    # Runtime primary: query SQLite proof store
    status=$(rt_proof_get "$workflow_id" 2>/dev/null) || status=""

    # Flat-file fallback: used when runtime unavailable or DB not yet seeded
    if [[ -z "$status" ]]; then
        proof_file=$(resolve_proof_file "$root" "$workflow_id")
        status=$(read_proof_status_file "$proof_file")
    fi

    printf '%s\n' "${status:-idle}"
}

read_proof_timestamp() {
    local root="$1"
    local workflow_id="${2:-}"
    local proof_file
    local ts=""

    [[ -n "$workflow_id" ]] || workflow_id=$(current_workflow_id "$root")

    # Runtime primary: query SQLite proof store for updated_at
    ts=$(rt_proof_timestamp "$workflow_id" 2>/dev/null) || ts=""

    # Flat-file fallback
    if [[ -z "$ts" || "$ts" == "0" ]]; then
        proof_file=$(resolve_proof_file "$root" "$workflow_id")
        ts=$(read_proof_timestamp_file "$proof_file")
    fi

    printf '%s\n' "${ts:-0}"
}

write_proof_status() {
    local root="$1"
    local status="$2"
    local workflow_id="${3:-}"
    local proof_file

    [[ -n "$workflow_id" ]] || workflow_id=$(current_workflow_id "$root")

    # Runtime primary: upsert into SQLite proof store
    rt_proof_set "$workflow_id" "$status" || true

    # Flat-file compat: dual-write during migration
    proof_file=$(resolve_proof_file "$root" "$workflow_id")
    mkdir -p "$root/.claude"
    printf '%s|%s\n' "$status" "$(date +%s)" > "$proof_file"
}

find_worktree_for_branch() {
    local root="$1"
    local branch="$2"
    local current_path=""
    local current_branch=""
    local line=""

    while IFS= read -r line; do
        case "$line" in
            worktree\ *)
                current_path="${line#worktree }"
                ;;
            branch\ refs/heads/*)
                current_branch="${line#branch refs/heads/}"
                if [[ -n "$current_path" && "$current_branch" == "$branch" ]]; then
                    printf '%s\n' "$current_path"
                    return 0
                fi
                ;;
            "")
                current_path=""
                current_branch=""
                ;;
        esac
    done < <(git -C "$root" worktree list --porcelain 2>/dev/null || true)

    return 1
}

# For merges performed from main, prefer the source branch's worktree proof file.
resolve_proof_file_for_command() {
    local root="$1"
    local command="$2"
    local merge_ref=""
    local merge_worktree=""
    local saw_merge=false
    local token=""

    for token in $command; do
        if [[ "$token" == "merge" ]]; then
            saw_merge=true
            continue
        fi
        if [[ "$saw_merge" == "true" ]]; then
            [[ "$token" == -* ]] && continue
            merge_ref="$token"
            break
        fi
    done

    if [[ -n "$merge_ref" ]]; then
        merge_worktree=$(find_worktree_for_branch "$root" "$merge_ref" 2>/dev/null || true)
        if [[ -n "$merge_worktree" ]]; then
            resolve_proof_file "$merge_worktree" "$(sanitize_token "$merge_ref")"
            return 0
        fi
    fi

    resolve_proof_file "$root"
}

# --- Role detection ---
current_active_agent_role() {
    local root="$1"
    local tracker="$root/.claude/.subagent-tracker"
    local role=""

    # Env var takes precedence — explicit override always wins
    if [[ -n "${CLAUDE_AGENT_ROLE:-}" ]]; then
        printf '%s\n' "$CLAUDE_AGENT_ROLE"
        return 0
    fi

    # Runtime primary: query SQLite agent_markers for the active role
    role=$(rt_marker_get_active_role 2>/dev/null) || role=""

    # Flat-file fallback: read .subagent-tracker when runtime returns empty
    if [[ -z "$role" ]]; then
        if [[ -f "$tracker" ]]; then
            role=$(awk -F'|' '$1=="ACTIVE"{active=$2} END{print active}' "$tracker" 2>/dev/null || true)
        fi
    fi

    printf '%s\n' "$role"
}

is_guardian_role() {
    local role="${1:-}"
    [[ "$role" == "guardian" || "$role" == "Guardian" ]]
}

is_claude_meta_repo() {
    local dir="$1"
    local repo_root

    repo_root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "")
    [[ "$repo_root" == */.claude ]]
}

# --- Statusline cache writer ---
# @decision DEC-CACHE-001
# @title Statusline cache for status bar enrichment
# @status accepted
# @rationale Hooks already compute git/plan/test state. Cache it so statusline.sh
# can render rich status bar without re-computing or re-parsing. Atomic writes
# prevent race conditions. JSON format for extensibility.
# Runtime snapshot path added in TKT-007: when the runtime is available its
# statusline snapshot is written directly, giving the statusline a richer
# runtime-backed projection. Falls back to the computed-fields path when the
# runtime is unavailable.
write_statusline_cache() {
    local root="$1"
    local cache_file="$root/.claude/.statusline-cache"
    mkdir -p "$root/.claude"

    # Runtime primary: write the runtime-backed snapshot directly to cache
    local snapshot
    snapshot=$(cc_policy statusline snapshot 2>/dev/null) || snapshot=""
    if [[ -n "$snapshot" ]]; then
        local tmp_cache="${cache_file}.tmp.$$"
        printf '%s\n' "$snapshot" > "$tmp_cache" && mv "$tmp_cache" "$cache_file"
        return 0
    fi

    # Fallback: compute cache from hook-gathered state (pre-runtime path)

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

track_subagent_start() {
    local root="$1" agent_type="$2"
    local tracker="$root/.claude/.subagent-tracker"
    mkdir -p "$root/.claude"

    # Append start record (line-based for simplicity and atomicity)
    echo "ACTIVE|${agent_type}|$(date +%s)" >> "$tracker"
}

track_subagent_stop() {
    local root="$1" agent_type="$2"
    local tracker="$root/.claude/.subagent-tracker"
    [[ ! -f "$tracker" ]] && return

    # Remove the OLDEST matching ACTIVE entry for this type (FIFO)
    # Use sed to delete first matching line only
    local tmp="${tracker}.tmp.$$"
    local found=false
    while IFS= read -r line; do
        if [[ "$found" == "false" && "$line" == "ACTIVE|${agent_type}|"* ]]; then
            # Convert to DONE record
            local start_epoch="${line##*|}"
            local now_epoch=$(date +%s)
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
    local tracker="$root/.claude/.subagent-tracker"

    SUBAGENT_ACTIVE_COUNT=0
    SUBAGENT_ACTIVE_TYPES=""
    SUBAGENT_TOTAL_COUNT=0

    [[ ! -f "$tracker" ]] && return

    # Count active agents
    SUBAGENT_ACTIVE_COUNT=$(grep -c '^ACTIVE|' "$tracker" 2>/dev/null || echo 0)

    # Get unique active types
    SUBAGENT_ACTIVE_TYPES=$(grep '^ACTIVE|' "$tracker" 2>/dev/null | cut -d'|' -f2 | sort | uniq -c | sed 's/^ *//' | while read count type; do
        if [[ "$count" -gt 1 ]]; then
            echo "${type}x${count}"
        else
            echo "$type"
        fi
    done | paste -sd ',' - 2>/dev/null || echo "")

    # Total = active + done
    SUBAGENT_TOTAL_COUNT=$(wc -l < "$tracker" 2>/dev/null | tr -d ' ')
}

# Export for subshells
export SOURCE_EXTENSIONS
export -f cc_policy _rt_ensure_schema rt_proof_get rt_proof_set rt_proof_timestamp rt_marker_get_active_role rt_marker_set rt_marker_deactivate rt_event_emit
export -f get_git_state get_plan_status get_session_changes get_drift_data get_research_status is_source_file is_skippable_path append_audit canonical_session_id sanitize_token current_workflow_id file_mtime resolve_proof_file read_proof_status_file read_proof_timestamp_file read_proof_status read_proof_timestamp write_proof_status find_worktree_for_branch resolve_proof_file_for_command current_active_agent_role is_guardian_role is_claude_meta_repo write_statusline_cache track_subagent_start track_subagent_stop get_subagent_status
