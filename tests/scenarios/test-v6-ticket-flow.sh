#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNTIME="$ROOT/runtime/cli.py"
PRE_AGENT="$ROOT/hooks/pre-agent.sh"
SUB_START="$ROOT/hooks/subagent-start.sh"
RESULT_HOOK="$ROOT/hooks/v6-result-submit.sh"
PRE_WRITE="$ROOT/hooks/pre-write.sh"
TMP="$ROOT/tmp/test-v6-ticket-flow-$$"
REPO="$TMP/repo"
DB="$REPO/.claude/state.db"
mkdir -p "$REPO/.claude"
trap 'rm -rf "$TMP"' EXIT

git -C "$REPO" init >/dev/null 2>&1
git -C "$REPO" config user.name Test
git -C "$REPO" config user.email test@example.com
touch "$REPO/README.md"
git -C "$REPO" add README.md && git -C "$REPO" commit -m seed >/dev/null 2>&1

export CLAUDE_POLICY_DB="$DB"
python3 "$RUNTIME" schema ensure >/dev/null
BOOT=$(python3 "$RUNTIME" stage bootstrap --workflow-id wf-v6-flow --worktree-path "$REPO" --prompt "implement v6 flow")
RUN=$(printf '%s' "$BOOT" | jq -r '.stage_run.id')

ALLOW_PAYLOAD=$(jq -n '{tool_name:"Agent", session_id:"parent", tool_use_id:"toolu-planner", tool_input:{subagent_type:"planner", prompt:"Plan the v6 flow naturally."}}')
ALLOW=$(printf '%s' "$ALLOW_PAYLOAD" | env -u CLAUDE_POLICY_DB CLAUDE_PROJECT_DIR="$REPO" "$PRE_AGENT")
[[ -z "$ALLOW" || $(printf '%s' "$ALLOW" | jq -r '.hookSpecificOutput.permissionDecision // "allow"') != deny ]]

ISOLATION_PAYLOAD=$(jq -n '{tool_name:"Agent", session_id:"parent", tool_use_id:"toolu-bad", tool_input:{subagent_type:"implementer", isolation:"worktree", prompt:"Apply the fix."}}')
ISOLATION_DENY=$(printf '%s' "$ISOLATION_PAYLOAD" | env -u CLAUDE_POLICY_DB CLAUDE_PROJECT_DIR="$REPO" "$PRE_AGENT")
[[ $(printf '%s' "$ISOLATION_DENY" | jq -r '.hookSpecificOutput.permissionDecision') == deny ]]
printf '%s' "$ISOLATION_DENY" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("ordinary Agent with no isolation flag")' >/dev/null

TRANSCRIPT="$TMP/session.jsonl"
mkdir -p "$TMP/subagents"
jq -nc '{toolUseId:"toolu-planner"}' > "$TMP/subagents/agent-agent-planner.meta.json"
jq -nc '{type:"user", message:{role:"user", content:"Plan the v6 flow naturally."}}' > "$TMP/subagents/agent-agent-planner.jsonl"
START_PAYLOAD=$(jq -n --arg transcript "$TRANSCRIPT" '{agent_type:"planner", session_id:"child", agent_id:"agent-planner", transcript_path:$transcript}')
START=$(printf '%s' "$START_PAYLOAD" | CLAUDE_PROJECT_DIR="$REPO" "$SUB_START")
printf '%s' "$START" | jq -e '.hookSpecificOutput.additionalContext | contains("stage_run_id")' >/dev/null
printf '%s' "$START" | jq -e '.hookSpecificOutput.additionalContext | contains("v6 Runtime Context")' >/dev/null
ACTIVE_ROLE=$(python3 "$RUNTIME" marker get-active --project-root "$REPO" | jq -r '.role // empty')
[[ "$ACTIVE_ROLE" == "planner" ]]
WRITE_PAYLOAD=$(jq -n --arg p "$REPO/MASTER_PLAN.md" '{tool_name:"Write", tool_input:{file_path:$p, content:"# MASTER_PLAN.md\n"}}')
WRITE_OUT=$(printf '%s' "$WRITE_PAYLOAD" | CLAUDE_PROJECT_DIR="$REPO" "$PRE_WRITE")
[[ -z "$WRITE_OUT" || $(printf '%s' "$WRITE_OUT" | jq -r '.hookSpecificOutput.permissionDecision // "allow"') != deny ]]

