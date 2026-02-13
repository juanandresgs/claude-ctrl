#!/usr/bin/env bash
# Integration tests for batch-fetch.py
#
# Purpose: Validate cascade-proof behavior of batch URL fetching.
# Tests verify that individual URL failures do not affect other fetches,
# order is preserved, and JSON output is well-formed.
#
# Rationale: The batch-fetch.py script solves WebFetch cascade failures.
# These tests prove the core requirement: one URL's failure must not
# block sibling URLs from returning results.
#
# @decision DEC-FETCH-002
# @title Live HTTP tests against public endpoints for cascade validation
# @status accepted
# @rationale Tests use real HTTP requests (httpbin.org, example.com) to prove
# cascade isolation in production conditions. httpbin.org/status/404 provides
# reliable failure injection. Could use mocks, but real HTTP validates timeout
# handling, encoding edge cases, and ThreadPoolExecutor behavior under load.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BATCH_FETCH="${SCRIPT_DIR}/../scripts/batch-fetch.py"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counter
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Helper functions
pass_test() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} $1"
}

fail_test() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} $1"
    echo -e "  ${YELLOW}Expected:${NC} $2"
    echo -e "  ${YELLOW}Got:${NC} $3"
}

run_test() {
    TESTS_RUN=$((TESTS_RUN + 1))
}

# Test 1: Mixed success/failure - cascade proof
test_mixed_results() {
    run_test
    echo "Test 1: Mixed success/failure (cascade-proof)"

    # Save to temp file to avoid bash variable issues with JSON
    tmpfile=$(mktemp)
    python3 "$BATCH_FETCH" \
        "https://httpbin.org/html" \
        "https://httpbin.org/status/404" \
        "https://example.com" > "$tmpfile" 2>&1

    # Check JSON is valid
    if ! python3 -m json.tool "$tmpfile" > /dev/null 2>&1; then
        fail_test "JSON output validation" "valid JSON" "invalid JSON"
        rm "$tmpfile"
        return
    fi

    # Check we have 3 results
    result_count=$(python3 -c "import sys, json; print(len(json.load(open('$tmpfile'))['results']))")
    if [ "$result_count" != "3" ]; then
        fail_test "Result count" "3" "$result_count"
        rm "$tmpfile"
        return
    fi

    # Check 404 failed but others succeeded
    success_count=$(python3 -c "import sys, json; print(sum(1 for r in json.load(open('$tmpfile'))['results'] if r['success']))")
    if [ "$success_count" != "2" ]; then
        fail_test "Success count (cascade isolation)" "2" "$success_count"
        cat "$tmpfile"
        rm "$tmpfile"
        return
    fi

    # Check 404 has error message
    has_404_error=$(python3 -c "import sys, json; results = json.load(open('$tmpfile'))['results']; print(any('404' in str(r.get('error', '')) for r in results))")
    if [ "$has_404_error" != "True" ]; then
        fail_test "404 error recorded" "True" "$has_404_error"
        rm "$tmpfile"
        return
    fi

    rm "$tmpfile"
    pass_test "Mixed success/failure handled independently"
}

# Test 2: Single URL
test_single_url() {
    run_test
    echo "Test 2: Single URL"

    tmpfile=$(mktemp)
    python3 "$BATCH_FETCH" "https://example.com" > "$tmpfile" 2>&1

    # Check JSON is valid
    if ! python3 -m json.tool "$tmpfile" > /dev/null 2>&1; then
        fail_test "JSON output validation" "valid JSON" "invalid JSON"
        rm "$tmpfile"
        return
    fi

    # Check success
    success=$(python3 -c "import sys, json; print(json.load(open('$tmpfile'))['results'][0]['success'])")
    if [ "$success" != "True" ]; then
        fail_test "Single URL fetch" "True" "$success"
        rm "$tmpfile"
        return
    fi

    rm "$tmpfile"
    pass_test "Single URL fetch successful"
}

# Test 3: No arguments
test_no_args() {
    run_test
    echo "Test 3: No arguments (usage)"

    output=$(python3 "$BATCH_FETCH" 2>&1 || true)

    # Check for usage message
    if echo "$output" | grep -q "Usage:"; then
        pass_test "Usage message shown for no arguments"
    else
        fail_test "Usage message" "contains 'Usage:'" "$output"
    fi
}

# Test 4: Malformed URL
test_malformed_url() {
    run_test
    echo "Test 4: Malformed URL"

    tmpfile=$(mktemp)
    python3 "$BATCH_FETCH" "not-a-url" "https://example.com" > "$tmpfile" 2>&1

    # Check JSON is valid
    if ! python3 -m json.tool "$tmpfile" > /dev/null 2>&1; then
        fail_test "JSON output validation" "valid JSON" "invalid JSON"
        rm "$tmpfile"
        return
    fi

    # Check first failed, second succeeded
    first_success=$(python3 -c "import sys, json; print(json.load(open('$tmpfile'))['results'][0]['success'])")
    second_success=$(python3 -c "import sys, json; print(json.load(open('$tmpfile'))['results'][1]['success'])")

    if [ "$first_success" == "False" ] && [ "$second_success" == "True" ]; then
        rm "$tmpfile"
        pass_test "Malformed URL isolated from valid URL"
    else
        fail_test "Malformed URL isolation" "False,True" "$first_success,$second_success"
        rm "$tmpfile"
    fi
}

# Test 5: Order preservation
test_order_preservation() {
    run_test
    echo "Test 5: Order preservation"

    tmpfile=$(mktemp)
    python3 "$BATCH_FETCH" \
        "https://httpbin.org/html" \
        "https://example.com" \
        "https://httpbin.org/status/404" > "$tmpfile" 2>&1

    # Check URLs are in the same order
    first_url=$(python3 -c "import sys, json; print(json.load(open('$tmpfile'))['results'][0]['url'])")
    third_url=$(python3 -c "import sys, json; print(json.load(open('$tmpfile'))['results'][2]['url'])")

    if [[ "$first_url" == *"httpbin.org/html"* ]] && [[ "$third_url" == *"404"* ]]; then
        rm "$tmpfile"
        pass_test "Result order matches input order"
    else
        fail_test "Order preservation" "httpbin.org/html first, 404 third" "$first_url, $third_url"
        rm "$tmpfile"
    fi
}

# Run all tests
echo "=========================================="
echo "Running batch-fetch.py integration tests"
echo "=========================================="
echo

test_mixed_results
test_single_url
test_no_args
test_malformed_url
test_order_preservation

echo
echo "=========================================="
echo "Test Summary"
echo "=========================================="
echo "Tests run: $TESTS_RUN"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "${RED}Failed: $TESTS_FAILED${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
