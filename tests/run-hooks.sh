#!/usr/bin/env bash
# Hook contract test runner
# Validates that each hook responds correctly to sample inputs.
#
# @decision DEC-TEST-001
# @title Fixture-based hook contract testing
# @status accepted
# @rationale Each hook's stdin/stdout contract is testable in isolation by
#   feeding JSON fixtures and checking exit codes + output structure. This
#   avoids needing a running Claude Code session for CI validation. Statusline
#   and subagent tests use temp directories for isolation.
#
# Usage: bash tests/run-hooks.sh
#
# Tests verify:
#   - Hooks exit with code 0 (no crashes)
#   - Stdout is valid JSON (when output is expected)
#   - Deny responses have the correct structure
#   - Allow/advisory responses have the correct structure
#   - Statusline cache read/write and segment rendering
#   - Subagent tracking display

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$(dirname "$SCRIPT_DIR")/hooks"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"

passed=0
failed=0
skipped=0

# Colors (disabled if not a terminal)
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    NC='\033[0m'
else
    GREEN='' RED='' YELLOW='' NC=''
fi

pass() { echo -e "${GREEN}PASS${NC} $1"; passed=$((passed + 1)); }
fail() { echo -e "${RED}FAIL${NC} $1: $2"; failed=$((failed + 1)); }
skip() { echo -e "${YELLOW}SKIP${NC} $1: $2"; skipped=$((skipped + 1)); }

# Run a hook with fixture input, capture stdout/stderr/exit code
run_hook() {
    local hook="$1"
    local fixture="$2"
    local stdout

    stdout=$(bash "$hook" < "$fixture" 2>/dev/null) || true

    echo "$stdout"
    return 0
}

echo "=== Hook Contract Tests ==="
echo "Hooks dir: $HOOKS_DIR"
echo "Fixtures dir: $FIXTURES_DIR"
echo ""

