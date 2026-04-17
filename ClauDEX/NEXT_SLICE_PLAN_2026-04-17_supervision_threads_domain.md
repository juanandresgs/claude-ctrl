# Next Implementation Slice — `supervision_threads` domain promotion

**Status:** planning-only (no code in this bundle).
**Created:** 2026-04-17 post-Integration-Wave-1 promotion (custody tip `516589a`).
**Authorizing instruction:** `1776451373640-0002-gv80p3`.

## Why this is the next slice

`ClauDEX/CUTOVER_PLAN.md` §Target Architecture 2a names four supervision
models that the runtime must own:

- `agent_session` — **present** (`agent_sessions` table + `dispatch_hook.py` upsert)
- `seat` — **present** (`seats` table + `dispatch_hook.py` upsert)
- `supervision_thread` — **EMPTY DOMAIN** (table DDL exists, no writers or readers)
- `dispatch_attempt` — **present** (full state machine in `dispatch_attempts.py`,
  Bundle 2 timeout discipline applied)

Three of four supervision primitives have runtime authority and CLI
exposure. The fourth — `supervision_threads` — was seeded with a schema
table in Phase 2b Slice 7 (`DEC-CLAUDEX-SUPERVISION-DOMAIN-001`) but was
never promoted to a domain module. CUTOVER_PLAN §2a design rule 4 says:

> Recursive supervision is represented explicitly as a relationship
> between seats. "Open an attached analysis thread on the running worker"
> is therefore a first-class runtime action, not a special-case bridge
> trick.

Today the only attached-analysis path is the bridge's tmux-pane-scraping
stack (explicitly "diagnostics only" per §2a rule 3). Promoting
`supervision_threads` to a domain module gives the runtime a first-class
answer to "open an attached analysis thread" without any bridge work.

This is **post-Phase-8 continuation**, not a new phase. `CUTOVER_PLAN.md`
declares no Phase 9; this slice lives under the closed Phase 2b scope
(§2a fabric build-out) as a deferred table-to-domain promotion.

## Objective

Promote `supervision_threads` from "schema table only" to a complete
runtime-owned domain with:

