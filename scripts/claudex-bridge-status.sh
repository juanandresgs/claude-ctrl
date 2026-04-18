#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
source "${SCRIPT_DIR}/claudex-common.sh"
BRAID_ROOT="$(claudex_resolve_braid_root "$ROOT" "${BRAID_ROOT:-}" "${CLAUDEX_STATE_DIR:-}")"
PID_DIR="${CLAUDEX_STATE_DIR:-$(claudex_state_dir "$ROOT" "$BRAID_ROOT")}"
PID_FILE="${PID_DIR}/auto-submit.pid"
LOG_FILE="${PID_DIR}/auto-submit.log"
WATCHDOG_PID_FILE="${PID_DIR}/watchdog.pid"
WATCHDOG_LOG_FILE="${PID_DIR}/watchdog.log"
PROGRESS_PID_FILE="${PID_DIR}/progress-monitor.pid"
PROGRESS_LOG_FILE="${PID_DIR}/progress-monitor.log"
APPROVER_PID_FILE="${PID_DIR}/codex-approver.pid"
APPROVER_LOG_FILE="${PID_DIR}/codex-approver.log"
WORKER_APPROVER_PID_FILE="${PID_DIR}/worker-approver.pid"
WORKER_APPROVER_LOG_FILE="${PID_DIR}/worker-approver.log"
PROGRESS_SNAPSHOT_FILE="${PID_DIR}/progress-monitor.latest.json"
PROGRESS_ALERT_FILE="${PID_DIR}/progress-monitor.alert.json"
DISPATCH_STALL_STATE_FILE="${PID_DIR}/dispatch-stall.state.json"
DISPATCH_RECOVERY_STATE_FILE="${PID_DIR}/dispatch-recovery.state.json"
DISPATCH_RECOVERY_LOG_FILE="${PID_DIR}/dispatch-recovery.log"
HANDOFF_FLAG="${PID_DIR}/ready-for-codex.flag"
PENDING_REVIEW_FILE="${PID_DIR}/pending-review.json"
POINTER="${BRAID_ROOT}/runs/active-run"
BROKER_SOCK="${BRAID_ROOT}/runs/braidd.sock"
BROKER_PID_FILE="${BRAID_ROOT}/runs/braidd.pid"
ACTIVE_RUN_ID=""
ACTIVE_STATE=""
ACTIVE_UPDATED_AT=""
ACTIVE_INSTRUCTION_ID=""
ACTIVE_LATEST_RESPONSE_FILE=""
ACTIVE_LATEST_RESPONSE_INSTRUCTION_ID=""
ACTIVE_CLAUDE_TARGET=""
ACTIVE_CLAUDE_TARGET_EXISTS=""
ACTIVE_CODEX_TARGET=""
ACTIVE_CODEX_TARGET_EXISTS=""
TOPOLOGY_JSON=""
ACTIVE_INTERACTION_GATE_FILE=""
PENDING_REVIEW_RUN_ID=""
PENDING_REVIEW_INSTRUCTION_ID=""
HELPERS_NEED_RECOVERY=0

timestamp_age_seconds() {
  local iso_timestamp="$1"
  if [[ -z "$iso_timestamp" ]]; then
    return 1
  fi
  python3 - "$iso_timestamp" <<'PY'
from datetime import datetime, timezone
import sys

raw = sys.argv[1].strip()
if not raw:
    raise SystemExit(1)
dt = datetime.fromisoformat(raw.replace('Z', '+00:00'))
now = datetime.now(timezone.utc)
print(int((now - dt).total_seconds()))
PY
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

print_pid_status() {
  local label="$1"
  local pid_file="$2"
  local required="${3:-1}"
  local probe=""
  probe="$(pid_file_probe "$pid_file")"
  case "$probe" in
    none)
      echo "${label}: none"
      if [[ "$required" -eq 1 ]]; then
        HELPERS_NEED_RECOVERY=1
      fi
      ;;
    stale)
      echo "${label}: stale"
      if [[ "$required" -eq 1 ]]; then
        HELPERS_NEED_RECOVERY=1
      fi
      ;;
    *:permission)
      echo "${label}: ${probe%%:*} (running; permission-limited)"
      ;;
    *:running)
      echo "${label}: ${probe%%:*} (running)"
      ;;
    *)
      echo "${label}: unknown"
      if [[ "$required" -eq 1 ]]; then
        HELPERS_NEED_RECOVERY=1
      fi
      ;;
  esac
}

