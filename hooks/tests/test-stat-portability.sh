#!/usr/bin/env bash
# Regression test for DEC-CONTEXT-LIB-STAT-PORTABILITY-001
# @decision DEC-TEST-CTX-STAT-001
# @title Regression: stat -f on GNU/Windows returns filesystem text not mtime epoch
# @status accepted
# @rationale Covers: (1) get_plan_status no unbound-variable + integer outputs;
#   (2) numeric guard logic with simulated bad-stat output; (3) file_mtime()
#   returns clean integer; (4) session-init.sh full chain no unbound variable.

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_integer() {
    local name="$1" val="$2"
    if [[ "$val" =~ ^[0-9]+$ ]]; then pass "$name is integer: $val";
    else fail "$name is NOT integer: $(printf '%q' "$val")"; fi
}
assert_no_unbound() {
    local name="$1" s="$2"
    if [[ "$s" != *"unbound variable"* ]]; then pass "$name: no unbound variable";
    else fail "$name: unbound variable on stderr: $s"; fi
}
assert_not_has() {
    local name="$1" h="$2" n="$3"
    if [[ "$h" != *"$n"* ]]; then pass "$name does not contain: $n";
    else fail "$name CONTAINS: $n"; fi
}

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT
GIT_OPTS=(-c user.email="t@t.com" -c user.name="T")

REPO="$TMPDIR_BASE/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" "${GIT_OPTS[@]}" commit --allow-empty -m "init" -q
printf '%s
' '# Plan' '' '## Phase 1' '**Status:** completed' > "$REPO/MASTER_PLAN.md"

detect_project_root() { echo "${_TEST_ROOT:-$PWD}"; }
export -f detect_project_root
source "$HOOKS_DIR/context-lib.sh"

echo ""
echo "=== Scenario A: get_plan_status -- integer outputs, no unbound variable ==="
_TEST_ROOT="$REPO"
CAPS=$(get_plan_status "$REPO" 2>&1 >/dev/null)
get_plan_status "$REPO"
assert_no_unbound "get_plan_status" "$CAPS"
assert_integer "PLAN_AGE_DAYS" "$PLAN_AGE_DAYS"
assert_integer "PLAN_TOTAL_PHASES" "$PLAN_TOTAL_PHASES"
assert_integer "PLAN_COMPLETED_PHASES" "$PLAN_COMPLETED_PHASES"
assert_integer "PLAN_IN_PROGRESS_PHASES" "$PLAN_IN_PROGRESS_PHASES"
assert_integer "PLAN_COMMITS_SINCE" "$PLAN_COMMITS_SINCE"
[[ "$PLAN_EXISTS" == "true" ]] && pass "PLAN_EXISTS=true" || fail "PLAN_EXISTS not true"
[[ "$PLAN_AGE_DAYS" -le 1 ]] && pass "PLAN_AGE_DAYS reasonable" || fail "PLAN_AGE_DAYS too large: $PLAN_AGE_DAYS"

echo ""
echo "=== Scenario B: numeric guard forces bad stat output to 0 ==="
# Simulate Windows git bash stat -f output (GNU stat --file-system output):
BAD="  File: /c/Users/foo/MASTER_PLAN.md  ID: 0 Namelen: 255 Type: NTFS"
PM="$BAD"
[[ "$PM" =~ ^[0-9]+$ ]] || PM=0
[[ "$PM" =~ ^[0-9]+$ ]] && pass "guard result is integer" || fail "guard result not integer"
[[ "$PM" -eq 0 ]] && pass "bad stat output forced to 0" || fail "expected 0, got: $PM"
# The File: prefix was the exact token that caused set -u crash:
SFP="File: some/path"
[[ "$SFP" =~ ^[0-9]+$ ]] || SFP=0
[[ "$SFP" -gt 0 ]] 2>/dev/null && fail "guard should have given 0" || pass "File: prefix guarded correctly"

echo ""
echo "=== Scenario C: file_mtime() -- clean integer ==="
MERR="$TMPDIR_BASE/merr"
MOUT=$(file_mtime "$REPO/MASTER_PLAN.md" 2>"$MERR")
MERRC=$(cat "$MERR" 2>/dev/null || true); rm -f "$MERR"
assert_integer "file_mtime output" "$MOUT"
assert_no_unbound "file_mtime" "$MERRC"
[[ "$MOUT" -gt 0 ]] && pass "file_mtime positive epoch" || fail "expected positive epoch, got: $MOUT"
MMISS=$(file_mtime "$REPO/NO_SUCH_FILE" 2>/dev/null)
assert_integer "file_mtime missing file" "$MMISS"
[[ "$MMISS" -eq 0 ]] && pass "file_mtime missing=0" || fail "expected 0, got: $MMISS"

echo ""
echo "=== Scenario D: session-init.sh -- full chain no unbound variable ==="
HERR="$TMPDIR_BASE/herr"
SESSION_JSON="{"session_id":"t","cwd":"$REPO","hook_event_name":"SessionStart"}"
HOUT=$(printf '%s' "$SESSION_JSON" | CLAUDE_PROJECT_DIR="$REPO" bash "$HOOKS_DIR/session-init.sh" 2>"$HERR")
HEXIT=$?
HERRC=$(cat "$HERR"); rm -f "$HERR"
[[ "$HEXIT" -eq 0 ]] && pass "session-init exits 0" || fail "session-init exits $HEXIT"
assert_no_unbound "session-init.sh" "$HERRC"
assert_not_has "session-init stderr" "$HERRC" "File: unbound variable"
[[ -n "$HERRC" ]] && { echo "    stderr:"; echo "$HERRC" | head -3 | sed "s/^/    /"; }

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
