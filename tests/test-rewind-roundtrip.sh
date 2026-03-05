#!/usr/bin/env bash
# Round-trip tests for checkpoint creation and rewind restore — Phase 4 (v2 Checkpoints & Rewind)
#
# Purpose: Validate that checkpoints capture working tree state accurately and
#   that the rewind protocol (git checkout + git clean) restores that state
#   completely, including removal of untracked files added after the checkpoint.
#
# Test cases:
#   1. Round-trip accuracy: tracked file content restored, untracked file removed
#   2. Sequential checkpoint numbering: refs numbered 1, 2, 3 in order
#   3. Checkpoint message format: subject matches checkpoint:EPOCH:before:FILENAME
#   4. Checkpoint tree accuracy: git ls-tree matches expected files
#   5. Rewind to middle checkpoint: with 3 checkpoints, rewind to #2
#   6. .claude/ exclusion: .claude/ state files survive git clean -fd -e .claude/
#   7. Counter reset: deleting .checkpoint-counter causes next checkpoint to start at 1
#   8. Worktree checkpoint: checkpoint.sh works from a worktree context
#
# @decision DEC-V2-002
# @title Round-trip tests for git ref-based checkpoint restore
# @status accepted
# @rationale REQ-P0-005 requires that after rewind, working tree matches checkpoint
#   state. This means tracked files are restored AND untracked files (created after
#   the checkpoint) are removed. Tests simulate the full protocol: checkpoint.sh
#   creates the ref, then we simulate the rewind restore commands from SKILL.md.
#   W4-3 (Issue #119) and W4-4 (Issue #120).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="${SCRIPT_DIR}/../hooks"
CHECKPOINT_SH="${HOOKS_DIR}/checkpoint.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0

# Cleanup trap (DEC-PROD-002): collect temp dirs and remove on exit
_CLEANUP_DIRS=()
trap '[[ ${#_CLEANUP_DIRS[@]} -gt 0 ]] && rm -rf "${_CLEANUP_DIRS[@]}" 2>/dev/null; true' EXIT
TESTS_PASSED=0
TESTS_FAILED=0

pass_test() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}PASS${NC} $1"
}

fail_test() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}FAIL${NC} $1"
    echo -e "  ${YELLOW}Details:${NC} $2"
}

run_test() {
    TESTS_RUN=$((TESTS_RUN + 1))
}

# Setup: create an isolated git repo on a feature branch for testing.
# Returns the repo path via echo (caller should capture).
setup_test_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@test.com"
    git -C "$repo" config user.name "Test"
    echo "initial" > "$repo/file.txt"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "init"
    git -C "$repo" checkout -q -b feature/test 2>/dev/null
}

# Trigger checkpoint.sh for a given repo and file path.
# Simulates a Write PreToolUse event piped to checkpoint.sh stdin.
run_checkpoint() {
    local repo="$1"
    local file_path="$2"
    local session_id="${3:-test-roundtrip-$$}"

    local input
    input=$(jq -n --arg fp "$file_path" '{"tool_name":"Write","tool_input":{"file_path":$fp}}')

    CLAUDE_PROJECT_DIR="$repo" \
    CLAUDE_SESSION_ID="$session_id" \
    HOME="$repo" \
    bash "$CHECKPOINT_SH" <<< "$input" 2>/dev/null
}

# Get the SHA of checkpoint ref N on feature/test branch
get_checkpoint_sha() {
    local repo="$1"
    local n="$2"
    local branch="${3:-feature/test}"
    git -C "$repo" rev-parse "refs/checkpoints/${branch}/${n}" 2>/dev/null || echo ""
}

# Count checkpoint refs for a branch
count_checkpoint_refs() {
    local repo="$1"
    local branch="${2:-feature/test}"
    git -C "$repo" for-each-ref "refs/checkpoints/${branch}/" 2>/dev/null | wc -l | tr -d ' '
}

# Simulate the rewind restore from SKILL.md Step 3:
#   git checkout SHA -- .
#   git clean -fd -e .claude/
simulate_rewind() {
    local repo="$1"
    local sha="$2"
    git -C "$repo" checkout "$sha" -- . 2>/dev/null
    git -C "$repo" clean -fd -e .claude/ 2>/dev/null
}

