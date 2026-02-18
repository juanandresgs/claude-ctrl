#!/usr/bin/env bash
# test-finalize-trace-fileschanged.sh — Unit tests for finalize_trace() git diff fallback
#
# Purpose: Verify that finalize_trace() falls back to git diff --stat when
#          files-changed.txt is absent, and that the artifact takes priority when present.
#
# @decision DEC-OBS-SUG003
# @title Test git diff fallback in finalize_trace() files_changed count
# @status accepted
# @rationale Most agents modify files but never write files-changed.txt as a trace
#             artifact, causing 97% of traces to show files_changed=0. This fallback
#             recovers accurate counts from git without changing agent behavior.
#             Tests use isolated subshells per test case (same pattern as run-hooks.sh)
#             to avoid set -e / SIGHUP interactions when sourcing context-lib.sh.
#             Real git repos are created in temp dirs — no mocks.
#
# Usage: bash tests/test-finalize-trace-fileschanged.sh
# Returns: 0 if all tests pass, 1 if any fail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="${WORKTREE_ROOT}/hooks"

PASS=0
FAIL=0
MASTER_TRACE_STORE=""
MASTER_GIT_REPOS=()

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Shared temp TRACE_STORE for all tests (cleaned at exit)
MASTER_TRACE_STORE=$(mktemp -d)
trap 'rm -rf "$MASTER_TRACE_STORE" "${MASTER_GIT_REPOS[@]}"' EXIT

# --- Helpers ---

# Create a minimal valid manifest + summary, returns trace_id
# Usage: make_trace TRACE_STORE label project_root
make_trace() {
    local ts="$1" label="$2" pr="$3"
    local trace_id="test-${label}-$$"
    local trace_dir="${ts}/${trace_id}"
    mkdir -p "${trace_dir}/artifacts"
    printf '{"trace_id":"%s","agent_type":"implementer","started_at":"%s","project_root":"%s","session_id":"test-session"}\n' \
        "$trace_id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr" > "${trace_dir}/manifest.json"
    echo "# Test summary" > "${trace_dir}/summary.md"
    echo "$trace_id"
}

# Create a real git repo with one initial commit, returns repo path
make_git_repo() {
    local d
    d=$(mktemp -d)
    MASTER_GIT_REPOS+=("$d")
    git -C "$d" init -q 2>/dev/null
    git -C "$d" config user.email "test@test.com" 2>/dev/null
    git -C "$d" config user.name "Test" 2>/dev/null
    echo "initial" > "${d}/base.txt"
    git -C "$d" add base.txt 2>/dev/null
    git -C "$d" commit -q -m "initial" 2>/dev/null
    echo "$d"
}

# --- Test 1: No files-changed.txt, no git repo → files_changed=0 ---
echo ""
echo "=== Test 1: No artifact, no git repo → files_changed=0 ==="
PR1=$(mktemp -d)
TRACE_STORE_1=$(mktemp -d)
TRACE1=$(make_trace "$TRACE_STORE_1" "no-git-no-artifact" "$PR1")
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TRACE_STORE_1"
    finalize_trace "$TRACE1" "$PR1" "implementer" 2>/dev/null
    jq -r '.files_changed // "not-set"' "${TRACE_STORE_1}/${TRACE1}/manifest.json" 2>/dev/null
)
rm -rf "$PR1" "$TRACE_STORE_1"
if [[ "$output" == "0" ]]; then
    pass "No artifact, no git repo → files_changed=0"
else
    fail "No artifact, no git repo → expected 0, got: $output"
fi

# --- Test 2: No files-changed.txt, uncommitted (unstaged) git changes → files_changed > 0 ---
echo ""
echo "=== Test 2: No artifact, unstaged git changes → files_changed > 0 ==="
REPO2=$(make_git_repo)
echo "modified content" >> "${REPO2}/base.txt"
TRACE_STORE_2=$(mktemp -d)
TRACE2=$(make_trace "$TRACE_STORE_2" "git-unstaged" "$REPO2")
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TRACE_STORE_2"
    finalize_trace "$TRACE2" "$REPO2" "implementer" 2>/dev/null
    jq -r '.files_changed // "not-set"' "${TRACE_STORE_2}/${TRACE2}/manifest.json" 2>/dev/null
)
rm -rf "$TRACE_STORE_2"
if [[ "$output" =~ ^[1-9][0-9]*$ ]]; then
    pass "No artifact, unstaged changes → files_changed=$output (>0)"
else
    fail "No artifact, unstaged changes → expected >0, got: $output"
fi

