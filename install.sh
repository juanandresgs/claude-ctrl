#!/usr/bin/env bash
set -euo pipefail

TARGET="${TARGET:-$HOME/.claude}"
BACKUP="${BACKUP:-$HOME/.claude.backup.$(date -u +%Y%m%dT%H%M%SZ)}"
EXPECTED_HEAD="${EXPECTED_HEAD:-}"
ALLOW_DIRTY="${ALLOW_DIRTY:-}"

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
STAGING_PARENT=""
INSTALL_ROOT=""
BACKED_UP=0
INSTALLED=0

restore_on_failure() {
  echo "Install failed." >&2

  if [ "$INSTALLED" -eq 1 ] && { [ -e "$TARGET" ] || [ -L "$TARGET" ]; }; then
    rm -rf "$TARGET"
  fi

  if [ "$BACKED_UP" -eq 1 ] && { [ -e "$BACKUP" ] || [ -L "$BACKUP" ]; }; then
    echo "Restoring previous $TARGET from: $BACKUP" >&2
    mv "$BACKUP" "$TARGET"
  fi

  if [ -n "$STAGING_PARENT" ] && [ -d "$STAGING_PARENT" ]; then
    rm -rf "$STAGING_PARENT"
  fi
}

require_tools() {
  for required in git python3 node jq; do
    command -v "$required" >/dev/null || {
      echo "$required is required but was not found on PATH." >&2
      exit 1
    }
  done
}

same_path() {
  [ -e "$1" ] && [ -e "$2" ] || return 1
  [ "$(cd "$1" && pwd -P)" = "$(cd "$2" && pwd -P)" ]
}

validate_payload() {
  local root="$1"

  for sentinel in \
    "$root/settings.json" \
    "$root/bin/cc-policy" \
    "$root/runtime/cli.py" \
    "$root/hooks/implementer-critic.sh" \
    "$root/sidecars/codex-review/.claude-plugin/plugin.json" \
    "$root/sidecars/codex-review/scripts/stop-review-gate-hook.mjs" \
    "$root/sidecars/codex-review/scripts/implementer-critic-hook.mjs"
  do
    if [ ! -f "$sentinel" ]; then
      echo "Install payload is missing required file: $sentinel" >&2
      exit 1
    fi
  done

  CLAUDEX_INSTALL_ROOT="$root" \
  CLAUDE_RUNTIME_ROOT="$root/runtime" \
  CLAUDE_POLICY_DB="$root/state.db" \
  python3 "$root/runtime/cli.py" schema ensure >/dev/null

  CLAUDEX_INSTALL_ROOT="$root" \
  CLAUDE_RUNTIME_ROOT="$root/runtime" \
  CLAUDE_POLICY_DB="$root/state.db" \
  python3 "$root/runtime/cli.py" hook validate-settings --settings "$root/settings.json" >/dev/null

  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local head_full head_short dirty
    head_full="$(git -C "$root" rev-parse HEAD)"
    head_short="$(git -C "$root" rev-parse --short HEAD)"

    if [ -n "$EXPECTED_HEAD" ] && [ "$head_full" != "$EXPECTED_HEAD" ] && [ "$head_short" != "$EXPECTED_HEAD" ]; then
      echo "Expected HEAD $EXPECTED_HEAD but found $head_full." >&2
      exit 1
    fi

    dirty="$(git -C "$root" status --porcelain)"
    if [ -n "$dirty" ] && [ "$ALLOW_DIRTY" != "1" ]; then
      echo "Install payload is dirty after validation:" >&2
      printf '%s\n' "$dirty" >&2
      echo "Set ALLOW_DIRTY=1 only for local development installs." >&2
      exit 1
    fi

    echo "Validated ClauDEX payload at $head_short"
  else
    echo "Validated ClauDEX payload"
  fi
}

clone_payload() {
  local source="$1"
  local dest="$2"

  if git -C "$source" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local head_full
    head_full="$(git -C "$source" rev-parse HEAD)"
    git clone --no-hardlinks "$source" "$dest" >/dev/null
    git -C "$dest" checkout --detach "$head_full" >/dev/null
  else
    mkdir -p "$dest"
    cp -R "$source"/. "$dest"/
  fi
}

wire_cc_policy() {
  local root="$1"
  local wrapper="$root/bin/cc-policy"
  local local_bin="$HOME/.local/bin"

  if [ ! -f "$wrapper" ]; then
    echo "cc-policy wrapper not found at $wrapper" >&2
    exit 1
  fi

  if "$wrapper" obs status >/dev/null 2>&1; then
    echo "cc-policy smoke check passed."
  else
    echo "WARNING: $wrapper exists but failed a smoke check." >&2
  fi

  if [[ ":$PATH:" == *":$local_bin:"* ]]; then
    mkdir -p "$local_bin"
    ln -sf "$wrapper" "$local_bin/cc-policy"
    echo "Linked cc-policy into $local_bin."
    return
  fi

  echo "cc-policy is available at $wrapper"
  echo "Add this to your shell rc if you want it globally on PATH:"
  echo "  export PATH=\"\$HOME/.claude/bin:\$PATH\""
}

trap restore_on_failure ERR
require_tools

if [ -e "$TARGET" ] && same_path "$SOURCE_DIR" "$TARGET"; then
  validate_payload "$TARGET"
  wire_cc_policy "$TARGET"
  trap - ERR
  echo "ClauDEX is installed at $TARGET."
  exit 0
fi

if [ -e "$BACKUP" ] || [ -L "$BACKUP" ]; then
  echo "Backup path already exists: $BACKUP" >&2
  exit 1
fi

validate_payload "$SOURCE_DIR"

STAGING_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/claude-ctrl-install.XXXXXX")"
INSTALL_ROOT="$STAGING_PARENT/.claude"
clone_payload "$SOURCE_DIR" "$INSTALL_ROOT"
validate_payload "$INSTALL_ROOT"

mkdir -p "$(dirname "$TARGET")"
if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
  mv "$TARGET" "$BACKUP"
  BACKED_UP=1
  echo "Backed up existing $TARGET to: $BACKUP"
fi

mv "$INSTALL_ROOT" "$TARGET"
INSTALLED=1

validate_payload "$TARGET"
wire_cc_policy "$TARGET"

rm -rf "$STAGING_PARENT"
trap - ERR

echo "Installed ClauDEX at $TARGET."
if [ "$BACKED_UP" -eq 1 ]; then
  echo "Previous config backup: $BACKUP"
fi
