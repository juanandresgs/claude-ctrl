#!/usr/bin/env bash
# test-proof-committed-safe.sh
# Regression suite for DEC-PROOF-COMMITTED-SAFE-001.
#
# Self-contained: builds isolated temp git repos, seeds proof state via the
# LIBRARY at the SAME project root the hook resolves (so seed path == read path),
# then asserts REAL hook behavior. No dependency on _PREBASH_DB / seed_proof_state.
#
# Invariants:
#   T1 (deadlock fix, REVERT-PROOF): pre-bash ALLOWS a git commit when proof=committed.
#       If the '!= committed' clause in task-track.sh / pre-bash.sh is reverted,
#       pre-bash emits a deny and T1 FAILS. So this test guards the fix, not just "green".
#   T2 (aa04bf4 guard / Component G): a 'verified' transition with NO human-minted
#       token is DENIED. Guards against any future change that weakens the token path.
#
# Exit 0 iff both pass.

set -uo pipefail
CLAUDE_HOME="${HOME}/.claude"
PASS=0; FAIL=0
pass(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1"; echo "    -> $2"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------
echo "=== T1: pre-bash ALLOWS git commit when proof_state=committed (revert-proof) ==="
REPO1="$(mktemp -d -t pgc-t1-XXXXXX)"
(
  cd "$REPO1"
  git init -q && git config user.email t@t && git config user.name t
  echo x > f.txt && git add f.txt
  source "$CLAUDE_HOME/hooks/source-lib.sh" >/dev/null 2>&1
  require_state >/dev/null 2>&1
  export CLAUDE_PROJECT_DIR="$REPO1"; export PROJECT_ROOT="$REPO1"
  proof_state_set "pending"   >/dev/null 2>&1 || true
  proof_state_set "committed" >/dev/null 2>&1 || { echo "SEED_FAIL"; exit 90; }
  RB="$(PROJECT_ROOT="$REPO1" proof_state_get 2>/dev/null | cut -d'|' -f1)"
  [ "$RB" = "committed" ] || { echo "READBACK=$RB"; exit 91; }
  OUT="$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git commit -m test"}}' \
        | bash "$CLAUDE_HOME/hooks/pre-bash.sh" 2>&1)"
  if echo "$OUT" | grep -q '"permissionDecision":"deny"'; then echo "DENY=$OUT"; exit 1; fi
  exit 0
)
rc=$?
case $rc in
  0)  pass "T1.1: committed allowed at pre-bash commit gate (would FAIL if clause reverted)";;
  90) fail "T1.1: could not seed 'committed'" "proof_state_set committed returned non-zero";;
  91) fail "T1.1: readback mismatch" "state did not read back as 'committed' at the resolved path";;
  1)  fail "T1.1: pre-bash DENIED a committed commit" "the '!= committed' clause is NOT effective";;
  *)  fail "T1.1: unexpected error" "rc=$rc";;
esac
rm -rf "$REPO1"

# ---------------------------------------------------------------------------
echo "=== T2 (Component G): tokenless 'verified' transition is DENIED (aa04bf4 guard) ==="
REPO2="$(mktemp -d -t pgc-t2-XXXXXX)"
(
  cd "$REPO2"; git init -q
  source "$CLAUDE_HOME/hooks/source-lib.sh" >/dev/null 2>&1
  require_state >/dev/null 2>&1
  export CLAUDE_PROJECT_DIR="$REPO2"; export PROJECT_ROOT="$REPO2"
  if proof_state_set "verified" 2>/dev/null; then exit 1; else exit 0; fi
)
rc=$?
if [ $rc -eq 0 ]; then
  pass "T2.1: tokenless 'verified' correctly DENIED (human-token guard intact)"
else
  fail "T2.1: tokenless 'verified' was PROMOTED" "aa04bf4 hardening BROKEN — DO NOT COMMIT"
fi
rm -rf "$REPO2"

# ---------------------------------------------------------------------------
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "================================"
[ $FAIL -eq 0 ]
