#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
ROOT="$(git rev-parse --show-toplevel)"
source "${SCRIPT_DIR}/claudex-common.sh"
BRAID_ROOT="${BRAID_ROOT:-${ROOT}/.b2r}"
PID_DIR="${CLAUDEX_STATE_DIR:-$(claudex_state_dir "$ROOT" "$BRAID_ROOT")}"
PID_FILE="${PID_DIR}/worker-approver.pid"
STATE_FILE="${PID_DIR}/worker-approver.state"
LOG_FILE="${PID_DIR}/worker-approver.log"
TMUX_TARGET=""
INTERVAL_SECONDS="${CLAUDEX_WORKER_APPROVER_INTERVAL_SECONDS:-2}"
RETRY_SECONDS="${CLAUDEX_WORKER_APPROVER_RETRY_SECONDS:-8}"
ALLOW_PUSH="${CLAUDEX_WORKER_APPROVER_ALLOW_PUSH:-1}"

usage() {
  cat <<'EOF'
Usage:
  scripts/claudex-worker-approver.sh --tmux-target <session:window.pane>
  scripts/claudex-worker-approver.sh --classify-stdin

Monitors the Claude worker pane and auto-selects "Allow" only for routine
worker prompts that the supervisor is expected to own: directory trust,
bounded test runs, routine git add/status/diff/commit/straightforward push,
roadmap/doc updates, and other non-destructive repo-local tool actions.
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

recent_capture_from_capture() {
  local capture="$1"
  printf '%s\n' "$capture" | tail -40
}

prompt_hash() {
  local capture="$1"
  printf '%s' "$capture" | cksum | awk '{print $1}'
}

is_directory_trust_prompt() {
  local capture="$1"
  [[ "$capture" == *"Do you trust the contents of this directory?"* ]] &&
    [[ "$capture" == *"Press enter to continue"* ]]
}

is_worker_approval_prompt() {
  local capture="$1"
  [[ "$capture" == *"Tool call needs your approval."* ]] &&
    [[ "$capture" == *"1. Allow"* ]] &&
    [[ "$capture" == *"enter to submit"* ]]
}

capture_has_deny_pattern() {
  local capture="$1"
  local deny_pattern='git reset --hard|git checkout --|git clean( |$)|rm -rf|rm -fr|force push|git push --force|--force-with-lease|git rebase|git cherry-pick|git stash|git restore|git revert|filter-branch|filter-repo'
  printf '%s\n' "$capture" | grep -Eiq "$deny_pattern"
}

capture_has_allow_pattern() {
  local capture="$1"
  local allow_pattern='pytest|python(3)? -m pytest|tests?|git add|git status|git diff|git commit|roadmap|doc(s|umentation)?|checkpoint|stage(d|ing)?|validate|constitution|hook(s)?|workflow|scope|approval|branch|status summary|read file|write file|modify .*workspace|active workspace'
  printf '%s\n' "$capture" | grep -Eiq "$allow_pattern"
}

capture_has_push_pattern() {
  local capture="$1"
  printf '%s\n' "$capture" | grep -Eiq 'git push|push to remote|publish branch'
}

worker_prompt_policy() {
  local capture="$1"

  if is_directory_trust_prompt "$capture"; then
    printf '%s\n' "trust"
    return 0
  fi

  if ! is_worker_approval_prompt "$capture"; then
    printf '%s\n' "ignore"
    return 0
  fi

  if capture_has_deny_pattern "$capture"; then
    printf '%s\n' "deny"
    return 0
  fi

  if capture_has_push_pattern "$capture" && [[ "$ALLOW_PUSH" != "1" ]]; then
    printf '%s\n' "deny"
    return 0
  fi

  if capture_has_allow_pattern "$capture"; then
    printf '%s\n' "allow"
    return 0
  fi

  printf '%s\n' "ignore"
}

classify_stdin() {
  local capture
  capture="$(cat)"
  worker_prompt_policy "$capture"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tmux-target)
      TMUX_TARGET="${2:-}"
      shift 2
      ;;
    --classify-stdin)
      classify_stdin
      exit 0
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

  pane="$(tmux capture-pane -p -t "$TMUX_TARGET" -S -120 2>/dev/null || true)"
  pane_pid="$(tmux display-message -p -t "$TMUX_TARGET" '#{pane_pid}' 2>/dev/null || true)"
  recent_capture="$(recent_capture_from_capture "$pane")"
  policy="$(worker_prompt_policy "$recent_capture")"
  now="$(date +%s)"

  case "$policy" in
    trust)
      fingerprint="${TMUX_TARGET}:${pane_pid}:trust:$(prompt_hash "$recent_capture")"
      if should_send "$fingerprint" "$now"; then
        send_choice 1
        record_state "$fingerprint" "$now"
        log "auto-approved worker directory trust prompt in ${TMUX_TARGET}"
      fi
      ;;
    allow)
      fingerprint="${TMUX_TARGET}:${pane_pid}:allow:$(prompt_hash "$recent_capture")"
      if should_send "$fingerprint" "$now"; then
        send_choice 1
        record_state "$fingerprint" "$now"
        log "auto-approved worker routine tool prompt in ${TMUX_TARGET}"
      fi
      ;;
    deny)
      fingerprint="${TMUX_TARGET}:${pane_pid}:deny:$(prompt_hash "$recent_capture")"
      if [[ "$fingerprint" != "$last_fingerprint" ]]; then
        record_state "$fingerprint" "$now"
        log "left worker approval prompt for manual review in ${TMUX_TARGET}"
      fi
      ;;
    *)
      clear_state
      ;;
  esac

  sleep "$INTERVAL_SECONDS"
done
