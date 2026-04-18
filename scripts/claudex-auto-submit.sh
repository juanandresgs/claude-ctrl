#!/usr/bin/env bash
set -euo pipefail

# Readiness-gated auto-submit wrapper for the ClauDEX bridge.
#
# The upstream braid auto-submit loop blindly types the relay sentinel as
# soon as a queue file exists. In practice that can race Claude startup:
# the sentinel lands in the pane before Claude is ready to treat it as a
# submitted prompt, so the queue never moves to inflight and the loop keeps
# stacking "__BRAID_RELAY__" at the prompt.
#
# This wrapper keeps the same queue-driven semantics but only sends the
# sentinel when the worker pane looks like an active Claude prompt. If the
# sentinel is already sitting in Claude's live prompt, it submits that prompt
# in place instead of stacking another copy or escalating to heavier recovery.

SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/claudex-common.sh"
BRAID_ROOT="${BRAID_ROOT:-${ROOT}/.b2r}"
RUNS_DIR="${BRAID_ROOT}/runs"
POLL_INTERVAL="${BRIDGE_POLL_INTERVAL:-2}"
RELAY_RETRY_BACKOFF_SECONDS="${CLAUDEX_RELAY_RETRY_BACKOFF_SECONDS:-30}"
RUN_ONCE=0
PID_DIR="${CLAUDEX_STATE_DIR:-$(claudex_state_dir "$ROOT" "$BRAID_ROOT")}"
AUTO_PID_FILE="${PID_DIR}/auto-submit.pid"
GLOBAL_AUTO_PID_FILE="${RUNS_DIR}/auto-submit.pid"
AUTO_LOCK_DIR="${RUNS_DIR}/.auto-submit.lock.d"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--once]

Watch the active braid run and inject __BRAID_RELAY__ into the Claude pane
only when the pane looks ready to accept a submitted prompt.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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

log() {
  echo "[auto-submit] $*" >&2
}

cleanup_singleton_lock() {
  trap - EXIT INT TERM
  local recorded_pid="" current_pid=""
  recorded_pid="$(tr -d '[:space:]' < "${AUTO_LOCK_DIR}/pid" 2>/dev/null || true)"
  if [[ -f "$AUTO_PID_FILE" ]]; then
    current_pid="$(tr -d '[:space:]' < "$AUTO_PID_FILE" 2>/dev/null || true)"
  fi

  if [[ "$recorded_pid" == "$$" ]]; then
    rm -rf "$AUTO_LOCK_DIR" 2>/dev/null || true
    rm -f "$GLOBAL_AUTO_PID_FILE" 2>/dev/null || true
  fi

  if [[ "$current_pid" == "$$" ]]; then
    rm -f "$AUTO_PID_FILE" 2>/dev/null || true
  fi
}

publish_singleton_identity() {
  printf '%s\n' "$$" > "${AUTO_LOCK_DIR}/pid"
  printf '%s\n' "$$" > "$GLOBAL_AUTO_PID_FILE"
  printf '%s\n' "$$" > "$AUTO_PID_FILE"
}

acquire_singleton_lock() {
  mkdir -p "$PID_DIR"
  mkdir -p "$RUNS_DIR"

  while true; do
    if mkdir "$AUTO_LOCK_DIR" 2>/dev/null; then
      publish_singleton_identity
      trap cleanup_singleton_lock EXIT
      trap 'cleanup_singleton_lock; exit 130' INT
      trap 'cleanup_singleton_lock; exit 143' TERM
      return 0
    fi

    local recorded_pid=""
    recorded_pid="$(tr -d '[:space:]' < "${AUTO_LOCK_DIR}/pid" 2>/dev/null || true)"
    if [[ -n "$recorded_pid" ]] && kill -0 "$recorded_pid" 2>/dev/null; then
      printf '%s\n' "$recorded_pid" > "$GLOBAL_AUTO_PID_FILE"
      printf '%s\n' "$recorded_pid" > "$AUTO_PID_FILE"
      log "Another auto-submit is already active (${recorded_pid}); exiting."
      exit 0
    fi

    rm -rf "$AUTO_LOCK_DIR" 2>/dev/null || true
    sleep 0.2
  done
}

ensure_singleton_lock_ownership() {
  local recorded_pid=""
  recorded_pid="$(tr -d '[:space:]' < "${AUTO_LOCK_DIR}/pid" 2>/dev/null || true)"

  if [[ "$recorded_pid" != "$$" ]]; then
    if [[ -n "$recorded_pid" ]]; then
      log "Lost singleton lock to ${recorded_pid}; exiting."
    else
      log "Singleton lock metadata is missing; exiting."
    fi
    cleanup_singleton_lock
    exit 0
  fi

  publish_singleton_identity
}

