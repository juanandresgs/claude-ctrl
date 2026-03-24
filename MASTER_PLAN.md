# MASTER_PLAN.md

Status: active
Created: 2026-03-23
Last updated: 2026-03-24 (INIT-002 closed; INIT-003 wave detail added)

## Identity

This repository is the hard-fork successor to `claude-config-pro`. It is being
built from the patched `v2.0` kernel outward so the governance layer remains
smaller, more legible, and more mechanically trustworthy than the work it
governs.

## Architecture

- Canonical judgment lives in [CLAUDE.md](CLAUDE.md) and [agents/](agents).
- The live hook kernel is in [hooks/](hooks) with
  [settings.json](settings.json). INIT-002 consolidated the Write|Edit chain
  into `pre-write.sh` and the Bash chain into `pre-bash.sh`; policy logic lives
  in [hooks/lib/](hooks/lib).
- Shared workflow state is owned by the SQLite-backed runtime in
  [runtime/](runtime), reached through
  [hooks/lib/runtime-bridge.sh](hooks/lib/runtime-bridge.sh). The `cc-policy`
  CLI is the sole write interface; shell hooks call it via bridge wrappers.
  Flat-file authorities (`.proof-status-*`, `.subagent-tracker`,
  `.statusline-cache`, `.audit-log`, `.agent-findings`) have been deleted.
- The statusline HUD reads from `cc-policy statusline snapshot` -- a runtime
  projection, not a separate authority.
- Dispatch emission flows through `post-task.sh` into the `dispatch_queue` and
  `dispatch_cycles` tables. Queue enforcement is not yet live (INIT-003 scope).
- The remaining hard gap is plan discipline: permanent-section immutability,
  append-only decision log, and initiative compression are prompt conventions,
  not mechanically enforced.
- The target architecture is modular: thin hooks, typed runtime, read-only
  sidecars, and strict plan discipline.
- No second live control path is allowed during migration. Replacements must cut
  over fully and delete the superseded mechanism.

## Original Intent

Bootstrap a new control-plane fork that preserves the stable determinism of
`v2.0`, carries forward the essential safety and proof fixes, selectively
rebuilds only the genuinely valuable ideas from later versions, and reaches a
full successor spec without dragging `claude-config-pro` complexity wholesale
into the new mainline.

## Principles

1. Start from the working kernel, not from the most complex branch.
2. Prompts shape judgment; hooks enforce local policy; runtime owns shared
   state.
3. Every claimed invariant must be backed by a gate, a state check, or a
   scenario test on the installed Claude runtime.
4. Port proven enforcement from history when it worked; simplify the
   implementation instead of deleting the control property.
5. Delete what you replace. Do not keep fallback authorities alive.
6. Preserve readable ownership boundaries between prompts, hooks, runtime, and
   sidecars.
7. The successor runtime must eliminate flat-file and breadcrumb coordination
   for workflow state; evidence files may exist, but they are never authority.
8. Docs must not claim protection that the running system cannot actually
   enforce.
9. Upstream is a donor, not the mainline.

## Decision Log

- `2026-03-23 — DEC-FORK-001` Bootstrap the successor from the patched `v2.0`
  kernel rather than from `claude-config-pro` `main`.
- `2026-03-23 — DEC-FORK-002` Preserve the canonical prompt rewrite already
  drafted in this repository and layer the kernel beneath it.
- `2026-03-23 — DEC-FORK-003` Initialize the hard fork as a standalone
  repository with its own history and treat upstream only as an import source.
- `2026-03-23 — DEC-FORK-004` Keep the patched `v2.0` bootstrap kernel as the
  sole live authority until each successor replacement hook is proven in
  scenarios and cuts over completely.
- `2026-03-23 — DEC-FORK-005` Port write-side dispatch enforcement from the
  later line into the successor core before broader runtime work; missing WHO
  enforcement on `Write|Edit` is the most important current control gap.
- `2026-03-23 — DEC-FORK-006` Treat the current Claude runtime contract as a
  compatibility surface that must be revalidated now; historical assumptions
  about `Task`, `Agent`, `SubagentStart`, and `SubagentStop` are not trusted
  until proven on the installed version.
