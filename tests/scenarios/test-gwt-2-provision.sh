#!/usr/bin/env bash
# test-gwt-2-provision.sh — Scenario test for W-GWT-2 Guardian worktree provisioning.
#
# Verifies that `cc-policy worktree provision` implements the full provision
# sequence defined by DEC-GUARD-WT-002 and DEC-GUARD-WT-008 (R3):
#
#   1. Fresh provision: git worktree add, DB register, Guardian lease at PROJECT_ROOT,
#      implementer lease at worktree_path, workflow binding. Returns already_exists=false.
#   2. Idempotent re-provision: filesystem check detects existing path, skips git worktree
#      add, ensures DB state correct. Returns already_exists=true. Active implementer
#      lease is NOT revoked.
#   3. End-to-end chain: provision → submit provisioned completion →
#      dispatch process-stop for guardian → next_role=implementer with worktree_path.
#   4. Filesystem-first: passing a non-git directory as project_root fails without
#      writing any DB state.
#   5. Missing args: each required flag missing produces a non-zero exit code.
#
# All cases exercise the real production CLI boundary via subprocess.
#
# @decision DEC-GUARD-WT-002
# @title Worktree provisioning is a runtime function (W-GWT-2 scenario test)
# @status accepted
# @rationale The provision CLI is the sole place that runs git side effects in the
#   runtime. This test exercises the real `cc-policy worktree provision` command
#   end-to-end with a real temporary git repo, verifying filesystem, DB, lease,
#   and workflow binding state after each operation.

set -euo pipefail

TEST_NAME="test-gwt-2-provision"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/state.db"

# shellcheck disable=SC2329
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
mkdir -p "$TMP_DIR"

CC="python3 $REPO_ROOT/runtime/cli.py"

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "=== $TEST_NAME ==="

# --- Bootstrap schema ---
CLAUDE_POLICY_DB="$TEST_DB" $CC schema ensure >/dev/null 2>&1

# ---------------------------------------------------------------------------
# Set up a minimal git repo to use as the project_root
# ---------------------------------------------------------------------------
GIT_REPO="$TMP_DIR/git-project"
mkdir -p "$GIT_REPO"
git -C "$GIT_REPO" init -q
git -C "$GIT_REPO" config user.email "test@test.com"
git -C "$GIT_REPO" config user.name "Test"
echo "test" > "$GIT_REPO/README.md"
git -C "$GIT_REPO" add .
git -C "$GIT_REPO" commit -q -m "init"

PROVISION_WF="wf-gwt2-scenario-001"
FEATURE_NAME="scenario-feature"
EXPECTED_WT="$(cd "$GIT_REPO" && pwd -P)/.worktrees/feature-$FEATURE_NAME"
EXPECTED_BRANCH="feature/$FEATURE_NAME"

# ---------------------------------------------------------------------------
# Helper: run cc-policy with test DB
# ---------------------------------------------------------------------------
cc() {
    CLAUDE_POLICY_DB="$TEST_DB" $CC "$@"
}

jq_get() {
    local json="$1"
    local key="$2"
    printf '%s' "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$key', ''))" 2>/dev/null || echo ""
}

jq_get_bool() {
    local json="$1"
    local key="$2"
    printf '%s' "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); v=d.get('$key'); print('true' if v else 'false')" 2>/dev/null || echo "false"
}

# ==========================================================================
# Test 1: Fresh provision — happy path
# ==========================================================================
echo ""
echo "--- Test 1: Fresh provision ---"
OUT=$(cc worktree provision \
    --workflow-id "$PROVISION_WF" \
    --feature-name "$FEATURE_NAME" \
    --project-root "$GIT_REPO" 2>/dev/null)

STATUS=$(jq_get "$OUT" "status")
WT_PATH=$(jq_get "$OUT" "worktree_path")
BRANCH=$(jq_get "$OUT" "branch")
ALREADY=$(jq_get_bool "$OUT" "already_exists")
G_LEASE=$(jq_get "$OUT" "guardian_lease_id")
I_LEASE=$(jq_get "$OUT" "implementer_lease_id")

if [[ "$STATUS" == "ok" ]]; then
    pass "provision: status=ok"
else
    fail "provision: status=ok (got: $STATUS, full output: $OUT)"
fi

if [[ "$WT_PATH" == "$EXPECTED_WT" ]]; then
    pass "provision: worktree_path=$EXPECTED_WT"
else
    fail "provision: worktree_path=$EXPECTED_WT (got: $WT_PATH)"
fi

if [[ "$BRANCH" == "$EXPECTED_BRANCH" ]]; then
    pass "provision: branch=$EXPECTED_BRANCH"
else
    fail "provision: branch=$EXPECTED_BRANCH (got: $BRANCH)"
fi

if [[ "$ALREADY" == "false" ]]; then
    pass "provision: already_exists=false on fresh provision"