read_submit_state() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  jq -r '.instruction_id // empty, .sent_at_epoch // empty' "$path" 2>/dev/null || true
}

write_submit_state() {
  local path="$1"
  local instruction_id="$2"
  local sent_at_epoch="$3"
  local dir_path
  dir_path="$(dirname "$path")"
  if [[ ! -d "$dir_path" ]]; then
    return 0
  fi
  jq -n \
    --arg instruction_id "$instruction_id" \
    --argjson sent_at_epoch "$sent_at_epoch" \
    '{instruction_id: $instruction_id, sent_at_epoch: $sent_at_epoch}' \
    > "${path}.tmp"
  mv "${path}.tmp" "$path" 2>/dev/null || true
}

sent_recently_for_instruction() {
  local state_path="$1"
  local instruction_id="$2"
  local now_epoch="$3"

  [[ -f "$state_path" ]] || return 1

  local saved_instruction_id="" saved_sent_at=""
  while IFS=$'\t' read -r saved_instruction_id saved_sent_at; do
    break
  done < <(
    jq -r '[.instruction_id // empty, (.sent_at_epoch // empty)] | @tsv' \
      "$state_path" 2>/dev/null || true
  )

  [[ "$saved_instruction_id" == "$instruction_id" ]] || return 1
  [[ "$saved_sent_at" =~ ^[0-9]+$ ]] || return 1

  (( now_epoch - saved_sent_at < RELAY_RETRY_BACKOFF_SECONDS ))
}

pane_capture() {
  local target="$1"
  tmux capture-pane -pt "$target" -S -120 2>/dev/null || true
}

recent_capture_from_capture() {
  local capture="$1"
  printf '%s\n' "$capture" | tail -40
}

pane_command() {
  local target="$1"
  tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null || true
}

prompt_line_from_capture() {
  local capture="$1"
  printf '%s\n' "$capture" | awk '/❯/ { prompt = $0 } END { print prompt }'
}

claude_pane_state() {
  local target="$1"

  if ! tmux has-session -t "${target%%.*}" 2>/dev/null; then
    printf '%s\n' "missing"
    return 0
  fi

  local command capture recent_capture prompt_line
  command="$(pane_command "$target")"
  capture="$(pane_capture "$target")"
  recent_capture="$(recent_capture_from_capture "$capture")"
  prompt_line="$(prompt_line_from_capture "$recent_capture")"

  # The queued-message footer is only authoritative when it is still present in
  # the live prompt region near the bottom of the pane. Historical scrollback
  # often contains the same footer from earlier relay deliveries and must not
  # block new work forever.
  if [[ "$recent_capture" == *"Press up to edit queued messages"* ]]; then
    printf '%s\n' "queued_messages"
    return 0
  fi

  if [[ -n "$prompt_line" && "$prompt_line" == *"__BRAID_RELAY__"* ]]; then
    printf '%s\n' "relay_prompt"
    return 0
  fi

  case "$command" in
    ""|bash|zsh|sh)
      printf '%s\n' "not_ready"
      return 0
      ;;
  esac

  if [[ -n "$prompt_line" ]]; then
    printf '%s\n' "ready"
    return 0
  fi

  if [[ "$capture" == *"Claude Code"* ]] || [[ "$recent_capture" == *"bypass permissions"* ]]; then
    printf '%s\n' "ready"
    return 0
  fi

  printf '%s\n' "not_ready"
}

recover_stale_inflight_response() {
  local run_dir="$1"
  local inflight_file="${run_dir}/inflight.json"
  [[ -f "$inflight_file" ]] || return 1

  local instruction_id=""
  instruction_id="$(jq -r '.instruction_id // empty' "$inflight_file" 2>/dev/null || true)"
  [[ -n "$instruction_id" ]] || return 1
  [[ -f "${run_dir}/responses/${instruction_id}.json" ]] || return 1

  local inflight_archive_dir="${run_dir}/recovery/stale-inflight"
  local queue_archive_dir="${run_dir}/recovery/stale-queued"
  mkdir -p "$inflight_archive_dir" "$queue_archive_dir"
  mv "$inflight_file" "${inflight_archive_dir}/${instruction_id}.json"

  if [[ -f "${run_dir}/queue/${instruction_id}.json" ]]; then
    mv "${run_dir}/queue/${instruction_id}.json" "${queue_archive_dir}/${instruction_id}.json"
  fi

  local status_file="${run_dir}/status.json"
  local response_file="${run_dir}/responses/${instruction_id}.json"
  if [[ -f "$status_file" ]]; then
    local updated_at=""
    updated_at="$(jq -r '.completed_at // empty' "$response_file" 2>/dev/null || true)"
    if [[ -z "$updated_at" ]]; then
      updated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    fi
    jq \
      --arg updated_at "$updated_at" \
      '.state = "waiting_for_codex"
       | .control_mode = "review"
       | .instruction_id = null
       | .updated_at = $updated_at' \
      "$status_file" > "${status_file}.tmp"
    mv "${status_file}.tmp" "$status_file"
  fi

  log "Recovered stale inflight ${instruction_id} because a response artifact already exists"
  return 0
}