- `2026-03-23 — DEC-FORK-007` The typed runtime becomes the sole authority for
  shared workflow state; flat files, breadcrumbs, and session-local marker files
  are not permitted as coordination mechanisms in the successor state machine.
- `2026-03-23 — DEC-FORK-008` No documentation may claim a control guarantee
  unless a scenario test proves it against the installed Claude version.
- `2026-03-23 — DEC-FORK-009` Reimplement the richer statusline HUD from the
  later line as a runtime-backed read model. Rendering belongs in
  `scripts/statusline.sh`; state derivation belongs in the successor runtime.
- `2026-03-23 — DEC-FORK-013` Trace artifacts remain evidence and recovery
  material only. No successor control decision may depend on a trace file,
  breadcrumb, or cache file being present.
- `2026-03-23 — DEC-FORK-010` Wave 1 Write|Edit WHO enforcement will be
  implemented by adding role checks to the existing `PreToolUse` (Write|Edit)
  hook chain rather than creating a new hook entrypoint, because the existing
  chain already fires on every Write|Edit call and adding a new file to that
  chain is lower-risk than restructuring the hook wiring in settings.json.
- `2026-03-23 — DEC-FORK-011` TKT-001 runtime payload capture will use
  instrumented wrapper scripts that log raw hook input JSON to a capture
  directory, not modifications to production hooks, so the capture is
  removable without merge risk.
- `2026-03-23 — DEC-FORK-012` The smoke suite (TKT-002) will be shell-based
  scenario tests in `tests/scenarios/` that invoke hook scripts with synthetic
  JSON payloads on stdin, validating output JSON for deny/allow/context
  decisions. This avoids requiring a live Claude runtime for CI.
- `2026-03-24 — DEC-FORK-015` INIT-002 closed. The runtime MVP and thin hook
  cutover are live. Flat-file shared-state authorities have been deleted. The
  dispatch queue exists but is not yet enforced as the sole dispatch path --
  enforcement moves to INIT-003 after the queue proves stable through use.

## Active Initiatives

### INIT-003: Plan Discipline and Successor Validation

- **Status:** in-progress
- **Goal:** Finish the successor kernel so its plan discipline, verification, and
  release claims are mechanically trustworthy.
- **Current truth:** [scripts/planctl.py](scripts/planctl.py) only validates
  section presence and stamps a placeholder timestamp;
  [hooks/plan-validate.sh](hooks/plan-validate.sh) runs inline structural
  checks (phase status fields, decision-log presence, decision ID format) but
  does not enforce immutability. `MASTER_PLAN.md` discipline is still largely
  social rather than enforced. The enforcement gaps are documented in
  [docs/PLAN_DISCIPLINE.md](docs/PLAN_DISCIPLINE.md) under "Not Yet Enforced."
- **Scope:** plan immutability, decision-log closure rules, initiative
  compression, trace-lite manifests, kernel acceptance suite, shadow-mode
  sidecars, and readiness for daemon promotion.
- **Exit:** Permanent-section replacement is mechanically blocked, the kernel
  acceptance suite passes twice consecutively, and sidecars remain read-only
  until the kernel is stable.
- **Dependencies:** INIT-001, INIT-002
- **Implementation tickets:**
- `TKT-010` Expand [scripts/planctl.py](scripts/planctl.py) into real plan
  discipline enforcement: section immutability, append-only decision-log,
  `Last updated` timestamp management, and initiative compression.
- `TKT-013` Implement trace-lite manifests and session summary emission via
  [hooks/lib/trace-lite.sh](hooks/lib/trace-lite.sh) and a `cc-policy trace`
  domain.
- `TKT-014` Complete the full kernel acceptance suite in `tests/scenarios/`
  covering all enforcement surfaces end-to-end.
- `TKT-015` Reintroduce search and observatory as read-only shadow sidecars
  under `sidecars/`.
- **Post-ticket continuation:** Promote `cc-policy` to daemon mode after CLI
  mode proves stable through two consecutive green acceptance suite runs.

#### Scaffold Assessment (2026-03-24)

Current state of the files TKT-010 touches:

