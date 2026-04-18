# Category C Retirement — Execution-Ready Scoping Packet

**Status:** planning-only (docs-only commit; no code execution).
**Created:** 2026-04-17 after `f37b8ab` (dead-recovery selector correction).
**Authorizing instruction:** `1776455948372-0019-tl9i2v`.

This packet does **not** reopen Phase 8 and does **not** create Phase 9.
It is a post-Phase-8 continuation under the closed Phase 2b scope,
aligned with `ClauDEX/CUTOVER_PLAN.md` (no Phase 9 defined).

## Installed truth — what is already done

Both Category C tracks named in `ClauDEX/PHASE8_DELETION_INVENTORY.md`
have had their **code surface** retired:

- `proof_state` track — retired post-Phase-8 at `f72e656`
  (`DEC-CATEGORY-C-PROOF-RETIRE-001`). `runtime/core/proof.py`
  deleted; `PROOF_STATE_DDL` and its `ALL_DDL` entry removed from
  `runtime/schemas.py`; `proof get/set/list` CLI retired; observatory
  / statusline / evaluation references rewritten to retirement
  pointers; invariant pin landed as
  `tests/runtime/test_phase8_category_c_proof_retired.py`.

- `dispatch_queue` + `dispatch_cycles` track — retired post-Phase-8
  at `369cca6` (`DEC-CATEGORY-C-DISPATCH-RETIRE-001`).
  `runtime/core/dispatch.py` deleted; `DISPATCH_QUEUE_DDL` /
  `DISPATCH_CYCLES_DDL` / their `ALL_DDL` entries and status
  frozensets removed from `runtime/schemas.py`; six legacy CLI
  actions retired; observatory / statusline references rewritten;
  invariant pin landed as
  `tests/runtime/test_phase8_category_c_dispatch_retired.py`.

The `PHASE8_DELETION_INVENTORY.md` Category C section declares the
code-surface retirement "fully closed" and future-bundle scope
"none remaining."

## What this packet scopes (the remaining deferred piece)

Both retirements were executed under a **non-destructive posture**:

- No runtime `DROP TABLE` was issued for `proof_state`,
  `dispatch_queue`, or `dispatch_cycles`.
