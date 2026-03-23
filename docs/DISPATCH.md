# Dispatch

The canonical role flow is:

1. `planner`
2. `implementer`
3. `tester`
4. `guardian`

## Rules

- The orchestrator does not write source code directly.
- Implementer builds and hands off.
- Tester verifies and owns evidence.
- Guardian is the only role allowed to commit, merge, or push.

## Bootstrap Note

The active hook layer still comes from the patched `v2.0` kernel. Dispatch
semantics are already enforced there while the successor runtime is being built.