# --- Test 3: No files-changed.txt, staged git changes → files_changed > 0 ---
echo ""
echo "=== Test 3: No artifact, staged git changes → files_changed > 0 ==="
REPO3=$(make_git_repo)
echo "staged content" >> "${REPO3}/base.txt"
git -C "$REPO3" add base.txt 2>/dev/null
TRACE_STORE_3=$(mktemp -d)
TRACE3=$(make_trace "$TRACE_STORE_3" "git-staged" "$REPO3")
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TRACE_STORE_3"
    finalize_trace "$TRACE3" "$REPO3" "implementer" 2>/dev/null
    jq -r '.files_changed // "not-set"' "${TRACE_STORE_3}/${TRACE3}/manifest.json" 2>/dev/null
)
rm -rf "$TRACE_STORE_3"
if [[ "$output" =~ ^[1-9][0-9]*$ ]]; then
    pass "No artifact, staged changes → files_changed=$output (>0)"
else
    fail "No artifact, staged changes → expected >0, got: $output"
fi

# --- Test 4: files-changed.txt present → artifact count wins over git fallback ---
echo ""
echo "=== Test 4: files-changed.txt present → artifact count takes priority ==="
REPO4=$(make_git_repo)
# Add uncommitted changes that would give count ≠ 7
echo "modified" >> "${REPO4}/base.txt"
TRACE_STORE_4=$(mktemp -d)
TRACE4=$(make_trace "$TRACE_STORE_4" "artifact-priority" "$REPO4")
# Write artifact with 7 entries — should override git fallback
printf 'file1.sh\nfile2.sh\nfile3.sh\nfile4.sh\nfile5.sh\nfile6.sh\nfile7.sh\n' \
    > "${TRACE_STORE_4}/${TRACE4}/artifacts/files-changed.txt"
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TRACE_STORE_4"
    finalize_trace "$TRACE4" "$REPO4" "implementer" 2>/dev/null
    jq -r '.files_changed // "not-set"' "${TRACE_STORE_4}/${TRACE4}/manifest.json" 2>/dev/null
)
rm -rf "$TRACE_STORE_4"
if [[ "$output" == "7" ]]; then
    pass "files-changed.txt present → files_changed=7 (artifact takes priority over git)"
else
    fail "files-changed.txt present → expected 7, got: $output"
fi

# --- Test 5: No artifact, clean git repo (no changes) → files_changed=0 ---
echo ""
echo "=== Test 5: No artifact, clean git repo → files_changed=0 ==="
REPO5=$(make_git_repo)
# No changes after initial commit — git diff --stat returns empty
TRACE_STORE_5=$(mktemp -d)
TRACE5=$(make_trace "$TRACE_STORE_5" "git-clean" "$REPO5")
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TRACE_STORE_5"
    finalize_trace "$TRACE5" "$REPO5" "implementer" 2>/dev/null
    jq -r '.files_changed // "not-set"' "${TRACE_STORE_5}/${TRACE5}/manifest.json" 2>/dev/null
)
rm -rf "$TRACE_STORE_5"
if [[ "$output" == "0" ]]; then
    pass "No artifact, clean git repo → files_changed=0"
else
    fail "No artifact, clean git repo → expected 0, got: $output"
fi

# --- Test 6: No artifact, multiple staged files → count ≥ 1 ---
echo ""
echo "=== Test 6: No artifact, 3 staged files → files_changed >= 1 ==="
REPO6=$(make_git_repo)
echo "modified" >> "${REPO6}/base.txt"
echo "new1" > "${REPO6}/new1.txt"
echo "new2" > "${REPO6}/new2.txt"
git -C "$REPO6" add base.txt new1.txt new2.txt 2>/dev/null
TRACE_STORE_6=$(mktemp -d)
TRACE6=$(make_trace "$TRACE_STORE_6" "git-multi-staged" "$REPO6")
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TRACE_STORE_6"
    finalize_trace "$TRACE6" "$REPO6" "implementer" 2>/dev/null
    jq -r '.files_changed // "not-set"' "${TRACE_STORE_6}/${TRACE6}/manifest.json" 2>/dev/null
)
rm -rf "$TRACE_STORE_6"
if [[ "$output" =~ ^[1-9][0-9]*$ ]]; then
    pass "No artifact, 3 staged files → files_changed=$output (>0)"
else
    fail "No artifact, 3 staged files → expected >0, got: $output"
fi

# --- Summary ---
echo ""
echo "====================================="
echo "RESULTS: $PASS passed, $FAIL failed"
echo "====================================="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