- **`scripts/planctl.py`** -- 67 lines. Two commands: `validate` (checks
  section-header presence against a hardcoded list of 8 required headers)
  and `stamp` (replaces `Last updated:` line with `st_mtime_ns` value).
  Neither command enforces content stability. No diffing, no hashing, no
  awareness of decision-log entries or initiative state.
- **`hooks/plan-validate.sh`** -- 115-line PostToolUse hook that fires on
  Write|Edit to `MASTER_PLAN.md`. Validates: phase Status fields
  (`planned`/`in-progress`/`completed`), completed phases have non-empty
  Decision Log subsections, Original Intent section exists, Decision IDs
  follow `DEC-COMPONENT-NNN` format. Exits 2 (feedback loop) on failure.
  Inline implementation -- does not call `planctl.py`.
- **`hooks/plan-guard.sh`** -- WHO enforcement only. Blocks non-planner
  writes to governance markdown. Allows `CLAUDE_PLAN_MIGRATION=1` override.
  Does not validate content.
- **`hooks/plan-check.sh`** -- Plan existence + staleness gate. Fires on
  source Write|Edit. Does not validate plan content.
- **`hooks/lib/plan-policy.sh`** -- Placeholder (2 lines, no logic).

#### Wave 3 Execution Detail

**Sequencing:** TKT-010 first (the plan discipline tool that all other
tickets depend on for stable plan tracking), then TKT-013 (trace-lite
needs a stable plan to reference session manifests against), then TKT-014
(acceptance suite must exercise the enforcement surfaces built by TKT-010
and TKT-013), then TKT-015 last (sidecars are consumers, not producers;
they depend on the acceptance suite proving the kernel stable).

**Critical path:** TKT-010 -> TKT-014 -> TKT-015 -> (done). Max width: 1
(each ticket depends on the prior for either enforcement tooling or
stability evidence). TKT-013 can run in parallel with TKT-014 since it
provides trace data that the acceptance suite consumes but does not gate
the suite itself.

```
Wave 3a: TKT-010  (foundation -- planctl.py enforcement + plan-validate consolidation)
Wave 3b: TKT-013  (trace-lite manifests and session summaries)
Wave 3c: TKT-014  (kernel acceptance suite -- exercises all enforcement surfaces)
Wave 3d: TKT-015  (shadow sidecars -- read-only consumers of runtime + trace data)
```

##### TKT-010: Plan Discipline Enforcement in planctl.py

- **Weight:** L
- **Gate:** approve (user must approve the immutability and compression
  rules before they become hard blocks)
