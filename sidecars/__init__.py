"""Shadow-mode sidecars — read-only runtime observers.

Sidecars observe runtime state but never write to canonical tables.
They are consumers only: they read from the SQLite runtime database
and produce derived views (health reports, search results) without
participating in any control-plane decision.

Sidecars remain in shadow mode (no hot-path authority) until the kernel
acceptance suite passes twice consecutively (INIT-003 exit criterion).

@decision DEC-SIDECAR-001
Title: Sidecars are read-only consumers of the canonical SQLite runtime
Status: accepted
Rationale: The successor architecture (MASTER_PLAN.md Architecture section,
  DEC-FORK-007) designates the typed runtime as the sole authority for
  shared workflow state. Sidecars must not become a second authority.
  Read-only access is enforced by convention (no INSERT/UPDATE/DELETE in
  sidecar code) and verified by the test suite row-count assertions.
  This keeps the sidecar/runtime boundary clean and prevents sidecars
  from accidentally becoming control-plane participants.
"""
