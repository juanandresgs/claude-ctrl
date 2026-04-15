#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
source "${SCRIPT_DIR}/claudex-common.sh"
BRAID_ROOT="${BRAID_ROOT:-${ROOT}/.b2r}"
AUTO_SUBMIT_SCRIPT="${ROOT}/scripts/claudex-auto-submit.sh"
STATE_DIR="${BRAID_ROOT}/runs"
PID_DIR="${CLAUDEX_STATE_DIR:-$(claudex_state_dir "$ROOT" "$BRAID_ROOT")}"
PID_FILE="${PID_DIR}/auto-submit.pid"
LOG_FILE="${PID_DIR}/auto-submit.log"
WATCHDOG_PID_FILE="${PID_DIR}/watchdog.pid"
WATCHDOG_LOG_FILE="${PID_DIR}/watchdog.log"
WORKER_APPROVER_PID_FILE="${PID_DIR}/worker-approver.pid"
WORKER_APPROVER_LOG_FILE="${PID_DIR}/worker-approver.log"
ACTIVE_RUN_POINTER="${STATE_DIR}/active-run"
BROKER_SOCK="${STATE_DIR}/braidd.sock"
BROKER_PID_FILE="${STATE_DIR}/braidd.pid"

TMUX_TARGET=""
START_DAEMON=1

usage() {
  cat <<EOF
Usage: $(basename "$0") --tmux-target SESSION:WINDOW.PANE [--no-daemon]

Bootstraps a braid bridge run for this repo and, by default, starts the
auto-submit daemon in the background.

Examples:
  $(basename "$0") --tmux-target overnight:0.1
  $(basename "$0") --tmux-target overnight:0.1 --no-daemon
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tmux-target)
      TMUX_TARGET="$2"
      shift 2
      ;;
    --no-daemon)
      START_DAEMON=0
      shift
      ;;
    -h|--help)
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
  usage >&2
  exit 1
fi

if [[ ! -x "${BRAID_ROOT}/bootstrap.sh" ]]; then
  echo "Missing braid bootstrap at ${BRAID_ROOT}/bootstrap.sh" >&2
  exit 1
fi

if [[ ! -f "${BRAID_ROOT}/braidd.mjs" ]]; then
  echo "Missing braid broker at ${BRAID_ROOT}/braidd.mjs" >&2
  exit 1
fi

if [[ ! -x "$AUTO_SUBMIT_SCRIPT" ]]; then
  echo "Missing ClauDEX auto-submit wrapper at ${AUTO_SUBMIT_SCRIPT}" >&2
  exit 1
fi

if [[ -f "$ACTIVE_RUN_POINTER" ]]; then
  EXISTING_RUN_ID="$(tr -d '[:space:]' < "$ACTIVE_RUN_POINTER" || true)"
  if [[ -n "$EXISTING_RUN_ID" ]]; then
    echo "A braid active run already exists: $EXISTING_RUN_ID" >&2
    echo "Check it with: ./scripts/claudex-bridge-status.sh" >&2
    echo "Shut it down with: ./scripts/claudex-bridge-down.sh --archive" >&2
    exit 1
  fi
fi

mkdir -p "$PID_DIR"

if [[ -f "$BROKER_PID_FILE" ]]; then
  OLD_BROKER_PID="$(tr -d '[:space:]' < "$BROKER_PID_FILE" || true)"
  if [[ -n "$OLD_BROKER_PID" ]] && kill -0 "$OLD_BROKER_PID" 2>/dev/null; then
    kill "$OLD_BROKER_PID" 2>/dev/null || true
    sleep 0.5
  fi
  rm -f "$BROKER_PID_FILE"
fi
rm -f "$BROKER_SOCK"

nohup node "${BRAID_ROOT}/braidd.mjs" --socket "$BROKER_SOCK" >>"${PID_DIR}/broker.log" 2>&1 &
BROKER_PID="$!"

BROKER_READY=0
for _i in 1 2 3 4 5 6; do
  sleep 0.5
  if [[ -S "$BROKER_SOCK" ]]; then
    BROKER_READY=1
    break
  fi
  if ! kill -0 "$BROKER_PID" 2>/dev/null; then
    break
  fi
done

if [[ "$BROKER_READY" -ne 1 ]]; then
  echo "Bridge broker failed to start cleanly." >&2
  echo "Inspect: ${PID_DIR}/broker.log" >&2
  exit 1
fi

