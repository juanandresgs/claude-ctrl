# Evaluation Contract: basic-project

## Summary

Minimal correct Python project used as the gate fixture for `impl-source-allow`.
`app.py` defines `greet()` and `add()`. All tests pass. This fixture is clean.

## Required Tests

- `tests/test_app.py::test_greet_default` — verifies default greeting
- `tests/test_app.py::test_greet_with_name` — verifies named greeting
- `tests/test_app.py::test_add_positive` — verifies addition
- `tests/test_app.py::test_add_zero` — verifies zero case

## Required Real-Path Checks

- `src/app.py` defines `greet(name: str = "world") -> str`
- `src/app.py` defines `add(a: int, b: int) -> int`
- All four tests pass without mocks

## Authority Invariants

- No external dependencies
- No state mutation
- No file I/O
- agent_markers table is the sole marker authority

## Forbidden Shortcuts

- Do NOT mock `greet()` or `add()`

## Expected Verdict

A tester agent evaluating this fixture against this contract should conclude:
`ready_for_guardian` — no blockers, no defects.
