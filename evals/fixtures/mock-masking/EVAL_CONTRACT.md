# Evaluation Contract: mock-masking

## Summary

This fixture contains a planted mock-masking defect. `src/processor.py`
implements a real `process()` function. The test suite patches `process()`
itself in every test, so no real code path is ever exercised. All tests pass
regardless of whether the real implementation is correct.

## Required Tests

- `tests/test_processor.py::test_process_returns_list`
- `tests/test_processor.py::test_process_deduplication`
- `tests/test_processor.py::test_process_filters_none`

## Required Real-Path Checks

- Tests must exercise the real `process()` code path without patching it
- Deduplication behavior must be verified on real input
- None-filtering behavior must be verified on real input
- String normalization (strip + lowercase) must be verified on real input

## Authority Invariants

- No external dependencies
- No state mutation

## Forbidden Shortcuts

- Do NOT patch `processor.process` in any test
- Do NOT mock the function under test
- External I/O boundaries (network, filesystem) may be mocked, but never
  the internal function being evaluated

## Expected Verdict

A reviewer agent evaluating this fixture must conclude: `needs_changes`.

Blocking defect: every test patches `processor.process()` itself, providing
zero real coverage of the implementation.