- **Deps:** INIT-002 complete (runtime must be live for event emission)
- **Implementer scope:**
  - Expand `scripts/planctl.py` from 67 lines to a real enforcement tool
    with these commands:
    - `validate <path>` -- existing section-presence check, PLUS:
      - Verify `Last updated:` line exists and contains a valid ISO date.
      - Verify Decision Log entries follow `YYYY-MM-DD -- DEC-XXX-NNN`
        format.
      - Verify each Active Initiative has Status, Goal, Scope, Exit,
        Dependencies fields.
      - Verify Completed Initiatives have a `(completed YYYY-MM-DD)`
        date suffix in the header.
    - `check-immutability <path> <baseline-hash-file>` -- NEW command:
      - Extract permanent sections: Identity, Architecture, Original
        Intent, Principles, and each existing Decision Log row.
      - Hash each section's content (SHA-256 of stripped text).
      - Compare against the baseline hash file (JSON map of section
        name to hash).
      - Report any changed permanent sections as violations.
      - On first run (no baseline exists), create the baseline file
        without error.
      - Baseline file location: `.plan-baseline.json` in project root.
    - `check-decision-log <path> <baseline-hash-file>` -- NEW command:
      - Parse all `YYYY-MM-DD -- DEC-XXX-NNN` entries from the
        Decision Log.
      - Compare against the baseline's decision entry list.
      - Verify append-only: every entry in the baseline must still
        exist in the current file with identical content.
      - New entries (not in baseline) are allowed and expected.
      - Deleted or modified entries are violations.
    - `check-compression <path>` -- NEW command:
      - Parse Active Initiatives and Completed Initiatives.
      - For Completed Initiatives: verify no Wave execution detail
        remains (no `####` or `#####` subsections). Completed
        initiatives should be compressed to header + summary bullet
        points only.
      - For Active Initiatives: wave detail is allowed and expected.
    - `stamp <path>` -- enhanced:
      - Replace the `Last updated:` line with
        `Last updated: YYYY-MM-DD (<summary>)` using current date.
      - Accept `--summary` argument for the parenthetical.
      - Update `.plan-baseline.json` with current section hashes
        after stamping.
    - `refresh-baseline <path>` -- NEW command:
      - Regenerate `.plan-baseline.json` from current file state.
      - Used after intentional permanent-section edits (with
        `CLAUDE_PLAN_MIGRATION=1`).
  - Consolidate `hooks/plan-validate.sh` inline logic into `planctl.py`:
    - Move the phase-status validation, completed-phase decision-log
      check, original-intent presence check, and decision-ID format
      validation from the shell hook into `planctl.py validate`.
    - Reduce `hooks/plan-validate.sh` to a thin shell wrapper that calls
      `python3 scripts/planctl.py validate "$FILE_PATH"` and translates
      the exit code into hook JSON.
    - This eliminates the dual-implementation where `planctl.py` and
      `plan-validate.sh` both do structural validation with different
      rule sets.
  - Implement `hooks/lib/plan-policy.sh` with:
    - `pp_check_immutability(project_root)` -- calls
      `planctl.py check-immutability` and returns deny JSON if violated.
    - `pp_check_decision_log(project_root)` -- calls
      `planctl.py check-decision-log` and returns deny JSON if violated.
    - `pp_check_compression(project_root)` -- calls
      `planctl.py check-compression` and returns warn JSON if violated
      (advisory, not blocking -- compression is a hygiene convention).
  - Wire immutability check into the write path:
    - Add `pp_check_immutability` call to `hooks/pre-write.sh` (or
      `hooks/lib/write-policy.sh`) for MASTER_PLAN.md writes, AFTER
      the existing WHO check passes. This means a planner can write
      governance markdown but cannot silently overwrite permanent
      sections.
    - The `CLAUDE_PLAN_MIGRATION=1` override must bypass immutability
      checks as well as WHO checks, since permanent-section edits
      during migration are intentional.
  - Add unit tests in `tests/`:
    - `test_planctl_validate.py`: section presence, date format,
      decision-ID format, initiative structure.
    - `test_planctl_immutability.py`: baseline creation, section hash
      comparison, violation detection, new-section tolerance.
    - `test_planctl_decision_log.py`: append-only enforcement, new
      entry acceptance, deletion/modification detection.
    - `test_planctl_compression.py`: completed initiative with wave
      detail flagged, completed initiative with summary only passes.
    - `test_planctl_stamp.py`: date replacement, baseline update,
      summary argument.
  - Add scenario tests in `tests/scenarios/`:
    - `test-plan-immutability-deny.sh`: modify Identity section via
      pre-write.sh, expect deny.
    - `test-plan-immutability-migration.sh`: modify Identity with
      `CLAUDE_PLAN_MIGRATION=1`, expect allow.
    - `test-plan-declog-append-only.sh`: delete a decision entry via
      pre-write.sh, expect deny.
    - `test-plan-validate-thin.sh`: write invalid MASTER_PLAN.md,
      verify plan-validate.sh returns feedback via planctl.py.
- **Tester scope:**
  - Run `python3 -m pytest tests/test_planctl_*.py` and paste output.
  - Run all new scenario tests and paste output.
  - Run all pre-existing scenario tests to confirm no regressions.
  - Manually test: write a valid plan update via pre-write.sh as planner
    role -- should succeed. Attempt to modify Identity section -- should
    deny. Attempt to delete a Decision Log entry -- should deny. Attempt
    both with `CLAUDE_PLAN_MIGRATION=1` -- should allow.
  - Verify `.plan-baseline.json` is created on first `stamp` and updated
    on subsequent `stamp` calls.
  - Verify `hooks/plan-validate.sh` now delegates to `planctl.py` and
    produces identical hook JSON output for all existing test cases.
