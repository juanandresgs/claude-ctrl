#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
source "${SCRIPT_DIR}/claudex-common.sh"
BRAID_ROOT="${BRAID_ROOT:-${ROOT}/.b2r}"
STATE_DIR="${BRAID_ROOT}/runs"
PID_DIR="${CLAUDEX_STATE_DIR:-$(claudex_state_dir "$ROOT" "$BRAID_ROOT")}"
RECOVERY_DIR="${PID_DIR}/recovery"
ACTIVE_RUN_POINTER="${STATE_DIR}/active-run"

RUN_ID=""
SESSION_NAME=""
BUNDLE_PATH=""
DRY_RUN=0
READY_TIMEOUT_SECONDS="${CLAUDEX_DISPATCH_RECOVERY_READY_TIMEOUT_SECONDS:-45}"
VERIFY_TIMEOUT_SECONDS="${CLAUDEX_DISPATCH_RECOVERY_VERIFY_TIMEOUT_SECONDS:-45}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--run-id RUN_ID] [--session NAME] [--bundle PATH] [--dry-run]

Authoritative dispatch recovery for a stalled ClauDEX run:
- preserve the oldest queued instruction into .claude/claudex/recovery/
- archive and tear down the disposable active run
- start a fresh supervised overnight session
- requeue the preserved instruction into the fresh run
- verify the fresh run advances beyond queued

If --run-id is omitted, the active braid run is used.
If --session is omitted, the next free session name is derived from the old one.
If --bundle is provided, skip teardown/start and requeue that preserved
instruction into the current active run.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id)
      RUN_ID="$2"
      shift 2
      ;;
    --session)
      SESSION_NAME="$2"
      shift 2
      ;;
    --bundle)
      BUNDLE_PATH="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
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

for cmd in jq tmux node python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
done

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

active_run_id() {
  if [[ ! -f "$ACTIVE_RUN_POINTER" ]]; then
    return 1
  fi
  tr -d '[:space:]' < "$ACTIVE_RUN_POINTER" 2>/dev/null
}

