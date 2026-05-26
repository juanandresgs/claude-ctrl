#!/usr/bin/env bash
set -euo pipefail

CONFIG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SHOW_CONFIG=0
VERIFY_CONFIG=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --show-config)
      SHOW_CONFIG=1
      shift
      ;;
    --verify-config)
      VERIFY_CONFIG=1
      shift
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

PROJECT_DIR="${1:-$PWD}"
if [[ $# -gt 0 ]]; then
  shift || true
fi
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd -P)"

export CLAUDE_CONFIG_DIR="$CONFIG_ROOT"
export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
export CLAUDE_RUNTIME_ROOT="$CONFIG_ROOT/runtime"
export PATH="$CONFIG_ROOT/bin:$PATH"

TMP_DIR="$CONFIG_ROOT/tmp"
EFFECTIVE_SETTINGS="$TMP_DIR/claude-v6-settings.json"
mkdir -p "$PROJECT_DIR/.claude" "$TMP_DIR"

python3 "$CONFIG_ROOT/runtime/cli.py" install render-settings \
  --root "$CONFIG_ROOT" \
  --settings "$CONFIG_ROOT/settings.json" \
  --output "$EFFECTIVE_SETTINGS" >/dev/null

if [[ "$SHOW_CONFIG" == "1" ]]; then
  echo "CONFIG_ROOT=$CONFIG_ROOT"
  echo "PROJECT_DIR=$PROJECT_DIR"
  echo "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR"
  echo "CLAUDE_RUNTIME_ROOT=$CLAUDE_RUNTIME_ROOT"
  echo "EFFECTIVE_SETTINGS=$EFFECTIVE_SETTINGS"
  python3 - "$EFFECTIVE_SETTINGS" <<'PY'
import json
import sys
settings = json.load(open(sys.argv[1]))
for event, entries in settings.get("hooks", {}).items():
    for entry in entries:
        for hook in entry.get("hooks", []):
            cmd = hook.get("command", "")
            if "prompt-submit.sh" in cmd or "pre-agent.sh" in cmd or "subagent-start.sh" in cmd or "v6-result-submit.sh" in cmd:
                print(f"HOOK:{event}:{cmd}")
PY
  exit 0
fi

if [[ "$VERIFY_CONFIG" == "1" ]]; then
  DEBUG_FILE="${CLAUDE_V6_DEBUG_FILE:-$TMP_DIR/claude-v6-debug.log}"
  STREAM_FILE="${CLAUDE_V6_STREAM_FILE:-$TMP_DIR/claude-v6-stream.jsonl}"
  VERIFY_STATE_DIR="$(mktemp -d "$TMP_DIR/claude-v6-verify-state.XXXXXX")"
  export CLAUDE_POLICY_DB="$VERIFY_STATE_DIR/state.db"
  rm -f "$DEBUG_FILE" "$STREAM_FILE"
  set +e
  (
    cd "$PROJECT_DIR"
    claude \
      --settings "$EFFECTIVE_SETTINGS" \
      --setting-sources "" \
      --no-session-persistence \
      --tools "" \
      --debug \
      --debug-file "$DEBUG_FILE" \
      -p "v6: verify claude-ctrl config" \
      --output-format stream-json \
      --verbose \
      --include-hook-events \
      "$@" >"$STREAM_FILE"
  )
  CLAUDE_RC=$?
  set -e

  echo "DEBUG_FILE=$DEBUG_FILE"
  echo "STREAM_FILE=$STREAM_FILE"
  echo "STATE_DB=$CLAUDE_POLICY_DB"
  if grep -q "V6_DISPATCH_READY" "$STREAM_FILE" 2>/dev/null; then
    echo "PASS hook-output: V6_DISPATCH_READY observed"
  else
    echo "FAIL hook-output: V6_DISPATCH_READY not observed"
    CLAUDE_RC=1
  fi
  if grep -q "$CONFIG_ROOT/hooks/prompt-submit.sh" "$DEBUG_FILE" "$STREAM_FILE" 2>/dev/null; then
    echo "PASS hook-path: repo prompt-submit.sh observed"
  else
    echo "WARN hook-path: repo prompt-submit.sh not visible in debug/stream output; inspect $DEBUG_FILE"
  fi
  exit "$CLAUDE_RC"
fi

cd "$PROJECT_DIR"
exec claude \
  --settings "$EFFECTIVE_SETTINGS" \
  --setting-sources "" \
  "$@"