echo "repo_root: $ROOT"
echo "braid_root: $BRAID_ROOT"
echo "lane_state_dir: $PID_DIR"

if [[ -f "$POINTER" ]]; then
  RUN_ID="$(tr -d '[:space:]' < "$POINTER")"
  ACTIVE_RUN_ID="$RUN_ID"
  echo "active_run: $RUN_ID"
  if [[ -f "${BRAID_ROOT}/runs/${RUN_ID}/run.json" ]]; then
    jq '{run_id, project_root, project_slug, claude_session_id, transcript_path, tmux_target, created_at, completed_at}' \
      "${BRAID_ROOT}/runs/${RUN_ID}/run.json"
    ACTIVE_CLAUDE_TARGET="$(jq -r '.tmux_target // empty' "${BRAID_ROOT}/runs/${RUN_ID}/run.json" 2>/dev/null || true)"
  fi
  if [[ -f "${BRAID_ROOT}/runs/${RUN_ID}/status.json" ]]; then
    echo "--- status ---"
    jq '.' "${BRAID_ROOT}/runs/${RUN_ID}/status.json"
    ACTIVE_STATE="$(jq -r '.state // empty' "${BRAID_ROOT}/runs/${RUN_ID}/status.json" 2>/dev/null || true)"
    ACTIVE_UPDATED_AT="$(jq -r '.updated_at // empty' "${BRAID_ROOT}/runs/${RUN_ID}/status.json" 2>/dev/null || true)"
    ACTIVE_INSTRUCTION_ID="$(jq -r '.instruction_id // empty' "${BRAID_ROOT}/runs/${RUN_ID}/status.json" 2>/dev/null || true)"
  fi
  ACTIVE_LATEST_RESPONSE_FILE="$(find "${BRAID_ROOT}/runs/${RUN_ID}/responses" -maxdepth 1 -type f -name '*.json' 2>/dev/null | sort | tail -1 || true)"
  if [[ -n "$ACTIVE_LATEST_RESPONSE_FILE" && -f "$ACTIVE_LATEST_RESPONSE_FILE" ]]; then
    ACTIVE_LATEST_RESPONSE_INSTRUCTION_ID="$(jq -r '.instruction_id // empty' "$ACTIVE_LATEST_RESPONSE_FILE" 2>/dev/null || true)"
  fi
  ACTIVE_INTERACTION_GATE_FILE="${BRAID_ROOT}/runs/${RUN_ID}/interaction-gate.json"
  QUEUE_COUNT="$(find "${BRAID_ROOT}/runs/${RUN_ID}/queue" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')"
  echo "queue_depth_fs: ${QUEUE_COUNT}"
else
  echo "active_run: none"
fi

TOPOLOGY_JSON="$(claudex_bridge_topology_json "$BRAID_ROOT" "$PID_DIR" 2>/dev/null || true)"
if [[ -n "$TOPOLOGY_JSON" ]]; then
  echo "--- lane_topology ---"
  printf '%s\n' "$TOPOLOGY_JSON" | jq '{
    active_run_id,
    session_name,
    pair_window_target,
    claude: {
      target: .claude.target,
      target_source: .claude.target_source,
      target_exists: .claude.target_exists,
      pane_id: .claude.pane_id,
      pane_id_source: .claude.pane_id_source,
      authoritative: .claude.authoritative
    },
    codex: {
      target: .codex.target,
      target_source: .codex.target_source,
      target_exists: .codex.target_exists,
      pane_id: .codex.pane_id,
      pane_id_source: .codex.pane_id_source,
      authoritative: .codex.authoritative
    },
    issues
  }'
  ACTIVE_CLAUDE_TARGET="$(printf '%s\n' "$TOPOLOGY_JSON" | jq -r '.claude.target // empty' 2>/dev/null || true)"
  ACTIVE_CLAUDE_TARGET_EXISTS="$(printf '%s\n' "$TOPOLOGY_JSON" | jq -r '.claude.target_exists // empty' 2>/dev/null || true)"
  ACTIVE_CODEX_TARGET="$(printf '%s\n' "$TOPOLOGY_JSON" | jq -r '.codex.target // empty' 2>/dev/null || true)"
  ACTIVE_CODEX_TARGET_EXISTS="$(printf '%s\n' "$TOPOLOGY_JSON" | jq -r '.codex.target_exists // empty' 2>/dev/null || true)"
fi

if [[ -S "$BROKER_SOCK" ]]; then
  echo "broker: up ($BROKER_SOCK)"
else
  echo "broker: down"
fi

