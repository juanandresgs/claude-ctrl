# Evaluation Contract: clean-implementation

## Summary

Correct implementation of a simple calculator with four operations. All tests
are real (no mocks of internal modules). This fixture is clean — a tester
should conclude `ready_for_guardian` with high confidence.

## Required Tests

- `tests/test_calculator.py::test_add` — verifies add with positive, negative, zero
- `tests/test_calculator.py::test_subtract` — verifies subtract edge cases
- `tests/test_calculator.py::test_multiply` — verifies multiply including zero
- `tests/test_calculator.py::test_divide` — verifies divide with float result
- `tests/test_calculator.py::test_divide_by_zero` — verifies ZeroDivisionError

## Required Real-Path Checks

- `src/calculator.py` defines `add`, `subtract`, `multiply`, `divide`
- `divide(a, 0)` raises `ZeroDivisionError`
- All five tests pass without mocks of internal modules

## Authority Invariants

- No external dependencies
- No state mutation
- No file I/O

## Forbidden Shortcuts

- Do NOT mock `add`, `subtract`, `multiply`, or `divide`
- Do NOT skip the divide-by-zero test

## Expected Verdict

A tester agent evaluating this fixture against this contract should conclude:
`ready_for_guardian` — no blockers, no defects, all tiers fully verified.
