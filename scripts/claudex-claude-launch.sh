#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SETTINGS_FILE="${ROOT}/ClauDEX/bridge/claude-settings.json"
EFFORT="${CLAUDEX_CLAUDE_EFFORT:-high}"

if [[ ! -f "$SETTINGS_FILE" ]]; then
  echo "Missing settings file: $SETTINGS_FILE" >&2
  exit 1
fi

exec claude \
  --effort "$EFFORT" \
  --setting-sources project,local \
  --settings "$SETTINGS_FILE" \
  "$@"