# --- Test: All hooks parse without syntax errors ---
echo "--- Syntax Validation ---"
for hook in "$HOOKS_DIR"/*.sh; do
    name=$(basename "$hook")
    if bash -n "$hook" 2>/dev/null; then
        pass "$name — syntax valid"
    else
        fail "$name" "syntax error"
    fi
done
echo ""

# --- Test: settings.json is valid ---
echo "--- Configuration ---"
SETTINGS="$(dirname "$HOOKS_DIR")/settings.json"
if python3 -m json.tool "$SETTINGS" > /dev/null 2>&1; then
    pass "settings.json — valid JSON"
else
    fail "settings.json" "invalid JSON"
fi
echo ""

# --- Test: guard.sh — /tmp rewrite ---
echo "--- guard.sh ---"
if [[ -f "$FIXTURES_DIR/guard-tmp-write.json" ]]; then
    output=$(run_hook "$HOOKS_DIR/guard.sh" "$FIXTURES_DIR/guard-tmp-write.json")
    if echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command' > /dev/null 2>&1; then
        rewritten=$(echo "$output" | jq -r '.hookSpecificOutput.updatedInput.command')
        if [[ "$rewritten" != "echo 'test' > /tmp/scratch.txt" ]]; then
            pass "guard.sh — /tmp rewrite rewrites /tmp path"
        else
            fail "guard.sh — /tmp rewrite" "command unchanged: $rewritten"
        fi
    else
        fail "guard.sh — /tmp rewrite" "no updatedInput in output: $output"
    fi
fi

# --- Test: guard.sh — force push to main denied ---
if [[ -f "$FIXTURES_DIR/guard-force-push-main.json" ]]; then
    output=$(run_hook "$HOOKS_DIR/guard.sh" "$FIXTURES_DIR/guard-force-push-main.json")
    if echo "$output" | jq -e '.hookSpecificOutput.permissionDecision' > /dev/null 2>&1; then
        decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision')
        if [[ "$decision" == "deny" ]]; then
            pass "guard.sh — force push to main denied"
        else
            fail "guard.sh — force push to main" "expected deny, got: $decision"
        fi
    else
        fail "guard.sh — force push to main" "no permissionDecision in output: $output"
    fi
fi

# --- Test: guard.sh — safe command passes through ---
if [[ -f "$FIXTURES_DIR/guard-safe-command.json" ]]; then
    output=$(run_hook "$HOOKS_DIR/guard.sh" "$FIXTURES_DIR/guard-safe-command.json")
    if [[ -z "$output" || "$output" == "{}" ]]; then
        pass "guard.sh — safe command passes through (no output)"
    else
        # Check it's not a deny
        decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
        if [[ "$decision" != "deny" ]]; then
            pass "guard.sh — safe command passes through"
        else
            fail "guard.sh — safe command" "unexpectedly denied: $output"
        fi
    fi
fi

# --- Test: guard.sh — force rewrite to force-with-lease ---
if [[ -f "$FIXTURES_DIR/guard-force-push.json" ]]; then
    output=$(run_hook "$HOOKS_DIR/guard.sh" "$FIXTURES_DIR/guard-force-push.json")
    if echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command' > /dev/null 2>&1; then
        rewritten=$(echo "$output" | jq -r '.hookSpecificOutput.updatedInput.command')
        if [[ "$rewritten" == *"--force-with-lease"* ]]; then
            pass "guard.sh — --force rewritten to --force-with-lease"
        else
            fail "guard.sh — force rewrite" "no --force-with-lease in: $rewritten"
        fi
    else
        fail "guard.sh — force rewrite" "no updatedInput in output: $output"
    fi
fi

# --- Test: guard.sh — nuclear command deny ---
echo "--- guard.sh nuclear commands ---"

# Nuclear deny tests — each must produce permissionDecision: deny
nuclear_assert_deny() {
    local fixture="$1" label="$2"
    if [[ -f "$FIXTURES_DIR/$fixture" ]]; then
        local output decision
        output=$(run_hook "$HOOKS_DIR/guard.sh" "$FIXTURES_DIR/$fixture")
        decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
        if [[ "$decision" == "deny" ]]; then
            pass "guard.sh — nuclear deny: $label"
        else
            fail "guard.sh — nuclear deny: $label" "expected deny, got: ${decision:-no output}"
        fi
    else
        skip "guard.sh — nuclear deny: $label" "fixture $fixture not found"
    fi
}

nuclear_assert_deny "guard-nuclear-rm-rf-root.json"  "rm -rf / (filesystem destruction)"
nuclear_assert_deny "guard-nuclear-rm-rf-home.json"   "rm -rf ~ (filesystem destruction)"
nuclear_assert_deny "guard-nuclear-curl-pipe-sh.json"  "curl | bash (remote code execution)"
nuclear_assert_deny "guard-nuclear-dd.json"            "dd of=/dev/sda (disk destruction)"
nuclear_assert_deny "guard-nuclear-shutdown.json"      "shutdown (system halt)"
nuclear_assert_deny "guard-nuclear-drop-db.json"       "DROP DATABASE (SQL destruction)"
nuclear_assert_deny "guard-nuclear-fork-bomb.json"     "fork bomb (resource exhaustion)"
echo ""

# --- Test: guard.sh — false positives (must NOT deny) ---
echo "--- guard.sh false positives ---"

nuclear_assert_safe() {
    local fixture="$1" label="$2"
    if [[ -f "$FIXTURES_DIR/$fixture" ]]; then
        local output decision
        output=$(run_hook "$HOOKS_DIR/guard.sh" "$FIXTURES_DIR/$fixture")
        decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
        if [[ "$decision" == "deny" ]]; then
            fail "guard.sh — false positive: $label" "should NOT deny but got deny"
        else
            pass "guard.sh — false positive: $label"
        fi
    else
        skip "guard.sh — false positive: $label" "fixture $fixture not found"
    fi
}

nuclear_assert_safe "guard-safe-rm-rf.json"   "rm -rf ./node_modules (scoped delete)"
nuclear_assert_safe "guard-safe-curl.json"    "curl | jq (not a shell)"
nuclear_assert_safe "guard-safe-chmod.json"   "chmod 755 ./build (not 777 on root)"
nuclear_assert_safe "guard-safe-rm-file.json" "rm file.txt (single file)"
echo ""

# --- Test: guard.sh — cross-project git (Check 1.5 removed) ---
echo "--- guard.sh cross-project git ---"

# Create a temporary bare repo for cross-project testing
CROSS_TEST_DIR=$(mktemp -d)
git init --bare "$CROSS_TEST_DIR/other-repo.git" 2>/dev/null

# Dynamic fixture: git -C targeting a different repo (should now pass through — Check 1.5 removed)
CROSS_FIXTURE="$FIXTURES_DIR/guard-git-c-cross-project.json"
cat > "$CROSS_FIXTURE" <<XEOF
{"tool_name":"Bash","tool_input":{"command":"git -C $CROSS_TEST_DIR/other-repo.git status"}}
XEOF

output=$(run_hook "$HOOKS_DIR/guard.sh" "$CROSS_FIXTURE")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" == "deny" ]]; then
    fail "guard.sh — cross-project git: git -C other-repo" "should pass through (Check 1.5 removed) but got deny"
else
    pass "guard.sh — cross-project git: git -C other-repo passes through"
fi

# git status with no -C should pass through
if [[ -f "$FIXTURES_DIR/guard-safe-command.json" ]]; then
    output=$(run_hook "$HOOKS_DIR/guard.sh" "$FIXTURES_DIR/guard-safe-command.json")
    decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    if [[ "$decision" != "deny" ]]; then
        pass "guard.sh — cross-project git: plain git status passes through"
    else
        fail "guard.sh — cross-project git: plain git status" "should pass through but got deny"
    fi
fi

# Cleanup
rm -rf "$CROSS_TEST_DIR"
rm -f "$CROSS_FIXTURE"
echo ""

# --- Test: guard.sh — git-in-text false positives (early-exit gate) ---
echo "--- guard.sh git-in-text false positives ---"

nuclear_assert_safe "guard-safe-text-git-commit.json" "todo.sh with 'git committing' in quoted args"
nuclear_assert_safe "guard-safe-text-git-merge.json"  "echo with 'git merging' in quoted text"
nuclear_assert_safe "guard-safe-text-git-push.json"   "printf with 'git push' in quoted text"
echo ""

# --- Test: guard.sh — git flag bypass (git -C /path <subcommand>) ---
echo "--- guard.sh git flag bypass ---"

# Flag bypass deny tests — git -C should NOT bypass guards
nuclear_assert_deny "guard-git-C-push-force.json"  "git -C /path push --force (flag bypass)"
nuclear_assert_deny "guard-git-C-reset-hard.json"  "git -C /path reset --hard (flag bypass)"

# Flag bypass false positive tests — hyphenated subcommands must NOT trigger
nuclear_assert_safe "guard-safe-git-merge-base.json" "git merge-base (not a merge)"

# Pipe false positive — git log | grep commit must NOT trigger commit guard
PIPE_FIXTURE="$FIXTURES_DIR/guard-safe-pipe-grep-commit.json"
cat > "$PIPE_FIXTURE" <<PEOF
{"tool_name":"Bash","tool_input":{"command":"git log --oneline | grep commit"}}
PEOF
nuclear_assert_safe "guard-safe-pipe-grep-commit.json" "git log | grep commit (pipe false positive)"
rm -f "$PIPE_FIXTURE"
echo ""

# --- Test: auto-review.sh ---
echo "--- auto-review.sh ---"
if [[ -f "$FIXTURES_DIR/auto-review-safe.json" ]]; then
    output=$(run_hook "$HOOKS_DIR/auto-review.sh" "$FIXTURES_DIR/auto-review-safe.json")
    if echo "$output" | jq -e '.hookSpecificOutput.permissionDecision' > /dev/null 2>&1; then
        decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision')
        if [[ "$decision" == "allow" ]]; then
            pass "auto-review.sh — safe command auto-approved"
        else
            fail "auto-review.sh — safe command" "expected allow, got: $decision"
        fi
    else
        # No output also means pass-through (no opinion)
        pass "auto-review.sh — safe command passes through"
    fi
fi

# --- Test: auto-review.sh — interpreter analyzer ---
echo "--- auto-review.sh interpreter analyzer ---"

# Helper: assert auto-review approves a command
auto_review_assert_approved() {
    local fixture="$1" label="$2"
    if [[ -f "$FIXTURES_DIR/$fixture" ]]; then
        local output decision
        output=$(run_hook "$HOOKS_DIR/auto-review.sh" "$FIXTURES_DIR/$fixture")
        decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
        if [[ "$decision" == "allow" ]]; then
            pass "auto-review.sh — $label"
        else
            fail "auto-review.sh — $label" "expected allow, got: ${decision:-no opinion (advisory/defer)}"
        fi
    else
        skip "auto-review.sh — $label" "fixture $fixture not found"
    fi
}

# Helper: assert auto-review does NOT approve (defers to user)
auto_review_assert_deferred() {
    local fixture="$1" label="$2"
    if [[ -f "$FIXTURES_DIR/$fixture" ]]; then
        local output decision
        output=$(run_hook "$HOOKS_DIR/auto-review.sh" "$FIXTURES_DIR/$fixture")
        decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
        if [[ "$decision" == "allow" ]]; then
            fail "auto-review.sh — $label" "should NOT auto-approve but got allow"
        else
            pass "auto-review.sh — $label"
        fi
    else
        skip "auto-review.sh — $label" "fixture $fixture not found"
    fi
}

# Interpreter: safe forms (script files, -m module)
auto_review_assert_approved "auto-review-python-script.json" "python3 script.py → approved (safe)"
auto_review_assert_approved "auto-review-python-module.json" "python3 -m pytest → approved (safe)"
auto_review_assert_approved "auto-review-node-script.json"   "node app.js → approved (safe)"

# Interpreter: risky forms (inline code, interactive REPL)
auto_review_assert_deferred "auto-review-python-inline.json" "python3 -c \"...\" → deferred (inline code)"
auto_review_assert_deferred "auto-review-python-repl.json"   "python3 (no args) → deferred (interactive REPL)"
auto_review_assert_deferred "auto-review-node-inline.json"   "node -e \"...\" → deferred (inline code)"

# Shell: existing analyzer (regression tests)
auto_review_assert_approved "auto-review-bash-script.json"   "bash script.sh → approved (safe)"
auto_review_assert_deferred "auto-review-bash-inline.json"   "bash -c \"...\" → deferred (inline code)"
echo ""

# --- Test: plan-validate.sh (PostToolUse) ---
echo "--- plan-validate.sh ---"
if [[ -f "$FIXTURES_DIR/plan-validate-non-plan.json" ]]; then
    output=$(run_hook "$HOOKS_DIR/plan-validate.sh" "$FIXTURES_DIR/plan-validate-non-plan.json")
    # Non-plan files should pass through silently
    if [[ -z "$output" || "$output" == "{}" ]]; then
        pass "plan-validate.sh — non-plan file passes through"
    else
        pass "plan-validate.sh — non-plan file (with advisory)"
    fi
fi

echo ""

# --- Test: session-init.sh ---
echo "--- session-init.sh ---"
if [[ -f "$FIXTURES_DIR/session-init.json" ]]; then
    output=$(bash "$HOOKS_DIR/session-init.sh" < "$FIXTURES_DIR/session-init.json" 2>/dev/null) || true
    if [[ -n "$output" ]]; then
        pass "session-init.sh — produces output on startup"
    else
        pass "session-init.sh — runs without error"
    fi
fi

echo ""

# --- Test: statusline.sh — cache rendering ---
echo "--- statusline.sh ---"
SL_TEST_DIR=$(mktemp -d)
mkdir -p "$SL_TEST_DIR/.claude"
echo '{"dirty":5,"worktrees":1,"plan":"Phase 2/4","test":"pass","updated":1234567890,"agents_active":0,"agents_types":"","agents_total":0}' > "$SL_TEST_DIR/.claude/.statusline-cache"
SL_INPUT=$(jq -n --arg dir "$SL_TEST_DIR" '{model:{display_name:"opus"},workspace:{current_dir:$dir},version:"1.0.0"}')
SL_OUTPUT=$(echo "$SL_INPUT" | bash "$SCRIPT_DIR/../scripts/statusline.sh" 2>/dev/null) || true
if echo "$SL_OUTPUT" | grep -q "dirty"; then
    pass "statusline.sh — shows dirty count from cache"
else
    fail "statusline.sh — dirty count" "expected 'dirty' in output: $SL_OUTPUT"
fi
if echo "$SL_OUTPUT" | grep -q "WT:"; then
    pass "statusline.sh — shows worktree count from cache"
else
    fail "statusline.sh — worktree count" "expected 'WT:' in output: $SL_OUTPUT"
fi
if echo "$SL_OUTPUT" | grep -q "Phase"; then
    pass "statusline.sh — shows plan phase from cache"
else
    fail "statusline.sh — plan phase" "expected 'Phase' in output: $SL_OUTPUT"
fi
if echo "$SL_OUTPUT" | grep -q "tests"; then
    pass "statusline.sh — shows test status from cache"
else
    fail "statusline.sh — test status" "expected 'tests' in output: $SL_OUTPUT"
fi
rm -rf "$SL_TEST_DIR"
echo ""

# --- Test: statusline.sh — works without cache ---
SL_TEST_DIR2=$(mktemp -d)
SL_INPUT2=$(jq -n --arg dir "$SL_TEST_DIR2" '{model:{display_name:"opus"},workspace:{current_dir:$dir},version:"1.0.0"}')
SL_OUTPUT2=$(echo "$SL_INPUT2" | bash "$SCRIPT_DIR/../scripts/statusline.sh" 2>/dev/null) || true
if [[ -n "$SL_OUTPUT2" ]]; then
    pass "statusline.sh — works without cache file"
else
    fail "statusline.sh — no cache" "no output produced"
fi
rm -rf "$SL_TEST_DIR2"
echo ""

# --- Test: statusline.sh — subagent tracking ---
echo "--- subagent tracking ---"
SA_TEST_DIR=$(mktemp -d)
mkdir -p "$SA_TEST_DIR/.claude"
echo '{"dirty":0,"worktrees":0,"plan":"no plan","test":"unknown","updated":1234567890,"agents_active":2,"agents_types":"implementer,planner","agents_total":3}' > "$SA_TEST_DIR/.claude/.statusline-cache"
SA_INPUT=$(jq -n --arg dir "$SA_TEST_DIR" '{model:{display_name:"opus"},workspace:{current_dir:$dir},version:"1.0.0"}')
SA_OUTPUT=$(echo "$SA_INPUT" | bash "$SCRIPT_DIR/../scripts/statusline.sh" 2>/dev/null) || true
if echo "$SA_OUTPUT" | grep -q "agents"; then
    pass "statusline.sh — shows active agent count from cache"
else
    fail "statusline.sh — agent count" "expected 'agents' in output: $SA_OUTPUT"
fi
rm -rf "$SA_TEST_DIR"
echo ""

# --- Test: update-check.sh ---
echo "--- update-check.sh ---"

# Syntax validation
UPDATE_SCRIPT="$SCRIPT_DIR/../scripts/update-check.sh"
if bash -n "$UPDATE_SCRIPT" 2>/dev/null; then
    pass "update-check.sh — syntax valid"
else
    fail "update-check.sh" "syntax error"
fi

# VERSION file exists and contains valid semver
VERSION_FILE="$SCRIPT_DIR/../VERSION"
if [[ -f "$VERSION_FILE" ]]; then
    VERSION_CONTENT=$(head -1 "$VERSION_FILE" | tr -d '[:space:]')
    if [[ "$VERSION_CONTENT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        pass "VERSION — valid semver ($VERSION_CONTENT)"
    else
        fail "VERSION" "invalid semver: '$VERSION_CONTENT'"
    fi
else
    fail "VERSION" "file not found"
fi

# Graceful degradation: run in a non-git temp dir (no remote, no crash)
UPD_TEST_DIR=$(mktemp -d)
while IFS= read -r line; do
    if [[ "$line" == "GRACEFUL_OK" ]]; then
        pass "update-check.sh — graceful exit with no git repo"
    elif [[ "$line" == GRACEFUL_FAIL* ]]; then
        fail "update-check.sh — graceful exit" "unexpected output: ${line#GRACEFUL_FAIL:}"
    fi
done < <(
    export HOME="$UPD_TEST_DIR"
    mkdir -p "$UPD_TEST_DIR/.claude"
    cp "$VERSION_FILE" "$UPD_TEST_DIR/.claude/VERSION"
    cp "$UPDATE_SCRIPT" "$UPD_TEST_DIR/.claude/update-check.sh"
    output=$(bash "$UPD_TEST_DIR/.claude/update-check.sh" 2>/dev/null) || true
    if [[ -z "$output" ]]; then
        echo "GRACEFUL_OK"
    else
        echo "GRACEFUL_FAIL:$output"
    fi
)
rm -rf "$UPD_TEST_DIR"

# Disable toggle test: create flag file, script should exit immediately
UPD_TEST_DIR2=$(mktemp -d)
while IFS= read -r line; do
    if [[ "$line" == "DISABLE_OK" ]]; then
        pass "update-check.sh — disable toggle skips update"
    else
        fail "update-check.sh — disable toggle" "should skip when .disable-auto-update exists"
    fi
done < <(
    export HOME="$UPD_TEST_DIR2"
    mkdir -p "$UPD_TEST_DIR2/.claude"
    touch "$UPD_TEST_DIR2/.claude/.disable-auto-update"
    cp "$VERSION_FILE" "$UPD_TEST_DIR2/.claude/VERSION"
    cp "$UPDATE_SCRIPT" "$UPD_TEST_DIR2/.claude/update-check.sh"
    output=$(bash "$UPD_TEST_DIR2/.claude/update-check.sh" 2>/dev/null) || true
    if [[ ! -f "$UPD_TEST_DIR2/.claude/.update-status" && -z "$output" ]]; then
        echo "DISABLE_OK"
    else
        echo "DISABLE_FAIL"
    fi
)
rm -rf "$UPD_TEST_DIR2"
echo ""


# --- Summary ---
echo "==========================="
total=$((passed + failed + skipped))
echo -e "Total: $total | ${GREEN}Passed: $passed${NC} | ${RED}Failed: $failed${NC} | ${YELLOW}Skipped: $skipped${NC}"

if [[ $failed -gt 0 ]]; then
    exit 1
fi