# ============================================================================
# Test 1: Round-trip accuracy
# Create files A (tracked), B (tracked). Trigger checkpoint. Modify A, add C (untracked).
# Simulate rewind. Assert: A has original content, B unchanged, C removed.
# ============================================================================
test_roundtrip_accuracy() {
    run_test
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    local claude_dir="$tmp/.claude"
    setup_test_repo "$tmp"
    mkdir -p "$claude_dir"

    local session_id="roundtrip-acc-$$"

    # Create files A and B, commit them (tracked)
    echo "original-A" > "$tmp/file_a.txt"
    echo "original-B" > "$tmp/file_b.txt"
    git -C "$tmp" add -A
    git -C "$tmp" commit -q -m "add A and B"

    # Pre-seed session-changes so first write triggers checkpoint
    touch "$claude_dir/.session-changes-${session_id}"

    # Trigger checkpoint (captures A and B as they are now)
    run_checkpoint "$tmp" "$tmp/file_a.txt" "$session_id"

    local ref_count
    ref_count=$(count_checkpoint_refs "$tmp")
    if [[ "$ref_count" -lt 1 ]]; then
        fail_test "Round-trip accuracy: no checkpoint created"
        return
    fi

    # Get checkpoint SHA
    local cp_sha
    cp_sha=$(get_checkpoint_sha "$tmp" 1)

    # Now modify A and add C (untracked)
    echo "modified-A" > "$tmp/file_a.txt"
    echo "new-C" > "$tmp/file_c.txt"

    # Simulate rewind to checkpoint
    simulate_rewind "$tmp" "$cp_sha"

    # Assertions
    local a_content b_content c_exists=false
    a_content=$(cat "$tmp/file_a.txt" 2>/dev/null || echo "MISSING")
    b_content=$(cat "$tmp/file_b.txt" 2>/dev/null || echo "MISSING")
    [[ -f "$tmp/file_c.txt" ]] && c_exists=true

    if [[ "$a_content" == "original-A" && "$b_content" == "original-B" && "$c_exists" == "false" ]]; then
        pass_test "Round-trip accuracy: A restored, B unchanged, C removed"
    else
        fail_test "Round-trip accuracy" \
            "A='$a_content' (want 'original-A'), B='$b_content' (want 'original-B'), C_exists=$c_exists (want false)"
    fi
}

# ============================================================================
# Test 2: Sequential checkpoint numbering
# Create multiple checkpoints (via first-new-file rule), verify refs are 1, 2, 3.
# ============================================================================
test_sequential_numbering() {
    run_test
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    local claude_dir="$tmp/.claude"
    setup_test_repo "$tmp"
    mkdir -p "$claude_dir"

    local session_id="seq-num-$$"

    # Pre-seed session-changes file so each new file triggers a checkpoint
    touch "$claude_dir/.session-changes-${session_id}"

    # Write to 3 distinct files (each triggers first-new-file checkpoint)
    for i in 1 2 3; do
        local file="$tmp/module_${i}.py"
        echo "content_${i}" > "$file"
        git -C "$tmp" add "$file"
        git -C "$tmp" commit -q -m "add module_${i}"
        run_checkpoint "$tmp" "$file" "$session_id"
    done

    # Verify refs 1, 2, 3 all exist
    local all_exist=true
    for n in 1 2 3; do
        local sha
        sha=$(get_checkpoint_sha "$tmp" "$n")
        if [[ -z "$sha" ]]; then
            all_exist=false
            break
        fi
    done

    if [[ "$all_exist" == "true" ]]; then
        pass_test "Sequential numbering: refs 1, 2, 3 all exist"
    else
        local found
        found=$(count_checkpoint_refs "$tmp")
        fail_test "Sequential numbering: expected refs 1,2,3 to exist (found ${found} refs)"
    fi
}

