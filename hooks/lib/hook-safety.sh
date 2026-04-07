#!/usr/bin/env bash
# hooks/lib/hook-safety.sh — Reusable fail-closed wrapper for enforcement hooks.
#
# @decision DEC-HOOK-004-FC-WRAPPER
# @title hook-safety.sh provides a fail-closed EXIT trap for enforcement hooks
# @status accepted
# @rationale Both pre-bash.sh and pre-write.sh use `set -euo pipefail`. Any
#   unexpected crash (unbound variable, failing subcommand, etc.) causes bash to
#   exit non-zero. Per Claude Code's hook contract, non-zero exit from a hook
#   means "hook error — does not block". The fail-closed intent (DEC-HOOK-004-FC)
#   is defeated by bash crashes because the deny that should have been emitted
#   never reaches stdout.
#
#   This wrapper installs an EXIT trap that detects when the hook exits without
#   having responded (i.e. _HOOK_RESPONDED is not "true") and emits a deny JSON
#   to stdout + forces exit 0. Claude Code reads deny from stdout; exit 0 is
#   required because exit non-zero causes Claude Code to ignore the stdout payload.
#
#   Usage:
#     source "$HOOKS_DIR/lib/hook-safety.sh"
#     # Define all hook logic in _hook_main():
#     _hook_main() { ... }
#     run_fail_closed _hook_main
#
#   The trap replaces any existing `trap 'rt_obs_metric_batch' EXIT` — callers
#   must NOT add their own EXIT trap after sourcing this file. The wrapper
#   handles rt_obs_metric_batch internally in the exit handler.
#
#   Observatory integration: the crash deny emits a hook_crash metric via
#   _obs_accum (queued) + rt_obs_metric_batch (flushed in the exit handler).
#   rt_obs_metric / _obs_accum are defined in runtime-bridge.sh which is sourced
#   transitively via context-lib.sh before this file is sourced.

# Guard against double-sourcing
[[ -n "${_HOOK_SAFETY_LOADED:-}" ]] && return 0
_HOOK_SAFETY_LOADED=1

# State flag: set to "true" by _mark_hook_responded() once the hook has
# successfully emitted its response to stdout. The EXIT trap checks this.
_HOOK_RESPONDED=false

# Call this once the hook has printed its final response to stdout.
# Not needed when using run_fail_closed — the wrapper calls it automatically
# after _hook_main returns normally. Exposed for hooks that respond mid-flow.
_mark_hook_responded() {
    _HOOK_RESPONDED=true
}

# EXIT trap: if the hook is exiting without having responded, emit a deny.
# This must exit 0 — Claude Code ignores stdout from hooks that exit non-zero.
_fail_closed_exit_handler() {
    local _exit_code=$?
    if [[ "$_HOOK_RESPONDED" != "true" ]]; then
        # Hook is dying before emitting a response — emit fail-closed deny.
        # This MUST go to stdout so Claude Code sees it as a valid deny decision.
        printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"HOOK CRASH — enforcement hook crashed before completing evaluation. Fail-closed safety deny. DO NOT retry this command. Report this crash to the user. (exit_code='"${_exit_code}"')","blockingHook":"hook-safety-crash-deny"}}'
        # Emit observatory crash metric (best-effort, never block the deny path).
        # Guard: _obs_accum may not be defined if context-lib.sh was not sourced
        # (e.g. auto-review.sh only sources log.sh). Never crash the deny path.
        if type -t _obs_accum >/dev/null 2>&1; then
            _obs_accum hook_crash 1 '{"hook":"hook-safety","reason":"crash_before_response"}' 2>/dev/null || true
        fi
    fi
    # Always flush observatory batch on exit — replaces the standalone
    # `trap 'rt_obs_metric_batch' EXIT` callers previously used.
    # Guard: rt_obs_metric_batch may not be defined if context-lib.sh was not sourced.
    if type -t rt_obs_metric_batch >/dev/null 2>&1; then
        rt_obs_metric_batch 2>/dev/null || true
    fi
    # Force exit 0: the deny JSON is on stdout; Claude Code reads it.
    # exit non-zero here would cause Claude Code to discard the stdout payload.
    exit 0
}

# Install the fail-closed EXIT trap.
# Must be called before any hook logic runs so the trap is in place for the
# entire lifecycle of the hook. run_fail_closed calls this automatically.
_install_fail_closed_trap() {
    trap '_fail_closed_exit_handler' EXIT
}

# run_fail_closed <fn> [args...]
# Execute <fn> with the fail-closed EXIT trap installed. After <fn> returns
# normally, marks the hook as responded (EXIT trap will then be a no-op).
#
# Example:
#   _hook_main() {
#       # ... all hook logic ...
#       printf '%s\n' "$RESULT"
#   }
#   run_fail_closed _hook_main
run_fail_closed() {
    _install_fail_closed_trap
    # Temporarily disable -e so that a non-zero return from the hook function
    # does not trigger bash's ERR handler (which would exit non-zero before the
    # EXIT trap can emit the deny JSON). The EXIT trap is the single authority
    # for handling unexpected failures — set -e would bypass it.
    set +e
    "$@"
    local _rc=$?
    set -e
    if [[ $_rc -ne 0 ]]; then
        # Hook function failed — EXIT trap will fire and emit the deny JSON.
        return $_rc
    fi
    # Normal return: hook responded successfully — disarm the crash deny.
    _mark_hook_responded
}
