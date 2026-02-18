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
#   get_session_changes <project_root> - Populates SESSION_CHANGED_COUNT
#   get_drift_data <project_root>    - Populates DRIFT_UNPLANNED_COUNT,
#                                      DRIFT_UNIMPLEMENTED_COUNT,
#                                      DRIFT_MISSING_DECISIONS,
#                                      DRIFT_LAST_AUDIT_EPOCH

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
    PLAN_TOTAL_PHASES=$(grep -cE '^\#\#\s+Phase\s+[0-9]' "$root/MASTER_PLAN.md" 2>/dev/null || true)
    PLAN_TOTAL_PHASES=${PLAN_TOTAL_PHASES:-0}
    PLAN_COMPLETED_PHASES=$(grep -cE '\*\*Status:\*\*\s*completed' "$root/MASTER_PLAN.md" 2>/dev/null || true)
    PLAN_COMPLETED_PHASES=${PLAN_COMPLETED_PHASES:-0}
    PLAN_IN_PROGRESS_PHASES=$(grep -cE '\*\*Status:\*\*\s*in-progress' "$root/MASTER_PLAN.md" 2>/dev/null || true)
    PLAN_IN_PROGRESS_PHASES=${PLAN_IN_PROGRESS_PHASES:-0}

    # Plan lifecycle state: none (no plan), active (has incomplete phases), completed (all phases done)
    # PLAN_LIFECYCLE defaults to "none" (set above, before early return).
    if [[ "$PLAN_TOTAL_PHASES" -gt 0 && "$PLAN_COMPLETED_PHASES" -eq "$PLAN_TOTAL_PHASES" ]]; then
        PLAN_LIFECYCLE="completed"
    else
        PLAN_LIFECYCLE="active"
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

