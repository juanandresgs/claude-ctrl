#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
BRAID_ROOT="${BRAID_ROOT:-${ROOT}/.b2r}"
POINTER="${BRAID_ROOT}/runs/active-run"

CHOICE=""

usage() {
  cat <<EOF
Usage: $(basename "$0") --choice VALUE

Resolve the active run's current interaction gate by sending the selected
choice to the worker tmux pane after re-verifying the gate is still present.

Examples:
  $(basename "$0") --choice 1
  $(basename "$0") --choice 2
  $(basename "$0") --choice y
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --choice)
      CHOICE="$2"
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

if [[ -z "$CHOICE" ]]; then
  echo "--choice is required" >&2
  usage >&2
  exit 1
fi

if [[ ! -f "$POINTER" ]]; then
  echo "No active bridge run." >&2
  exit 1
fi

RUN_ID="$(tr -d '[:space:]' < "$POINTER" 2>/dev/null || true)"
if [[ -z "$RUN_ID" ]]; then
  echo "Active-run pointer is empty." >&2
  exit 1
fi

RUN_DIR="${BRAID_ROOT}/runs/${RUN_ID}"
RUN_JSON="${RUN_DIR}/run.json"
if [[ ! -f "$RUN_JSON" ]]; then
  echo "Run metadata missing: $RUN_JSON" >&2
  exit 1
fi

TMUX_TARGET="$(jq -r '.tmux_target // empty' "$RUN_JSON" 2>/dev/null || true)"
if [[ -z "$TMUX_TARGET" ]]; then
  echo "Active run has no worker tmux target." >&2
  exit 1
fi

exec node "$ROOT/ClauDEX/bridge/interaction_gate.mjs" \
  resolve \
  --run-dir "$RUN_DIR" \
  --tmux-target "$TMUX_TARGET" \
  --choice "$CHOICE"
