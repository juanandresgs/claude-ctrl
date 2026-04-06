#!/usr/bin/env bash
# test-obs-emission.sh — Scenario test for W-OBS-2 hook metric emission.
#
# Production sequence exercised:
#   1. rt_obs_metric emits a single metric row to obs_metrics (direct wrapper test)
#   2. _obs_accum + rt_obs_metric_batch flush a batch atomically (batch pattern)
#   3. rt_obs_metric ... & disown fires asynchronously and row appears after sleep
#   4. check-implementer.sh emits agent_duration_s on stop (end-to-end compound test)
#
# All four scenarios use a fresh isolated state.db to prevent cross-test pollution.
#
# @decision DEC-OBS-EMIT-001
# @title test-obs-emission.sh proves hook emission wrappers write to obs_metrics
# @status accepted
# @rationale W-OBS-2 adds rt_obs_metric/batch calls to 11 hooks. Unit tests of the
#   Python observatory layer exist in runtime/tests/. This scenario test proves the
#   shell-layer wrappers (rt_obs_metric, _obs_accum, rt_obs_metric_batch) correctly
#   reach the SQLite table when called from the bash environment hooks run in, and
#   that the end-to-end production sequence (hook stop → emission → DB row) works.
set -euo pipefail

TEST_NAME="test-obs-emission"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNTIME_ROOT="$REPO_ROOT/runtime"
HOOKS_DIR="$REPO_ROOT/hooks"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/.claude/state.db"

PASS=0
FAIL=0

# shellcheck disable=SC2329  # invoked via trap
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude"

# ---------------------------------------------------------------------------
# Helper: provision a fresh schema each sub-test needs a clean DB.
# ---------------------------------------------------------------------------
provision_db() {
    rm -f "$TEST_DB"
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Helper: query obs_metrics count for a given metric name.
# ---------------------------------------------------------------------------
obs_count() {
    local name="$1"
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        obs query "$name" --limit 1000 2>/dev/null \
        | jq 'length' 2>/dev/null || echo "0"
}

# ===========================================================================
# Scenario 1: rt_obs_metric emits a single row
# ===========================================================================
provision_db

CLAUDE_POLICY_DB="$TEST_DB" \
CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" \
CLAUDE_PROJECT_DIR="$TMP_DIR" \
    bash -c "
        source '$HOOKS_DIR/log.sh'
        source '$HOOKS_DIR/context-lib.sh'
        rt_obs_metric test_single_emit 42.0 '{\"tag\":\"s1\"}' '' 'tester'
    " 2>/dev/null

count=$(obs_count "test_single_emit")
if [[ "$count" -ge 1 ]]; then
    echo "PASS: $TEST_NAME — scenario 1: rt_obs_metric single emit (count=$count)"
    (( PASS++ )) || true
else
    echo "FAIL: $TEST_NAME — scenario 1: expected >=1 row for test_single_emit, got $count"
    (( FAIL++ )) || true
fi

# ===========================================================================
# Scenario 2: _obs_accum + rt_obs_metric_batch flush atomically
# ===========================================================================
provision_db

CLAUDE_POLICY_DB="$TEST_DB" \
CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" \
CLAUDE_PROJECT_DIR="$TMP_DIR" \
    bash -c "
        source '$HOOKS_DIR/log.sh'
        source '$HOOKS_DIR/context-lib.sh'
        _obs_accum test_batch_emit 1 '{\"seq\":\"a\"}' 'implementer'
        _obs_accum test_batch_emit 2 '{\"seq\":\"b\"}' 'implementer'
        _obs_accum test_batch_emit 3 '{\"seq\":\"c\"}' 'implementer'
        rt_obs_metric_batch
    " 2>/dev/null

count=$(obs_count "test_batch_emit")
if [[ "$count" -eq 3 ]]; then
    echo "PASS: $TEST_NAME — scenario 2: batch flush 3 rows (count=$count)"
    (( PASS++ )) || true
else
    echo "FAIL: $TEST_NAME — scenario 2: expected 3 rows for test_batch_emit, got $count"
    (( FAIL++ )) || true
fi

# ===========================================================================
# Scenario 3: async fire-and-forget (& disown) — row appears after background completes
# ===========================================================================
provision_db

# Fire async in a subshell, then wait briefly for the background process to finish.
CLAUDE_POLICY_DB="$TEST_DB" \
CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" \
CLAUDE_PROJECT_DIR="$TMP_DIR" \
    bash -c "
        source '$HOOKS_DIR/log.sh'
        source '$HOOKS_DIR/context-lib.sh'
        rt_obs_metric test_async_emit 7.0 '' '' '' &
        # Wait for the background process to finish (disown is not used here since
        # we need to confirm it completes; production track.sh uses disown for
        # true fire-and-forget, but the row must still appear).
        wait
    " 2>/dev/null

count=$(obs_count "test_async_emit")
if [[ "$count" -ge 1 ]]; then
    echo "PASS: $TEST_NAME — scenario 3: async emit row visible (count=$count)"
    (( PASS++ )) || true
else
    echo "FAIL: $TEST_NAME — scenario 3: expected >=1 row for test_async_emit, got $count"
    (( FAIL++ )) || true
fi

# ===========================================================================
# Scenario 4: end-to-end compound — check-implementer.sh emits agent_duration_s
#
# Production sequence: implementer agent stops → check-implementer.sh runs →
# parses IMPL_STATUS → emits agent_duration_s to obs_metrics.
# ===========================================================================
provision_db

# Set up a minimal git repo so check-implementer.sh can run its branch check.
GIT_DIR="$TMP_DIR/repo"
mkdir -p "$GIT_DIR/.claude"
git -C "$GIT_DIR" init -q
git -C "$GIT_DIR" config user.email "t@t.com"
git -C "$GIT_DIR" config user.name "T"
git -C "$GIT_DIR" commit --allow-empty -m "init" -q
git -C "$GIT_DIR" checkout -b feature/obs-test -q

HOOK="$HOOKS_DIR/check-implementer.sh"

RESPONSE_BODY="Implementation complete. Tests pass.

IMPL_STATUS: complete
IMPL_HEAD_SHA: abc123def456"

PAYLOAD=$(jq -n \
    --arg agent_type "implementer" \
    --arg response "$RESPONSE_BODY" \
    '{agent_type: $agent_type, response: $response}')

printf '%s' "$PAYLOAD" \
    | CLAUDE_PROJECT_DIR="$GIT_DIR" \
      CLAUDE_POLICY_DB="$TEST_DB" \
      CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" \
      "$HOOK" >/dev/null 2>/dev/null || true
# check-implementer.sh exits 0 always (advisory); ignore non-zero from any
# internal advisory check that happens to emit to stderr.

# Allow a brief moment for any async writes to settle.
sleep 1

count=$(obs_count "agent_duration_s")
if [[ "$count" -ge 1 ]]; then
    echo "PASS: $TEST_NAME — scenario 4: check-implementer.sh emitted agent_duration_s (count=$count)"
    (( PASS++ )) || true
else
    echo "FAIL: $TEST_NAME — scenario 4: no agent_duration_s row after check-implementer.sh ran (count=$count)"
    (( FAIL++ )) || true
fi

# ===========================================================================
# Summary
# ===========================================================================
echo "---"
echo "$TEST_NAME: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
