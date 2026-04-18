#!/usr/bin/env bash

claudex_lane_name() {
  local braid_root="${2:-}"
  local base="${braid_root##*/}"
  base="${base#.}"

  case "$base" in
    ""|b2r)
      printf 'default\n'
      ;;
    b2r-*)
      printf '%s\n' "$base"
      ;;
    *)
      printf 'default\n'
      ;;
  esac
}

claudex_state_dir() {
  local root="$1"
  local braid_root="${2:-${root}/.b2r}"
  local state_root="${root}/.claude/claudex"
  local lane

  if [[ -d "$state_root" ]]; then
    local lane_dir="" lane_hint=""
    shopt -s nullglob
    for lane_dir in "${state_root}/"*; do
      [[ -d "$lane_dir" ]] || continue
      [[ -f "${lane_dir}/braid-root" ]] || continue
      lane_hint="$(tr -d '[:space:]' < "${lane_dir}/braid-root" 2>/dev/null || true)"
      if [[ -n "$lane_hint" && "$lane_hint" == "$braid_root" ]]; then
        shopt -u nullglob
        printf '%s\n' "$lane_dir"
        return 0
      fi
    done
    shopt -u nullglob

    local direct_hint=""
    if [[ -f "${state_root}/braid-root" ]]; then
      direct_hint="$(tr -d '[:space:]' < "${state_root}/braid-root" 2>/dev/null || true)"
      if [[ -n "$direct_hint" && "$direct_hint" == "$braid_root" ]]; then
        printf '%s\n' "$state_root"
        return 0
      fi
    fi
  fi

  lane="$(claudex_lane_name "$root" "$braid_root")"

  if [[ "$lane" == "default" ]]; then
    printf '%s/.claude/claudex\n' "$root"
  else
    printf '%s/.claude/claudex/%s\n' "$root" "$lane"
  fi
}

claudex_resolve_braid_root() {
  local root="$1"
  local explicit="${2:-}"
  local state_dir_hint="${3:-}"

  if [[ -n "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return 0
  fi

  if [[ -n "$state_dir_hint" && -f "${state_dir_hint}/braid-root" ]]; then
    local hinted=""
    hinted="$(tr -d '[:space:]' < "${state_dir_hint}/braid-root" 2>/dev/null || true)"
    if [[ -n "$hinted" ]]; then
      printf '%s\n' "$hinted"
      return 0
    fi
  fi

  if [[ -f "${root}/.claude/claudex/braid-root" ]]; then
    local root_hint=""
    root_hint="$(tr -d '[:space:]' < "${root}/.claude/claudex/braid-root" 2>/dev/null || true)"
    if [[ -n "$root_hint" ]]; then
      printf '%s\n' "$root_hint"
      return 0
    fi
  fi

  printf '%s\n' "${root}/.b2r"
}

claudex_runtime_cli() {
  local common_dir
  common_dir="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s\n' "${CLAUDEX_RUNTIME_CLI:-${common_dir}/../runtime/cli.py}"
}

claudex_runtime_python() {
  if [[ -n "${CLAUDEX_PYTHON_BIN:-}" ]]; then
    printf '%s\n' "${CLAUDEX_PYTHON_BIN}"
    return 0
  fi

  local candidate=""
  for candidate in python3 /opt/homebrew/bin/python3 /usr/bin/python3; do
    if [[ "$candidate" != */* ]]; then
      command -v "$candidate" >/dev/null 2>&1 || continue
      candidate="$(command -v "$candidate")"
    elif [[ ! -x "$candidate" ]]; then
      continue
    fi

    if "$candidate" -c 'import yaml' >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  printf '%s\n' "python3"
}

claudex_bridge_topology_json() {
  local braid_root="$1"
  local state_dir="$2"
  shift 2 || true

  "$(claudex_runtime_python)" "$(claudex_runtime_cli)" \
    bridge topology \
    --braid-root "$braid_root" \
    --state-dir "$state_dir" \
    "$@"
}