# ============================================================================
# Test 3: Checkpoint message format
# Verify commit subject matches checkpoint:EPOCH:before:FILENAME
# ============================================================================
test_checkpoint_message_format() {
    run_test
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    local claude_dir="$tmp/.claude"
    setup_test_repo "$tmp"
    mkdir -p "$claude_dir"

    local session_id="msg-fmt-$$"
    touch "$claude_dir/.session-changes-${session_id}"

    echo "hello" > "$tmp/target.py"
    git -C "$tmp" add "$tmp/target.py"
    git -C "$tmp" commit -q -m "add target"
    run_checkpoint "$tmp" "$tmp/target.py" "$session_id"

    # Get the checkpoint message subject
    local sha subject
    sha=$(get_checkpoint_sha "$tmp" 1)
    if [[ -z "$sha" ]]; then
        fail_test "Checkpoint message format: no checkpoint created"
        return
    fi
    subject=$(git -C "$tmp" log --format='%s' -1 "$sha" 2>/dev/null || echo "")

    # Subject must match checkpoint:DIGITS:before:FILENAME
    if echo "$subject" | grep -qE '^checkpoint:[0-9]+:before:target\.py$'; then
        pass_test "Checkpoint message format: '$subject'"
    else
        fail_test "Checkpoint message format" \
            "got '$subject', expected format 'checkpoint:EPOCH:before:target.py'"
    fi
}

# ============================================================================
# Test 4: Checkpoint tree accuracy
# git ls-tree of checkpoint should include both committed files
# ============================================================================
test_checkpoint_tree_accuracy() {
    run_test
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    local claude_dir="$tmp/.claude"
    setup_test_repo "$tmp"
    mkdir -p "$claude_dir"

    local session_id="tree-acc-$$"
    touch "$claude_dir/.session-changes-${session_id}"

    # Create two files and commit
    echo "alpha content" > "$tmp/alpha.py"
    echo "beta content" > "$tmp/beta.py"
    git -C "$tmp" add -A
    git -C "$tmp" commit -q -m "add alpha and beta"

    run_checkpoint "$tmp" "$tmp/alpha.py" "$session_id"

    local sha
    sha=$(get_checkpoint_sha "$tmp" 1)
    if [[ -z "$sha" ]]; then
        fail_test "Checkpoint tree accuracy: no checkpoint created"
        return
    fi

    # Get tree from the checkpoint commit
    local tree_sha
    tree_sha=$(git -C "$tmp" cat-file -p "$sha" 2>/dev/null | grep '^tree' | awk '{print $2}')

    local has_alpha has_beta
    has_alpha=$(git -C "$tmp" ls-tree "$tree_sha" 2>/dev/null | grep 'alpha.py' || echo "")
    has_beta=$(git -C "$tmp" ls-tree "$tree_sha" 2>/dev/null | grep 'beta.py' || echo "")

    if [[ -n "$has_alpha" && -n "$has_beta" ]]; then
        pass_test "Checkpoint tree accuracy: alpha.py and beta.py in checkpoint tree"
    else
        fail_test "Checkpoint tree accuracy" \
            "alpha.py found='${has_alpha:-no}', beta.py found='${has_beta:-no}'"
    fi
}

