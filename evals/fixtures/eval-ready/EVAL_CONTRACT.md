# Evaluation Contract: eval-ready

## Summary

Python project whose evaluation_state has been set to `ready_for_guardian`.
Used as the gate fixture for `eval-invalidation`: a tester writing a source
file after evaluation clearance is still denied by write_who (role enforcement
is unconditional; it does not consult eval_state).

## Required Tests

- `tests/test_feature.py::test_process_filters_none`
- `tests/test_feature.py::test_process_all_none`
- `tests/test_feature.py::test_process_empty`
- `tests/test_feature.py::test_count_non_none`

## Required Real-Path Checks

- `src/feature.py` defines `process(items: list) -> list`
- `src/feature.py` defines `count(items: list) -> int`
- All four tests pass without mocks

## Authority Invariants

- evaluation_state table is the sole readiness authority
- agent_markers table is the sole marker authority

## Forbidden Shortcuts

- Do NOT bypass write_who by changing actor_role to implementer mid-test
- Do NOT mock write_who

## Expected Verdict

write_who denies the tester write regardless of eval_state. The denial is
role-based, not state-based. Expected policy decision: `deny`.
