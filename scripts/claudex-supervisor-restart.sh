#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
source "${SCRIPT_DIR}/claudex-common.sh"
BRAID_ROOT="${BRAID_ROOT:-${ROOT}/.b2r}"
PID_DIR="${CLAUDEX_STATE_DIR:-$(claudex_state_dir "$ROOT" "$BRAID_ROOT")}"
APPROVER_PID_FILE="${PID_DIR}/codex-approver.pid"
APPROVER_STATE_FILE="${PID_DIR}/codex-approver.state"
WORKER_APPROVER_PID_FILE="${PID_DIR}/worker-approver.pid"
WORKER_APPROVER_STATE_FILE="${PID_DIR}/worker-approver.state"
PROGRESS_PID_FILE="${PID_DIR}/progress-monitor.pid"
PROGRESS_SNAPSHOT_FILE="${PID_DIR}/progress-monitor.latest.json"
ACTIVE_RUN_POINTER="${BRAID_ROOT}/runs/active-run"
MONITOR_WINDOW_NAME="claudex-monitor"

CODEX_TARGET=""
DRY_RUN=0
RESTART_MONITOR=1
RESTART_APPROVER=1
RESTART_WORKER_APPROVER=1

usage() {
  cat <<EOF
Usage: $(basename "$0") [--codex-target SESSION:WINDOW.PANE] [--dry-run] [--no-monitor] [--no-approver] [--no-worker-approver]

Restarts the dedicated ClauDEX Codex supervisor pane in place and, by default,
re-arms the progress monitor window, codex approver helper, and worker approver helper.

If --codex-target is omitted, the script will try to resolve it from the latest
progress-monitor snapshot first, then from the active run's Claude pane target.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --codex-target)
      CODEX_TARGET="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --no-monitor)
      RESTART_MONITOR=0
      shift
      ;;
    --no-approver)
      RESTART_APPROVER=0
      shift
      ;;
    --no-worker-approver)
      RESTART_WORKER_APPROVER=0
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

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

pid_file_probe() {
  local file="$1"
  python3 - "$file" <<'PY'
from pathlib import Path
import os
import sys

path = Path(sys.argv[1])
if not path.exists():
    print('none')
    raise SystemExit(0)

raw = path.read_text().strip()
if not raw:
    print('stale')
    raise SystemExit(0)

try:
    pid = int(raw)
except ValueError:
    print('stale')
    raise SystemExit(0)

try:
    os.kill(pid, 0)
except ProcessLookupError:
    print('stale')
except PermissionError:
    print(f'{pid}:permission')
else:
    print(f'{pid}:running')
PY
}

resolve_codex_target() {
  if [[ -n "$CODEX_TARGET" ]]; then
    printf '%s\n' "$CODEX_TARGET"
    return 0
  fi

  if [[ -f "$PROGRESS_SNAPSHOT_FILE" ]]; then
    local snapshot_target
    snapshot_target="$(jq -r '.codex_target // empty' "$PROGRESS_SNAPSHOT_FILE" 2>/dev/null || true)"
    if [[ -n "$snapshot_target" ]]; then
      printf '%s\n' "$snapshot_target"
      return 0
    fi
  fi

  if [[ -f "$ACTIVE_RUN_POINTER" ]]; then
    local run_id run_json claude_target prefix
    run_id="$(tr -d '[:space:]' < "$ACTIVE_RUN_POINTER" 2>/dev/null || true)"
    run_json="${BRAID_ROOT}/runs/${run_id}/run.json"
    if [[ -n "$run_id" && -f "$run_json" ]]; then
      claude_target="$(jq -r '.tmux_target // empty' "$run_json" 2>/dev/null || true)"
      if [[ "$claude_target" == *.* ]]; then
        prefix="${claude_target%.*}"
        printf '%s.1\n' "$prefix"
        return 0
      fi
    fi
  fi

  return 1
}

kill_pid_file() {
  local pid_file="$1"
  if [[ ! -f "$pid_file" ]]; then
    return 1
  fi
  local probe
  probe="$(pid_file_probe "$pid_file")"
  case "$probe" in
    none)
      return 1
      ;;
    stale)
      run rm -f "$pid_file"
      return 1
      ;;
    *:permission)
      return 2
      ;;
    *:running)
      if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '[dry-run] kill %q\n' "${probe%%:*}"
        printf '[dry-run] rm -f %q\n' "$pid_file"
        return 0
      fi
      if kill "${probe%%:*}" 2>/dev/null; then
        run rm -f "$pid_file"
        return 0
      fi
      return 2
      ;;
    *)
      return 2
      ;;
  esac
}

resolve_worker_target() {
  if [[ -f "$ACTIVE_RUN_POINTER" ]]; then
    local run_id run_json worker_target
    run_id="$(tr -d '[:space:]' < "$ACTIVE_RUN_POINTER" 2>/dev/null || true)"
    run_json="${BRAID_ROOT}/runs/${run_id}/run.json"
    if [[ -n "$run_id" && -f "$run_json" ]]; then
      worker_target="$(jq -r '.tmux_target // empty' "$run_json" 2>/dev/null || true)"
      if [[ -n "$worker_target" ]]; then
        printf '%s\n' "$worker_target"
        return 0
      fi
    fi
  fi

  return 1
}

SESSION_NAME=""
WINDOW_INDEX=""
SESSION_WINDOW_TARGET=""

parse_target() {
  local target="$1"
  SESSION_NAME="${target%%:*}"
  local window_and_pane="${target#*:}"
  WINDOW_INDEX="${window_and_pane%.*}"
  SESSION_WINDOW_TARGET="${SESSION_NAME}:${WINDOW_INDEX}"
}

