#!/usr/bin/env bash
# Shared context-building library for Claude Code hooks.
# Source this file from hooks that need project context:
#   source "$(dirname "$0")/context-lib.sh"
#
# @decision DEC-CTXLIB-001
# @title Consolidate duplicate context code into shared library
# @status accepted
# @rationale session-init.sh, prompt-submit.sh, and subagent-start.sh all duplicated
#   git state, plan status, and worktree listing code. A shared library eliminates
#   drift and reduces maintenance surface. All hooks source this file instead of
#   reimplementing context capture logic inline.
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

    # Capture start_commit for retrospective file counting in refinalize_trace.
    # @decision DEC-REFINALIZE-004
    # @title Capture start_commit in init_trace for commit-range file counting
    # @status accepted
    # @rationale refinalize_trace() cannot use git diff (worktree may be gone) but CAN
    #   use git log/show on commit hashes if they are stored at trace start. The start
    #   commit paired with end_commit (captured in finalize_trace) gives a precise range
    #   for counting files changed, recovering files_changed=0 for 79% of traces.
    local start_commit=""
    if [[ "$branch" != "no-git" ]]; then
        start_commit=$(git -C "$project_root" rev-parse HEAD 2>/dev/null || echo "")
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

    # Active marker for detection
    echo "${trace_id}" > "${TRACE_STORE}/.active-${agent_type}-${session_id}"

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
    local project_root="$1"
    local agent_type="${2:-unknown}"
    local session_id="${CLAUDE_SESSION_ID:-}"

    # Primary path: session-specific marker (named .active-TYPE-SESSION_ID)
    if [[ -n "$session_id" ]]; then
        local marker="${TRACE_STORE}/.active-${agent_type}-${session_id}"
        if [[ -f "$marker" ]]; then
            cat "$marker"
            return 0
        fi

        # Session-specific marker not found. Iterate all markers for this agent type
        # and validate each one against the manifest session_id. This handles the
        # case where the marker was written with a different session_id format but
        # the manifest correctly records the session_id we're looking for.
        local candidate
        for candidate in "${TRACE_STORE}/.active-${agent_type}-"*; do
            [[ -f "$candidate" ]] || continue
            local candidate_trace_id
            candidate_trace_id=$(cat "$candidate" 2>/dev/null) || continue
            [[ -n "$candidate_trace_id" ]] || continue
            local candidate_manifest="${TRACE_STORE}/${candidate_trace_id}/manifest.json"
            [[ -f "$candidate_manifest" ]] || continue
            local manifest_session
            manifest_session=$(jq -r '.session_id // empty' "$candidate_manifest" 2>/dev/null)
            if [[ "$manifest_session" == "$session_id" ]]; then
                echo "$candidate_trace_id"
                return 0
            fi
        done

        # No marker matched our session_id — return not found
        return 1
    fi

    # CLAUDE_SESSION_ID is unavailable: fall back to ls -t (most recent marker).
    # Log a warning so operators know the session-safe path was bypassed.
    # This is the original behavior, preserved for backward compatibility when
    # session IDs are not injected (e.g., legacy hook invocations).
    echo "WARNING: detect_active_trace: CLAUDE_SESSION_ID not set — using ls -t fallback (glob race possible)" >&2
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

    # Fallback: check verification-output.txt for tester agents.
    # Testers write verification-output.txt (not test-output.txt) as their
    # primary evidence artifact. Check for pass/success signals in it.
    if [[ "$test_result" == "unknown" && -f "${trace_dir}/artifacts/verification-output.txt" ]]; then
        if grep -qiE 'passed|success|ok|successful' "${trace_dir}/artifacts/verification-output.txt" 2>/dev/null; then
            test_result="pass"
        elif grep -qiE 'failed|error|failure' "${trace_dir}/artifacts/verification-output.txt" 2>/dev/null; then
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
    if [[ "$test_result" == "pass" ]]; then
        outcome="success"
    elif [[ "$test_result" == "fail" ]]; then
        outcome="failure"
    elif [[ "$duration" -gt 600 && "$test_result" == "unknown" ]]; then
        outcome="timeout"
    elif [[ ! -d "${trace_dir}/artifacts" ]]; then
        outcome="skipped"
    elif [[ -z "$(ls -A "${trace_dir}/artifacts" 2>/dev/null)" ]]; then
        outcome="skipped"
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

    # Capture end_commit for retrospective file counting in refinalize_trace.
    # Paired with start_commit (written by init_trace), this enables git log --name-only
    # to count files changed between the two commits even after the worktree is removed.
    local end_commit=""
    if [[ -n "$project_root" ]] && git -C "$project_root" rev-parse --git-dir >/dev/null 2>&1; then
        end_commit=$(git -C "$project_root" rev-parse HEAD 2>/dev/null || echo "")
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

