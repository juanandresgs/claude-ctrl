# Phase 2b §2a Status Audit + Next-Wave Definition — `seat` domain promotion

**Status:** planning-only (audit + next-slice scoping; no runtime or hook behavior change).
**Created:** 2026-04-17 after the SubagentStop behavioral pin slice (custody tip `d733ee3`).
**Authorizing instruction:** `1776453938665-0011-0uqsrj`.

## Audit method

§2a ("Agent-Agnostic Supervision Fabric", `ClauDEX/CUTOVER_PLAN.md:387`)
lists **four target models** and **four design rules**. This audit maps
each to concrete installed truth — file paths, domain modules, CLI
surfaces, test pins — at custody tip `d733ee3`, not to narrative.

## Model-by-model status

### Target 1 — `agent_session` (one live agent instance bound to one workflow + transport)

| Criterion | Evidence | Status |
|---|---|---|
| Schema table | `runtime/schemas.py:527 CREATE TABLE agent_sessions` | ✅ |
| Write path | `runtime/core/dispatch_hook.py:88 ensure_session_and_seat` upserts row | ✅ |
| Runtime-owned domain module | `runtime/core/agent_sessions.py` **does not exist** | ❌ |
| State-machine enforcement | No domain helpers; `AGENT_SESSION_STATUSES = {active, completed, dead, orphaned}` declared but only `active` is ever written | ❌ |
| CLI surface | None | ❌ |

### Target 2 — `seat` (named role inside a session)

| Criterion | Evidence | Status |
|---|---|---|
| Schema table | `runtime/schemas.py:547 CREATE TABLE seats`; `SEAT_STATUSES = {active, released, dead}`; `SEAT_ROLES = {worker, supervisor, reviewer, observer}` | ✅ |
| Create path | `dispatch_hook.ensure_session_and_seat` (`INSERT OR IGNORE`) | ✅ |
| Release path | `dispatch_hook.release_session_seat` (`UPDATE seats SET status='released'`) — landed at `472d94b` | ✅ |
| `dead` transition | No caller anywhere writes `status='dead'` | ❌ |
| Runtime-owned domain module | `runtime/core/seats.py` **does not exist**; both writes live inside `dispatch_hook.py` (lines `99`, `273`) | ❌ |
| State-machine enforcement | Ad-hoc inline SQL UPDATE; no `_VALID_TRANSITIONS` dict, no shared vocabulary guard | ❌ |
| Query surface | Callers read `seats` directly via raw SQL; no list helpers | ❌ |
| CLI surface | None — the closest is `cc-policy dispatch seat-release` (a thin adapter over the hook helper, not a seat-domain CLI) | ❌ |

### Target 3 — `supervision_thread` (attached analysis/review/autopilot relationship)

| Criterion | Evidence | Status |
|---|---|---|
| Schema table | `runtime/schemas.py:566 CREATE TABLE supervision_threads` | ✅ |
| Runtime-owned domain module | `runtime/core/supervision_threads.py` with 9 public methods (`attach`, `detach`, `abandon`, `get`, `list_for_supervisor`, `list_for_worker`, `list_for_session`, `list_for_seat`, `list_active`, `abandon_for_seat`, `abandon_for_session`) | ✅ |
| State-machine enforcement | `_VALID_TRANSITIONS = {active: {completed, abandoned}, ...}`; vocabulary sourced exclusively from `runtime.schemas.SUPERVISION_THREAD_STATUSES` / `_TYPES`; seat-existence invariant enforced at domain layer (`887f4e1`) | ✅ |
| CLI surface | `cc-policy supervision {attach, detach, abandon, abandon-for-seat, abandon-for-session, get, list-*, list-active}` — 11 actions | ✅ |
| Tests | `tests/runtime/test_supervision_threads.py` + schema pin = 88 passing tests at `5432e10`; domain-vs-schema linkage pinned | ✅ |

### Target 4 — `dispatch_attempt` (issued instruction with claim/ack/retry/timeout)

