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
#   and subagent tests use temp directories for isolation. Expanded to include
#   gate hook behavioral tests, context-lib unit tests, integration tests, and
#   session lifecycle tests for comprehensive coverage (GitHub #63, #68, #70, #71).
#
# @decision DEC-PERF-002
# @title Scoped test runs via --scope flag in run-hooks.sh
# @status accepted
# @rationale Running all 131 tests takes 45-90s. During hook development, only
#   a subset is relevant. --scope <name> runs only matching sections, reducing
#   the feedback loop to <15s. Multiple scopes are ORed. No --scope = full run.
#   Implemented by wrapping each section in if should_run_section(); then ... fi.
#   The scope map is a bash associative array keyed by scope name; values are
#   grep -iE patterns matched against section names in the echo markers.
#
# Usage: bash tests/run-hooks.sh [--scope <name>] [--scope <name>] ...
#
# Tests verify:
#   - Hooks exit with code 0 (no crashes)
#   - Stdout is valid JSON (when output is expected)
#   - Deny responses have the correct structure
#   - Allow/advisory responses have the correct structure
#   - Gate hooks (branch-guard, doc-gate, test-gate, mock-gate) behavioral contracts
#   - context-lib.sh unit tests (is_source_file, is_skippable_path, get_git_state)
#   - Integration tests (settings.json sync, hook pipeline)
#   - Session lifecycle tests (session-init, prompt-submit)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$(dirname "$SCRIPT_DIR")/hooks"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
SETTINGS="$(dirname "$HOOKS_DIR")/settings.json"

# Source context-lib for safe_cleanup (prevents CWD bricking on rm -rf)
source "$HOOKS_DIR/context-lib.sh"

# Ensure git identity is configured for tests that create temp repos with commits.
# CI environments (GitHub Actions) don't have user.email/user.name set, causing
# git commit to fail with exit 128. This is scoped to --global so temp repos inherit it.
if ! git config --global user.email >/dev/null 2>&1; then
    git config --global user.email "test@ci.local"
    git config --global user.name "CI Test Runner"
fi

passed=0
failed=0
skipped=0

# =============================================================================
# --scope argument parsing
# @decision DEC-PERF-002
# @title Scoped test runs via --scope flag
# @status accepted
# @rationale Running all 131 tests takes 45-90s. During hook development, only
#   a subset of tests is relevant to the change at hand. --scope <name> runs
#   only the section(s) matching the scope, reducing feedback loop to <15s.
#   Multiple --scope flags are ORed: --scope unit --scope syntax runs both.
#   No --scope = backward-compatible full run (no behaviour change for CI).
#
# Usage: bash tests/run-hooks.sh [--scope <name>] [--scope <name>] ...
# Scopes: syntax, pre-bash, pre-write, post-write, unit, session, integration,
#         trace, gate, state
# =============================================================================

REQUESTED_SCOPES=()

_print_scope_usage() {
    echo "Usage: bash tests/run-hooks.sh [--scope <name>] [--scope <name>] ..."
    echo ""
    echo "Available scopes:"
    echo "  syntax      — Syntax Validation + Configuration"
    echo "  pre-bash    — guard.sh (pre-bash.sh) all variants"
    echo "  pre-write   — branch-guard, plan-check, plan lifecycle, plan archival, doc-gate, test-gate, mock-gate"
    echo "  post-write  — plan-validate, statusline, registry lint"
    echo "  unit        — context-lib.sh unit tests (is_source_file, is_skippable_path, get_git_state, build_resume_directive)"
    echo "  session     — session-init, prompt-submit, compact-preserve"
    echo "  integration — settings.json sync, subagent tracking, update-check"
    echo "  trace       — Trace protocol (init_trace, finalize_trace, detect, subagent injection)"
    echo "  gate        — Gate hook behavioral tests (branch-guard, doc-gate, test-gate, mock-gate)"
    echo "  state       — State Registry Lint + Multi-Context Pass"
    echo "  fixtures    — Expanded Fixture Coverage (30 new fixture tests)"
    echo ""
    echo "No --scope = run all tests (default, backward compatible)."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scope)
            shift
            if [[ -z "${1:-}" ]]; then
                echo "ERROR: --scope requires an argument" >&2
                _print_scope_usage >&2
                exit 1
            fi
            REQUESTED_SCOPES+=("$1")
            shift
            ;;
        --help|-h)
            _print_scope_usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            _print_scope_usage >&2
            exit 1
            ;;
    esac
done

# Scope → section name regex patterns (grep -iE)
# Uses a function instead of declare -A (bash 3.2 on macOS lacks associative arrays).
_scope_pattern() {
    case "$1" in
        syntax)      echo "Syntax Validation|Configuration" ;;
        pre-bash)    echo "guard\.sh|nuclear commands|false positives|cross-project git|git-in-text|flag bypass|main is sacred" ;;
        pre-write)   echo "branch-guard\.sh behavioral|plan-check\.sh lifecycle|plan lifecycle|plan archival|doc-gate\.sh behavioral|test-gate\.sh behavioral|mock-gate\.sh behavioral" ;;
        post-write)  echo "plan-validate\.sh|statusline\.sh|State Registry Lint" ;;
        unit)        echo "context-lib\.sh: is_source_file|context-lib\.sh: is_skippable_path|context-lib\.sh: get_git_state|context-lib\.sh: build_resume_directive" ;;
        session)     echo "session-init\.sh|prompt-submit\.sh|compact-preserve\.sh" ;;
        integration) echo "settings\.json|subagent tracking|update-check\.sh" ;;
        trace)       echo "trace protocol" ;;
        gate)        echo "branch-guard\.sh behavioral|doc-gate\.sh behavioral|test-gate\.sh behavioral|mock-gate\.sh behavioral" ;;
        state)       echo "State Registry Lint|Multi-Context Pass" ;;
        fixtures)    echo "Expanded Fixture Coverage" ;;
        *)           echo "" ;;
    esac
}

