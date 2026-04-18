#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------------
# Self-exec on script drift (DEC-CLAUDEX-BRIDGE-SELF-EXEC-001)
#
# Bash parses function bodies into memory at script load time. If this
# script file is edited in place while a long-running watchdog is active,
# the running process keeps executing the OLD code until someone manually
# restarts it. That is exactly how the repo-local bridge ended up with a
# stale `pending-review.json`: the running watchdog had been started before
# `write_pending_review` was added to the file, so every tick it was still
# advancing the handoff flag but never writing the pending-review artifact.
#
# To heal this automatically we capture the script's identity at load time
# (path + mtime signature + original argv) and, after each tick in the
# long-running loop, re-exec ourselves if the on-disk signature has changed.
# `exec` keeps the process PID, so the pid file stays valid and the trap
# does not need to rewrite it.
#
# The --once path is unaffected because it returns before the loop starts.
# -------------------------------------------------------------------------
ORIGINAL_INVOCATION=("$0" "$@")
SCRIPT_PATH="$(cd "$(dirname -- "$0")" && pwd)/$(basename -- "$0")"
_WATCHDOG_DIR="$(dirname "$SCRIPT_PATH")"
RUNTIME_CLI="${_WATCHDOG_DIR}/../runtime/cli.py"

script_signature() {
  # Portable mtime-as-epoch: BSD stat first, GNU stat second, 0 fallback.
  stat -f '%m' "$SCRIPT_PATH" 2>/dev/null \
    || stat -c '%Y' "$SCRIPT_PATH" 2>/dev/null \
    || echo 0
}
SCRIPT_START_SIGNATURE="$(script_signature)"

ROOT="$(git rev-parse --show-toplevel)"
source "${_WATCHDOG_DIR}/claudex-common.sh"
BRAID_ROOT="${BRAID_ROOT:-${ROOT}/.b2r}"
AUTO_SUBMIT_SCRIPT="${ROOT}/scripts/claudex-auto-submit.sh"
STATE_DIR="${BRAID_ROOT}/runs"
PID_DIR="${CLAUDEX_STATE_DIR:-$(claudex_state_dir "$ROOT" "$BRAID_ROOT")}"
AUTO_PID_FILE="${PID_DIR}/auto-submit.pid"
AUTO_LOG_FILE="${PID_DIR}/auto-submit.log"
WATCHDOG_PID_FILE="${PID_DIR}/watchdog.pid"
BROKER_SOCK="${STATE_DIR}/braidd.sock"
BROKER_PID_FILE="${STATE_DIR}/braidd.pid"
BROKER_LOG_FILE="${PID_DIR}/broker.log"
HANDOFF_FLAG="${PID_DIR}/ready-for-codex.flag"
PENDING_REVIEW_FILE="${PID_DIR}/pending-review.json"
PROGRESS_SNAPSHOT_FILE="${PID_DIR}/progress-monitor.latest.json"
PROGRESS_ALERT_FILE="${PID_DIR}/progress-monitor.alert.json"
DISPATCH_STALL_STATE_FILE="${PID_DIR}/dispatch-stall.state.json"
DISPATCH_RECOVERY_SCRIPT="${ROOT}/scripts/claudex-dispatch-recover.sh"
DISPATCH_RECOVERY_LOG_FILE="${PID_DIR}/dispatch-recovery.log"
DISPATCH_RECOVERY_STATE_FILE="${PID_DIR}/dispatch-recovery.state.json"
RELAY_PROMPT_RECOVERY_STATE_FILE="${PID_DIR}/relay-prompt-recovery.state.json"
SUPERVISOR_RESTART_SCRIPT="${ROOT}/scripts/claudex-supervisor-restart.sh"
SUPERVISOR_RECOVERY_LOG_FILE="${PID_DIR}/supervisor-recovery.log"
SUPERVISOR_RECOVERY_STATE_FILE="${PID_DIR}/supervisor-recovery.state.json"

POLL_INTERVAL="${CLAUDEX_WATCHDOG_POLL_INTERVAL:-5}"
AUTO_HAND_BACK_USER_DRIVING="${CLAUDEX_AUTO_HAND_BACK_USER_DRIVING:-0}"
DISPATCH_RECOVERY_COOLDOWN_SECONDS="${CLAUDEX_DISPATCH_RECOVERY_COOLDOWN_SECONDS:-900}"
SUPERVISOR_RECOVERY_COOLDOWN_SECONDS="${CLAUDEX_SUPERVISOR_RECOVERY_COOLDOWN_SECONDS:-900}"
CLAUDEX_DISPATCH_STALL_THRESHOLD_SECONDS="${CLAUDEX_DISPATCH_STALL_THRESHOLD_SECONDS:-120}"
CLAUDEX_DISPATCH_STALL_TIMEOUT_COUNT="${CLAUDEX_DISPATCH_STALL_TIMEOUT_COUNT:-3}"
CLAUDEX_RELAY_PROMPT_NUDGE_COOLDOWN_SECONDS="${CLAUDEX_RELAY_PROMPT_NUDGE_COOLDOWN_SECONDS:-30}"
RUN_ONCE=0
TMUX_TARGET=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [--once] [--tmux-target SESSION:WINDOW.PANE]

Watches the ClauDEX bridge transport and keeps it armed:
- restarts auto-submit when its pid file is stale
- restarts the broker when the socket disappears
- writes a ready-for-codex flag + pending-review artifact when Claude hands control back

