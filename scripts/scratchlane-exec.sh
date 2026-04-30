#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage:
  scratchlane-exec.sh --task-slug <task> [--project-root <path>] -- <command> [args...]
EOF
}

escape_sb() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTROL_ROOT="$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$CONTROL_ROOT" ]]; then
    echo "scratchlane-exec: failed to resolve control-plane root" >&2
    exit 1
fi

TASK_SLUG=""
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --task-slug)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            TASK_SLUG="$2"
            shift 2
            ;;
        --project-root)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            PROJECT_ROOT="$2"
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

if [[ -z "$PROJECT_ROOT" ]]; then
    PROJECT_ROOT="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
fi
if [[ -z "$PROJECT_ROOT" ]]; then
    PROJECT_ROOT="$CONTROL_ROOT"
fi
PROJECT_ROOT="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P)" || {
    echo "scratchlane-exec: failed to resolve project root: $PROJECT_ROOT" >&2
    exit 1
}

RUNTIME_CLI="$CONTROL_ROOT/runtime/cli.py"
PERMIT_JSON="$(python3 "$RUNTIME_CLI" scratchlane get --project-root "$PROJECT_ROOT" --task-slug "$TASK_SLUG")"
FOUND="$(printf '%s' "$PERMIT_JSON" | jq -r '.found // false' 2>/dev/null || echo false)"
if [[ "$FOUND" != "true" ]]; then
    echo "scratchlane-exec: scratchlane '$TASK_SLUG' is not active for $PROJECT_ROOT. Ask the user to approve task scratchlane tmp/.claude-scratch/$TASK_SLUG/ in chat, or grant it manually with: python3 $RUNTIME_CLI scratchlane grant --project-root $PROJECT_ROOT --task-slug $TASK_SLUG" >&2
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
