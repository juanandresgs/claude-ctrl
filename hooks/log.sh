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
#   resolve_proof_file          - Resolve the canonical .proof-status path (scoped to project)
#   write_proof_status          - Atomic write to canonical proof-status file
#
# All output goes to stderr so it doesn't interfere with hook JSON output.
#
# @decision DEC-LOG-001
# @title Shared logging and path utilities for all hooks
# @status accepted
# @rationale Centralized helper functions prevent duplication and ensure consistent
#   behavior across all hooks. get_claude_dir() fixes #77 double-nesting bug.
#   detect_project_root() includes #34 deleted CWD recovery.
#   resolve_proof_file() returns the single canonical scoped proof-status path.
#   project_hash() and scoped state files fix cross-project contamination (#isolation).
#
# @decision DEC-PROOF-PATH-002
# @title resolve_proof_file: breadcrumb-based worktree proof-status resolution
# @status superseded
# @rationale Superseded by DEC-PROOF-SINGLE-001. The 3-tier breadcrumb resolution
#   (scoped/legacy/worktree) introduced more bugs than it solved — the exact
#   screenshot bug (prompt-submit.sh wrote "verified" to scoped file, Gate A
#   resolved to worktree file still showing "needs-verification") was caused by
#   this logic. Single canonical path eliminates the ambiguity entirely.
#
# @decision DEC-ISOLATION-001
# @title Project-scoped state files via 8-char hash suffix
# @status accepted
# @rationale State files (.proof-status, .active-*-* markers) are global and
#   contaminate subsequent sessions on different projects. Appending an 8-char
#   SHA-256 hash of project_root to each file name scopes it to one project.
#   The canonical proof-status file is .proof-status-{phash} in CLAUDE_DIR.
#   Cleanup removes the scoped file only (no legacy fallbacks remain).

_LOG_LIB_VERSION=1

# Portable SHA-256 command — macOS has shasum, Ubuntu/Linux has sha256sum
# Both produce identical output format: "hash  filename" — cut works the same way.
if command -v shasum >/dev/null 2>&1; then
    _SHA256_CMD="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
    _SHA256_CMD="sha256sum"
else
    _SHA256_CMD="cat"  # last resort — won't hash but won't crash
fi

# Cache stdin so multiple functions can read it
HOOK_INPUT=""

# @decision DEC-SESSION-ID-001
# @title Extract session_id from Claude Code hook stdin JSON
# @status accepted
# @rationale Claude Code provides session_id in the stdin JSON to all hooks, but the
#   hooks system was referencing CLAUDE_SESSION_ID as an env var that doesn't exist.
#   Every fallback defaulted to $$ (PID, varies per hook) or "unknown". Extracting
#   session_id in read_input() — the shared stdin capture function called by all hooks —
#   ensures CLAUDE_SESSION_ID is available to every downstream function. Only sets it
#   if not already set (preserves any future native env var support).
read_input() {
    if [[ -z "$HOOK_INPUT" ]]; then
        HOOK_INPUT=$(cat)
        # Extract session_id from Claude Code's hook input JSON
        # Claude Code provides session_id in stdin to ALL hooks
        if [[ -z "${CLAUDE_SESSION_ID:-}" ]]; then
            CLAUDE_SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
            export CLAUDE_SESSION_ID
        fi
    fi
    echo "$HOOK_INPUT"
}

