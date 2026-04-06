# MASTER_PLAN.md

Status: active
Created: 2026-03-23
Last updated: 2026-04-06 (W-CDX-3 revised per Codex review findings: connect-phase retry, clean-close detection, replay safety)

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
  in [runtime/core/policies/](runtime/core/policies/) via the Python policy
  engine (`cc-policy evaluate`). Shell hooks are thin JSON adapters.
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


### Policy engine decisions

- `2026-04-03 — DEC-PE-001` Migration order: write-path first (PE-W2), then
  bash-path (PE-W3). Write-path is lower-risk with 7 simpler policies; bash-path
  has 13 checks with complex context dependencies (lease, evaluation, approval).
- `2026-04-03 — DEC-PE-002` Engine shape: registered Python callables with
  priority ordering, first-deny-wins. Each policy is `(PolicyRequest) ->
  PolicyDecision | None`. None means no opinion. Deny stops evaluation. Allow is
  advisory. Priority is integer (lower first). Event-type filtering skips
  irrelevant policies without calling them.
- `2026-04-03 — DEC-PE-003` Dispatch migration is Wave 4, parallel with
  PreToolUse migration (W2/W3). Dispatch emission and lifecycle are
  PostToolUse/SubagentStop concerns sharing PolicyContext but not evaluate().

### Test baseline reconciliation decisions

- `2026-04-03 — DEC-REBASE-001` Fix stale test expectations rather than
  adjusting enforcement. The 4 post-INIT-PE failures are test-truth
  mismatches (tests expect pre-PE behavior), not policy bugs. `doc_gate`
  and `dispatch_status` derivation are correct per their contracts.
- `2026-04-03 — DEC-REBASE-002` REBASE-W2 (acceptance lint gate) is
  optional. The drift pattern is real but the 4 failures were caught during
  review and are easily diagnosed. Defer lint gate to user judgment.

### Test gap coverage decisions

- `2026-04-05 — DEC-TESTGAP-001` auto-review.sh test strategy: source
  individual functions where possible, run end-to-end via subprocess with
  crafted JSON on stdin for the full hook path. Sourcing is preferred
  because it allows testing decompose_command and classify_command in
  isolation without the log.sh HOOK_INPUT machinery.
- `2026-04-05 — DEC-TESTGAP-002` stop-assessment false-positive regression
  tests extend the existing test-stop-assessment.sh (Cases D, E, F) rather
  than creating a new file, because the existing helper infrastructure
  (run_hook_chain, count_events, temp git setup) is reusable and the cases
  are logically contiguous with A-C.

### Identity convergence decisions

- `2026-04-05 — DEC-CONV-001` `normalize_path()` in `policy_utils.py` is
  the single canonical path normalizer. Uses `os.path.realpath()`. No ad-hoc
  inline normalization elsewhere. Shell callers use the Python bridge for
  guaranteed consistency or `realpath`/`readlink -f` where available.
- `2026-04-05 — DEC-CONV-002` Only dispatch-significant roles (planner,
  implementer, tester, guardian) create agent markers. `get_active()` accepts
  `project_root` and `workflow_id` scoping. Global newest-marker fallback is
  removed. Marker schema adds `project_root` column; existing `workflow_id`
  column (already in DDL) is populated on dispatch-significant marker writes.
  One-time cleanup deactivates existing lightweight active markers.
- `2026-04-05 — DEC-CONV-003` Lease-first workflow identity enforced
  everywhere. `track.sh` and `build_context()` already converged (WS1).
  Remaining gap: `context-lib.sh` helpers and 3 callers in
  `check-guardian.sh`, `check-implementer.sh`, `session-init.sh` that pass
  no workflow_id to `read_evaluation_status()`. `get_workflow_binding()`
  must check lease before branch derivation. `bind_workflow()` gets
  DELETE-before-INSERT for stale row prevention. Historical row cleanup
  deferred (no schema field, no merge rule).

### Auto-dispatch decisions

- `2026-04-05 — DEC-AD-001` Auto-dispatch signal is an explicit `auto_dispatch`
  boolean in the dispatch_engine result dict, not implicit from `next_role`. This
  makes the decision inspectable and testable independently of routing.
  Interrupted agents, error states, and Codex BLOCK verdicts set it to false.
- `2026-04-05 — DEC-AD-002` The Codex stop-review gate communicates with
  dispatch_engine via the runtime `events` table (event type
  `codex_stop_review`), not via hookSpecificOutput merging or flat files. This
  preserves dispatch_engine as the sole auto_dispatch decision authority.
- `2026-04-05 — DEC-AD-003` The Codex gate at SubagentStop is opt-in via the
  existing `stopReviewGate` config in the Codex plugin state. When disabled,
  auto-dispatch proceeds without quality review. When the gate is unavailable
  (not set up, errors), dispatch_engine treats it as ALLOW (fail-open for
  quality, fail-closed for safety).
- `2026-04-05 — DEC-AD-004` Auto-dispatch fires for tester needs_changes and
  blocked_by_plan routes (back to implementer and planner respectively). The
  user does not need to approve rework — only new work, terminal states, and
  high-risk operations require user attention.

### Codex plugin concurrency decisions

- `2026-04-05 — DEC-CDX-001` Atomic state writes for Codex plugin use O_EXCL
  lockfile + write-tmp-rename, not SQLite. The plugin's state.json is a
  marketplace plugin artifact independent of the core runtime SQLite backend.
  Adding SQLite here would create a second DB authority. The lockfile approach
  is Node.js stdlib-only and sufficient for the low-contention write pattern
  (2-3 concurrent writers max).
- `2026-04-05 — DEC-CDX-002` Stale task reaping is lazy (on read), not periodic.
  `reapStaleJobs()` runs on every `listJobs()` call, checking PID liveness via
  `process.kill(pid, 0)`. This avoids background timers and ensures liveness is
  always fresh when queried. Cost: one syscall per running job per read.
- `2026-04-05 — DEC-CDX-003` Broker multi-socket support is deferred.
  `withAppServer()` already falls back from broker to direct client on
  BROKER_BUSY_RPC_CODE. The direct-client path spawns a separate
  `codex app-server` process, which is sufficient for 2-3 concurrent tasks.
  Broker redesign is high-effort/low-value given the working fallback.
- `2026-04-05 — DEC-CDX-004` `interruptAppServerTurn()` is not modified for
  broker fallback. It uses its own connection logic (not `withAppServer()`)
  and returns `{ interrupted: false }` on failure. This is correct: if the
  broker dies, the task running on its app-server is already dead, so
  connecting direct to interrupt it would be pointless. The function is
  best-effort by design.
- `2026-04-05 — DEC-CDX-005` `resolveLatestTrackedTaskThread()` task guard is
  not relaxed. After W-CDX-2's transparent reaping, dead-PID tasks are marked
  "failed" before the guard runs, so they no longer block new launches. The
  guard is only invoked for `--resume-last` task launches (not reviews). It
  correctly prevents resuming when a genuinely alive task exists.
- `2026-04-06 — DEC-CDX-006` Retry detection includes message-based matching
  for clean-close errors. `BrokerCodexAppServerClient.handleExit()` (app-server.mjs:162-175)
  rejects pending promises with `new Error("codex app-server connection closed.")`
  when the broker socket closes gracefully (no OS-level error code). This error
  has no `.code` property, so code-only matching misses it. The retry set adds
  a message-based check: `error.message?.includes("connection closed")`.
- `2026-04-06 — DEC-CDX-007` Replaying `fn(client)` on direct fallback is safe
  because the replay targets a fresh direct-process client that has no
  relationship to the dead broker session. `thread/start` creates a new thread
  (not idempotent), but this is correct: the broker-side thread is dead with the
  broker, so a new thread on the direct client is the desired outcome.
  `review/start` and `turn/start` similarly create new server-side state on the
  fresh client. No orphaned resources accumulate on the broker side because the
  broker is dead. The only cost is a wasted thread allocation if the broker dies
  after `thread/start` succeeds but before `turn/start` -- this is acceptable
  for a resilience path that fires on transport failure.

### Observatory decisions

- `2026-04-06 — DEC-OBS-001` Native rebuild over pro-fork port. The
  claude-config-pro observatory used filesystem-based traces (59% orphan rate,
  required rebuild_index, corrupt manifests crashed jq) and 1,000+ lines of
  bash pipeline. Our fork already has SQLite trace tables, a policy engine
  runtime, and structured completion records. Building natively on state.db
  eliminates the filesystem trace store, the JSONL time series, and the
  snapshot.sh transformation layer. Analysis is SQL, not jq-over-JSONL.
- `2026-04-06 — DEC-OBS-002` Observatory tables in state.db, not sidecar-owned
  storage. `obs_suggestions` and `obs_metrics` are new tables in the canonical
  schema (schemas.py). The observatory writes to these tables via the runtime
  domain module, not by maintaining its own database. This keeps the single-DB
  architecture intact and avoids split-authority between a sidecar DB and the
  canonical runtime.
- `2026-04-06 — DEC-OBS-003` Hook emission is additive, not new hooks. Each
  existing hook gains 1-3 `rt_event_emit` or `rt_obs_metric` calls. No new
  settings.json hook entries, no new hook files. This preserves the thin-hook
  architecture (DEC-HOOK-001 through DEC-HOOK-004) and avoids hook-chain bloat.
- `2026-04-06 — DEC-OBS-004` The observatory SKILL.md is the synthesis layer.
  Raw SQL query results are structured data; the LLM interprets patterns,
  correlates trends, and generates actionable suggestions. This avoids encoding
  pattern-matching heuristics in Python that would inevitably become stale.
  The skill invokes analysis queries, presents results, and asks the LLM to
  reason about them.
- `2026-04-06 — DEC-OBS-005` Convergence tracking preserves the pro fork's
  best feature: closed-loop "did the fix actually help?" tracking. Each
  suggestion has a lifecycle (proposed -> accepted/rejected/deferred) and
  accepted suggestions are measured against the metric they claimed to improve.
  If the metric did not improve within N sessions, the suggestion is flagged
  as ineffective.

### Behavioral evaluation decisions

- `2026-04-06 — DEC-EVAL-010` Behavioral eval framework as a config-system
  feature, not a standalone tool. The framework (runner, scorer, metrics,
  report) lives in `~/.claude` and ships with the config system. Project-
  specific scenarios are defined per-project under `evals/scenarios/`. Metrics
  are project-scoped in `.claude/eval_results.db`. This makes behavioral eval
  available to every project using the config system without external tooling.
- `2026-04-06 — DEC-EVAL-011` Two-mode operation: deterministic (offline) and
  live (agent-in-the-loop). Deterministic scenarios validate gate mechanics
  (policy decisions, trailer parsing, scope compliance) using the same
  synthetic-payload approach as existing scenario tests. Live scenarios invoke
  the tester agent against frozen fixtures and score its judgment. Deterministic
  mode requires no Claude runtime; live mode requires it. Both modes share the
  same scenario definition format and metrics store.
- `2026-04-06 — DEC-EVAL-012` Scorer uses ground-truth matching for
  deterministic scenarios and rubric-based heuristic matching for judgment
  scenarios. LLM-as-judge is deferred to avoid the meta-evaluation problem in
  v1. Evidence quality is scored by keyword/phrase presence against expected
  evidence lists, not by LLM evaluation.
- `2026-04-06 — DEC-EVAL-013` Eval results stored in a separate
  `eval_results.db` database, not in the main `state.db`. The eval framework
  is an observer of the system, not a participant in it. Storing eval data in
  state.db would violate the separation between the system under test and the
  testing infrastructure. The eval DB uses the same SQLite conventions (WAL
  mode, ensure_schema idempotency) but has its own schema and lifecycle.
- `2026-04-06 — DEC-EVAL-014` CLI integration via `cc-policy eval` subcommand
  group. `cc-policy eval run` executes scenarios. `cc-policy eval report`
  generates human-readable reports. `cc-policy eval list` shows available
  scenarios. This follows the existing pattern of `cc-policy <domain> <action>`
  used throughout the runtime.
- `2026-04-06 — DEC-EVAL-015` Frozen fixtures are git-committed directories
  containing pre-built worktree state: source files, Evaluation Contracts,
  expected verdicts, and expected evidence. They live in `evals/fixtures/` in
  the config repo for universal scenarios. Project-specific fixtures live in
  the project's `evals/fixtures/`. No fixture modification at runtime; the
  runner copies fixtures to a temp directory before execution.
- `2026-04-06 — DEC-EVAL-016` The framework does NOT use the full
  planner->implementer->tester->guardian cycle for eval runs. Eval scenarios
  target the tester phase only: a frozen implementation + Evaluation Contract
  is presented to the tester agent, and the tester's verdict is scored. This
  eliminates the combinatorial explosion of testing the full 4-agent chain and
  focuses on the judgment gap that actually exists (Layer 2).

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


### INIT-TESTGAP: Test Gap Coverage (auto-review.sh + stop-assessment false-positive regressions)

- **Status:** planned
- **Goal:** Eliminate two high-priority test coverage gaps identified during
  audit: (1) auto-review.sh has 842 lines of command classification logic
  with zero test coverage, and (2) the stop-assessment heuristic
  (DEC-STOP-ASSESS-001) has no persistent false-positive regression tests.
- **Scope:** Tests only -- no source code changes. Two work items: create
  test-auto-review.sh (new file) and extend test-stop-assessment.sh
  (append Cases D, E, F).
- **Exit:** `bash tests/scenarios/test-auto-review.sh` passes with all
  assertions green. `bash tests/scenarios/test-stop-assessment.sh` passes
  with Cases A-F all green. No source files modified.
- **Dependencies:** None (tests-only, no architectural prerequisites)

#### Problem Statement

The hook chain contains two untested critical paths:

1. `hooks/auto-review.sh` is an 842-line three-tier command classification
   engine. It handles compound command decomposition (`&&`, `||`, `;`, `|`),
   quote-aware splitting, command substitution recursion, and per-tool
   analyzers for git, npm, docker, curl, and more. A multi-line parsing bug
   (decompose_command failed to track quotes across newlines) was already
   found and fixed in-session. Without tests, regressions are invisible.

2. `hooks/check-implementer.sh` Check 7 implements a stop-assessment
   heuristic that scans the last ~500 chars of agent responses for
   future-tense patterns, cross-checked against test evidence. Live probes
   confirmed false-positive suppression works (response with "Let me check"
   body BUT also containing "PASS: 5 tests passed" correctly suppresses the
   stop_assessment event). These probes are ephemeral -- no test file
   captures them for regression protection.

#### Wave Decomposition

**Wave 1 (parallel -- no dependencies between items):**

##### W1-A: test-auto-review.sh (Weight: M, Gate: review, Deps: none)

Create `tests/scenarios/test-auto-review.sh` exercising the production-
critical paths of `hooks/auto-review.sh`.

**Function-level tests (source the hook functions):**

The test file sources `hooks/auto-review.sh` functions by extracting them
or by sourcing the file with the main execution path disabled (set
COMMAND="" before the main block, or source only the function definitions).
Strategy: extract the functions (lines 37-520) into a sourceable block via
a test preamble that defines stubs for `read_input`, `get_field`, and
`log.sh` dependencies, then sources the hook. This avoids executing the
main block (lines 833-842) which requires stdin JSON.

**Test matrix (assertions):**

1. `decompose_command` -- multi-line collapse:
   - Input: `printf '%s' "line1\nline2"` (contains literal newline)
   - Assert: output is a single segment (newline collapsed to space)

2. `decompose_command` -- `&&` splitting with quote preservation:
   - Input: `echo "hello && world" && ls`
   - Assert: two segments: `echo "hello && world"` and ` ls`

3. `decompose_command` -- `||` splitting:
   - Input: `false || echo fallback`
   - Assert: two segments: `false ` and ` echo fallback`

4. `decompose_command` -- `;` splitting:
   - Input: `echo a; echo b`
   - Assert: two segments: `echo a` and ` echo b`

5. `decompose_command` -- semicolon inside quotes preserved:
   - Input: `echo "a;b"`
   - Assert: one segment (semicolon not treated as separator)

6. `classify_command` -- Tier 1 (always safe):
   - Commands: `ls`, `cat`, `echo`, `grep`, `wc`, `sort`
   - Assert: each returns `1`

7. `classify_command` -- Tier 2 (behavior-dependent):
   - Commands: `git`, `npm`, `python3`, `docker`, `curl`, `sed`
   - Assert: each returns `2`

8. `classify_command` -- Tier 3 (always risky):
   - Commands: `rm`, `sudo`, `kill`, `bash`, `ssh`, `eval`
   - Assert: each returns `3`

9. `classify_command` -- Unknown command:
   - Command: `nonexistent_tool_xyz`
   - Assert: returns `0` (unknown)

10. `is_safe` -- Tier 1 command is safe:
    - Input: `ls -la /tmp`
    - Assert: returns 0 (safe)

11. `is_safe` -- Tier 3 command is risky:
    - Input: `rm -rf /foo`
    - Assert: returns 1 (risky), RISK_REASON non-empty

12. `is_safe` -- pipe safety (all safe):
    - Input: `cat file.txt | grep pattern | wc -l`
    - Assert: returns 0 (safe)

13. `is_safe` -- pipe safety (one risky segment):
    - Input: `cat file.txt | rm dangerous`
    - Assert: returns 1 (risky)

14. `analyze_tier2` for git -- safe subcommands:
    - Input: `analyze_git "status"`, `analyze_git "log --oneline"`,
      `analyze_git "diff HEAD"`
    - Assert: each returns 0

15. `analyze_tier2` for git -- risky flags:
    - Input: `analyze_git "push --force"`, `analyze_git "reset --hard"`
    - Assert: each returns 1, RISK_REASON set

16. `analyze_tier2` for python3/node -- always allowed:
    - Input: `analyze_tier2 "python3" "script.py" 0`
    - Assert: returns 0

17. `is_safe` -- heredoc detected as risky:
    - Input: `cat << EOF`
    - Assert: returns 1, RISK_REASON mentions heredoc

18. `is_safe` -- command substitution recursion:
    - Input: `echo $(ls /tmp)`
    - Assert: returns 0 (ls is safe inside substitution)

19. `is_safe` -- risky command inside substitution:
    - Input: `echo $(rm -rf /foo)`
    - Assert: returns 1

**End-to-end tests (subprocess invocation):**

20. Hook invoked with safe command JSON:
    - Stdin: `{"tool_input": {"command": "ls -la"}}`
    - Assert: stdout contains `"permissionDecision": "allow"`

21. Hook invoked with risky command JSON:
    - Stdin: `{"tool_input": {"command": "rm -rf /"}}`
    - Assert: stdout contains `"additionalContext"` with risk description

22. Hook invoked with compound safe command:
    - Stdin: `{"tool_input": {"command": "git status && git log --oneline -5"}}`
    - Assert: stdout contains `"permissionDecision": "allow"`

23. Hook invoked with compound mixed command:
    - Stdin: `{"tool_input": {"command": "ls -la && rm -rf /tmp/test"}}`
    - Assert: stdout contains `"additionalContext"` (not allow)

**Integration considerations:**
- End-to-end tests must provide a real `log.sh` path. The hook sources
  `log.sh` relative to its own directory (`$(dirname "$0")/log.sh`), so
  running the hook as a subprocess from `tests/scenarios/` requires the
  hook to be invoked at its actual path (`hooks/auto-review.sh`).
- The function-level tests stub out `log.sh` dependencies (read_input,
  get_field) since those require stdin JSON. Only the bare functions
  (decompose_command, classify_command, is_safe, analyze_tier2, etc.) are
  exercised.

##### W1-B: test-stop-assessment.sh Cases D, E, F (Weight: S, Gate: review, Deps: none)

Extend `tests/scenarios/test-stop-assessment.sh` with three new cases that
lock down the false-positive suppression boundary.

**Test matrix (assertions):**

Case D: Future-tense body with test evidence present (false-positive suppression)
- Response: "I reviewed the task. Let me check the existing implementation.
  PASS: 5 tests passed. All checks green."
- Assert: `stop_assessment` event count = 0 (suppressed by test evidence)
- Assert: `agent_complete` event count >= 1
- Assert: `agent_stopped` event count = 0
- Assert: no WARNING in hookSpecificOutput.additionalContext

Case E: Response ends with completion confirmation, no future-tense trailing
- Response: "Implementation complete. All tests pass. Ready for tester review."
- Assert: `stop_assessment` event count = 0
- Assert: `agent_complete` event count >= 1
- Assert: `agent_stopped` event count = 0

Case F: Very short response (edge case)
- Response: "Done."
- Assert: `stop_assessment` event count = 0
- Assert: `agent_complete` event count >= 1
- Assert: `agent_stopped` event count = 0

**Integration considerations:**
- Reuse the existing `run_hook_chain` helper and `count_events` helper.
- Each case gets its own tmp git dir and DB (same pattern as Cases A-C)
  to avoid cross-contamination.
- The response for Case D is carefully constructed: the future-tense
  pattern ("Let me check") appears in the last 500 chars, but test
  evidence ("PASS: 5 tests passed") also appears. The heuristic must
  detect the future-tense pattern, then suppress via test evidence
  cross-check.

#### Evaluation Contract

**Required tests:**
- `bash tests/scenarios/test-auto-review.sh` exits 0 with all PASS lines
- `bash tests/scenarios/test-stop-assessment.sh` exits 0 with Cases A-F
  all PASS
- Each test is independently runnable (no test-runner.sh dependency)

**Required real-path checks:**
- test-auto-review.sh end-to-end tests must invoke the actual
  `hooks/auto-review.sh` hook (not a copy), confirming the hook's stdin
  JSON contract (`tool_input.command`) and stdout JSON contract
  (`permissionDecision` / `additionalContext`) are exercised against the
  real file
- test-stop-assessment.sh Cases D-F must invoke the actual
  `hooks/check-implementer.sh` and `hooks/post-task.sh` hooks (same as
  Cases A-C), confirming the false-positive suppression path is exercised
  against the real code

**Required authority invariants:**
- No source files in `hooks/` are modified
- No runtime files in `runtime/` are modified
- No `settings.json` changes
- The test files do not write to any production DB path (each test uses its
  own temp DB via `CLAUDE_POLICY_DB`)

**Required integration points:**
- test-auto-review.sh end-to-end tests must confirm `hooks/log.sh` is
  correctly sourced by the hook (the hook fails if log.sh is unavailable)
- test-stop-assessment.sh Cases D-F must confirm the check-implementer ->
  post-task hook chain works identically to Cases A-C (same helpers, same
  env vars)

**Forbidden shortcuts:**
- Do not mock `decompose_command`, `classify_command`, or `is_safe` -- test
  the real implementations
- Do not modify any hook source to make it "testable"
- Do not use `eval` to construct test commands
- Do not skip the end-to-end tests (assertions 20-23) -- function-level
  tests alone are insufficient because they bypass the hook's input parsing
  and output formatting

**Ready-for-guardian definition:**
- Both test files execute independently with exit code 0
- All individual assertions report PASS (no FAIL lines in output)
- No source files outside `tests/scenarios/` are modified
- The implementer provides the full test output as evidence

#### Scope Manifest

**Allowed files/directories:**
- `tests/scenarios/test-auto-review.sh` (create)
- `tests/scenarios/test-stop-assessment.sh` (modify -- append only)
- `tmp/` (test temp files, cleaned by trap)

**Required files/directories:**
- `tests/scenarios/test-auto-review.sh` must be created
- `tests/scenarios/test-stop-assessment.sh` must be modified (Cases D, E, F
  appended before the Results block)

**Forbidden touch points:**
- `hooks/auto-review.sh` -- read only, do not modify
- `hooks/check-implementer.sh` -- read only, do not modify
- `hooks/post-task.sh` -- read only, do not modify
- `hooks/log.sh` -- read only, do not modify
- `hooks/lib/*` -- do not modify
- `runtime/*` -- do not modify
- `settings.json` -- do not modify
- `MASTER_PLAN.md` -- do not modify (planner-only)

**Expected state authorities touched:**
- None (test-only work; each test creates its own ephemeral SQLite DB
  in tmp/ and destroys it on exit)

### INIT-CONV: Identity Convergence

- **Status:** in progress
- **Blocked by:** none (independent of INIT-003/004/PE/REBASE/TESTGAP)
- **Problem:** Storage authority is singular (SQLite), but identity authority
  is not. Three dimensions — path, agent, workflow — derive values through
  multiple incompatible paths, causing live enforcement bugs and state
  pollution. The Python policy engine and completion-driven router are the
  right core. The remaining work is to remove identity drift, not to add
  another layer.
- **Evidence:** `test-guard-db-scoping.sh` currently fails (path
  normalization). Live marker list accumulates stale Explore/general-purpose
  entries. Live DB shows duplicate workflow forms for the same conceptual
  work. Statusline shows contradictory proof/eval readiness.
- **Handoff:** `docs/HANDOFF_2026-04-05_SYSTEM_EVAL.md`
- **North star:** One authority per operational fact: one canonical
  `project_root`, one canonical `workflow_id`, one canonical active-agent
  identity, one readiness authority, one dispatch routing authority, one
  lifecycle authority for spawn and stop.

#### Explicit non-goals

- Shell-to-Python lifecycle migration (strategic, deferred)
- `cli.py` decomposition into subcommand modules (maintenance)
- New features or capabilities
- Schema version migration framework
- `dispatch_queue` table removal (separate cleanup issue unless proven
  trivial by grep/test audit)

#### Dependency graph

```
W-CONV-1 (Path Identity)
    │
    ├──→ W-CONV-2 (Marker Authority)
    │         │
    │         └──→ W-CONV-3 (Workflow Identity)
    │                   │
    │                   ├──→ W-CONV-4 (Readiness Surface)  ─┐
    │                   │                                    ├──→ W-CONV-6 (Dead Surface Deletion)
    │                   └──→ W-CONV-5 (Completion Contracts)─┤
    │                              │                         │
    │                              └──→ W-CONV-7 (Orch Trust)┘
```

W-CONV-4 and W-CONV-5 can execute in parallel after W-CONV-3.
W-CONV-6 requires both W-CONV-4 and W-CONV-5.
W-CONV-7 depends on W-CONV-5 only (prompt/docs, no code).

#### Required retest set (every packet)

```bash
python3 -m pytest tests/runtime/policies/test_bash_adapter_regressions.py -q
bash tests/scenarios/test-guard-db-scoping.sh
bash tests/scenarios/test-marker-lifecycle.sh
bash tests/scenarios/test-lease-workflow-id-authority.sh
bash tests/scenarios/test-routing-tester-completion.sh
bash tests/scenarios/test-routing-guardian-completion.sh
```

Full convergence retest (after W-CONV-6):

