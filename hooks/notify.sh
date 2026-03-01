#!/usr/bin/env bash
set -euo pipefail

# DECISION: Use terminal-notifier with osascript fallback for macOS notifications
# Rationale: terminal-notifier provides proper terminal activation on click,
# solving "Script Editor" attribution problem. Fallback ensures no hard dependency.
# Status: accepted

# Desktop notification when Claude needs attention.
# Notification hook — matcher: (all notification types)
#
# Primary: terminal-notifier (if installed) — activates terminal window on click
# Fallback: osascript — basic notification (opens Script Editor on click)
#
# Triggers for:
#   - Claude requests permission (permission_prompt)
#   - Claude is idle waiting for input (idle_prompt)

source "$(dirname "$0")/source-lib.sh"

HOOK_INPUT=$(read_input)
NOTIFICATION_TYPE=$(get_field '.notification_type')
MESSAGE=$(get_field '.message')
MESSAGE="${MESSAGE:-Claude Code needs attention}"
TITLE=$(get_field '.title')
TITLE="${TITLE:-Claude Code}"

# Only notify on macOS
[[ "$(uname)" != "Darwin" ]] && exit 0

# Cooldown — suppress rapid-fire notifications per session per type
COOLDOWN_DIR="$HOME/.claude/tmp/notify-cooldown"
COOLDOWN_SECS=30

should_notify() {
    local type="$1"
    local session="$$"  # shell PID = Claude Code process for this session
    local stamp_file="$COOLDOWN_DIR/${session}-${type}"
    mkdir -p "$COOLDOWN_DIR"

    # Prune stamps from dead sessions
    for f in "$COOLDOWN_DIR"/*; do
        [[ -f "$f" ]] || continue
        local pid="${f##*/}"
        pid="${pid%%-*}"
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$f"
        fi
    done

    if [[ -f "$stamp_file" ]]; then
        local last now
        last=$(cat "$stamp_file")
        now=$(date +%s)
        if (( now - last < COOLDOWN_SECS )); then
            return 1  # suppress
        fi
    fi
    date +%s > "$stamp_file"
    return 0
}

# Detect which terminal is running Claude Code
# Returns bundle ID for activation by terminal-notifier
detect_terminal_bundle() {
    case "${TERM_PROGRAM:-}" in
        Apple_Terminal) echo "com.apple.Terminal" ;;
        iTerm.app) echo "com.googlecode.iterm2" ;;
        ghostty) echo "com.mitchellh.ghostty" ;;
        *) echo "com.apple.Terminal" ;;  # Default fallback
    esac
}

# Map notification type to sound urgency
get_sound_for_type() {
    case "$1" in
        permission_prompt) echo "Ping" ;;      # High urgency
        idle_prompt) echo "Glass" ;;           # Medium urgency
        *) echo "" ;;                          # No sound
    esac
}

# Only notify for attention-needed events
case "$NOTIFICATION_TYPE" in
    permission_prompt|idle_prompt)
        should_notify "$NOTIFICATION_TYPE" || exit 0

        SOUND=$(get_sound_for_type "$NOTIFICATION_TYPE")

        if command -v terminal-notifier &>/dev/null; then
            # Better notification with terminal activation
            BUNDLE_ID=$(detect_terminal_bundle)
            terminal-notifier \
                -title "$TITLE" \
                -message "$MESSAGE" \
                -sound "$SOUND" \
                -activate "$BUNDLE_ID" \
                2>/dev/null || true
        else
            # Fallback to osascript (opens Script Editor on click)
            if [[ -n "$SOUND" ]]; then
                osascript -e "display notification \"$MESSAGE\" with title \"$TITLE\" sound name \"$SOUND\"" 2>/dev/null || true
            else
                osascript -e "display notification \"$MESSAGE\" with title \"$TITLE\"" 2>/dev/null || true
            fi
        fi
        ;;
    *)
        # Other notification types (auth_success, etc.) — no desktop alert needed
        ;;
esac

exit 0