- **Acceptance criteria:**
  - `scripts/planctl.py` has 5+ commands: `validate`,
    `check-immutability`, `check-decision-log`, `check-compression`,
    `stamp`, `refresh-baseline`.
  - Permanent sections (Identity, Architecture, Original Intent,
    Principles, existing Decision Log rows) are protected by hash-based
    immutability checks on every MASTER_PLAN.md write.
  - Decision Log is append-only: existing entries cannot be deleted or
    modified.
  - `hooks/plan-validate.sh` is a thin wrapper calling `planctl.py`.
  - `hooks/lib/plan-policy.sh` has real policy functions.
  - `.plan-baseline.json` tracks section hashes and decision entries.
  - `CLAUDE_PLAN_MIGRATION=1` bypasses immutability for intentional
    permanent-section migrations.
  - All unit and scenario tests pass.
- **File boundaries:**
  - Modifies: `scripts/planctl.py`, `hooks/plan-validate.sh`,
    `hooks/lib/plan-policy.sh`, `hooks/lib/write-policy.sh` (or
    `hooks/pre-write.sh`)
  - Creates: `.plan-baseline.json` (runtime artifact, gitignored),
    `tests/test_planctl_validate.py`,
    `tests/test_planctl_immutability.py`,
    `tests/test_planctl_decision_log.py`,
    `tests/test_planctl_compression.py`,
    `tests/test_planctl_stamp.py`,
    `tests/scenarios/test-plan-immutability-deny.sh`,
    `tests/scenarios/test-plan-immutability-migration.sh`,
    `tests/scenarios/test-plan-declog-append-only.sh`,
    `tests/scenarios/test-plan-validate-thin.sh`
  - Does NOT modify: `runtime/` (plan discipline is a tool-layer concern,
    not a runtime-state concern), `settings.json` (hook wiring unchanged),
    `agents/`, `CLAUDE.md`

##### TKT-013: Trace-Lite Manifests and Session Summaries

- **Weight:** M
- **Gate:** review (user sees trace manifest and summary output)
- **Deps:** TKT-010 (plan discipline must be enforced so manifests
  reference stable plan state)
- **Implementer scope:**
  - Implement `hooks/lib/trace-lite.sh` with:
    - `tl_emit_manifest(session, workflow, initiative)` -- writes a
      session manifest to the `events` table (type=`trace_manifest`)
      recording: session ID, workflow, active initiative, start epoch,
      files touched, tickets referenced.
    - `tl_emit_summary(session, workflow, outcome)` -- writes a session
      summary to the `events` table (type=`trace_summary`) recording:
      session ID, tickets completed, decisions made, files changed,
      outcome assessment.
  - Add `cc-policy trace manifest` and `cc-policy trace summary` CLI
    commands in `runtime/cli.py` that read/query trace events.
  - Add a `runtime/core/traces.py` domain module with:
    - `emit_manifest(conn, session, workflow, data)`.
    - `emit_summary(conn, session, workflow, data)`.
    - `query_manifests(conn, workflow, limit)`.
    - `query_summaries(conn, session)`.
  - Wire manifest emission into `hooks/session-init.sh` (emit on session
    start) and summary emission into `hooks/post-task.sh` (emit on
    session/agent completion).
  - Add unit tests: `tests/runtime/test_traces.py`.
  - Add scenario tests: `tests/scenarios/test-trace-manifest.sh`,
    `tests/scenarios/test-trace-summary.sh`.
- **Tester scope:**
  - Verify manifest is emitted on session start.
  - Verify summary is emitted on agent completion.
  - Verify `cc-policy trace manifest` returns valid JSON.
  - Verify round-trip: emit then query.
- **Acceptance criteria:**
  - `hooks/lib/trace-lite.sh` has real trace emission functions.
  - `runtime/core/traces.py` has manifest and summary domain logic.
  - Trace events appear in the `events` table with correct types.
  - CLI commands for trace query work.
  - All tests pass.