- New databases never create the tables (DDL gone from
  `runtime/schemas.py`'s `ALL_DDL`).
- Existing databases that ran under pre-retirement ClauDEX retain
  the inert rows until a forensic operator drops them manually.

That residual state is the single deferred unit of Category C
retirement that remains.  This packet turns it into an
execution-ready plan — not into an execution.

## Sub-slice ordering (proof_state first, dispatch next)

Finalization splits cleanly into two independent sub-slices, to be
executed in this order if and only if a future instruction
authorizes it:

### Sub-slice 1 — `proof_state` forensic cleanup

| Aspect | Value |
|---|---|
| Authority | `runtime.schemas` already owns the DDL surface; this sub-slice owns the *one-time* erasure of residual rows. The five-element authority-writer allowlist stays unchanged. |
| Removal target | Inert `proof_state` rows on pre-retirement databases. |
| Proposed shape | A dedicated, idempotent one-shot migration module (e.g. `runtime/core/phase8_category_c_cleanup.py` or a `scripts/one_shot/` entry) guarded by an explicit `--yes-drop-proof-state` flag. Issues `DROP TABLE IF EXISTS proof_state`. No schema-DDL change, no `runtime/schemas.py` edit, no CLI-subparser persistence. |
| Required invariants before run | `cc-policy constitution validate` healthy `concrete_count=25`; `tests/runtime/test_phase8_category_c_proof_retired.py` green; authority-writer invariant green (the migration module is a one-shot outside the runtime authority surface and must be allowlisted explicitly before running). **Stability note:** the `concrete_count` / `entry_count` numbers reflect the live registry at packet-reconciliation time (post-`cc-policy-who-remediation` + post-merge hardening, lane HEAD `566e2d7`). An execution slice must re-snapshot the live baseline at dispatch time and treat post-dispatch movement — not historical packet-baseline mismatch — as the halt condition per Escalation boundaries §3. |
| Acceptance evidence | Post-run SQLite `PRAGMA table_info(proof_state)` returns empty on any target DB; invariant pin extended with a one-line "no table anywhere" check. |
| Rollback boundary | `DROP TABLE IF EXISTS` is not reversible. A forensic operator must snapshot the DB first.  The packet therefore declares this a **one-way operation** and requires explicit user sign-off before it runs. |

### Sub-slice 2 — `dispatch_queue` + `dispatch_cycles` forensic cleanup

| Aspect | Value |
|---|---|
| Authority | Same as Sub-slice 1. Authority-writer allowlist unchanged. |
| Removal target | Inert `dispatch_queue` and `dispatch_cycles` rows on pre-retirement databases. |
| Proposed shape | Same migration module extended with `--yes-drop-dispatch-queue` and `--yes-drop-dispatch-cycles` flags. `DROP TABLE IF EXISTS` for each. |
| Required invariants before run | Same as Sub-slice 1, plus `tests/runtime/test_phase8_category_c_dispatch_retired.py` green. |
| Acceptance evidence | `PRAGMA table_info(dispatch_queue)` / `PRAGMA table_info(dispatch_cycles)` both empty post-run; invariant pin extended. |
| Rollback boundary | Same one-way declaration. Requires explicit user sign-off. |

The ordering matters only for blast-radius isolation: proof_state
is a self-contained read-only surface, while `dispatch_queue` /
`dispatch_cycles` historically fed observability paths (the
surface is retired but a cautious operator runs the simpler
sub-slice first and confirms no regressions before running the
second).

## Explicit non-goals

- **No schema-DDL edit.** `runtime/schemas.py` is already clean of
  the retired DDL constants; no further edit.
- **No CLI persistence.** Any migration module is a one-shot
  forensic tool, invoked explicitly by an operator, not a
  permanent `cc-policy` subcommand.
- **No runtime/hook/bridge change.** The runtime has been running
  without these tables since `f72e656` / `369cca6`; the residual
  rows are invisible to it.
- **No *permanent* authority-writer allowlist expansion.** This
  non-goal prohibits any general, open-ended widening of the
  five-element authority-writer allowlist in
  `tests/runtime/test_authority_table_writers.py`. It does **not**
  prohibit a bounded, one-shot exception for the migration module
  itself — that exception is in fact required by the Proposed-shape
  rows of both sub-slices. To remain within this non-goal, any
  future migration writer MUST:
  - be added to the allowlist as an explicitly-commented one-shot
    exception (comment naming `DEC-CATEGORY-C-FORENSIC-001`, the
    sub-slice it belongs to, and the single `DROP TABLE IF EXISTS`
    it authorises),
  - ship with a same-slice decommission plan — the allowlist entry
    is scoped to the migration module and must be removed (along
    with the module itself, per "No CLI persistence") once the
    forensic run has been executed on all enumerated target DBs
    and verified, in the **same** slice that runs the cleanup or
    its immediate successor,
  - not authorise writes against any §2a table or any non-retired
    table — the exception is limited to `proof_state`,
    `dispatch_queue`, and `dispatch_cycles` and to the
    `DROP TABLE IF EXISTS` statement only.
  Any deviation — a long-lived allowlist entry, a broader op set,
  a second table target — is outside this packet's scope and
  requires a fresh authorising instruction.
- **No reintroduction.** If a future slice adds a new domain with
  the same table name, that is a separate Rule-1 authority review
  and is outside this packet's scope.

## Escalation boundaries (when Codex / user decision is required)

The packet itself is planning-only and lands no code.  A future
slice that *executes* Sub-slice 1 or Sub-slice 2 must escalate to
explicit user approval before running, because:

1. **`DROP TABLE` is destructive.** Sacred Practice #8 gates
   approval for irreversible operations.
2. **Data forensics.** Existing DBs that carry inert rows may be
   the only record of historical activity a future audit needs;
   dropping the tables without snapshotting them is irreversible
   data loss.
3. **Cross-database impact.** Operators run ClauDEX against
   multiple DBs (main, worktree, soak); a migration run once must
   be deliberate about which DB it targets.
4. **Authority-writer allowlist.** A migration module that issues
   `DROP TABLE` against the retired tables is a one-off exception
   to the Rule-1 invariant; adding the exception requires explicit
   review so it does not become a precedent.

If any of the following surface during a future execution slice,
**halt and report**:

- Invariant tests (`test_phase8_category_c_proof_retired.py`,
  `test_phase8_category_c_dispatch_retired.py`) turn red.
- A new active reader of the retired tables is discovered (should
  be impossible given Rule-1 but re-checkable).
- `cc-policy hook validate-settings` / `hook doc-check` /
  `constitution validate` numbers move.
- The target DB carries rows with non-default shape suggesting
  active-era writes the retirement missed (would mean the bundle
  did not actually retire the writer).

## Pre-execution operator prerequisites (for any future execution slice)

These are **operator-supplied** prerequisites that must be captured
**before** an execution slice is dispatched. The packet is
planning-only; none of these prerequisites are satisfied by this
commit. This section does not authorise execution — it names the
inputs a future execution slice will demand.

1. **Target-DB enumeration.** The operator must produce a concrete
   list of SQLite DB paths that carry inert Category C rows and
   are in scope for this forensic cleanup. Candidates to enumerate
   (project-agnostic labels — the operator names the actual paths
   for this lane):
   - the main ClauDEX runtime DB (primary project state),
   - any worktree-local DBs used by active dispatch lanes,
   - any soak / integration / checkpoint DBs retained from
     pre-retirement ClauDEX,
   - any backup / snapshot DBs used by operational recovery paths.
   Each entry MUST record: absolute path, ClauDEX version that
   last wrote to it, whether it is read-only / archival / live,
   and whether it is in scope for Sub-slice 1, Sub-slice 2, both,
   or excluded. DB paths that are **excluded** must be named
   explicitly with the reason, not silently omitted.

2. **Per-target forensic snapshots before any `DROP TABLE`.** For
   every in-scope DB identified in step 1, the operator must
   capture a forensic snapshot prior to the migration run:
   - a byte-for-byte copy of the DB file to a dated, read-only
     snapshot location (e.g. `backups/category-c-forensic/<date>/<db-basename>`),
   - a per-table row-count export (`SELECT COUNT(*) FROM
     proof_state`, `dispatch_queue`, `dispatch_cycles`) recorded in
     the slice's artifact trail,
   - optionally a per-table row dump if the operator's audit
     posture requires content retention.
   The execution slice MUST NOT dispatch its `DROP TABLE` run on
   any target DB for which a snapshot has not been captured and
   verified readable.

3. **Approval checkpoint per Sacred Practice #8.** Because
   `DROP TABLE IF EXISTS` is an irreversible, destructive
   operation, an explicit user-approval token is required before
   each target-DB run. The approval record MUST name:
   - the exact DB path being targeted,
   - the sub-slice being executed (Sub-slice 1 or Sub-slice 2),
   - the snapshot path from step 2 that precedes it,
   - the authorising Codex instruction ID.
   Approval granted for one target-DB does not transitively
   authorise other target-DBs — each in-scope DB from step 1
   consumes its own approval token. Approvals are recorded in the
   runtime approval surface (`cc-policy approval grant`) or the
   lane's equivalent audited path.

If any of steps 1-3 is not complete, the execution slice MUST
return **blocked (missing prerequisite)** and not proceed.

## Required invariant / test gates for any future implementation slice

If (and only if) a subsequent instruction authorizes execution of
either sub-slice, the implementer must produce:

```bash
pytest -q tests/runtime/test_phase8_category_c_proof_retired.py
pytest -q tests/runtime/test_phase8_category_c_dispatch_retired.py
pytest -q tests/runtime/test_authority_table_writers.py
pytest -q tests/runtime/test_phase8_deletions.py
python3 runtime/cli.py constitution validate      # concrete_count=25, unchanged from dispatch-time snapshot
python3 runtime/cli.py hook validate-settings     # entry_count=31, unchanged from dispatch-time snapshot
python3 runtime/cli.py hook doc-check             # exact_match=true, unchanged from dispatch-time snapshot
```

**Stability note for gate numbers:** the `25` / `31` values above reflect the live registry at packet-reconciliation time (post-`cc-policy-who-remediation` + post-merge hardening, lane HEAD `566e2d7`). An execution slice must re-snapshot `concrete_count` / `entry_count` at its own dispatch start and use that snapshot — not these literals — as the "unchanged" baseline. Treat only post-dispatch movement as a halt condition per Escalation boundaries §3.

Plus, for a migration run:

```bash
sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='proof_state'"
# → empty after Sub-slice 1
sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('dispatch_queue','dispatch_cycles')"
# → empty after Sub-slice 2
```

## Time-scoping note

The two code-surface retirements (`f72e656`, `369cca6`) are
historical checkpoint facts — they were part of the Integration
Wave 1 landing and fast-forwarded onto `feat/claudex-cutover` at
`018f2fa`.  References in this packet to those SHAs are snapshot
identifiers, not live `git status` output.  Live custody HEAD at
the time of this packet's commit is `f37b8ab`.  The "retired" /
"fully closed" language throughout this packet refers to the
code-surface retirement landed in 2026-04-17, not to any claim
about inert table data on operator databases today.

## Included vs excluded scope — final

**Included in this packet (this commit):**

- `ClauDEX/CATEGORY_C_SCOPING_PACKET_2026-04-17.md` (this file)
- `ClauDEX/CURRENT_STATE.md` — one-entry "next bounded cutover
  slice" update pointing here, explicitly planning-only.
- `ClauDEX/SUPERVISOR_HANDOFF.md` — matching one-paragraph handoff
  entry.
- `ClauDEX/PHASE8_DELETION_INVENTORY.md` — historical Category C
  section clarified to point at this packet as the authoritative
  scoping artifact for the remaining inert-row finalization;
  "fully closed" language preserved for the code surface while
  the inert-row posture is explicitly called out as the deferred
  piece this packet scopes.

**Explicitly excluded — not in this commit and not in any future
execution slice until authorized:**

- Any `runtime/` / `hooks/` / `scripts/` / `settings.json` edit.
- Any schema change.
- Any `DROP TABLE` execution.
- Any new CLI subcommand.
- Any authority-writer allowlist extension.
- Any Phase 9 creation or phase-related restructuring.

## Decision annotation (for any future implementation slice)

```
@decision DEC-CATEGORY-C-FORENSIC-001
@title Optional forensic cleanup of retired Category C inert tables
@status planning
@rationale The code surfaces for proof_state (f72e656) and
  dispatch_queue/dispatch_cycles (369cca6) were retired under a
  non-destructive posture that left inert rows on pre-retirement
  databases.  This decision reserves the ID for a future forensic
  sub-slice that would issue one-shot DROP TABLE IF EXISTS against
  the named tables, guarded by explicit operator consent.  The
  decision remains 'planning' until a supervisor instruction
  authorizes execution.  Post-Phase-8 continuation; no new phase.
```

## Planning artifact invariant

Future revisions (if supervisor redirects) should supersede this
file by a newer dated `CATEGORY_C_SCOPING_PACKET_YYYY-MM-DD.md`
rather than editing this file in place, preserving the scoping
record.  `PHASE8_DELETION_INVENTORY.md` remains the historical
audit; this packet is the active planning artifact.