Environment:
  CLAUDEX_WATCHDOG_POLL_INTERVAL         Poll interval in seconds (default: 5)
  CLAUDEX_AUTO_HAND_BACK_USER_DRIVING    When 1, auto-run braid resume for the
                                         dedicated overnight profile if the
                                         relay drifts into user_driving.
  CLAUDEX_DISPATCH_RECOVERY_COOLDOWN_SECONDS
                                         Minimum seconds between identical
                                         dispatch recovery attempts
                                         (default: 900)
  CLAUDEX_SUPERVISOR_RECOVERY_COOLDOWN_SECONDS
                                         Minimum seconds between identical
                                         supervisor auto-restart attempts
                                         (default: 900)
  CLAUDEX_DISPATCH_STALL_THRESHOLD_SECONDS
                                         Seconds a queued instruction may sit
                                         unclaimed before dispatch is treated
                                         as stalled (default: 120)
  CLAUDEX_DISPATCH_STALL_TIMEOUT_COUNT   Auto-submit timeout count required in
                                         recent logs before dispatch is marked
                                         stalled (default: 3)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --once)
      RUN_ONCE=1
      shift
      ;;
    --tmux-target)
      TMUX_TARGET="$2"
      shift 2
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

mkdir -p "$PID_DIR"

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  printf '[watchdog] %s %s\n' "$(timestamp)" "$*" >&2
}

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

cleanup_watchdog() {
  trap - EXIT INT TERM
  if [[ "$RUN_ONCE" -eq 1 ]]; then
    return 0
  fi
  local current=""
  current="$(pid_from_file "$WATCHDOG_PID_FILE" || true)"
  if [[ "$current" == "$$" ]]; then
    rm -f "$WATCHDOG_PID_FILE"
  fi
}

pid_from_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    return 1
  fi
  local pid
  pid="$(tr -d '[:space:]' < "$file" 2>/dev/null || true)"
  if [[ -z "$pid" ]]; then
    return 1
  fi
  printf '%s\n' "$pid"
}

pid_is_live() {
  local file="$1"
  local pid
  pid="$(pid_from_file "$file")" || return 1
  kill -0 "$pid" 2>/dev/null
}

emit_live_pid_from_file() {
  local file="$1"
  local pid
  pid="$(pid_from_file "$file" || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s\n' "$pid"
}

list_broker_pids() {
  emit_live_pid_from_file "$BROKER_PID_FILE" && return 0
  if [[ "${CLAUDEX_ALLOW_PGREP_FALLBACK:-0}" == "1" ]]; then
    pgrep -f -x "node ${BRAID_ROOT}/braidd.mjs --socket ${BROKER_SOCK}" || true
  fi
}

list_auto_submit_pids() {
  {
    emit_live_pid_from_file "$AUTO_PID_FILE" || true
    if [[ "${CLAUDEX_ALLOW_PGREP_FALLBACK:-0}" == "1" ]]; then
      pgrep -f -x "bash ${AUTO_SUBMIT_SCRIPT}" || true
    fi
  } | awk 'NF && !seen[$0]++'
}

list_watchdog_pids() {
  emit_live_pid_from_file "$WATCHDOG_PID_FILE" && return 0
  if [[ "${CLAUDEX_ALLOW_PGREP_FALLBACK:-0}" != "1" ]]; then
    return 0
  fi
  local target="${TMUX_TARGET:-}"
  if [[ -n "$target" ]]; then
    pgrep -f "${SCRIPT_PATH} --tmux-target ${target}" || true
    return 0
  fi
  pgrep -f "${SCRIPT_PATH}" || true
}

kill_pid_list() {
  local pid
  for pid in "$@"; do
    [[ -n "$pid" ]] || continue
    kill "$pid" 2>/dev/null || true
  done
}

safe_rm() {
  rm -f "$@" 2>/dev/null || true
}

restart_broker() {
  local broker_pids=()
  local pid=""
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    broker_pids+=("$pid")
  done < <(list_broker_pids)

  if [[ -S "$BROKER_SOCK" ]]; then
    if [[ "${#broker_pids[@]}" -eq 1 ]]; then
      printf '%s\n' "${broker_pids[0]}" > "$BROKER_PID_FILE"
    fi
    if [[ "${#broker_pids[@]}" -le 1 ]]; then
      return 0
    fi
  fi

  if [[ "${#broker_pids[@]}" -eq 1 ]]; then
    printf '%s\n' "${broker_pids[0]}" > "$BROKER_PID_FILE"
    return 0
  fi

  if [[ "${#broker_pids[@]}" -gt 0 ]]; then
    log "broker drift detected (${#broker_pids[@]} processes for ${BROKER_SOCK}); restarting cleanly"
    kill_pid_list "${broker_pids[@]}"
    sleep 0.5
  fi

  safe_rm "$BROKER_PID_FILE"
  safe_rm "$BROKER_SOCK"

  log "broker socket missing; restarting broker"
  nohup node "${BRAID_ROOT}/braidd.mjs" --socket "$BROKER_SOCK" >>"$BROKER_LOG_FILE" 2>&1 &
  local broker_pid="$!"
  local ready=0
  for _i in 1 2 3 4 5 6; do
    sleep 0.5
    if [[ -S "$BROKER_SOCK" ]]; then
      ready=1
      break
    fi
    if ! kill -0 "$broker_pid" 2>/dev/null; then
      break
    fi
  done

  if [[ "$ready" -eq 1 ]]; then
    log "broker restarted"
  else
    log "broker restart failed"
  fi
}

restart_auto_submit() {
  local auto_submit_pids=()
  local pid=""
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    auto_submit_pids+=("$pid")
  done < <(list_auto_submit_pids)

  if [[ "${#auto_submit_pids[@]}" -eq 1 ]]; then
    printf '%s\n' "${auto_submit_pids[0]}" > "$AUTO_PID_FILE"
    return 0
  fi

  if [[ "${#auto_submit_pids[@]}" -gt 1 ]]; then
    log "auto-submit drift detected (${#auto_submit_pids[@]} processes); restarting cleanly"
    kill_pid_list "${auto_submit_pids[@]}"
    sleep 0.5
  fi

  safe_rm "$AUTO_PID_FILE"
  log "auto-submit not running; restarting daemon"
  BRAID_ROOT="$BRAID_ROOT" CLAUDEX_STATE_DIR="$PID_DIR" nohup "$AUTO_SUBMIT_SCRIPT" >>"$AUTO_LOG_FILE" 2>&1 &
  local auto_submit_pid="$!"
  sleep 0.2
  if emit_live_pid_from_file "$AUTO_PID_FILE" >/dev/null 2>&1; then
    return 0
  fi
  if kill -0 "$auto_submit_pid" 2>/dev/null; then
    printf '%s\n' "$auto_submit_pid" > "$AUTO_PID_FILE"
  else
    safe_rm "$AUTO_PID_FILE"
  fi
}

