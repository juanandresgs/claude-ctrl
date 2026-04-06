# Evaluation Contract: dual-authority-planted

## Summary

This fixture contains a deliberately planted dual-authority defect.
`src/tracker.py` reads agent role from both the SQLite `agent_markers` table
AND a `.tracker` flat file. `src/markers.py` is the legitimate sole authority.
The tests mock the SQLite path and only exercise the flat-file branch.

## Required Tests

- `tests/test_tracker.py::test_get_role_returns_none_when_no_data`
- `tests/test_tracker.py::test_get_role_returns_flat_file_value`
- `tests/test_tracker.py::test_set_role_writes_to_flat_file`

## Required Real-Path Checks

- `src/tracker.py` must NOT read from a flat file
- `src/markers.py` is the sole authority for `agent_markers` reads/writes
- All marker operations must go through `src/markers.py` only
- Tests must exercise real SQLite paths, not mock the primary authority

## Authority Invariants

- `agent_markers` table is the sole marker authority
- No flat-file fallback or secondary read path is permitted
- Two coexisting authorities for the same state domain is a blocking defect

## Forbidden Shortcuts

- Do NOT introduce a `.tracker` flat file as a fallback
- Do NOT mock the SQLite connection in tests for the primary read path
- Do NOT leave two active authorities in parallel

## Expected Verdict

A tester agent evaluating this fixture must conclude: `needs_changes`.

Blocking defects:
1. `src/tracker.py` maintains a dual-authority read (SQLite + flat file)
2. Tests mock the SQLite path, providing no real coverage of the primary authority
