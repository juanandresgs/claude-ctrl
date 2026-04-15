#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
source "${SCRIPT_DIR}/claudex-common.sh"
BRAID_ROOT="${BRAID_ROOT:-${ROOT}/.b2r}"
BRIDGE_STATE_DIR="${BRIDGE_STATE_DIR:-${BRAID_ROOT}/runs}"
CLAUDEX_STATE_DIR="${CLAUDEX_STATE_DIR:-$(claudex_state_dir "$ROOT" "$BRAID_ROOT")}"
LOCAL_CODEX_HOME="${CLAUDEX_STATE_DIR}/codex-home-live"
LOCAL_CODEX_ARCHIVES="${CLAUDEX_STATE_DIR}/codex-home-archives"
PROMPT_FILE="${ROOT}/.codex/prompts/claudex_handoff.txt"

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "Missing supervisor prompt: $PROMPT_FILE" >&2
  exit 1
fi

prepare_local_codex_home() {
  mkdir -p "$LOCAL_CODEX_HOME"

  if [[ ! -e "${LOCAL_CODEX_HOME}/auth.json" ]] && [[ -f "${HOME}/.codex/auth.json" ]]; then
    ln -sf "${HOME}/.codex/auth.json" "${LOCAL_CODEX_HOME}/auth.json"
  fi

  # Keep CODEX_HOME limited to supervisor-local state plus the one MCP server
  # definition the supervisor needs. Do not mirror repo hooks/prompts here.
  for entry in hooks.json hooks prompts; do
    dest="${LOCAL_CODEX_HOME}/${entry}"
    if [[ -e "$dest" || -L "$dest" ]]; then
      rm -rf "$dest"
    fi
  done

  cat >"${LOCAL_CODEX_HOME}/config.toml" <<EOF
model = "${CLAUDEX_CODEX_MODEL:-gpt-5.3-codex}"
model_reasoning_effort = "${CLAUDEX_CODEX_REASONING_EFFORT:-xhigh}"

[mcp_servers.claude_bridge]
transport = "stdio"
command = "node"
args = ["${ROOT}/ClauDEX/bridge/claudex-bridge-mcp-server.mjs"]

[mcp_servers.claude_bridge.env]
BRAID_ROOT = "${BRAID_ROOT}"
BRIDGE_STATE_DIR = "${BRIDGE_STATE_DIR}"

[mcp_servers.claude_bridge.tools.send_instruction]
approval_mode = "auto"

[mcp_servers.claude_bridge.tools.get_status]
approval_mode = "auto"

[mcp_servers.claude_bridge.tools.get_response]
approval_mode = "auto"

[mcp_servers.claude_bridge.tools.wait_for_response]
approval_mode = "auto"

[mcp_servers.claude_bridge.tools.wait_for_codex_review]
approval_mode = "auto"

[mcp_servers.claude_bridge.tools.get_conversation]
approval_mode = "approve"

[mcp_servers.claude_bridge.tools.get_worker_observer]
approval_mode = "approve"

[projects."${ROOT}"]
trust_level = "trusted"
EOF

  python3 - "${LOCAL_CODEX_HOME}/version.json" <<'PY'
import json
import sys
from datetime import datetime, timezone

path = sys.argv[1]
try:
    with open(path, 'r', encoding='utf-8') as handle:
        payload = json.load(handle)
except Exception:
    payload = {}
payload['latest_version'] = payload.get('latest_version') or '0.120.0'
payload['last_checked_at'] = payload.get('last_checked_at') or datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
payload['dismissed_version'] = payload.get('latest_version')
with open(path, 'w', encoding='utf-8') as handle:
    json.dump(payload, handle, separators=(',', ':'))
    handle.write('\n')
PY
}

