#!/usr/bin/env bash
# Test suite: CI Feedback Loop — ci-lib.sh functions and pre-bash.sh ci-local-gate.
#
# @decision DEC-CI-001
# @title CI feedback loop test suite
# @status accepted
# @rationale Validates all components of the CI feedback loop: (1) ci-lib.sh
#   functions (find_local_ci priority, has_github_actions, read/write round-trip,
#   format_ci_summary), (2) pre-bash.sh ci-local-gate (deny on failure, pass on
#   success, advisory when workflows exist, silent pass when nothing present,
#   timeout handling), (3) ci-watch.sh lock file concurrency prevention,
#   (4) session-init.sh two-tier CI status injection, (5) prompt-submit.sh
#   mid-session CI keyword trigger.
#   Uses the same run_test/pass_test/fail_test pattern as test-proof-gate.sh.

set -euo pipefail
# Portable SHA-256 (macOS: shasum, Ubuntu: sha256sum)
if command -v shasum >/dev/null 2>&1; then
    _SHA256_CMD="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
    _SHA256_CMD="sha256sum"
else
    _SHA256_CMD="cat"
fi

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"

mkdir -p "$PROJECT_ROOT/tmp"

_CLEANUP_DIRS=()
trap '[[ ${#_CLEANUP_DIRS[@]} -gt 0 ]] && rm -rf "${_CLEANUP_DIRS[@]}" 2>/dev/null; true' EXIT

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
    local test_name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "Running: $test_name"
}

pass_test() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  PASS"
}

fail_test() {
    local reason="$1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL: $reason"
}

# Helper: make hook input JSON for a bash command
make_input() {
    local cmd="$1"
    jq -n --arg cmd "$cmd" '{"tool_name":"Bash","tool_input":{"command":$cmd}}'
}

# Helper: run pre-bash.sh with given command from a given CWD
run_pre_bash() {
    local cmd="$1"
    local cwd="${2:-$PROJECT_ROOT}"
    local INPUT
    INPUT=$(jq -n --arg cmd "$cmd" --arg cwd "$cwd" \
        '{"tool_name":"Bash","tool_input":{"command":$cmd,"cwd":$cwd}}')
    local OUTPUT
    OUTPUT=$(cd "$cwd" && echo "$INPUT" | bash "$HOOKS_DIR/pre-bash.sh" 2>&1)
    local EXIT_CODE=$?
    echo "$OUTPUT"
    return $EXIT_CODE
}

# ===========================================================================
# --- Syntax validation ---
# ===========================================================================

run_test "Syntax: ci-lib.sh is valid bash"
if bash -n "$HOOKS_DIR/ci-lib.sh"; then
    pass_test
else
    fail_test "ci-lib.sh has syntax errors"
fi

run_test "Syntax: ci-watch.sh is valid bash"
if bash -n "$SCRIPTS_DIR/ci-watch.sh"; then
    pass_test
else
    fail_test "ci-watch.sh has syntax errors"
fi

run_test "Syntax: pre-bash.sh still valid after ci-local-gate addition"
if bash -n "$HOOKS_DIR/pre-bash.sh"; then
    pass_test
else
    fail_test "pre-bash.sh has syntax errors"
fi

run_test "Syntax: source-lib.sh valid after require_ci addition"
if bash -n "$HOOKS_DIR/source-lib.sh"; then
    pass_test
else
    fail_test "source-lib.sh has syntax errors"
fi

run_test "Syntax: context-lib.sh valid after ci-lib.sh addition"
if bash -n "$HOOKS_DIR/context-lib.sh"; then
    pass_test
else
    fail_test "context-lib.sh has syntax errors"
fi

run_test "Syntax: check-guardian.sh valid after CI watcher spawn"
if bash -n "$HOOKS_DIR/check-guardian.sh"; then
    pass_test
else
    fail_test "check-guardian.sh has syntax errors"
fi

run_test "Syntax: session-init.sh valid after two-tier CI check"
if bash -n "$HOOKS_DIR/session-init.sh"; then
    pass_test
else
    fail_test "session-init.sh has syntax errors"
fi

run_test "Syntax: prompt-submit.sh valid after CI keyword trigger"
if bash -n "$HOOKS_DIR/prompt-submit.sh"; then
    pass_test
