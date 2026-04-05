#!/usr/bin/env bash
# test-lint-patterns.sh: verifies lint-test-patterns.sh catches stale patterns
# and reports zero warnings on the real test suite.
#
# @decision DEC-REBASE-W2-001
# @title Scenario test for the stale-pattern lint gate
# @status accepted
# @rationale The lint gate must catch known drift patterns and must not
#   produce false positives on the real suite. This test validates both
#   properties: synthetic bad fixtures trigger warnings, real suite is clean.
set -euo pipefail

TEST_NAME="test-lint-patterns"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINTER="$REPO_ROOT/tests/lint-test-patterns.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR"

PASS=0
FAIL=0

check() {
    local label="$1" expected_exit="$2" expected_pattern="${3:-}"
    shift 3 || true
    local exit_code=0
    local output
    output=$(bash "$LINTER" "$TMP_DIR" 2>&1) || exit_code=$?

    if [[ "$exit_code" -ne "$expected_exit" ]]; then
        echo "  FAIL: $label — expected exit $expected_exit, got $exit_code"
        FAIL=$((FAIL + 1))
        return
    fi
    if [[ -n "$expected_pattern" ]] && ! echo "$output" | grep -q "$expected_pattern"; then
        echo "  FAIL: $label — output missing pattern '$expected_pattern'"
        echo "  output: $output"
        FAIL=$((FAIL + 1))
        return
    fi
    echo "  PASS: $label"
    PASS=$((PASS + 1))
}

# --- Synthetic bad fixtures ---

# Pattern 1: deleted hook ref
cat > "$TMP_DIR/bad-hook.sh" << 'EOF'
HOOK="$REPO_ROOT/hooks/guard.sh"
EOF
check "deleted hook ref detected" 1 "hooks/guard.sh"
rm "$TMP_DIR/bad-hook.sh"

# Pattern 2: flat-file test-status
cat > "$TMP_DIR/bad-flatfile.sh" << 'EOF'
echo "pass|0|123" > "$TMP_DIR/.claude/.test-status"
EOF
check "flat-file test-status detected" 1 "test-status"
rm "$TMP_DIR/bad-flatfile.sh"

# Pattern 3: dispatch enqueue
cat > "$TMP_DIR/bad-dispatch.sh" << 'EOF'
policy dispatch enqueue "implementer" --ticket "TKT-001"
EOF
check "dispatch enqueue detected" 1 "dispatch enqueue"
rm "$TMP_DIR/bad-dispatch.sh"

# Pattern 4: W1-era policy count
cat > "$TMP_DIR/bad-count.sh" << 'EOF'
assert_eq "count is zero" "$result" '"count": 0'
EOF
check "W1-era count: 0 detected" 1 '"count": 0'
rm "$TMP_DIR/bad-count.sh"

# Pattern 5: comment lines should NOT trigger
cat > "$TMP_DIR/ok-comment.sh" << 'EOF'
# hooks/guard.sh was deleted in INIT-PE
# echo "pass|0|123" > "$TMP_DIR/.claude/.test-status"
echo "this line is fine"
EOF
check "comment lines ignored (no false positive)" 0 "0 warnings"
rm "$TMP_DIR/ok-comment.sh"

# --- Real suite check ---
echo ""
echo "-- Real suite lint check"
real_exit=0
real_output=$(bash "$LINTER" 2>&1) || real_exit=$?
if [[ "$real_exit" -eq 0 ]]; then
    echo "  PASS: real suite clean — $real_output"
    PASS=$((PASS + 1))
else
    echo "  FAIL: real suite has warnings:"
    echo "$real_output"
    FAIL=$((FAIL + 1))
fi

# --- Results ---
echo ""
if [[ $FAIL -gt 0 ]]; then
    echo "FAIL: $TEST_NAME — $PASS passed, $FAIL failed"
    exit 1
fi
echo "PASS: $TEST_NAME — $PASS passed, $FAIL failed"
exit 0
