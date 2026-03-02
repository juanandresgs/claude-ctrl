#!/usr/bin/env bash
# state-lib.sh — Coordination/audit layer via state.json for Claude Code hooks.
#
# Loaded on demand via: require_state (defined in source-lib.sh)
# Depends on: log.sh (detect_project_root, get_claude_dir, log_info)
#
# Provides:
#   state_update  - Write a key/value to state.json with timestamp and source
#   state_read    - Read a value from state.json by jq path
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

# state_update KEY VALUE [SOURCE]
#   KEY:    jq path (e.g., ".proof.status", ".agents.tester.status")
#   VALUE:  string value to write
#   SOURCE: identifier for the writing hook (default: $_HOOK_NAME)
#
# Writes to CLAUDE_DIR/state.json with atomic tmp+mv.
# Maintains .history array (capped at 20 entries) for audit trail.
state_update() {
    local key="${1:?state_update requires a key}"
    local value="${2:?state_update requires a value}"
    local source="${3:-${_HOOK_NAME:-unknown}}"
    local claude_dir="${CLAUDE_DIR:-$(get_claude_dir 2>/dev/null || echo "$HOME/.claude")}"
    local state_file="${claude_dir}/state.json"
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    mkdir -p "$claude_dir" 2>/dev/null || return 0

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

export -f state_update state_read

_STATE_LIB_LOADED=1