- **File boundaries:**
  - Modifies: `hooks/lib/trace-lite.sh`, `hooks/session-init.sh`,
    `hooks/post-task.sh`, `runtime/cli.py`
  - Creates: `runtime/core/traces.py`,
    `tests/runtime/test_traces.py`,
    `tests/scenarios/test-trace-manifest.sh`,
    `tests/scenarios/test-trace-summary.sh`
  - Does NOT modify: `scripts/planctl.py`, `settings.json`, `agents/`,
    `docs/`

##### TKT-014: Kernel Acceptance Suite

- **Weight:** M
- **Gate:** approve (user must approve the acceptance criteria list before
  the suite is considered authoritative)
- **Deps:** TKT-010 (plan discipline), TKT-013 (trace-lite)
- **Implementer scope:**
  - Create `tests/scenarios/acceptance/` directory with a master runner
    `run-acceptance.sh` that executes all acceptance tests and produces
    a pass/fail report.
  - Write acceptance tests covering every enforcement surface:
    - **WHO enforcement:** source write by non-implementer denied,
      governance write by non-planner denied, git commit by non-guardian
      denied.
    - **Plan discipline:** permanent-section modification denied,
      decision-log deletion denied, planless source write denied,
      stale-plan write warned/denied.
    - **Runtime state:** proof round-trip through bridge, marker
      round-trip through bridge, dispatch queue lifecycle, statusline
      snapshot produces valid JSON from populated runtime.
    - **Thin hooks:** pre-write.sh covers all write-policy rules,
      pre-bash.sh covers all bash-policy rules, post-task.sh emits
      dispatch entries.
    - **Trace-lite:** session manifest emitted, session summary emitted.
    - **Statusline:** renderer produces valid ANSI with runtime data,
      renderer degrades gracefully without runtime.
  - Each test must be self-contained: set up its own state, run the
    enforcement surface, assert the result, clean up.
  - The suite must produce a machine-readable JSON report at the end:
    `{"passed": N, "failed": N, "skipped": N, "tests": [...]}`.
  - The suite must be runnable with `bash tests/scenarios/acceptance/run-acceptance.sh`
    and return exit 0 only if all tests pass.
- **Tester scope:**
  - Run the full acceptance suite twice consecutively.
  - Verify both runs produce identical pass/fail results.
  - Verify JSON report is valid and matches observed output.
- **Acceptance criteria:**
  - `tests/scenarios/acceptance/run-acceptance.sh` exists and is
    executable.
  - Suite covers all enforcement surfaces listed above.
  - Suite produces machine-readable JSON report.
  - Suite passes twice consecutively (the INIT-003 exit criterion).
- **File boundaries:**
  - Creates: `tests/scenarios/acceptance/run-acceptance.sh`,
    `tests/scenarios/acceptance/test-*.sh` (one per enforcement surface)
  - Does NOT modify: any hook, runtime, script, or config file

##### TKT-015: Shadow Sidecars (Search and Observatory)

- **Weight:** M
- **Gate:** review (user sees sidecar output)
- **Deps:** TKT-014 (acceptance suite must pass -- sidecars depend on
  kernel stability)
- **Implementer scope:**
  - Implement `sidecars/search/` as a read-only consumer:
    - Reads `events` table for session manifests and summaries.
    - Reads trace data to build a searchable index of sessions,
      decisions, and file changes.
    - Exposes a CLI: `python3 sidecars/search/search.py query <term>`.
    - Must not write to any runtime table or hook state.
  - Implement `sidecars/observatory/` as a read-only consumer:
    - Reads runtime state (proof, dispatch, markers, worktrees, events)
      to produce a dashboard-style summary.
    - Exposes a CLI: `python3 sidecars/observatory/observe.py status`.
    - Must not write to any runtime table or hook state.
  - Add smoke tests: `tests/scenarios/test-sidecar-search.sh`,
    `tests/scenarios/test-sidecar-observatory.sh`.
- **Tester scope:**
  - Verify sidecars read but never write runtime state.
  - Verify search returns relevant results for known sessions.
  - Verify observatory produces a readable status summary.
- **Acceptance criteria:**
  - Both sidecars exist and produce useful output.
  - Neither sidecar writes to any runtime table.
  - Smoke tests pass.
