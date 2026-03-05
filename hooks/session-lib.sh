#!/usr/bin/env bash
# session-lib.sh — Session state, trajectory, and agent tracking for Claude Code hooks.
#
# Loaded on demand via: require_session (defined in source-lib.sh)
# Depends on: core-lib.sh (always loaded first)
# Cross-domain: build_resume_directive calls get_git_state (git-lib) and
#   get_plan_status (plan-lib) — explicit require_* calls are made at the top
#   of build_resume_directive to ensure those libraries are available.
#
# @decision DEC-SPLIT-001 (see core-lib.sh for full rationale)
#
# Provides:
#   append_session_event    - Append JSONL event to session event log
#   detect_approach_pivots  - Detect edit->fail->edit loop patterns
#   get_session_trajectory  - Populate TRAJ_* globals from event log
#   get_session_summary_context - Build structured session summary for commits
#   get_prior_sessions      - Read cross-session index for context injection
#   build_resume_directive  - Compute actionable resume directive from state
#   write_statusline_cache  - Write .statusline-cache-<SESSION_ID> JSON for status bar
#   track_subagent_start    - Record ACTIVE subagent entry
#   track_subagent_stop     - Convert ACTIVE to DONE for matching subagent
#   get_subagent_status     - Populate SUBAGENT_* globals from tracker file

# Guard against double-sourcing
[[ -n "${_SESSION_LIB_LOADED:-}" ]] && return 0

