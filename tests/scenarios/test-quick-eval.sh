#!/usr/bin/env bash
# test-quick-eval.sh — end-to-end scenario tests for ``cc-policy evaluate quick``.
#
# Tests four cases using a real git repo in tmp/:
#   Case A: Small non-source change (<= 50 lines, .md file) → eligible, eval written
#   Case B: Source file change (.py file) → not eligible, exit 1
#   Case C: Too many lines (>50 line change) → not eligible, exit 1
#   Case D: No uncommitted changes → not eligible, exit 1
#
# Each case uses an isolated git repo and a separate state.db so they do not
# interfere with each other or the project's live database.
#
# @decision DEC-QUICKEVAL-001
# @title Quick eval is scope-gated, not LLM-gated
# @status accepted
# @rationale These scenario tests exercise the full production sequence:
#   real git repo → git diff subprocess → scope validation → SQLite write.
#   They complement the unit tests (monkeypatched subprocess) by proving the
#   subprocess integration actually works end-to-end.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNTIME_ROOT="$REPO_ROOT/runtime"
TMP_BASE="$REPO_ROOT/tmp/test-quick-eval-$$"

PASS_COUNT=0
FAIL_COUNT=0

# shellcheck disable=SC2329  # invoked via trap EXIT — shellcheck can't see that
cleanup() { rm -rf "$TMP_BASE"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helper: run cc-policy evaluate quick in an isolated env
# ---------------------------------------------------------------------------

run_quick() {
    local repo_dir="$1"
    local db_path="$2"
    local wf_id="$3"
    CLAUDE_POLICY_DB="$db_path" python3 "$RUNTIME_ROOT/cli.py" \
        evaluate quick \
        --project-root "$repo_dir" \
        --workflow-id "$wf_id"
}

# ---------------------------------------------------------------------------
# Helper: assert evaluation_state was written with ready_for_guardian
# ---------------------------------------------------------------------------

assert_eval_ready() {
    local db_path="$1"
    local wf_id="$2"
    local row
    row=$(CLAUDE_POLICY_DB="$db_path" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation get "$wf_id" 2>/dev/null)
    local status
    status=$(printf '%s' "$row" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null || echo "")
    if [[ "$status" != "ready_for_guardian" ]]; then
        echo "  ASSERTION FAILED: expected evaluation_state=ready_for_guardian for $wf_id, got '$status'"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Helper: assert evaluation_state was NOT written
# ---------------------------------------------------------------------------

assert_eval_absent() {
    local db_path="$1"
    local wf_id="$2"
    local row
    row=$(CLAUDE_POLICY_DB="$db_path" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation get "$wf_id" 2>/dev/null)
    # evaluation get returns {"found": false, ...} when no row exists in the DB.
    local found
    found=$(printf '%s' "$row" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('found', False))" 2>/dev/null || echo "False")
    if [[ "$found" == "True" ]]; then
        echo "  ASSERTION FAILED: evaluation_state must not exist for $wf_id but found=True"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# init_repo: create a fresh git repo with initial commit
# ---------------------------------------------------------------------------

init_repo() {
    local dir="$1"
    mkdir -p "$dir/.claude"
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" commit --allow-empty -m "init" -q
    # Ensure schema in isolated DB
    CLAUDE_POLICY_DB="$dir/.claude/state.db" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Case A: Small non-source change → eligible, eval state written
# ---------------------------------------------------------------------------

case_a_dir="$TMP_BASE/case-a"
case_a_db="$case_a_dir/.claude/state.db"

init_repo "$case_a_dir"

# Make a small change to a .md file (< 50 lines) and stage it.
# git diff HEAD only shows staged or tracked-modified files; untracked files
# are invisible to it, so we must stage before calling evaluate quick.
printf '# Notes\n\nThis is a test note added for Case A.\nIt is small enough for the STFP gate.\n' \
    > "$case_a_dir/NOTES.md"
git -C "$case_a_dir" add NOTES.md

output_a=$(run_quick "$case_a_dir" "$case_a_db" "wf-case-a" 2>&1)
exit_a=$?

if [[ $exit_a -eq 0 ]]; then
    if assert_eval_ready "$case_a_db" "wf-case-a"; then
        echo "PASS: Case A — small .md change → eligible, eval written"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "FAIL: Case A — exit 0 but eval_state not ready_for_guardian"
        echo "  output: $output_a"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    echo "FAIL: Case A — expected exit 0, got $exit_a"
    echo "  output: $output_a"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ---------------------------------------------------------------------------
# Case B: Source file change → not eligible, exit 1
# ---------------------------------------------------------------------------

case_b_dir="$TMP_BASE/case-b"
case_b_db="$case_b_dir/.claude/state.db"

init_repo "$case_b_dir"

# Write a .py file (source) and leave it unstaged → diff against HEAD shows it
# Use git diff HEAD which also covers unstaged changes to tracked files.
# Stage it so git diff HEAD sees it.
cat > "$case_b_dir/mymodule.py" <<'EOF'
def hello():
    return "hello"
EOF
git -C "$case_b_dir" add mymodule.py

exit_b=0
output_b=$(run_quick "$case_b_dir" "$case_b_db" "wf-case-b" 2>&1) || exit_b=$?

if [[ $exit_b -ne 0 ]]; then
    if assert_eval_absent "$case_b_db" "wf-case-b"; then
        echo "PASS: Case B — .py source file → not eligible, exit 1, eval not written"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "FAIL: Case B — exit 1 but eval_state was written (must not be)"
        echo "  output: $output_b"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    echo "FAIL: Case B — expected exit 1 for source file, got exit 0"
    echo "  output: $output_b"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ---------------------------------------------------------------------------
# Case C: Too many lines → not eligible, exit 1
# ---------------------------------------------------------------------------

case_c_dir="$TMP_BASE/case-c"
case_c_db="$case_c_dir/.claude/state.db"

init_repo "$case_c_dir"

# Write a .md file with 60 lines → total lines changed > 50
python3 -c "
lines = ['# Big doc\n'] + [f'Line {i}\n' for i in range(1, 60)]
open('$case_c_dir/BIG.md', 'w').writelines(lines)
"
git -C "$case_c_dir" add BIG.md

exit_c=0
output_c=$(run_quick "$case_c_dir" "$case_c_db" "wf-case-c" 2>&1) || exit_c=$?

if [[ $exit_c -ne 0 ]]; then
    if assert_eval_absent "$case_c_db" "wf-case-c"; then
        echo "PASS: Case C — >50 lines → not eligible, exit 1, eval not written"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "FAIL: Case C — exit 1 but eval_state was written"
        echo "  output: $output_c"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    echo "FAIL: Case C — expected exit 1 for large diff, got exit 0"
    echo "  output: $output_c"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ---------------------------------------------------------------------------
# Case D: No changes → not eligible, exit 1
# ---------------------------------------------------------------------------

case_d_dir="$TMP_BASE/case-d"
case_d_db="$case_d_dir/.claude/state.db"

init_repo "$case_d_dir"
# No changes — working tree is clean after init

exit_d=0
output_d=$(run_quick "$case_d_dir" "$case_d_db" "wf-case-d" 2>&1) || exit_d=$?

if [[ $exit_d -ne 0 ]]; then
    if assert_eval_absent "$case_d_db" "wf-case-d"; then
        echo "PASS: Case D — no changes → not eligible, exit 1, eval not written"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "FAIL: Case D — exit 1 but eval_state was written"
        echo "  output: $output_d"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    echo "FAIL: Case D — expected exit 1 for empty diff, got exit 0"
    echo "  output: $output_d"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi

exit 0
