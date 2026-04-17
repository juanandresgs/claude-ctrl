# Phase 2b Post-Closure Audit — Dead/Orphan Recovery Gap

**Status:** planning-only (re-audit + next-slice scoping; no runtime or hook behavior change).
**Created:** 2026-04-17 after Rule-1 mechanical enforcement (custody tip `571c155`).
**Authorizing instruction:** `1776454973177-0015-fhtqe1`.

## Audit method

The two domain-promotion waves (`f1e4fc6 → a3653ad`) plus the Rule-1
invariant (`571c155`) closed most of §2a.  This audit re-checks the
four §2a models, the four §2a design rules, and the two specific
concerns the latest instruction calls out:

1. MCP-capable and tmux-hosted adapters using the same runtime
   dispatch/supervision model.
2. Dead-loop stop/recovery path being runtime-owned rather than a
   side effect of stop-hook recursion.

All findings are grounded in the code at custody tip `571c155`, not
in narrative.

## Model-by-model status

| Model | Domain module | State machine | CLI | Tests | Status |
|---|---|---|---|---|---|
| `agent_session` | `runtime/core/agent_sessions.py` (a3653ad) | `active → {completed, dead, orphaned}` | `cc-policy agent-session {get, mark-*, list-active}` | `test_agent_sessions.py` (24 tests) | ✅ |
| `seat` | `runtime/core/seats.py` (e982d50) | `active → {released, dead}`, `released → dead` | `cc-policy seat {get, release, mark-dead, list-*}` | `test_seats.py` (32 tests) | ✅ |
| `supervision_thread` | `runtime/core/supervision_threads.py` (f1e4fc6 → 5432e10) | `active → {completed, abandoned}` | `cc-policy supervision {attach, detach, abandon, abandon-for-*, list-*}` | `test_supervision_threads.py` (88 tests) | ✅ |
| `dispatch_attempt` | `runtime/core/dispatch_attempts.py` (Bundle 2) | `pending → delivered → ack/timed_out/failed` | `cc-policy dispatch {attempt-*}` | `test_dispatch_attempts.py` | ✅ |

All four §2a models now have a runtime-owned domain module, a
state-machine enforcement layer keyed off `runtime.schemas`, a query
surface, and a CLI.  The model-symmetry axis of §2a is complete.

## Design-rule status

### Rule 1 — tmux is execution surface, not authority

**Status:** ✅ mechanically enforced (`571c155`).
`tests/runtime/test_authority_table_writers.py` scans every `.py`
under `runtime/` and every `.sh` under `hooks/` + `scripts/` and
fails if any non-allowlisted surface issues `INSERT/UPDATE/DELETE`
against the four tables.  Scan is green at `571c155` — zero
violations on clean baseline.

### Rule 2 — MCP / provider-native adapters plug into runtime state machine

**Status:** ✅ for every installed adapter.

- `runtime/core/transport_contract.py:52` declares the
  `TransportAdapter` Protocol with `transport_name()`, `dispatch()`,
  `on_delivery_claimed()`, `on_acknowledged()`, `on_failed()`,
  `on_timeout()`.  All state transitions route through
  `runtime.core.dispatch_attempts`.
- `runtime/core/claude_code_adapter.py:91` implements the Protocol
  and registers `ADAPTER` at module load.
- `runtime/core/tmux_adapter.py:120` implements the Protocol and
  registers `ADAPTER` at module load.
- No MCP adapter exists in the repo.  That is not a gap — the
  contract is declared; any future MCP adapter inherits it by
  construction.  The Protocol pin guarantees a non-conformant
  adapter would fail at registration time, not silently coexist with
  a parallel state path.

### Rule 3 — Runtime owns dispatch claim/ack, review handoff, seat binding, timeout policy

- Dispatch claim/ack: `dispatch_attempts.claim` + adapter hooks. ✅
- Review handoff: `runtime/core/completions.py` + `bash_eval_readiness`. ✅
- Seat binding create + release: `seats.create`, `seats.release`
  (e982d50) with the SubagentStop adapters wired at `3967f6d`. ✅
- Timeout policy for `dispatch_attempts`: `dispatch_attempts.expire_stale`
  run via watchdog (`scripts/claudex-watchdog.sh:1040`). ✅
- **Dead / orphan transitions for `seat` and `agent_session`: ❌ gap.**
  `seats.mark_dead` and `agent_sessions.{mark_dead, mark_orphaned}`
  are declared and tested, but **no production caller invokes them**.
  The watchdog sweeps `dispatch_attempts` to `timed_out` but does
  not cascade to seats or sessions.

### Rule 4 — Recursive supervision is a first-class runtime action

**Status:** ✅ closed by `f1e4fc6 → 5432e10`.

