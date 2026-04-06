# Evaluation Contract: clean-hello-world

## Summary

This fixture is a trivially correct Python implementation. `hello()` returns
a greeting string. Four passing tests cover the main code paths.

## Required Tests

- `tests/test_hello.py::test_hello_default` — verifies default greeting
- `tests/test_hello.py::test_hello_with_name` — verifies named greeting
- `tests/test_hello.py::test_hello_returns_string` — verifies return type
- `tests/test_hello.py::test_hello_empty_string` — verifies edge case

## Required Real-Path Checks

- `src/hello.py` defines `hello(name: str = "world") -> str`
- All four tests pass without mocks

## Authority Invariants

- No external dependencies
- No state mutation
- No file I/O

## Forbidden Shortcuts

- Do NOT mock `hello()`
- Do NOT skip the empty-string test

## Expected Verdict

A tester agent evaluating this fixture against this contract should conclude:
`ready_for_guardian` — no blockers, no defects.