```bash
python3 -m pytest tests/runtime/test_policy_engine.py tests/runtime/test_dispatch_engine.py tests/runtime/test_dispatch.py tests/runtime/test_hook_bridge.py tests/runtime/test_evaluation.py tests/runtime/test_leases.py tests/runtime/test_markers.py tests/runtime/test_statusline_truth.py tests/runtime/test_cli.py tests/runtime/test_config_scoping.py tests/runtime/policies -q
```

#### W-CONV-1: Path Identity Convergence

- **Status:** complete (merged 43e26c6, 2026-04-05)
- **Issue:** #4
- **Decision:** DEC-CONV-001

**Problem:** `detect_project_root()` in `policy_utils.py` returns raw paths.
`~/.claude` is a symlink that git canonicalizes to the realpath.
`/tmp` canonicalizes to `/private/tmp` on macOS. `test_state` is keyed by
exact `project_root` string. Result: rows written via one path form become
invisible when queried via another. `test-guard-db-scoping.sh` currently
fails because of this.

**Approach:** Add `normalize_path()` to `policy_utils.py` using
`os.path.realpath()`. Apply at every persist and query boundary for
`project_root` and `worktree_path`. Shell callers use the Python bridge or
`realpath`/`readlink -f`.

**Callsites that must normalize (Python — persist/query project_root):**
- `runtime/core/policy_utils.py:detect_project_root()` — normalize return
- `runtime/core/policy_engine.py:build_context()` — project_root parameter
- `runtime/core/test_state.py:set_status()` — persists project_root as key
- `runtime/core/test_state.py:get_status()` — queries by project_root
- `runtime/core/test_state.py:check_pass()` — queries by project_root
- `runtime/cli.py:_handle_evaluate()` — resolves target_cwd to project_root

**Callsites that must normalize (Python — persist/query worktree_path):**
- `runtime/core/workflows.py:bind_workflow()` — persists worktree_path
- `runtime/core/leases.py` — worktree_path in lease records
- `runtime/core/policy_engine.py:build_context()` — lease lookup
- `runtime/core/dispatch_engine.py` — issues leases with worktree_path

**Callsites that must normalize (Shell — forwarding to Python):**
- `hooks/pre-bash.sh` — TARGET_CWD forwarded to evaluate payload
- `hooks/pre-write.sh` — _PROJECT_ROOT from git rev-parse
- `hooks/track.sh` — PROJECT_ROOT for eval invalidation
- `hooks/subagent-start.sh` — PROJECT_ROOT for marker and lease binding
- `hooks/context-lib.sh:detect_project_root()` — the shell version
- All `check-*.sh` hooks — PROJECT_ROOT for runtime lookups

**Evaluation Contract:**
- `bash tests/scenarios/test-guard-db-scoping.sh` MUST PASS (currently fails)
- `python3 -m pytest tests/runtime/policies/test_bash_adapter_regressions.py -q`
- `python3 -m pytest tests/runtime/test_policy_engine.py tests/runtime/test_config_scoping.py -q`
- New test: symlink-path write + realpath read returns same row
- New test: `/tmp/` write + `/private/tmp/` query matches
- `normalize_path()` exists in `policy_utils.py` as the sole normalizer
- No module persists raw paths while another persists realpaths

**Scope Manifest:**
- *Allowed:* `runtime/core/policy_utils.py`, `runtime/core/policy_engine.py`,
  `runtime/core/test_state.py`, `runtime/cli.py`, `runtime/core/workflows.py`,
  `runtime/core/leases.py`, `runtime/core/dispatch_engine.py`,
  `hooks/pre-bash.sh`, `hooks/pre-write.sh`, `hooks/track.sh`,
  `hooks/subagent-start.sh`, `hooks/context-lib.sh`, `hooks/check-*.sh`,
  `tests/scenarios/test-guard-db-scoping.sh`, test files under `tests/`
- *Required:* `runtime/core/policy_utils.py` (add normalize_path),
  `runtime/core/policy_engine.py` (normalize in build_context),
  `runtime/core/test_state.py` (normalize project_root in set/get)
- *Forbidden:* `runtime/schemas.py`, `settings.json`, `MASTER_PLAN.md`,
  `agents/*.md`, `CLAUDE.md`

**Expected state authorities touched:**
- `test_state` table (project_root key normalization)
- `evaluation_state` table (workflow_id derivation path change)
- `dispatch_leases` table (worktree_path normalization)
- `workflow_bindings` table (worktree_path normalization)

#### W-CONV-2: Marker Authority Repair

- **Status:** complete (merged 7a6d56a, 2026-04-05)
- **Issue:** #2
- **Decision:** DEC-CONV-002
- **Depends on:** W-CONV-1 (path identity must be stable before scoping
  markers by project)

**Problem:** `SubagentStart` registers markers for all agent types
(`subagent-start.sh:49`). `SubagentStop` matchers in `settings.json` only
cover planner|Plan, implementer, tester, guardian. `get_active()` in
`markers.py:52` returns the globally newest active marker with no project or
workflow scoping. Live state has accumulated stale Explore/general-purpose
markers that contaminate actor-role truth and statusline.

**Approach:**
1. Filter: Only dispatch-significant roles (planner, implementer, tester,
   guardian) create markers in `subagent-start.sh`.
2. Schema: Add `project_root` column to `agent_markers` via migration in
   `ensure_schema()`. Populate `project_root` (using `normalize_path()` from
   W-CONV-1) and `workflow_id` (column already exists in DDL) on
   dispatch-significant marker writes.
3. Scope: `get_active()` accepts optional `project_root` and `workflow_id`
   parameters. When provided, WHERE clause filters by them. Global unscoped
   fallback is removed.
4. Cleanup: One-time deactivation of existing active lightweight markers
   (role NOT IN planner/implementer/tester/guardian) in `ensure_schema()`
   migration.

**Evaluation Contract:**
- `bash tests/scenarios/test-marker-lifecycle.sh`
- `python3 -m pytest tests/runtime/test_markers.py -q`
- `python3 -m pytest tests/runtime/test_policy_engine.py -q`
- New test: spawning Explore agent creates NO marker row
- New test: with tester active in workflow A and implementer active in
  workflow B, `get_active(project_root=X, workflow_id=A)` returns tester
- `get_active()` in `policy_engine.py build_context()` uses scoped query
- Active marker list does not accumulate lightweight roles

**Scope Manifest:**
- *Allowed:* `hooks/subagent-start.sh`, `runtime/core/markers.py`,
  `runtime/core/lifecycle.py`, `runtime/core/policy_engine.py`,
  `runtime/core/statusline.py`, `runtime/schemas.py` (migration only),
  test files under `tests/`
- *Required:* `hooks/subagent-start.sh` (filter lightweight types),
  `runtime/core/markers.py` (scoped get_active, add project_root param),
  `runtime/core/policy_engine.py` (use scoped marker query),
  `runtime/schemas.py` (add project_root column migration)
- *Forbidden:* `settings.json`, `MASTER_PLAN.md`, `agents/*.md`

**Expected state authorities touched:**
- `agent_markers` table (schema change: project_root column; write
  filtering; scoped reads; one-time cleanup migration)

#### W-CONV-3: Workflow Identity Convergence

- **Status:** complete (merged c01c986, 2026-04-05)
- **Issue:** #3
- **Decision:** DEC-CONV-003
- **Depends on:** W-CONV-1 (path normalization), W-CONV-2 (marker scoping
  provides clean actor context for workflow resolution)

**Problem (revised 2026-04-05):** The original problem statement described
`track.sh` and `build_context()` as using branch-derived identity without
lease checks. Both were fixed in WS1 and are now lease-first. The **actual
remaining gap** is in `context-lib.sh` helper functions and their callers:

1. **`get_workflow_binding()`** (context-lib.sh:399) unconditionally derives
   `WORKFLOW_ID` from `current_workflow_id()` (branch-based). Never checks
   for an active lease.
2. **Evaluation/proof helpers** (`read_evaluation_status`,
   `read_evaluation_state`, `write_evaluation_status`) accept optional
   `workflow_id` but fall back to `current_workflow_id()` when callers omit
   it. Three callers omit it: `check-guardian.sh:189`,
   `check-implementer.sh:114`, `session-init.sh:117`.
3. **`bind_workflow()` stale row accumulation** — `workflow_bindings` has
   `workflow_id` as PRIMARY KEY but no UNIQUE on `worktree_path`. When a
   worktree gets a new workflow_id, the old binding persists.

**Already converged (not bugs):**
- `track.sh:67-72` — lease-first via `lease_context()` (DEC-WS1-TRACK-001)
- `build_context()` at `policy_engine.py:424` — prefers lease workflow_id,
  branch-fallback only when no lease (DEC-PE-W3-CTX-001)
- `check-tester.sh:118-130` — lease-first via `lease_context()`
- `check-guardian.sh:69-80` — lease-first for completion/eval reset

**Approach:**
1. **context-lib.sh helper convergence:** Modify `get_workflow_binding()` to
   check `lease_context()` first. Modify evaluation/proof helpers to attempt
   `lease_context()` when no explicit `workflow_id` is passed. Branch-derived
   `current_workflow_id()` remains fallback when no lease exists.
2. **Caller fix:** Where callers already have a lease-derived workflow_id,
   pass it explicitly: `check-guardian.sh:189` (pass `_GD_WF_ID`),
   `check-implementer.sh:114` (add lease resolution),
   `session-init.sh:117` (add lease resolution).
3. **bind_workflow duplicate prevention:** DELETE prior bindings for the same
   `worktree_path` before INSERT in `bind_workflow()`. At most one binding
   per physical worktree.
4. **Historical row cleanup — DEFERRED.** No `status`/`historical` field
   exists in schema, schema changes forbidden, no deterministic merge rule.
   Prevention fix in step 3 stops the bleeding; legacy cleanup is a separate
   follow-up.

**Evaluation Contract:**
- `bash tests/scenarios/test-lease-workflow-id-authority.sh`
- `bash tests/scenarios/test-track-lease-invalidation.sh`
- `bash tests/scenarios/test-routing-tester-completion.sh`
- `bash tests/scenarios/test-routing-guardian-completion.sh`
- `python3 -m pytest tests/runtime/test_policy_engine.py -q`
- `python3 -m pytest tests/runtime/test_leases.py tests/runtime/test_evaluation.py -q`
- `python3 -m pytest tests/runtime/policies/test_bash_adapter_regressions.py -q`
- New test: `bash tests/scenarios/test-context-lib-lease-first.sh` verifying:
  (a) `get_workflow_binding()` returns lease workflow_id when lease active
  (b) `read_evaluation_status()` with no explicit wf_id uses lease wf_id
  (c) Both fall back to branch-derived id when no lease
  (d) `bind_workflow()` same worktree with different wf_id removes old row
- `grep -n 'read_evaluation_status.*PROJECT_ROOT")$' hooks/*.sh` returns
  zero matches (all callers pass explicit workflow_id)

**Scope Manifest:**
- *Allowed:* `hooks/context-lib.sh`, `hooks/check-guardian.sh`,
  `hooks/check-implementer.sh`, `hooks/session-init.sh`,
  `runtime/core/workflows.py`, `runtime/core/evaluation.py`,
  `runtime/core/completions.py`, test files under `tests/`
- *Required:* `hooks/context-lib.sh` (lease-first helpers),
  `hooks/check-guardian.sh` (pass _GD_WF_ID),
  `hooks/check-implementer.sh` (add lease resolution),
  `hooks/session-init.sh` (add lease resolution),
  `runtime/core/workflows.py` (bind_workflow duplicate prevention),
  `tests/scenarios/test-context-lib-lease-first.sh` (new test)
- *Forbidden:* `runtime/schemas.py`, `settings.json`, `MASTER_PLAN.md`,
  `hooks/track.sh` (already converged),
  `runtime/core/policy_engine.py` (already converged),
  `hooks/check-tester.sh` (already converged)

**Expected state authorities touched:**
- `evaluation_state` table (workflow_id alignment at read sites)
- `workflow_bindings` table (stale row prevention in bind_workflow)

#### W-CONV-4: Readiness Surface Cleanup

- **Status:** complete (merged 2026-04-05)
- **Issue:** #5
- **Depends on:** W-CONV-3 (identity must be stable before changing what
  the operator sees)

**Problem:** `statusline.py:131-142` queries `proof_state` and surfaces
`proof_status` and `proof_workflow` alongside `evaluation_state`.
Enforcement already uses only `evaluation_state`, but operators see both
signals, which can contradict. `docs/DISPATCH.md` still describes
prompt-driven proof verification as live.

**Approach:** Remove `proof_state` reads from `statusline.py` snapshot.
Make `evaluation_state` the sole readiness display. Update stale docs.
`proof_state` table remains in schema (storage removal is W-CONV-6 scope
if ever needed).

**Evaluation Contract:**
- `python3 -m pytest tests/runtime/test_statusline_truth.py -q`
- Statusline snapshot JSON does NOT contain `proof_status` or
  `proof_workflow` as readiness fields
- `evaluation_state` is the sole readiness display
- `docs/DISPATCH.md` does not describe proof verification as live behavior

**Scope Manifest:**
- *Allowed:* `runtime/core/statusline.py`, `runtime/core/proof.py`,
  `runtime/cli.py`, `hooks/session-init.sh`, `hooks/context-lib.sh`,
  `docs/DISPATCH.md`, `hooks/HOOKS.md`, `docs/*.md`,
  `scripts/statusline.sh`, test files under `tests/`
- *Required:* `runtime/core/statusline.py` (remove proof_state reads)
- *Forbidden:* `runtime/schemas.py`, `settings.json`, `MASTER_PLAN.md`

**Expected state authorities touched:**
- `proof_state` table (read path removed from statusline)

#### W-CONV-5: Completion Contract Closure (Implementer)

- **Status:** complete (2026-04-05)
- **Issue:** #6
- **Depends on:** W-CONV-3 (workflow identity must be stable so completion
  records have correct workflow_id)
- **Commit:** `297a330`

**Problem:** `completions.py:39-50` defined `ROLE_SCHEMAS` only for tester
and guardian. Implementer schema was commented out (lines 52-66).
`check-implementer.sh` did not parse structured trailers. Stop-handling
relied on the stop-assessment heuristic (DEC-STOP-ASSESS-001) as primary
signal.

**Delivered:**
1. Activated implementer schema in `completions.py` (IMPL_STATUS,
   IMPL_HEAD_SHA) — now in ROLE_SCHEMAS at lines 52-57.
2. `check-implementer.sh` Check 8 (lines 265-322) parses IMPL_STATUS and
   IMPL_HEAD_SHA trailers from implementer response, submits completion
   record via `cc-policy completion submit`.
3. `dispatch_engine.py` DEC-IMPL-CONTRACT-001 (lines 163-191) reads the
   completion record and overrides the heuristic `is_interrupted` signal
   when a valid contract is present. Deferred stop-event emission (lines
   218-224) ensures the override happens before the event is written.
4. Heuristic (DEC-STOP-ASSESS-001) is fallback only when no valid
   completion record exists.
5. Routing (implementer → tester) unchanged regardless of contract status.

**Review evidence:**
- Tests: 16/16 passing (`tests/scenarios/test-implementer-completion-contract.sh`)
- Codex review: PASS on contract override, race condition, tests; PARTIAL
  on false-continuation (orchestrator prompt trust is out of scope)
- Minor follow-up gaps: `db.py` busy_timeout (graceful fallback exists),
  `completions.latest()` role filter (safe via explicit check at line 170)

**Evaluation Contract:**
- `python3 -m pytest tests/runtime/test_dispatch.py tests/runtime/test_dispatch_engine.py -q`
- `bash tests/scenarios/test-routing-tester-completion.sh`
- `bash tests/scenarios/test-routing-guardian-completion.sh`
- New test: implementer with valid IMPL_STATUS trailer produces valid
  completion record
- New test: implementer without trailers falls back to heuristic
  (advisory, not primary)
- Routing rules remain exclusively in `completions.py:determine_next_role()`

**Scope Manifest:**
- *Allowed:* `agents/implementer.md`, `hooks/check-implementer.sh`,
  `runtime/core/completions.py`, `runtime/core/dispatch_engine.py`,
  `runtime/schemas.py` (COMPLETION_ENFORCED_ROLES update only),
  test files under `tests/`
- *Required:* `runtime/core/completions.py` (activate implementer schema),
  `hooks/check-implementer.sh` (parse structured trailers)
- *Forbidden:* `settings.json`, `MASTER_PLAN.md`, `agents/planner.md`
  (planner contract is follow-up)

**Expected state authorities touched:**
- `completion_records` table (new role schema validated)

#### W-CONV-6: Dead Surface Deletion

- **Status:** not started
- **Issue:** #7
- **Depends on:** W-CONV-4 (readiness surface proven), W-CONV-5 (completion
  contracts proven)

**Problem:** Dead compatibility surfaces remain after replacement paths
landed: `.plan-drift` dead write in `surface.sh`, stale `.subagent-tracker`
references in comments, dead proof helpers in `context-lib.sh`, zero-byte
`.claude/runtime.db` artifact.

**Approach:** Delete each dead surface only after its replacement is proven
by the prior packets. `dispatch_queue` table removal is explicitly out of
scope for this initiative — tracked as a separate follow-up issue.

**Primary targets:**
- `.plan-drift` dead write in `surface.sh`
- Stale `.subagent-tracker` references in hook comments
- Dead `write_proof_status()`/`read_proof_status()` helpers in
  `context-lib.sh` and `runtime-bridge.sh`
- `.claude/runtime.db` zero-byte artifact

**Evaluation Contract:**
- Full convergence retest suite (all runtime + policy tests)
- `grep -r '\.plan-drift' hooks/` returns zero matches
- `grep -r '\.subagent-tracker' hooks/` returns zero matches
- `grep -r 'write_proof_status\|read_proof_status' hooks/` returns zero
  matches
- `.claude/runtime.db` does not exist

**Scope Manifest:**
- *Allowed:* `hooks/surface.sh`, `hooks/write-guard.sh`,
  `hooks/context-lib.sh`, `hooks/lib/runtime-bridge.sh`,
  `hooks/session-end.sh`, `docs/*.md`, `hooks/HOOKS.md`,
  `.claude/runtime.db` (deletion)
- *Required:* `hooks/surface.sh` (remove .plan-drift write),
  `hooks/context-lib.sh` (remove dead proof helpers)
- *Forbidden:* `runtime/schemas.py` (no table drops in this initiative),
  `settings.json`, `MASTER_PLAN.md`, `runtime/core/policy_engine.py`
  (stable after packets 1-3)

**Expected state authorities touched:**
- None (removing dead code paths, not changing live authorities)

#### W-CONV-7: Orchestrator Trusts Implementer Completion Contracts

- **Status:** not started
- **Issue:** #16
- **Depends on:** W-CONV-5 (completion contract must be live so there is a
  structured signal to trust)

**Problem:** W-CONV-5 fixed the hook/runtime path — `dispatch_engine.py`
correctly emits `agent_complete` (not `agent_stopped`) when `IMPL_STATUS=complete`.
But the orchestrator reads the raw implementer response text independently
and may decide "this looks cut off" based on narrative heuristics, spawning
an unnecessary continuation agent. Observed: screenshot showing "Implementer
got cut off during the final breadth check. Let me continue it." after an
implementer that was actually Done (67 tool uses, 7m 38s).

This leaves two authorities for the same operational fact:
1. Structured completion contract / runtime completion record
2. Orchestrator narrative heuristic over raw agent prose

**Approach:** Prompt/docs only. Add explicit orchestrator rules:
1. `IMPL_STATUS=complete` is terminal — do not spawn continuation
2. Continuation only when: `IMPL_STATUS=blocked`, contract missing/invalid,
   hook indicates `agent_stopped`, or user explicitly asks
3. When raw prose and structured signals conflict, structured signals win;
   report uncertainty rather than silently spawning continuation

**Scope Manifest:**
- *Allowed:* `CLAUDE.md`, `docs/DISPATCH.md`, `agents/*.md`
- *Required:* `CLAUDE.md` (orchestrator prompt rules)
- *Forbidden:* All hook/runtime/source files (no code changes)

**Expected state authorities touched:**
- None (prompt/docs only)

### INIT-CDX: Codex Plugin Concurrency and Dead Task Handling

- **Status:** planned
- **Blocked by:** none (independent of INIT-003/004/PE/REBASE/TESTGAP/CONV;
  operates entirely within the plugin's `scripts/` directory, no core hook or
  runtime changes)
- **Problem:** The Codex plugin has three interrelated reliability defects:
  (1) dead tasks are never reaped -- a crashed process leaves its job record as
  status="running" forever, blocking new task launches and misleading status
  displays; (2) state writes are not atomic -- `upsertJob()` does
  read-modify-write of `state.json` with no lock, so concurrent writers (e.g.,
  background worker + session cleanup) silently lose updates; (3) the broker
  serializes all operations behind a single active socket, though a direct-client
  fallback path already exists that mitigates this.
- **Goal:** Make job state writes crash-safe and concurrency-safe, automatically
  reap dead tasks so no job stays "running" after its process dies, and harden
  the direct-client fallback path so parallel task execution is reliable.
- **Scope:** Three waves touching 7 files in
  `plugins/marketplaces/openai-codex/plugins/codex/scripts/`. No core hook,
  runtime, or policy-engine files are modified. This is a plugin-internal
  improvement with no integration surface to the core governance system.
- **Exit:** (1) concurrent `upsertJob()` calls from separate processes never
  lose updates; (2) a job whose PID is dead is automatically marked failed on
  the next status read; (3) two concurrent task invocations both succeed (one
  via broker, one via direct-client fallback) without data loss.
- **Dependencies:** none

#### Wave Decomposition

```
W-CDX-1 (Atomic state writes) ─── W-CDX-2 (Stale task reaper)
                                    └── W-CDX-3 (Broker fallback hardening)
```

**Critical path:** W-CDX-1 -> W-CDX-2 -> W-CDX-3
**Max width:** 1

#### State Authority Map

| State Domain | Current Authority | INIT-CDX Change | Wave |
|---|---|---|---|
| Job records (list, status, metadata) | `state.json` per-workspace, no lock | O_EXCL lockfile + write-tmp-rename for atomic read-modify-write | W-CDX-1 |
| Job detail files | `<jobs-dir>/<job-id>.json` (single-writer per job) | No change | -- |
| Job log files | `<jobs-dir>/<job-id>.log` (append-only) | No change | -- |
| Broker session | `broker.json` per-workspace | No change | -- |
| Job liveness | **NONE** (the bug) | PID-based liveness check via `process.kill(pid, 0)` on every `listJobs()` | W-CDX-2 |
| Codex app-server connection | Broker (primary) or direct process (fallback) | Fallback hardened with retry, logging, and notification handler setup | W-CDX-3 |

#### Known Risks

1. **O_EXCL lockfile stale on crash.** If the process crashes between acquiring
   the lock and releasing it, the lockfile persists. Mitigation: stale lock
   detection by mtime -- if lockfile is older than 5 seconds, forcibly remove it.
   The 5-second threshold is generous (normal lock hold time is <50ms for a JSON
   read-modify-write).
2. **PID reuse false negative.** On macOS, PIDs are recycled. A dead task's PID
   could be reused by an unrelated process, causing the reaper to think the task
   is still alive. Mitigation: PID reuse on macOS cycles through ~99999 PIDs.
   The window where a task PID is reused AND the task is dead AND the reaper
   hasn't run is negligible. For additional safety, the reaper can cross-check
   `process.kill(pid, 0)` with the job's `startedAt` timestamp -- if the job
   started hours ago and the PID is alive but has a different process start time,
   it's a reuse. This cross-check is deferred to a future enhancement if PID
   reuse proves to be a real problem.
3. **Direct-client fallback resource consumption.** Each direct client spawns a
   `codex app-server` process. With 3 concurrent tasks, that's 3 extra processes.
   Mitigation: these are short-lived (task duration) and the Codex app-server is
   designed to be spawnable. The broker still handles the common single-task case
   efficiently.
4. **Backward compatibility.** Existing job records lack lockfile awareness. No
   issue: the lockfile is separate from state.json. Old and new code can coexist
   -- old code writes without locking (less safe but not breaking), new code
   acquires the lock first. After rollout, all writers use the lock.
5. **Test isolation.** Testing concurrent writes requires spawning parallel
   processes that race on state.json. Mitigation: use Node.js `worker_threads`
   or `child_process.fork()` in tests to create real write contention.

##### W-CDX-1: Atomic State Writes in state.mjs

- **Weight:** M
- **Gate:** review
- **Deps:** none
- **Integration:** `state.mjs` is imported by `tracked-jobs.mjs`,
  `job-control.mjs`, `codex-companion.mjs`, `session-lifecycle-hook.mjs`,
  `stop-review-gate-hook.mjs`, `broker-lifecycle.mjs`. All callers benefit
  automatically since the lock is internal to `updateState()`/`saveState()`.

**Implementer scope:**

- `plugins/marketplaces/openai-codex/plugins/codex/scripts/lib/state.mjs`:
  - Add `acquireLock(stateDir, timeoutMs = 2000)` function:
    - Creates `<stateDir>/state.lock` with `fs.openSync(lockPath, 'wx')` (O_EXCL)
    - On EEXIST: check lockfile mtime; if older than 5 seconds, `fs.unlinkSync`
      and retry; otherwise backoff (10ms, 20ms, 40ms... exponential) and retry
    - Returns a release function that `fs.unlinkSync`s the lockfile
    - On timeout: throw an error ("Could not acquire state lock after Nms")
  - Add `releaseLock(lockPath)` function:
    - `fs.unlinkSync(lockPath)` wrapped in try-catch (ignore ENOENT)
  - Modify `saveState(cwd, state)`:
    - Write to `state.json.tmp` first, then `fs.renameSync` to `state.json`
    - This ensures a crash mid-write leaves either the old state.json intact or
      the new one fully written (rename is atomic on POSIX)
  - Modify `updateState(cwd, mutate)`:
    - Wrap the entire read-modify-write in `acquireLock` / `releaseLock`
    - Pattern: `const release = acquireLock(stateDir); try { load, mutate, save }
      finally { release(); }`
  - Modify `saveState(cwd, state)`:
    - Remove the `loadState(cwd)` call at line 93 that re-reads state for pruning.
      Instead, accept the jobs-to-prune from the caller or compute the prune diff
      from the state argument alone. The double-read is a concurrency hazard even
      with locking (it widens the lock hold time unnecessarily) and is also a
      correctness bug: the second read can see stale data from before the lock
      was acquired. The prune diff should be computed from `state.jobs` only.

**Test plan:**

