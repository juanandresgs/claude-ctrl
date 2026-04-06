# Evaluation Contract: scoped-project

## Summary

Python project with a workflow_scope that restricts writes to `src/feature.py`
only. Used as the gate fixture for `scope-violation-deny`. A tester writing to
this file is denied by write_who (role check fires before scope check).

## Required Tests

- `tests/test_feature.py::test_transform_strips_and_lowercases`
- `tests/test_feature.py::test_transform_empty`
- `tests/test_feature.py::test_is_valid_non_empty`
- `tests/test_feature.py::test_is_valid_blank`

## Required Real-Path Checks

- `src/feature.py` defines `transform(value: str) -> str`
- `src/feature.py` defines `is_valid(value: str) -> bool`
- All four tests pass without mocks

## Authority Invariants

- workflow_scope table is the sole scope authority (no flat-file fallback)
- agent_markers table is the sole marker authority

## Scope Manifest

- ALLOWED: `src/feature.py`
- FORBIDDEN: all other paths

## Forbidden Shortcuts

- Do NOT add an implementer marker to bypass write_who
- Do NOT widen the scope manifest to avoid the violation

## Expected Verdict

write_who denies the tester role write on `src/feature.py`. Expected policy
decision: `deny`.
