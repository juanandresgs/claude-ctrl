#!/usr/bin/env bash
set -euo pipefail

BRAID_ROOT="${BRAID_ROOT:-/Users/turla/Code/braid}"
BRAID_HOOK="${BRAID_ROOT}/hooks/submit-inject.sh"
SENTINEL="__BRAID_RELAY__"

if [[ ! -x "$BRAID_HOOK" ]]; then
  exit 0
fi

export BRIDGE_RUNS_DIR="${BRIDGE_RUNS_DIR:-${BRAID_ROOT}/runs}"

PAYLOAD="$(cat)"
PROMPT_RAW="$(printf '%s' "$PAYLOAD" | jq -r '.prompt // empty' 2>/dev/null || true)"
PROMPT_COMPACT="$(printf '%s' "$PROMPT_RAW" | tr -d '[:space:]')"

# Auto-submit and stale relay recovery can occasionally stack multiple
# sentinel writes into a single prompt. Normalize any prompt that consists
# only of one-or-more sentinel tokens back to the single trigger string so
# the upstream braid hook can still claim the queued instruction.
if [[ -n "$PROMPT_COMPACT" ]]; then
  PROMPT_REMAINDER="${PROMPT_COMPACT//${SENTINEL}/}"
  if [[ -z "$PROMPT_REMAINDER" ]]; then
    PAYLOAD="$(printf '%s' "$PAYLOAD" | jq --arg prompt "$SENTINEL" '.prompt = $prompt')"
  fi
fi

printf '%s' "$PAYLOAD" | "$BRAID_HOOK"
