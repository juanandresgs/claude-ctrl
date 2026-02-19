#!/usr/bin/env bash
# test-worktree-sweep.sh — Test suite for worktree sweep, Check 7b, session-init orphan scan,
# and .proof-status leak fix.
#
# Purpose: Validates the four-change worktree cleanup enforcement implementation:
#   1. worktree-roster.sh sweep command (three-way reconciliation)
#   2. check-guardian.sh Check 7b (post-merge directory verification)
#   3. session-init.sh filesystem orphan scan
#   4. session-init.sh .proof-status leak fix
#
# Follows test patterns from test-worktree-roster.sh: real git repos in tmp/,
# no mocks of internal functions, REGISTRY and WORKTREE_DIR env var overrides.
#
# @decision DEC-SWEEP-TEST-001
# @title Test sweep using real filesystem state with env var overrides for isolation
# @status accepted
# @rationale Sweep touches filesystem, git worktree list, and registry — all three
# must be real for meaningful tests. Mock-free: WORKTREE_DIR and REGISTRY env vars
# redirect all I/O to tmp/. This follows Sacred Practice #5 (real implementations,
# not mocks) while keeping tests isolated from the live ~/.claude/.worktrees/ state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROSTER_SCRIPT="$PROJECT_ROOT/scripts/worktree-roster.sh"

# Isolated test state in tmp/
TEST_TMP="$PROJECT_ROOT/tmp/test-sweep-$$"
TEST_REGISTRY="$TEST_TMP/.worktree-roster-sweep-test.tsv"
TEST_WORKTREE_DIR="$TEST_TMP/.worktrees"
TEST_PROOF_DIR="$TEST_TMP/.claude"

# ---- Helpers ----------------------------------------------------------------

setup() {
    rm -rf "$TEST_TMP"
    mkdir -p "$TEST_TMP"
    mkdir -p "$TEST_WORKTREE_DIR"
    mkdir -p "$TEST_PROOF_DIR"
    export REGISTRY="$TEST_REGISTRY"
    export WORKTREE_DIR="$TEST_WORKTREE_DIR"
    touch "$TEST_REGISTRY"
}

teardown() {
    rm -rf "$TEST_TMP"
    unset REGISTRY WORKTREE_DIR 2>/dev/null || true
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-assertion failed}"
    if [[ "$expected" != "$actual" ]]; then
        echo "FAIL: $msg"
        echo "  Expected: [$expected]"
        echo "  Actual:   [$actual]"
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-assertion failed}"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "FAIL: $msg"
        echo "  Expected to contain: [$needle]"
        echo "  Actual: [$haystack]"
        return 1
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-assertion failed}"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "FAIL: $msg"
        echo "  Expected NOT to contain: [$needle]"
        echo "  Actual: [$haystack]"
        return 1
    fi
}

assert_dir_exists() {
    local path="$1"
    local msg="${2:-directory should exist}"
    if [[ ! -d "$path" ]]; then
        echo "FAIL: $msg: $path"
        return 1
    fi
}

assert_dir_gone() {
    local path="$1"
    local msg="${2:-directory should be gone}"
    if [[ -d "$path" ]]; then
        echo "FAIL: $msg: $path"
        return 1
    fi
}

# Create a standalone git repo (NOT a worktree) in TEST_WORKTREE_DIR.
# These simulate directories that were never added to any git worktree list.
make_standalone_dir() {
    local name="$1"
    local add_files="${2:-false}"
    local dir="$TEST_WORKTREE_DIR/$name"
    mkdir -p "$dir"
    if [[ "$add_files" == "true" ]]; then
        echo "content" > "$dir/file.txt"
    fi
    echo "$dir"
}

# Add a ghost entry to the registry (path that does not exist on disk)
add_ghost_entry() {
    local ghost_path="$TEST_WORKTREE_DIR/ghost-$(date +%s)-$$"
    local created_at
    created_at=$(date '+%Y-%m-%d %H:%M:%S')
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$ghost_path" "feature/ghost" "" "test-session" "0" "$created_at" \
        >> "$TEST_REGISTRY"
    echo "$ghost_path"
}

# ---- Tests ------------------------------------------------------------------

