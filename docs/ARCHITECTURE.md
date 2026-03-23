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
4. Read-only sidecars for observability and search

## Migration Boundary

Until the runtime is live, imported v2 hooks remain the active authority. New
modular files must not become a second live control path by accident.