reconcile_completed_inflight() {
  local run_id="$1"
  local run_dir="$2"
  local run_json="$3"
  local status_json="$4"
  local inflight_json="${run_dir}/inflight.json"

  if [[ ! -f "$inflight_json" ]]; then
    return 1
  fi

  local instruction_id=""
  instruction_id="$(jq -r '.instruction_id // empty' "$inflight_json" 2>/dev/null || true)"
  if [[ -z "$instruction_id" ]]; then
    return 1
  fi

  local response_json="${run_dir}/responses/${instruction_id}.json"
  if [[ ! -f "$response_json" ]]; then
    return 1
  fi

  local completed_at="" session_id="" status_payload="" tmp_status=""
  completed_at="$(jq -r '.completed_at // empty' "$response_json" 2>/dev/null || true)"
  if [[ -z "$completed_at" ]]; then
    completed_at="$(timestamp)"
  fi

  session_id="$(jq -r '.claude_session_id // empty' "$run_json" 2>/dev/null || true)"
  tmp_status="${status_json}.tmp"

  if [[ -n "$session_id" ]]; then
    status_payload="$(jq -n \
      --arg sid "$session_id" \
      --arg ts "$completed_at" \
      '{
        state: "waiting_for_codex",
        control_mode: "review",
        active_session_id: $sid,
        instruction_id: null,
        updated_at: $ts
      }')"
  else
    status_payload="$(jq -n \
      --arg ts "$completed_at" \
      '{
        state: "waiting_for_codex",
        control_mode: "review",
        instruction_id: null,
        updated_at: $ts
      }')"
  fi

  rm -f "$inflight_json"
  printf '%s\n' "$status_payload" > "$tmp_status"
  mv "$tmp_status" "$status_json"

  local event_json=""
  event_json="$(jq -n \
    --arg iid "$instruction_id" \
    --arg ts "$(timestamp)" \
    '{type: "stale_inflight_reconciled", instruction_id: $iid, ts: $ts}')"
  printf '%s\n' "$event_json" >> "${run_dir}/events.jsonl"
  log "reconciled stale completed inflight ${instruction_id} into waiting_for_codex"
  return 0
}

recover_missing_response_from_transcript() {
  local run_id="$1"
  local run_dir="$2"
  local run_json="$3"
  local inflight_json="${run_dir}/inflight.json"

  if [[ ! -f "$inflight_json" ]]; then
    return 1
  fi

  local instruction_id="" response_json="" transcript_path="" submitted_at="" tmp_response=""
  instruction_id="$(jq -r '.instruction_id // empty' "$inflight_json" 2>/dev/null || true)"
  if [[ -z "$instruction_id" ]]; then
    return 1
  fi

  response_json="${run_dir}/responses/${instruction_id}.json"
  if [[ -f "$response_json" ]]; then
    return 1
  fi

  transcript_path="$(jq -r '.transcript_path // empty' "$run_json" 2>/dev/null || true)"
  if [[ -z "$transcript_path" || ! -f "$transcript_path" ]]; then
    return 1
  fi

  submitted_at="$(jq -r '.submitted_at // .queued_at // empty' "$inflight_json" 2>/dev/null || true)"
  tmp_response="${response_json}.tmp"

  if ! python3 - "$transcript_path" "$instruction_id" "$submitted_at" <<'PY' > "$tmp_response"; then
import json
import sys

transcript_path, instruction_id, min_timestamp = sys.argv[1:4]
latest = None

with open(transcript_path, 'r', encoding='utf-8') as handle:
    for raw_line in handle:
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        try:
            entry = json.loads(raw_line)
        except json.JSONDecodeError:
            continue
        if entry.get("type") != "assistant":
            continue
        message = entry.get("message") or {}
        if message.get("role") != "assistant":
            continue
        if message.get("stop_reason") != "end_turn":
            continue
        timestamp = entry.get("timestamp") or ""
        if min_timestamp and timestamp and timestamp < min_timestamp:
            continue
        text_blocks = []
        for item in message.get("content") or []:
            if item.get("type") == "text" and item.get("text"):
                text_blocks.append(item["text"])
        if not text_blocks:
            continue
        latest = {
            "instruction_id": instruction_id,
            "response": "\n\n".join(text_blocks),
            "transcript_path": transcript_path,
            "completed_at": timestamp or None,
            "recovered_from_transcript": True,
        }

if latest is None:
    raise SystemExit(1)

json.dump(latest, sys.stdout, indent=2)
sys.stdout.write("\n")
PY
    rm -f "$tmp_response"
    return 1
  fi

  mv "$tmp_response" "$response_json"
  printf '%s\n' "$(jq -n \
    --arg iid "$instruction_id" \
    --arg response_path "$response_json" \
    --arg ts "$(timestamp)" \
    '{type: "response_recovered_from_transcript", instruction_id: $iid, response_path: $response_path, ts: $ts}')" \
    >> "${run_dir}/events.jsonl"
  log "recovered missing response artifact from transcript for ${instruction_id}"
  return 0
}

reconcile_watchdog_processes() {
  [[ "$RUN_ONCE" -eq 0 ]] || return 0

  local watchdog_pids=()
  local pid=""
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    watchdog_pids+=("$pid")
  done < <(list_watchdog_pids)

  if [[ "${#watchdog_pids[@]}" -le 1 ]]; then
    return 0
  fi

  local stale_pids=()
  for pid in "${watchdog_pids[@]}"; do
    [[ "$pid" == "$$" ]] && continue
    stale_pids+=("$pid")
  done

  if [[ "${#stale_pids[@]}" -gt 0 ]]; then
    log "watchdog drift detected (${#watchdog_pids[@]} processes for ${TMUX_TARGET:-no-target}); pruning stale copies"
    kill_pid_list "${stale_pids[@]}"
    sleep 0.5
  fi
}

