#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage:
  ./scripts/scratchlane-exec.sh --task-slug <task> -- <command> [args...]
EOF
}

escape_sb() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
    echo "scratchlane-exec: failed to resolve repo root" >&2
    exit 1
fi

TASK_SLUG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --task-slug)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            TASK_SLUG="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

[[ -n "$TASK_SLUG" ]] || { usage; exit 2; }
[[ $# -gt 0 ]] || { usage; exit 2; }

RUNTIME_CLI="$REPO_ROOT/runtime/cli.py"
PERMIT_JSON="$(python3 "$RUNTIME_CLI" scratchlane get --project-root "$REPO_ROOT" --task-slug "$TASK_SLUG")"
FOUND="$(printf '%s' "$PERMIT_JSON" | jq -r '.found // false' 2>/dev/null || echo false)"
if [[ "$FOUND" != "true" ]]; then
    echo "scratchlane-exec: scratchlane '$TASK_SLUG' is not active. Ask the user to approve task scratchlane tmp/.claude-scratch/$TASK_SLUG/ in chat, or grant it manually with: python3 runtime/cli.py scratchlane grant --task-slug $TASK_SLUG" >&2
    exit 1
fi

SCRATCH_ROOT="$(printf '%s' "$PERMIT_JSON" | jq -r '.permit.root_path // empty' 2>/dev/null || echo '')"
if [[ -z "$SCRATCH_ROOT" ]]; then
    echo "scratchlane-exec: active permit for '$TASK_SLUG' did not include a root path" >&2
    exit 1
fi

if ! command -v sandbox-exec >/dev/null 2>&1; then
    echo "scratchlane-exec: sandbox-exec is required for opaque interpreter execution" >&2
    exit 1
fi

SCRATCH_TMP="$SCRATCH_ROOT/.tmp"
mkdir -p "$SCRATCH_ROOT" "$SCRATCH_TMP"

PROFILE_FILE="$(mktemp "$SCRATCH_TMP/sandbox.XXXXXX")"
cleanup() {
    rm -f "$PROFILE_FILE"
}
trap cleanup EXIT

SCRATCH_ROOT_ESC="$(escape_sb "$SCRATCH_ROOT")"
cat >"$PROFILE_FILE" <<EOF
(version 1)
(import "system.sb")
(deny default)
(allow process*)
(allow network*)
(allow file-read*)
(allow file-write* (subpath "$SCRATCH_ROOT_ESC"))
EOF

cd "$SCRATCH_ROOT"
export CC_SCRATCH_ROOT="$SCRATCH_ROOT"
export TMPDIR="$SCRATCH_TMP"

exec sandbox-exec -f "$PROFILE_FILE" "$@"