RESP=$(jq -n --arg run "$RUN" '{agent_type:"planner", last_assistant_message:("Done\n```claude_ctrl_result\n{\"stage_run_id\":\""+$run+"\",\"stage_id\":\"planner\",\"verdict\":\"next_work_item\",\"summary\":\"planned\"}\n```") }')
OUT=$(printf '%s' "$RESP" | CLAUDE_PROJECT_DIR="$REPO" "$RESULT_HOOK")
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("V6_DISPATCH_READY")' >/dev/null
NEXT=$(python3 "$RUNTIME" dispatch next --workflow-id wf-v6-flow)
[[ $(printf '%s' "$NEXT" | jq -r '.authority') == v6_stage_machine ]]
[[ $(printf '%s' "$NEXT" | jq -r '.found') == false ]]

BOOT2=$(python3 "$RUNTIME" stage bootstrap --workflow-id wf-natural-flow --worktree-path "$REPO" --prompt "natural launch")
RUN2=$(printf '%s' "$BOOT2" | jq -r '.stage_run.id')
NATURAL_PRE=$(jq -n '{tool_name:"Agent", session_id:"parent-natural", tool_use_id:"toolu-natural", tool_input:{subagent_type:"planner", prompt:"Build MASTER_PLAN.md from the research proposal."}}')
NATURAL_ALLOW=$(printf '%s' "$NATURAL_PRE" | env -u CLAUDE_POLICY_DB CLAUDE_PROJECT_DIR="$REPO" "$PRE_AGENT")
[[ -z "$NATURAL_ALLOW" || $(printf '%s' "$NATURAL_ALLOW" | jq -r '.hookSpecificOutput.permissionDecision // "allow"') != deny ]]
TRANSCRIPT2="$TMP/session-natural.jsonl"
jq -nc '{toolUseId:"toolu-natural"}' > "$TMP/subagents/agent-agent-natural.meta.json"
jq -nc '{type:"user", message:{role:"user", content:"Build MASTER_PLAN.md from the research proposal."}}' > "$TMP/subagents/agent-agent-natural.jsonl"
START2_PAYLOAD=$(jq -n --arg transcript "$TRANSCRIPT2" '{agent_type:"planner", session_id:"child-natural", agent_id:"agent-natural", transcript_path:$transcript}')
START2=$(printf '%s' "$START2_PAYLOAD" | CLAUDE_PROJECT_DIR="$REPO" "$SUB_START")
printf '%s' "$START2" | jq -e --arg run "$RUN2" '.hookSpecificOutput.additionalContext | contains($run)' >/dev/null

for role in planner implementer critic reviewer guardian; do
  WF="wf-marker-$role"
  START_PAYLOAD=$(jq -n --arg role "$role" --arg aid "agent-$role-repair" '{agent_type:$role, session_id:"repair", agent_id:$aid}')
  START_OUT=$(printf '%s' "$START_PAYLOAD" | CLAUDE_PROJECT_DIR="$REPO" "$SUB_START")
  printf '%s' "$START_OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("stage_run_id")' >/dev/null
  ACTIVE=$(python3 "$RUNTIME" marker get-active --project-root "$REPO" | jq -r '.role // empty')
  [[ "$ACTIVE" == "$role" ]]
  STOP_PAYLOAD=$(jq -n --arg role "$role" '{agent_type:$role}')
  printf '%s' "$STOP_PAYLOAD" | CLAUDE_PROJECT_DIR="$REPO" "$RESULT_HOOK" >/dev/null || true
  FOUND=$(python3 "$RUNTIME" marker get-active --project-root "$REPO" | jq -r '.found')
  [[ "$FOUND" == "false" ]]
done

echo "PASS test-v6-ticket-flow"
