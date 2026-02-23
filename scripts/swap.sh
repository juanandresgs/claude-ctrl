#!/usr/bin/env bash
# Config swap for Metanoia hook consolidation rollout.
# Swaps settings.json between legacy (original hooks) and metanoia (consolidated hooks)
# with JSON validation and timestamped backups.
#
# Usage: bash scripts/swap.sh [legacy|metanoia|status]
#
# @decision DEC-META-004
# @title Dual settings files with swap script for rollback
# @status accepted
# @rationale Instant rollback between legacy and consolidated hook configs. Validates
#   JSON before overwrite to prevent broken configs. Timestamped backups ensure no data loss.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
LEGACY="$CLAUDE_DIR/settings-legacy.json"
METANOIA="$CLAUDE_DIR/settings-metanoia.json"
BACKUP_DIR="$CLAUDE_DIR/tmp"

usage() {
    echo "Usage: bash scripts/swap.sh [legacy|metanoia|status]"
    echo ""
    echo "  legacy   — Swap to original (separate) hooks"
    echo "  metanoia — Swap to consolidated hooks"
    echo "  status   — Report which config is active"
    exit 1
}

validate_json() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "ERROR: $file does not exist"
        return 1
    fi
    if ! jq empty "$file" 2>/dev/null; then
        echo "ERROR: $file is not valid JSON"
        return 1
    fi
    return 0
}

backup_current() {
    if [[ ! -f "$SETTINGS" ]]; then
        return 0
    fi
    mkdir -p "$BACKUP_DIR"
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local backup="$BACKUP_DIR/settings.json.bak-$ts"
    cp "$SETTINGS" "$backup"
    echo "Backed up to $backup"
}

swap_to() {
    local target="$1"
    local source_file="$2"
    local label="$3"

    echo "Swapping to $label config..."

    # Validate source
    if ! validate_json "$source_file"; then
        echo "ABORT: Source file invalid, settings.json unchanged"
        exit 1
    fi

    # Backup current
    backup_current

    # Copy
    cp "$source_file" "$SETTINGS"
    echo "Active config: $label"

    # Verify
    if ! validate_json "$SETTINGS"; then
        echo "ERROR: settings.json corrupted after copy — restoring backup"
        local latest_backup
        latest_backup=$(ls -t "$BACKUP_DIR"/settings.json.bak-* 2>/dev/null | head -1)
        if [[ -n "$latest_backup" ]]; then
            cp "$latest_backup" "$SETTINGS"
            echo "Restored from $latest_backup"
        fi
        exit 1
    fi

    echo "Swap complete. Restart Claude Code for changes to take effect."
}

show_status() {
    if [[ ! -f "$SETTINGS" ]]; then
        echo "No settings.json found"
        exit 1
    fi

    local active="unknown"

    if [[ -f "$LEGACY" ]] && diff -q "$SETTINGS" "$LEGACY" >/dev/null 2>&1; then
        active="legacy"
    elif [[ -f "$METANOIA" ]] && diff -q "$SETTINGS" "$METANOIA" >/dev/null 2>&1; then
        active="metanoia"
    else
        active="modified (differs from both legacy and metanoia)"
    fi

    echo "Active config: $active"

    # Show hook counts for quick comparison
    local pre_write_count pre_bash_count post_write_count
    pre_write_count=$(jq '[.hooks.PreToolUse[] | select(.matcher == "Write|Edit") | .hooks[]] | length' "$SETTINGS" 2>/dev/null || echo "?")
    pre_bash_count=$(jq '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]] | length' "$SETTINGS" 2>/dev/null || echo "?")
    post_write_count=$(jq '[.hooks.PostToolUse[] | select(.matcher == "Write|Edit") | .hooks[]] | length' "$SETTINGS" 2>/dev/null || echo "?")

    echo "  PreToolUse:Write|Edit hooks: $pre_write_count"
    echo "  PreToolUse:Bash hooks:       $pre_bash_count"
    echo "  PostToolUse:Write|Edit hooks: $post_write_count"
}

# Main
case "${1:-}" in
    legacy)
        swap_to legacy "$LEGACY" "legacy"
        ;;
    metanoia)
        swap_to metanoia "$METANOIA" "metanoia"
        ;;
    status)
        show_status
        ;;
    *)
        usage
        ;;
esac