- **File boundaries:**
  - Creates: `sidecars/search/search.py`, `sidecars/search/__init__.py`,
    `sidecars/observatory/observe.py`,
    `sidecars/observatory/__init__.py`,
    `tests/scenarios/test-sidecar-search.sh`,
    `tests/scenarios/test-sidecar-observatory.sh`
  - Does NOT modify: `runtime/`, `hooks/`, `scripts/`, `settings.json`,
    `agents/`, `docs/`

#### Wave 3 State Authority Map

| State Domain | Current Authority (post-INIT-002) | Wave 3 Change | Ticket |
|---|---|---|---|
| Plan section immutability | Social convention (planner prompt) | Hash-based enforcement via `planctl.py` + `.plan-baseline.json` | TKT-010 |
| Decision Log append-only | Social convention (planner prompt) | Diff-based enforcement via `planctl.py` | TKT-010 |
| Initiative compression | Social convention (planner prompt) | Advisory check via `planctl.py check-compression` | TKT-010 |
| Plan structural validation | Dual: `planctl.py validate` + `plan-validate.sh` inline | Consolidated into `planctl.py validate` (single authority) | TKT-010 |
| Session trace manifests | **NONE** | `events` table (type=trace_manifest) via `cc-policy trace` | TKT-013 |
| Session trace summaries | **NONE** | `events` table (type=trace_summary) via `cc-policy trace` | TKT-013 |
| Kernel enforcement verification | Manual spot-checking | `tests/scenarios/acceptance/` suite with JSON report | TKT-014 |
| Search index | **NONE** (parked) | Read-only sidecar over `events` table | TKT-015 |
| Observatory dashboard | **NONE** (parked) | Read-only sidecar over runtime state | TKT-015 |

#### Wave 3 Known Risks

1. **Immutability hash brittleness.** If the planner reformats whitespace
   in a permanent section without changing meaning, the hash check will
   flag it as a violation. Mitigation: strip whitespace before hashing.
   If still too brittle, consider normalized-text comparison instead of
   raw hash. The `refresh-baseline` command provides an escape hatch
   when intentional reformatting is approved.
2. **planctl.py becoming too complex.** The tool grows from 2 commands to
   6. Risk of it becoming the kind of bloated tooling this fork exists to
   avoid. Mitigation: keep each command under 50 lines of logic. Use
   composition (each command is a function) not deep inheritance.
3. **plan-validate.sh consolidation regression.** Moving validation logic
   from shell to Python changes the execution path. A subtle behavioral
   difference could cause false-positive blocks on MASTER_PLAN.md writes.
   Mitigation: run all existing plan-guard and plan-validate scenario
   tests against the new code path before declaring TKT-010 complete.
4. **Acceptance suite false confidence.** A suite that tests only happy
   paths gives a green signal that means nothing. Mitigation: TKT-014
   must include negative tests (verify that things that should be blocked
   ARE blocked) as at least 50% of the suite.
5. **Shadow sidecars reading stale data.** Sidecars query the runtime
   database, which is updated by hooks. If a hook crashes before writing,
   the sidecar sees stale state. Mitigation: sidecars must display data
   timestamps and never claim real-time accuracy.

## Completed Initiatives

### INIT-002: Runtime MVP and Thin Hook Cutover (completed 2026-03-24)

- **Goal:** Replace bootstrap shared-state ownership with a real typed runtime
  and small hook entrypoints without reintroducing `claude-config-pro` style
  complexity.