RUN_ID="$(
  BRIDGE_PROJECT_ROOT="$ROOT" \
  BRIDGE_PROJECT_SLUG="$(basename "$ROOT")" \
  "${BRAID_ROOT}/bootstrap.sh" --tmux-target "$TMUX_TARGET"
)"

RUN_JSON="${STATE_DIR}/${RUN_ID}/run.json"
if [[ -f "$RUN_JSON" ]]; then
  PANE_ID="$(tmux display-message -p -t "$TMUX_TARGET" '#{pane_id}' 2>/dev/null || true)"
  if [[ -n "$PANE_ID" ]]; then
    jq --arg cpid "$PANE_ID" '. + {claude_pane_id: $cpid}' "$RUN_JSON" > "${RUN_JSON}.tmp"
    mv "${RUN_JSON}.tmp" "$RUN_JSON"
  fi
fi

DAEMON_STARTED="no"
WATCHDOG_STARTED="no"
WORKER_APPROVER_STARTED="no"
if [[ "$START_DAEMON" -eq 1 ]]; then
  if [[ -f "$PID_FILE" ]]; then
    EXISTING_PID="$(tr -d '[:space:]' < "$PID_FILE" || true)"
    if [[ -n "$EXISTING_PID" ]] && kill -0 "$EXISTING_PID" 2>/dev/null; then
      kill "$EXISTING_PID" 2>/dev/null || true
      sleep 0.2
    fi
    rm -f "$PID_FILE"
  fi

  BRAID_ROOT="$BRAID_ROOT" CLAUDEX_STATE_DIR="$PID_DIR" nohup "$AUTO_SUBMIT_SCRIPT" >>"$LOG_FILE" 2>&1 &
  echo "$!" > "$PID_FILE"
  DAEMON_STARTED="yes"

  if [[ -f "$WATCHDOG_PID_FILE" ]]; then
    EXISTING_WATCHDOG_PID="$(tr -d '[:space:]' < "$WATCHDOG_PID_FILE" || true)"
    if [[ -n "$EXISTING_WATCHDOG_PID" ]] && kill -0 "$EXISTING_WATCHDOG_PID" 2>/dev/null; then
      kill "$EXISTING_WATCHDOG_PID" 2>/dev/null || true
      sleep 0.2
    fi
    rm -f "$WATCHDOG_PID_FILE"
  fi

  BRAID_ROOT="$BRAID_ROOT" CLAUDEX_STATE_DIR="$PID_DIR" CLAUDEX_AUTO_HAND_BACK_USER_DRIVING=1 \
    nohup "${ROOT}/scripts/claudex-watchdog.sh" --tmux-target "$TMUX_TARGET" >>"$WATCHDOG_LOG_FILE" 2>&1 &
  WATCHDOG_STARTED="yes"

  if [[ -f "$WORKER_APPROVER_PID_FILE" ]]; then
    EXISTING_WORKER_APPROVER_PID="$(tr -d '[:space:]' < "$WORKER_APPROVER_PID_FILE" || true)"
    if [[ -n "$EXISTING_WORKER_APPROVER_PID" ]] && kill -0 "$EXISTING_WORKER_APPROVER_PID" 2>/dev/null; then
      kill "$EXISTING_WORKER_APPROVER_PID" 2>/dev/null || true
      sleep 0.2
    fi
    rm -f "$WORKER_APPROVER_PID_FILE"
  fi

  BRAID_ROOT="$BRAID_ROOT" CLAUDEX_STATE_DIR="$PID_DIR" \
    nohup "${ROOT}/scripts/claudex-worker-approver.sh" --tmux-target "$TMUX_TARGET" >>"$WORKER_APPROVER_LOG_FILE" 2>&1 &
  echo "$!" > "$WORKER_APPROVER_PID_FILE"
  WORKER_APPROVER_STARTED="yes"
fi

cat <<EOF
ClauDEX bridge bootstrapped.

repo_root: $ROOT
run_id: $RUN_ID
tmux_target: $TMUX_TARGET
auto_submit: $DAEMON_STARTED
watchdog: $WATCHDOG_STARTED
worker_approver: $WORKER_APPROVER_STARTED
state_dir: $STATE_DIR
lane_state_dir: $PID_DIR
daemon_log: $LOG_FILE
watchdog_log: $WATCHDOG_LOG_FILE
worker_approver_log: $WORKER_APPROVER_LOG_FILE
broker_log: ${PID_DIR}/broker.log

Next step in the Claude pane:
  cd "$ROOT"
  ./scripts/claudex-claude-launch.sh
EOF
