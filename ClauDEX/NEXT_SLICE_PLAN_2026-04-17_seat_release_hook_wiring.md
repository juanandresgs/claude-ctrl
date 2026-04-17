# Next Implementation Slice — Wire `dispatch seat-release` into SubagentStop adapters

**Status:** planning-only (no runtime/hook behavior change in this slice).
**Created:** 2026-04-17 post-seat-release-foundation (custody tip `472d94b`).
**Authorizing instruction:** `1776453443957-0008-26ui8q`.

## Why this is the next slice

The runtime already owns an authoritative seat-teardown path via
`runtime.core.dispatch_hook.release_session_seat(conn, session_id,
agent_type)` (landed at `472d94b`). It transitions `seats.status` to
`released` and cascades `supervision_threads.abandon_for_seat()` in a
single call, exposed as `cc-policy dispatch seat-release`.

Today no hook ever calls that path. SubagentStop adapters
(`hooks/check-{implementer,reviewer,guardian,planner}.sh`) currently
stop at `lifecycle on-stop` for marker deactivation and `completion
submit` for stage verdicts; the seat row itself stays `active` forever,
and active supervision_threads touching the departing seat are never
closed until something else abandons them. That leaves a gap the
CUTOVER_PLAN §2a supervision fabric expects the runtime to close.

This slice prepares — but does not yet perform — the minimal hook
wiring that closes that gap.

## Objective

Wire each of the four SubagentStop adapters to call
`cc-policy dispatch seat-release` best-effort immediately after the
existing `lifecycle on-stop` line, so a seat's release and its
supervision_thread closure happen at the same moment the marker is
deactivated.

**Non-objective:** no new supervision behavior, no new policy, no new
schema, no new phase. This is pure adapter plumbing over a runtime
helper that already exists.

## In-scope files / modules (first implementation slice)

| Path | Status | Role |
|---|---|---|
| `hooks/check-implementer.sh` | **MODIFIED** | Extract `SESSION_ID` from the SubagentStop payload with the established `jq -r '.session_id // empty'` pattern. After the existing `_local_cc_policy lifecycle on-stop` line, add one best-effort call: `_local_cc_policy dispatch seat-release --session-id "$SESSION_ID" --agent-type "$AGENT_TYPE" >/dev/null 2>&1 \|\| true`. Guard on `[[ -n "$SESSION_ID" && -n "$AGENT_TYPE" ]]` so malformed payloads are a no-op. |
| `hooks/check-reviewer.sh` | **MODIFIED** | Same pattern as check-implementer.sh. |
| `hooks/check-guardian.sh` | **MODIFIED** | Same pattern as check-implementer.sh. |
| `hooks/check-planner.sh` | **MODIFIED** | Same pattern as check-implementer.sh. |
| `tests/runtime/test_dispatch_hook.py` | **MODIFIED (tiny)** | Add one or two invariant pins that the seat-release call pattern survives hook-level simulation (see §Test strategy). |
| `tests/runtime/test_hook_config.py` | **MODIFIED (optional)** | If the existing hook-config invariant suite exposes a per-adapter contract list, add `dispatch seat-release` as an expected call for each SubagentStop check hook; otherwise skip. |

Estimated diff: ≤4 lines added per check hook × 4 hooks = ≤16 shell
lines, plus 1–2 test pins. No deletions, no refactors.

### Call pattern (canonical, identical across all four hooks)

Insert immediately after the existing `lifecycle on-stop` block (the
guarded `if [[ -n "$AGENT_TYPE" ]]; then … fi`):

```bash
# Release the seat and abandon every active supervision_thread touching it.
# DEC-SUPERVISION-THREADS-DOMAIN-001 continuation. Best-effort — seat-release
# failures must never block the hook. release_session_seat() is idempotent
# (repeat calls return released=false, abandoned_count=0) so retries on
# unexpected interrupts are safe.
SESSION_ID=$(printf '%s' "$AGENT_RESPONSE" | jq -r '.session_id // empty' 2>/dev/null || echo "")
if [[ -n "$SESSION_ID" && -n "$AGENT_TYPE" ]]; then
    _local_cc_policy dispatch seat-release \
        --session-id "$SESSION_ID" \
        --agent-type "$AGENT_TYPE" >/dev/null 2>&1 || true
fi
```

Why this exact shape:

- `AGENT_RESPONSE` is already captured by every check hook at the top,
  so no second `read_input` call is needed.
- The `jq -r '.session_id // empty'` form is the same one used by
  `hooks/subagent-start.sh:22` and `hooks/pre-agent.sh:98`, so the
  extraction is identical to the existing runtime-owned path that
  *creates* the seat. Same convention on both ends of the lifecycle.