if [[ -f "$BROKER_PID_FILE" ]]; then
  BROKER_PID="$(tr -d '[:space:]' < "$BROKER_PID_FILE" || true)"
  if [[ -n "$BROKER_PID" ]] && kill -0 "$BROKER_PID" 2>/dev/null; then
    echo "broker_pid: $BROKER_PID (running)"
  elif [[ -S "$BROKER_SOCK" ]]; then
    echo "broker_pid: socket_present (pid file stale)"
  else
    echo "broker_pid: stale"
  fi
else
  if [[ -S "$BROKER_SOCK" ]]; then
    echo "broker_pid: socket_present (pid file missing)"
  else
    echo "broker_pid: none"
  fi
fi

print_pid_status "auto_submit_pid" "$PID_FILE"
print_pid_status "watchdog_pid" "$WATCHDOG_PID_FILE"
print_pid_status "progress_monitor_pid" "$PROGRESS_PID_FILE"
print_pid_status "codex_approver_pid" "$APPROVER_PID_FILE" 0
print_pid_status "worker_approver_pid" "$WORKER_APPROVER_PID_FILE" 0

if [[ -f "$HANDOFF_FLAG" ]]; then
  echo "--- handoff ---"
  cat "$HANDOFF_FLAG"
fi

if [[ -f "$PENDING_REVIEW_FILE" ]]; then
  echo "--- pending_review ---"
  jq '.' "$PENDING_REVIEW_FILE"
  PENDING_REVIEW_RUN_ID="$(jq -r '.run_id // empty' "$PENDING_REVIEW_FILE" 2>/dev/null || true)"
  PENDING_REVIEW_INSTRUCTION_ID="$(jq -r '.instruction_id // empty' "$PENDING_REVIEW_FILE" 2>/dev/null || true)"
fi

if [[ -n "$ACTIVE_INTERACTION_GATE_FILE" && -f "$ACTIVE_INTERACTION_GATE_FILE" ]]; then
  echo "--- interaction_gate ---"
  jq '.' "$ACTIVE_INTERACTION_GATE_FILE"
fi