# --- Session tracking ---
get_session_changes() {
    local root="$1"
    SESSION_CHANGED_COUNT=0
    SESSION_FILE=""

    local session_id="${CLAUDE_SESSION_ID:-}"
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
    RESEARCH_ENTRY_COUNT=$(grep -c '^### \[' "$log" 2>/dev/null || true)
    RESEARCH_ENTRY_COUNT=${RESEARCH_ENTRY_COUNT:-0}
    RESEARCH_RECENT_TOPICS=$(grep '^### \[' "$log" | tail -3 | sed 's/^### \[[^]]*\] //' | paste -sd ', ' - 2>/dev/null || echo "")
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

TRACE_STORE="$HOME/.claude/traces"

# Initialize a trace directory for a new agent run.
# Usage: init_trace "/path/to/project" "implementer"
# Returns: trace_id (or empty on failure)
init_trace() {
    local project_root="$1"
    local agent_type="${2:-unknown}"
    local session_id="${CLAUDE_SESSION_ID:-$(date +%s)}"
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
    branch=$(git -C "$project_root" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch="unknown"

    cat > "${trace_dir}/manifest.json" <<MANIFEST
{
  "version": "1",
  "trace_id": "${trace_id}",
  "agent_type": "${agent_type}",
  "session_id": "${session_id}",
  "project": "${project_root}",
  "project_name": "${project_name}",
  "branch": "${branch}",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "active"
}
MANIFEST

    # Active marker for detection
    echo "${trace_id}" > "${TRACE_STORE}/.active-${agent_type}-${session_id}"

    echo "${trace_id}"
}

# Detect active trace for current session and agent type.
# Usage: detect_active_trace "/path/to/project" "implementer"
# Returns: trace_id (or empty if none active)
detect_active_trace() {
    local project_root="$1"
    local agent_type="${2:-unknown}"
    local session_id="${CLAUDE_SESSION_ID:-}"

    # Try session-specific marker first
    if [[ -n "$session_id" ]]; then
        local marker="${TRACE_STORE}/.active-${agent_type}-${session_id}"
        if [[ -f "$marker" ]]; then
            cat "$marker"
            return 0
        fi
    fi

    # Fallback: find most recent active marker for this agent type
    local latest
    latest=$(ls -t "${TRACE_STORE}/.active-${agent_type}-"* 2>/dev/null | head -1)
    if [[ -n "$latest" && -f "$latest" ]]; then
        cat "$latest"
        return 0
    fi

    return 1
}

# Finalize a trace after agent completion.
# Updates manifest with outcome, duration, test results. Indexes the trace.
# Usage: finalize_trace "trace_id" "/path/to/project" "implementer"
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
        now_epoch=$(date +%s)
        if [[ "$start_epoch" -gt 0 ]]; then
            duration=$(( now_epoch - start_epoch ))
        fi
    fi

    # Determine outcome from artifacts
    local outcome="unknown"
    local test_result="unknown"
    local proof_status="unknown"

    # Check test output
    if [[ -f "${trace_dir}/artifacts/test-output.txt" ]]; then
        if grep -qiE 'passed|success|ok' "${trace_dir}/artifacts/test-output.txt" 2>/dev/null; then
            test_result="pass"
        elif grep -qiE 'failed|error|failure' "${trace_dir}/artifacts/test-output.txt" 2>/dev/null; then
            test_result="fail"
        fi
    fi

    # Fallback: check .test-status file when test-output.txt didn't resolve a result.
    # Most agents write .test-status to the project root (or .claude/) instead of the
    # trace artifacts dir, causing 97.8% of traces to show unknown test_result.
    # Priority: project_root/.test-status > project_root/.claude/.test-status.
    # @decision DEC-OBS-SUG002
    # @title Add .test-status fallback to finalize_trace
    # @status accepted
    # @rationale Agents consistently write .test-status but rarely write test-output.txt
    #             as a trace artifact. This fallback recovers test_result from the file
    #             agents already produce, without changing agent behavior. test-output.txt
    #             (checked above) takes priority because it contains richer evidence.
    if [[ "$test_result" == "unknown" ]]; then
        local test_status_file=""
        if [[ -f "${project_root}/.test-status" ]]; then
            test_status_file="${project_root}/.test-status"
        elif [[ -f "${project_root}/.claude/.test-status" ]]; then
            test_status_file="${project_root}/.claude/.test-status"
        fi
        if [[ -n "$test_status_file" ]]; then
            local ts_content
            ts_content=$(cat "$test_status_file" 2>/dev/null | tr -d '[:space:]')
            if [[ "$ts_content" == "pass" || "$ts_content" == "passed" ]]; then
                test_result="pass"
            elif [[ "$ts_content" == "fail" || "$ts_content" == "failed" ]]; then
                test_result="fail"
            fi
        fi
    fi

    # Check proof status from project
    # Prefer the local .claude/.proof-status; fall back to get_claude_dir() to
    # handle the ~/.claude meta-repo case (avoids double-nesting ~/.claude/.claude/).
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
    if [[ "$test_result" == "pass" ]]; then
        outcome="success"
    elif [[ "$test_result" == "fail" ]]; then
        outcome="failure"
    else
        outcome="partial"
    fi

    # Count files changed
    local files_changed=0
    if [[ -f "${trace_dir}/artifacts/files-changed.txt" ]]; then
        files_changed=$(wc -l < "${trace_dir}/artifacts/files-changed.txt" | tr -d ' ')
    fi

    # Fallback: use git diff when files-changed.txt artifact is missing.
    # Most agents modify files but don't write files-changed.txt as a trace artifact,
    # causing 97% of traces to show files_changed=0.
    # @decision DEC-OBS-SUG003
    # @title Add git diff fallback to finalize_trace files_changed count
    # @status accepted
    # @rationale Agents consistently modify files but rarely write files-changed.txt.
    #             git diff --stat against the worktree or recent commits recovers accurate
    #             file counts without changing agent behavior. Uncommitted changes are
    #             checked first (most relevant for in-flight traces); staged changes are
    #             the secondary fallback.
    if [[ "$files_changed" -eq 0 && -n "$project_root" ]]; then
        # Try git diff --stat for uncommitted changes first
        local git_stat
        git_stat=$(git -C "$project_root" diff --stat 2>/dev/null | tail -1)
        if [[ -n "$git_stat" ]]; then
            files_changed=$(echo "$git_stat" | awk '{print $1}')
            # Validate it's a number
            [[ "$files_changed" =~ ^[0-9]+$ ]] || files_changed=0
        fi
        # If still 0, try staged changes
        if [[ "$files_changed" -eq 0 ]]; then
            git_stat=$(git -C "$project_root" diff --cached --stat 2>/dev/null | tail -1)
            if [[ -n "$git_stat" ]]; then
                files_changed=$(echo "$git_stat" | awk '{print $1}')
                [[ "$files_changed" =~ ^[0-9]+$ ]] || files_changed=0
            fi
        fi
    fi

    # Check if summary exists; if not, it's likely a crash
    local trace_status="completed"
    if [[ ! -f "${trace_dir}/summary.md" ]]; then
        trace_status="crashed"
        outcome="crashed"
    fi

    # Update manifest with jq (merge new fields)
    local tmp_manifest="${manifest}.tmp"
    jq --arg finished_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --argjson duration "$duration" \
       --arg trace_status "$trace_status" \
       --arg outcome "$outcome" \
       --arg test_result "$test_result" \
       --arg proof_status "$proof_status" \
       --argjson files_changed "$files_changed" \
       '. + {
         finished_at: $finished_at,
         duration_seconds: $duration,
         status: $trace_status,
         outcome: $outcome,
         test_result: $test_result,
         proof_status: $proof_status,
         files_changed: $files_changed
       }' "$manifest" > "$tmp_manifest" 2>/dev/null && mv "$tmp_manifest" "$manifest"

    # Clean active marker
    local session_id="${CLAUDE_SESSION_ID:-}"
    rm -f "${TRACE_STORE}/.active-${agent_type}-${session_id}" 2>/dev/null
    # Also try wildcard cleanup for this agent type (handles session ID mismatch)
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
                trace_path="~/.claude/traces/$(cat "$marker" 2>/dev/null)"
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
                | while IFS= read -r f; do echo "$(stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f" 2>/dev/null || echo 0) $f"; done \
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

# Export for subshells
export TRACE_STORE SOURCE_EXTENSIONS DECISION_LINE_THRESHOLD TEST_STALENESS_THRESHOLD SESSION_STALENESS_THRESHOLD
export -f get_git_state get_plan_status get_session_changes get_drift_data get_research_status is_source_file is_skippable_path is_test_file read_test_status validate_state_file atomic_write append_audit write_statusline_cache track_subagent_start track_subagent_stop get_subagent_status safe_cleanup archive_plan init_trace detect_active_trace finalize_trace index_trace is_claude_meta_repo append_session_event get_session_trajectory get_session_summary_context build_resume_directive get_prior_sessions
