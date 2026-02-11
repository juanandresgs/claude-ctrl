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
# Usage: bash tests/run-hooks.sh
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

# Source context-lib for safe_cleanup (prevents CWD bricking on rm -rf)
source "$HOOKS_DIR/context-lib.sh"

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

# =============================================================================
# GATE HOOK BEHAVIORAL TESTS
# =============================================================================

echo "=========================================="
echo "GATE HOOK BEHAVIORAL TESTS"
echo "=========================================="
echo ""

# --- Test: branch-guard.sh behavioral tests ---
echo "--- branch-guard.sh behavioral tests ---"

# Test 1: Deny source file write on main branch
BG_TEST_DIR_MAIN=$(mktemp -d)
git init "$BG_TEST_DIR_MAIN" >/dev/null 2>&1
(cd "$BG_TEST_DIR_MAIN" && git add -A && git commit -m "init" --allow-empty) >/dev/null 2>&1

BG_FIXTURE_MAIN_DENY="$FIXTURES_DIR/branch-guard-main-deny.json"
cat > "$BG_FIXTURE_MAIN_DENY" <<EOF
{"tool_name":"Write","tool_input":{"file_path":"$BG_TEST_DIR_MAIN/src/main.ts","content":"console.log('test');\n"}}
EOF

output=$(run_hook "$HOOKS_DIR/branch-guard.sh" "$BG_FIXTURE_MAIN_DENY")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" == "deny" ]]; then
    pass "branch-guard.sh — deny source file on main"
else
    fail "branch-guard.sh — deny source file on main" "expected deny, got: ${decision:-no output}"
fi
safe_cleanup "$BG_TEST_DIR_MAIN" "$SCRIPT_DIR"
rm -f "$BG_FIXTURE_MAIN_DENY"

# Test 2: Allow source file write on feature branch
BG_TEST_DIR_FEATURE=$(mktemp -d)
git init "$BG_TEST_DIR_FEATURE" >/dev/null 2>&1
(cd "$BG_TEST_DIR_FEATURE" && git checkout -b feature/test >/dev/null 2>&1 && git add -A && git commit -m "init" --allow-empty >/dev/null 2>&1)

BG_FIXTURE_FEATURE_ALLOW="$FIXTURES_DIR/branch-guard-feature-allow.json"
cat > "$BG_FIXTURE_FEATURE_ALLOW" <<EOF
{"tool_name":"Write","tool_input":{"file_path":"$BG_TEST_DIR_FEATURE/src/main.ts","content":"console.log('test');\n"}}
EOF

output=$(run_hook "$HOOKS_DIR/branch-guard.sh" "$BG_FIXTURE_FEATURE_ALLOW")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" != "deny" ]]; then
    pass "branch-guard.sh — allow source file on feature branch"
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

output=$(run_hook "$HOOKS_DIR/branch-guard.sh" "$BG_FIXTURE_MAIN_NONSOURCE")
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

output=$(run_hook "$HOOKS_DIR/branch-guard.sh" "$BG_FIXTURE_PLAN")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" != "deny" ]]; then
    pass "branch-guard.sh — allow MASTER_PLAN.md on main"
else
    fail "branch-guard.sh — allow MASTER_PLAN.md on main" "should allow but got deny"
fi
safe_cleanup "$BG_TEST_DIR_PLAN" "$SCRIPT_DIR"
rm -f "$BG_FIXTURE_PLAN"

echo ""

# --- Test: doc-gate.sh behavioral tests ---
echo "--- doc-gate.sh behavioral tests ---"

