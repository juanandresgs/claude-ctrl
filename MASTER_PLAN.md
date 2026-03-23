# MASTER_PLAN.md

## Identity

This repository is the hard-fork successor to `claude-config-pro`. It is being
built from the patched `v2.0` kernel outward so the governance layer remains
smaller and more legible than the work it governs.

## Architecture

- Canonical judgment lives in [CLAUDE.md](CLAUDE.md) and [agents/](agents).
- The active bootstrap kernel is the imported patched `v2.0` hook set in
  [hooks/](hooks) with [settings.json](settings.json).
- The target architecture is modular: thin hooks, typed runtime, read-only
  sidecars, and strict plan discipline.
- The future shared-state authority moves into [runtime/](runtime), reached
  through [hooks/lib/runtime-bridge.sh](hooks/lib/runtime-bridge.sh).

## Original Intent

Bootstrap a new control-plane fork that preserves the stable determinism of
`v2.0`, carries forward the essential safety and proof fixes, and selectively
rebuilds only the genuinely valuable ideas from later versions.

## Principles

1. Start from the working kernel, not from the most complex branch.
2. Prompts shape judgment; hooks enforce local policy; runtime owns shared
   state.
3. Delete what you replace. Do not keep fallback authorities alive.
4. Preserve readable ownership boundaries between subsystems.
5. Upstream is a donor, not the mainline.

## Decision Log

- `DEC-FORK-001` Bootstrap the successor from the patched `v2.0` kernel rather
  than from `claude-config-pro` `main`.
- `DEC-FORK-002` Preserve the canonical prompt rewrite already drafted in this
  repository and layer the kernel beneath it.
- `DEC-FORK-003` Initialize the hard fork as a standalone repository with its
  own history and treat upstream only as an import source.

## Active Initiatives

### INIT-001: Kernel Bootstrap

- **Status:** in-progress
- **Goal:** Make the fork usable immediately with the patched `v2.0` control
  plane.
- **Scope:** `settings.json`, `hooks/`, `scripts/statusline.sh`, command
  stubs, prompt set retention.
- **Exit:** The repo can be installed as a Claude config without depending on
  `claude-config-pro`.

### INIT-002: Runtime Skeleton

- **Status:** in-progress
- **Goal:** Establish the typed runtime package and CLI contract without
  coupling hooks to it yet.
- **Scope:** `runtime/`, `hooks/lib/runtime-bridge.sh`, `scripts/planctl.py`,
  `scripts/diagnose.py`.
- **Exit:** The interface exists and future work can land against it cleanly.

### INIT-003: Hook Decomposition

- **Status:** planned
- **Goal:** Move from the imported v2 hook bundle to thin entrypoints and
  explicit domain libs.
- **Scope:** `hooks/lib/*.sh`, eventual `pre-bash.sh`, `pre-write.sh`,
  `post-task.sh` consolidation.
- **Exit:** Core hook entrypoints are small and policy is split by domain.

## Completed Initiatives

- Canonical prompt set drafted in `CLAUDE.md` and `agents/`.
- Successor implementation spec written in `implementation_plan.md`.

## Parked Issues

- Search and observatory sidecars remain parked until the kernel and runtime
  authority are stable.
- No upstream synchronization policy is implemented yet beyond manual import.