- `_local_cc_policy` is the local-runtime CLI wrapper every check hook
  already defines; nothing new is imported.
- `>/dev/null 2>&1 || true` matches the existing `lifecycle on-stop`
  pattern — hook-side best-effort, failures silent.

## Out-of-scope files / modules (explicit)

- **`settings.json` / `HOOK_MANIFEST`** — SubagentStop wiring is
  already correct; this slice adds one line inside the already-wired
  adapters, not a new adapter file or matcher. `cc-policy hook
  validate-settings` must stay green and unchanged.
- **`hooks/HOOKS.md`** — the doc generator is event-and-adapter scoped,
  not call-tree scoped. Adding one cc-policy invocation inside an
  existing adapter does not change the document. `cc-policy hook
  doc-check` must stay `exact_match=true`.
- **`runtime/core/dispatch_hook.py`** — `release_session_seat()` is
  already landed at `472d94b`. No change here.
- **`runtime/core/supervision_threads.py`** — no change.
- **`runtime/cli.py`** — no change; `dispatch seat-release` subparser is
  already landed.
- **All bridge-transport files** (`scripts/claudex-*.sh`,
  `hooks/claudex-*.sh`, `tests/runtime/test_claudex_*.py`,
  `ClauDEX/OVERNIGHT_RUNBOOK.md`): unchanged. Bridge stays containment
  per supervisor handoff discipline.
- **No new CLAUDE.md or SUPERVISOR_HANDOFF.md edit** — the hook wiring
  is too small to warrant a governance-doc touch. Once landed, the slice
  after the wiring may include a one-line mention in
  `CURRENT_STATE.md` (not this slice).

## Test strategy (for the implementation slice)

Runtime correctness is already covered (80 tests pass on `472d94b`
including the 7 `release_session_seat` tests and 2 CLI round-trips).
The implementation slice adds coverage for the *hook-level* linkage
only, without re-testing the runtime helper itself.

### Deterministic hook-level checks already in the repo

1. **Shell-level simulation** — the repo's existing hook tests drive
   the check hooks by piping a synthetic SubagentStop payload through
   the script and asserting on side effects. Add a focused check for
   each of the four hooks:
   - Feed a synthetic payload with `session_id="sess-hook-slicetest"`
     and `agent_type="implementer"` (rotate per hook).
   - Pre-seed a matching seat via `ensure_session_and_seat()` in the
     test DB.
   - Run the hook with `CLAUDE_POLICY_DB` pointing at the test DB.
   - Assert that `seats.status` for the seeded seat transitioned to
     `"released"`.
   - Assert that any pre-seeded active `supervision_threads` row
     touching that seat flipped to `"abandoned"`.
   - Pin idempotency: run the same hook payload twice; the second run
     must leave the DB unchanged.
2. **Payload-shape fallback** — if the existing hook harness does not
   support this form of invocation, fall back to a narrower invariant:
   parse the check hook source and assert the canonical call pattern
   appears exactly once, immediately after the `lifecycle on-stop`
   block, with both `--session-id` and `--agent-type` arguments. This
   pin prevents silent drift of the call pattern across hooks.

### Runtime-test additions

- `tests/runtime/test_dispatch_hook.py` (existing): no new runtime
  logic to exercise — `release_session_seat()` is already covered. Add
  at most one pin that the CLI help output for `dispatch seat-release`
  still advertises the exact argument names the hooks use
  (`--session-id`, `--agent-type`), so a rename in either place breaks
  the test instead of silently desyncing.

### What is explicitly NOT tested in this slice

- Any integration against the real Claude Code harness SubagentStop
  event. The synthetic-payload simulation is authoritative for this
  slice; live-harness verification lives in a later slice once SOAK
  signals are needed.
- Bridge-transport flows. Bridge stays containment.

## Required evidence (implementation slice)

```bash
pytest -q tests/runtime/test_dispatch_hook.py
pytest -q tests/runtime/test_supervision_threads.py
pytest -q tests/runtime/test_hook_config.py
python3 runtime/cli.py dispatch seat-release --help
python3 runtime/cli.py constitution validate
python3 runtime/cli.py hook validate-settings
python3 runtime/cli.py hook doc-check
python3 runtime/cli.py doc ref-check CLAUDE.md   # must remain healthy=true, refs=0
```

All three hook-validation CLIs must remain **unchanged** from the
current `472d94b` output:

- `hook validate-settings` → `healthy=true`, `settings_repo_entry_count=30`
- `hook doc-check` → `exact_match=true`
- `constitution validate` → `concrete_count=24`

If any of those numbers move, the slice has drifted outside planned
scope and must stop for supervisor review.

