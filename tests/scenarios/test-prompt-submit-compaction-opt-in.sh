#!/usr/bin/env bash
# test-prompt-submit-compaction-opt-in.sh
#
# Pins the opt-in contract for the prompt-submit.sh compaction suggestion
# (DEC-COMPACT-001 as updated in Bundle B):
#
#   - Default behaviour (no CLAUDEX_ENABLE_COMPACTION_HINTS set) must NOT
#     emit the "Consider running /compact" line, even when the prior
#     DB prompt-count threshold (35 or 60 prompts) would otherwise have
#     fired.
#   - Opt-in behaviour (CLAUDEX_ENABLE_COMPACTION_HINTS=1) must emit the
#     compaction suggestion when the threshold is reached.
#
# Deterministic driver: the hook derives SESSION_ID from CLAUDE_SESSION_ID
# (falling back to $$), so the test can pre-seed the state.db session_activity
# row to one below the threshold and assert the hook's post-increment behavior.
set -euo pipefail

TEST_NAME="test-prompt-submit-compaction-opt-in"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/prompt-submit.sh"
TMP_DIR="$REPO_ROOT/tmp/${TEST_NAME}-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" commit --allow-empty -m "init" -q

# Use a fixed session id so the state.db row is predictable.
SESSION_ID="compaction-opt-in-test"
CLAUDE_DIR="$TMP_DIR/.claude"
mkdir -p "$CLAUDE_DIR"
TEST_DB="$CLAUDE_DIR/state.db"
CLAUDE_POLICY_DB="$TEST_DB" python3 "$REPO_ROOT/runtime/cli.py" schema ensure >/dev/null

PAYLOAD='{"prompt":"What is the current plan status?"}'
COMPACT_MARKER="Consider running /compact"

fail() {
  echo "FAIL: $TEST_NAME — $1"
  exit 1
}

run_hook() {
  local enable_flag="${1:-}"
  local env_prefix=()
  env_prefix+=("CLAUDE_PROJECT_DIR=$TMP_DIR" "CLAUDE_SESSION_ID=$SESSION_ID" "CLAUDE_POLICY_DB=$TEST_DB")
  if [[ -n "$enable_flag" ]]; then
    env_prefix+=("CLAUDEX_ENABLE_COMPACTION_HINTS=$enable_flag")
  fi
  printf '%s' "$PAYLOAD" | env "${env_prefix[@]}" "$HOOK" 2>/dev/null
}

seed_prompt_count() {
  local count="$1"
  local now
  now=$(date +%s)
  sqlite3 "$TEST_DB" \
    "INSERT INTO session_activity(session_id, project_root, prompt_count, started_at, updated_at) VALUES('$SESSION_ID', '$TMP_DIR', $count, $now, $now) ON CONFLICT(session_id, project_root) DO UPDATE SET prompt_count=$count, started_at=$now, updated_at=$now, ended_at=NULL;"
}

current_prompt_count() {
  sqlite3 "$TEST_DB" "SELECT prompt_count FROM session_activity WHERE session_id='$SESSION_ID' AND project_root='$TMP_DIR';"
}

# ---------------------------------------------------------------------------
# Case 1: default (no env var) — hint must NOT fire at the 35-prompt threshold
# ---------------------------------------------------------------------------
seed_prompt_count 34   # hook increments → 35 (pre-fix threshold)
output_default=$(run_hook "")
post_count_default=$(current_prompt_count)
if [[ "$post_count_default" != "35" ]]; then
  fail "increment path (no env) did not reach 35; got $post_count_default"
fi
if echo "$output_default" | grep -q "$COMPACT_MARKER"; then
  fail "compaction hint fired at 35 prompts with default (opt-in absent)"
fi

# ---------------------------------------------------------------------------
# Case 2: explicit CLAUDEX_ENABLE_COMPACTION_HINTS=0 — same: hint must NOT fire
# ---------------------------------------------------------------------------
seed_prompt_count 34   # re-seed so increment lands on 35 again
output_zero=$(run_hook "0")
post_count_zero=$(current_prompt_count)
if [[ "$post_count_zero" != "35" ]]; then
  fail "increment path (=0) did not reach 35; got $post_count_zero"