# --- Statusline cache writer ---
# @decision DEC-CACHE-001
# @title Statusline cache for status bar enrichment
# @status accepted
# @rationale Hooks already compute git state and subagent counts. Cache them so
# statusline.sh can render the two-line HUD without re-computing. Atomic write
# prevents a partially-written file from being read by the status bar mid-render.
# Plan phase and test status removed: statusline now sources those from stdin JSON.
write_statusline_cache() {
    local root="$1"
    local cache_file="$root/.claude/.statusline-cache-${CLAUDE_SESSION_ID:-$$}"
    mkdir -p "$root/.claude"

    # Subagent status (populates SUBAGENT_* globals)
    get_subagent_status "$root"

    # Atomic write — only git/agent state, no plan or test fields
    # @decision DEC-CACHE-003
    # @title Add todo_project, todo_global, lifetime_cost, lifetime_tokens fields to statusline cache
    # @status accepted
    # @rationale Phase 2 splits the single todo count into project-specific and global
    # counts (REQ-P0-005). Callers set TODO_PROJECT_COUNT and TODO_GLOBAL_COUNT globals
    # before calling write_statusline_cache(). lifetime_cost is the running sum of all
    # session costs from .session-cost-history (REQ-P1-001). lifetime_tokens is the
    # running sum of all session tokens from .session-token-history (DEC-LIFETIME-TOKENS-003).
    # All fields default to 0 when not set so the cache is always valid JSON.
    local tmp_cache="${cache_file}.tmp.$$"
    jq -n \
        --arg dirty "${GIT_DIRTY_COUNT:-0}" \
        --arg wt "${GIT_WT_COUNT:-0}" \
        --arg ts "$(date +%s)" \
        --arg sa_count "${SUBAGENT_ACTIVE_COUNT:-0}" \
        --arg sa_types "${SUBAGENT_ACTIVE_TYPES:-}" \
        --arg sa_total "${SUBAGENT_TOTAL_COUNT:-0}" \
        --arg todo_project "${TODO_PROJECT_COUNT:-0}" \
        --arg todo_global "${TODO_GLOBAL_COUNT:-0}" \
        --arg lifetime_cost "${LIFETIME_COST:-0}" \
        --arg lifetime_tokens "${LIFETIME_TOKENS:-0}" \
        --arg initiative "${PLAN_ACTIVE_INITIATIVE_NAME:-}" \
        --arg phase "${PLAN_IN_PROGRESS_PHASE:-}" \
        --arg active_initiatives "${PLAN_ACTIVE_INITIATIVES:-0}" \
        --arg total_phases "${PLAN_TOTAL_PHASES:-0}" \
        '{dirty:($dirty|tonumber),worktrees:($wt|tonumber),updated:($ts|tonumber),agents_active:($sa_count|tonumber),agents_types:$sa_types,agents_total:($sa_total|tonumber),todo_project:($todo_project|tonumber),todo_global:($todo_global|tonumber),lifetime_cost:($lifetime_cost|tonumber),lifetime_tokens:($lifetime_tokens|tonumber),initiative:$initiative,phase:$phase,active_initiatives:($active_initiatives|tonumber),total_phases:($total_phases|tonumber)}' \
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
    type state_update &>/dev/null && state_update ".agents.${agent_type}.status" "active" "track_subagent_start" || true
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
    type state_update &>/dev/null && state_update ".agents.${agent_type}.status" "inactive" "track_subagent_stop" || true
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
    project_hash=$(echo "$project_root" | ${_SHA256_CMD:-shasum -a 256} 2>/dev/null | cut -c1-12 || echo "")
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
    # Compute the canonical scoped proof-status path using the local claude_dir
    # and project_root already resolved above, mirroring resolve_proof_file() logic.
    # We avoid calling resolve_proof_file() directly here because it reads CLAUDE_DIR/
    # PROJECT_ROOT globals which may not match the locally-computed claude_dir when
    # build_resume_directive() is called with an explicit project_root argument (e.g., in tests).
    local _brd_phash
    _brd_phash=$(project_hash "$project_root")
    local proof_file="${claude_dir}/.proof-status-${_brd_phash}"
    if [[ -z "$RESUME_DIRECTIVE" && -f "$proof_file" ]]; then
        local proof_status
        proof_status=$(cut -d'|' -f1 "$proof_file" 2>/dev/null || echo "")
        if [[ "$proof_status" == "needs-verification" ]]; then
            RESUME_DIRECTIVE="Implementation complete but unverified. Dispatch tester."
        elif [[ "$proof_status" == "verified" ]]; then
            # Verified + dirty = ready for Guardian
            # Cross-domain call: require git-lib to be available
            # (source-lib.sh's require_git() handles idempotent loading)
            type get_git_state >/dev/null 2>&1 || { type require_git >/dev/null 2>&1 && require_git; }
            if type get_git_state >/dev/null 2>&1; then
                get_git_state "$project_root"
                if [[ "${GIT_DIRTY_COUNT:-0}" -gt 0 ]]; then
                    RESUME_DIRECTIVE="Verified implementation ready. Dispatch Guardian to commit."
                fi
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
        type get_git_state >/dev/null 2>&1 || { type require_git >/dev/null 2>&1 && require_git; }
        if type get_git_state >/dev/null 2>&1; then
            get_git_state "$project_root"
            if [[ -n "${GIT_BRANCH:-}" && "$GIT_BRANCH" != "main" && "$GIT_BRANCH" != "master" && "${GIT_DIRTY_COUNT:-0}" -gt 0 ]]; then
                RESUME_DIRECTIVE="Implementation in progress on ${GIT_BRANCH}. Continue editing."
            fi
        fi
    fi

    # --- Priority 5: On main with worktrees ---
    if [[ -z "$RESUME_DIRECTIVE" ]]; then
        type get_git_state >/dev/null 2>&1 || { type require_git >/dev/null 2>&1 && require_git; }
        if type get_git_state >/dev/null 2>&1; then
            get_git_state "$project_root"
            if [[ ("${GIT_BRANCH:-}" == "main" || "${GIT_BRANCH:-}" == "master") && "${GIT_WT_COUNT:-0}" -gt 0 ]]; then
                RESUME_DIRECTIVE="Work in worktrees. Check active worktree branches."
            fi
        fi
    fi

    # --- Fallback: Plan status ---
    if [[ -z "$RESUME_DIRECTIVE" ]]; then
        # Cross-domain call: require plan-lib
        type get_plan_status >/dev/null 2>&1 || { type require_plan >/dev/null 2>&1 && require_plan; }
        if type get_plan_status >/dev/null 2>&1; then
            get_plan_status "$project_root"
            if [[ "$PLAN_EXISTS" == "true" && "$PLAN_LIFECYCLE" == "active" ]]; then
                local phase_num=$(( PLAN_COMPLETED_PHASES + PLAN_IN_PROGRESS_PHASES ))
                [[ "$phase_num" -eq 0 ]] && phase_num=1
                RESUME_DIRECTIVE="Working on Phase ${phase_num}/${PLAN_TOTAL_PHASES}. Check plan for next steps."
            fi
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

# --- Transcript token parser ---
# @decision DEC-SUBAGENT-TOKENS-001
# @title sum_transcript_tokens() parses JSONL transcripts for token accumulation
# @status accepted
# @rationale SubagentStop hooks receive the path to the agent's transcript JSONL file.
# Each line in the transcript is a JSON object that may have a .message.usage field
# containing {input_tokens, output_tokens, cache_read_input_tokens,
# cache_creation_input_tokens}. A single jq -s pass sums all four fields across all
# messages to give the complete token cost for the agent's run. This feeds
# track-agent-tokens.sh which accumulates subagent totals in a session-scoped state
# file, enabling the statusline to display main + subagent tokens as "145k (Σ240k)".
# jq -s is used (slurp mode) rather than streaming because transcripts are small
# enough to fit in memory and -s enables clean reduce/add semantics.

# sum_transcript_tokens <transcript_path>
# Parses JSONL transcript, sums all usage fields across messages.
# Outputs JSON: {"input":N,"output":N,"cache_read":N,"cache_create":N}
# Returns 1 if transcript missing or unparseable.
sum_transcript_tokens() {
    local transcript_path="$1"
    [[ -f "$transcript_path" ]] || return 1

    jq -s '[.[] | select(.message.usage) | .message.usage] |
      { input: (map(.input_tokens // 0) | add // 0),
        output: (map(.output_tokens // 0) | add // 0),
        cache_read: (map(.cache_read_input_tokens // 0) | add // 0),
        cache_create: (map(.cache_creation_input_tokens // 0) | add // 0) }' "$transcript_path" 2>/dev/null || return 1
}
export -f sum_transcript_tokens

export -f write_statusline_cache track_subagent_start track_subagent_stop get_subagent_status
export -f append_session_event get_session_trajectory get_session_summary_context
export -f get_prior_sessions build_resume_directive

_SESSION_LIB_LOADED=1
