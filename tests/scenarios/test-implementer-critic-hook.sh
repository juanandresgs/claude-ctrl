#!/usr/bin/env bash
# test-implementer-critic-hook.sh — scenario coverage for the dedicated
# implementer critic hook.
#
# Production path exercised:
#   SubagentStop:implementer payload
#     -> hooks/implementer-critic.sh
#     -> critic-review submit (runtime)
#     -> dispatch process-stop consumes persisted verdict
#
# The Codex invocation itself is overridden with
# CLAUDEX_IMPLEMENTER_CRITIC_TEST_RESPONSE so the test stays deterministic
# and does not depend on a live Codex login.
set -euo pipefail

TEST_NAME="test-implementer-critic-hook"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/implementer-critic.sh"
RUNTIME="$REPO_ROOT/runtime/cli.py"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/state.db"
WORKTREE="$TMP_DIR/repo"
FAILURES=0

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

mkdir -p "$WORKTREE"

git -C "$WORKTREE" init >/dev/null 2>&1
git -C "$WORKTREE" config user.name "Test User"
git -C "$WORKTREE" config user.email "test@example.com"
printf 'print("hello")\n' > "$WORKTREE/app.py"
git -C "$WORKTREE" add app.py
git -C "$WORKTREE" commit -m "seed" >/dev/null 2>&1
printf '\nprint("critic loop")\n' >> "$WORKTREE/app.py"

CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME" schema ensure >/dev/null 2>&1

LEASE_JSON=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME" \
    lease issue-for-dispatch implementer \
    --workflow-id "wf-critic-hook" \
    --worktree-path "$WORKTREE" 2>/dev/null)
LEASE_ID=$(printf '%s' "$LEASE_JSON" | jq -r '.lease.lease_id // empty')

if [[ -z "$LEASE_ID" ]]; then
    echo "FAIL: $TEST_NAME — failed to issue implementer lease"
    exit 1
fi

CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME" \
    completion submit \
    --lease-id "$LEASE_ID" \
    --workflow-id "wf-critic-hook" \
    --role implementer \
    --payload '{"IMPL_STATUS":"complete","IMPL_HEAD_SHA":"abc123"}' >/dev/null 2>&1

PAYLOAD='{"hook_event_name":"SubagentStop","agent_type":"implementer","last_assistant_message":"Implemented the feature but it still needs more tests."}'
TEST_RESPONSE='{"verdict":"TRY_AGAIN","summary":"Add coverage before reviewer handoff.","detail":"The main success path is implemented, but the regression test for the dispatch retry boundary is still missing.","next_steps":["Add the missing regression test."],"progress":["Provider ready.","Inspecting changed files."]}'

OUTPUT=$(printf '%s' "$PAYLOAD" \
    | CLAUDE_PROJECT_DIR="$WORKTREE" \
      CLAUDE_POLICY_DB="$TEST_DB" \
      CLAUDEX_IMPLEMENTER_CRITIC_TEST_RESPONSE="$TEST_RESPONSE" \
      "$HOOK" 2>/dev/null || true)

if ! printf '%s' "$OUTPUT" | jq '.' >/dev/null 2>&1; then
    fail "hook output is valid JSON"
else
    CONTEXT=$(printf '%s' "$OUTPUT" | jq -r '.additionalContext // empty')
    if [[ "$CONTEXT" == *"Implementer critic progress: Starting Codex tactical critic (read-only)."* ]]; then
        pass "hook output shows start context"
    else
        fail "hook output shows start context (got: $CONTEXT)"
    fi
    if [[ "$CONTEXT" == *"provider=codex"* && "$CONTEXT" == *"verdict=TRY_AGAIN"* ]]; then
        pass "hook output shows provider and verdict"
    else
        fail "hook output shows provider and verdict (got: $CONTEXT)"
    fi
    if [[ "$CONTEXT" == *"retry 1 of 2"* ]]; then
        pass "hook output shows retry attempt context"
    else
        fail "hook output shows retry attempt context (got: $CONTEXT)"
    fi
fi

LATEST=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME" \
    critic-review latest --workflow-id "wf-critic-hook" 2>/dev/null)
VERDICT=$(printf '%s' "$LATEST" | jq -r '.verdict // empty')
if [[ "$VERDICT" == "TRY_AGAIN" ]]; then
    pass "critic review persisted with TRY_AGAIN verdict"
else
    fail "critic review persisted with TRY_AGAIN verdict (got: $VERDICT)"
fi

DISPATCH=$(printf '{"agent_type":"implementer","project_root":"%s"}' "$WORKTREE" \
    | CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME" dispatch process-stop 2>/dev/null || echo '{}')
NEXT_ROLE=$(printf '%s' "$DISPATCH" | jq -r '.next_role // empty')
CRITIC_VERDICT=$(printf '%s' "$DISPATCH" | jq -r '.critic_verdict // empty')
AUTO=$(printf '%s' "$DISPATCH" | jq -r '.auto_dispatch // false')
if [[ "$NEXT_ROLE" == "implementer" && "$CRITIC_VERDICT" == "TRY_AGAIN" && "$AUTO" == "true" ]]; then
    pass "dispatch consumes persisted TRY_AGAIN critic verdict"
else
    fail "dispatch consumes persisted TRY_AGAIN critic verdict (next_role=$NEXT_ROLE critic_verdict=$CRITIC_VERDICT auto_dispatch=$AUTO)"
fi

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
    echo "PASS: $TEST_NAME"
    exit 0
fi

echo "FAIL: $TEST_NAME — $FAILURES check(s) failed"
exit 1
