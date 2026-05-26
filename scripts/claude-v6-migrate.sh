#!/usr/bin/env bash
set -euo pipefail

CONFIG_ROOT="${CLAUDE_CTRL_CONFIG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
BACKUP_ROOT="${CLAUDE_CTRL_BACKUP_ROOT:-$HOME/.claude-ctrl-backups}"
CLAUDE_HOME="$HOME/.claude"
CLAUDE_JSON="$HOME/.claude.json"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [args]

Commands:
  backup [--backup-root DIR]
      Copy existing ~/.claude target plus ~/.claude.json into a timestamped backup.

  verify-backup BACKUP_DIR
      Verify the backup contains manifest + state-bearing Claude paths when present.

  install [--backup-dir DIR] [--yes]
      Backup if needed, copy state-bearing history into this v6 config root, then
      replace ~/.claude with a symlink to this repo. Refuses destructive cutover
      unless --yes is provided.

  restore BACKUP_DIR [--yes]
      Backup current ~/.claude, remove v6 symlink/dir, restore the selected backup.

  test PROJECT_DIR
      Run isolated v6 config verification without changing ~/.claude.

Environment:
  CLAUDE_CTRL_CONFIG_ROOT   Override v6 config root (test/support).
  CLAUDE_CTRL_BACKUP_ROOT   Override backup root (default ~/.claude-ctrl-backups).
EOF
}

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

copy_tree() {
  local src="$1" dst="$2"
  [[ -e "$src" ]] || return 0
  mkdir -p "$(dirname "$dst")"
  if command -v rsync >/dev/null 2>&1; then
    if [[ -d "$src" && ! -L "$src" ]]; then
      mkdir -p "$dst"
      rsync -a "$src/" "$dst/"
    else
      rsync -a "$src" "$dst"
    fi
  else
    if [[ -d "$src" && ! -L "$src" ]]; then
      mkdir -p "$dst"
      cp -a "$src/." "$dst/"
    else
      cp -a "$src" "$dst"
    fi
  fi
}

write_manifest() {
  local dir="$1" source_path="$2" source_kind="$3" moved_aside="${4:-}"
  python3 - "$dir" "$source_path" "$source_kind" "$CONFIG_ROOT" "$moved_aside" <<'PY'
import json, os, sys, time
backup_dir, source_path, source_kind, config_root, moved_aside = sys.argv[1:]
manifest = {
    "schema": "claude-ctrl-v6-backup/v1",
    "created_at": int(time.time()),
    "backup_dir": backup_dir,
    "source_path": source_path,
    "source_kind": source_kind,
    "config_root": config_root,
    "moved_aside": moved_aside,
    "contains": {
        "claude_home": os.path.exists(os.path.join(backup_dir, "claude-home")),
        "claude_home_symlink": os.path.exists(os.path.join(backup_dir, "claude-home.symlink")),
        "claude_json": os.path.exists(os.path.join(backup_dir, "home-claude.json")),
    },
}
with open(os.path.join(backup_dir, "manifest.json"), "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write("\n")
PY
}

backup_cmd() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backup-root) BACKUP_ROOT="$2"; shift 2 ;;
      *) die "unknown backup arg: $1" ;;
    esac
  done
  mkdir -p "$BACKUP_ROOT"
  local out="$BACKUP_ROOT/$TS"
  mkdir -p "$out"

  local source_kind="missing"
  if [[ -L "$CLAUDE_HOME" ]]; then
    source_kind="symlink"
    readlink "$CLAUDE_HOME" > "$out/claude-home.symlink"
    local target
    target="$(cd "$(dirname "$CLAUDE_HOME")" && cd "$(dirname "$(readlink "$CLAUDE_HOME")")" 2>/dev/null && pwd -P)/$(basename "$(readlink "$CLAUDE_HOME")")" || target="$(readlink "$CLAUDE_HOME")"
    [[ -e "$target" ]] && copy_tree "$target" "$out/claude-home"
  elif [[ -d "$CLAUDE_HOME" ]]; then
    source_kind="directory"
    copy_tree "$CLAUDE_HOME" "$out/claude-home"
  elif [[ -e "$CLAUDE_HOME" ]]; then
    source_kind="file"
    copy_tree "$CLAUDE_HOME" "$out/claude-home"
  fi

  [[ -f "$CLAUDE_JSON" ]] && copy_tree "$CLAUDE_JSON" "$out/home-claude.json"
  write_manifest "$out" "$CLAUDE_HOME" "$source_kind"
  verify_backup_cmd "$out" >/dev/null
  say "$out"
}

verify_backup_cmd() {
  local dir="${1:-}"
  [[ -n "$dir" ]] || die "verify-backup requires BACKUP_DIR"
  [[ -f "$dir/manifest.json" ]] || die "missing manifest.json in $dir"
  python3 - "$dir" <<'PY'
import json, os, sys
root = sys.argv[1]
manifest = json.load(open(os.path.join(root, "manifest.json"), encoding="utf-8"))
if manifest.get("schema") != "claude-ctrl-v6-backup/v1":
    raise SystemExit("bad backup schema")
state_paths = ["projects", "sessions", "history.jsonl", "shell-snapshots", "session-env", "state.db", "plugins"]
claude_home = os.path.join(root, "claude-home")
present = [p for p in state_paths if os.path.exists(os.path.join(claude_home, p))]
print(json.dumps({"ok": True, "backup_dir": root, "state_paths_present": present, "has_claude_json": os.path.exists(os.path.join(root, "home-claude.json"))}, sort_keys=True))
PY
}

