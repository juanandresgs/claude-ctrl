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
ARTIFACT_DIR="$TMP_DIR/review-artifacts"
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
      CLAUDEX_REVIEW_ARTIFACT_DIR="$ARTIFACT_DIR" \
      CLAUDEX_IMPLEMENTER_CRITIC_TEST_RESPONSE="$TEST_RESPONSE" \
      "$HOOK" 2>/dev/null || true)

if ! printf '%s' "$OUTPUT" | jq '.' >/dev/null 2>&1; then
    fail "hook output is valid JSON"
else
    CONTEXT=$(printf '%s' "$OUTPUT" | jq -r '.additionalContext // empty')
    if [[ "$CONTEXT" == *"Implementer critic progress: Starting tactical review critic (read-only)."* ]]; then
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
    if [[ "$CONTEXT" == *"Implementer critic next steps:"* && "$CONTEXT" == *"Add the missing regression test."* ]]; then
        pass "hook output shows actionable next steps"
    else
        fail "hook output shows actionable next steps (got: $CONTEXT)"
    fi
    if [[ "$CONTEXT" == *"Implementer critic artifact:"* ]]; then
        pass "hook output shows artifact path"
    else
        fail "hook output shows artifact path (got: $CONTEXT)"
    fi
fi

LATEST=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME" \
    critic-review latest --workflow-id "wf-critic-hook" 2>/dev/null)
VERDICT=$(printf '%s' "$LATEST" | jq -r '.verdict // empty')
ARTIFACT_PATH=$(printf '%s' "$LATEST" | jq -r '.metadata.artifact_path // empty')
if [[ "$VERDICT" == "TRY_AGAIN" ]]; then
    pass "critic review persisted with TRY_AGAIN verdict"
else
    fail "critic review persisted with TRY_AGAIN verdict (got: $VERDICT)"
fi
if [[ -n "$ARTIFACT_PATH" && -f "$ARTIFACT_PATH" ]]; then
    pass "critic review artifact is written"
else
    fail "critic review artifact is written (path=$ARTIFACT_PATH)"
fi