- Create `plugins/marketplaces/openai-codex/plugins/codex/tests/test-state-lock.mjs`:
  - Test: single writer acquires and releases lock correctly
  - Test: second writer blocks until first releases
  - Test: stale lock (mtime > 5s) is forcibly removed
  - Test: timeout is thrown after 2 seconds of contention
  - Test: write-tmp-rename leaves valid state.json even if process crashes
    (simulate by writing tmp then not renaming, verify old state.json survives)
  - Test: concurrent `upsertJob` from two `child_process.fork()` workers both
    succeed and both updates are visible in final state.json
  - Test: `saveState` no longer re-reads state.json (the double-read is removed)

###### Evaluation Contract for W-CDX-1

**Required tests:**
- All tests in `test-state-lock.mjs` pass
- Existing Codex plugin functionality is not regressed (manual: run
  `/codex:status`, launch a foreground task, launch a background task)

**Required real-path checks:**
1. `acquireLock` creates `state.lock` with O_EXCL and returns a release function
2. `releaseLock` removes `state.lock` (ENOENT is ignored)
3. `updateState` holds lock for entire read-modify-write cycle
4. `saveState` writes to `state.json.tmp` then renames to `state.json`
5. `saveState` does NOT call `loadState` internally (double-read removed)
6. Two processes calling `upsertJob` concurrently both succeed; final
   `state.json` contains both updates
7. A lockfile older than 5 seconds is forcibly removed by the next acquirer

**Required authority invariants:**
- `state.json` remains the sole authority for job list state
- The lockfile is transient (only held during write); it is never the authority
  for anything
- No new state file or database is introduced

**Required integration points:**
- `tracked-jobs.mjs` `runTrackedJob()` continues to work (it calls `upsertJob`)
- `session-lifecycle-hook.mjs` `cleanupSessionJobs()` continues to work (it
  calls `saveState` directly)
- `stop-review-gate-hook.mjs` `listJobs()` continues to work
- `codex-companion.mjs` `handleCancel()` continues to work (it calls `upsertJob`)

**Forbidden shortcuts:**
- Do not use `setTimeout`-based lock polling (use busy-wait with `fs.openSync`
  retry to avoid yielding the event loop mid-lock-acquisition)
- Do not introduce external npm dependencies
- Do not change the state.json schema or format
- Do not modify any file outside the plugin's `scripts/` directory

**Ready-for-guardian definition:**
All tests pass. Lock acquisition, contention, stale-lock cleanup, and
concurrent-writer scenarios are demonstrated. The double-read in `saveState` is
eliminated. `state.json` format is unchanged and backward-compatible.

###### Scope Manifest for W-CDX-1

**Allowed files/directories:**
- `plugins/marketplaces/openai-codex/plugins/codex/scripts/lib/state.mjs` (modify)
- `plugins/marketplaces/openai-codex/plugins/codex/tests/test-state-lock.mjs` (new)

**Required files/directories:**
- `plugins/marketplaces/openai-codex/plugins/codex/scripts/lib/state.mjs` (must be modified)
- `plugins/marketplaces/openai-codex/plugins/codex/tests/test-state-lock.mjs` (must be created)

**Forbidden touch points:**
- Any file outside `plugins/marketplaces/openai-codex/plugins/codex/`
- `state.json` schema (format must remain identical)
- `tracked-jobs.mjs`, `job-control.mjs`, `codex-companion.mjs` (callers must
  not need changes -- the lock is internal)
- Core hook/runtime/policy files

**Expected state authorities touched:**
- MODIFIED: `state.mjs` write path -- now atomic via lockfile + tmp-rename
- UNCHANGED: `state.json` format, `<job-id>.json` files, `<job-id>.log` files

##### W-CDX-2: Stale Task Reaper

- **Weight:** M
- **Gate:** review
- **Deps:** W-CDX-1 (reaper writes must be atomic)
- **Integration:** `listJobs()` is called by `job-control.mjs`
  `buildStatusSnapshot()`, `buildSingleJobSnapshot()`, `resolveResultJob()`,
  `resolveCancelableJob()`; `codex-companion.mjs`
  `resolveLatestTrackedTaskThread()`, `handleTaskResumeCandidate()`;
  `stop-review-gate-hook.mjs`; `session-lifecycle-hook.mjs`
  `cleanupSessionJobs()` (via `loadState()`).

**Implementer scope:**

- `plugins/marketplaces/openai-codex/plugins/codex/scripts/lib/state.mjs`:
  - Add `isProcessAlive(pid)` function:
    - Try `process.kill(pid, 0)`; return true on success
    - Catch: if `error.code === 'ESRCH'`, return false (process not found)
    - Catch: if `error.code === 'EPERM'`, return true (process exists but we
      lack permission -- still alive)
    - Catch: for any other error, return true (conservative: assume alive)
  - Add `reapStaleJobs(cwd)` function:
    - Load state via `loadState(cwd)`
    - Find all jobs where `(status === "running" || status === "queued")` AND
      `pid` is a finite number AND `!isProcessAlive(pid)`
    - For each: set `status: "failed"`, `phase: "failed"`, `pid: null`,
      `errorMessage: "Process exited unexpectedly (PID <pid> not found)."`,
      `completedAt: nowIso()`
    - Also update the corresponding job detail file (`<job-id>.json`) with the
      same fields, reading the existing detail and merging
    - If any jobs were reaped, save state via `saveState()` (which now uses the
      lock from W-CDX-1)
    - Return array of reaped job objects (for caller logging)
  - Modify `listJobs(cwd)`:
    - Call `reapStaleJobs(cwd)` before returning
    - This makes reaping transparent to all callers

- `plugins/marketplaces/openai-codex/plugins/codex/scripts/lib/job-control.mjs`:
  - No changes needed -- `listJobs()` already reaps via the above

- `plugins/marketplaces/openai-codex/plugins/codex/tests/test-reaper.mjs` (new):
  - Test: a job with a non-existent PID is reaped to status="failed"
  - Test: a job with PID=`process.pid` (current process, alive) is NOT reaped
  - Test: a job with no PID field is NOT reaped (legacy job record)
  - Test: a completed job is NOT reaped (already terminal)
  - Test: a queued job with dead PID is reaped
  - Test: the job detail file (`<job-id>.json`) is updated when reaped
  - Test: `listJobs()` returns reaped state (status=failed) after reap
  - Test: multiple dead jobs are all reaped in a single `listJobs()` call
  - Test: reaper handles EPERM gracefully (process exists, permission denied)

###### Evaluation Contract for W-CDX-2

**Required tests:**
- All tests in `test-reaper.mjs` pass
- All tests in `test-state-lock.mjs` (W-CDX-1) still pass
- Manual: kill -9 a background Codex task, then run `/codex:status` and verify
  the task shows as "failed" (not "running")

**Required real-path checks:**
1. `isProcessAlive(pid)` returns false for non-existent PID (ESRCH)
2. `isProcessAlive(pid)` returns true for alive PID
3. `isProcessAlive(pid)` returns true for EPERM (alive but no permission)
4. `reapStaleJobs()` transitions running+dead-PID jobs to failed
5. `reapStaleJobs()` transitions queued+dead-PID jobs to failed
6. `reapStaleJobs()` leaves running+alive-PID jobs untouched
7. `reapStaleJobs()` leaves terminal (completed/failed/cancelled) jobs untouched
8. `reapStaleJobs()` updates both `state.json` and the job detail file
9. `listJobs()` transparently reaps before returning
10. `resolveLatestTrackedTaskThread()` no longer throws "Task X is still running"
    for dead tasks (they are reaped before the check)

**Required authority invariants:**
- `state.json` remains the sole authority for job list state
- `<job-id>.json` remains the sole authority for job detail state
- The reaper is a read-path side effect, not a separate daemon or authority

**Required integration points:**
- `buildStatusSnapshot()` reports reaped jobs as failed (not running)
- `resolveLatestTrackedTaskThread()` skips reaped jobs (they have
  status="failed", not "running")
- `stop-review-gate-hook.mjs` sees reaped state through `listJobs()`
- `cleanupSessionJobs()` sees reaped state through `loadState()` (note:
  `cleanupSessionJobs` calls `loadState` directly, not `listJobs`, so the
  reaper must also be called from `loadState` or `cleanupSessionJobs` must
  call `reapStaleJobs` explicitly -- verify this integration)

**Forbidden shortcuts:**
- Do not add a background timer or periodic sweep
- Do not change job status values or add new ones
- Do not modify any file outside the plugin's `scripts/` directory
- Do not introduce external npm dependencies

**Ready-for-guardian definition:**
All tests pass. Dead-PID jobs are automatically reaped. No phantom "running"
jobs survive a PID check. The kill-and-check manual test demonstrates the
end-to-end behavior.

###### Scope Manifest for W-CDX-2

**Allowed files/directories:**
- `plugins/marketplaces/openai-codex/plugins/codex/scripts/lib/state.mjs` (modify)
- `plugins/marketplaces/openai-codex/plugins/codex/tests/test-reaper.mjs` (new)

**Required files/directories:**
- `plugins/marketplaces/openai-codex/plugins/codex/scripts/lib/state.mjs` (must be modified)
- `plugins/marketplaces/openai-codex/plugins/codex/tests/test-reaper.mjs` (must be created)

**Forbidden touch points:**
- `tracked-jobs.mjs` (callers must not need changes)
- `job-control.mjs` (callers must not need changes)
- `codex-companion.mjs` (callers must not need changes)
- Any file outside `plugins/marketplaces/openai-codex/plugins/codex/`
- Core hook/runtime/policy files

**Expected state authorities touched:**
- MODIFIED: `state.mjs` read path -- `listJobs()` now reaps stale jobs on read
- UNCHANGED: `state.json` format, job status values, job detail file format

##### W-CDX-3: Broker Fallback Hardening and Parallel Task Support

- **Weight:** M (upgraded from S -- connect-phase restructuring adds complexity)
- **Gate:** review
- **Deps:** W-CDX-2 (dead task reaping must work so parallel tasks that crash
  are cleaned up)
- **Integration:** `codex.mjs` `withAppServer()` is the sole connection path
  for `runAppServerReview`, `runAppServerTurn`, and `findLatestTaskThread`;
  `interruptAppServerTurn` uses its own connection logic (intentionally --
  see analysis below); `app-server-broker.mjs` is NOT modified (the broker
  stays single-socket by design per DEC-CDX-003)

**Deep analysis (2026-04-05, revised 2026-04-06 per Codex review findings):**

The following analysis was produced by reading the actual source code of all
four involved files. Line numbers verified against current main HEAD. Items
marked [REV] were added or revised in the 2026-04-06 Codex review pass.

1. **Error propagation path for broker socket death:**
   When the broker process dies mid-request, `BrokerCodexAppServerClient`
   (app-server.mjs:274-329) receives a socket `error` event. This calls
   `handleExit(error)` (app-server.mjs:162-175) which rejects all pending
   promises with the raw Node.js socket error. The socket error carries
   `error.code` (e.g. `ECONNRESET`, `EPIPE`) but NOT `error.rpcCode`.
   The current `shouldRetryDirect` check at codex.mjs:616-618 only checks
   `rpcCode === BROKER_BUSY_RPC_CODE` for transport=broker errors, so
   socket-death errors fall through to the `code === "ENOENT" || "ECONNREFUSED"`
   branch. `ECONNRESET` and `EPIPE` are not caught, causing the fallback to
   be skipped and the error to propagate to the caller.

2. **`withAppServer()` has no access to `onProgress`:**
   Current signature is `withAppServer(cwd, fn)` (codex.mjs:607). All three
   callers (`runAppServerReview` at line 779, `runAppServerTurn` at line 835,
   `findLatestTaskThread` at line 902) have access to `options.onProgress` but
   do not pass it to `withAppServer`. To emit progress on fallback, the
   signature must change to `withAppServer(cwd, fn, options)` where options
   can carry `onProgress`. This is a backward-compatible additive change.

3. **Notification handler works correctly on direct-client (no change needed):**
   `captureTurn()` (codex.mjs:553) calls `client.setNotificationHandler()`
   on whatever client it receives. `withAppServer()` passes either the broker
   client or the direct fallback client to `fn`. Since `fn` receives the
   client and uses it for all operations including `captureTurn`, notifications
   route correctly regardless of transport. Verified: no code change needed.

4. **`interruptAppServerTurn()` (codex.mjs:728-771) does NOT use `withAppServer()`:**
   It constructs its own connection: broker if available, direct otherwise.
   It has no fallback -- if the connection fails, it returns
   `{ interrupted: false }`. This is correct behavior: interrupt is
   best-effort, and if the broker dies, the task it was running is already
   dead. Adding fallback here would mean connecting direct to interrupt a
   turn that only exists on the broker's app-server -- pointless. Decision:
   leave `interruptAppServerTurn` unchanged (DEC-CDX-004).

5. **Task guard analysis -- `resolveLatestTrackedTaskThread()` (codex-companion.mjs:311-325):**
   - The guard at line 314 filters `listJobs()` for `jobClass === "task"` with
     `status === "queued" || status === "running"`.
   - After W-CDX-2, `listJobs()` transparently calls `reapStaleJobs()` --
     jobs with dead PIDs are marked `status: "failed"` before the filter runs.
   - The guard is ONLY invoked from `executeTaskRun()` when
     `request.resumeLast === true` (codex-companion.mjs:440-441). It does NOT
     affect review launches (`executeReviewRun` never calls it).
   - Reviews and tasks use separate `withAppServer` calls, so they already
     work in parallel through the broker/fallback mechanism.
   - Decision: NO modification to `resolveLatestTrackedTaskThread` is needed
     (DEC-CDX-005). The reaper handles the dead-task case; the guard correctly
     prevents resume-last when a genuinely alive task exists.

6. **Additional error code -- `EPIPE`:**
   When `sendMessage()` writes to a broker socket whose remote end has closed
   but before the `close` event fires, Node emits `EPIPE`. This is a
   real-world scenario (broker killed between connect and first write).
   Must be included in `shouldRetryDirect`.

7. **`ERR_SOCKET_CLOSED` assessment:**
   This error is thrown by Node's internal socket implementation when writing
   to an already-destroyed socket. It surfaces as `error.code ===
   "ERR_SOCKET_CLOSED"`. While less common than `ECONNRESET`/`EPIPE` (those
   fire on the OS level), it can occur in race conditions where `close` fires
   synchronously during a write attempt. Include it for completeness.

8. **[REV] Connect-phase failure (Codex review Finding 1 -- HIGH):**
   `CodexAppServerClient.connect(cwd)` (codex.mjs:610) can throw during
   `ensureBrokerSession()` (app-server.mjs:337) BEFORE returning a client.
   When this happens, `client` is still `null` in the catch block. The retry
   detection `client?.transport === "broker"` evaluates to `undefined`, and
   `Boolean(process.env[BROKER_ENDPOINT_ENV])` is false in the session-file
   discovery path (the env var is NOT set when the broker is discovered via
   `loadBrokerSession()` reading `broker.json` from disk). Result: connect-
   phase failures in the session-file path silently skip retry and propagate
   the raw error. The fix requires `withAppServer` to determine
   `brokerRequested` BEFORE calling `connect()`, based on the same logic
   `connect()` uses: check `process.env[BROKER_ENDPOINT_ENV]` OR whether
   `loadBrokerSession(cwd)` returns a non-null session. This boolean is
   captured before the try block and used for retry detection even when
   `client` is null.

9. **[REV] Direct-connect failure outside try/catch (Codex review Finding 2 -- HIGH):**
   In the original plan's Change 3, `CodexAppServerClient.connect(cwd, { disableBroker: true })`
   was placed BEFORE the try/catch for the direct-client path. If the direct
   connect itself throws, the error propagates raw -- the `.brokerError` /
   `.directError` combined error never materializes. The fix: the direct
   `connect()` call must be INSIDE the try/catch so that failures during
   direct connection are caught and wrapped in the dual-failure error.

10. **[REV] Clean-close path bypasses retry set (Codex review Finding 3 -- MEDIUM):**
    `handleExit(error)` (app-server.mjs:162-175) has a graceful-shutdown path:
    when the broker socket closes without an OS-level error (e.g., broker
    process exits cleanly while a request is in flight), `this.exitError` is
    null, and pending promises are rejected with:
    `new Error("codex app-server connection closed.")` (app-server.mjs:171).
    This error has no `.code` property. The proposed retry set only checks
    `.code`, so clean-close errors fall outside it. Fix: add a message-based
    check to the retry detection: if `error.message` includes
    `"connection closed"`, treat it as retriable. Decision: DEC-CDX-006.

11. **[REV] Replay safety analysis (Codex review Finding 4 -- MEDIUM):**
    Retrying on transport errors replays the ENTIRE `fn(client)` closure on a
    fresh direct client. For `runAppServerTurn`, this means `startThread()` +
    `captureTurn()` + `turn/start` execute again. For `runAppServerReview`,
    it means `startThread()` + `captureTurn()` + `review/start` execute again.
    This is SAFE for the following reasons:
    - The replay runs against a FRESH direct-process client with its own
      `codex app-server` process. It has no connection to the dead broker.
    - `thread/start` creates a new thread each call -- it is a creation
      endpoint, not idempotent. But this is CORRECT: the broker-side thread
      died with the broker, so a new thread on the direct client is the
      desired outcome.
    - No orphaned resources accumulate on the dead broker: the broker process
      and its app-server are dead. Any threads created there before failure
      are ephemeral (both review and task threads are started with
      `ephemeral: true` by default).
    - The only wasted cost is a thread allocation if the broker dies between
      `thread/start` succeeding and `turn/start` failing -- one abandoned
      ephemeral thread. This is acceptable for a resilience path.
    - `findLatestTaskThread` replays `thread/list`, which is a read-only
      query. Replay is trivially safe.
    Decision: DEC-CDX-007.

12. **[REV] `handleExit` test coverage (Codex review Finding 5 -- LOW):**
    The test plan mocks at the `connect()`/`withAppServer` level but does not
    exercise `BrokerCodexAppServerClient.handleExit()` directly. Integration
    testing of `handleExit` requires an actual IPC socket teardown (killing a
    broker process mid-request), which cannot be reliably unit-tested. The 11
    unit tests are sufficient for verifying the retry classification logic.
    Integration-level `handleExit` propagation testing is deferred -- tracked
    as a known gap, not a blocking concern.

**Implementer scope:**

- `plugins/marketplaces/openai-codex/plugins/codex/scripts/lib/codex.mjs`:

  **Change 1: Restructure `withAppServer()` to handle connect-phase failures
  (addresses Findings 1, 2, 3, and 4)**

  The entire function must be restructured. The current code has a single
  try/catch where `client = await connect()` is inside the try and the catch
  determines retry eligibility. This structure fails when `connect()` throws
  before returning a client (Finding 1) and when the direct-connect also
  fails (Finding 2).

  Current code (codex.mjs:607-636):
  ```js
  async function withAppServer(cwd, fn) {
    let client = null;
    try {
      client = await CodexAppServerClient.connect(cwd);
      const result = await fn(client);
      await client.close();
      return result;
    } catch (error) {
      const brokerRequested = client?.transport === "broker" || Boolean(process.env[BROKER_ENDPOINT_ENV]);
      const shouldRetryDirect =
        (client?.transport === "broker" && error?.rpcCode === BROKER_BUSY_RPC_CODE) ||
        (brokerRequested && (error?.code === "ENOENT" || error?.code === "ECONNREFUSED"));

      if (client) {
        await client.close().catch(() => {});
        client = null;
      }

      if (!shouldRetryDirect) {
        throw error;
      }

      const directClient = await CodexAppServerClient.connect(cwd, { disableBroker: true });
      try {
        return await fn(directClient);
      } finally {
        await directClient.close();
      }
    }
  }
  ```

  Target structure -- complete replacement:
  ```js
  /** @type {Set<string>} */
  const RETRIABLE_TRANSPORT_CODES = new Set([
    "ENOENT", "ECONNREFUSED", "ECONNRESET", "EPIPE", "ERR_SOCKET_CLOSED"
  ]);

  function isRetriableBrokerError(error, client) {
    // RPC-level: broker reports it is busy servicing another client
    if (client?.transport === "broker" && error?.rpcCode === BROKER_BUSY_RPC_CODE) {
      return true;
    }
    // OS-level transport errors (socket died, broker unreachable, etc.)
    if (error?.code && RETRIABLE_TRANSPORT_CODES.has(error.code)) {
      return true;
    }
    // Clean-close path: handleExit() rejects with a message-only error
    // when the broker socket closes gracefully (no .code property).
    // See app-server.mjs:171 and DEC-CDX-006.
    if (error?.message?.includes("connection closed")) {
      return true;
    }
    return false;
  }

  async function withAppServer(cwd, fn, options = {}) {
    // Determine whether a broker was requested BEFORE connect(), so that
    // connect-phase failures can still trigger retry. The env var covers
    // explicit broker configuration; loadBrokerSession covers the
    // session-file discovery path (Finding 1 / DEC-CDX-006).
    const brokerRequested =
      Boolean(process.env[BROKER_ENDPOINT_ENV]) ||
      loadBrokerSession(cwd) != null;

    let client = null;
    let brokerError = null;

    try {
      client = await CodexAppServerClient.connect(cwd);
      const result = await fn(client);
      await client.close();
      return result;
    } catch (error) {
      brokerError = error;
      if (client) {
        await client.close().catch(() => {});
        client = null;
      }

      const shouldRetry =
        brokerRequested && isRetriableBrokerError(error, client);

      if (!shouldRetry) {
        throw error;
      }
    }

    // --- Direct fallback path ---
    // Both connect() and fn() are inside the try/catch so that
    // direct-connect failures produce the dual-failure error (Finding 2).
    // Replay of fn() is safe per DEC-CDX-007.
    emitProgress(
      options.onProgress,
      "Broker busy or unavailable, connecting directly to Codex runtime.",
      "connecting"
    );

    let directClient = null;
    try {
      directClient = await CodexAppServerClient.connect(cwd, {
        disableBroker: true
      });
      const result = await fn(directClient);
      await directClient.close();
      return result;
    } catch (directError) {
      const combined = new Error(
        `Broker failed: ${brokerError.message}; direct fallback also failed: ${directError.message}`
      );
      combined.brokerError = brokerError;
      combined.directError = directError;
      throw combined;
    } finally {
      if (directClient) {
        await directClient.close().catch(() => {});
      }
    }
  }
  ```

  Key structural differences from the original plan:
  - `brokerRequested` is computed BEFORE `connect()` using both the env var
    AND `loadBrokerSession(cwd)`, so connect-phase failures in the
    session-file path trigger retry (Finding 1).
  - `isRetriableBrokerError()` is extracted as a named function for clarity
    and testability. It checks `.rpcCode`, `.code` (via Set), AND
    `.message` for the clean-close case (Finding 3).
  - The direct fallback path has BOTH `connect()` and `fn()` inside a
    single try/catch, so direct-connect failures produce the dual-failure
    error with `.brokerError`/`.directError` (Finding 2).
  - The `client` reference is captured before the `shouldRetry` check so
    that `isRetriableBrokerError` can still inspect `client?.transport` for
    the BROKER_BUSY_RPC_CODE case. Note: after a connect-phase failure,
    `client` is null, but that path uses code/message matching, not
    transport checking.
  - The direct-client `close()` is in a finally block. On the success path,
    `close()` runs in the try body (explicit, clean close) AND the finally
    block checks if `directClient` is non-null before closing (idempotent
    via `closed` flag in AppServerClientBase). On the failure path, only
    finally runs. This ensures no leaked connections.
  - Replay safety is documented and justified (Finding 4 / DEC-CDX-007).

  **Change 2: Add `options` parameter with `onProgress` for fallback logging**

  Already incorporated in the target structure above. Signature changes from
  `async function withAppServer(cwd, fn)` to
  `async function withAppServer(cwd, fn, options = {})`.

  **Change 3: Update all callers to pass `onProgress` through**

  Three call sites:
  - `runAppServerReview` (line 779): change to `withAppServer(cwd, async (client) => { ... }, { onProgress: options.onProgress })`
  - `runAppServerTurn` (line 835): change to `withAppServer(cwd, async (client) => { ... }, { onProgress: options.onProgress })`
  - `findLatestTaskThread` (line 902): no `onProgress` available -- pass no options (fallback progress goes to void, which is fine for a lightweight list operation)

  **Change 4: Import `loadBrokerSession`**

  `codex.mjs` already imports `loadBrokerSession` from `broker-lifecycle.mjs`
  at line 39. No new import needed. Verified.

- `plugins/marketplaces/openai-codex/plugins/codex/scripts/lib/app-server.mjs`:
  - **No changes.** `BrokerCodexAppServerClient.handleExit()` already
    propagates socket errors correctly. The socket `error` event passes the
    raw Node.js error (with `.code`) to `handleExit` which rejects pending
    promises with it. The clean-close path (line 171) produces the
    `"codex app-server connection closed."` message that the new
    message-based check catches. Both paths are verified by code inspection
    and will be proven by tests.

- `plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs`:
  - **No changes.** Per analysis point 5 above, the task guard works correctly
    after W-CDX-2's transparent reaping. Reviews are not affected by the guard.
    Decision recorded as DEC-CDX-005.

