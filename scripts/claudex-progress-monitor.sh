#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
ROOT="$(git rev-parse --show-toplevel)"
source "${SCRIPT_DIR}/claudex-common.sh"
BRAID_ROOT="${BRAID_ROOT:-${ROOT}/.b2r}"
STATE_DIR="${BRAID_ROOT}/runs"
PID_DIR="${CLAUDEX_STATE_DIR:-$(claudex_state_dir "$ROOT" "$BRAID_ROOT")}"
PID_FILE="${PID_DIR}/progress-monitor.pid"
LOG_FILE="${PID_DIR}/progress-monitor.log"
SNAPSHOT_FILE="${PID_DIR}/progress-monitor.latest.json"
ALERT_FILE="${PID_DIR}/progress-monitor.alert.json"
PENDING_REVIEW_FILE="${PID_DIR}/pending-review.json"

INTERVAL_SECONDS="${CLAUDEX_PROGRESS_MONITOR_INTERVAL_SECONDS:-1800}"
RUN_ONCE=0
CODEX_TARGET=""

usage() {
  cat <<EOF
Usage: $(basename "$0") --codex-target SESSION:WINDOW.PANE [--once]

Samples the live ClauDEX bridge and Codex operator pane to verify that the
overnight cutover session is still progressing.

Environment:
  CLAUDEX_PROGRESS_MONITOR_INTERVAL_SECONDS   Poll interval in seconds (default: 1800)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --codex-target)
      CODEX_TARGET="$2"
      shift 2
      ;;
    --once)
      RUN_ONCE=1
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

if [[ -z "$CODEX_TARGET" ]]; then
  echo "--codex-target is required" >&2
  usage >&2
  exit 1
fi

mkdir -p "$PID_DIR"

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  printf '[progress-monitor] %s %s\n' "$(timestamp)" "$*" >&2
}

cleanup_monitor() {
  if [[ "$RUN_ONCE" -eq 1 ]]; then
    return 0
  fi
  local current=""
  current="$(tr -d '[:space:]' < "$PID_FILE" 2>/dev/null || true)"
  if [[ "$current" == "$$" ]]; then
    rm -f "$PID_FILE"
  fi
}

read_json_field() {
  local file="$1"
  local expr="$2"
  if [[ ! -f "$file" ]]; then
    return 1
  fi
  jq -r "$expr" "$file" 2>/dev/null
}

