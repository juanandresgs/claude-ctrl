#!/usr/bin/env bash
# state-lib.sh — Coordination/audit layer via state.json for Claude Code hooks.
#
# Loaded on demand via: require_state (defined in source-lib.sh)
# Depends on: log.sh (detect_project_root, get_claude_dir, log_info)
#
# Provides:
#   state_update        - Write a key/value to state.json with timestamp and source
#   state_read          - Read a value from state.json by jq path
#
# state.json is the audit/coordination layer. Dotfiles remain authoritative.
# All writes are dual-write: callers write dotfile first, then call state_update.
# state.json failures never block hook execution (all calls are || true guarded).
#
# @decision DEC-STATE-001
# @title state.json as audit/coordination layer alongside dotfiles
# @status accepted
# @rationale Dotfiles (.proof-status, .test-status, .subagent-tracker) are the
#   authoritative state store. state.json provides: (1) unified read for debugging,
#   (2) audit history with timestamps and sources, (3) coordination visibility
#   across hooks. Dual-write pattern: dotfile write is the primary (must succeed),
#   state_update is secondary (failures are logged and suppressed).

# Guard against double-sourcing
[[ -n "${_STATE_LIB_LOADED:-}" ]] && return 0

_STATE_LIB_VERSION=1

# state_update KEY VALUE [SOURCE]
#   KEY:    jq path (e.g., ".proof.status", ".agents.tester.status")
#   VALUE:  string value to write
#   SOURCE: identifier for the writing hook (default: $_HOOK_NAME)
#
# Writes to CLAUDE_DIR/state.json with atomic tmp+mv under flock.
# Maintains .history array (capped at 20 entries) for audit trail.
#
# @decision DEC-STATE-002
# @title flock on state_update() to prevent TOCTOU race conditions
# @status accepted
# @rationale The previous read-modify-write pattern (jq read → tmp write → mv) had
#   a race window: two concurrent hooks could both read the same state.json, compute
#   independent updates, and one would silently overwrite the other's write. Using
#   flock -w 5 on a lock file serializes concurrent state_update() calls. Timeout
#   is 5s to match write_proof_status(); on timeout we log and return 0 (non-fatal)
#   because state.json is the audit/coordination layer — dotfiles are authoritative.
state_update() {
    local key="${1:?state_update requires a key}"
    local value="${2:?state_update requires a value}"
    local source="${3:-${_HOOK_NAME:-unknown}}"
    local claude_dir="${CLAUDE_DIR:-$(get_claude_dir 2>/dev/null || echo "$HOME/.claude")}"
    local state_dir_base="${claude_dir}/state"
    mkdir -p "$state_dir_base" 2>/dev/null || true
    local state_file="${state_dir_base}/state.json"
    local locks_dir="${state_dir_base}/locks"
    mkdir -p "$locks_dir" 2>/dev/null || true
    local lockfile="${locks_dir}/state.lock"
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    mkdir -p "$claude_dir" 2>/dev/null || return 0

    # Wrap critical section in flock to prevent concurrent read-modify-write races.
    # fd 9 is used as the lock descriptor; subshell ensures the lock is released on exit.
    (
        if ! _lock_fd 5 9; then
            log_info "STATE" "lock timeout for ${key}, skipping update" 2>/dev/null || true
            return 0
        fi

        # Initialize state.json if missing
        if [[ ! -f "$state_file" ]]; then
            echo '{"history":[]}' > "$state_file" 2>/dev/null || return 0
        fi

        # Atomic update: read -> modify -> write via tmp
        local tmp="${state_file}.tmp.$$"
        jq --arg key "$key" \
           --arg val "$value" \
           --arg src "$source" \
           --arg ts "$timestamp" \
           '
           # Set the value at the key path
           setpath($key | split(".") | map(select(. != "")); $val) |
           # Append to history (cap at 20)
           .history = ([{key: $key, value: $val, source: $src, ts: $ts}] + (.history // []))[:20]
           ' "$state_file" > "$tmp" 2>/dev/null && mv "$tmp" "$state_file" 2>/dev/null || {
            rm -f "$tmp" 2>/dev/null
            return 0
        }

        log_info "STATE" "updated ${key}=${value} (source=${source})" 2>/dev/null || true
    ) 9>"$lockfile"
}

# state_read KEY
#   KEY: jq path (e.g., ".proof.status")
#   Prints the value to stdout. Returns 1 if key not found.
state_read() {
    local key="${1:?state_read requires a key}"
    local claude_dir="${CLAUDE_DIR:-$(get_claude_dir 2>/dev/null || echo "$HOME/.claude")}"
    local state_file="${claude_dir}/state/state.json"
    # Migration fallback: check legacy state.json location
    if [[ ! -f "$state_file" && -f "${claude_dir}/state.json" ]]; then
        state_file="${claude_dir}/state.json"
    fi

    [[ ! -f "$state_file" ]] && return 1

    local value
    value=$(jq -r "getpath(\"${key}\" | split(\".\") | map(select(. != \"\"))) // empty" "$state_file" 2>/dev/null)
    if [[ -n "$value" ]]; then
        echo "$value"
        return 0
    fi
    return 1
}

# state_dir [PROJECT_ROOT]
#   Returns the canonical state directory for the current project.
#   Creates the directory if it doesn't exist.
#   Path: $CLAUDE_DIR/state/{project_hash}/
#
# @decision DEC-RSM-STATEDIR-001
# @title Unified state directory with per-project hash subdirectories
# @status accepted
# @rationale Consolidates scattered dotfiles (.proof-status-{phash},
#   .test-status, .proof-epoch, .cas-failures, .proof-gate-pending) into
#   a structured directory hierarchy. The project hash becomes a directory
#   name instead of a file suffix, yielding clean internal names.
#   Backward-compatible via dual-write during migration (W3-1, W3-2).
state_dir() {
    local project_root="${1:-${PROJECT_ROOT:-$(detect_project_root)}}"
    local claude_dir
    claude_dir=$(PROJECT_ROOT="$project_root" get_claude_dir)
    local phash
    phash=$(project_hash "$project_root")
    local dir="${claude_dir}/state/${phash}"
    mkdir -p "$dir" 2>/dev/null || true
    echo "$dir"
}

# state_locks_dir
#   Returns the centralized locks directory: $CLAUDE_DIR/state/locks/
#   Creates the directory if it doesn't exist.
state_locks_dir() {
    local claude_dir="${CLAUDE_DIR:-$(get_claude_dir)}"
    local dir="${claude_dir}/state/locks"
    mkdir -p "$dir" 2>/dev/null || true
    echo "$dir"
}

export -f state_update state_read state_dir state_locks_dir

_STATE_LIB_LOADED=1
