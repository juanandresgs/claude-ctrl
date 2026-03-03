#!/usr/bin/env bash
# Structured JSON logging helper for Claude Code hooks.
# Source this file from other hooks: source "$(dirname "$0")/log.sh"
#
# Provides:
#   log_json <stage> <message>  - Print structured JSON to stderr
#   log_info <stage> <message>  - Print human-readable info to stderr
#   read_input                  - Read and cache stdin JSON (sets HOOK_INPUT)
#   get_field <jq_path>         - Extract field from cached input
#   detect_project_root         - Find git root or fall back to CLAUDE_PROJECT_DIR
#   get_claude_dir              - Get .claude directory path (handles ~/.claude special case)
#   resolve_proof_file          - Resolve the active .proof-status path (worktree-aware)
#   write_proof_status          - Atomic write to all 3 proof-status paths (worktree, project-scoped, legacy)
#
# All output goes to stderr so it doesn't interfere with hook JSON output.
#
# @decision DEC-LOG-001
# @title Shared logging and path utilities for all hooks
# @status accepted
# @rationale Centralized helper functions prevent duplication and ensure consistent
#   behavior across all hooks. get_claude_dir() fixes #77 double-nesting bug.
#   detect_project_root() includes #34 deleted CWD recovery.
#   resolve_proof_file() fixes the worktree proof-status mismatch (#proof-path).
#   project_hash() and scoped state files fix cross-project contamination (#isolation).
#
# @decision DEC-PROOF-PATH-002
# @title resolve_proof_file: breadcrumb-based worktree proof-status resolution
# @status accepted
# @rationale When orchestrator runs from ~/.claude and dispatches agents to a git
#   worktree, .proof-status files end up in two locations: the orchestrator's
#   CLAUDE_DIR and the worktree's .claude/. The breadcrumb file
#   .active-worktree-path (written by task-track.sh at implementer dispatch)
#   lets hooks find the active path without scanning all worktrees. Resolution
#   logic: if breadcrumb exists AND worktree .proof-status is in pending,
#   verified, or needs-verification state → return worktree path; otherwise
#   return CLAUDE_DIR path. Stale breadcrumbs (deleted worktree) fall back to
#   CLAUDE_DIR safely. needs-verification added in W4-2 (Issue #41) so that
#   implementer-dispatched worktrees resolve correctly through the full proof
#   lifecycle (needs-verification → pending → verified).
#
# @decision DEC-ISOLATION-001
# @title Project-scoped state files via 8-char hash suffix
# @status accepted
# @rationale State files (.proof-status, .active-worktree-path, .active-*-* markers)
#   are global and contaminate subsequent sessions on different projects. Appending
#   an 8-char SHA-256 hash of project_root to each file name scopes it to one project.
#   Reads check scoped file first, fall back to unscoped for backward compatibility.
#   Writes always go to scoped files. Cleanup removes both scoped and unscoped.

# Cache stdin so multiple functions can read it
HOOK_INPUT=""

read_input() {
    if [[ -z "$HOOK_INPUT" ]]; then
        HOOK_INPUT=$(cat)
    fi
    echo "$HOOK_INPUT"
}

get_field() {
    local path="$1"
    echo "$HOOK_INPUT" | jq -r "$path // empty" 2>/dev/null
}

log_json() {
    local stage="$1"
    local message="$2"
    echo "{\"stage\":\"$stage\",\"message\":\"$message\"}" >&2
}

log_info() {
    local stage="$1"
    local message="$2"
    echo "[$stage] $message" >&2
}