# Re-finalize a single trace whose manifest was sealed before artifacts arrived.
# Reads artifacts from the trace dir, re-evaluates test_result, files_changed,
# duration_seconds, and outcome, then updates the manifest only if values changed.
# Does NOT call index_trace() — caller decides when to rebuild the index.
# Does NOT check .test-status (project-scoped, may have changed since trace time).
# Does NOT use git diff fallback for files_changed (worktree may be gone).
#
# @decision DEC-REFINALIZE-002
# @title Re-finalize uses finished_at for duration, not current time
# @status accepted
# @rationale finalize_trace() uses now_epoch (current time) for duration because it runs
#   at SubagentStop time. refinalize_trace() runs retrospectively — possibly days later.
#   Using current time would inflate duration_seconds to absurd values. Instead, we
#   parse finished_at from the manifest to get the correct end time. If finished_at is
#   missing, we skip duration correction (leave as-is) rather than guess.
#
# Usage: refinalize_trace "trace_id"
# Returns: 0 if manifest was updated, 1 if no changes needed
refinalize_trace() {
    local trace_id="$1"
    local trace_dir="${TRACE_STORE}/${trace_id}"
    local manifest="${trace_dir}/manifest.json"

    [[ ! -f "$manifest" ]] && return 1

    # Read current manifest values
    local cur_test_result cur_files_changed cur_duration cur_outcome cur_started_at
    cur_test_result=$(jq -r '.test_result // "unknown"' "$manifest" 2>/dev/null)
    cur_files_changed=$(jq -r '.files_changed // 0' "$manifest" 2>/dev/null)
    cur_duration=$(jq -r '.duration_seconds // 0' "$manifest" 2>/dev/null)
    cur_outcome=$(jq -r '.outcome // "unknown"' "$manifest" 2>/dev/null)
    cur_started_at=$(jq -r '.started_at // empty' "$manifest" 2>/dev/null)

    # --- Re-evaluate test_result from artifacts ---
    local test_result="unknown"

    if [[ -f "${trace_dir}/artifacts/test-output.txt" ]]; then
        if grep -qiE 'passed|success|ok' "${trace_dir}/artifacts/test-output.txt" 2>/dev/null; then
            test_result="pass"
        elif grep -qiE 'failed|error|failure' "${trace_dir}/artifacts/test-output.txt" 2>/dev/null; then
            test_result="fail"
        fi
    fi

    # Fallback: check verification-output.txt (tester agents write this instead)
    if [[ "$test_result" == "unknown" && -f "${trace_dir}/artifacts/verification-output.txt" ]]; then
        if grep -qiE 'passed|success|ok|successful' "${trace_dir}/artifacts/verification-output.txt" 2>/dev/null; then
            test_result="pass"
        elif grep -qiE 'failed|error|failure' "${trace_dir}/artifacts/verification-output.txt" 2>/dev/null; then
            test_result="fail"
        fi
    fi

    # Fallback: check .test-status from the project directory.
    # @decision DEC-REFINALIZE-005
    # @title Add .test-status fallback to refinalize_trace with timestamp window validation
    # @status accepted
    # @rationale 72% of new traces have test_result=unknown because agents write .test-status
    #   (not test-output.txt). finalize_trace() already reads .test-status but at seal time
    #   the file may not yet exist. refinalize_trace() runs retrospectively when the file
    #   has had time to land. Timestamp validation (mtime within trace window + 10-min buffer)
    #   prevents misattribution when multiple agents ran against the same project sequentially.
    #   This is safe because agents have finished writing before refinalize runs.
    if [[ "$test_result" == "unknown" ]]; then
        local rf_project_root
        rf_project_root=$(jq -r '.project // empty' "$manifest" 2>/dev/null)
        if [[ -n "$rf_project_root" ]]; then
            local test_status_file=""
            if [[ -f "${rf_project_root}/.test-status" ]]; then
                test_status_file="${rf_project_root}/.test-status"
            elif [[ -f "${rf_project_root}/.claude/.test-status" ]]; then
                test_status_file="${rf_project_root}/.claude/.test-status"
            fi
            if [[ -n "$test_status_file" ]]; then
                local ts_content
                ts_content=$(cut -d'|' -f1 "$test_status_file" 2>/dev/null | tr -d '[:space:]')
                # Verify .test-status timestamp is within the trace's time window.
                # Prevents misattribution when multiple agents ran sequentially.
                local ts_mod
                ts_mod=$(stat -f '%m' "$test_status_file" 2>/dev/null \
                    || stat -c '%Y' "$test_status_file" 2>/dev/null \
                    || echo "0")
                local trace_start_epoch trace_end_epoch
                trace_start_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$cur_started_at" +%s 2>/dev/null \
                    || date -u -d "$cur_started_at" +%s 2>/dev/null \
                    || echo "0")
                local finished_at_val
                finished_at_val=$(jq -r '.finished_at // empty' "$manifest" 2>/dev/null)
                trace_end_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$finished_at_val" +%s 2>/dev/null \
                    || date -u -d "$finished_at_val" +%s 2>/dev/null \
                    || echo "0")
                # Allow 10-minute buffer after trace end for late writes
                local buffer=600
                if [[ "$ts_mod" -ge "$trace_start_epoch" && \
                      "$trace_start_epoch" -gt 0 && \
                      "$ts_mod" -le $(( trace_end_epoch + buffer )) ]]; then
                    if [[ "$ts_content" == "pass" || "$ts_content" == "passed" ]]; then
                        test_result="pass"
                    elif [[ "$ts_content" == "fail" || "$ts_content" == "failed" ]]; then
                        test_result="fail"
                    fi
                fi
            fi
        fi
    fi

    # --- Re-evaluate files_changed from artifact (no git fallback — worktree may be gone) ---
    local files_changed=0
    if [[ -f "${trace_dir}/artifacts/files-changed.txt" ]]; then
        files_changed=$(wc -l < "${trace_dir}/artifacts/files-changed.txt" | tr -d ' ')
    fi

    # Fallback: use commit hashes stored in manifest to count files changed via git log.
    # @decision DEC-REFINALIZE-006
    # @title Commit-hash-based file counting fallback in refinalize_trace
    # @status accepted
    # @rationale 79% of traces have files_changed=0 because agents commit files rather than
    #   writing files-changed.txt. start_commit (init_trace) and end_commit (finalize_trace)
    #   bracket the work. git log --name-only between those commits counts unique files changed
    #   even after the worktree is removed, as long as the commit objects exist in any repo
    #   that contains them. We check project root first, then ~/.claude as fallback for merged
    #   worktrees. cat-file -t validates the commit exists before running git log.
    if [[ "$files_changed" -eq 0 ]]; then
        local fc_start_commit fc_end_commit fc_project_root
        fc_start_commit=$(jq -r '.start_commit // empty' "$manifest" 2>/dev/null)
        fc_end_commit=$(jq -r '.end_commit // empty' "$manifest" 2>/dev/null)
        fc_project_root=$(jq -r '.project // empty' "$manifest" 2>/dev/null)

        if [[ -n "$fc_end_commit" && -n "$fc_project_root" ]]; then
            # Find a repo that contains the end_commit — try project root, then ~/.claude
            local git_repo=""
            for candidate in "$fc_project_root" "$HOME/.claude"; do
                if [[ -d "$candidate" ]] && git -C "$candidate" rev-parse --git-dir >/dev/null 2>&1; then
                    if git -C "$candidate" cat-file -t "$fc_end_commit" >/dev/null 2>&1; then
                        git_repo="$candidate"
                        break
                    fi
                fi
            done

            if [[ -n "$git_repo" ]]; then
                local git_files=0
                if [[ -n "$fc_start_commit" ]] && \
                   git -C "$git_repo" cat-file -t "$fc_start_commit" >/dev/null 2>&1; then
                    # Count unique files changed between start and end commits
                    git_files=$(git -C "$git_repo" log --name-only --format="" \
                        "${fc_start_commit}..${fc_end_commit}" 2>/dev/null \
                        | sort -u | grep -c '.' 2>/dev/null) || git_files=0
                else
                    # No valid start_commit — count files in the end commit only
                    git_files=$(git -C "$git_repo" show --name-only --format="" \
                        "$fc_end_commit" 2>/dev/null \
                        | grep -c '.' 2>/dev/null) || git_files=0
                fi
                [[ "$git_files" =~ ^[0-9]+$ ]] && files_changed="$git_files"
            fi
        fi
    fi

    # --- Fix duration_seconds if <= 0 using started_at + finished_at from manifest ---
    local duration="$cur_duration"
    if [[ "$cur_duration" -le 0 ]]; then
        local started_at finished_at
        started_at=$(jq -r '.started_at // empty' "$manifest" 2>/dev/null)
        finished_at=$(jq -r '.finished_at // empty' "$manifest" 2>/dev/null)
        if [[ -n "$started_at" && -n "$finished_at" ]]; then
            local start_epoch end_epoch
            start_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_at" +%s 2>/dev/null \
                || date -u -d "$started_at" +%s 2>/dev/null \
                || echo "0")
            end_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$finished_at" +%s 2>/dev/null \
                || date -u -d "$finished_at" +%s 2>/dev/null \
                || echo "0")
            if [[ "$start_epoch" -gt 0 && "$end_epoch" -gt "$start_epoch" ]]; then
                duration=$(( end_epoch - start_epoch ))
            fi
        fi
    fi

    # --- Re-evaluate outcome using canonical logic ---
    local outcome="unknown"

    if [[ "$test_result" == "pass" ]]; then
        outcome="success"
    elif [[ "$test_result" == "fail" ]]; then
        outcome="failure"
    elif [[ "$duration" -gt 600 && "$test_result" == "unknown" ]]; then
        outcome="timeout"
    elif [[ ! -d "${trace_dir}/artifacts" ]]; then
        outcome="skipped"
    elif [[ -z "$(ls -A "${trace_dir}/artifacts" 2>/dev/null)" ]]; then
        outcome="skipped"
    else
        outcome="partial"
    fi

    # Preserve "crashed" outcome if summary.md is missing (don't downgrade to partial)
    if [[ ! -f "${trace_dir}/summary.md" && "$outcome" != "skipped" ]]; then
        outcome="crashed"
    fi

    # --- Status repair: transition stuck "active" traces to "completed" ---
    # Orphaned traces (where finalize_trace was never called) keep status="active"
    # indefinitely. If a trace has been "active" for more than 30 minutes, we
    # assume the agent is gone and transition it to "completed" with an estimated
    # finished_at. This does not affect traces that already have status="completed"
    # or "crashed".
    #
    # @decision DEC-REFINALIZE-007
    # @title Repair orphaned active status in refinalize_trace
    # @status accepted
    # @rationale Three bug sources leave traces permanently "active":
    #   1. check-explore.sh and check-general-purpose.sh (no finalize_trace call)
    #   2. Timeout races where finalize_trace is reached too late in the 5s budget
    #   3. Agent crashes before SubagentStop fires
    #   All three leave status="active" with no finished_at. Running refinalize_trace
    #   retrospectively can detect these orphans (>30 min old, still active) and
    #   transition them to "completed" so they appear correctly in reports and
    #   don't inflate active-agent counts. finished_at is estimated from the latest
    #   artifact mtime or started_at + duration_seconds when available.
    local cur_status
    cur_status=$(jq -r '.status // "unknown"' "$manifest" 2>/dev/null)
    local new_status="$cur_status"
    local new_finished_at=""

    if [[ "$cur_status" == "active" ]]; then
        local now_epoch_rf
        now_epoch_rf=$(date -u +%s)
        local start_epoch_rf=0
        if [[ -n "$cur_started_at" ]]; then
            start_epoch_rf=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$cur_started_at" +%s 2>/dev/null \
                || date -u -d "$cur_started_at" +%s 2>/dev/null \
                || echo "0")
        fi
        local orphan_threshold=1800  # 30 minutes
        if [[ "$start_epoch_rf" -gt 0 && \
              $(( now_epoch_rf - start_epoch_rf )) -gt "$orphan_threshold" ]]; then
            new_status="completed"
            # Estimate finished_at: try latest artifact mtime, then started_at + duration
            local estimated_end=0
            if [[ -d "${trace_dir}/artifacts" ]]; then
                local latest_artifact
                latest_artifact=$(ls -t "${trace_dir}/artifacts/" 2>/dev/null | head -1)
                if [[ -n "$latest_artifact" ]]; then
                    estimated_end=$(stat -f '%m' "${trace_dir}/artifacts/${latest_artifact}" 2>/dev/null \
                        || stat -c '%Y' "${trace_dir}/artifacts/${latest_artifact}" 2>/dev/null \
                        || echo "0")
                fi
            fi
            if [[ "$estimated_end" -eq 0 && "$duration" -gt 0 ]]; then
                estimated_end=$(( start_epoch_rf + duration ))
            fi
            if [[ "$estimated_end" -gt 0 ]]; then
                new_finished_at=$(date -u -r "$estimated_end" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                    || date -u -d "@${estimated_end}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                    || echo "")
            fi
        fi
    fi

    # --- Check if anything actually changed ---
    local changed=false
    [[ "$test_result" != "$cur_test_result" ]] && changed=true
    [[ "$files_changed" != "$cur_files_changed" ]] && changed=true
    [[ "$duration" != "$cur_duration" ]] && changed=true
    [[ "$outcome" != "$cur_outcome" ]] && changed=true
    [[ "$new_status" != "$cur_status" ]] && changed=true

    if ! $changed; then
        return 1
    fi

    # --- Atomic manifest update ---
    local tmp_manifest="${manifest}.tmp"
    local jq_args=(
        --argjson duration "$duration"
        --arg test_result "$test_result"
        --argjson files_changed "$files_changed"
        --arg outcome "$outcome"
        --arg new_status "$new_status"
    )
    local jq_expr='. + {
         duration_seconds: $duration,
         test_result: $test_result,
         files_changed: $files_changed,
         outcome: $outcome,
         status: $new_status
       }'
    # Only inject finished_at if we computed one (avoid overwriting existing value)
    if [[ -n "$new_finished_at" ]]; then
        jq_args+=(--arg new_finished_at "$new_finished_at")
        jq_expr='. + {
         duration_seconds: $duration,
         test_result: $test_result,
         files_changed: $files_changed,
         outcome: $outcome,
         status: $new_status,
         finished_at: $new_finished_at
       }'
    fi
    # Apply the same jq error handling pattern as finalize_trace (DEC-OBS-OVERHAUL-003):
    # use a separate error file to capture stderr (stdout goes to tmp_manifest),
    # check exit code, validate non-empty tmp before mv.
    local jq_err_file="${manifest}.jqerr"
    jq "${jq_args[@]}" "$jq_expr" "$manifest" > "$tmp_manifest" 2>"$jq_err_file" || {
        local jq_err_msg
        jq_err_msg=$(cat "$jq_err_file" 2>/dev/null)
        echo "ERROR: refinalize_trace: jq failed to update manifest for trace $trace_id: $jq_err_msg" >&2
        rm -f "$tmp_manifest" "$jq_err_file"
        return 1
    }
    rm -f "$jq_err_file"
    if [[ ! -s "$tmp_manifest" ]]; then
        echo "ERROR: refinalize_trace: jq produced empty manifest for trace $trace_id — not replacing" >&2
        rm -f "$tmp_manifest"
        return 1
    fi
    mv "$tmp_manifest" "$manifest"

    return 0
}

