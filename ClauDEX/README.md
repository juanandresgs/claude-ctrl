# ClauDEX

Status: public release workspace

This folder holds the ClauDEX cutover architecture and the experimental
bridge/supervision work that sits beside the main Claude Code policy runtime.

Purpose:
- give the restart one grounding document instead of another drifting addendum
- define the target authority model before more implementation work lands
- keep cutover planning separate from the historical donor docs in the repo root

Authority rules:
- [CUTOVER_PLAN.md](CUTOVER_PLAN.md) records the architecture target and
  migration logic that produced ClauDEX.
- [braid-v2](braid-v2/README.md) is the clean-room workspace for the next
  supervision kernel.
- [bridge](bridge/) contains the current bridge adapter helpers.
- Runtime truth still lives in the repo-level `runtime/` package; ClauDEX docs
  describe that model, they do not replace it.

Operating intent:
- preserve architecture by constraint, not by convention
- make one authority per operational fact explicit in code
- treat hook wiring, docs, and config surfaces as derived outputs that must not
  silently drift from the runtime authority

Public-release note:
- Private operator handoff files, lane-state snapshots, and one-off runbooks
  are intentionally not part of this public tree.
- Use `README.md`, `docs/ARCHITECTURE.md`, `docs/DISPATCH.md`,
  `CLAUDE.md`, `agents/`, and the runtime tests for the current product
  surface.