current_snapshot() {
  local run_id=""
  local run_dir=""
  local status_file=""
  local state="inactive"
  local updated_at=""
  local latest_response_file=""
  local latest_response_instruction=""
  local pending_run_id=""
  local pending_instruction_id=""
  local interaction_gate_file=""
  local interaction_gate_status=""
  local interaction_gate_type=""
  local codex_excerpt=""
  local codex_hash=""
  local issues='[]'

  if [[ -f "${STATE_DIR}/active-run" ]]; then
    run_id="$(tr -d '[:space:]' < "${STATE_DIR}/active-run" 2>/dev/null || true)"
  fi

  if [[ -n "$run_id" ]]; then
    run_dir="${STATE_DIR}/${run_id}"
    status_file="${run_dir}/status.json"
    if [[ -f "$status_file" ]]; then
      state="$(read_json_field "$status_file" '.state // "unknown"' || printf 'unknown')"
      updated_at="$(read_json_field "$status_file" '.updated_at // ""' || printf '')"
    fi
    interaction_gate_file="${run_dir}/interaction-gate.json"
    if [[ -f "$interaction_gate_file" ]]; then
      interaction_gate_status="$(read_json_field "$interaction_gate_file" '.status // ""' || printf '')"
      interaction_gate_type="$(read_json_field "$interaction_gate_file" '.gate_type // ""' || printf '')"
      if [[ "$interaction_gate_status" == "open" ]]; then
        state="interaction_gate"
        issues="$(jq -cn \
          --argjson existing "$issues" \
          --arg gate_type "$interaction_gate_type" \
          '$existing + [{"code":"interaction_gate_open","severity":"error","gate_type":$gate_type}]')"
      fi
    fi
    latest_response_file="$(find "${run_dir}/responses" -maxdepth 1 -type f -name '*.json' 2>/dev/null | sort | tail -1 || true)"
    if [[ -n "$latest_response_file" && -f "$latest_response_file" ]]; then
      latest_response_instruction="$(read_json_field "$latest_response_file" '.instruction_id // ""' || printf '')"
    fi
  fi

  if [[ -f "$PENDING_REVIEW_FILE" ]]; then
    pending_run_id="$(read_json_field "$PENDING_REVIEW_FILE" '.run_id // ""' || printf '')"
    pending_instruction_id="$(read_json_field "$PENDING_REVIEW_FILE" '.instruction_id // ""' || printf '')"
  fi

  if codex_excerpt="$(tmux capture-pane -p -t "$CODEX_TARGET" 2>/dev/null | tail -60)"; then
    codex_hash="$(printf '%s' "$codex_excerpt" | cksum | awk '{print $1}')"
    if [[ -z "${codex_excerpt//[[:space:]]/}" ]]; then
      issues="$(jq -cn \
        --argjson existing "$issues" \
        '$existing + [{"code":"codex_pane_empty","severity":"error"}]')"
    elif [[ -n "$run_id" && "$state" != "inactive" && "$codex_excerpt" == *"Stop hook (stopped)"* ]]; then
      issues="$(jq -cn \
        --argjson existing "$issues" \
        '$existing + [{"code":"codex_supervisor_stopped","severity":"error"}]')"
    fi
  else
    codex_excerpt=""
    codex_hash=""
    issues="$(jq -cn '[{"code":"codex_pane_unavailable","severity":"error"}]')"
  fi

  if [[ -n "$run_id" && -n "$pending_run_id" && "$pending_run_id" != "$run_id" ]]; then
    issues="$(jq -cn \
      --argjson existing "$issues" \
      --arg active "$run_id" \
      --arg pending "$pending_run_id" \
      '$existing + [{"code":"pending_review_run_mismatch","severity":"error","active_run_id":$active,"pending_run_id":$pending}]')"
  fi

  jq -cn \
    --arg sampled_at "$(timestamp)" \
    --arg codex_target "$CODEX_TARGET" \
    --argjson monitor_interval_seconds "$INTERVAL_SECONDS" \
    --arg run_id "$run_id" \
    --arg state "$state" \
    --arg updated_at "$updated_at" \
    --arg latest_response_file "$latest_response_file" \
    --arg latest_response_instruction "$latest_response_instruction" \
    --arg pending_run_id "$pending_run_id" \
    --arg pending_instruction_id "$pending_instruction_id" \
    --arg codex_hash "$codex_hash" \
    --arg codex_excerpt "$codex_excerpt" \
    --argjson issues "$issues" \
    '{
      sampled_at: $sampled_at,
      codex_target: $codex_target,
      monitor_interval_seconds: $monitor_interval_seconds,
      active_run_id: ($run_id | select(length > 0) // null),
      bridge_state: $state,
      bridge_updated_at: ($updated_at | select(length > 0) // null),
      latest_response_file: ($latest_response_file | select(length > 0) // null),
      latest_response_instruction_id: ($latest_response_instruction | select(length > 0) // null),
      pending_review_run_id: ($pending_run_id | select(length > 0) // null),
      pending_review_instruction_id: ($pending_instruction_id | select(length > 0) // null),
      codex_excerpt_hash: ($codex_hash | select(length > 0) // null),
      codex_excerpt: $codex_excerpt,
      issues: $issues
    }'
}

write_snapshot_and_alert() {
  local snapshot="$1"
  local previous=""
  local advancing="true"
  local stale="false"
  local summary="healthy"

  if [[ -f "$SNAPSHOT_FILE" ]]; then
    previous="$(cat "$SNAPSHOT_FILE" 2>/dev/null || true)"
  fi

  if [[ -n "$previous" ]]; then
    local prev_sig cur_sig
    prev_sig="$(printf '%s\n' "$previous" | jq -c '{active_run_id, bridge_state, bridge_updated_at, latest_response_file, latest_response_instruction_id, pending_review_run_id, pending_review_instruction_id, codex_excerpt_hash}' 2>/dev/null || true)"
    cur_sig="$(printf '%s\n' "$snapshot" | jq -c '{active_run_id, bridge_state, bridge_updated_at, latest_response_file, latest_response_instruction_id, pending_review_run_id, pending_review_instruction_id, codex_excerpt_hash}' 2>/dev/null || true)"
    if [[ -n "$prev_sig" && "$prev_sig" == "$cur_sig" ]]; then
      advancing="false"
      stale="true"
    fi
  fi

  if [[ "$(printf '%s\n' "$snapshot" | jq '.issues | length')" -gt 0 ]]; then
    summary="alert"
  elif [[ "$stale" == "true" ]]; then
    summary="stale"
  fi

  local final_snapshot
  final_snapshot="$(printf '%s\n' "$snapshot" | jq \
    --argjson advancing "$advancing" \
    --argjson stale "$stale" \
    --arg summary "$summary" \
    '. + {advancing: $advancing, stale: $stale, summary: $summary}')"

  printf '%s\n' "$final_snapshot" > "$SNAPSHOT_FILE"
  printf '%s\n' "$final_snapshot" >> "$LOG_FILE"

  if [[ "$summary" == "healthy" ]]; then
    rm -f "$ALERT_FILE"
  else
    printf '%s\n' "$final_snapshot" > "$ALERT_FILE"
  fi

  if [[ "$summary" == "healthy" ]]; then
    log "sample ok"
  else
    log "sample ${summary}"
  fi
}

monitor_tick() {
  local snapshot
  snapshot="$(current_snapshot)"
  write_snapshot_and_alert "$snapshot"
}

trap cleanup_monitor EXIT INT TERM

if [[ "$RUN_ONCE" -eq 0 ]]; then
  printf '%s\n' "$$" > "$PID_FILE"
fi

while true; do
  monitor_tick
  if [[ "$RUN_ONCE" -eq 1 ]]; then
    exit 0
  fi
  sleep "$INTERVAL_SECONDS"
done
