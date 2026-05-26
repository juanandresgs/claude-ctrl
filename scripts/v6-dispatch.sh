#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
WF_ID="${1:-$(basename "$ROOT" | tr -cs '[:alnum:]_.-' '-' | sed 's/^-//;s/-$//')}"
export CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$ROOT}"

BOOT=$(cc-policy stage bootstrap --workflow-id "$WF_ID" --worktree-path "$ROOT" --prompt "${*:2}" 2>/dev/null || true)
TICKET=$(printf '%s' "$BOOT" | jq -r '.prompt_prefix // empty' 2>/dev/null || true)
ROLE=$(printf '%s' "$BOOT" | jq -r '.subagent_type // empty' 2>/dev/null || true)
STAGE=$(printf '%s' "$BOOT" | jq -r '.stage_id // empty' 2>/dev/null || true)

if [[ -z "$TICKET" ]]; then
  printf '%s\n' "$BOOT" >&2
  exit 1
fi

cat <<EOF
Launch ${ROLE:-agent} for v6 stage ${STAGE:-unknown} with prompt line 1:

$TICKET

Then put the task below that line. The runtime will inject the rest.
EOF