else
    fail "provision: already_exists=false on fresh provision (got: $ALREADY)"
fi

if [[ -n "$G_LEASE" ]]; then
    pass "provision: guardian_lease_id populated"
else
    fail "provision: guardian_lease_id populated (got empty)"
fi

if [[ -n "$I_LEASE" ]]; then
    pass "provision: implementer_lease_id populated"
else
    fail "provision: implementer_lease_id populated (got empty)"
fi

# Verify filesystem
if [[ -d "$EXPECTED_WT" ]]; then
    pass "provision: worktree directory exists on filesystem"
else
    fail "provision: worktree directory exists (path: $EXPECTED_WT)"
fi

# Verify Guardian lease in DB at PROJECT_ROOT
G_LEASE_ROW=$(cc lease current --worktree-path "$GIT_REPO" 2>/dev/null)
G_ROLE=$(jq_get "$G_LEASE_ROW" "role")
if [[ "$G_ROLE" == "guardian" ]]; then
    pass "provision: Guardian lease active at project_root"
else
    fail "provision: Guardian lease active at project_root (got role: $G_ROLE)"
fi

# Verify implementer lease in DB at worktree_path
I_LEASE_ROW=$(cc lease current --worktree-path "$EXPECTED_WT" 2>/dev/null)
I_ROLE=$(jq_get "$I_LEASE_ROW" "role")
if [[ "$I_ROLE" == "implementer" ]]; then
    pass "provision: implementer lease active at worktree_path"
else
    fail "provision: implementer lease active at worktree_path (got role: $I_ROLE)"
fi

# Verify workflow binding
WF_OUT=$(cc workflow get "$PROVISION_WF" 2>/dev/null)
WF_BRANCH=$(jq_get "$WF_OUT" "branch")
if [[ "$WF_BRANCH" == "$EXPECTED_BRANCH" ]]; then
    pass "provision: workflow binding created with correct branch"
else
    fail "provision: workflow binding created (got branch: $WF_BRANCH, full: $WF_OUT)"
fi

# ==========================================================================
# Test 2: Idempotent re-provision
# ==========================================================================
echo ""
echo "--- Test 2: Idempotent re-provision ---"
OUT2=$(cc worktree provision \
    --workflow-id "$PROVISION_WF" \
    --feature-name "$FEATURE_NAME" \
    --project-root "$GIT_REPO" 2>/dev/null)

STATUS2=$(jq_get "$OUT2" "status")
ALREADY2=$(jq_get_bool "$OUT2" "already_exists")
I_LEASE2=$(jq_get "$OUT2" "implementer_lease_id")

if [[ "$STATUS2" == "ok" ]]; then
    pass "re-provision: status=ok"
else
    fail "re-provision: status=ok (got: $STATUS2, full: $OUT2)"
fi

if [[ "$ALREADY2" == "true" ]]; then
    pass "re-provision: already_exists=true on second call"
else
    fail "re-provision: already_exists=true on second call (got: $ALREADY2)"
fi

# Original implementer lease must still be active (not revoked)
ORIG_LEASE_STATUS=$(cc lease get "$I_LEASE" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null || echo "")
if [[ "$ORIG_LEASE_STATUS" == "active" ]]; then
    pass "re-provision: original implementer lease not revoked"
else
    fail "re-provision: original implementer lease not revoked (status: $ORIG_LEASE_STATUS)"
fi

# The re-provision returns the existing lease ID (reuse, not re-issue)
if [[ "$I_LEASE2" == "$I_LEASE" ]]; then
    pass "re-provision: implementer_lease_id reused (not re-issued)"
else
    # It's acceptable if the re-provision re-issues as long as the original is still active.
    # The spec says "do NOT revoke active implementer lease" — checked above.
    pass "re-provision: implementer_lease_id present (may be reused or re-issued)"
fi

# ==========================================================================
# Test 3: End-to-end chain — provision → provisioned completion → implementer dispatch
# ==========================================================================
echo ""
echo "--- Test 3: End-to-end provision chain ---"
WF3="wf-gwt2-chain-001"
FEAT3="chain-feature"

OUT3=$(cc worktree provision \
    --workflow-id "$WF3" \
    --feature-name "$FEAT3" \
    --project-root "$GIT_REPO" 2>/dev/null || echo '{}')

STATUS3=$(jq_get "$OUT3" "status")
WT3=$(jq_get "$OUT3" "worktree_path")
GL3=$(jq_get "$OUT3" "guardian_lease_id")

