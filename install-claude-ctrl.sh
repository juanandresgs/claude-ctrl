#!/usr/bin/env bash
set -euo pipefail

REMOTE="${REMOTE:-https://github.com/juanandresgs/claude-ctrl.git}"
BRANCH="${BRANCH:-main}"
TARGET="${TARGET:-$HOME/.claude}"
BACKUP="${BACKUP:-$HOME/.claude.backup.$(date -u +%Y%m%dT%H%M%SZ)}"
EXPECTED_HEAD="${EXPECTED_HEAD:-}"
ALLOW_FLOATING_NON_MAIN="${ALLOW_FLOATING_NON_MAIN:-}"

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

trap restore_on_failure ERR

for required in git python3 node jq; do
  command -v "$required" >/dev/null || {
    echo "$required is required but was not found on PATH." >&2
    exit 1
  }
done

if [ "$BRANCH" != "main" ] && [ -z "$EXPECTED_HEAD" ] && [ "$ALLOW_FLOATING_NON_MAIN" != "1" ]; then
  echo "Refusing to install floating non-main branch '$BRANCH'." >&2
  echo "Set EXPECTED_HEAD=<sha> for pinned branch testing, or ALLOW_FLOATING_NON_MAIN=1 for local experiments." >&2
  exit 1
fi

if [ -e "$BACKUP" ] || [ -L "$BACKUP" ]; then
  echo "Backup path already exists: $BACKUP" >&2
  exit 1
fi

STAGING_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/claude-ctrl-install.XXXXXX")"
INSTALL_ROOT="$STAGING_PARENT/.claude"

git clone --branch "$BRANCH" --single-branch "$REMOTE" "$INSTALL_ROOT"

HEAD_FULL="$(git -C "$INSTALL_ROOT" rev-parse HEAD)"
HEAD_SHORT="$(git -C "$INSTALL_ROOT" rev-parse --short HEAD)"
echo "Fetched $REMOTE"
echo "Branch: $BRANCH"
echo "HEAD: $HEAD_SHORT"

if [ -n "$EXPECTED_HEAD" ] && [ "$HEAD_FULL" != "$EXPECTED_HEAD" ] && [ "$HEAD_SHORT" != "$EXPECTED_HEAD" ]; then
  echo "Expected HEAD $EXPECTED_HEAD but fetched $HEAD_FULL." >&2
  exit 1
fi

for sentinel in \
  "$INSTALL_ROOT/settings.json" \
  "$INSTALL_ROOT/runtime/cli.py" \
  "$INSTALL_ROOT/hooks/implementer-critic.sh" \
  "$INSTALL_ROOT/sidecars/codex-review/.claude-plugin/plugin.json" \
  "$INSTALL_ROOT/sidecars/codex-review/scripts/stop-review-gate-hook.mjs" \
  "$INSTALL_ROOT/sidecars/codex-review/scripts/implementer-critic-hook.mjs"
do
  if [ ! -f "$sentinel" ]; then
    echo "Install payload is missing required file: $sentinel" >&2
    exit 1
  fi
done

CLAUDEX_INSTALL_ROOT="$INSTALL_ROOT" \
CLAUDE_RUNTIME_ROOT="$INSTALL_ROOT/runtime" \
CLAUDE_POLICY_DB="$INSTALL_ROOT/state.db" \
python3 "$INSTALL_ROOT/runtime/cli.py" schema ensure >/dev/null

CLAUDEX_INSTALL_ROOT="$INSTALL_ROOT" \
CLAUDE_RUNTIME_ROOT="$INSTALL_ROOT/runtime" \
CLAUDE_POLICY_DB="$INSTALL_ROOT/state.db" \
python3 "$INSTALL_ROOT/runtime/cli.py" hook validate-settings --settings "$INSTALL_ROOT/settings.json" >/dev/null

DIRTY="$(git -C "$INSTALL_ROOT" status --porcelain)"
if [ -n "$DIRTY" ]; then
  echo "Fetched tree is dirty after validation:" >&2
  printf '%s\n' "$DIRTY" >&2
  exit 1
fi

mkdir -p "$(dirname "$TARGET")"
if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
  mv "$TARGET" "$BACKUP"
  BACKED_UP=1
  echo "Backed up existing $TARGET to: $BACKUP"
fi

mv "$INSTALL_ROOT" "$TARGET"
INSTALLED=1

CLAUDEX_INSTALL_ROOT="$TARGET" \
CLAUDE_RUNTIME_ROOT="$TARGET/runtime" \
CLAUDE_POLICY_DB="$TARGET/state.db" \
python3 "$TARGET/runtime/cli.py" hook validate-settings --settings "$TARGET/settings.json"

FINAL_DIRTY="$(git -C "$TARGET" status --porcelain)"
if [ -n "$FINAL_DIRTY" ]; then
  echo "Installed tree is dirty after final validation:" >&2
  printf '%s\n' "$FINAL_DIRTY" >&2
  exit 1
fi

rm -rf "$STAGING_PARENT"
trap - ERR

echo "Installed $TARGET from $REMOTE"
echo "Branch: $BRANCH"
echo "HEAD: $HEAD_SHORT"
echo "Install complete."
if [ "$BACKED_UP" -eq 1 ]; then
  echo "Previous config backup: $BACKUP"
fi
