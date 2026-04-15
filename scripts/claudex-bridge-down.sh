#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
source "${SCRIPT_DIR}/claudex-common.sh"
BRAID_ROOT="${BRAID_ROOT:-${ROOT}/.b2r}"
PID_DIR="${CLAUDEX_STATE_DIR:-$(claudex_state_dir "$ROOT" "$BRAID_ROOT")}"
PID_FILE="${PID_DIR}/auto-submit.pid"
WATCHDOG_PID_FILE="${PID_DIR}/watchdog.pid"
PROGRESS_PID_FILE="${PID_DIR}/progress-monitor.pid"
APPROVER_PID_FILE="${PID_DIR}/codex-approver.pid"
WORKER_APPROVER_PID_FILE="${PID_DIR}/worker-approver.pid"
HANDOFF_FLAG="${PID_DIR}/ready-for-codex.flag"
PENDING_REVIEW_FILE="${PID_DIR}/pending-review.json"
PROGRESS_SNAPSHOT_FILE="${PID_DIR}/progress-monitor.latest.json"
PROGRESS_ALERT_FILE="${PID_DIR}/progress-monitor.alert.json"
DISPATCH_STALL_STATE_FILE="${PID_DIR}/dispatch-stall.state.json"
DISPATCH_RECOVERY_STATE_FILE="${PID_DIR}/dispatch-recovery.state.json"
SUPERVISOR_RECOVERY_STATE_FILE="${PID_DIR}/supervisor-recovery.state.json"

if [[ -f "$PROGRESS_PID_FILE" ]]; then
  PID="$(tr -d '[:space:]' < "$PROGRESS_PID_FILE" || true)"
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
  fi
  rm -f "$PROGRESS_PID_FILE"
fi

if [[ -f "$APPROVER_PID_FILE" ]]; then
  PID="$(tr -d '[:space:]' < "$APPROVER_PID_FILE" || true)"
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
  fi
  rm -f "$APPROVER_PID_FILE"
fi

if [[ -f "$WORKER_APPROVER_PID_FILE" ]]; then
  PID="$(tr -d '[:space:]' < "$WORKER_APPROVER_PID_FILE" || true)"
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
  fi
  rm -f "$WORKER_APPROVER_PID_FILE"
fi

if [[ -f "$WATCHDOG_PID_FILE" ]]; then
  PID="$(tr -d '[:space:]' < "$WATCHDOG_PID_FILE" || true)"
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
  fi
  rm -f "$WATCHDOG_PID_FILE"
fi

if [[ -f "$PID_FILE" ]]; then
  PID="$(tr -d '[:space:]' < "$PID_FILE" || true)"
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
fi

rm -f "$HANDOFF_FLAG"
rm -f "$PENDING_REVIEW_FILE"
rm -f "$PROGRESS_SNAPSHOT_FILE"
rm -f "$PROGRESS_ALERT_FILE"
rm -f "$DISPATCH_STALL_STATE_FILE"
rm -f "$DISPATCH_RECOVERY_STATE_FILE"
rm -f "$SUPERVISOR_RECOVERY_STATE_FILE"
rm -f "${PID_DIR}/worker-approver.state"

if [[ -x "${BRAID_ROOT}/teardown.sh" ]]; then
  "${BRAID_ROOT}/teardown.sh" "$@"
else
  echo "Missing braid teardown at ${BRAID_ROOT}/teardown.sh" >&2
  exit 1
fi
