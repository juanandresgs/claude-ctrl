#!/usr/bin/env bash
# test-meta-repo-worktree.sh: verifies that is_claude_meta_repo() returns true
# for a worktree of the ~/.claude meta-repo, not just for the main checkout.
#
# Bug: Before this fix, is_claude_meta_repo() used only --show-toplevel which
# returns the WORKTREE root (e.g. ~/.claude/.worktrees/feature-foo), not the
# shared repo root.  A worktree path does not end in /.claude so the check
# returned false, causing guard checks (main-is-sacred, proof, test-status,
# workflow binding) to fire incorrectly on meta-repo worktrees.
#
# Fix: Added Check 3 — git --git-common-dir always returns the shared .git
# path (e.g. ~/.claude/.git) regardless of which worktree is active.
#
# Regression for: #163 (bash), #143 (python)
#
# @decision DEC-META-001
# @title Use --git-common-dir to detect meta-repo worktrees
# @status accepted
# @rationale see hooks/context-lib.sh is_claude_meta_repo() Check 3 comment.
set -euo pipefail

TEST_NAME="test-meta-repo-worktree"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Create a temp directory structure that simulates ~/.claude
TMPBASE=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$TMPBASE'" EXIT

META_REPO="$TMPBASE/.claude"
mkdir -p "$META_REPO"

# Initialize the simulated ~/.claude repo
git -C "$META_REPO" init -q
git -C "$META_REPO" -c user.email="t@t.com" -c user.name="T" \
    commit --allow-empty -m "init meta-repo" -q

# Create a worktree of the meta-repo — this is the case that was broken
WORKTREE_DIR="$META_REPO/.worktrees/feature-test-branch"
mkdir -p "$META_REPO/.worktrees"
git -C "$META_REPO" worktree add "$WORKTREE_DIR" -b feature/test-branch -q 2>/dev/null

# Verify the worktree structure: --show-toplevel returns the worktree path
# (not ending in /.claude), while --git-common-dir returns the shared .git
WT_TOPLEVEL=$(git -C "$WORKTREE_DIR" rev-parse --show-toplevel 2>/dev/null)
WT_COMMON=$(git -C "$WORKTREE_DIR" rev-parse --git-common-dir 2>/dev/null)

if [[ "$WT_TOPLEVEL" == */.claude ]]; then
    echo "SKIP: $TEST_NAME — worktree toplevel unexpectedly ends in /.claude (git version behavior)"
    exit 0
fi

if [[ "$WT_COMMON" != */.claude/.git ]]; then
    echo "FAIL: $TEST_NAME — git --git-common-dir does not end in /.claude/.git"
    echo "  common_dir=$WT_COMMON"
    echo "  expected:  .../.claude/.git"
    exit 1
fi

# ---------------------------------------------------------------------------
# Part 1: Test the bash is_claude_meta_repo() function directly via context-lib.sh
# ---------------------------------------------------------------------------

# Source context-lib.sh in a subshell to call is_claude_meta_repo directly.
# We must NOT set CLAUDE_PROJECT_DIR — we want the --git-common-dir check (Check 3)
# to do the work, not the env var shortcut (Check 1).
BASH_RESULT=$(bash -c "
    source '$REPO_ROOT/hooks/context-lib.sh' 2>/dev/null
    # Unset CLAUDE_PROJECT_DIR to force git-based detection (Checks 2 and 3)
    unset CLAUDE_PROJECT_DIR
    if is_claude_meta_repo '$WORKTREE_DIR'; then
        echo 'true'
    else
        echo 'false'
    fi
" 2>/dev/null)

if [[ "$BASH_RESULT" != "true" ]]; then
    echo "FAIL: $TEST_NAME — bash is_claude_meta_repo() returned '$BASH_RESULT' for worktree of meta-repo"
    echo "  worktree_dir=$WORKTREE_DIR"
    echo "  expected: true (Check 3 via --git-common-dir)"
    echo "  regression: #163"
    exit 1
fi

# ---------------------------------------------------------------------------
# Part 2: Test the Python is_claude_meta_repo() function directly
# ---------------------------------------------------------------------------

PY_RESULT=$(python3 -c "
import os, sys
# Remove CLAUDE_PROJECT_DIR so Python Check 1 does not shortcut
os.environ.pop('CLAUDE_PROJECT_DIR', None)
sys.path.insert(0, '$REPO_ROOT')
from runtime.core.policy_utils import is_claude_meta_repo
result = is_claude_meta_repo('$WORKTREE_DIR')
print('true' if result else 'false')
" 2>/dev/null)

if [[ "$PY_RESULT" != "true" ]]; then
    echo "FAIL: $TEST_NAME — Python is_claude_meta_repo() returned '$PY_RESULT' for worktree of meta-repo"
    echo "  worktree_dir=$WORKTREE_DIR"
    echo "  expected: true (Check 3 via --git-common-dir)"
    echo "  regression: #143"
    exit 1
fi

# ---------------------------------------------------------------------------
# Part 3: Verify the main checkout still returns true (no regression on Check 2)
# ---------------------------------------------------------------------------

BASH_MAIN=$(bash -c "
    source '$REPO_ROOT/hooks/context-lib.sh' 2>/dev/null
    unset CLAUDE_PROJECT_DIR
    if is_claude_meta_repo '$META_REPO'; then
        echo 'true'
    else
        echo 'false'
    fi
" 2>/dev/null)

if [[ "$BASH_MAIN" != "true" ]]; then
    echo "FAIL: $TEST_NAME — bash is_claude_meta_repo() returned '$BASH_MAIN' for main checkout"
    echo "  meta_repo=$META_REPO"
    echo "  regression: Check 2 (--show-toplevel) broken"
    exit 1
fi

# ---------------------------------------------------------------------------
# Part 4: Verify a non-meta-repo returns false (no false positives)
# ---------------------------------------------------------------------------

PLAIN_REPO="$TMPBASE/myproject"
mkdir -p "$PLAIN_REPO"
git -C "$PLAIN_REPO" init -q
git -C "$PLAIN_REPO" -c user.email="t@t.com" -c user.name="T" \
    commit --allow-empty -m "init" -q

BASH_NEG=$(bash -c "
    source '$REPO_ROOT/hooks/context-lib.sh' 2>/dev/null
    unset CLAUDE_PROJECT_DIR
    if is_claude_meta_repo '$PLAIN_REPO'; then
        echo 'true'
    else
        echo 'false'
    fi
" 2>/dev/null)

if [[ "$BASH_NEG" != "false" ]]; then
    echo "FAIL: $TEST_NAME — bash is_claude_meta_repo() returned '$BASH_NEG' for plain repo (false positive)"
    echo "  plain_repo=$PLAIN_REPO"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