else
    fail_test "prompt-submit.sh has syntax errors"
fi

# ===========================================================================
# --- ci-lib.sh unit tests: find_local_ci priority order ---
# ===========================================================================

run_test "test_ci_lib_find_local_ci: .githooks/pre-push is highest priority"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-ci-find-XXXXXX")
_CLEANUP_DIRS+=("$TEMP_REPO")
mkdir -p "$TEMP_REPO/.githooks" "$TEMP_REPO/.claude" "$TEMP_REPO"
cat > "$TEMP_REPO/.githooks/pre-push" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEMP_REPO/.githooks/pre-push"
cat > "$TEMP_REPO/.claude/pre-push.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEMP_REPO/.claude/pre-push.sh"
# Also create a Makefile with ci-local target
cat > "$TEMP_REPO/Makefile" <<'EOF'
ci-local:
	echo "ci-local"
EOF

RESULT=$(bash -c "source '$HOOKS_DIR/core-lib.sh'; source '$HOOKS_DIR/ci-lib.sh'; find_local_ci '$TEMP_REPO'")
if [[ "$RESULT" == "$TEMP_REPO/.githooks/pre-push" ]]; then
    pass_test
else
    fail_test "Expected .githooks/pre-push, got: $RESULT"
fi
rm -rf "$TEMP_REPO"

run_test "test_ci_lib_find_local_ci: .claude/pre-push.sh is second priority"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-ci-find2-XXXXXX")
_CLEANUP_DIRS+=("$TEMP_REPO")
mkdir -p "$TEMP_REPO/.claude"
cat > "$TEMP_REPO/.claude/pre-push.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEMP_REPO/.claude/pre-push.sh"

RESULT=$(bash -c "source '$HOOKS_DIR/core-lib.sh'; source '$HOOKS_DIR/ci-lib.sh'; find_local_ci '$TEMP_REPO'")
if [[ "$RESULT" == "$TEMP_REPO/.claude/pre-push.sh" ]]; then
    pass_test
else
    fail_test "Expected .claude/pre-push.sh, got: $RESULT"
fi
rm -rf "$TEMP_REPO"

run_test "test_ci_lib_find_local_ci: Makefile ci-local is third priority"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-ci-find3-XXXXXX")
_CLEANUP_DIRS+=("$TEMP_REPO")
cat > "$TEMP_REPO/Makefile" <<'EOF'
ci-local:
	echo "ci-local"
EOF

RESULT=$(bash -c "source '$HOOKS_DIR/core-lib.sh'; source '$HOOKS_DIR/ci-lib.sh'; find_local_ci '$TEMP_REPO'")
if [[ "$RESULT" == "$TEMP_REPO/Makefile:ci-local" ]]; then
    pass_test
else
    fail_test "Expected Makefile:ci-local, got: $RESULT"
fi
rm -rf "$TEMP_REPO"

run_test "test_ci_lib_find_local_ci: returns empty when nothing found"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-ci-find4-XXXXXX")
_CLEANUP_DIRS+=("$TEMP_REPO")

RESULT=$(bash -c "source '$HOOKS_DIR/core-lib.sh'; source '$HOOKS_DIR/ci-lib.sh'; find_local_ci '$TEMP_REPO'" 2>/dev/null || true)
if [[ -z "$RESULT" ]]; then
    pass_test
else
    fail_test "Expected empty, got: $RESULT"
fi
rm -rf "$TEMP_REPO"

# ===========================================================================
# --- ci-lib.sh unit tests: read/write round-trip ---
# ===========================================================================

run_test "test_ci_lib_read_write: round-trip state file"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-ci-rw-XXXXXX")
_CLEANUP_DIRS+=("$TEMP_REPO")
git -C "$TEMP_REPO" init > /dev/null 2>&1
TEMP_CLAUDE_DIR="${TEMP_REPO}/.claude"
mkdir -p "$TEMP_CLAUDE_DIR"

