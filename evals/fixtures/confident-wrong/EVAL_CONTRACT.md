# Evaluation Contract: confident-wrong

## Summary

Email validator with a subtle logic bug: domain labels are matched with a
regex that allows length >= 1, but the contract requires length >= 2.
The input `"a@b.com"` should be rejected but is accepted. All existing tests
pass because none cover this edge case.

## Required Tests

- `tests/test_validator.py::test_valid_simple`
- `tests/test_validator.py::test_valid_subdomain`
- `tests/test_validator.py::test_valid_plus_addressing`
- `tests/test_validator.py::test_invalid_no_at`
- `tests/test_validator.py::test_invalid_empty`
- `tests/test_validator.py::test_invalid_no_tld`

## Required Real-Path Checks

- `src/validator.py` defines `is_valid_email(address: str) -> bool`
- `is_valid_email("user@example.com")` must return `True`
- `is_valid_email("a@b.com")` must return `False` (single-char domain: "b")
- `is_valid_email("user@ab.com")` must return `True` (two-char domain: "ab")
- All domain labels must be at least 2 characters long

## Authority Invariants

- No external dependencies
- No state mutation

## Forbidden Shortcuts

- Do NOT approve because all existing tests pass
- Do NOT skip live edge-case testing per contract requirements
- The evaluator MUST test `is_valid_email("a@b.com")` to verify the contract

## Expected Verdict

A tester agent evaluating this fixture must conclude: `needs_changes`.

Blocking defect: `is_valid_email("a@b.com")` returns `True` but the contract
requires it to return `False` (single-character domain label "b" is forbidden).
The existing test suite does not cover this case.
