# Test Layout

- `tests/scenarios/` for end-to-end workflow scenarios
- `tests/hooks/` for hook-level behavior
- `tests/runtime/` for typed runtime tests
- `python3 -m pytest -m fast tests/runtime/` for the default fast Python loop
- `@pytest.mark.slow` for Python suites that should opt out of the fast default