touch_handoff_flag() {
  local run_id="$1"
  local updated_at="$2"
  local current=""
  if [[ -f "$HANDOFF_FLAG" ]]; then
    current="$(cat "$HANDOFF_FLAG" 2>/dev/null || true)"
  fi
  local next="run_id=${run_id}
updated_at=${updated_at}
state=waiting_for_codex"
  if [[ "$current" != "$next" ]]; then
    printf '%s\n' "$next" > "$HANDOFF_FLAG"
    log "Claude finished; Codex review needed for run ${run_id}"
  fi
}

clear_handoff_flag() {
  safe_rm "$HANDOFF_FLAG"
}

write_pending_review() {
  local run_id="$1"
  local run_dir="$2"
  local updated_at="$3"
  local pending_dir=""
  pending_dir="$(dirname "$PENDING_REVIEW_FILE")"
  mkdir -p "$pending_dir"

  local tmp_file=""
  tmp_file="$(mktemp "${PENDING_REVIEW_FILE}.tmp.XXXXXX")"

  local latest_response_file=""
  latest_response_file="$(find "${run_dir}/responses" -maxdepth 1 -type f -name '*.json' 2>/dev/null | sort | tail -1 || true)"

  if [[ -z "$latest_response_file" || ! -f "$latest_response_file" ]]; then
    jq -n \
      --arg run_id "$run_id" \
      --arg updated_at "$updated_at" \
      '{
        run_id: $run_id,
        state: "waiting_for_codex",
        updated_at: $updated_at,
        response_available: false
      }' > "$tmp_file"
    mv -f "$tmp_file" "$PENDING_REVIEW_FILE"
    return 0
  fi

  jq -n \
    --arg run_id "$run_id" \
    --arg updated_at "$updated_at" \
    --arg response_path "$latest_response_file" \
    --slurpfile response "$latest_response_file" \
    '{
      run_id: $run_id,
      state: "waiting_for_codex",
      updated_at: $updated_at,
      response_available: true,
      instruction_id: ($response[0].instruction_id // null),
      completed_at: ($response[0].completed_at // null),
      transcript_path: ($response[0].transcript_path // null),
      response_path: $response_path,
      response_preview: (($response[0].response // "") | tostring | split("\n")[:8] | join("\n"))
    }' > "$tmp_file"
  mv -f "$tmp_file" "$PENDING_REVIEW_FILE"
}

clear_pending_review() {
  safe_rm "$PENDING_REVIEW_FILE"
}

prompt_line_from_capture() {
  local capture="$1"
  printf '%s\n' "$capture" | awk '/❯/ { prompt = $0 } END { print prompt }'
}

clear_relay_prompt_recovery_state() {
  safe_rm "$RELAY_PROMPT_RECOVERY_STATE_FILE"
}

write_relay_prompt_recovery_state() {
  local recovery_key="$1"
  local run_id="$2"
  local instruction_id="$3"
  local tmux_target="$4"
  local attempted_at="$5"

  jq -n \
    --arg recovery_key "$recovery_key" \
    --arg run_id "$run_id" \
    --arg instruction_id "$instruction_id" \
    --arg tmux_target "$tmux_target" \
    --arg attempted_at "$attempted_at" \
    '{
      recovery_key: $recovery_key,
      run_id: $run_id,
      instruction_id: $instruction_id,
      tmux_target: $tmux_target,
      attempted_at: $attempted_at
    }' > "$RELAY_PROMPT_RECOVERY_STATE_FILE"
}

recover_lodged_relay_prompt_if_needed() {
  local run_id="$1"
  local run_dir="$2"
  local run_json="$3"
  local status_json="$4"

  local state=""
  state="$(jq -r '.state // empty' "$status_json" 2>/dev/null || true)"
  if [[ "$state" != "queued" ]]; then
    clear_relay_prompt_recovery_state
    return 1
  fi

  if [[ -f "${run_dir}/inflight.json" ]]; then
    clear_relay_prompt_recovery_state
    return 1
  fi

  local queue_file=""
  queue_file="$(find "${run_dir}/queue" -maxdepth 1 -type f -name '*.json' 2>/dev/null | sort | head -1 || true)"
  if [[ -z "$queue_file" || ! -f "$queue_file" ]]; then
    clear_relay_prompt_recovery_state
    return 1
  fi

  local tmux_target instruction_id capture prompt_line
  tmux_target="$(jq -r '.tmux_target // empty' "$run_json" 2>/dev/null || true)"
  instruction_id="$(jq -r '.instruction_id // empty' "$queue_file" 2>/dev/null || true)"
  if [[ -z "$tmux_target" || -z "$instruction_id" ]]; then
    clear_relay_prompt_recovery_state
    return 1
  fi

  capture="$(tmux capture-pane -pt "$tmux_target" 2>/dev/null | tail -40 || true)"
  if [[ -z "$capture" || "$capture" == *"Press up to edit queued messages"* ]]; then
    clear_relay_prompt_recovery_state
    return 1
  fi

  prompt_line="$(prompt_line_from_capture "$capture")"
  if [[ "$prompt_line" != *"__BRAID_RELAY__"* ]]; then
    clear_relay_prompt_recovery_state
    return 1
  fi

  local recovery_key="${run_id}|${instruction_id}|${tmux_target}"
  local previous_key="" previous_attempted_at="" recovery_age=""
  previous_key="$(jq -r '.recovery_key // empty' "$RELAY_PROMPT_RECOVERY_STATE_FILE" 2>/dev/null || true)"
  previous_attempted_at="$(jq -r '.attempted_at // empty' "$RELAY_PROMPT_RECOVERY_STATE_FILE" 2>/dev/null || true)"
  if [[ "$previous_key" == "$recovery_key" ]]; then
    recovery_age="$(timestamp_age_seconds "$previous_attempted_at" 2>/dev/null || true)"
    if [[ "$recovery_age" =~ ^[0-9]+$ ]] && (( recovery_age < CLAUDEX_RELAY_PROMPT_NUDGE_COOLDOWN_SECONDS )); then
      return 0
    fi
  fi

  local attempted_at=""
  attempted_at="$(timestamp)"
  log "relay prompt is lodged in ${tmux_target}; nudging Enter for ${instruction_id}"
  tmux send-keys -t "$tmux_target" Enter
  write_relay_prompt_recovery_state "$recovery_key" "$run_id" "$instruction_id" "$tmux_target" "$attempted_at"
  return 0
}

capture_interaction_gate() {
  local run_id="$1"
  local run_dir="$2"
  local run_json="$3"
  local status_json="$4"

  local state tmux_target session_id instruction_id helper result gate_status
  state="$(jq -r '.state // empty' "$status_json" 2>/dev/null || true)"
  if [[ "$state" != "queued" && "$state" != "inflight" ]]; then
    safe_rm "${run_dir}/interaction-gate.json"
    return 1
  fi

  tmux_target="$(jq -r '.tmux_target // empty' "$run_json" 2>/dev/null || true)"
  if [[ -z "$tmux_target" ]]; then
    safe_rm "${run_dir}/interaction-gate.json"
    return 1
  fi

  helper="${ROOT}/ClauDEX/bridge/interaction_gate.mjs"
  if [[ ! -f "$helper" ]]; then
    safe_rm "${run_dir}/interaction-gate.json"
    return 1
  fi

  session_id="$(jq -r '.claude_session_id // empty' "$run_json" 2>/dev/null || true)"
  instruction_id="$(jq -r '.instruction_id // empty' "$status_json" 2>/dev/null || true)"

  if ! result="$(
    node "$helper" capture \
      --run-dir "$run_dir" \
      --run-id "$run_id" \
      --tmux-target "$tmux_target" \
      --bridge-state "$state" \
      ${instruction_id:+--instruction-id "$instruction_id"} \
      ${session_id:+--session-id "$session_id"} \
      2>/dev/null
  )"; then
    return 1
  fi

  gate_status="$(printf '%s' "$result" | jq -r '.status // empty' 2>/dev/null || true)"
  if [[ "$gate_status" == "gate_open" ]]; then
    return 0
  fi

  return 1
}

clear_dispatch_stall_state() {
  safe_rm "$DISPATCH_STALL_STATE_FILE"
  safe_rm "$DISPATCH_RECOVERY_STATE_FILE"
}

write_dispatch_stall_state() {
  local run_id="$1"
  local instruction_id="$2"
  local queued_at="$3"
  local queue_age_seconds="$4"
  local tmux_target="$5"
  local timeout_count="$6"
  local detected_at="$7"

  jq -n \
    --arg run_id "$run_id" \
    --arg instruction_id "$instruction_id" \
    --arg queued_at "$queued_at" \
    --argjson queue_age_seconds "$queue_age_seconds" \
    --arg tmux_target "$tmux_target" \
    --argjson timeout_count "$timeout_count" \
    --arg detected_at "$detected_at" \
    '{
      state: "dispatch_stalled",
      run_id: $run_id,
      instruction_id: $instruction_id,
      queued_at: $queued_at,
      queue_age_seconds: $queue_age_seconds,
      tmux_target: $tmux_target,
      timeout_count: $timeout_count,
      detected_at: $detected_at
    }' > "$DISPATCH_STALL_STATE_FILE"
}