fi
if echo "$output_zero" | grep -q "$COMPACT_MARKER"; then
  fail "compaction hint fired at 35 prompts with CLAUDEX_ENABLE_COMPACTION_HINTS=0"
fi

# ---------------------------------------------------------------------------
# Case 3: opt-in (CLAUDEX_ENABLE_COMPACTION_HINTS=1) — hint MUST fire at 35
# ---------------------------------------------------------------------------
seed_prompt_count 34
output_on=$(run_hook "1")
post_count_on=$(current_prompt_count)
if [[ "$post_count_on" != "35" ]]; then
  fail "increment path (=1) did not reach 35; got $post_count_on"
fi
if ! echo "$output_on" | grep -q "$COMPACT_MARKER"; then
  fail "compaction hint did NOT fire at 35 prompts with CLAUDEX_ENABLE_COMPACTION_HINTS=1 (output: $output_on)"
fi
# Hook output must be valid JSON when non-empty.
if ! echo "$output_on" | jq '.' >/dev/null 2>&1; then
  fail "hook output with opt-in is not valid JSON"
fi
# Sanity: check that the 35-prompt reason text appears too.
if ! echo "$output_on" | grep -q "35 prompts"; then
  fail "compaction hint missing '35 prompts' reason"
fi

# ---------------------------------------------------------------------------
# Case 4: opt-in at 60-prompt secondary threshold must also fire
# ---------------------------------------------------------------------------
seed_prompt_count 59
output_on_60=$(run_hook "1")
if [[ "$(current_prompt_count)" != "60" ]]; then
  fail "increment path to 60 did not land; got $(current_prompt_count)"
fi
if ! echo "$output_on_60" | grep -q "$COMPACT_MARKER"; then
  fail "compaction hint did NOT fire at 60 prompts with opt-in enabled"
fi
if ! echo "$output_on_60" | grep -q "60 prompts"; then
  fail "compaction hint at 60 missing '60 prompts' reason"
fi

# ---------------------------------------------------------------------------
# Case 5: opt-in at a NON-threshold count (36) must NOT fire the hint
# ---------------------------------------------------------------------------
seed_prompt_count 35
output_on_36=$(run_hook "1")
if [[ "$(current_prompt_count)" != "36" ]]; then
  fail "increment path to 36 did not land; got $(current_prompt_count)"
fi
if echo "$output_on_36" | grep -q "$COMPACT_MARKER"; then
  fail "compaction hint fired at 36 (non-threshold) with opt-in enabled"
fi

# ---------------------------------------------------------------------------
# Case 6: unexpected env-var values (anything not == '1') must NOT fire
# ---------------------------------------------------------------------------
for flag in "true" "yes" "on" "2" "01"; do
  seed_prompt_count 34
  output_unexpected=$(run_hook "$flag")
  if [[ "$(current_prompt_count)" != "35" ]]; then
    fail "increment path with env=$flag did not land at 35"
  fi
  if echo "$output_unexpected" | grep -q "$COMPACT_MARKER"; then
    fail "compaction hint fired with CLAUDEX_ENABLE_COMPACTION_HINTS=$flag (only '1' must enable)"
  fi
done

# ---------------------------------------------------------------------------
# Hook exit code must remain 0 on every path.
# ---------------------------------------------------------------------------
seed_prompt_count 10
if ! printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_SESSION_ID="$SESSION_ID" CLAUDE_POLICY_DB="$TEST_DB" \
    CLAUDEX_ENABLE_COMPACTION_HINTS=1 "$HOOK" >/dev/null 2>&1; then
  fail "hook exited nonzero on opt-in path"
fi
if ! printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_SESSION_ID="$SESSION_ID" \
    "$HOOK" >/dev/null 2>&1; then
  fail "hook exited nonzero on default path"
fi

echo "PASS: $TEST_NAME"
exit 0
