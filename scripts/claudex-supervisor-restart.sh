#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
source "${SCRIPT_DIR}/claudex-common.sh"
BRAID_ROOT="$(claudex_resolve_braid_root "$ROOT" "${BRAID_ROOT:-}" "${CLAUDEX_STATE_DIR:-}")"
PID_DIR="${CLAUDEX_STATE_DIR:-$(claudex_state_dir "$ROOT" "$BRAID_ROOT")}"
APPROVER_PID_FILE="${PID_DIR}/codex-approver.pid"
APPROVER_STATE_FILE="${PID_DIR}/codex-approver.state"
MODEL_GUARD_PID_FILE="${PID_DIR}/codex-model-guard.pid"
WORKER_APPROVER_PID_FILE="${PID_DIR}/worker-approver.pid"
WORKER_APPROVER_STATE_FILE="${PID_DIR}/worker-approver.state"
PROGRESS_PID_FILE="${PID_DIR}/progress-monitor.pid"
PROGRESS_SNAPSHOT_FILE="${PID_DIR}/progress-monitor.latest.json"
ACTIVE_RUN_POINTER="${BRAID_ROOT}/runs/active-run"
MONITOR_WINDOW_NAME="claudex-monitor"
WATCHDOG_WINDOW_NAME="claudex-watchdog"
WATCHDOG_PID_FILE="${PID_DIR}/watchdog.pid"
WATCHDOG_LOG_FILE="${PID_DIR}/watchdog.log"
AUTO_SUBMIT_PID_FILE="${PID_DIR}/auto-submit.pid"
BROKER_PID_FILE="${BRAID_ROOT}/runs/braidd.pid"
TOPOLOGY_JSON=""

CODEX_TARGET=""
DRY_RUN=0
RESTART_MONITOR=1
RESTART_APPROVER=1
RESTART_WORKER_APPROVER=1
RESTART_TRANSPORT=1

usage() {
  cat <<EOF
Usage: $(basename "$0") [--codex-target SESSION:WINDOW.PANE] [--dry-run] [--no-monitor] [--no-approver] [--no-worker-approver] [--no-transport]

Restarts the dedicated ClauDEX Codex supervisor pane in place and, by default,
re-arms the transport watchdog window, progress monitor window, codex approver
helper, and worker approver helper.

If --codex-target is omitted, the script resolves both supervisor and worker
targets through the runtime lane-topology probe instead of guessing in shell.
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
    --no-transport)
      RESTART_TRANSPORT=0
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

load_lane_topology() {
  if [[ -n "$TOPOLOGY_JSON" ]]; then
    return 0
  fi

  local args=()
  if [[ -n "$CODEX_TARGET" ]]; then
    args+=(--codex-target "$CODEX_TARGET")
  fi

  TOPOLOGY_JSON="$(claudex_bridge_topology_json "$BRAID_ROOT" "$PID_DIR" "${args[@]}" 2>/dev/null || true)"
  [[ -n "$TOPOLOGY_JSON" ]]
}

lane_topology_field() {
  local jq_expr="$1"
  if ! load_lane_topology; then
    return 1
  fi
  printf '%s\n' "$TOPOLOGY_JSON" | jq -r "$jq_expr" 2>/dev/null
}

resolve_codex_target() {
  if [[ -n "$CODEX_TARGET" ]]; then
    printf '%s\n' "$CODEX_TARGET"
    return 0
  fi

  local target authoritative
  target="$(lane_topology_field '.codex.target // empty' || true)"
  authoritative="$(lane_topology_field '.codex.authoritative // false' || printf 'false')"
  [[ -n "$target" && "$authoritative" == "true" ]] || return 1
  printf '%s\n' "$target"
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
  local target
  target="$(lane_topology_field '.claude.target // empty' || true)"
  [[ -n "$target" ]] || return 1
  printf '%s\n' "$target"
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

restart_transport_watchdog() {
  [[ "$RESTART_TRANSPORT" -eq 1 ]] || return 0

  mkdir -p "$PID_DIR"

  local worker_target=""
  worker_target="$(resolve_worker_target)" || {
    echo "transport watchdog target could not be resolved from active run; leaving transport unchanged" >&2
    return 0
  }

  local kill_result=1
  if kill_pid_file "$WATCHDOG_PID_FILE"; then
    kill_result=0
  else
    kill_result=$?
  fi

  if [[ "$kill_result" -eq 2 ]]; then
    echo "watchdog pid probe is permission-limited; starting a fresh watchdog and letting stale copies age out" >&2
  fi

  run rm -f "$WATCHDOG_PID_FILE" "$AUTO_SUBMIT_PID_FILE" "$BROKER_PID_FILE"

  if tmux list-windows -t "$SESSION_NAME" -F '#{window_name}' 2>/dev/null | grep -Fxq "$WATCHDOG_WINDOW_NAME"; then
    run tmux kill-window -t "${SESSION_NAME}:${WATCHDOG_WINDOW_NAME}"
  fi

  local once_cmd
  once_cmd="cd \"$ROOT\" && export BRAID_ROOT=\"$BRAID_ROOT\" CLAUDEX_STATE_DIR=\"$PID_DIR\" CLAUDEX_AUTO_HAND_BACK_USER_DRIVING=1 && bash ./scripts/claudex-watchdog.sh --tmux-target \"$worker_target\" --once"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] %s >> %q 2>&1\n' "$once_cmd" "$WATCHDOG_LOG_FILE"
  else
    bash -lc "$once_cmd" >>"$WATCHDOG_LOG_FILE" 2>&1 || true
  fi

  local watchdog_cmd
  watchdog_cmd="cd \"$ROOT\" && export BRAID_ROOT=\"$BRAID_ROOT\" CLAUDEX_STATE_DIR=\"$PID_DIR\" CLAUDEX_AUTO_HAND_BACK_USER_DRIVING=1 && exec bash ./scripts/claudex-watchdog.sh --tmux-target \"$worker_target\""
  run tmux new-window -d -t "$SESSION_NAME" -n "$WATCHDOG_WINDOW_NAME" -c "$ROOT" "$watchdog_cmd"
}

