#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$ROOT/tmp/test-v6-prompt-bootstrap-$$"
DB="$TMP/state.db"
REPO="$TMP/repo"
HOME_DIR="$TMP/home"
BIN_DIR="$TMP/bin"
mkdir -p "$REPO/.claude" "$HOME_DIR/.claude/scripts" "$BIN_DIR"
trap 'rm -rf "$TMP"' EXIT

ln -s "$ROOT/scripts/todo.sh" "$HOME_DIR/.claude/scripts/todo.sh"
cat > "$BIN_DIR/gh" <<'SH'
#!/usr/bin/env bash
sleep 2
exit 1
SH
chmod +x "$BIN_DIR/gh"

git -C "$REPO" init >/dev/null 2>&1
git -C "$REPO" config user.name Test
git -C "$REPO" config user.email test@example.com
touch "$REPO/README.md"
git -C "$REPO" add README.md && git -C "$REPO" commit -m seed >/dev/null 2>&1

export CLAUDE_POLICY_DB="$DB"
export CLAUDE_PROJECT_DIR="$REPO"
export HOME="$HOME_DIR"
export PATH="$BIN_DIR:$ROOT/bin:$PATH"
export TODO_HUD_TIMEOUT=0.2
python3 "$ROOT/runtime/cli.py" schema ensure >/dev/null

PAYLOAD=$(jq -n '{prompt:"Implement a tiny feature through v6"}')
RUN_JSON=$(
  python3 - "$ROOT/hooks/prompt-submit.sh" "$PAYLOAD" <<'PY'
import json
import subprocess
import sys
import time

hook = sys.argv[1]
payload = sys.argv[2]
started = time.monotonic()
completed = subprocess.run(
    [hook],
    input=payload,
    text=True,
    capture_output=True,
    timeout=5,
)
elapsed = time.monotonic() - started
print(json.dumps({
    "returncode": completed.returncode,
    "elapsed": elapsed,
    "stdout": completed.stdout,
    "stderr": completed.stderr,
}))
PY
)
printf '%s' "$RUN_JSON" | jq -e '.returncode == 0 and .elapsed < 5' >/dev/null
OUT=$(printf '%s' "$RUN_JSON" | jq -r '.stdout')
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("V6_DISPATCH_READY")' >/dev/null
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext')
printf '%s' "$CTX" | grep -q 'V6_DISPATCH_READY: launch planner for stage planner'
! printf '%s' "$CTX" | grep -q 'CLAUDE_CTRL_TICKET'
BRANCH=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)
WF=$(printf '%s' "$BRANCH" | tr '/_ ' '---' | tr -cd '[:alnum:]-')
CLAIM=$(python3 "$ROOT/runtime/cli.py" stage launch-claim --subagent-type planner --workflow-id "$WF" --worktree-path "$REPO" --prompt "Natural planner launch.")
printf '%s' "$CLAIM" | jq -e '.stage_run.stage_id == "planner"' >/dev/null

echo "PASS test-v6-prompt-bootstrap"
