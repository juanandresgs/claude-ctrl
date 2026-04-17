#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SOURCE_DIR="${ROOT}/agents"
TARGET_DIR="${ROOT}/.claude/agents"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--check]

Sync the canonical repo-owned role prompts from agents/ into Claude Code's
native project agent surface at .claude/agents/.

Options:
  --check   Fail if .claude/agents/ is missing, stale, or divergent.
EOF
}

CHECK_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      CHECK_ONLY=1
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

if [[ ! -d "$SOURCE_DIR" ]]; then
  echo "Missing canonical agents directory: $SOURCE_DIR" >&2
  exit 1
fi

source_files=()
while IFS= read -r path; do
  source_files+=("$path")
done < <(find "$SOURCE_DIR" -maxdepth 1 -type f -name '*.md' -print | sort)
if [[ "${#source_files[@]}" -eq 0 ]]; then
  echo "No canonical agent files found under $SOURCE_DIR" >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"

status=0
for source_path in "${source_files[@]}"; do
  name="$(basename "$source_path")"
  target_path="${TARGET_DIR}/${name}"
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    if [[ ! -f "$target_path" ]]; then
      echo "Missing projected Claude agent: $target_path" >&2
      status=1
      continue
    fi
    if ! cmp -s "$source_path" "$target_path"; then
      echo "Projected Claude agent drifted from canonical source: $target_path" >&2
      status=1
    fi
    continue
  fi

  if [[ ! -f "$target_path" ]] || ! cmp -s "$source_path" "$target_path"; then
    cp "$source_path" "$target_path"
  fi
done

target_files=()
while IFS= read -r path; do
  target_files+=("$path")
done < <(find "$TARGET_DIR" -maxdepth 1 -type f -name '*.md' -print | sort)
for target_path in "${target_files[@]}"; do
  name="$(basename "$target_path")"
  source_path="${SOURCE_DIR}/${name}"
  if [[ -f "$source_path" ]]; then
    continue
  fi
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    echo "Unexpected projected Claude agent not backed by canonical source: $target_path" >&2
    status=1
    continue
  fi
  rm -f "$target_path"
done

exit "$status"