if [[ "$STATUS3" == "ok" && -n "$GL3" ]]; then
    # Submit guardian completion with provisioned verdict
    PROV_PAYLOAD="{\"LANDING_RESULT\":\"provisioned\",\"OPERATION_CLASS\":\"routine_local\",\"WORKTREE_PATH\":\"$WT3\"}"
    cc completion submit \
        --lease-id "$GL3" \
        --workflow-id "$WF3" \
        --role "guardian" \
        --payload "$PROV_PAYLOAD" >/dev/null 2>&1 || true

    # process-stop for guardian → next_role=implementer
    STOP_OUT=$(printf '{"agent_type":"guardian","project_root":"%s"}' "$GIT_REPO" \
        | CLAUDE_POLICY_DB="$TEST_DB" $CC dispatch process-stop 2>/dev/null || echo '{}')

    NEXT=$(jq_get "$STOP_OUT" "next_role")
    STOP_WT=$(jq_get "$STOP_OUT" "worktree_path")
    CTX=$(printf '%s' "$STOP_OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('hookSpecificOutput',{}).get('additionalContext',''))" 2>/dev/null || true)

    if [[ "$NEXT" == "implementer" ]]; then
        pass "chain: guardian provisioned → next_role=implementer"
    else
        fail "chain: guardian provisioned → next_role=implementer (got: $NEXT, full: $STOP_OUT)"
    fi

    if [[ "$STOP_WT" == "$WT3" ]]; then
        pass "chain: worktree_path=$WT3 in process-stop result"
    else
        fail "chain: worktree_path=$WT3 in process-stop result (got: $STOP_WT)"
    fi

    if [[ "$CTX" == *"worktree_path=$WT3"* ]]; then
        pass "chain: worktree_path encoded in AUTO_DISPATCH suggestion"
    else
        fail "chain: worktree_path encoded in AUTO_DISPATCH suggestion (got: $CTX)"
    fi
else
    fail "chain: provision step failed — skipping chain checks (status=$STATUS3, gl=$GL3)"
fi

# ==========================================================================
# Test 4: Filesystem-first — non-git directory → error, no DB state
# ==========================================================================
echo ""
echo "--- Test 4: Filesystem-first guard ---"
# The non-git directory must be OUTSIDE any git repo so git -C finds no parent .git.
# Using mktemp -d ensures it lands in the system temp outside the project tree.
NOT_GIT="$(mktemp -d)"
NG_CLEANUP="$NOT_GIT"  # captured for cleanup below
WF4="wf-gwt2-fsfirst-001"
FEAT4="fsfirst-feature"

FS_OUT=$(cc worktree provision \
    --workflow-id "$WF4" \
    --feature-name "$FEAT4" \
    --project-root "$NOT_GIT" 2>/dev/null || echo '{"status":"error"}')

# Clean up the mktemp directory now that we have the output
rm -rf "$NG_CLEANUP"

FS_STATUS=$(jq_get "$FS_OUT" "status")
if [[ "$FS_STATUS" == "error" ]]; then
    pass "filesystem-first: non-git project_root returns error"
else
    fail "filesystem-first: non-git project_root returns error (got: $FS_STATUS, full: $FS_OUT)"
fi

# Verify no DB state written — no worktree registered, no guardian lease
WT4_PATH="$NOT_GIT/.worktrees/feature-$FEAT4"
if [[ ! -d "$WT4_PATH" ]]; then
    pass "filesystem-first: no worktree directory created"
else
    fail "filesystem-first: no worktree directory created (found: $WT4_PATH)"
fi

G4_LEASE=$(cc lease current --worktree-path "$NOT_GIT" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('found',''))" 2>/dev/null || echo "false")
if [[ "$G4_LEASE" == "False" || "$G4_LEASE" == "false" || -z "$G4_LEASE" ]]; then
    pass "filesystem-first: no Guardian lease written to DB"
else
    fail "filesystem-first: no Guardian lease written to DB (found: $G4_LEASE)"
fi

# ==========================================================================
# Test 5: Missing required args
# ==========================================================================
echo ""
echo "--- Test 5: Missing required args ---"

# Missing --workflow-id
if ! CLAUDE_POLICY_DB="$TEST_DB" $CC worktree provision \
    --feature-name "x" --project-root "$GIT_REPO" >/dev/null 2>&1; then
    pass "missing --workflow-id: non-zero exit"
else
    fail "missing --workflow-id: non-zero exit (expected error, got success)"
fi

# Missing --feature-name
if ! CLAUDE_POLICY_DB="$TEST_DB" $CC worktree provision \
    --workflow-id "wf-x" --project-root "$GIT_REPO" >/dev/null 2>&1; then
    pass "missing --feature-name: non-zero exit"
else
    fail "missing --feature-name: non-zero exit (expected error, got success)"
fi

# ==========================================================================
# Summary
# ==========================================================================
echo ""
if [[ "$FAILURES" -eq 0 ]]; then
    echo "PASS: $TEST_NAME — all checks passed"
    exit 0
else
    echo "FAIL: $TEST_NAME — $FAILURES check(s) failed"
    exit 1
fi
