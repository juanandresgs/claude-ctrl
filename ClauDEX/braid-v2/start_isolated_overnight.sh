#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$SCRIPT_DIR/isolated-env.sh"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing isolated environment file: $ENV_FILE" >&2
  echo "Prepare the workspace first with:" >&2
  echo "  $SCRIPT_DIR/prepare_isolated_workspace.sh" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

if [[ -z "${BRAID_ROOT:-}" ]]; then
  echo "isolated-env.sh did not set BRAID_ROOT" >&2
  exit 1
fi

cd "$ROOT"
exec ./scripts/claudex-overnight-start.sh "$@"
