#!/usr/bin/env bash
set -euo pipefail

BRAID_ROOT="${BRAID_ROOT:-/Users/turla/Code/braid}"
BRAID_HOOK="${BRAID_ROOT}/hooks/stop-relay.sh"

if [[ ! -x "$BRAID_HOOK" ]]; then
  exit 0
fi

export BRIDGE_RUNS_DIR="${BRIDGE_RUNS_DIR:-${BRAID_ROOT}/runs}"
exec "$BRAID_HOOK"