# @decision DEC-INIT-HOOK-001
# @title init_hook() — replace HOOK_INPUT=$(read_input) in all hooks
# @status accepted
# @rationale HOOK_INPUT=$(read_input) spawns a bash command-substitution subshell.
#   The `export CLAUDE_SESSION_ID` inside read_input() runs in that subshell and
#   NEVER propagates back to the parent shell. Every hook using
#   ${CLAUDE_SESSION_ID:-$$} falls back to $$ (PID per process), creating a
#   different cache file name per hook process.  This broke:
#     - statusline cache lifetime_tokens (DEC-LIFETIME-PERSIST-001 reads wrong file)
#     - auto-verify flow (post-task.sh session fallback requires CLAUDE_SESSION_ID)
#     - subagent tracker scoping (.subagent-tracker-$$)
#     - orchestrator SID detection
#   init_hook() reads stdin directly into HOOK_INPUT as a global variable (no
#   command substitution, no subshell) and then extracts CLAUDE_SESSION_ID in
#   the same parent shell. All hooks call `init_hook` (bare, no assignment) at
#   the top — HOOK_INPUT and CLAUDE_SESSION_ID are then available as globals.
#   read_input() is kept for backwards compatibility with any direct callers
#   (tests that exercise it directly).
init_hook() {
    if [[ -z "$HOOK_INPUT" ]]; then
        HOOK_INPUT=$(cat)
        if [[ -z "${CLAUDE_SESSION_ID:-}" && -n "$HOOK_INPUT" ]]; then
            CLAUDE_SESSION_ID=$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
            export CLAUDE_SESSION_ID
        fi
    fi
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

# @decision DEC-WORKTREE-RESOLVE-001
# @title Resolve worktree git root to main repo root
# @status accepted
# @rationale When CWD is inside a git worktree, git rev-parse --show-toplevel
#   returns the worktree path, not the main repo root. This causes project_hash()
#   to compute a different hash, breaking lifetime token sums, cache file paths,
#   and proof-status lookups. Fix: use git-common-dir (always points to main .git)
#   to derive the main working tree root. If the common dir lives inside the
#   resolved root (same repo), strip the /.git suffix to get the main root.
#   Returns input unchanged when git fails or when input is already the main root.
_resolve_to_main_worktree() {
    local _root="${1:?}"
    local _common_dir
    _common_dir=$(git -C "$_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "")
    if [[ -n "$_common_dir" ]]; then
        local _main_root="${_common_dir%/.git}"
        if [[ -d "$_main_root" && "$_main_root" != "$_root" ]]; then
            echo "$_main_root"
            return
        fi
    fi
    echo "$_root"
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
                _hook_root=$(_resolve_to_main_worktree "$_hook_root")
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
            root=$(_resolve_to_main_worktree "$root")
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

    # Normalize: strip trailing slashes to prevent comparison mismatch (#77)
    project_root="${project_root%/}"
    home_claude="${home_claude%/}"

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
    echo "${1:?project_hash requires a path argument}" | ${_SHA256_CMD:-shasum -a 256} | cut -c1-8
}

# resolve_proof_file — return the canonical .proof-status path for the current project.
#
# Returns CLAUDE_DIR/.proof-status-{phash}. This single path is accessible from all
# agents regardless of worktree because CLAUDE_DIR (~/.claude) is always shared.
# No breadcrumb resolution needed — the scoped file IS the canonical truth.
#
# @decision DEC-PROOF-SINGLE-001
# @title Single canonical proof-status file
# @status accepted
# @rationale Eliminates 3-tier resolution ambiguity (scoped/legacy/worktree).
#   The scoped file .proof-status-{phash} in CLAUDE_DIR is always accessible
#   from all agents regardless of worktree because CLAUDE_DIR (~/.claude) is
#   shared. The breadcrumb system introduced more bugs than it solved — the
#   exact screenshot bug (prompt-submit.sh wrote "verified" to scoped file,
#   Gate A resolved to worktree file still showing "needs-verification") is
#   now structurally impossible. Supersedes DEC-PROOF-PATH-002.
#
# @decision DEC-PROOF-STABLE-001
# @title resolve_proof_file: prefer CLAUDE_PROJECT_DIR for stable cross-hook phash
# @status accepted
# @rationale Each hook invocation is a separate process. HOOK_INPUT.cwd varies
#   between hooks (prompt-submit.sh gets session cwd, pre-bash.sh gets command cwd,
#   task-track.sh gets task cwd). When CLAUDE_PROJECT_DIR is not set, detect_project_root()
#   reads HOOK_INPUT.cwd and may return different paths, producing different phashes.
#   Claude Code exports CLAUDE_PROJECT_DIR to all hook processes with the canonical
#   project root for the session. Using CLAUDE_PROJECT_DIR as the first priority
#   ensures all hooks produce the same phash regardless of their invocation context.
#   Priority: CLAUDE_PROJECT_DIR > PROJECT_ROOT > detect_project_root().
#   Fixes #106 (hash mismatch between prompt-submit.sh and pre-bash.sh/task-track.sh).
resolve_proof_file() {
    local claude_dir="${CLAUDE_DIR:-$(get_claude_dir)}"
    # Use CLAUDE_PROJECT_DIR (set by Claude Code, stable across all hook processes)
    # before falling back to PROJECT_ROOT or re-detecting from HOOK_INPUT.cwd.
    local project_root="${CLAUDE_PROJECT_DIR:-${PROJECT_ROOT:-$(detect_project_root)}}"
    local phash
    phash=$(project_hash "$project_root")
    # Diagnostic: log which root was used so hash mismatches can be diagnosed
    echo "resolve_proof_file: root=${project_root} phash=${phash}" >&2

    # New path: state/{phash}/proof-status
    local new_path="${claude_dir}/state/${phash}/proof-status"
    if [[ -f "$new_path" ]]; then
        echo "$new_path"
        return 0
    fi

    # Old path: .proof-status-{phash} (migration fallback)
    local old_path="${claude_dir}/.proof-status-${phash}"
    if [[ -f "$old_path" ]]; then
        echo "$old_path"
        return 0
    fi

    # Neither exists — return new path (where new writes go)
    echo "$new_path"
}

# resolve_proof_file_for_path — return the workflow-scoped proof-status path for a file.
#
# Calls detect_workflow_id() on the file path to determine the active worktree.
# If the file is in a worktree (workflow_id != "main"), returns:
#   CLAUDE_DIR/state/{phash}/worktrees/{workflow_id}/proof-status
# For "main" or unknown, returns the standard canonical path:
#   CLAUDE_DIR/state/{phash}/proof-status
#
# Usage: proof_file=$(resolve_proof_file_for_path "$FILE_PATH")
#
# @decision DEC-V3-FIX6-001
# @title resolve_proof_file_for_path() — workflow-aware proof path resolution
# @status accepted
# @rationale Convenience wrapper that combines detect_workflow_id() with path
#   construction. Callers (post-write.sh, task-track.sh, check-tester.sh) can
#   use this instead of two-step detect+resolve. Backward compatible: non-worktree
#   paths return the existing canonical path unchanged.
resolve_proof_file_for_path() {
    local filepath="${1:-}"
    local claude_dir="${CLAUDE_DIR:-$(get_claude_dir)}"
    local project_root="${CLAUDE_PROJECT_DIR:-${PROJECT_ROOT:-$(detect_project_root)}}"
    local phash
    phash=$(project_hash "$project_root")

    # Determine workflow from file path
    local workflow_id
    # detect_workflow_id may not be loaded yet if source-lib.sh hasn't been sourced.
    # Inline the same logic here as a fallback to avoid circular dependency.
    if declare -f detect_workflow_id >/dev/null 2>&1; then
        workflow_id=$(detect_workflow_id "$filepath")
    else
        # Inline fallback (same logic as detect_workflow_id)
        if [[ "$filepath" == */.worktrees/* ]]; then
            local _after="${filepath#*/.worktrees/}"
            workflow_id="${_after%%/*}"
            [[ -z "$workflow_id" ]] && workflow_id="main"
        elif [[ -n "${WORKTREE_PATH:-}" ]]; then
            workflow_id="${WORKTREE_PATH##*/}"
            [[ -z "$workflow_id" ]] && workflow_id="main"
        else
            workflow_id="main"
        fi
    fi

    if [[ "$workflow_id" != "main" && -n "$workflow_id" ]]; then
        echo "${claude_dir}/state/${phash}/worktrees/${workflow_id}/proof-status"
    else
        # Standard canonical path (backward compatible)
        local new_path="${claude_dir}/state/${phash}/proof-status"
        local old_path="${claude_dir}/.proof-status-${phash}"
        if [[ -f "$new_path" ]]; then
            echo "$new_path"
        elif [[ -f "$old_path" ]]; then
            echo "$old_path"
        else
            echo "$new_path"
        fi
    fi
}

# write_proof_status — atomically write a proof status to the canonical proof-status file.
#
# Usage: write_proof_status <status> [project_root]
#
# Since W2-1: PRIMARY write goes to SQLite proof_state table via proof_state_set().
# DUAL-WRITE (W5-2 remove): also writes flat file for backward compatibility.
# Flat-file writes are kept for hooks not yet migrated to proof_state_get().
#
# Enforces a monotonic status lattice via proof_state_set() (SQLite enforces lattice
# with epoch reset support). The bash-side lattice check is kept as defense-in-depth.
#
# @decision DEC-LOG-002
# @title write_proof_status: atomic single-path proof status writer
# @status accepted
# @rationale prompt-submit.sh, check-tester.sh, and post-task.sh all need to write
#   "verified" status. The function writes only to the canonical scoped file
#   (.proof-status-{phash}) since all hooks share CLAUDE_DIR. Atomic write via tmp
#   file prevents partial reads under concurrent hook execution.
#   Previously wrote to 3 paths (scoped, legacy, worktree) — simplified by
#   DEC-PROOF-SINGLE-001 and DEC-PROOF-BREADCRUMB-001.
#   Since W2-1: proof_state_set() is the PRIMARY write path; flat files are dual-write.
#
# @decision DEC-PROOF-LOCK-001
# @title Single flock around the canonical write in write_proof_status()
# @status accepted
# @rationale The previous implementation wrote to 3 files sequentially without a lock.
#   A single flock(1) on .proof-status.lock serializes all callers. The 5-second
#   timeout matches state_update(); on timeout, the function returns 1 (the status
#   transition is rejected rather than silently skipped, since this IS authoritative).
#
# @decision DEC-PROOF-BREADCRUMB-001
# @title Remove breadcrumb system
# @status accepted
# @rationale CLAUDE_DIR is shared across worktrees; breadcrumbs were a bridge
#   that introduced more bugs than they solved. Single canonical path means
#   no worktree copy, no breadcrumb needed, no stale breadcrumb failures.
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
#   Since W2-1: lattice is enforced in proof_state_set() (SQLite); bash-side kept
#   as defense-in-depth for the flat-file dual-write path.
#
# @decision DEC-STATE-UNIFY-004
# @title Dual-write: proof_state_set (SQLite PRIMARY) + flat file (W5-2 remove)
# @status accepted
# @rationale During the transition period (W2-1 through W5-1), both the SQLite
#   proof_state table and the flat proof-status files are written on every status
#   change. This ensures backward compatibility: hooks not yet migrated to
#   proof_state_get() continue to read flat files without interruption. The flat-file
#   write in write_proof_status() is marked "W5-2 remove" — it will be deleted when
#   all readers have been migrated to proof_state_get(). The SQLite write is first
#   (primary) because it enforces the lattice atomically with BEGIN IMMEDIATE.
#   See MASTER_PLAN.md DEC-STATE-UNIFY-004.
write_proof_status() {
    local proof_status="${1:?write_proof_status requires a status argument}"
    local project_root="${2:-${PROJECT_ROOT:-$(detect_project_root)}}"
    local claude_dir
    claude_dir=$(PROJECT_ROOT="$project_root" get_claude_dir)
    local phash
    phash=$(project_hash "$project_root")
    # New lock path: state/locks/proof.lock
    local locks_dir="${claude_dir}/state/locks"
    mkdir -p "$locks_dir" 2>/dev/null || true
    local lockfile="${locks_dir}/proof.lock"

    mkdir -p "$claude_dir" 2>/dev/null || return 1

    # --- PRIMARY: Write to SQLite via proof_state_set() ---
    # proof_state_set() enforces the monotonic lattice atomically via BEGIN IMMEDIATE.
    # Requires state-lib.sh to be loaded (via require_state in the calling hook).
    # If proof_state_set is not available (state-lib not loaded), falls through to
    # flat-file only (backward compatible). DEC-STATE-UNIFY-004.
    if declare -f proof_state_set >/dev/null 2>&1; then
        PROJECT_ROOT="$project_root" CLAUDE_DIR="$claude_dir" \
            proof_state_set "$proof_status" "write_proof_status" 2>/dev/null || true
    fi

    local _result=0
    (
        if ! _lock_fd 5 9; then
            log_info "write_proof_status" "lock timeout — status transition rejected" 2>/dev/null || true
            exit 1
        fi

        local timestamp
        timestamp=$(date +%s)
        local content="${proof_status}|${timestamp}"

        # --- Monotonic lattice enforcement ---
        # Ordinal map: none < needs-verification < pending < verified < committed
        # Use case statement instead of declare -A for bash 3 (macOS) compatibility.
        # declare -A fails on bash 3.2 (macOS default), causing the subshell to exit
        # under set -e before writing the status file.
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

        # New canonical path: state/{phash}/proof-status
        local state_dir_path="${claude_dir}/state/${phash}"
        local new_proof="${state_dir_path}/proof-status"
        # Old path for backward compat during migration
        local old_proof="${claude_dir}/.proof-status-${phash}"

        # Read current status from NEW path first, fall back to old
        local current="none"
        if [[ -f "$new_proof" ]]; then
            current=$(cut -d'|' -f1 "$new_proof" 2>/dev/null || echo "none")
        elif [[ -f "$old_proof" ]]; then
            current=$(cut -d'|' -f1 "$old_proof" 2>/dev/null || echo "none")
        fi
        [[ -z "$current" ]] && current="none"

        local current_ord
        current_ord=$(_proof_ordinal "$current")
        local new_ord
        new_ord=$(_proof_ordinal "$proof_status")

        if (( new_ord < current_ord )); then
            # Check for epoch reset: proof-epoch newer than proof-status
            # Check new state dir location first, fall back to old dotfile
            local epoch_file="${claude_dir}/state/${phash}/proof-epoch"
            if [[ ! -f "$epoch_file" ]]; then
                epoch_file="${claude_dir}/.proof-epoch"
            fi
            # Use new_proof for comparison; fall back to old_proof if new doesn't exist
            local proof_file_for_cmp="$new_proof"
            [[ ! -f "$proof_file_for_cmp" ]] && proof_file_for_cmp="$old_proof"

            local allow_reset=false
            if [[ -f "$epoch_file" && -f "$proof_file_for_cmp" ]]; then
                local epoch_mtime proof_mtime
                epoch_mtime=$(_file_mtime "$epoch_file")
                proof_mtime=$(_file_mtime "$proof_file_for_cmp")
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

        # --- DUAL-WRITE: flat files (W5-2 remove when all readers use proof_state_get) ---
        # These writes maintain backward compatibility during the W2→W5 migration window.
        # Primary: state/{phash}/proof-status
        mkdir -p "$state_dir_path"
        printf '%s\n' "$content" > "${new_proof}.tmp" && mv "${new_proof}.tmp" "$new_proof"
        # Secondary: legacy .proof-status-{phash} (W5-2 remove)
        printf '%s\n' "$content" > "${old_proof}.tmp" && mv "${old_proof}.tmp" "$old_proof"

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

        log_info "write_proof_status" "Wrote '${proof_status}' to canonical proof-status for project $(basename "$project_root") [${phash}]"

        # W5-1: direct state_update (type guard removed; state-lib loaded by callers via require_state)
        state_update ".proof.status" "$proof_status" "write_proof_status" >/dev/null 2>/dev/null || true
        # W5-1: emit proof transition event to ledger (best-effort; stdout suppressed — state_emit outputs row ID)
        state_emit "proof.transition" "{\"to\":\"${proof_status}\",\"project\":\"${phash}\"}" >/dev/null 2>/dev/null || true
    ) 9>"$lockfile"
    _result=$?
    return $_result
}

# Export for subshells
export -f log_json log_info read_input get_field _resolve_to_main_worktree detect_project_root get_claude_dir project_hash resolve_proof_file resolve_proof_file_for_path write_proof_status