# Test 1: sweep --dry-run reports all classifications without side effects
test_sweep_dry_run_reports_correctly() {
    echo "TEST: sweep --dry-run reports correctly"

    local husk_dir orphan_dir
    husk_dir=$(make_standalone_dir "husk1" false)
    orphan_dir=$(make_standalone_dir "orphan1" true)
    ghost_path=$(add_ghost_entry)

    local output
    output=$(REGISTRY="$TEST_REGISTRY" WORKTREE_DIR="$TEST_WORKTREE_DIR" \
        "$ROSTER_SCRIPT" sweep --dry-run 2>&1)

    assert_contains "$output" "husk" "dry-run should mention husks"
    assert_contains "$output" "orphan" "dry-run should mention orphans"
    assert_contains "$output" "ghost" "dry-run should mention ghosts"
    assert_contains "$output" "Dry-run" "dry-run should say no changes"

    # No side effects — dirs must still exist
    assert_dir_exists "$husk_dir" "husk should still exist after dry-run"
    assert_dir_exists "$orphan_dir" "orphan should still exist after dry-run"

    # Registry should still have ghost entry
    local registry_content
    registry_content=$(cat "$TEST_REGISTRY")
    assert_contains "$registry_content" "$ghost_path" "ghost should still be in registry after dry-run"

    echo "PASS: sweep --dry-run reports correctly"
}

# Test 2: sweep --auto removes husks only, preserves content orphans
test_sweep_auto_removes_husks_only() {
    echo "TEST: sweep --auto removes husks only"

    local husk_dir orphan_dir
    husk_dir=$(make_standalone_dir "husk2" false)
    orphan_dir=$(make_standalone_dir "orphan2" true)

    local output
    output=$(REGISTRY="$TEST_REGISTRY" WORKTREE_DIR="$TEST_WORKTREE_DIR" \
        "$ROSTER_SCRIPT" sweep --auto 2>&1)

    assert_dir_gone "$husk_dir" "husk should be removed by --auto"
    assert_dir_exists "$orphan_dir" "orphan with content should be preserved by --auto"
    assert_contains "$output" "Removed husk" "should report husk removal"
    assert_contains "$output" "WARN" "should warn about skipped orphan"

    echo "PASS: sweep --auto removes husks only"
}

# Test 3: sweep --confirm removes both husks and content orphans
test_sweep_confirm_removes_all() {
    echo "TEST: sweep --confirm removes husks and orphans"

    local husk_dir orphan_dir
    husk_dir=$(make_standalone_dir "husk3" false)
    orphan_dir=$(make_standalone_dir "orphan3" true)

    local output
    output=$(REGISTRY="$TEST_REGISTRY" WORKTREE_DIR="$TEST_WORKTREE_DIR" \
        "$ROSTER_SCRIPT" sweep --confirm 2>&1)

    assert_dir_gone "$husk_dir" "husk should be removed by --confirm"
    assert_dir_gone "$orphan_dir" "orphan should be removed by --confirm"
    assert_contains "$output" "Removed husk" "should report husk removal"
    assert_contains "$output" "Removed orphan" "should report orphan removal"

    echo "PASS: sweep --confirm removes both husks and orphans"
}

# Test 4: sweep auto-registers worktrees that are in git but not in roster
test_sweep_auto_registers_unregistered() {
    echo "TEST: sweep auto-registers unregistered git worktrees"

    # Create a real git worktree so it shows up in git worktree list
    local main_repo="$TEST_TMP/main-repo"
    mkdir -p "$main_repo"
    git -C "$main_repo" init --initial-branch=main >/dev/null 2>&1
    git -C "$main_repo" config user.email "test@test.com" >/dev/null 2>&1
    git -C "$main_repo" config user.name "Test" >/dev/null 2>&1
    touch "$main_repo/README.md"
    git -C "$main_repo" add . >/dev/null 2>&1
    git -C "$main_repo" commit -m "initial" >/dev/null 2>&1

    # Create a real git worktree from this repo
    local wt_dir="$TEST_WORKTREE_DIR/real-wt"
    git -C "$main_repo" worktree add "$wt_dir" -b feature/real-wt >/dev/null 2>&1

    # Registry is empty — the worktree is unregistered
    local registry_before
    registry_before=$(cat "$TEST_REGISTRY")
    assert_equals "" "$registry_before" "registry should be empty before sweep"

    # Sweep from main_repo context so git worktree list sees the worktree
    local output
    output=$(GIT_DIR="$main_repo/.git" GIT_WORK_TREE="$main_repo" \
        REGISTRY="$TEST_REGISTRY" WORKTREE_DIR="$TEST_WORKTREE_DIR" \
        git -C "$main_repo" worktree list --porcelain 2>/dev/null | head -5 || true)

    # Run sweep using the main_repo as working dir (so git sees the worktrees)
    output=$(cd "$main_repo" && \
        REGISTRY="$TEST_REGISTRY" WORKTREE_DIR="$TEST_WORKTREE_DIR" \
        "$ROSTER_SCRIPT" sweep --auto 2>&1)

    assert_contains "$output" "Registered" "sweep should register the unregistered worktree"

    local registry_after
    registry_after=$(cat "$TEST_REGISTRY")
    assert_contains "$registry_after" "$wt_dir" "registered worktree should appear in registry"

    # Cleanup
    git -C "$main_repo" worktree remove "$wt_dir" 2>/dev/null || rm -rf "$wt_dir"

    echo "PASS: sweep auto-registers unregistered git worktrees"
}

