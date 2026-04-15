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
  local lane
  lane="$(claudex_lane_name "$root" "$braid_root")"

  if [[ "$lane" == "default" ]]; then
    printf '%s/.claude/claudex\n' "$root"
  else
    printf '%s/.claude/claudex/%s\n' "$root" "$lane"
  fi
}