# Scan all traces and re-finalize those with stale data (test_result=unknown,
# files_changed=0, or duration_seconds<=0). Optionally limit to traces started
# within max_age_hours (skip older traces to bound runtime).
#
# Usage: refinalize_stale_traces [max_age_hours]
# Prints: count of traces updated to stdout
# Returns: 0 always
refinalize_stale_traces() {
    local max_age_hours="${1:-}"
    local updated=0
    local now_epoch
    now_epoch=$(date -u +%s)

    for manifest in "${TRACE_STORE}"/*/manifest.json; do
        [[ ! -f "$manifest" ]] && continue

        # Check staleness criteria
        local tr fc dur
        tr=$(jq -r '.test_result // "unknown"' "$manifest" 2>/dev/null)
        fc=$(jq -r '.files_changed // 0' "$manifest" 2>/dev/null)
        dur=$(jq -r '.duration_seconds // 0' "$manifest" 2>/dev/null)

        local is_stale=false
        [[ "$tr" == "unknown" ]] && is_stale=true
        [[ "$fc" -eq 0 ]] && is_stale=true
        [[ "$dur" -le 0 ]] && is_stale=true

        if ! $is_stale; then
            continue
        fi

        # If max_age_hours provided, skip traces older than the threshold
        if [[ -n "$max_age_hours" ]]; then
            local started_at
            started_at=$(jq -r '.started_at // empty' "$manifest" 2>/dev/null)
            if [[ -n "$started_at" ]]; then
                local start_epoch
                start_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_at" +%s 2>/dev/null \
                    || date -u -d "$started_at" +%s 2>/dev/null \
                    || echo "0")
                if [[ "$start_epoch" -gt 0 ]]; then
                    local age_hours=$(( (now_epoch - start_epoch) / 3600 ))
                    if [[ "$age_hours" -gt "$max_age_hours" ]]; then
                        continue
                    fi
                fi
            fi
        fi

        local trace_id
        trace_id=$(jq -r '.trace_id // empty' "$manifest" 2>/dev/null)
        [[ -z "$trace_id" ]] && continue

        if refinalize_trace "$trace_id"; then
            updated=$(( updated + 1 ))
        fi
    done

    echo "$updated"
    return 0
}

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

# Export for subshells
export TRACE_STORE SOURCE_EXTENSIONS DECISION_LINE_THRESHOLD TEST_STALENESS_THRESHOLD SESSION_STALENESS_THRESHOLD
export -f get_git_state get_plan_status get_session_changes get_drift_data get_research_status is_source_file is_skippable_path is_test_file read_test_status validate_state_file atomic_write append_audit write_statusline_cache track_subagent_start track_subagent_stop get_subagent_status safe_cleanup archive_plan init_trace detect_active_trace finalize_trace index_trace refinalize_trace refinalize_stale_traces rebuild_index is_claude_meta_repo append_session_event get_session_trajectory get_session_summary_context build_resume_directive get_prior_sessions backup_trace_manifests check_trace_count_canary
