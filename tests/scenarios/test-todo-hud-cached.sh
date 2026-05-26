#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$ROOT/tmp/test-todo-hud-cached-$$"
HOME_DIR="$TMP/home"
BIN_DIR="$TMP/bin"
WORK_DIR="$TMP/work"
mkdir -p "$HOME_DIR/.claude" "$HOME_DIR/.config/cc-todos" "$BIN_DIR" "$WORK_DIR"
trap 'rm -rf "$TMP"' EXIT

cat > "$HOME_DIR/.config/cc-todos/config" <<'CONF'
GITHUB_USER=tester
GLOBAL_REPO=tester/cc-todos
CONF

cat > "$BIN_DIR/gh" <<'SH'
#!/usr/bin/env bash
[[ -n "${GH_CALL_LOG:-}" ]] && printf '%s\n' "$*" >> "$GH_CALL_LOG"

if [[ "${FAIL_IF_CALLED:-0}" == "1" ]]; then
  exit 42
fi

if [[ "${SLOW_GH:-0}" == "1" ]]; then
  sleep 2
  exit 1
fi

case "$1 $2" in
  "auth status")
    exit 0
    ;;
  "repo view")
    if [[ "$*" == *"nameWithOwner"* ]]; then
      printf 'tester/project\n'
    fi
    exit 0
    ;;
  "issue list")
    printf '[{"number":101,"title":"Fast item"}]\n'
    exit 0
    ;;
esac

exit 0
SH
chmod +x "$BIN_DIR/gh"

export HOME="$HOME_DIR"
export PATH="$BIN_DIR:$PATH"
export GH_CALL_LOG="$TMP/gh-calls.log"
export TODO_HUD_CACHE_TTL=300

cd "$WORK_DIR"

export TODO_HUD_TIMEOUT=2
OUT=$("$ROOT/scripts/todo.sh" hud-cached)
if [[ "$OUT" != *"Fast item"* ]]; then
  echo "FAIL: initial live HUD did not return fake issue output" >&2
  exit 1
fi
if [[ ! -f "$HOME_DIR/.claude/.todo-hud-cache" || ! -f "$HOME_DIR/.claude/.todo-hud-cache.stamp" ]]; then
  echo "FAIL: initial live HUD did not populate cache" >&2
  exit 1
fi

: > "$GH_CALL_LOG"
OUT_FRESH=$(FAIL_IF_CALLED=1 "$ROOT/scripts/todo.sh" hud-cached)
if [[ "$OUT_FRESH" != *"Fast item"* ]]; then
  echo "FAIL: fresh HUD cache did not return cached issue output" >&2
  exit 1
fi
if [[ -s "$GH_CALL_LOG" ]]; then
  echo "FAIL: fresh HUD cache called gh" >&2
  exit 1
fi

export TODO_HUD_TIMEOUT=0.1
printf '0\n' > "$HOME_DIR/.claude/.todo-hud-cache.stamp"
OUT_STALE=$(SLOW_GH=1 "$ROOT/scripts/todo.sh" hud-cached)
if [[ "$OUT_STALE" != *"Fast item"* ]]; then
  echo "FAIL: stale HUD cache was not returned after live timeout" >&2
  exit 1
fi

rm -f "$HOME_DIR/.claude/.todo-hud-cache" "$HOME_DIR/.claude/.todo-hud-cache.stamp"
OUT_EMPTY=$(SLOW_GH=1 "$ROOT/scripts/todo.sh" hud-cached)
if [[ -n "$OUT_EMPTY" ]]; then
  echo "FAIL: HUD timeout without cache should return empty output" >&2
  exit 1
fi

echo "PASS test-todo-hud-cached"
