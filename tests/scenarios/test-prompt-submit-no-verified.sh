#!/usr/bin/env bash
# test-prompt-submit-no-verified.sh: proves that a user prompt of "verified"
# no longer flips readiness state after TKT-024 cutover.
#
# Evaluation Contract check 16:
#   "User prompt 'verified' cannot flip readiness"
#
# Pre-condition:  evaluation_state = idle (no evaluator clearance)
# Action:         user submits prompt "verified"
# Post-condition: evaluation_state = idle (unchanged)
#                 proof CLI remains retired
#
# The old behaviour (pre-TKT-024) was: proof_state pending -> "verified"
# prompt -> proof_state = "verified". The proof store and prompt-side write
# are both removed.
#
# @decision DEC-EVAL-004
# @title prompt-submit.sh no longer writes any readiness state
# @status accepted
# @rationale Ceremony is not technical proof. evaluation_state is the
#   sole authority and is written only by the evaluator stop hook
#   (historically the tester stop hook; retired in Phase 8 Slice 10.
#   Phase 8 Slice 11 retired the ``tester`` role entirely — reviewer
#   readiness is owned by the reviewer completion/findings/convergence
#   path and does not write evaluation_state). Either way,
#   prompt-submit.sh never writes readiness state.
set -euo pipefail

TEST_NAME="test-prompt-submit-no-verified"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/prompt-submit.sh"
RUNTIME_ROOT="$REPO_ROOT/runtime"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/.claude/state.db"
BRANCH="feature/no-verified-test"
WF_ID="feature-no-verified-test"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" config user.email "t@t.com"
git -C "$TMP_DIR" config user.name "T"
git -C "$TMP_DIR" commit --allow-empty -m "init" -q
git -C "$TMP_DIR" checkout -b "$BRANCH" -q

# Provision schema — evaluation_state idle
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1

# Submit the "verified" prompt
PAYLOAD=$(jq -n --arg prompt "verified" '{prompt: $prompt}')

output=$(printf '%s' "$PAYLOAD" \
    | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TEST_DB" \
      CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" "$HOOK" 2>/dev/null) || {
    echo "FAIL: $TEST_NAME — hook exited nonzero"
    exit 1
}

# proof_state is retired; the old CLI must not be available for the prompt
# path to mutate.
if CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    proof get "$WF_ID" >/dev/null 2>&1; then
    echo "FAIL: $TEST_NAME — retired proof CLI is still available"
    exit 1
fi

# evaluation_state must still be idle (prompt-submit.sh writes nothing to it)
EVAL_ROW=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    evaluation get "$WF_ID" 2>/dev/null)
EVAL_STATUS=$(printf '%s' "$EVAL_ROW" | jq -r '.status // "idle"' 2>/dev/null || echo "idle")

if [[ "$EVAL_STATUS" != "idle" ]]; then
    echo "FAIL: $TEST_NAME — prompt-submit.sh wrote evaluation_state='$EVAL_STATUS' (must not write any readiness)"
    exit 1
fi

# Output (if any) must not mention "Proof-of-work recorded"
if printf '%s' "$output" | grep -qi "Proof-of-work recorded"; then
    echo "FAIL: $TEST_NAME — output still contains deprecated 'Proof-of-work recorded' message"
    echo "  output: $output"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