DISPATCH=$(printf '{"agent_type":"implementer","project_root":"%s"}' "$WORKTREE" \
    | CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME" dispatch process-stop 2>/dev/null || echo '{}')
NEXT_ROLE=$(printf '%s' "$DISPATCH" | jq -r '.next_role // empty')
CRITIC_VERDICT=$(printf '%s' "$DISPATCH" | jq -r '.critic_verdict // empty')
AUTO=$(printf '%s' "$DISPATCH" | jq -r '.auto_dispatch // false')
SUGGESTION=$(printf '%s' "$DISPATCH" | jq -r '.suggestion // .hookSpecificOutput.additionalContext // empty')
if [[ "$NEXT_ROLE" == "implementer" && "$CRITIC_VERDICT" == "TRY_AGAIN" && "$AUTO" == "true" ]]; then
    pass "dispatch consumes persisted TRY_AGAIN critic verdict"
else
    fail "dispatch consumes persisted TRY_AGAIN critic verdict (next_role=$NEXT_ROLE critic_verdict=$CRITIC_VERDICT auto_dispatch=$AUTO)"
fi
if [[ "$SUGGESTION" == *"CRITIC_NEXT_STEPS"* && "$SUGGESTION" == *"Add the missing regression test."* && "$SUGGESTION" == *"CRITIC_ACTION: Re-dispatch implementer"* ]]; then
    pass "dispatch suggestion carries critic feedback to implementer"
else
    fail "dispatch suggestion carries critic feedback to implementer (got: $SUGGESTION)"
fi

CLAUDE_POLICY_DB="$TEST_DB" CLAUDE_AGENT_ROLE="planner" python3 "$RUNTIME" \
    config set critic_enabled_implementer_stop false \
    --scope "project=$WORKTREE" >/dev/null 2>&1

LEASE_JSON_2=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME" \
    lease issue-for-dispatch implementer \
    --workflow-id "wf-critic-disabled" \
    --worktree-path "$WORKTREE" 2>/dev/null)
LEASE_ID_2=$(printf '%s' "$LEASE_JSON_2" | jq -r '.lease.lease_id // empty')

CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME" \
    completion submit \
    --lease-id "$LEASE_ID_2" \
    --workflow-id "wf-critic-disabled" \
    --role implementer \
    --payload '{"IMPL_STATUS":"complete","IMPL_HEAD_SHA":"abc123"}' >/dev/null 2>&1

DISABLED_OUTPUT=$(printf '%s' "$PAYLOAD" \
    | CLAUDE_PROJECT_DIR="$WORKTREE" \
      CLAUDE_POLICY_DB="$TEST_DB" \
      CLAUDEX_REVIEW_ARTIFACT_DIR="$ARTIFACT_DIR" \
      CLAUDEX_IMPLEMENTER_CRITIC_TEST_RESPONSE="$TEST_RESPONSE" \
      "$HOOK" 2>/dev/null || true)

DISABLED_CONTEXT=$(printf '%s' "$DISABLED_OUTPUT" | jq -r '.additionalContext // empty' 2>/dev/null || true)
if [[ "$DISABLED_CONTEXT" == *"Implementer critic disabled for this scope."* ]]; then
    pass "hook reports disabled critic path"
else
    fail "hook reports disabled critic path (got: $DISABLED_CONTEXT)"
fi

LATEST_DISABLED=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME" \
    critic-review latest --workflow-id "wf-critic-disabled" 2>/dev/null)
DISABLED_FOUND=$(printf '%s' "$LATEST_DISABLED" | jq -r '.found // false')
if [[ "$DISABLED_FOUND" == "false" ]]; then
    pass "disabled critic path does not persist a critic review"
else
    fail "disabled critic path does not persist a critic review (got: $LATEST_DISABLED)"
fi

DISPATCH_DISABLED=$(printf '{"agent_type":"implementer","project_root":"%s"}' "$WORKTREE" \
    | CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME" dispatch process-stop 2>/dev/null || echo '{}')
DISABLED_NEXT_ROLE=$(printf '%s' "$DISPATCH_DISABLED" | jq -r '.next_role // empty')
DISABLED_CRITIC=$(printf '%s' "$DISPATCH_DISABLED" | jq -r '.critic_found // false')
if [[ "$DISABLED_NEXT_ROLE" == "reviewer" && "$DISABLED_CRITIC" == "false" ]]; then
    pass "disabled critic path falls back to reviewer"
else
    fail "disabled critic path falls back to reviewer (next_role=$DISABLED_NEXT_ROLE critic_found=$DISABLED_CRITIC)"
fi

CLAUDE_POLICY_DB="$TEST_DB" CLAUDE_AGENT_ROLE="planner" python3 "$RUNTIME" \
    config set critic_enabled_implementer_stop true \
    --scope "project=$WORKTREE" >/dev/null 2>&1

FAKE_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_HOME/.gemini" "$FAKE_BIN"
printf '{}\n' > "$FAKE_HOME/.gemini/oauth_creds.json"
cat > "$FAKE_BIN/gemini" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "gemini-test"
  exit 0
fi
printf '%s\n' '{"response":"{\"verdict\":\"READY_FOR_REVIEWER\",\"summary\":\"Gemini cleared the tactical handoff.\",\"detail\":\"The fake Gemini provider returned a structured critic verdict.\",\"next_steps\":[]}","session_id":"gemini-test-session"}'
SH
chmod +x "$FAKE_BIN/gemini"

LEASE_JSON_3=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME" \
    lease issue-for-dispatch implementer \
    --workflow-id "wf-critic-gemini" \
    --worktree-path "$WORKTREE" 2>/dev/null)
LEASE_ID_3=$(printf '%s' "$LEASE_JSON_3" | jq -r '.lease.lease_id // empty')

CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME" \
    completion submit \
    --lease-id "$LEASE_ID_3" \
    --workflow-id "wf-critic-gemini" \
    --role implementer \
    --payload '{"IMPL_STATUS":"complete","IMPL_HEAD_SHA":"abc123"}' >/dev/null 2>&1

GEMINI_OUTPUT=$(printf '%s' "$PAYLOAD" \
    | HOME="$FAKE_HOME" \
      PATH="$FAKE_BIN:$PATH" \
      CLAUDE_PROJECT_DIR="$WORKTREE" \
      CLAUDE_POLICY_DB="$TEST_DB" \
      CLAUDEX_REVIEW_ARTIFACT_DIR="$ARTIFACT_DIR" \
      CLAUDEX_REVIEW_PROVIDER="gemini" \
      "$HOOK" 2>/dev/null || true)
GEMINI_CONTEXT=$(printf '%s' "$GEMINI_OUTPUT" | jq -r '.additionalContext // empty' 2>/dev/null || true)
if [[ "$GEMINI_CONTEXT" == *"provider=gemini"* && "$GEMINI_CONTEXT" == *"verdict=READY_FOR_REVIEWER"* ]]; then
    pass "Gemini provider can replace Codex for implementer critic"
else
    fail "Gemini provider can replace Codex for implementer critic (got: $GEMINI_CONTEXT)"
fi

LEASE_JSON_4=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME" \
    lease issue-for-dispatch implementer \
    --workflow-id "wf-critic-fallback" \
    --worktree-path "$WORKTREE" 2>/dev/null)
LEASE_ID_4=$(printf '%s' "$LEASE_JSON_4" | jq -r '.lease.lease_id // empty')

CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME" \
    completion submit \
    --lease-id "$LEASE_ID_4" \
    --workflow-id "wf-critic-fallback" \
    --role implementer \
    --payload '{"IMPL_STATUS":"complete","IMPL_HEAD_SHA":"abc123"}' >/dev/null 2>&1

FALLBACK_OUTPUT=$(printf '%s' "$PAYLOAD" \
    | CLAUDE_PROJECT_DIR="$WORKTREE" \
      CLAUDE_POLICY_DB="$TEST_DB" \
      CLAUDEX_REVIEW_ARTIFACT_DIR="$ARTIFACT_DIR" \
      CLAUDEX_REVIEW_PROVIDER="reviewer-subagent" \
      "$HOOK" 2>/dev/null || true)
FALLBACK_CONTEXT=$(printf '%s' "$FALLBACK_OUTPUT" | jq -r '.additionalContext // empty' 2>/dev/null || true)
if [[ "$FALLBACK_CONTEXT" == *"provider=reviewer-subagent"* && "$FALLBACK_CONTEXT" == *"verdict=CRITIC_UNAVAILABLE"* && "$FALLBACK_CONTEXT" == *"dispatch reviewer subagent fallback"* ]]; then
    pass "reviewer subagent fallback is explicit when external critic is unavailable"
else
    fail "reviewer subagent fallback is explicit (got: $FALLBACK_CONTEXT)"
fi

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
    echo "PASS: $TEST_NAME"
    exit 0
fi

echo "FAIL: $TEST_NAME — $FAILURES check(s) failed"
exit 1