write_dispatch_recovery_state() {
  local recovery_key="$1"
  local run_id="$2"
  local instruction_id="$3"
  local reason="$4"
  local status="$5"
  local attempted_at="$6"

  jq -n \
    --arg recovery_key "$recovery_key" \
    --arg run_id "$run_id" \
    --arg instruction_id "$instruction_id" \
    --arg reason "$reason" \
    --arg status "$status" \
    --arg attempted_at "$attempted_at" \
    '{
      recovery_key: $recovery_key,
      run_id: $run_id,
      instruction_id: $instruction_id,
      reason: $reason,
      status: $status,
      attempted_at: $attempted_at
    }' > "$DISPATCH_RECOVERY_STATE_FILE"
}

detect_dispatch_stall() {
  local run_id="$1"
  local run_dir="$2"
  local run_json="$3"
  local status_json="$4"

  local state=""
  state="$(jq -r '.state // empty' "$status_json" 2>/dev/null || true)"
  if [[ "$state" != "queued" ]]; then
    clear_dispatch_stall_state
    return 1
  fi

  if [[ -f "${run_dir}/inflight.json" ]]; then
    clear_dispatch_stall_state
    return 1
  fi

  local queue_file=""
  queue_file="$(find "${run_dir}/queue" -maxdepth 1 -type f -name '*.json' 2>/dev/null | sort | head -1 || true)"
  if [[ -z "$queue_file" || ! -f "$queue_file" ]]; then
    clear_dispatch_stall_state
    return 1
  fi

  local instruction_id queued_at queue_age_seconds
  instruction_id="$(jq -r '.instruction_id // empty' "$queue_file" 2>/dev/null || true)"
  queued_at="$(jq -r '.queued_at // empty' "$queue_file" 2>/dev/null || true)"
  if [[ -z "$queued_at" ]]; then
    queued_at="$(jq -r '.updated_at // empty' "$status_json" 2>/dev/null || true)"
  fi
  queue_age_seconds="$(timestamp_age_seconds "$queued_at" 2>/dev/null || true)"
  if [[ ! "$queue_age_seconds" =~ ^[0-9]+$ ]] || (( queue_age_seconds < CLAUDEX_DISPATCH_STALL_THRESHOLD_SECONDS )); then
    clear_dispatch_stall_state
    return 1
  fi

  local tmux_target timeout_count send_count log_tail
  tmux_target="$(jq -r '.tmux_target // empty' "$run_json" 2>/dev/null || true)"
  log_tail="$(tail -120 "$AUTO_LOG_FILE" 2>/dev/null || true)"
  timeout_count="$(printf '%s\n' "$log_tail" | grep -c 'Timeout waiting for inflight' || true)"
  send_count=0
  if [[ -n "$tmux_target" ]]; then
    send_count="$(printf '%s\n' "$log_tail" | grep -F -c "Queued work detected. Sending sentinel to ${tmux_target}" || true)"
  fi
  if (( timeout_count < CLAUDEX_DISPATCH_STALL_TIMEOUT_COUNT )) || (( send_count < CLAUDEX_DISPATCH_STALL_TIMEOUT_COUNT )); then
    clear_dispatch_stall_state
    return 1
  fi

  local existing_instruction_id="" existing_detected_at="" detected_at=""
  existing_instruction_id="$(jq -r '.instruction_id // empty' "$DISPATCH_STALL_STATE_FILE" 2>/dev/null || true)"
  existing_detected_at="$(jq -r '.detected_at // empty' "$DISPATCH_STALL_STATE_FILE" 2>/dev/null || true)"
  if [[ "$existing_instruction_id" != "$instruction_id" ]]; then
    log "dispatch stalled for instruction ${instruction_id}; queue age ${queue_age_seconds}s with ${timeout_count} recent auto-submit timeouts"
  fi
  if [[ "$existing_instruction_id" == "$instruction_id" && -n "$existing_detected_at" ]]; then
    detected_at="$existing_detected_at"
  else
    detected_at="$(timestamp)"
  fi
  write_dispatch_stall_state "$run_id" "$instruction_id" "$queued_at" "$queue_age_seconds" "$tmux_target" "$timeout_count" "$detected_at"
  return 0
}