- a CRUD + state-query module (`runtime/core/supervision_threads.py`),
- a CLI surface (`cc-policy supervision attach|detach|list`),
- explicit invariant tests,
- atomic single-transaction writes (per Sacred Practice #11).

No new schema table. No new hook wiring. No new HOOK_MANIFEST entry. No
bridge transport touch. One domain module + one CLI subparser + one
test file.

## In-scope files / modules

| Path | Status | Role |
|---|---|---|
| `runtime/core/supervision_threads.py` | **NEW** | Domain module. Public API: `attach(conn, supervisor_seat_id, worker_seat_id, *, workflow_id, relationship_kind) -> int` returning `thread_id`; `detach(conn, thread_id)`; `get(conn, thread_id)`; `list_for_session(conn, agent_session_id)`; `list_for_seat(conn, seat_id)`; `list_active(conn)`. Module docstring carries `@decision DEC-SUPERVISION-THREADS-DOMAIN-001`. Mirrors `dispatch_attempts.py` structure. Status vocabulary `{"active", "detached"}` with explicit `ValueError` on invalid transitions. All writes in `with conn:` blocks. |
| `runtime/cli.py` | **MODIFIED** | Add `supervision` subparser with `attach`/`detach`/`get`/`list-for-session`/`list-for-seat`/`list-active` actions. `_handle_supervision(args)` thin handler forwarding to the domain module. Add `if args.domain == "supervision": return _handle_supervision(args)` branch. |
| `tests/runtime/test_supervision_threads.py` | **NEW** | Unit coverage: valid attach/detach, double-detach raises ValueError, invalid seat_id rejected (FK), list helpers return expected rows, round-trip via CLI subprocess. |
| `tests/runtime/test_supervision_schema.py` | **MODIFIED** (small) | Add one invariant pin that the domain module is importable and its public names match the table's column vocabulary. |

## Out-of-scope files / modules (explicit)

- **Schema surface** — `runtime/schemas.py` is **not** edited. The
  `supervision_threads` table DDL already exists (landed in Phase 2b).
- **Hook wiring** — No hook edits. No `settings.json` edits. No
  `hook_manifest.py` edits. `hooks/HOOKS.md` projection stays exact-match.
- **Bridge transport** — all `scripts/claudex-*.sh`, `hooks/claudex-*.sh`,
  watchdog, tmux bridge helpers: **not touched**. Bridge stays
  containment per handoff discipline.
- **Other supervision primitives** — `agent_sessions`, `seats`,
  `dispatch_attempts`: not touched.
- **Transport adapters** — `transport_contract.py`, `tmux_adapter.py`,
  `claude_code_adapter.py`: not touched. The adapter protocol is
  runtime-agnostic to supervision threads.
- **Policy modules** — no new policy; capability contracts stay as-is.
- **Docs** — `CLAUDE.md`, `ClauDEX/CUTOVER_PLAN.md`,
  `ClauDEX/SUPERVISOR_HANDOFF.md`: not touched. This planning artifact
  (`NEXT_SLICE_PLAN_2026-04-17_supervision_threads_domain.md`) is the
  only doc in flight.

## Invariant / test evidence required before commit

1. **New unit tests pass:**
   `pytest -q tests/runtime/test_supervision_threads.py` → all tests
   green.
2. **Schema invariant extended:**
   `pytest -q tests/runtime/test_supervision_schema.py` →
   previous-count pins still green; new import-and-column-name pin
   passes.
3. **CLI round-trip:** a subprocess test that invokes
   `python3 runtime/cli.py supervision attach` / `list-active` / `detach`
   end-to-end against an in-memory DB returns `status=ok` and
   structurally valid JSON.
4. **Constitution health:**
   `python3 runtime/cli.py constitution validate` → `healthy=true`,
   `concrete_count=24` **unchanged**. `supervision_threads.py` is a new
   runtime module but NOT a constitution-level file (schemas.py stays
   the sole constitution-level schema authority).
5. **Hook wiring health:** `cc-policy hook validate-settings` and
   `cc-policy hook doc-check` both green and unchanged — this slice does
   not touch hook wiring.
6. **No Phase 9 discipline:** the commit message must NOT announce a new
   phase. It must reference this planning artifact (DEC-SUPERVISION-
   THREADS-DOMAIN-001) as Phase 2b §2a continuation.

## Explicit stop / escalation boundaries

Halt implementation and escalate to the Codex supervisor if any of
these surfaces:

1. **Hook wiring required.** If the domain module's intended operation
   requires a new hook (e.g. auto-attach on `SubagentStart`), stop. Hook
   wiring changes require separate Codex authorization and would expand
   scope into Phase 2 territory.
2. **Schema change required.** If `supervision_threads`'s existing DDL
   needs column additions/changes for the domain module to function,
   stop. Schema changes are constitution-level (`runtime/schemas.py`
   concrete file) and require planner-scoped authorization.
3. **Transport-adapter coupling.** If the domain API must call back into
   `transport_contract.py` / `tmux_adapter.py` / `claude_code_adapter.py`,
   stop and escalate. The CUTOVER design says adapters plug into the
   runtime state machine, not the other way around.
4. **Bridge transport dependency.** If a live-bridge artifact must be
   read/written by the new domain, stop. Bridge stays containment.
5. **Capability-gate collision.** If `bash_git_who`, `write_who`,
   `bash_write_who`, or `write_plan_guard` deny the implementer's source
   writes for reasons beyond routine WHO enforcement (e.g., a policy
   insists supervision state needs a `CAN_SET_CONTROL_CONFIG` check that
   doesn't exist yet), stop.
6. **Pre-existing test regression.** If focused tests surface any NEW
   failure in the runtime suite that wasn't already baseline, stop and
   diagnose rather than patch.

## Bridge transport containment statement

Bridge transport work (`scripts/claudex-*.sh`, `hooks/claudex-*.sh`,
`tests/runtime/test_claudex_*.py`, `ClauDEX/OVERNIGHT_RUNBOOK.md`,
`ClauDEX/SOAK_REMEDIATION_READINESS_*.md`) remains out-of-scope
containment for this slice. The 57-row main-repo dirty set covering
that surface is preserved intact. Bridge refinement must be its own
session under separate supervisor authorization. This slice operates
entirely on runtime-owned surfaces (`runtime/core/`, `runtime/cli.py`,
`tests/runtime/test_supervision_*`).

## Included vs excluded scope — final

**Included in this planning artifact only (this commit):**
- `ClauDEX/NEXT_SLICE_PLAN_2026-04-17_supervision_threads_domain.md`
  (this file)

**Intended for the next implementation slice (NOT in this commit):**
- `runtime/core/supervision_threads.py` (new)
- `runtime/cli.py` (supervision subparser + handler)
- `tests/runtime/test_supervision_threads.py` (new)
- `tests/runtime/test_supervision_schema.py` (small invariant extension)

**Explicitly excluded:**
- Bridge transport stack (entirely).
- Hook wiring / `settings.json` / `hook_manifest.py`.
- Schema changes.
- Other supervision primitives or transport adapters.
- New phase creation.
- Broad docs rewrites.

## Acceptance test list (for the implementation slice)

Exactly these commands must be green in the implementer's worktree
before checkpoint attempt:

```bash
pytest -q tests/runtime/test_supervision_threads.py
pytest -q tests/runtime/test_supervision_schema.py
pytest -q tests/runtime/   # no new failures beyond tracked baseline
python3 runtime/cli.py supervision --help
python3 runtime/cli.py constitution validate
python3 runtime/cli.py hook validate-settings
python3 runtime/cli.py hook doc-check
python3 runtime/cli.py doc ref-check CLAUDE.md   # must remain healthy=true, refs=0
```

## Decision annotation (for the implementation slice's commit)

```
@decision DEC-SUPERVISION-THREADS-DOMAIN-001
@title supervision_threads promoted to runtime-owned domain module
@status accepted
@rationale Phase 2b §2a (DEC-CLAUDEX-SUPERVISION-DOMAIN-001) seeded the
  supervision_threads table but never promoted it to a domain. This
  slice adds the module + CLI + tests so "open an attached analysis
  thread on the running worker" becomes a first-class runtime action
  per CUTOVER_PLAN Target Architecture §2a design rule 4, without any
  bridge transport touch. Post-Phase-8 continuation under the closed
  Phase 2b scope; no new phase opened.
```

## Planning artifact invariant

Future revisions of this planning artifact (if Codex supervisor redirects
to a different next slice) should supersede this file by a newer dated
`NEXT_SLICE_PLAN_YYYY-MM-DD_*.md` rather than editing this file in
place. That preserves the planning record and lets `git log` show the
slice-selection history.