| Criterion | Evidence | Status |
|---|---|---|
| Schema table | `runtime/schemas.py` `dispatch_attempts` DDL | ✅ |
| Runtime-owned domain module | `runtime/core/dispatch_attempts.py` full state machine | ✅ |
| Hook-event bridging | `dispatch_hook.record_agent_dispatch` (PreToolUse → issue), `dispatch_hook.record_subagent_delivery` (SubagentStart → claim) | ✅ |
| Timeout discipline | `dispatch_attempts.expire_stale` + `timeout_at` on pending attempts + watchdog sweep (Bundle 2) | ✅ |
| CLI surface | `cc-policy dispatch {attempt-issue, attempt-claim, attempt-expire-stale, ...}` | ✅ |

## Design-rule status

### Rule 1 — tmux is execution surface, not authority

**Status:** ✅ conceptually; ⚠ un-audited mechanically. The bridge stack
(`scripts/claudex-*.sh`) is scoped to containment per supervisor
discipline, and no runtime-owned domain reads tmux pane text to make
decisions. A mechanical pin that bridge adapters cannot write to
`seats`, `agent_sessions`, `supervision_threads`, or `dispatch_attempts`
directly does not yet exist. Flagged but out of scope for this wave —
enforcement here belongs in a later bridge-containment slice.

### Rule 2 — MCP / provider-native adapters plug into runtime state machine

**Status:** ✅ for the only adapter currently installed.
`runtime/core/claude_code_adapter.py` + `runtime/core/transport_contract.py`
enforce that adapters call into `dispatch_attempts` rather than write
directly. No MCP adapter exists yet; when one is added it inherits this
contract by construction.

### Rule 3 — Runtime owns dispatch claim/ack, review handoff, seat binding, timeout policy

| Aspect | Evidence | Status |
|---|---|---|
| Dispatch claim/ack | `dispatch_attempts.claim` + `ADAPTER.on_delivery_claimed` | ✅ |
| Review handoff | `runtime/core/completions.py` + `cc-policy completion submit` + `bash_eval_readiness` policy | ✅ |
| Seat binding (create) | `dispatch_hook.ensure_session_and_seat` | ✅ (hook-adapter module, not domain) |
| Seat binding (terminate) | `dispatch_hook.release_session_seat` | ✅ (hook-adapter module, not domain) |
| Seat binding (dead transition / richer lifecycle) | No caller; no enforcement | ❌ |
| Timeout policy | `dispatch_attempts.expire_stale` + `timeout_at` + watchdog cron | ✅ |

### Rule 4 — Recursive supervision is a first-class runtime action

