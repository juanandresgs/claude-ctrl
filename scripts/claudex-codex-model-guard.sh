#!/usr/bin/env bash
set -euo pipefail

PANE_TARGET="${1:-${TMUX_PANE:-}}"
TIMEOUT_SECONDS="${CLAUDEX_CODEX_MODEL_GUARD_TIMEOUT_SECONDS:-20}"
POLL_SECONDS="${CLAUDEX_CODEX_MODEL_GUARD_POLL_SECONDS:-1}"

if [[ -z "$PANE_TARGET" ]]; then
  exit 0
fi

if ! command -v tmux >/dev/null 2>&1; then
  exit 0
fi

deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))

while (( $(date +%s) < deadline )); do
  if ! tmux list-panes -t "$PANE_TARGET" >/dev/null 2>&1; then
    exit 0
  fi

  pane_text="$(tmux capture-pane -pt "$PANE_TARGET" -S -120 2>/dev/null || true)"
  if [[ "$pane_text" == *"Choose how you'd like Codex to proceed."* ]] && \
     [[ "$pane_text" == *"Use existing model"* ]]; then
    tmux send-keys -t "$PANE_TARGET" 2
    sleep 0.2
    tmux send-keys -t "$PANE_TARGET" Enter
    exit 0
  fi

  sleep "$POLL_SECONDS"
done

exit 0
