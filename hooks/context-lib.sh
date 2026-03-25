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
# @title Runtime-only state: flat-file dual-write bridge removed (TKT-008)
# @status accepted
# @rationale TKT-007 migrated shared workflow state (proof, markers, audit)
#   from flat files to the SQLite runtime. TKT-008 completes the cutover:
#   all flat-file writes and fallback reads have been removed. The SQLite
#   runtime (cc-policy) is the sole authority for proof, markers, and audit
#   events. Functions that previously dual-wrote to .proof-status-*,
#   .subagent-tracker, .audit-log, or .statusline-cache now use runtime-only
#   paths. Flat-file helper functions (resolve_proof_file,
#   read_proof_status_file, read_proof_timestamp_file) are retained only
#   because guard.sh still calls read_proof_status_file directly on the
#   worktree-resolved proof path. get_drift_data is retained as a no-op
#   stub so callers in plan-check.sh compile without changes.
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
#   get_drift_data <project_root>    - Stub: always returns zero counts (no .plan-drift file read)

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

# --- Plan drift data — stub (TKT-008: .plan-drift file removed) ---
# The .plan-drift flat file is no longer written or read. plan-check.sh uses
# the commit-count heuristic exclusively when DRIFT_LAST_AUDIT_EPOCH == 0.
# This stub keeps callers compiling without changes.
get_drift_data() {
    # root="$1" — ignored, no file to read
    DRIFT_UNPLANNED_COUNT=0
    DRIFT_UNIMPLEMENTED_COUNT=0
    DRIFT_MISSING_DECISIONS=0
    DRIFT_LAST_AUDIT_EPOCH=0
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
# Runtime-only (TKT-008): .audit-log flat file removed.
# All audit events go directly to the SQLite event store via rt_event_emit.
# The root parameter is kept for call-site compatibility but is no longer used.
append_audit() {
    local root="$1" event="$2" detail="${3:-}"
    rt_event_emit "$event" "$detail" || true
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
    local status=""

    [[ -n "$workflow_id" ]] || workflow_id=$(current_workflow_id "$root")

    # Runtime-only (TKT-008): query SQLite proof store exclusively.
    status=$(rt_proof_get "$workflow_id" 2>/dev/null) || status=""

    printf '%s\n' "${status:-idle}"
}

read_proof_timestamp() {
    local root="$1"
    local workflow_id="${2:-}"
    local ts=""

    [[ -n "$workflow_id" ]] || workflow_id=$(current_workflow_id "$root")

    # Runtime-only (TKT-008): query SQLite proof store exclusively.
    ts=$(rt_proof_timestamp "$workflow_id" 2>/dev/null) || ts=""

    printf '%s\n' "${ts:-0}"
}

write_proof_status() {
    local root="$1"
    local status="$2"
    local workflow_id="${3:-}"

    [[ -n "$workflow_id" ]] || workflow_id=$(current_workflow_id "$root")

    # Runtime-only (TKT-008): upsert into SQLite proof store exclusively.
    # The root parameter is kept for call-site compatibility but is no longer used.
    rt_proof_set "$workflow_id" "$status" || true
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
    local role=""

    # Env var takes precedence — explicit override always wins
    if [[ -n "${CLAUDE_AGENT_ROLE:-}" ]]; then
        printf '%s\n' "$CLAUDE_AGENT_ROLE"
        return 0
    fi

    # Runtime-only (TKT-008): query SQLite agent_markers exclusively.
    # .subagent-tracker flat-file fallback removed.
    role=$(rt_marker_get_active_role 2>/dev/null) || role=""

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

# --- Statusline cache writer removed (TKT-008) ---
# @decision DEC-CACHE-001
# @title .statusline-cache flat file removed; statusline reads runtime directly
# @status superseded
# @rationale write_statusline_cache() wrote a .statusline-cache flat file that
#   scripts/statusline.sh would then read. Since TKT-007, statusline.sh calls
#   rt_statusline_snapshot() directly against the runtime — the cache file is
#   no longer read by any consumer. The function is removed in TKT-008 to
#   eliminate the last hot-path flat-file write. session-init.sh callers that
#   called write_statusline_cache() have been updated to call
#   rt_statusline_snapshot() directly if they need a snapshot for logging,
#   or to simply omit the call if the snapshot was only ever written to the
#   cache file.

# --- Subagent tracking removed (TKT-008) ---
# @decision DEC-SUBAGENT-001
# @title .subagent-tracker flat file removed; lifecycle tracked via runtime markers
# @status superseded
# @rationale track_subagent_start/stop/get_subagent_status wrote to
#   .subagent-tracker. The runtime marker store (rt_marker_set/deactivate) is
#   the sole authority for agent lifecycle since TKT-007. subagent-start.sh
#   already called rt_marker_set; the redundant flat-file call is removed.
#   check-implementer.sh called track_subagent_stop; that call is removed too.
#   session-init.sh deleted .subagent-tracker on startup; that line is removed.

# Export for subshells
export SOURCE_EXTENSIONS
export -f cc_policy _rt_ensure_schema rt_proof_get rt_proof_set rt_proof_timestamp rt_marker_get_active_role rt_marker_set rt_marker_deactivate rt_event_emit
export -f get_git_state get_plan_status get_session_changes get_drift_data get_research_status is_source_file is_skippable_path append_audit canonical_session_id sanitize_token current_workflow_id file_mtime resolve_proof_file read_proof_status_file read_proof_timestamp_file read_proof_status read_proof_timestamp write_proof_status find_worktree_for_branch resolve_proof_file_for_command current_active_agent_role is_guardian_role is_claude_meta_repo