## The remaining blocker

**The dead-loop recovery path is not runtime-owned.**

Today the only path that transitions a `seat` out of `active` is the
SubagentStop adapter (`3967f6d`).  When a subagent dies silently —
host process killed, adapter crashed, transport dropped — no
SubagentStop fires and:

- The `dispatch_attempt` is eventually flipped to `timed_out` by
  the watchdog sweep (good — this is runtime-owned).
- The `seat` that owns that attempt stays `active` forever.
- The `agent_session` stays `active` forever.
- Every `supervision_thread` touching the dead seat stays `active`
  forever (the bulk abandonment from `release_session_seat` was
  never invoked because `SubagentStop` never fired).

This creates a quiet inventory of stale `active` rows across all
three tables.  The invariant surface is present (`seats.mark_dead`,
`agent_sessions.mark_dead`, `agent_sessions.mark_orphaned`,
`supervision_threads.abandon_for_seat`), but the *caller* is
missing.  Recovery currently relies on SubagentStop firing; if the
stop event never arrives there is no runtime-owned way out of the
loop.

The fix must be *runtime-owned* rather than "wire a second stop-hook
path to try harder" — stop-hook recursion would re-introduce the
dual-authority anti-pattern §2a rule 3 exists to prevent.

## Next-wave definition — runtime-owned dead-loop sweeper

**Objective.** Add a runtime-owned sweeper that, when invoked by the
watchdog, transitions seats and agent_sessions to `dead` whenever
their backing `dispatch_attempts` have been `timed_out` or `failed`
for longer than a grace threshold with no SubagentStop rescue.
Cascade to `supervision_threads.abandon_for_seat` so threads touching
newly-dead seats close automatically.

No hook shell edit.  No new phase.  The sweeper is invoked from the
existing `scripts/claudex-watchdog.sh` call site that already shells
out to `cc-policy dispatch attempt-expire-stale`.

### In-scope files (next implementation slice)

| Path | Status | Role |
|---|---|---|
| `runtime/core/dead_recovery.py` | **NEW** | Single-file sweeper module.  Public API: `sweep_dead_seats(conn, *, grace_seconds=<default>) -> dict` and `sweep_dead_sessions(conn, *, grace_seconds=<default>) -> dict`.  Each returns `{swept: int, seats: [...], sessions: [...]}` for structured telemetry.  Implementation queries `dispatch_attempts` for rows in `{timed_out, failed}` whose `updated_at` is older than `now - grace_seconds` and whose owning seat is still `active`, then calls `seats.mark_dead()` + `supervision_threads.abandon_for_seat()` for each.  `sweep_dead_sessions` transitions `agent_sessions` whose every seat is `{released, dead}` to `completed` (normal end) or `dead` (if any seat is dead). |
| `runtime/cli.py` | **MODIFIED** | Add `cc-policy dispatch sweep-dead [--grace-seconds N]` subcommand calling `dead_recovery.sweep_dead_seats + sweep_dead_sessions` in one pass.  Structured JSON output with per-table counts.  Thin adapter. |
| `scripts/claudex-watchdog.sh` | **MODIFIED (1–3 lines)** | Immediately after the existing `attempt-expire-stale` invocation, invoke `cc-policy dispatch sweep-dead` best-effort with `|| true` to match the existing pattern.  No structural refactor. |
| `tests/runtime/test_dead_recovery.py` | **NEW** | Unit coverage: seats with recent-timeout attempts are NOT swept (still inside grace), seats with past-grace timed-out/failed attempts ARE swept, released seats are not re-written, already-dead seats are idempotent, cascade closes `supervision_threads.abandon_for_seat`, sessions with every seat terminal transition to `completed` or `dead`, CLI round-trip. |
| `tests/runtime/test_authority_table_writers.py` | **MODIFIED (small)** | Add `runtime/core/dead_recovery.py` to the authority-writer allowlist so the Rule-1 invariant continues to pass — the sweeper itself issues writes via the domain modules, not directly, but the file path must be acknowledged by the scanner.  Actually: if `dead_recovery.py` only calls `seats.mark_dead` / `agent_sessions.mark_dead` / `supervision_threads.abandon_for_seat` (domain-module delegation, no raw SQL), no allowlist extension is needed.  That is the target — the scanner stays on green baseline. |

### Out-of-scope for this wave (explicit)

- **Schema changes.** `dispatch_attempts.updated_at` already exists;
  the sweeper keys off it.  No new column.
- **Hook shell edits beyond the single watchdog call.** The
  SubagentStop adapters at `3967f6d` stay unchanged — they remain
  the primary (not the only) path to seat release.
