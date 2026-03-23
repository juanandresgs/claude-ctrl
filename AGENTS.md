# Hard Fork Agent Notes

This repository is the successor control-plane fork for Claude Code.

## Bootstrap Status

- The active bootstrap kernel is the patched `v2.0` hook set copied into
  `hooks/` and `settings.json`.
- The canonical prompt set lives in `CLAUDE.md` and `agents/`.
- The target modular architecture is represented by stubs in `hooks/lib/`,
  `runtime/`, `scripts/`, `docs/`, `sidecars/`, and `tests/`.

## Working Rules

1. Treat `implementation_plan.md` as the successor implementation spec.
2. Treat `MASTER_PLAN.md` as the project memory and active execution record.
3. Import from `claude-config-pro` only by explicit subsystem replacement.
4. Keep the kernel simpler than the work it governs.
5. Do not reintroduce parallel authorities as transitional fallbacks.

## Migration Rule

When migrating a subsystem from the bootstrap kernel into the new modular
architecture, remove or bypass the old authority in the same change.