archive_stale_queued_responses() {
  local run_dir="$1"
  local queue_dir="${run_dir}/queue"
  local responses_dir="${run_dir}/responses"
  local archive_dir="${run_dir}/recovery/stale-queued"
  local archived=0
  local file=""

  shopt -s nullglob
  for file in "${queue_dir}/"*.json; do
    local instruction_id="${file##*/}"
    instruction_id="${instruction_id%.json}"

    if [[ ! -f "${responses_dir}/${instruction_id}.json" ]]; then
      break
    fi

    mkdir -p "$archive_dir"
    mv "$file" "${archive_dir}/${instruction_id}.json"
    archived=$((archived + 1))
  done
  shopt -u nullglob

  if (( archived > 0 )); then
    log "Archived ${archived} stale queued entr$( (( archived == 1 )) && printf 'y' || printf 'ies' ) with existing responses"
  fi
}

wait_for_inflight_and_completion() {
  local run_dir="$1"
  local timeout_message="$2"

  if [[ "$RUN_ONCE" -eq 1 ]]; then
    return 0
  fi

  log "Waiting for inflight to complete..."

  local wait_count=0
  while [[ ! -f "${run_dir}/inflight.json" ]]; do
    sleep "$POLL_INTERVAL"
    wait_count=$((wait_count + 1))
    if [[ "$wait_count" -ge 15 ]]; then
      log "$timeout_message"
      break
    fi

    local completed=""
    completed="$(jq -r '.completed_at // empty' "${run_dir}/run.json" 2>/dev/null || true)"
    if [[ -n "$completed" ]]; then
      break
    fi
  done

  while [[ -f "${run_dir}/inflight.json" ]]; do
    sleep "$POLL_INTERVAL"
    local completed=""
    completed="$(jq -r '.completed_at // empty' "${run_dir}/run.json" 2>/dev/null || true)"
    if [[ -n "$completed" ]]; then
      break
    fi
  done

  log "Instruction complete. Checking for more queued work..."
}

send_and_wait() {
  local run_dir="$1"
  local tmux_target="$2"
  local instruction_id="$3"
  local state_path="${run_dir}/auto-submit.state.json"

  if [[ "$RUN_ONCE" -eq 0 ]]; then
    ensure_singleton_lock_ownership
  fi

  log "Queued work detected. Sending sentinel to ${tmux_target}"
  tmux send-keys -t "$tmux_target" "__BRAID_RELAY__" Enter
  write_submit_state "$state_path" "$instruction_id" "$(date +%s)"
  wait_for_inflight_and_completion \
    "$run_dir" \
    "Timeout waiting for inflight — sentinel may not have reached Claude."
}

submit_lodged_prompt() {
  local run_dir="$1"
  local state_path="$2"
  local tmux_target="$3"
  local instruction_id="$4"

  if [[ "$RUN_ONCE" -eq 0 ]]; then
    ensure_singleton_lock_ownership
  fi

  log "Relay prompt is still live in ${tmux_target}; submitting it in place."
  tmux send-keys -t "$tmux_target" Enter
  write_submit_state "$state_path" "$instruction_id" "$(date +%s)"
  wait_for_inflight_and_completion \
    "$run_dir" \
    "Timeout waiting for inflight — lodged relay prompt may still need attention."
}

LAST_NOT_READY_KEY=""
LAST_PENDING_RELAY_KEY=""
LAST_GATE_KEY=""

open_interaction_gate_type() {
  local run_dir="$1"
  local gate_path="${run_dir}/interaction-gate.json"
  [[ -f "$gate_path" ]] || return 1

  local gate_status="" gate_type=""
  gate_status="$(jq -r '.status // empty' "$gate_path" 2>/dev/null || true)"
  [[ "$gate_status" == "open" ]] || return 1
  gate_type="$(jq -r '.gate_type // empty' "$gate_path" 2>/dev/null || true)"
  [[ -n "$gate_type" ]] || gate_type="interaction_gate"
  printf '%s\n' "$gate_type"
}

