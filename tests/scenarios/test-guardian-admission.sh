#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="test-guardian-admission"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
PROJECT="$TMP_DIR/project"
DB="$TMP_DIR/state.db"
PYTHON_BIN="${PYTHON:-python3}"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$PROJECT"

run_policy() {
    CLAUDE_POLICY_DB="$DB" \
    CLAUDE_PROJECT_DIR="$PROJECT" \
    PYTHONPATH="$REPO_ROOT" \
    "$PYTHON_BIN" "$REPO_ROOT/runtime/cli.py" "$@"
}

run_policy schema ensure >/dev/null

SCRATCH_PAYLOAD=$(jq -nc --arg root "$PROJECT" '{
  trigger:"source_write",
  project_root:$root,
  cwd:$root,
  target_path:($root + "/tmp/dedup.py"),
  session_id:"session-admission",
  workflow_id:"wf-admission"
}')

APPLY_OUT=$(run_policy admission apply --payload "$SCRATCH_PAYLOAD")
APPLIED=$(printf '%s' "$APPLY_OUT" | jq -r '.applied')
GRANTED_BY=$(printf '%s' "$APPLY_OUT" | jq -r '.permit.granted_by')
if [[ "$APPLIED" != "true" || "$GRANTED_BY" != "guardian_admission" ]]; then
    echo "FAIL: scratchlane admission apply did not grant guardian_admission permit"
    echo "$APPLY_OUT"
    exit 1
fi

UNCLEAR_PAYLOAD=$(jq -nc --arg root "$PROJECT" '{
  trigger:"source_write",
  project_root:$root,
  cwd:$root,
  target_path:($root + "/src/app.py"),
  user_prompt:"quick scratch helper in src/app.py"
}')
UNCLEAR_OUT=$(run_policy admission apply --payload "$UNCLEAR_PAYLOAD")
UNCLEAR_VERDICT=$(printf '%s' "$UNCLEAR_OUT" | jq -r '.verdict')
UNCLEAR_APPLIED=$(printf '%s' "$UNCLEAR_OUT" | jq -r '.applied')
if [[ "$UNCLEAR_VERDICT" != "user_decision_required" || "$UNCLEAR_APPLIED" != "false" ]]; then
    echo "FAIL: unclear admission should require user decision without granting"
    echo "$UNCLEAR_OUT"
    exit 1
fi

HOOK_PAYLOAD=$(jq -nc --arg root "$PROJECT" '{
  agent_type:"guardian",
  last_assistant_message:(
    "Admission complete.\n" +
    "ADMISSION_VERDICT: scratchlane_authorized\n" +
    "ADMISSION_NEXT_AUTHORITY: scratchlane\n" +
    "ADMISSION_TARGET_ROOT: " + $root + "\n" +
    "ADMISSION_TARGET_PATH: " + $root + "/tmp/dedup.py\n" +
    "ADMISSION_SCRATCHLANE: tmp/dedup/\n" +
    "ADMISSION_REASON: obvious scratchlane candidate"
  )
}')
HOOK_OUT=$(printf '%s' "$HOOK_PAYLOAD" | \
    CLAUDE_POLICY_DB="$DB" CLAUDE_PROJECT_DIR="$PROJECT" PYTHONPATH="$REPO_ROOT" \
    "$REPO_ROOT/hooks/check-guardian.sh")
if ! printf '%s' "$HOOK_OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("scratchlane_authorized")' >/dev/null; then
    echo "FAIL: check-guardian did not surface admission context"
    echo "$HOOK_OUT"
    exit 1
fi

EVENTS=$(run_policy event query --type guardian_admission.stop)
if ! printf '%s' "$EVENTS" | jq -e '.count >= 1 or (.items | length) >= 1' >/dev/null; then
    echo "FAIL: Guardian admission stop handler did not emit guardian_admission.stop event"
    echo "$EVENTS"
    exit 1
fi

PRE_AGENT_PAYLOAD=$(jq -nc --arg root "$PROJECT" '{
  hook_event_name:"PreToolUse",
  session_id:"session-admission",
  cwd:$root,
  tool_name:"Agent",
  tool_input:{
    subagent_type:"guardian",
    description:"Guardian Admission custody fork",
    prompt:"GUARDIAN_MODE: admission\nClassify project onboarding vs scratchlane custody."
  }
}')
PRE_AGENT_OUT=$(printf '%s' "$PRE_AGENT_PAYLOAD" | \
    CLAUDE_POLICY_DB="$DB" CLAUDE_PROJECT_DIR="$PROJECT" PYTHONPATH="$REPO_ROOT" \
    "$REPO_ROOT/hooks/pre-agent.sh")
if ! printf '%s' "$PRE_AGENT_OUT" | jq -e '.hookSpecificOutput.permissionDecision == "allow"' >/dev/null; then
    echo "FAIL: Guardian admission Agent launch should be allowed with mode carrier"
    echo "$PRE_AGENT_OUT"
    exit 1
fi

START_PAYLOAD='{"agent_type":"guardian","agent_id":"admission-agent-1","session_id":"session-admission"}'
START_OUT=$(printf '%s' "$START_PAYLOAD" | \
    CLAUDE_POLICY_DB="$DB" CLAUDE_PROJECT_DIR="$PROJECT" PYTHONPATH="$REPO_ROOT" \
    "$REPO_ROOT/hooks/subagent-start.sh")
if ! printf '%s' "$START_OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("Guardian mode=admission")' >/dev/null; then
    echo "FAIL: guardian admission SubagentStart should consume the admission mode carrier"
    echo "$START_OUT"
    exit 1
fi

POST_OUT=$(printf '%s' "$HOOK_PAYLOAD" | \
    CLAUDE_POLICY_DB="$DB" CLAUDE_PROJECT_DIR="$PROJECT" PYTHONPATH="$REPO_ROOT" \
    "$REPO_ROOT/hooks/post-task.sh")
if [[ -n "$POST_OUT" ]]; then
    echo "FAIL: post-task should skip Guardian admission stops"
    echo "$POST_OUT"
    exit 1
fi

MARKER=$(run_policy marker get-active --project-root "$PROJECT")
if [[ "$(printf '%s' "$MARKER" | jq -r '.found')" != "false" ]]; then
    echo "FAIL: Guardian admission should not create canonical dispatch markers"
    echo "$MARKER"
    exit 1
fi

COMPLETION_COUNT=$(sqlite3 "$DB" 'SELECT COUNT(*) FROM completion_records;')
if [[ "$COMPLETION_COUNT" != "0" ]]; then
    echo "FAIL: Guardian admission should not create completion records"
    sqlite3 "$DB" 'SELECT * FROM completion_records;'
    exit 1
fi

echo "PASS: $TEST_NAME"
