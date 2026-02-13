#!/usr/bin/env python3
"""
Integration tests for batch-fetch.py

Purpose: Validate cascade-proof behavior of batch URL fetching.
Tests verify that individual URL failures do not affect other fetches,
order is preserved, and JSON output is well-formed.

Rationale: The batch-fetch.py script solves WebFetch cascade failures.
These tests prove the core requirement: one URL's failure must not
block sibling URLs from returning results.

@decision DEC-FETCH-002
@title Live HTTP tests against public endpoints for cascade validation
@status accepted
@rationale Tests use real HTTP requests (httpbin.org, example.com) to prove
cascade isolation in production conditions. httpbin.org/status/404 provides
reliable failure injection. Could use mocks, but real HTTP validates timeout
handling, encoding edge cases, and ThreadPoolExecutor behavior under load.
"""

import sys
import json
import subprocess
from pathlib import Path

# Colors for output
RED = '\033[0;31m'
GREEN = '\033[0;32m'
YELLOW = '\033[1;33m'
NC = '\033[0m'

# Test counters
tests_run = 0
tests_passed = 0
tests_failed = 0

# Path to batch-fetch.py
SCRIPT_DIR = Path(__file__).parent
BATCH_FETCH = SCRIPT_DIR.parent / "scripts" / "batch-fetch.py"


def pass_test(name):
    global tests_passed
    tests_passed += 1
    print(f"{GREEN}✓{NC} {name}")


def fail_test(name, expected, got):
    global tests_failed
    tests_failed += 1
    print(f"{RED}✗{NC} {name}")
    print(f"  {YELLOW}Expected:{NC} {expected}")
    print(f"  {YELLOW}Got:{NC} {got}")


def run_batch_fetch(*urls):
    """Run batch-fetch.py with given URLs and return parsed JSON."""
    result = subprocess.run(
        ["python3", str(BATCH_FETCH)] + list(urls),
        capture_output=True,
        text=True,
        timeout=45
    )
    return json.loads(result.stdout)


def test_mixed_results():
    """Test 1: Mixed success/failure - cascade proof"""
    global tests_run
    tests_run += 1
    print("Test 1: Mixed success/failure (cascade-proof)")

    data = run_batch_fetch(
        "https://httpbin.org/html",
        "https://httpbin.org/status/404",
        "https://example.com"
    )

    # Check we have 3 results
    if len(data["results"]) != 3:
        fail_test("Result count", "3", str(len(data["results"])))
        return

    # Check 404 failed but others succeeded (cascade isolation)
    success_count = sum(1 for r in data["results"] if r["success"])
    if success_count != 2:
        fail_test("Success count (cascade isolation)", "2", str(success_count))
        return

    # Check 404 has error message
    has_404_error = any("404" in str(r.get("error", "")) for r in data["results"])
    if not has_404_error:
        fail_test("404 error recorded", "True", "False")
        return

    pass_test("Mixed success/failure handled independently")


def test_single_url():
    """Test 2: Single URL"""
    global tests_run
    tests_run += 1
    print("Test 2: Single URL")

    data = run_batch_fetch("https://example.com")

    # Check success
    if not data["results"][0]["success"]:
        fail_test("Single URL fetch", "True", "False")
        return

    pass_test("Single URL fetch successful")


def test_no_args():
    """Test 3: No arguments (usage)"""
    global tests_run
    tests_run += 1
    print("Test 3: No arguments (usage)")

    result = subprocess.run(
        ["python3", str(BATCH_FETCH)],
        capture_output=True,
        text=True
    )

    # Check for usage message
    if "Usage:" in result.stdout:
        pass_test("Usage message shown for no arguments")
    else:
        fail_test("Usage message", "contains 'Usage:'", result.stdout[:100])


def test_malformed_url():
    """Test 4: Malformed URL"""
    global tests_run
    tests_run += 1
    print("Test 4: Malformed URL")

    data = run_batch_fetch("not-a-url", "https://example.com")

    # Check first failed, second succeeded
    first_success = data["results"][0]["success"]
    second_success = data["results"][1]["success"]

    if not first_success and second_success:
        pass_test("Malformed URL isolated from valid URL")
    else:
        fail_test(
            "Malformed URL isolation",
            "False,True",
            f"{first_success},{second_success}"
        )


def test_order_preservation():
    """Test 5: Order preservation"""
    global tests_run
    tests_run += 1
    print("Test 5: Order preservation")

    data = run_batch_fetch(
        "https://httpbin.org/html",
        "https://example.com",
        "https://httpbin.org/status/404"
    )

    # Check URLs are in the same order
    first_url = data["results"][0]["url"]
    third_url = data["results"][2]["url"]

    if "httpbin.org/html" in first_url and "404" in third_url:
        pass_test("Result order matches input order")
    else:
        fail_test(
            "Order preservation",
            "httpbin.org/html first, 404 third",
            f"{first_url}, {third_url}"
        )


def main():
    print("=" * 42)
    print("Running batch-fetch.py integration tests")
    print("=" * 42)
    print()

    try:
        test_mixed_results()
        test_single_url()
        test_no_args()
        test_malformed_url()
        test_order_preservation()
    except Exception as e:
        print(f"{RED}Test execution error:{NC} {e}")
        sys.exit(1)

    print()
    print("=" * 42)
    print("Test Summary")
    print("=" * 42)
    print(f"Tests run: {tests_run}")
    print(f"{GREEN}Passed: {tests_passed}{NC}")
    if tests_failed > 0:
        print(f"{RED}Failed: {tests_failed}{NC}")
        sys.exit(1)
    else:
        print(f"{GREEN}All tests passed!{NC}")
        sys.exit(0)


if __name__ == "__main__":
    main()
