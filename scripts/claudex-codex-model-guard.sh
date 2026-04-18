#!/usr/bin/env bash
set -euo pipefail

PANE_TARGET="${1:-${TMUX_PANE:-}}"
TIMEOUT_SECONDS="${CLAUDEX_CODEX_MODEL_GUARD_TIMEOUT_SECONDS:-0}"
POLL_SECONDS="${CLAUDEX_CODEX_MODEL_GUARD_POLL_SECONDS:-1}"
RETRY_SECONDS="${CLAUDEX_CODEX_MODEL_GUARD_RETRY_SECONDS:-5}"
PID_DIR="${CLAUDEX_STATE_DIR:-}"
PID_FILE=""
if [[ -n "$PID_DIR" ]]; then
  PID_FILE="${PID_DIR}/codex-model-guard.pid"
fi

if [[ -z "$PANE_TARGET" ]]; then
  exit 0
fi

if ! command -v tmux >/dev/null 2>&1; then
  exit 0
fi

if [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] && (( TIMEOUT_SECONDS > 0 )); then
  deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
else
  deadline=0
fi

last_sent_at=0
registered_pid=0

while true; do
  if [[ -n "$PID_FILE" ]]; then
    pid_payload="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid_payload" ]]; then
      if [[ "$pid_payload" == "$$" ]]; then
        registered_pid=1
      elif [[ "$registered_pid" -eq 1 ]]; then
        exit 0
      fi
    fi
  fi

  if (( deadline > 0 )) && (( $(date +%s) >= deadline )); then
    exit 0
  fi

  if ! tmux list-panes -t "$PANE_TARGET" >/dev/null 2>&1; then
    exit 0
  fi

  pane_text="$(tmux capture-pane -pt "$PANE_TARGET" -S -120 2>/dev/null || true)"
  if [[ "$pane_text" == *"Choose how you'd like Codex to proceed."* ]] && \
     [[ "$pane_text" == *"Try new model"* || "$pane_text" == *"Use existing model"* ]]; then
    now="$(date +%s)"
    if (( now - last_sent_at >= RETRY_SECONDS )); then
      tmux select-pane -t "$PANE_TARGET" -e >/dev/null 2>&1 || true
      tmux send-keys -t "$PANE_TARGET" Down
      sleep 0.2
      tmux send-keys -t "$PANE_TARGET" Enter
      last_sent_at="$now"
    fi
  fi

  sleep "$POLL_SECONDS"
done

exit 0
