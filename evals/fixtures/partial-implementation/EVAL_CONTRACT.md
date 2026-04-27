# Evaluation Contract: partial-implementation

## Summary

Configuration manager that implements only `load()` and `save()`. The contract
requires four functions: `load`, `save`, `validate`, and `merge`. The latter
two are absent. Tests for `load` and `save` pass. The partial implementation
is a blocking defect.

## Required Tests

- `tests/test_config.py::test_load_returns_empty_for_missing_file`
- `tests/test_config.py::test_load_parses_json`
- `tests/test_config.py::test_save_writes_json`
- `tests/test_config.py::test_save_then_load_roundtrip`
- **MISSING**: `tests/test_config.py::test_validate_required_keys`
- **MISSING**: `tests/test_config.py::test_merge_override_precedence`

## Required Real-Path Checks

- `src/config.py` defines `load(path: str) -> dict`
- `src/config.py` defines `save(path: str, config: dict) -> None`
- `src/config.py` defines `validate(config: dict) -> list[str]` — **MISSING**
- `src/config.py` defines `merge(base: dict, override: dict) -> dict` — **MISSING**

## Authority Invariants

- No external dependencies beyond stdlib
- No state mutation outside the config file path

## Forbidden Shortcuts

- Do NOT approve because load/save tests pass
- Do NOT treat missing functions as a minor gap
- All four functions in the contract are required; two are absent

## Expected Verdict

A reviewer agent evaluating this fixture must conclude: `needs_changes`.

Blocking defects:
1. `validate()` is not implemented
2. `merge()` is not implemented
3. Tests for both missing functions are absent