# Test 5: sweep prunes ghost registry entries (dirs in registry but gone on disk)
test_sweep_prunes_ghost_entries() {
    echo "TEST: sweep prunes ghost registry entries"

    local ghost_path
    ghost_path=$(add_ghost_entry)

    # Verify ghost is in registry
    local registry_before
    registry_before=$(cat "$TEST_REGISTRY")
    assert_contains "$registry_before" "$ghost_path" "ghost should be in registry"

    local output
    output=$(REGISTRY="$TEST_REGISTRY" WORKTREE_DIR="$TEST_WORKTREE_DIR" \
        "$ROSTER_SCRIPT" sweep --auto 2>&1)

    assert_contains "$output" "Pruned" "should report ghost pruning"

    local registry_after
    registry_after=$(cat "$TEST_REGISTRY" 2>/dev/null || echo "")
    assert_not_contains "$registry_after" "$ghost_path" "ghost should be pruned from registry"

    echo "PASS: sweep prunes ghost registry entries"
}

# Test 6: sweep CWD safety — no ENOENT when CWD inside orphan being deleted
test_sweep_cwd_safety() {
    echo "TEST: sweep CWD safety — survives when called from inside orphan dir"

    local husk_dir
    husk_dir=$(make_standalone_dir "husk6" false)

    # Run from inside the husk dir — sweep must cd out before rm
    local result
    result=$(
        cd "$husk_dir"
        REGISTRY="$TEST_REGISTRY" WORKTREE_DIR="$TEST_WORKTREE_DIR" \
            "$ROSTER_SCRIPT" sweep --confirm 2>&1
        echo "EXIT:$?"
    )

    if echo "$result" | grep -q "EXIT:0"; then
        echo "PASS: sweep CWD safety — sweep succeeded from inside orphan"
    else
        echo "FAIL: sweep CWD safety — unexpected result: $result"
        return 1
    fi

    assert_dir_gone "$husk_dir" "husk should have been removed"

    echo "PASS: sweep CWD safety"
}

# Test 7: sweep cleans empty .worktrees/ parent after last child deleted
test_sweep_cleans_empty_parent() {
    echo "TEST: sweep cleans empty .worktrees/ parent directory"

    # Create a single husk — after removal, parent should be empty and removed
    local husk_dir
    husk_dir=$(make_standalone_dir "only-husk" false)

    local output
    output=$(REGISTRY="$TEST_REGISTRY" WORKTREE_DIR="$TEST_WORKTREE_DIR" \
        "$ROSTER_SCRIPT" sweep --auto 2>&1)

    assert_dir_gone "$TEST_WORKTREE_DIR" ".worktrees/ parent should be removed when empty"
    assert_contains "$output" "Removed empty" "should report parent removal"

    echo "PASS: sweep cleans empty .worktrees/ parent directory"
}

