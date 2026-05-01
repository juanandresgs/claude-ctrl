#!/usr/bin/env bash
# Live installed-harness smoke for Claude Code operator sessions.
#
# This script intentionally uses the installed `cc-policy` on PATH and the
# repo-local hook adapters. It should not mutate tracked files; temporary
# subprocess CWDs live under mktemp and hook baselines land under ignored tmp/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PRE_BASH="$REPO_ROOT/hooks/pre-bash.sh"
PRE_WRITE="$REPO_ROOT/hooks/pre-write.sh"

WORKFLOW_ID="${WORKFLOW_ID:-}"
WORKTREE_PATH="${WORKTREE_PATH:-}"
STAGE_ID="${STAGE_ID:-reviewer}"

TMP_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/claudex-installed-smoke.XXXXXX")"
cleanup() {
    rm -rf "$TMP_PARENT"
}
trap cleanup EXIT

pass() {
    printf 'PASS: %s\n' "$1"
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

json_field() {
    local json="$1" expr="$2"
    printf '%s' "$json" | jq -r "$expr"
}

command -v cc-policy >/dev/null 2>&1 || fail "installed cc-policy not found on PATH"
command -v jq >/dev/null 2>&1 || fail "jq not found on PATH"

if [[ -z "$WORKFLOW_ID" || -z "$WORKTREE_PATH" ]]; then
    bindings="$(cc-policy workflow list)"
    [[ "$(json_field "$bindings" '.count // 0')" -gt 0 ]] \
        || fail "no live workflow bindings found; set WORKFLOW_ID and WORKTREE_PATH"
    if [[ -z "$WORKFLOW_ID" ]]; then
        WORKFLOW_ID="$(json_field "$bindings" '.items[0].workflow_id // empty')"
    fi
    if [[ -z "$WORKTREE_PATH" ]]; then
        WORKTREE_PATH="$(
            printf '%s' "$bindings" \
                | jq -r --arg workflow_id "$WORKFLOW_ID" \
                    '.items[] | select(.workflow_id == $workflow_id) | .worktree_path' \
                | head -n 1
        )"
    fi
fi
[[ -n "$WORKFLOW_ID" && -n "$WORKTREE_PATH" ]] \
    || fail "could not resolve workflow/worktree; set WORKFLOW_ID and WORKTREE_PATH"

cc-policy marker get-active --project-root "$REPO_ROOT" >/dev/null
pass "installed cc-policy opens live DB"

cc-policy hook validate-settings >/dev/null
pass "hook settings match manifest"

cc-policy hook doc-check >/dev/null
pass "hook docs match projection"

cc-policy constitution validate >/dev/null
pass "constitution registry validates"

stage_packet="$(
    cc-policy workflow stage-packet "$WORKFLOW_ID" \
        --stage-id "$STAGE_ID" \
        --worktree-path "$WORKTREE_PATH"
)"
[[ "$(json_field "$stage_packet" '.status // empty')" == "ok" ]] \
    || fail "workflow stage-packet did not return status ok: $stage_packet"
pass "bound $STAGE_ID stage-packet returns status ok"

run_hook_replay() {
    local label="$1" hook="$2" payload="$3"
    local side_db="$TMP_PARENT/.claude/state.db"
    local output decision

    output="$(
        cd "$TMP_PARENT"
        env -u CLAUDE_POLICY_DB -u CLAUDE_PROJECT_DIR \
            CLAUDE_RUNTIME_ROOT="$HOME/.claude/runtime" \
            bash "$hook" <<<"$payload"
    )"
    decision="$(json_field "$output" '.hookSpecificOutput.permissionDecision // empty')"
    [[ "$decision" != "deny" ]] || fail "$label denied unexpectedly: $output"
    [[ ! -e "$side_db" ]] || fail "$label created side DB at $side_db"
    pass "$label replay stayed on project DB authority"
}

pre_bash_payload="$(
    jq -n \
        --arg cwd "$REPO_ROOT" \
        '{tool_name:"Bash", cwd:$cwd, tool_input:{command:"git status --short"}}'
)"
run_hook_replay "pre-bash" "$PRE_BASH" "$pre_bash_payload"

pre_write_payload="$(
    jq -n \
        --arg cwd "$REPO_ROOT" \
        '{tool_name:"Write", cwd:$cwd, tool_input:{file_path:"tmp/installed-harness-smoke.json", content:"{\"ok\":true}\n"}}'
)"
run_hook_replay "pre-write" "$PRE_WRITE" "$pre_write_payload"