recover_dispatch_if_needed() {
  local run_id="$1"

  if [[ ! -f "$DISPATCH_STALL_STATE_FILE" ]]; then
    return 1
  fi

  local stalled_run_id stalled_instruction_id detected_at reason
  stalled_run_id="$(jq -r '.run_id // empty' "$DISPATCH_STALL_STATE_FILE" 2>/dev/null || true)"
  stalled_instruction_id="$(jq -r '.instruction_id // empty' "$DISPATCH_STALL_STATE_FILE" 2>/dev/null || true)"
  detected_at="$(jq -r '.detected_at // empty' "$DISPATCH_STALL_STATE_FILE" 2>/dev/null || true)"
  if [[ -z "$stalled_run_id" || "$stalled_run_id" != "$run_id" ]]; then
    return 1
  fi

  reason="dispatch_stalled"
  local recovery_key="${run_id}|${stalled_instruction_id}|${detected_at}|${reason}"
  local previous_key previous_attempted_at
  previous_key="$(jq -r '.recovery_key // empty' "$DISPATCH_RECOVERY_STATE_FILE" 2>/dev/null || true)"
  previous_attempted_at="$(jq -r '.attempted_at // empty' "$DISPATCH_RECOVERY_STATE_FILE" 2>/dev/null || true)"
  if [[ "$previous_key" == "$recovery_key" ]]; then
    local recovery_age=""
    recovery_age="$(timestamp_age_seconds "$previous_attempted_at" 2>/dev/null || true)"
    if [[ "$recovery_age" =~ ^[0-9]+$ ]] && (( recovery_age < DISPATCH_RECOVERY_COOLDOWN_SECONDS )); then
      return 0
    fi
  fi

  local attempted_at=""
  attempted_at="$(timestamp)"
  if [[ ! -x "$DISPATCH_RECOVERY_SCRIPT" ]]; then
    log "dispatch recovery needed for ${stalled_instruction_id} but script is unavailable: $DISPATCH_RECOVERY_SCRIPT"
    write_dispatch_recovery_state "$recovery_key" "$run_id" "$stalled_instruction_id" "$reason" "missing_recovery_script" "$attempted_at"
    return 0
  fi

  log "dispatch stalled for ${stalled_instruction_id}; starting authoritative dispatch recovery"
  if BRAID_ROOT="$BRAID_ROOT" "$DISPATCH_RECOVERY_SCRIPT" --run-id "$run_id" >>"$DISPATCH_RECOVERY_LOG_FILE" 2>&1; then
    write_dispatch_recovery_state "$recovery_key" "$run_id" "$stalled_instruction_id" "$reason" "recovered" "$attempted_at"
    return 0
  fi

  write_dispatch_recovery_state "$recovery_key" "$run_id" "$stalled_instruction_id" "$reason" "recovery_failed" "$attempted_at"
  log "dispatch recovery command failed for run ${run_id}"
  return 0
}

write_supervisor_recovery_state() {
  local recovery_key="$1"
  local run_id="$2"
  local codex_target="$3"
  local reason="$4"
  local status="$5"
  local attempted_at="$6"

  jq -n \
    --arg recovery_key "$recovery_key" \
    --arg run_id "$run_id" \
    --arg codex_target "$codex_target" \
    --arg reason "$reason" \
    --arg status "$status" \
    --arg attempted_at "$attempted_at" \
    '{
      recovery_key: $recovery_key,
      run_id: $run_id,
      codex_target: $codex_target,
      reason: $reason,
      status: $status,
      attempted_at: $attempted_at
    }' > "$SUPERVISOR_RECOVERY_STATE_FILE"
}

