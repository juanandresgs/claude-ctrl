#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MIGRATE="$ROOT/scripts/claude-v6-migrate.sh"
TMP="$ROOT/tmp/test-v6-backup-restore-$$"
HOME_DIR="$TMP/home"
CONFIG_ROOT="$TMP/v6-config"
BACKUP_ROOT="$TMP/backups"
mkdir -p "$HOME_DIR/.claude/projects/proj-1" "$HOME_DIR/.claude/sessions" "$CONFIG_ROOT" "$BACKUP_ROOT"
trap 'rm -rf "$TMP"' EXIT

printf '{"hooks":{}}\n' > "$CONFIG_ROOT/settings.json"
printf 'conversation-history\n' > "$HOME_DIR/.claude/projects/proj-1/session.jsonl"
printf 'session-history\n' > "$HOME_DIR/.claude/sessions/session.jsonl"
printf 'history\n' > "$HOME_DIR/.claude/history.jsonl"
printf '{"numStartups":42}\n' > "$HOME_DIR/.claude.json"

BACKUP=$(HOME="$HOME_DIR" CLAUDE_CTRL_CONFIG_ROOT="$CONFIG_ROOT" CLAUDE_CTRL_BACKUP_ROOT="$BACKUP_ROOT" "$MIGRATE" backup)
[[ -f "$BACKUP/manifest.json" ]]
VERIFY=$(HOME="$HOME_DIR" CLAUDE_CTRL_CONFIG_ROOT="$CONFIG_ROOT" CLAUDE_CTRL_BACKUP_ROOT="$BACKUP_ROOT" "$MIGRATE" verify-backup "$BACKUP")
printf '%s' "$VERIFY" | jq -e '.ok == true' >/dev/null

HOME="$HOME_DIR" CLAUDE_CTRL_CONFIG_ROOT="$CONFIG_ROOT" CLAUDE_CTRL_BACKUP_ROOT="$BACKUP_ROOT" "$MIGRATE" install --backup-dir "$BACKUP" --yes >/dev/null
[[ -L "$HOME_DIR/.claude" ]]
[[ "$(readlink "$HOME_DIR/.claude")" == "$CONFIG_ROOT" ]]
[[ -f "$CONFIG_ROOT/projects/proj-1/session.jsonl" ]]
[[ -f "$CONFIG_ROOT/sessions/session.jsonl" ]]
[[ -f "$CONFIG_ROOT/history.jsonl" ]]

HOME="$HOME_DIR" CLAUDE_CTRL_CONFIG_ROOT="$CONFIG_ROOT" CLAUDE_CTRL_BACKUP_ROOT="$BACKUP_ROOT" "$MIGRATE" restore "$BACKUP" --yes >/dev/null
[[ ! -L "$HOME_DIR/.claude" ]]
[[ -f "$HOME_DIR/.claude/projects/proj-1/session.jsonl" ]]
[[ "$(cat "$HOME_DIR/.claude/projects/proj-1/session.jsonl")" == "conversation-history" ]]
[[ "$(cat "$HOME_DIR/.claude.json")" == '{"numStartups":42}' ]]

echo "PASS test-v6-backup-restore"
