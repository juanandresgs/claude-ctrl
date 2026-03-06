#!/usr/bin/env bash
# trace-lib.sh — Agent trace protocol utilities for Claude Code hooks.
#
# Loaded on demand via: require_trace (defined in source-lib.sh)
# Depends on: core-lib.sh (must be loaded first; uses project_hash, append_audit)
#
# @decision DEC-SPLIT-001 (see core-lib.sh for full rationale)
#
# Provides:
#   init_trace            - Initialize a trace directory for a new agent run
#   detect_active_trace   - Find active trace for current session/agent
#   finalize_trace        - Seal trace manifest with metrics, clean markers
#   index_trace           - Append compact JSON line to trace index
#   rebuild_index         - Rebuild index.jsonl from scratch
#   backup_trace_manifests - Periodic compressed backup of trace manifests
#   check_trace_count_canary - Session-start trace count canary for data loss detection

# Guard against double-sourcing
[[ -n "${_TRACE_LIB_LOADED:-}" ]] && return 0

_TRACE_LIB_VERSION=1

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
    hash=$(echo "${session_id}" | ${_SHA256_CMD:-shasum -a 256} 2>/dev/null | cut -c1-6)
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

    # Clean up stale .active-* markers older than 30 minutes
    # @decision DEC-OBS-020
    # @title Age-based cleanup of orphaned .active-* markers
    # @status accepted
    # @rationale Agents that crash leave behind .active-* markers that can
    #             cause false "agent already running" blocks. Cleaning markers
    #             older than 30 minutes on every init_trace() call is safe because
    #             no legitimate agent runs for more than 30 minutes (max_turns
    #             enforcement caps all agents). Reduced from 2 hours to 30 minutes
    #             to detect stuck/crashed agents faster and recover sooner.
    local stale_threshold=1800  # 30 minutes in seconds
    local now_epoch
    now_epoch=$(date +%s)
    for marker in "${TRACE_STORE}/.active-"*; do
        [[ -f "$marker" ]] || continue
        local marker_mtime
        marker_mtime=$(_file_mtime "$marker")
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

        # Tertiary path: iterate all markers for this agent type (capped at 5).
        # Validate both session_id AND project from manifest.
        local candidate
        local _tertiary_count=0
        for candidate in "${TRACE_STORE}/.active-${agent_type}-"*; do
            [[ -f "$candidate" ]] || continue
            (( _tertiary_count++ >= 5 )) && break
            local candidate_trace_id
            candidate_trace_id=$(cat "$candidate" 2>/dev/null) || continue
            [[ -n "$candidate_trace_id" ]] || continue
            local candidate_manifest="${TRACE_STORE}/${candidate_trace_id}/manifest.json"
            [[ -f "$candidate_manifest" ]] || continue
            local manifest_session manifest_project _combined
            _combined=$(jq -r '[.session_id, .project] | @tsv' "$candidate_manifest" 2>/dev/null) || continue
            IFS=$'\t' read -r manifest_session manifest_project <<< "$_combined"
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
    echo "WARNING: detect_active_trace: CLAUDE_SESSION_ID not set — using glob fallback with project validation" >&2
    # @decision DEC-TRACE-GLOB-001
    # @title Use stat-sorted glob instead of ls -t for active marker iteration
    # @status accepted
    # @rationale SC2045: iterating over ls output is fragile. Collect markers via glob
    #   (safe, no word-split), sort by mtime using stat, then iterate. This preserves
    #   the recency-first ordering that ls -t provided while avoiding shellcheck violation.
    local mf_path
    local _markers=()
    for mf_path in "${TRACE_STORE}/.active-${agent_type}-"*; do
        [[ -f "$mf_path" ]] && _markers+=("$mf_path")
    done
    if [[ ${#_markers[@]} -gt 0 ]]; then
        # @decision DEC-STAT-COMPAT-001
        # @title Use stat -c (GNU/Linux) first, stat -f (BSD/macOS) as fallback
        # @status accepted
        # @rationale On Linux, `stat -f "%m"` means "filesystem status" and returns
        #   hex metadata (like "ef53"), not file mtime. It succeeds (exit 0) so the
        #   || fallback never fires. Using `stat -c "%Y"` first is correct because
        #   -c is not a valid option on macOS BSD stat (fails immediately), allowing
        #   the fallback to `stat -f "%m"` (correct on macOS). Fixes CI failures
        #   in test-trace-classification.sh and test-validation-harness.sh.
        local _sorted_marker
        while IFS= read -r _sorted_marker; do
            [[ -f "$_sorted_marker" ]] || continue
            local fallback_trace_id
            fallback_trace_id=$(cat "$_sorted_marker" 2>/dev/null)
            [[ -n "$fallback_trace_id" ]] || continue
            local fallback_manifest="${TRACE_STORE}/${fallback_trace_id}/manifest.json"
            [[ -f "$fallback_manifest" ]] || continue
            local fb_project
            fb_project=$(jq -r '.project // empty' "$fallback_manifest" 2>/dev/null)
            if [[ "$fb_project" == "$project_root" ]]; then
                echo "$fallback_trace_id"
                return 0
            fi
        done < <(for _m in "${_markers[@]}"; do
            _mt=$(stat -c "%Y" "$_m" 2>/dev/null || stat -f "%m" "$_m" 2>/dev/null || echo 0)
            printf '%s\t%s\n' "$_mt" "$_m"
        done | sort -rn | cut -f2- | head -5)
    fi

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
    # Use the canonical scoped proof-status path via resolve_proof_file().
    # This is always accessible from all agents regardless of worktree because
    # CLAUDE_DIR (~/.claude) is shared. No fallback needed — scoped file IS canonical truth.
    local proof_status="unknown"
    local proof_file
    proof_file=$(resolve_proof_file)
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
    #
    # @decision DEC-OBS-OUTCOME-002
    # @title Agent-type-aware outcome classification
    # @status accepted
    # @rationale Non-implementer agents (guardian, tester, planner) don't run test suites,
    #   so test_result is always "not-provided" for them — making the generic classification
    #   produce "timeout" or "partial" even on successful runs. Agent-specific signals
    #   provide accurate outcome detection:
    #   - Guardian: HEAD SHA change from start → success; no change but no errors → partial;
    #     conflict/rejection markers in summary → failure
    #   - Tester: AUTOVERIFY: CLEAN in summary → success; summary present but no AUTOVERIFY
    #     → partial; verification-output.txt missing → partial
    #   - Planner: MASTER_PLAN.md modification detected → success; summary present but no
    #     plan change → partial; long duration with no summary → timeout
    #   - Implementer: falls through to the original test_result-based classification
    local outcome="unknown"

    if [[ "$agent_type" == "guardian" ]]; then
        # Guardian success: HEAD SHA changed (commit occurred)
        # Check CLAUDE_DIR env var first (set by production hooks), then derive from project.
        # Using two locations handles both production (CLAUDE_DIR set) and test environments
        # (CLAUDE_DIR may be a test-scoped temp dir).
        local _claude_dir_local="${CLAUDE_DIR:-}"
        [[ -z "$_claude_dir_local" ]] && _claude_dir_local="${project_root}/.claude"
        local _start_sha_file="${_claude_dir_local}/.guardian-start-sha"
        local _current_sha=""
        local _start_sha=""
        _current_sha=$(git -C "$project_root" rev-parse HEAD 2>/dev/null || echo "")
        # start-sha file is cleaned by check-guardian.sh after comparison; read if present
        [[ -f "$_start_sha_file" ]] && _start_sha=$(cat "$_start_sha_file" 2>/dev/null || echo "")
        local _summary_text=""
        [[ -f "${trace_dir}/summary.md" ]] && _summary_text=$(cat "${trace_dir}/summary.md" 2>/dev/null || echo "")
        if [[ -n "$_current_sha" && -n "$_start_sha" && "$_current_sha" != "$_start_sha" ]]; then
            outcome="success"
        elif echo "$_summary_text" | grep -qiE 'merge conflict|rejected by guard|guard denied|CONFLICT'; then
            outcome="failure"
        elif [[ -n "$_summary_text" && ${#_summary_text} -gt 50 ]]; then
            outcome="partial"
        elif [[ "$duration" -gt 600 ]]; then
            outcome="timeout"
        elif [[ ! -d "${trace_dir}/artifacts" ]] || [[ -z "$(ls -A "${trace_dir}/artifacts" 2>/dev/null)" ]]; then
            outcome="skipped"
        else
            outcome="partial"
        fi
    elif [[ "$agent_type" == "tester" ]]; then
        # Tester success: AUTOVERIFY: CLEAN in summary (high confidence verification)
        local _tester_summary=""
        [[ -f "${trace_dir}/summary.md" ]] && _tester_summary=$(cat "${trace_dir}/summary.md" 2>/dev/null || echo "")
        if echo "$_tester_summary" | grep -q 'AUTOVERIFY: CLEAN'; then
            outcome="success"
        elif [[ -n "$_tester_summary" && ${#_tester_summary} -gt 50 ]]; then
            # Tester ran but didn't produce high-confidence verification
            outcome="partial"
        elif [[ "$duration" -gt 600 ]]; then
            outcome="timeout"
        elif [[ ! -d "${trace_dir}/artifacts" ]] || [[ -z "$(ls -A "${trace_dir}/artifacts" 2>/dev/null)" ]]; then
            outcome="skipped"
        else
            outcome="partial"
        fi
    elif [[ "$agent_type" == "planner" ]]; then
        # Planner success: MASTER_PLAN.md was modified during this trace window
        local _plan_path="${project_root}/MASTER_PLAN.md"
        local _plan_modified=false
        if [[ -f "$_plan_path" && -n "$started_at" ]]; then
            local _plan_mtime
            _plan_mtime=$(stat -c "%Y" "$_plan_path" 2>/dev/null || stat -f "%m" "$_plan_path" 2>/dev/null || echo 0)
            local _start_epoch_check
            _start_epoch_check=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_at" +%s 2>/dev/null \
                || date -u -d "$started_at" +%s 2>/dev/null || echo 0)
            [[ "$_plan_mtime" -gt "$_start_epoch_check" ]] && _plan_modified=true
        fi
        local _planner_summary=""
        [[ -f "${trace_dir}/summary.md" ]] && _planner_summary=$(cat "${trace_dir}/summary.md" 2>/dev/null || echo "")
        if [[ "$_plan_modified" == "true" ]]; then
            outcome="success"
        elif [[ "$duration" -gt 600 && ${#_planner_summary} -lt 50 ]]; then
            outcome="timeout"
        elif [[ -n "$_planner_summary" && ${#_planner_summary} -gt 50 ]]; then
            outcome="partial"
        elif [[ ! -d "${trace_dir}/artifacts" ]] || [[ -z "$(ls -A "${trace_dir}/artifacts" 2>/dev/null)" ]]; then
            outcome="skipped"
        else
            outcome="partial"
        fi
    else
        # Implementer and unknown agents: use test_result-based classification
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
    local archive
    archive="${store}/.manifest-backup-$(date +%Y-%m-%dT%H%M%S).tar.gz"

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

# --- Trace TTL cleanup ---
#
# @decision DEC-TRACE-TTL-001
# @title Age-based trace directory cleanup with 7-day retention
# @status accepted
# @rationale Trace directories grow unbounded as agents run. Each agent session
#   writes a new trace dir with manifests and artifacts. Without rotation, this
#   accumulates indefinitely. 7 days (604800 seconds) retains enough history for
#   the observatory to detect weekly patterns while preventing unbounded growth.
#   Called from session-end.sh once per session exit — low enough frequency to
#   avoid performance impact. Returns count of cleaned directories so callers can
#   log meaningful diagnostics without needing to introspect file system state.
#   Only non-hidden directories at depth 1 are scanned (hidden dirs are system
#   files like .active-* markers and .manifest-backup-* archives).
cleanup_stale_traces() {
    local store="${TRACE_STORE:-$HOME/.claude/traces}"
    [[ ! -d "$store" ]] && echo "0" && return 0
    local ttl_minutes=$(( 604800 / 60 ))  # 7 days in minutes
    local cleaned
    # Single find invocation replaces O(N) bash loop + per-dir stat/basename calls.
    # Benchmark: 870 dirs, ~7s bash loop → ~6ms with find.
    # -maxdepth 1: only immediate children; -not -name '.*': skip hidden dirs (markers, backups).
    # -not -name "$(basename "$store")": exclude the store root itself (find includes parent).
    # -mmin +N: modified more than N minutes ago (7-day TTL = 10080 minutes).
    # -print before -exec: counts dirs cleaned via wc -l on printed paths.
    cleaned=$(find "$store" -maxdepth 1 -type d -not -name '.*' -not -name "$(basename "$store")" -mmin +"$ttl_minutes" -print -exec rm -rf {} + 2>/dev/null | wc -l | tr -d ' ')
    echo "${cleaned:-0}"
}

export TRACE_STORE
export -f init_trace detect_active_trace finalize_trace index_trace rebuild_index
export -f backup_trace_manifests check_trace_count_canary cleanup_stale_traces

_TRACE_LIB_LOADED=1