transport_health_report() {
  [[ "$RESTART_TRANSPORT" -eq 1 ]] || return 0
  [[ "$DRY_RUN" -eq 0 ]] || return 0

  "$(claudex_runtime_python)" "$(claudex_runtime_cli)" bridge broker-health --braid-root "$BRAID_ROOT" 2>/dev/null || true
}

restart_supervisor_pane() {
  run tmux respawn-pane -k -t "$CODEX_TARGET" \
    "cd \"$ROOT\" && export BRAID_ROOT=\"$BRAID_ROOT\" CLAUDEX_STATE_DIR=\"$PID_DIR\" && clear && ./scripts/claudex-codex-launch.sh"
  run tmux select-pane -t "$CODEX_TARGET" -e
}

restart_model_guard() {
  mkdir -p "$PID_DIR"
  kill_pid_file "$MODEL_GUARD_PID_FILE" >/dev/null 2>&1 || true

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] BRAID_ROOT=%q CLAUDEX_STATE_DIR=%q nohup bash %q %q >>%q 2>&1 &\n' \
      "$BRAID_ROOT" "$PID_DIR" \
      "$ROOT/scripts/claudex-codex-model-guard.sh" "$CODEX_TARGET" "$PID_DIR/codex-model-guard.log"
    printf '[dry-run] write pid to %q\n' "$MODEL_GUARD_PID_FILE"
    return 0
  fi

  BRAID_ROOT="$BRAID_ROOT" CLAUDEX_STATE_DIR="$PID_DIR" \
    nohup bash "$ROOT/scripts/claudex-codex-model-guard.sh" "$CODEX_TARGET" \
    >>"$PID_DIR/codex-model-guard.log" 2>&1 &
  echo "$!" > "$MODEL_GUARD_PID_FILE"
}

refresh_active_run_topology_metadata() {
  [[ "$DRY_RUN" -eq 0 ]] || return 0
  [[ -f "$ACTIVE_RUN_POINTER" ]] || return 0

  local run_id run_json worker_target worker_pane_id codex_pane_id
  run_id="$(tr -d '[:space:]' < "$ACTIVE_RUN_POINTER" 2>/dev/null || true)"
  run_json="${BRAID_ROOT}/runs/${run_id}/run.json"
  [[ -n "$run_id" && -f "$run_json" ]] || return 0

  TOPOLOGY_JSON=""
  worker_target="$(resolve_worker_target 2>/dev/null || true)"
  codex_pane_id="$(tmux display-message -p -t "$CODEX_TARGET" '#{pane_id}' 2>/dev/null || true)"
  worker_pane_id=""
  if [[ -n "$worker_target" ]] && tmux list-panes -t "$worker_target" >/dev/null 2>&1; then
    worker_pane_id="$(tmux display-message -p -t "$worker_target" '#{pane_id}' 2>/dev/null || true)"
  fi

  jq \
    --arg worker_target "$worker_target" \
    --arg worker_pane_id "$worker_pane_id" \
    --arg codex_target "$CODEX_TARGET" \
    --arg codex_pane_id "$codex_pane_id" \
    '
    . as $run
    | if ($worker_target | length) > 0 then $run + {tmux_target: $worker_target} else $run end
    | if ($worker_pane_id | length) > 0 then . + {claude_pane_id: $worker_pane_id} else . end
    | if ($codex_target | length) > 0 then . + {codex_target: $codex_target} else . end
    | if ($codex_pane_id | length) > 0 then . + {codex_pane_id: $codex_pane_id} else . end
    ' \
    "$run_json" > "${run_json}.tmp"
  mv "${run_json}.tmp" "$run_json"
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

restart_transport_watchdog
restart_progress_monitor
restart_codex_approver
restart_worker_approver
restart_supervisor_pane
restart_model_guard
refresh_active_run_topology_metadata

cat <<EOF
ClauDEX supervisor restart queued.

codex_target: $CODEX_TARGET
session: $SESSION_NAME
monitor_window: ${SESSION_NAME}:${MONITOR_WINDOW_NAME}
approver: $([[ "$RESTART_APPROVER" -eq 1 ]] && echo restarted || echo unchanged)
worker_approver: $([[ "$RESTART_WORKER_APPROVER" -eq 1 ]] && echo restarted || echo unchanged)
model_guard: restarted
monitor: $([[ "$RESTART_MONITOR" -eq 1 ]] && echo restarted || echo unchanged)
transport: $([[ "$RESTART_TRANSPORT" -eq 1 ]] && echo restarted || echo unchanged)
watchdog_window: ${SESSION_NAME}:${WATCHDOG_WINDOW_NAME}
watchdog_log: ${WATCHDOG_LOG_FILE}

If the pane shows the standard trust prompt, press Enter once.
EOF

transport_health_report