recover_supervisor_if_needed() {
  local run_id="$1"
  local _run_json="$2"

  local reason=""
  local sampled_at=""
  local codex_target=""

  if [[ -f "$PROGRESS_ALERT_FILE" ]]; then
    local alert_run_id alert_summary alert_sampled_at alert_codex_target
    alert_run_id="$(jq -r '.active_run_id // empty' "$PROGRESS_ALERT_FILE" 2>/dev/null || true)"
    alert_summary="$(jq -r '.summary // empty' "$PROGRESS_ALERT_FILE" 2>/dev/null || true)"
    alert_sampled_at="$(jq -r '.sampled_at // empty' "$PROGRESS_ALERT_FILE" 2>/dev/null || true)"
    alert_codex_target="$(jq -r '.codex_target // empty' "$PROGRESS_ALERT_FILE" 2>/dev/null || true)"
    if [[ "$alert_run_id" == "$run_id" && -n "$alert_summary" && "$alert_summary" != "healthy" ]]; then
      reason="progress_alert:${alert_summary}"
      sampled_at="$alert_sampled_at"
      codex_target="$alert_codex_target"
    fi
  fi

  if [[ -z "$reason" && -f "$PROGRESS_SNAPSHOT_FILE" ]]; then
    local snapshot_run_id snapshot_sampled_at snapshot_codex_target snapshot_interval snapshot_age snapshot_max_age
    snapshot_run_id="$(jq -r '.active_run_id // empty' "$PROGRESS_SNAPSHOT_FILE" 2>/dev/null || true)"
    snapshot_sampled_at="$(jq -r '.sampled_at // empty' "$PROGRESS_SNAPSHOT_FILE" 2>/dev/null || true)"
    snapshot_codex_target="$(jq -r '.codex_target // empty' "$PROGRESS_SNAPSHOT_FILE" 2>/dev/null || true)"
    snapshot_interval="$(jq -r '.monitor_interval_seconds // empty' "$PROGRESS_SNAPSHOT_FILE" 2>/dev/null || true)"
    if [[ "$snapshot_interval" =~ ^[0-9]+$ ]] && [[ "$snapshot_interval" -gt 0 ]]; then
      snapshot_max_age="$((snapshot_interval + 60))"
    else
      snapshot_max_age="1860"
    fi
    snapshot_age="$(timestamp_age_seconds "$snapshot_sampled_at" 2>/dev/null || true)"
    if [[ "$snapshot_run_id" == "$run_id" && "$snapshot_age" =~ ^[0-9]+$ ]] && (( snapshot_age > snapshot_max_age )); then
      reason="progress_snapshot_stale"
      sampled_at="$snapshot_sampled_at"
      codex_target="$snapshot_codex_target"
    fi
  fi

  [[ -n "$reason" ]] || return 0

  local topology_json="" codex_authoritative="false" codex_target_exists="false"
  topology_json="$(claudex_bridge_topology_json "$BRAID_ROOT" "$PID_DIR" 2>/dev/null || true)"
  if [[ -n "$topology_json" ]]; then
    if [[ -z "$codex_target" ]]; then
      codex_target="$(printf '%s\n' "$topology_json" | jq -r '.codex.target // empty' 2>/dev/null || true)"
    fi
    codex_authoritative="$(printf '%s\n' "$topology_json" | jq -r '.codex.authoritative // false' 2>/dev/null || printf 'false')"
    codex_target_exists="$(printf '%s\n' "$topology_json" | jq -r '.codex.target_exists // false' 2>/dev/null || printf 'false')"
  fi

  local attempted_at=""
  attempted_at="$(timestamp)"
  if [[ -z "$codex_target" ]]; then
    log "supervisor recovery needed (${reason}) but no Codex pane target is available from lane topology"
    write_supervisor_recovery_state "${run_id}|${reason}|unresolved" "$run_id" "" "$reason" "missing_codex_target" "$attempted_at"
    return 0
  fi
  if [[ "$codex_authoritative" != "true" ]]; then
    log "supervisor recovery needed (${reason}) but Codex target ${codex_target} is non-authoritative; refusing legacy fallback"
    write_supervisor_recovery_state "${run_id}|${reason}|${codex_target}" "$run_id" "$codex_target" "$reason" "non_authoritative_codex_target" "$attempted_at"
    return 0
  fi
  if [[ "$codex_target_exists" != "true" ]]; then
    log "supervisor recovery needed (${reason}) but Codex pane target ${codex_target} is unavailable"
    write_supervisor_recovery_state "${run_id}|${reason}|${codex_target}" "$run_id" "$codex_target" "$reason" "codex_target_unavailable" "$attempted_at"
    return 0
  fi

  local recovery_key="${run_id}|${reason}|${codex_target}"
  local previous_key=""
  local previous_attempted_at=""
  previous_key="$(jq -r '.recovery_key // empty' "$SUPERVISOR_RECOVERY_STATE_FILE" 2>/dev/null || true)"
  previous_attempted_at="$(jq -r '.attempted_at // empty' "$SUPERVISOR_RECOVERY_STATE_FILE" 2>/dev/null || true)"
  if [[ "$previous_key" == "$recovery_key" ]]; then
    local recovery_age=""
    recovery_age="$(timestamp_age_seconds "$previous_attempted_at" 2>/dev/null || true)"
    if [[ "$recovery_age" =~ ^[0-9]+$ ]] && (( recovery_age < SUPERVISOR_RECOVERY_COOLDOWN_SECONDS )); then
      return 0
    fi
  fi

  if [[ ! -x "$SUPERVISOR_RESTART_SCRIPT" ]]; then
    log "supervisor recovery needed (${reason}) but restart script is unavailable: $SUPERVISOR_RESTART_SCRIPT"
    write_supervisor_recovery_state "$recovery_key" "$run_id" "$codex_target" "$reason" "missing_restart_script" "$attempted_at"
    return 0
  fi

  # The watchdog is the transport authority. When it repairs the supervisor
  # path, it must not invoke the restart script's transport branch or it will
  # kill/reseed itself before writing cooldown state for this recovery.
  log "progress monitor degraded (${reason}); restarting supervisor path for ${codex_target}"
  if BRAID_ROOT="$BRAID_ROOT" "$SUPERVISOR_RESTART_SCRIPT" --codex-target "$codex_target" --no-transport >>"$SUPERVISOR_RECOVERY_LOG_FILE" 2>&1; then
    write_supervisor_recovery_state "$recovery_key" "$run_id" "$codex_target" "$reason" "restarted" "$attempted_at"
    return 0
  fi

  write_supervisor_recovery_state "$recovery_key" "$run_id" "$codex_target" "$reason" "restart_failed" "$attempted_at"
  log "supervisor recovery command failed for ${codex_target}"
  return 0
}