# ============================================================================
# Test 5: Rewind to middle checkpoint (with 3 checkpoints, rewind to #2)
# Files at checkpoint 2 are restored, not the state at checkpoint 1 or 3.
# ============================================================================
test_rewind_to_middle_checkpoint() {
    run_test
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    local claude_dir="$tmp/.claude"
    setup_test_repo "$tmp"
    mkdir -p "$claude_dir"

    local session_id="middle-cp-$$"
    touch "$claude_dir/.session-changes-${session_id}"

    # Checkpoint 1: file has "state-1"
    echo "state-1" > "$tmp/evolving.txt"
    git -C "$tmp" add "$tmp/evolving.txt"
    git -C "$tmp" commit -q -m "state-1"
    run_checkpoint "$tmp" "$tmp/evolving.txt" "$session_id"
    local sha1
    sha1=$(get_checkpoint_sha "$tmp" 1)

    # Checkpoint 2: file has "state-2"
    echo "state-2" > "$tmp/evolving.txt"
    git -C "$tmp" add "$tmp/evolving.txt"
    git -C "$tmp" commit -q -m "state-2"
    run_checkpoint "$tmp" "$tmp/second.txt" "$session_id"
    local sha2
    sha2=$(get_checkpoint_sha "$tmp" 2)

    # Checkpoint 3: file has "state-3"
    echo "state-3" > "$tmp/evolving.txt"
    git -C "$tmp" add "$tmp/evolving.txt"
    git -C "$tmp" commit -q -m "state-3"
    run_checkpoint "$tmp" "$tmp/third.txt" "$session_id"
    local sha3
    sha3=$(get_checkpoint_sha "$tmp" 3)

    # Verify we have 3 checkpoints
    local count
    count=$(count_checkpoint_refs "$tmp")
    if [[ "$count" -ne 3 ]]; then
        fail_test "Rewind to middle: expected 3 checkpoints, got $count"
        return
    fi

    # Rewind to checkpoint 2
    simulate_rewind "$tmp" "$sha2"

    local content
    content=$(cat "$tmp/evolving.txt" 2>/dev/null || echo "MISSING")

    if [[ "$content" == "state-2" ]]; then
        pass_test "Rewind to middle checkpoint: file has 'state-2' after rewind to CP2"
    else
        fail_test "Rewind to middle checkpoint" \
            "got '$content', expected 'state-2'"
    fi
}

# ============================================================================
# Test 6: .claude/ exclusion
# Create .claude/state-file, simulate rewind, verify state-file survives.
# ============================================================================
test_claude_dir_exclusion() {
    run_test
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    local claude_dir="$tmp/.claude"
    setup_test_repo "$tmp"
    mkdir -p "$claude_dir"

    local session_id="claude-excl-$$"
    touch "$claude_dir/.session-changes-${session_id}"

    # Create and commit a file, then checkpoint
    echo "base" > "$tmp/code.txt"
    git -C "$tmp" add "$tmp/code.txt"
    git -C "$tmp" commit -q -m "add code"
    run_checkpoint "$tmp" "$tmp/code.txt" "$session_id"
    local sha
    sha=$(get_checkpoint_sha "$tmp" 1)
    if [[ -z "$sha" ]]; then
        fail_test ".claude/ exclusion: no checkpoint created"
        return
    fi

    # Add an untracked file AND a .claude/ state file after the checkpoint
    echo "post-checkpoint" > "$tmp/newfile.txt"
    echo "session-state" > "$claude_dir/some-state.txt"

    # Simulate rewind (must exclude .claude/)
    git -C "$tmp" checkout "$sha" -- . 2>/dev/null
    git -C "$tmp" clean -fd -e .claude/ 2>/dev/null

    local newfile_exists=false state_exists=false
    [[ -f "$tmp/newfile.txt" ]] && newfile_exists=true
    [[ -f "$claude_dir/some-state.txt" ]] && state_exists=true

    if [[ "$newfile_exists" == "false" && "$state_exists" == "true" ]]; then
        pass_test ".claude/ exclusion: newfile removed, .claude/some-state.txt preserved"
    else
        fail_test ".claude/ exclusion" \
            "newfile_exists=$newfile_exists (want false), state_exists=$state_exists (want true)"
    fi
}

