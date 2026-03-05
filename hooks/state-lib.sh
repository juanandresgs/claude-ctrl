#!/usr/bin/env bash
# state-lib.sh — Coordination/audit layer via state.json for Claude Code hooks.
#
# Loaded on demand via: require_state (defined in source-lib.sh)
# Depends on: log.sh (detect_project_root, get_claude_dir, log_info)
#
# Provides:
#   state_write_locked  - Generic locked write with optional CAS semantics
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
#
# @decision DEC-STATE-CAS-001
# @title state_write_locked() generic CAS wrapper — extracted from cas_proof_status()
# @status accepted
# @rationale Multiple hooks implement their own inline flock+write patterns for
#   protected dotfiles (.proof-status, .proof-epoch, future state files). The pattern
#   is identical: acquire lock, optionally compare current value, write new value,
#   release lock. Extracting it into state_write_locked() in state-lib.sh gives callers
#   a single, tested implementation. cas_proof_status() in prompt-submit.sh now
#   delegates its CAS interior to state_write_locked(), eliminating code duplication
#   and ensuring the same timeout (STATE_LOCK_TIMEOUT, default 5s) applies everywhere.

# Guard against double-sourcing
[[ -n "${_STATE_LIB_LOADED:-}" ]] && return 0

# state_write_locked FILE NEW_VALUE [EXPECTED_VALUE]
#   Generic locked write for protected dotfiles with optional CAS semantics.
#
#   FILE:           Path to the file to write (e.g., "${CLAUDE_DIR}/.proof-epoch")
#   NEW_VALUE:      Content to write atomically
#   EXPECTED_VALUE: (optional) If provided, acts as a compare-and-swap — the write
#                   is only performed if the current file content equals EXPECTED_VALUE.
#                   If the current value differs, logs a warning and returns 1.
#
#   Returns:
#     0 — write succeeded (or CAS matched and write succeeded)
#     1 — CAS failed (current value != expected) or write error
#     1 — lock timeout (logs warning, returns 1 non-fatally)
#
#   Lock file: <file>.lock (consistent with write_proof_status and state_update)
#   Timeout: STATE_LOCK_TIMEOUT env var (default: 5 seconds)
#
#   Usage (simple write):
#     state_write_locked "${CLAUDE_DIR}/.proof-epoch" "$(date +%s)"
#
#   Usage (CAS — only write if currently "pending"):
#     state_write_locked "${CLAUDE_DIR}/.proof-status" "verified" "pending" || echo "CAS failed"
state_write_locked() {
    local file="$1"
    local new_value="$2"
    local expected="${3:-}"
    local lockfile="${file}.lock"
    local timeout="${STATE_LOCK_TIMEOUT:-5}"

    mkdir -p "$(dirname "$file")" 2>/dev/null || return 1

    local _result=0
    (
        if ! _lock_fd "$timeout" 9; then
            log_info "state_write_locked" "lock timeout on $file" 2>/dev/null || true
            exit 1
        fi

        # CAS check: if expected value provided, verify current matches before writing
        if [[ -n "$expected" ]]; then
            local current
            current=$(cat "$file" 2>/dev/null || echo "")
            if [[ "$current" != "$expected" ]]; then
                log_info "state_write_locked" "CAS failed on $file: expected='$expected' actual='$current'" 2>/dev/null || true
                exit 1
            fi
        fi

        printf '%s' "$new_value" > "$file" || exit 1
        exit 0
    ) 9>"$lockfile"
    _result=$?
    return $_result
}

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
    local state_file="${claude_dir}/state.json"
    local lockfile="${claude_dir}/.state.lock"
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
    local state_file="${claude_dir}/state.json"

    [[ ! -f "$state_file" ]] && return 1

    local value
    value=$(jq -r "getpath(\"${key}\" | split(\".\") | map(select(. != \"\"))) // empty" "$state_file" 2>/dev/null)
    if [[ -n "$value" ]]; then
        echo "$value"
        return 0
    fi
    return 1
}

export -f state_write_locked state_update state_read

_STATE_LIB_LOADED=1