## Explicit stop / escalation boundaries

Halt implementation and escalate to the Codex supervisor if any of
these surface:

1. **Payload field missing.** If the SubagentStop payload does not
   reliably carry `session_id` in practice (empirical check via
   `runtime/dispatch-debug.jsonl`), stop. The plan's premise is that
   both `session_id` and `agent_type` are already available at
   SubagentStop time; if only one is, the helper cannot be called
   safely and the wiring design needs revisiting.
2. **Hook-doc drift.** If `cc-policy hook doc-check` flips to
   `exact_match=false`, stop. The HOOK_MANIFEST generator's projection
   must not change for a one-line call addition; drift there indicates
   an unintended authority-surface touch.
3. **`hook validate-settings` count change.** Any change in
   `settings_repo_entry_count` or `manifest_wired_entry_count` means
   the slice accidentally added or removed an adapter entry; stop.
4. **Cascade failure inside `release_session_seat`.** If simulation
   surfaces an uncaught exception (e.g. the late import of
   `supervision_threads` fails under a real hook env), stop; the
   helper needs hardening first rather than wrapping the failure in
   `|| true`.
5. **Cross-adapter divergence.** If the call pattern ends up different
   across the four check hooks (typo, forgotten guard), stop. Every
   SubagentStop adapter must carry the *same* pattern verbatim so
   behavior is uniform across roles.
6. **`bash_write_who` / `write_plan_guard` denial.** If capability
   gates deny the hook edits for reasons beyond routine WHO
   enforcement, stop. Don't paper over the denial; route to the owning
   authority.

## Rollback boundary

The implementation slice is a shell-script-only edit inside already
existing adapters — a `git revert` of the slice commit cleanly reverts
to `472d94b` behavior. No schema migration, no CLI contract change, no
HOOK_MANIFEST edit. The seat-release runtime helper remains available
for any other caller regardless of whether the wiring lands.

## Bridge transport containment statement

Bridge transport work (`scripts/claudex-*.sh`, `hooks/claudex-*.sh`,
`tests/runtime/test_claudex_*.py`, `ClauDEX/OVERNIGHT_RUNBOOK.md`,
`ClauDEX/SOAK_REMEDIATION_READINESS_*.md`) remains out-of-scope
containment. This slice and its implementation successor operate
entirely on runtime-owned SubagentStop adapters
(`hooks/check-*.sh`) and runtime tests (`tests/runtime/`).

## Included vs excluded scope — final

**Included in this planning artifact only (this commit):**

- `ClauDEX/NEXT_SLICE_PLAN_2026-04-17_seat_release_hook_wiring.md`
  (this file)

**Intended for the next implementation slice (NOT in this commit):**

- `hooks/check-implementer.sh` (≤4 added lines + 1 session_id capture)
- `hooks/check-reviewer.sh` (same pattern)
- `hooks/check-guardian.sh` (same pattern)
- `hooks/check-planner.sh` (same pattern)
- `tests/runtime/test_dispatch_hook.py` (tiny invariant pin on CLI help)
- Optional: `tests/runtime/test_hook_config.py` or an equivalent
  hook-level simulation test, only if the repo's existing harness
  supports it without new scaffolding.

**Explicitly excluded:**

- Bridge transport stack (entirely).
- `settings.json`, `HOOK_MANIFEST`, `hooks/HOOKS.md`.
- Schema changes.
- New runtime helpers or CLI subcommands.
- Other supervision primitives or transport adapters.
- New phase creation.
- Broad docs rewrites. `CURRENT_STATE.md` / `SUPERVISOR_HANDOFF.md` /
  `CLAUDE.md` / `CUTOVER_PLAN.md` are not touched by this plan or by
  the implementation slice.

## Decision annotation (for the implementation slice's commit)

```
@decision DEC-SUPERVISION-THREADS-DOMAIN-001
@title SubagentStop adapters wire cc-policy dispatch seat-release
@status accepted
@rationale The runtime's seat-release path (landed at 472d94b) is only
  reachable if a caller invokes it. This slice wires each of the four
  SubagentStop check hooks to call cc-policy dispatch seat-release
  best-effort, so seat teardown and supervision_thread closure happen
  at the same moment the marker is deactivated. No schema change, no
  HOOK_MANIFEST edit, no new phase — pure adapter plumbing over an
  existing helper.
```

## Planning artifact invariant

Future revisions of this planning artifact (if Codex supervisor
redirects to a different next slice) should supersede this file by a
newer dated `NEXT_SLICE_PLAN_YYYY-MM-DD_*.md` rather than editing this
file in place. That preserves the planning record and lets `git log`
show the slice-selection history.
