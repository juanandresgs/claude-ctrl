#!/usr/bin/env bash
set -euo pipefail

resolve_repo_root() {
  if command -v git >/dev/null 2>&1; then
    git rev-parse --show-toplevel 2>/dev/null && return 0
  fi
  local script_dir
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  cd "${script_dir}/.." && pwd
}

resolve_default_braid_root() {
  local repo_root="$1"
  local marker="${repo_root}/.claude/claudex/braid-root"
  if [[ -f "$marker" ]]; then
    local from_marker
    from_marker="$(tr -d '[:space:]' < "$marker" 2>/dev/null || true)"
    if [[ -n "$from_marker" ]]; then
      printf '%s\n' "$from_marker"
      return 0
    fi
  fi
  printf '%s/.b2r\n' "$repo_root"
}

REPO_ROOT="$(resolve_repo_root)"
BRAID_ROOT_DEFAULT="$(resolve_default_braid_root "$REPO_ROOT")"
BRAID_ROOT="${BRAID_ROOT:-$BRAID_ROOT_DEFAULT}"
BRAID_HOOK="${BRAID_ROOT}/hooks/stop-relay.sh"

if [[ ! -x "$BRAID_HOOK" ]]; then
  exit 0
fi

export BRIDGE_RUNS_DIR="${BRIDGE_RUNS_DIR:-${BRAID_ROOT}/runs}"
exec "$BRAID_HOOK"