restart_progress_monitor() {
  [[ "$RESTART_MONITOR" -eq 1 ]] || return 0

  run rm -f "$PROGRESS_PID_FILE"

  if tmux list-windows -t "$SESSION_NAME" -F '#{window_name}' 2>/dev/null | grep -Fxq "$MONITOR_WINDOW_NAME"; then
    run tmux kill-window -t "${SESSION_NAME}:${MONITOR_WINDOW_NAME}"
  fi

  run tmux new-window -d -a -t "$SESSION_WINDOW_TARGET" -n "$MONITOR_WINDOW_NAME" -c "$ROOT" \
    "cd \"$ROOT\" && export BRAID_ROOT=\"$BRAID_ROOT\" CLAUDEX_STATE_DIR=\"$PID_DIR\" && exec bash ./scripts/claudex-progress-monitor.sh --codex-target \"$CODEX_TARGET\""
}

restart_codex_approver() {
  [[ "$RESTART_APPROVER" -eq 1 ]] || return 0

  mkdir -p "$PID_DIR"
  run rm -f "$APPROVER_STATE_FILE"

  local kill_result=1
  if kill_pid_file "$APPROVER_PID_FILE"; then
    kill_result=0
  else
    kill_result=$?
  fi

  if [[ "$kill_result" -eq 2 ]]; then
    echo "codex approver probe is permission-limited; starting a fresh helper and letting the old helper exit via pid-file handoff" >&2
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] BRAID_ROOT=%q CLAUDEX_STATE_DIR=%q nohup bash %q --tmux-target %q >>%q 2>&1 &\n' \
      "$BRAID_ROOT" \
      "$PID_DIR" \
      "$ROOT/scripts/claudex-codex-approver.sh" "$CODEX_TARGET" "$PID_DIR/codex-approver.log"
    printf '[dry-run] write pid to %q\n' "$APPROVER_PID_FILE"
    return 0
  fi

  BRAID_ROOT="$BRAID_ROOT" CLAUDEX_STATE_DIR="$PID_DIR" \
    nohup bash "$ROOT/scripts/claudex-codex-approver.sh" --tmux-target "$CODEX_TARGET" \
    >>"$PID_DIR/codex-approver.log" 2>&1 &
  echo "$!" > "$APPROVER_PID_FILE"
}

restart_worker_approver() {
  [[ "$RESTART_WORKER_APPROVER" -eq 1 ]] || return 0

  mkdir -p "$PID_DIR"
  run rm -f "$WORKER_APPROVER_STATE_FILE"

  local worker_target=""
  worker_target="$(resolve_worker_target)" || {
    echo "worker approver target could not be resolved from active run; leaving worker approver unchanged" >&2
    return 0
  }

  local kill_result=1
  if kill_pid_file "$WORKER_APPROVER_PID_FILE"; then
    kill_result=0
  else
    kill_result=$?
  fi

  if [[ "$kill_result" -eq 2 ]]; then
    echo "worker approver probe is permission-limited; starting a fresh helper and letting the old helper exit via pid-file handoff" >&2
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] BRAID_ROOT=%q CLAUDEX_STATE_DIR=%q nohup bash %q --tmux-target %q >>%q 2>&1 &\n' \
      "$BRAID_ROOT" "$PID_DIR" \
      "$ROOT/scripts/claudex-worker-approver.sh" "$worker_target" "$PID_DIR/worker-approver.log"
    printf '[dry-run] write pid to %q\n' "$WORKER_APPROVER_PID_FILE"
    return 0
  fi

  BRAID_ROOT="$BRAID_ROOT" CLAUDEX_STATE_DIR="$PID_DIR" \
    nohup bash "$ROOT/scripts/claudex-worker-approver.sh" --tmux-target "$worker_target" \
    >>"$PID_DIR/worker-approver.log" 2>&1 &
  echo "$!" > "$WORKER_APPROVER_PID_FILE"
}

restart_supervisor_pane() {
  run tmux respawn-pane -k -t "$CODEX_TARGET" \
    "cd \"$ROOT\" && export BRAID_ROOT=\"$BRAID_ROOT\" CLAUDEX_STATE_DIR=\"$PID_DIR\" && clear && ./scripts/claudex-codex-launch.sh"
}

CODEX_TARGET="$(resolve_codex_target)" || {
  echo "Unable to resolve the Codex supervisor pane target. Pass --codex-target explicitly." >&2
  exit 1
}

parse_target "$CODEX_TARGET"

if ! tmux list-panes -t "$CODEX_TARGET" >/dev/null 2>&1; then
  echo "Codex pane target not found: $CODEX_TARGET" >&2
  exit 1
fi

restart_progress_monitor
restart_codex_approver
restart_worker_approver
restart_supervisor_pane

cat <<EOF
ClauDEX supervisor restart queued.

codex_target: $CODEX_TARGET
session: $SESSION_NAME
monitor_window: ${SESSION_NAME}:${MONITOR_WINDOW_NAME}
approver: $([[ "$RESTART_APPROVER" -eq 1 ]] && echo restarted || echo unchanged)
worker_approver: $([[ "$RESTART_WORKER_APPROVER" -eq 1 ]] && echo restarted || echo unchanged)
monitor: $([[ "$RESTART_MONITOR" -eq 1 ]] && echo restarted || echo unchanged)

If the pane shows the standard trust prompt, press Enter once.
EOF
