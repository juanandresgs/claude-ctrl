#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
ROOT="$(git rev-parse --show-toplevel)"
source "${SCRIPT_DIR}/claudex-common.sh"
BRAID_ROOT="${BRAID_ROOT:-${ROOT}/.b2r}"
PID_DIR="${CLAUDEX_STATE_DIR:-$(claudex_state_dir "$ROOT" "$BRAID_ROOT")}"
PID_FILE="${PID_DIR}/codex-approver.pid"
STATE_FILE="${PID_DIR}/codex-approver.state"
LOG_FILE="${PID_DIR}/codex-approver.log"
TMUX_TARGET=""
INTERVAL_SECONDS="${CLAUDEX_CODEX_APPROVER_INTERVAL_SECONDS:-2}"
RETRY_SECONDS="${CLAUDEX_CODEX_APPROVER_RETRY_SECONDS:-5}"

usage() {
  cat <<'EOF'
Usage: scripts/claudex-codex-approver.sh --tmux-target <session:window.pane>

Monitors the Codex supervisor pane and auto-selects "Always allow" only for
claude_bridge MCP trust prompts. This is a narrow bootstrap helper for the
read-only ClauDEX supervisor seat.
EOF
}

log() {
  mkdir -p "$PID_DIR"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG_FILE"
}

send_choice() {
  local choice="$1"
  tmux send-keys -t "$TMUX_TARGET" "$choice"
  sleep 0.2
  tmux send-keys -t "$TMUX_TARGET" Enter
}

send_enter() {
  tmux send-keys -t "$TMUX_TARGET" Enter
}

clear_state() {
  rm -f "$STATE_FILE" 2>/dev/null || true
  last_fingerprint=""
  last_sent_at=""
}

record_state() {
  local fingerprint="$1"
  local sent_at="$2"
  printf '%s|%s\n' "$fingerprint" "$sent_at" >"$STATE_FILE"
  last_fingerprint="$fingerprint"
  last_sent_at="$sent_at"
}

should_send() {
  local fingerprint="$1"
  local now="$2"

  if [[ "$fingerprint" != "$last_fingerprint" ]]; then
    return 0
  fi

  if [[ ! "$last_sent_at" =~ ^[0-9]+$ ]]; then
    return 0
  fi

  (( now - last_sent_at >= RETRY_SECONDS ))
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tmux-target)
      TMUX_TARGET="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$TMUX_TARGET" ]]; then
  echo "--tmux-target is required" >&2
  exit 1
fi

mkdir -p "$PID_DIR"

state_payload="$(cat "$STATE_FILE" 2>/dev/null || true)"
if [[ "$state_payload" == *"|"* ]]; then
  last_fingerprint="${state_payload%%|*}"
  last_sent_at="${state_payload##*|}"
else
  last_fingerprint="$state_payload"
  last_sent_at=""
fi
registered_pid=0

while true; do
  pid_payload="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$pid_payload" ]]; then
    if [[ "$pid_payload" == "$$" ]]; then
      registered_pid=1
    elif [[ "$registered_pid" -eq 1 ]]; then
      exit 0
    fi
  fi

  pane="$(tmux capture-pane -p -t "$TMUX_TARGET" 2>/dev/null || true)"
  pane_pid="$(tmux display-message -p -t "$TMUX_TARGET" '#{pane_pid}' 2>/dev/null || true)"
  now="$(date +%s)"
  tool="$(printf '%s' "$pane" | perl -ne 'if (/Allow the claude_bridge MCP server to run tool "([^"]+)"/) { print $1; exit 0 }')"
  trust_prompt=0
  if printf '%s' "$pane" | grep -q 'Do you trust the contents of this' \
    && printf '%s' "$pane" | grep -q 'Press enter to continue'; then
    trust_prompt=1
  fi

  if [[ "$trust_prompt" -eq 1 ]]; then
    fingerprint="${TMUX_TARGET}:${pane_pid}:directory_trust"
    if should_send "$fingerprint" "$now"; then
      send_choice 1
      record_state "$fingerprint" "$now"
      log "auto-approved directory trust prompt in ${TMUX_TARGET}"
    fi
    sleep "$INTERVAL_SECONDS"
    continue
  fi

  if [[ -n "$tool" ]]; then
    fingerprint="${TMUX_TARGET}:${pane_pid}:${tool}"
    if should_send "$fingerprint" "$now"; then
      send_choice 3
      record_state "$fingerprint" "$now"
      log "auto-approved claude_bridge tool trust for ${tool} in ${TMUX_TARGET}"
    fi
  else
    clear_state
  fi
  sleep "$INTERVAL_SECONDS"
done
