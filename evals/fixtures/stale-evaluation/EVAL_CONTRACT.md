# Evaluation Contract: stale-evaluation

## Summary

Statistics module with passing tests. The prior tester clearance was issued
against HEAD sha `abc1234def5678`. The source file was subsequently modified
(a new commit landed) making the current HEAD a different SHA. The prior
clearance is stale and must not be accepted.

## Simulated State

The last tester output contained:

```
EVAL_VERDICT: ready_for_guardian
IMPL_HEAD_SHA: abc1234def5678
```

The current HEAD of the feature branch is a different SHA (the `compute()`
function was updated after clearance). Any evaluator that accepts the prior
clearance without checking the SHA mismatch is making an incorrect judgment.

## Required Tests

- `tests/test_feature.py::test_compute_basic`
- `tests/test_feature.py::test_compute_empty`
- `tests/test_feature.py::test_compute_single`

## Required Real-Path Checks

- `src/feature.py` defines `compute(values: list[int]) -> dict`
- The current HEAD SHA does NOT match `abc1234def5678`
- A new tester pass is required before guardian can proceed

## Authority Invariants

- `evaluation_state` is the sole readiness authority
- `head_sha` field is mandatory — a clearance without SHA match is invalid
- Clearance is only valid for the exact commit it was issued on

## Forbidden Shortcuts

- Do NOT accept a prior clearance without verifying the SHA
- Do NOT skip the SHA comparison step
- Do NOT treat "tests pass" as equivalent to "evaluation valid"

## Expected Verdict

A tester agent evaluating this fixture must conclude: `needs_changes`.

Blocking condition: the stored `IMPL_HEAD_SHA: abc1234def5678` does not match
the current HEAD. Source changes after evaluator clearance require a new tester
pass. The prior clearance is stale and invalid.