detect_project_root() {
    # Check if CWD still exists — recover if deleted (Fix #34)
    if [[ ! -d "$PWD" ]]; then
        cd "${HOME}" 2>/dev/null || cd / 2>/dev/null
        echo "WARNING: CWD was deleted, recovered to $(pwd)" >&2
    fi

    # Prefer CLAUDE_PROJECT_DIR if set and valid
    if [[ -n "${CLAUDE_PROJECT_DIR:-}" && -d "${CLAUDE_PROJECT_DIR}" ]]; then
        echo "$CLAUDE_PROJECT_DIR"
        return
    fi
    # Anchor from hook input .cwd when $PWD diverges from session context.
    # Prevents phash mismatch between hooks (e.g., prompt-submit.sh vs task-track.sh).
    # .cwd is Claude Code's authoritative working directory for the hook invocation.
    # Cache result in CLAUDE_PROJECT_DIR so subsequent calls within the same
    # hook execution hit the fast path above.
    if [[ -n "${HOOK_INPUT:-}" ]]; then
        local _hook_cwd
        _hook_cwd=$(echo "$HOOK_INPUT" | jq -r '.cwd // empty' 2>/dev/null)
        if [[ -n "$_hook_cwd" && -d "$_hook_cwd" ]]; then
            local _hook_root
            _hook_root=$(git -C "$_hook_cwd" rev-parse --show-toplevel 2>/dev/null || echo "")
            if [[ -n "$_hook_root" && -d "$_hook_root" ]]; then
                export CLAUDE_PROJECT_DIR="$_hook_root"
                echo "$_hook_root"
                return
            fi
            export CLAUDE_PROJECT_DIR="$_hook_cwd"
            echo "$_hook_cwd"
            return
        fi
    fi

    # Check if CWD is valid before using git
    if [[ -d "$PWD" ]]; then
        local root
        root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
        if [[ -n "$root" && -d "$root" ]]; then
            echo "$root"
            return
        fi
    fi
    # Last resort: fall back to HOME
    echo "${HOME:-/}"
}

# @decision DEC-QUICKFIX-001
# @title Fix double-nested paths when PROJECT_ROOT is ~/.claude
# @status accepted
# @rationale When PROJECT_ROOT is ~/.claude, using ${PROJECT_ROOT}/.claude/ produces
#   ~/.claude/.claude/ which breaks state file paths. This helper returns the correct
#   .claude directory: PROJECT_ROOT/.claude for normal projects, PROJECT_ROOT for ~/.claude.
#   Fixes #77.
get_claude_dir() {
    local project_root="${PROJECT_ROOT:-$(detect_project_root)}"
    local home_claude="${HOME}/.claude"

    # If PROJECT_ROOT is already ~/.claude, return it as-is (don't double-nest)
    if [[ "$project_root" == "$home_claude" ]]; then
        echo "$project_root"
    else
        echo "${project_root}/.claude"
    fi
}

# project_hash — compute deterministic 8-char hash of a project root path.
# Usage: project_hash "/path/to/project"
# Returns: 8-character hex string, consistent across calls for the same input.
project_hash() {
    echo "${1:?project_hash requires a path argument}" | shasum -a 256 | cut -c1-8
}