sync_state_into_config_root() {
  local backup_dir="$1"
  local src="$backup_dir/claude-home"
  [[ -d "$src" ]] || return 0
  mkdir -p "$CONFIG_ROOT"
  local paths=(projects sessions history.jsonl shell-snapshots session-env state.db state.db-shm state.db-wal plugins/data plugins/cache plugins/installed_plugins.json plugins/known_marketplaces.json mcp-needs-auth-cache.json)
  for rel in "${paths[@]}"; do
    [[ -e "$src/$rel" ]] || continue
    mkdir -p "$(dirname "$CONFIG_ROOT/$rel")"
    copy_tree "$src/$rel" "$CONFIG_ROOT/$rel"
  done
}

install_cmd() {
  local backup_dir="" yes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backup-dir) backup_dir="$2"; shift 2 ;;
      --yes|-y) yes=1; shift ;;
      *) die "unknown install arg: $1" ;;
    esac
  done
  [[ -d "$CONFIG_ROOT" ]] || die "config root missing: $CONFIG_ROOT"
  [[ -f "$CONFIG_ROOT/settings.json" ]] || die "settings.json missing in config root: $CONFIG_ROOT"
  if [[ -z "$backup_dir" ]]; then
    backup_dir="$(backup_cmd)"
  else
    verify_backup_cmd "$backup_dir" >/dev/null
  fi
  sync_state_into_config_root "$backup_dir"

  if [[ "$yes" != "1" ]]; then
    say "Prepared backup: $backup_dir"
    say "Prepared state copy into: $CONFIG_ROOT"
    say "Re-run with --yes to replace ~/.claude with a symlink to this v6 config root."
    exit 0
  fi

  local moved=""
  if [[ -e "$CLAUDE_HOME" || -L "$CLAUDE_HOME" ]]; then
    moved="$HOME/.claude.pre-v6-$TS"
    mv "$CLAUDE_HOME" "$moved"
  fi
  ln -s "$CONFIG_ROOT" "$CLAUDE_HOME"
  write_manifest "$backup_dir" "$CLAUDE_HOME" "installed_symlink" "$moved"
  say "INSTALLED claude-ctrl v6"
  say "backup=$backup_dir"
  [[ -n "$moved" ]] && say "previous_claude_home_moved=$moved"
  say "restore=$(realpath "$0") restore $backup_dir --yes"
}

restore_cmd() {
  local backup_dir="${1:-}" yes=0
  [[ -n "$backup_dir" ]] || die "restore requires BACKUP_DIR"
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) yes=1; shift ;;
      *) die "unknown restore arg: $1" ;;
    esac
  done
  verify_backup_cmd "$backup_dir" >/dev/null
  [[ "$yes" == "1" ]] || die "restore is destructive to current ~/.claude; re-run with --yes"

  local current_backup="$BACKUP_ROOT/restore-current-$TS"
  if [[ -e "$CLAUDE_HOME" || -L "$CLAUDE_HOME" ]]; then
    mkdir -p "$current_backup"
    if [[ -L "$CLAUDE_HOME" ]]; then
      readlink "$CLAUDE_HOME" > "$current_backup/claude-home.symlink"
      local target="$(readlink "$CLAUDE_HOME")"
      [[ -e "$target" ]] && copy_tree "$target" "$current_backup/claude-home"
      rm "$CLAUDE_HOME"
    else
      copy_tree "$CLAUDE_HOME" "$current_backup/claude-home"
      rm -rf "$CLAUDE_HOME"
    fi
    write_manifest "$current_backup" "$CLAUDE_HOME" "restore_current"
  fi

  if [[ -d "$backup_dir/claude-home" ]]; then
    copy_tree "$backup_dir/claude-home" "$CLAUDE_HOME"
  elif [[ -f "$backup_dir/claude-home.symlink" ]]; then
    ln -s "$(cat "$backup_dir/claude-home.symlink")" "$CLAUDE_HOME"
  else
    mkdir -p "$CLAUDE_HOME"
  fi

  if [[ -f "$backup_dir/home-claude.json" ]]; then
    [[ -f "$CLAUDE_JSON" ]] && cp -a "$CLAUDE_JSON" "$current_backup/home-claude.json.before-restore" 2>/dev/null || true
    cp -a "$backup_dir/home-claude.json" "$CLAUDE_JSON"
  fi
  say "RESTORED Claude config from $backup_dir"
  [[ -d "$current_backup" ]] && say "current_v6_backup=$current_backup"
}

test_cmd() {
  local project="${1:-$PWD}"
  "$CONFIG_ROOT/scripts/claude-v6.sh" --show-config "$project" >/dev/null
  "$CONFIG_ROOT/scripts/claude-v6.sh" --verify-config "$project"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  backup) backup_cmd "$@" ;;
  verify-backup) verify_backup_cmd "$@" ;;
  install) install_cmd "$@" ;;
  restore) restore_cmd "$@" ;;
  test) test_cmd "$@" ;;
  -h|--help|help|"") usage ;;
  *) die "unknown command: $cmd" ;;
esac
