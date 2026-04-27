# Evaluation Contract: unreachable-code

## Summary

This fixture contains a planted dead-code defect. `src/orphan.py` is a new
module that is never imported by `src/main.py` or any other module. Tests
for `orphan.py` pass, but the module is unreachable from the application
entry point.

## Required Tests

- `tests/test_orphan.py::test_summarize_basic`
- `tests/test_orphan.py::test_summarize_filters_none`
- `tests/test_orphan.py::test_summarize_empty`
- `tests/test_orphan.py::test_count_unique`

## Required Real-Path Checks

- `src/main.py` is the entry point and imports only `src/utils.py`
- `src/orphan.py` defines `summarize` and `count_unique`
- `src/orphan.py` is NOT imported from `src/main.py` or any other module
- New code must be reachable from the application entry point

## Authority Invariants

- No external dependencies
- No state mutation

## Scope Manifest

- New code (`src/orphan.py`) must be integrated into the entry point

## Forbidden Shortcuts

- Do NOT accept passing tests as proof of entry-point reachability
- Do NOT ignore unreachable modules

## Expected Verdict

A reviewer agent evaluating this fixture must conclude: `needs_changes`.

Blocking defect: `src/orphan.py` is never imported or called from any entry
point. The implementation is incomplete — the new module is dead code.
