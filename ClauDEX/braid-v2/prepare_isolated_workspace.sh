#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_BRAID_ROOT="${SOURCE_BRAID_ROOT:-}"
WORKSPACE="${CLAUDEX_V2_WORKSPACE:-/tmp/claudex-braid-v2-workspace}"
BRAID_WORKSPACE="${CLAUDEX_V2_BRAID_ROOT:-/tmp/claudex-braid-v2-braid}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--workspace PATH] [--braid-root PATH]

Creates an isolated braid-v2 workspace by copying the current repository tree
and a separate braid runtime root into independent paths. This avoids the
singleton bridge collision on:
  - BRAID_ROOT/runs/active-run
  - repo-local .claude/claudex/*

Defaults:
  workspace:  $WORKSPACE
  braid-root: $BRAID_WORKSPACE

After prepare, start the isolated run with:
  $WORKSPACE/ClauDEX/braid-v2/start_isolated_overnight.sh --session overnight-braid-v2 --no-attach
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      WORKSPACE="$2"
      shift 2
      ;;
    --braid-root)
      BRAID_WORKSPACE="$2"
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

for cmd in rsync git; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
done

if [[ -z "$SOURCE_BRAID_ROOT" ]]; then
  echo "Set SOURCE_BRAID_ROOT to the local braid checkout before preparing an isolated workspace." >&2
  exit 1
fi

if [[ ! -d "$SOURCE_BRAID_ROOT" ]]; then
  echo "Missing braid source root: $SOURCE_BRAID_ROOT" >&2
  exit 1
fi

mkdir -p "$WORKSPACE" "$BRAID_WORKSPACE"

rsync -a --delete \
  --exclude '.claude/claudex/' \
  --exclude 'ClauDEX/braid-v2/state/' \
  --exclude '.pytest_cache/' \
  --exclude '__pycache__/' \
  --exclude '.DS_Store' \
  "$ROOT/" "$WORKSPACE/"

rsync -a --delete \
  --exclude 'runs/' \
  --exclude 'archive/' \
  --exclude '.DS_Store' \
  "$SOURCE_BRAID_ROOT/" "$BRAID_WORKSPACE/"

mkdir -p "$WORKSPACE/ClauDEX/braid-v2"
cat > "$WORKSPACE/ClauDEX/braid-v2/isolated-env.sh" <<EOF
#!/usr/bin/env bash
export BRAID_ROOT="$BRAID_WORKSPACE"
EOF
chmod +x "$WORKSPACE/ClauDEX/braid-v2/isolated-env.sh"

cat <<EOF
braid-v2 isolated workspace prepared.

source_repo: $ROOT
workspace: $WORKSPACE
source_braid_root: $SOURCE_BRAID_ROOT
isolated_braid_root: $BRAID_WORKSPACE

Next:
  cd "$WORKSPACE"
  ./ClauDEX/braid-v2/start_isolated_overnight.sh --session overnight-braid-v2 --no-attach
EOF
