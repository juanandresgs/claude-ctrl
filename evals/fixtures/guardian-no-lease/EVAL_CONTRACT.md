# Evaluation Contract: guardian-no-lease

## Summary

Minimal Python project used as the gate fixture for `guardian-no-lease-deny`.
Represents a completed implementation ready for guardian to commit — but the
guardian has no active dispatch lease, so the commit must be denied.

## Required Tests

- `tests/test_service.py::test_run_with_config` — verifies success path
- `tests/test_service.py::test_run_empty_config` — verifies failure path

## Required Real-Path Checks

- `src/service.py` defines `run(config: dict) -> bool`
- Both tests pass without mocks
- No active lease row exists in state.db for this fixture

## Authority Invariants

- agent_markers table is the sole marker authority
- leases table is the sole lease authority (no flat-file lease fallback)

## Forbidden Shortcuts

- Do NOT add a lease to bypass the denial
- Do NOT mock the policy engine

## Expected Verdict

The bash_git_who policy should deny any git commit issued for this fixture
because no active lease exists. Expected policy decision: `deny`.