**Status:** ✅ closed by the supervision_threads domain promotion
(`f1e4fc6` → `5432e10`). "Open an attached analysis thread on the
running worker" is now `cc-policy supervision attach --supervisor-seat-id
... --worker-seat-id ... --thread-type ...` — a first-class runtime
action, not a bridge trick.

## The single remaining blocker

**`seat` lacks a runtime-owned domain module.** Among all four §2a
models, seat is the only one whose writes still live inside
`dispatch_hook.py` — a hook-adapter module by its own declared
authority boundary:

> `dispatch_hook.py`'s docstring: "the thin Python bridge between Claude
> Code harness events and the dispatch_attempts domain authority"

That means:

1. Seat lifecycle transitions have no `_VALID_TRANSITIONS` vocabulary
   guard; `UPDATE seats SET status='released'` is an inline SQL string
   in `dispatch_hook.py:273`.
2. The `dead` state declared in `SEAT_STATUSES` has no writer; there's
   no path to mark a seat `dead` when a session dies or an adapter
   reports an irrecoverable failure.
3. There is no runtime-owned seat query API (`get`, `list_for_session`,
   `list_active`, `list_released`). Callers read raw SQL.
4. Seat is the FK target for both `supervision_threads` (via
   supervisor_seat_id / worker_seat_id) and `dispatch_attempts` (via
   seat_id). Both of those referrers now enforce seat-existence
   invariants at the domain layer (887f4e1 for supervision_threads);
   seat itself has no reciprocal guard on its own transitions.
5. `agent_session` has the same structural gap but closing seat first
   unlocks the full §2a pattern because seat is directly entwined with
   the two primitives that already have domain modules. Agent_session
   can follow in a subsequent slice; the absence of an
   agent_sessions.py does not currently block any active runtime path.

Closing this blocker finishes §2a model symmetry: all four primitives
would have a domain module, state-machine enforcement, a query surface,
and a CLI. It is a pure structural mirror of the supervision_threads
slice just landed.

## Next-wave definition — `seat` domain promotion

**Objective.** Promote `seat` from "writes scattered in `dispatch_hook.py`"
to a runtime-owned domain module (`runtime/core/seats.py`) with the
same discipline as `supervision_threads.py`. No schema change.

### In-scope files (next implementation slice)

| Path | Status | Role |
|---|---|---|
| `runtime/core/seats.py` | **NEW** | Domain module. Public API: `create(conn, seat_id, session_id, role) -> dict`, `get(conn, seat_id) -> dict`, `release(conn, seat_id) -> dict`, `mark_dead(conn, seat_id) -> dict`, `list_for_session(conn, session_id, *, status=None) -> list[dict]`, `list_active(conn) -> list[dict]`. State machine `{active: {released, dead}, released: {dead}, dead: frozenset()}`. Vocabulary sourced exclusively from `runtime.schemas.SEAT_STATUSES` / `SEAT_ROLES`. Module docstring carries `@decision DEC-SEAT-DOMAIN-001`. |
| `runtime/core/dispatch_hook.py` | **MODIFIED (refactor only, behavior unchanged)** | `ensure_session_and_seat` delegates its `INSERT OR IGNORE INTO seats` call to `seats.create` (idempotent on already-existing seat); `release_session_seat` delegates its `UPDATE seats SET status='released'` call to `seats.release`. Public API of both helpers is unchanged; this is a pure inward refactor so the existing 93 dispatch_hook + supervision tests stay green. |
| `runtime/cli.py` | **MODIFIED** | Add `seat` subparser with `get`, `release`, `mark-dead`, `list-for-session`, `list-active` actions + `_handle_seat()` thin handler. No seat-creation subcommand (seats are created exclusively through dispatch_hook bootstrap). |
| `tests/runtime/test_seats.py` | **NEW** | Unit coverage: valid create/release/mark-dead transitions, invalid transitions raise `ValueError` (release→release, dead→anything), unknown seat in release/mark-dead raises, list helpers filter by status, CLI round-trip. Same structure as `test_supervision_threads.py`. |
| `tests/runtime/test_supervision_schema.py` | **MODIFIED (small)** | Extend existing domain-vs-schema linkage test with a seats.py public-API pin (just like the supervision_threads pin it already carries). |
| `tests/runtime/test_dispatch_hook.py` | **MODIFIED (small)** | Add one pin that `ensure_session_and_seat` and `release_session_seat` delegate to the seats domain module (import path + integration), so the refactor cannot silently revert. |

### Out-of-scope for this wave (explicit)

- **`runtime/schemas.py`** — not edited. `seats` DDL and `SEAT_STATUSES`
  / `SEAT_ROLES` frozensets already exist and are unchanged.
- **`runtime/core/agent_sessions.py`** — not created. Agent_session
  domain promotion is a **follow-up** slice, not this one. The gap is
  acknowledged but closing seat is the higher-leverage move.
- **Hook shell scripts** — no `hooks/*.sh` edit. SubagentStop wiring
  already lives at `3967f6d` and is preserved by the inward refactor of
  `release_session_seat`.
- **`settings.json`, `HOOK_MANIFEST`, `hooks/HOOKS.md`** — unchanged.
- **Bridge transport** — unchanged. Bridge containment preserved.
- **No new phase** — post-Phase-8 continuation under the closed Phase
  2b scope.
- **No MCP adapter work** — not required by this wave.

### Test + evidence strategy

Required acceptance commands for the implementation slice:

```bash
pytest -q tests/runtime/test_seats.py
pytest -q tests/runtime/test_supervision_schema.py
pytest -q tests/runtime/test_dispatch_hook.py       # must stay 93 green
pytest -q tests/runtime/test_supervision_threads.py # must stay 88 green
python3 runtime/cli.py seat --help
python3 runtime/cli.py constitution validate         # healthy=true, concrete_count=24
python3 runtime/cli.py hook validate-settings        # entry_count=30, unchanged
python3 runtime/cli.py hook doc-check                # exact_match=true, unchanged
```

All three "must remain unchanged" invariants from prior slices hold:
30 settings entries, HOOKS.md exact_match, 24 concrete constitution
paths. Any movement in those numbers means the slice has drifted
outside planned scope and must stop for supervisor review.

### Stop / escalation boundaries

Halt implementation and escalate to the Codex supervisor if any of
these surface:

1. **Schema change required.** If the domain module's invariants need a
   new column on `seats` (e.g. a `released_at` timestamp not currently
   present), stop. Schema changes are constitution-level and require
   separate authorization.
2. **Behavior change in `dispatch_hook.ensure_session_and_seat` /
   `release_session_seat`.** The refactor must preserve external
   behavior exactly — same return shape, same idempotency, same
   exit conditions. If the delegation requires a visible behavioral
   change, stop and escalate.
3. **Existing hook tests break.** `tests/runtime/test_dispatch_hook.py`
   must stay at 93 passing (source pins + behavioral pins). Any
   regression means the refactor is not behaviorally equivalent.
4. **Hook-doc drift.** `hook doc-check` flipping to `exact_match=false`
   signals an unintended authority-surface touch.
5. **Capability-gate collision.** Policy denies runtime source writes
   for reasons beyond routine WHO enforcement.
6. **Bridge transport appears in the diff.** Bridge stays containment
   for this wave.

### Rollback boundary

The slice is structurally a single-commit `git revert` back to
`d733ee3` — the domain module is additive, the CLI subparser is
additive, the `dispatch_hook.py` refactor is a pure inward delegation.
No schema migration, no CLI contract removal, no hook wiring change.

## Included vs excluded scope — final

**Included in this planning artifact only (this commit):**

- `ClauDEX/PHASE2B_STATUS_2026-04-17_next_wave_seat_domain.md`
  (this file)

**Intended for the next implementation slice (NOT in this commit):**

- `runtime/core/seats.py` (new)
- `runtime/core/dispatch_hook.py` (inward refactor only)
- `runtime/cli.py` (`seat` subparser + handler)
- `tests/runtime/test_seats.py` (new)
- `tests/runtime/test_supervision_schema.py` (small invariant extension)
- `tests/runtime/test_dispatch_hook.py` (small delegation pin)

**Explicitly excluded:**

- Bridge transport stack.
- `settings.json`, `HOOK_MANIFEST`, `hooks/HOOKS.md`.
- Schema changes.
- `runtime/core/agent_sessions.py` (deferred to a follow-up slice).
- Any new phase.
- CLAUDE.md / CUTOVER_PLAN.md / SUPERVISOR_HANDOFF.md edits.

## Decision annotation (for the implementation slice's commit)

```
@decision DEC-SEAT-DOMAIN-001
@title seat promoted to runtime-owned domain module
@status accepted
@rationale §2a requires every supervision primitive to be runtime-
  owned with a domain module, state-machine enforcement, query
  surface, and CLI.  Three of four primitives already are;
  supervision_threads was closed at f1e4fc6→5432e10 and seat is the
  last one whose writes still live inside dispatch_hook.py.  This
  slice promotes seat to a first-class domain with the same shape as
  supervision_threads, delegating existing hook-adapter writes inward
  so external behavior is unchanged.  Post-Phase-8 continuation under
  the closed Phase 2b scope; no new phase.
```

## Planning artifact invariant

Future revisions of this audit (if supervisor redirects) should
supersede this file by a newer dated `PHASE2B_STATUS_YYYY-MM-DD_*.md`
rather than editing this file in place, preserving the audit record
and letting `git log` show the slice-selection history.