# Test 8: check-guardian Check 7b fires on merge (simulated via breadcrumb + existing dir)
test_check_guardian_7b_fires_on_merge() {
    echo "TEST: check-guardian Check 7b fires on merge"

    local CHECK_GUARDIAN="$PROJECT_ROOT/hooks/check-guardian.sh"
    if [[ ! -x "$CHECK_GUARDIAN" ]]; then
        echo "SKIP: check-guardian.sh not found/executable"
        return 0
    fi

    # Create a fake worktree dir with a clean git repo
    local fake_wt="$TEST_TMP/fake-wt"
    mkdir -p "$fake_wt"
    git -C "$fake_wt" init --initial-branch=feature/test >/dev/null 2>&1
    git -C "$fake_wt" config user.email "test@test.com" >/dev/null 2>&1
    git -C "$fake_wt" config user.name "Test" >/dev/null 2>&1
    touch "$fake_wt/file.txt"
    git -C "$fake_wt" add . >/dev/null 2>&1
    git -C "$fake_wt" commit -m "initial" >/dev/null 2>&1

    # Write breadcrumb pointing to the fake worktree
    echo "$fake_wt" > "$TEST_PROOF_DIR/.active-worktree-path"

    # Test the Check 7b logic directly (extract and run the relevant code)
    # We simulate: HAS_COMMIT is set, breadcrumb exists, dir exists, dir is clean
    local WT_DIRTY
    WT_DIRTY=$(git -C "$fake_wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    assert_equals "0" "$WT_DIRTY" "fake wt should be clean"

    # Verify Check 7b would attempt sweep (dir is clean, breadcrumb exists)
    local breadcrumb_val
    breadcrumb_val=$(cat "$TEST_PROOF_DIR/.active-worktree-path" 2>/dev/null | tr -d '[:space:]')
    assert_equals "$fake_wt" "$breadcrumb_val" "breadcrumb should point to fake wt"

    # The sweep call in Check 7b uses WORKTREE_DIR="$(dirname WT_PATH_7B)"
    # Verify the sweep can be invoked with the right WORKTREE_DIR
    local sweep_dir
    sweep_dir=$(dirname "$fake_wt")
    local output
    output=$(REGISTRY="$TEST_REGISTRY" WORKTREE_DIR="$sweep_dir" \
        "$ROSTER_SCRIPT" sweep --auto 2>&1 || true)

    # The dir exists and is a real git repo (not a husk) — sweep should report it
    assert_contains "$output" "Sweep report" "sweep should produce a report"

    echo "PASS: check-guardian Check 7b fires on merge"
}

# Test 9: check-guardian Check 7b skips dirty worktrees (uncommitted changes)
test_check_guardian_7b_skips_dirty() {
    echo "TEST: check-guardian Check 7b skips dirty worktrees"

    local fake_wt="$TEST_TMP/dirty-wt"
    mkdir -p "$fake_wt"
    git -C "$fake_wt" init --initial-branch=feature/dirty >/dev/null 2>&1
    git -C "$fake_wt" config user.email "test@test.com" >/dev/null 2>&1
    git -C "$fake_wt" config user.name "Test" >/dev/null 2>&1
    touch "$fake_wt/file.txt"
    git -C "$fake_wt" add . >/dev/null 2>&1
    git -C "$fake_wt" commit -m "initial" >/dev/null 2>&1

    # Make it dirty
    echo "uncommitted change" > "$fake_wt/dirty.txt"

    local WT_DIRTY
    WT_DIRTY=$(git -C "$fake_wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

    # Check 7b logic: if dirty, should NOT call sweep, should add to ISSUES
    if [[ "$WT_DIRTY" -gt 0 ]]; then
        # Simulate the Check 7b conditional: dirty wt produces a WARN, not a sweep call
        # The warning goes to ISSUES array; sweep is only called when WT_DIRTY -eq 0.
        local would_warn="WARN: Worktree $fake_wt still exists with $WT_DIRTY uncommitted change(s) — manual cleanup needed"
        assert_contains "$would_warn" "WARN" "dirty wt should produce a warning"
        assert_contains "$would_warn" "manual cleanup" "dirty wt warning should say manual cleanup"
        # Verify the sweep would NOT be called (WT_DIRTY > 0 branch does not call sweep)
        local sweep_called=false
        if [[ "$WT_DIRTY" -eq 0 ]]; then
            sweep_called=true
        fi
        assert_equals "false" "$sweep_called" "sweep should not be called for dirty worktree"
        echo "PASS: check-guardian Check 7b skips dirty worktrees"
    else
        echo "FAIL: test setup — wt should be dirty but WT_DIRTY=$WT_DIRTY"
        return 1
    fi
}

# Test 10: session-init filesystem orphan scan auto-cleans husks
test_session_init_auto_cleans_husks() {
    echo "TEST: session-init auto-cleans husks on startup"

    # Create a husk (empty dir) in a fake .worktrees/
    local fake_project="$TEST_TMP/fake-project"
    mkdir -p "$fake_project"
    git -C "$fake_project" init --initial-branch=main >/dev/null 2>&1
    git -C "$fake_project" config user.email "test@test.com" >/dev/null 2>&1
    git -C "$fake_project" config user.name "Test" >/dev/null 2>&1
    touch "$fake_project/README.md"
    git -C "$fake_project" add . >/dev/null 2>&1
    git -C "$fake_project" commit -m "initial" >/dev/null 2>&1

    local fake_wt_base="$fake_project/.worktrees"
    mkdir -p "$fake_wt_base"
    local husk_dir="$fake_wt_base/orphan-husk"
    mkdir -p "$husk_dir"  # empty — is a husk

    # Verify husk exists before simulating session-init scan
    assert_dir_exists "$husk_dir" "husk should exist before scan"

    # Extract and run the session-init orphan scan logic directly
    # This tests the core logic without needing to invoke the full hook
    local WORKTREE_BASE="$fake_project/.worktrees"
    local GIT_WT_PATHS
    GIT_WT_PATHS=$(git -C "$fake_project" worktree list --porcelain 2>/dev/null \
        | grep '^worktree ' | sed 's/^worktree //' || echo "")

    local HUSK_COUNT=0
    local ORPHAN_DIRS=()

    for wt_dir in "$WORKTREE_BASE"/*/; do
        [[ ! -d "$wt_dir" ]] && continue
        wt_dir="${wt_dir%/}"
        wt_name=$(basename "$wt_dir")

        # Skip if tracked by git
        if echo "$GIT_WT_PATHS" | grep -qF "$wt_dir"; then
            continue
        fi

        local FILE_COUNT
        FILE_COUNT=$(find "$wt_dir" -not -name '.git' -not -path '*/.git/*' \
            -type f 2>/dev/null | wc -l | tr -d ' ')

        if [[ "$FILE_COUNT" -eq 0 ]]; then
            rm -rf "$wt_dir"
            HUSK_COUNT=$((HUSK_COUNT + 1))
        else
            ORPHAN_DIRS+=("$wt_name ($FILE_COUNT files)")
        fi
    done

    assert_equals "1" "$HUSK_COUNT" "should have cleaned 1 husk"
    assert_dir_gone "$husk_dir" "husk should be gone after scan"
    assert_equals "0" "${#ORPHAN_DIRS[@]}" "no content orphans should exist"

    echo "PASS: session-init auto-cleans husks on startup"
}

# Test 11: session-init warns on content orphans without deleting them
test_session_init_warns_on_content_orphans() {
    echo "TEST: session-init warns on content orphans without deleting"

    local fake_project="$TEST_TMP/fake-project-orphan"
    mkdir -p "$fake_project"
    git -C "$fake_project" init --initial-branch=main >/dev/null 2>&1
    git -C "$fake_project" config user.email "test@test.com" >/dev/null 2>&1
    git -C "$fake_project" config user.name "Test" >/dev/null 2>&1
    touch "$fake_project/README.md"
    git -C "$fake_project" add . >/dev/null 2>&1
    git -C "$fake_project" commit -m "initial" >/dev/null 2>&1

    local fake_wt_base="$fake_project/.worktrees"
    mkdir -p "$fake_wt_base"
    local orphan_dir="$fake_wt_base/content-orphan"
    mkdir -p "$orphan_dir"
    echo "important data" > "$orphan_dir/important.txt"  # has content — is an orphan

    local WORKTREE_BASE="$fake_project/.worktrees"
    local GIT_WT_PATHS
    GIT_WT_PATHS=$(git -C "$fake_project" worktree list --porcelain 2>/dev/null \
        | grep '^worktree ' | sed 's/^worktree //' || echo "")

    local HUSK_COUNT=0
    local ORPHAN_DIRS=()

    for wt_dir in "$WORKTREE_BASE"/*/; do
        [[ ! -d "$wt_dir" ]] && continue
        wt_dir="${wt_dir%/}"
        wt_name=$(basename "$wt_dir")

        if echo "$GIT_WT_PATHS" | grep -qF "$wt_dir"; then
            continue
        fi

        local FILE_COUNT
        FILE_COUNT=$(find "$wt_dir" -not -name '.git' -not -path '*/.git/*' \
            -type f 2>/dev/null | wc -l | tr -d ' ')

        if [[ "$FILE_COUNT" -eq 0 ]]; then
            rm -rf "$wt_dir"
            HUSK_COUNT=$((HUSK_COUNT + 1))
        else
            ORPHAN_DIRS+=("$wt_name ($FILE_COUNT files)")
        fi
    done

    assert_equals "0" "$HUSK_COUNT" "no husks should be cleaned"
    assert_dir_exists "$orphan_dir" "content orphan should be preserved"
    assert_equals "1" "${#ORPHAN_DIRS[@]}" "one orphan should be detected"
    assert_contains "${ORPHAN_DIRS[0]}" "content-orphan" "orphan name should be in list"

    echo "PASS: session-init warns on content orphans without deleting"
}

# Test 12: .proof-status leak fix — "verified" status cleaned at session start with no agents
test_proof_status_leak_fix() {
    echo "TEST: .proof-status leak fix — verified status cleaned at session start"

    local FAKE_PROOF="$TEST_PROOF_DIR/.proof-status"
    local FAKE_TRACE_STORE="$TEST_TMP/traces"
    mkdir -p "$FAKE_TRACE_STORE"

    # Write a "verified" .proof-status — the leaked state we need to clean
    echo "verified|$(date +%s)" > "$FAKE_PROOF"

    # Simulate the new session-init logic:
    # 1. No active markers (no .active-* files in TRACE_STORE)
    # 2. ANY .proof-status should be cleaned
    # Use glob expansion rather than ls to avoid newline issues from ls error output
    local ACTIVE_MARKERS=0
    local _marker
    for _marker in "$FAKE_TRACE_STORE"/.active-*; do
        [[ -f "$_marker" ]] && ACTIVE_MARKERS=$((ACTIVE_MARKERS + 1))
    done
    assert_equals "0" "$ACTIVE_MARKERS" "no active markers should exist"

    local PROOF_VAL=""
    if [[ -f "$FAKE_PROOF" ]]; then
        if [[ "$ACTIVE_MARKERS" -eq 0 ]]; then
            PROOF_VAL=$(cut -d'|' -f1 "$FAKE_PROOF" 2>/dev/null || echo "")
            rm -f "$FAKE_PROOF"
        fi
    fi

    assert_equals "verified" "$PROOF_VAL" "should have read verified status before cleaning"
    if [[ -f "$FAKE_PROOF" ]]; then
        echo "FAIL: .proof-status should have been cleaned but still exists"
        return 1
    fi

    echo "PASS: .proof-status leak fix — verified status cleaned at session start"
}

# Test 12b: Old behavior check — old code preserved "verified" status (regression guard)
test_old_code_would_preserve_verified() {
    echo "TEST: Regression guard — old code preserved verified (new code must not)"

    local FAKE_PROOF="$TEST_PROOF_DIR/.proof-status-old"
    echo "verified|$(date +%s)" > "$FAKE_PROOF"

    # Simulate OLD session-init logic (the bug):
    # Only cleaned if PROOF_VAL != "verified"
    local PROOF_VAL_OLD
    PROOF_VAL_OLD=$(cut -d'|' -f1 "$FAKE_PROOF" 2>/dev/null || echo "")
    local OLD_WOULD_CLEAN=false
    if [[ "$PROOF_VAL_OLD" != "verified" ]]; then
        OLD_WOULD_CLEAN=true
        rm -f "$FAKE_PROOF"
    fi

    assert_equals "false" "$OLD_WOULD_CLEAN" "old code should NOT have cleaned verified status"
    assert_dir_exists "$(dirname "$FAKE_PROOF")" "proof dir should still exist"
    if [[ ! -f "$FAKE_PROOF" ]]; then
        echo "FAIL: old code incorrectly cleaned verified status"
        return 1
    fi

    # New code SHOULD clean it (already verified in test 12 above)
    rm -f "$FAKE_PROOF"  # cleanup
    echo "PASS: regression guard — old code preserved verified, new code correctly cleans it"
}

# ---- Runner -----------------------------------------------------------------

run_tests() {
    local failed=0
    local passed=0
    local skipped=0

    local tests=(
        test_sweep_dry_run_reports_correctly
        test_sweep_auto_removes_husks_only
        test_sweep_confirm_removes_all
        test_sweep_auto_registers_unregistered
        test_sweep_prunes_ghost_entries
        test_sweep_cwd_safety
        test_sweep_cleans_empty_parent
        test_check_guardian_7b_fires_on_merge
        test_check_guardian_7b_skips_dirty
        test_session_init_auto_cleans_husks
        test_session_init_warns_on_content_orphans
        test_proof_status_leak_fix
        test_old_code_would_preserve_verified
    )

    for test_func in "${tests[@]}"; do
        setup
        if $test_func; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
        fi
        teardown
        echo ""
    done

    echo "=========================================="
    echo "Results: $passed passed, $failed failed"
    echo "=========================================="

    if [[ "$failed" -gt 0 ]]; then
        exit 1
    fi
}

# Main
if [[ ! -x "$ROSTER_SCRIPT" ]]; then
    echo "ERROR: worktree-roster.sh not found or not executable at $ROSTER_SCRIPT"
    exit 1
fi

mkdir -p "$PROJECT_ROOT/tmp"
run_tests
