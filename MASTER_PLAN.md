# MASTER_PLAN.md

Status: active
Created: 2026-03-23
Last updated: 2026-03-27 (INIT-004 TKT-024 final revision — check-implementer added, proof writes enumerated, statusline tightened)

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
  `.statusline-cache`, `.audit-log`) have been eliminated from hot paths.
  `.agent-findings` remains active (written by check-guardian.sh, read by
  prompt-submit.sh and compact-preserve.sh).
- The statusline HUD reads from `cc-policy statusline snapshot` -- a runtime
  projection, not a separate authority.
- Dispatch emission flows through `post-task.sh` into the `dispatch_queue` and
  `dispatch_cycles` tables. Queue enforcement is not yet live (INIT-003 scope).
- INIT-004 added `workflow_bindings` and `workflow_scope` tables to the runtime
  schema. Guard.sh Check 12 denies commit/merge without a bound workflow and
  scope manifest. The orchestrator writes scope to runtime before implementer
  dispatch; hooks enforce it mechanically.
- Guard.sh Checks 3-12 use broadened grep patterns (`\bgit\b.*\bcommit\b`)
  that handle both `git commit` and `git -C /path commit` command forms.
- Proof-of-work reads (guard.sh Check 10) are runtime-only. Flat-file proof
  helpers in context-lib.sh are deprecated with zero live callers.