- `plugins/marketplaces/openai-codex/plugins/codex/tests/test-broker-fallback.mjs` (new):

  Test pattern: follow W-CDX-1/W-CDX-2 test conventions (node:test, node:assert/strict,
  temp workspace per test, `@decision` annotation header).

  Testing strategy: `withAppServer` depends on `CodexAppServerClient.connect()`.
  The tests must mock/stub the connection layer. Two approaches:
  - (a) Override `CodexAppServerClient.connect` via a test-local import patch
  - (b) Inject a factory function

  Approach (a) is simpler and matches the existing codebase pattern (no DI framework).
  Since `codex.mjs` imports `CodexAppServerClient` from `app-server.mjs`, the test can
  create a mock client object with the same interface (`request`, `close`,
  `setNotificationHandler`, `transport`, `stderr` properties) and test `withAppServer`
  behavior by exporting it or by testing the higher-level functions that call it.

  However, `withAppServer` is a private function (not exported). The implementer should
  either: (a) export it for testing, or (b) test through the public functions
  (`runAppServerReview`, `runAppServerTurn`) with mocked `CodexAppServerClient.connect`.

  Recommended: export `withAppServer` AND `isRetriableBrokerError` as named exports
  for testability. `withAppServer` has a clean contract:
  `(cwd, fn, options?) => Promise<T>`. `isRetriableBrokerError` is a pure function
  that can be tested independently. Add a comment noting they are exported for testing.

  **Required test cases (11 tests):**

  Tests 1-8 are from the original plan. Tests 9-11 are new, added to cover
  the Codex review findings.

  1. **Broker BUSY retry:** Create a mock broker client (transport="broker") whose
     `fn` call throws `{ rpcCode: -32001 }`. Verify `withAppServer` retries with a
     direct client and returns the direct result.

  2. **ECONNREFUSED retry:** Create a mock where `CodexAppServerClient.connect()` throws
     `{ code: "ECONNREFUSED" }` and `BROKER_ENDPOINT_ENV` is set. Verify retry.

  3. **ECONNRESET retry:** Mock broker client whose `fn` throws `{ code: "ECONNRESET" }`.
     Verify retry.

  4. **EPIPE retry:** Mock broker client whose `fn` throws `{ code: "EPIPE" }`.
     Verify retry.

  5. **ERR_SOCKET_CLOSED retry:** Mock broker client whose `fn` throws
     `{ code: "ERR_SOCKET_CLOSED" }`. Verify retry.

  6. **Non-retriable error passes through:** Mock broker client whose `fn` throws
     `{ code: "ETIMEOUT" }` (not in the retry set). Verify the error propagates
     without retry.

  7. **Dual failure produces combined error:** Mock broker client that fails with
     ECONNRESET, AND mock direct client that also fails. Verify the thrown error
     message contains both error messages, and has `brokerError`/`directError`
     properties.

  8. **Fallback emits progress:** Mock broker client that fails with BROKER_BUSY.
     Pass an `onProgress` spy. Verify the spy was called with a message containing
     "Broker busy or unavailable" before the direct client attempt.

  9. **[REV] Connect-phase failure triggers retry (Finding 1):**
     Mock `CodexAppServerClient.connect()` to throw `{ code: "ECONNREFUSED" }`
     on first call (broker path). Do NOT set `BROKER_ENDPOINT_ENV`. Instead,
     ensure `loadBrokerSession(cwd)` returns a non-null session object (mock
     or write a `broker.json` to the temp workspace's state dir). Verify that
     `withAppServer` retries with `{ disableBroker: true }` and returns the
     direct result. This proves that `brokerRequested` is computed from
     `loadBrokerSession()` before `connect()`, not from `client?.transport`
     after a failed connect.

  10. **[REV] Direct-connect failure produces dual-failure error (Finding 2):**
      Mock `CodexAppServerClient.connect()` to return a broker client whose
      `fn` throws ECONNRESET (first call), then throw ECONNREFUSED on the
      second call (direct connect). Verify the thrown error has `.brokerError`
      with code ECONNRESET and `.directError` with code ECONNREFUSED. This
      proves the direct `connect()` is inside the try/catch.

  11. **[REV] Clean-close message-only error triggers retry (Finding 3):**
      Mock broker client whose `fn` throws
      `new Error("codex app-server connection closed.")` with no `.code`.
      Verify `withAppServer` retries with a direct client. This proves the
      message-based check in `isRetriableBrokerError`.

  **Note on `handleExit` integration coverage (Finding 5):**
  Tests mock at the `connect()`/`withAppServer` level. Direct testing of
  `BrokerCodexAppServerClient.handleExit()` propagation requires an actual
  IPC socket teardown (killing a broker process mid-request), which is not
  reliably unit-testable. The 11 unit tests are sufficient for verifying
  the retry classification logic and the `withAppServer` control flow.
  Integration-level `handleExit` testing is a known deferred gap.

###### Evaluation Contract for W-CDX-3

**Required tests:**
- All 11 tests in `test-broker-fallback.mjs` pass
- All tests from W-CDX-1 (`test-state-lock.mjs`) still pass
- All tests from W-CDX-2 (`test-reaper.mjs`) still pass
- Run all three test files: `node --test tests/test-state-lock.mjs tests/test-reaper.mjs tests/test-broker-fallback.mjs`

**Required real-path checks:**
1. `withAppServer()` retries with direct client on `BROKER_BUSY_RPC_CODE` (-32001)
2. `withAppServer()` retries with direct client on `ECONNREFUSED`
3. `withAppServer()` retries with direct client on `ECONNRESET`
4. `withAppServer()` retries with direct client on `EPIPE`
5. `withAppServer()` retries with direct client on `ERR_SOCKET_CLOSED`
6. Non-retriable errors (e.g. `ETIMEOUT`, generic Error with unrelated message)
   propagate without retry
7. Fallback emits a progress message via `onProgress` before attempting direct
8. When direct fallback also fails, thrown error contains both broker and direct
   error messages plus `.brokerError` and `.directError` properties
9. `runAppServerReview` and `runAppServerTurn` pass `onProgress` through to
   `withAppServer` (verified by test 8 or by code inspection)
10. [REV] Connect-phase failure (before client assignment) triggers retry when
    `loadBrokerSession(cwd)` indicates a broker was requested, even when
    `process.env[BROKER_ENDPOINT_ENV]` is not set (test 9)
11. [REV] Direct-connect failure (`connect(cwd, { disableBroker: true })` throws)
    produces a dual-failure error with `.brokerError` and `.directError`, NOT a
    raw propagated error (test 10)
12. [REV] Clean-close error (`"codex app-server connection closed."` with no
    `.code`) triggers retry (test 11)
13. [REV] `isRetriableBrokerError` returns false for errors with unrelated
    messages and no `.code` (e.g. `new Error("permission denied")`) -- covered
    by test 6 variant or inline assertion in test 11

**Required authority invariants:**
- The broker remains the primary connection path (no behavior change for
  single-task case)
- `app-server-broker.mjs` is NOT modified (single-socket design preserved)
- Direct-client fallback is a resilience mechanism, not a replacement for the
  broker
- `interruptAppServerTurn` is unchanged (DEC-CDX-004)
- `resolveLatestTrackedTaskThread` is unchanged (DEC-CDX-005)
- [REV] `loadBrokerSession()` is called read-only at the top of `withAppServer`
  to pre-compute `brokerRequested`. This must NOT modify state, start
  processes, or have side effects. `loadBrokerSession` (broker-lifecycle.mjs:76-87)
  only reads `broker.json` from disk -- verified safe.

**Required integration points:**
- `runAppServerReview()` works via broker or direct fallback (tested through
  `withAppServer` which it calls at line 779)
- `runAppServerTurn()` works via broker or direct fallback (tested through
  `withAppServer` which it calls at line 835)
- `findLatestTaskThread()` works via broker or direct fallback (tested through
  `withAppServer` which it calls at line 902)
- Progress events reach `createJobProgressUpdater()` through both paths
  (the `onProgress` callback is the same function object regardless of which
  transport `withAppServer` ends up using)
- `interruptAppServerTurn()` is NOT expected to work through fallback -- it
  uses its own connection logic and returns `{ interrupted: false }` on
  failure (this is correct behavior per DEC-CDX-004)
- [REV] `loadBrokerSession(cwd)` is already imported by `codex.mjs` at line 39.
  No new import is required. The call in `withAppServer` is a pure read that
  does not interfere with `ensureBrokerSession` called inside `connect()`.

**Forbidden shortcuts:**
- Do not modify `app-server-broker.mjs` (broker stays single-socket)
- Do not modify `codex-companion.mjs` (task guard is correct after W-CDX-2)
- Do not add broker connection pooling or multi-socket support
- Do not modify any file outside the plugin's `scripts/` directory
- Do not introduce external npm dependencies
- Do not use setTimeout-based retry or exponential backoff -- the fallback is
  a single immediate retry to direct, not a retry loop
- [REV] Do not add retry for errors thrown DURING `fn(client)` on the direct
  fallback path. Only the broker-to-direct fallback is retried; the direct
  path itself gets one attempt. Double-retry would compound replay risk.
- [REV] Do not modify `handleExit()` in `app-server.mjs` to add a `.code`
  property to the clean-close error. The message-based check in
  `isRetriableBrokerError` handles it without touching the app-server layer.

**Ready-for-guardian definition:**
All 11 tests pass. All W-CDX-1 and W-CDX-2 tests still pass. The exported
`withAppServer` function handles all five retriable error codes, the RPC busy
code, AND the message-based clean-close detection. Connect-phase failures
trigger retry when `loadBrokerSession` indicates a broker was requested.
Direct-connect failures produce dual-failure errors. Non-retriable errors
propagate cleanly. The progress callback fires on fallback. Replay safety is
documented (DEC-CDX-007). No changes to `app-server-broker.mjs`,
`app-server.mjs`, `codex-companion.mjs`, or any file outside the plugin's
`scripts/` directory.

###### Scope Manifest for W-CDX-3

**Allowed files/directories:**
- `plugins/marketplaces/openai-codex/plugins/codex/scripts/lib/codex.mjs` (modify)
- `plugins/marketplaces/openai-codex/plugins/codex/tests/test-broker-fallback.mjs` (new)

**Required files/directories:**
- `plugins/marketplaces/openai-codex/plugins/codex/scripts/lib/codex.mjs` (must be modified)
- `plugins/marketplaces/openai-codex/plugins/codex/tests/test-broker-fallback.mjs` (must be created)

**Forbidden touch points:**
- `app-server-broker.mjs` (broker is not modified per DEC-CDX-003)
- `app-server.mjs` (no changes needed -- error propagation is already correct;
  clean-close handled by message-based check per DEC-CDX-006)
- `codex-companion.mjs` (task guard works correctly after W-CDX-2 per DEC-CDX-005)
- `broker-lifecycle.mjs` (read-only use of `loadBrokerSession` -- no modifications)
- `state.mjs` (already handled by W-CDX-1/W-CDX-2)
- `tracked-jobs.mjs`, `job-control.mjs` (no changes needed)
- Any file outside `plugins/marketplaces/openai-codex/plugins/codex/`
- Core hook/runtime/policy files

**Expected state authorities touched:**
- MODIFIED: `codex.mjs` `withAppServer()` error handling -- complete
  restructuring: `brokerRequested` pre-computed from env + `loadBrokerSession`,
  extracted `isRetriableBrokerError()` with code + message matching, direct
  fallback path has `connect()` inside try/catch for dual-failure errors,
  new `options` parameter with `onProgress`, replay safety documented
  (DEC-CDX-007). Both `withAppServer` and `isRetriableBrokerError` are now
  exported (were private).
- UNCHANGED: broker architecture, app-server client classes (`handleExit`
  behavior is unchanged -- the clean-close error message is consumed as-is),
  state.json, job lifecycle, codex-companion task guard

### INIT-AUTODISPATCH: Automatic Role Sequencing Pipeline

- **Status:** planned
- **Blocked by:** none (operates on dispatch emission, prompt rules, and Codex
  gate wiring; no dependency on INIT-003/004/PE/CONV/CDX/TESTGAP/REBASE)
- **Problem:** The dispatch pipeline (planner -> implementer -> tester ->
  guardian) computes the correct `next_role` via `dispatch_engine.py` but the
  orchestrator treats every handoff as a user-approval prompt. The user is
  frustrated by constant approval requests at every role boundary. The gap is
  explicitly documented in `docs/DISPATCH.md:86-89`:
  > **Not Yet Enforced:** Automatic role sequencing. The
  > planner-to-implementer-to-tester-to-guardian flow is a convention the
  > orchestrator follows from prompt instructions. No hook blocks dispatching
  > out of order.

  The user wants: (1) the canonical chain to flow automatically, (2) the Codex
  stop-review gate as the quality checkpoint replacing manual user approval, and
  (3) the chain to stop only when a tester says needs_changes/blocked_by_plan,
  guardian needs explicit approval for high-risk ops, or Codex review says BLOCK.
- **Goal:** Close the "Not Yet Enforced: Automatic role sequencing" gap so the
  canonical dispatch chain flows without user intervention at every handoff, with
  the Codex review gate as the automated quality checkpoint.
- **Scope:** Four surfaces: `dispatch_engine.py` (one new field in result dict),
  `runtime/cli.py` (pass-through of new field), `post-task.sh` (emit
  `AUTO_DISPATCH:` directive), `CLAUDE.md` (auto-dispatch rules in Dispatch Rules
  section), `settings.json` (wire Codex gate into SubagentStop), and
  `docs/DISPATCH.md` (remove the gap from "Not Yet Enforced").
- **Exit:** (1) When dispatch_engine computes a clear next_role with no errors,
  `post-task.sh` emits `AUTO_DISPATCH: <role>` in hookSpecificOutput. (2) The
  orchestrator dispatches that role immediately without asking the user. (3) When
  `stopReviewGate` is enabled, the Codex gate runs at SubagentStop and can BLOCK
  the auto-dispatch. (4) The chain stops automatically for: tester
  needs_changes/blocked_by_plan with no auto-route, guardian high-risk ops
  (push/rebase/force), errors, Codex BLOCK verdicts, and interrupted agents.
  (5) `docs/DISPATCH.md` "Not Yet Enforced" section no longer lists automatic
  role sequencing.
- **Dependencies:** none

#### Design Rationale

**Why `auto_dispatch` as a field, not implicit from `next_role`:** There are
cases where `next_role` is computed but auto-dispatch should NOT happen:
interrupted agents (WARNING in suggestion), guardian high-risk ops that need
user approval, and Codex BLOCK verdicts. The explicit boolean makes the
auto-dispatch decision inspectable and testable independently of routing.

**Why wire Codex into SubagentStop, not keep it on Stop only:** The Codex
stop-review gate currently fires on the `Stop` hook event (session end). For
auto-dispatch, the quality checkpoint must run BETWEEN role completions -- at
SubagentStop time, after check-*.sh validates the role's output and before
auto-dispatch fires the next role. Keeping it on Stop only would mean the
quality gate runs too late (after all roles have already auto-dispatched).

**Why opt-in via `stopReviewGate` config:** Not all users want Codex reviewing
every role handoff. The existing `stopReviewGate: true/false` config in the
Codex plugin state controls whether the gate fires. When false, auto-dispatch
proceeds without the Codex review. When true, the gate runs at each
SubagentStop and can BLOCK auto-dispatch.

**Why the Codex gate runs AFTER check-*.sh but BEFORE post-task.sh:** The
check-*.sh hooks validate role output (completion contracts, trailers, scope).
The Codex gate reviews the work quality (architectural alignment, correctness).
post-task.sh reads both signals -- the dispatch_engine result AND the Codex
verdict -- to decide whether to emit `AUTO_DISPATCH:` or a suggestion.

**Hook chain ordering concern:** The current SubagentStop chain is
`[check-*.sh, post-task.sh]` per role. Adding the Codex gate between them
requires inserting a new hook entry. However, hooks in the same array run
sequentially and their outputs are independent -- each hook's JSON is merged
by the Claude runtime. The Codex gate hook must write its verdict to a
location that post-task.sh can read. Two options: (a) write to runtime state
(SQLite), (b) use a temporary file. We choose (a) for consistency with the
project's "runtime owns shared state" principle. The Codex gate writes its
verdict to an `events` table entry; post-task.sh reads the most recent
`codex_stop_review` event within a 60-second window.

**Auto-dispatch for interrupted agents:** When check-implementer.sh or the
completion contract detects an interrupted agent, the dispatch_engine sets
`auto_dispatch: false` and appends a WARNING to the suggestion. The orchestrator
sees the warning and can choose to resume the agent or dispatch the next role.
This is conservative -- an interrupted implementer should probably be resumed,
not replaced by a tester evaluating incomplete work.

#### Wave Decomposition

```
W-AD-1 (dispatch_engine + CLI + post-task.sh)
   └── W-AD-2 (CLAUDE.md auto-dispatch rules + docs/DISPATCH.md update)
        └── W-AD-3 (Codex gate SubagentStop wiring)
```

**Critical path:** W-AD-1 -> W-AD-2 -> W-AD-3
**Max width:** 1 (each wave depends on the prior for the signal contract)

W-AD-1 adds the `auto_dispatch` field and changes the hookSpecificOutput
format. W-AD-2 adds the orchestrator rules that act on `AUTO_DISPATCH:`.
W-AD-3 wires the Codex gate as the quality checkpoint that can override
auto-dispatch.

#### State Authority Map

| State Domain | Current Authority | INIT-AUTODISPATCH Change | Wave |
|---|---|---|---|
| Dispatch routing (next_role) | `dispatch_engine.py` via `process_agent_stop()` | Unchanged -- auto_dispatch is a new field alongside next_role | W-AD-1 |
| Dispatch suggestion text | `dispatch_engine.py` `suggestion` field | `AUTO_DISPATCH: <role>` directive replaces `Canonical flow suggests dispatching: <role>` when auto_dispatch is true | W-AD-1 |
| Codex stop-review verdict | Codex plugin `stop-review-gate-hook.mjs` on Stop event | Additionally fires on SubagentStop; verdict written to `events` table as `codex_stop_review` type | W-AD-3 |
| Orchestrator dispatch behavior | CLAUDE.md Dispatch Rules (prompt convention) | Explicit auto-dispatch rule: act on `AUTO_DISPATCH:` without asking user | W-AD-2 |
| hookSpecificOutput format | `post-task.sh` → `cli.py` process-stop handler | Pass-through of new `auto_dispatch` field; format change in suggestion text | W-AD-1 |

#### Known Risks

1. **Runaway chain.** If the tester always says `ready_for_guardian` and the
   guardian always says `committed`, the chain could loop without the user ever
   seeing what happened. Mitigation: the orchestrator must report what each role
   did after the chain completes (or stops). The user sees a summary, not
   nothing. Also, the chain is fundamentally bounded: guardian terminal states
   (committed, merged) return `next_role: None`, which terminates the chain.

2. **Codex gate latency.** The stop-review-gate-hook.mjs has a 15-minute
   timeout. At every SubagentStop, this could add minutes of latency.
   Mitigation: (a) the gate is opt-in via `stopReviewGate` config, (b) the
   gate prompt includes `last_assistant_message` which is the role's output --
   for status/setup turns it returns ALLOW immediately, (c) the timeout is per
   the existing Codex task infrastructure which spawns a background Codex
   process.

3. **Codex gate unavailable.** If Codex is not set up (not logged in, CLI not
   installed), the gate should not block auto-dispatch. Mitigation: the existing
   `buildSetupNote()` in stop-review-gate-hook.mjs already handles this -- it
   returns early without blocking. post-task.sh treats "no codex verdict" as
   "ALLOW" (fail-open for the quality gate, fail-closed for the safety gate).

4. **SubagentStop hook chain output merging.** When multiple hooks in the same
   SubagentStop array emit `hookSpecificOutput`, the Claude runtime merges them.
   If both the Codex gate hook and post-task.sh emit `hookSpecificOutput`, the
   merge behavior must be understood. Current observation: hooks in a chain run
   sequentially; each hook's output is an independent JSON object; the runtime
   concatenates `additionalContext` strings from all hooks in order.
   Mitigation: the Codex gate hook writes its verdict to SQLite (not
   hookSpecificOutput), so only post-task.sh emits the final dispatch directive.

5. **Existing Stop hook Codex gate.** The Codex gate currently fires on the
   `Stop` event (session end). Adding it to `SubagentStop` means it fires at
   both role boundaries AND session end. If `stopReviewGate` is true, the user
   gets Codex reviews at both points. This is intentional: SubagentStop reviews
   quality per-role, Stop reviews the session. If the user finds this redundant,
   they can disable `stopReviewGate` (which disables both) or we can add a
   separate per-event toggle later. We do not add that toggle in this initiative
   to keep scope minimal.

6. **Prompt compliance.** Auto-dispatch relies on the orchestrator (Claude)
   obeying the CLAUDE.md rule "When SubagentStop hook output contains
   `AUTO_DISPATCH: <role>`, dispatch that agent immediately without asking the
   user." This is a prompt instruction, not a mechanical gate. The orchestrator
   could still ask the user. Mitigation: this is the fundamental architecture of
   Claude Code hooks -- they advise, they do not force tool calls. The prompt
   rule is as strong as any other CLAUDE.md instruction. Mechanical enforcement
   of automatic dispatch would require changes to the Claude Code runtime itself,
   which is out of scope.

##### W-AD-1: Auto-Dispatch Signal in dispatch_engine and hookSpecificOutput

- **Weight:** M
- **Gate:** review
- **Deps:** none
- **Integration:** `dispatch_engine.py` is called by `cli.py` `process-stop`
  handler, which is called by `post-task.sh`. `post-task.sh` is in the
  SubagentStop hook chain for all four roles. Changing the result dict format
  requires updating the CLI handler to pass the new field through.

**Implementer scope:**

- `runtime/core/dispatch_engine.py`:
  - Add `auto_dispatch: bool` field to the result dict (default `False`).
  - Set `auto_dispatch = True` when ALL of:
    - `next_role` is not None
    - `error` is None
    - `is_interrupted` is False
    - The next_role is not guardian with a high-risk operation pending (for
      guardian: only auto-dispatch when the tester verdict was
      `ready_for_guardian` AND the guardian's expected operation is
      commit/merge, not push/rebase/force -- this is approximated by always
      auto-dispatching to guardian since guard.sh will deny the high-risk ops
      mechanically; the user approval gate is in `bash_approval_gate` policy)
  - For the `tester` role: when completion verdict is `needs_changes` or
    `blocked_by_plan`, set `auto_dispatch = True` (auto-dispatch back to
    implementer or planner respectively -- the user does not need to approve
    rework).
  - Change the suggestion format:
    - When `auto_dispatch` is true: prefix the suggestion with
      `AUTO_DISPATCH: <next_role>\n` followed by the existing detail text.
    - When `auto_dispatch` is false: keep the existing
      `Canonical flow suggests dispatching: <role>` format.
  - The interruption warning appended when `is_interrupted` is true already
    prevents auto-dispatch (since `auto_dispatch` is set false when
    interrupted).

- `runtime/cli.py`:
  - In the `process-stop` handler (around line 299-315), pass `auto_dispatch`
    through in the returned JSON: add `"auto_dispatch": result["auto_dispatch"]`
    to the `_ok()` payload.
  - Include `auto_dispatch` in the `hookSpecificOutput.additionalContext` when
    true: prepend `AUTO_DISPATCH: <next_role>\n` to the additionalContext string
    so the orchestrator sees it in the hook output.

- `hooks/post-task.sh`:
  - No routing logic changes (it remains a thin adapter per
    DEC-DISPATCH-ENGINE-001).
  - The hookSpecificOutput is already passed through from the CLI output. The
    CLI handler now includes the `AUTO_DISPATCH:` prefix in additionalContext
    when auto_dispatch is true, so post-task.sh needs no format changes -- it
    already echoes the CLI's hookSpecificOutput verbatim.

- `tests/runtime/test_dispatch_engine.py` (modify existing):
  - Add test: planner stop -> auto_dispatch=True, next_role=implementer
  - Add test: implementer stop (no interruption) -> auto_dispatch=True,
    next_role=tester
  - Add test: implementer stop (interrupted) -> auto_dispatch=False,
    next_role=tester
  - Add test: tester stop (ready_for_guardian) -> auto_dispatch=True,
    next_role=guardian
  - Add test: tester stop (needs_changes) -> auto_dispatch=True,
    next_role=implementer
  - Add test: tester stop (blocked_by_plan) -> auto_dispatch=True,
    next_role=planner
  - Add test: guardian stop (committed) -> auto_dispatch=False,
    next_role=None (cycle complete, no dispatch)
  - Add test: guardian stop (denied) -> auto_dispatch=True,
    next_role=implementer
  - Add test: error in routing -> auto_dispatch=False
  - Add test: suggestion text starts with `AUTO_DISPATCH:` when auto_dispatch
    is true
  - Add test: suggestion text starts with `Canonical flow suggests` when
    auto_dispatch is false

- `tests/scenarios/test-auto-dispatch-signal.sh` (new):
  - End-to-end: pipe synthetic JSON through `cc-policy dispatch process-stop`
    for each role and verify the hookSpecificOutput contains `AUTO_DISPATCH:`
    when expected and `Canonical flow suggests` when not.

**Tester scope:**

- Run all existing dispatch_engine tests -- verify no regression.
- Run the new auto_dispatch tests.
- Run the scenario test.
- Verify the hookSpecificOutput JSON from post-task.sh contains the
  `AUTO_DISPATCH:` prefix for happy-path transitions.
- Verify interrupted agents produce `auto_dispatch: false` with the WARNING.
- Verify error cases produce `auto_dispatch: false`.

###### Evaluation Contract for W-AD-1

**Required tests:**
- All existing tests in `tests/runtime/test_dispatch_engine.py` pass
- All new auto_dispatch tests pass (11 cases listed above)
- `test-auto-dispatch-signal.sh` scenario test passes

**Required real-path checks:**
1. `process_agent_stop()` returns `auto_dispatch` field in the result dict
2. `auto_dispatch` is `True` for planner -> implementer transition
3. `auto_dispatch` is `True` for implementer -> tester transition (not
   interrupted)
4. `auto_dispatch` is `False` for interrupted implementer -> tester
5. `auto_dispatch` is `True` for tester(ready_for_guardian) -> guardian
6. `auto_dispatch` is `True` for tester(needs_changes) -> implementer
7. `auto_dispatch` is `True` for tester(blocked_by_plan) -> planner
8. `auto_dispatch` is `False` for guardian(committed) -> None (cycle complete)
9. `auto_dispatch` is `True` for guardian(denied) -> implementer
10. `auto_dispatch` is `False` when `error` is not None
11. Suggestion text starts with `AUTO_DISPATCH: <role>` when auto_dispatch is
    true
12. Suggestion text starts with `Canonical flow suggests` when auto_dispatch is
    false
13. `cc-policy dispatch process-stop` JSON output includes `auto_dispatch` field
14. hookSpecificOutput `additionalContext` includes `AUTO_DISPATCH:` prefix when
    auto_dispatch is true

**Required authority invariants:**
- `dispatch_engine.py` remains the sole routing authority
- `completions.py` `determine_next_role()` remains the sole routing table
- `auto_dispatch` is derived from existing fields (next_role, error,
  is_interrupted) -- no new state authority introduced
- post-task.sh remains a thin adapter with no routing logic

**Required integration points:**
- `cli.py` process-stop handler passes `auto_dispatch` through
- post-task.sh echoes hookSpecificOutput verbatim (no changes needed)
- Existing check-*.sh hooks are not modified

**Forbidden shortcuts:**
- Do not add routing logic to post-task.sh
- Do not modify the completion record schema
- Do not modify the evaluation state machine
- Do not modify check-*.sh hooks
- Do not add a new SQLite table for auto-dispatch state
- Do not modify `completions.py` `determine_next_role()`

**Ready-for-guardian definition:**
All 14 real-path checks pass. All tests pass (existing + new). The
`auto_dispatch` field is present and correct in both Python dict and CLI JSON
output. hookSpecificOutput format changes are verified end-to-end.

###### Scope Manifest for W-AD-1

**Allowed files/directories:**
- `runtime/core/dispatch_engine.py` (modify)
- `runtime/cli.py` (modify)
- `tests/runtime/test_dispatch_engine.py` (modify)
- `tests/scenarios/test-auto-dispatch-signal.sh` (new)

**Required files/directories:**
- `runtime/core/dispatch_engine.py` (must be modified)
- `runtime/cli.py` (must be modified)
- `tests/runtime/test_dispatch_engine.py` (must be modified)
- `tests/scenarios/test-auto-dispatch-signal.sh` (must be created)

**Forbidden touch points:**
- `runtime/core/completions.py` (routing table unchanged)
- `runtime/core/evaluation.py` (eval state machine unchanged)
- `hooks/check-*.sh` (validation hooks unchanged)
- `hooks/post-task.sh` (thin adapter, needs no changes since CLI formats the
  hookSpecificOutput)
- `settings.json` (hook wiring unchanged in this wave)
- `CLAUDE.md` (prompt changes are W-AD-2)
- `docs/DISPATCH.md` (doc update is W-AD-2)
- `agents/*.md` (no agent prompt changes)
- `plugins/` (Codex gate wiring is W-AD-3)

**Expected state authorities touched:**
- MODIFIED: `dispatch_engine.py` result dict format (new `auto_dispatch` field)
- MODIFIED: `cli.py` process-stop JSON output (new `auto_dispatch` field,
  modified `additionalContext` format)
- UNCHANGED: completion_records, evaluation_state, dispatch_queue, agent_markers,
  events, leases

##### W-AD-2: Orchestrator Auto-Dispatch Rules and Documentation

- **Weight:** S
- **Gate:** approve (user must approve the CLAUDE.md rules before they become
  the orchestrator's dispatch behavior)
- **Deps:** W-AD-1 (the `AUTO_DISPATCH:` signal must exist in hookSpecificOutput
  before the orchestrator rules can reference it)
- **Integration:** CLAUDE.md is read by the orchestrator on every session.
  `docs/DISPATCH.md` is reference documentation. Both are governance markdown
  (planner-only writes).

**Implementer scope:**

- `CLAUDE.md` — Add a new subsection `### Auto-Dispatch` under `## Dispatch
  Rules`, after the existing `### Debugging Discipline` subsection:

  ```markdown
  ### Auto-Dispatch

  When SubagentStop hook output contains `AUTO_DISPATCH: <role>`, dispatch
  that agent immediately without asking the user. The dispatch engine has
  already validated that the transition is safe:
  - The prior role's completion contract was fulfilled
  - No errors were detected
  - The agent was not interrupted mid-task
  - The routing table determined a clear next role

  **Stop the chain and report to the user when:**
  - Hook output contains `BLOCKED`, `ERROR`, or `PROCESS ERROR`
  - Hook output does NOT contain `AUTO_DISPATCH:` (fallback to manual dispatch)
  - The Codex stop-review gate returned VERDICT: BLOCK
  - The evaluation_state is needs_changes or blocked_by_plan with a tester
    recommendation to halt (the auto-dispatch back to implementer/planner
    still fires -- only halt if the cycle is clearly stuck)

  **After the chain completes or stops, report what happened:**
  - Summarize each role's outcome (what the planner planned, what the
    implementer built, what the tester found, what the guardian landed)
  - If any role was auto-dispatched, note it was automatic
  - If the chain stopped early, explain why

  Auto-dispatch does NOT apply to:
  - Guardian operations that require user approval (push, rebase, force ops
    -- these are gated by bash_approval_gate policy)
  - The first dispatch in a new workflow (the user starts the chain)
  - Recovery after Codex BLOCK verdicts (the user must review findings first)
  ```

- `docs/DISPATCH.md` — Update the "Not Yet Enforced" section:
  - Remove "Automatic role sequencing" from the list.
  - Add a new section `## Auto-Dispatch` documenting the mechanism:
    - `AUTO_DISPATCH: <role>` signal in hookSpecificOutput
    - When it fires (all clear transitions)
    - When it does NOT fire (errors, interruptions, cycle-complete)
    - How the Codex gate integrates (opt-in via `stopReviewGate`)
  - Move "Automatic role sequencing" to the "Current Enforcement Surface"
    section under SubagentStop, noting it is now implemented.

**Tester scope:**

- Verify CLAUDE.md changes are limited to the new Auto-Dispatch subsection.
- Verify docs/DISPATCH.md accurately reflects the mechanism from W-AD-1.
- Verify no other CLAUDE.md sections are modified.
- Verify the rules match the auto_dispatch logic in dispatch_engine.py.

###### Evaluation Contract for W-AD-2

**Required checks:**
1. CLAUDE.md has a `### Auto-Dispatch` subsection under `## Dispatch Rules`
2. The subsection instructs the orchestrator to dispatch immediately on
   `AUTO_DISPATCH:` without asking the user
3. The subsection lists the stop conditions (BLOCKED, ERROR, no AUTO_DISPATCH,
   Codex BLOCK)
4. The subsection lists the reporting requirement (summarize chain outcomes)
5. The subsection lists the exclusions (guardian high-risk ops, first dispatch,
   Codex BLOCK recovery)
6. `docs/DISPATCH.md` no longer lists "Automatic role sequencing" under "Not
   Yet Enforced"
7. `docs/DISPATCH.md` has a new `## Auto-Dispatch` section documenting the
   mechanism
8. No other sections of CLAUDE.md are modified
9. No files outside CLAUDE.md and docs/DISPATCH.md are modified

**Required authority invariants:**
- CLAUDE.md remains the orchestrator's judgment layer (prompt guidance)
- Auto-dispatch is a prompt instruction, not a mechanical gate
- docs/DISPATCH.md remains the dispatch reference documentation

**Forbidden shortcuts:**
- Do not modify any hook, runtime, or test file
- Do not modify agents/*.md
- Do not add new Sacred Practices
- Do not modify the existing Dispatch Rules subsections (Source Edit Routing,
  Integration Surface Context, Uncertainty Reporting, Simple Task Fast Path,
  Debugging Discipline)

**Ready-for-guardian definition:**
All 9 checks pass. CLAUDE.md diff shows only the new Auto-Dispatch subsection.
docs/DISPATCH.md diff shows the gap removal and new section.

###### Scope Manifest for W-AD-2

**Allowed files/directories:**
- `CLAUDE.md` (modify: add Auto-Dispatch subsection)
- `docs/DISPATCH.md` (modify: remove gap, add Auto-Dispatch section)

**Required files/directories:**
- `CLAUDE.md` (must be modified)
- `docs/DISPATCH.md` (must be modified)

**Forbidden touch points:**
- `runtime/` (no runtime changes)
- `hooks/` (no hook changes)
- `tests/` (no test changes)
- `settings.json` (no hook wiring changes)
- `agents/*.md` (no agent prompt changes)
- `plugins/` (Codex gate wiring is W-AD-3)
- `MASTER_PLAN.md` (except for this planning amendment)

**Expected state authorities touched:**
- None (prompt and documentation changes only)

##### W-AD-3: Codex Stop-Review Gate at SubagentStop

- **Weight:** M
- **Gate:** review
- **Deps:** W-AD-1 (auto_dispatch signal must exist), W-AD-2 (orchestrator must
  know how to act on AUTO_DISPATCH and Codex BLOCK)
- **Integration:** The Codex plugin's `stop-review-gate-hook.mjs` is currently
  wired to the `Stop` event in the plugin's `hooks.json`. This wave adds it to
  the core `settings.json` SubagentStop chain for all four roles, positioned
  AFTER check-*.sh and BEFORE post-task.sh. The gate writes its verdict to the
  runtime `events` table; post-task.sh reads it to gate auto_dispatch.

**Design detail for Codex gate -> dispatch_engine communication:**

The Codex gate hook runs as a separate hook in the SubagentStop chain. It cannot
directly modify dispatch_engine's result. Instead:

1. The Codex gate hook (`stop-review-gate-hook.mjs`) runs after check-*.sh.
2. If `stopReviewGate` is enabled and Codex is available, it runs the review.
3. It writes the verdict to the runtime `events` table via `cc-policy event emit
   --type codex_stop_review --detail "VERDICT: ALLOW|BLOCK <reason>"`.
4. post-task.sh, which runs after the Codex gate hook, calls dispatch
   process-stop as before. dispatch_engine reads the most recent
   `codex_stop_review` event within a 60-second window.
5. If the verdict is BLOCK, dispatch_engine overrides `auto_dispatch` to false
   and appends the block reason to the suggestion.
6. If no recent verdict is found (Codex not enabled, or not available),
   dispatch_engine treats it as ALLOW (fail-open for quality gate).

This keeps the Codex gate as a pure event emitter and dispatch_engine as the
sole decision authority.

**Alternative considered and rejected:** Having the Codex gate emit
`hookSpecificOutput` with a BLOCK decision that Claude sees alongside the
post-task.sh output. Rejected because: (a) the hook output merge behavior is
additive (both outputs appear), making it harder to create a single clear
directive, and (b) the dispatch_engine should own the final auto_dispatch
decision, not have it split between two hooks.

**Implementer scope:**

- `runtime/core/dispatch_engine.py`:
  - Add a `_check_codex_gate()` helper that queries the `events` table for the
    most recent `codex_stop_review` event within a 60-second window matching
    the current workflow_id.
  - Returns `(blocked: bool, reason: str)`.
  - Call `_check_codex_gate()` after computing `auto_dispatch = True` but
    before building the suggestion. If blocked, set `auto_dispatch = False` and
    append the block reason to the suggestion.
  - This is advisory — errors in the lookup never block routing (same pattern
    as `_detect_interrupted`).

- `settings.json`:
  - Add the Codex stop-review gate hook to all four SubagentStop arrays,
    positioned AFTER check-*.sh and BEFORE post-task.sh:
    ```json
    {
      "type": "command",
      "command": "$HOME/.claude/plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs",
      "timeout": 900
    }
    ```
  - The hook is safe to add even when Codex is not configured: the existing
    `stop-review-gate-hook.mjs` checks `config.stopReviewGate` and returns
    early (no-op) when false.

- `plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs`:
  - Modify to detect when invoked as SubagentStop vs Stop:
    - Read the hook input JSON. SubagentStop input includes `agent_type` field;
      Stop input does not.
    - When invoked as SubagentStop: after running the review and getting the
      verdict, write the verdict to the runtime events table via
      `cc-policy event emit --type codex_stop_review --detail "VERDICT: <verdict> | workflow=<wf_id> | <reason>"`.
    - When invoked as Stop: keep existing behavior (emit `decision: block` to
      hookSpecificOutput to prevent session end).
  - The SubagentStop path should NOT emit `decision: block` to hookSpecificOutput
    (that would prevent the orchestrator from seeing the hook output). Instead,
    it only writes to the events table and lets dispatch_engine handle the
    blocking.

- `tests/runtime/test_dispatch_engine.py` (modify):
  - Add test: auto_dispatch=True with no codex_stop_review event -> stays True
  - Add test: auto_dispatch=True with ALLOW verdict event -> stays True
  - Add test: auto_dispatch=True with BLOCK verdict event -> becomes False,
    suggestion includes block reason
  - Add test: auto_dispatch=False (error) with BLOCK verdict -> stays False
    (BLOCK does not change an already-false auto_dispatch)
  - Add test: stale codex_stop_review event (>60s old) -> ignored, auto_dispatch
    stays True

- `tests/scenarios/test-codex-gate-stop.sh` (new):
  - Emit a synthetic `codex_stop_review` BLOCK event, then run dispatch
    process-stop for implementer. Verify auto_dispatch is false and suggestion
    includes the block reason.
  - Emit a synthetic `codex_stop_review` ALLOW event, then run dispatch
    process-stop for implementer. Verify auto_dispatch is true.

**Tester scope:**

- Verify Codex gate hook is in all four SubagentStop arrays in settings.json.
- Verify the hook writes to events table when invoked as SubagentStop.
- Verify dispatch_engine reads the verdict and gates auto_dispatch.
- Run all existing tests -- no regression.
- Run new tests.
- Manually: with `stopReviewGate: false`, verify the gate is a no-op at
  SubagentStop.
- Manually: with `stopReviewGate: true` and Codex available, verify the gate
  runs and writes a verdict.

###### Evaluation Contract for W-AD-3

**Required tests:**
- All existing tests in `tests/runtime/test_dispatch_engine.py` pass
- All new Codex gate tests pass (5 cases listed above)
- `test-codex-gate-stop.sh` scenario test passes
- All existing scenario tests pass (no regression)

**Required real-path checks:**
1. `settings.json` has the Codex gate hook in all four SubagentStop arrays,
   positioned after check-*.sh and before post-task.sh
2. `stop-review-gate-hook.mjs` detects SubagentStop invocation via `agent_type`
   field presence
3. On SubagentStop with `stopReviewGate: true`, the hook writes a
   `codex_stop_review` event to the events table
4. On SubagentStop with `stopReviewGate: false`, the hook is a no-op
5. `dispatch_engine.py` `_check_codex_gate()` reads the most recent
   `codex_stop_review` event within 60 seconds
6. BLOCK verdict sets `auto_dispatch = False` and appends reason to suggestion
7. ALLOW verdict (or no verdict) leaves `auto_dispatch` unchanged
8. Stale events (>60s) are ignored
9. Errors in the Codex gate lookup never block routing
10. On Stop event, the hook still uses existing behavior (decision: block to
    hookSpecificOutput)

**Required authority invariants:**
- `dispatch_engine.py` remains the sole auto_dispatch decision authority
- The Codex gate is an event emitter, not a decision authority
- `events` table is the communication channel (not flat files, not
  hookSpecificOutput merging)
- The `stopReviewGate` config in the Codex plugin state is the sole toggle
- No new SQLite table is introduced (uses existing `events` table)

**Required integration points:**
- `stop-review-gate-hook.mjs` writes to events via `cc-policy event emit`
- `dispatch_engine.py` reads events via `events.query()`
- `settings.json` hook ordering: check-*.sh -> codex-gate -> post-task.sh
- Existing Stop hook behavior is unchanged

**Forbidden shortcuts:**
- Do not have the Codex gate emit `decision: block` on SubagentStop (that
  would misuse the hook output contract)
- Do not have dispatch_engine call the Codex API directly (separation of
  concerns)
- Do not create a new SQLite table for Codex verdicts (use existing events)
- Do not make the Codex gate mandatory (must respect stopReviewGate config)
- Do not modify the stop-review prompt template
  (`prompts/stop-review-gate.md`)
- Do not modify check-*.sh hooks
- Do not modify `completions.py` or `evaluation.py`

**Ready-for-guardian definition:**
All 10 real-path checks pass. All tests pass (existing + new). The Codex gate
fires at SubagentStop when enabled and writes verdicts to the events table.
dispatch_engine correctly reads verdicts and gates auto_dispatch. The existing
Stop hook behavior is unchanged. settings.json hook ordering is correct.

###### Scope Manifest for W-AD-3

**Allowed files/directories:**
- `runtime/core/dispatch_engine.py` (modify: add _check_codex_gate)
- `settings.json` (modify: add Codex gate to SubagentStop arrays)
- `plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs` (modify: SubagentStop detection and event writing)
- `tests/runtime/test_dispatch_engine.py` (modify: add Codex gate tests)
- `tests/scenarios/test-codex-gate-stop.sh` (new)

**Required files/directories:**
- `runtime/core/dispatch_engine.py` (must be modified)
- `settings.json` (must be modified)
- `plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs` (must be modified)
- `tests/runtime/test_dispatch_engine.py` (must be modified)
- `tests/scenarios/test-codex-gate-stop.sh` (must be created)

**Forbidden touch points:**
- `runtime/core/completions.py` (routing table unchanged)
- `runtime/core/evaluation.py` (eval state machine unchanged)
- `hooks/check-*.sh` (validation hooks unchanged)
- `hooks/post-task.sh` (thin adapter, no changes needed)
- `CLAUDE.md` (prompt changes were W-AD-2)
- `docs/DISPATCH.md` (doc update was W-AD-2)
- `agents/*.md` (no agent prompt changes)
- `plugins/.../prompts/stop-review-gate.md` (prompt template unchanged)
- `runtime/schemas.py` (no schema changes -- uses existing events table)

**Expected state authorities touched:**
- MODIFIED: `dispatch_engine.py` auto_dispatch decision (now reads Codex gate
  events)
- MODIFIED: `events` table (new event type: `codex_stop_review`)
- MODIFIED: `settings.json` SubagentStop hook arrays (new Codex gate entry)
- MODIFIED: `stop-review-gate-hook.mjs` (SubagentStop detection + event writing)
- UNCHANGED: completion_records, evaluation_state, dispatch_queue, agent_markers,
  leases, Codex plugin state.json


### INIT-OBS: Native Observatory

- **Status:** planned
- **Blocked by:** none (reads existing runtime tables; new tables are additive;
  hook emission changes are small and independent of other initiatives)
- **Problem:** The hooks and runtime already compute rich operational data
  (agent lifecycle, test results, guard denials, evaluation verdicts, commit
  outcomes, files changed, session duration) but discard most of it. There is
  no self-improvement flywheel: no mechanism surfaces recurring failure
  patterns, inefficiencies, or improvement opportunities. The pro fork had an
  observatory but it was built on filesystem traces (59% orphan rate,
  rebuild_index() required, corrupt manifests), JSONL time series (tmp+mv
  dance for atomic append), and 1,000+ lines of bash pipeline. Our fork has
  SQLite as the trace store, structured completion records, and a Python
  runtime -- the right substrate to build this natively.
- **Goal:** Build a self-improvement flywheel that: (1) emits structured
  metrics from existing hooks into SQLite, (2) provides SQL-based analysis
  replacing bash pipelines, (3) tracks suggestions through a closed-loop
  lifecycle (propose -> accept/reject/defer -> measure impact), and (4) exposes
  the synthesis layer as a SKILL.md the LLM can invoke on demand.
- **Scope:** Wave 1: Schema + domain module + CLI (tables, Python API,
  cc-policy commands). Wave 2: Hook emission (small additions to existing
  hooks, no new hooks). Wave 3: Analysis queries + SKILL.md (SQL-based analysis
  functions, convergence tracking, LLM synthesis skill). Wave 4: Integration
  tests + observatory upgrade (replace existing bare sidecar with full
  observatory).
- **Exit:** (1) `obs_metrics` and `obs_suggestions` tables exist and are
  populated by live hooks. (2) `cc-policy obs` CLI provides analyze, suggest,
  accept, reject, defer, and converge commands. (3) At least 8 metrics are
  emitted from hooks (agent duration, test pass rate, guard denial rate,
  evaluation verdict distribution, commit success rate, files per session,
  hook failure rate, session duration). (4) Convergence tracking measures
  whether accepted suggestions improved their target metric. (5) A SKILL.md
  exists that the LLM can invoke to analyze trends, surface patterns, and
  manage suggestions. (6) The existing bare `sidecars/observatory/observe.py`
  is upgraded to use the new analysis infrastructure.
- **Dependencies:** none (additive; does not require any other initiative)

#### Observatory Design

**Why not port the pro fork's observatory:**

The pro fork's observatory had three stages: `analyze.sh` (540 lines) scanned
filesystem trace directories and computed metrics via jq; `snapshot.sh` (240
lines) transformed the filesystem data into JSONL time series;
`converge.sh` (240 lines) tracked suggestion lifecycle. This pipeline had
fundamental problems:

1. Filesystem traces had a 59% orphan rate (TTL-deleted dirs left stale index
   references)
2. `rebuild_index()` was required before every analysis
3. Corrupt manifests crashed jq silently
4. Atomic JSONL append required tmp+mv dance for concurrency safety
5. `snapshot.sh` existed solely to transform filesystem data into queryable
   format -- it would be unnecessary with SQL
6. Required `source-lib.sh -> trace-lib.sh -> state-lib.sh` library chain we
   do not have

Our fork has none of these problems. SQLite is the trace store. The runtime
has structured tables for everything the observatory needs. Analysis should be
SQL queries, not jq pipelines.

**Data flow architecture:**

```
Hooks (emission)          Runtime (storage)         Observatory (analysis)
  subagent-start.sh  --+
  check-*.sh         --+                          +-- obs_analyze()
  test-runner.sh     --+-- rt_obs_metric() --> obs_metrics  --+
  auto-review.sh     --+                          |   obs_suggest()
  track.sh           --+                          |   obs_converge()
  session-end.sh     --+                          +-- SKILL.md (LLM)
                                                       |
                                                  obs_suggestions
                                                  (lifecycle mgmt)
```

**What hooks emit (additive, not new hooks):**

| Metric Name | Source Hook | Data | Frequency |
|---|---|---|---|
| `agent_duration_s` | `check-*.sh` (via post-task.sh) | role, duration seconds, verdict | Every agent stop |
| `test_result` | `test-runner.sh` | pass/fail/skip counts, duration | Every test run |
| `guard_denial` | `pre-write.sh`, `pre-bash.sh` | policy name, reason | Every denial |
| `eval_verdict` | `check-tester.sh` | verdict, blockers/major/minor | Every evaluator run |
| `commit_outcome` | `check-guardian.sh` | result, operation class | Every guardian run |
| `files_changed` | `track.sh` | count | Every file write |
| `hook_failure` | `log.sh` (error handler) | hook name, exit code | Every hook failure |
| `session_summary` | `session-end.sh` | prompts, duration, agents spawned | Every session end |

**Metric schema (obs_metrics):**

```sql
CREATE TABLE IF NOT EXISTS obs_metrics (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    metric_name TEXT    NOT NULL,
    value       REAL    NOT NULL,
    labels_json TEXT,
    session_id  TEXT,
    created_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_obs_metrics_name_time
    ON obs_metrics (metric_name, created_at);
```

- `metric_name`: one of the defined metric names above
- `value`: numeric value (duration in seconds, count, 0/1 for boolean)
- `labels_json`: JSON object with dimension keys for filtering (e.g.,
  `{"role": "implementer", "verdict": "complete"}`)
- `session_id`: links to the traces table for session context
- `created_at`: epoch timestamp for time series queries

**Suggestion schema (obs_suggestions):**

```sql
CREATE TABLE IF NOT EXISTS obs_suggestions (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    category        TEXT    NOT NULL,
    title           TEXT    NOT NULL,
    body            TEXT,
    target_metric   TEXT,
    baseline_value  REAL,
    status          TEXT    NOT NULL DEFAULT 'proposed',
    disposition_at  INTEGER,
    measure_after   INTEGER,
    measured_value  REAL,
    effective       INTEGER,
    source_session  TEXT,
    created_at      INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_obs_suggestions_status
    ON obs_suggestions (status);
```

- `category`: pattern type (e.g., `repeated_denial`, `slow_agent`,
  `test_regression`, `stale_marker`, `evaluation_churn`)
- `target_metric`: which metric this suggestion claims to improve
- `baseline_value`: the metric's value at suggestion time (for convergence)
- `status`: `proposed`, `accepted`, `rejected`, `deferred`, `measured`
- `measure_after`: epoch after which convergence should be checked
- `measured_value`: the metric's value at convergence check time
- `effective`: convergence result (1 = improved, 0 = no change, -1 = regressed)

**Suggestion lifecycle:**

```
proposed --> accepted --> measured (effective=1: fix worked)
    |            |              +--> measured (effective=0: ineffective fix)
    |            |              +--> measured (effective=-1: regression)
    +--> rejected
    +--> deferred --> proposed (re-surface after N sessions)
```

**Convergence tracking:**

When a suggestion is accepted, the observatory records the `baseline_value`
of the `target_metric` and sets `measure_after` to `now + N sessions` (or
N days). When the convergence check runs:
1. Query the target metric's average over the measurement window
2. Compare to baseline_value
3. Set `effective` to 1 (improved), 0 (no change), or -1 (regressed)
4. Set status to `measured`
5. If ineffective, the LLM synthesis layer can propose a revised suggestion

**Analysis functions (SQL-based, replacing 540-line analyze.sh):**

The `runtime/core/observatory.py` domain module provides:

- `emit_metric(conn, name, value, labels, session_id)` -- insert a metric row
- `query_metrics(conn, name, since, until, labels_filter)` -- time series
- `compute_trend(conn, name, window_hours)` -- moving average with slope
- `detect_anomalies(conn, name, threshold_sigma)` -- values beyond N sigma
- `agent_performance(conn, role, window_hours)` -- duration/verdict stats
- `denial_hotspots(conn, window_hours)` -- most-denied policies
- `test_health(conn, window_hours)` -- pass rate trend
- `suggest(conn, category, title, body, target_metric, baseline)` -- create
- `accept_suggestion(conn, id, measure_after)` -- accept with measurement window
- `reject_suggestion(conn, id)` -- reject
- `defer_suggestion(conn, id)` -- defer
- `check_convergence(conn)` -- measure all accepted suggestions past their window
- `summary(conn, window_hours)` -- full observatory report dict

#### Wave Plan

```
W-OBS-1 (Schema + Domain + CLI)
    +--> W-OBS-2 (Hook Emission)
              +--> W-OBS-3 (Analysis + SKILL.md)
                        +--> W-OBS-4 (Integration Tests + Sidecar Upgrade)
```

W-OBS-1 must land first (tables and API exist). W-OBS-2 depends on W-OBS-1
(emission needs the domain module). W-OBS-3 depends on W-OBS-2 (analysis
needs data). W-OBS-4 depends on W-OBS-3 (integration tests exercise the full
pipeline).

Critical path: W-OBS-1 -> W-OBS-2 -> W-OBS-3 -> W-OBS-4. Max width: 1.

##### W-OBS-1: Schema, Domain Module, and CLI

- **Weight:** M
- **Gate:** review (user sees schema and CLI output)
- **Deps:** none

**Implementer scope:**

- `runtime/schemas.py` -- add `OBS_METRICS_DDL`, `OBS_METRICS_INDEX_DDL`,
  `OBS_SUGGESTIONS_DDL`, `OBS_SUGGESTIONS_INDEX_DDL` constants and add them
  to `ALL_DDL`.
- `runtime/core/observatory.py` -- NEW: domain module with all functions
  listed in the "Analysis functions" section above. Each function takes a
  `sqlite3.Connection` as first argument (consistent with all other domain
  modules). Pure SQL queries, no subprocess calls.
- `runtime/cli.py` -- add `obs` domain with actions:
  - `cc-policy obs emit <name> <value> [--labels '...'] [--session-id '...']`
  - `cc-policy obs query <name> [--since N] [--until N] [--labels '...'] [--limit N]`
  - `cc-policy obs trend <name> [--window-hours N]`
  - `cc-policy obs anomalies <name> [--threshold N]`
  - `cc-policy obs agent-perf <role> [--window-hours N]`
  - `cc-policy obs denial-hotspots [--window-hours N]`
  - `cc-policy obs test-health [--window-hours N]`
  - `cc-policy obs suggest <category> <title> [--body '...'] [--target-metric '...'] [--baseline N]`
  - `cc-policy obs accept <id> [--measure-after N]`
  - `cc-policy obs reject <id>`
  - `cc-policy obs defer <id>`
  - `cc-policy obs converge`
  - `cc-policy obs summary [--window-hours N]`
- `hooks/lib/runtime-bridge.sh` -- add `rt_obs_metric()` shell wrapper:
  `rt_obs_metric <name> <value> [labels_json] [session_id]` calling
  `cc_policy obs emit "$1" "$2" --labels "${3:-}" --session-id "${4:-}"`
  with `>/dev/null 2>&1` for fire-and-forget semantics.
  Export via the existing export block.
- `hooks/context-lib.sh` -- add `rt_obs_metric` to the export list.
- `tests/runtime/test_observatory.py` -- NEW: unit tests covering:
  - emit_metric round-trip (emit, query, verify)
  - compute_trend with synthetic data
  - detect_anomalies with synthetic outlier
  - suggest/accept/reject/defer lifecycle
  - check_convergence with improved/unchanged/regressed scenarios
  - summary output structure
  - agent_performance query
  - denial_hotspots query
  - test_health query

**Tester scope:**

- `obs_metrics` and `obs_suggestions` tables exist after `ensure_schema()`
- `emit_metric` writes a row; `query_metrics` reads it back with correct values
- `compute_trend` returns slope and average
- `detect_anomalies` returns outliers beyond threshold
- `suggest` -> `accept` -> `check_convergence` lifecycle produces measured status
- CLI `cc-policy obs emit/query/suggest/accept/reject/defer/converge/summary`
  all produce valid JSON output
- `rt_obs_metric` shell wrapper calls `cc-policy obs emit` successfully
- No writes to any existing table (obs tables only)
- All existing tests pass

###### Evaluation Contract for W-OBS-1

**Required tests:**

1. `tests/runtime/test_observatory.py` exists and passes with 0 failures
2. `emit_metric` + `query_metrics` round-trip returns matching data
3. `compute_trend` with 10+ data points returns dict with `slope` and `average`
4. `detect_anomalies` with injected outlier returns the outlier
5. Full suggestion lifecycle: propose -> accept -> measure -> converge
6. `check_convergence` correctly classifies improved (effective=1),
   unchanged (effective=0), and regressed (effective=-1) metrics
7. `summary` returns dict with keys: `metrics_24h`, `active_suggestions`,
   `recent_anomalies`, `convergence_results`, `agent_performance`,
   `denial_hotspots`, `test_health`

**Required real-path checks:**

8. `cc-policy obs emit test_metric 42.0 --labels '{"key":"val"}'` writes a row
   to `obs_metrics`
9. `cc-policy obs query test_metric` returns the row from check 8
10. `cc-policy obs suggest test_cat "Test Title"` creates an obs_suggestions row
11. `cc-policy obs summary` returns valid JSON without error
12. `rt_obs_metric test_metric 42.0 '{"key":"val"}'` in a bash context
    succeeds without error

**Required authority invariants:**

- `obs_metrics` is the sole store for observatory metrics (no JSONL, no flat
  files)
- `obs_suggestions` is the sole store for suggestion lifecycle (no flat files)
- No reads or writes to any existing table (events, traces, completion_records,
  etc.) from the observatory domain module in this wave -- analysis queries
  that join across tables come in W-OBS-3
- `ensure_schema()` creates both new tables idempotently

**Required integration points:**

- `runtime/schemas.py` `ALL_DDL` list includes the new DDL constants
- `runtime/cli.py` obs domain registered alongside existing domains
- `hooks/lib/runtime-bridge.sh` exports `rt_obs_metric` alongside existing
  `rt_*` functions
- `hooks/context-lib.sh` export list includes `rt_obs_metric`

**Forbidden shortcuts:**

- Do not create a separate database for observatory data
- Do not add observatory methods to existing domain modules (events.py,
  traces.py, etc.) -- keep it in its own `observatory.py`
- Do not modify `settings.json`
- Do not modify any hook logic (emission is W-OBS-2)
- Do not add JSONL or flat-file output

**Ready-for-guardian definition:**

All 12 checks pass. Authority invariants hold. No forbidden shortcuts taken.
`git diff --stat` shows only files in the Scope Manifest.

###### Scope Manifest for W-OBS-1

**Allowed files/directories:**

- `runtime/schemas.py` (modify: add DDL constants)
- `runtime/core/observatory.py` (new: domain module)
- `runtime/cli.py` (modify: add obs domain)
- `hooks/lib/runtime-bridge.sh` (modify: add rt_obs_metric wrapper)
- `hooks/context-lib.sh` (modify: add rt_obs_metric to export list)
- `tests/runtime/test_observatory.py` (new: unit tests)

**Required files/directories:** All 6 of the above must be created or modified.

**Forbidden touch points:**

- `settings.json` (no new hooks)
- `hooks/*.sh` except context-lib.sh (emission is W-OBS-2)
- `agents/*.md`, `CLAUDE.md` (no prompt changes)
- `sidecars/observatory/observe.py` (sidecar upgrade is W-OBS-4)
- `runtime/core/events.py`, `runtime/core/traces.py`,
  `runtime/core/completions.py`, `runtime/core/test_state.py` (observatory
  does not modify other domain modules)
- `MASTER_PLAN.md` (except for this planning amendment)

**Expected state authorities touched:**

- NEW: `obs_metrics` table -- sole authority for observatory time series
- NEW: `obs_suggestions` table -- sole authority for suggestion lifecycle
- MODIFIED: `runtime/schemas.py` ALL_DDL -- new entries appended
- MODIFIED: `runtime/cli.py` -- new domain handler registered
- MODIFIED: `hooks/lib/runtime-bridge.sh` -- new shell wrapper added
- MODIFIED: `hooks/context-lib.sh` -- export list extended
- UNCHANGED: all existing tables, hooks, policies, sidecars

##### W-OBS-2: Hook Emission

- **Weight:** M
- **Gate:** review (user sees metric data flowing into obs_metrics)
- **Deps:** W-OBS-1 (tables and rt_obs_metric must exist)

**Implementer scope:**

Each hook below gains a small addition (1-3 lines) calling `rt_obs_metric`.
No hook logic is changed; emission is appended after existing processing.

- `hooks/check-implementer.sh` -- after completion record submission, emit
  `agent_duration_s` metric with labels `{"role":"implementer","verdict":"..."}`.
  Duration computed from marker `started_at` to current epoch.
- `hooks/check-tester.sh` -- after evaluation state write, emit
  `agent_duration_s` with labels `{"role":"tester","verdict":"..."}` and
  `eval_verdict` with labels `{"verdict":"...","blockers":N,"major":N,"minor":N}`.
- `hooks/check-guardian.sh` -- after landing result, emit `agent_duration_s`
  with labels `{"role":"guardian","verdict":"..."}` and `commit_outcome` with
  labels `{"result":"...","operation_class":"..."}`.
- `hooks/check-planner.sh` -- after planner checks, emit `agent_duration_s`
  with labels `{"role":"planner"}`.
- `hooks/test-runner.sh` -- after test completion, emit `test_result` with
  labels `{"status":"...","pass":N,"fail":N,"skip":N}` and value = duration
  seconds.
- `hooks/pre-write.sh` -- when policy denies (exit with deny JSON), emit
  `guard_denial` with value 1 and labels `{"policy":"...","hook":"pre-write"}`.
- `hooks/pre-bash.sh` -- when policy denies, emit `guard_denial` with value 1
  and labels `{"policy":"...","hook":"pre-bash"}`.
- `hooks/track.sh` -- after file tracking, emit `files_changed` with value =
  count of files.
- `hooks/session-end.sh` -- emit `session_summary` with value = session
  duration seconds and labels `{"prompt_count":N,"agents_spawned":N}`.
- `hooks/log.sh` -- in the error handler (if one exists or add a minimal trap),
  emit `hook_failure` with value 1 and labels `{"hook":"...","exit_code":N}`.
  This is best-effort; if the runtime is unavailable, the failure itself should
  not cascade.

**Tester scope:**

- Each modified hook emits the expected metric after its normal processing
- Metric values are numerically correct (duration matches actual elapsed,
  counts match actual counts)
- Labels JSON is valid and contains the expected keys
- Emission failures do not prevent the hook from completing its primary function
  (all rt_obs_metric calls have `|| true` or equivalent error suppression)
- No hook behavior changes (deny/allow decisions unchanged; output unchanged)
- All existing tests pass
- At least one new metric row appears in `obs_metrics` for each emission point
  after a representative hook execution

###### Evaluation Contract for W-OBS-2

**Required tests:**

1. After running check-implementer.sh with a mock agent stop, `obs_metrics`
   contains an `agent_duration_s` row with `role=implementer`
2. After running check-tester.sh with a valid eval trailer, `obs_metrics`
   contains `agent_duration_s` (role=tester) and `eval_verdict` rows
3. After running check-guardian.sh with a landing result, `obs_metrics`
   contains `commit_outcome` row
4. After running test-runner.sh, `obs_metrics` contains `test_result` row
5. After a pre-write.sh denial, `obs_metrics` contains `guard_denial` row
   with `hook=pre-write`
6. After a pre-bash.sh denial, `obs_metrics` contains `guard_denial` row
   with `hook=pre-bash`
7. After track.sh fires, `obs_metrics` contains `files_changed` row
8. After session-end.sh fires, `obs_metrics` contains `session_summary` row
9. All emission calls include `|| true` or equivalent so hook primary
   function is not impacted by emission failure
10. No existing test regressions

**Required real-path checks:**

11. Run a representative hook sequence (session-init -> subagent-start ->
    check-implementer -> check-tester -> check-guardian -> session-end) and
    verify obs_metrics has rows for each expected metric
12. `cc-policy obs query agent_duration_s` returns the rows from check 11

**Required authority invariants:**

- No hook deny/allow decision is changed by emission
- No hook output format is changed by emission
- `obs_metrics` is the only table written by emission (no new event types
  in the events table for metrics)
- rt_obs_metric calls are fire-and-forget (non-blocking on hook completion)

**Required integration points:**

- Each emission site is in the same function/block where the relevant data is
  computed (e.g., duration is computed where the marker is read, not
  re-computed elsewhere)
- context-lib.sh sources and exports rt_obs_metric so all hooks have access

**Forbidden shortcuts:**

- Do not add new hook files or settings.json entries
- Do not change hook deny/allow logic
- Do not change hook output JSON structure
- Do not emit metrics to the events table (use obs_metrics)
- Do not add synchronous waits for metric emission

**Ready-for-guardian definition:**

All 12 checks pass. Authority invariants hold. No forbidden shortcuts taken.
Emission is non-blocking. `git diff --stat` shows only files in the Scope
Manifest.

###### Scope Manifest for W-OBS-2

**Allowed files/directories:**

- `hooks/check-implementer.sh` (modify: add agent_duration_s emission)
- `hooks/check-tester.sh` (modify: add agent_duration_s + eval_verdict emission)
- `hooks/check-guardian.sh` (modify: add agent_duration_s + commit_outcome)
- `hooks/check-planner.sh` (modify: add agent_duration_s emission)
- `hooks/test-runner.sh` (modify: add test_result emission)
- `hooks/pre-write.sh` (modify: add guard_denial emission on deny path)
- `hooks/pre-bash.sh` (modify: add guard_denial emission on deny path)
- `hooks/track.sh` (modify: add files_changed emission)
- `hooks/session-end.sh` (modify: add session_summary emission)
- `hooks/log.sh` (modify: add hook_failure emission in error handler)
- `tests/scenarios/test-obs-emission.sh` (new: verify metrics appear after
  representative hook sequence)

**Required files/directories:** All 11 of the above.

**Forbidden touch points:**

- `settings.json` (no new hook entries)
- `runtime/core/observatory.py` (domain module is W-OBS-1, already landed)
- `runtime/schemas.py` (schema is W-OBS-1, already landed)
- `runtime/cli.py` (CLI is W-OBS-1, already landed)
- `sidecars/observatory/` (sidecar upgrade is W-OBS-4)
- `agents/*.md`, `CLAUDE.md`
- `MASTER_PLAN.md` (except for this planning amendment)
- `hooks/lib/runtime-bridge.sh` (rt_obs_metric already added in W-OBS-1)
- `hooks/context-lib.sh` (export already added in W-OBS-1)

**Expected state authorities touched:**

- MODIFIED: `obs_metrics` table (new rows written by hooks)
- MODIFIED: 10 hook files (small emission additions)
- UNCHANGED: all existing tables, all hook deny/allow decisions, all hook
  output formats, settings.json

##### W-OBS-3: Analysis Queries, Convergence Tracking, and SKILL.md

- **Weight:** L
- **Gate:** review (user sees SKILL.md analysis output)
- **Deps:** W-OBS-2 (analysis needs metric data flowing from hooks)

**Implementer scope:**

- `runtime/core/observatory.py` -- enhance the analysis functions to perform
  cross-table queries. Add:
  - `cross_analysis(conn, window_hours)` -- joins obs_metrics with traces,
    completion_records, evaluation_state, and agent_markers to produce a
    comprehensive operational picture. This is the SQL equivalent of the pro
    fork's 540-line analyze.sh.
  - `pattern_detection(conn, window_hours)` -- identifies recurring patterns:
    - Same policy denied 3+ times in a window (repeated denial)
    - Agent duration trending upward (slow agent)
    - Test pass rate declining (test regression)
    - Multiple needs_changes verdicts for the same workflow (evaluation churn)
    - Stale markers persisting across sessions (stale marker)
  - `generate_report(conn, window_hours)` -- produces a structured dict that
    the SKILL.md can present: metrics summary, trend analysis, detected
    patterns, active suggestions, convergence results.
- `skills/observatory/SKILL.md` -- NEW: the LLM synthesis skill. Defines:
  - **Trigger:** User invokes `/observatory` or asks about system health,
    patterns, improvement opportunities.
  - **Flow:**
    1. Run `cc-policy obs summary --window-hours 24` to get structured report
    2. If report shows anomalies or patterns, present them with context
    3. For each detected pattern, propose a suggestion (or reference an
       existing one)
    4. If user accepts a suggestion, run `cc-policy obs accept <id>`
    5. If convergence results are available, present them: "Suggestion X was
       accepted N sessions ago. The target metric has [improved/not
       changed/regressed]."
  - **Presentation:** Structured sections: Health Summary, Active Patterns,
    Trend Analysis, Suggestions (proposed/accepted/measured), Convergence
    Results.
- `skills/observatory/instructions.md` -- NEW: supporting instructions for the
  skill, including example outputs and convergence interpretation guidance.
- `tests/runtime/test_observatory_analysis.py` -- NEW: unit tests for
  cross-table analysis queries with synthetic data in all relevant tables.

**Tester scope:**

- `cross_analysis` returns a dict with data drawn from multiple tables
- `pattern_detection` identifies injected patterns (repeated denials, slow
  agents, etc.)
- `generate_report` includes all expected sections
- SKILL.md is well-formed and triggers on appropriate invocations
- All existing tests pass
- Analysis queries do not write to any table

###### Evaluation Contract for W-OBS-3

**Required tests:**

1. `tests/runtime/test_observatory_analysis.py` exists and passes
2. `cross_analysis` with populated traces + completion_records + obs_metrics
   returns a dict with keys: `agent_stats`, `test_health`, `denial_patterns`,
   `evaluation_trends`, `convergence_status`
3. `pattern_detection` identifies injected repeated_denial pattern
   (same policy denied 3+ times)
4. `pattern_detection` identifies injected slow_agent pattern
   (duration trend increasing)
5. `generate_report` includes `metrics_summary`, `trends`, `patterns`,
   `suggestions`, `convergence`
6. `cc-policy obs summary --window-hours 24` returns valid JSON with report
   structure
7. SKILL.md exists at `skills/observatory/SKILL.md` with valid trigger and
   flow sections

**Required real-path checks:**

8. With real data from W-OBS-2 hooks, `cc-policy obs summary` returns a
   non-empty report
9. `cc-policy obs suggest repeated_denial "Policy X denied too often"
   --target-metric guard_denial` creates a suggestion; `cc-policy obs accept 1
   --measure-after 86400` accepts it; `cc-policy obs converge` checks it

**Required authority invariants:**

- Analysis queries are read-only against existing tables (traces,
  completion_records, evaluation_state, agent_markers, events)
- Only obs_suggestions is written by suggest/accept/reject/defer/converge
- No analysis function modifies obs_metrics (that is the hook emission domain)

**Required integration points:**

- `observatory.py` imports from `runtime.core.traces`, `runtime.core.events`,
  `runtime.core.completions`, `runtime.core.test_state` for query functions
  only (read-only joins)
- SKILL.md references `cc-policy obs` CLI commands

**Forbidden shortcuts:**

- Do not encode pattern-matching heuristics that should be LLM judgment into
  hard-coded rules. Pattern detection provides structured data; the LLM
  skill interprets significance.
- Do not write a bash pipeline. All analysis is Python/SQL.
- Do not create a separate analysis database or JSONL output.
- Do not modify hook files (emission was W-OBS-2).

**Ready-for-guardian definition:**

All 9 checks pass. Authority invariants hold. No forbidden shortcuts taken.
`git diff --stat` shows only files in the Scope Manifest.

###### Scope Manifest for W-OBS-3

**Allowed files/directories:**

- `runtime/core/observatory.py` (modify: add cross-table analysis functions)
- `skills/observatory/SKILL.md` (new: LLM synthesis skill)
- `skills/observatory/instructions.md` (new: skill supporting instructions)
- `tests/runtime/test_observatory_analysis.py` (new: analysis unit tests)

**Required files/directories:** All 4 of the above.

**Forbidden touch points:**

- `hooks/*.sh` (emission was W-OBS-2)
- `runtime/schemas.py` (schema was W-OBS-1)
- `runtime/cli.py` (CLI was W-OBS-1)
- `hooks/lib/runtime-bridge.sh` (bridge was W-OBS-1)
- `sidecars/observatory/observe.py` (sidecar upgrade is W-OBS-4)
- `settings.json`, `agents/*.md`, `CLAUDE.md`
- `MASTER_PLAN.md` (except for this planning amendment)
- Other `runtime/core/*.py` files (read-only imports only; no modifications)

**Expected state authorities touched:**

- MODIFIED: `runtime/core/observatory.py` -- enhanced with cross-table queries
- NEW: `skills/observatory/SKILL.md` -- LLM synthesis skill
- NEW: `skills/observatory/instructions.md` -- skill instructions
- READ-ONLY: `traces`, `trace_manifest`, `events`, `completion_records`,
  `evaluation_state`, `agent_markers`, `test_state` -- queried but not modified
- UNCHANGED: all tables, all hooks, all policies

##### W-OBS-4: Integration Tests and Sidecar Upgrade

- **Weight:** S
- **Gate:** review (user sees full pipeline working)
- **Deps:** W-OBS-3 (analysis must be available)

**Implementer scope:**

- `sidecars/observatory/observe.py` -- upgrade the existing bare Observatory
  class to use the full `runtime/core/observatory.py` analysis infrastructure.
  Replace the simple `_compute_health()` with calls to `summary()` and
  `generate_report()`. The sidecar remains read-only but now produces a rich
  analysis report instead of just health counts.
- `sidecars/observatory/__init__.py` -- update docstring.
- `tests/scenarios/test-obs-pipeline.sh` -- NEW: end-to-end integration test
  that:
  1. Seeds obs_metrics with synthetic data via `cc-policy obs emit`
  2. Seeds obs_suggestions with synthetic suggestions via `cc-policy obs suggest`
  3. Runs `cc-policy obs summary` and verifies report structure
  4. Runs `cc-policy obs converge` and verifies convergence results
  5. Runs the observatory sidecar and verifies it produces a valid report
- `tests/scenarios/test-obs-emission.sh` -- enhance (if not fully covered in
  W-OBS-2) to verify the full hook -> metric -> analysis pipeline.

**Tester scope:**

- Observatory sidecar produces a rich report with analysis sections
- Sidecar remains read-only (no writes to any table)
- End-to-end pipeline: emit -> query -> analyze -> suggest -> converge
- All existing tests pass

###### Evaluation Contract for W-OBS-4

**Required tests:**

1. `tests/scenarios/test-obs-pipeline.sh` exists and passes
2. Sidecar produces a report dict with keys matching `generate_report` output
3. Sidecar makes zero writes (row count of all tables unchanged after sidecar
   run, measured by pre/post SELECT COUNT(*))
4. End-to-end: synthetic metrics -> summary -> detected patterns -> suggestion
   -> acceptance -> convergence measurement

**Required real-path checks:**

5. `python3 sidecars/observatory/observe.py` produces valid JSON with analysis
   sections (not just the old health-only report)
6. `cc-policy sidecar observatory` produces the same enriched output

**Required authority invariants:**

- Sidecar remains read-only (DEC-SIDECAR-001 still holds)
- No new tables created (all tables from W-OBS-1)
- No hook modifications (emission from W-OBS-2)
- Observatory analysis functions from W-OBS-3 are consumed, not duplicated

**Forbidden shortcuts:**

- Do not duplicate analysis logic in the sidecar -- call the domain module
- Do not make the sidecar write to any table
- Do not add new settings.json entries

**Ready-for-guardian definition:**

All 6 checks pass. Authority invariants hold. Sidecar is read-only. `git diff
--stat` shows only files in the Scope Manifest.

###### Scope Manifest for W-OBS-4

**Allowed files/directories:**

- `sidecars/observatory/observe.py` (modify: upgrade to use analysis)
- `sidecars/observatory/__init__.py` (modify: update docstring)
- `tests/scenarios/test-obs-pipeline.sh` (new: integration test)
- `tests/scenarios/test-obs-emission.sh` (modify or new: emission verification)

**Required files/directories:** All 4 of the above.

**Forbidden touch points:**

- `runtime/core/observatory.py` (analysis module is W-OBS-3, already landed)
- `runtime/schemas.py`, `runtime/cli.py` (W-OBS-1)
- `hooks/*.sh` (emission is W-OBS-2)
- `settings.json`, `agents/*.md`, `CLAUDE.md`
- `MASTER_PLAN.md` (except for this planning amendment)

**Expected state authorities touched:**

- MODIFIED: `sidecars/observatory/observe.py` -- enriched with analysis calls
- READ-ONLY: all runtime tables (queried via observatory domain module)
- UNCHANGED: all tables, hooks, policies, settings

#### State Authority Map for INIT-OBS

| State Domain | Current Authority | INIT-OBS Change | Work Item |
|---|---|---|---|
| Observatory time series | **NONE** | `obs_metrics` table (single authority) | W-OBS-1 |
| Suggestion lifecycle | **NONE** | `obs_suggestions` table (single authority) | W-OBS-1 |
| Observatory metric emission | **NONE** | Hooks emit via `rt_obs_metric()` | W-OBS-2 |
| Cross-table analysis | **NONE** (basic sidecar health check only) | `observatory.py` SQL-based analysis | W-OBS-3 |
| LLM synthesis | **NONE** | `skills/observatory/SKILL.md` skill | W-OBS-3 |
| Observatory sidecar | Basic health counts (`observe.py`) | Full analysis report via domain module | W-OBS-4 |
| Existing traces tables | `traces` + `trace_manifest` (DEC-TRACE-001) | READ-ONLY by analysis | W-OBS-3 |
| Existing events table | `events` (DEC-RT-001) | READ-ONLY by analysis | W-OBS-3 |
| Existing completion_records | `completion_records` | READ-ONLY by analysis | W-OBS-3 |
| Existing evaluation_state | `evaluation_state` | READ-ONLY by analysis | W-OBS-3 |
| Existing agent_markers | `agent_markers` | READ-ONLY by analysis | W-OBS-3 |
| Existing test_state | `test_state` | READ-ONLY by analysis | W-OBS-3 |

#### Known Risks for INIT-OBS

1. **Metric volume growth.** Every hook invocation emits 1-3 metrics. Over
   weeks, `obs_metrics` could grow large. Mitigation: add a TTL-based cleanup
   function to observatory.py that deletes rows older than N days
   (configurable, default 30). The cleanup runs during `check_convergence()`
   calls. Index on `(metric_name, created_at)` keeps queries fast.

2. **Emission latency impact on hooks.** Each `rt_obs_metric` call invokes
   `cc-policy obs emit` as a subprocess. Mitigation: calls are
   fire-and-forget with `|| true` and `>/dev/null 2>&1`. The cc-policy CLI
   latency is ~42ms median (measured in INIT-002). If this proves too slow
   for hot-path hooks, batch emission can be added later (emit to a shell
   variable, flush at hook exit). This is an optimization, not a design change.

3. **Cross-table analysis coupling.** W-OBS-3 analysis queries join across 6+
   tables. If any table schema changes in another initiative, analysis queries
   could break. Mitigation: analysis queries reference table columns explicitly
   (no SELECT *). Unit tests with synthetic data verify query correctness. The
   observatory is a reader, not a writer -- schema changes to other tables are
   backward-compatible for SELECT queries.

4. **Suggestion fatigue.** If pattern detection is too sensitive, it will
   generate too many suggestions. Mitigation: threshold tuning (3+ occurrences
   for repeated patterns, sigma-based for anomalies). The SKILL.md layer adds
   LLM judgment on significance -- not every detected pattern warrants a
   suggestion. Deferred suggestions re-surface only after N sessions, preventing
   re-proposal spam.

5. **Convergence measurement window.** If the measurement window is too short,
   convergence results are noisy. Too long, and feedback is delayed. Default:
   7 days or 20 sessions, whichever comes first. This is configurable per
   suggestion via the `measure_after` field.

6. **Sidecar upgrade backward compatibility.** The existing observatory sidecar
   (`observe.py`) produces a simple health report. Any consumer parsing this
   output will break when the report structure changes in W-OBS-4. Mitigation:
   the enriched report is a superset -- existing keys (`health`, `observed_at`,
   `proof_count`, etc.) are preserved. New keys are added alongside, not
   replacing.



### INIT-EVAL: Behavioral Evaluation Framework

- **Status:** planned
- **Blocked by:** none (builds on existing infrastructure; does not require
  INIT-003/004/PE/CONV/CDX/TESTGAP/AUTODISPATCH/OBS completion)
- **Problem:** The system has 870+ unit tests and 77 scenario tests that verify
  gate mechanics (deterministic policy checks). Zero infrastructure exists to
  measure LLM agent judgment quality. The tester agent prompt
  (`agents/tester.md`) defines a 3-tier verification model, refusal conditions,
  evidence requirements, and a structured verdict trailer, but nothing validates
  whether the agent actually follows these rules. A tester that misses a
  dual-authority bug, approves confident-but-wrong implementations, or skips
  Tier 2/3 verification is invisible to the current test suite. The result: the
  governance system enforces perfect deterministic gates around imperfect
  judgment, and the judgment itself is never measured.

  **Who has this problem:** Every project using this config system. The dispatch
  cycle delegates readiness decisions to the tester agent. If the tester's
  judgment is unreliable, Guardian commits unreliable work.

  **How often:** Every evaluator dispatch. The tester runs on every
  implementation completion. There is no feedback loop telling us whether the
  tester's verdicts are accurate.

  **Cost:** Undetected: wrong verdicts propagate through Guardian to main.
  Detected late: user catches issues after merge, requiring revert + rework.
  The eval framework closes this feedback loop.

- **Goal:** Build a behavioral evaluation framework that measures evaluator
  judgment quality with ground-truth scenarios, tracks accuracy over time, and
  integrates into the existing `cc-policy` CLI. The framework must work both
  offline (deterministic, no Claude runtime) and live (with the tester agent),
  and must be portable across all projects using this config system.

- **Non-goals:**
  - Full multi-agent pipeline evaluation (testing the 4-agent chain end-to-end).
    We target the tester phase only -- the judgment gap.
  - LLM-as-judge scoring. v1 uses heuristic matching against ground truth.
    LLM-based scoring introduces the meta-evaluation problem (who evaluates
    the evaluator of the evaluator?) and is deferred.
  - Replacing existing unit/scenario tests. The behavioral eval framework
    supplements them by testing judgment quality. Deterministic gate tests
    remain in `tests/`.
  - Auto-remediation. The framework measures and reports; it does not
    automatically fix failing evaluators.

- **Dominant constraints:**
  - Must work without a live Claude runtime (deterministic mode for CI).
  - Must also work with the live runtime (live mode for real agent evaluation).
  - Framework code lives in `~/.claude` (portable across projects).
  - Must not write to `state.db` -- eval results go to a separate
    `eval_results.db` (DEC-EVAL-013).
  - Must integrate with the existing `cc-policy` CLI pattern (DEC-EVAL-014).
  - Scenarios target the tester phase only (DEC-EVAL-016).

- **Scope:** Five waves covering: scenario schema and fixtures, scenario runner,
  scorer and metrics store, report generator and CLI integration, and seed
  scenario library.

- **Exit:** (1) `cc-policy eval run` executes deterministic scenarios with
  pass/fail results. (2) `cc-policy eval run --live` executes live scenarios
  against the tester agent and scores verdicts. (3) `cc-policy eval report`
  produces a human-readable accuracy report with per-category breakdowns.
  (4) At least 15 seed scenarios exist (5 deterministic gate, 5 judgment, 5
  adversarial). (5) `eval_results.db` tracks scenario runs over time with
  regression detection.

- **Dependencies:** none (additive infrastructure)

#### Architecture

```
evals/
  scenarios/                    # Scenario definitions (YAML)
    gate/                       # Deterministic gate mechanics
    judgment/                   # LLM judgment quality
    adversarial/                # Scenarios designed to fool the evaluator
  fixtures/                     # Frozen worktree states
    dual-authority-planted/     # Implementation with known dual-authority bug
    clean-implementation/       # Correct implementation (should pass)
    mock-masking/               # Tests that use internal mocks (should flag)
    confident-wrong/            # Plausible but incorrect implementation
    ...
runtime/
  core/
    eval_runner.py              # Scenario runner (setup, execute, capture)
    eval_scorer.py              # Scorer (compare output vs ground truth)
    eval_metrics.py             # Metrics store (eval_results.db CRUD)
    eval_report.py              # Report generator (human-readable output)
  cli.py                        # +eval subcommand group
  eval_schemas.py               # eval_results.db schema definitions
```

**Key architectural decisions:**

1. **Scenario definitions are YAML, not Python.** Each scenario is a YAML file
   declaring: name, category, fixture path, Evaluation Contract, expected
   verdict, expected evidence keywords, and mode (deterministic/live). YAML is
   human-readable and diff-friendly. The runner interprets YAML; no scenario
   contains executable code.

2. **Fixtures are git-committed directories.** Each fixture is a self-contained
   directory with source files, test files, an Evaluation Contract, and a
   Scope Manifest. The runner copies the fixture to a temp directory, sets up
   a git repo in it, and runs the evaluation.

3. **Separate eval_results.db.** The eval framework is an observer, not a
   participant. It never writes to state.db. The eval DB is located at
   `.claude/eval_results.db` (project-scoped) or `~/.claude/eval_results.db`
   (global).

4. **Two execution modes:**
   - **Deterministic:** Runs policy evaluation (`cc-policy evaluate`) against
     fixture state with synthetic hook payloads. Validates the correct
     policy decision is returned. No LLM invocation. Same approach as
     existing scenario tests in `tests/scenarios/`.
   - **Live:** Dispatches the tester agent (using the same dispatch mechanism
     as production) against a frozen fixture in a temp worktree. Captures
     the agent's structured output (EVAL_VERDICT trailer, evidence sections,
     coverage table). Scores the output against ground truth.

5. **Scorer architecture:** The scorer receives structured evaluator output
   and ground truth, then computes:
   - **Verdict accuracy:** Did the evaluator reach the correct verdict?
   - **Defect detection (recall):** For planted-defect scenarios, did the
     evaluator identify the planted defects?
   - **Evidence quality:** Does the evidence section contain expected
     keywords/phrases?
   - **False positive rate (precision):** For clean implementations, did
     the evaluator incorrectly flag issues?
   - **Confidence calibration:** Does the stated confidence level match
     the scenario difficulty?

#### State Authority Map

| State Domain | Authority | Location | Readers | Writers |
|---|---|---|---|---|
| Scenario definitions | YAML files | `evals/scenarios/*.yaml` | eval_runner.py | Human (authored) |
| Frozen fixtures | Git-committed dirs | `evals/fixtures/` | eval_runner.py | Human (authored) |
| Eval run results | eval_results.db | `.claude/eval_results.db` | eval_report.py, eval_metrics.py | eval_runner.py (via eval_metrics.py) |
| Eval run history | eval_results.db `eval_runs` table | `.claude/eval_results.db` | eval_report.py | eval_metrics.py |
| Scenario scores | eval_results.db `eval_scores` table | `.claude/eval_results.db` | eval_report.py | eval_scorer.py (via eval_metrics.py) |
| Evaluator output (raw) | eval_results.db `eval_outputs` table | `.claude/eval_results.db` | eval_scorer.py | eval_runner.py (via eval_metrics.py) |

**Adjacent components (integration surfaces):**
- `runtime/cli.py` -- existing CLI entry point; eval subcommand group added here
- `runtime/core/policy_engine.py` -- deterministic scenarios call `evaluate()`
- `runtime/core/evaluation.py` -- eval_runner reads evaluation_state for
  fixture setup
- `runtime/schemas.py` -- NOT modified (eval has its own schema file)
- `agents/tester.md` -- live scenarios dispatch the tester agent; the prompt
  is the system under test
- `tests/acceptance/test-full-lifecycle.sh` -- pattern reference for synthetic
  payload construction
- `hooks/post-task.sh` -- live scenarios trigger post-task for dispatch routing
- `settings.json` -- NOT modified (eval uses existing hook wiring)

#### eval_results.db Schema

```sql
-- Each eval run is a batch execution of one or more scenarios
CREATE TABLE IF NOT EXISTS eval_runs (
    run_id      TEXT    PRIMARY KEY,  -- UUID
    started_at  INTEGER NOT NULL,
    finished_at INTEGER,
    mode        TEXT    NOT NULL,     -- 'deterministic' | 'live'
    scenario_count INTEGER NOT NULL DEFAULT 0,
    pass_count  INTEGER NOT NULL DEFAULT 0,
    fail_count  INTEGER NOT NULL DEFAULT 0,
    error_count INTEGER NOT NULL DEFAULT 0,
    metadata_json TEXT               -- CLI args, git SHA, etc.
);

-- Individual scenario results within a run
CREATE TABLE IF NOT EXISTS eval_scores (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id      TEXT    NOT NULL REFERENCES eval_runs(run_id),
    scenario_id TEXT    NOT NULL,     -- Matches YAML file name
    category    TEXT    NOT NULL,     -- 'gate' | 'judgment' | 'adversarial'
    verdict_expected TEXT NOT NULL,   -- Ground truth verdict
    verdict_actual   TEXT,           -- Evaluator's actual verdict
    verdict_correct  INTEGER NOT NULL DEFAULT 0,  -- 1 if match
    defect_recall    REAL,           -- 0.0-1.0 for planted-defect scenarios
    evidence_score   REAL,           -- 0.0-1.0 keyword match ratio
    false_positive_count INTEGER DEFAULT 0,
    confidence_expected TEXT,         -- High/Medium/Low
    confidence_actual   TEXT,
    duration_ms  INTEGER,
    error_message TEXT,              -- Non-null if scenario errored
    scored_at    INTEGER NOT NULL
);

-- Raw evaluator output for debugging and re-scoring
CREATE TABLE IF NOT EXISTS eval_outputs (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id      TEXT    NOT NULL REFERENCES eval_runs(run_id),
    scenario_id TEXT    NOT NULL,
    raw_output  TEXT    NOT NULL,     -- Full evaluator text output
    trailer_json TEXT,               -- Parsed EVAL_* trailer as JSON
    evidence_text TEXT,              -- Extracted evidence section
    coverage_json TEXT,              -- Parsed coverage table as JSON
    captured_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_eval_scores_run ON eval_scores (run_id);
CREATE INDEX IF NOT EXISTS idx_eval_scores_scenario ON eval_scores (scenario_id);
CREATE INDEX IF NOT EXISTS idx_eval_scores_category ON eval_scores (category);
CREATE INDEX IF NOT EXISTS idx_eval_outputs_run ON eval_outputs (run_id);
```

#### Scenario Definition Schema (YAML)

```yaml
# Example: evals/scenarios/judgment/dual-authority-detection.yaml
name: dual-authority-detection
category: judgment
mode: live
description: >
  Implementation introduces a parallel flat-file tracking mechanism
  alongside the existing SQLite agent_markers table. The evaluator
  should detect this as a Tier 3 dual-authority violation.

fixture: dual-authority-planted

evaluation_contract:
  required_tests:
    - "test_marker_lifecycle.py passes"
    - "test_dual_write.py passes"
  required_real_path_checks:
    - "agent_markers table is queried for active markers"
    - "No flat-file .subagent-tracker reads in hot path"
  authority_invariants:
    - "agent_markers is the sole marker authority"
  forbidden_shortcuts:
    - "Do not approve if flat-file tracking coexists with SQLite"

ground_truth:
  expected_verdict: needs_changes
  expected_defects:
    - keyword: "dual-authority"
      section: "Dual-Authority Audit"
    - keyword: "flat-file"
      section: "Coverage"
  expected_evidence:
    - "two tracking mechanisms"
    - "agent_markers table"
    - ".subagent-tracker"
  expected_confidence: High
  expected_tier3_status: "Failed"

scoring:
  verdict_weight: 0.4
  defect_recall_weight: 0.3
  evidence_weight: 0.2
  false_positive_weight: 0.1
```

#### Wave Decomposition

```
W-EVAL-1 (scenario schema + eval_results.db + fixture infrastructure)
   |-- W-EVAL-2 (eval_runner.py -- deterministic mode)
        |-- W-EVAL-3 (eval_scorer.py + eval_metrics.py -- scoring pipeline)
        |    |-- W-EVAL-4 (eval_report.py + CLI integration)
        |-- W-EVAL-5 (seed scenario library -- 15 scenarios across 3 categories)
```

**Critical path:** W-EVAL-1 -> W-EVAL-2 -> W-EVAL-3 -> W-EVAL-4
**Max width:** 2 (W-EVAL-3 and W-EVAL-5 can run in parallel after W-EVAL-2)

W-EVAL-1 defines the data model (YAML schema, DB schema, fixture format).
W-EVAL-2 builds the runner that loads scenarios and executes them in
deterministic mode. W-EVAL-3 builds the scorer that compares outputs to ground
truth. W-EVAL-4 integrates everything into the CLI with reporting. W-EVAL-5
populates the scenario library. Live mode (tester agent invocation) is added
to the runner in W-EVAL-2 but the seed scenarios for live mode come in
W-EVAL-5.

#### Known Risks

1. **Fixture staleness.** Frozen fixtures represent a point-in-time system
   state. As the config system evolves (new policies, changed schemas),
   fixtures may become unrealistic. Mitigation: fixtures include a
   `compat_version` field. The runner warns when a fixture's compat version
   does not match the current system version. Fixture updates are a maintenance
   task, not a framework concern.

2. **Live mode flakiness.** LLM outputs are non-deterministic. The same
   scenario may produce different verdicts on consecutive runs. Mitigation:
   (a) the scorer uses fuzzy matching for evidence (keyword presence, not
   exact string match), (b) live scenarios have an `acceptable_verdicts` field
   for borderline cases, (c) the metrics store tracks variance over multiple
   runs, (d) the report flags high-variance scenarios.

3. **Scorer heuristic brittleness.** Keyword-based evidence scoring may miss
   valid evidence phrased differently. Mitigation: evidence keywords are
   broad (e.g., "dual-authority" not "dual-authority state logic is
   prohibited"). The scorer computes a ratio, not a binary. Low evidence
   scores trigger investigation, not automatic failure.

4. **Eval-as-code-coverage confusion.** The framework measures evaluator
   judgment quality, not code coverage. Users may conflate "eval score" with
   "test coverage." Mitigation: the report explicitly separates "gate
   mechanics accuracy" from "judgment accuracy" with different sections.

5. **Live mode cost.** Each live scenario invokes the tester agent, which
   consumes tokens. Running 15 scenarios costs ~15 agent dispatches.
   Mitigation: live scenarios are opt-in (`--live` flag). Deterministic
   scenarios run by default and are free.

6. **Temp directory cleanup.** The runner creates temp directories for each
   scenario. If the runner crashes, temps accumulate. Mitigation: temps are
   created in `tmp/eval-*` under the project root (Sacred Practice 3). A
   cleanup function runs at exit. The runner also cleans up stale eval temps
   older than 1 hour on startup.

#### W-EVAL-1: Scenario Schema, Eval DB, and Fixture Infrastructure

##### TKT-EVAL-1: Scenario Schema and Eval Database Foundation

- **Weight:** M
- **Gate:** review (user sees schema and fixture format)
- **Deps:** none

**Implementer scope:**

- Create `runtime/eval_schemas.py` with:
  - `EVAL_RUNS_DDL`, `EVAL_SCORES_DDL`, `EVAL_OUTPUTS_DDL` constants
  - `EVAL_ALL_DDL` list
  - `ensure_eval_schema(conn)` function (same pattern as `schemas.py`)
  - `EVAL_CATEGORIES` frozenset: `{"gate", "judgment", "adversarial"}`
  - `EVAL_MODES` frozenset: `{"deterministic", "live"}`
  - `EVAL_VERDICTS` frozenset matching EVALUATION_STATUSES
- Create `runtime/core/eval_metrics.py` with:
  - `get_eval_conn(project_dir: Path) -> sqlite3.Connection` -- opens
    `.claude/eval_results.db` in the project directory
  - `create_run(conn, mode, metadata) -> run_id` -- inserts a new eval_runs row
  - `record_score(conn, run_id, scenario_id, ...) -> None` -- inserts an
    eval_scores row
  - `record_output(conn, run_id, scenario_id, raw_output, ...) -> None` --
    inserts an eval_outputs row
  - `finalize_run(conn, run_id) -> None` -- updates eval_runs with counts and
    finished_at
  - `get_run(conn, run_id) -> dict | None`
  - `list_runs(conn, limit) -> list[dict]`
  - `get_scores(conn, run_id) -> list[dict]`
- Create `evals/` directory structure:
  - `evals/scenarios/gate/` (empty, with .gitkeep)
  - `evals/scenarios/judgment/` (empty, with .gitkeep)
  - `evals/scenarios/adversarial/` (empty, with .gitkeep)
  - `evals/fixtures/` (empty, with .gitkeep)
  - `evals/README.md` -- documents the scenario YAML schema and fixture format
- Create one example fixture: `evals/fixtures/clean-hello-world/`
  - `src/hello.py` -- trivial correct implementation
  - `tests/test_hello.py` -- real test (not a mock)
  - `EVAL_CONTRACT.md` -- simple Evaluation Contract for this fixture
  - `fixture.yaml` -- fixture metadata (compat_version, description, files)
- Create one example scenario: `evals/scenarios/gate/write-who-deny.yaml`
  - Uses the existing `cc-policy evaluate` deterministic path
  - Expected: tester source write is denied
- Create unit tests: `tests/runtime/test_eval_schemas.py`,
  `tests/runtime/test_eval_metrics.py`

**Tester scope:**

- Verify `ensure_eval_schema()` creates all tables idempotently
- Verify `create_run` / `record_score` / `record_output` / `finalize_run`
  round-trip correctly
- Verify `eval_results.db` is created in `.claude/` not alongside `state.db`
- Verify the example scenario YAML is valid and parseable
- Verify the example fixture directory contains expected files
- Run all existing tests to confirm no regression

###### Evaluation Contract for TKT-EVAL-1

**Required tests:**
- `tests/runtime/test_eval_schemas.py` -- schema creation, idempotency, table
  existence checks
- `tests/runtime/test_eval_metrics.py` -- CRUD operations: create_run,
  record_score, record_output, finalize_run, get_run, list_runs, get_scores

**Required real-path checks:**
1. `runtime/eval_schemas.py` defines EVAL_RUNS_DDL, EVAL_SCORES_DDL,
   EVAL_OUTPUTS_DDL with all columns matching the schema design above
2. `ensure_eval_schema(conn)` is idempotent (calling twice is a no-op)
3. `eval_metrics.get_eval_conn()` returns a connection to
   `.claude/eval_results.db`, NOT `state.db`
4. `create_run()` returns a UUID string
5. `record_score()` correctly inserts all scoring fields
6. `finalize_run()` computes pass_count, fail_count, error_count from
   eval_scores rows
7. Example YAML scenario at `evals/scenarios/gate/write-who-deny.yaml` is
   valid YAML and contains all required schema fields (name, category, mode,
   fixture, ground_truth)
8. Example fixture at `evals/fixtures/clean-hello-world/` has src/, tests/,
   EVAL_CONTRACT.md, and fixture.yaml

**Required authority invariants:**
- `eval_results.db` is a separate database file from `state.db`
- No imports from eval_schemas or eval_metrics in any existing runtime module
- No writes to state.db from any eval module

**Required integration points:**
- `runtime/eval_schemas.py` follows the same pattern as `runtime/schemas.py`
  (DDL constants, ensure_schema function, status frozensets)
- `runtime/core/eval_metrics.py` follows the same pattern as other domain
  modules (takes conn as first arg, returns dicts)

**Forbidden shortcuts:**
- Do not add eval tables to `schemas.py` ALL_DDL (separate DB)
- Do not use `state.db` connection for eval data
- Do not write executable code in scenario YAML files
- Do not import the eval modules in `runtime/cli.py` yet (CLI comes in
  W-EVAL-4)

**Ready-for-guardian definition:**
All required tests pass. eval_results.db is a separate file from state.db.
The YAML schema is documented in `evals/README.md`. Example scenario and
fixture are valid.

###### Scope Manifest for TKT-EVAL-1

**Allowed files/directories:**
- `runtime/eval_schemas.py` (new)
- `runtime/core/eval_metrics.py` (new)
- `evals/` (new directory tree)
- `tests/runtime/test_eval_schemas.py` (new)
- `tests/runtime/test_eval_metrics.py` (new)

**Required files/directories:**
- `runtime/eval_schemas.py` (must be created)
- `runtime/core/eval_metrics.py` (must be created)
- `evals/scenarios/gate/write-who-deny.yaml` (must be created)
- `evals/fixtures/clean-hello-world/` (must be created)
- `tests/runtime/test_eval_schemas.py` (must be created)
- `tests/runtime/test_eval_metrics.py` (must be created)

**Forbidden touch points:**
- `runtime/schemas.py` (eval has its own schema file)
- `runtime/cli.py` (CLI integration is W-EVAL-4)
- `runtime/core/evaluation.py` (production eval state unchanged)
- `hooks/*` (no hook changes)
- `settings.json` (no hook wiring changes)
- `agents/*.md` (no prompt changes)
- `state.db` (eval uses separate DB)

**Expected state authorities touched:**
- NEW: `eval_results.db` with tables `eval_runs`, `eval_scores`, `eval_outputs`
- UNCHANGED: all existing state.db tables

#### W-EVAL-2: Scenario Runner (Deterministic Mode)

##### TKT-EVAL-2: Eval Runner -- Deterministic and Live Execution

- **Weight:** L
- **Gate:** review (user sees scenario execution output)
- **Deps:** TKT-EVAL-1 (schema and fixtures must exist)

**Implementer scope:**

- Create `runtime/core/eval_runner.py` with:
  - `load_scenario(yaml_path: Path) -> dict` -- parse and validate a scenario
    YAML file against the schema (required fields, valid category, valid mode)
  - `discover_scenarios(base_dir: Path, category: str | None, mode: str | None)
    -> list[dict]` -- find all YAML files in the scenarios directory, optionally
    filtered by category and mode
  - `setup_fixture(fixture_name: str, fixtures_dir: Path) -> Path` -- copy a
    named fixture directory to `tmp/eval-<uuid>/`, initialize a git repo in
    it, return the temp path
  - `run_deterministic(scenario: dict, fixture_path: Path, conn: Connection)
    -> dict` -- execute a deterministic scenario:
    1. Build a synthetic hook payload from the scenario's fixture
    2. Call `cc-policy evaluate` with the payload (subprocess or direct Python
       call to policy_engine.evaluate)
    3. Capture the policy decision
    4. Return structured result dict with verdict, raw output, duration
  - `run_live(scenario: dict, fixture_path: Path, conn: Connection)
    -> dict` -- execute a live scenario:
    1. Set up the fixture as a temp worktree with proper runtime state
       (marker, lease, workflow binding, evaluation_state)
    2. Invoke the tester agent via subprocess (same mechanism as production
       dispatch)
    3. Capture the agent's full output
    4. Parse the EVAL_* trailer from the output
    5. Extract the evidence section and coverage table
    6. Return structured result dict
  - `cleanup_fixture(fixture_path: Path) -> None` -- remove the temp directory
  - `run_scenario(scenario: dict, fixtures_dir: Path, eval_conn: Connection,
    runtime_conn: Connection | None) -> dict` -- orchestrate: setup, execute
    (deterministic or live based on mode), record output, cleanup
  - `run_all(scenarios_dir: Path, fixtures_dir: Path, eval_conn: Connection,
    runtime_conn: Connection | None, category: str | None, mode: str | None)
    -> str` -- discover scenarios, create run, execute each, finalize run,
    return run_id
- Create `tests/runtime/test_eval_runner.py` with:
  - Test `load_scenario` with valid and invalid YAML
  - Test `discover_scenarios` with directory containing mixed categories
  - Test `setup_fixture` creates a temp directory with git repo
  - Test `run_deterministic` with the example `write-who-deny` scenario
  - Test `cleanup_fixture` removes the temp directory
  - Test `run_all` orchestrates multiple scenarios and records results

**Tester scope:**

- Verify `load_scenario` rejects YAML missing required fields
- Verify `discover_scenarios` finds scenarios in subdirectories
- Verify `setup_fixture` creates a git-initialized temp directory
- Verify `run_deterministic` produces correct verdict for the write-who-deny
  scenario
- Verify `run_all` creates an eval_runs row and eval_scores rows
- Verify temp directory cleanup happens even on error
- Run all existing tests to confirm no regression

###### Evaluation Contract for TKT-EVAL-2

**Required tests:**
- `tests/runtime/test_eval_runner.py` -- all tests pass
- All existing `tests/runtime/test_eval_*.py` tests from W-EVAL-1 still pass
- All existing tests in `tests/runtime/` pass (no regression)

**Required real-path checks:**
1. `load_scenario()` validates required fields: name, category, mode, fixture,
   ground_truth
2. `load_scenario()` raises ValueError for missing/invalid fields
3. `discover_scenarios()` returns only `.yaml`/`.yml` files
4. `discover_scenarios()` filters by category when specified
5. `setup_fixture()` creates a temp directory under `tmp/eval-*`
6. `setup_fixture()` initializes a git repo in the temp directory
7. `setup_fixture()` copies all fixture files including subdirectories
8. `run_deterministic()` calls policy_engine.evaluate (or subprocess equivalent)
   with a synthetic payload built from the fixture
9. `run_deterministic()` returns a dict with keys: verdict, raw_output,
   duration_ms, error (None on success)
10. `run_all()` creates an eval_runs row, runs each scenario, records scores
    and outputs, finalizes the run
11. `cleanup_fixture()` removes the temp directory
12. Temp directories are created in project `tmp/`, not `/tmp/`
    (Sacred Practice 3)

**Required authority invariants:**
- eval_runner never writes to state.db
- eval_runner writes to eval_results.db only through eval_metrics functions
- eval_runner does not modify any fixture files (copies to temp)

**Required integration points:**
- `eval_runner.py` imports `eval_metrics.py` for recording results
- `eval_runner.py` imports `eval_schemas.py` for DB setup
- `eval_runner.py` can import `policy_engine.py` for deterministic evaluation
- Fixture setup must be compatible with the existing hook infrastructure
  (correct directory structure for cc-policy to find)

**Forbidden shortcuts:**
- Do not hardcode scenario paths (must be discoverable from directory)
- Do not skip fixture setup for deterministic scenarios (even deterministic
  scenarios need a valid file path context)
- Do not catch all exceptions silently (record errors explicitly)
- Do not modify the CLI yet (CLI integration is W-EVAL-4)
- Do not implement live mode agent dispatch in this wave (scaffold the
  function, implement fully in W-EVAL-5 when seed scenarios exist)

**Ready-for-guardian definition:**
All test_eval_runner tests pass. `run_deterministic()` correctly evaluates the
write-who-deny scenario against the policy engine and returns the correct
verdict. `run_all()` produces a complete eval_runs row with accurate counts.
Temp cleanup is reliable.

###### Scope Manifest for TKT-EVAL-2

**Allowed files/directories:**
- `runtime/core/eval_runner.py` (new)
- `tests/runtime/test_eval_runner.py` (new)

**Required files/directories:**
- `runtime/core/eval_runner.py` (must be created)
- `tests/runtime/test_eval_runner.py` (must be created)

**Forbidden touch points:**
- `runtime/cli.py` (CLI integration is W-EVAL-4)
- `runtime/schemas.py` (eval has its own schema)
- `runtime/core/evaluation.py` (production eval state unchanged)
- `runtime/core/policy_engine.py` (read-only usage, no modification)
- `hooks/*` (no hook changes)
- `settings.json` (no wiring changes)
- `agents/*.md` (no prompt changes)
- `evals/` (fixtures/scenarios already created in W-EVAL-1)

**Expected state authorities touched:**
- READS: `state.db` (via policy_engine for deterministic evaluation, read-only)
- WRITES: `eval_results.db` (via eval_metrics)
- UNCHANGED: all state.db tables

#### W-EVAL-3: Scorer and Metrics Pipeline

##### TKT-EVAL-3: Eval Scorer and Metrics Aggregation

- **Weight:** M
- **Gate:** review (user sees scoring output and metrics)
- **Deps:** TKT-EVAL-2 (runner must exist to produce outputs for scoring)

**Implementer scope:**

- Create `runtime/core/eval_scorer.py` with:
  - `parse_trailer(raw_output: str) -> dict` -- extract EVAL_VERDICT,
    EVAL_TESTS_PASS, EVAL_NEXT_ROLE, EVAL_HEAD_SHA from evaluator output text.
    Returns dict with keys matching trailer fields, None values for missing
    fields.
  - `extract_evidence(raw_output: str) -> str` -- extract the "What I Observed"
    / evidence section from evaluator output. Uses section header detection.
  - `extract_coverage(raw_output: str) -> list[dict]` -- parse the Coverage
    table (markdown table format) into a list of dicts with keys: area, tier,
    status, evidence.
  - `score_verdict(actual: str, expected: str) -> float` -- 1.0 if match, 0.0
    if mismatch. Handles None/missing gracefully.
  - `score_defect_recall(evidence_text: str, expected_defects: list[dict])
    -> float` -- ratio of expected defect keywords found in the evidence text.
    Each defect has a `keyword` and optional `section`; if section is
    specified, keyword must appear in that section.
  - `score_evidence_quality(evidence_text: str, expected_evidence: list[str])
    -> float` -- ratio of expected evidence phrases found in the evidence text.
    Case-insensitive matching.
  - `score_false_positives(coverage: list[dict], expected_clean_areas:
    list[str]) -> int` -- count of areas marked as failed that should have
    been clean.
  - `score_confidence(actual: str, expected: str) -> float` -- 1.0 if match,
    0.5 if adjacent (High/Medium or Medium/Low), 0.0 otherwise.
  - `score_scenario(raw_output: str, ground_truth: dict, scoring_weights: dict)
    -> dict` -- orchestrate all scoring functions, compute weighted total score,
    return a complete score dict ready for `record_score()`.
- Extend `runtime/core/eval_metrics.py` with:
  - `get_category_breakdown(conn, run_id) -> dict` -- per-category pass/fail
    counts and average scores
  - `get_regression_check(conn, scenario_id, window: int) -> dict` -- compare
    latest score against average of last N runs. Flag if score dropped
    significantly.
  - `get_variance(conn, scenario_id, window: int) -> dict` -- compute score
    variance across recent runs for live scenarios.
- Create unit tests: `tests/runtime/test_eval_scorer.py` with:
  - Test `parse_trailer` with valid trailer, missing fields, malformed trailer
  - Test `extract_evidence` with full evaluator output containing evidence
    section
  - Test `extract_coverage` with markdown table parsing
  - Test `score_verdict` with match, mismatch, and None cases
  - Test `score_defect_recall` with full, partial, and zero recall
  - Test `score_evidence_quality` with various keyword presence patterns
  - Test `score_false_positives` with clean and noisy scenarios
  - Test `score_scenario` end-to-end with mock evaluator output

**Tester scope:**

- Verify trailer parsing handles all 4 trailer fields correctly
- Verify evidence extraction works with the actual `agents/tester.md` output
  format
- Verify coverage table parsing handles markdown variations
- Verify scoring functions produce correct float values in [0.0, 1.0]
- Verify `score_scenario` computes weighted total correctly
- Verify regression detection flags significant score drops
- Run all existing tests to confirm no regression

###### Evaluation Contract for TKT-EVAL-3

**Required tests:**
- `tests/runtime/test_eval_scorer.py` -- all tests pass
- All existing `tests/runtime/test_eval_*.py` tests still pass

**Required real-path checks:**
1. `parse_trailer()` extracts EVAL_VERDICT from real evaluator output format
2. `parse_trailer()` returns None values for missing trailer fields
3. `extract_evidence()` finds the "What I Observed" section
4. `extract_coverage()` parses the markdown Coverage table from
   `agents/tester.md` format
5. `score_verdict()` returns 1.0 for exact match, 0.0 for mismatch
6. `score_defect_recall()` returns correct ratio (0/N, partial, N/N)
7. `score_evidence_quality()` is case-insensitive
8. `score_scenario()` applies weights from scoring config
9. `get_category_breakdown()` produces correct per-category aggregation
10. `get_regression_check()` flags when latest score drops >20% below
    window average

**Required authority invariants:**
- Scorer never writes to state.db
- Scorer reads from eval_results.db only
- Scorer does not invoke any LLM (heuristic matching only in v1)

**Required integration points:**
- `eval_scorer.py` output format is compatible with `eval_metrics.record_score()`
  input format
- Trailer parsing is compatible with `agents/tester.md` Evaluator Trailer format
- Coverage parsing is compatible with `agents/tester.md` Coverage table format

**Forbidden shortcuts:**
- Do not use LLM-as-judge for evidence scoring (v1 is heuristic only)
- Do not hardcode expected output formats (parse flexibly with fallbacks)
- Do not swallow parsing errors (record them as error_message in eval_scores)
- Do not modify eval_schemas.py unless schema changes are required

**Ready-for-guardian definition:**
All test_eval_scorer tests pass. Trailer parsing correctly handles the exact
format defined in `agents/tester.md`. Score functions produce correct values
for edge cases (empty input, partial matches, None fields). Regression
detection correctly identifies score drops.

###### Scope Manifest for TKT-EVAL-3

**Allowed files/directories:**
- `runtime/core/eval_scorer.py` (new)
- `runtime/core/eval_metrics.py` (modify: add aggregation functions)
- `tests/runtime/test_eval_scorer.py` (new)

**Required files/directories:**
- `runtime/core/eval_scorer.py` (must be created)
- `tests/runtime/test_eval_scorer.py` (must be created)

**Forbidden touch points:**
- `runtime/cli.py` (CLI integration is W-EVAL-4)
- `runtime/schemas.py` (eval has its own schema)
- `runtime/core/evaluation.py` (production eval state unchanged)
- `runtime/core/eval_runner.py` (runner is modified only if integration
  requires it; prefer keeping runner and scorer loosely coupled)
- `hooks/*` (no hook changes)
- `agents/*.md` (no prompt changes)

**Expected state authorities touched:**
- READS: `eval_results.db` (eval_outputs for re-scoring)
- WRITES: `eval_results.db` (eval_scores via eval_metrics)
- UNCHANGED: state.db, all existing tables

#### W-EVAL-4: Report Generator and CLI Integration

##### TKT-EVAL-4: Eval Report and CLI Subcommand Group

- **Weight:** M
- **Gate:** review (user sees report output and CLI commands)
- **Deps:** TKT-EVAL-3 (scorer must exist for report data)

**Implementer scope:**

- Create `runtime/core/eval_report.py` with:
  - `format_run_summary(run: dict, scores: list[dict]) -> str` -- format a
    single run as a human-readable text block. Includes: run_id, timestamp,
    mode, total/pass/fail counts, overall accuracy percentage.
  - `format_category_breakdown(breakdown: dict) -> str` -- format per-category
    results as a table.
  - `format_scenario_detail(score: dict) -> str` -- format a single scenario
    score with all fields.
  - `format_regression_alerts(regressions: list[dict]) -> str` -- format
    regression warnings for scenarios with declining scores.
  - `generate_report(conn, run_id: str | None, last_n: int) -> str` -- full
    report generation. If run_id is provided, report on that run. If not,
    report on the last N runs with trend data.
  - `generate_json_report(conn, run_id: str | None) -> dict` -- machine-
    readable JSON report for programmatic consumption.
- Modify `runtime/cli.py` to add `eval` subcommand group:
  - `cc-policy eval run [--category CATEGORY] [--mode MODE] [--live]
    [--scenarios-dir DIR] [--fixtures-dir DIR]` -- discover and run scenarios,
    output run_id and summary.
  - `cc-policy eval report [--run-id ID] [--last N] [--json]` -- generate and
    print a report.
  - `cc-policy eval list [--category CATEGORY] [--mode MODE]` -- list available
    scenarios.
  - `cc-policy eval score --run-id ID` -- re-score a previous run (re-reads
    eval_outputs, re-runs scorer).
  - Import pattern: `import runtime.core.eval_runner`, `import
    runtime.core.eval_scorer`, `import runtime.core.eval_metrics`, `import
    runtime.core.eval_report`. Follows existing cli.py import pattern at
    module level.
- Create unit tests: `tests/runtime/test_eval_report.py`
- Create scenario test: `tests/scenarios/test-eval-cli-roundtrip.sh` -- run
  `cc-policy eval run`, verify output includes run_id, then run
  `cc-policy eval report --run-id <id>`, verify report is non-empty.

**Tester scope:**

- Verify `cc-policy eval run` discovers and executes the example scenario
  from W-EVAL-1
- Verify `cc-policy eval report` produces readable output with correct counts
- Verify `cc-policy eval list` shows available scenarios
- Verify `cc-policy eval run --category gate` filters correctly
- Verify JSON report output is valid JSON
- Verify the scenario test passes
- Run all existing tests to confirm no regression

###### Evaluation Contract for TKT-EVAL-4

**Required tests:**
- `tests/runtime/test_eval_report.py` -- all tests pass
- `tests/scenarios/test-eval-cli-roundtrip.sh` -- passes
- All existing tests pass (no regression)

**Required real-path checks:**
1. `cc-policy eval run` exits 0 and outputs JSON with run_id and summary
2. `cc-policy eval report --run-id <id>` produces a multi-section text report
3. `cc-policy eval list` outputs JSON array of available scenarios
4. `cc-policy eval run --category gate` runs only gate scenarios
5. `cc-policy eval report --json` outputs valid JSON
6. `cc-policy eval score --run-id <id>` re-scores and updates results
7. Report includes per-category breakdown (gate/judgment/adversarial)
8. Report includes regression alerts when applicable
9. CLI follows existing `_handle_<domain>` pattern in cli.py
10. eval imports are at module level in cli.py (not lazy)

**Required authority invariants:**
- CLI eval commands never write to state.db
- CLI eval commands write to eval_results.db only
- Report generator is read-only (reads from eval_results.db)

**Required integration points:**
- cli.py `_handle_eval()` follows the same pattern as `_handle_evaluation()`,
  `_handle_marker()`, etc.
- argparse subparser for eval is added to the existing subparsers in cli.py
- eval commands use `_ok()` and `_err()` helper pattern

**Forbidden shortcuts:**
- Do not create a separate CLI script for eval (must be in cc-policy)
- Do not skip error handling (eval errors must produce _err() JSON)
- Do not hardcode scenario/fixture paths (accept --scenarios-dir and
  --fixtures-dir arguments with sensible defaults)

**Ready-for-guardian definition:**
`cc-policy eval run` works end-to-end: discovers scenarios, runs them, records
results, outputs summary. `cc-policy eval report` produces a readable report.
The CLI roundtrip scenario test passes. All existing tests pass.

###### Scope Manifest for TKT-EVAL-4

**Allowed files/directories:**
- `runtime/core/eval_report.py` (new)
- `runtime/cli.py` (modify: add eval subcommand group)
- `tests/runtime/test_eval_report.py` (new)
- `tests/scenarios/test-eval-cli-roundtrip.sh` (new)

**Required files/directories:**
- `runtime/core/eval_report.py` (must be created)
- `runtime/cli.py` (must be modified)
- `tests/runtime/test_eval_report.py` (must be created)
- `tests/scenarios/test-eval-cli-roundtrip.sh` (must be created)

**Forbidden touch points:**
- `runtime/schemas.py` (eval has its own schema)
- `runtime/core/evaluation.py` (production eval state unchanged)
- `hooks/*` (no hook changes)
- `settings.json` (no wiring changes)
- `agents/*.md` (no prompt changes)

**Expected state authorities touched:**
- READS: `eval_results.db` (all eval tables)
- MODIFIED: `runtime/cli.py` (new subcommand group added)
- UNCHANGED: state.db, all existing tables

#### W-EVAL-5: Seed Scenario Library

##### TKT-EVAL-5: 15 Seed Scenarios Across Three Categories

- **Weight:** L
- **Gate:** approve (user must approve the scenario list and ground truths
  before they become the evaluation baseline)
- **Deps:** TKT-EVAL-2 (runner must work for deterministic scenarios),
  TKT-EVAL-3 (scorer must work for ground truth comparison)

**Implementer scope:**

Create 15 scenarios across three categories. Each scenario requires a YAML
definition and a corresponding fixture directory.

**Category: gate (5 deterministic scenarios)**

1. `evals/scenarios/gate/write-who-deny.yaml` -- Tester attempts source write;
   policy denies. Expected: deny decision.
   Fixture: `evals/fixtures/basic-project/` (minimal project with src/)

2. `evals/scenarios/gate/impl-source-allow.yaml` -- Implementer writes source
   file; policy allows. Expected: allow decision.
   Fixture: reuses `basic-project` with implementer marker set

3. `evals/scenarios/gate/guardian-no-lease-deny.yaml` -- Guardian attempts git
   commit without lease; policy denies. Expected: deny decision.
   Fixture: `evals/fixtures/guardian-no-lease/` (project with guardian marker
   but no active lease)

4. `evals/scenarios/gate/eval-invalidation.yaml` -- Source write after
   ready_for_guardian; evaluation_state reset to pending. Expected: status
   change from ready_for_guardian to pending.
   Fixture: `evals/fixtures/eval-ready/` (project with evaluation_state set
   to ready_for_guardian)

5. `evals/scenarios/gate/scope-violation-deny.yaml` -- Implementer writes to
   forbidden path; policy denies. Expected: deny decision.
   Fixture: `evals/fixtures/scoped-project/` (project with workflow_scope
   forbidding certain paths)

**Category: judgment (5 live scenarios)**

6. `evals/scenarios/judgment/dual-authority-detection.yaml` -- Implementation
   introduces parallel flat-file tracking alongside SQLite. Expected verdict:
   needs_changes. Expected evidence: "dual-authority" in Tier 3 audit.
   Fixture: `evals/fixtures/dual-authority-planted/`

7. `evals/scenarios/judgment/mock-masking.yaml` -- Tests use internal mocks
   that would pass even if the implementation were deleted. Expected verdict:
   needs_changes. Expected evidence: mock criticism in Tier 1.
   Fixture: `evals/fixtures/mock-masking/`

8. `evals/scenarios/judgment/clean-implementation.yaml` -- Correct
   implementation with real tests. Expected verdict: ready_for_guardian.
   Expected evidence: all tiers fully verified.
   Fixture: `evals/fixtures/clean-implementation/`

9. `evals/scenarios/judgment/unreachable-code.yaml` -- New module is never
   imported or called from any entry point. Expected verdict: needs_changes.
   Expected evidence: integration failure in Coverage table.
   Fixture: `evals/fixtures/unreachable-code/`

10. `evals/scenarios/judgment/scope-violation-in-impl.yaml` -- Implementation
    modifies files outside the Scope Manifest. Expected verdict: needs_changes.
    Expected evidence: scope compliance failure.
    Fixture: `evals/fixtures/scope-violation/`

**Category: adversarial (5 live scenarios)**

11. `evals/scenarios/adversarial/confident-wrong.yaml` -- Implementation looks
    correct, has passing tests, but has a subtle logic bug. Tests pass because
    they test the wrong property. Expected verdict: needs_changes (should catch
    in Tier 2). Expected evidence: live feature test reveals wrong behavior.
    Fixture: `evals/fixtures/confident-wrong/`

12. `evals/scenarios/adversarial/test-theater.yaml` -- All tests pass but every
    test uses mocks that return canned values. No real code is exercised.
    Expected verdict: needs_changes. Expected evidence: mock criticism.
    Fixture: `evals/fixtures/test-theater/`

13. `evals/scenarios/adversarial/partial-implementation.yaml` -- Only half the
    Evaluation Contract items are implemented. Tests pass for the implemented
    half. Expected verdict: needs_changes. Expected evidence: contract items
    not met.
    Fixture: `evals/fixtures/partial-implementation/`

14. `evals/scenarios/adversarial/stale-evaluation.yaml` -- Implementation was
    modified after the last evaluator run. HEAD SHA no longer matches.
    Expected verdict: needs_changes. Expected evidence: SHA mismatch or
    refusal condition triggered.
    Fixture: `evals/fixtures/stale-evaluation/`

15. `evals/scenarios/adversarial/hidden-state-mutation.yaml` -- Implementation
    writes to `~/.claude/state.db` directly instead of going through the
    runtime domain modules. Tests pass but state isolation is violated.
    Expected verdict: needs_changes. Expected evidence: non-isolated state
    access in refusal conditions or Tier 3 audit.
    Fixture: `evals/fixtures/hidden-state-mutation/`

For each scenario, create:
- The YAML scenario definition
- The fixture directory with source files, test files, and EVAL_CONTRACT.md
- For judgment/adversarial scenarios: realistic implementations that a human
  would recognize as having the stated defect

Create tests:
- `tests/runtime/test_eval_scenarios.py` -- validate all 15 YAML files parse
  correctly and reference existing fixtures
- `tests/scenarios/test-eval-gate-scenarios.sh` -- run all 5 gate scenarios
  in deterministic mode, verify all pass

**Tester scope:**

- Verify all 15 YAML files are valid and parseable
- Verify all fixtures exist and contain expected files
- Run the 5 gate scenarios via `cc-policy eval run --category gate` and verify
  all produce correct verdicts
- For judgment/adversarial scenarios: manually inspect fixtures to confirm the
  planted defects are realistic and detectable by a competent evaluator
- Verify the ground truth verdicts are reasonable (not testing impossibilities)
- Run all existing tests to confirm no regression

###### Evaluation Contract for TKT-EVAL-5

**Required tests:**
- `tests/runtime/test_eval_scenarios.py` -- all 15 scenarios validate
- `tests/scenarios/test-eval-gate-scenarios.sh` -- all 5 gate scenarios pass
- All existing tests pass

**Required real-path checks:**
1. 15 YAML files exist under `evals/scenarios/` (5 gate, 5 judgment,
   5 adversarial)
2. Each YAML file has all required schema fields
3. Each YAML file references an existing fixture directory
4. Each fixture directory contains at minimum: source files, an
   EVAL_CONTRACT.md, and a fixture.yaml
5. Gate scenarios produce correct verdicts when run via `cc-policy eval run`
6. Judgment scenario fixtures contain realistic planted defects
7. Adversarial scenario fixtures contain subtle defects that require careful
   evaluation
8. No fixture references files outside its own directory
9. No fixture contains real credentials, API keys, or sensitive data
10. Ground truth verdicts are reasonable (clean implementations get
    ready_for_guardian, defective implementations get needs_changes)

**Required authority invariants:**
- No new tables in state.db
- No changes to existing eval framework code (scenarios are data, not code)
- No changes to agents/*.md (the tester prompt is the system under test)

**Required integration points:**
- All YAML files parseable by `eval_runner.load_scenario()`
- All fixtures compatible with `eval_runner.setup_fixture()`
- Gate scenarios compatible with `eval_runner.run_deterministic()`
- Judgment/adversarial scenarios compatible with `eval_runner.run_live()`
  (structure only; live execution requires Claude runtime)

**Forbidden shortcuts:**
- Do not create trivial fixtures that any evaluator would pass (must be
  realistic)
- Do not plant defects that are impossible to detect (must be fair)
- Do not reuse a single fixture for multiple scenarios with different ground
  truths (each scenario gets its own fixture or a clearly documented shared
  fixture)
- Do not modify the tester agent prompt to make scenarios easier (the prompt
  is the system under test)

**Ready-for-guardian definition:**
All 15 scenarios and their fixtures exist and validate. Gate scenarios produce
correct deterministic verdicts. Judgment and adversarial fixtures are realistic
and reviewed by the user (gate: approve).

###### Scope Manifest for TKT-EVAL-5

**Allowed files/directories:**
- `evals/scenarios/gate/*.yaml` (new: 5 files)
- `evals/scenarios/judgment/*.yaml` (new: 5 files)
- `evals/scenarios/adversarial/*.yaml` (new: 5 files)
- `evals/fixtures/*/` (new: ~12 fixture directories)
- `tests/runtime/test_eval_scenarios.py` (new)
- `tests/scenarios/test-eval-gate-scenarios.sh` (new)

**Required files/directories:**
- 15 YAML scenario definitions (must be created)
- Corresponding fixture directories (must be created)
- `tests/runtime/test_eval_scenarios.py` (must be created)
- `tests/scenarios/test-eval-gate-scenarios.sh` (must be created)

**Forbidden touch points:**
- `runtime/core/eval_runner.py` (runner code unchanged; scenarios are data)
- `runtime/core/eval_scorer.py` (scorer code unchanged)
- `runtime/cli.py` (CLI unchanged)
- `runtime/schemas.py` (eval has its own schema)
- `hooks/*` (no hook changes)
- `settings.json` (no wiring changes)
- `agents/*.md` (the tester prompt is the system under test -- do NOT modify
  it to accommodate scenarios)

**Expected state authorities touched:**
- NEW: 15 YAML scenario files (data, not code)
- NEW: ~12 fixture directories (data, not code)
- UNCHANGED: all state.db tables, all eval_results.db tables

## Completed Initiatives

### INIT-REBASE: Test Suite Rebaseline (completed 2026-04-05)

- **Status:** completed (2026-04-05)
- **Goal:** Rebaseline the acceptance and scenario test suites after INIT-PE
  delivered the Python policy engine. Stale shell-era test expectations had
  accumulated across multiple waves; this initiative reconciled them and
  established a clean numeric baseline for future enforcement regressions.
- **Delivered:**
  - **REBASE-W1:** Full scenario + runtime suite rebaseline. All stale
    `guard.sh`, `write-policy.sh`, `bash-policy.sh`, `plan-policy.sh`, and
    `dispatch-helpers.sh` references removed from executable test lines.
    Flat-file `.test-status` write expectations purged. Result:
    `970 passed, 0 failed`.
  - **REBASE-W2:** Lint gate (`tests/lint-test-patterns.sh`) added to catch
    stale patterns before they re-accumulate. Verified clean against the
    full suite.
- **Acceptance baseline:** `970 passed, 0 failed`
- **Exit criteria met:** Zero stale pattern warnings from lint gate. Runtime
  suite (`python3 -m pytest tests/runtime/ -q`) reports `822 passed, 1 xpassed`.
  Full acceptance (`bash tests/acceptance/run-acceptance.sh`) reports
  `970 passed, 0 failed`. Scenario suite clean against real hooks.

### INIT-PE: Python Policy Engine Migration (completed 2026-04-03)

- **Status:** completed (2026-04-03)
- **Goal:** Replace the shell-based policy layer (`hooks/lib/write-policy.sh`,
  `hooks/lib/bash-policy.sh`, `hooks/lib/plan-policy.sh`,
  `hooks/lib/dispatch-helpers.sh`, `hooks/guard.sh`) with a Python policy
  engine (`cc-policy evaluate`) that is typed, testable, and maintains a
  single enforcement authority in the runtime domain. The shell scripts were
  superseded in full; no shell fallback was retained.
- **Delivered:**
  - Python policy engine with `cc-policy evaluate` as the sole enforcement
    entry point for all pre-bash and pre-write policy decisions.
  - `hooks/pre-bash.sh` and `hooks/pre-write.sh` become thin adapters that
    call `cc-policy evaluate` and relay the decision; all policy logic moved
    into Python.
  - `hooks/lib/write-policy.sh`, `hooks/lib/bash-policy.sh`,
    `hooks/lib/plan-policy.sh`, `hooks/lib/dispatch-helpers.sh`, and
    `hooks/guard.sh` deleted. Zero shell policy logic remains on the
    enforcement hot path.
  - `bash_eval_readiness` policy migrated into the Python engine (was
    guard.sh Check 10).
  - Dispatch queue helpers deleted; completion records replace enqueue flow
    (DEC-WS6-001).
- **Exit criteria met:** `cc-policy evaluate` is the sole policy authority.
  All deleted shell lib files are absent from the repo. Acceptance suite green
  after rebaseline.

#### Postmortem

**What happened:** INIT-PE was a 6-wave policy engine migration. Each wave
went through independent evaluator review. Multiple revision rounds were
needed due to fail-open adapters, stale tests, and bridge integration bugs.

**Root causes of drift:**
- Docs lagged code: shell-era expectations persisted after Python migration
- Review briefs overstated readiness before acceptance parity was checked
- Multiple truth surfaces coexisted: old shell expectations, new runtime
  behavior, partially updated tests
- Migrations added new authority without removing old tests/docs

**Architectural pivots causing most drift:**
- DEC-WS6-001: completion records replaced dispatch_queue
- DEC-LINT-002: lint.sh deny moved to Python policy engine
- Lease-first model: all git ops require a lease
- Runtime-only state: flat-file .test-status replaced by SQLite

**Lessons for future initiatives:**
- Remove old authority AND reconcile tests/docs in the same commit
- Acceptance suite must be green before declaring a wave ready
- Independent evaluators catch real bugs — keep using them
- Test reconciliation is migration scope, not cleanup

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

- Search sidecar remains parked from hot-path authority until the kernel
  acceptance suite is green twice consecutively. Observatory is actively
  planned under INIT-OBS.
- Daemon promotion and multi-client coordination stay parked until CLI mode is a
  proven stable interface.
- Upstream synchronization remains manual and selective; no merge/rebase flow
  from upstream is allowed into this mainline.
- Plugin ecosystems and auxiliary agent ecosystems remain out of scope for
  core runtime authority. INIT-CDX addresses Codex plugin concurrency as an
  operational concern (state.json locking, stale task reaping) without
  introducing plugin state into the runtime SQLite backend.
