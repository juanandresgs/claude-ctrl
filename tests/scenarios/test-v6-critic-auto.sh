#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNTIME="$ROOT/runtime/cli.py"
RESULT_HOOK="$ROOT/hooks/v6-result-submit.sh"
TMP="$ROOT/tmp/test-v6-critic-auto-$$"
DB="$TMP/state.db"
REPO="$TMP/repo"
mkdir -p "$REPO/.claude"
trap 'rm -rf "$TMP"' EXIT

git -C "$REPO" init >/dev/null 2>&1
git -C "$REPO" config user.name Test
git -C "$REPO" config user.email test@example.com
touch "$REPO/README.md"
git -C "$REPO" add README.md && git -C "$REPO" commit -m seed >/dev/null 2>&1
HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)

export CLAUDE_POLICY_DB="$DB"
export CLAUDE_CTRL_CRITIC_PROVIDERS="critic-subagent"
python3 "$RUNTIME" schema ensure >/dev/null
RUN_JSON=$(python3 "$RUNTIME" stage run-create --workflow-id wf-v6-critic --stage-id implementer --worktree-path "$REPO")
RUN=$(printf '%s' "$RUN_JSON" | jq -r '.stage_run.id')
RESP=$(jq -n --arg run "$RUN" --arg sha "$HEAD_SHA" '{agent_type:"implementer", last_assistant_message:("Done\n```claude_ctrl_result\n{\"stage_run_id\":\""+$run+"\",\"stage_id\":\"implementer\",\"verdict\":\"complete\",\"summary\":\"implemented\",\"head_sha\":\""+$sha+"\"}\n```") }')
OUT=$(printf '%s' "$RESP" | CLAUDE_PROJECT_DIR="$REPO" "$RESULT_HOOK")
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext')
printf '%s' "$CTX" | grep -q 'V6_CRITIC_FALLBACK'
printf '%s' "$CTX" | grep -q 'V6_DISPATCH_READY: launch critic for stage critic'
! printf '%s' "$CTX" | grep -q 'CLAUDE_CTRL_TICKET'
CLAIM=$(python3 "$RUNTIME" stage launch-claim --subagent-type critic --workflow-id wf-v6-critic --worktree-path "$REPO" --prompt "Run adversarial critic.")
[[ $(printf '%s' "$CLAIM" | jq -r '.ticket.subagent_type') == critic ]]
[[ $(printf '%s' "$CLAIM" | jq -r '.stage_run.stage_id') == critic ]]

echo "PASS test-v6-critic-auto"