- **`settings.json`, `HOOK_MANIFEST`, `hooks/HOOKS.md`** — unchanged.
- **Bridge transport.** No bridge adapter change.
- **New phase.** Post-Phase-8 continuation under the closed Phase 2b
  scope.
- **MCP adapter creation.** Out of scope; the contract is already in
  place for when one is added.

### Grace-threshold choice (design note for the implementation slice)

Default grace should be long enough that a normal slow adapter does
not get swept prematurely but short enough that a real crash frees
the inventory within one operational cycle.  `dispatch_attempts`
already uses a Bundle-2 timeout_at on pending rows.  A seat sweep
that looks at attempts whose `updated_at < now - (2 × dispatch
timeout default)` is a safe first number — re-litigable in a later
slice without breaking the contract.  The implementation slice
should declare the default as a module-level constant so a reviewer
can flip it without hunting through call sites.

### Acceptance tests (for the implementation slice)

```bash
pytest -q tests/runtime/test_dead_recovery.py
pytest -q tests/runtime/test_seats.py
pytest -q tests/runtime/test_agent_sessions.py
pytest -q tests/runtime/test_supervision_threads.py
pytest -q tests/runtime/test_authority_table_writers.py    # must stay green
python3 runtime/cli.py dispatch sweep-dead --help
python3 runtime/cli.py constitution validate               # healthy=true, concrete_count=24
python3 runtime/cli.py hook validate-settings              # entry_count=30, unchanged
python3 runtime/cli.py hook doc-check                      # exact_match=true, unchanged
```

All three "must remain unchanged" invariants hold (30 settings
entries, exact_match HOOKS.md, concrete_count=24).  Any drift stops
the slice.

### Stop / escalation boundaries

Halt implementation and escalate if:

1. **Schema drift.** The sweeper needs a column that doesn't exist
   (e.g., `seats.last_heartbeat_at`).  Stop — schema changes are
   constitution-level.
2. **Authority-writer allowlist change required.** The sweeper is
   supposed to delegate to domain modules; if it accumulates direct
   SQL, the Rule-1 invariant goes red, which means the design has
   regressed.
3. **Watchdog side effects beyond the single new invocation.**
   Anything that touches state outside the new sweeper command is
   out of scope.
4. **Hook-doc drift.** `hook doc-check` flipping to
   `exact_match=false` signals an unintended authority-surface touch.
5. **Cross-session mutation.** The sweeper must operate only on the
   same `(session_id, seat_id, thread_id)` triples its query
   selected — no bulk wildcard transitions.

### Rollback boundary

The implementation slice is:

- one new module (`dead_recovery.py`) — additive
- one CLI subcommand — additive
- one watchdog line — single `git revert` removes it
- one new test file + optional tiny existing-test extension

A `git revert` of the slice returns the system to `571c155` exactly.
No schema migration, no CLI contract removal, no authority surface
change, no hook wiring change beyond the watchdog one-liner.

## Included vs excluded scope — final

**Included in this planning artifact only (this commit):**

- `ClauDEX/PHASE2B_STATUS_2026-04-17_post_closure_dead_recovery.md`
  (this file)

**Intended for the next implementation slice (NOT in this commit):**

- `runtime/core/dead_recovery.py` (new)
- `runtime/cli.py` (sweep-dead subparser + handler)
- `scripts/claudex-watchdog.sh` (≤3 lines added)
- `tests/runtime/test_dead_recovery.py` (new)

**Explicitly excluded:**

- Schema changes.
- `settings.json`, `HOOK_MANIFEST`, `hooks/HOOKS.md`.
- Bridge transport stack.
- New phase creation.
- MCP adapter creation.
- Any change to SubagentStop adapters (`hooks/check-*.sh`) — the
  `3967f6d` wiring remains the primary path; the sweeper is the
  runtime-owned fallback for the silent-death case.
- Docs beyond this planning artifact.

## Decision annotation (for the implementation slice's commit)

```
@decision DEC-DEAD-RECOVERY-001
@title Runtime-owned dead/orphan sweeper for §2a seat and session
@status accepted
@rationale The SubagentStop path (3967f6d) handles the normal seat-
  teardown case but relies on a stop event firing.  When the event
  never fires (silent crash, transport drop, host kill), seats and
  sessions stay active indefinitely, which §2a rule 3 forbids
  because recovery then relies on hook-adapter recursion rather
  than runtime authority.  This slice adds a runtime-owned sweeper
  invoked by the existing watchdog so dead/orphan transitions are
  authored by the runtime, not by stop-hook side effects.  Post-
  Phase-8 continuation; no new phase.
```

## Planning artifact invariant

Future revisions of this audit should supersede this file by a
newer dated `PHASE2B_STATUS_YYYY-MM-DD_*.md` rather than editing
this file in place, preserving the audit record and letting
`git log` show the slice-selection history.
