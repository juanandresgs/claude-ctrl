# Architecture

## Current Bootstrap

The hard fork currently runs on the patched `v2.0` kernel imported into
`hooks/` and registered by `settings.json`. This is intentional. Phase 1 of the
successor plan prioritizes a working, understandable control plane over early
architectural purity.

## Target Shape

The target architecture is:

1. Canonical prompts in `CLAUDE.md` and `agents/`
2. Thin hook entrypoints and small shell policy libs
3. Typed runtime for shared state and concurrency
4. Runtime-backed read models such as the statusline HUD
5. Read-only sidecars for observability and search

## Statusline Direction

The richer statusline HUD is part of the successor architecture, but it must be
implemented as a read model over canonical runtime state. `scripts/statusline.sh`
renders the HUD; it must not become a second authority for workflow state, nor
may it rely on flat-file or breadcrumb coordination once the runtime is live.

## Migration Boundary

Until the runtime is live, imported v2 hooks remain the active authority. New
modular files must not become a second live control path by accident.