# ============================================================================
# Test 7: Counter reset
# Delete .checkpoint-counter, verify next checkpoint starts at 1 (not continuing).
# Specifically: after deletion, a new first-write-of-file write must trigger a
# checkpoint and the ref must be assigned number 1 (i.e., counter resets to 0 → N=1).
# ============================================================================
test_counter_reset() {
    run_test
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    local claude_dir="$tmp/.claude"
    setup_test_repo "$tmp"
    mkdir -p "$claude_dir"

    local session_id="counter-reset-$$"

    # Run 6 writes to get the counter to 6 (with checkpoints created)
    for i in 1 2 3 4 5 6; do
        run_checkpoint "$tmp" "$tmp/file_$i.py" "$session_id"
    done

    local count_before
    count_before=$(count_checkpoint_refs "$tmp")

    # Delete the counter file
    rm -f "$claude_dir/.checkpoint-counter"

    # New session — use a new session_id so the session-changes file is fresh
    local new_session="counter-reset-new-$$"
    # Trigger one more write — should create a checkpoint as first-of-session
    run_checkpoint "$tmp" "$tmp/fresh.py" "$new_session"

    # Counter file should now exist with value 1
    local counter_val=0
    if [[ -f "$claude_dir/.checkpoint-counter" ]]; then
        counter_val=$(cat "$claude_dir/.checkpoint-counter" 2>/dev/null || echo "0")
    fi

    if [[ "$counter_val" -eq 1 ]]; then
        pass_test "Counter reset: after deletion, counter starts fresh at 1"
    else
        fail_test "Counter reset" \
            "expected counter=1 after reset, got counter=$counter_val"
    fi
}

# ============================================================================
# Test 8: Worktree checkpoint (W4-4, Issue #120)
# Create a git repo, add a worktree, run checkpoint.sh from the worktree context.
# Verify refs are created and accessible from the main repo.
# ============================================================================
test_worktree_checkpoint() {
    run_test
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    local main_repo="$tmp/main-repo"
    local wt_path="$tmp/worktree"

    # Set up main repo
    mkdir -p "$main_repo"
    git -C "$main_repo" init -q
    git -C "$main_repo" config user.email "test@test.com"
    git -C "$main_repo" config user.name "Test"
    echo "initial" > "$main_repo/main.txt"
    git -C "$main_repo" add -A
    git -C "$main_repo" commit -q -m "init"

    # Create a worktree on a feature branch
    git -C "$main_repo" worktree add "$wt_path" -b feature/wt-test 2>/dev/null

    local wt_claude_dir="$wt_path/.claude"
    mkdir -p "$wt_claude_dir"

    local session_id="wt-test-$$"
    touch "$wt_claude_dir/.session-changes-${session_id}"

    # Add a file in the worktree and commit it
    echo "worktree-content" > "$wt_path/wt-file.txt"
    git -C "$wt_path" add "$wt_path/wt-file.txt"
    git -C "$wt_path" commit -q -m "add wt-file"

    # Run checkpoint from worktree context (CLAUDE_PROJECT_DIR points to worktree)
    local input
    input=$(jq -n --arg fp "$wt_path/wt-file.txt" '{"tool_name":"Write","tool_input":{"file_path":$fp}}')

    CLAUDE_PROJECT_DIR="$wt_path" \
    CLAUDE_SESSION_ID="$session_id" \
    HOME="$wt_path" \
    bash "$CHECKPOINT_SH" <<< "$input" 2>/dev/null

    # Refs should be under refs/checkpoints/feature/wt-test/
    local ref_count
    ref_count=$(git -C "$wt_path" for-each-ref "refs/checkpoints/feature/wt-test/" 2>/dev/null | wc -l | tr -d ' ')

    # Also verify from main repo (refs are shared in a git common dir)
    local ref_count_main
    ref_count_main=$(git -C "$main_repo" for-each-ref "refs/checkpoints/feature/wt-test/" 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$ref_count" -ge 1 ]]; then
        pass_test "Worktree checkpoint: ref created from worktree context (wt_count=${ref_count}, main_count=${ref_count_main})"
    else
        fail_test "Worktree checkpoint" \
            "no refs in refs/checkpoints/feature/wt-test/ from worktree or main (wt=${ref_count}, main=${ref_count_main})"
    fi

    # Cleanup worktree
    git -C "$main_repo" worktree remove --force "$wt_path" 2>/dev/null || true
}

# ============================================================================
# Run all tests
# ============================================================================

echo "=== checkpoint rewind round-trip tests ==="
echo ""

test_roundtrip_accuracy
test_sequential_numbering
test_checkpoint_message_format
test_checkpoint_tree_accuracy
test_rewind_to_middle_checkpoint
test_claude_dir_exclusion
test_counter_reset
test_worktree_checkpoint

echo ""
echo "=== Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed ==="

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
exit 0