poll_once() {
  local pointer="${RUNS_DIR}/active-run"

  if [[ ! -f "$pointer" ]]; then
    return 0
  fi

  local run_id
  run_id="$(tr -d '[:space:]' < "$pointer")"
  local run_dir="${RUNS_DIR}/${run_id}"

  if [[ ! -f "${run_dir}/run.json" ]]; then
    return 0
  fi

  local completed
  completed="$(jq -r '.completed_at // empty' "${run_dir}/run.json" 2>/dev/null || true)"
  if [[ -n "$completed" ]]; then
    return 0
  fi

  local control_mode
  control_mode="$(jq -r '.control_mode // empty' "${run_dir}/status.json" 2>/dev/null || true)"
  if [[ "$control_mode" == "user_driving" ]]; then
    return 0
  fi

  local open_gate_type=""
  open_gate_type="$(open_interaction_gate_type "$run_dir" || true)"
  if [[ -n "$open_gate_type" ]]; then
    local gate_key="${run_id}:${open_gate_type}"
    if [[ "$LAST_GATE_KEY" != "$gate_key" ]]; then
      log "Open interaction gate (${open_gate_type}) for run ${run_id}; pausing auto-submit until deliberate recovery."
      LAST_GATE_KEY="$gate_key"
    fi
    return 0
  fi
  LAST_GATE_KEY=""

  if [[ -f "${run_dir}/inflight.json" ]]; then
    recover_stale_inflight_response "$run_dir" || return 0
  fi

  archive_stale_queued_responses "$run_dir"

  local next_file=""
  next_file="$(ls -1 "${run_dir}/queue/"*.json 2>/dev/null | head -1 || true)"
  if [[ -z "$next_file" ]]; then
    return 0
  fi

  local tmux_target=""
  tmux_target="$(jq -r '.tmux_target // empty' "${run_dir}/run.json" 2>/dev/null || true)"
  if [[ -z "$tmux_target" ]]; then
    log "No tmux_target in run.json for run ${run_id} — skipping"
    return 0
  fi

  local instruction_id=""
  instruction_id="$(jq -r '.instruction_id // empty' "$next_file" 2>/dev/null || true)"
  local state_path="${run_dir}/auto-submit.state.json"
  local submit_state_path="${run_dir}/auto-submit-enter.state.json"
  local relay_key="${run_id}:${instruction_id}:${tmux_target}"
  local pane_state=""
  pane_state="$(claude_pane_state "$tmux_target")"

  case "$pane_state" in
    ready)
      LAST_NOT_READY_KEY=""
      LAST_PENDING_RELAY_KEY=""
      ;;
    relay_prompt)
      LAST_NOT_READY_KEY=""
      if sent_recently_for_instruction "$submit_state_path" "$instruction_id" "$(date +%s)"; then
        if [[ "$LAST_PENDING_RELAY_KEY" != "$relay_key:submit_recent" ]]; then
          log "Submit nudge already sent recently for ${instruction_id}; waiting before nudging again."
          LAST_PENDING_RELAY_KEY="$relay_key:submit_recent"
        fi
        return 0
      fi
      LAST_PENDING_RELAY_KEY=""
      submit_lodged_prompt "$run_dir" "$submit_state_path" "$tmux_target" "$instruction_id"
      return 0
      ;;
    queued_messages)
      if [[ "$LAST_PENDING_RELAY_KEY" != "$relay_key:queued_messages" ]]; then
        log "Relay prompt already present in ${tmux_target}; waiting for claim before resending."
        LAST_PENDING_RELAY_KEY="$relay_key:queued_messages"
      fi
      return 0
      ;;
    missing)
      if [[ "$LAST_NOT_READY_KEY" != "$relay_key:missing" ]]; then
        log "tmux target ${tmux_target} is unavailable — waiting"
        LAST_NOT_READY_KEY="$relay_key:missing"
      fi
      return 0
      ;;
    *)
      if [[ "$LAST_NOT_READY_KEY" != "$relay_key:not_ready" ]]; then
        log "Claude pane ${tmux_target} is not ready for relay yet — waiting"
        LAST_NOT_READY_KEY="$relay_key:not_ready"
      fi
      return 0
      ;;
  esac

  if sent_recently_for_instruction "$state_path" "$instruction_id" "$(date +%s)"; then
    if [[ "$LAST_PENDING_RELAY_KEY" != "$relay_key:recent" ]]; then
      log "Relay already sent recently for ${instruction_id}; waiting before retry."
      LAST_PENDING_RELAY_KEY="$relay_key:recent"
    fi
    return 0
  fi

  sleep 0.5
  send_and_wait "$run_dir" "$tmux_target" "$instruction_id"
}

if [[ "$RUN_ONCE" -eq 0 ]]; then
  acquire_singleton_lock
  ensure_singleton_lock_ownership
fi

log "Starting. Poll interval: ${POLL_INTERVAL}s"
log "Runs dir: ${RUNS_DIR}"
[[ "$RUN_ONCE" -eq 1 ]] && log "Single-pass mode enabled."

while true; do
  if [[ "$RUN_ONCE" -eq 0 ]]; then
    ensure_singleton_lock_ownership
  fi
  poll_once
  if [[ "$RUN_ONCE" -eq 1 ]]; then
    exit 0
  fi
  sleep "$POLL_INTERVAL"
done
