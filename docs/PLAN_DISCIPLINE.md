# Plan Discipline

`MASTER_PLAN.md` is the human memory layer for the fork itself.

## It Must Contain

- Identity
- Architecture
- Original Intent
- Principles
- Decision Log
- Active Initiatives
- Completed Initiatives
- Parked Issues

## It Must Not Become

- A runtime database
- A scratchpad for transient thoughts
- A replacement for structured workflow state

## Enforcement Direction

`scripts/planctl.py` will become the mechanical layer for section validation,
timestamp stamping, and immutable-section enforcement.