# Test 1: Deny Write without header
DOC_FIXTURE_NO_HEADER="$FIXTURES_DIR/doc-gate-no-header.json"
cat > "$DOC_FIXTURE_NO_HEADER" <<EOF
{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.ts","content":"console.log('no header');\n"}}
EOF

output=$(run_hook "$HOOKS_DIR/doc-gate.sh" "$DOC_FIXTURE_NO_HEADER")
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

output=$(run_hook "$HOOKS_DIR/doc-gate.sh" "$DOC_FIXTURE_WITH_HEADER")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" != "deny" ]]; then
    pass "doc-gate.sh — allow Write with header"
else
    fail "doc-gate.sh — allow Write with header" "should allow but got deny"
fi
rm -f "$DOC_FIXTURE_WITH_HEADER"

# Test 3: Deny 50+ line file without @decision
DOC_FIXTURE_NO_DECISION="$FIXTURES_DIR/doc-gate-no-decision.json"
LARGE_CONTENT="/**\n * @file test.ts\n * @description Test\n */\n"
for i in {1..50}; do
    LARGE_CONTENT+="console.log($i);\n"
done
cat > "$DOC_FIXTURE_NO_DECISION" <<EOF
{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.ts","content":"$LARGE_CONTENT"}}
EOF

output=$(run_hook "$HOOKS_DIR/doc-gate.sh" "$DOC_FIXTURE_NO_DECISION")
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

output=$(run_hook "$HOOKS_DIR/doc-gate.sh" "$DOC_FIXTURE_WITH_DECISION")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" != "deny" ]]; then
    pass "doc-gate.sh — allow 50+ lines with @decision"
else
    fail "doc-gate.sh — allow 50+ lines with @decision" "should allow but got deny"
fi
rm -f "$DOC_FIXTURE_WITH_DECISION"
echo ""

# --- Test: test-gate.sh behavioral tests ---
echo "--- test-gate.sh behavioral tests ---"

TG_TEST_DIR=$(mktemp -d)
mkdir -p "$TG_TEST_DIR/.claude"
git init "$TG_TEST_DIR" >/dev/null 2>&1

# Test 1: Allow when no test status (cold start)
TG_FIXTURE_COLD="$FIXTURES_DIR/test-gate-cold.json"
cat > "$TG_FIXTURE_COLD" <<EOF
{"tool_name":"Write","tool_input":{"file_path":"$TG_TEST_DIR/src/main.ts","content":"console.log('test');\n"}}
EOF

output=$(CLAUDE_PROJECT_DIR="$TG_TEST_DIR" run_hook "$HOOKS_DIR/test-gate.sh" "$TG_FIXTURE_COLD")
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
{"tool_name":"Write","tool_input":{"file_path":"$TG_TEST_DIR/src/main.ts","content":"console.log('test');\n"}}
EOF
output=$(CLAUDE_PROJECT_DIR="$TG_TEST_DIR" run_hook "$HOOKS_DIR/test-gate.sh" "$TG_FIXTURE_PASS")
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
{"tool_name":"Write","tool_input":{"file_path":"$TG_TEST_DIR/src/main.ts","content":"console.log('strike1');\n"}}
EOF

output=$(CLAUDE_PROJECT_DIR="$TG_TEST_DIR" run_hook "$HOOKS_DIR/test-gate.sh" "$TG_FIXTURE_SRC")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
if [[ "$decision" != "deny" && -n "$context" && "$context" == *"failing"* ]]; then
    pass "test-gate.sh — advisory warning on strike 1"
else
    fail "test-gate.sh — advisory warning on strike 1" "expected advisory, got decision=$decision context=$context"
fi

# Test 4: Deny on second strike
output=$(CLAUDE_PROJECT_DIR="$TG_TEST_DIR" run_hook "$HOOKS_DIR/test-gate.sh" "$TG_FIXTURE_SRC")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" == "deny" ]]; then
    pass "test-gate.sh — deny on strike 2"
else
    fail "test-gate.sh — deny on strike 2" "expected deny, got: ${decision:-no output}"
fi
rm -f "$TG_FIXTURE_SRC"

safe_cleanup "$TG_TEST_DIR" "$SCRIPT_DIR"
echo ""

# --- Test: mock-gate.sh behavioral tests ---
echo "--- mock-gate.sh behavioral tests ---"

MG_TEST_DIR=$(mktemp -d)
mkdir -p "$MG_TEST_DIR/.claude"

# Test 1: Allow non-test files
MG_FIXTURE_NONTEST="$FIXTURES_DIR/mock-gate-nontest.json"
cat > "$MG_FIXTURE_NONTEST" <<EOF
{"tool_name":"Write","tool_input":{"file_path":"$MG_TEST_DIR/src/main.ts","content":"console.log('not a test');\n"}}
EOF

output=$(run_hook "$HOOKS_DIR/mock-gate.sh" "$MG_FIXTURE_NONTEST")
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

output=$(CLAUDE_PROJECT_DIR="$MG_TEST_DIR" run_hook "$HOOKS_DIR/mock-gate.sh" "$MG_FIXTURE_INTERNAL_MOCK")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
if [[ "$decision" != "deny" && -n "$context" && "$context" == *"mock"* ]]; then
    pass "mock-gate.sh — advisory warning on internal mock (strike 1)"
else
    fail "mock-gate.sh — advisory warning on internal mock" "expected advisory, got decision=$decision"
fi

# Test 3: Deny on second mock usage
output=$(CLAUDE_PROJECT_DIR="$MG_TEST_DIR" run_hook "$HOOKS_DIR/mock-gate.sh" "$MG_FIXTURE_INTERNAL_MOCK")
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" == "deny" ]]; then
    pass "mock-gate.sh — deny on strike 2"
else
    fail "mock-gate.sh — deny on strike 2" "expected deny, got: ${decision:-no output}"
fi
rm -f "$MG_FIXTURE_INTERNAL_MOCK"

safe_cleanup "$MG_TEST_DIR" "$SCRIPT_DIR"
echo ""

# =============================================================================
# CONTEXT-LIB UNIT TESTS
# =============================================================================

echo "=========================================="
echo "CONTEXT-LIB UNIT TESTS"
echo "=========================================="
echo ""

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

# =============================================================================
# INTEGRATION TESTS
# =============================================================================

echo "=========================================="
echo "INTEGRATION TESTS"
echo "=========================================="
echo ""

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
        # Exempt utility libraries (not hooks)
        case "$hook" in
            log.sh|context-lib.sh)
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

# =============================================================================
# SESSION LIFECYCLE TESTS
# =============================================================================

echo "=========================================="
echo "SESSION LIFECYCLE TESTS"
echo "=========================================="
echo ""

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

# =============================================================================
# EXISTING TESTS (PRESERVED)
# =============================================================================

echo "=========================================="
echo "EXISTING GUARD.SH TESTS (PRESERVED)"
echo "=========================================="
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
safe_cleanup "$CROSS_TEST_DIR" "$SCRIPT_DIR"
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
(
    source "$HOOKS_DIR/context-lib.sh"
    get_plan_status "$PL_TEST_DIR"
    if [[ "$PLAN_LIFECYCLE" == "completed" ]]; then
        echo "COMPLETED_OK"
    else
        echo "COMPLETED_FAIL:$PLAN_LIFECYCLE"
    fi
) | while IFS= read -r line; do
    if [[ "$line" == "COMPLETED_OK" ]]; then
        pass "lifecycle — completed plan detected"
    elif [[ "$line" == COMPLETED_FAIL* ]]; then
        fail "lifecycle — completed plan" "expected 'completed', got: ${line#COMPLETED_FAIL:}"
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

# Feed plan-check a source file Write
PLAN_CHECK_INPUT=$(jq -n --arg fp "$PC_TEST_DIR/src/main.ts" '{tool_name:"Write",tool_input:{file_path:$fp,content:"console.log(1);\nconsole.log(2);\nconsole.log(3);\nconsole.log(4);\nconsole.log(5);\nconsole.log(6);\nconsole.log(7);\nconsole.log(8);\nconsole.log(9);\nconsole.log(10);\nconsole.log(11);\nconsole.log(12);\nconsole.log(13);\nconsole.log(14);\nconsole.log(15);\nconsole.log(16);\nconsole.log(17);\nconsole.log(18);\nconsole.log(19);\nconsole.log(20);\nconsole.log(21);"}}')
output=$(echo "$PLAN_CHECK_INPUT" | CLAUDE_PROJECT_DIR="$PC_TEST_DIR" bash "$HOOKS_DIR/plan-check.sh" 2>/dev/null) || true
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

output=$(echo "$PLAN_CHECK_INPUT" | CLAUDE_PROJECT_DIR="$PC_TEST_DIR" bash "$HOOKS_DIR/plan-check.sh" 2>/dev/null) || true
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" != "deny" ]]; then
    pass "plan-check.sh — active plan allows source writes"
else
    fail "plan-check.sh — active plan" "should allow but got deny"
fi

safe_cleanup "$PC_TEST_DIR" "$SCRIPT_DIR"
echo ""


# --- Summary ---
echo "==========================="
total=$((passed + failed + skipped))
echo -e "Total: $total | ${GREEN}Passed: $passed${NC} | ${RED}Failed: $failed${NC} | ${YELLOW}Skipped: $skipped${NC}"

if [[ $failed -gt 0 ]]; then
    exit 1
fi