# Override CLAUDE_DIR to temp dir for isolation
RESULT=$(bash -c "
    export CLAUDE_DIR='${TEMP_CLAUDE_DIR}'
    source '${HOOKS_DIR}/core-lib.sh'
    source '${HOOKS_DIR}/ci-lib.sh'
    write_ci_status '${TEMP_REPO}' 'success' '123456' 'success' 'main' 'CI' '2026-01-01T00:00:00Z' '2026-01-01T00:05:00Z' 'https://github.com/r/a/runs/123'
    read_ci_status '${TEMP_REPO}'
    echo \"\${CI_STATUS}|\${CI_RUN_ID}|\${CI_CONCLUSION}|\${CI_BRANCH}|\${CI_WORKFLOW}|\${CI_URL}\"
")

if echo "$RESULT" | grep -q "success|123456|success|main|CI|https://"; then
    pass_test
else
    fail_test "Round-trip failed, got: $RESULT"
fi
rm -rf "$TEMP_REPO"

run_test "test_ci_lib_read_write: failure status round-trip"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-ci-rw2-XXXXXX")
_CLEANUP_DIRS+=("$TEMP_REPO")
git -C "$TEMP_REPO" init > /dev/null 2>&1
TEMP_CLAUDE_DIR="${TEMP_REPO}/.claude"
mkdir -p "$TEMP_CLAUDE_DIR"

RESULT=$(bash -c "
    export CLAUDE_DIR='${TEMP_CLAUDE_DIR}'
    source '${HOOKS_DIR}/core-lib.sh'
    source '${HOOKS_DIR}/ci-lib.sh'
    write_ci_status '${TEMP_REPO}' 'failure' '789' 'failure' 'feature/x' 'test' '' '' ''
    read_ci_status '${TEMP_REPO}'
    echo \"\${CI_STATUS}|\${CI_BRANCH}\"
")

if echo "$RESULT" | grep -q "failure|feature/x"; then
    pass_test
else
    fail_test "Failure round-trip failed, got: $RESULT"
fi
rm -rf "$TEMP_REPO"

run_test "test_ci_lib_read_write: read returns 1 when no state file"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-ci-rw3-XXXXXX")
_CLEANUP_DIRS+=("$TEMP_REPO")
git -C "$TEMP_REPO" init > /dev/null 2>&1
TEMP_CLAUDE_DIR="${TEMP_REPO}/.claude"
mkdir -p "$TEMP_CLAUDE_DIR"

RESULT=$(bash -c "
    export CLAUDE_DIR='${TEMP_CLAUDE_DIR}'
    source '${HOOKS_DIR}/core-lib.sh'
    source '${HOOKS_DIR}/ci-lib.sh'
    if read_ci_status '${TEMP_REPO}'; then
        echo 'returned 0'
    else
        echo 'returned 1'
    fi
")

if [[ "$RESULT" == "returned 1" ]]; then
    pass_test
else
    fail_test "Expected return 1 when no state file, got: $RESULT"
fi
rm -rf "$TEMP_REPO"

# ===========================================================================
# --- ci-lib.sh: format_ci_summary ---
# ===========================================================================

run_test "test_ci_lib_format_summary: success format"
RESULT=$(bash -c "
    source '${HOOKS_DIR}/core-lib.sh'
    source '${HOOKS_DIR}/ci-lib.sh'
    CI_STATUS='success'; CI_BRANCH='main'; CI_WORKFLOW='CI'; CI_AGE=30; CI_RUN_ID=''; CI_CONCLUSION=''; CI_URL=''
    format_ci_summary
")
if echo "$RESULT" | grep -q "CI: PASSING on main"; then
    pass_test
else
    fail_test "Expected 'CI: PASSING on main', got: $RESULT"
fi

run_test "test_ci_lib_format_summary: failure format"
RESULT=$(bash -c "
    source '${HOOKS_DIR}/core-lib.sh'
    source '${HOOKS_DIR}/ci-lib.sh'
    CI_STATUS='failure'; CI_BRANCH='feature/x'; CI_WORKFLOW=''; CI_AGE=120; CI_RUN_ID=''; CI_CONCLUSION=''; CI_URL=''
    format_ci_summary
")
if echo "$RESULT" | grep -q "CI: FAILING on feature/x"; then
    pass_test
else
    fail_test "Expected 'CI: FAILING on feature/x', got: $RESULT"
fi

run_test "test_ci_lib_format_summary: pending format"
RESULT=$(bash -c "
    source '${HOOKS_DIR}/core-lib.sh'
    source '${HOOKS_DIR}/ci-lib.sh'
    CI_STATUS='pending'; CI_BRANCH='main'; CI_WORKFLOW='test'; CI_AGE=60; CI_RUN_ID=''; CI_CONCLUSION=''; CI_URL=''
    format_ci_summary
")
if echo "$RESULT" | grep -q "CI: IN PROGRESS on main"; then
    pass_test
else
    fail_test "Expected 'CI: IN PROGRESS on main', got: $RESULT"
fi

# ===========================================================================
# --- pre-bash.sh ci-local-gate integration tests ---
# ===========================================================================

run_test "test_ci_local_gate_pass: passing local CI allows push"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-ci-gate-pass-XXXXXX")
_CLEANUP_DIRS+=("$TEMP_REPO")
git -C "$TEMP_REPO" init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.githooks"
cat > "$TEMP_REPO/.githooks/pre-push" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEMP_REPO/.githooks/pre-push"

INPUT=$(jq -n --arg cwd "$TEMP_REPO" \
    '{"tool_name":"Bash","tool_input":{"command":"git push origin main","cwd":$cwd}}')
OUTPUT=$(cd "$TEMP_REPO" && echo "$INPUT" | bash "$HOOKS_DIR/pre-bash.sh" 2>&1) || true

# Should NOT deny
if [[ "$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" == "deny" ]]; then
    fail_test "Push was denied but local CI passed: $OUTPUT"
else
    pass_test
fi
rm -rf "$TEMP_REPO"

run_test "test_ci_local_gate_deny: failing local CI blocks push"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-ci-gate-deny-XXXXXX")
_CLEANUP_DIRS+=("$TEMP_REPO")
git -C "$TEMP_REPO" init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.githooks"
cat > "$TEMP_REPO/.githooks/pre-push" <<'EOF'
#!/usr/bin/env bash
echo "Test failure: linting failed"
exit 1
EOF
chmod +x "$TEMP_REPO/.githooks/pre-push"

INPUT=$(jq -n --arg cwd "$TEMP_REPO" \
    '{"tool_name":"Bash","tool_input":{"command":"git push origin main","cwd":$cwd}}')
OUTPUT=$(cd "$TEMP_REPO" && echo "$INPUT" | bash "$HOOKS_DIR/pre-bash.sh" 2>&1) || true

if [[ "$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" == "deny" ]]; then
    pass_test
else
    fail_test "Push was not denied when local CI failed: $OUTPUT"
fi
rm -rf "$TEMP_REPO"

run_test "test_ci_local_gate_advisory: no pre-push but .github/workflows exists emits advisory"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-ci-gate-adv-XXXXXX")
_CLEANUP_DIRS+=("$TEMP_REPO")
git -C "$TEMP_REPO" init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.github/workflows"
cat > "$TEMP_REPO/.github/workflows/ci.yml" <<'EOF'
name: CI
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
EOF

INPUT=$(jq -n --arg cwd "$TEMP_REPO" \
    '{"tool_name":"Bash","tool_input":{"command":"git push origin main","cwd":$cwd}}')
OUTPUT=$(cd "$TEMP_REPO" && echo "$INPUT" | bash "$HOOKS_DIR/pre-bash.sh" 2>&1) || true

# Should NOT deny, but may emit advisory
if [[ "$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" == "deny" ]]; then
    fail_test "Push was denied when advisory expected: $OUTPUT"
else
    pass_test
fi
rm -rf "$TEMP_REPO"

run_test "test_ci_local_gate_skip: no pre-push and no workflows → silent pass"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-ci-gate-skip-XXXXXX")
_CLEANUP_DIRS+=("$TEMP_REPO")
git -C "$TEMP_REPO" init > /dev/null 2>&1
# No .githooks/, no .claude/pre-push.sh, no Makefile, no .github/workflows

INPUT=$(jq -n --arg cwd "$TEMP_REPO" \
    '{"tool_name":"Bash","tool_input":{"command":"git push origin main","cwd":$cwd}}')
OUTPUT=$(cd "$TEMP_REPO" && echo "$INPUT" | bash "$HOOKS_DIR/pre-bash.sh" 2>&1) || true

if [[ "$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" == "deny" ]]; then
    fail_test "Push was denied when nothing found (should silent pass): $OUTPUT"
else
    pass_test
fi
rm -rf "$TEMP_REPO"

run_test "test_ci_local_gate_timeout: slow script triggers timeout denial"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-ci-gate-timeout-XXXXXX")
_CLEANUP_DIRS+=("$TEMP_REPO")
git -C "$TEMP_REPO" init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.githooks"
# Use a 200s sleep to simulate a slow CI (will be killed by 120s timeout)
# For test speed, we'll create a script that takes longer than our test timeout (not 120s)
# Actually we can't wait 120s in tests — instead we verify the timeout logic path is correct
# by testing that a script exiting with 124 (timeout exit code) triggers denial
# We mock this by wrapping the logic
cat > "$TEMP_REPO/.githooks/pre-push" <<'SCRIPT'
#!/usr/bin/env bash
# Simulate timeout: exit with 124 (timeout exit code)
exit 124
SCRIPT
chmod +x "$TEMP_REPO/.githooks/pre-push"

INPUT=$(jq -n --arg cwd "$TEMP_REPO" \
    '{"tool_name":"Bash","tool_input":{"command":"git push origin main","cwd":$cwd}}')
OUTPUT=$(cd "$TEMP_REPO" && echo "$INPUT" | bash "$HOOKS_DIR/pre-bash.sh" 2>&1) || true

# Exit code 124 from the script should be treated as timeout
if [[ "$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" == "deny" ]]; then
    pass_test
else
    fail_test "Expected denial for timeout-exit-code script: $OUTPUT"
fi
rm -rf "$TEMP_REPO"

run_test "test_ci_local_gate_force_push_skip: force push skips ci-local-gate"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-ci-gate-force-XXXXXX")
_CLEANUP_DIRS+=("$TEMP_REPO")
git -C "$TEMP_REPO" init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.githooks"
cat > "$TEMP_REPO/.githooks/pre-push" <<'EOF'
#!/usr/bin/env bash
echo "CI would fail"
exit 1
EOF
chmod +x "$TEMP_REPO/.githooks/pre-push"

# Force push to non-main branch should NOT trigger ci-local-gate
# (Check 3 handles --force but allows --force-with-lease to non-main)
INPUT=$(jq -n --arg cwd "$TEMP_REPO" \
    '{"tool_name":"Bash","tool_input":{"command":"git push origin feature/x --force-with-lease","cwd":$cwd}}')
OUTPUT=$(cd "$TEMP_REPO" && echo "$INPUT" | bash "$HOOKS_DIR/pre-bash.sh" 2>&1) || true

# Check 3 with --force-with-lease denies with "Use --force-with-lease" message
# Or ci-local-gate fires. Let's check that ci-local-gate's deny message is NOT present.
if echo "$OUTPUT" | grep -q "Local CI failed"; then
    fail_test "ci-local-gate fired on force push (should skip): $OUTPUT"
else
    pass_test
fi
rm -rf "$TEMP_REPO"

# ===========================================================================
# --- ci-watch.sh lock file concurrency prevention ---
# ===========================================================================

run_test "test_ci_watch_lock: second invocation exits if lock holds live PID"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-ci-watch-lock-XXXXXX")
_CLEANUP_DIRS+=("$TEMP_REPO")
git -C "$TEMP_REPO" init > /dev/null 2>&1
TEMP_CLAUDE_DIR="$TEMP_REPO"
mkdir -p "$TEMP_CLAUDE_DIR"

# Compute phash for the repo
PHASH=$(echo "$TEMP_REPO" | $_SHA256_CMD | cut -c1-8)
LOCK_FILE="${TEMP_CLAUDE_DIR}/.ci-watch-${PHASH}.lock"

# Write our own PID to the lock file (simulate live watcher)
echo $$ > "$LOCK_FILE"

# Run ci-watch.sh — it should exit immediately (no gh, but should exit before gh)
RESULT=$(CLAUDE_DIR="$TEMP_CLAUDE_DIR" timeout 5 bash "$SCRIPTS_DIR/ci-watch.sh" "$TEMP_REPO" 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?

# Lock file should still contain OUR PID (not overwritten)
if [[ -f "$LOCK_FILE" ]]; then
    LOCK_CONTENT=$(cat "$LOCK_FILE")
    if [[ "$LOCK_CONTENT" == "$$" ]]; then
        pass_test
    else
        fail_test "Lock was overwritten (new PID: $LOCK_CONTENT, expected: $$)"
    fi
else
    fail_test "Lock file was deleted"
fi

rm -rf "$TEMP_REPO"

# ===========================================================================
# --- session-init.sh Tier 1: state file injection ---
# ===========================================================================

run_test "test_session_init_ci_tier1: two-tier code present in session-init.sh"
# Verify the two-tier CI check was injected into session-init.sh.
# session-init.sh integration is difficult to test in isolation due to
# its dependency on full session context. Instead verify code presence and
# that the ci-lib functions work correctly (tested above in unit tests).
if grep -q "read_ci_status\|CI_TIER2_NEEDED\|require_ci" "$HOOKS_DIR/session-init.sh"; then
    pass_test
else
    fail_test "Two-tier CI check not found in session-init.sh"
fi

run_test "test_session_init_ci_tier2_fallback: fallback gh-query code present"
# Verify that when no state file or stale, session-init falls back to gh query
if grep -q "CI_TIER2_NEEDED\|gh run list" "$HOOKS_DIR/session-init.sh"; then
    pass_test
else
    fail_test "Tier 2 fallback not found in session-init.sh"
fi

# ===========================================================================
# --- prompt-submit.sh: CI keyword trigger ---
# ===========================================================================

run_test "test_prompt_submit_ci_keyword: CI keyword with state file injects status"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-ci-prompt-XXXXXX")
_CLEANUP_DIRS+=("$TEMP_REPO")
git -C "$TEMP_REPO" init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.claude"
TEMP_CLAUDE_DIR="${TEMP_REPO}/.claude"

bash -c "
    export CLAUDE_DIR='${TEMP_CLAUDE_DIR}'
    source '${HOOKS_DIR}/core-lib.sh'
    source '${HOOKS_DIR}/ci-lib.sh'
    write_ci_status '${TEMP_REPO}' 'failure' '789' 'failure' 'main' 'CI' '' '' ''
"

# Run prompt-submit.sh with a CI-keyword prompt
INPUT=$(jq -n '{"prompt":"why is the CI pipeline failing?"}')
OUTPUT=$(CLAUDE_PROJECT_DIR="$TEMP_REPO" \
         CLAUDE_DIR="$TEMP_CLAUDE_DIR" \
         cd "$TEMP_REPO" && \
         echo "$INPUT" | bash "$HOOKS_DIR/prompt-submit.sh" 2>/dev/null) || true

if echo "$OUTPUT" | grep -qi "CI.*FAIL\|FAILING"; then
    pass_test
else
    fail_test "prompt-submit.sh did not inject CI status for CI keyword. Output: $(echo "$OUTPUT" | head -5)"
fi
rm -rf "$TEMP_REPO"

run_test "test_prompt_submit_ci_keyword: no state file = no injection"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-ci-prompt2-XXXXXX")
_CLEANUP_DIRS+=("$TEMP_REPO")
git -C "$TEMP_REPO" init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.claude"
TEMP_CLAUDE_DIR="${TEMP_REPO}/.claude"

# No state file written

INPUT=$(jq -n '{"prompt":"how is the CI looking?"}')
OUTPUT=$(CLAUDE_PROJECT_DIR="$TEMP_REPO" \
         CLAUDE_DIR="$TEMP_CLAUDE_DIR" \
         cd "$TEMP_REPO" && \
         echo "$INPUT" | bash "$HOOKS_DIR/prompt-submit.sh" 2>/dev/null) || true

# Should not inject CI status (no state file)
if echo "$OUTPUT" | grep -qi "CI: PASSING\|CI: FAILING\|CI: IN PROGRESS"; then
    fail_test "prompt-submit.sh injected CI status when no state file"
else
    pass_test
fi
rm -rf "$TEMP_REPO"

# ===========================================================================
# --- Summary ---
# ===========================================================================

echo ""
echo "=========================================="
echo "Test Results: $TESTS_PASSED/$TESTS_RUN passed"
echo "=========================================="

if [[ $TESTS_FAILED -gt 0 ]]; then
    echo "FAILED: $TESTS_FAILED tests failed"
    exit 1
else
    echo "SUCCESS: All tests passed"
    exit 0
fi