if [[ -f "$PROGRESS_SNAPSHOT_FILE" ]]; then
  echo "--- progress_monitor ---"
  jq '.' "$PROGRESS_SNAPSHOT_FILE"
  SNAPSHOT_SAMPLED_AT="$(jq -r '.sampled_at // empty' "$PROGRESS_SNAPSHOT_FILE" 2>/dev/null || true)"
  SNAPSHOT_RUN_ID="$(jq -r '.active_run_id // empty' "$PROGRESS_SNAPSHOT_FILE" 2>/dev/null || true)"
  SNAPSHOT_CODEX_TARGET="$(jq -r '.codex_target // empty' "$PROGRESS_SNAPSHOT_FILE" 2>/dev/null || true)"
  SNAPSHOT_STATE="$(jq -r '.bridge_state // empty' "$PROGRESS_SNAPSHOT_FILE" 2>/dev/null || true)"
  SNAPSHOT_INTERVAL_SECONDS="$(jq -r '.monitor_interval_seconds // empty' "$PROGRESS_SNAPSHOT_FILE" 2>/dev/null || true)"
  SNAPSHOT_SUMMARY="$(jq -r '.summary // empty' "$PROGRESS_SNAPSHOT_FILE" 2>/dev/null || true)"
  SNAPSHOT_ISSUES_COUNT="$(jq -r '.issues | length' "$PROGRESS_SNAPSHOT_FILE" 2>/dev/null || printf '0')"
  SNAPSHOT_PENDING_REVIEW_INSTRUCTION_ID="$(jq -r '.pending_review_instruction_id // empty' "$PROGRESS_SNAPSHOT_FILE" 2>/dev/null || true)"
  SNAPSHOT_LATEST_RESPONSE_INSTRUCTION_ID="$(jq -r '.latest_response_instruction_id // empty' "$PROGRESS_SNAPSHOT_FILE" 2>/dev/null || true)"
  SNAPSHOT_AGE_SECONDS="$(timestamp_age_seconds "$SNAPSHOT_SAMPLED_AT" 2>/dev/null || true)"
  if [[ -n "$SNAPSHOT_CODEX_TARGET" ]] && { [[ -z "$ACTIVE_RUN_ID" ]] || [[ "$SNAPSHOT_RUN_ID" == "$ACTIVE_RUN_ID" ]]; } && [[ -z "$ACTIVE_CODEX_TARGET" ]]; then
    ACTIVE_CODEX_TARGET="$SNAPSHOT_CODEX_TARGET"
  fi
  SNAPSHOT_MAX_AGE_SECONDS="${CLAUDEX_PROGRESS_MONITOR_MAX_AGE_SECONDS:-}"
  if [[ -z "$SNAPSHOT_MAX_AGE_SECONDS" ]]; then
    if [[ "$SNAPSHOT_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] && [[ "$SNAPSHOT_INTERVAL_SECONDS" -gt 0 ]]; then
      SNAPSHOT_MAX_AGE_SECONDS="$((SNAPSHOT_INTERVAL_SECONDS + 60))"
    else
      SNAPSHOT_MAX_AGE_SECONDS="1860"
    fi
  fi
  SNAPSHOT_AGE_OK="unknown"
  if [[ "$SNAPSHOT_AGE_SECONDS" =~ ^[0-9]+$ ]] && [[ "$SNAPSHOT_MAX_AGE_SECONDS" =~ ^[0-9]+$ ]]; then
    if (( SNAPSHOT_AGE_SECONDS <= SNAPSHOT_MAX_AGE_SECONDS )); then
      SNAPSHOT_AGE_OK="true"
    else
      SNAPSHOT_AGE_OK="false"
    fi
  fi
  SNAPSHOT_STATE_MATCH="unknown"
  if [[ -n "$ACTIVE_STATE" && -n "$SNAPSHOT_STATE" ]]; then
    if [[ "$SNAPSHOT_STATE" == "$ACTIVE_STATE" ]]; then
      SNAPSHOT_STATE_MATCH="true"
    else
      SNAPSHOT_STATE_MATCH="false"
    fi
  fi
  SNAPSHOT_PENDING_REVIEW_MATCH="unknown"
  if [[ -n "$PENDING_REVIEW_INSTRUCTION_ID" || -n "$SNAPSHOT_PENDING_REVIEW_INSTRUCTION_ID" ]]; then
    if [[ "$SNAPSHOT_PENDING_REVIEW_INSTRUCTION_ID" == "$PENDING_REVIEW_INSTRUCTION_ID" ]]; then
      SNAPSHOT_PENDING_REVIEW_MATCH="true"
    else
      SNAPSHOT_PENDING_REVIEW_MATCH="false"
    fi
  fi
  SNAPSHOT_LATEST_RESPONSE_MATCH="unknown"
  if [[ -n "$ACTIVE_LATEST_RESPONSE_INSTRUCTION_ID" || -n "$SNAPSHOT_LATEST_RESPONSE_INSTRUCTION_ID" ]]; then
    if [[ "$SNAPSHOT_LATEST_RESPONSE_INSTRUCTION_ID" == "$ACTIVE_LATEST_RESPONSE_INSTRUCTION_ID" ]]; then
      SNAPSHOT_LATEST_RESPONSE_MATCH="true"
    else
      SNAPSHOT_LATEST_RESPONSE_MATCH="false"
    fi
  fi
  # @decision DEC-GS1-SNAPSHOT-HEALTH-RACE-001
  # Title: SNAPSHOT_AGE_OK is the single freshness authority for snapshot health
  # Status: accepted
  # Rationale: The progress monitor is a periodic writer; between samples, the
  # live instruction-id fields (ACTIVE_LATEST_RESPONSE_INSTRUCTION_ID, etc.)
  # race ahead of the last-sampled snapshot values. A race-based diff between
  # live and snapshot fields is NOT a health signal — it is expected in any
  # active+waiting_for_codex run. The *_MATCH lines remain as informational
  # diagnostics only. Only SNAPSHOT_AGE_OK, SNAPSHOT_SUMMARY, and
  # SNAPSHOT_ISSUES_COUNT are authoritative for health classification.
  # The `lagging` branch that promoted *_MATCH==false to a health state has
  # been removed; it produced false positives on every healthy active run.
  SNAPSHOT_HEALTH="healthy"
  if [[ "${SNAPSHOT_SUMMARY:-healthy}" != "healthy" ]] || [[ "$SNAPSHOT_ISSUES_COUNT" -gt 0 ]] || [[ "$SNAPSHOT_AGE_OK" == "false" ]]; then
    SNAPSHOT_HEALTH="degraded"
    HELPERS_NEED_RECOVERY=1
  fi
  echo "progress_monitor_snapshot_age_seconds: ${SNAPSHOT_AGE_SECONDS:-unknown}"
  echo "progress_monitor_snapshot_max_age_seconds: ${SNAPSHOT_MAX_AGE_SECONDS:-unknown}"
  echo "progress_monitor_snapshot_age_ok: ${SNAPSHOT_AGE_OK:-unknown}"
  echo "progress_monitor_snapshot_summary: ${SNAPSHOT_SUMMARY:-unknown}"
  echo "progress_monitor_snapshot_issue_count: ${SNAPSHOT_ISSUES_COUNT:-0}"
  if [[ -n "$ACTIVE_RUN_ID" ]]; then
    if [[ "$SNAPSHOT_RUN_ID" == "$ACTIVE_RUN_ID" ]]; then
      echo "progress_monitor_snapshot_run_match: true"
    else
      echo "progress_monitor_snapshot_run_match: false"
    fi
  fi
  if [[ -n "$ACTIVE_CODEX_TARGET" ]]; then
    if [[ "$SNAPSHOT_CODEX_TARGET" == "$ACTIVE_CODEX_TARGET" ]]; then
      echo "progress_monitor_snapshot_codex_target_match: true"
    else
      echo "progress_monitor_snapshot_codex_target_match: false"
    fi
  fi
  if [[ "$SNAPSHOT_STATE_MATCH" != "unknown" ]]; then
    echo "progress_monitor_snapshot_state_match: $SNAPSHOT_STATE_MATCH"
  fi
  if [[ "$SNAPSHOT_PENDING_REVIEW_MATCH" != "unknown" ]]; then
    echo "progress_monitor_snapshot_pending_review_match: $SNAPSHOT_PENDING_REVIEW_MATCH"
  fi
  if [[ "$SNAPSHOT_LATEST_RESPONSE_MATCH" != "unknown" ]]; then
    echo "progress_monitor_snapshot_latest_response_match: $SNAPSHOT_LATEST_RESPONSE_MATCH"
  fi
  echo "progress_monitor_snapshot_health: $SNAPSHOT_HEALTH"
fi

if [[ -f "$PROGRESS_ALERT_FILE" ]]; then
  echo "--- progress_alert ---"
  jq '.' "$PROGRESS_ALERT_FILE"
fi

if [[ -f "$DISPATCH_STALL_STATE_FILE" ]]; then
  echo "--- dispatch_stall ---"
  jq '.' "$DISPATCH_STALL_STATE_FILE"
  STALL_RUN_ID="$(jq -r '.run_id // empty' "$DISPATCH_STALL_STATE_FILE" 2>/dev/null || true)"
  STALL_INSTRUCTION_ID="$(jq -r '.instruction_id // empty' "$DISPATCH_STALL_STATE_FILE" 2>/dev/null || true)"
  if [[ -z "$ACTIVE_RUN_ID" || "$STALL_RUN_ID" == "$ACTIVE_RUN_ID" ]]; then
    echo "dispatch_stall_active: true"
    if [[ -n "$ACTIVE_INSTRUCTION_ID" && "$STALL_INSTRUCTION_ID" == "$ACTIVE_INSTRUCTION_ID" ]]; then
      echo "dispatch_stall_instruction_match: true"
    fi
    HELPERS_NEED_RECOVERY=1
  else
    echo "dispatch_stall_active: false"
  fi
fi

if [[ -f "$DISPATCH_RECOVERY_STATE_FILE" ]]; then
  echo "--- dispatch_recovery_state ---"
  jq '.' "$DISPATCH_RECOVERY_STATE_FILE"
fi

echo "daemon_log: $LOG_FILE"
echo "watchdog_log: $WATCHDOG_LOG_FILE"
echo "progress_monitor_log: $PROGRESS_LOG_FILE"
echo "codex_approver_log: $APPROVER_LOG_FILE"
echo "worker_approver_log: $WORKER_APPROVER_LOG_FILE"
echo "dispatch_recovery_log: $DISPATCH_RECOVERY_LOG_FILE"

if [[ -n "$ACTIVE_CODEX_TARGET" && "$ACTIVE_CODEX_TARGET_EXISTS" == "true" && "$HELPERS_NEED_RECOVERY" -eq 1 ]]; then
  echo "--- supervisor_recovery ---"
  echo "codex_target: $ACTIVE_CODEX_TARGET"
  echo "restart_command: ./scripts/claudex-supervisor-restart.sh --codex-target $ACTIVE_CODEX_TARGET"
fi

if [[ -f "$DISPATCH_STALL_STATE_FILE" ]]; then
  echo "--- dispatch_recovery ---"
  echo "recovery_command: ./scripts/claudex-dispatch-recover.sh"
fi