archive_and_reset_local_codex_home() {
  mkdir -p "$LOCAL_CODEX_ARCHIVES"
  if [[ -e "$LOCAL_CODEX_HOME" || -L "$LOCAL_CODEX_HOME" ]]; then
    stamp="$(date +%Y%m%dT%H%M%S)"
    mv "$LOCAL_CODEX_HOME" "${LOCAL_CODEX_ARCHIVES}/codex-home-live-${stamp}"
  fi
  mkdir -p "$LOCAL_CODEX_HOME"
}

probe_local_codex_home() {
  CODEX_HOME="$LOCAL_CODEX_HOME" codex \
    -C "$ROOT" \
    mcp get claude_bridge >/dev/null 2>&1
}

prepare_local_codex_home
if ! probe_local_codex_home; then
  archive_and_reset_local_codex_home
  prepare_local_codex_home
  if ! probe_local_codex_home; then
    echo "Supervisor bootstrap failed: Codex home probe did not pass." >&2
    exit 1
  fi
fi

mkdir -p "$CLAUDEX_STATE_DIR"
printf '%s\n' "$BRAID_ROOT" > "${CLAUDEX_STATE_DIR}/braid-root"
mkdir -p "${ROOT}/.claude/claudex"
printf '%s\n' "$BRAID_ROOT" > "${ROOT}/.claude/claudex/braid-root"

export CODEX_HOME="$LOCAL_CODEX_HOME"
export CLAUDEX_SUPERVISOR=1
export CLAUDEX_STATE_DIR
export BRAID_ROOT
export BRIDGE_STATE_DIR

INITIAL_PROMPT="$(
  {
    cat "$PROMPT_FILE"
    cat <<'EOF'

Operational discipline:
- If `wait_for_codex_review()` returns because the connector/tool layer timed out or was interrupted while the bridge remains `queued` or `inflight`, do not re-summarize the whole situation.
- In that case, call `get_status()` once, emit at most two short sentences, and immediately return to `wait_for_codex_review(timeout_ms=1200000)`.
- Treat repeated ~120s wakeups as connector behavior, not as a new bridge investigation trigger by themselves.
- Routine checkpoint branch / stage / commit / push work is guardian-equivalent, not an automatic stop condition.
- When an accepted slice leaves the repo in a coherent uncheckpointed state, dispatch a bounded checkpoint-stewardship slice before opening new implementation work.
- Escalate only for destructive git actions, missing upstream placement, ambiguous mixed changes, or sensitive artifacts.
- Report branch, commit SHA, push target, included scope, excluded scope, and test evidence after checkpoint work.
- Use the lane-local handoff artifact path printed below, not repo-global `.claude/claudex/...` defaults.
- If non-destructive checkpoint commit/push work is blocked only by the Claude harness approval gate, treat that as checkpoint debt rather than a terminal stop: preserve the staged bundle, report the blocked checkpoint clearly, and continue the next bounded cutover slice.
- If queued or inflight bridge work still exists and the read-only Codex seat cannot perform write-side recovery itself, do not stop the supervisor. Rely on the repo-local watchdog / dispatch-recovery path and stay in the loop.
EOF
    printf '\nLane-local supervisor state:\n- Active lane state dir: %s\n- Active bridge handoff artifact: %s/pending-review.json\n' \
      "$CLAUDEX_STATE_DIR" \
      "$CLAUDEX_STATE_DIR"
  }
)"

exec codex \
  -m "${CLAUDEX_CODEX_MODEL:-gpt-5.3-codex}" \
  -c "model_reasoning_effort=\"${CLAUDEX_CODEX_REASONING_EFFORT:-xhigh}\"" \
  -c "mcp_servers.claude_bridge.transport=\"stdio\"" \
  -c "mcp_servers.claude_bridge.env.BRAID_ROOT=\"$BRAID_ROOT\"" \
  -c "mcp_servers.claude_bridge.env.BRIDGE_STATE_DIR=\"$BRIDGE_STATE_DIR\"" \
  --sandbox read-only \
  --ask-for-approval never \
  --no-alt-screen \
  -C "$ROOT" \
  "$INITIAL_PROMPT"
