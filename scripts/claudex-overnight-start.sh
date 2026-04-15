#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
source "${SCRIPT_DIR}/claudex-common.sh"
SESSION="overnight"
ATTACH=1
LAUNCH_ENV_PREFIX=""
ACTIVE_BRAID_ROOT="${BRAID_ROOT:-${ROOT}/.b2r}"
CLAUDEX_STATE_DIR="${CLAUDEX_STATE_DIR:-$(claudex_state_dir "$ROOT" "$ACTIVE_BRAID_ROOT")}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--session NAME] [--no-attach]

Creates a fresh tmux session, boots the ClauDEX bridge, starts a fresh Claude
worker in the correct pane with the cutover settings, and attaches you.
The bridge bootstrap also launches the watchdog so relay stalls self-heal.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)
      SESSION="$2"
      shift 2
      ;;
    --no-attach)
      ATTACH=0
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

for cmd in tmux claude codex jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
done

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "tmux session '$SESSION' already exists." >&2
  echo "Attach with: tmux attach -t $SESSION" >&2
  echo "If you want a fresh session, rerun with --session ${SESSION}-2" >&2
  exit 1
fi

LAUNCH_ENV_PREFIX="export BRAID_ROOT=\"$ACTIVE_BRAID_ROOT\" CLAUDEX_STATE_DIR=\"$CLAUDEX_STATE_DIR\"; "

LEFT_PANE_ID="$(tmux new-session -d -P -F '#{pane_id}' -s "$SESSION" -c "$ROOT")"
RIGHT_PANE_ID="$(tmux split-window -h -P -F '#{pane_id}' -t "$LEFT_PANE_ID" -c "$ROOT")"

tmux select-pane -t "$LEFT_PANE_ID" -T "codex-operator" 2>/dev/null || true
tmux select-pane -t "$RIGHT_PANE_ID" -T "claude-worker" 2>/dev/null || true
tmux set-option -t "$SESSION" pane-border-status top 2>/dev/null || true
tmux set-option -t "$SESSION" pane-border-format " #{pane_title} " 2>/dev/null || true
tmux set-environment -t "$SESSION" BRAID_ROOT "$ACTIVE_BRAID_ROOT" 2>/dev/null || true
tmux set-environment -t "$SESSION" CLAUDEX_STATE_DIR "$CLAUDEX_STATE_DIR" 2>/dev/null || true

CLAUDE_PANE_TARGET="$(tmux display-message -p -t "$RIGHT_PANE_ID" '#{session_name}:#{window_index}.#{pane_index}')"
CODEX_PANE_TARGET="$(tmux display-message -p -t "$LEFT_PANE_ID" '#{session_name}:#{window_index}.#{pane_index}')"
PAIR_WINDOW_TARGET="$(tmux display-message -p -t "$LEFT_PANE_ID" '#{session_name}:#{window_index}')"

BRAID_ROOT="$ACTIVE_BRAID_ROOT" CLAUDEX_STATE_DIR="$CLAUDEX_STATE_DIR" \
  "$ROOT/scripts/claudex-bridge-up.sh" --tmux-target "$CLAUDE_PANE_TARGET" --no-daemon

tmux send-keys -t "$RIGHT_PANE_ID" "${LAUNCH_ENV_PREFIX}cd \"$ROOT\" && clear && ./scripts/claudex-claude-launch.sh" C-m
tmux send-keys -t "$LEFT_PANE_ID" "${LAUNCH_ENV_PREFIX}cd \"$ROOT\" && clear && ./scripts/claudex-codex-launch.sh" C-m
tmux new-window -d -a -t "$PAIR_WINDOW_TARGET" -n "claudex-monitor" -c "$ROOT" \
  "${LAUNCH_ENV_PREFIX}cd \"$ROOT\" && exec bash ./scripts/claudex-progress-monitor.sh --codex-target \"$CODEX_PANE_TARGET\""
tmux new-window -d -a -t "$PAIR_WINDOW_TARGET" -n "claudex-helper" -c "$ROOT" \
  "${LAUNCH_ENV_PREFIX}cd \"$ROOT\" && mkdir -p \"$CLAUDEX_STATE_DIR\" && \
  bash ./scripts/claudex-auto-submit.sh >> \"$CLAUDEX_STATE_DIR/auto-submit.log\" 2>&1 & echo \$! > \"$CLAUDEX_STATE_DIR/auto-submit.pid\" && \
  bash ./scripts/claudex-codex-approver.sh --tmux-target \"$CODEX_PANE_TARGET\" >> \"$CLAUDEX_STATE_DIR/codex-approver.log\" 2>&1 & echo \$! > \"$CLAUDEX_STATE_DIR/codex-approver.pid\" && \
  bash ./scripts/claudex-worker-approver.sh --tmux-target \"$CLAUDE_PANE_TARGET\" >> \"$CLAUDEX_STATE_DIR/worker-approver.log\" 2>&1 & echo \$! > \"$CLAUDEX_STATE_DIR/worker-approver.pid\" && \
  exec bash ./scripts/claudex-watchdog.sh --tmux-target \"$CLAUDE_PANE_TARGET\" >> \"$CLAUDEX_STATE_DIR/watchdog.log\" 2>&1"

cat <<EOF
ClauDEX overnight session is ready.

session: $SESSION
repo_root: $ROOT
braid_root: $ACTIVE_BRAID_ROOT
lane_state_dir: $CLAUDEX_STATE_DIR
codex_pane: $CODEX_PANE_TARGET
claude_pane: $CLAUDE_PANE_TARGET

Attach:
  tmux attach -t $SESSION

Inside tmux:
  left pane  = Codex operator
  right pane = fresh Claude worker under the cutover profile

The bridge helper window owns the watchdog, auto-submit loop, Codex MCP
trust approver, and worker approval helper.
The progress monitor is started automatically in the tmux window
'claudex-monitor' and samples the Codex pane every 30 minutes.
Bridge status is available any time with:
  ./scripts/claudex-bridge-status.sh
EOF

if [[ "$ATTACH" -eq 1 ]]; then
  exec tmux attach -t "$SESSION"
fi