auto_hand_back_user_driving() {
  local status_json="$1"

  if [[ "$AUTO_HAND_BACK_USER_DRIVING" != "1" ]]; then
    return 0
  fi

  local control_mode=""
  control_mode="$(jq -r '.control_mode // ""' "$status_json" 2>/dev/null || true)"
  if [[ "$control_mode" != "user_driving" ]]; then
    return 0
  fi

  if [[ ! -x "${BRAID_ROOT}/resume.sh" ]]; then
    log "relay is user_driving but ${BRAID_ROOT}/resume.sh is unavailable"
    return 0
  fi

  log "relay drifted to user_driving during supervised overnight run; handing control back"
  if "${BRAID_ROOT}/resume.sh" --runs-dir "$STATE_DIR" >>"$BROKER_LOG_FILE" 2>&1; then
    return 0
  fi

  log "automatic handback via braid resume failed"
  return 0
}

expire_stale_dispatch_attempts() {
  # Sweep dispatch_attempts rows whose timeout_at has elapsed (pending/delivered
  # → timed_out). Authority lives in runtime/core/dispatch_attempts.expire_stale.
  # Best-effort: errors are suppressed so transport failures never block the tick.
  local db="${ROOT}/.claude/state.db"
  if [[ ! -f "$db" ]]; then
    return 0
  fi
  if [[ ! -f "$RUNTIME_CLI" ]]; then
    return 0
  fi
  local runtime_python
  runtime_python="$(claudex_runtime_python)" || return 0
  local result expired
  result=$(CLAUDE_POLICY_DB="$db" "$runtime_python" "$RUNTIME_CLI" dispatch attempt-expire-stale 2>/dev/null) || return 0
  expired=$(printf '%s' "$result" | jq -r '.expired // 0' 2>/dev/null || echo 0)
  if [[ "$expired" =~ ^[0-9]+$ ]] && (( expired > 0 )); then
    log "expired ${expired} stale dispatch attempt(s)"
  fi

  # Runtime-owned dead-loop recovery (DEC-DEAD-RECOVERY-001).  Marks seats
  # with past-grace terminal attempts as dead, cascade-closes their
  # supervision_threads, and transitions every-seat-terminal sessions to
  # completed / dead.  Best-effort — failures must never block the tick.
  CLAUDE_POLICY_DB="$db" "$runtime_python" "$RUNTIME_CLI" dispatch sweep-dead >/dev/null 2>&1 || true
}

watchdog_tick() {
  reconcile_watchdog_processes
  expire_stale_dispatch_attempts
  restart_broker
  restart_auto_submit

  local pointer="${STATE_DIR}/active-run"
  if [[ ! -f "$pointer" ]]; then
    clear_handoff_flag
    clear_pending_review
    return 0
  fi

  local run_id run_dir run_json status_json
  run_id="$(tr -d '[:space:]' < "$pointer" 2>/dev/null || true)"
  if [[ -z "$run_id" ]]; then
    clear_handoff_flag
    clear_pending_review
    return 0
  fi
  run_dir="${STATE_DIR}/${run_id}"
  run_json="${run_dir}/run.json"
  status_json="${run_dir}/status.json"
  if [[ ! -f "$run_json" || ! -f "$status_json" ]]; then
    clear_handoff_flag
    clear_pending_review
    return 0
  fi

  auto_hand_back_user_driving "$status_json"
  capture_interaction_gate "$run_id" "$run_dir" "$run_json" "$status_json" || true
  recover_missing_response_from_transcript "$run_id" "$run_dir" "$run_json" || true
  reconcile_completed_inflight "$run_id" "$run_dir" "$run_json" "$status_json" || true
  if recover_lodged_relay_prompt_if_needed "$run_id" "$run_dir" "$run_json" "$status_json"; then
    clear_handoff_flag
    clear_pending_review
    return 0
  fi
  if detect_dispatch_stall "$run_id" "$run_dir" "$run_json" "$status_json"; then
    recover_dispatch_if_needed "$run_id"
  else
    recover_supervisor_if_needed "$run_id" "$run_json"
  fi

  local state updated_at
  state="$(jq -r '.state // empty' "$status_json" 2>/dev/null || true)"
  updated_at="$(jq -r '.updated_at // empty' "$status_json" 2>/dev/null || true)"

  if [[ "$state" == "waiting_for_codex" ]]; then
    touch_handoff_flag "$run_id" "$updated_at"
    write_pending_review "$run_id" "$run_dir" "$updated_at"
  else
    clear_handoff_flag
    clear_pending_review
  fi
}

if [[ "$RUN_ONCE" -eq 1 ]]; then
  watchdog_tick
  exit 0
fi

EXISTING_WATCHDOG_PID="$(pid_from_file "$WATCHDOG_PID_FILE" || true)"
# Tolerate our own PID in the pid file: after self-exec, $$ is preserved
# across exec and the outgoing process does not fire its EXIT trap, so the
# file still contains our own PID. Treating that as "already running" would
# cause the re-exec'd watchdog to refuse to start.
if [[ -n "$EXISTING_WATCHDOG_PID" ]] \
  && [[ "$EXISTING_WATCHDOG_PID" != "$$" ]] \
  && kill -0 "$EXISTING_WATCHDOG_PID" 2>/dev/null; then
  log "watchdog already running with pid ${EXISTING_WATCHDOG_PID}"
  exit 0
fi

printf '%s\n' "$$" > "$WATCHDOG_PID_FILE"
trap cleanup_watchdog EXIT
trap 'cleanup_watchdog; exit 130' INT
trap 'cleanup_watchdog; exit 143' TERM

while true; do
  watchdog_tick

  # Self-exec on script drift (DEC-CLAUDEX-BRIDGE-SELF-EXEC-001). Check
  # after the tick so the tick that noticed the drift still completes
  # normally. Re-exec preserves PID, argv, and environment, so the new
  # instance picks up where we left off without any external restart.
  current_signature="$(script_signature)"
  if [[ "$current_signature" != "$SCRIPT_START_SIGNATURE" ]]; then
    log "script updated (signature ${SCRIPT_START_SIGNATURE} -> ${current_signature}); re-exec'ing"
    exec "${ORIGINAL_INVOCATION[@]}"
  fi

  sleep "$POLL_INTERVAL"
done
