#!/usr/bin/env bash
# test-runner.sh: minimal harness that discovers and runs all test-*.sh
# scenario scripts, counts pass/fail, and exits nonzero if any fail.
# Each scenario script must print "PASS: <name>" or "FAIL: <name>" and
# exit 0 on pass, 1 on fail.
#
# @decision DEC-SMOKE-001
# @title Shell-based scenario test harness for hook validation
# @status accepted
# @rationale TKT-002 requires a runnable smoke suite that exercises real
# hook scripts with synthetic JSON payloads. A minimal shell harness avoids
# external test framework dependencies and keeps CI simple. Each scenario
# is a standalone script so failures are isolated. DEC-FORK-012.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

# Discover all test-*.sh scripts in this directory
TESTS=()
for f in "$SCRIPT_DIR"/test-*.sh; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" == "test-runner.sh" ]] && continue
    TESTS+=("$f")
done

if [[ ${#TESTS[@]} -eq 0 ]]; then
    echo "ERROR: No test-*.sh scripts found in $SCRIPT_DIR" >&2
    exit 1
fi

echo "Running ${#TESTS[@]} scenario tests..."
echo "----------------------------------------"

for test_script in "${TESTS[@]}"; do
    test_name="$(basename "$test_script" .sh)"
    chmod +x "$test_script"

    # Run test with a 30s timeout to prevent hangs
    output=$(timeout 30 "$test_script" 2>&1) && exit_code=0 || exit_code=$?

    if [[ "$exit_code" -eq 124 ]]; then
        echo "FAIL: $test_name — timed out after 30s"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS+=("$test_name")
        continue
    fi

    if [[ "$exit_code" -eq 0 ]]; then
        echo "$output" | grep -E "^PASS:" | head -1 || echo "PASS: $test_name"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "$output" | grep -E "^FAIL:" | head -1 || echo "FAIL: $test_name"
        # Print diagnostic lines (non-PASS/FAIL output) on failure
        echo "$output" | grep -vE "^(PASS|FAIL):" | while IFS= read -r line; do
            [[ -n "$line" ]] && echo "  | $line"
        done
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS+=("$test_name")
    fi
done

echo "----------------------------------------"
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do
        echo "  - $t"
    done
    exit 1
fi

exit 0