- Prompt files (CLAUDE.md, agents/*.md) use evaluator-based readiness semantics,
  Evaluation Contract and Scope Manifest conventions, and structured output
  trailers (IMPL_STATUS, EVAL_VERDICT).
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

### Hook-layer decisions

- `2026-03-24 — DEC-FORK-014` Planner-only governance markdown writes.
- `2026-03-24 — DEC-HOOK-001` Thin policy delegation to existing hooks.
- `2026-03-24 — DEC-HOOK-002` Thin bash policy delegation.
- `2026-03-24 — DEC-HOOK-003` Consolidated Write|Edit entrypoint.
- `2026-03-24 — DEC-HOOK-004` Consolidated Bash entrypoint.
- `2026-03-24 — DEC-BRIDGE-001` Shell wrappers isolate hook scripts from
  cc_policy JSON parsing.
- `2026-03-24 — DEC-CTX-001` Dual-write migration: runtime primary, flat-file
  fallback.
- `2026-03-24 — DEC-CACHE-001` Statusline cache for status bar enrichment.
- `2026-03-24 — DEC-SUBAGENT-001` Subagent lifecycle tracking via state file.
- `2026-03-24 — DEC-COMPACT-001` Smart compaction suggestions based on prompts
  and session duration.
- `2026-03-24 — DEC-AUTOREVIEW-001` Three-tier command classification with
  recursive analysis.
- `2026-03-24 — DEC-MOCK-001` Escalating mock detection gate.

### Dispatch decisions

- `2026-03-24 — DEC-DISPATCH-001` Shell wrappers for dispatch queue operations.
- `2026-03-24 — DEC-DISPATCH-002` Test canonical flow suggestions from
  post-task.sh.
- `2026-03-24 — DEC-DISPATCH-003` Test dispatch queue FIFO ordering and
  lifecycle transitions.

### Runtime decisions

- `2026-03-24 — DEC-RT-001` Canonical SQLite schema for all shared workflow
  state.
- `2026-03-24 — DEC-RT-011` Statusline snapshot is a read-only projection
  across all runtime tables.

### Plan discipline decisions

- `2026-03-24 — DEC-PLAN-001` planctl.py as the single enforcement authority
  for MASTER_PLAN.md discipline.
- `2026-03-24 — DEC-PLAN-002` plan-policy.sh as thin shell bridge to
  planctl.py.

### Trace decisions

- `2026-03-24 — DEC-TRACE-001` Trace-lite uses dedicated tables, not the events
  table.

### Sidecar decisions

- `2026-03-24 — DEC-SIDECAR-001` Sidecars are read-only consumers of the
  canonical SQLite runtime.
- `2026-03-24 — DEC-SIDECAR-002` Observatory receives a pre-opened connection,
  not a db path.
- `2026-03-24 — DEC-SIDECAR-003` SearchIndex loads traces and manifest entries
  into memory.

### Statusline decisions

- `2026-03-24 — DEC-SL-001` Runtime-backed statusline renderer.

### Capture infrastructure decisions

- `2026-03-24 — DEC-CAP-001` Capture wrapper: passthrough with payload logging.
- `2026-03-24 — DEC-CAP-002` Capture install modifies only a settings copy,
  never the live file.

### Scenario test decisions

- `2026-03-24 — DEC-SMOKE-001` Shell-based scenario test harness for hook
  validation.
- `2026-03-24 — DEC-SMOKE-002` Test all named agent types produce
  additionalContext on spawn.
- `2026-03-24 — DEC-SMOKE-003` Guardian-allow test requires all three gates:
  role, test, proof.
- `2026-03-24 — DEC-SMOKE-010` Orchestrator source-write deny test.
- `2026-03-24 — DEC-SMOKE-011` Implementer source-write allow test.
- `2026-03-24 — DEC-SMOKE-012` Tester source-write deny test.
- `2026-03-24 — DEC-SMOKE-013` Planner source-write deny test.
- `2026-03-24 — DEC-SMOKE-014` Non-source file WHO pass-through test.
- `2026-03-24 — DEC-TKT008-002` Compound allow path: all three bash-policy
  gates satisfied.

### Acceptance suite decisions

- `2026-03-24 — DEC-ACC-001` Full lifecycle test exercises the complete dispatch
  cycle end-to-end.
- `2026-03-24 — DEC-ACC-002` Enforcement matrix covers every WHO x action cell
  independently.
- `2026-03-24 — DEC-ACC-003` Runtime consistency tests exercise the full
  read-write round trip.
- `2026-03-24 — DEC-ACC-004` Master runner aggregates all suites into a single
  JSON report.

### Flat-file migration decisions

- `2026-03-24 — DEC-FORK-016` `.plan-drift` is a flat-file state authority
  (written by `hooks/surface.sh`, read by `hooks/context-lib.sh` and
  `hooks/plan-check.sh`) that violates DEC-FORK-007. It should be migrated to a
  runtime computation or eliminated. Until then it remains a known exception.

### Stabilization decisions

- `2026-03-24 — DEC-STAB-001` Wave 3e added as a stabilization pass before
  INIT-003 exit. The acceptance suite (TKT-014) passed but post-delivery audit
  found seven defects (#465-#471) proving the kernel is not yet mechanically
  trustworthy. P0 enforcement reliability fixes (marker deactivation, post-task
  wiring) must land before P1 hook correctness and flat-file elimination, which
  must land before P2 doc reconciliation.

### Self-hosting hardening decisions

- `2026-03-26 — DEC-SELF-001` Self-hosting hardening initiative begins with
  prompt hardening (Wave 1). Evaluator semantics replace tester/proof-state
  language. Evaluation Contract and Scope Manifest become mandatory planner
  outputs for guardian-bound source work. Cornerstone beliefs preserved intact.
- `2026-03-26 — DEC-SELF-002` Wave 2 adds `workflow_bindings` and
  `workflow_scope` tables as the sole authorities for workflow-to-worktree
  mapping and scope enforcement. The existing `worktrees` table remains a
  registry; `workflow_bindings` adds semantic binding (initiative, ticket, base
  branch). Scope manifests are stored as JSON arrays in `workflow_scope`, not
  flat files. Guardian denies commit/merge when no workflow binding exists for
  guardian-bound source tasks.
- `2026-03-27 — DEC-SELF-003` DB scoping hardening: `runtime/core/config.py`
  `default_db_path()` becomes the sole canonical DB resolver with 4-step
  resolution: CLAUDE_POLICY_DB → CLAUDE_PROJECT_DIR → git-root+.claude/ →
  ~/.claude/state.db. `hooks/log.sh` auto-exports CLAUDE_PROJECT_DIR as a
  performance optimization. `scripts/statusline.sh` inherits correct scoping.
  This closes the split-authority bug where hooks/scripts could silently write
  to ~/.claude/state.db while intending project-scoped state.
- `2026-03-27 — DEC-SELF-004` Statusline actor-truth hardening: `⚡impl`
  replaced with `marker: impl (2m)` label that explicitly represents subagent
  marker state, not current tool-call actor. Stale markers (>=5min) show `?`
  suffix. Evaluator display deferred until evaluation_state schema exists on
  main — this wave fixes actor-truth only.
- `2026-03-27 — DEC-SELF-005` Evaluator-state readiness cutover:
  `evaluation_state` replaces `proof_state` as the sole readiness authority.
  Evaluator writes via EVAL_* trailer in check-tester.sh. Guard Check 10 gates
  on eval_status + head_sha. prompt-submit.sh stops writing "verified" on user
  reply. check-guardian.sh validates evaluator state. proof_state has zero
  enforcement effect after cutover. User ceremony eliminated — readiness is
  earned by evaluator verdict.
  check-implementer.sh updated to evaluator-era handoff language. All five
  proof writers removed from hook chain (prompt-submit, subagent-start,
  guard merge-reset, track invalidation, session-init idle). Zero proof
  writes remain after cutover.

## Active Initiatives

### INIT-003: Plan Discipline and Successor Validation

- **Status:** stabilization complete (TKT-016/017/018/019 verified; acceptance
  suite green; exit pending `.agent-findings` flat-file migration or explicit
  exception — see below)
- **Goal:** Finish the successor kernel so its plan discipline, verification, and
  release claims are mechanically trustworthy.
- **Current truth:** Waves 3a-3d delivered plan discipline (TKT-010),
  trace-lite (TKT-013), acceptance suite (TKT-014), and shadow sidecars
  (TKT-015). Wave 3e stabilization (TKT-016/017/018/019) is substantively
  complete: runtime marker deactivation fires on SubagentStop (TKT-016),
  post-task.sh is wired into the live hook chain (TKT-016), plan-check.sh
  works in worktrees (TKT-017), hook denials include blockingHook observability
  (TKT-017), write-time policy resolves from target file path (TKT-017),
  flat-file dual-write bridge eliminated (TKT-018), and docs reconciled
  (TKT-019). One residual: `.agent-findings` flat file is still written by
  check-guardian.sh and read by prompt-submit.sh and compact-preserve.sh. This
  is advisory output (not workflow state), but it is the last flat-file write
  in the hook chain. Additionally, guard.sh Check 10 was migrated from
  flat-file to runtime proof reads in INIT-004 (`a182d7a`), closing the last
  flat-file proof reader. Minor documentation drift remains: write-guard.sh
  line 17 has a stale comment referencing `.subagent-tracker` fallback (code
  is correct, comment is not).
- **Scope:** plan immutability, decision-log closure rules, initiative
  compression, trace-lite manifests, kernel acceptance suite, shadow-mode
  sidecars, stabilization of enforcement reliability and flat-file elimination,
  and readiness for daemon promotion.
- **Exit:** Permanent-section replacement is mechanically blocked, the kernel
  acceptance suite passes twice consecutively with zero enforcement defects,
  no flat-file coordination mechanisms remain in hot-path hooks, and sidecars
  remain read-only until the kernel is stable.
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
- `TKT-016` Fix SubagentStop lifecycle: deactivate runtime markers and wire
  `post-task.sh` into the live hook chain (#470, #471).
- `TKT-017` Fix hook worktree detection and deny observability (#465, #466,
  #468).
- `TKT-018` Eliminate flat-file dual-write bridge and remaining breadcrumbs
  (#467, #469).
- `TKT-019` Reconcile docs to match actual live behavior (ARCHITECTURE.md
  scaffold language, MASTER_PLAN.md flat-file claims, dead statusline-cache
  write).
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
Wave 3e: TKT-016, TKT-017, TKT-018, TKT-019  (stabilization -- enforcement reliability + flat-file elimination)
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

#### Wave 3e: Stabilization (enforcement reliability + flat-file elimination)

**Sequencing:** P0 first (marker deactivation + post-task wiring), then P1
(hook worktree/observability fixes + flat-file removal), then P2 (doc
reconciliation). TKT-016 and TKT-017 have no mutual dependency and can run
in parallel after TKT-016's post-task wiring lands (TKT-017's deny
observability changes touch the same hook output format). TKT-018 depends on
TKT-017 completing (write-policy repo identity resolution must be correct
before flat-file removal changes the fallback behavior). TKT-019 runs last
because it documents what is, not what should be.

**Critical path:** TKT-016 -> TKT-018 -> TKT-019 -> (done). Max width: 2
(TKT-016 and TKT-017 can run in parallel).

##### TKT-016: Fix SubagentStop Lifecycle (#470, #471)

- **Weight:** M
- **Gate:** review (user sees marker deactivation and dispatch emission in
  acceptance suite output)
- **Deps:** INIT-002 complete (runtime must be live)
- **Implementer scope:**
  - Wire `hooks/post-task.sh` into `settings.json` under SubagentStop for all
    agent matchers. Currently SubagentStop only runs `check-*.sh` hooks;
    `post-task.sh` exists but is not registered. Add it to the SubagentStop
    hook array alongside the existing check hooks.
  - Add `rt_marker_deactivate` call to the SubagentStop path. The function
    exists in `hooks/lib/runtime-bridge.sh` (line 98) and is exported by
    `hooks/context-lib.sh` (line 559), but no SubagentStop hook ever calls it.
    The deactivation should happen in `hooks/post-task.sh` (or a dedicated
    lifecycle hook) so the agent marker row gets `stopped_at` set and
    `is_active` cleared.
  - Add scenario tests:
    - `tests/scenarios/test-marker-deactivation.sh`: spawn a mock agent,
      verify marker is active, fire SubagentStop, verify marker is
      deactivated.
    - `tests/scenarios/test-post-task-wiring.sh`: fire SubagentStop with
      implementer matcher, verify `post-task.sh` runs and emits dispatch
      queue entries.
  - Update existing acceptance suite tests that assert marker state to expect
    deactivation after SubagentStop.
- **Tester scope:**
  - Run `python3 runtime/cli.py marker list` before and after SubagentStop
    and verify `stopped_at` is populated and `is_active` is 0.
  - Run acceptance suite and verify marker lifecycle tests pass.
  - Verify dispatch queue entries appear after SubagentStop fires.
- **Acceptance criteria:**
  - `post-task.sh` appears in `settings.json` SubagentStop hook arrays.
  - `rt_marker_deactivate` is called on every SubagentStop event.
  - `marker list` shows `is_active=0` and non-null `stopped_at` for
    completed agents.
  - Dispatch queue entries are emitted on agent completion.
  - All scenario tests pass.
- **File boundaries:**
  - Modifies: `settings.json` (add post-task.sh to SubagentStop),
    `hooks/post-task.sh` (add marker deactivation call)
  - Creates: `tests/scenarios/test-marker-deactivation.sh`,
    `tests/scenarios/test-post-task-wiring.sh`
  - Does NOT modify: `runtime/`, `hooks/lib/runtime-bridge.sh` (function
    already exists), `hooks/context-lib.sh`

##### TKT-017: Fix Hook Worktree Detection and Deny Observability (#465, #466, #468)

- **Weight:** M
- **Gate:** review (user sees correct behavior in worktree and clear deny
  messages)
- **Deps:** none (independent of TKT-016)
- **Implementer scope:**
  - **#465 -- plan-check.sh .git detection:** Replace `[[ ! -d
    "$PROJECT_ROOT/.git" ]]` (line 67 of `hooks/plan-check.sh`) with
    `[[ ! -d "$PROJECT_ROOT/.git" && ! -f "$PROJECT_ROOT/.git" ]]` or
    equivalently `[[ ! -e "$PROJECT_ROOT/.git" ]]`. In a worktree, `.git` is
    a file containing `gitdir: /path/to/main/.git/worktrees/<name>`. The
    current `-d` test exits early, silently skipping plan-existence checks
    for all worktree operations.
  - **#466 -- deny observability:** When a hook denies an action, the deny
    JSON must include a `"blockingHook"` field naming the specific hook file
    that fired the denial. Currently the agent sees a generic denial message
    and cannot tell which of the 5+ hooks in the write chain blocked it.
    Add `"blockingHook": "<hook-filename>"` to the deny JSON output in:
    `hooks/plan-guard.sh`, `hooks/write-guard.sh`, `hooks/plan-check.sh`,
    `hooks/branch-guard.sh`, `hooks/guard.sh`, and the
    `check_plan_immutability_hook` / `check_decision_log_hook` wrappers in
    `hooks/lib/write-policy.sh`.
  - **#468 -- write-time repo identity resolution:** Hooks that fire on
    Write|Edit and call `detect_project_root()` resolve repo identity from
    the session CWD, not from the target file's path. When a session on
    `main` writes to a file in a worktree, the hook resolves the wrong
    project root. The fix: in `hooks/lib/write-policy.sh` functions that
    receive a `file_path` from the hook input, resolve `project_root` from
    `git -C "$(dirname "$file_path")" rev-parse --show-toplevel` (as
    `check_plan_immutability_hook` already does correctly on line 71). Apply
    this pattern to the delegated hook calls in write-policy.sh that
    currently pass session-root-resolved context. Also fix
    `hooks/plan-check.sh` and `hooks/plan-guard.sh` to resolve from
    file path when available.
  - Add scenario tests:
    - `tests/scenarios/test-plan-check-worktree.sh`: create a worktree,
      attempt a source write from it, verify plan-check.sh fires (not
      skipped).
    - `tests/scenarios/test-deny-observability.sh`: trigger a write-guard
      denial, verify the JSON output includes `blockingHook` field.
    - `tests/scenarios/test-write-policy-repo-identity.sh`: write to a
      worktree file from a main-branch session, verify the hook resolves the
      worktree's project root.
- **Tester scope:**
  - Create a worktree and verify plan-check.sh runs correctly in it.
  - Trigger each denial hook and verify `blockingHook` appears in the JSON.
  - Verify write-policy resolves the correct project root for cross-worktree
    writes.
  - Run full acceptance suite to confirm no regressions.
- **Acceptance criteria:**
  - `plan-check.sh` uses `-e` (not `-d`) for `.git` existence check.
  - All deny JSON responses include `blockingHook` field.
  - Write-time policy resolves repo identity from target file path, not
    session CWD.
  - All scenario tests pass including worktree scenarios.
- **File boundaries:**
  - Modifies: `hooks/plan-check.sh`, `hooks/plan-guard.sh`,
    `hooks/write-guard.sh`, `hooks/branch-guard.sh`, `hooks/guard.sh`,
    `hooks/lib/write-policy.sh`
  - Creates: `tests/scenarios/test-plan-check-worktree.sh`,
    `tests/scenarios/test-deny-observability.sh`,
    `tests/scenarios/test-write-policy-repo-identity.sh`
  - Does NOT modify: `runtime/`, `settings.json`, `scripts/`

##### TKT-018: Eliminate Flat-File Dual-Write Bridge and Remaining Breadcrumbs (#467, #469)

- **Weight:** L
- **Gate:** approve (user must approve the removal list before deletion --
  some files may have undocumented consumers)
- **Deps:** TKT-017 (write-policy repo identity must be correct before
  changing fallback behavior)
- **Implementer scope:**
  - **#467 -- .plan-drift elimination:** `hooks/surface.sh` (line 274)
    writes `.plan-drift`; `hooks/context-lib.sh` (line 148) and
    `hooks/plan-check.sh` read it for staleness scoring. Migrate the drift
    computation to a runtime function or compute it inline from git state
    (the data is derivable from `git log` + plan timestamp). Remove
    `.plan-drift` file creation, reading, and preservation from all hooks.
    Remove the `session-end.sh` preservation of `.plan-drift`.
  - **#469 -- remaining flat-file breadcrumbs:** Audit and remove all
    remaining flat-file coordination from hot-path hooks:
    - `.proof-status-*`: still referenced in `hooks/context-lib.sh` (line
      245). The runtime `proof_state` table is canonical (INIT-002). Remove
      flat-file reads and writes. Remove `resolve_proof_file` and
      `resolve_proof_file_for_command` functions if they only serve the
      flat-file path.
    - `.subagent-tracker`: still referenced in `hooks/context-lib.sh`
      (lines 387, 399, 493, 502, 533), `hooks/write-guard.sh` (lines 17,
      55), `hooks/subagent-start.sh` (line 13), `hooks/session-init.sh`
      (line 124). The runtime `agent_markers` table is canonical. Remove
      `track_subagent_start`, `track_subagent_stop`, `get_subagent_status`
      flat-file functions. Remove the flat-file fallback in
      `current_active_agent_role`.
    - `.statusline-cache`: `hooks/context-lib.sh` (line 435) still writes
      it via `write_statusline_cache`. The statusline renderer reads
      `cc-policy statusline snapshot` directly (TKT-012). Remove
      `write_statusline_cache` function and all callers.
    - `.audit-log`: still referenced in `hooks/context-lib.sh` (line 202),
      `hooks/session-end.sh` (line 59), `hooks/surface.sh` (line 262),
      `hooks/compact-preserve.sh` (line 96), `hooks/HOOKS.md` (line 381).
      The runtime `events` table is canonical. Remove the flat-file
      `append_audit` dual-write (keep the `rt_event_emit` call). Remove
      `.audit-log` trimming from `session-end.sh`.
    - `.agent-findings`: still referenced in `hooks/prompt-submit.sh` (line
      103), `hooks/compact-preserve.sh` (line 87), `hooks/check-tester.sh`
      (line 57), `hooks/session-init.sh` (line 110), and all `check-*.sh`
      hooks. Migrate to runtime event queries or eliminate if findings
      injection is no longer needed.
  - Update `hooks/HOOKS.md` to remove all flat-file state references from
    the state authority table.
  - Add scenario tests:
    - `tests/scenarios/test-no-flat-file-writes.sh`: run a representative
      hook sequence and verify no `.proof-status-*`, `.subagent-tracker`,
      `.statusline-cache`, `.audit-log`, `.agent-findings`, or `.plan-drift`
      files are created.
- **Tester scope:**
  - Run the full hook chain and verify no flat files are created in
    `.claude/`.
  - Verify `current_active_agent_role` returns correct values from runtime
    only.
  - Verify `append_audit` emits to runtime only.
  - Verify plan staleness scoring works without `.plan-drift`.
  - Run full acceptance suite.
- **Acceptance criteria:**
  - Zero flat-file coordination mechanisms in hot-path hooks.
  - `grep -r '\.proof-status\|\.subagent-tracker\|\.statusline-cache\|\.audit-log\|\.agent-findings\|\.plan-drift' hooks/` returns zero matches
    (excluding comments documenting the removal).
  - All runtime-backed alternatives work correctly.
  - `hooks/HOOKS.md` state authority table reflects runtime-only authorities.
  - All tests pass.
- **File boundaries:**
  - Modifies: `hooks/context-lib.sh`, `hooks/surface.sh`,
    `hooks/plan-check.sh`, `hooks/session-end.sh`, `hooks/session-init.sh`,
    `hooks/write-guard.sh`, `hooks/subagent-start.sh`,
    `hooks/prompt-submit.sh`, `hooks/compact-preserve.sh`,
    `hooks/check-tester.sh`, `hooks/check-planner.sh`,
    `hooks/check-implementer.sh`, `hooks/check-guardian.sh`,
    `hooks/HOOKS.md`
  - Creates: `tests/scenarios/test-no-flat-file-writes.sh`
  - Does NOT modify: `runtime/` (runtime is already canonical),
    `settings.json`, `scripts/planctl.py`

##### TKT-019: Reconcile Docs to Match Actual Live Behavior

- **Weight:** S
- **Gate:** review (user sees corrected docs)
- **Deps:** TKT-016, TKT-017, TKT-018 (docs must describe the final state,
  not an intermediate one)
- **Implementer scope:**
  - **docs/ARCHITECTURE.md scaffold language:** Lines 65-77 describe
    `runtime/`, `runtime/core/`, `hooks/lib/runtime-bridge.sh`, and other
    files as "scaffolds" with "no real state backend." These are all live,
    implemented components as of INIT-002. Rewrite the "Current Bootstrap"
    section to describe the actual architecture: thin hooks delegating to
    write-policy/bash-policy, runtime-bridge.sh bridging to cc-policy CLI,
    SQLite-backed runtime with 6+ tables, read-only sidecars.
  - **MASTER_PLAN.md flat-file claims:** The Architecture section (line 26)
    states "Flat-file authorities ... have been deleted." This is false --
    dual-write is still active (or was, until TKT-018 removes it). After
    TKT-018 lands, verify this claim is now true. If any flat-file remnants
    survived TKT-018, update the Architecture section accordingly.
  - **Dead statusline-cache write:** `hooks/context-lib.sh` function
    `write_statusline_cache` (line 433) writes to `.statusline-cache` but
    nothing reads it -- the renderer uses `cc-policy statusline snapshot`
    directly. If TKT-018 did not already remove this function, remove it
    here.
  - **docs/ARCHITECTURE.md SubagentStop description:** Update to reflect
    post-task.sh wiring (after TKT-016).
  - **hooks/HOOKS.md:** Verify all hook descriptions match current behavior
    after TKT-016/017/018 changes.
- **Tester scope:**
  - Read each modified doc section and verify every claim against the actual
    codebase.
  - Verify no doc claims protection that the hook chain cannot deliver
    (Principle 8).
- **Acceptance criteria:**
  - `docs/ARCHITECTURE.md` describes the live system, not scaffolds.
  - MASTER_PLAN.md Architecture section claims match reality.
  - No dead code remains for flat-file writes that nothing reads.
  - `hooks/HOOKS.md` matches current hook behavior.
- **File boundaries:**
  - Modifies: `docs/ARCHITECTURE.md`, `hooks/HOOKS.md`,
    `hooks/context-lib.sh` (if dead code remains after TKT-018)
  - May modify: MASTER_PLAN.md Architecture section (planner-gated)
  - Does NOT modify: `runtime/`, `settings.json`, `scripts/`

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
| Agent marker lifecycle | `agent_markers` table (write), flat-file `.subagent-tracker` (fallback read) | `agent_markers` table only; `rt_marker_deactivate` called on SubagentStop | TKT-016, TKT-018 |
| Dispatch emission on agent stop | `check-*.sh` hooks only (no dispatch) | `post-task.sh` wired into SubagentStop; dispatch queue entries emitted | TKT-016 |
| Plan-existence gate in worktrees | Broken (`.git` `-d` check exits early) | `-e` check handles both directory and file `.git` | TKT-017 |
| Hook deny diagnostics | Generic deny JSON (no hook identification) | `blockingHook` field in all deny responses | TKT-017 |
| Write-time repo identity | `detect_project_root()` from session CWD | `git -C "$(dirname "$file_path")"` from target file path | TKT-017 |
| Plan staleness / drift data | `.plan-drift` flat file | Runtime computation or inline git derivation | TKT-018 |
| Proof state (flat-file remnant) | `.proof-status-*` flat files (fallback) | `proof_state` table only | TKT-018 |
| Subagent tracking (flat-file remnant) | `.subagent-tracker` flat file (fallback) | `agent_markers` table only | TKT-018 |
| Audit trail (flat-file remnant) | `.audit-log` flat file (dual-write) | `events` table only via `rt_event_emit` | TKT-018 |
| Agent findings (flat-file remnant) | `.agent-findings` flat file | Runtime event queries or eliminated | TKT-018 |
| Statusline cache (flat-file remnant) | `.statusline-cache` flat file | Eliminated; renderer reads runtime directly | TKT-018 |

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
6. **Flat-file removal cascading breakage.** TKT-018 touches 13+ hook files
   to remove flat-file references. If any hook has an undocumented dependency
   on a flat file that the audit missed, removing it silently degrades
   behavior. Mitigation: the acceptance suite (TKT-014) must run green after
   TKT-018 and the user must approve the removal list before deletion.
7. **post-task.sh integration side effects.** Wiring post-task.sh into
   SubagentStop may change hook chain timing or introduce failures that
   previously didn't exist in the SubagentStop path. Mitigation: TKT-016
   tests must verify that existing check-*.sh hooks still fire correctly
   after post-task.sh is added to the chain.
8. **Deny observability format change.** Adding `blockingHook` to deny JSON
   changes the output format that agents parse. If any agent code parses
   deny messages with exact string matching, the new field could break it.
   Mitigation: `blockingHook` is added as a new field, not replacing existing
   fields. The existing `permissionDecisionReason` string is unchanged.

### INIT-004: Self-Hosting Hardening

- **Status:** in-progress (Wave 1 prompt hardening landed at `a888c60`; Wave 2
  workflow identity and scope binding landed at `c1bd1f0`; proof-read hot-path
  fix landed at `a182d7a`; CLAUDE.md source-edit-routing patch landed at
  `5cdc6b8`; Wave 3 DB-scoping hardening TKT-022 planned; Wave 4 statusline
  actor-truth hardening TKT-023 planned; Wave 5 evaluator-state cutover
  TKT-024 planned (revised))
- **Goal:** Harden prompts, runtime identity, scope enforcement, and hook
  mechanisms so the repo can accurately build and judge itself. Waves 1-2
  delivered. Wave 3 closes the DB-scoping split-authority bug. Wave 4 closes the
  statusline actor-truth gap (stale markers implying active agents). Wave 5
  replaces proof_state with evaluation_state as the sole readiness authority for
  Guardian commit/merge, eliminating the fake user-proof ceremony. Remaining
  waves (test isolation, stop-hook hardening) are planned in the forward plan
  but not yet scheduled in MASTER_PLAN.md.
- **Scope:** Wave 1: 6 prompt/agent markdown files (landed). Wave 2: runtime
  schemas, domain module, CLI extensions, hook changes for binding and scope
  enforcement, guard grep pattern broadening, unit and scenario tests (landed).
  Additional: proof-read hot-path fix migrating guard.sh Check 10 from flat-file
  to runtime (landed). CLAUDE.md source-edit-routing patch (landed). Wave 3:
  `hooks/log.sh` CLAUDE_PROJECT_DIR auto-export and DB-scoping scenario tests.
  Wave 4: statusline marker label replaces actor-implying symbol with explicit
  marker-state display; age suffix and stale indicator; session-init warns on
  stale markers. Wave 5: evaluation_state schema, domain, CLI, bridge, context
  functions, check-tester trailer parsing, guard.sh evaluation gate, post-task
  verdict routing, track.sh invalidation, subagent-start and session-init
  evaluation context, prompt-submit proof removal, check-guardian evaluator
  check-implementer evaluator-era language,
  validation, unit and scenario tests (23 files total).
- **Exit:** All waves delivered. Prompts support evaluator-based readiness.
  Workflow identity is bound to worktrees. Scope manifests are mechanically
  enforced. Guardian denies unbound source tasks. DB scoping is unified: all
  hook contexts resolve to the project DB when a git root exists. Statusline
  displays marker age accurately. Evaluation_state is the sole readiness
  authority for Guardian; proof_state is deprecated display-only.
- **Dependencies:** INIT-003 (additive; does not require INIT-003 completion
  but must not contradict its decisions)

#### Wave 1: Prompt Hardening

##### TKT-020: Wave 1 Prompt Hardening

- **Weight:** M
- **Gate:** approve (user must approve before merge since this changes governance
  prompts)
- **Deps:** none (pure prompt changes)

###### Evaluation Contract for TKT-020

**Required checks (each must be verified by the evaluator):**

1. `CLAUDE.md` — Simple Task Fast Path tightened: planner skip only for
   docs/config/non-source with no guardian path, no state-authority changes.
   Source tasks require planner Evaluation Contract.
2. `CLAUDE.md` — Sacred Practice #10 replaced: evaluator owns technical
   readiness; user approval is for irreversible git actions or product signoff,
   not proof of correctness.
3. `CLAUDE.md` — Dispatch context requires Evaluation Contract for
   guardian-bound source tasks.
4. `CLAUDE.md` — Uncertainty-reporting rule added: if you cannot prove worktree,
   branch, head SHA, and test completeness, report uncertainty not completion.
5. `CLAUDE.md` — Debugging rule added: keep collecting failures until minimal
   root-cause set; do not stop at first non-zero command.
6. `agents/planner.md` — Hard constraint added: no guardian-bound source task
   without Evaluation Contract and Scope Manifest.
7. `agents/planner.md` — Evaluation Contract section added with: required tests,
   real-path checks, authority invariants, integration points, forbidden
   shortcuts, ready-for-guardian definition.
8. `agents/planner.md` — Scope Manifest section added with: allowed/required/
   forbidden paths, authority domains.
9. `agents/planner.md` — Quality gate requires executable evaluation criteria.
10. `agents/implementer.md` — "Presenting Your Work" replaced with
    contract-driven report: Contract Compliance, Scope Compliance, minimal
    trailer (IMPL_STATUS, IMPL_SCOPE_OK, IMPL_HEAD_SHA).
11. `agents/implementer.md` — Rule added: may not claim guardian readiness;
    evidence is implementer's, readiness belongs to evaluator.
12. `agents/tester.md` — Semantic role changed to evaluator. Verdict set:
    needs_changes, ready_for_guardian, blocked_by_plan.
13. `agents/tester.md` — Refusal conditions added: unclear repo/worktree
    identity, partial test execution, hung suite, non-isolated real state.
14. `agents/tester.md` — Deterministic trailer with status, counts, next role,
    head SHA.
15. `agents/tester.md` — Must classify uncertainty instead of papering over it.
16. `agents/guardian.md` — Proof-state trust replaced with: runtime evaluation
    state, head SHA match, test completeness, role policy.
17. `agents/guardian.md` — Explicit rule: prose summaries are non-authoritative;
    agent summaries are advisory.
18. `agents/shared-protocols.md` — Role-specific output contracts added
    (implementer trailer, evaluator trailer).
19. `agents/shared-protocols.md` — No lines after evaluator trailer rule.
20. `agents/shared-protocols.md` — Debugging collection rule: keep collecting
    failures until failure set is categorized.

**Required authority invariants:**

- Cornerstone Belief section in CLAUDE.md unchanged
- Philosophy sections (What Matters, Interaction Style, Output Intelligence)
  unchanged
- All 5 bullet points under Cornerstone Belief unchanged
- No prompt instructs user to reply "verified" as technical proof
- No prompt uses "proof state" as the name for evaluator readiness

**Forbidden shortcuts:**

- Do not flatten the repo's philosophical language into generic corporate prompt
  language
- Do not remove @decision annotation requirements
- Do not remove worktree isolation requirements
- Do not change hooks, runtime, tests, settings, or any file outside the 6
  prompt files

**Ready-for-guardian definition:**

All 20 required checks pass. Authority invariants hold. No forbidden shortcuts
taken. `git diff --stat` shows exactly 6 files changed (CLAUDE.md,
agents/planner.md, agents/implementer.md, agents/tester.md,
agents/guardian.md, agents/shared-protocols.md).

###### Scope Manifest for TKT-020

**Allowed files:** CLAUDE.md, agents/planner.md, agents/implementer.md,
agents/tester.md, agents/guardian.md, agents/shared-protocols.md

**Required files:** All 6 of the above must be modified.

**Forbidden touch points:** hooks/\*, runtime/\*, tests/\*, settings.json,
scripts/\*, docs/\*, .claude/\*, MASTER_PLAN.md (except for this planning
amendment)

**Expected state authorities touched:** None — this is prompt-only, no runtime
state changes.

#### Wave 2: Workflow Identity and Scope Binding

##### TKT-021: Wave 2 Workflow Identity and Scope Binding

- **Weight:** L
- **Gate:** review (user sees result before guardian merge)
- **Deps:** TKT-020 (Wave 1 prompt hardening must be landed so evaluator
  semantics and Evaluation Contract conventions are established)

**Implementer scope (files to create or modify):**

- `runtime/schemas.py` — add `workflow_bindings` and `workflow_scope` tables to
  `ensure_schema()`
- `runtime/core/workflows.py` — NEW: domain logic for workflow bindings and
  scope (bind_workflow, get_binding, set_scope, get_scope,
  check_scope_compliance, list_bindings)
- `runtime/cli.py` — add `workflow` domain with bind, get, scope-set,
  scope-get, scope-check, list actions
- `hooks/lib/runtime-bridge.sh` — add workflow wrapper functions
  (rt_workflow_bind, rt_workflow_get, rt_workflow_scope_check)
- `hooks/subagent-start.sh` — bind workflow to worktree on implementer spawn
- `hooks/check-implementer.sh` — validate changed files against workflow scope
  manifest on implementer stop
- `hooks/guard.sh` — add Check 12: workflow binding gate that denies
  commit/merge when no binding exists for guardian-bound source tasks
- `hooks/post-task.sh` — include workflow_id in dispatch context for later roles
- `hooks/context-lib.sh` — add `get_workflow_binding()` function exposing
  WORKFLOW_ID, WORKFLOW_WORKTREE, WORKFLOW_BRANCH, WORKFLOW_TICKET
- `tests/runtime/test_workflows.py` — NEW: unit tests for workflow domain
- `tests/scenarios/test-workflow-bind-roundtrip.sh` — NEW: scenario test for
  bind-get roundtrip
- `tests/scenarios/test-workflow-scope-check.sh` — NEW: scenario test for scope
  compliance checking
- `tests/scenarios/test-guard-workflow-binding-required.sh` — NEW: scenario test
  for guardian fail-closed behavior
- `tests/scenarios/test-guard-scope-missing-denied.sh` — NEW: scenario test for
  guardian fail-closed when workflow_scope is missing
- `CLAUDE.md` — narrow addition: add 1 sentence to Scope Manifest dispatch
  bullet instructing orchestrator to write scope to runtime via
  `cc-policy workflow scope-set` before dispatching implementer

**Scope ingestion path (plan → runtime):**

The planner writes the Scope Manifest as prose in MASTER_PLAN.md. The runtime
`workflow_scope` table must be populated before the implementer starts. The
ingestion path is:

1. **Sole writer:** The orchestrator. No hook, no agent, no other component
   writes to `workflow_scope`. The orchestrator calls
   `cc-policy workflow scope-set <workflow_id> --allowed '...' --required '...'
   --forbidden '...' --authorities '...'` as a Bash command.
2. **When:** After plan approval, before implementer dispatch. The orchestrator
   already reads the plan and extracts the Scope Manifest for the dispatch
   context (per Wave 1 CLAUDE.md rules). Writing it to runtime is the same
   extraction step, projected into SQLite.
3. **workflow_id matching:** The orchestrator determines workflow_id from the
   planned branch name — the same derivation as `current_workflow_id()` in
   context-lib.sh (sanitized branch name). The orchestrator creates the
   worktree with a known branch, so workflow_id is deterministic.
4. **Missing scope:** If `workflow_scope` is empty when `check-implementer.sh`
   runs → advisory warning. If empty when `guard.sh` runs → deny (fail-closed
   for guardian-bound source tasks). This creates the forcing function: if the
   orchestrator forgets, Guardian blocks.
5. **Stale scope:** If the plan changes mid-implementation, the orchestrator
   must re-write scope before re-dispatching. Staleness is detectable by
   comparing `workflow_scope.updated_at` to `workflow_bindings.updated_at`.
   Guard.sh does not enforce staleness in Wave 2 (deferred to Wave 4).

**Tester scope (what to verify):**

- Workflow binding roundtrip works (bind, get, verify fields match)
- Scope ingestion roundtrip: orchestrator writes scope via CLI, runtime stores
  it, check-implementer reads it, guard.sh reads it
- Scope compliance check correctly accepts in-scope files and rejects
  out-of-scope files
- Guardian denies commit when no workflow binding exists
- Guardian denies commit when workflow binding exists but workflow_scope is
  missing
- Guardian allows commit when workflow binding and scope both exist and are
  compliant
- Hook integration: subagent-start binds, check-implementer validates,
  guard.sh gates
- No flat-file scope or binding tracking introduced
- No component other than the orchestrator (via CLI) writes to workflow_scope
- Existing proof_state, agent_markers, dispatch tables unchanged
- All existing tests continue to pass

###### Evaluation Contract for TKT-021

**Required checks (each must be verified by the evaluator):**

1. `workflow_bindings` table exists in the SQLite schema with columns:
   workflow_id (TEXT PK), worktree_path (TEXT NOT NULL), branch (TEXT NOT NULL),
   base_branch (TEXT DEFAULT 'main'), ticket (TEXT), initiative (TEXT),
   created_at (INTEGER NOT NULL), updated_at (INTEGER NOT NULL).
2. `workflow_scope` table exists in the SQLite schema with columns:
   workflow_id (TEXT PK, FK to workflow_bindings), allowed_paths (TEXT),
   required_paths (TEXT), forbidden_paths (TEXT), authority_domains (TEXT),
   updated_at (INTEGER NOT NULL).
3. `runtime/core/workflows.py` implements: bind_workflow, get_binding,
   set_scope, get_scope, check_scope_compliance, list_bindings. Each function
   takes a connection as first argument.
4. `runtime/cli.py` exposes `workflow` domain with actions: bind, get,
   scope-set, scope-get, scope-check, list. Each action calls the corresponding
   domain function via cc-policy CLI.
5. `hooks/lib/runtime-bridge.sh` has shell wrapper functions: rt_workflow_bind,
   rt_workflow_get, rt_workflow_scope_check. Each calls cc-policy workflow
   with appropriate arguments.
6. `hooks/subagent-start.sh` calls rt_workflow_bind when spawning an
   implementer, passing workflow_id, worktree path, and branch.
7. `hooks/check-implementer.sh` calls rt_workflow_scope_check on implementer
   stop and reports violations if any files are out of scope.
8. `hooks/guard.sh` has Check 12 (workflow binding gate) that denies
   commit/merge when no workflow binding exists for guardian-bound source tasks.
   The check must be skippable for meta-repo operations (e.g., MASTER_PLAN.md
   edits on main).
9. `hooks/context-lib.sh` has `get_workflow_binding()` that reads the binding
   from runtime and exports WORKFLOW_ID, WORKFLOW_WORKTREE, WORKFLOW_BRANCH,
   WORKFLOW_TICKET.
10. Workflow binding roundtrip: bind a workflow, get it back, all fields match
    what was bound.
11. Scope compliance check: files matching allowed_paths pass; files outside
    allowed_paths fail; files in forbidden_paths always fail.
12. Guardian fail-closed: guard.sh denies commit when no workflow binding exists
    for a guardian-bound source task (not a meta-repo bypass).
13. Later roles do not infer worktree from CWD — they read the binding from
    runtime via get_workflow_binding or rt_workflow_get.
14. All unit tests pass (pytest tests/runtime/).
15. All scenario tests pass (tests/scenarios/test-*.sh).
16. Scope ingestion: `cc-policy workflow scope-set` writes to `workflow_scope`
    table; `cc-policy workflow scope-get` reads it back with matching fields.
17. Guardian fail-closed on missing scope: guard.sh denies commit when
    `workflow_bindings` exists but `workflow_scope` is empty for that
    workflow_id.
18. `CLAUDE.md` dispatch context Scope Manifest bullet updated to instruct
    orchestrator to write scope to runtime via `cc-policy workflow scope-set`
    before implementer dispatch.

**Required authority invariants:**

- `workflow_bindings` is the single authority for workflow-to-worktree mapping.
- `workflow_scope` is the single authority for scope manifests.
- No flat-file scope or binding tracking introduced.
- Existing `worktrees` table is NOT the authority for workflow binding — it
  remains a registry. `workflow_bindings` adds workflow semantics (initiative,
  ticket, base branch, scope).
- Existing `proof_state`, `agent_markers`, `dispatch_queue`,
  `dispatch_cycles`, `worktrees` tables are unchanged in schema.
- The orchestrator is the sole writer for `workflow_scope`. No hook or agent
  writes scope directly. Guard.sh enforces this by failing closed when scope
  is missing — the forcing function that ensures the orchestrator writes it.

**Forbidden shortcuts:**

- Do not store scope in flat files.
- Do not infer worktree from CWD in hooks when a binding exists.
- Do not skip the guardian fail-closed check.
- Do not modify agents/*.md (prompt changes were Wave 1).
- CLAUDE.md may only be modified to add the scope-to-runtime instruction in
  the existing Scope Manifest dispatch bullet — no other CLAUDE.md changes.
- Do not modify `runtime/core/proof.py` (not changing proof semantics).

**Ready-for-guardian definition:**

All 18 required checks pass. Authority invariants hold. No forbidden shortcuts
taken. `git diff --stat` shows only files listed in the Scope Manifest below.

###### Scope Manifest for TKT-021

**Allowed files:**

- `runtime/schemas.py` (modify: add tables)
- `runtime/core/workflows.py` (new)
- `runtime/cli.py` (modify: add workflow domain)
- `hooks/lib/runtime-bridge.sh` (modify: add workflow wrappers)
- `hooks/subagent-start.sh` (modify: bind workflow on implementer spawn)
- `hooks/check-implementer.sh` (modify: scope compliance check)
- `hooks/guard.sh` (modify: Check 12 workflow binding gate)
- `hooks/post-task.sh` (modify: include workflow_id in dispatch context)
- `hooks/context-lib.sh` (modify: add get_workflow_binding)
- `tests/runtime/test_workflows.py` (new: unit tests)
- `tests/scenarios/test-workflow-bind-roundtrip.sh` (new: scenario test)
- `tests/scenarios/test-workflow-scope-check.sh` (new: scenario test)
- `tests/scenarios/test-guard-workflow-binding-required.sh` (new: scenario test)
- `CLAUDE.md` (modify: 1-sentence addition to Scope Manifest dispatch bullet)
- `tests/scenarios/test-guard-scope-missing-denied.sh` (new: scenario test)

**Required files:** All 15 of the above must be created or modified.

**Forbidden touch points:**

- `agents/*.md` (Wave 1 scope, already landed)
- `CLAUDE.md` sections other than the Scope Manifest dispatch bullet
- `MASTER_PLAN.md` (except for this planning amendment)
- `settings.json` (no new hook events needed — existing events cover this)
- `runtime/core/proof.py` (not changing proof semantics in this wave)
- `runtime/core/dispatch.py` (not changing dispatch semantics in this wave)
- `runtime/core/worktrees.py` (not changing worktree registry in this wave)

**Expected state authorities touched:**

- NEW: `workflow_bindings` table — sole authority for workflow-to-worktree
  mapping
- NEW: `workflow_scope` table — sole authority for scope manifests
- MODIFIED: `guard.sh` check chain — adding Check 12 (workflow binding gate)
- MODIFIED: `check-implementer.sh` validation chain — adding scope compliance
- UNCHANGED: `proof_state`, `agent_markers`, `dispatch_queue`,
  `dispatch_cycles`, `worktrees`

#### Wave 3: DB-Scoping Hardening

##### TKT-022: Wave 3 DB-Scoping Hardening

- **Weight:** M
- **Gate:** review (user sees result before guardian merge)
- **Deps:** TKT-021 (workflow binding reads/writes must target the correct DB)

**Root cause:**

The DB-scoping bug has three entry points, not one:

1. **Hooks** call `detect_project_root()` but never export
   `CLAUDE_PROJECT_DIR`. `runtime-bridge.sh`'s `cc_policy()` cannot scope to
   the project DB and falls back to `~/.claude/state.db`.
2. **`runtime/core/config.py` `default_db_path()`** only checks
   `CLAUDE_POLICY_DB` → `~/.claude/state.db`. It has no awareness of project
   context, CWD, or git root.
3. **`scripts/statusline.sh`** calls `python3 cli.py` directly (not through
   `runtime-bridge.sh`), bypassing the hook bridge entirely.

Any fix that only patches hooks leaves direct CLI invocations and script paths
silently hitting `~/.claude/state.db`.

**Canonical DB resolution rule (to be implemented):**

One resolver, in `runtime/core/config.py`, used by all paths:

1. If `CLAUDE_POLICY_DB` is set → use it (explicit override, always wins)
2. Else if `CLAUDE_PROJECT_DIR` is set → use `$CLAUDE_PROJECT_DIR/.claude/state.db`
3. Else if CWD is inside a git repo that contains a `.claude/` directory → use
   `<git-root>/.claude/state.db`
4. Else → fall back to `~/.claude/state.db`

Steps 1-2 are env-var-based (fast, no subprocess). Step 3 runs
`git rev-parse --show-toplevel` and checks for `.claude/` — this is the
project-detection fallback for direct CLI invocations that don't inherit hook
env vars. Step 4 is the global fallback for non-project contexts.

**Worktree behavior (explicit):**

All worktrees of the same repo share the same project `.claude/state.db`
because `git rev-parse --show-toplevel` in a worktree returns the main repo
root. This is correct — workflow state, proof, and bindings are per-project,
not per-worktree. The `workflow_bindings` table distinguishes work items by
workflow_id (derived from branch name), not by worktree path.

**Fix description:**

- `runtime/core/config.py`: expand `default_db_path()` to implement the
  4-step canonical resolution rule above. Add a `resolve_project_db()` helper
  that encapsulates the git-root + `.claude/` check.
- `hooks/log.sh`: auto-export `CLAUDE_PROJECT_DIR` after
  `detect_project_root()` so hooks pass the env var to `cc_policy()`. This
  is a performance optimization — the runtime resolver would find the same
  path via git, but the export avoids a subprocess per cc_policy call.
- `hooks/lib/runtime-bridge.sh`: no changes needed. `cc_policy()` already
  exports `CLAUDE_POLICY_DB` from `CLAUDE_PROJECT_DIR` when set. With
  `log.sh` now exporting `CLAUDE_PROJECT_DIR`, the bridge path is fixed.
- `scripts/statusline.sh`: add `CLAUDE_PROJECT_DIR` or `CLAUDE_POLICY_DB`
  export before calling `_cc()`, so the Python CLI receives the correct DB
  path. Alternatively, rely on the new `config.py` git-root detection.
- Tests: two scenario tests and one unit test.

**Implementer scope (files to create or modify):**

- `runtime/core/config.py` — expand `default_db_path()` with 4-step resolver;
  add `resolve_project_db()` helper
- `hooks/log.sh` — auto-export `CLAUDE_PROJECT_DIR` from
  `detect_project_root()` with HOME guard
- `scripts/statusline.sh` — ensure `_cc()` calls resolve to project DB
- `tests/scenarios/test-guard-db-scoping.sh` — NEW: positive (project-scoped
  proof write + guard read hit same DB) and negative (home DB proof alone does
  not satisfy project guard)
- `tests/scenarios/test-cli-db-scoping.sh` — NEW: direct `python3 cli.py`
  invocation from inside a project without `CLAUDE_POLICY_DB` set resolves to
  project `.claude/state.db`
- `tests/runtime/test_config_scoping.py` — NEW: unit tests for
  `default_db_path()` and `resolve_project_db()` covering all 4 resolution
  steps

**Tester scope (what to verify):**

- Proof write in hook context → guard read → same project DB (no split)
- Direct CLI invocation from project CWD → resolves to project DB
- statusline.sh from project CWD → resolves to project DB
- Home DB proof alone does not satisfy project-scoped guard
- Non-git CWD → falls back to `~/.claude/state.db` (no crash, no wrong scope)
- Worktree CWD → resolves to main repo project DB
- Existing tests pass (no regression from resolver changes)

###### Evaluation Contract for TKT-022

**Required checks (each must be verified by the evaluator):**

1. `runtime/core/config.py` `default_db_path()` implements the 4-step
   resolution: CLAUDE_POLICY_DB → CLAUDE_PROJECT_DIR → git-root+.claude/ →
   ~/.claude/state.db.
2. `runtime/core/config.py` has a `resolve_project_db()` helper that checks
   git root and `.claude/` directory existence.
3. `hooks/log.sh` auto-exports `CLAUDE_PROJECT_DIR` from
   `detect_project_root()` when not already set, with HOME guard.
4. `scripts/statusline.sh` `_cc()` calls resolve to project DB when invoked
   from inside a project.
5. Proof write via hook (rt_proof_set) lands in project `.claude/state.db`.
6. Proof read via guard.sh (read_proof_status) reads from same project
   `.claude/state.db`.
7. Proof in `~/.claude/state.db` alone does NOT satisfy guard in a project
   context (negative test passes).
8. Direct `python3 runtime/cli.py proof get ...` from project CWD without
   `CLAUDE_POLICY_DB` set resolves to project `.claude/state.db`.
9. Worktree CWD resolves to main repo `.claude/state.db` (shared across
   worktrees of the same repo).
10. Non-git CWD falls back to `~/.claude/state.db` without error.
11. All existing scenario and acceptance tests pass (no regression).
12. All new unit and scenario tests pass.

**Required authority invariants:**

- `runtime/core/config.py` `default_db_path()` is the sole canonical DB
  resolver. All paths (Python, shell bridge, direct CLI, scripts) converge
  through it.
- No code path silently resolves to `~/.claude/state.db` when operating inside
  a project with `.claude/state.db` present.
- `hooks/log.sh` CLAUDE_PROJECT_DIR export is a performance optimization, not
  the authority — `config.py` can find the project DB independently via git.

**Forbidden shortcuts:**

- Do not add a second resolver in `runtime-bridge.sh` that diverges from
  `config.py`.
- Do not hardcode DB paths in scripts or hooks.
- Do not change `settings.json`.
- Do not modify agent prompts.

**Ready-for-guardian definition:**

All 12 checks pass. Authority invariants hold. No forbidden shortcuts taken.
`git diff --stat` shows only files in the Scope Manifest.

###### Scope Manifest for TKT-022

**Allowed files:**

- `runtime/core/config.py` (modify: expand default_db_path, add
  resolve_project_db)
- `hooks/log.sh` (modify: add CLAUDE_PROJECT_DIR auto-export)
- `scripts/statusline.sh` (modify: ensure project DB scoping for _cc calls)
- `tests/scenarios/test-guard-db-scoping.sh` (new)
- `tests/scenarios/test-cli-db-scoping.sh` (new)
- `tests/runtime/test_config_scoping.py` (new)

**Required files:** All 6 of the above must be created or modified.

**Forbidden touch points:**

- `hooks/lib/runtime-bridge.sh` (already correct, no changes needed)
- `settings.json`
- `CLAUDE.md`, `agents/*.md`
- `MASTER_PLAN.md` (except for this planning amendment)
- `runtime/cli.py` (config.py handles resolution; CLI inherits)

**Expected state authorities touched:**

- MODIFIED: `runtime/core/config.py` — sole canonical DB resolver
- MODIFIED: `hooks/log.sh` — performance optimization for hook paths
- MODIFIED: `scripts/statusline.sh` — direct-CLI path now scoped
- UNCHANGED: `hooks/lib/runtime-bridge.sh`, `runtime/cli.py`,
  `runtime/core/proof.py`, all other runtime modules

#### Wave 4: Statusline Actor-Truth Hardening

##### TKT-023: Wave 4 Statusline Actor-Truth Hardening

- **Weight:** S
- **Gate:** review
- **Deps:** TKT-022 (DB scoping must be resolved so snapshot reads correct DB)

**Problem:**

The statusline `⚡impl` display implies the implementer is currently executing.
In reality, the `agent_markers` table only tracks "this marker was set and has
not been deactivated." The statusline has no liveness check and no age
indicator. A 2-hour-old stale marker (e.g., after a crash where SubagentStop
never fired) looks identical to a 2-second-old active marker.

**Design:**

Replace the actor-implying `⚡impl` with an explicit marker-state label:

- **Fresh marker (<5min):** `marker: impl (2m)` — the parenthesized age makes
  clear this is a temporal state, not a liveness assertion.
- **Stale marker (>=5min):** `marker: impl? (7m)` — the `?` suffix signals the
  marker may no longer reflect reality.
- **No active marker:** segment omitted entirely (no empty label).

The 5-minute staleness threshold is chosen because the longest typical agent
dispatch (planner) completes well within 5 minutes. Agents that exceed this
are either long-running implementers (where the age display is informative) or
crashed/hung (where the `?` suffix is a warning).

**HUD label semantics:**

| Label | Meaning |
|-------|---------|
| `marker: impl (2m)` | An implementer subagent marker was set 2 minutes ago and has not been deactivated. The agent may or may not be the current tool-call actor. |
| `marker: impl? (7m)` | Same, but the marker is >=5min old. Treat with lower confidence — the agent may have finished, crashed, or been superseded. |
| (absent) | No active marker exists. |

**Proof and dispatch displays:** Unchanged in this wave. `proof:` continues to
show legacy proof_state. `next:` continues to show pending dispatch. Neither
overstates actor identity. Evaluator display is deferred until the
evaluation_state schema exists on main.

**Implementer scope:**

- `runtime/core/statusline.py` — add `marker_age_seconds` field to `snapshot()`.
  Compute as `int(time.time()) - started_at` for the active marker.
- `runtime/core/markers.py` — add `get_active_with_age(conn)` that returns the
  marker dict with an additional `age_seconds` field. Keep existing
  `get_active()` unchanged for backwards compatibility.
- `scripts/statusline.sh` — replace `⚡{role}` segment with `marker: {role}
  ({age})` format. Add `?` suffix when `marker_age_seconds >= 300`. Omit
  segment entirely when no active marker.
- `hooks/session-init.sh` — when marker is >=5min old, include advisory in
  additionalContext: "Active subagent marker is Nm old and may be stale."
- `tests/runtime/test_statusline_truth.py` — NEW: unit tests for
  `get_active_with_age()` and `snapshot()` `marker_age_seconds` field.
- `tests/scenarios/test-statusline-stale-marker.sh` — NEW: scenario test
  proving stale marker gets `?` suffix and fresh marker does not.

**Tester scope:**

- Statusline snapshot includes `marker_age_seconds`
- `marker:` label replaces `⚡` in HUD output
- Stale threshold at 300 seconds produces `?` suffix
- Fresh marker below threshold has no `?`
- No active marker → segment absent
- Session-init advisory fires when stale
- Existing tests pass
- All new tests pass

###### Evaluation Contract for TKT-023

**Required checks:**

1. `runtime/core/markers.py` has `get_active_with_age(conn)` returning marker
   dict with `age_seconds` field computed from `started_at`.
2. `runtime/core/statusline.py` `snapshot()` includes `marker_age_seconds`
   (integer, seconds since marker was set; None when no active marker).
3. `scripts/statusline.sh` displays `marker: {role} ({age})` instead of
   `⚡{role}`.
4. `scripts/statusline.sh` appends `?` when `marker_age_seconds >= 300`:
   `marker: impl? (7m)`.
5. `scripts/statusline.sh` omits the marker segment entirely when no active
   marker exists.
6. `hooks/session-init.sh` includes stale-marker advisory in additionalContext
   when marker age >= 300 seconds.
7. Proof display (`proof:` segment) is unchanged.
8. Dispatch display (`next:` segment) is unchanged.
9. New unit tests for `get_active_with_age()` and snapshot age field pass.
10. New scenario test proves: fresh marker → `marker: impl (Xs)` without `?`;
    stale marker → `marker: impl? (Nm)` with `?`.
11. All existing tests pass (no regression).

**Required authority invariants:**

- `agent_markers` table remains the sole source for marker state. No new table
  or flat file introduced.
- `marker_age_seconds` is computed (not stored) — no schema change.
- The `marker:` label does not imply current tool-call actor identity. It
  explicitly means "subagent marker state."

**Forbidden shortcuts:**

- Do not change marker write paths (`set_active`, `deactivate`).
- Do not change `check-*.sh` deactivation logic.
- Do not change `subagent-start.sh` marker-set logic.
- Do not add `evaluation_state` display (deferred until schema exists on main).
- Do not modify `settings.json`.
- Do not modify agent prompts (`CLAUDE.md`, `agents/*.md`).
- Do not change the runtime schema.

**Ready-for-guardian definition:**

All 11 checks pass. Authority invariants hold. No forbidden shortcuts taken.
`git diff --stat` shows only files in the Scope Manifest.

###### Scope Manifest for TKT-023

**Allowed files:**

- `runtime/core/statusline.py` (modify: add marker_age_seconds to snapshot)
- `runtime/core/markers.py` (modify: add get_active_with_age)
- `scripts/statusline.sh` (modify: marker label, age display, stale suffix)
- `hooks/session-init.sh` (modify: stale marker advisory)
- `tests/runtime/test_statusline_truth.py` (new)
- `tests/scenarios/test-statusline-stale-marker.sh` (new)

**Required files:** All 6 must be created or modified.

**Forbidden touch points:**

- `hooks/check-*.sh`, `hooks/subagent-start.sh` (no marker lifecycle changes)
- `runtime/schemas.py` (no schema changes)
- `settings.json`
- `CLAUDE.md`, `agents/*.md`
- `MASTER_PLAN.md` (except this planning amendment)

**Expected state authorities touched:**

- MODIFIED: `runtime/core/statusline.py` — snapshot adds computed field
- MODIFIED: `runtime/core/markers.py` — new read-only helper function
- MODIFIED: `scripts/statusline.sh` — display format change
- MODIFIED: `hooks/session-init.sh` — advisory context
- UNCHANGED: `agent_markers` table schema, all write paths, all other hooks

#### Wave 5: Evaluator-State Readiness Cutover

##### TKT-024: Wave 5 Evaluator-State Readiness Cutover

- **Weight:** L
- **Gate:** approve (changes the readiness authority — user must approve before
  merge)
- **Deps:** TKT-023 (statusline truth must be landed so HUD shows correct
  marker state when the readiness authority changes)

**Problem:**

Readiness to commit/merge is currently gated on `proof_state.status ==
"verified"`, which is set when the user types "verified" in response to the
tester's evidence report (`hooks/prompt-submit.sh` lines 27-33). This is
a ceremony — the user's reply is social confirmation, not technical proof.
Guard.sh Check 10 enforces this gate; check-guardian.sh Check 6 validates it
after the fact. Both read the same proof_state table.

The evaluator prompts (Wave 1) already define EVAL_VERDICT / EVAL_TESTS_PASS /
EVAL_NEXT_ROLE / EVAL_HEAD_SHA trailers, but no runtime backing exists on main.
Readiness must become earned by evaluator verdict, not by user reply.

**Design:**

`evaluation_state` table replaces `proof_state` as the sole readiness authority.

Schema:
```
evaluation_state (
    workflow_id  TEXT PRIMARY KEY,
    status       TEXT NOT NULL DEFAULT 'idle',
    head_sha     TEXT,
    blockers     INTEGER DEFAULT 0,
    major        INTEGER DEFAULT 0,
    minor        INTEGER DEFAULT 0,
    updated_at   INTEGER NOT NULL
)
```

Statuses: idle, pending, needs_changes, ready_for_guardian, blocked_by_plan.

**Post-cutover meaning of proof_state:**

`proof_state` is deprecated compatibility state with zero enforcement effect.
It remains in the schema temporarily. Nothing gates on it. Nothing writes to it
in the evaluator-era flow. `statusline.py` stops showing it as the readiness
display — evaluator state takes that slot. Proof invalidation in `track.sh`
is removed (only evaluation invalidation remains).
All five active proof writers are removed: `prompt-submit.sh` (verified on
user reply), `subagent-start.sh` (pending on tester spawn), `guard.sh` (idle
after merge), `track.sh` (invalidation), `session-init.sh` (idle on session
start). After cutover, zero hooks write `proof_state`. The `write_proof_status`
and `rt_proof_set` functions remain in context-lib.sh and runtime-bridge.sh as
deprecated exports but have zero callers in the hook chain.
`prompt-submit.sh` stops
writing "verified" on user reply. `check-guardian.sh` validates evaluator
readiness, not proof readiness.

**Cutover sequence (atomic enough — steps 1-9):**

1. Add schema + domain + CLI + bridge + context (pure additions, no behavior
   change)
2. `post-task.sh`: implementer completion sets `evaluation_state = pending`
3. `check-tester.sh`: parse EVAL_* trailer → write evaluator verdict to
   evaluation_state (fail-closed on invalid/missing trailer)
4. `post-task.sh`: tester completion routes on evaluator verdict
   (needs_changes→implementer, ready_for_guardian→guardian,
   blocked_by_plan→planner)
5. `prompt-submit.sh`: remove proof verification on user "verified" reply —
   user prompt content no longer alters Guardian eligibility
6. `guard.sh` Check 10 + `check-guardian.sh` Check 6: switch from proof_state
   to evaluation_state gating (eval_status == "ready_for_guardian" AND
   head_sha matches current HEAD)
7. `track.sh`: replace proof invalidation with evaluation invalidation
   (ready_for_guardian→pending on source writes)
8. `subagent-start.sh`: inject evaluation state into tester context;
   `session-init.sh`: show evaluation state in session context
9. `statusline.py`: evaluator state becomes the readiness display;
   eval_status shown as the readiness segment (e.g., "eval: ready" or
   "eval: needs_changes"). proof_status removed from the readiness segment.
   If proof is shown at all, it must be visually distinct and labeled
   "legacy" or equivalent — not presented alongside eval as a co-authority.

**Implementer scope (files to create or modify):**

Modified (15):
- `runtime/schemas.py` — add evaluation_state table
- `runtime/cli.py` — add evaluation domain (get/set/list/invalidate)
- `runtime/core/statusline.py` — show eval_status as readiness; deprioritize
  proof
- `hooks/lib/runtime-bridge.sh` — add rt_eval_get, rt_eval_set, rt_eval_list,
  rt_eval_invalidate
- `hooks/context-lib.sh` — add read_evaluation_status, read_evaluation_state,
  write_evaluation_status
- `hooks/check-tester.sh` — parse EVAL_* trailer, write evaluation_state,
  fail-closed on invalid
- `hooks/check-guardian.sh` — Check 6: validate eval_status instead of
  proof_status
- `hooks/check-implementer.sh` — Check 5: replace proof-era verification
  handoff status with evaluator-era language (read evaluation_state instead of
  proof_state; report "evaluator pending" / "evaluator next" instead of
  "proof-of-work pending" / "Tester is the next required role")
- `bash_eval_readiness` policy — gate on eval_status + head_sha match (was guard.sh Check 10, migrated in INIT-PE)
- `hooks/post-task.sh` — implementer sets eval pending; tester routes on
  verdict
- `hooks/prompt-submit.sh` — remove proof verification on user "verified"
  reply
- `hooks/subagent-start.sh` — inject evaluation state into tester context
- `hooks/track.sh` — replace proof invalidation with evaluation invalidation
- `hooks/session-init.sh` — show evaluation state in context

New (8):
- `runtime/core/evaluation.py` — domain module
- `tests/runtime/test_evaluation.py` — unit tests
- `tests/scenarios/test-guard-evaluator-gate-allows.sh` — ready_for_guardian +
  SHA match allows
- `tests/scenarios/test-guard-evaluator-gate-denies.sh` — needs_changes and
  blocked_by_plan deny
- `tests/scenarios/test-guard-evaluator-sha-mismatch.sh` — SHA mismatch denies
- `tests/scenarios/test-check-tester-valid-trailer.sh` — valid trailer writes
  state
- `tests/scenarios/test-check-tester-invalid-trailer.sh` — invalid trailer
  fails closed
- `tests/scenarios/test-prompt-submit-no-verified.sh` — user "verified" no
  longer flips readiness

**Tester scope (what to verify):**

- Evaluator ready_for_guardian + matching head SHA allows guardian path
- Evaluator needs_changes denies guardian path
- Evaluator blocked_by_plan denies guardian path
- Invalid or missing EVAL_* trailer fails closed
- Stale proof_state cannot satisfy guard after cutover
- User prompt "verified" no longer satisfies guard after cutover
- Source changes after evaluator clearance invalidate readiness
- Implementer completion sets evaluation_state to pending
- check-guardian.sh validates evaluator readiness, not proof
- statusline shows evaluator state as readiness authority
- All existing tests pass

###### Evaluation Contract for TKT-024

**Required checks (each must be verified by the evaluator):**

1. `evaluation_state` table exists with correct schema (workflow_id, status,
   head_sha, blockers, major, minor, updated_at).
2. `runtime/core/evaluation.py` implements get(), set_status(), list_all(),
   invalidate_if_ready().
3. `runtime/cli.py` exposes evaluation domain (get/set/list/invalidate).
4. `hooks/lib/runtime-bridge.sh` has rt_eval_get, rt_eval_set, rt_eval_list,
   rt_eval_invalidate.
5. `hooks/context-lib.sh` has read_evaluation_status, read_evaluation_state,
   write_evaluation_status.
6. `hooks/check-tester.sh` parses EVAL_VERDICT, EVAL_TESTS_PASS,
   EVAL_NEXT_ROLE, EVAL_HEAD_SHA from tester output; writes evaluation_state
   on valid trailer; fails closed on invalid/missing.
7. `hooks/guard.sh` Check 10 denies unless eval_status ==
   "ready_for_guardian" AND head_sha matches current HEAD.
8. `hooks/check-guardian.sh` Check 6 validates eval_status instead of
   proof_status.
9. `hooks/post-task.sh` sets evaluation_state = pending on implementer
   completion; routes on evaluator verdict on tester completion.
10. `hooks/prompt-submit.sh` no longer writes proof_state on user "verified"
    reply.
11. `hooks/track.sh` invalidates evaluation ready_for_guardian→pending on
    source writes; proof invalidation removed.
12. `hooks/subagent-start.sh` injects evaluation state into tester context.
13. `hooks/session-init.sh` shows evaluation state.
14. `runtime/core/statusline.py` shows eval_status as the readiness display;
    proof_status deprioritized or removed from readiness slot.
15. Stale proof_state == "verified" cannot satisfy guard Check 10
    (regression test).
16. User prompt "verified" cannot flip readiness (regression test).
17. Source changes after evaluator clearance invalidate readiness
    (regression test).
18. No normal hook path writes proof_state after cutover — verified by
    grep: `grep -rn 'write_proof_status\|rt_proof_set' hooks/ scripts/`
    returns zero non-deprecated/non-commented matches.
19. All new unit and scenario tests pass.
20. All existing tests pass (proof-based tests updated or removed).

**Required authority invariants:**

- `evaluation_state` is the sole readiness authority for Guardian commit/merge.
- `proof_state` has zero enforcement effect — nothing gates on it.
- `check-tester.sh` is the sole writer for evaluation_state verdicts.
- `post-task.sh` is the sole writer for evaluation_state = pending.
- `track.sh` is the sole invalidator for evaluation_state.
- `prompt-submit.sh` does not write any readiness state.
- `check-implementer.sh` reports evaluator-era next-step language, not proof-era.

**Forbidden shortcuts:**

- Do not remove proof_state table (schema cleanup deferred).
- Do not rename tester agent files or settings.json hook wiring.
- Do not modify CLAUDE.md or agents/*.md.
- Do not let proof_state reads gate any Guardian operation.
- Do not let user prompt content alter evaluation_state.

**Ready-for-guardian definition:**

All 20 checks pass. Authority invariants hold. No forbidden shortcuts taken.
`git diff --stat` shows only files in the Scope Manifest.

###### Scope Manifest for TKT-024

**Allowed files:**

Modified (15):
- `runtime/schemas.py`
- `runtime/cli.py`
- `runtime/core/statusline.py`
- `hooks/lib/runtime-bridge.sh`
- `hooks/context-lib.sh`
- `hooks/check-tester.sh`
- `hooks/check-guardian.sh`
- `hooks/check-implementer.sh`
- `hooks/guard.sh`
- `hooks/post-task.sh`
- `hooks/prompt-submit.sh`
- `hooks/subagent-start.sh`
- `hooks/track.sh`
- `hooks/session-init.sh`

New (8):
- `runtime/core/evaluation.py`
- `tests/runtime/test_evaluation.py`
- `tests/scenarios/test-guard-evaluator-gate-allows.sh`
- `tests/scenarios/test-guard-evaluator-gate-denies.sh`
- `tests/scenarios/test-guard-evaluator-sha-mismatch.sh`
- `tests/scenarios/test-check-tester-valid-trailer.sh`
- `tests/scenarios/test-check-tester-invalid-trailer.sh`
- `tests/scenarios/test-prompt-submit-no-verified.sh`

**Required files:** All 23 must be created or modified.

**Forbidden touch points:**

- `settings.json`
- `CLAUDE.md`, `agents/*.md`
- `MASTER_PLAN.md` (except this amendment)
- `runtime/core/proof.py` (not removed in this wave)

**Expected state authorities touched:**

- NEW: `evaluation_state` table — sole readiness authority
- MODIFIED: `guard.sh` Check 10 — reads evaluation, not proof
- MODIFIED: `check-guardian.sh` Check 6 — validates evaluation, not proof
- MODIFIED: `prompt-submit.sh` — stops writing proof on user reply
- MODIFIED: `track.sh` — evaluation invalidation replaces proof invalidation
- MODIFIED: `post-task.sh` — sets eval pending + routes on verdict
- MODIFIED: `check-tester.sh` — sole evaluator verdict writer
- DEPRECATED: `proof_state` — zero enforcement effect after cutover

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
    delegation to `hooks/lib/write-policy.sh` (superseded by INIT-PE: policy
    engine now owns all enforcement; write-policy.sh, bash-policy.sh, guard.sh
    deleted). `hooks/pre-bash.sh` consolidates `guard.sh` into a single
    entrypoint (now a thin adapter calling `cc-policy evaluate`).
  - `TKT-009`: `hooks/post-task.sh` dispatch emission. Detects completing agent
    role, routes via completion records (DEC-WS6-001: dispatch_queue enqueue
    removed). Dispatch queue helpers deleted in INIT-PE.
    (Note: `post-task.sh` was created by TKT-009 but was not wired into
    `settings.json` SubagentStop hooks until TKT-016 in Wave 3e.)
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