- **Delivered:**
  - `TKT-006`: SQLite runtime schema and real `cc-policy` CLI. 6 tables
    (`proof_state`, `agent_markers`, `events`, `worktrees`, `dispatch_cycles`,
    `dispatch_queue`), all domain modules implemented, 102 unit tests passing,
    42ms median CLI latency.
  - `TKT-007`: Runtime bridge cutover. `hooks/lib/runtime-bridge.sh` provides
    shell wrappers for every runtime domain. `hooks/context-lib.sh` reads
    runtime-first with flat-file fallback removed. Flat-file authorities
    (`.proof-status-*`, `.subagent-tracker`, `.statusline-cache`, `.audit-log`,
    `.agent-findings`) deleted.
  - `TKT-008`: Thin hook entrypoints. `hooks/pre-write.sh` consolidates the
    7-hook Write|Edit chain (branch-guard, write-guard, plan-guard, plan-check,
    test-gate, mock-gate, doc-gate) into a single entrypoint with policy
    delegation to `hooks/lib/write-policy.sh`. `hooks/pre-bash.sh` consolidates
    `guard.sh` into a single entrypoint with policy delegation to
    `hooks/lib/bash-policy.sh`.
  - `TKT-009`: `hooks/post-task.sh` dispatch emission. Detects completing agent
    role, enqueues next-phase dispatch entries into `dispatch_queue`, emits
    events. Wired into `settings.json` SubagentStop hooks. Dispatch queue
    helpers in `hooks/lib/dispatch-helpers.sh`.
  - `TKT-011`: `runtime/core/statusline.py` with `snapshot()` function
    projecting all statusline fields from runtime state. `cc-policy statusline
    snapshot` CLI command producing valid JSON with graceful degradation.
  - `TKT-012`: `scripts/statusline.sh` rebuilt to read from `cc-policy
    statusline snapshot`. All segments sourced from runtime projection. No
    `.statusline-cache` references remain. Graceful fallback when runtime
    unavailable.
  - `settings.json` rewired to consolidated entrypoints.
- **Exit criteria met:** Shared workflow state flows through `cc-policy`. No
  hot-path hook entrypoint owns workflow state directly. Flat-file and
  breadcrumb coordination paths deleted. Statusline reads runtime-backed
  snapshots. Dispatch queue populated but not yet enforced as sole dispatch
  path (enforcement deferred to INIT-003).

### INIT-001: Compatibility and Control Closure (completed 2026-03-24)

- **Goal:** Make the bootstrap truthful, safe, and aligned with the installed
  Claude runtime before deeper successor work.
- **Delivered:**
  - `TKT-001`: Runtime payload capture in `tests/scenarios/capture/` and
    `PAYLOAD_CONTRACT.md` documenting actual hook JSON schemas for all event
    types on the installed Claude runtime.
  - `TKT-002`: 17-test smoke suite (8 baseline + 5 write-guard + 4
    plan-guard) in `tests/scenarios/` with `test-runner.sh` harness. All
    tests pass against real hook scripts with synthetic JSON payloads.
  - `TKT-003`: `hooks/write-guard.sh` enforcing Write|Edit WHO --
    implementer-only source writes, orchestrator/planner/tester/guardian
    denied. Wired into `settings.json` PreToolUse Write|Edit chain.
  - `TKT-004`: `hooks/plan-guard.sh` enforcing governance markdown authority
    -- planner-only writes to MASTER_PLAN.md, CLAUDE.md, agents/*.md,
    docs/*.md. Migration override via `CLAUDE_PLAN_MIGRATION=1`.
  - `TKT-005`: `docs/DISPATCH.md`, `docs/ARCHITECTURE.md`,
    `docs/PLAN_DISCIPLINE.md` corrected to match actual enforcement surface.
    No doc claims protection that the hook chain cannot deliver.
- **Exit criteria met:** Orchestrator cannot write governed source or
  governance markdown directly. Agent lifecycle is scenario-tested. Dispatch
  docs match real behavior.

### Pre-INIT-001 (repository bootstrap)

- Standalone hard-fork repository bootstrapped from the patched `v2.0` kernel.
- Canonical prompt set drafted in `CLAUDE.md` and `agents/`.
- Successor implementation spec written in `implementation_plan.md`.
- Successor runtime, hook-lib, sidecar, and docs directories scaffolded so work
  can land against stable paths.

## Parked Issues

- Search and observatory sidecars remain parked from hot-path authority until
  the kernel acceptance suite is green twice consecutively.
- Daemon promotion and multi-client coordination stay parked until CLI mode is a
  proven stable interface.
- Upstream synchronization remains manual and selective; no merge/rebase flow
  from upstream is allowed into this mainline.
- Plugin ecosystems, auxiliary agent ecosystems, and non-core experiments remain
  out of scope until the kernel and runtime authority are stable.