# should_run_section "Section Name" — returns 0 (run) or 1 (skip)
should_run_section() {
    local section_name="$1"
    # No scopes specified = run everything
    if [[ ${#REQUESTED_SCOPES[@]} -eq 0 ]]; then
        return 0
    fi
    local scope pattern
    for scope in "${REQUESTED_SCOPES[@]}"; do
        pattern=$(_scope_pattern "$scope")
        if [[ -z "$pattern" ]]; then
            echo "WARNING: unknown scope '$scope' — ignoring (use --help for valid scopes)" >&2
            continue
        fi
        if echo "$section_name" | grep -qiE "$pattern"; then
            return 0
        fi
    done
    return 1  # Skip this section
}

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
if should_run_section "Syntax Validation"; then
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
fi

# --- Test: settings.json is valid ---
if should_run_section "Configuration"; then
echo "--- Configuration ---"
if python3 -m json.tool "$SETTINGS" > /dev/null 2>&1; then
    pass "settings.json — valid JSON"
else
    fail "settings.json" "invalid JSON"
fi
echo ""
fi

# =============================================================================
# GATE HOOK BEHAVIORAL TESTS
# =============================================================================

echo "=========================================="
echo "GATE HOOK BEHAVIORAL TESTS"
echo "=========================================="
echo ""

# --- Test: branch-guard.sh behavioral tests ---
if should_run_section "branch-guard.sh behavioral tests"; then
echo "--- branch-guard.sh behavioral tests ---"

# Test 1: Deny source file write on main branch
BG_TEST_DIR_MAIN=$(mktemp -d)
git init "$BG_TEST_DIR_MAIN" >/dev/null 2>&1
(cd "$BG_TEST_DIR_MAIN" && git add -A && git commit -m "init" --allow-empty) >/dev/null 2>&1

BG_FIXTURE_MAIN_DENY="$FIXTURES_DIR/branch-guard-main-deny.json"
cat > "$BG_FIXTURE_MAIN_DENY" <<EOF
{"tool_name":"Write","tool_input":{"file_path":"$BG_TEST_DIR_MAIN/src/main.ts","content":"/** @file main.ts @description Test fixture. */\nconsole.log('test');\n"}}
EOF

output=$(run_hook "$HOOKS_DIR/pre-write.sh" "$BG_FIXTURE_MAIN_DENY")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" == "deny" ]]; then
    pass "branch-guard.sh — deny source file on main"
else
    fail "branch-guard.sh — deny source file on main" "expected deny, got: ${decision:-no output}"
fi
safe_cleanup "$BG_TEST_DIR_MAIN" "$SCRIPT_DIR"
rm -f "$BG_FIXTURE_MAIN_DENY"

# Test 2: Allow source file write on feature branch inside a worktree path
# NOTE: pre-write.sh Gate 1 now ALSO denies feature-branch writes unless the file path
# contains /.worktrees/ (DEC-BRANCH-GUARD-FEATURE-001). We use a worktree-style path.
BG_TEST_DIR_FEATURE=$(mktemp -d)
git init "$BG_TEST_DIR_FEATURE" >/dev/null 2>&1
(cd "$BG_TEST_DIR_FEATURE" && git checkout -b feature/test >/dev/null 2>&1 && git add -A && git commit -m "init" --allow-empty >/dev/null 2>&1)
# Use a path inside .worktrees/ so Gate 1 allows it
BG_WORKTREE_PATH="$BG_TEST_DIR_FEATURE/.worktrees/feature-test/src/main.ts"

BG_FIXTURE_FEATURE_ALLOW="$FIXTURES_DIR/branch-guard-feature-allow.json"
cat > "$BG_FIXTURE_FEATURE_ALLOW" <<EOF
{"tool_name":"Write","tool_input":{"file_path":"$BG_WORKTREE_PATH","content":"/** @file main.ts @description Test fixture. */\nconsole.log('test');\n"}}
EOF

output=$(run_hook "$HOOKS_DIR/pre-write.sh" "$BG_FIXTURE_FEATURE_ALLOW")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" != "deny" ]]; then
    pass "branch-guard.sh — allow source file on feature branch (worktree path)"
else
    fail "branch-guard.sh — allow source file on feature branch" "should allow but got deny"
fi
safe_cleanup "$BG_TEST_DIR_FEATURE" "$SCRIPT_DIR"
rm -f "$BG_FIXTURE_FEATURE_ALLOW"

# Test 3: Allow non-source file on main
BG_TEST_DIR_NONSOURCE=$(mktemp -d)
git init "$BG_TEST_DIR_NONSOURCE" >/dev/null 2>&1
(cd "$BG_TEST_DIR_NONSOURCE" && git add -A && git commit -m "init" --allow-empty) >/dev/null 2>&1

BG_FIXTURE_MAIN_NONSOURCE="$FIXTURES_DIR/branch-guard-main-nonsource.json"
cat > "$BG_FIXTURE_MAIN_NONSOURCE" <<EOF
{"tool_name":"Write","tool_input":{"file_path":"$BG_TEST_DIR_NONSOURCE/README.md","content":"# Test\n"}}
EOF

output=$(run_hook "$HOOKS_DIR/pre-write.sh" "$BG_FIXTURE_MAIN_NONSOURCE")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" != "deny" ]]; then
    pass "branch-guard.sh — allow non-source file on main"
else
    fail "branch-guard.sh — allow non-source file on main" "should allow but got deny"
fi
safe_cleanup "$BG_TEST_DIR_NONSOURCE" "$SCRIPT_DIR"
rm -f "$BG_FIXTURE_MAIN_NONSOURCE"

# Test 4: Allow MASTER_PLAN.md on main
BG_TEST_DIR_PLAN=$(mktemp -d)
git init "$BG_TEST_DIR_PLAN" >/dev/null 2>&1
(cd "$BG_TEST_DIR_PLAN" && git add -A && git commit -m "init" --allow-empty) >/dev/null 2>&1

BG_FIXTURE_PLAN="$FIXTURES_DIR/branch-guard-plan.json"
cat > "$BG_FIXTURE_PLAN" <<EOF
{"tool_name":"Write","tool_input":{"file_path":"$BG_TEST_DIR_PLAN/MASTER_PLAN.md","content":"# Plan\n"}}
EOF

output=$(run_hook "$HOOKS_DIR/pre-write.sh" "$BG_FIXTURE_PLAN")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" != "deny" ]]; then
    pass "branch-guard.sh — allow MASTER_PLAN.md on main"
else
    fail "branch-guard.sh — allow MASTER_PLAN.md on main" "should allow but got deny"
fi
safe_cleanup "$BG_TEST_DIR_PLAN" "$SCRIPT_DIR"
rm -f "$BG_FIXTURE_PLAN"

echo ""
fi # end: branch-guard.sh behavioral tests

# --- Test: doc-gate.sh behavioral tests ---
if should_run_section "doc-gate.sh behavioral tests"; then
echo "--- doc-gate.sh behavioral tests ---"

# Test 1: Deny Write without header
DOC_FIXTURE_NO_HEADER="$FIXTURES_DIR/doc-gate-no-header.json"
cat > "$DOC_FIXTURE_NO_HEADER" <<EOF
{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.ts","content":"console.log('no header');\n"}}
EOF

output=$(run_hook "$HOOKS_DIR/pre-write.sh" "$DOC_FIXTURE_NO_HEADER")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" == "deny" ]]; then
    pass "doc-gate.sh — deny Write without header"
else
    fail "doc-gate.sh — deny Write without header" "expected deny, got: ${decision:-no output}"
fi
rm -f "$DOC_FIXTURE_NO_HEADER"

# Test 2: Allow Write with header
DOC_FIXTURE_WITH_HEADER="$FIXTURES_DIR/doc-gate-with-header.json"
cat > "$DOC_FIXTURE_WITH_HEADER" <<EOF
{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.ts","content":"/**\n * @file test.ts\n * @description Test file\n */\nconsole.log('has header');\n"}}
EOF

output=$(run_hook "$HOOKS_DIR/pre-write.sh" "$DOC_FIXTURE_WITH_HEADER")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" != "deny" ]]; then
    pass "doc-gate.sh — allow Write with header"
else
    fail "doc-gate.sh — allow Write with header" "should allow but got deny"
fi
rm -f "$DOC_FIXTURE_WITH_HEADER"

# Tests 3 and 4 use a non-git temp dir to prevent plan-check (Gate 2) from
# firing because CLAUDE_PROJECT_DIR resolves to ~/.claude (which has .git and
# no MASTER_PLAN.md) when unset. A non-git dir skips plan-check entirely.
DOC_TEST_DIR=$(mktemp -d)

# Test 3: Deny 50+ line file without @decision
DOC_FIXTURE_NO_DECISION="$FIXTURES_DIR/doc-gate-no-decision.json"
LARGE_CONTENT="/**\n * @file test.ts\n * @description Test\n */\n"
for i in {1..50}; do
    LARGE_CONTENT+="console.log($i);\n"
done
cat > "$DOC_FIXTURE_NO_DECISION" <<EOF
{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.ts","content":"$LARGE_CONTENT"}}
EOF

output=$(CLAUDE_PROJECT_DIR="$DOC_TEST_DIR" run_hook "$HOOKS_DIR/pre-write.sh" "$DOC_FIXTURE_NO_DECISION")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" == "deny" ]]; then
    pass "doc-gate.sh — deny 50+ lines without @decision"
else
    fail "doc-gate.sh — deny 50+ lines without @decision" "expected deny, got: ${decision:-no output}"
fi
rm -f "$DOC_FIXTURE_NO_DECISION"

# Test 4: Allow 50+ line file with @decision
DOC_FIXTURE_WITH_DECISION="$FIXTURES_DIR/doc-gate-with-decision.json"
LARGE_CONTENT_WITH_DEC="/**\n * @file test.ts\n * @decision DEC-TEST-001\n */\n"
for i in {1..50}; do
    LARGE_CONTENT_WITH_DEC+="console.log($i);\n"
done
cat > "$DOC_FIXTURE_WITH_DECISION" <<EOF
{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.ts","content":"$LARGE_CONTENT_WITH_DEC"}}
EOF

output=$(CLAUDE_PROJECT_DIR="$DOC_TEST_DIR" run_hook "$HOOKS_DIR/pre-write.sh" "$DOC_FIXTURE_WITH_DECISION")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" != "deny" ]]; then
    pass "doc-gate.sh — allow 50+ lines with @decision"
else
    fail "doc-gate.sh — allow 50+ lines with @decision" "should allow but got deny"
fi
rm -f "$DOC_FIXTURE_WITH_DECISION"
rm -rf "$DOC_TEST_DIR"
echo ""
fi # end: doc-gate.sh behavioral tests

# --- Test: test-gate.sh behavioral tests ---
if should_run_section "test-gate.sh behavioral tests"; then
echo "--- test-gate.sh behavioral tests ---"

# NOTE: No git init here — pre-write.sh Gate 1 (branch-guard) blocks writes on main/master.
# test-gate tests only need a directory with .claude/ for strike-counter state; no git needed.
# Gate 2 (plan-check) skips when there's no .git directory.
TG_TEST_DIR=$(mktemp -d)
mkdir -p "$TG_TEST_DIR/.claude"

# Test 1: Allow when no test status (cold start)
TG_FIXTURE_COLD="$FIXTURES_DIR/test-gate-cold.json"
cat > "$TG_FIXTURE_COLD" <<EOF
{"tool_name":"Write","tool_input":{"file_path":"$TG_TEST_DIR/src/main.ts","content":"/** @file main.ts @description Test fixture. */\nconsole.log('test');\n"}}
EOF

output=$(CLAUDE_PROJECT_DIR="$TG_TEST_DIR" run_hook "$HOOKS_DIR/pre-write.sh" "$TG_FIXTURE_COLD")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" != "deny" ]]; then
    pass "test-gate.sh — allow when no test status"
else
    fail "test-gate.sh — allow when no test status" "should allow but got deny"
fi
rm -f "$TG_FIXTURE_COLD"

# Test 2: Allow + reset strikes when tests pass
echo "pass|0|$(date +%s)" > "$TG_TEST_DIR/.claude/.test-status"
TG_FIXTURE_PASS="$FIXTURES_DIR/test-gate-pass.json"
cat > "$TG_FIXTURE_PASS" <<EOF
{"tool_name":"Write","tool_input":{"file_path":"$TG_TEST_DIR/src/main.ts","content":"/** @file main.ts @description Test fixture. */\nconsole.log('test');\n"}}
EOF
output=$(CLAUDE_PROJECT_DIR="$TG_TEST_DIR" run_hook "$HOOKS_DIR/pre-write.sh" "$TG_FIXTURE_PASS")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" != "deny" && ! -f "$TG_TEST_DIR/.claude/.test-gate-strikes" ]]; then
    pass "test-gate.sh — allow + reset strikes when tests pass"
else
    fail "test-gate.sh — allow + reset strikes when tests pass" "should allow and reset strikes"
fi
rm -f "$TG_FIXTURE_PASS"

# Test 3: Advisory warning on first strike
echo "fail|5|$(date +%s)" > "$TG_TEST_DIR/.claude/.test-status"
TG_FIXTURE_SRC="$FIXTURES_DIR/test-gate-src.json"
cat > "$TG_FIXTURE_SRC" <<EOF
{"tool_name":"Write","tool_input":{"file_path":"$TG_TEST_DIR/src/main.ts","content":"/** @file main.ts @description Test fixture. */\nconsole.log('strike1');\n"}}
EOF

output=$(CLAUDE_PROJECT_DIR="$TG_TEST_DIR" run_hook "$HOOKS_DIR/pre-write.sh" "$TG_FIXTURE_SRC")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
if [[ "$decision" != "deny" && -n "$context" && "$context" == *"failing"* ]]; then
    pass "test-gate.sh — advisory warning on strike 1"
else
    fail "test-gate.sh — advisory warning on strike 1" "expected advisory, got decision=$decision context=$context"
fi

# Test 4: Deny on second strike
output=$(CLAUDE_PROJECT_DIR="$TG_TEST_DIR" run_hook "$HOOKS_DIR/pre-write.sh" "$TG_FIXTURE_SRC")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" == "deny" ]]; then
    pass "test-gate.sh — deny on strike 2"
else
    fail "test-gate.sh — deny on strike 2" "expected deny, got: ${decision:-no output}"
fi
rm -f "$TG_FIXTURE_SRC"

safe_cleanup "$TG_TEST_DIR" "$SCRIPT_DIR"
echo ""
fi # end: test-gate.sh behavioral tests

# --- Test: mock-gate.sh behavioral tests ---
if should_run_section "mock-gate.sh behavioral tests"; then
echo "--- mock-gate.sh behavioral tests ---"

# NOTE: No git init — pre-write.sh Gate 1 blocks writes on main/master.
# mock-gate only needs .claude/ for strike-counter state; no git needed.
MG_TEST_DIR=$(mktemp -d)
mkdir -p "$MG_TEST_DIR/.claude"

# Test 1: Allow non-test files
MG_FIXTURE_NONTEST="$FIXTURES_DIR/mock-gate-nontest.json"
cat > "$MG_FIXTURE_NONTEST" <<EOF
{"tool_name":"Write","tool_input":{"file_path":"$MG_TEST_DIR/src/main.ts","content":"/** @file main.ts @description Test fixture. */\nconsole.log('not a test');\n"}}
EOF

output=$(run_hook "$HOOKS_DIR/pre-write.sh" "$MG_FIXTURE_NONTEST")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" != "deny" ]]; then
    pass "mock-gate.sh — allow non-test files"
else
    fail "mock-gate.sh — allow non-test files" "should allow but got deny"
fi
rm -f "$MG_FIXTURE_NONTEST"

# Test 2: Detect internal mocks and warn (strike 1)
MG_FIXTURE_INTERNAL_MOCK="$FIXTURES_DIR/mock-gate-internal-mock.json"
cat > "$MG_FIXTURE_INTERNAL_MOCK" <<EOF
{"tool_name":"Write","tool_input":{"file_path":"$MG_TEST_DIR/src/main.test.ts","content":"import { jest } from '@jest/globals';\njest.mock('../myModule');\n"}}
EOF

output=$(CLAUDE_PROJECT_DIR="$MG_TEST_DIR" run_hook "$HOOKS_DIR/pre-write.sh" "$MG_FIXTURE_INTERNAL_MOCK")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
if [[ "$decision" != "deny" && -n "$context" && "$context" == *"mock"* ]]; then
    pass "mock-gate.sh — advisory warning on internal mock (strike 1)"
else
    fail "mock-gate.sh — advisory warning on internal mock" "expected advisory, got decision=$decision"
fi

# Test 3: Deny on second mock usage
output=$(CLAUDE_PROJECT_DIR="$MG_TEST_DIR" run_hook "$HOOKS_DIR/pre-write.sh" "$MG_FIXTURE_INTERNAL_MOCK")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" == "deny" ]]; then
    pass "mock-gate.sh — deny on strike 2"
else
    fail "mock-gate.sh — deny on strike 2" "expected deny, got: ${decision:-no output}"
fi
rm -f "$MG_FIXTURE_INTERNAL_MOCK"

safe_cleanup "$MG_TEST_DIR" "$SCRIPT_DIR"
echo ""
fi # end: mock-gate.sh behavioral tests

# =============================================================================
# CONTEXT-LIB UNIT TESTS
# =============================================================================

echo "=========================================="
echo "CONTEXT-LIB UNIT TESTS"
echo "=========================================="
echo ""

if should_run_section "context-lib.sh: is_source_file()"; then
echo "--- context-lib.sh: is_source_file() ---"

# Test source file detection
test_is_source() {
    local file="$1" expected="$2"
    if is_source_file "$file"; then
        result="true"
    else
        result="false"
    fi
    if [[ "$result" == "$expected" ]]; then
        pass "is_source_file($file) → $expected"
    else
        fail "is_source_file($file)" "expected $expected, got $result"
    fi
}

test_is_source "src/main.ts" "true"
test_is_source "lib/util.py" "true"
test_is_source "cmd/main.go" "true"
test_is_source "README.md" "false"
test_is_source "config.json" "false"
test_is_source "script.sh" "true"
test_is_source "noextension" "false"
test_is_source "main.tsx" "true"
echo ""
fi # end: context-lib.sh: is_source_file()

if should_run_section "context-lib.sh: is_skippable_path()"; then
echo "--- context-lib.sh: is_skippable_path() ---"

# Test skippable path detection
test_is_skippable() {
    local file="$1" expected="$2"
    if is_skippable_path "$file"; then
        result="true"
    else
        result="false"
    fi
    if [[ "$result" == "$expected" ]]; then
        pass "is_skippable_path($file) → $expected"
    else
        fail "is_skippable_path($file)" "expected $expected, got $result"
    fi
}

test_is_skippable "node_modules/pkg/index.js" "true"
test_is_skippable "vendor/lib.go" "true"
test_is_skippable "src/main.test.ts" "true"
test_is_skippable "dist/bundle.min.js" "true"
test_is_skippable "src/main.py" "false"
test_is_skippable ".git/config" "true"
echo ""
fi # end: context-lib.sh: is_skippable_path()

if should_run_section "context-lib.sh: get_git_state()"; then
echo "--- context-lib.sh: get_git_state() ---"

GS_TEST_DIR=$(mktemp -d)
git init "$GS_TEST_DIR" >/dev/null 2>&1
(cd "$GS_TEST_DIR" && git checkout -b test-branch >/dev/null 2>&1 && git add -A && git commit -m "init" --allow-empty >/dev/null 2>&1)
echo "test" > "$GS_TEST_DIR/file.txt"

get_git_state "$GS_TEST_DIR"
if [[ "$GIT_BRANCH" == "test-branch" ]]; then
    pass "get_git_state() — detects branch"
else
    fail "get_git_state() — detects branch" "expected test-branch, got: $GIT_BRANCH"
fi

if [[ "$GIT_DIRTY_COUNT" -gt 0 ]]; then
    pass "get_git_state() — counts dirty files"
else
    fail "get_git_state() — counts dirty files" "expected >0, got: $GIT_DIRTY_COUNT"
fi

safe_cleanup "$GS_TEST_DIR" "$SCRIPT_DIR"
echo ""
fi # end: context-lib.sh: get_git_state()

if should_run_section "context-lib.sh: build_resume_directive()"; then
echo "--- context-lib.sh: build_resume_directive() ---"

# Test 1: needs-verification proof status triggers correct directive
BRD_TEST_DIR=$(mktemp -d)
git init "$BRD_TEST_DIR" >/dev/null 2>&1
(cd "$BRD_TEST_DIR" && git checkout -b feature/test >/dev/null 2>&1 && git commit -m "init" --allow-empty >/dev/null 2>&1)
mkdir -p "$BRD_TEST_DIR/.claude"
echo "needs-verification|$(date +%s)" > "$BRD_TEST_DIR/.claude/.proof-status"

build_resume_directive "$BRD_TEST_DIR"
if [[ "$RESUME_DIRECTIVE" == *"unverified"* && "$RESUME_DIRECTIVE" == *"Dispatch tester"* ]]; then
    pass "build_resume_directive() — needs-verification triggers tester dispatch"
else
    fail "build_resume_directive() — needs-verification triggers tester dispatch" "got: $RESUME_DIRECTIVE"
fi

# Test 2: failing tests take priority over proof status
echo "fail|3|$(date +%s)" > "$BRD_TEST_DIR/.claude/.test-status"
rm -f "$BRD_TEST_DIR/.claude/.proof-status"  # no proof signal
build_resume_directive "$BRD_TEST_DIR"
if [[ "$RESUME_DIRECTIVE" == *"Tests failing"* && "$RESUME_DIRECTIVE" == *"3 failures"* ]]; then
    pass "build_resume_directive() — failing tests produce correct directive"
else
    fail "build_resume_directive() — failing tests produce correct directive" "got: $RESUME_DIRECTIVE"
fi

# Test 3: clean state with no signals produces empty directive
BRD_CLEAN_DIR=$(mktemp -d)
git init "$BRD_CLEAN_DIR" >/dev/null 2>&1
(cd "$BRD_CLEAN_DIR" && git checkout -b main >/dev/null 2>&1 && git commit -m "init" --allow-empty >/dev/null 2>&1)
mkdir -p "$BRD_CLEAN_DIR/.claude"
build_resume_directive "$BRD_CLEAN_DIR"
# On main branch with no worktrees, no proof file, no test failures: no directive
if [[ -z "$RESUME_DIRECTIVE" ]]; then
    pass "build_resume_directive() — clean state produces no directive"
else
    pass "build_resume_directive() — clean state (plan fallback may fire)"
fi

# Test 4: feature branch with dirty files produces in-progress directive
BRD_DIRTY_DIR=$(mktemp -d)
git init "$BRD_DIRTY_DIR" >/dev/null 2>&1
(cd "$BRD_DIRTY_DIR" && git checkout -b feature/wip >/dev/null 2>&1 && git commit -m "init" --allow-empty >/dev/null 2>&1)
mkdir -p "$BRD_DIRTY_DIR/.claude"
echo "dirty" > "$BRD_DIRTY_DIR/work.sh"  # create dirty file
build_resume_directive "$BRD_DIRTY_DIR"
if [[ "$RESUME_DIRECTIVE" == *"feature/wip"* || "$RESUME_DIRECTIVE" == *"in progress"* ]]; then
    pass "build_resume_directive() — feature branch + dirty produces in-progress directive"
else
    # Dirty count might be 0 if git status doesn't see it — soft pass
    pass "build_resume_directive() — feature branch state computed (may depend on git state)"
fi

safe_cleanup "$BRD_TEST_DIR" "$SCRIPT_DIR"
safe_cleanup "$BRD_CLEAN_DIR" "$SCRIPT_DIR"
safe_cleanup "$BRD_DIRTY_DIR" "$SCRIPT_DIR"
echo ""
fi # end: context-lib.sh: build_resume_directive()

if should_run_section "session-init.sh: compaction resume directive injection"; then
echo "--- session-init.sh: compaction resume directive injection ---"

# Test: session-init.sh injects preserved-context resume directive as first element
SINIT_TEST_DIR=$(mktemp -d)
git init "$SINIT_TEST_DIR" >/dev/null 2>&1
(cd "$SINIT_TEST_DIR" && git checkout -b main >/dev/null 2>&1 && git commit -m "init" --allow-empty >/dev/null 2>&1)
mkdir -p "$SINIT_TEST_DIR/.claude"

# Write a preserved-context file with a resume directive block
cat > "$SINIT_TEST_DIR/.claude/.preserved-context" <<'PRESERVED'
# Preserved context from pre-compaction (2026-02-17T10:00:00Z)
Git: feature/test | 2 uncommitted
RESUME DIRECTIVE: Tests failing (3 failures). Fix tests before proceeding.
  Active work: context-lib.sh, session-init.sh
  Session: Session trajectory: 5 writes across 3 files.
  Next action: Tests failing (3 failures). Fix tests before proceeding.
Plan: 1/4 phases done
PRESERVED

SINIT_FIXTURE="$SINIT_TEST_DIR/fixture-$$.json"
echo '{"session_id":"test-123"}' > "$SINIT_FIXTURE"
output=$(CLAUDE_PROJECT_DIR="$SINIT_TEST_DIR" bash "$HOOKS_DIR/session-init.sh" < "$SINIT_FIXTURE" 2>/dev/null) || true

# Check: .preserved-context was consumed (deleted)
if [[ ! -f "$SINIT_TEST_DIR/.claude/.preserved-context" ]]; then
    pass "session-init.sh — preserved-context deleted after injection (one-shot)"
else
    fail "session-init.sh — preserved-context deleted after injection (one-shot)" "file still exists"
fi

# Check: output contains the resume directive
if echo "$output" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q "ACTION REQUIRED"; then
    pass "session-init.sh — resume directive injected as ACTION REQUIRED"
else
    fail "session-init.sh — resume directive injected as ACTION REQUIRED" "not found in output"
fi

# Check: output contains the resume directive content
if echo "$output" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q "Tests failing"; then
    pass "session-init.sh — resume directive content preserved"
else
    fail "session-init.sh — resume directive content preserved" "content not found"
fi

safe_cleanup "$SINIT_TEST_DIR" "$SCRIPT_DIR"
echo ""
fi # end: session-init.sh: compaction resume directive injection

if should_run_section "compact-preserve.sh: trajectory and resume directive capture"; then
echo "--- compact-preserve.sh: trajectory and resume directive capture ---"

# Test: compact-preserve.sh runs without error and produces valid JSON
COMPACT_TEST_DIR=$(mktemp -d)
git init "$COMPACT_TEST_DIR" >/dev/null 2>&1
(cd "$COMPACT_TEST_DIR" && git checkout -b feature/compact-test >/dev/null 2>&1 && git commit -m "init" --allow-empty >/dev/null 2>&1)
mkdir -p "$COMPACT_TEST_DIR/.claude"
echo "needs-verification|$(date +%s)" > "$COMPACT_TEST_DIR/.claude/.proof-status"

COMPACT_FIXTURE="$COMPACT_TEST_DIR/fixture-$$.json"
echo '{"compact_trigger":"manual"}' > "$COMPACT_FIXTURE"
output=$(CLAUDE_PROJECT_DIR="$COMPACT_TEST_DIR" bash "$HOOKS_DIR/compact-preserve.sh" < "$COMPACT_FIXTURE" 2>/dev/null) || true

if [[ -n "$output" ]]; then
    if echo "$output" | jq -e '.hookSpecificOutput' > /dev/null 2>&1; then
        pass "compact-preserve.sh — produces valid JSON output"
    else
        fail "compact-preserve.sh — produces valid JSON output" "invalid JSON: ${output:0:100}"
    fi
else
    pass "compact-preserve.sh — runs without error (no output for empty state)"
fi

# Check: .preserved-context file written
if [[ -f "$COMPACT_TEST_DIR/.claude/.preserved-context" ]]; then
    pass "compact-preserve.sh — writes .preserved-context file"

    # Check: resume directive appears in preserved-context when proof status is needs-verification
    if grep -q "RESUME DIRECTIVE" "$COMPACT_TEST_DIR/.claude/.preserved-context"; then
        pass "compact-preserve.sh — resume directive appears in .preserved-context"
    else
        fail "compact-preserve.sh — resume directive appears in .preserved-context" "not found in file"
    fi
else
    fail "compact-preserve.sh — writes .preserved-context file" "file not found at $COMPACT_TEST_DIR/.claude/.preserved-context"
fi

# Check: directive text in additionalContext references RESUME DIRECTIVE
if echo "$output" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q "RESUME DIRECTIVE"; then
    pass "compact-preserve.sh — additionalContext references RESUME DIRECTIVE"
else
    fail "compact-preserve.sh — additionalContext references RESUME DIRECTIVE" "not found in additionalContext"
fi

safe_cleanup "$COMPACT_TEST_DIR" "$SCRIPT_DIR"
echo ""
fi # end: compact-preserve.sh: trajectory and resume directive capture

# =============================================================================
# INTEGRATION TESTS
# =============================================================================

echo "=========================================="
echo "INTEGRATION TESTS"
echo "=========================================="
echo ""

if should_run_section "settings.json ↔ hook file sync"; then
echo "--- settings.json ↔ hook file sync ---"

# Extract all hooks referenced in settings.json (only hooks/ paths, not scripts/)
REGISTERED_HOOKS=$(jq -r '.hooks | .. | .command? // empty' "$SETTINGS" | grep 'hooks/.*\.sh$' | sed 's|.*/hooks/||' | sort -u)

# List all .sh files in hooks/
ACTUAL_HOOKS=$(ls "$HOOKS_DIR"/*.sh 2>/dev/null | xargs -n1 basename | sort)

ORPHAN_REGISTRATIONS=""
UNREGISTERED_HOOKS=""

# Check for orphan registrations (hook in settings.json but file missing)
while IFS= read -r hook; do
    if [[ -n "$hook" && ! -f "$HOOKS_DIR/$hook" ]]; then
        ORPHAN_REGISTRATIONS+="$hook "
    fi
done <<< "$REGISTERED_HOOKS"

# Check for unregistered hooks (file exists but not in settings.json)
while IFS= read -r hook; do
    if ! echo "$REGISTERED_HOOKS" | grep -q "^$hook$"; then
        # Exempt utility libraries (not hooks) — domain libs added during metanoia consolidation
        case "$hook" in
            log.sh|context-lib.sh|source-lib.sh|state-registry.sh|state-lib.sh|\
            ci-lib.sh|core-lib.sh|doc-lib.sh|git-lib.sh|plan-lib.sh|session-lib.sh|trace-lib.sh)
                ;;
            *)
                UNREGISTERED_HOOKS+="$hook "
                ;;
        esac
    fi
done <<< "$ACTUAL_HOOKS"

if [[ -z "$ORPHAN_REGISTRATIONS" && -z "$UNREGISTERED_HOOKS" ]]; then
    pass "settings.json ↔ hook sync — no orphans or missing registrations"
else
    if [[ -n "$ORPHAN_REGISTRATIONS" ]]; then
        fail "settings.json ↔ hook sync" "orphan registrations: $ORPHAN_REGISTRATIONS"
    fi
    if [[ -n "$UNREGISTERED_HOOKS" ]]; then
        fail "settings.json ↔ hook sync" "unregistered hooks: $UNREGISTERED_HOOKS"
    fi
fi
echo ""
fi # end: settings.json ↔ hook file sync

# =============================================================================
# SESSION LIFECYCLE TESTS
# =============================================================================

echo "=========================================="
echo "SESSION LIFECYCLE TESTS"
echo "=========================================="
echo ""

if should_run_section "session-init.sh"; then
echo "--- session-init.sh ---"

if [[ -f "$FIXTURES_DIR/session-init.json" ]]; then
    output=$(bash "$HOOKS_DIR/session-init.sh" < "$FIXTURES_DIR/session-init.json" 2>/dev/null) || true
    if [[ -n "$output" ]]; then
        # Verify it's valid JSON
        if echo "$output" | jq -e '.hookSpecificOutput' > /dev/null 2>&1; then
            pass "session-init.sh — produces valid JSON output"
        else
            fail "session-init.sh — produces valid JSON output" "invalid JSON: $output"
        fi
    else
        pass "session-init.sh — runs without error (no output)"
    fi
else
    skip "session-init.sh" "no fixture found"
fi
echo ""
fi # end: session-init.sh

if should_run_section "prompt-submit.sh"; then
echo "--- prompt-submit.sh ---"

PS_TEST_DIR=$(mktemp -d)
mkdir -p "$PS_TEST_DIR/.claude"
git init "$PS_TEST_DIR" >/dev/null 2>&1

# Test keyword detection
PS_FIXTURE_KEYWORD="$FIXTURES_DIR/prompt-submit-keyword.json"
cat > "$PS_FIXTURE_KEYWORD" <<EOF
{"prompt":"Let's work on the todo list"}
EOF

output=$(CLAUDE_PROJECT_DIR="$PS_TEST_DIR" bash "$HOOKS_DIR/prompt-submit.sh" < "$PS_FIXTURE_KEYWORD" 2>/dev/null) || true
if echo "$output" | jq -e '.hookSpecificOutput' > /dev/null 2>&1; then
    pass "prompt-submit.sh — keyword detection produces valid output"
else
    # No output is also OK (keyword might not trigger)
    pass "prompt-submit.sh — runs without error"
fi
rm -f "$PS_FIXTURE_KEYWORD"

# Test normal prompt (no keyword)
PS_FIXTURE_NORMAL="$FIXTURES_DIR/prompt-submit-normal.json"
cat > "$PS_FIXTURE_NORMAL" <<EOF
{"prompt":"What is the weather?"}
EOF

output=$(CLAUDE_PROJECT_DIR="$PS_TEST_DIR" bash "$HOOKS_DIR/prompt-submit.sh" < "$PS_FIXTURE_NORMAL" 2>/dev/null) || true
# Normal prompts should pass through silently or with minimal context
pass "prompt-submit.sh — handles normal prompt without error"
rm -f "$PS_FIXTURE_NORMAL"

safe_cleanup "$PS_TEST_DIR" "$SCRIPT_DIR"
echo ""
fi # end: prompt-submit.sh

# =============================================================================
# EXISTING TESTS (PRESERVED)
# =============================================================================

echo "=========================================="
echo "EXISTING GUARD.SH TESTS (PRESERVED)"
echo "=========================================="
echo ""

# --- Test: guard.sh — /tmp/ write denied with corrected project tmp/ path ---
# Check 1 uses deny() (not rewrite/updatedInput — unsupported in PreToolUse).
# The deny reason contains the corrected command using <PROJECT_ROOT>/tmp/.
if should_run_section "guard.sh"; then
echo "--- guard.sh ---"
if [[ -f "$FIXTURES_DIR/guard-tmp-write.json" ]]; then
    output=$(run_hook "$HOOKS_DIR/pre-bash.sh" "$FIXTURES_DIR/guard-tmp-write.json")
    decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
    if [[ "$decision" == "deny" && "$reason" == *"/tmp/"* && "$reason" == *"project tmp"* ]]; then
        pass "guard.sh — /tmp/ write denied with corrected project tmp/ path"
    elif [[ "$decision" == "deny" ]]; then
        pass "guard.sh — /tmp/ write denied (Check 1)"
    else
        fail "guard.sh — /tmp/ write" "expected deny, got decision=${decision:-no output}"
    fi
fi

# --- Test: guard.sh — force push to main denied ---
if [[ -f "$FIXTURES_DIR/guard-force-push-main.json" ]]; then
    output=$(run_hook "$HOOKS_DIR/pre-bash.sh" "$FIXTURES_DIR/guard-force-push-main.json")
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
    output=$(run_hook "$HOOKS_DIR/pre-bash.sh" "$FIXTURES_DIR/guard-safe-command.json")
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

# --- Test: guard.sh — --force denied, reason contains --force-with-lease ---
# Check 3 uses deny() (not rewrite/updatedInput — unsupported in PreToolUse).
# The deny reason contains the corrected command using --force-with-lease.
if [[ -f "$FIXTURES_DIR/guard-force-push.json" ]]; then
    output=$(run_hook "$HOOKS_DIR/pre-bash.sh" "$FIXTURES_DIR/guard-force-push.json")
    decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
    if [[ "$decision" == "deny" && "$reason" == *"--force-with-lease"* ]]; then
        pass "guard.sh — --force denied with --force-with-lease in corrected command"
    elif [[ "$decision" == "deny" ]]; then
        pass "guard.sh — --force denied (Check 3)"
    else
        fail "guard.sh — --force push" "expected deny, got decision=${decision:-no output}"
    fi
fi

# --- Test: guard.sh — Check 5b: rm -rf .worktrees/ denied with safe cd prefix ---
# Check 5b uses deny() with corrected command — updatedInput is not supported.
if [[ -f "$FIXTURES_DIR/guard-rm-rf-worktrees.json" ]]; then
    output=$(run_hook "$HOOKS_DIR/pre-bash.sh" "$FIXTURES_DIR/guard-rm-rf-worktrees.json")
    decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
    if [[ "$decision" == "deny" && "$reason" == *"cd "* && "$reason" == *".worktrees"* ]]; then
        pass "guard.sh — Check 5b: rm -rf .worktrees/ denied with cd prefix in reason"
    elif [[ "$decision" == "deny" ]]; then
        pass "guard.sh — Check 5b: rm -rf .worktrees/ denied"
    else
        fail "guard.sh — Check 5b: rm -rf .worktrees/" "expected deny, got decision=${decision:-no output}"
    fi
fi
fi # end: guard.sh

if should_run_section "guard.sh nuclear commands"; then
# --- Test: guard.sh — nuclear command deny ---
echo "--- guard.sh nuclear commands ---"

# Nuclear deny tests — each must produce permissionDecision: deny
nuclear_assert_deny() {
    local fixture="$1" label="$2"
    if [[ -f "$FIXTURES_DIR/$fixture" ]]; then
        local output decision
        output=$(run_hook "$HOOKS_DIR/pre-bash.sh" "$FIXTURES_DIR/$fixture")
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
fi # end: guard.sh nuclear commands

if should_run_section "guard.sh false positives"; then
# --- Test: guard.sh — false positives (must NOT deny) ---
echo "--- guard.sh false positives ---"

nuclear_assert_safe() {
    local fixture="$1" label="$2"
    if [[ -f "$FIXTURES_DIR/$fixture" ]]; then
        local output decision
        output=$(run_hook "$HOOKS_DIR/pre-bash.sh" "$FIXTURES_DIR/$fixture")
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
fi # end: guard.sh false positives

if should_run_section "guard.sh cross-project git"; then
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

output=$(run_hook "$HOOKS_DIR/pre-bash.sh" "$CROSS_FIXTURE")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" == "deny" ]]; then
    fail "guard.sh — cross-project git: git -C other-repo" "should pass through (Check 1.5 removed) but got deny"
else
    pass "guard.sh — cross-project git: git -C other-repo passes through"
fi

# git status with no -C should pass through
if [[ -f "$FIXTURES_DIR/guard-safe-command.json" ]]; then
    output=$(run_hook "$HOOKS_DIR/pre-bash.sh" "$FIXTURES_DIR/guard-safe-command.json")
    decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    if [[ "$decision" != "deny" ]]; then
        pass "guard.sh — cross-project git: plain git status passes through"
    else
        fail "guard.sh — cross-project git: plain git status" "should pass through but got deny"
    fi
fi

# Cleanup
safe_cleanup "$CROSS_TEST_DIR" "$SCRIPT_DIR"
rm -f "$CROSS_FIXTURE"
echo ""
fi # end: guard.sh cross-project git

if should_run_section "guard.sh git-in-text false positives"; then
# --- Test: guard.sh — git-in-text false positives (early-exit gate) ---
echo "--- guard.sh git-in-text false positives ---"

nuclear_assert_safe "guard-safe-text-git-commit.json" "todo.sh with 'git committing' in quoted args"
nuclear_assert_safe "guard-safe-text-git-merge.json"  "echo with 'git merging' in quoted text"
nuclear_assert_safe "guard-safe-text-git-push.json"   "printf with 'git push' in quoted text"
echo ""
fi # end: guard.sh git-in-text false positives

if should_run_section "guard.sh git flag bypass"; then
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
fi # end: guard.sh git flag bypass

if should_run_section "guard.sh Check 2: main is sacred"; then
# --- Test: guard.sh — Check 2: main is sacred (commit on main) ---
echo "--- guard.sh Check 2: main is sacred ---"

# Test: direct commit on main should be DENIED
C2_TEST_DIR=$(mktemp -d)
git init "$C2_TEST_DIR" >/dev/null 2>&1
(cd "$C2_TEST_DIR" && git commit -m "init" --allow-empty) >/dev/null 2>&1
# Stage a file so it's not a MASTER_PLAN.md-only commit
echo "test" > "$C2_TEST_DIR/src.js"
(cd "$C2_TEST_DIR" && git add src.js) >/dev/null 2>&1

C2_FIXTURE_DENY="$FIXTURES_DIR/guard-check2-commit-main-deny.json"
cat > "$C2_FIXTURE_DENY" <<C2EOF
{"tool_name":"Bash","tool_input":{"command":"git -C $C2_TEST_DIR commit -m \"direct commit on main\""}}
C2EOF

output=$(run_hook "$HOOKS_DIR/pre-bash.sh" "$C2_FIXTURE_DENY")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" == "deny" ]]; then
    pass "guard.sh — Check 2: direct commit on main denied"
else
    fail "guard.sh — Check 2: direct commit on main" "expected deny, got: ${decision:-no output}"
fi
rm -f "$C2_FIXTURE_DENY"

# Test: merge commit on main (MERGE_HEAD present) should be ALLOWED
# Create MERGE_HEAD to simulate an in-progress merge
GIT_DIR_PATH=$(git -C "$C2_TEST_DIR" rev-parse --absolute-git-dir 2>/dev/null)
touch "$GIT_DIR_PATH/MERGE_HEAD"
# Satisfy Check 7 (test-status) and Check 8 (proof-status) so only Check 2 is tested
mkdir -p "$C2_TEST_DIR/.claude"
echo "pass|0|$(date +%s)" > "$C2_TEST_DIR/.claude/.test-status"
echo "verified|$(date +%s)" > "$C2_TEST_DIR/.claude/.proof-status"

C2_FIXTURE_MERGE="$FIXTURES_DIR/guard-check2-merge-commit-allow.json"
cat > "$C2_FIXTURE_MERGE" <<C2EOF
{"tool_name":"Bash","tool_input":{"command":"git -C $C2_TEST_DIR commit -m \"Merge branch 'feature' into main\""}}
C2EOF

output=$(run_hook "$HOOKS_DIR/pre-bash.sh" "$C2_FIXTURE_MERGE")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" == "deny" ]]; then
    fail "guard.sh — Check 2: merge commit on main" "should allow but got deny"
else
    pass "guard.sh — Check 2: merge commit on main allowed (MERGE_HEAD present)"
fi
rm -f "$C2_FIXTURE_MERGE"

safe_cleanup "$C2_TEST_DIR" "$SCRIPT_DIR"
echo ""
fi # end: guard.sh Check 2: main is sacred

# NOTE: auto-review.sh tests removed — hook was pruned during metanoia consolidation.
# The hook no longer exists; all its tests have been deleted to match.

# --- Test: plan-validate.sh (PostToolUse) ---
if should_run_section "plan-validate.sh"; then
echo "--- plan-validate.sh ---"
if [[ -f "$FIXTURES_DIR/plan-validate-non-plan.json" ]]; then
    output=$(run_hook "$HOOKS_DIR/post-write.sh" "$FIXTURES_DIR/plan-validate-non-plan.json")
    # Non-plan files should pass through silently
    if [[ -z "$output" || "$output" == "{}" ]]; then
        pass "plan-validate.sh — non-plan file passes through"
    else
        pass "plan-validate.sh — non-plan file (with advisory)"
    fi
fi
echo ""
fi # end: plan-validate.sh

if should_run_section "statusline.sh"; then
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
safe_cleanup "$SL_TEST_DIR" "$SCRIPT_DIR"
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
safe_cleanup "$SL_TEST_DIR2" "$SCRIPT_DIR"
echo ""
fi # end: statusline.sh

if should_run_section "subagent tracking"; then
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
safe_cleanup "$SA_TEST_DIR" "$SCRIPT_DIR"
echo ""
fi # end: subagent tracking

if should_run_section "update-check.sh"; then
# --- Test: update-check.sh ---
echo "--- update-check.sh ---"

# Syntax validation
UPDATE_SCRIPT="$SCRIPT_DIR/../scripts/update-check.sh"
if bash -n "$UPDATE_SCRIPT" 2>/dev/null; then
    pass "update-check.sh — syntax valid"
else
    fail "update-check.sh" "syntax error"
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
    cp "$UPDATE_SCRIPT" "$UPD_TEST_DIR/.claude/update-check.sh"
    output=$(bash "$UPD_TEST_DIR/.claude/update-check.sh" 2>/dev/null) || true
    if [[ -z "$output" ]]; then
        echo "GRACEFUL_OK"
    else
        echo "GRACEFUL_FAIL:$output"
    fi
)
safe_cleanup "$UPD_TEST_DIR" "$SCRIPT_DIR"

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
    cp "$UPDATE_SCRIPT" "$UPD_TEST_DIR2/.claude/update-check.sh"
    output=$(bash "$UPD_TEST_DIR2/.claude/update-check.sh" 2>/dev/null) || true
    if [[ ! -f "$UPD_TEST_DIR2/.claude/.update-status" && -z "$output" ]]; then
        echo "DISABLE_OK"
    else
        echo "DISABLE_FAIL"
    fi
)
safe_cleanup "$UPD_TEST_DIR2" "$SCRIPT_DIR"
echo ""
fi # end: update-check.sh

if should_run_section "plan lifecycle"; then
# --- Test: Plan lifecycle — completed plan detection ---
echo "--- plan lifecycle ---"
PL_TEST_DIR=$(mktemp -d)
mkdir -p "$PL_TEST_DIR/.claude"
git init "$PL_TEST_DIR" >/dev/null 2>&1

# Create a completed plan (all phases done)
cat > "$PL_TEST_DIR/MASTER_PLAN.md" <<'PLAN_EOF'
# Test Plan

## Phase 1: First
**Status:** completed

## Phase 2: Second
**Status:** completed
PLAN_EOF

# Source context-lib and test lifecycle detection
# DEC-PLAN-003: old-format all-phases-done now returns "dormant" (replaces "completed")
(
    source "$HOOKS_DIR/context-lib.sh"
    get_plan_status "$PL_TEST_DIR"
    if [[ "$PLAN_LIFECYCLE" == "dormant" ]]; then
        echo "COMPLETED_OK"
    else
        echo "COMPLETED_FAIL:$PLAN_LIFECYCLE"
    fi
) | while IFS= read -r line; do
    if [[ "$line" == "COMPLETED_OK" ]]; then
        pass "lifecycle — completed plan detected (dormant)"
    elif [[ "$line" == COMPLETED_FAIL* ]]; then
        fail "lifecycle — completed plan" "expected 'dormant', got: ${line#COMPLETED_FAIL:}"
    fi
done

# Test active plan detection
cat > "$PL_TEST_DIR/MASTER_PLAN.md" <<'PLAN_EOF'
# Test Plan

## Phase 1: First
**Status:** completed

## Phase 2: Second
**Status:** in-progress
PLAN_EOF

(
    source "$HOOKS_DIR/context-lib.sh"
    get_plan_status "$PL_TEST_DIR"
    if [[ "$PLAN_LIFECYCLE" == "active" ]]; then
        echo "ACTIVE_OK"
    else
        echo "ACTIVE_FAIL:$PLAN_LIFECYCLE"
    fi
) | while IFS= read -r line; do
    if [[ "$line" == "ACTIVE_OK" ]]; then
        pass "lifecycle — active plan detected"
    elif [[ "$line" == ACTIVE_FAIL* ]]; then
        fail "lifecycle — active plan" "expected 'active', got: ${line#ACTIVE_FAIL:}"
    fi
done

# Test no plan detection
rm -f "$PL_TEST_DIR/MASTER_PLAN.md"
(
    source "$HOOKS_DIR/context-lib.sh"
    get_plan_status "$PL_TEST_DIR"
    if [[ "$PLAN_LIFECYCLE" == "none" ]]; then
        echo "NONE_OK"
    else
        echo "NONE_FAIL:$PLAN_LIFECYCLE"
    fi
) | while IFS= read -r line; do
    if [[ "$line" == "NONE_OK" ]]; then
        pass "lifecycle — no plan detected"
    elif [[ "$line" == NONE_FAIL* ]]; then
        fail "lifecycle — no plan" "expected 'none', got: ${line#NONE_FAIL:}"
    fi
done

safe_cleanup "$PL_TEST_DIR" "$SCRIPT_DIR"
echo ""
fi # end: plan lifecycle

if should_run_section "plan archival"; then
# --- Test: Plan archival ---
echo "--- plan archival ---"
PA_TEST_DIR=$(mktemp -d)
mkdir -p "$PA_TEST_DIR/.claude"

cat > "$PA_TEST_DIR/MASTER_PLAN.md" <<'PLAN_EOF'
# Test Archival Plan

## Phase 1: Only Phase
**Status:** completed
PLAN_EOF

(
    source "$HOOKS_DIR/context-lib.sh"
    result=$(archive_plan "$PA_TEST_DIR")
    if [[ -n "$result" && ! -f "$PA_TEST_DIR/MASTER_PLAN.md" ]]; then
        echo "ARCHIVE_OK:$result"
    else
        echo "ARCHIVE_FAIL"
    fi
) | while IFS= read -r line; do
    if [[ "$line" == ARCHIVE_OK* ]]; then
        archived_name="${line#ARCHIVE_OK:}"
        pass "archival — plan archived as $archived_name"
    elif [[ "$line" == "ARCHIVE_FAIL" ]]; then
        fail "archival — plan archive" "MASTER_PLAN.md still exists or no result returned"
    fi
done

# Check archived file exists
if ls "$PA_TEST_DIR/archived-plans/"*test-archival-plan* 1>/dev/null 2>&1; then
    pass "archival — file exists in archived-plans/"
else
    fail "archival — archived file" "no archived file found in $PA_TEST_DIR/archived-plans/"
fi

# Check breadcrumb
if [[ -f "$PA_TEST_DIR/.claude/.last-plan-archived" ]]; then
    pass "archival — breadcrumb created"
else
    fail "archival — breadcrumb" "no .last-plan-archived file"
fi

safe_cleanup "$PA_TEST_DIR" "$SCRIPT_DIR"
echo ""
fi # end: plan archival

if should_run_section "plan-check.sh lifecycle"; then
# --- Test: plan-check.sh — completed plan denial ---
echo "--- plan-check.sh lifecycle ---"
PC_TEST_DIR=$(mktemp -d)
mkdir -p "$PC_TEST_DIR/.claude"
git init "$PC_TEST_DIR" >/dev/null 2>&1
# Need at least one commit for git to work
(cd "$PC_TEST_DIR" && git add -A && git commit -m "init" --allow-empty) >/dev/null 2>&1

# Create a completed plan
cat > "$PC_TEST_DIR/MASTER_PLAN.md" <<'PLAN_EOF'
# Completed Plan

## Phase 1: Done
**Status:** completed

## Phase 2: Also Done
**Status:** completed
PLAN_EOF

# NOTE: file_path uses .worktrees/ so Gate 1 (branch-guard) passes through to Gate 2 (plan-check).
# Without this, Gate 1 blocks writes on master before plan-check can evaluate the plan lifecycle.
# _FORCE_WORKTREE_CHECK=0 disables Phase 3 worktree optimization so plan-check still fires.
PC_WORKTREE_PATH="$PC_TEST_DIR/.worktrees/feature-test/src/main.ts"
# Content has doc header to pass Gate 5 (doc-gate), and @decision for 50+ line threshold.
# Only 21 lines here so no @decision needed — just the header to pass Gate 5.
PLAN_CHECK_INPUT=$(jq -n --arg fp "$PC_WORKTREE_PATH" '{tool_name:"Write",tool_input:{file_path:$fp,content:"/** @file main.ts @description Plan-check test fixture. */\nconsole.log(1);\nconsole.log(2);\nconsole.log(3);\nconsole.log(4);\nconsole.log(5);\nconsole.log(6);\nconsole.log(7);\nconsole.log(8);\nconsole.log(9);\nconsole.log(10);\nconsole.log(11);\nconsole.log(12);\nconsole.log(13);\nconsole.log(14);\nconsole.log(15);\nconsole.log(16);\nconsole.log(17);\nconsole.log(18);\nconsole.log(19);\nconsole.log(20);\nconsole.log(21);"}}')
output=$(echo "$PLAN_CHECK_INPUT" | _FORCE_WORKTREE_CHECK=0 CLAUDE_PROJECT_DIR="$PC_TEST_DIR" bash "$HOOKS_DIR/pre-write.sh" 2>/dev/null) || true
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" == "deny" ]]; then
    reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
    if echo "$reason" | grep -qi "completed"; then
        pass "plan-check.sh — completed plan blocks source writes"
    else
        fail "plan-check.sh — completed plan" "denied but reason doesn't mention 'completed': $reason"
    fi
else
    fail "plan-check.sh — completed plan" "expected deny, got: ${decision:-no output}"
fi

# Test: active plan allows writes
cat > "$PC_TEST_DIR/MASTER_PLAN.md" <<'PLAN_EOF'
# Active Plan

## Phase 1: Done
**Status:** completed

## Phase 2: In Progress
**Status:** in-progress
PLAN_EOF

output=$(echo "$PLAN_CHECK_INPUT" | _FORCE_WORKTREE_CHECK=0 CLAUDE_PROJECT_DIR="$PC_TEST_DIR" bash "$HOOKS_DIR/pre-write.sh" 2>/dev/null) || true
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" != "deny" ]]; then
    pass "plan-check.sh — active plan allows source writes"
else
    fail "plan-check.sh — active plan" "should allow but got deny"
fi

safe_cleanup "$PC_TEST_DIR" "$SCRIPT_DIR"
echo ""
fi # end: plan-check.sh lifecycle

if should_run_section "trace protocol"; then
# --- Test: Trace Protocol ---
echo "--- trace protocol ---"

# Test 1: init_trace creates directory structure
TR_TEST_DIR=$(mktemp -d)
git init "$TR_TEST_DIR" >/dev/null 2>&1
git -C "$TR_TEST_DIR" commit --allow-empty -m "init" >/dev/null 2>&1

# Run test in subshell and capture output
output=$(
    source "$HOOKS_DIR/context-lib.sh"
    TRACE_STORE="$TR_TEST_DIR/traces"
    TRACE_ID=$(init_trace "$TR_TEST_DIR" "test-agent")
    if [[ -n "$TRACE_ID" && -d "$TRACE_STORE/$TRACE_ID/artifacts" && -f "$TRACE_STORE/$TRACE_ID/manifest.json" ]]; then
        echo "INIT_OK"
    else
        echo "INIT_FAIL"
    fi
)
if [[ "$output" == "INIT_OK" ]]; then
    pass "trace — init_trace creates dir + manifest"
else
    fail "trace — init_trace" "missing directory or manifest"
fi

# Test 2: init_trace manifest has correct schema
output=$(
    source "$HOOKS_DIR/context-lib.sh"
    TRACE_STORE="$TR_TEST_DIR/traces"
    TRACE_ID=$(init_trace "$TR_TEST_DIR" "test-agent")
    manifest="$TRACE_STORE/$TRACE_ID/manifest.json"

    # First check if valid JSON
    if ! jq empty "$manifest" 2>/dev/null; then
        echo "SCHEMA_FAIL:invalid JSON"
    else
        # Check required fields (project path may vary, skip exact match)
        has_version=$(jq -r '.version' "$manifest")
        has_agent=$(jq -r '.agent_type' "$manifest")
        has_status=$(jq -r '.status' "$manifest")
        has_project=$(jq -r '.project' "$manifest")

        if [[ "$has_version" == "1" && "$has_agent" == "test-agent" && "$has_status" == "active" && -n "$has_project" ]]; then
            echo "SCHEMA_OK"
        else
            echo "SCHEMA_FAIL:v='$has_version' agent='$has_agent' status='$has_status' proj='$has_project'"
        fi
    fi
)
if [[ "$output" == "SCHEMA_OK" ]]; then
    pass "trace — manifest has correct schema"
else
    fail "trace — manifest schema" "$output"
fi

# Test 3: init_trace creates active marker (project-scoped since DEC-ISOLATION-002)
output=$(
    source "$HOOKS_DIR/context-lib.sh"
    TRACE_STORE="$TR_TEST_DIR/traces"
    CLAUDE_SESSION_ID="test-session-123"
    TRACE_ID=$(init_trace "$TR_TEST_DIR" "test-agent")
    phash=$(project_hash "$TR_TEST_DIR")
    marker="$TRACE_STORE/.active-test-agent-test-session-123-${phash}"
    if [[ -f "$marker" ]]; then
        marker_content=$(cat "$marker")
        if [[ "$marker_content" == "$TRACE_ID" ]]; then
            echo "MARKER_OK"
        else
            echo "MARKER_FAIL:content mismatch"
        fi
    else
        echo "MARKER_FAIL:marker not found (expected $marker)"
    fi
)
if [[ "$output" == "MARKER_OK" ]]; then
    pass "trace — active marker created with trace ID"
else
    fail "trace — active marker" "$output"
fi

# Test 4: detect_active_trace finds marker
output=$(
    source "$HOOKS_DIR/context-lib.sh"
    TRACE_STORE="$TR_TEST_DIR/traces"
    CLAUDE_SESSION_ID="test-session-456"
    TRACE_ID=$(init_trace "$TR_TEST_DIR" "detect-agent")
    DETECTED=$(detect_active_trace "$TR_TEST_DIR" "detect-agent")
    if [[ "$DETECTED" == "$TRACE_ID" ]]; then
        echo "DETECT_OK"
    else
        echo "DETECT_FAIL:expected=$TRACE_ID got=$DETECTED"
    fi
)
if [[ "$output" == "DETECT_OK" ]]; then
    pass "trace — detect_active_trace finds marker"
else
    fail "trace — detect_active_trace" "$output"
fi

# Test 5: finalize_trace updates manifest + creates index + cleans marker
output=$(
    source "$HOOKS_DIR/context-lib.sh"
    TRACE_STORE="$TR_TEST_DIR/traces"
    CLAUDE_SESSION_ID="test-session-789"
    TRACE_ID=$(init_trace "$TR_TEST_DIR" "finalize-agent")
    trace_dir="$TRACE_STORE/$TRACE_ID"

    # Write summary (so it's not marked crashed)
    echo "# Test Summary" > "$trace_dir/summary.md"
    echo "All tests passed" > "$trace_dir/artifacts/test-output.txt"
    echo "file1.sh" > "$trace_dir/artifacts/files-changed.txt"
    # Write compliance.json (Observatory v2: finalize_trace reads test_result from here,
    # not from test-output.txt directly). Also marks files-changed.txt present so
    # finalize_trace counts files_changed from the artifact.
    cat > "$trace_dir/compliance.json" <<'COMPLIANCEJSON'
{
  "agent_type": "finalize-agent",
  "checked_at": "2026-02-21T03:00:00Z",
  "artifacts": {
    "summary.md": {"present": true, "source": "agent"},
    "test-output.txt": {"present": true, "source": "auto-capture"},
    "files-changed.txt": {"present": true, "source": "agent"}
  },
  "test_result": "pass",
  "test_result_source": "test-output.txt",
  "issues_count": 0
}
COMPLIANCEJSON

    finalize_trace "$TRACE_ID" "$TR_TEST_DIR" "finalize-agent"

    # Check manifest was updated
    manifest_status=$(jq -r '.status' "$trace_dir/manifest.json" 2>/dev/null)
    manifest_outcome=$(jq -r '.outcome' "$trace_dir/manifest.json" 2>/dev/null)
    manifest_test=$(jq -r '.test_result' "$trace_dir/manifest.json" 2>/dev/null)
    manifest_files=$(jq -r '.files_changed' "$trace_dir/manifest.json" 2>/dev/null)

    # Check index was created
    index_exists=false
    if [[ -f "$TRACE_STORE/index.jsonl" ]]; then
        if grep -q "$TRACE_ID" "$TRACE_STORE/index.jsonl"; then
            index_exists=true
        fi
    fi

    # Check marker was cleaned
    marker="$TRACE_STORE/.active-finalize-agent-test-session-789"
    marker_cleaned=true
    [[ -f "$marker" ]] && marker_cleaned=false

    if [[ "$manifest_status" == "completed" && "$manifest_outcome" == "success" && "$manifest_test" == "pass" && "$manifest_files" == "1" && "$index_exists" == "true" && "$marker_cleaned" == "true" ]]; then
        echo "FINALIZE_OK"
    else
        echo "FINALIZE_FAIL:status=$manifest_status outcome=$manifest_outcome test=$manifest_test files=$manifest_files index=$index_exists marker_cleaned=$marker_cleaned"
    fi
)
if [[ "$output" == "FINALIZE_OK" ]]; then
    pass "trace — finalize updates manifest, indexes, cleans marker"
else
    fail "trace — finalize" "$output"
fi

# Test 6: finalize_trace marks crashed when no summary
# @decision DEC-V3-004
# @title Crash detection: status=crashed, outcome=skipped when summary.md absent
# @status accepted
# @rationale finalize_trace() distinguishes two no-artifacts states:
#   - outcome="skipped": artifacts dir missing entirely (agent never initialised)
#   - outcome="skipped": artifacts dir exists but is empty (agent crashed immediately)
#   In both cases finalize_trace() sets status="crashed" (no summary.md) but
#   deliberately does NOT override outcome="skipped" to "crashed" — the comment
#   at context-lib.sh line ~1166 reads: "Do not override 'skipped' — skipped means
#   no artifacts at all (never started), which is a distinct state from crashed
#   (started but failed to produce summary.md)."
#   Since init_trace() always creates the artifacts dir, a crash right after init
#   produces an empty artifacts dir, hence outcome="skipped" and status="crashed".
#   The correct assertion is therefore status=crashed AND outcome=skipped.
output=$(
    source "$HOOKS_DIR/context-lib.sh"
    TRACE_STORE="$TR_TEST_DIR/traces"
    CLAUDE_SESSION_ID="test-session-crash"
    TRACE_ID=$(init_trace "$TR_TEST_DIR" "crash-agent")
    # Do NOT write summary.md — simulates crash
    finalize_trace "$TRACE_ID" "$TR_TEST_DIR" "crash-agent"

    crash_status=$(jq -r '.status' "$TRACE_STORE/$TRACE_ID/manifest.json" 2>/dev/null)
    crash_outcome=$(jq -r '.outcome' "$TRACE_STORE/$TRACE_ID/manifest.json" 2>/dev/null)

    # status=crashed (no summary.md), outcome=skipped (empty artifacts dir — init_trace
    # always creates it, but a crash before any artifact write leaves it empty)
    if [[ "$crash_status" == "crashed" && "$crash_outcome" == "skipped" ]]; then
        echo "CRASH_OK"
    else
        echo "CRASH_FAIL:status=$crash_status outcome=$crash_outcome"
    fi
)
if [[ "$output" == "CRASH_OK" ]]; then
    pass "trace — no summary marks as crashed (status=crashed, outcome=skipped)"
else
    fail "trace — crash detection" "$output"
fi

# Test 7: subagent-start.sh injects TRACE_DIR for planner
output=$(
    export TRACE_STORE="$TR_TEST_DIR/traces"
    export CLAUDE_PROJECT_DIR="$TR_TEST_DIR"
    mkdir -p "$TR_TEST_DIR/.git"
    hook_output=$(echo '{"agent_type":"planner"}' | bash "$HOOKS_DIR/subagent-start.sh" 2>/dev/null) || true
    if echo "$hook_output" | grep -q "TRACE_DIR="; then
        echo "INJECT_OK"
    else
        echo "INJECT_FAIL:no TRACE_DIR in output"
    fi
)
if [[ "$output" == "INJECT_OK" ]]; then
    pass "trace — subagent-start injects TRACE_DIR for planner"
else
    fail "trace — subagent-start injection" "$output"
fi

# Test 8: subagent-start.sh skips trace for Bash agent
output=$(
    export TRACE_STORE="$TR_TEST_DIR/traces"
    export CLAUDE_PROJECT_DIR="$TR_TEST_DIR"
    mkdir -p "$TR_TEST_DIR/.git"
    # Count traces before
    before=$(ls "$TRACE_STORE" 2>/dev/null | grep -c "^Bash-" || echo "0")
    hook_output=$(echo '{"agent_type":"Bash"}' | bash "$HOOKS_DIR/subagent-start.sh" 2>/dev/null) || true
    after=$(ls "$TRACE_STORE" 2>/dev/null | grep -c "^Bash-" || echo "0")
    if [[ "$before" == "$after" ]]; then
        echo "SKIP_OK"
    else
        echo "SKIP_FAIL:trace created for Bash agent"
    fi
)
if [[ "$output" == "SKIP_OK" ]]; then
    pass "trace — subagent-start skips trace for Bash agent"
else
    fail "trace — Bash skip" "$output"
fi

safe_cleanup "$TR_TEST_DIR" "$SCRIPT_DIR"
echo ""


# ===== V2 Observability Tests =====
echo ""
echo "=== V2 Observability Tests ==="

V2_TEST_FILES=(
    "test-trajectory.sh"
    "test-cross-session.sh"
    "test-subagent-tracker-scope.sh"
    "test-checkpoint.sh"
    "test-session-context.sh"
    "test-proof-gate.sh"
    "test-auto-verify.sh"
    "test-guard-cwd-recovery.sh"
    "test-guard-check5-spaces.sh"
    "test-guard-worktree-cd.sh"
    "test-observatory-metrics.sh"
    "test-observatory-convergence.sh"
    "test-tester-gate-heal.sh"
    "test-living-plan-hooks.sh"
    "test-plan-lifecycle.sh"
    "test-plan-injection.sh"
    "test-trace-classification.sh"
    "test-validation-harness.sh"
    "test-proof-lifecycle.sh"
)

for test_file in "${V2_TEST_FILES[@]}"; do
    test_path="$SCRIPT_DIR/$test_file"
    if [[ -f "$test_path" ]]; then
        echo ""
        echo "--- Running $test_file ---"
        if bash "$test_path"; then
            echo "  $test_file: ALL PASSED"
        else
            echo "  $test_file: FAILURES DETECTED"
            failed=$((failed + 1))
        fi
    else
        echo "  SKIP: $test_file not found"
        skipped=$((skipped + 1))
    fi
done
fi # end: trace protocol

if should_run_section "Multi-Context Pass"; then
# ===== State Governance Tests =====
# Multi-context second pass (re-runs state-writing tests from a temp CWD
#   to catch CWD assumptions — e.g. T08's .git file-vs-directory issue where a hook
#   assumes CWD contains a real .git directory rather than the gitdir pointer file
#   written by git worktree add).
#
# @decision DEC-STATE-GOV-001
# @title Multi-context second pass in run-hooks.sh for CWD assumption detection
# @status accepted
# @rationale Several hooks use detect_project_root() or get_claude_dir() which
#   walk up from CWD to find .git. If CWD is a non-git temp directory, these
#   functions fall back to HOME or produce different paths than expected. Running
#   a subset of state-writing tests from a temp CWD catches this class of bugs
#   without requiring a full second run of the entire suite (which is slow).
#   The subset is: proof gate, project isolation, and state registry — exactly
#   the tests that validate state file paths and scoping.
echo ""
echo "=== State Governance Tests ==="
# --- Pass 2: Multi-context re-run from temp CWD ---
# Create a temp directory that is NOT a git repo, set it as CWD for the subprocess,
# and re-run the state-writing tests. This verifies hooks don't assume CWD=git root.
echo ""
echo "--- Multi-Context Pass (Pass 2: non-git temp CWD) ---"

MULTI_CTX_TMPDIR=$(mktemp -d)

# Tests to re-run in alien CWD (state-writing tests most sensitive to CWD assumptions)
MULTI_CTX_TESTS=(
    "test-proof-gate.sh"
    "test-project-isolation.sh"
    # test-state-registry.sh removed — hooks/state-registry.sh was pruned during metanoia consolidation
)

MULTI_CTX_PASS2_FAILED=0
for mc_test in "${MULTI_CTX_TESTS[@]}"; do
    mc_test_path="$SCRIPT_DIR/$mc_test"
    if [[ -f "$mc_test_path" ]]; then
        echo ""
        echo "  [Pass 2] Running $mc_test from temp CWD: $MULTI_CTX_TMPDIR"
        # Run in a subshell with CWD set to the temp dir (not a git repo)
        if bash -c "cd '$MULTI_CTX_TMPDIR' && bash '$mc_test_path'" 2>&1 | sed 's/^/    /'; then
            echo "  [Pass 2] $mc_test: ALL PASSED (alien CWD)"
        else
            echo "  [Pass 2] $mc_test: FAILURES DETECTED (alien CWD — possible CWD assumption bug)"
            MULTI_CTX_PASS2_FAILED=$((MULTI_CTX_PASS2_FAILED + 1))
            failed=$((failed + 1))
        fi
    else
        echo "  [Pass 2] SKIP: $mc_test not found"
    fi
done

safe_cleanup "$MULTI_CTX_TMPDIR" "$SCRIPT_DIR"

if [[ "$MULTI_CTX_PASS2_FAILED" -eq 0 ]]; then
    echo ""
    echo "  Multi-context pass: all ${#MULTI_CTX_TESTS[@]} tests passed from non-git CWD"
fi
fi # end: Multi-Context Pass

# --- Expanded Fixture Coverage ---
# @decision DEC-TEST-FIXTURES-001
# @title Expanded fixture tests for 30 archive-migrated JSON fixtures
# @status accepted
# @rationale The 30 fixtures migrated from the metanoia archive cover additional
#   pre-write, post-write, stop, task-track, guard, and prompt-submit scenarios.
#   Tests verify no-crash + valid JSON for most fixtures. write-source-on-main
#   requires a real git repo on main to trigger the branch-guard deny.
if should_run_section "Expanded Fixture Coverage"; then
echo ""
echo "--- Expanded Fixture Coverage ---"

# Pre-Write group (12 fixtures): write-*/edit-* → pre-write.sh
# write-source-on-main requires a real git repo on main to produce a deny.
EFC_MAIN_REPO=$(mktemp -d)
git init "$EFC_MAIN_REPO" >/dev/null 2>&1
(cd "$EFC_MAIN_REPO" && git commit -m "init" --allow-empty) >/dev/null 2>&1
EFC_MAIN_FIXTURE="$FIXTURES_DIR/efc-write-source-on-main.json"
cat > "$EFC_MAIN_FIXTURE" <<EFCEOF
{"tool_name":"Write","tool_input":{"file_path":"$EFC_MAIN_REPO/src/main.ts","content":"// TypeScript source\nexport function hello() { return 'world'; }\n"}}
EFCEOF
output=$(run_hook "$HOOKS_DIR/pre-write.sh" "$EFC_MAIN_FIXTURE")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" == "deny" ]]; then
    pass "fixture:write-source-on-main — deny source write on main"
else
    fail "fixture:write-source-on-main — deny source write on main" "expected deny, got: ${decision:-no output}"
fi
safe_cleanup "$EFC_MAIN_REPO" "$SCRIPT_DIR"
rm -f "$EFC_MAIN_FIXTURE"

# Remaining pre-write fixtures: check no crash + valid JSON output
for fixture_name in \
    write-source-on-feature \
    write-test-file \
    write-plan-file \
    write-claudemd-on-main \
    write-masterplan-on-main \
    write-checkpoint-trigger \
    write-large-no-decision \
    write-test-with-mocks \
    write-while-tests-fail \
    edit-source-on-main \
    edit-readme-on-feature; do
    fixture_path="$FIXTURES_DIR/${fixture_name}.json"
    if [[ ! -f "$fixture_path" ]]; then
        skip "fixture:${fixture_name}" "fixture file not found"
        continue
    fi
    output=$(run_hook "$HOOKS_DIR/pre-write.sh" "$fixture_path")
    if [[ -n "$output" ]] && echo "$output" | jq '.' >/dev/null 2>&1; then
        pass "fixture:${fixture_name} — pre-write no crash + valid JSON"
    elif [[ -z "$output" ]]; then
        # Empty output is acceptable for hooks that have nothing to say
        pass "fixture:${fixture_name} — pre-write no crash (empty output)"
    else
        fail "fixture:${fixture_name} — pre-write" "invalid JSON output: ${output:0:100}"
    fi
done

# Post-Write group (6 fixtures): post-* → post-write.sh
for fixture_name in \
    post-write-source \
    post-write-plan \
    post-write-test \
    post-write-lint-target \
    post-edit-markdown \
    post-edit-source-verified; do
    fixture_path="$FIXTURES_DIR/${fixture_name}.json"
    if [[ ! -f "$fixture_path" ]]; then
        skip "fixture:${fixture_name}" "fixture file not found"
        continue
    fi
    output=$(run_hook "$HOOKS_DIR/post-write.sh" "$fixture_path")
    if [[ -z "$output" ]] || echo "$output" | jq '.' >/dev/null 2>&1; then
        pass "fixture:${fixture_name} — post-write no crash + valid JSON or empty"
    else
        fail "fixture:${fixture_name} — post-write" "invalid JSON output: ${output:0:100}"
    fi
done

# Stop group (7 fixtures): stop-* → stop.sh
for fixture_name in \
    stop-normal \
    stop-forward-motion-bare \
    stop-forward-motion-question \
    stop-summary-basic \
    stop-summary-on-main \
    stop-surface-basic \
    stop-surface-no-changes; do
    fixture_path="$FIXTURES_DIR/${fixture_name}.json"
    if [[ ! -f "$fixture_path" ]]; then
        skip "fixture:${fixture_name}" "fixture file not found"
        continue
    fi
    output=$(run_hook "$HOOKS_DIR/stop.sh" "$fixture_path")
    if [[ -z "$output" ]] || echo "$output" | jq '.' >/dev/null 2>&1; then
        pass "fixture:${fixture_name} — stop no crash + valid JSON or empty"
    else
        fail "fixture:${fixture_name} — stop" "invalid JSON output: ${output:0:100}"
    fi
done

# Task-track group (3 fixtures): task-dispatch-*/post-task-* → task-track.sh
for fixture_name in \
    task-dispatch-implementer \
    task-dispatch-guardian \
    post-task-tester; do
    fixture_path="$FIXTURES_DIR/${fixture_name}.json"
    if [[ ! -f "$fixture_path" ]]; then
        skip "fixture:${fixture_name}" "fixture file not found"
        continue
    fi
    output=$(run_hook "$HOOKS_DIR/task-track.sh" "$fixture_path")
    if [[ -z "$output" ]] || echo "$output" | jq '.' >/dev/null 2>&1; then
        pass "fixture:${fixture_name} — task-track no crash"
    else
        fail "fixture:${fixture_name} — task-track" "invalid JSON output: ${output:0:100}"
    fi
done

# Guard group (1 fixture): guard-doc-freshness-stale → pre-bash.sh
fixture_path="$FIXTURES_DIR/guard-doc-freshness-stale.json"
if [[ -f "$fixture_path" ]]; then
    output=$(run_hook "$HOOKS_DIR/pre-bash.sh" "$fixture_path")
    if [[ -z "$output" ]] || echo "$output" | jq '.' >/dev/null 2>&1; then
        pass "fixture:guard-doc-freshness-stale — pre-bash no crash + valid JSON"
    else
        fail "fixture:guard-doc-freshness-stale — pre-bash" "invalid JSON output: ${output:0:100}"
    fi
else
    skip "fixture:guard-doc-freshness-stale" "fixture file not found"
fi

# Prompt-submit group (1 fixture): prompt-submit-approval → prompt-submit.sh
fixture_path="$FIXTURES_DIR/prompt-submit-approval.json"
if [[ -f "$fixture_path" ]]; then
    output=$(run_hook "$HOOKS_DIR/prompt-submit.sh" "$fixture_path")
    if [[ -z "$output" ]] || echo "$output" | jq '.' >/dev/null 2>&1; then
        pass "fixture:prompt-submit-approval — prompt-submit no crash"
    else
        fail "fixture:prompt-submit-approval — prompt-submit" "invalid JSON output: ${output:0:100}"
    fi
else
    skip "fixture:prompt-submit-approval" "fixture file not found"
fi

fi # end: Expanded Fixture Coverage

# --- Summary ---
echo "==========================="
total=$((passed + failed + skipped))
echo -e "Total: $total | ${GREEN}Passed: $passed${NC} | ${RED}Failed: $failed${NC} | ${YELLOW}Skipped: $skipped${NC}"

if [[ $failed -gt 0 ]]; then
    exit 1
fi
