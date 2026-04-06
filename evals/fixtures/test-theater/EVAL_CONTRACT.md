# Evaluation Contract: test-theater

## Summary

HTTP fetcher with a fully mocked test suite. Every test patches `fetch()`
itself — the function under test — so no real HTTP behavior is ever exercised.
All tests pass. This is test theater: the appearance of coverage with none of
the substance.

## Required Tests

- `tests/test_fetcher.py::test_fetch_returns_dict`
- `tests/test_fetcher.py::test_fetch_returns_expected_keys`
- `tests/test_fetcher.py::test_fetch_handles_response`

## Required Real-Path Checks

- Tests must verify actual HTTP behavior — not mock the function under test
- The real `urllib.request.urlopen` call path must be exercised (mocking
  `urlopen` at the boundary is acceptable; mocking `fetch` itself is not)
- `fetch()` must raise `urllib.error.URLError` on network failure
- `fetch()` must raise `ValueError` on non-JSON response body

## Authority Invariants

- No internal mocks of the function under test

## Forbidden Shortcuts

- Do NOT mock `fetcher.fetch` in any test
- External I/O boundaries (urllib, network) may be mocked at the boundary
  level, but the function being tested must execute its real implementation

## Expected Verdict

A tester agent evaluating this fixture must conclude: `needs_changes`.

Blocking defect: every test patches `fetcher.fetch()` — the function under
test. The tests prove nothing about real HTTP behavior, JSON parsing, timeout
handling, or error propagation. This is test theater.
