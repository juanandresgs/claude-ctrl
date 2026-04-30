#!/usr/bin/env bash

# hooks/lib/notify-bridge.sh -- transport-only bridge for runtime notifications.
#
# @decision DEC-SCRATCHLANE-004
# @title Runtime emits notification intent and hooks transport it to notify.sh
# @status accepted
# @rationale Scratchlane approval is runtime-owned state, so the runtime must
#   decide when user attention is needed and what the notice says. The shell
#   adapters should not infer notification semantics from prose reasons. They
#   only transport the structured runtimeNotification payload to notify.sh and
#   strip that internal metadata before printing the hook contract JSON.

[[ -n "${_NOTIFY_BRIDGE_LOADED:-}" ]] && return 0
_NOTIFY_BRIDGE_LOADED=1

emit_runtime_notification() {
    local result_json="${1:-}"
    local hooks_dir="${2:-}"
    local notification_json=""
    local notify_hook=""

    notification_json=$(printf '%s' "$result_json" | jq -c '.runtimeNotification // empty' 2>/dev/null || echo "")
    [[ -z "$notification_json" || "$notification_json" == "null" ]] && return 0

    notify_hook="${hooks_dir}/notify.sh"
    [[ -f "$notify_hook" ]] || return 0

    printf '%s' "$notification_json" | bash "$notify_hook" >/dev/null 2>&1 || true
}

strip_runtime_notification() {
    local result_json="${1:-}"
    printf '%s' "$result_json" | jq -c 'del(.runtimeNotification)' 2>/dev/null || printf '%s\n' "$result_json"
}

export -f emit_runtime_notification strip_runtime_notification
