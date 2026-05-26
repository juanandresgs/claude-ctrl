# Hard Fork Agent Notes

This repository is the successor control-plane fork for a Claude Code config called 'claude-ctrl'.

In this folder, Codex works alongside Claude Code by treating Claude Code as the agent that executes and implements to improve/fix/update the runtime and hook environment being governed, audited, and redesigned. The job is not only to edit files, but to reconcile prompts, hooks, runtime state,
configuration, and plans into one coherent control plane. Note technical debt or silent failures, and improve the mechanism to the best possible spec of deterministic enforcement paired with single authorities for self-sustaining and self-increasing reliability and guaranteed outcomes.

## Bootstrap Status

- The active bootstrap kernel is the patched `v2.0` hook set copied into
  `hooks/` and `settings.json`.
- The canonical prompt set lives in `CLAUDE.md` and `agents/`.
- The target modular architecture is represented by stubs in `hooks/lib/`,
  `runtime/`, `scripts/`, `docs/`, `sidecars/`, and `tests/`.

## Codex and Claude Code

- Claude Code is the governed system: prompts, hooks, runtime domains, worktree/dispatch behavior, and installed configuration are all in scope.
- Codex is the repo-level analysis and refactor agent. It should inspect how the installed system actually behaves before trusting architectural prose. Codex reviews the output of the Claude Code (cc) threads, skeptically reviews, then provides guidance/steering towards meeting the intended goal at the highest spec.
- Documentation is intent first, not mechanism truth. For mechanism truth, inspect the components themselves including `settings.json`, `hooks/`, `runtime/`, and the active test suites.
- When architectural drift is found, suggest updates and initiatives for Claude Code to address the review doc, implementation spec, master plan, and architecture docs together rather than fixing only one narrative surface.

## Session Working Pattern

- Start from installed truth, not from aspiration.
- Review end to end: hook wiring, shell entrypoints, runtime domains, state
  authorities, dispatch flow, worktree handling, prompts, and tests.
- Treat stale docs and stale scenarios as control-plane defects, not cosmetic issues.
- Prefer architecture corrections that collapse authorities instead of adding another layer beside the current one.
- When the intended design changes, rewrite the plans around the new core model rather than patching an addendum onto an obsolete plan.

## Working Rules

1. Treat `implementation_plan.md` as the successor implementation spec.
2. Treat `MASTER_PLAN.md` as the project memory and active execution record.
3. Import from `claude-config-pro` only by explicit subsystem replacement.
4. Keep the kernel simpler than the work it governs.
5. Do not reintroduce parallel authorities as transitional fallbacks.
6. For architecture work, use docs as statements of goals and values, but use
   code, config, and tests as the source of truth for how the system currently
   works.
8. Default toward a policy-engine-first design: hooks should become adapters,
   policy should become the point of visibility and configuration, dispatch
   should be authoritative, and concurrency/worktree management should be part
   of the control plane.
9. Keep one authority per operational fact: workflow identity, readiness,
   dispatch phase, worktree ownership, approval state, and policy evaluation
   should not be derivable from multiple competing paths.

## Migration Rule

When migrating a subsystem from the bootstrap kernel into the new modular
architecture, remove or bypass the old authority in the same change.