derive_next_session_name() {
  local current="$1"
  local candidate=""

  if [[ "$current" =~ ^(.+?)([0-9]+)$ ]]; then
    local prefix="${BASH_REMATCH[1]}"
    local digits="${BASH_REMATCH[2]}"
    local width="${#digits}"
    local number=$((10#$digits))
    while :; do
      number=$((number + 1))
      printf -v candidate "%s%0${width}d" "$prefix" "$number"
      if ! tmux has-session -t "$candidate" 2>/dev/null; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  fi

  local base="${current:-overnight-recover}"
  local suffix=1
  while :; do
    candidate="${base}-${suffix}"
    if ! tmux has-session -t "$candidate" 2>/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
    suffix=$((suffix + 1))
  done
}

wait_for_new_active_run() {
  local previous_run_id="$1"
  local waited=0
  while (( waited < READY_TIMEOUT_SECONDS )); do
    local current=""
    current="$(active_run_id || true)"
    if [[ -n "$current" && "$current" != "$previous_run_id" ]]; then
      printf '%s\n' "$current"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

wait_for_claude_pane() {
  local tmux_target="$1"
  local waited=0
  while (( waited < READY_TIMEOUT_SECONDS )); do
    local pane_command="" pane_capture=""
    pane_command="$(tmux display-message -p -t "$tmux_target" '#{pane_current_command}' 2>/dev/null || true)"
    pane_capture="$(tmux capture-pane -pt "$tmux_target" 2>/dev/null | tail -40 || true)"
    if [[ "$pane_capture" == *"Claude Code"* ]] || [[ "$pane_capture" == *"❯"* ]] || [[ "$pane_capture" == *"bypass permissions"* ]]; then
      return 0
    fi
    case "$pane_command" in
      ""|bash|zsh|sh)
        ;;
      *)
        return 0
        ;;
    esac
    if [[ "$pane_command" == "claude" ]]; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

queue_instruction_into_run() {
  local run_id="$1"
  local instruction_text="$2"

  BRAID_ROOT="$BRAID_ROOT" \
  BRIDGE_STATE_DIR="$STATE_DIR" \
  CLAUDEX_QUEUE_RUN_ID="$run_id" \
  CLAUDEX_QUEUE_TEXT="$instruction_text" \
  node --input-type=module <<'NODE'
import { pathToFileURL } from 'node:url';

const braidRoot = process.env.BRAID_ROOT;
const runsDir = process.env.BRIDGE_STATE_DIR;
const runId = process.env.CLAUDEX_QUEUE_RUN_ID;
const text = process.env.CLAUDEX_QUEUE_TEXT ?? '';

if (!braidRoot || !runsDir || !runId) {
  throw new Error('Missing queueInstruction environment inputs');
}

const moduleUrl = pathToFileURL(`${braidRoot}/lib/state.mjs`).href;
const { queueInstruction } = await import(moduleUrl);
const result = queueInstruction(runId, text, runsDir);
console.log(JSON.stringify(result));
NODE
}

verify_run_advances() {
  local run_id="$1"
  local instruction_id="$2"
  local status_json="${STATE_DIR}/${run_id}/status.json"
  local inflight_json="${STATE_DIR}/${run_id}/inflight.json"
  local response_json="${STATE_DIR}/${run_id}/responses/${instruction_id}.json"

  local waited=0
  while (( waited < VERIFY_TIMEOUT_SECONDS )); do
    if [[ -f "$response_json" ]]; then
      return 0
    fi

    if [[ -f "$inflight_json" ]]; then
      local inflight_id=""
      inflight_id="$(jq -r '.instruction_id // empty' "$inflight_json" 2>/dev/null || true)"
      if [[ "$inflight_id" == "$instruction_id" ]]; then
        return 0
      fi
    fi

    if [[ -f "$status_json" ]]; then
      local state="" current_instruction=""
      state="$(jq -r '.state // empty' "$status_json" 2>/dev/null || true)"
      current_instruction="$(jq -r '.instruction_id // empty' "$status_json" 2>/dev/null || true)"
      if [[ "$current_instruction" == "$instruction_id" && "$state" != "queued" ]]; then
        return 0
      fi
    fi

    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

ACTIVE_RUN_ID="${RUN_ID:-$(active_run_id || true)}"
PREVIOUS_RUN_ID=""
QUEUED_AT=""
RECOVERY_BUNDLE=""

if [[ -n "$BUNDLE_PATH" ]]; then
  if [[ ! -f "$BUNDLE_PATH" ]]; then
    echo "Recovery bundle not found: $BUNDLE_PATH" >&2
    exit 1
  fi
  if [[ -z "$ACTIVE_RUN_ID" ]]; then
    echo "No active run found to receive recovery bundle ${BUNDLE_PATH}." >&2
    exit 1
  fi

  RECOVERY_BUNDLE="$BUNDLE_PATH"
  PREVIOUS_RUN_ID="$(jq -r '.previous_run_id // empty' "$RECOVERY_BUNDLE" 2>/dev/null || true)"
  INSTRUCTION_ID="$(jq -r '.instruction.instruction_id // empty' "$RECOVERY_BUNDLE" 2>/dev/null || true)"
  INSTRUCTION_TEXT="$(jq -r '.instruction.text // empty' "$RECOVERY_BUNDLE" 2>/dev/null || true)"
  QUEUED_AT="$(jq -r '.instruction.queued_at // empty' "$RECOVERY_BUNDLE" 2>/dev/null || true)"
  NEW_RUN_ID="$ACTIVE_RUN_ID"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    cat <<EOF
Dry-run bundle requeue prepared.

recovery_bundle: $RECOVERY_BUNDLE
previous_run: $PREVIOUS_RUN_ID
target_run: $NEW_RUN_ID
instruction_id: $INSTRUCTION_ID
EOF
    exit 0
  fi
else
  if [[ -z "$ACTIVE_RUN_ID" ]]; then
    echo "No active run found to recover." >&2
    exit 1
  fi

  if [[ -f "$ACTIVE_RUN_POINTER" ]]; then
    POINTER_RUN_ID="$(active_run_id || true)"
    if [[ -n "$RUN_ID" && -n "$POINTER_RUN_ID" && "$POINTER_RUN_ID" != "$RUN_ID" ]]; then
      echo "Pinned run_id ${RUN_ID} does not match the active run ${POINTER_RUN_ID}." >&2
      exit 1
    fi
  fi

  RUN_DIR="${STATE_DIR}/${ACTIVE_RUN_ID}"
  RUN_JSON="${RUN_DIR}/run.json"
  STATUS_JSON="${RUN_DIR}/status.json"
  QUEUE_FILE="$(find "${RUN_DIR}/queue" -maxdepth 1 -type f -name '*.json' 2>/dev/null | sort | head -1 || true)"

  if [[ ! -f "$RUN_JSON" || ! -f "$STATUS_JSON" ]]; then
    echo "Run metadata is incomplete for ${ACTIVE_RUN_ID}." >&2
    exit 1
  fi
  if [[ -z "$QUEUE_FILE" || ! -f "$QUEUE_FILE" ]]; then
    echo "No queued instruction found for run ${ACTIVE_RUN_ID}; nothing to recover." >&2
    exit 1
  fi

  OLD_TMUX_TARGET="$(jq -r '.tmux_target // empty' "$RUN_JSON" 2>/dev/null || true)"
  OLD_SESSION_NAME="${OLD_TMUX_TARGET%%:*}"
  INSTRUCTION_ID="$(jq -r '.instruction_id // empty' "$QUEUE_FILE" 2>/dev/null || true)"
  INSTRUCTION_TEXT="$(jq -r '.text // empty' "$QUEUE_FILE" 2>/dev/null || true)"
  QUEUED_AT="$(jq -r '.queued_at // empty' "$QUEUE_FILE" 2>/dev/null || true)"
  STATUS_STATE="$(jq -r '.state // empty' "$STATUS_JSON" 2>/dev/null || true)"

  if [[ -z "$INSTRUCTION_ID" || -z "$INSTRUCTION_TEXT" ]]; then
    echo "Queued instruction payload is missing required fields in ${QUEUE_FILE}." >&2
    exit 1
  fi

  if [[ -z "$SESSION_NAME" ]]; then
    SESSION_NAME="$(derive_next_session_name "$OLD_SESSION_NAME")"
  fi

  mkdir -p "$RECOVERY_DIR"
  RECOVERY_BUNDLE="${RECOVERY_DIR}/$(date -u +%Y%m%dT%H%M%SZ)-${INSTRUCTION_ID}.json"
  jq -n \
    --arg recovery_started_at "$(timestamp)" \
    --arg previous_run_id "$ACTIVE_RUN_ID" \
    --arg previous_session "$OLD_SESSION_NAME" \
    --arg previous_tmux_target "$OLD_TMUX_TARGET" \
    --arg previous_state "$STATUS_STATE" \
    --arg next_session "$SESSION_NAME" \
    --arg queue_file "$QUEUE_FILE" \
    --slurpfile instruction "$QUEUE_FILE" \
    '{
      recovery_started_at: $recovery_started_at,
      previous_run_id: $previous_run_id,
      previous_session: $previous_session,
      previous_tmux_target: $previous_tmux_target,
      previous_state: $previous_state,
      next_session: $next_session,
      queue_file: $queue_file,
      instruction: $instruction[0]
    }' > "$RECOVERY_BUNDLE"

  run "$ROOT/scripts/claudex-bridge-down.sh" --archive
  run "$ROOT/scripts/claudex-overnight-start.sh" --session "$SESSION_NAME" --no-attach

  if [[ "$DRY_RUN" -eq 1 ]]; then
    cat <<EOF
Dry-run dispatch recovery prepared.

previous_run: $ACTIVE_RUN_ID
instruction_id: $INSTRUCTION_ID
recovery_bundle: $RECOVERY_BUNDLE
next_session: $SESSION_NAME
EOF
    exit 0
  fi

  NEW_RUN_ID="$(wait_for_new_active_run "$ACTIVE_RUN_ID")" || {
    echo "Fresh run did not become active after restarting the session." >&2
    exit 1
  }
  PREVIOUS_RUN_ID="$ACTIVE_RUN_ID"
fi

NEW_RUN_JSON="${STATE_DIR}/${NEW_RUN_ID}/run.json"
NEW_TMUX_TARGET="$(jq -r '.tmux_target // empty' "$NEW_RUN_JSON" 2>/dev/null || true)"
if [[ -z "$NEW_TMUX_TARGET" ]]; then
  echo "Target run ${NEW_RUN_ID} is missing tmux_target." >&2
  exit 1
fi
if [[ -z "$SESSION_NAME" ]]; then
  SESSION_NAME="${NEW_TMUX_TARGET%%:*}"
fi

wait_for_claude_pane "$NEW_TMUX_TARGET" || {
  echo "Claude pane ${NEW_TMUX_TARGET} did not become ready before requeue." >&2
  exit 1
}

QUEUE_RESULT="$(queue_instruction_into_run "$NEW_RUN_ID" "$INSTRUCTION_TEXT")"
NEW_INSTRUCTION_ID="$(printf '%s\n' "$QUEUE_RESULT" | jq -r '.instruction_id // empty')"
if [[ -z "$NEW_INSTRUCTION_ID" ]]; then
  echo "queueInstruction did not return a new instruction_id." >&2
  exit 1
fi

verify_run_advances "$NEW_RUN_ID" "$NEW_INSTRUCTION_ID" || {
  echo "Fresh run ${NEW_RUN_ID} did not advance beyond queued for ${NEW_INSTRUCTION_ID}." >&2
  exit 1
}

cat <<EOF
ClauDEX dispatch recovery completed.

previous_run: ${PREVIOUS_RUN_ID:-$ACTIVE_RUN_ID}
previous_instruction: $INSTRUCTION_ID
recovery_bundle: $RECOVERY_BUNDLE
new_run: $NEW_RUN_ID
new_instruction: $NEW_INSTRUCTION_ID
session: $SESSION_NAME
claude_target: $NEW_TMUX_TARGET

Attach:
  tmux attach -t $SESSION_NAME
EOF