# resolve_proof_file — return the active .proof-status path for the current context.
#
# In non-worktree scenarios (no breadcrumb): returns CLAUDE_DIR/.proof-status-{phash}
# (falls back to .proof-status for backward compat with pre-migration state).
# In worktree scenarios: reads breadcrumb in this priority order:
#   1. Session-scoped: .active-worktree-path-{session_id}-{phash}  (highest priority)
#   2. Project-scoped: .active-worktree-path-{phash}               (backward compat)
#   3. Legacy:         .active-worktree-path                        (oldest format)
# If the breadcrumb exists and the worktree has a .proof-status in "pending",
# "verified", or "needs-verification" state, returns the worktree path.
# Stale breadcrumbs (deleted worktree) fall back to CLAUDE_DIR.
#
# Callers that write "verified" should also dual-write to the orchestrator's
# copy so guard.sh can find it regardless of which path it checks.
#
# @decision DEC-SESSION-BREADCRUMB-001
# @title Session-scoped breadcrumb priority in resolve_proof_file()
# @status accepted
# @rationale When multiple Claude sessions run concurrently (e.g., two worktrees),
#   the project-scoped breadcrumb (.active-worktree-path-{phash}) is last-write-wins.
#   Session N's breadcrumb can point to session M's worktree, causing resolve_proof_file
#   to read the WRONG .proof-status file. The root cause of the stale breadcrumb
#   incident (#91): task-track.sh for one session overwrote the shared breadcrumb,
#   making subsequent resolve calls resolve to test-health-audit instead of the active
#   feature worktree. Session-scoped breadcrumbs (.active-worktree-path-{session}-{phash})
#   give each session a private slot, eliminating cross-session contamination.
#   The fallback chain preserves backward compatibility with hooks that only write
#   project-scoped breadcrumbs. Issue #98.
resolve_proof_file() {
    local claude_dir="${CLAUDE_DIR:-$(get_claude_dir)}"
    local project_root="${PROJECT_ROOT:-$(detect_project_root)}"
    local phash
    phash=$(project_hash "$project_root")
    local session_id="${CLAUDE_SESSION_ID:-}"
    local session_breadcrumb=""
    [[ -n "$session_id" ]] && session_breadcrumb="$claude_dir/.active-worktree-path-${session_id}-${phash}"
    local scoped_breadcrumb="$claude_dir/.active-worktree-path-${phash}"
    local legacy_breadcrumb="$claude_dir/.active-worktree-path"
    local scoped_proof="$claude_dir/.proof-status-${phash}"
    local default_proof="$claude_dir/.proof-status"

    # Try each breadcrumb in priority order, cascading on stale targets.
    # A breadcrumb is "stale" if its target directory no longer exists.
    # On stale, continue to the next breadcrumb rather than immediately falling
    # back to scoped proof — this lets a valid project-scoped breadcrumb serve
    # as a fallback when the session-scoped breadcrumb is stale.
    #
    # Candidate list: session-scoped > project-scoped > legacy
    local _candidates=()
    [[ -n "$session_breadcrumb" && -f "$session_breadcrumb" ]] && _candidates+=("$session_breadcrumb")
    [[ -f "$scoped_breadcrumb" ]] && _candidates+=("$scoped_breadcrumb")
    [[ -f "$legacy_breadcrumb" ]] && _candidates+=("$legacy_breadcrumb")

    # No breadcrumb at all — standard (non-worktree) path
    if [[ ${#_candidates[@]} -eq 0 ]]; then
        if [[ -f "$scoped_proof" ]]; then
            echo "$scoped_proof"
        elif [[ -f "$default_proof" ]]; then
            echo "$default_proof"
        else
            echo "$scoped_proof"
        fi
        return
    fi

    # Walk candidates; return on first live worktree with active proof
    for _bc in "${_candidates[@]}"; do
        local worktree_path
        worktree_path=$(cat "$_bc" 2>/dev/null | tr -d '[:space:]')

        # Empty or stale breadcrumb: try next candidate
        [[ -z "$worktree_path" || ! -d "$worktree_path" ]] && continue

        local worktree_proof="$worktree_path/.claude/.proof-status"

        # Check if worktree has an active proof-status (pending, verified, or needs-verification)
        # needs-verification is written by task-track.sh at implementer dispatch — it must resolve
        # to the worktree path so check-tester.sh reads/writes the correct file. Previously, only
        # "pending" and "verified" were accepted, causing needs-verification to fall through to the
        # scoped (orchestrator) file. This caused the dedup guard in check-tester.sh to fire when
        # the scoped file had stale "verified" from a prior test or session. (Fix: W4-2, Issue #41)
        if [[ -f "$worktree_proof" ]]; then
            local wt_status
            wt_status=$(cut -d'|' -f1 "$worktree_proof" 2>/dev/null || echo "")
            if [[ "$wt_status" == "pending" || "$wt_status" == "verified" || "$wt_status" == "needs-verification" ]]; then
                echo "$worktree_proof"
                return
            fi
        fi

        # Worktree exists but has no active proof — return scoped fallback immediately
        # (no need to check further breadcrumbs; the active worktree is found but
        # the proof was not written there yet — use orchestrator's path)
        if [[ -f "$scoped_proof" ]]; then
            echo "$scoped_proof"
        elif [[ -f "$default_proof" ]]; then
            echo "$default_proof"
        else
            echo "$scoped_proof"
        fi
        return
    done

    # All breadcrumbs were stale or empty — fall back to orchestrator's scoped path
    if [[ -f "$scoped_proof" ]]; then
        echo "$scoped_proof"
    elif [[ -f "$default_proof" ]]; then
        echo "$default_proof"
    else
        echo "$scoped_proof"
    fi
}

# write_proof_status — atomically write a proof status to all 3 proof-status paths.
#
# Usage: write_proof_status <status> [project_root]
#
# Writes "status|timestamp" to:
#   1. Scoped: CLAUDE_DIR/.proof-status-{phash}  (primary — project-isolated)
#   2. Legacy: CLAUDE_DIR/.proof-status           (backward compat for older hooks)
#   3. Worktree: worktree_path/.claude/.proof-status
#      (only when breadcrumb .active-worktree-path-{phash} or .active-worktree-path
#       exists and points to a valid directory)
#
# Enforces a monotonic status lattice: none → needs-verification → pending → verified → committed.
# Rejects regressions (e.g., verified → pending) unless .proof-epoch exists and is newer
# than the current .proof-status (epoch reset). All 3 writes are serialized under flock.
#
# @decision DEC-LOG-002
# @title write_proof_status: atomic multi-path proof status writer
# @status accepted
# @rationale prompt-submit.sh, check-tester.sh, and post-task.sh all need to write
#   "verified" status but previously called write_proof_status which was never defined.
#   The function mirrors resolve_proof_file's breadcrumb-resolution logic for reads,
#   extended to write all three locations so guard.sh and task-track.sh can find the
#   status regardless of which path they check. Atomic write via tmp file prevents
#   partial reads under concurrent hook execution.
#
# @decision DEC-PROOF-LOCK-001
# @title Single flock around all 3 writes in write_proof_status()
# @status accepted
# @rationale The previous implementation wrote to 3 files sequentially without a lock.
#   If a hook crashed between writes, the files would be in inconsistent states (e.g.,
#   scoped file = "verified" but worktree file = "pending"). A single flock(1) on
#   .proof-status.lock serializes all callers and eliminates the crash window. The
#   5-second timeout matches state_update(); on timeout, the function returns 1 (the
#   status transition is rejected rather than silently skipped, since this IS authoritative).
#
# @decision DEC-PROOF-LATTICE-001
# @title Monotonic status lattice enforcement in write_proof_status()
# @status accepted
# @rationale Regressions (e.g., verified → pending) can happen when post-write.sh
#   fires during Guardian's commit workflow if the guardian marker is missing. Enforcing
#   a strict ordinal map prevents status regression without an explicit epoch reset.
#   Epoch reset is supported via .proof-epoch: if this file exists and is NEWER than
#   the current .proof-status, the lattice is bypassed and any status is accepted.
#   This allows deliberate resets (e.g., starting a new verification cycle) while
#   preventing accidental regressions from race conditions.
write_proof_status() {
    local proof_status="${1:?write_proof_status requires a status argument}"
    local project_root="${2:-${PROJECT_ROOT:-$(detect_project_root)}}"
    local claude_dir
    claude_dir=$(PROJECT_ROOT="$project_root" get_claude_dir)
    local phash
    phash=$(project_hash "$project_root")
    local lockfile="${claude_dir}/.proof-status.lock"

    mkdir -p "$claude_dir" 2>/dev/null || return 1

    local _result=0
    (
        # Use _portable_flock if available (sourced via source-lib.sh → core-lib.sh),
        # fall back to bare flock, then proceed unlocked (tests source log.sh directly).
        local _lock_ok=true
        if type _portable_flock &>/dev/null; then
            _portable_flock 5 9 || _lock_ok=false
        elif command -v flock &>/dev/null; then
            flock -w 5 9 || _lock_ok=false
        fi
        if [[ "$_lock_ok" == "false" ]]; then
            log_info "write_proof_status" "lock timeout for '${proof_status}' — status transition rejected" 2>/dev/null || true; exit 1
        fi

        local timestamp
        timestamp=$(date +%s)
        local content="${proof_status}|${timestamp}"

        # --- Monotonic lattice enforcement ---
        # Ordinal map: none < needs-verification < pending < verified < committed
        # Use case statement instead of declare -A for bash 3 (macOS) compatibility.
        # declare -A fails on bash 3.2 (macOS default), causing the subshell to exit
        # under set -e before writing the status file. The case-based helper avoids this.
        #
        # @decision DEC-BASH32-001
        # @title Replace declare -A with case function for bash 3.2 compatibility
        # @status accepted
        # @rationale macOS ships bash 3.2 which does not support associative arrays
        #   (declare -A). The previous implementation used declare -A STATUS_ORDINAL
        #   which silently fails on bash 3.2 — STATUS_ORDINAL becomes an empty regular
        #   variable, all ordinal lookups return 0, and the lattice enforcement never
        #   blocks regressions. The case-based _proof_ordinal() function is POSIX-
        #   compatible and works identically on bash 3.2 and bash 4+. This was the
        #   root cause of the proof-status gate failure during the statusline-banner
        #   merge (#91): the user's "approved" was detected by prompt-submit.sh, but
        #   write_proof_status() silently failed to enforce the lattice, making
        #   "verified" unwritable because the regression check passed with ordinal 0=0.
        #   Issue #97.
        _proof_ordinal() {
            case "$1" in
                none)                 echo 0 ;;
                needs-verification)   echo 1 ;;
                pending)              echo 2 ;;
                verified)             echo 3 ;;
                committed)            echo 4 ;;
                *)                    echo 0 ;;
            esac
        }
        local scoped_proof="${claude_dir}/.proof-status-${phash}"
        local legacy_proof="${claude_dir}/.proof-status"

        # Read current status from scoped proof (prefer) or legacy
        local current="none"
        if [[ -f "$scoped_proof" ]]; then
            current=$(cut -d'|' -f1 "$scoped_proof" 2>/dev/null || echo "none")
        elif [[ -f "$legacy_proof" ]]; then
            current=$(cut -d'|' -f1 "$legacy_proof" 2>/dev/null || echo "none")
        fi
        [[ -z "$current" ]] && current="none"

        local current_ord
        current_ord=$(_proof_ordinal "$current")
        local new_ord
        new_ord=$(_proof_ordinal "$proof_status")

        if (( new_ord < current_ord )); then
            # Check for epoch reset: .proof-epoch newer than .proof-status
            local epoch_file="${claude_dir}/.proof-epoch"
            local proof_file_for_cmp="${scoped_proof}"
            [[ ! -f "$proof_file_for_cmp" ]] && proof_file_for_cmp="$legacy_proof"

            local allow_reset=false
            if [[ -f "$epoch_file" && -f "$proof_file_for_cmp" ]]; then
                # On macOS: stat -f %m; on Linux: stat -c %Y
                local epoch_mtime proof_mtime
                if [[ "$(uname)" == "Darwin" ]]; then
                    epoch_mtime=$(stat -f %m "$epoch_file" 2>/dev/null || echo "0")
                    proof_mtime=$(stat -f %m "$proof_file_for_cmp" 2>/dev/null || echo "1")
                else
                    epoch_mtime=$(stat -c %Y "$epoch_file" 2>/dev/null || echo "0")
                    proof_mtime=$(stat -c %Y "$proof_file_for_cmp" 2>/dev/null || echo "1")
                fi
                if [[ "$epoch_mtime" -gt "$proof_mtime" ]]; then
                    allow_reset=true
                fi
            fi

            if [[ "$allow_reset" == "false" ]]; then
                log_info "write_proof_status" "rejecting regression ${current} → ${proof_status} (ordinals: ${current_ord} → ${new_ord})" 2>/dev/null || true
                exit 1
            fi
            log_info "write_proof_status" "epoch reset allowed: ${current} → ${proof_status}" 2>/dev/null || true
        fi

        # --- Write all 3 proof-status paths inside the lock ---

        # 1. Scoped proof-status file (primary)
        mkdir -p "$(dirname "$scoped_proof")"
        printf '%s\n' "$content" > "${scoped_proof}.tmp" && mv "${scoped_proof}.tmp" "$scoped_proof"

        # 2. Legacy proof-status file (backward compat)
        printf '%s\n' "$content" > "${legacy_proof}.tmp" && mv "${legacy_proof}.tmp" "$legacy_proof"

        # 3. Worktree proof-status file (if breadcrumb exists and points to a valid dir)
        # Use session-scoped breadcrumb as highest priority to avoid cross-session
        # contamination (see DEC-SESSION-BREADCRUMB-001 in resolve_proof_file).
        local _session_id="${CLAUDE_SESSION_ID:-}"
        local _session_bc=""
        [[ -n "$_session_id" ]] && _session_bc="${claude_dir}/.active-worktree-path-${_session_id}-${phash}"
        local scoped_breadcrumb="${claude_dir}/.active-worktree-path-${phash}"
        local legacy_breadcrumb="${claude_dir}/.active-worktree-path"
        local breadcrumb=""
        if [[ -n "$_session_bc" && -f "$_session_bc" ]]; then
            breadcrumb="$_session_bc"
        elif [[ -f "$scoped_breadcrumb" ]]; then
            breadcrumb="$scoped_breadcrumb"
        elif [[ -f "$legacy_breadcrumb" ]]; then
            breadcrumb="$legacy_breadcrumb"
        fi

        if [[ -n "$breadcrumb" ]]; then
            local worktree_path
            worktree_path=$(cat "$breadcrumb" 2>/dev/null | tr -d '[:space:]')
            if [[ -n "$worktree_path" && -d "$worktree_path" ]]; then
                local worktree_claude="${worktree_path}/.claude"
                mkdir -p "$worktree_claude"
                local worktree_proof="${worktree_claude}/.proof-status"
                printf '%s\n' "$content" > "${worktree_proof}.tmp" && mv "${worktree_proof}.tmp" "$worktree_proof"
            fi
        fi

        # Pre-create guardian marker to close proof-invalidation window.
        # Between verification and Guardian dispatch, any source file Write/Edit
        # triggers post-write.sh which resets verified→pending when no marker exists.
        # This marker uses "pre-verified|<epoch>" format — post-write.sh's TTL check
        # accepts it. task-track.sh overwrites with "pre-dispatch|<epoch>" at dispatch.
        # finalize_trace() cleans all .active-guardian-* markers via wildcard.
        if [[ "$proof_status" == "verified" ]]; then
            local trace_store="${TRACE_STORE:-$HOME/.claude/traces}"
            local session="${CLAUDE_SESSION_ID:-$$}"
            echo "pre-verified|${timestamp}" > "${trace_store}/.active-guardian-${session}-${phash}" 2>/dev/null || true
        fi

        log_info "write_proof_status" "Wrote '${proof_status}' to proof-status paths for project $(basename "$project_root") [${phash}]"

        # Dual-write to state.json (audit/coordination layer)
        type state_update &>/dev/null && state_update ".proof.status" "$proof_status" "write_proof_status" || true
    ) 9>"$lockfile"
    _result=$?
    return $_result
}

# Export for subshells
export -f log_json log_info read_input get_field detect_project_root get_claude_dir project_hash resolve_proof_file write_proof_status
