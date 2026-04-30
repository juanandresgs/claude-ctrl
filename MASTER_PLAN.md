# MASTER_PLAN.md

Status: active
Created: 2026-03-23
Last updated: 2026-04-29 (INIT-ADMIT planned: bootstrap admission atomicity flip + token-not-found UX; DEC-ADMIT-001 / DEC-ADMIT-002 logged)

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
- The current ClauDEX supervision surfaces in [`.codex/`](.codex/),
  [ClauDEX/](ClauDEX/), and `scripts/claudex-*` are containment scaffolding to
  keep Codex in the driver seat during cutover. They are not the target
  permanent authority. The target model is a runtime-owned supervision fabric
  with transport adapters (`tmux`, MCP, or provider-native control) behind one
  canonical state machine.
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
- `2026-04-09 — DEC-CLAUDEX-ARCH-001` Agent-agnostic recursive supervision is
  a runtime-owned domain. The canonical control plane will model agent
  sessions, seats, supervision threads, dispatch attempts, and delivery
  claim/ack in runtime state. `tmux` is the universal execution/attachment
  adapter for arbitrary CLI agents, not the authority for queue state, health,
  or completion. MCP or provider-native APIs are preferred structured adapters
  when available, but they plug into the same runtime-owned state machine.
- `2026-04-11 — DEC-CLAUDEX-BREAKGLASS-001` Interaction-gate breakglass
  escalation is split across two authorities: `braid-v2` runtime owns gate
  detection, escalation routing, review delivery, grant consumption, and
  resume/fail evidence; the policy engine owns approval hierarchy, grant
  issuance, scope, expiry, and audit. Approval grants are narrow temporary
  exception leases bound to a concrete bundle/seat/session/gate, not global
  bypass flags.

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
- `2026-04-27 — DEC-AD-005` The broad Codex stop-review gate is regular-Stop
  only. SubagentStop workflow influence now belongs to dedicated runtime-owned
  critics, currently `implementer-critic.sh` writing `critic_reviews` before
  `post-task.sh` routes. This removes duplicate 15-minute advisory reviews from
  planner/reviewer/guardian/implementer stops and keeps the Codex lane
  deterministic: either a verdict is persisted and consumed by dispatch, or the
  review remains an ordinary Stop audit.
- `2026-04-27 — DEC-AD-006` Regular Stop no longer runs broad Codex/Gemini
  review. The live Stop chain uses deterministic diagnostics plus
  `stop-advisor.sh`, which only blocks obvious low-risk "should I do this?"
  questions and redirects routine git landing to Guardian. Model review belongs
  to explicit review/rescue commands and dispatch critic lanes, not the
  user-facing Stop boundary.
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
- `2026-04-06 — DEC-OBS-006` First-class `role` column in obs_metrics.
  The most common query filter is by agent role. Storing role only in
  labels_json forces a full JSON scan on every role-based query. Adding
  `role TEXT` as an indexed column (nullable, populated at emission time)
  gives O(log n) filtering. Role is extracted from labels if present, or
  passed explicitly. labels_json no longer duplicates the role field.
- `2026-04-06 — DEC-OBS-007` Batch emission pattern for hot-path hooks.
  `|| true` and `>/dev/null 2>&1` suppress errors but do not make subprocess
  calls non-blocking -- the hook still waits ~42ms per call. For hot-path
  hooks (track.sh fires on every file write), this is designed from the start:
  accumulate metrics in a shell array during hook execution, flush once at
  hook exit via `rt_obs_metric_batch` -> `cc-policy obs emit-batch` (single
  subprocess, single transaction). For single hot-path metrics, `& disown`
  makes the call truly async.
- `2026-04-06 — DEC-OBS-008` Suggestion lifecycle enrichment for professional
  use. `signal_id` enables duplicate detection and suggestion chaining.
  `reject_reason` preserves rationale for future pattern detection.
  `defer_reassess_after` controls re-surfacing cadence (default 5 sessions).
  `batch_accept(conn, category)` accepts all proposed suggestions in a
  category at once.
- `2026-04-06 — DEC-OBS-009` Analysis run history via `obs_runs` table.
  Each `summary()` invocation records a run with metric snapshots and counts.
  This enables convergence tracking to compare current metrics against
  metrics-at-time-of-suggestion without re-querying historical data, and
  supports incremental analysis (only process metrics since last run).
- `2026-04-06 — DEC-OBS-010` Stop-gate review metrics emitted from first-
  party hooks, not the plugin. `post-task.sh` reads `codex_stop_review`
  events from the events table and emits `review_verdict`,
  `review_duration_s`, and `review_infra_failure` metrics. This isolates
  metric emission from plugin internals and keeps all emission in the
  existing hook chain.
- `2026-04-27 — DEC-OBS-011` `post-task.sh` no longer reads
  `codex_stop_review` for review metrics. Once broad SubagentStop reviews were
  retired, that read could only observe stale regular-Stop audit events during
  later SubagentStop routing. Review visibility now lives in Stop-hook
  `codex_stop_review` events and the statusline; metric emission needs a future
  Stop-owned emitter if organization-level reporting requires it.

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

### Guardian worktree authority decisions

- `2026-04-06 — DEC-GUARD-WT-001` Guardian mode signaling via completion
  verdict, not routing table branching. Guardian determines its mode (provision
  vs merge) from dispatch context, not from a separate routing key. Planner
  routes to Guardian. Guardian emits `LANDING_RESULT: provisioned` for
  worktree creation, which routes to implementer.
- `2026-04-06 — DEC-GUARD-WT-002` Worktree provisioning is a runtime function,
  not a dispatch_engine side effect. dispatch_engine remains pure (no git side
  effects, no lease writes — R3 restored full purity). `cc-policy worktree
  provision` handles the entire sequence: `git worktree add` (subprocess),
  DB registration, Guardian lease, implementer lease, workflow binding.
  Guardian calls one CLI command, does not run git worktree add separately.
  Uses register()'s ON CONFLICT as sole concurrency guard (no list_active
  pre-check). See DEC-GUARD-WT-008 (R3: filesystem-first).
- `2026-04-06 — DEC-GUARD-WT-003` Worktree path injection via dispatch result
  enrichment. Guardian's completion record includes WORKTREE_PATH in payload.
  dispatch_engine reads it from completion record and includes it in result.
  **REVISED 2026-04-06 R1**: cli.py must serialize `worktree_path` in output.
  **REVISED 2026-04-06 R2**: The critical carrier to the orchestrator is the
  suggestion text, not the cli.py JSON field. post-task.sh strips the result to
  `hookSpecificOutput` only. The suggestion builder must encode worktree_path in
  the AUTO_DISPATCH line: `AUTO_DISPATCH: implementer (worktree_path=<path>,
  workflow_id=<W>)`. Full carrier chain:
  completion_record.payload_json.WORKTREE_PATH -> dispatch_engine result ->
  suggestion text -> hookSpecificOutput.additionalContext -> orchestrator.
- `2026-04-06 — DEC-GUARD-WT-004` Worktree reuse on rework cycles.
  `(tester, needs_changes) -> implementer` does not re-provision. dispatch_engine
  reads existing worktree_path from workflow_bindings table via
  workflows.get_binding(). **REVISED 2026-04-06**: Workflow binding creation
  moves from subagent-start.sh to Guardian provisioning (W-GWT-2) so the
  binding exists when dispatch_engine needs it for rework routing.
- `2026-04-06 — DEC-GUARD-WT-005` `isolation: "worktree"` on Agent tool calls
  is forbidden. No runtime enforcement possible (harness controls isolation
  before hooks fire). CLAUDE.md prompt constraint is sufficient.
- `2026-04-06 — DEC-GUARD-WT-006` **Guardian provisioning lease (REVISED R2:
  fail-closed, REVISED R3: moved to W-GWT-2).** Guardian needs its own
  lease to anchor completion record submission. **R3:** Lease issuance moves
  from dispatch_engine (W-GWT-1) to the provision CLI (W-GWT-2). The R2
  design assumed the planner always holds a lease at PROJECT_ROOT — this is
  wrong (subagent-start.sh claims, does not issue; existing tests model
  planner stops with no lease). The provision CLI issues the Guardian lease
  at PROJECT_ROOT as part of the provision sequence: filesystem first, then
  register, then Guardian lease, then implementer lease, then workflow
  binding. workflow_id at planner stop is best-effort (lease -> branch
  fallback -> orchestrator context). dispatch_engine returns to pure routing
  (no lease writes). check-guardian.sh reads the Guardian lease to submit the
  completion record. Guardian's lease is released by dispatch_engine when
  processing guardian stop.
- `2026-04-06 — DEC-GUARD-WT-007` **Structured guardian_mode dispatch field.**
  dispatch_engine includes `guardian_mode` in the suggestion text as a
  structured prefix: `AUTO_DISPATCH: guardian (mode=provision,
  workflow_id=W, feature_name=X)`. This is parsed by the orchestrator and
  included in Guardian's dispatch context. Eliminates implicit mode detection.
- `2026-04-06 — DEC-GUARD-WT-008` **Provision-if-absent idempotency (REVISED R2:
  no list_active pre-check, REVISED R3: filesystem-first order).** Provision
  sequence reversed: filesystem first (`git worktree add`), then DB
  (`register`, `leases.issue`, `bind_workflow`). Already-exists detection via
  filesystem check (does the path exist on disk?), not via `register()` return
  value parsing. If `git worktree add` fails, nothing to clean up (no DB state
  written). If DB writes fail after filesystem creation, cleanup:
  `git worktree remove` + `worktrees.remove()`. No `list_active()` pre-check
  (TOCTOU). `register()`'s `ON CONFLICT(path) DO UPDATE` remains the DB-level
  idempotency guard.
- `2026-04-06 — DEC-ENFORCE-001` **Replace `_GIT_OP_RE` with
  `classify_git_op()` call.** The regex only covered commit/merge/push,
  missing worktree remove, branch -d/-D, rebase, reset, clean. Using the
  canonical Python classifier in `bash_git_who.py` eliminates the regex sync
  burden. The bash mirror in `context-lib.sh` is updated in parallel; the
  Python version in `leases.py` is authoritative when they disagree. Parity
  is enforced by scenario tests.
- `2026-04-06 — DEC-ENFORCE-002` **Role-scoped lease resolution.** When
  `build_context()` finds a lease by worktree_path (no actor_id match), it now
  validates that actor_role matches the lease's role. Empty actor_role (the
  orchestrator case) gets lease=None. This prevents the orchestrator from
  inheriting Guardian permissions.
- `2026-04-06 — DEC-ENFORCE-003` **Fail-closed safety wrapper.** New
  `hooks/lib/hook-safety.sh` provides `_run_fail_closed`. Any hook crash is
  caught, converted to deny JSON + observatory event + exit 0. Works within
  Claude Code's "non-zero = does not block" contract by ensuring hooks NEVER
  exit non-zero.
- `2026-04-06 — DEC-ENFORCE-004` **Auto-review heredoc crash fix.** The
  `analyze_substitutions()` function now checks for heredocs in extracted
  `$()` inner content before recursing, preventing the paren-depth counter
  crash that exited non-zero and silently allowed the command.
- `2026-04-07 — DEC-SOURCEEXT-001` **Modern JS module variants added to
  SOURCE_EXTENSIONS.** `mjs`, `cjs`, `mts`, `cts` are added to both the Python
  authority (`runtime/core/policy_utils.py:SOURCE_EXTENSIONS`) and the shell
  mirror (`hooks/context-lib.sh:SOURCE_EXTENSIONS`). Rationale: every
  write-side WHO gate (`branch_guard`, `write_who`, `doc_gate`, `plan_guard`,
  `test_gate_pretool`, `mock_gate`) classifies via `is_source_file()`. Without
  the modern ESM/CJS/TS-module extensions, modules in those formats bypass
  the entire write-side enforcement chain — directly reproduced by editing
  `plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs`
  on main without policy intervention. The hard-coded source-extension regex
  in `hooks/check-implementer.sh:68` is intentionally NOT touched here; it
  is a separate, bigger refactor (unify into the shared helper) tracked as
  ENFORCE-RCA-9.
- `2026-04-07 — DEC-EVAL-HOOKOUT-001` **PreToolUse hook output must include
  `hookEventName`.** The `hookSpecificOutput` dict emitted by
  `runtime/cli.py:_handle_evaluate` (lines ~1296-1321) MUST set
  `"hookEventName": "PreToolUse"` in all three branches (`deny`, `feedback`,
  `allow`). Rationale: the Claude Code hook output contract documented at
  `hooks/HOOKS.md:28-34` requires `hookEventName` as a peer of
  `permissionDecision`; without it, Claude Code's harness silently discards
  the entire `hookSpecificOutput` block and the underlying tool call executes
  unblocked. Commit `3be693f` (PE-W1, 2026-04-03) introduced
  `_handle_evaluate` without the field, and from that moment every deny
  emitted by `branch_guard`, `write_who`, `bash_main_sacred`, `bash_git_who`,
  `doc_gate`, `plan_guard`, `test_gate_pretool`, `mock_gate`, and
  `enforcement_gap` via the `cc-policy evaluate` path was a no-op — the
  policy-engine metric fired but the harness never honored the deny. This
  defect is the empirically-verified root cause of the four-day "orchestrators
  bypassing dispatch" complaint. The crash-deny path in
  `hooks/lib/hook-safety.sh:56` was the only correctly-shaped deny in the
  system because it injects `hookEventName` as a literal string. The cell at
  `runtime/cli.py:533` (the `process-stop` handler) already includes
  `hookEventName`, demonstrating that the contract is known and the omission
  in `_handle_evaluate` was a localized regression rather than a systemic
  misunderstanding. Verified independently by a parallel Codex rescue probe
  (session `019d69bd-fcc6-7012-b435-9d6398fc0ad1`) which returned
  `"VERDICT: JSON shape MISSING hookEventName at runtime/cli.py:1298"` in
  53 seconds. The fix is enforced going forward by extending
  `tests/runtime/policies/test_hook_scenarios.py` to assert
  `hookEventName == "PreToolUse"` on every deny payload, so any future drop
  of the field fails CI rather than silently disabling enforcement.
- `2026-04-07 — DEC-ENFORCE-REVIEW-GATE-002` **SubagentStop review path is
  unconditional; `config.stopReviewGate` gates only the user-facing regular
  Stop path.** The early-return at
  `plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs:591-596`
  currently bails out for BOTH the SubagentStop and regular Stop branches
  when `config.stopReviewGate === false`. Because `config.stopReviewGate`
  defaults to false and is only toggled on by the user via
  `codex-companion.mjs setup --enable-review-gate`, the SubagentStop branch
  (lines 613-646, which writes `codex_stop_review` events via
  `emitCodexReviewEventSync` at line 622) never runs in a default install.
  The downstream consumer `runtime/core/dispatch_engine.py:_check_codex_gate`
  (lines 406-445) looks for those events within a 60-second window to set
  `codex_blocked=True` and suppress `AUTO_DISPATCH` on BLOCK verdicts; with
  the events table empty, the gate silently always-allows. The SubagentStop
  review path is part of **dispatch-chain integrity** — it is an enforcement
  surface, not a user-facing convenience — and must run on every SubagentStop
  regardless of the flag. The user-facing regular-Stop path (interactive
  block at turn-end that the user opts into via
  `codex setup --enable-review-gate`) retains the flag as its opt-in gate.
  The fix flips the condition to
  `if (!isSubagentStop && !config.stopReviewGate)` — a single-line logic
  change plus a rationale comment block. Verified live in RCA-11 chain
  verification: the orchestrator observed zero `codex_stop_review` rows in
  the events table despite the hook being wired into all four SubagentStop
  matchers in `settings.json`. User verbatim direction: *"The stop review
  from codex setup isn't the one we want, we want it enforced at the stops
  and the subagent returns in our own mechanism so make sure to understand
  that properly."*
- `2026-04-07 — DEC-CONFIG-AUTHORITY-001` **Policy engine is the canonical
  authority for enforcement configuration.** A new SQLite table
  `enforcement_config(scope TEXT, key TEXT, value TEXT, updated_at INTEGER,
  PRIMARY KEY (scope, key))` with index on `(key, scope)` is added to
  `runtime/schemas.py:ALL_DDL`. Defaults are seeded at table-creation time
  and mirrored in `runtime/core/enforcement_config.py` as fail-safe fallback
  constants. Scoping follows the `(scope, key)` convention already used by
  `workflow_scope` and the policy engine's scope resolution: lookups fall
  back from `workflow=<workflow_id>` → `project=<project_root>` → `global`
  → built-in default. `build_context()` (runtime/core/policy_engine.py:328)
  loads rows for the current scope in a single indexed query and exposes
  them on a new `PolicyContext.enforcement_config: dict` field so policies
  and hook bridges read config without any additional I/O. A new
  `cc-policy config {get,set,list}` CLI domain mirrors the existing
  `evaluation`, `marker`, and `workflow` domains. Mutations through `set`
  are WHO-gated: `runtime/core/enforcement_config.set` raises
  `PermissionError` when `actor_role` is not `"guardian"`, surfaced by the
  CLI as a JSON error. This prevents the orchestrator (actor_role="") or
  any subagent from self-toggling its own enforcement constraints — a
  structural requirement because `build_context()` already refuses to
  elevate an actor_role=empty caller into any role with write privileges.
  The previous authority — the Codex plugin's `state.json.stopReviewGate`
  field written by `codex-companion.mjs setup --enable-review-gate` — is
  deprecated as the canonical source for review-gate toggles; the plugin
  retains a transitional dual-write shim in `lib/state.mjs:setConfig` that
  ALSO calls `cc-policy config set review_gate_regular_stop …` so the UI
  shortcut keeps working for one release. After that release the plugin's
  own `stopReviewGate` field will be deleted. Rationale: RCA-15 (regular
  Stop review default-on) is pointless if the config authority is still a
  plugin-local JSON blob — every cycle the Codex plugin rewrites
  `state.json` would reintroduce the old default. Flipping the default
  without first moving the authority leaves dual-authority for at least
  one cycle, which violates the single-source-of-truth Sacred Practice.
  This decision was converged with Codex against five architectural
  questions (Q1-Q5) and Codex confirmed there is no higher-priority
  blocker; this IS the shortest path to the north-star "policy engine is
  canonical" state. The three architectural risks Codex identified
  (scoping drift, fail-open wrapper suppression, Node hooks bypassing
  project scoping via missing `CLAUDE_POLICY_DB`) are mitigated by: the
  `(scope, key)` schema from day one; an explicit `__FAIL_CLOSED__`
  sentinel return from `rt_config_get` in `hooks/lib/runtime-bridge.sh`;
  and a mandatory `CLAUDE_POLICY_DB = <CLAUDE_PROJECT_DIR>/.claude/state.db`
  assignment in `stop-review-gate-hook.mjs` before every shell-out to
  `cc-policy`, mirroring the existing `cc_policy()` pattern at
  `hooks/lib/runtime-bridge.sh:23-29`.
- `2026-04-07 — DEC-REGULAR-STOP-REVIEW-001` **Regular-Stop Codex review is
  enforced by default.** Seed value for `review_gate_regular_stop` in the
  newly-created `enforcement_config` table is `true`, scope `global`. The
  current default (`config.stopReviewGate === false` in the Codex plugin
  `state.json`) is the failure state — it means the regular-Stop review
  code path in `plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs`
  (the user-facing turn-end gate, lines ~656-end) never runs unless the
  user explicitly opted in via `codex setup --enable-review-gate`. The
  `stop-review-gate-hook.mjs` main function is retargeted to read
  `review_gate_regular_stop` from `cc-policy config get` instead of from
  `getConfig(workspaceRoot).stopReviewGate`. This flips the default on
  immediately, with no advisory week, because an advisory week adds zero
  signal and because the
  regular-Stop review is the enforcement surface that covers the very
  turn type the orchestrator operates on — every user-initiated session
  stop. Codex concurred that this is a "flip and ship" default. If the
  user wants to disable regular-Stop review locally, the procedure is
  `cc-policy config set review_gate_regular_stop false` (requires
  guardian lease; the orchestrator can request this via the normal
  guardian dispatch path). This decision is tested by live-dispatch
  verification in the W-ENFORCE-RCA-15 Evaluation Contract: after the
  patch lands, `cc-policy config get review_gate_regular_stop` returns
  `true` in clean installs, AND a regular Stop in this session fires
  the Codex review (verifiable by a `codex_stop_review` event landing
  in the events table within 60s of session stop). The fix is a pure
  default flip combined with the config-source retarget from
  DEC-CONFIG-AUTHORITY-001 — it is not a behavioral rewrite of the
  review path itself; that code (lines 656-end) stays intact.

### Bootstrap admission decisions

- `2026-04-29 — DEC-ADMIT-001` **Bootstrap admission `consume()` precedes
  state-mutating writes.** In
  `runtime.core.workflow_bootstrap.bootstrap_local_workflow`, the
  `bootstrap_requests_mod.consume(...)` call moves from the post-write
  position (current line ~408, after `bind_workflow`, `upsert_goal`,
  `upsert_work_item`, `set_status`, and `build_stage_packet`) to the
  pre-write position immediately after `_validate_existing_state(...)` and
  before `workflows_mod.bind_workflow(...)`. The atomic `UPDATE ... WHERE
  token=? AND consumed=0` inside `bootstrap_requests.consume` becomes the
  admission gate; under a write-time race, the loser raises
  `BootstrapRequestError` before any side effects land, instead of after.
  Trade-off accepted: the new failure mode is "admission succeeds, a
  downstream upsert fails, token is burned, operator must re-mint via
  `bootstrap-request`." This is rare (the upserts run against a fixed
  schema with no foreign-key surprises) and recoverable (one CLI re-mint).
  The reverse failure mode (current ordering: writes succeed, admission
  denial after) leaves a confusing audit trail and mis-trains operators.
  This matches the `lease`-style admission idiom used elsewhere in the
  runtime. Closes GitHub issue #68. Implementer must add an inline
  `@decision DEC-ADMIT-001` comment at the moved call site so the
  ordering is discoverable from source.
- `2026-04-29 — DEC-ADMIT-002` **`resolve_pending` reports the resolved DB
  path on `token_not_found`.** `runtime.core.bootstrap_requests.resolve_pending`
  gains an optional `db_path: str | None = None` keyword argument, threaded
  through from `bootstrap_local_workflow` (which already resolves
  `db_path`). When the row lookup misses, the raised
  `BootstrapRequestError` message names the resolved DB path the runtime
  actually opened, states that bootstrap tokens are scoped to the worktree
  where `bootstrap-request` was issued, tells the operator to verify
  `--worktree-path` matches that worktree, and tells the operator to re-run
  `bootstrap-request` from the correct worktree if it was issued
  elsewhere. `consume()` already calls `resolve_pending` internally and
  must thread the same `db_path` keyword through. The audit-event
  `detail` payload for the `workflow.bootstrap.denied`
  `reason=token_not_found` branch is intentionally NOT changed; the new
  context lives in the operator-facing exception message, not in the
  audit row. The audit row already records `worktree_path` for forensic
  correlation. Forbidden alternatives: cross-DB scans, a global
  breadcrumb table, or embedding the DB path in the token string itself —
  each re-introduces a parallel admission authority. Closes GitHub
  issue #69.

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

- **Status:** complete (all 6 waves landed, 2026-04-05/06)
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
- **Handoff:** source handoff retired in Phase 8 Slice 6 (2026-04-13);
  conclusions, corrections, and the 6-packet priority order are preserved
  in this INIT-CONV section and W-CONV-1 through W-CONV-7 below.
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

- **Status:** complete (merged 2026-04-06)
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

> **Superseded by DEC-PHASE5-STOP-REVIEW-SEPARATION-001 (Phase 5 Slice 2).**
> The stop-review gate no longer influences workflow `auto_dispatch` or
> `next_role`. `_check_codex_gate` has been deleted. The gate hook is retained
> in `settings.json` for user-facing review observability only — its
> `codex_stop_review` events are not consumed by the dispatch engine.
> The specification below is preserved for historical context.

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
  check-*.sh         --+                          +-- obs_analyze()
  test-runner.sh     --+-- rt_obs_metric() --> obs_metrics  --+
  pre-write.sh       --+   (or batch flush)       |   obs_suggest()
  pre-bash.sh        --+                          |   obs_converge()
  track.sh           --+                          +-- SKILL.md (LLM)
  session-end.sh     --+                               |
  post-task.sh       --+                          obs_suggestions
  log.sh             --+                          (lifecycle mgmt)
                                                       |
                                                  obs_runs
                                                  (analysis history)
```

Note: `subagent-start.sh` is not an emission source (it produces context,
not metrics). `auto-review.sh` is not an emission source (its classification
data is consumed by `pre-bash.sh`). DEC-OBS-011 retired the `post-task.sh`
review-metric reader because broad SubagentStop reviews are no longer emitted;
regular Stop review visibility is carried by `codex_stop_review` events and
the statusline.

**What hooks emit (additive, not new hooks):**

| Metric Name | Source Hook | Data | Frequency |
|---|---|---|---|
| `agent_duration_s` | `check-*.sh` | role, duration seconds, verdict | Every agent stop |
| `test_result` | `test-runner.sh` | pass/fail/skip counts, duration | Every test run |
| `guard_denial` | `pre-write.sh`, `pre-bash.sh` | policy name, reason | Every denial |
| `eval_verdict` | `check-tester.sh` | verdict, blockers/major/minor | Every evaluator run |
| `commit_outcome` | `check-guardian.sh` | result, operation class | Every guardian run |
| `files_changed` | `track.sh` | count | Every file write |
| `hook_failure` | `log.sh` (error handler) | hook name, exit code | Every hook failure |
| `session_summary` | `session-end.sh` | prompts, duration, agents spawned | Every session end |
| `review_verdict` | Retired from `post-task.sh` | Stop-hook `codex_stop_review` events remain visible; future Stop-owned metric emitter if needed | DEC-OBS-011 |
| `review_duration_s` | Retired from `post-task.sh` | Stop-hook `codex_stop_review` events remain visible; future Stop-owned metric emitter if needed | DEC-OBS-011 |
| `review_infra_failure` | Retired from `post-task.sh` | Stop-hook `codex_stop_review` events remain visible; future Stop-owned metric emitter if needed | DEC-OBS-011 |

**Metric schema (obs_metrics):**

```sql
CREATE TABLE IF NOT EXISTS obs_metrics (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    metric_name TEXT    NOT NULL,
    value       REAL    NOT NULL,
    role        TEXT,
    labels_json TEXT,
    session_id  TEXT,
    created_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_obs_metrics_name_time
    ON obs_metrics (metric_name, created_at);
CREATE INDEX IF NOT EXISTS idx_obs_metrics_role
    ON obs_metrics (role, metric_name, created_at);
```

- `metric_name`: one of the defined metric names above
- `value`: numeric value (duration in seconds, count, 0/1 for boolean)
- `role`: first-class dimension for the most common filter path (nullable;
  e.g., `implementer`, `tester`, `guardian`, `planner`). Extracted from
  labels at emission time to avoid full JSON scan on every role-based query.
  (DEC-OBS-006)
- `labels_json`: JSON object with additional dimension keys for filtering
  (e.g., `{"verdict": "complete", "policy": "scope_check"}`). Role is NOT
  duplicated here -- use the `role` column for role filtering.
- `session_id`: links to the traces table for session context
- `created_at`: epoch timestamp for time series queries

**Suggestion schema (obs_suggestions):**

```sql
CREATE TABLE IF NOT EXISTS obs_suggestions (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    signal_id            TEXT,
    category             TEXT    NOT NULL,
    title                TEXT    NOT NULL,
    body                 TEXT,
    target_metric        TEXT,
    baseline_value       REAL,
    status               TEXT    NOT NULL DEFAULT 'proposed',
    disposition_at       INTEGER,
    reject_reason        TEXT,
    defer_reassess_after INTEGER,
    measure_after        INTEGER,
    measured_value       REAL,
    effective            INTEGER,
    source_session       TEXT,
    created_at           INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_obs_suggestions_status
    ON obs_suggestions (status);
CREATE INDEX IF NOT EXISTS idx_obs_suggestions_signal
    ON obs_suggestions (signal_id);
```

- `signal_id`: optional stable identifier for the underlying signal (e.g.,
  `repeated_denial:scope_check`) so the system can detect re-proposals of
  the same issue and link suggestion chains. (DEC-OBS-008)
- `category`: pattern type (e.g., `repeated_denial`, `slow_agent`,
  `test_regression`, `stale_marker`, `evaluation_churn`)
- `target_metric`: which metric this suggestion claims to improve
- `baseline_value`: the metric's value at suggestion time (for convergence)
- `status`: `proposed`, `accepted`, `rejected`, `deferred`, `measured`
- `reject_reason`: free-text rationale when status is `rejected` (why it
  was declined; aids future pattern detection to avoid re-proposing similar
  suggestions)
- `defer_reassess_after`: number of sessions before a deferred suggestion is
  re-surfaced. Default: 5 sessions. When the defer count expires, status
  reverts to `proposed`.
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

**Analysis run history (obs_runs):**

```sql
CREATE TABLE IF NOT EXISTS obs_runs (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    ran_at           INTEGER NOT NULL,
    metrics_snapshot TEXT,
    trace_count      INTEGER,
    suggestion_count INTEGER
);
```

- `ran_at`: epoch timestamp of the analysis run
- `metrics_snapshot`: JSON summary of key metrics at run time (enables
  convergence comparison between runs without re-querying historical data)
- `trace_count`: number of trace entries at analysis time
- `suggestion_count`: number of active suggestions at analysis time

Each `obs_analyze()` or `cc-policy obs summary` invocation records a run.
`latest_run()` returns the most recent snapshot. Convergence tracking can
compare current metrics to the metrics-at-time-of-suggestion by referencing
the run that was active when the suggestion was created. (DEC-OBS-009)

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

- `emit_metric(conn, name, value, labels, session_id, role=None)` -- insert
  a metric row. If `role` is provided, it is stored in the first-class `role`
  column (indexed). If `role` is None but labels contains a "role" key, the
  value is extracted and stored in the `role` column automatically.
- `emit_batch(conn, metrics_list)` -- insert multiple metric rows in a single
  transaction. Each element is a dict with keys matching `emit_metric` args.
  Used by the shell batch-flush pattern to avoid per-metric subprocess cost.
  (DEC-OBS-007)
- `query_metrics(conn, name, since, until, labels_filter, role=None)` -- time
  series. When `role` is specified, uses the indexed `role` column instead of
  JSON scan on labels_json.
- `compute_trend(conn, name, window_hours)` -- moving average with slope
- `detect_anomalies(conn, name, threshold_sigma)` -- values beyond N sigma
- `agent_performance(conn, role, window_hours)` -- duration/verdict stats
  (uses indexed `role` column)
- `denial_hotspots(conn, window_hours)` -- most-denied policies
- `test_health(conn, window_hours)` -- pass rate trend
- `suggest(conn, category, title, body, target_metric, baseline,
  signal_id=None)` -- create suggestion with optional stable signal_id
- `accept_suggestion(conn, id, measure_after)` -- accept with measurement window
- `reject_suggestion(conn, id, reason=None)` -- reject with optional reason
- `defer_suggestion(conn, id, reassess_after=5)` -- defer with session count
  before re-surfacing (default 5 sessions)
- `batch_accept(conn, category)` -- accept all proposed suggestions in a
  category at once, setting measure_after to default window. Returns count
  of accepted suggestions. (DEC-OBS-008)
- `check_convergence(conn)` -- measure all accepted suggestions past their window
- `record_run(conn, metrics_snapshot, trace_count, suggestion_count)` -- record
  an analysis run in obs_runs. Called automatically by summary().
- `latest_run(conn)` -- return the most recent obs_runs row
- `obs_cleanup(conn, metric_ttl_days=30, suggestion_ttl_days=90)` -- delete
  obs_metrics rows older than metric_ttl_days and obs_suggestions in terminal
  states (measured, rejected) older than suggestion_ttl_days
- `status(conn)` -- quick health check without LLM: pending suggestion count,
  acceptance rate, last analysis timestamp, total metric count. Used by
  `cc-policy obs status`.
- `summary(conn, window_hours)` -- full observatory report dict. Records an
  obs_runs entry on each invocation.

#### Wave Plan

```
W-OBS-1 (Schema + Domain + CLI)
  [obs_metrics (with role column), obs_suggestions (with signal_id),
   obs_runs, emit_batch, batch_accept, obs status, obs cleanup]
    +--> W-OBS-2 (Hook Emission + Review Metrics)
           [batch/async emission, post-task.sh review metrics]
              +--> W-OBS-3 (Analysis + SKILL.md)
                     [LEFT JOIN cross-analysis, review gate health,
                      pattern detection, SKILL.md with Review Gate Health]
                        +--> W-OBS-4 (Integration Tests + Sidecar Upgrade)
```

W-OBS-1 must land first (tables, API, batch primitives exist). W-OBS-2
depends on W-OBS-1 (emission needs the domain module and batch API). W-OBS-3
depends on W-OBS-2 (analysis needs data). W-OBS-4 depends on W-OBS-3
(integration tests exercise the full pipeline).

Critical path: W-OBS-1 -> W-OBS-2 -> W-OBS-3 -> W-OBS-4. Max width: 1.

Note: SKILL.md drafting can begin during W-OBS-2 (defining trigger, flow
outline, presentation structure with placeholder analysis calls) and be
finalized in W-OBS-3. This does not change the critical path but allows
parallel work within the linear dependency chain.

##### W-OBS-1: Schema, Domain Module, and CLI

- **Weight:** M
- **Gate:** review (user sees schema and CLI output)
- **Deps:** none

**Implementer scope:**

- `runtime/schemas.py` -- add `OBS_METRICS_DDL`, `OBS_METRICS_INDEX_DDL`,
  `OBS_METRICS_ROLE_INDEX_DDL`, `OBS_SUGGESTIONS_DDL`,
  `OBS_SUGGESTIONS_INDEX_DDL`, `OBS_SUGGESTIONS_SIGNAL_INDEX_DDL`,
  `OBS_RUNS_DDL` constants and add them to `ALL_DDL`.
- `runtime/core/observatory.py` -- NEW: domain module with all functions
  listed in the "Analysis functions" section above. Each function takes a
  `sqlite3.Connection` as first argument (consistent with all other domain
  modules). Pure SQL queries, no subprocess calls. Includes `emit_batch()`
  for bulk insertion (single transaction) and `status()` for quick health
  check.
- `runtime/cli.py` -- add `obs` domain with actions:
  - `cc-policy obs emit <name> <value> [--labels '...'] [--session-id '...'] [--role '...']`
  - `cc-policy obs emit-batch` (reads JSON array from stdin, each element has
    name/value/labels/session_id/role keys; calls `emit_batch()` in one
    transaction)
  - `cc-policy obs query <name> [--since N] [--until N] [--labels '...'] [--role '...'] [--limit N]`
  - `cc-policy obs trend <name> [--window-hours N]`
  - `cc-policy obs anomalies <name> [--threshold N]`
  - `cc-policy obs agent-perf <role> [--window-hours N]`
  - `cc-policy obs denial-hotspots [--window-hours N]`
  - `cc-policy obs test-health [--window-hours N]`
  - `cc-policy obs suggest <category> <title> [--body '...'] [--target-metric '...'] [--baseline N] [--signal-id '...']`
  - `cc-policy obs accept <id> [--measure-after N]`
  - `cc-policy obs reject <id> [--reason '...']`
  - `cc-policy obs defer <id> [--reassess-after N]`
  - `cc-policy obs batch-accept <category>`
  - `cc-policy obs converge`
  - `cc-policy obs status` (quick health: pending count, acceptance rate, last
    analysis, total metrics -- no LLM needed)
  - `cc-policy obs summary [--window-hours N]`
- `hooks/lib/runtime-bridge.sh` -- add two shell wrappers:
  - `rt_obs_metric <name> <value> [labels_json] [session_id] [role]` -- single
    metric emission. For hot-path hooks (track.sh, pre-write.sh, pre-bash.sh),
    use `& disown` pattern to make truly async. For non-hot-path hooks, use
    synchronous call with `|| true`.
  - `rt_obs_metric_batch` -- flush accumulated `_OBS_BATCH` array via a single
    `cc-policy obs emit-batch` call. Hooks accumulate metrics in `_OBS_BATCH`
    shell array during execution and call `rt_obs_metric_batch` once at hook
    exit. Pattern:
    ```
    _OBS_BATCH=()
    _obs_accum() { _OBS_BATCH+=("$(printf '{"name":"%s","value":%s,"labels":%s,"role":"%s"}' "$1" "$2" "${3:-null}" "${4:-}")"); }
    rt_obs_metric_batch() {
      [[ ${#_OBS_BATCH[@]} -eq 0 ]] && return 0
      printf '[%s]' "$(IFS=,; echo "${_OBS_BATCH[*]}")" | cc_policy obs emit-batch >/dev/null 2>&1 || true
      _OBS_BATCH=()
    }
    ```
  Export both via the existing export block.
  Note: the `rt_obs_metric` wrapper definition lives in `runtime-bridge.sh`;
  the export statement is in `context-lib.sh` at the end-of-file export block.
- `hooks/context-lib.sh` -- add `rt_obs_metric`, `rt_obs_metric_batch`,
  `_obs_accum` to the export list.
- `tests/runtime/test_cc_policy.sh` -- update the hard-coded table inventory
  at the EXPECTED variable (currently line ~105) to include `obs_metrics`,
  `obs_runs`, `obs_suggestions` in the sorted alphabetical list.
- `tests/runtime/test_observatory.py` -- NEW: unit tests covering:
  - emit_metric round-trip (emit, query, verify) including role column
  - emit_batch with multiple metrics in one call
  - query_metrics with role filter uses indexed column
  - compute_trend with synthetic data
  - detect_anomalies with synthetic outlier
  - suggest/accept/reject/defer lifecycle with signal_id, reject_reason,
    defer_reassess_after
  - batch_accept by category
  - check_convergence with improved/unchanged/regressed scenarios
  - record_run and latest_run round-trip
  - obs_cleanup removes old metrics and terminal suggestions
  - status returns expected keys
  - summary output structure and obs_runs recording

**Tester scope:**

- `obs_metrics`, `obs_suggestions`, and `obs_runs` tables exist after
  `ensure_schema()`
- `emit_metric` writes a row with `role` column populated; `query_metrics`
  reads it back with correct values including role filter
- `emit_batch` writes multiple rows in a single transaction
- `compute_trend` returns slope and average
- `detect_anomalies` returns outliers beyond threshold
- `suggest` -> `accept` -> `check_convergence` lifecycle produces measured
  status; signal_id, reject_reason, defer_reassess_after columns populated
- `batch_accept` accepts all proposed suggestions in a category
- `record_run` and `latest_run` round-trip correctly
- `obs_cleanup` removes old data from obs_metrics and terminal suggestions
- `status` returns pending count, acceptance rate, last analysis, total metrics
- CLI `cc-policy obs emit/emit-batch/query/suggest/accept/reject/defer/
  batch-accept/converge/status/summary` all produce valid JSON output
- `rt_obs_metric` shell wrapper calls `cc-policy obs emit` successfully
- `rt_obs_metric_batch` flushes accumulated batch successfully
- `tests/runtime/test_cc_policy.sh` table inventory check passes with new
  obs tables included
- No writes to any existing table (obs tables only)
- All existing tests pass

###### Evaluation Contract for W-OBS-1

**Required tests:**

1. `tests/runtime/test_observatory.py` exists and passes with 0 failures
2. `emit_metric` + `query_metrics` round-trip: emitted row has correct
   `metric_name`, `value`, `role`, `labels_json`, `session_id`, `created_at`.
   Query by name returns the row. Query with `role` filter returns only
   matching rows and uses the indexed `role` column (verify via EXPLAIN
   QUERY PLAN or by asserting correct results with role filter).
3. `emit_batch` with 5+ metrics: all rows persisted in a single transaction;
   row count matches input list length; each row has correct values
4. `compute_trend` with 10+ data points returns dict with `slope` and `average`
5. `detect_anomalies` with injected outlier returns the outlier row (not just
   a truthy value -- verify the returned row's value matches the injected
   outlier)
6. Full suggestion lifecycle: propose (with signal_id) -> accept
   (with measure_after) -> measure -> converge. Verify each status transition
   and that signal_id, reject_reason, defer_reassess_after columns are
   correctly populated at each stage.
7. `batch_accept` with 3+ proposed suggestions in a category: all transition
   to `accepted`; suggestions in other categories remain `proposed`
8. `check_convergence` correctly classifies improved (effective=1),
   unchanged (effective=0), and regressed (effective=-1) metrics
9. `record_run` inserts a row; `latest_run` returns it with correct
   metrics_snapshot JSON and counts
10. `obs_cleanup` deletes metrics older than TTL and suggestions in terminal
    states older than TTL; preserves recent data
11. `status` returns dict with keys: `pending_count`, `acceptance_rate`,
    `last_analysis_at`, `total_metrics`
12. `summary` returns dict with keys: `metrics_24h`, `active_suggestions`,
    `recent_anomalies`, `convergence_results`, `agent_performance`,
    `denial_hotspots`, `test_health`; also records an obs_runs entry
    (verify obs_runs row count increments)

**Required real-path checks:**

13. `cc-policy obs emit test_metric 42.0 --labels '{"key":"val"}' --role tester`
    writes a row to `obs_metrics` with `role='tester'` in the role column
14. `cc-policy obs query test_metric --role tester` returns the row from check 13
15. `echo '[{"name":"m1","value":1.0},{"name":"m2","value":2.0}]' | cc-policy obs emit-batch`
    writes 2 rows to `obs_metrics`
16. `cc-policy obs suggest test_cat "Test Title" --signal-id "test:sig1"` creates
    an obs_suggestions row with signal_id populated
17. `cc-policy obs status` returns valid JSON with pending_count and total_metrics
18. `cc-policy obs summary` returns valid JSON with the expected report structure
    and creates an obs_runs row
19. `rt_obs_metric test_metric 42.0 '{"key":"val"}' '' tester` in a bash context
    persists a row with role=tester in obs_metrics (verify via SELECT, not just
    exit code)
20. `tests/runtime/test_cc_policy.sh` passes with the updated table inventory
    including obs_metrics, obs_runs, obs_suggestions

**Required authority invariants:**

- `obs_metrics` is the sole store for observatory metrics (no JSONL, no flat
  files)
- `obs_suggestions` is the sole store for suggestion lifecycle (no flat files)
- `obs_runs` is the sole store for analysis run history
- No reads or writes to any existing table (events, traces, completion_records,
  etc.) from the observatory domain module in this wave -- analysis queries
  that join across tables come in W-OBS-3
- `ensure_schema()` creates all three new tables idempotently

**Required integration points:**

- `runtime/schemas.py` `ALL_DDL` list includes the new DDL constants
  (metrics, metrics indexes, suggestions, suggestions indexes, runs)
- `runtime/cli.py` obs domain registered alongside existing domains
- `hooks/lib/runtime-bridge.sh` exports `rt_obs_metric` and
  `rt_obs_metric_batch` alongside existing `rt_*` functions
- `hooks/context-lib.sh` export list includes `rt_obs_metric`,
  `rt_obs_metric_batch`, `_obs_accum`
- `tests/runtime/test_cc_policy.sh` table inventory includes the 3 new tables

**Forbidden shortcuts:**

- Do not create a separate database for observatory data
- Do not add observatory methods to existing domain modules (events.py,
  traces.py, etc.) -- keep it in its own `observatory.py`
- Do not modify `settings.json`
- Do not modify any hook logic (emission is W-OBS-2)
- Do not add JSONL or flat-file output
- Do not omit the `role` column from obs_metrics (it is required for indexed
  filtering -- DEC-OBS-006)

**Ready-for-guardian definition:**

All 20 checks pass. Authority invariants hold. No forbidden shortcuts taken.
`git diff --stat` shows only files in the Scope Manifest.

###### Scope Manifest for W-OBS-1

**Allowed files/directories:**

- `runtime/schemas.py` (modify: add DDL constants)
- `runtime/core/observatory.py` (new: domain module)
- `runtime/cli.py` (modify: add obs domain)
- `hooks/lib/runtime-bridge.sh` (modify: add rt_obs_metric and
  rt_obs_metric_batch wrappers)
- `hooks/context-lib.sh` (modify: add rt_obs_metric, rt_obs_metric_batch,
  _obs_accum to export list)
- `tests/runtime/test_observatory.py` (new: unit tests)
- `tests/runtime/test_cc_policy.sh` (modify: update hard-coded table inventory
  at EXPECTED variable to include obs_metrics, obs_runs, obs_suggestions)

**Required files/directories:** All 7 of the above must be created or modified.

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
  (includes indexed `role` column)
- NEW: `obs_suggestions` table -- sole authority for suggestion lifecycle
  (includes signal_id, reject_reason, defer_reassess_after columns)
- NEW: `obs_runs` table -- sole authority for analysis run history
- MODIFIED: `runtime/schemas.py` ALL_DDL -- new entries appended
- MODIFIED: `runtime/cli.py` -- new domain handler registered
- MODIFIED: `hooks/lib/runtime-bridge.sh` -- new shell wrappers added
  (rt_obs_metric, rt_obs_metric_batch, _obs_accum)
- MODIFIED: `hooks/context-lib.sh` -- export list extended
- MODIFIED: `tests/runtime/test_cc_policy.sh` -- table inventory updated
- UNCHANGED: all existing tables, hooks, policies, sidecars

##### W-OBS-2: Hook Emission

- **Weight:** M
- **Gate:** review (user sees metric data flowing into obs_metrics)
- **Deps:** W-OBS-1 (tables and rt_obs_metric must exist)

**Implementer scope:**

Each hook below gains a small addition calling `rt_obs_metric` (individual
emission) or `_obs_accum` + `rt_obs_metric_batch` (batch pattern). No hook
logic is changed; emission is appended after existing processing.

**Emission pattern selection:**
- Hot-path hooks (track.sh, pre-write.sh, pre-bash.sh): use batch pattern
  (`_obs_accum` during hook, `rt_obs_metric_batch` at hook exit trap) to
  avoid per-metric subprocess cost. If only one metric is emitted, use
  `rt_obs_metric ... & disown` for truly async fire-and-forget.
- Non-hot-path hooks (check-*.sh, test-runner.sh, session-end.sh, log.sh,
  post-task.sh): use `rt_obs_metric ... || true` (synchronous, error-
  suppressed). These hooks are not latency-sensitive.

**Per-hook changes:**

- `hooks/check-implementer.sh` -- after completion record submission, emit
  `agent_duration_s` metric with role=`implementer` and labels
  `{"verdict":"..."}`. Duration computed from marker `started_at` to current
  epoch.
- `hooks/check-tester.sh` -- after evaluation state write, emit
  `agent_duration_s` with role=`tester` and labels `{"verdict":"..."}`, and
  `eval_verdict` with role=`tester` and labels
  `{"verdict":"...","blockers":N,"major":N,"minor":N}`.
- `hooks/check-guardian.sh` -- after landing result, emit `agent_duration_s`
  with role=`guardian` and labels `{"verdict":"..."}`, and `commit_outcome`
  with role=`guardian` and labels `{"result":"...","operation_class":"..."}`.
- `hooks/check-planner.sh` -- after planner checks, emit `agent_duration_s`
  with role=`planner`.
- `hooks/test-runner.sh` -- after test completion, emit `test_result` with
  labels `{"status":"...","pass":N,"fail":N,"skip":N}` and value = duration
  seconds.
- `hooks/pre-write.sh` -- when policy denies (exit with deny JSON), use
  `_obs_accum guard_denial 1 '{"policy":"...","hook":"pre-write"}'` and flush
  via `rt_obs_metric_batch` in the exit trap.
- `hooks/pre-bash.sh` -- when policy denies, use `_obs_accum guard_denial 1
  '{"policy":"...","hook":"pre-bash"}'` and flush via `rt_obs_metric_batch`
  in the exit trap.
- `hooks/track.sh` -- after file tracking, use `rt_obs_metric files_changed
  $count '' '' '' & disown` for async emission (track.sh is the highest-
  frequency hook; one metric per invocation does not justify batch overhead).
- `hooks/session-end.sh` -- emit `session_summary` with value = session
  duration seconds and labels `{"prompt_count":N,"agents_spawned":N}`.
- `hooks/log.sh` -- in the error handler (if one exists or add a minimal trap),
  emit `hook_failure` with value 1 and labels `{"hook":"...","exit_code":N}`.
  This is best-effort; if the runtime is unavailable, the failure itself should
  not cascade.
- Review metrics from `hooks/post-task.sh` are retired by DEC-OBS-011. The
  regular Stop hook still emits `codex_stop_review` events for visibility, but
  SubagentStop routing must not read stale Stop audit events to synthesize
  metrics. Future review metrics, if needed, should be emitted from a Stop-owned
  path.

**Tester scope:**

- Each modified hook emits the expected metric after its normal processing
- Metric values are numerically correct (duration matches actual elapsed,
  counts match actual counts)
- Labels JSON is valid and contains the expected keys
- The `role` column is populated for role-bearing metrics (agent_duration_s,
  eval_verdict, commit_outcome)
- Hot-path hooks (track.sh, pre-write.sh, pre-bash.sh) use batch pattern or
  `& disown` -- no synchronous subprocess wait on the critical path
- Non-hot-path hooks use `|| true` suppression
- Emission failures do not prevent the hook from completing its primary function
- No hook behavior changes (deny/allow decisions unchanged; output unchanged)
- All existing tests pass
- At least one new metric row appears in `obs_metrics` for each emission point
  after a representative hook execution
- Regular Stop `codex_stop_review` events remain visible via the events table
  and statusline; no SubagentStop review metrics are emitted from `post-task.sh`.

###### Evaluation Contract for W-OBS-2

**Required tests:**

1. After running check-implementer.sh with a mock agent stop, `obs_metrics`
   contains an `agent_duration_s` row with `role='implementer'` in the role
   column (SELECT where role='implementer', not JSON scan)
2. After running check-tester.sh with a valid eval trailer, `obs_metrics`
   contains `agent_duration_s` (role='tester') and `eval_verdict` rows
3. After running check-guardian.sh with a landing result, `obs_metrics`
   contains `commit_outcome` row with role='guardian'
4. After running test-runner.sh, `obs_metrics` contains `test_result` row
5. After a pre-write.sh denial, `obs_metrics` contains `guard_denial` row
   with labels containing `hook=pre-write` (emitted via batch pattern or
   `& disown`, not synchronous subprocess)
6. After a pre-bash.sh denial, `obs_metrics` contains `guard_denial` row
   with labels containing `hook=pre-bash` (emitted via batch pattern)
7. After track.sh fires, `obs_metrics` contains `files_changed` row
   (emitted via `& disown`, verified by waiting briefly then querying)
8. After session-end.sh fires, `obs_metrics` contains `session_summary` row
9. Hot-path hooks (track.sh, pre-write.sh, pre-bash.sh) use `& disown` or
   batch flush pattern -- verified by inspecting the hook source for the
   pattern, NOT by `|| true` alone (which does not make calls async)
10. No existing test regressions
11. No `post-task.sh` review-metric reader remains; seeded
    `codex_stop_review` events must not create stale SubagentStop review
    metrics (DEC-OBS-011)
12. Regular Stop `codex_stop_review` events remain queryable for visibility
    and statusline use

**Required real-path checks:**

13. Run a representative hook sequence (session-init -> subagent-start ->
    check-implementer -> check-tester -> check-guardian -> session-end) and
    verify obs_metrics has rows for each expected metric
14. `cc-policy obs query agent_duration_s --role implementer` returns the
    implementer row from check 13

**Required authority invariants:**

- No hook deny/allow decision is changed by emission
- No hook output format is changed by emission
- `obs_metrics` is the only table written by emission (no new event types
  in the events table for metrics)
- Hot-path emission is truly non-blocking (subprocess is backgrounded or
  batched, not just error-suppressed)
- Review metric emission reads from the events table, not from plugin scripts
  directly

**Required integration points:**

- Each emission site is in the same function/block where the relevant data is
  computed (e.g., duration is computed where the marker is read, not
  re-computed elsewhere)
- context-lib.sh sources and exports rt_obs_metric, rt_obs_metric_batch,
  _obs_accum so all hooks have access
- post-task.sh reads codex_stop_review events via rt_event_emit or direct
  SQL query on the events table

**Forbidden shortcuts:**

- Do not add new hook files or settings.json entries
- Do not change hook deny/allow logic
- Do not change hook output JSON structure
- Do not emit metrics to the events table (use obs_metrics)
- Do not use `|| true` alone as the non-blocking mechanism for hot-path hooks
  (it suppresses errors but does not prevent subprocess wait -- use `& disown`
  or batch pattern)
- Do not read review data from the plugin script file or its state.json --
  read from the events table only

**Ready-for-guardian definition:**

All 14 checks pass. Authority invariants hold. No forbidden shortcuts taken.
Hot-path emission is non-blocking. `git diff --stat` shows only files in the
Scope Manifest.

###### Scope Manifest for W-OBS-2

**Allowed files/directories:**

- `hooks/check-implementer.sh` (modify: add agent_duration_s emission)
- `hooks/check-tester.sh` (modify: add agent_duration_s + eval_verdict emission)
- `hooks/check-guardian.sh` (modify: add agent_duration_s + commit_outcome)
- `hooks/check-planner.sh` (modify: add agent_duration_s emission)
- `hooks/test-runner.sh` (modify: add test_result emission)
- `hooks/pre-write.sh` (modify: add guard_denial batch emission on deny path)
- `hooks/pre-bash.sh` (modify: add guard_denial batch emission on deny path)
- `hooks/track.sh` (modify: add files_changed async emission via `& disown`)
- `hooks/session-end.sh` (modify: add session_summary emission)
- `hooks/log.sh` (modify: add hook_failure emission in error handler)
- `hooks/post-task.sh` (DEC-OBS-011: review metric reader retired; do not
  reintroduce stale event reads)
- `tests/scenarios/test-obs-emission.sh` (new: verify metrics appear after
  representative hook sequence, including review metrics)

**Required files/directories:** All 12 of the above.

Note: `hooks/subagent-start.sh` is NOT modified in this wave. It produces
context (additionalContext JSON), not metrics. It appears in the system's
data flow but is not an emission source. Similarly, `hooks/auto-review.sh`
is not an emission source -- its classification data flows through
`pre-bash.sh`.

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
- `hooks/subagent-start.sh` (not an emission source)
- `hooks/auto-review.sh` (not an emission source)
- `plugins/` (review metrics are emitted from post-task.sh, not from the
  stop-review-gate plugin)

**Expected state authorities touched:**

- MODIFIED: `obs_metrics` table (new rows written by hooks, including review
  metrics from post-task.sh)
- MODIFIED: 11 hook files (small emission additions)
- READ-ONLY: `events` table (post-task.sh reads codex_stop_review events to
  emit review metrics -- does not write new event types)
- UNCHANGED: all existing tables (except obs_metrics writes), all hook
  deny/allow decisions, all hook output formats, settings.json

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
    fork's 540-line analyze.sh. **CRITICAL: all joins to non-obs tables MUST
    use LEFT JOIN.** obs_metrics is the primary data source; other tables
    (traces, completion_records, evaluation_state, agent_markers) are
    enrichment sources that may have zero rows. The analysis MUST be
    null-tolerant: when enrichment tables are empty, cross_analysis returns
    the obs_metrics-only view with NULL enrichment fields, not an empty
    result. This is the ground truth: obs_metrics is populated by W-OBS-2
    hooks; other tables populate naturally as the system runs and must not
    be required for a useful analysis.
  - `cross_analysis` also correlates `review_verdict` metrics with
    `eval_verdict` metrics to measure stop-gate predictive accuracy: when
    the review gate says CONTINUE but the evaluator says `ready_for_guardian`,
    the review gate was wrong (false negative). When the review gate says
    PASS but the evaluator finds blockers, the review gate was too lenient.
  - `pattern_detection(conn, window_hours)` -- identifies recurring patterns:
    - Same policy denied 3+ times in a window (repeated denial)
    - Agent duration trending upward (slow agent)
    - Test pass rate declining (test regression)
    - Multiple needs_changes verdicts for the same workflow (evaluation churn)
    - Stale markers persisting across sessions (stale marker)
    - Review infra failure rate >20% in window (review quality) -- triggers
      suggestion about provider availability or prompt template
  - `generate_report(conn, window_hours)` -- produces a structured dict that
    the SKILL.md can present: metrics summary, trend analysis, detected
    patterns, active suggestions, convergence results, review gate health.
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
    Results, Review Gate Health (infra failure rate, predictive accuracy vs
    evaluator verdicts, provider breakdown).

Note: The SKILL.md can be drafted during W-OBS-2 and finalized in W-OBS-3
once analysis functions are available. The draft should define the skill
trigger, flow outline, and presentation structure using placeholder analysis
calls. Finalization adds the actual `cc-policy obs summary` integration.
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
   `evaluation_trends`, `convergence_status`, `review_gate_health`
3. `cross_analysis` with obs_metrics populated but traces, completion_records,
   evaluation_state, and agent_markers ALL EMPTY (0 rows) returns a valid
   dict with obs_metrics-only data and NULL/empty enrichment fields -- NOT
   an empty result. This is the null-tolerance test: the system must produce
   useful output from obs_metrics alone.
4. `pattern_detection` identifies injected repeated_denial pattern
   (same policy denied 3+ times)
5. `pattern_detection` identifies injected slow_agent pattern
   (duration trend increasing)
6. `pattern_detection` identifies injected review_quality pattern
   (review_infra_failure rate >20% in window)
7. `generate_report` includes `metrics_summary`, `trends`, `patterns`,
   `suggestions`, `convergence`, `review_gate_health`
8. `cc-policy obs summary --window-hours 24` returns valid JSON with report
   structure
9. SKILL.md exists at `skills/observatory/SKILL.md` with valid trigger and
   flow sections, including a "Review Gate Health" section

**Required real-path checks:**

10. With real data from W-OBS-2 hooks, `cc-policy obs summary` returns a
    non-empty report
11. With ONLY obs_metrics populated (no traces, no completion_records),
    `cc-policy obs summary` still returns a valid report (not empty or error)
12. `cc-policy obs suggest repeated_denial "Policy X denied too often"
    --target-metric guard_denial` creates a suggestion; `cc-policy obs accept 1
    --measure-after 86400` accepts it; `cc-policy obs converge` checks it

**Required authority invariants:**

- Analysis queries are read-only against existing tables (traces,
  completion_records, evaluation_state, agent_markers, events)
- All joins to non-obs tables use LEFT JOIN (obs_metrics is primary; other
  tables are enrichment)
- Only obs_suggestions and obs_runs are written by analysis functions
- No analysis function modifies obs_metrics (that is the hook emission domain)

**Required integration points:**

- `observatory.py` imports from `runtime.core.traces`, `runtime.core.events`,
  `runtime.core.completions`, `runtime.core.test_state` for query functions
  only (read-only LEFT JOINs)
- SKILL.md references `cc-policy obs` CLI commands
- Review gate health correlates review_verdict with eval_verdict metrics

**Forbidden shortcuts:**

- Do not encode pattern-matching heuristics that should be LLM judgment into
  hard-coded rules. Pattern detection provides structured data; the LLM
  skill interprets significance.
- Do not write a bash pipeline. All analysis is Python/SQL.
- Do not create a separate analysis database or JSONL output.
- Do not modify hook files (emission was W-OBS-2).
- Do not use INNER JOIN on non-obs tables. All cross-table joins MUST be
  LEFT JOIN from obs_metrics. Empty prerequisite tables must not produce
  empty analysis results.
- Do not require non-empty prerequisite tables (traces, completion_records,
  evaluation_state, agent_markers) for analysis to succeed. These tables
  populate naturally as the system runs; analysis degrades gracefully when
  they are empty.
- Do not add a backfill step for prerequisite tables.

**Ready-for-guardian definition:**

All 12 checks pass. Authority invariants hold. No forbidden shortcuts taken.
Null-tolerance verified (check 3 and 11). `git diff --stat` shows only files
in the Scope Manifest.

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
| Observatory time series | **NONE** | `obs_metrics` table (single authority, indexed `role` column) | W-OBS-1 |
| Suggestion lifecycle | **NONE** | `obs_suggestions` table (single authority, with signal_id) | W-OBS-1 |
| Analysis run history | **NONE** | `obs_runs` table (single authority) | W-OBS-1 |
| Observatory metric emission | **NONE** | Hooks emit via `rt_obs_metric()` / `rt_obs_metric_batch()` | W-OBS-2 |
| Review gate metrics | Retired from `post-task.sh` | Stop-hook `codex_stop_review` events + statusline visibility; future Stop-owned metric emitter if needed | DEC-OBS-011 |
| Cross-table analysis | **NONE** (basic sidecar health check only) | `observatory.py` SQL-based analysis (LEFT JOIN) | W-OBS-3 |
| LLM synthesis | **NONE** | `skills/observatory/SKILL.md` skill | W-OBS-3 |
| Observatory sidecar | Basic health counts (`observe.py`) | Full analysis report via domain module | W-OBS-4 |
| Existing traces tables | `traces` + `trace_manifest` (DEC-TRACE-001) | READ-ONLY by analysis (LEFT JOIN) | W-OBS-3 |
| Existing events table | `events` (DEC-RT-001) | Stop-review hook writes `codex_stop_review`; statusline and analysis read it | DEC-OBS-011, W-OBS-3 |
| Existing completion_records | `completion_records` | READ-ONLY by analysis (LEFT JOIN, may be empty) | W-OBS-3 |
| Existing evaluation_state | `evaluation_state` | READ-ONLY by analysis (LEFT JOIN, may be empty) | W-OBS-3 |
| Existing agent_markers | `agent_markers` | READ-ONLY by analysis (LEFT JOIN) | W-OBS-3 |
| Existing test_state | `test_state` | READ-ONLY by analysis (LEFT JOIN) | W-OBS-3 |
| Existing proof_state | `proof_state` | READ-ONLY by existing `observe.py` sidecar (legacy) | W-OBS-4 |
| Existing worktrees | `worktrees` | READ-ONLY by existing `observe.py` sidecar | W-OBS-4 |
| Existing dispatch_queue | `dispatch_queue` | READ-ONLY by existing `observe.py` sidecar | W-OBS-4 |
| Session change tracking | `.session-changes-$SESSION_ID` flat file (written by track.sh) | READ-ONLY by W-OBS-2 `files_changed` metric emission (reads count from this file) | W-OBS-2 |

#### Known Risks for INIT-OBS

1. **Metric volume growth.** Every hook invocation emits 1-3 metrics. Over
   weeks, `obs_metrics` could grow large. Mitigation: add a TTL-based cleanup
   function to observatory.py that deletes rows older than N days
   (configurable, default 30). The cleanup runs during `check_convergence()`
   calls. Index on `(metric_name, created_at)` keeps queries fast.

2. **Emission latency impact on hooks.** Each `rt_obs_metric` call invokes
   `cc-policy obs emit` as a subprocess (~42ms median, measured in INIT-002).
   `|| true` and `>/dev/null 2>&1` suppress errors but do NOT make calls
   non-blocking -- the hook still waits for the subprocess to complete.
   For hot-path hooks (track.sh fires on every file write), this is
   unacceptable. Mitigation (designed from the start, not deferred):
   - Hot-path hooks use `& disown` for single-metric async emission, or the
     batch pattern: accumulate metrics in `_OBS_BATCH` shell array during
     hook execution, flush once at hook exit via `rt_obs_metric_batch`
     (single `cc-policy obs emit-batch` subprocess). (DEC-OBS-007)
   - Non-hot-path hooks (check-*.sh, session-end.sh) use synchronous
     `rt_obs_metric ... || true` since they are not latency-sensitive.
   - The `emit_batch()` Python function inserts all metrics in a single
     transaction, amortizing both subprocess and SQLite overhead.

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

7. **Schema evolution: no migration strategy for obs tables.** The obs tables
   have no `user_version` or migration mechanism. If the schema needs to
   change after initial deployment (e.g., adding a column), there is no
   automated path. Mitigation: W-OBS-1 must set `PRAGMA user_version` for
   the obs tables (or use a version row in a metadata table). Future schema
   changes check the version and apply ALTER TABLE as needed. This is low
   urgency for v1 (tables are new and can be rebuilt) but must be addressed
   before v2 schema changes.

8. **Concurrent write loss from missing busy_timeout.** WAL mode is enabled
   on state.db, but if no `busy_timeout` is set, simultaneous hook emissions
   (e.g., two hooks firing concurrently in different subagents) can fail with
   SQLITE_BUSY. The `|| true` suppression would silently discard the metric.
   Mitigation: `emit_metric()` and `emit_batch()` must set
   `conn.execute("PRAGMA busy_timeout = 3000")` (3 seconds) before writing.
   This is consistent with the existing runtime convention. W-OBS-1
   implementer should verify that the connection passed to observatory
   functions already has busy_timeout set (as it should via the standard
   runtime connection setup), and add it explicitly if not.

9. **Bootstrap skew: cc_policy() targets installed runtime, not repo runtime.**
   The `cc_policy()` shell function targets `$HOME/.claude/runtime/cli.py`.
   If the installed runtime is older than the repo runtime (e.g., after a
   `git pull` but before re-installing), `cc-policy obs emit` calls will
   fail silently because the older cli.py does not have the `obs` domain.
   Mitigation: emission uses `|| true` / `& disown`, so failures are
   non-fatal. The implementer should document that `cc-policy obs emit` is
   only available after the W-OBS-1 code is installed (i.e., the runtime is
   updated). This is the same bootstrap issue that affects all `cc-policy`
   commands and is not unique to the observatory.

10. **Stop-gate plugin dependency.** The stop-review-gate is a plugin
    (openai-codex marketplace), not first-party code. Plugin updates could
    change the event format (field names, JSON structure) of
    `codex_stop_review` events. Mitigation: review metric emission in
    `post-task.sh` reads from the `events` table, not from the plugin script
    directly. Event schema changes are detectable by checking for expected
    fields before emission (if `verdict` field is missing, skip emission with
    a warning, do not crash). The plugin's event format is effectively a
    contract; breaking changes should be caught in review.


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

### INIT-GUARD-WT: Guardian as Sole Worktree Lifecycle Authority

- **Status:** planned (revised 2026-04-06 R3: planner lease decoupled from
  guardian lease issuance, enriched AUTO_DISPATCH orchestrator contract,
  provision order reversed (filesystem before DB).
  R2: HIGH-1 suggestion-text carrier, HIGH-2 fail-closed guardian lease,
  race-safety TOCTOU/partial-failure fix.
  R1: HIGH-1 cli.py carrier, HIGH-2 guardian lease, MEDIUM-3 rework path,
  MEDIUM-4 guardian_mode, race-safety idempotency)
- **Goal:** Make Guardian the sole authority for worktree creation, assignment,
  and cleanup. No other agent may create or remove worktrees. This eliminates
  the current split authority where implementers self-provision worktrees
  (agents/implementer.md line 43), subagent-start.sh contradicts with `../`
  paths (line 118), and Guardian already handles merge and cleanup. Unifying
  worktree lifecycle under Guardian makes provisioning auditable, ensures
  consistent `.worktrees/` placement, and enables the lease system to bind
  workflow identity to worktree path at creation time rather than after the
  fact.
- **Current truth:** Implementers create their own worktrees on first action.
  subagent-start.sh line 117-118 injects a "CRITICAL FIRST ACTION" message
  telling implementers to run `git worktree add ../...`, which contradicts the
  `.worktrees/` convention in implementer.md line 43. Guardian already handles
  merge and cleanup (guardian.md lines 53-54). The `worktrees.py` registry
  module exists but registration is ad-hoc. The dispatch_engine routing table
  maps `("planner", _) -> "implementer"` directly, bypassing Guardian for
  worktree provisioning. The lease system (leases.py) already supports issuing
  leases with worktree_path and workflow_id, but requires the path to exist
  before issuance. `write_branch.py` line 113 already says "invoke the
  Guardian agent to create an isolated worktree" in its denial message.
- **Scope:** Routing table change, Guardian mode signaling, worktree
  provisioning runtime function, WORKTREE_PATH end-to-end carrier through
  cli.py, Guardian provisioning lease, rework-path worktree resolution,
  structured guardian_mode dispatch field, provision-if-absent idempotency,
  workflow binding creation at provision time, prompt updates (guardian.md,
  implementer.md), subagent-start.sh cleanup, dispatch_engine planner routing,
  CLAUDE.md dispatch documentation update.
- **Exit:** Planner completion routes through Guardian for worktree
  provisioning. Guardian receives a structured dispatch with `guardian_mode`,
  `workflow_id`, and `feature_name`. Guardian creates `.worktrees/feature-<name>`,
  registers it, issues an implementer lease, creates a workflow binding, and
  emits `LANDING_RESULT: provisioned`. Its own completion record is anchored to
  a Guardian lease at PROJECT_ROOT. The dispatch result propagates
  `worktree_path` end-to-end through dispatch_engine -> cli.py ->
  hookSpecificOutput -> orchestrator. Implementer receives the path in
  dispatch context and never creates worktrees. On rework cycles
  (tester -> needs_changes -> implementer), dispatch_engine reads
  worktree_path from workflow_bindings. Tester and guardian reuse the same
  worktree. No agent other than Guardian runs `git worktree add` or
  `git worktree remove`. Concurrent provision attempts for the same workflow
  are idempotent. All existing tests continue to pass.
- **Dependencies:** INIT-PE (policy engine must be live), INIT-CONV (lease
  identity must be converged)

#### Design Decisions

- `DEC-GUARD-WT-001` **Guardian mode signaling via completion verdict, not
  routing table branching.** The routing table in completions.py maps
  `(role, verdict) -> next_role`. Adding `planner -> guardian` would require
  Guardian to know it is in "provision mode" vs "merge mode." Rather than
  encoding mode into the routing table (which would require a new verdict
  enum or a separate routing key), Guardian determines its mode from the
  **structured dispatch field** `guardian_mode` (DEC-GUARD-WT-007). The
  routing change is: `("planner", _) -> "guardian"` replaces the current
  hard-coded `result["next_role"] = "implementer"` in dispatch_engine.py
  line 151. Guardian's completion record uses `LANDING_RESULT: provisioned`
  (new verdict) with `OPERATION_CLASS: routine_local`, and the routing
  table maps `("guardian", "provisioned") -> "implementer"`.

- `DEC-GUARD-WT-002` **Worktree provisioning is a runtime function, not a
  dispatch_engine side effect (REVISED R3).** dispatch_engine must remain
  a pure routing decision engine (no git side effects, no lease writes).
  The `cc-policy worktree provision` CLI subcommand handles the entire
  provision sequence atomically: filesystem creation (`git worktree add`
  via subprocess), DB registration, Guardian lease at PROJECT_ROOT
  (DEC-GUARD-WT-006 R3), implementer lease at worktree_path, and workflow
  binding. The Guardian calls this single CLI command — it does not need
  to run `git worktree add` separately. See DEC-GUARD-WT-008 for the
  filesystem-first order and partial-failure cleanup pattern.

- `DEC-GUARD-WT-003` **Worktree path injection via dispatch result
  enrichment (REVISED).** When Guardian completes provisioning, its
  completion record includes `WORKTREE_PATH` in the payload. The full
  carrier chain is:
  1. Guardian emits `WORKTREE_PATH: <path>` trailer in response text.
  2. check-guardian.sh parses `WORKTREE_PATH` (new, alongside existing
     `LANDING_RESULT` and `OPERATION_CLASS` parsing) and includes it in
     the completion record payload.
  3. dispatch_engine `_route_from_completion()` extracts `WORKTREE_PATH`
     from `payload_json` when verdict is `provisioned` and sets
     `result["worktree_path"]`.
  4. cli.py `_handle_dispatch()` serializes `worktree_path` in the
     result dict (same pattern as `auto_dispatch`).
  5. dispatch_engine suggestion builder encodes `worktree_path` in the
     AUTO_DISPATCH line: `AUTO_DISPATCH: implementer
     (worktree_path=<path>, workflow_id=<W>)`. This is the critical
     last mile: post-task.sh strips the cli.py result to
     `hookSpecificOutput` only, so the suggestion text (which becomes
     `additionalContext`) is the ONLY carrier to the orchestrator.

  **Changes from original plan:** cli.py must add `worktree_path` to the
  serialized output (was forbidden in original W-GWT-1 scope).
  check-guardian.sh must parse `WORKTREE_PATH` (was not in any scope).
  **R2 addition:** suggestion builder must encode worktree_path in
  AUTO_DISPATCH line (sole carrier to orchestrator via additionalContext).

- `DEC-GUARD-WT-004` **Worktree reuse on rework cycles (REVISED).** When
  `("tester", "needs_changes") -> "implementer"`, the worktree already
  exists. The routing does not go through Guardian again. dispatch_engine
  reads the existing worktree_path from `workflow_bindings` table via
  `workflows.get_binding(workflow_id)` and includes it in the result so
  the orchestrator can pass it to the implementer's dispatch context.

  **Changes from original plan:** Workflow binding creation moves from
  subagent-start.sh (line 135) to Guardian provisioning (W-GWT-2) via the
  `cc-policy worktree provision` CLI. This ensures the binding exists
  before dispatch_engine needs it for rework routing. subagent-start.sh
  retains its binding call as an idempotent update (safe to call twice, the
  INSERT OR REPLACE handles it), but Guardian provisioning is the primary
  writer.

- `DEC-GUARD-WT-005` **`isolation: "worktree"` on Agent tool calls is
  forbidden.** The Claude Code Agent tool parameter `isolation: "worktree"`
  creates worktrees in /tmp, bypassing all hooks and registry. This must
  never be used. No runtime enforcement is possible since the harness
  controls isolation before hooks fire. CLAUDE.md prompt constraint is
  sufficient.

- `DEC-GUARD-WT-006` **Guardian provisioning lease (NEW, REVISED R2:
  fail-closed, REVISED R3: moved to W-GWT-2 provision CLI).**
  Guardian needs its own lease to anchor its completion record submission
  in check-guardian.sh. The problem: check-guardian.sh (line 68-79) uses
  `lease_context(PROJECT_ROOT)` to find the active lease for completion
  record submission. After provisioning, the only lease Guardian issued
  is an implementer lease at the worktree_path, not at PROJECT_ROOT.
  Guardian has no lease to submit its completion against.

  **R3 revision — planner lease is a claim, not an issue.** The R2
  design assumed the planner always holds a lease at PROJECT_ROOT
  (issued by the orchestrator, claimed by subagent-start.sh line 82).
  This is wrong: subagent-start.sh CLAIMS an existing lease — it does
  not issue one. If no lease was issued before the planner was dispatched
  (which is the case in existing tests: test-auto-dispatch-signal.sh L86,
  test-full-lifecycle.sh L7), the planner has no lease. Making
  dispatch_engine fail-closed on missing workflow_id at planner stop
  would break all planner stops that lack a pre-issued lease.

  **Solution (R3):** Guardian lease issuance moves from dispatch_engine
  (W-GWT-1) to the `cc-policy worktree provision` CLI (W-GWT-2). The
  provision CLI already runs inside the Guardian agent and already
  issues the implementer lease. It now also issues the Guardian lease
  at PROJECT_ROOT as part of the same provision sequence. The sequence
  becomes: (1) git worktree add (filesystem), (2) worktrees.register(),
  (3) leases.issue() for Guardian at PROJECT_ROOT, (4) leases.issue()
  for implementer at worktree_path, (5) workflows.bind_workflow(). The
  Guardian lease is available to check-guardian.sh immediately after
  the provision CLI returns.

  **workflow_id derivation at planner stop:** dispatch_engine does NOT
  require workflow_id at planner stop. It is best-effort: if an active
  lease exists at PROJECT_ROOT, use its workflow_id. Otherwise, derive
  from branch via `policy_utils.current_workflow_id()` (same fallback
  dispatch_engine already uses for stop-assessment). If neither yields
  a workflow_id, the suggestion text omits it — the orchestrator
  already has the workflow_id from the plan and includes it in the
  Guardian dispatch context. The provision CLI receives workflow_id as
  a CLI argument, not from the planner's lease chain.

  **dispatch_engine purity restored:** The R2 "controlled exception"
  that allowed dispatch_engine to issue leases is no longer needed.
  dispatch_engine returns to being a pure routing engine that reads
  but never writes leases. Lease issuance happens in the provision
  CLI (runtime side effect in the Guardian agent, not in dispatch_engine).

  check-guardian.sh finds Guardian's lease via the existing
  `lease_context(PROJECT_ROOT)` path. After Guardian stops,
  dispatch_engine releases the Guardian lease in
  `_route_from_completion()` as it does for all roles.

- `DEC-GUARD-WT-007` **Structured guardian_mode dispatch field (NEW).**
  When dispatch_engine routes `planner -> guardian`, the suggestion text
  includes a structured prefix:
  `AUTO_DISPATCH: guardian (mode=provision, workflow_id=<W>,
  feature_name=<F>)`
  where `feature_name` is extracted from the workflow_id (which follows
  the pattern `W-<INITIATIVE>-<N>` or from a planner completion record
  field if available). This structured prefix is parseable by the
  orchestrator and eliminates the need for Guardian to infer its mode
  from ambient context.

  The `guardian_mode` field is also added to the dispatch result dict
  so cli.py can serialize it. Values: `"provision"` (after planner) or
  `"merge"` (after tester ready_for_guardian). The merge path does not
  need feature_name since the worktree already exists.

  **Documentation update required:** CLAUDE.md dispatch rules and
  agents/guardian.md must describe the
  planner -> guardian -> implementer chain (not planner -> implementer
  directly).

- `DEC-GUARD-WT-008` **Provision-if-absent idempotency (NEW, REVISED R2:
  no TOCTOU, REVISED R3: filesystem-first order).** The `cc-policy
  worktree provision` CLI command creates the filesystem worktree BEFORE
  any DB writes. No `list_active()` pre-check -- that would create a
  TOCTOU window where two concurrent provisions both see "not found" and
  race.

  **Already-exists detection (R3):** Check the filesystem BEFORE
  `git worktree add`: does `.worktrees/feature-<name>` exist on disk?
  If yes, it is a re-provision — skip `git worktree add`, just ensure
  DB state is correct (register + leases + binding). This is simpler
  and more reliable than parsing SQLite side effects from register().

  The provision sequence is (R3):
  1. Filesystem check: does `<project_root>/.worktrees/feature-<name>`
     exist? If yes, skip step 2 (re-provision path).
  2. `git worktree add .worktrees/feature-<name> -b feature/<name>` --
     filesystem first. If it fails, nothing to clean up.
  3. `worktrees.register(conn, path, branch, ticket=workflow_id)` --
     ON CONFLICT updates (idempotent). DB records filesystem reality.
  4. `leases.issue(conn, role="guardian", worktree_path=project_root,
     workflow_id=workflow_id)` -- Guardian lease at PROJECT_ROOT
     (DEC-GUARD-WT-006 R3: moved here from dispatch_engine).
  5. `leases.issue(conn, role="implementer", worktree_path=path,
     workflow_id=workflow_id)` -- implementer lease at worktree_path.
  6. `workflows.bind_workflow(conn, ...)` -- workflow binding.

  **Partial-failure cleanup (R3):** If steps 3-6 fail after step 2
  succeeded, cleanup: `git worktree remove .worktrees/feature-<name>`.
  This is simpler than the R2 approach (which cleaned up DB state after
  register succeeded) because there is no stale DB state to clean —
  the DB was never written. If step 3 succeeds but steps 4-6 fail,
  the provision CLI calls `worktrees.remove(conn, path)` to roll back
  the registration AND `git worktree remove` to clean the filesystem.
  The cleanup itself is wrapped in try/except so a cleanup failure
  does not mask the original error.

#### Work Items

##### W-GWT-1: Routing Table, Dispatch Engine, and WORKTREE_PATH Carrier

- **Weight:** L (upgraded from M: now includes cli.py serialization,
  guardian_mode field, rework-path enrichment, and rework-path suggestion
  encoding. R3: guardian lease issuance moved to W-GWT-2)
- **Gate:** review
- **Deps:** none
- **Integration:** `runtime/core/completions.py` (routing table),
  `runtime/core/dispatch_engine.py` (planner routing block, worktree_path
  enrichment, rework-path enrichment, guardian_mode field, rework suggestion
  encoding — NO guardian lease issuance, moved to W-GWT-2 per R3),
  `runtime/cli.py` (worktree_path + guardian_mode serialization),
  `tests/runtime/test_completions.py`, `tests/runtime/test_dispatch_engine.py`

**Changes:**

1. **completions.py** `determine_next_role()`: Add routing entries:
   - `("guardian", "provisioned") -> "implementer"`
   - Existing `("guardian", "committed") -> None` and
     `("guardian", "merged") -> None` unchanged.
   - `ROLE_SCHEMAS["guardian"]["valid_verdicts"]`: Add `"provisioned"` to
     the frozenset.

2. **dispatch_engine.py** `process_agent_stop()`: Change the planner
   routing block (line 151) from:
   ```python
   if normalised == "planner":
       result["next_role"] = "implementer"
   ```
   to:
   ```python
   if normalised == "planner":
       result["next_role"] = "guardian"
       result["guardian_mode"] = "provision"
       # DEC-GUARD-WT-006 R3: No guardian lease issued here.
       # The provision CLI (W-GWT-2) issues the guardian lease
       # at PROJECT_ROOT as part of the provision sequence.
       # workflow_id is best-effort: if the planner had a lease,
       # _resolve_lease_context already found it. If not, try
       # branch-derived fallback. Either way, workflow_id flows
       # to the orchestrator via suggestion text, and the
       # orchestrator passes it to the Guardian dispatch context.
       if not workflow_id:
           try:
               from runtime.core import policy_utils
               workflow_id = policy_utils.current_workflow_id(
                   project_root)
               result["workflow_id"] = workflow_id
           except Exception:
               pass  # Orchestrator provides workflow_id to Guardian
   ```

3. **dispatch_engine.py** guardian routing block: After
   `_route_from_completion()` returns for guardian, when verdict is
   `provisioned` and `next_role == "implementer"`:
   - Extract `WORKTREE_PATH` from the completion record's `payload_json`
   - Set `result["worktree_path"] = extracted_path`
   - Set `result["guardian_mode"] = "provision"` (for the suggestion)

4. **dispatch_engine.py** tester routing block: After
   `_route_from_completion()` returns for tester, when verdict is
   `needs_changes` and `next_role == "implementer"`:
   - Import `runtime.core.workflows` and call
     `workflows.get_binding(conn, workflow_id)`
   - If binding found, set `result["worktree_path"] =
     binding["worktree_path"]`
   - This is the rework-path worktree resolution (DEC-GUARD-WT-004)

5. **dispatch_engine.py** suggestion builder: The enriched AUTO_DISPATCH
   format is `AUTO_DISPATCH: <role> (key=value, key=value)`. The
   parenthetical metadata is contextual information the orchestrator
   passes to the next agent's dispatch context. The orchestrator reads
   this as text — no programmatic parser needed. Three cases:

   a. **Planner -> guardian (provision):** When
      `result["guardian_mode"] == "provision"`, emit:
      `AUTO_DISPATCH: guardian (mode=provision, workflow_id=<W>,
      feature_name=<F>)`

   b. **Guardian (provisioned) -> implementer:** When the previous role
      was guardian with provisioned verdict (i.e., `next_role ==
      "implementer"` and `result.get("worktree_path")`), emit:
      `AUTO_DISPATCH: implementer (worktree_path=<path>,
      workflow_id=<W>)`

   c. **Tester (needs_changes) -> implementer (rework):** When
      `next_role == "implementer"` and `result.get("worktree_path")`
      was enriched from workflow_bindings (change 4), emit:
      `AUTO_DISPATCH: implementer (worktree_path=<path>,
      workflow_id=<W>)`
      This ensures the rework path also encodes worktree_path in the
      suggestion text, not just the guardian-provisioned path.

   The suggestion text is how metadata reaches the orchestrator:
   post-task.sh strips the cli.py result to `hookSpecificOutput` only —
   no other field propagates. The `AUTO_DISPATCH: <role> (key=value)`
   format extends the existing pattern without requiring post-task.sh
   changes.

6. **cli.py** `_handle_dispatch()` process-stop output (line 312-331):
   Add `worktree_path` and `guardian_mode` to the serialized result dict:
   ```python
   return _ok({
       "next_role": result["next_role"],
       "workflow_id": result["workflow_id"],
       "auto_dispatch": result.get("auto_dispatch", False),
       "worktree_path": result.get("worktree_path", ""),
       "guardian_mode": result.get("guardian_mode", ""),
       "codex_blocked": result.get("codex_blocked", False),
       "codex_reason": result.get("codex_reason", ""),
       "error": result["error"],
       "hookSpecificOutput": hook_output,
   })
   ```

7. **check-guardian.sh** (lines 55-66): Add `WORKTREE_PATH` parsing
   alongside existing `LANDING_RESULT` and `OPERATION_CLASS`:
   ```bash
   _GD_WORKTREE_PATH=""
   if [[ -n "$RESPONSE_TEXT" ]]; then
       _GD_WORKTREE_PATH=$(printf '%s' "$RESPONSE_TEXT" \
           | grep -oE '^WORKTREE_PATH:[[:space:]]*/[^ ]+' \
           | head -1 \
           | sed 's/WORKTREE_PATH:[[:space:]]*//' || true)
   fi
   ```
   Include `WORKTREE_PATH` in the completion record payload:
   ```bash
   _GD_PAYLOAD=$(jq -n \
       --arg lr "${_GD_LANDING_RESULT:-}" \
       --arg oc "${_GD_OP_CLASS:-}" \
       --arg wp "${_GD_WORKTREE_PATH:-}" \
       '{LANDING_RESULT:$lr, OPERATION_CLASS:$oc, WORKTREE_PATH:$wp}')
   ```

8. **Tests:** Update existing tests that assert planner -> implementer
   routing. Add tests for:
   - Guardian provisioned -> implementer routing
   - worktree_path enrichment in dispatch result (from completion record)
   - worktree_path enrichment in rework path (from workflow_bindings)
   - Guardian lease issuance on planner -> guardian transition
   - guardian_mode field in dispatch result and suggestion text
   - cli.py serializes worktree_path and guardian_mode
   - check-guardian.sh parses WORKTREE_PATH and includes it in payload

###### Evaluation Contract for W-GWT-1

**Required tests:**
- `test_planner_routes_to_guardian`: planner stop produces
  `next_role="guardian"` (replaces existing planner->implementer test)
- `test_planner_no_lease_still_routes_to_guardian`: planner stop with
  no active lease at project_root still routes to guardian (not
  PROCESS ERROR). workflow_id is best-effort — may be empty.
  (DEC-GUARD-WT-006 R3: planner lease is not required)
- `test_planner_with_lease_resolves_workflow_id`: planner stop with an
  active lease at project_root resolves workflow_id from that lease and
  includes it in the suggestion text
- `test_planner_no_lease_uses_branch_fallback`: planner stop with no
  active lease falls back to branch-derived workflow_id via
  policy_utils.current_workflow_id()
- `test_planner_sets_guardian_mode_provision`: planner stop sets
  `guardian_mode="provision"` in dispatch result
- `test_guardian_provisioned_routes_to_implementer`: guardian with
  `LANDING_RESULT=provisioned` routes to implementer
- `test_guardian_provisioned_enriches_worktree_path`: dispatch result
  includes `worktree_path` from completion record payload when verdict
  is provisioned
- `test_guardian_merge_routing_unchanged`: `committed` and `merged`
  still route to None
- `test_guardian_denied_routing_unchanged`: `denied` still routes to
  implementer
- `test_tester_needs_changes_enriches_worktree_path`: tester
  needs_changes result includes worktree_path from workflow_bindings
  when binding exists
- `test_tester_needs_changes_no_binding_no_crash`: tester needs_changes
  without a workflow_binding returns result without worktree_path (no
  error)
- `test_tester_needs_changes_suggestion_encodes_worktree_path`: when
  tester needs_changes has a workflow_binding with worktree_path, the
  suggestion text contains
  `AUTO_DISPATCH: implementer (worktree_path=<path>, workflow_id=<W>)`
  — rework path also carries worktree_path to orchestrator (Gap 2 fix)
- `test_cli_serializes_worktree_path_and_guardian_mode`: cli.py
  process-stop output includes worktree_path and guardian_mode keys
- `test_check_guardian_parses_worktree_path`: check-guardian.sh
  extracts WORKTREE_PATH from response text and includes it in
  completion payload
- `test_guardian_provisioned_suggestion_encodes_worktree_path`: when
  guardian completes with provisioned verdict and worktree_path is set,
  the suggestion text contains
  `AUTO_DISPATCH: implementer (worktree_path=<path>, workflow_id=<W>)`
  — this is the only mechanism by which worktree_path reaches the
  orchestrator (HIGH-1 carrier fix)
- All existing dispatch_engine and completions tests pass without
  modification (except the planner->implementer assertion which must
  change to planner->guardian)

**Required real-path checks:**
- `process_agent_stop(conn, "planner", project_root)` returns
  `{"next_role": "guardian", "auto_dispatch": True,
  "guardian_mode": "provision"}` with NO guardian lease issued (lease
  issuance happens in W-GWT-2 provision CLI, not here)
- Round-trip: planner stop -> guardian provision completion (with
  WORKTREE_PATH in payload) -> process_agent_stop(conn, "guardian", ...)
  returns `{"next_role": "implementer", "worktree_path": "<path>"}` AND
  the suggestion field contains
  `AUTO_DISPATCH: implementer (worktree_path=<path>, workflow_id=<W>)`
- Rework round-trip: create workflow_binding -> tester needs_changes
  completion -> process_agent_stop(conn, "tester", ...) returns
  `{"next_role": "implementer", "worktree_path": "<binding_path>"}`

**Required authority invariants:**
- completions.py `determine_next_role()` remains the sole routing table
  authority (DEC-COMPLETION-001)
- dispatch_engine remains pure (no git side effects, no worktree creation,
  no lease writes). DEC-GUARD-WT-006 R3 restores full purity — the R2
  lease-write exception is eliminated.
- Lease release timing unchanged (DEC-ROUTING-002)

**Required integration points:**
- post-task.sh thin adapter still works (dispatches to process-stop).
  post-task.sh emits hookSpecificOutput which now may contain
  worktree_path and guardian_mode in the additionalContext suggestion.
  The suggestion text is the sole carrier of worktree_path to the
  orchestrator — post-task.sh strips the cli.py result to
  hookSpecificOutput only, so any field not encoded in the suggestion
  is lost. The `AUTO_DISPATCH: <role> (key=value, ...)` format is
  the established pattern.
- Auto-dispatch flag is True for planner->guardian and
  guardian(provisioned)->implementer transitions
- check-guardian.sh WORKTREE_PATH parsing is compatible with existing
  LANDING_RESULT and OPERATION_CLASS parsing (same grep pattern style)
- No guardian lease is issued at planner stop (DEC-GUARD-WT-006 R3).
  The planner may or may not have a lease at PROJECT_ROOT (it claims
  one if available but does not issue). If a planner lease exists, it
  is released by dispatch_engine's normal lease release path (or left
  for the provision CLI to supersede). The guardian lease is issued by
  the provision CLI (W-GWT-2) during the guardian agent's execution.

**Forbidden shortcuts:**
- Do not split the routing table into multiple functions
- Do not add git side effects to dispatch_engine
- Do not hardcode worktree_path in dispatch_engine -- it must come from
  completion records (for provisioning) or workflow_bindings (for rework)

**Ready-for-guardian definition:**
All new and existing routing tests pass. `process_agent_stop` produces
correct next_role, auto_dispatch, worktree_path, and guardian_mode for
all planner, guardian, and tester scenarios. Planner stop with no active
lease still routes to guardian (best-effort workflow_id, not fail-closed).
Planner stop with active lease resolves workflow_id from lease. Guardian
provisioned suggestion text encodes worktree_path in AUTO_DISPATCH line
(sole carrier to orchestrator). Tester needs_changes suggestion text also
encodes worktree_path from workflow_bindings. check-guardian.sh parses
WORKTREE_PATH. cli.py serializes all new fields. dispatch_engine issues
no leases (pure routing). No existing test regressions.

###### Scope Manifest for W-GWT-1

**Allowed files/directories:**
- `runtime/core/completions.py` (modify routing table and valid_verdicts)
- `runtime/core/dispatch_engine.py` (modify planner block, add guardian
  lease issuance, add worktree_path enrichment for both provisioning and
  rework paths, add guardian_mode field, update suggestion builder)
- `runtime/cli.py` (add worktree_path and guardian_mode to process-stop
  serialization in _handle_dispatch)
- `hooks/check-guardian.sh` (add WORKTREE_PATH parsing and payload
  inclusion)
- `tests/runtime/test_completions.py` (update/add tests)
- `tests/runtime/test_dispatch_engine.py` (update/add tests)
- `tests/test_cli_dispatch.py` (new or extend existing: serialization
  tests)
- `tests/scenarios/test-check-guardian-worktree-path.sh` (new:
  WORKTREE_PATH parsing test)

**Required files/directories:**
- `runtime/core/completions.py` (routing table must change)
- `runtime/core/dispatch_engine.py` (planner block, worktree_path
  enrichment, guardian_mode, suggestion encoding must change)
- `runtime/cli.py` (serialization must add worktree_path and
  guardian_mode)
- `hooks/check-guardian.sh` (WORKTREE_PATH parsing must be added)
- At least one test file must be modified to cover new routing

**Forbidden touch points:**
- `hooks/post-task.sh` (thin adapter, no changes needed -- it already
  passes through hookSpecificOutput from cli.py)
- `hooks/subagent-start.sh` (changed in W-GWT-3)
- `agents/guardian.md` (changed in W-GWT-2)
- `agents/implementer.md` (changed in W-GWT-3)
- `runtime/core/worktrees.py` (changed in W-GWT-2)

**Expected state authorities touched:**
- MODIFIED: `completions.py` routing table (read authority for role
  transitions)
- MODIFIED: `dispatch_engine.py` planner routing block (write to dispatch
  result dict only — no lease writes, DEC-GUARD-WT-006 R3)
- MODIFIED: `dispatch_engine.py` tester routing block (read from
  workflow_bindings)
- MODIFIED: `cli.py` dispatch serialization (adds worktree_path,
  guardian_mode to output)
- MODIFIED: `check-guardian.sh` payload construction (adds WORKTREE_PATH)
- UNCHANGED: `dispatch_leases` table (no lease writes in W-GWT-1;
  guardian lease moved to W-GWT-2 provision CLI per DEC-GUARD-WT-006 R3)
- READ: `workflow_bindings` table (rework path enrichment)
- READ: `completion_records` table (worktree_path extraction)
- UNCHANGED: worktrees table, evaluation_state, workflow_scope

##### W-GWT-2: Guardian Worktree Provisioning (CLI + Prompt + Workflow Binding)

- **Weight:** L
- **Gate:** approve (user must approve Guardian prompt changes)
- **Deps:** W-GWT-1 (routing must send planner -> guardian first)
- **Integration:** `runtime/cli.py` (new worktree provision subcommand
  with filesystem-first order, Guardian lease at PROJECT_ROOT per
  DEC-GUARD-WT-006 R3), `runtime/core/worktrees.py` (register),
  `runtime/core/leases.py` (issue -- Guardian + implementer leases),
  `runtime/core/workflows.py` (bind_workflow -- binding at provision time),
  `agents/guardian.md` (provision mode instructions)

**Changes:**

1. **runtime/cli.py** `_handle_worktree()`: Add `provision` action that:
   - Takes `--workflow-id`, `--feature-name`, `--project-root`, `--branch`
     (optional, defaults to `main`)
   - Computes `worktree_path = <project_root>/.worktrees/feature-<name>`

   **Already-exists detection (DEC-GUARD-WT-008 R3):** Check the
   filesystem BEFORE any git or DB operations: does
   `<project_root>/.worktrees/feature-<name>` exist on disk? If yes,
   it is a re-provision — skip `git worktree add`, just ensure DB
   state is correct. Return `{"already_exists": true, ...}`.

   **Fresh provision sequence (DEC-GUARD-WT-008 R3, filesystem-first):**
   1. `git worktree add .worktrees/feature-<name> -b feature/<name>` —
      the CLI runs this via subprocess. If it fails, return error
      immediately — nothing to clean up.
   2. `worktrees.register(conn, path, branch_name, ticket=workflow_id)`
      — DB records filesystem reality. `ON CONFLICT(path) DO UPDATE`
      makes this idempotent.
   3. `leases.issue(conn, role="guardian", worktree_path=project_root,
      workflow_id=workflow_id)` — Guardian lease at PROJECT_ROOT so
      check-guardian.sh can anchor the completion record
      (DEC-GUARD-WT-006 R3: moved here from dispatch_engine).
   4. `leases.issue(conn, role="implementer", worktree_path=path,
      workflow_id=workflow_id, branch=branch_name)` — implementer
      lease at worktree_path.
   5. `workflows.bind_workflow(conn, workflow_id=workflow_id,
      worktree_path=path, branch=branch_name)` — workflow binding at
      provision time (DEC-GUARD-WT-004 revised).

   **Partial-failure cleanup (DEC-GUARD-WT-008 R3):** If steps 2-5
   fail after step 1 succeeded, cleanup: `git worktree remove
   <worktree_path>` (subprocess). If step 2 succeeds but steps 3-5
   fail, also call `worktrees.remove(conn, path)` to roll back the
   registration. The cleanup is wrapped in try/except so a cleanup
   failure does not mask the original error.

   - Returns `{"worktree_path": path, "branch": branch_name,
     "guardian_lease_id": guardian_lease_id,
     "implementer_lease_id": implementer_lease_id,
     "workflow_id": workflow_id, "already_exists": false}`

2. **agents/guardian.md**: Add a `## Worktree Provisioning` section
   describing the provision mode:
   - Guardian is dispatched after planner with `next_role=guardian` and
     `guardian_mode=provision` in dispatch context
   - The structured dispatch includes `workflow_id` and `feature_name`
   - Run `cc-policy worktree provision --workflow-id <wf> --feature-name
     <name> --project-root <root>` — this single CLI call handles:
     filesystem creation (`git worktree add`), DB registration,
     Guardian lease at PROJECT_ROOT, implementer lease at worktree_path,
     and workflow binding (DEC-GUARD-WT-008 R3)
   - If `already_exists=true`: filesystem and DB state already correct,
     Guardian just emits trailers
   - Emit `LANDING_RESULT: provisioned`, `OPERATION_CLASS: routine_local`,
     and `WORKTREE_PATH: <path>` trailers
   - Auto-land: provisioning is always auto (no user approval needed)

3. **runtime/core/worktrees.py**: No schema change needed. The existing
   `register()` function suffices. The `ticket` field stores workflow_id.

**Tests:**
- CLI integration test for `cc-policy worktree provision`
- Test that provision returns correct worktree_path, lease_id, and
  workflow binding
- Test that provision is idempotent (second call returns already_exists)
- Test that `provisioned` is accepted as a valid guardian verdict
- Test that workflow_bindings has entry after provision

###### Evaluation Contract for W-GWT-2

**Required tests:**
- `test_worktree_provision_cli`: `cc-policy worktree provision`
  creates worktree on filesystem, registers in DB, issues Guardian lease
  at PROJECT_ROOT, issues implementer lease at worktree_path, and creates
  workflow binding
- `test_worktree_provision_returns_leases`: provision result includes
  valid guardian_lease_id, implementer_lease_id, worktree_path,
  workflow_id
- `test_worktree_provision_guardian_lease_at_project_root`: after
  provision, an active Guardian lease exists at PROJECT_ROOT with the
  correct workflow_id (DEC-GUARD-WT-006 R3: this is how
  check-guardian.sh anchors the completion record)
- `test_worktree_provision_creates_binding`: after provision,
  `workflows.get_binding(conn, workflow_id)` returns a binding with the
  correct worktree_path and branch
- `test_worktree_provision_idempotent`: calling provision twice for the
  same path returns `already_exists=true` on the second call without
  creating a duplicate lease or binding. Filesystem check (path exists
  on disk) detects already-exists, not register() return value.
- `test_worktree_provision_filesystem_first`: provision creates the
  filesystem worktree BEFORE any DB writes. If git worktree add fails,
  no DB state is written. (DEC-GUARD-WT-008 R3)
- `test_worktree_provision_partial_failure_cleanup`: when git worktree
  add succeeds but register() or leases.issue() raises, git worktree
  remove is called to clean up the filesystem -- no orphaned worktree
  remains. If register() succeeds but leases.issue() raises,
  worktrees.remove() is also called.
- `test_worktree_provision_no_toctou`: provision does not call
  list_active() as a pre-check (verify by inspecting that list_active
  is NOT called during provision)
- `test_guardian_provisioned_verdict_valid`: completion record with
  `LANDING_RESULT=provisioned` validates as valid=True
- `test_provision_does_not_reset_eval`: check-guardian.sh with
  `LANDING_RESULT=provisioned` does not call `rt_eval_set idle` (eval
  reset gate at check-guardian.sh line 111 already excludes provisioned
  since it only matches `committed|merged`)

**Required real-path checks:**
- Run `cc-policy worktree provision --workflow-id test-wf
  --feature-name test-feat --project-root /tmp/test-proj` and verify:
  - `.worktrees/feature-test-feat` exists on the filesystem
  - worktrees table has an entry at the computed path
  - dispatch_leases table has an active Guardian lease at PROJECT_ROOT
  - dispatch_leases table has an active implementer lease at worktree
  - workflow_bindings table has a binding for workflow_id=test-wf
- Run provision again with same args, verify `already_exists=true` and
  no duplicate rows in any table (filesystem check detects existing path)

**Required authority invariants:**
- worktrees.py `register()` remains the sole worktree registry writer
- leases.py `issue()` remains the sole lease issuer
- workflows.py `bind_workflow()` remains the sole workflow binding writer
- check-guardian.sh eval reset is gated on `committed|merged` only

**Required integration points:**
- `cc-policy worktree provision` callable from Guardian bash commands
- Lease issued by provision is claimable by subagent-start.sh
- Workflow binding created by provision is readable by
  dispatch_engine's rework-path enrichment (W-GWT-1 change 4)

**Forbidden shortcuts:**
- Do not create a separate provisioning module -- use existing
  worktrees.py + leases.py + workflows.py
- Do not modify leases.py, worktrees.py, or workflows.py APIs (the
  existing signatures are sufficient)
- Do not use `worktrees.list_active()` as a pre-check before
  `register()` -- this creates a TOCTOU race (DEC-GUARD-WT-008 revised)
- Do not register in DB before filesystem creation -- filesystem is
  the source of truth (DEC-GUARD-WT-008 R3)

**Ready-for-guardian definition:**
CLI provision subcommand creates filesystem worktree BEFORE any DB writes
(DEC-GUARD-WT-008 R3). Provision is idempotent (filesystem check for
already-exists). Partial failure (git succeeds, DB fails) triggers
git worktree remove cleanup — no orphaned filesystem or DB state.
Guardian lease at PROJECT_ROOT is issued by provision CLI
(DEC-GUARD-WT-006 R3). Guardian prompt includes provision mode
instructions. Workflow binding exists after provision. All existing
tests pass.

###### Scope Manifest for W-GWT-2

**Allowed files/directories:**
- `runtime/cli.py` (add provision action to _handle_worktree)
- `agents/guardian.md` (add Worktree Provisioning section)
- `tests/runtime/test_worktree_provision.py` (new)
- `tests/scenarios/test-guardian-provision.sh` (new)

**Required files/directories:**
- `runtime/cli.py` (provision action must be added)
- `agents/guardian.md` (provision instructions must be added)
- At least one test file exercising the provision CLI

**Forbidden touch points:**
- `runtime/core/worktrees.py` (use existing API, do not modify)
- `runtime/core/leases.py` (use existing API, do not modify)
- `runtime/core/workflows.py` (use existing API, do not modify)
- `runtime/core/dispatch_engine.py` (changed in W-GWT-1)
- `runtime/core/completions.py` (changed in W-GWT-1)
- `hooks/check-guardian.sh` (changed in W-GWT-1)
- `hooks/subagent-start.sh` (changed in W-GWT-3)
- `agents/implementer.md` (changed in W-GWT-3)

**Expected state authorities touched:**
- WRITE: `worktrees` table (via register)
- WRITE: `dispatch_leases` table (via issue — Guardian lease at
  PROJECT_ROOT + implementer lease at worktree_path, DEC-GUARD-WT-006 R3)
- WRITE: `workflow_bindings` table (via bind_workflow)
- WRITE: filesystem (git worktree add via subprocess, DEC-GUARD-WT-008 R3)
- UNCHANGED: `evaluation_state`, `workflow_scope`, `completion_records`

##### W-GWT-3: Implementer/Hook Cleanup and Documentation

- **Weight:** M
- **Gate:** review
- **Deps:** W-GWT-1, W-GWT-2 (routing and provision must work first)
- **Integration:** `agents/implementer.md` (remove worktree creation
  instructions), `hooks/subagent-start.sh` (remove worktree creation
  prompt, update implementer context), CLAUDE.md (update dispatch rules)

**Changes:**

1. **agents/implementer.md**: Remove the `## Worktree Setup` section
   (lines 42-44) that tells implementers to create worktrees. Replace
   with:
   ```
   ## Worktree
   
   Your worktree has been provisioned by Guardian and is specified in
   your dispatch context. Work exclusively in that worktree. Do NOT
   create new worktrees or run `git worktree add`.
   ```

2. **hooks/subagent-start.sh**: Remove the implementer worktree
   creation prompt (lines 117-119):
   ```bash
   if [[ "$GIT_WT_COUNT" -eq 0 ]]; then
       CONTEXT_PARTS+=("CRITICAL FIRST ACTION: No worktree detected...")
   fi
   ```
   Replace with worktree path injection from lease context:
   ```bash
   # Inject worktree path from lease context (DEC-GUARD-WT-003)
   if [[ -n "$_LEASE_ID" ]]; then
       _WT_PATH=$(printf '%s' "$_CLAIM" | jq -r '.lease.worktree_path // empty')
       [[ -n "$_WT_PATH" ]] && CONTEXT_PARTS+=("Worktree: $_WT_PATH (provisioned by Guardian)")
   fi
   ```
   **Note:** The workflow binding call at line 135 is retained as an
   idempotent update. Guardian provisioning (W-GWT-2) is now the primary
   binding writer, but subagent-start.sh's call is safe (INSERT OR
   REPLACE) and acts as a fallback for edge cases where provisioning
   did not create the binding.

3. **agents/guardian.md**: Update `## Worktree Management` section
   (lines 53-54) to clarify Guardian is the SOLE worktree lifecycle
   authority. Remove ambiguity about who creates worktrees.

4. **runtime/core/policies/bash_main_sacred.py**: Update denial message
   (line 109) from `"Create a worktree first: git worktree add ..."` to
   reference Guardian provisioning instead of self-provisioning.

5. **CLAUDE.md dispatch rules**: Update the "Source Edit Routing"
   section and dispatch chain documentation to describe:
   - planner -> guardian (provision) -> implementer -> tester -> guardian
     (merge) lifecycle
   - Guardian as sole worktree lifecycle authority
   - Structured `guardian_mode` field in dispatch context
   - **Enriched AUTO_DISPATCH format (Gap 2 fix):** Update the
     "Auto-Dispatch" section (line ~107) to specify the enriched format:
     `AUTO_DISPATCH: <role> (key=value, key=value)`. The parenthetical
     metadata is contextual information the orchestrator passes to the
     next agent's dispatch prompt. The orchestrator reads this as text —
     no programmatic parser needed. Examples:
     `AUTO_DISPATCH: guardian (mode=provision, workflow_id=W, feature_name=F)`
     `AUTO_DISPATCH: implementer (worktree_path=/path, workflow_id=W)`
   - **Launch-in-worktree requirement:** When `AUTO_DISPATCH` includes
     `worktree_path`, the orchestrator MUST set the implementer agent's
     working directory to that path (not merely mention it in prompt
     text). This is a dispatch/launch concern, not a prompt concern.
     subagent-start.sh derives PROJECT_ROOT from the agent's cwd
     (line 82: lease claim, line 133: workflow bind). If the implementer
     launches at the repo root instead of the worktree, it will:
     (1) claim a lease against the repo root, not the worktree,
     (2) bind workflow to the repo root, not the worktree,
     (3) write source code on main, violating Sacred Practice #2.
     The orchestrator must pass `worktree_path` as the `cwd` parameter
     on the Agent tool call (or equivalent launch mechanism) so the
     implementer's PROJECT_ROOT resolves to the worktree directory.
     This makes subagent-start.sh's lease claim, workflow bind, and
     branch guard all operate against the correct root automatically.

**Tests:**
- Scenario test: subagent-start.sh for implementer with active lease
  includes worktree path
- Scenario test: subagent-start.sh for implementer without worktree
  does NOT include "CRITICAL FIRST ACTION" (that prompt is removed)
- Verify no agent prompt contains `git worktree add` instructions
  (except guardian.md)

###### Evaluation Contract for W-GWT-3

**Required tests:**
- `test_implementer_start_with_lease_shows_worktree`: subagent-start.sh
  for implementer with active lease includes "Worktree: <path>"
- `test_implementer_start_no_critical_first_action`: subagent-start.sh
  for implementer does NOT contain "CRITICAL FIRST ACTION"
- `test_no_worktree_add_in_implementer_prompt`: agents/implementer.md
  does not contain `git worktree add`
- `test_guardian_sole_worktree_authority`: agents/guardian.md contains
  sole worktree authority language
- `test_bash_main_sacred_message_updated`: bash_main_sacred.py denial
  message references Guardian, not self-provisioning
- `test_claude_md_dispatch_chain`: CLAUDE.md describes planner ->
  guardian -> implementer chain, not planner -> implementer directly
- `test_claude_md_enriched_auto_dispatch`: CLAUDE.md describes the
  enriched `AUTO_DISPATCH: <role> (key=value, key=value)` format with
  examples showing worktree_path and workflow_id metadata
- `test_claude_md_launch_in_worktree_requirement`: CLAUDE.md explicitly
  states that when AUTO_DISPATCH includes worktree_path, the orchestrator
  MUST set the implementer's working directory (cwd) to that path — not
  merely include it in prompt text. Verify the text contains language
  about cwd/working directory being the worktree_path, and explains the
  consequences of launching at repo root (wrong lease, wrong workflow
  bind, writes on main)

**Required real-path checks:**
- Run subagent-start.sh with implementer agent_type and an active
  lease that has worktree_path set. Verify hookSpecificOutput contains
  the worktree path.
- Grep all `.md` files in `agents/` for `git worktree add` -- only
  guardian.md should contain it.

**Required authority invariants:**
- Only agents/guardian.md contains worktree creation instructions
- subagent-start.sh lease context injection is the sole source of
  worktree path for implementers
- No flat-file worktree state is introduced

**Required integration points:**
- subagent-start.sh lease claim still works (lease issued by
  W-GWT-2 provision is claimable)
- Implementer workflow binding still works (retained as idempotent
  update in subagent-start.sh line 135)
- Branch guard policy still denies source writes on main

**Forbidden shortcuts:**
- Do not remove the lease claim logic from subagent-start.sh
  (it is still needed for all roles)
- Do not add worktree creation fallback to implementer ("if no
  worktree, create one") -- the provisioning is Guardian's job
- Do not modify the worktree registry or lease system
- Do not remove the workflow binding call from subagent-start.sh
  (it is retained as an idempotent fallback)

**Ready-for-guardian definition:**
Implementer prompt contains no worktree creation instructions.
subagent-start.sh injects worktree path from lease context. No agent
prompt except guardian.md references `git worktree add`. CLAUDE.md
describes the updated dispatch chain including the launch-in-worktree
requirement: when AUTO_DISPATCH includes worktree_path, the orchestrator
must set the implementer's working directory (cwd) to that path, not
merely include it in prompt text. All existing subagent-start scenario
tests pass.

###### Scope Manifest for W-GWT-3

**Allowed files/directories:**
- `agents/implementer.md` (remove worktree creation, add worktree
  received instructions)
- `agents/guardian.md` (update Worktree Management for sole authority)
- `hooks/subagent-start.sh` (remove worktree creation prompt, add
  worktree path injection)
- `runtime/core/policies/bash_main_sacred.py` (update denial message)
- `CLAUDE.md` (update dispatch rules for guardian provisioning chain)
- `tests/scenarios/test-implementer-worktree-context.sh` (new)

**Required files/directories:**
- `agents/implementer.md` (worktree creation instructions must be
  removed)
- `hooks/subagent-start.sh` (CRITICAL FIRST ACTION must be removed,
  worktree path injection added)
- `CLAUDE.md` (dispatch chain documentation must be updated)

**Forbidden touch points:**
- `runtime/core/dispatch_engine.py` (changed in W-GWT-1)
- `runtime/core/completions.py` (changed in W-GWT-1)
- `runtime/cli.py` (changed in W-GWT-1 and W-GWT-2)
- `runtime/core/worktrees.py` (no changes needed)
- `runtime/core/leases.py` (no changes needed)
- `runtime/core/workflows.py` (no changes needed)
- `hooks/check-guardian.sh` (changed in W-GWT-1)
- `hooks/post-task.sh` (no changes needed)

**Expected state authorities touched:**
- UNCHANGED: all SQLite tables (this wave is prompt/hook context only)
- READ: `dispatch_leases` table (subagent-start.sh reads lease for
  worktree_path)

#### Wave Decomposition

```
Wave 1: W-GWT-1  (routing table + dispatch engine + carrier chain + suggestion encoding -- foundation)
Wave 2: W-GWT-2  (Guardian provision CLI + prompt + workflow binding -- requires routing)
Wave 3: W-GWT-3  (implementer cleanup + hook update + docs -- requires provision working)
```

**Critical path:** W-GWT-1 -> W-GWT-2 -> W-GWT-3
**Max width:** 1 (strictly sequential -- each wave depends on the prior)

**Codex review findings addressed:**

| Finding | Severity | Resolution | Work Item |
|---------|----------|------------|-----------|
| HIGH-1: WORKTREE_PATH has no end-to-end carrier | HIGH | cli.py serialization + check-guardian.sh parsing + suggestion-text encoding of worktree_path in AUTO_DISPATCH line (sole carrier to orchestrator) | W-GWT-1 |
| HIGH-2: No valid Guardian completion anchor | HIGH | DEC-GUARD-WT-006 R3: Guardian lease issued by provision CLI (W-GWT-2), not dispatch_engine. Planner lease is a claim, not an issue — fail-closed at planner stop would break existing tests. workflow_id at planner stop is best-effort (lease -> branch fallback). | W-GWT-2 |
| MEDIUM-3: Rework path not in work items | MEDIUM | DEC-GUARD-WT-004 revised: rework enrichment + binding at provision time | W-GWT-1, W-GWT-2 |
| MEDIUM-4: Mode-from-context too implicit | MEDIUM | DEC-GUARD-WT-007: structured guardian_mode field + docs update | W-GWT-1, W-GWT-3 |
| Gap 2: No orchestrator parser for enriched AUTO_DISPATCH | MEDIUM | CLAUDE.md updated (W-GWT-3) to specify enriched format: `AUTO_DISPATCH: <role> (key=value, ...)`. Rework path (tester -> implementer) suggestion builder also encodes worktree_path (W-GWT-1 change 5c). | W-GWT-1, W-GWT-3 |
| Race safety | ADDITIONAL | DEC-GUARD-WT-008 R3: filesystem-first provision order, no list_active() pre-check (TOCTOU), filesystem check for already-exists detection, git worktree remove cleanup on partial failure | W-GWT-2 |

**File-level change summary:**

| File | Wave | Change Type |
|------|------|-------------|
| `runtime/core/completions.py` | W-GWT-1 | Modify routing table, add `provisioned` verdict |
| `runtime/core/dispatch_engine.py` | W-GWT-1 | Change planner block routing (no guardian lease — moved to W-GWT-2), add worktree_path enrichment (provision + rework), add guardian_mode, update suggestion with enriched AUTO_DISPATCH format |
| `runtime/cli.py` | W-GWT-1, W-GWT-2 | Add worktree_path + guardian_mode to dispatch serialization (W-GWT-1); add provision action (W-GWT-2) |
| `hooks/check-guardian.sh` | W-GWT-1 | Add WORKTREE_PATH parsing and payload inclusion |
| `agents/guardian.md` | W-GWT-2, W-GWT-3 | Add provision mode section with structured fields, update Worktree Management |
| `agents/implementer.md` | W-GWT-3 | Remove worktree creation, add received-worktree instructions |
| `hooks/subagent-start.sh` | W-GWT-3 | Remove CRITICAL FIRST ACTION, add worktree path injection |
| `runtime/core/policies/bash_main_sacred.py` | W-GWT-3 | Update denial message |
| `CLAUDE.md` | W-GWT-3 | Update dispatch chain documentation |
| `tests/runtime/test_completions.py` | W-GWT-1 | Update/add routing tests |
| `tests/runtime/test_dispatch_engine.py` | W-GWT-1 | Update/add dispatch tests (worktree_path, guardian_mode, rework path, enriched suggestion format) |
| `tests/test_cli_dispatch.py` | W-GWT-1 | New/extend: serialization tests |
| `tests/scenarios/test-check-guardian-worktree-path.sh` | W-GWT-1 | New: WORKTREE_PATH parsing test |
| `tests/runtime/test_worktree_provision.py` | W-GWT-2 | New: provision CLI tests (incl. idempotency, binding) |
| `tests/scenarios/test-guardian-provision.sh` | W-GWT-2 | New: guardian provision scenario |
| `tests/scenarios/test-implementer-worktree-context.sh` | W-GWT-3 | New: implementer context scenario |

### INIT-ENFORCE: Hook Enforcement Breach Remediation

- **Status:** planned (2026-04-06)
- **Goal:** Close four enforcement gaps that allowed the orchestrator to execute
  Guardian-only git operations (commit on main, worktree remove, branch delete)
  without being blocked. Harden the hook system so that internal hook failures
  can never silently degrade to "allow."
- **Current truth:** The orchestrator ran `git commit` on main, `git worktree
  remove`, and `git branch -d` without being denied. Root cause is a
  four-gap breach: (1) `bash_git_who` regex only gates commit/merge/push,
  ignoring worktree lifecycle, branch deletion, rebase, and reset;
  (2) `build_context()` lease resolution is role-blind, letting the
  orchestrator inherit any Guardian lease sharing the same worktree_path;
  (3) auto-review.sh crashes on heredoc commands (`$(cat <<'EOF'...)`),
  exiting non-zero and hitting the hook contract's "non-zero = does not
  block" rule; (4) `set -euo pipefail` in all enforcement hooks means any
  unexpected crash exits non-zero, which per the Claude Code contract means
  "hook error, does not block," silently degrading to allow.
- **Scope:** Policy engine regex expansion and role-scoped lease resolution
  in Python; heredoc crash fix in auto-review.sh; reusable fail-closed
  safety wrapper in a new `hooks/lib/hook-safety.sh`; integration of the
  wrapper into `pre-bash.sh`, `pre-write.sh`, and `auto-review.sh`; observatory
  event emission for crash-denials.
- **Exit criteria:** (1) `bash_git_who` denies `git worktree remove`,
  `git branch -d/-D`, `git rebase`, `git reset` without a valid role-matched
  lease. (2) `build_context()` only assigns a lease when the caller's
  `actor_role` matches the lease's `role` field (or actor_role is empty and
  falls through to marker inference). (3) auto-review.sh handles heredoc
  commands without crashing. (4) All three enforcement hooks (`pre-bash.sh`,
  `pre-write.sh`, `auto-review.sh`) use the fail-closed wrapper so any
  internal crash emits a deny + observatory event + exit 0. (5) All existing
  tests pass with zero regressions.
- **Dependencies:** INIT-PE (completed), INIT-OBS (W-OBS-2 landed)
- **Dominant constraints:** Cannot change Claude Code's hook contract
  (non-zero = does not block). Must maintain backward compatibility with
  existing `settings.json` hook registration. Must not break policy engine
  evaluate flow. Observatory events must use existing `rt_event_emit`
  infrastructure. Lease role filtering must not break legitimate subagent use
  (Guardian, Implementer, Tester all hold leases).

#### Problem Decomposition

**Who has this problem:** Every user of this governance system. An
orchestrator (or any non-Guardian caller) can bypass WHO enforcement for
destructive git operations. This undermines the core Sacred Practice that
"Guardian is sole git authority."

**How often:** Every session where the orchestrator issues git commands that
fall outside the narrow commit/merge/push regex, or where the orchestrator
shares a worktree_path with a Guardian lease, or where a heredoc-style commit
message triggers the auto-review crash.

**Cost:** Complete enforcement bypass. The hook system claims protection it
cannot deliver. This violates Principle 8: "Docs must not claim protection
that the running system cannot actually enforce."

#### Architecture Decisions

##### DEC-ENFORCE-001: Expand `_GIT_OP_RE` to cover all Guardian-only operations

**Options considered:**
1. Expand `_GIT_OP_RE` inline to match all git subcommands that classify_git_op
   covers (worktree remove, branch -d/-D, rebase, reset, clean, etc.)
2. Replace the regex gate entirely with a call to `classify_git_op()` and deny
   when the result is anything other than `"unclassified"`

**Recommendation:** Option 2. `classify_git_op()` is already the canonical
classifier. The regex `_GIT_OP_RE` is a redundant, weaker gate that must be
kept in sync with the classifier. Replacing the regex with a classifier call
eliminates the sync burden and guarantees that any command `classify_git_op()`
deems non-unclassified is subject to WHO enforcement. The new pattern:
call `classify_git_op()` first; if result is `"unclassified"`, skip (no
lease needed for read-only git ops). If non-unclassified, proceed to lease
validation.

**Additional expansion needed:** `classify_git_op()` currently does not cover
`git worktree remove`, `git branch -d/-D`, or `git clean`. These must be
added to the classifier as `high_risk` operations in both the Python version
(`leases.py`) and the bash performance mirror (`context-lib.sh`). The Python
version is authoritative; the bash version must produce identical results.
This eliminates the third classification point (`_GIT_OP_RE`) and reduces
the system from three classifiers to two (Python canonical + bash mirror),
with parity enforced by scenario tests.

**Decision:** Option 2 adopted.

##### DEC-ENFORCE-002: Role-scoped lease resolution in build_context()

**Options considered:**
1. When falling back to worktree_path-based lease lookup (no actor_id match),
   add a role filter: `WHERE role = ?` using actor_role.
2. When falling back, load the lease but then check that actor_role matches
   the lease's role before assigning it to context. If mismatch, set lease=None.
3. Add a separate `lease_role` field to PolicyContext and let each policy
   decide whether role mismatch is relevant.

**Trade-offs:**
- Option 1 fails when actor_role is empty (common for the orchestrator, which
  has no marker). An empty-role query would match nothing, which is actually
  correct behavior (orchestrator should NOT get a lease), but it changes
  semantics for legitimate subagents whose marker hasn't been read yet.
- Option 2 is safest: load the lease, then validate. When actor_role is empty,
  the lease is not assigned (orchestrator gets lease=None, which is correct).
  When actor_role matches, the lease is assigned as before. This preserves
  existing behavior for implementer/tester/guardian and blocks the orchestrator.
- Option 3 pushes complexity to every policy function. Not worth it.

**Decision:** Option 2 adopted. The check is: if `actor_role` is non-empty and
the lease's `role` field is non-empty and they differ, discard the lease
(set to None). If either is empty, keep current behavior (empty actor_role
means unknown caller, which should NOT inherit a leased role).

**Refinement:** When actor_role is empty AND we found a lease by worktree_path,
we currently assign `resolved_role = lease["role"]`. This is the exact
inheritance bug. The fix: when actor_role is empty, do NOT assign the lease.
The orchestrator has no role marker and no actor_id, so it should fall through
to lease=None, which produces a deny from bash_git_who. Legitimate subagents
always have actor_role set (from marker or env var).

##### DEC-ENFORCE-003: Fail-closed safety wrapper for all enforcement hooks

**Options considered:**
1. Remove `set -euo pipefail` from hooks and add explicit error handling.
2. Keep `set -euo pipefail` for development safety but wrap the main logic
   in a `_run_fail_closed` function that traps ERR/EXIT and emits deny+exit 0
   on any unexpected failure.
3. Create a library function in `hooks/lib/hook-safety.sh` that any hook can
   source and use.

**Trade-offs:**
- Option 1 removes a useful development guard. Unset variables would silently
  expand to empty string, masking bugs.
- Option 2+3 are complementary. The wrapper temporarily disables `set -e`
  via `set +e`, calls the main function, captures the exit code, re-enables
  `set -e`, and on non-zero exit emits deny JSON + observatory event + exit 0.
  The hook's own `set -euo pipefail` remains for development discipline on the
  code paths that don't crash.
- Option 3 makes the pattern reusable across pre-bash.sh, pre-write.sh, and
  auto-review.sh.

**Decision:** Options 2+3 adopted. New file `hooks/lib/hook-safety.sh` provides
`_run_fail_closed <hook_name> <main_function>`. The function:
1. Temporarily disables `set -e` via `set +e`.
2. Calls main_function, captures its exit code.
3. Re-enables `set -e` via `set -e`.
4. If exit code is 0: no-op (the function already emitted its output).
5. If exit code is non-zero: emits a deny JSON payload via stdout, emits an
   observatory event via `rt_event_emit "hook_crash_deny"` with crash context
   (hook name, exit code, stderr snippet), and exits 0 so the Claude Code
   contract interprets the output as a valid hook response (deny).

Subshells are not used because they cannot pass stdout output back to the
parent without temp files, adding failure modes. The `set +e` / `set -e`
toggle runs the function in the same process, preserving natural stdout flow.

**Integration pattern:**
```bash
# In pre-bash.sh:
source "$HOOKS_DIR/lib/hook-safety.sh"
_hook_main() { ... existing logic ... }
_run_fail_closed "pre-bash" _hook_main
```

The existing `set -euo pipefail` at the top of each hook remains, but the
`_run_fail_closed` wrapper catches any crash that escapes, ensuring the hook
NEVER exits non-zero.

##### DEC-ENFORCE-004: Auto-review heredoc crash fix

The crash occurs because `is_safe()` line 91 uses `grep -qE '<<\s*[A-Za-z_"'"'"']'`
to detect heredocs and returns 1 (risky). This is correct behavior -- heredocs
cannot be statically analyzed so they are classified as risky. The real problem
is that the `$( )` inside the git commit command triggers `analyze_substitutions()`
which tries to parse the heredoc content recursively, and the paren-depth counter
fails when the heredoc crosses the `$()` boundary.

The fix: In `is_safe()`, the heredoc check (Phase 1, line 91) already fires
BEFORE command substitution analysis. It sets risk and returns 1 (risky).
The crash happens when the heredoc check does NOT match (e.g., the heredoc is
inside a `$()` that was extracted by `analyze_substitutions()`). The inner
content `cat <<'EOF'...` is then passed to `is_safe()` recursively, where
the heredoc check DOES match, but by then the `set -euo pipefail` has caused
an intermediate failure in the paren-depth counter.

**Fix approach:** The heredoc detection in `is_safe()` is already correct for
top-level commands. The crash path is inside `analyze_substitutions()` where
the `$()` parser extracts inner content that includes heredoc markers. The
fix is to run the heredoc check on the inner content BEFORE recursing into
`is_safe()`, and if a heredoc is detected, return 1 (risky) immediately
without further parsing.

Additionally, even if the fix is imperfect, Gap 4's `_run_fail_closed` wrapper
ensures any remaining crash path is caught and converted to a deny.

#### State Authority Map

| State Domain | Canonical Authority | Read By | Written By |
|---|---|---|---|
| Lease records | `dispatch_leases` table in state.db | `build_context()`, bash_git_who, bash_eval_readiness, bash_approval_gate | `leases.issue()`, `leases.claim()`, `leases.release()` |
| Actor role | `agent_markers` table (via `get_active`) | `build_context()`, `current_active_agent_role()` | `subagent-start.sh` via `rt_marker_set()` |
| Git op classification | `classify_git_op()` in leases.py (canonical Python); `classify_git_op()` in context-lib.sh (bash performance mirror, must produce identical results) | bash_git_who policy (Python), shell hooks and scenario tests (bash) | N/A (pure functions, both updated in W-ENFORCE-1) |
| Hook crash telemetry | `events` table (existing, `hook_crash_deny` event type) | Observatory dashboards, `cc_policy event` queries | `_run_fail_closed()` via `rt_event_emit()` |
| Policy evaluation | `PolicyRegistry.evaluate()` | pre-bash.sh, pre-write.sh | Policy functions (pure, no writes) |

#### Work Items

##### W-ENFORCE-1: Expand git op classification and WHO regex (Python)

**Weight:** M
**Gate:** review (user sees test output)
**Deps:** none
**Integration:** `runtime/core/leases.py` (classify_git_op), `runtime/core/policies/bash_git_who.py` (check function), `tests/runtime/policies/test_bash_git_who.py`, `tests/runtime/test_leases.py` (if exists)

**Changes:**

1. **`runtime/core/leases.py` `classify_git_op()`**: Add patterns:
   - `git worktree remove` / `git worktree prune` -> `high_risk`
   - `git branch -d` / `git branch -D` -> `high_risk`
   - `git clean` -> `high_risk`
   - Place these BEFORE the existing `unclassified` fallback.

2. **`runtime/core/policies/bash_git_who.py`**: Replace `_GIT_OP_RE` gate
   with `classify_git_op()` call:
   ```python
   op_class = classify_git_op(command)
   if op_class == "unclassified":
       return None  # read-only git ops, no lease needed
   ```
   Then proceed with existing lease validation using the already-computed
   `op_class`. Remove the second `classify_git_op()` call (line 92) since
   we already have the result.

3. **`context-lib.sh` `classify_git_op()` (bash version)**: Add matching
   patterns for worktree remove, branch -d/-D, and clean. The bash classifier
   is a performance-motivated mirror of the Python classifier in `leases.py`.
   It exists because shell hooks and scenario tests call it directly to avoid
   Python startup overhead. **Both classifiers must produce identical results
   for all inputs.** The Python version in `leases.py` is the canonical
   authority; the bash version must be updated to match whenever the Python
   version changes. A parity test (see below) enforces this.

**Evaluation Contract (W-ENFORCE-1):**

- **Required tests:**
  - `tests/runtime/policies/test_bash_git_who.py`: New tests for
    `git worktree remove`, `git branch -d`, `git branch -D`, `git rebase`,
    `git reset`, `git clean` -- all must return deny when no lease.
  - `tests/runtime/policies/test_bash_git_who.py`: New test that
    `git worktree list`, `git branch`, `git status`, `git log` still return
    None (skip, no enforcement).
  - `tests/runtime/test_leases.py` or inline: New tests for
    `classify_git_op()` covering worktree remove -> high_risk, branch -d ->
    high_risk, clean -> high_risk.
  - All existing tests in `test_bash_git_who.py` must continue to pass.
  - `tests/scenarios/test-auto-review.sh` Group 7: extend existing bash
    `classify_git_op` tests with new cases (worktree remove, branch -d/-D,
    clean) to verify bash/Python parity.
- **Required real-path checks:** Run `cc-policy evaluate` with a synthetic
  JSON payload containing `git worktree remove /path` and verify the policy
  engine returns deny.
- **Required authority invariants:** `classify_git_op()` in `leases.py`
  (Python) is the canonical classifier. The bash version in `context-lib.sh`
  is a performance mirror that must produce identical results. Both must be
  updated together. The parity test in Group 7 of `test-auto-review.sh`
  enforces this.
- **Required integration points:** `bash_git_who.py` still works with
  `bash_eval_readiness.py` and `bash_approval_gate.py` in the priority chain.
- **Forbidden shortcuts:** Do not add a second regex alongside
  `classify_git_op()`. Do not bypass `classify_git_op()` with hardcoded
  subcommand lists in the policy function.
- **Ready-for-guardian definition:** All new and existing unit tests pass.
  `classify_git_op("git worktree remove /path")` returns `"high_risk"`.
  `classify_git_op("git branch -d feature")` returns `"high_risk"`.
  The policy denies these commands when no lease is present.

**Scope Manifest (W-ENFORCE-1):**

- **Allowed files:** `runtime/core/leases.py`, `runtime/core/policies/bash_git_who.py`, `hooks/context-lib.sh`, `tests/runtime/policies/test_bash_git_who.py`, `tests/runtime/test_leases.py`, `tests/scenarios/test-auto-review.sh` (Group 7 parity tests)
- **Required files:** `runtime/core/leases.py`, `runtime/core/policies/bash_git_who.py`, `hooks/context-lib.sh`, `tests/runtime/policies/test_bash_git_who.py`
- **Forbidden touch points:** `runtime/core/policy_engine.py` (Gap 2 scope), `hooks/pre-bash.sh` (Gap 3/4 scope), `hooks/auto-review.sh` (Gap 3 scope), `hooks/lib/hook-safety.sh` (Gap 4 scope)
- **Expected state authorities touched:** `classify_git_op()` (extended), `bash_git_who.check()` (modified gate logic)

---

##### W-ENFORCE-2: Role-scoped lease resolution in build_context() (Python)

**Weight:** M
**Gate:** review
**Deps:** none (independent of W-ENFORCE-1)
**Integration:** `runtime/core/policy_engine.py` (build_context), `tests/runtime/test_policy_engine.py`

**Changes:**

1. **`runtime/core/policy_engine.py` `build_context()` lines 386-393**: After
   loading a lease by worktree_path, validate role alignment before assigning:
   ```python
   if lease is None:
       row = conn.execute(
           "SELECT * FROM dispatch_leases WHERE status = 'active' "
           "AND (worktree_path = ? OR worktree_path = ?) LIMIT 1",
           (cwd, project_root),
       ).fetchone()
       if row:
           candidate = dict(row)
           # DEC-ENFORCE-002: role-scoped lease resolution.
           # Only assign the lease if the caller's role matches the lease's
           # role, or if the caller has an explicit actor_id (already tried above).
           # An empty actor_role (orchestrator) must NOT inherit a leased role.
           candidate_role = candidate.get("role", "")
           if actor_role and candidate_role and actor_role != candidate_role:
               lease = None  # role mismatch — do not inherit
           elif not actor_role:
               lease = None  # unknown caller — do not inherit leased identity
           else:
               lease = candidate
   ```

2. **Downstream effect on `resolved_role` (lines 396-404):** Currently, when
   lease is loaded, `resolved_role` is set from `lease["role"]` if not already
   set. With the fix, if the lease is discarded due to role mismatch,
   `resolved_role` stays empty, which is correct -- the orchestrator has no
   role and should not be assigned one from a lease it doesn't own.

**Evaluation Contract (W-ENFORCE-2):**

- **Required tests:**
  - New test: `build_context()` with actor_role="" and an active lease for
    worktree_path should return context with lease=None.
  - New test: `build_context()` with actor_role="implementer" and a Guardian
    lease for worktree_path should return context with lease=None.
  - New test: `build_context()` with actor_role="guardian" and a Guardian lease
    for worktree_path should return context with lease=that_lease.
  - New test: `build_context()` with actor_id matching a lease should still
    return that lease regardless of role (actor_id match is the primary path).
  - All existing `test_policy_engine.py` tests must pass.
- **Required real-path checks:** Run the full policy evaluation pipeline with
  a synthetic orchestrator payload (no actor_role, no actor_id) targeting a
  worktree_path that has a Guardian lease. Verify the result is deny (no lease
  assigned).
- **Required authority invariants:** Lease is the sole source of WHO identity.
  Marker fallback is secondary. The invariant "one active lease per
  worktree_path" is preserved (we don't modify lease issuance).
- **Required integration points:** `bash_git_who.py`, `bash_eval_readiness.py`,
  `bash_approval_gate.py` all read `context.lease`. They must still receive
  a valid lease when the caller is the correct role.
- **Forbidden shortcuts:** Do not add role filtering to the SQL query (breaks
  when actor_role is empty but actor_id is valid). Do not add a separate
  `is_orchestrator()` check (fragile, not future-proof).
- **Ready-for-guardian definition:** All new and existing tests pass. An
  orchestrator-like caller (empty actor_role, empty actor_id) sharing a
  worktree_path with an active Guardian lease gets `context.lease = None`.
  A Guardian caller with matching actor_role gets the lease as before.

**Scope Manifest (W-ENFORCE-2):**

- **Allowed files:** `runtime/core/policy_engine.py`, `tests/runtime/test_policy_engine.py`
- **Required files:** `runtime/core/policy_engine.py`, `tests/runtime/test_policy_engine.py`
- **Forbidden touch points:** `runtime/core/leases.py` (W-ENFORCE-1 scope), `runtime/core/policies/bash_git_who.py` (W-ENFORCE-1 scope), `hooks/` (Gaps 3/4 scope)
- **Expected state authorities touched:** `build_context()` lease resolution logic (modified)

---

##### W-ENFORCE-3: Fail-closed safety wrapper (shell, new file)

**Weight:** M
**Gate:** review
**Deps:** none (independent of W-ENFORCE-1 and W-ENFORCE-2)
**Integration:** New file `hooks/lib/hook-safety.sh`. Will be sourced by
pre-bash.sh, pre-write.sh, auto-review.sh in W-ENFORCE-4.

**Changes:**

1. **Create `hooks/lib/hook-safety.sh`**: Provides `_run_fail_closed` function:
   ```bash
   # _run_fail_closed <hook_name> <function_name>
   # Executes function_name. If it exits non-zero (crash), emits:
   #   1. A deny JSON on stdout (hookSpecificOutput with permissionDecision=deny)
   #   2. An observatory event (hook_crash_deny) with crash context
   #   3. exit 0 (so Claude Code treats the output as a valid hook response)
   ```
   Implementation approach:
   - Temporarily disable `set -e` (`set +e`)
   - Call the function, capture exit code
   - Re-enable `set -e` (`set -e`)
   - If exit code != 0: emit deny JSON + observatory event + exit 0
   - If exit code == 0: no-op (function already emitted its output)

2. **Observatory integration:** Use `rt_event_emit "hook_crash_deny"` with a
   detail JSON containing `hook_name`, `exit_code`, and a truncated stderr
   snippet (max 500 chars). This requires `context-lib.sh` to be sourced
   before `hook-safety.sh` (it already is, since context-lib.sh sources
   runtime-bridge.sh which defines rt_event_emit).

**Evaluation Contract (W-ENFORCE-3):**

- **Required tests:**
  - New test: `tests/scenarios/test-hook-safety.sh` that sources
    `hook-safety.sh` and verifies:
    - A function that exits 0 passes through normally
    - A function that exits 1 produces deny JSON on stdout
    - A function that exits 1 emits deny JSON with correct hookSpecificOutput
      structure (parseable by jq, has permissionDecision=deny)
    - The wrapper itself exits 0 even when the inner function crashes
  - Verify the deny JSON output matches the Claude Code PreToolUse hook
    contract (contains `hookSpecificOutput.permissionDecision`).
- **Required real-path checks:** Source the wrapper in a test environment and
  trigger a crash. Verify stdout contains valid deny JSON and the exit code
  is 0.
- **Required authority invariants:** The wrapper does not modify any state
  beyond emitting the observatory event. It does not read or write leases,
  markers, or evaluation state.
- **Required integration points:** `rt_event_emit` must be available (sourced
  via context-lib.sh -> runtime-bridge.sh). If not available (bootstrap race),
  the wrapper must still emit deny JSON and exit 0 without the observatory
  event.
- **Forbidden shortcuts:** Do not use a subshell for the main function call
  (subshells cannot pass output back to the parent's stdout without temp
  files, adding failure modes). Use `set +e` / `set -e` toggle instead.
- **Ready-for-guardian definition:** `test-hook-safety.sh` passes. The wrapper
  produces valid deny JSON on crash. The wrapper exits 0 on crash. The
  wrapper does not interfere with normal (exit 0) hook execution.

**Scope Manifest (W-ENFORCE-3):**

- **Allowed files:** `hooks/lib/hook-safety.sh` (NEW), `tests/scenarios/test-hook-safety.sh` (NEW)
- **Required files:** `hooks/lib/hook-safety.sh` (NEW), `tests/scenarios/test-hook-safety.sh` (NEW)
- **Forbidden touch points:** `hooks/pre-bash.sh`, `hooks/pre-write.sh`, `hooks/auto-review.sh` (W-ENFORCE-4 scope), `runtime/` (W-ENFORCE-1/2 scope)
- **Expected state authorities touched:** `events` table (new event type `hook_crash_deny`; table already exists in `runtime/schemas.py` EVENTS_DDL)

---

##### W-ENFORCE-4: Integrate safety wrapper + fix heredoc crash (shell)

**Weight:** M
**Gate:** review
**Deps:** W-ENFORCE-3 (safety wrapper must exist first)
**Integration:** `hooks/pre-bash.sh`, `hooks/pre-write.sh`, `hooks/auto-review.sh`

**Changes:**

1. **`hooks/auto-review.sh`**: Fix the heredoc crash in
   `analyze_substitutions()`. When the inner content extracted from `$()`
   contains a heredoc marker (`<<`), return 1 (risky) immediately without
   recursing into `is_safe()`. Add the heredoc check as the first line of
   the inner-content analysis loop (after `if [[ -n "$inner" ]]; then`):
   ```bash
   if echo "$inner" | grep -qE '<<\s*[A-Za-z_"'"'"']'; then
       set_risk "Command substitution contains heredoc — cannot statically analyze"
       return 1
   fi
   ```

2. **`hooks/pre-bash.sh`**: Wrap the main logic in `_run_fail_closed`:
   - Source `hooks/lib/hook-safety.sh` after context-lib.sh
   - Move lines 41-127 (HOOK_INPUT through exit 0) into `_hook_main()`
   - Replace with: `_run_fail_closed "pre-bash" _hook_main`
   - The existing fail-closed logic (lines 93-107) is still valuable as an
     inner defense; the wrapper is the outer safety net.

3. **`hooks/pre-write.sh`**: Same wrapper pattern:
   - Source `hooks/lib/hook-safety.sh` after context-lib.sh
   - Move lines 36-109 into `_hook_main()`
   - Replace with: `_run_fail_closed "pre-write" _hook_main`
   - **Behavioral change:** The current inner fail-closed path (lines 79-98)
     emits deny JSON and `exit 2`. Under the wrapper, that `exit 2` would be
     caught and the wrapper would emit a second deny JSON. Fix: change the
     inner fail-closed `exit 2` to `exit 0` (the deny JSON is already on
     stdout; the wrapper sees exit 0 and passes through). This aligns the
     inner fail-closed with the outer wrapper's contract: deny = JSON on
     stdout + exit 0. The wrapper only fires on crashes that did NOT produce
     deny JSON.
   - **Test update required:** `tests/runtime/policies/test_write_adapter.py`
     currently asserts `result.returncode != 0` at lines 121-122, 176, 213,
     and 249. These four assertions must be changed to `result.returncode == 0`
     because the hook now always exits 0 (deny is signaled via JSON payload,
     not exit code). The JSON assertions in those same tests remain correct --
     they already validate deny payload structure.

4. **`hooks/auto-review.sh`**: Wrap the main execution block:
   - Source `hooks/lib/hook-safety.sh` (requires also sourcing context-lib.sh
     for rt_event_emit access; currently auto-review.sh only sources log.sh)
   - Move lines 30-894 (HOOK_INPUT through advise call) into `_hook_main()`
   - Replace with: `_run_fail_closed "auto-review" _hook_main`
   - Note: auto-review.sh currently only sources log.sh. To get
     `rt_event_emit`, it must also source context-lib.sh. However, this adds
     ~200ms Python startup overhead. Alternative: make the observatory event
     optional in `_run_fail_closed` (if `rt_event_emit` is not defined, skip
     the event but still emit deny + exit 0). This is safer -- the wrapper
     works even without the full runtime bridge.

**Evaluation Contract (W-ENFORCE-4):**

- **Required tests:**
  - `tests/scenarios/test-auto-review.sh`: Add test case for a command
    containing heredoc inside `$()`:
    ```
    git commit -m "$(cat <<'EOF'\nCommit message\nEOF\n)"
    ```
    Verify the hook outputs advisory JSON (not crash), exit code 0.
  - Run existing `test-auto-review.sh` and `test-auto-review-quoted-pipes.sh`
    -- all must pass (no regressions).
  - New test: Force a crash in pre-bash.sh (e.g., by setting COMMAND to a
    value that triggers a jq parse error in EVAL_INPUT construction). Verify
    the hook outputs deny JSON and exits 0.
  - New test: Force a crash in pre-write.sh similarly. Verify deny JSON and
    exit 0.
  - `tests/runtime/policies/test_write_adapter.py`: Update four assertions
    that expect `returncode != 0` to expect `returncode == 0` (lines 121-122,
    176, 213, 249). The deny JSON assertions remain unchanged. Run the full
    test file to confirm no regressions.
- **Required real-path checks:** Run the pre-bash.sh hook with a heredoc
  commit command. Verify it does not crash (exit 0) and the output is valid
  JSON.
- **Required authority invariants:** The hooks' functional behavior (allow/deny
  decisions) must not change for non-crash paths. The wrapper only activates
  on unexpected failures.
- **Required integration points:** `settings.json` hook registration is
  unchanged. Hook timeout values are unchanged. The fail-closed wrapper
  must complete within the hook timeout (5s for auto-review, 10s for
  pre-bash/pre-write).
- **Forbidden shortcuts:** Do not remove `set -euo pipefail` from hooks.
  Do not add `|| true` to any command in the main logic. Do not move
  auto-review.sh into the policy engine (it serves a different purpose:
  user-facing auto-approval, not WHO enforcement).
- **Ready-for-guardian definition:** All existing scenario tests pass.
  Heredoc commit command does not crash auto-review.sh. A simulated crash
  in each hook produces valid deny JSON and exit 0. No regression in hook
  timing (wrapper adds < 1ms overhead on the happy path).

**Scope Manifest (W-ENFORCE-4):**

- **Allowed files:** `hooks/pre-bash.sh`, `hooks/pre-write.sh`, `hooks/auto-review.sh`, `tests/scenarios/test-auto-review.sh`, `tests/scenarios/test-hook-safety-integration.sh` (NEW), `tests/runtime/policies/test_write_adapter.py`
- **Required files:** `hooks/auto-review.sh` (heredoc fix + wrapper), `hooks/pre-bash.sh` (wrapper), `hooks/pre-write.sh` (wrapper), `tests/runtime/policies/test_write_adapter.py` (exit code assertion update)
- **Forbidden touch points:** `runtime/core/` (W-ENFORCE-1/2 scope), `hooks/lib/hook-safety.sh` (W-ENFORCE-3 scope, already landed), `settings.json` (no registration changes)
- **Expected state authorities touched:** None (hooks are stateless adapters; the wrapper only adds crash recovery)

#### Wave Structure

```
Wave 1: W-ENFORCE-1, W-ENFORCE-2, W-ENFORCE-3  (independent, max width 3)
Wave 2: W-ENFORCE-4                              (depends on W-ENFORCE-3)
```

**Critical path:** W-ENFORCE-3 -> W-ENFORCE-4 (safety wrapper must exist
before hooks can integrate it).

W-ENFORCE-1 and W-ENFORCE-2 are fully independent of each other and of
the shell work. They can proceed in parallel with W-ENFORCE-3.

#### Risk Assessment

| Gap | Severity | Fix | Work Item |
|---|---|---|---|
| Gap 1: `bash_git_who` regex too narrow | CRITICAL | Replace regex with `classify_git_op()` call; expand classifier to cover worktree remove, branch -d/-D, clean | W-ENFORCE-1 |
| Gap 2: Role-blind lease resolution | CRITICAL | Validate role alignment before assigning worktree_path-matched lease; discard lease when actor_role is empty | W-ENFORCE-2 |
| Gap 3: auto-review.sh heredoc crash | HIGH | Add heredoc check before recursing in `analyze_substitutions()`; wrap in `_run_fail_closed` | W-ENFORCE-4 |
| Gap 4: `set -euo pipefail` defeats fail-closed | HIGH | Reusable `_run_fail_closed` wrapper catches any crash -> deny + observatory event + exit 0 | W-ENFORCE-3, W-ENFORCE-4 |

#### File-Level Change Summary

| File | Wave | Change Type |
|------|------|-------------|
| `runtime/core/leases.py` | W-ENFORCE-1 | Modify: expand `classify_git_op()` with worktree remove, branch -d/-D, clean patterns |
| `runtime/core/policies/bash_git_who.py` | W-ENFORCE-1 | Modify: replace `_GIT_OP_RE` with `classify_git_op()` call |
| `hooks/context-lib.sh` | W-ENFORCE-1 | Modify: expand bash `classify_git_op()` with matching patterns |
| `tests/runtime/policies/test_bash_git_who.py` | W-ENFORCE-1 | Modify: add test cases for new git ops |
| `tests/scenarios/test-auto-review.sh` | W-ENFORCE-1 | Modify: extend Group 7 with parity tests for new classifier patterns |
| `runtime/core/policy_engine.py` | W-ENFORCE-2 | Modify: role-scoped lease resolution in `build_context()` |
| `tests/runtime/test_policy_engine.py` | W-ENFORCE-2 | Modify: add role-scoped lease tests |
| `hooks/lib/hook-safety.sh` | W-ENFORCE-3 | NEW: reusable fail-closed wrapper |
| `tests/scenarios/test-hook-safety.sh` | W-ENFORCE-3 | NEW: wrapper unit tests |
| `hooks/auto-review.sh` | W-ENFORCE-4 | Modify: heredoc fix + safety wrapper |
| `hooks/pre-bash.sh` | W-ENFORCE-4 | Modify: safety wrapper integration |
| `hooks/pre-write.sh` | W-ENFORCE-4 | Modify: safety wrapper integration |
| `tests/scenarios/test-auto-review.sh` | W-ENFORCE-4 | Modify: add heredoc test case |
| `tests/runtime/policies/test_write_adapter.py` | W-ENFORCE-4 | Modify: update exit code assertions (!=0 to ==0) |

#### Addendum: Post-Landing RCA Findings (2026-04-07)

After the four W-ENFORCE waves landed, a follow-up RCA on the orchestrator
write that escaped to main (`stop-review-gate-hook.mjs`) identified four
additional gaps in the write-side enforcement chain. These are tracked as
ENFORCE-RCA-6 through ENFORCE-RCA-9. Each is a separate, narrow work item
that ships independently. The first one — W-ENFORCE-RCA-6 — is also the
end-to-end smoke test of the post-W-GWT-3 dispatch chain
(`planner -> guardian(provision) -> implementer -> tester -> guardian(merge)`),
which is why it ships before the others.

##### W-ENFORCE-RCA-6: Add `.mjs/.cjs/.mts/.cts` to SOURCE_EXTENSIONS

- **GitHub issue:** #27
- **Decision:** DEC-SOURCEEXT-001
- **Weight:** S (8 lines source change + ~30 lines test)
- **Gate:** review (Guardian merge after tester PASS)
- **Deps:** none
- **Wave:** standalone (Wave 1 of the post-RCA addendum series)
- **Worktree:** Guardian-provisioned, branch `feature/enforce-rca-6-source-ext`
- **Critical context:** This is Fix 2 of a four-fix campaign. It is
  intentionally first because (a) it is a 2-line widening with clear blast
  radius, (b) it lets us exercise the full dispatch chain as a smoke test,
  and (c) the other fixes depend on dispatch working.

**Problem statement.** Every write-side WHO policy
(`branch_guard`, `write_who`, `doc_gate`, `plan_guard`, `test_gate_pretool`,
`mock_gate`, `enforcement_gap`) classifies write targets via
`runtime.core.policy_utils.is_source_file()`. The classifier reads
`SOURCE_EXTENSIONS`, which currently lists `js, jsx, ts, tsx` but NOT the
modern ESM/CJS/TS-module variants `mjs, cjs, mts, cts`. Result: a Write to
any `.mjs/.cjs/.mts/.cts` file falls into the catch-all `default: allow`
policy regardless of branch, role, lease, or scope. This is the single most
load-bearing gap in the post-W-ENFORCE write-side chain. Verified by direct
`cc-policy evaluate` call against
`plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs`
on main: returns `{action: allow, policy_name: default}` instead of the
expected `{action: deny, policy_name: branch_guard}`.

**Goal.** `is_source_file()` (Python and shell) recognizes all four modern
JS module variants. The reproduction command flips from `allow/default` to
`deny/branch_guard`. No other behavior changes.

**Non-goals.**
- NOT touching `hooks/check-implementer.sh:68`, which carries its own
  hard-coded source-extension regex. That is a third authority and unifying
  it into the shared helper is a separate refactor — tracked as ENFORCE-RCA-9.
- NOT bundling ENFORCE-RCA-7, ENFORCE-RCA-8, or any #26-extension scoping
  work. Each gets its own dispatch chain.
- NOT touching any other policy file, hook, dispatch engine, or settings.json.
- NOT modifying any of the 7 dirty files currently on main (the implementer
  works in a Guardian-provisioned worktree branched from the latest main HEAD).

**State authorities touched.**
- `runtime/core/policy_utils.py:SOURCE_EXTENSIONS` (Python, authoritative)
- `hooks/context-lib.sh:SOURCE_EXTENSIONS` (shell mirror, must stay in sync
  per the DEC-PE-W2-* parity pattern)
- No runtime state, no DB writes, no event emission. `is_source_file` is a
  pure classifier.

**Adjacent components that inherit the fix automatically (no changes
needed).** `runtime/core/policies/write_who.py`, `write_branch.py`
(branch_guard), `write_doc_gate.py`, `write_plan_guard.py`,
`write_test_gate.py`, `write_mock_gate.py`, `write_enforcement_gap.py`. All
of these call `is_source_file()` and inherit the new extensions.

**Evaluation Contract (executed verbatim by the tester before
`ready_for_guardian`).**

1. `runtime.core.policy_utils.is_source_file("x.mjs")` returns `True`.
   Verified by a new unit test in `tests/runtime/test_policy_utils.py`.
2. `runtime.core.policy_utils.is_source_file("x.cjs")`,
   `runtime.core.policy_utils.is_source_file("x.mts")`, and
   `runtime.core.policy_utils.is_source_file("x.cts")` all return `True`.
   Verified by parametrized or per-extension unit tests in the same file.
3. The shell function `is_source_file` in `hooks/context-lib.sh` matches
   `.mjs/.cjs/.mts/.cts`. Verified by a scenario test under
   `tests/scenarios/` that sources `context-lib.sh` and asserts the function
   returns success (exit 0) for each extension.
4. Direct `cc-policy evaluate` call with `tool_input.file_path` pointing at
   the `.mjs` fixture on main returns
   `{"action":"deny","policy_name":"branch_guard"}` (currently returns
   `{"action":"allow","policy_name":"default"}`). The exact reproduction
   command is in the section below.
5. The full Python test suite (`pytest tests/`) and the shell scenario
   suite both pass with zero regressions versus the head SHA the implementer
   started from.
6. No behavior change for any extension NOT in `{mjs, cjs, mts, cts}`. The
   existing `test_is_source_file_all_extensions` test must still pass
   unmodified, and all existing `is_source_file_*` cases must still pass.

**Forbidden shortcuts.**
- Do NOT add a wildcard match (e.g., `.*js$`) — extensions must be
  enumerated to keep the deny set explicit and auditable.
- Do NOT add the extensions only to the Python side. The shell mirror is
  load-bearing for any hook that runs before the Python policy engine
  (e.g., the legacy enforcement-gap detector path).
- Do NOT touch `check-implementer.sh:68`. If the implementer feels tempted,
  STOP and escalate — that is ENFORCE-RCA-9.
- Do NOT silently fix any other divergence found between the two
  SOURCE_EXTENSIONS lists. If divergence exists outside the four extensions,
  flag it in the implementation report and leave it for a follow-up.
- Do NOT update `runtime/core/policy_utils.py` line 74 comment to mention a
  new line number that does not match the actual shell file location after
  the edit. Re-verify the cross-reference comment after editing both files.

**Ready-for-guardian definition.** All six Evaluation Contract checks pass
on a single, named head SHA inside the implementer's worktree, and the
tester has captured (a) raw `pytest tests/runtime/test_policy_utils.py -v`
output showing the four new tests passing, (b) raw output of the new
scenario test, (c) raw output of the reproduction command BEFORE the fix
on the worktree's parent SHA returning `allow/default` and AFTER the fix on
the worktree HEAD returning `deny/branch_guard`, and (d) raw `pytest tests/`
exit-0 output. The tester then sets `ready_for_guardian` via
`cc-policy workflow ready-set`. Guardian merges after SHA-match verification.

**Scope Manifest (the orchestrator must write this to runtime via
`cc-policy workflow scope-set` BEFORE dispatching the implementer).**

Allowed files (the implementer may read or write only these):
- `runtime/core/policy_utils.py`
- `hooks/context-lib.sh`
- `tests/runtime/test_policy_utils.py`
- `tests/scenarios/test-source-extensions.sh` (NEW; see test plan below)

Required files (all four must change; otherwise the work is incomplete):
- `runtime/core/policy_utils.py` — add 4 entries to `SOURCE_EXTENSIONS`
  frozenset (lines 77-100). Update the cross-reference comment at line 74
  to match the post-edit `hooks/context-lib.sh` line if it shifts.
- `hooks/context-lib.sh` — add 4 entries to the
  `SOURCE_EXTENSIONS='ts|tsx|...'` pipe-delimited string at line 164.
- `tests/runtime/test_policy_utils.py` — add 4 new unit tests
  (one per extension) plus an explicit assertion that `mjs, cjs, mts, cts`
  are all members of `SOURCE_EXTENSIONS`.
- `tests/scenarios/test-source-extensions.sh` — NEW scenario test that
  sources `hooks/context-lib.sh`, calls `is_source_file` against each of
  the four extensions, asserts success, then runs the reproduction command
  against a fixture `.mjs` path and asserts `deny/branch_guard`.

Forbidden touch points (any modification triggers immediate scope violation
and tester rejection):
- `settings.json`
- Any file under `runtime/core/policies/`
- Any other file under `runtime/core/`
- Any other file under `hooks/`
- `hooks/check-implementer.sh` (explicitly — this is ENFORCE-RCA-9)
- Any file under `runtime/core/dispatch/` or `runtime/cli.py`
- Any of the 7 currently-dirty files on main (`MASTER_PLAN.md`,
  `plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs`,
  `settings.json`, `runtime/cc_state.db`, `traces/`,
  `hooks/block-worktree-create.sh`)

Expected state authorities touched: NONE at runtime. Source-only edits to
the SOURCE_EXTENSIONS classifier sets.

**Test plan (concrete, executable).**

1. *Extend `tests/runtime/test_policy_utils.py`.* Add four new tests
   immediately after `test_is_source_file_sh` (line 59), before
   `test_is_source_file_json_false`. Use the existing one-liner pattern:

   ```python
   def test_is_source_file_mjs():
       assert is_source_file("module.mjs") is True


   def test_is_source_file_cjs():
       assert is_source_file("legacy.cjs") is True


   def test_is_source_file_mts():
       assert is_source_file("typed.mts") is True


   def test_is_source_file_cts():
       assert is_source_file("typed.cts") is True
   ```

   The existing `test_is_source_file_all_extensions` test (line 66) iterates
   over `SOURCE_EXTENSIONS` — it will pick up the new entries automatically
   and provides the parametric coverage. No edit to that test is needed.

2. *Create `tests/scenarios/test-source-extensions.sh`* (NEW). Pattern after
   the existing scenario test conventions in that directory. Contents
   (paraphrased — the implementer writes the actual file):

   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
   source "$PROJECT_ROOT/hooks/context-lib.sh"

   # Phase 1: shell mirror parity for each extension
   for ext in mjs cjs mts cts; do
       if ! is_source_file "fixture.$ext"; then
           echo "FAIL: shell is_source_file rejected .$ext" >&2
           exit 1
       fi
   done

   # Phase 2: end-to-end policy reproduction — must return deny/branch_guard
   FIXTURE="$PROJECT_ROOT/plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs"
   RESULT=$(jq -n --arg path "$FIXTURE" \
       '{"event_type":"Write","tool_name":"Write","tool_input":{"file_path":$path},"cwd":"'"$PROJECT_ROOT"'","actor_role":"","actor_id":""}' \
       | python3 "$PROJECT_ROOT/runtime/cli.py" evaluate \
       | jq -r '.action + "/" + .policy_name')

   if [[ "$RESULT" != "deny/branch_guard" ]]; then
       echo "FAIL: expected deny/branch_guard, got $RESULT" >&2
       exit 1
   fi
   echo "PASS: source-extension scenario"
   ```

   The fixture file `stop-review-gate-hook.mjs` already exists on main
   (it is one of the dirty files) and the test only reads its path — no
   write occurs, so the dirty-file constraint is not violated. If the
   fixture is committed/cleaned before the test runs, replace the path
   with any other `.mjs` file path that exists in the worktree (e.g.,
   `tests/scenarios/fixtures/example.mjs` if such a fixture exists, or
   create one inside `tests/scenarios/fixtures/` — that path is allowed
   under the test scope).

3. *Run the suite.* Inside the worktree:
   ```bash
   pytest tests/runtime/test_policy_utils.py -v
   pytest tests/
   bash tests/scenarios/test-source-extensions.sh
   ```
   All three must exit 0. The tester captures and reports raw stdout for
   each.

**Reproduction command (canonical, runs identically before and after the
fix to prove the flip).**

```bash
cd /Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork
jq -n --arg path "$PWD/plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs" \
  '{"event_type":"Write","tool_name":"Write","tool_input":{"file_path":$path},"cwd":"'"$PWD"'","actor_role":"","actor_id":""}' \
| python3 runtime/cli.py evaluate | jq '{action, policy_name}'
```

- Expected on the parent SHA (before the fix):
  `{"action":"allow","policy_name":"default"}`
- Expected on the worktree HEAD (after the fix):
  `{"action":"deny","policy_name":"branch_guard"}`

The Planner has already executed this command on `main` at HEAD `11e4fcd`
and confirmed the `allow/default` result, so the BEFORE state is documented
at plan time. The implementer must re-run it from the worktree branch
point and from the post-fix worktree HEAD to capture the matched flip pair.

**Risk assessment.**

| Risk | Likelihood | Mitigation |
|---|---|---|
| Implementer touches `check-implementer.sh` "while we're here" | Medium | Forbidden in Scope Manifest; explicit STOP-and-escalate instruction; tester rejects on scope violation |
| Implementer adds wildcard regex instead of enumerated extensions | Low | Forbidden in Evaluation Contract; tester rejects |
| Python and shell lists drift (only one updated) | Medium | Required Files lists both; scenario test asserts shell side; unit test asserts Python side; both must be green |
| Reproduction fixture file moves/disappears | Low | Test plan documents fallback to a `tests/scenarios/fixtures/` path |
| Some other policy ALSO denies before `branch_guard` and the assertion fails on `deny/<other_policy>` | Low | If the assertion fails with `deny/<other>` instead of `allow/default`, that is still a SUCCESS for the underlying intent — flag as a gap in the test, not in the fix; tester decides whether to relax assertion to `action == deny` or to investigate which policy fired first |

**Wave structure.**

Single wave, single work item, single implementer dispatch.

```
Wave 1: W-ENFORCE-RCA-6  (independent, no deps)
```

**Dispatch chain (this is the smoke test for W-GWT-3 dispatch).**

1. Orchestrator writes the Scope Manifest to runtime via
   `cc-policy workflow scope-set --workflow-id enforce-rca-6 --allowed
   runtime/core/policy_utils.py,hooks/context-lib.sh,tests/runtime/test_policy_utils.py,tests/scenarios/test-source-extensions.sh
   --forbidden settings.json,hooks/check-implementer.sh`
2. Orchestrator dispatches Guardian (provision) with
   `workflow_id=enforce-rca-6, branch=feature/enforce-rca-6-source-ext`.
3. Guardian provisions the worktree and issues the implementer lease.
4. Orchestrator dispatches the implementer into the worktree with the full
   Evaluation Contract and Scope Manifest in the dispatch context.
5. Implementer makes the four edits, runs the reproduction + test commands
   inside the worktree, and reports completion with the head SHA.
6. Tester evaluates against the Evaluation Contract, captures raw output,
   and sets `ready_for_guardian` via `cc-policy workflow ready-set` if all
   six checks pass.
7. Guardian merges (commit + merge to main) after SHA-match verification.

If any step in the chain fails or produces an `AUTO_DISPATCH` directive
that is not honored, that is a smoke-test failure for W-GWT-3 itself and
must be reported to the user before resuming the four-fix campaign.

**File-level change summary.**

| File | Change Type | Lines |
|---|---|---|
| `runtime/core/policy_utils.py` | Modify: 4 entries added to `SOURCE_EXTENSIONS` frozenset | +4 |
| `hooks/context-lib.sh` | Modify: 4 entries appended to `SOURCE_EXTENSIONS` pipe string | +0/~1 |
| `tests/runtime/test_policy_utils.py` | Modify: 4 new one-line tests | +12 |
| `tests/scenarios/test-source-extensions.sh` | NEW: shell scenario test | +~30 |

Total: ~46 lines net. No file reaches the 50-line `@decision` annotation
threshold, but `DEC-SOURCEEXT-001` is pre-assigned and may be referenced in
either source file's commit message regardless.

**Open questions.** None. The plan is executable as-is. If the implementer
or tester finds an unstated ambiguity, it must be escalated to the user
rather than resolved silently.

##### W-ENFORCE-RCA-11: Restore `hookEventName` in `cc-policy evaluate` JSON output

- **GitHub issue:** TBD (file before dispatch)
- **Decision:** DEC-EVAL-HOOKOUT-001
- **Weight:** S (3 dict-literal edits in one Python function + 1 test
  helper extension; ~15 net source lines, ~10 net test lines)
- **Gate:** review (Guardian merge after tester PASS)
- **Deps:** none. Specifically NOT bundled with W-ENFORCE-RCA-6 (already
  landed at `4a3ebb5`) and NOT bundled with the future ENFORCE-RCA-12
  (CLI self-privilege via `marker set` and `lease issue-for-dispatch`,
  out of scope for this work item).
- **Wave:** standalone (Wave 2 of the post-RCA addendum series; ships
  immediately, single dispatch chain)
- **Worktree:** Guardian-provisioned, branch
  `feature/enforce-rca-11-hook-event-name`
- **Critical context:** This is the empirically-verified root cause of the
  multi-day "orchestrators bypassing dispatch" complaint. Latent for 4+
  days since `3be693f` (PE-W1, 2026-04-03). The Planner has already
  drafted, applied, and tested the exact patch in main's working tree
  (uncommitted, present in the orchestrator's local `runtime/cli.py` only)
  and confirmed `git commit` is now correctly denied by `bash_git_who`
  with the full pytest suite at `1441 passed, 1 xpassed, 0 failures`.
  This work item exists to land that patch through the canonical dispatch
  chain, lock the contract in with a regression test, and ship the
  decision-log entry — NOT to re-derive the fix.

**Problem statement.** `runtime/cli.py:_handle_evaluate` builds a
`hookSpecificOutput` dict and returns it as the JSON body of every
`cc-policy evaluate` call. The Claude Code hook output contract documented
at `hooks/HOOKS.md:28-34` requires that this dict include
`"hookEventName": "PreToolUse"` as a peer of `permissionDecision`. Commit
`3be693f` (PE-W1, 2026-04-03) introduced `_handle_evaluate` without that
field. As a result, every deny returned by `branch_guard`, `write_who`,
`bash_main_sacred`, `bash_git_who`, `doc_gate`, `plan_guard`,
`test_gate_pretool`, `mock_gate`, and `enforcement_gap` via the
`cc-policy evaluate` path is silently discarded by Claude Code's harness:
the policy-engine metric increments, the deny event is logged, and the
underlying tool call executes anyway. The defect has been latent for four
days and is the root cause of the orchestrator bypass complaint. Verified
in two ways: (a) by direct `cc-policy evaluate` call against
`tool_name=Bash, command="git commit --allow-empty -m test"` on main as
orchestrator, which returns `action=deny, blockingHook=bash_git_who` in
the JSON body but Claude Code still executes the commit; (b) by the
parallel Codex rescue probe (session `019d69bd-fcc6-7012-b435-9d6398fc0ad1`)
which returned
`VERDICT: JSON shape MISSING hookEventName at runtime/cli.py:1298`
within 53 seconds. The crash-deny path at `hooks/lib/hook-safety.sh:56`
is the only deny shape in the system that has been firing correctly,
because it constructs the JSON literally with `hookEventName` baked in.
The `process-stop` handler at `runtime/cli.py:533` also includes the
field — confirming the omission in `_handle_evaluate` is a localized
regression, not a misunderstanding of the contract.

**Goal.** `runtime/cli.py:_handle_evaluate` emits
`"hookEventName": "PreToolUse"` in all three `hookSpecificOutput` branches
(`deny`, `feedback`, `allow`). The contract is locked in by extending the
existing parametrized scenario tests in
`tests/runtime/policies/test_hook_scenarios.py` to assert the field's
presence on every deny payload, so any future regression fails CI rather
than silently disabling enforcement. The decision is recorded as
`DEC-EVAL-HOOKOUT-001`. The fix is delivered through the canonical
`planner -> guardian(provision) -> implementer -> tester -> guardian(merge)`
dispatch chain on the post-W-GWT-3 system.

**Non-goals.**
- NOT touching `hooks/pre-bash.sh`, `hooks/pre-write.sh`, or any other
  caller of `cc-policy evaluate`. They print this function's stdout
  verbatim and inherit the fix automatically.
- NOT touching any policy file under `runtime/core/policies/`. The deny
  decisions are already correct; only the JSON envelope was wrong.
- NOT touching `hooks/lib/hook-safety.sh`. Its crash-deny path already
  includes `hookEventName` as a literal string and is the only deny shape
  that has been working correctly; do not "harmonize" it.
- NOT touching `runtime/cli.py:533` (the `process-stop` handler). It
  already includes `hookEventName: "SubagentStop"` and is correct as-is.
- NOT bundling W-ENFORCE-RCA-6 (`.mjs/.cjs/.mts/.cts` source extensions),
  which already landed at `4a3ebb5`.
- NOT bundling the future W-ENFORCE-RCA-12 (CLI self-privilege via
  `marker set` and `lease issue-for-dispatch`). That is a separate work
  item the Planner will file after W-ENFORCE-RCA-11 lands.
- NOT touching MASTER_PLAN.md, settings.json, or any of the currently
  dirty files on main beyond what is required for the source + test fix.
  In particular, the implementer must NOT amend the planner's addendum
  while in the worktree — MASTER_PLAN.md edits remain a planner-only
  authority.
- NOT introducing a new policy, a new hook, a new dispatch path, or a
  new architectural surface. This is a single-function correctness fix.

**State authorities touched.**
- `runtime/cli.py:_handle_evaluate` (the canonical Python authority for
  shaping the `cc-policy evaluate` stdout envelope; no DB writes, no
  runtime state mutation, pure JSON construction).
- No SQLite tables, no event emission, no marker writes. The function
  reads `decision.action`, `decision.reason`, and `decision.policy_name`
  off an already-built `PolicyDecision` and shapes the response. The fix
  changes only the shape, not the underlying decision.

**Adjacent components that inherit the fix automatically (no changes
needed but the implementer must not break them).**
- `hooks/pre-bash.sh:141` — calls `cc-policy evaluate` and prints the
  stdout verbatim to Claude Code. After the fix, every deny/allow/feedback
  it relays will carry `hookEventName` and Claude Code will honor the
  permissionDecision.
- `hooks/pre-write.sh:122` — same caller pattern for Write/Edit. Same
  inherited fix.
- `hooks/lib/hook-safety.sh:56` — already correct; do not touch.
- `runtime/cli.py:533` (the `process-stop` handler) — already correct;
  do not touch.

**Evaluation Contract (executed verbatim by the tester before
`ready_for_guardian`; copied from the planner brief).**

1. `runtime/cli.py:_handle_evaluate` emits
   `hookEventName: "PreToolUse"` in all three `hookSpecificOutput`
   branches (deny, feedback, allow).
2. Direct `cc-policy evaluate` call with
   `event_type=PreToolUse, tool_name=Bash,
   tool_input.command="git commit --allow-empty -m test"`
   on main, `actor_role=""` returns a JSON whose
   `.hookSpecificOutput.hookEventName == "PreToolUse"`.
3. Live canary `git commit --allow-empty -m test` on main as orchestrator
   (no lease, no marker) is denied by `pre-bash.sh` with
   `blockingHook: bash_git_who`. Tester pastes the exact stderr.
4. `python3 -m pytest tests/` returns `1441 passed, 1 xpassed` or better.
5. New scenario test OR extension of
   `tests/runtime/policies/test_hook_scenarios.py` that asserts
   `hookEventName == "PreToolUse"` in deny responses, so this contract
   is locked in against regressions.
6. `DEC-EVAL-HOOKOUT-001` annotation is present inline in `cli.py`
   (already drafted at lines 1297-1304 of the working-tree patch),
   with rationale pointing at `hooks/HOOKS.md:28-34` contract.

**Forbidden shortcuts.**
- Do NOT add `hookEventName` only to the `deny` branch. The Claude Code
  hook contract requires it on every `hookSpecificOutput` dict regardless
  of decision; the `allow` and `feedback` branches must carry it too,
  and the regression test must cover at least one allow case.
- Do NOT add a "fallback" that injects `hookEventName` in the calling
  hook script (`pre-bash.sh`, `pre-write.sh`). That creates a second
  authority for the JSON envelope shape. The Python function is the
  single source of truth. Any caller-side patching is forbidden.
- Do NOT change the `permissionDecision`, `permissionDecisionReason`, or
  `blockingHook` keys. The deny shape is otherwise correct and downstream
  observers (auto-review, observatory, scenario tests) parse those exact
  names.
- Do NOT silently fix any other JSON-shape divergence found in
  neighboring functions while in the worktree. If divergence exists,
  flag it in the implementation report and leave it for a follow-up
  work item.
- Do NOT bundle the future W-ENFORCE-RCA-12 self-privilege fix. That is
  a separate dispatch chain.
- Do NOT skip the live canary in step 3 of the Evaluation Contract. The
  pytest suite alone is necessary but not sufficient — the canary is the
  end-to-end proof that Claude Code honors the deny.

**Ready-for-guardian definition.** All six Evaluation Contract checks
pass on a single, named head SHA inside the implementer's worktree, and
the tester has captured (a) raw `pytest tests/runtime/policies/test_hook_scenarios.py -v`
output showing the new `hookEventName` assertion passing, (b) raw output
of the direct `cc-policy evaluate` reproduction in step 2 showing the
field present, (c) raw stderr of the live canary `git commit` deny in
step 3, (d) raw `python3 -m pytest tests/` exit-0 output with the
`1441 passed, 1 xpassed` (or better) summary line. The tester then sets
`ready_for_guardian` via `cc-policy workflow ready-set`. Guardian merges
after SHA-match verification.

**Scope Manifest (the orchestrator MUST write this to runtime via
`cc-policy workflow scope-set` BEFORE dispatching the implementer).**

Allowed files (the implementer may read or write only these):
- `runtime/cli.py`
- `tests/runtime/policies/test_hook_scenarios.py`

Required files (both must change; otherwise the work is incomplete):
- `runtime/cli.py` — replace the three `hook_output = {...}` dict
  literals in `_handle_evaluate` (current HEAD lines 1297-1305) so each
  branch carries `"hookEventName": "PreToolUse"` as the first key. Add
  the `ENFORCE-RCA-11 / DEC-EVAL-HOOKOUT-001` rationale comment block
  immediately above the `if decision.action == "deny":` line, citing
  `hooks/HOOKS.md` lines 28-34 as the contract source.
- `tests/runtime/policies/test_hook_scenarios.py` — extend the
  `_assert_hook_result` helper (current lines 193-217) so every payload
  parsed via `_parse_stdout` is checked for
  `payload["hookSpecificOutput"]["hookEventName"] == "PreToolUse"` on
  both deny and non-deny paths whenever a payload exists. Equivalently,
  add a small dedicated helper `_hook_event_name(payload)` and assert
  on it inside `_assert_hook_result`. The implementer chooses the cleaner
  shape but the assertion must run on every parametrized case in
  `test_pre_write_hook_cases` and `test_pre_bash_hook_cases` (or
  whichever scenario tests parse the JSON envelope).

Forbidden touch points (any modification triggers immediate scope
violation and tester rejection):
- `hooks/pre-bash.sh` (caller; inherits the fix)
- `hooks/pre-write.sh` (caller; inherits the fix)
- `hooks/lib/hook-safety.sh` (already correct)
- Any file under `runtime/core/policies/`
- Any other file under `runtime/core/`
- Any other file under `hooks/`
- `hooks/check-implementer.sh` (out of scope; ENFORCE-RCA-9)
- `hooks/HOOKS.md` (the contract source — read-only reference; do NOT
  edit)
- `MASTER_PLAN.md` (planner-only authority)
- `settings.json`
- `runtime/cc_state.db`
- Any file under `traces/`
- Any of the currently-dirty files on main
  (`MASTER_PLAN.md`,
  `plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs`,
  `settings.json`, `runtime/cc_state.db`,
  `runtime/dispatch-debug.jsonl`, `traces/`,
  `hooks/block-worktree-create.sh`)
- `runtime/cli.py:533` (the `process-stop` handler — already correct)

Expected state authorities touched: NONE at runtime. Source-only edits
to the JSON envelope shape and the scenario test helper.

**Critical pre-implementation note (must be relayed verbatim in the
dispatch context).** The orchestrator's main working tree currently
contains the uncommitted `cli.py` patch — that is what allows enforcement
to fire correctly in the planner's session right now. Guardian will
provision a fresh worktree from main HEAD (`929f8dc6` at plan time),
which does NOT contain the fix. Therefore the implementer's own
`pre-bash.sh` and `pre-write.sh` chain inside the new worktree will
NOT enforce correctly until the patch is in place. The implementer
MUST apply the `_handle_evaluate` patch as the FIRST file edit in the
worktree, BEFORE running any test command, BEFORE any other Read/Write
exploration, and BEFORE any pytest invocation. Once the three dict
literals carry `hookEventName`, the worktree's own enforcement chain
becomes self-consistent and the rest of the test plan is safe to
execute. Failure to apply the patch first means the implementer's own
session may execute commands that should have been blocked, producing
false-positive completion signals.

**Test plan (concrete, executable).**

1. *Apply the source patch FIRST.* Before any other action in the
   worktree, edit `runtime/cli.py` to replace the three current
   `hook_output = {...}` dict literals in `_handle_evaluate` with the
   versions below. This is required first so the worktree's own
   enforcement chain is self-consistent for the rest of the test plan.

   Verbatim source patch (replace the existing block at the current
   HEAD location of `_handle_evaluate` after the `finally: conn.close()`
   line):

   ```python
   # Build hookSpecificOutput per Claude hook contract.
   # ENFORCE-RCA-11 / DEC-EVAL-HOOKOUT-001: hookEventName is REQUIRED by
   # the Claude Code hook output contract documented at
   # hooks/HOOKS.md:28-34. Without it, Claude Code silently discards the
   # permissionDecision and the underlying tool call executes unblocked.
   # PE-W1 (3be693f, 2026-04-03) created this dict without hookEventName,
   # so every deny emitted by branch_guard / write_who / bash_main_sacred
   # / bash_git_who / doc_gate / plan_guard / test_gate_pretool /
   # mock_gate / enforcement_gap via the cc-policy evaluate path was a
   # no-op for four days — the metric fired but the harness never honored
   # the deny. Setting it to "PreToolUse" matches the spec.
   if decision.action == "deny":
       hook_output = {
           "hookEventName": "PreToolUse",
           "permissionDecision": "deny",
           "permissionDecisionReason": decision.reason,
           "blockingHook": decision.policy_name,
       }
   elif decision.action == "feedback":
       hook_output = {
           "hookEventName": "PreToolUse",
           "additionalContext": decision.reason,
       }
   else:
       hook_output = {
           "hookEventName": "PreToolUse",
           "permissionDecision": "allow",
       }
   ```

2. *Extend the regression test.* In
   `tests/runtime/policies/test_hook_scenarios.py`, locate the
   `_assert_hook_result` helper (currently lines 193-217) and add an
   assertion that every parsed `hookSpecificOutput` payload carries
   `hookEventName == "PreToolUse"`. The minimal patch (paraphrased —
   the implementer writes the actual code):

   ```python
   def _hook_event_name(payload: dict | None) -> str | None:
       if payload is None:
           return None
       return payload.get("hookSpecificOutput", {}).get("hookEventName")


   def _assert_hook_result(
       result: subprocess.CompletedProcess[str],
       *,
       expected_decision: str,
       reason_substring: str | None = None,
   ) -> None:
       assert result.returncode == 0, (
           f"hook exited with {result.returncode}\nstdout={result.stdout!r}\nstderr={result.stderr!r}"
       )

       payload = _parse_stdout(result.stdout)
       decision = _decision(payload)

       # ENFORCE-RCA-11 / DEC-EVAL-HOOKOUT-001: every hookSpecificOutput
       # payload must include hookEventName per the Claude Code hook
       # output contract (hooks/HOOKS.md:28-34). Locking the contract in
       # at the assertion layer prevents any future regression of the
       # PE-W1 defect.
       if payload is not None and "hookSpecificOutput" in payload:
           assert _hook_event_name(payload) == "PreToolUse", (
               f"hookSpecificOutput missing hookEventName=PreToolUse: payload={payload!r}"
           )

       if expected_decision == "deny":
           assert payload is not None, "deny path must emit hookSpecificOutput JSON"
           assert decision == "deny", f"expected deny, got {decision!r} payload={payload!r}"
           if reason_substring is not None:
               assert reason_substring in _reason(payload), (
                   f"deny reason missing {reason_substring!r}: {_reason(payload)!r}"
               )
           return

       assert decision != "deny", (
           f"expected non-deny path, got payload={payload!r}\nstderr={result.stderr!r}"
       )
   ```

   The assertion runs on every parametrized case in
   `test_pre_write_hook_cases` and the bash-side scenario tests
   automatically because they all flow through `_assert_hook_result`.
   No new parametrize entries are required, and no fixture data
   changes are required.

3. *Run the suites.* Inside the worktree, after step 1 and step 2:

   ```bash
   python3 -m pytest tests/runtime/policies/test_hook_scenarios.py -v
   python3 -m pytest tests/
   ```

   Both must exit 0. The first invocation must show the
   `_hook_event_name` assertion path executed in every parametrized
   case (visible in the verbose output as the parametrized case ids).
   The second must report `1441 passed, 1 xpassed` or better, matching
   the planner-confirmed baseline.

4. *Direct `cc-policy evaluate` reproduction (Evaluation Contract step 2).*
   From the worktree root, with no role marker set:

   ```bash
   jq -n '{
     "event_type":"PreToolUse",
     "tool_name":"Bash",
     "tool_input":{"command":"git commit --allow-empty -m test"},
     "cwd":"'"$PWD"'",
     "actor_role":"",
     "actor_id":""
   }' \
     | python3 runtime/cli.py evaluate \
     | jq '.hookSpecificOutput'
   ```

   Expected output:

   ```json
   {
     "hookEventName": "PreToolUse",
     "permissionDecision": "deny",
     "permissionDecisionReason": "<bash_git_who reason text>",
     "blockingHook": "bash_git_who"
   }
   ```

5. *Live canary (Evaluation Contract step 3).* From the orchestrator's
   own session on main (NOT inside the implementer's worktree — this
   step is the tester's end-to-end proof and runs after merge or as a
   pre-merge sanity check on a stash of the patch into main's working
   tree if necessary), with no lease and no role marker:

   ```bash
   git commit --allow-empty -m "ENFORCE-RCA-11 canary: must be denied"
   ```

   Expected: `pre-bash.sh` denies with stderr containing
   `blockingHook: bash_git_who` (or the equivalent rendered form). The
   tester pastes the raw stderr verbatim. If the commit succeeds, the
   fix is incomplete and the implementer must investigate before
   marking ready.

**Reproduction command (canonical, runs identically before and after
the fix to prove the flip).**

```bash
jq -n '{
  "event_type":"PreToolUse",
  "tool_name":"Bash",
  "tool_input":{"command":"git commit --allow-empty -m test"},
  "cwd":"'"$PWD"'",
  "actor_role":"",
  "actor_id":""
}' | python3 runtime/cli.py evaluate | jq '.hookSpecificOutput.hookEventName'
```

- Expected on the parent SHA (HEAD `929f8dc6`, before the fix): `null`
- Expected on the worktree HEAD (after the fix): `"PreToolUse"`

The Planner has executed the equivalent direct test on the
working-tree-patched main session and confirmed the post-fix flip plus
the full pytest baseline (`1441 passed, 1 xpassed, 0 failures`). The
implementer must re-run the reproduction from inside the worktree both
before applying the patch (to capture the BEFORE `null` result) and
after (to capture the AFTER `"PreToolUse"` result) so the tester can
report the matched flip pair.

**Risk assessment.**

| Risk | Likelihood | Mitigation |
|---|---|---|
| Implementer applies the patch but forgets to add the regression test | Medium | Required Files lists both files; tester rejects ready if the test file is unchanged |
| Implementer extends the test only for the deny path and not the allow path | Medium | The `_assert_hook_result` helper runs on every parametrized case, so adding the assertion at the helper layer covers both paths automatically; the test plan documents this explicitly |
| Implementer forgets to apply the source patch FIRST and runs pytest in a self-inconsistent worktree | Medium | Critical pre-implementation note in the dispatch context; tester verifies the implementer's reported file-edit order in the implementation report |
| Implementer "harmonizes" `hooks/lib/hook-safety.sh` or `runtime/cli.py:533` (process-stop) | Low | Forbidden in Scope Manifest; both are explicitly already-correct authorities |
| Implementer adds `hookEventName` only to the `deny` branch | Low | Evaluation Contract step 1 requires all three branches; tester rejects |
| Implementer touches `pre-bash.sh` or `pre-write.sh` to "double-check" the field at the caller | Low | Forbidden in Scope Manifest; the Python function is the single authority |
| Live canary (step 3) executes successfully despite the patch | Low | If the canary commits, the fix is provably incomplete; the tester must escalate, NOT mark ready |
| Implementer accidentally edits `MASTER_PLAN.md` while in the worktree | Low | Forbidden in Scope Manifest; planner-only authority |
| Future ENFORCE-RCA-12 (CLI self-privilege) accidentally bundled | Low | Non-goals list explicitly excludes it; planner files it as a separate work item after this lands |

**Wave structure.**

Single wave, single work item, single implementer dispatch.

```
Wave 2: W-ENFORCE-RCA-11  (independent of W-ENFORCE-RCA-6 which is
                           already landed at 4a3ebb5)
```

**Dispatch chain.**

1. Orchestrator writes the Scope Manifest to runtime via
   `cc-policy workflow scope-set --workflow-id enforce-rca-11
   --allowed runtime/cli.py,tests/runtime/policies/test_hook_scenarios.py
   --forbidden hooks/pre-bash.sh,hooks/pre-write.sh,hooks/lib/hook-safety.sh,hooks/HOOKS.md,MASTER_PLAN.md,settings.json,runtime/cc_state.db`
2. Orchestrator dispatches Guardian (provision) with
   `workflow_id=enforce-rca-11,
   branch=feature/enforce-rca-11-hook-event-name`. Guardian provisions
   a fresh worktree from main HEAD (`929f8dc6` at plan time, or
   whatever main HEAD is at provision time) and issues the implementer
   lease.
3. Orchestrator dispatches the implementer into the worktree with the
   full Evaluation Contract, the full Scope Manifest, the verbatim
   source patch, and the verbatim test extension above. The dispatch
   context MUST include the critical pre-implementation note that the
   implementer must apply the source patch as the FIRST file edit
   before any test invocation.
4. Implementer applies the patch, extends the test helper, runs the
   reproduction commands and the full pytest suite inside the worktree,
   captures all output, and reports completion with the head SHA.
5. Tester evaluates against the Evaluation Contract, runs the live
   canary, captures raw output, and sets `ready_for_guardian` via
   `cc-policy workflow ready-set` if all six checks pass.
6. Guardian merges (commit + merge to main) after SHA-match
   verification. Commit message MUST reference `ENFORCE-RCA-11` in the
   title and `DEC-EVAL-HOOKOUT-001` in the body.

If any step in the chain fails, the orchestrator must report the
failure verbatim to the user before retrying. Specifically: if the
implementer's pytest run reports fewer than 1441 passing tests, that
is a regression and the implementer must investigate before marking
complete.

**File-level change summary.**

| File | Change Type | Lines |
|---|---|---|
| `runtime/cli.py` | Modify: 3 dict-literal branches in `_handle_evaluate` get `hookEventName` key + 8-line rationale comment block | +~15 |
| `tests/runtime/policies/test_hook_scenarios.py` | Modify: add `_hook_event_name` helper + assertion in `_assert_hook_result` + rationale comment | +~10 |

Total: ~25 lines net. Neither file crosses any new `@decision`
threshold individually (cli.py is already a 2748-line file with
existing `@decision` annotations). `DEC-EVAL-HOOKOUT-001` is
pre-assigned and is referenced inline in the cli.py rationale comment
block AND must appear in the Guardian commit message body.

**Open questions.** None. The plan is executable as-is. The exact
source patch and test extension are inlined above. If the implementer
or tester finds an unstated ambiguity, it must be escalated to the
user rather than resolved silently.

##### W-ENFORCE-RCA-14: SubagentStop review path must be unconditional

- **GitHub issue:** TBD (file before dispatch)
- **Decision:** DEC-ENFORCE-REVIEW-GATE-002
- **Weight:** S (4-line logic change + inline DEC rationale comment block
  in one `.mjs` file; ~12 net source lines)
- **Gate:** review (Guardian merge after tester PASS)
- **Deps:** none. Specifically NOT bundled with W-ENFORCE-RCA-12 (CLI
  self-privilege via `marker set` and `lease issue-for-dispatch`, GitHub
  issue #31) or W-ENFORCE-RCA-13 (git regex greedy matching, GitHub
  issue #32). Each gets its own dispatch chain.
- **Wave:** standalone (Wave 3 of the post-RCA addendum series; ships
  immediately, single dispatch chain)
- **Worktree:** Guardian-provisioned, branch
  `feature/enforce-rca-14-review-gate-subagent-path` (or whatever the
  provision CLI derives from `--feature-name enforce-rca-14`; accept the
  derived name as authoritative — see RCA-11 precedent)

**Critical context.** Today's enforcement RCA campaign
(ENFORCE-RCA-6/7/8/10/11/12/13) landed and the Planner verified the full
dispatch chain end-to-end via the RCA-11 work item. During verification
the user noticed that the Codex stop-review gate — which was supposed to
run on every SubagentStop and write verdicts into the
`dispatch_engine` events table — was NOT firing. The Planner investigated
and confirmed:

1. `stop-review-gate-hook.mjs` is correctly wired into `settings.json` for
   all four SubagentStop matchers (planner, implementer, tester, guardian).
2. The hook correctly distinguishes SubagentStop from regular Stop via
   `const isSubagentStop = Boolean(input.agent_type)` at line 583.
3. When `isSubagentStop === true`, the SubagentStop branch (lines 613-646)
   correctly runs the Codex review, writes a `codex_stop_review` event via
   `emitCodexReviewEventSync(cwd, workflowId, verdict, reason)` at line
   622, and emits a `systemMessage` with the verdict.
4. `runtime/core/dispatch_engine.py:_check_codex_gate` (lines 406-445)
   consumes that event within a 60-second window and sets
   `codex_blocked=True` to suppress `AUTO_DISPATCH` if the verdict was
   `BLOCK`. The consumer is correct.
5. **The bug.** At `stop-review-gate-hook.mjs:591-596` there is an early
   return that bails out for BOTH the SubagentStop and regular Stop
   branches whenever `config.stopReviewGate === false`:

   ```js
   if (!config.stopReviewGate) {
     if (!isSubagentStop) { logNote(runningTaskNote); }
     return;
   }
   ```

   `config.stopReviewGate` is the user-facing toggle controlled via
   `codex-companion.mjs setup --enable-review-gate`. It defaults to false.
   When false (the default on every machine that has not run
   `codex setup --enable-review-gate`), the SubagentStop branch never
   runs, the `events` table stays empty, and `_check_codex_gate` silently
   always-allows because there is nothing to consume.

This is a latent defect that has been silently disabling one of the
dispatch-chain integrity gates for the entire post-RCA-11 verification
window. It is invisible to the user because the hook still fires at the
shell level, the Python policy engine still evaluates, and `AUTO_DISPATCH`
continues to work as expected — it just works *without* the Codex gate
doing any work. The events table silence is the only observable tell and
is not surfaced in the statusline or in the dispatch-debug JSONL.

**Problem statement.** The SubagentStop review path in
`stop-review-gate-hook.mjs` is incorrectly gated behind the user-facing
`config.stopReviewGate` flag. Because the flag defaults to false, the
path never runs on a default install, which means:

- `codex_stop_review` events never land in the `events` table.
- `dispatch_engine._check_codex_gate` never finds anything to consume and
  silently always-allows `AUTO_DISPATCH`.
- The dispatch-chain integrity gate that was supposed to catch a
  misbehaving subagent by blocking the next dispatch is a no-op.

The user's verbatim direction is that the SubagentStop review path is
enforcement infrastructure, not a user-facing convenience, and must run
unconditionally: *"The stop review from codex setup isn't the one we
want, we want it enforced at the stops and the subagent returns in our
own mechanism so make sure to understand that properly."* The
`config.stopReviewGate` flag retains its meaning for the user-facing
regular-Stop path only.

**Goal.** `stop-review-gate-hook.mjs` early-returns only when
`isSubagentStop === false && config.stopReviewGate === false`. Every
SubagentStop event runs through the review path regardless of the flag.
The user-facing regular-Stop path continues to require
`config.stopReviewGate === true` to run. The decision is recorded inline
in the hook as `DEC-ENFORCE-REVIEW-GATE-002` with a rationale comment
block that explains the split between dispatch-chain integrity
(SubagentStop, unconditional) and user-facing convenience (regular Stop,
opt-in).

**Non-goals.**
- NOT touching `runtime/core/dispatch_engine.py`. The consumer at
  `_check_codex_gate` is already correct; it just never had anything to
  consume. Inheriting this fix unblocks it automatically.
- NOT touching `runtime/cli.py`. The CLI's `events-emit` path is inherited
  and correct.
- NOT touching `settings.json`. The SubagentStop hook chain is already
  wired for all four matchers.
- NOT touching `codex-companion.mjs` setup code. The
  `--enable-review-gate` flag retains its semantics for the user-facing
  regular-Stop path. No CLI behavior change.
- NOT touching any `hooks/check-*.sh`, `hooks/post-task.sh`,
  `hooks/pre-bash.sh`, `hooks/pre-write.sh`, or any other shell hook. All
  are inherited.
- NOT touching any file under `runtime/core/policies/`. No policy change.
- NOT bundling W-ENFORCE-RCA-12 (CLI self-privilege, GitHub #31) or
  W-ENFORCE-RCA-13 (git regex greedy, GitHub #32). Each is its own
  dispatch chain.
- NOT introducing a new config flag, a new hook, a new policy, or a new
  dispatch path. This is a single-line logic flip with a rationale
  comment.
- NOT touching `MASTER_PLAN.md` from the worktree — planner-only
  authority.

**State authorities touched.**
- `plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs`
  (the sole source authority for the hook's early-return gate).
- No SQLite tables are modified directly by this patch. Indirectly, the
  `events` table will begin receiving `codex_stop_review` rows on every
  SubagentStop once the patch lands — that is the intended runtime
  observable and is the basis for Evaluation Contract step 3.

**Adjacent components that inherit the fix automatically (no changes
needed but the implementer must not break them).**
- `plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs:622`
  — `emitCodexReviewEventSync(cwd, workflowId, verdict, reason)` writes
  the event that feeds `dispatch_engine`. Inherited; do not modify.
- `runtime/core/dispatch_engine.py:406-445` — `_check_codex_gate` consumer
  that reads from the events table with a 60-second window. Inherited; do
  not modify.
- `runtime/core/dispatch_engine.py:321-326` — the call site that invokes
  `_check_codex_gate` after `auto_dispatch = True`. Inherited; do not
  modify.
- `settings.json` SubagentStop hook chain entries for planner,
  implementer, tester, and guardian. Inherited; do not modify.
- `codex-companion.mjs setup --enable-review-gate` — continues to toggle
  `config.stopReviewGate` for the user-facing regular-Stop path only.
  Semantic meaning shifts to "opt-in to user-facing Stop review"; no code
  change.

**Evaluation Contract (executed verbatim by the tester before
`ready_for_guardian`; copied from the user brief).**

1. After the patch,
   `plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs`
   early-returns only when
   `isSubagentStop === false && config.stopReviewGate === false`. Verify
   by reading the file and pasting the exact new lines.
2. When `config.stopReviewGate === false` AND `isSubagentStop === true`,
   the hook proceeds past line ~591 into the Guardian-landing check
   (line 600) and then into the `runStopReview` call (line 610). Verify
   by reading the file and tracing the control flow.
3. **Live end-to-end test.** Dispatch any subagent through the full
   chain. Verify a `codex_stop_review` event row appears in the `events`
   table via
   `cc-policy event query --type codex_stop_review --limit 1` with
   `created_at > <now - 120>`. The verdict may be `ALLOW` or `BLOCK` —
   we are testing that the mechanism FIRES, not any particular outcome.
   Tester pastes the raw CLI output.
4. `python3 -m pytest tests/` passes with `1441 passed, 1 xpassed` or
   better. This is a `.mjs` file not a Python file, so pytest does not
   exercise it directly, but we want to catch any unintended ripple.
5. `DEC-ENFORCE-REVIEW-GATE-002` annotation is present inline in the
   hook file as a rationale comment block immediately above the new
   conditional.

**Forbidden shortcuts.**
- Do NOT add a new config flag (e.g. `config.dispatchChainReviewGate`)
  to "make the split opt-in." The user's direction is explicit: the
  dispatch-chain path is unconditional. Adding a flag reintroduces the
  same silent-disable failure mode on any machine that does not set the
  new flag to true. Inline, hard-coded unconditional behavior is the
  only correct shape.
- Do NOT move the SubagentStop branch into a separate helper function
  "for clarity" and then gate the helper with the same flag by accident.
  The fix is a single-line condition flip; do not reshape the function.
- Do NOT also "harmonize" the regular-Stop path by changing its behavior
  in any way. The regular-Stop path's existing gate on
  `config.stopReviewGate` is correct for the user-facing interactive
  block.
- Do NOT touch `runtime/core/dispatch_engine.py:_check_codex_gate` to
  "make it more tolerant" of an empty events table. The consumer is
  correct; its silence was a symptom, not a cause.
- Do NOT add a scenario test that depends on a real Codex CLI
  invocation. If the implementer elects to add a scenario test (optional,
  see Scope Manifest below), it must feed the hook a synthetic
  `SubagentStop` JSON input directly to node and assert on the
  early-return behavior without requiring the Codex binary.
- Do NOT bundle W-ENFORCE-RCA-12 or W-ENFORCE-RCA-13 in the same
  dispatch chain. Each is a separate work item with a separate Evaluation
  Contract.
- Do NOT touch `MASTER_PLAN.md` while in the worktree. Planner-only
  authority.

**Ready-for-guardian definition.** All five Evaluation Contract checks
pass on a single, named head SHA inside the implementer's worktree, and
the tester has captured:

- (a) raw file excerpt showing the new condition
  `if (!isSubagentStop && !config.stopReviewGate) { ... return; }` and
  the `DEC-ENFORCE-REVIEW-GATE-002` rationale comment block,
- (b) raw `cc-policy event query --type codex_stop_review --limit 1`
  output showing at least one row with `created_at` within the last
  120 seconds and the dispatch exercise that produced it,
- (c) raw `python3 -m pytest tests/` exit-0 output with the
  `1441 passed, 1 xpassed` (or better) summary line.

The tester then sets `ready_for_guardian` via
`cc-policy workflow ready-set`. Guardian merges after SHA-match
verification. Commit message MUST reference `ENFORCE-RCA-14` in the
title and `DEC-ENFORCE-REVIEW-GATE-002` in the body.

**Scope Manifest (the orchestrator MUST write this to runtime via
`cc-policy workflow scope-set` BEFORE dispatching the implementer).**

Allowed files (exactly these; the implementer may read or write only
these source paths):
- `plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs`

Optional / contingent (the implementer's judgment on whether to add; if
added, it lives in the same worktree and same commit):
- `tests/scenarios/test-review-gate-subagent-stop.sh` (NEW, optional) — a
  node-based scenario test that feeds the hook a synthetic SubagentStop
  JSON input with `agent_type=implementer` and
  `config.stopReviewGate=false`, and asserts the hook does NOT
  early-return. If the implementer elects to add it, the test must not
  depend on a real Codex binary and must not write to `runtime/cc_state.db`.

Required files (at least this one must change; otherwise the work is
incomplete):
- `plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs`
  — replace the 4-line early-return block at current HEAD lines 591-596
  with the 9-line replacement from the verbatim source patch below,
  preserving surrounding whitespace and the trailing blank line before
  line 598's `// For guardian SubagentStop` comment.

Forbidden touch points (any modification triggers immediate scope
violation and tester rejection):
- `runtime/core/dispatch_engine.py`
- `runtime/cli.py`
- Any file under `runtime/core/policies/`
- Any other file under `runtime/core/`
- Any file under `hooks/` (including but not limited to `pre-bash.sh`,
  `pre-write.sh`, `check-implementer.sh`, `post-task.sh`,
  `lib/hook-safety.sh`, `lib/runtime-bridge.sh`)
- `settings.json`
- `plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs`
  (the setup CLI — its `--enable-review-gate` behavior is unchanged)
- Any other file under `plugins/marketplaces/openai-codex/plugins/codex/scripts/`
- `MASTER_PLAN.md` (planner-only authority)
- `runtime/cc_state.db`
- Any file under `traces/`
- Any of the currently-dirty files on main
  (`MASTER_PLAN.md`,
  `plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs`
  is the ONE exception — it IS the required file),
  `settings.json`, `runtime/cc_state.db`,
  `runtime/dispatch-debug.jsonl`, `traces/`,
  `hooks/block-worktree-create.sh`)

Expected state authorities touched: NONE at patch time. After the patch
lands and the live dispatch exercise in Evaluation Contract step 3 runs,
the `events` table will receive a `codex_stop_review` row — this is the
intended runtime observable and the basis for readiness.

**Critical pre-implementation note (must be relayed verbatim in the
dispatch context).** The orchestrator's main working tree currently
contains an uncommitted diagnostic version of
`stop-review-gate-hook.mjs` (one of the 12 dirty files flagged in the
SubagentStart warning). Guardian will provision a fresh worktree from
main HEAD, which does NOT contain any uncommitted diagnostic changes and
DOES contain the exact buggy early-return block at lines 591-596 that
the patch targets. The implementer must apply the patch against the
clean main HEAD copy in the worktree, NOT against any stashed diagnostic
version. If the line numbers in the worktree do not match 591-596 at
the moment the implementer opens the file, the implementer must
re-locate the exact block

```js
  if (!config.stopReviewGate) {
    if (!isSubagentStop) {
      logNote(runningTaskNote);
    }
    return;
  }
```

by literal content match (not line number) and apply the patch there.

**Verbatim source patch.** Replace the block above with:

```js
  // ENFORCE-RCA-14 / DEC-ENFORCE-REVIEW-GATE-002: the SubagentStop review path
  // is part of dispatch-chain integrity — it writes codex_stop_review events
  // that dispatch_engine._check_codex_gate consumes for AUTO_DISPATCH routing
  // decisions. It MUST run on every SubagentStop regardless of the user-facing
  // `config.stopReviewGate` flag, otherwise the events table stays empty and
  // the dispatch engine gate silently always-allows.
  //
  // `config.stopReviewGate` continues to gate only the USER-FACING regular
  // Stop path (the interactive block at turn-end that the user opts into
  // via `codex setup --enable-review-gate`).
  if (!isSubagentStop && !config.stopReviewGate) {
    logNote(runningTaskNote);
    return;
  }
```

That is the entire source-code change. No other files need to be
touched for the fix itself.

**Test plan (concrete, executable).**

1. *Apply the source patch.* Open
   `plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs`
   in the worktree. Locate the buggy early-return block by literal
   content (not line number). Replace it with the verbatim source patch
   above.

2. *Static verification (Evaluation Contract steps 1 and 2 and 5).* Read
   the file and confirm:
   - The new condition reads
     `if (!isSubagentStop && !config.stopReviewGate)`.
   - The `DEC-ENFORCE-REVIEW-GATE-002` rationale comment block is present
     immediately above the condition.
   - The SubagentStop branch at lines ~613-646 is unchanged.
   - The Guardian-landing check at ~line 600 is unchanged.
   - The `runStopReview` call at ~line 610 is unchanged.

3. *Optional scenario test.* If the implementer elects to add
   `tests/scenarios/test-review-gate-subagent-stop.sh`, it must:
   - Launch `node` directly against
     `plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs`
     with a synthetic SubagentStop JSON input on stdin
     (`{"agent_type":"implementer","cwd":"...","workflow_id":"test"}`).
   - Set an environment variable or mock to force
     `config.stopReviewGate === false`.
   - Assert the hook does NOT early-return by checking that it attempts
     to invoke `runStopReview` (use a stub codex binary on PATH that
     echoes a PASS verdict so the test does not require a real Codex
     install).
   - Exit 0 on success, non-zero with a clear message on failure.

4. *Run the full pytest suite (Evaluation Contract step 4).*

   ```bash
   python3 -m pytest tests/
   ```

   Must exit 0 with `1441 passed, 1 xpassed` or better.

5. *Live dispatch exercise (Evaluation Contract step 3).* After the
   patch is applied and pytest is green, trigger a real subagent
   dispatch through the full chain (the simplest reproduction is for
   the orchestrator to dispatch a trivial implementer for an adjacent
   tiny change, OR for the tester to use an existing SubagentStop fixture
   if one exists). Within 120 seconds, run:

   ```bash
   cc-policy event query --type codex_stop_review --limit 1
   ```

   Expected: at least one row with `created_at` within the last 120
   seconds. The verdict may be `ALLOW` or `BLOCK`. The tester pastes the
   raw CLI output into the tester report. If the query returns zero
   rows, the fix did not land correctly; the implementer must
   investigate before marking ready.

**Reproduction command (canonical; runs identically before and after
the fix to prove the flip).**

```bash
cc-policy event query --type codex_stop_review --limit 1
```

- Expected on the parent SHA (before the fix, in a default install where
  `config.stopReviewGate === false`): zero rows, or only stale rows from
  a prior user-enabled run.
- Expected on the worktree HEAD (after the fix, after a subagent
  dispatch): at least one new row with a recent `created_at`.

**Risk assessment.**

| Risk | Likelihood | Mitigation |
|---|---|---|
| Implementer flips the condition incorrectly (e.g. `(isSubagentStop \|\| !config.stopReviewGate)`) | Low | Verbatim source patch inlined above; tester verifies the exact literal match |
| Implementer adds a new config flag "for symmetry" | Low | Forbidden Shortcuts explicitly bans this; tester rejects |
| Implementer reshapes the function (extracts helper, renames variable) | Low | Scope Manifest requires a 4-line logic change + comment block only; tester rejects any broader refactor |
| Line numbers drift between the brief and the worktree HEAD | Medium | Implementer locates the buggy block by literal content match, not line number; the critical pre-implementation note covers this |
| Live dispatch exercise hangs because no subagent is available to dispatch | Medium | Tester uses a trivial `echo`-only implementer dispatch or an existing SubagentStop fixture; alternative: tester invokes the hook directly via node with a synthetic JSON input and a stub Codex binary on PATH |
| `events` table row was pre-existing from a user-enabled run | Low | Tester filters by `created_at > <now - 120>` via the `--limit 1` output's timestamp; any stale row is rejected |
| Implementer accidentally edits the dirty-main version of the hook instead of the worktree copy | Low | Critical pre-implementation note explicitly says fresh worktree; Guardian provisions from clean main HEAD |
| Pytest regression from an unrelated `.mjs` touchpoint | Low | The `.mjs` file is not imported by any Python path; if pytest regresses, the regression is unrelated and must be investigated before marking ready |
| Future W-ENFORCE-RCA-12 (CLI self-privilege) accidentally bundled | Low | Non-goals list explicitly excludes it; planner files it as a separate work item |
| Future W-ENFORCE-RCA-13 (git regex greedy) accidentally bundled | Low | Non-goals list explicitly excludes it; planner files it as a separate work item |

**Wave structure.**

Single wave, single work item, single implementer dispatch.

```
Wave 3: W-ENFORCE-RCA-14  (independent of W-ENFORCE-RCA-11 which is
                           dispatched in Wave 2; independent of the
                           future W-ENFORCE-RCA-12 and W-ENFORCE-RCA-13
                           which are separate chains)
```

**Dispatch chain.**

1. Orchestrator writes the Scope Manifest to runtime via

   ```bash
   cc-policy workflow scope-set --workflow-id enforce-rca-14 \
     --allowed plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs \
     --forbidden runtime/core/dispatch_engine.py,runtime/cli.py,settings.json,hooks/pre-bash.sh,hooks/pre-write.sh,hooks/check-implementer.sh,hooks/post-task.sh,MASTER_PLAN.md,runtime/cc_state.db,plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs
   ```

2. Orchestrator dispatches Guardian (provision) with
   `workflow_id=enforce-rca-14,
   feature_name=enforce-rca-14`. Guardian provisions a fresh worktree
   from main HEAD and issues the implementer lease. Accept whatever
   branch name Guardian derives (RCA-11 precedent:
   `feature/enforce-rca-14`).
3. Orchestrator dispatches the implementer into the worktree with the
   full Evaluation Contract, the full Scope Manifest, the verbatim
   source patch, and the critical pre-implementation note that the
   implementer must locate the buggy block by literal content match
   (not line number) because the orchestrator's main copy is dirty.
4. Implementer applies the patch, runs the full pytest suite inside the
   worktree, captures all output, and reports completion with the head
   SHA and the before/after file excerpt of the patched region.
5. Tester evaluates against the Evaluation Contract, runs the live
   dispatch exercise to verify the `codex_stop_review` event lands in
   the events table, captures raw output, and sets
   `ready_for_guardian` via `cc-policy workflow ready-set` if all five
   checks pass.
6. Guardian merges (commit + merge to main) after SHA-match
   verification. Commit message MUST reference `ENFORCE-RCA-14` in the
   title and `DEC-ENFORCE-REVIEW-GATE-002` in the body.

If any step in the chain fails, the orchestrator must report the
failure verbatim to the user before retrying. Specifically: if the
live dispatch exercise in step 5 produces zero `codex_stop_review`
rows, the fix is provably incomplete and the tester must NOT set
`ready_for_guardian` — escalate instead.

**File-level change summary.**

| File | Change Type | Lines |
|---|---|---|
| `plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs` | Modify: 4-line early-return block replaced with 9-line conditional + 10-line DEC rationale comment block | +~14/-4 |
| `tests/scenarios/test-review-gate-subagent-stop.sh` (optional) | NEW: node-based scenario test with synthetic SubagentStop JSON input and stub Codex binary | +~40 (if added) |

Total: ~10-50 lines net depending on whether the optional scenario test
is added. The source file is already tracked as dirty on main
(diagnostic changes from today's RCA verification); those dirty changes
are irrelevant — Guardian provisions from clean main HEAD and the
implementer applies the patch to the clean copy. `DEC-ENFORCE-REVIEW-GATE-002`
is pre-assigned and is referenced inline in the rationale comment block
AND must appear in the Guardian commit message body.

**Open questions.** None. The plan is executable as-is. The exact source
patch is inlined above. If the implementer or tester finds an unstated
ambiguity, it must be escalated to the user rather than resolved
silently.

##### W-ENFORCE-RCA-15: Policy-engine canonical config + regular Stop review enforcement

- **Status:** planned, awaiting Guardian provision (2026-04-07)
- **DEC-IDs pre-assigned:** `DEC-CONFIG-AUTHORITY-001`,
  `DEC-REGULAR-STOP-REVIEW-001`
- **Branch name suggestion:** `enforce-rca-15-config-canonical`
  (Guardian provision with
  `--feature-name enforce-rca-15-config-canonical` produces
  `feature/enforce-rca-15-config-canonical`)
- **Weight:** L (multi-file change touching schema, CLI, policy engine,
  shell bridge, two Node files, and tests; fits comfortably in a single
  implementer dispatch because every file change is mechanical once the
  table shape is agreed)
- **Gate:** approve (Guardian merge after tester + live dispatch
  verification, user approval required for push/merge per normal chain)
- **Dependencies:** none within INIT-ENFORCE. Independent of the open
  follow-ups #31 (RCA-12), #32 (RCA-13), #33 (tester workflow_id), #34
  (worktree remove). Codex confirmed no higher-priority blocker.
- **Codex convergence:** `Q1` table shape (`enforcement_config` with
  seeded defaults + policy-code fail-safes), `Q2` WHO gate on
  `cc-policy config set` (guardian lease required), `Q3` immediate flip
  (no advisory week), `Q4` keep `--enable-review-gate` as UI shortcut
  that delegates to the policy engine, `Q5` no higher-priority blocker —
  all five answers converged before planning. This section encodes the
  converged architecture verbatim.

**Problem statement.** The Codex review gate is the only surface that
converts in-session orchestrator output into a `codex_stop_review` event
that `dispatch_engine._check_codex_gate` (runtime/core/dispatch_engine.py:406-445)
can consume. Today it is gated by `plugins/marketplaces/openai-codex/plugins/codex/scripts/lib/state.mjs:getConfig(workspaceRoot).stopReviewGate`
— a plugin-local JSON field that defaults to `false` and is only
toggled on by the user running `codex setup --enable-review-gate`.
W-ENFORCE-RCA-14 fixed the SubagentStop side by making it unconditional
(DEC-ENFORCE-REVIEW-GATE-002). The regular-Stop side — which gates the
user-facing turn-end review on every session stop — is still off by
default and still reads from plugin-local JSON. Two problems compound:
(a) the regular-Stop gate's default is wrong, and (b) the config
authority for review-gate toggles is a plugin flat file rather than
the policy engine, so any fix that only flips the default perpetuates
the dual-authority problem. Fixing (a) without (b) leaves dual
authority for at least one cycle — violating the Single Source of
Truth Sacred Practice. The two MUST ship together.

**Goals (measurable).**

1. A new `enforcement_config` SQLite table exists in the canonical
   schema with `(scope, key, value, updated_at)` columns, PK on
   `(scope, key)`, and an index on `(key, scope)`; seeded with
   `review_gate_regular_stop=true`, `review_gate_provider=codex`,
   `critic_enabled_implementer_stop=true`, and `critic_retry_limit=2` at
   scope `global`.
2. `cc-policy config {get,set,list}` CLI domain exists, with `set`
   WHO-gated to guardian-role callers.
3. `PolicyContext.enforcement_config` field is populated by
   `build_context()` in one indexed read per call.
4. `stop-review-gate-hook.mjs` reads both toggles from `cc-policy config
   get` and sets `CLAUDE_POLICY_DB` from `CLAUDE_PROJECT_DIR` before
   every shell-out; plugin `state.json.stopReviewGate` is no longer the
   canonical source for review-gate toggles.
5. `plugins/.../lib/state.mjs:setConfig` dual-writes to
   `cc-policy config set review_gate_regular_stop` whenever the UI
   toggles `stopReviewGate`, preserving the `--enable-review-gate`
   shortcut for one release.
6. `python3 -m pytest tests/` returns `1441 passed, 1 xpassed` or
   better (current baseline from post-RCA-14 chain) — no regressions.
   ~6 new unit/scenario tests added.
7. Live verification: `cc-policy config get review_gate_regular_stop`
   returns `true` on a fresh install, and a regular Stop event in this
   session produces a `codex_stop_review` row within 60s.

**Non-goals (explicit exclusions).**

- Do NOT bundle any other open RCA. #31 (RCA-12 CLI self-privilege),
  #32 (RCA-13 git regex greedy), #33 (tester workflow_id), #34
  (worktree remove) each get their own chain.
- Do NOT touch other policy files under `runtime/core/policies/`. The
  policy engine is the config loader, not the config consumer, in this
  work item. Policies that want to read these toggles in later work
  will do so by reading `ctx.enforcement_config[key]`.
- Do NOT modify `settings.json`, `MASTER_PLAN.md` (planner updates it,
  implementer must not), or any file outside the Scope Manifest.
- Do NOT delete the plugin's own `stopReviewGate` field in this commit.
  The dual-write shim buys one release of backward compatibility; the
  deletion is a follow-up tracked as a TODO inline in `state.mjs`.
- Do NOT add new policies; the config plumbing is standalone.

**Ordered patch sequence (Codex's 5-step verbatim).** The implementer
MUST apply these in order. Target line numbers reflect the clean main
HEAD that Guardian provisions; they are approximate anchors because
the implementer's worktree is fresh from main.

1. **Schema and runtime module (new table + new module).**
   - `runtime/schemas.py` around line 320: add `ENFORCEMENT_CONFIG_DDL`
     constant near the other DDLs (insertion point is between the
     existing DDL constants and the `ALL_DDL` list), then append
     `ENFORCEMENT_CONFIG_DDL` to `ALL_DDL` immediately after
     `OBS_RUNS_DDL`. Add `ENFORCEMENT_CONFIG_INDEXES_DDL: list[str]`
     list with the `(key, scope)` index and wire it into the schema
     bootstrap path that existing indexed tables use (follow
     `OBS_SUGGESTIONS_INDEXES_DDL` at line 303 as the pattern).
     Exact DDL:

     ```python
     ENFORCEMENT_CONFIG_DDL = """
     CREATE TABLE IF NOT EXISTS enforcement_config (
         scope       TEXT NOT NULL,
         key         TEXT NOT NULL,
         value       TEXT NOT NULL,
         updated_at  INTEGER NOT NULL,
         PRIMARY KEY (scope, key)
     )
     """
     ENFORCEMENT_CONFIG_INDEXES_DDL: list[str] = [
         """CREATE INDEX IF NOT EXISTS idx_enforcement_config_key_scope
            ON enforcement_config (key, scope)""",
     ]
     ```

     Seeding of the three default rows happens in
     `runtime/core/enforcement_config.py` on module import / on table
     creation (idempotent INSERT OR IGNORE), not inline in the DDL,
     so that the fail-safe fallback constants in the module are the
     single source of truth for default values.

   - `runtime/core/enforcement_config.py` (NEW file): exports
     `DEFAULTS: dict[str, str]` constants (the three seeded rows), and
     functions `get(conn, key, *, scope='global')`, `set(conn, key,
     value, *, scope='global', actor_role=None)`, `list(conn, *,
     scope=None)`, and `seed_defaults(conn)` (called lazily from
     `get`/`set`/`list` to make the module idempotent with fresh DBs).
     The `get` function implements fallback: `workflow=<wf_id>` →
     `project=<project_root>` → `global` → `DEFAULTS[key]` → `None`.
     The `set` function raises `PermissionError("config set requires
     guardian role, got %r" % actor_role)` when `actor_role != 'guardian'`.
     `list` returns a list of dicts ordered by `(scope, key)`.

2. **Policy engine integration.**
   - `runtime/core/policy_engine.py:69` (the `@dataclass class
     PolicyContext`): add a new field
     `enforcement_config: dict[str, str]` with default
     `field(default_factory=dict)` (import `field` from dataclasses
     if not already imported).
   - `runtime/core/policy_engine.py:328` (the `build_context`
     function): at the end of the context assembly (just before the
     `return PolicyContext(...)`), call a new helper
     `_load_enforcement_config(conn, project_root, workflow_id)` that
     selects every row from `enforcement_config` where scope is one of
     `('global', f'project={project_root}', f'workflow={workflow_id}')`,
     then collapses them into a single dict by key with precedence
     `workflow > project > global`. Pass the resulting dict into
     `PolicyContext(enforcement_config=...)`. Exactly one indexed read.

3. **CLI domain.**
   - `runtime/cli.py` around line 2681 (inside `build_parser()` — the
     domain-subparser section that follows the obs domain): add a new
     `config` subparser with three actions `get`, `set`, `list`.
     Mirror the structure of `_handle_evaluation` (line 122) and
     `_handle_workflow` (line 669) exactly. For `config set`, the
     handler MUST call `build_context()` to resolve `actor_role`
     identically to how `_handle_evaluate` resolves it (it already
     passes actor_role in from the hook JSON payload), then pass that
     `actor_role` into `enforcement_config.set()`. When
     `PermissionError` is raised, surface via `_err({"error":
     "permission_denied", "reason": str(e)})`.
   - `runtime/cli.py:main()` at line 2681: add the dispatch
     `if args.domain == "config": return _handle_config(args)` in the
     same block that routes `evaluation`, `marker`, `workflow`, etc.

4. **Shell bridge.**
   - `hooks/lib/runtime-bridge.sh` (after the existing eval/marker/
     workflow wrapper sections): add `rt_config_get <key> [scope]`
     and `rt_config_set <key> <value> [scope]`. `rt_config_get` must
     emit the literal string `__FAIL_CLOSED__` (choose a sentinel in
     the implementation; `__FAIL_CLOSED__` is the recommended value)
     on ANY non-zero exit from `cc_policy` OR on an empty JSON
     response, NOT empty string — callers must be able to distinguish
     "not set" (empty) from "lookup failed" (sentinel). Document the
     sentinel in `hooks/HOOKS.md` under a new `## Runtime bridge
     sentinels` subsection. Follow `rt_eval_get` (line 53) as the
     structural template. `rt_config_set` calls `cc_policy config set
     …` with stdin-provided JSON payload that includes the
     current session's `actor_role` (the CLI handler will reject
     non-guardian calls).

5. **Node plugin retarget.**
   - `plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs:577`
     (`function main()`): immediately after `const workspaceRoot =
     resolveWorkspaceRoot(cwd);` and BEFORE `const config =
     getConfig(workspaceRoot);`, introduce a helper call
     `readEnforcementConfig(workspaceRoot)` that shells out to
     `python3 <cliPath> config get <key> --json` with the env
     `CLAUDE_POLICY_DB = ${workspaceRoot}/.claude/state.db` (mirroring
     the bash `cc_policy()` pattern at
     `hooks/lib/runtime-bridge.sh:23-29`). Parse both toggles:
     `reviewGateSubagentStop` and `reviewGateRegularStop`. Replace
     the existing `if (!isSubagentStop && !config.stopReviewGate)`
     guard at line 601 with `if (!isSubagentStop &&
     !reviewGateRegularStop)`. Leave the DEC-ENFORCE-REVIEW-GATE-002
     comment block intact (it still documents why the SubagentStop
     branch is unconditional) but reference the new config source in
     an appended note. Also: if the CLI shell-out fails, treat the
     response as the sentinel "fail closed" value — for a DEFAULT-ON
     toggle, fail-closed means the review gate STILL runs (because
     running the review is the safe side of the fence), NOT skips.
     Document this inversion inline.
   - `plugins/marketplaces/openai-codex/plugins/codex/scripts/lib/state.mjs:484`
     (`export function setConfig(cwd, key, value)`): add a dual-write
     shim — when `key === "stopReviewGate"`, after the existing
     `updateState(cwd, …)` call, ALSO shell out to `python3 <cliPath>
     config set review_gate_regular_stop <value> --scope global` with
     `CLAUDE_POLICY_DB = ${cwd}/.claude/state.db`. Add an inline
     comment:
     `// TODO(DEC-CONFIG-AUTHORITY-001): dual-write transitional.`
     `// Delete after one release; stopReviewGate is no longer canonical.`
     Catch the shell-out failure and log it with `logNote()` — do NOT
     let a CLI error break the `setConfig` call, because the plugin
     UI must keep working in offline/degraded states.

**Seeded defaults table (schema + enforcement_config module mirror).**

| key | value | scope | rationale |
|---|---|---|---|
| `review_gate_regular_stop` | `true` | `global` | The RCA-15 flip. Was `false` (via plugin `state.json`). This commit makes it `true` by default — every fresh install enforces regular-Stop Codex review out of the box. |
| `review_gate_provider` | `codex` | `global` | Primary review provider intent. The current hook still tries Codex first and Gemini fallback directly; provider-config consumption remains a follow-up cleanup. |

**Evaluation Contract (11 checks — executable acceptance).**

Each item is measurable and must be verified by the tester before
`ready_for_guardian` is set. The tester will run each check, capture
raw output, and include it in the handoff to Guardian.

1. `runtime/schemas.py:ALL_DDL` list contains `ENFORCEMENT_CONFIG_DDL`,
   and the new DDL creates a table with columns `(scope TEXT, key
   TEXT, value TEXT, updated_at INTEGER, PRIMARY KEY (scope, key))`.
   Verified by `python3 -c "from runtime.schemas import ALL_DDL;
   assert any('enforcement_config' in d for d in ALL_DDL)"` and by
   inspecting the column list via `sqlite3 <db> '.schema
   enforcement_config'` after running `cc-policy schema ensure`.
2. `runtime/core/enforcement_config.py` exports `get`, `set`, `list`,
   `seed_defaults`, and `DEFAULTS`. The `DEFAULTS` dict contains the
   three keys from the seeded-defaults table with the exact values
   shown. The `set` function raises `PermissionError` when
   `actor_role` is not `'guardian'`.
3. `runtime/cli.py` has a `config` domain reachable via
   `cc-policy config get`, `cc-policy config set`, `cc-policy config
   list`. `set` reads `actor_role` from `build_context()` and
   surfaces `PermissionError` as `_err(…)` JSON. Verified by
   `cc-policy config get review_gate_regular_stop` returning
   `{"value": "true"}` (or equivalent JSON shape) after the patch
   lands on a fresh DB, and by
   `cc-policy config set review_gate_regular_stop false` returning
   `{"error": "permission_denied", …}` when called without a
   guardian lease.
4. `runtime/core/policy_engine.PolicyContext` has a new field
   `enforcement_config: dict[str, str]` (default empty dict). `grep`
   on the file finds the field declaration.
5. `build_context()` at `runtime/core/policy_engine.py:328` loads
   `enforcement_config` rows for `('global', 'project=…',
   'workflow=…')` in a single indexed read and collapses them into
   the new `PolicyContext.enforcement_config` field with precedence
   `workflow > project > global`. Verified by
   `tests/runtime/test_policy_engine.py` adding a test that seeds
   rows at two scopes and asserts the field on the returned
   context reflects the correct collapse.
6. `hooks/lib/runtime-bridge.sh` has `rt_config_get` and
   `rt_config_set` wrappers. `rt_config_get` returns the literal
   string `__FAIL_CLOSED__` (or chosen sentinel) when `cc-policy`
   exits non-zero. `hooks/HOOKS.md` documents the sentinel under
   `## Runtime bridge sentinels`.
7. `plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs`
   reads `review_gate_regular_stop` from `cc-policy config get` (NOT from
   `getConfig(workspaceRoot).stopReviewGate`). SubagentStop review influence
   is owned by role-specific critics, currently `implementer-critic.sh` via
   `critic_reviews`. Sets
   `CLAUDE_POLICY_DB = ${workspaceRoot}/.claude/state.db` in the env
   for every shell-out. Plugin `state.json.stopReviewGate` is not
   read in the regular-Stop gate decision. Verified by `grep` on
   the file asserting no `config.stopReviewGate` reference remains
   and that `CLAUDE_POLICY_DB` is set before `execFileSync`/`spawnSync`.
8. `plugins/marketplaces/openai-codex/plugins/codex/scripts/lib/state.mjs:484`
   `setConfig` shim: when `key === "stopReviewGate"`, ALSO calls
   `cc-policy config set review_gate_regular_stop …` with
   `CLAUDE_POLICY_DB` scoped to `cwd`. Inline TODO comment
   references `DEC-CONFIG-AUTHORITY-001`. Verified by `grep` and
   by a unit test that calls `setConfig(…, "stopReviewGate",
   false)` and asserts the config table row updated.
9. `python3 -m pytest tests/` returns `1441 passed, 1 xpassed` or
   better. New tests added:
   - `tests/runtime/test_enforcement_config.py`:
     - `test_default_seeding_populates_three_rows` — after
       `seed_defaults(conn)`, `list(conn)` returns three rows with
       the seeded keys/values/scope.
     - `test_get_scope_fallback_workflow_project_global` — seeds
       the same key at three scopes, asserts `get` with
       `scope='workflow=wf1'` returns the workflow value,
       `scope='project=/p'` returns the project value, `scope='global'`
       returns the global value; asserts fallback ordering with a key
       only at `global`.
     - `test_set_requires_guardian_role` — calls `set` with
       `actor_role='guardian'` (succeeds), `actor_role='implementer'`
       (raises `PermissionError`), `actor_role=''` (raises
       `PermissionError`).
     - `test_list_orders_rows_deterministically` — inserts three
       rows at mixed scopes, asserts `list` returns them in
       `(scope, key)` order.
   - `tests/runtime/test_policy_engine.py`: extend with
     `test_build_context_loads_enforcement_config` — seed rows at
     global + project, call `build_context(conn, cwd=…,
     project_root='/p', …)`, assert the returned
     `ctx.enforcement_config` reflects the project-over-global
     collapse.
   - Optional: `tests/runtime/test_cli_config_domain.py` with
     scenario tests for `cc-policy config get/set/list` including
     a WHO-gated `set` denial test. Recommended but not required
     if the unit tests fully cover the domain logic.
10. **Live verification.** After the patch lands in the worktree and
    pytest passes, the tester runs:
    - `cc-policy config get review_gate_regular_stop` → returns
      `true`
    - `cc-policy config get critic_enabled_implementer_stop` → returns
      `true`
    - Trigger a regular Stop event in the session (the tester does
      this by issuing a normal assistant completion in its own
      session, which fires the regular-Stop hook chain).
    - Within 60 seconds, `cc-policy event list --name
      codex_stop_review --limit 1` (or equivalent query) returns at
      least one new row with a `VERDICT:` detail field. Raw output
      captured and attached to the handoff.
    If zero `codex_stop_review` rows appear within 60s, the fix is
    incomplete and the tester MUST NOT set `ready_for_guardian` —
    escalate to the user.
11. **DEC annotations.** Both DEC-IDs are referenced inline in the
    implementation:
    - `DEC-CONFIG-AUTHORITY-001` appears in the docstring of
      `runtime/core/enforcement_config.py` AND in the comment block
      above the `cc-policy config` handler in `runtime/cli.py` AND
      in the inline TODO in `plugins/.../lib/state.mjs:setConfig`.
    - `DEC-REGULAR-STOP-REVIEW-001` appears in the comment block
      near the patched guard in `stop-review-gate-hook.mjs` AND
      in the seeded-defaults constant docstring in
      `runtime/core/enforcement_config.py`.
    Both IDs must appear verbatim in the Guardian commit message
    body; `ENFORCE-RCA-15` must appear in the commit title.

**Scope Manifest.**

Allowed / required files (the implementer must modify ALL of these
and MUST NOT touch anything else). The orchestrator writes this
manifest to the runtime before dispatch via:

```bash
cc-policy workflow scope-set --workflow-id enforce-rca-15 \
  --allowed runtime/schemas.py,runtime/core/enforcement_config.py,runtime/core/policy_engine.py,runtime/cli.py,hooks/lib/runtime-bridge.sh,plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs,plugins/marketplaces/openai-codex/plugins/codex/scripts/lib/state.mjs,tests/runtime/test_enforcement_config.py,tests/runtime/test_policy_engine.py,hooks/HOOKS.md \
  --forbidden settings.json,MASTER_PLAN.md,runtime/core/policies/,runtime/core/dispatch_engine.py,hooks/pre-bash.sh,hooks/pre-write.sh,hooks/check-implementer.sh,hooks/post-task.sh,runtime/cc_state.db,plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs
```

| Path | Change | Rationale |
|---|---|---|
| `runtime/schemas.py` | Modify: add `ENFORCEMENT_CONFIG_DDL`, `ENFORCEMENT_CONFIG_INDEXES_DDL`, append to `ALL_DDL`, wire indexes into `ensure_schema()` path | Canonical DDL authority |
| `runtime/core/enforcement_config.py` | NEW file | Module implementing `get`/`set`/`list`/`seed_defaults`/`DEFAULTS` with WHO gate |
| `runtime/core/policy_engine.py` | Modify: add `enforcement_config` field to `PolicyContext`; extend `build_context()` with a single indexed read | PolicyContext integration, no extra I/O per evaluate |
| `runtime/cli.py` | Modify: add `config` subparser + `_handle_config()` handler; dispatch in `main()` | CLI surface |
| `hooks/lib/runtime-bridge.sh` | Modify: add `rt_config_get`, `rt_config_set` | Shell-side bridge with fail-closed sentinel |
| `plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs` | Modify: retarget config source to `cc-policy config get`, set `CLAUDE_POLICY_DB` before shell-out, flip the regular-Stop guard condition | The actual enforcement flip |
| `plugins/marketplaces/openai-codex/plugins/codex/scripts/lib/state.mjs` | Modify: `setConfig` dual-write shim for `stopReviewGate` | Backward compat for one release |
| `tests/runtime/test_enforcement_config.py` | NEW file | Unit coverage for DDL + get/set/list + WHO gate |
| `tests/runtime/test_policy_engine.py` | Modify: add `test_build_context_loads_enforcement_config` | Integration with PolicyContext |
| `hooks/HOOKS.md` | Modify: add `## Runtime bridge sentinels` subsection | Document `__FAIL_CLOSED__` convention |

Forbidden touch points (implementer MUST NOT modify):

- `settings.json` (hook wiring is already correct)
- `MASTER_PLAN.md` (planner updates only)
- `runtime/core/policies/` (this work item is plumbing, not a new policy)
- `runtime/core/dispatch_engine.py` (the consumer side is already correct)
- `hooks/pre-bash.sh`, `hooks/pre-write.sh`, `hooks/check-implementer.sh`,
  `hooks/post-task.sh` (these read/write other domains, untouched)
- `runtime/cc_state.db` (generated artifact)
- `plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs`
  (the UI shortcut surface continues to call `setConfig` — and
  `setConfig`'s dual-write handles the rest)
- Any file outside the Allowed list above

Expected state authorities touched:

- **`enforcement_config`** (NEW SQLite table; written by
  `runtime/core/enforcement_config.py`, read by `build_context()` and
  `cc-policy config get`). This is the canonical authority DEC-CONFIG-AUTHORITY-001
  establishes.
- **`events`** (read-only verification via `cc-policy event list
  --name codex_stop_review`). No writes from this work item — the
  writes happen in `stop-review-gate-hook.mjs:emitCodexReviewEventSync`
  which is unchanged in behavior (DEC-ENFORCE-REVIEW-GATE-002 already
  made it unconditional).
- **Plugin `state.json`** (read-only for non-review-gate fields;
  review-gate fields are now dual-written via the transitional shim
  and will be removed in a follow-up release).
- **`PolicyContext`** (new `enforcement_config` dict field populated
  by `build_context()` in one indexed read; zero impact on existing
  consumers).

**Risk table.**

| Risk | Likelihood | Mitigation |
|---|---|---|
| Config scoping drift — a later commit adds config rows without the `(scope, key)` convention and introduces per-project drift | Medium | Schema enforces PK on `(scope, key)` and the `set()` function requires scope as a keyword arg with default `'global'`; the `seed_defaults()` function is the only place that writes scope-unqualified rows, and those are all explicitly scoped to `'global'`. CI test `test_get_scope_fallback_workflow_project_global` asserts the fallback chain is correct, so regressions break tests. |
| Fail-open via wrapper error suppression — `rt_config_get` returns empty string on CLI failure, and a policy treats empty as "permission allowed" | High if uncaught | Return `__FAIL_CLOSED__` sentinel instead of empty on ANY failure path. Document in `HOOKS.md`. In the Node hook, fail-closed for a DEFAULT-ON toggle means the review gate STILL runs (safe side). Unit test in `test_enforcement_config.py` does not cover the shell wrapper directly, but the inversion is documented inline and verified by the live dispatch exercise in Evaluation Contract item 10 — zero `codex_stop_review` rows on regular Stop means something is fail-opening and the tester escalates. |
| Node hooks bypass project scoping by inheriting parent env `CLAUDE_POLICY_DB` unset or wrong | High if uncaught | Mandatory explicit assignment in `stop-review-gate-hook.mjs` and in `lib/state.mjs` dual-write shim BEFORE every `execFileSync`. Mirror the bash `cc_policy()` pattern at `runtime/lib/runtime-bridge.sh:23-29`. The tester verifies this by reading the Node file and grepping for `CLAUDE_POLICY_DB` before every `execFileSync` in the touched files. |
| Regressions in existing `build_context()` callers — adding a new field changes the dataclass shape and any positional constructor call breaks | Low | The new field has `default_factory=dict`, so it is keyword-optional. All existing callers already use keyword arguments. A pytest run of the full suite (Evaluation Contract item 9) catches any positional-call regression immediately. |
| WHO gate bypass — orchestrator or another subagent manages to call `cc-policy config set` without a guardian lease | Low | `_handle_config()` resolves `actor_role` via `build_context()` just like `_handle_evaluate` does (which has been hardened through INIT-PE + INIT-ENFORCE); the `PermissionError` originates from the domain layer not the CLI, so even direct Python imports of `enforcement_config.set()` are gated. Three cases tested in `test_set_requires_guardian_role`: `'guardian'` (allowed), `'implementer'` (denied), `''` (denied). |
| Plugin `state.json.stopReviewGate` field still read somewhere outside the two touched files | Medium | Implementer MUST `grep -rn "stopReviewGate" plugins/marketplaces/openai-codex/plugins/codex/` before completion, report every hit, and confirm each is either in a touched file, in a comment, or in a doc. Tester verifies by re-running the grep. |
| Dual-write shim silently fails in offline / degraded state and the plugin UI toggle appears to work but the canonical config is stale | Medium | `setConfig` logs the shell-out failure via `logNote()` with an unmistakable message (`"[config-shim] cc-policy config set failed: …"`). User-visible log preserves debuggability. The dual-write is transitional and will be deleted in one release, so permanent fragility is bounded. |
| Implementer attempts to touch `settings.json` because the hook wiring "looks wrong" | Low | Scope Manifest explicitly forbids it. The `workflow scope-set` command above forbids it at the runtime level. If the implementer believes `settings.json` must change, the correct path is to escalate to the orchestrator, not to modify it unilaterally. |

**State-authority map (what reads / writes what).**

| Domain | Canonical authority | Writers | Readers |
|---|---|---|---|
| `enforcement_config` table | NEW — `runtime/core/enforcement_config.py` | `cc-policy config set` (WHO-gated to guardian), `seed_defaults()` on first use, `lib/state.mjs:setConfig` dual-write shim (transitional) | `cc-policy config get/list`, `build_context()` via `PolicyContext.enforcement_config`, `stop-review-gate-hook.mjs` via `rt_config_get` / direct `execFileSync` |
| Plugin `state.json.stopReviewGate` | Deprecated — `lib/state.mjs:setConfig` dual-writes to canonical. Will be deleted one release after this commit. | `lib/state.mjs:setConfig` (UI shortcut) | (previously) `stop-review-gate-hook.mjs` — NO LONGER after this commit |
| `events.codex_stop_review` | `emitCodexReviewEventSync` in `stop-review-gate-hook.mjs` — unchanged | Same as before (no change in this work item) | `dispatch_engine._check_codex_gate` — unchanged |
| `PolicyContext.enforcement_config` | In-memory dict built per `build_context()` call | `build_context()` via `_load_enforcement_config()` | Any policy that later opts into reading config-driven toggles; this work item adds no such policy |
| `workflow_scope` | Unchanged — `runtime/core/workflow.py` | Orchestrator via `cc-policy workflow scope-set` | `pre-write.sh`, `check-implementer.sh`, etc. The NEW work item writes to this domain at dispatch time (the `scope-set` command above) to advertise the Scope Manifest. |

**Critical implementer warnings.**

1. **Dirty main worktree.** The orchestrator's main working tree has 12
   uncommitted files including `runtime/cli.py` (the RCA-11
   hookEventName diagnostic, now identical to HEAD post-RCA-11),
   `hooks/context-lib.sh` (realpath fix), `settings.json` (debug
   capture wiring), etc. The implementer's fresh worktree will be
   provisioned from clean main HEAD and will NOT have any of these
   files modified. Do not assume. Apply the patch by file, not by
   diff against the dirty main.

2. **`CLAUDE_POLICY_DB` env scoping is MANDATORY in Node code.** The
   bash `cc_policy()` function at `hooks/lib/runtime-bridge.sh:23-29`
   sets `CLAUDE_POLICY_DB` from `CLAUDE_PROJECT_DIR` automatically.
   Node code does not inherit that behavior. Every `execFileSync` or
   `spawnSync` call to `python3 …/cli.py …` in
   `stop-review-gate-hook.mjs` and `lib/state.mjs` MUST set
   `env: { ...process.env, CLAUDE_POLICY_DB:
   path.join(workspaceRoot, '.claude/state.db') }` BEFORE the call.
   Without this, the CLI resolves to the default `~/.claude/state.db`
   and reintroduces per-project vs global DB drift, which is
   Codex risk #3.

3. **WHO gate test coverage is non-optional.** The
   `test_set_requires_guardian_role` test in
   `test_enforcement_config.py` MUST cover all three cases:
   `actor_role='guardian'` (allowed), `actor_role='implementer'`
   (denied with `PermissionError`), `actor_role=''` (denied with
   `PermissionError`). Do not ship without all three. An empty
   actor_role is the orchestrator case and it is the most dangerous
   bypass vector because `build_context()` ALREADY refuses to
   elevate an empty-role caller via the lease fallback path
   (DEC-PE-EGAP-BUILD-CTX-001); the config setter must enforce the
   same contract at the write boundary.

4. **The `_load_enforcement_config()` helper is one indexed query, not
   three.** Use a single `SELECT * FROM enforcement_config WHERE
   scope IN (?, ?, ?)` with the three scope strings, then collapse
   in Python. Do NOT issue three separate queries — `build_context()`
   is already on the hot path and performance matters here.

5. **Fail-closed semantics are inverted for default-on toggles.** For
   `review_gate_regular_stop=true`, "fail closed" means the review
   gate STILL RUNS on lookup failure, because running the review is
   the safe side of the fence. For a hypothetical default-off
   toggle, "fail closed" would mean the gated operation is DENIED.
   The Node hook implementation must encode this inversion
   correctly and the comment must explain it, otherwise a later
   engineer who sees `__FAIL_CLOSED__` → "skip review" will regress
   the fix.

6. **Do NOT bundle any other open RCA.** The follow-ups
   #31 (RCA-12 CLI self-privilege), #32 (RCA-13 git regex greedy),
   #33 (tester workflow_id), and #34 (worktree remove) each get
   their own chain. Even if the implementer notices a two-line fix
   to #32 while editing an adjacent file, the fix does not belong
   in this commit — file a separate task via `/backlog`.

**Wave structure.**

```
Wave 4: W-ENFORCE-RCA-15  (independent of W-ENFORCE-RCA-11, RCA-14,
                           and the parked RCA-12/13 follow-ups;
                           third end-to-end chain of this session)
```

Single wave, single work item, single implementer dispatch. Third
end-to-end chain of the session; the first two (RCA-11 and RCA-14)
verified the dispatch chain works under the post-RCA-11
`hookEventName` fix. This chain additionally validates the new
policy-engine-canonical config story end-to-end.

**Dispatch chain.**

1. Orchestrator writes the Scope Manifest to runtime via

   ```bash
   cc-policy workflow scope-set --workflow-id enforce-rca-15 \
     --allowed runtime/schemas.py,runtime/core/enforcement_config.py,runtime/core/policy_engine.py,runtime/cli.py,hooks/lib/runtime-bridge.sh,plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs,plugins/marketplaces/openai-codex/plugins/codex/scripts/lib/state.mjs,tests/runtime/test_enforcement_config.py,tests/runtime/test_policy_engine.py,hooks/HOOKS.md \
     --forbidden settings.json,MASTER_PLAN.md,runtime/core/policies/,runtime/core/dispatch_engine.py,hooks/pre-bash.sh,hooks/pre-write.sh,hooks/check-implementer.sh,hooks/post-task.sh,runtime/cc_state.db,plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs
   ```

2. Orchestrator dispatches Guardian (provision) with
   `workflow_id=enforce-rca-15,
   feature_name=enforce-rca-15-config-canonical`. Guardian provisions
   a fresh worktree from main HEAD and issues the implementer lease.
   Accept whatever branch name Guardian derives (expected:
   `feature/enforce-rca-15-config-canonical`).
3. Orchestrator dispatches the implementer into the worktree with
   the full Evaluation Contract, the full Scope Manifest, the
   verbatim ordered patch sequence (5 steps from Codex), and the
   six critical implementer warnings above. Integration-surface
   context in the dispatch: state domains touched =
   `enforcement_config` (new), `PolicyContext` (new field),
   `workflow_scope` (via the manifest write in step 1); adjacent
   components that read/write those domains = `build_context()`,
   every hook that sources `runtime-bridge.sh`, the two touched
   `.mjs` files; canonical authority for
   `review_gate_regular_stop` = `enforcement_config` table;
   removal targets = plugin `state.json.stopReviewGate` (deferred
   one release via dual-write shim, to be deleted in the follow-up).
4. Implementer applies the patch, runs the full pytest suite inside
   the worktree, captures all output, and reports completion with
   the head SHA, the before/after file excerpt of each patched
   region, and the pytest summary line.
5. Tester evaluates against the 11 Evaluation Contract items, runs
   the live dispatch exercise (contract item 10) to verify
   `cc-policy config get review_gate_regular_stop` returns `true`
   AND a `codex_stop_review` event lands in the events table
   within 60s of a regular Stop. Captures raw output for every
   check. Sets `ready_for_guardian` via `cc-policy workflow
   ready-set` only if all 11 checks pass.
6. Guardian merges (commit + merge to main) after SHA-match
   verification. Commit message MUST reference `ENFORCE-RCA-15` in
   the title and BOTH `DEC-CONFIG-AUTHORITY-001` AND
   `DEC-REGULAR-STOP-REVIEW-001` in the body.

If any step in the chain fails, the orchestrator must report the
failure verbatim to the user before retrying. Specifically: if the
live dispatch exercise in step 5 produces zero `codex_stop_review`
rows, the fix is provably incomplete and the tester MUST NOT set
`ready_for_guardian` — escalate instead. Same escalation rule if
`cc-policy config get review_gate_regular_stop` returns anything
other than `true` on a fresh DB.

**File-level change summary.**

| File | Change Type | Est. Lines |
|---|---|---|
| `runtime/schemas.py` | Modify: new DDL constant, new indexes list, append to `ALL_DDL`, wire indexes into ensure_schema bootstrap | +~20 |
| `runtime/core/enforcement_config.py` | NEW file | +~120 |
| `runtime/core/policy_engine.py` | Modify: field + `_load_enforcement_config()` helper + call in `build_context()` | +~35 |
| `runtime/cli.py` | Modify: `config` subparser + `_handle_config()` handler + dispatch in `main()` | +~80 |
| `hooks/lib/runtime-bridge.sh` | Modify: `rt_config_get` + `rt_config_set` wrappers | +~35 |
| `plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs` | Modify: `readEnforcementConfig()` helper + `CLAUDE_POLICY_DB` env + guard flip + comment block | +~60/-5 |
| `plugins/marketplaces/openai-codex/plugins/codex/scripts/lib/state.mjs` | Modify: dual-write shim in `setConfig` | +~25 |
| `tests/runtime/test_enforcement_config.py` | NEW file | +~140 (four+ unit tests) |
| `tests/runtime/test_policy_engine.py` | Modify: extend with one new test | +~35 |
| `hooks/HOOKS.md` | Modify: add `## Runtime bridge sentinels` section | +~15 |

Total: ~570 net additions, ~5 deletions. Larger than RCA-14 (single
conditional flip) but each file change is mechanical; the bulk of
the diff is the new module, the new tests, and the new CLI handler.
No architectural decisions remain — Codex converged every open
question before planning.

**Open questions.** None. The plan is executable as-is. The
ordered patch sequence, the Evaluation Contract, the Scope
Manifest, the risk mitigations, and the live verification protocol
are all inlined above. If the implementer or tester finds an
unstated ambiguity, escalate to the user rather than resolve
silently. The pre-assigned DEC-IDs are final.

### INIT-PHASE0: Hook-Authority Cleanup Before Reviewer-Stage Refactor

- **Status:** planned (2026-04-07)
- **Base commit:** `c7a3109` on `fix/enforce-rca-13-git-shell-classifier`
- **Goal:** Re-establish a single trustworthy hook/config authority surface
  so the downstream `implementer -> reviewer -> guardian` cut (Phase 1+) does
  not inherit silent regressions. This initiative is hook-authority hygiene
  ONLY. It must not absorb or pre-implement any reviewer-stage scope.
- **Forbidden surface (Phase 1+ territory — DO NOT TOUCH in any P0 work item):**
  `runtime/core/dispatch_engine.py`, `runtime/core/completions.py`,
  `runtime/core/policies/bash_eval_readiness.py`, reviewer-provider extensions
  in `runtime/core/enforcement_config.py`, tester-routing replacement, any
  introduction of a `reviewer` stage, any `workflow_review_*` config keys, any
  `cc-policy review run|submit` provider runner. Until the reviewer cut lands,
  Phase 0 continues to use the existing tester-based canonical chain
  (planner -> guardian provision -> implementer -> tester -> guardian merge).
- **Allowed problem space:** hook wiring correctness, hook-contract accuracy,
  drift between `hooks/HOOKS.md` and the official Claude Code docs, missing
  tracked files referenced from `settings.json`, the auto-review.sh authority
  decision, verification gaps in hook-path tests, gitignore hygiene for
  runtime artifacts, leaked-fixture marker cleanup, and backlog filing for
  out-of-scope defects discovered in flight.

#### Empirical baseline (sources: official Claude Code docs + `runtime/dispatch-debug.jsonl`)

The decisions below are grounded in the following measurements taken at base
commit `c7a3109` against the live installed harness:

- **Official docs (https://code.claude.com/docs/en/hooks)** list the canonical
  hook event catalog. Confirmed events relevant to Phase 0:
  - `WorktreeCreate` IS a real event. Fires on `--worktree` CLI flag or
    `isolation: "worktree"`. Exit code 2 (or any non-zero) blocks creation.
    Does NOT support matchers — always fires.
  - `WorktreeRemove` IS a real event but cannot block.
  - `EnterWorktree` is NOT in the documented event list AND NOT in the
    documented PreToolUse tool-name matcher list. The documented PreToolUse
    matchers are: `Bash`, `Edit`, `Write`, `Read`, `Glob`, `Grep`, `Agent`,
    `WebFetch`, `WebSearch`, `AskUserQuestion`, `ExitPlanMode`, plus MCP tool
    name patterns. `EnterWorktree` appears nowhere.
  - Matching hooks within an event run **in parallel**, deduplicated by
    command string.
  - `PreToolUse` exit code 2 blocks the tool call AND feeds `stderr` to
    Claude.
- **`runtime/dispatch-debug.jsonl` (1303 lines, 651 hook events captured at
  c7a3109):** 0 events with `tool_name == "EnterWorktree"`, 0 events with
  `hook_event_name == "WorktreeCreate"`, 0 events with `hook_event_name ==
  "EnterWorktree"`. The capture window contains 547 PreToolUse:Bash, 38
  PreToolUse:Agent, 39 SubagentStart, 28 SubagentStop, and 0 of any
  worktree-specific tool/event. Of the 38 Agent invocations, **zero** carried
  an `isolation` field — meaning the orchestrator never exercised the
  `isolation: "worktree"` path that would have triggered `WorktreeCreate`.
  Absence of `WorktreeCreate` events from the JSONL is therefore consistent
  with both "the harness emits the event but no Agent triggered it" AND with
  "the event surface is dead" — the JSONL alone does not discriminate. The
  official docs DO discriminate: `WorktreeCreate` is documented and verified
  as a real surface; `EnterWorktree` is not.
- **Repo state at c7a3109:** `hooks/block-worktree-create.sh` is referenced
  twice from `settings.json` (lines 92-102 `WorktreeCreate` block,
  lines 103-113 `PreToolUse: matcher: "EnterWorktree"` block) but is currently
  **untracked** in git. `git log -- hooks/block-worktree-create.sh` returns
  empty. This is the highest-priority cleanup target.
- **`hooks/HOOKS.md` drift:** Three known divergences are catalogued in
  `~/.claude/projects/.../memory/project_hooks_md_drift.md` and confirmed in
  the live file:
  1. `HOOKS.md:9` says "Non-zero = hook error (logged, does not block)"; the
     official docs say PreToolUse exit-2 blocks.
  2. `HOOKS.md:155` says "Hooks within the same event run sequentially in
     array order"; the official docs say "All matching hooks run in parallel,
     and identical handlers are deduplicated automatically."
  3. `HOOKS.md:136-279` documents `auto-review.sh` as part of the live
     `PreToolUse:Bash` chain; the c7a3109 diff (verified via `git show`)
     replaced `auto-review.sh` in that chain with the
     `dispatch-debug.jsonl` capture writer. The file is still tracked
     (`hooks/auto-review.sh`, 36 KB) but has zero live wiring.
  Phase 0 work item P0-H must produce a complete delta against the official
  docs, not just patch these three. The delta produced during planning is
  documented inline in P0-H below.
- **The leaked fixture marker:** The repo-local state DB at
  `/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/.claude/state.db`
  contains an active row in `agent_markers`:
  `agent_id='foo', role='tester', is_active=1, status='active',
  project_root='/private/tmp/project', workflow_id=NULL, started_at=1775612185`.
  Schema (verified): columns are `agent_id, role, started_at, stopped_at,
  is_active, workflow_id, status, project_root` (note: column is `is_active`,
  not `active`, and `started_at` is epoch seconds — implementer must use these
  exact names). This is a unit-test fixture that wrote to the live project DB
  instead of an isolated test DB. The marker is deactivatable with one UPDATE;
  the underlying root cause (test fixtures using the live DB) is a separate
  backlog target tracked under P0-G.

#### Goals and non-goals

**Goals:**
1. Eliminate every speculative hook surface from `settings.json` that lacks
   evidence in either the official docs or the empirical capture.
2. Make every repo-owned hook command referenced from `settings.json` resolve
   to a tracked file, enforced by a failing test on regression.
3. Make `hooks/HOOKS.md` no longer claim authority over harness semantics
   where it disagrees with the official docs. Internal-mechanism documentation
   stays; external-contract documentation is removed and replaced with a
   pointer to the official docs.
4. Resolve the fate of `hooks/auto-review.sh` (and its three scenario tests)
   so the repo no longer carries an orphan file plus stale documentation.
5. Identify the verification gap in `tests/scenarios/test-codex-gate-stop.sh`
   (the production-sequence test that bypasses the actual `.mjs` emitter) and
   either close it in Phase 0 or file it as backlog with an exact target.
6. Add `.gitignore` coverage for the four runtime artifacts currently sitting
   uncommitted in the working tree.
7. Deactivate the leaked `foo` fixture marker and file the underlying
   fixture-isolation defect as backlog.

**Non-goals:**
- Any reviewer-stage routing change. (Phase 1+.)
- Any new policy in `runtime/core/policies/`. The Phase 0 evaluation contract
  scope manifests forbid touching `runtime/core/policies/` precisely so this
  initiative cannot accidentally leak into policy-engine work.
- Any modification to `runtime/core/dispatch_engine.py` or
  `runtime/core/completions.py`. These are reviewer-cut surfaces and are
  forbidden in every Phase 0 work item.
- Backporting any auto-review.sh classification logic into the policy engine.
  If P0-C decommissions auto-review.sh and a future need surfaces, that
  backport is a separate initiative.
- Fixing the test-codex-gate-stop.sh production-sequence gap if the fix
  requires changes outside `tests/scenarios/`. P0-E is allowed to identify
  and document the gap; the actual `.mjs` invocation harness build is
  explicitly permitted to slip to backlog.

#### Architecture Decisions

##### DEC-PHASE0-001: `WorktreeCreate` wiring is verified-live and stays

**Sources of truth checked:**
1. Official Claude Code docs at `https://code.claude.com/docs/en/hooks` —
   `WorktreeCreate` is listed as a real event. Exit-2 blocks. No matcher.
2. `runtime/dispatch-debug.jsonl` capture window (651 events) — 0 hits, but
   also 0 `Agent` invocations carrying `isolation: "worktree"`, so the
   trigger was never exercised. Absence is non-falsifying.
3. `hooks/HOOKS.md` — does not document the event (drift item, captured in
   P0-H delta).

**Decision:** Keep the `WorktreeCreate` block in `settings.json` (lines
92-102 of c7a3109). Track `hooks/block-worktree-create.sh` (currently
untracked) so the wiring resolves to a real file. Add a hook-path
verification test that invokes `block-worktree-create.sh` directly with a
synthetic stdin payload and asserts `exit 2` plus the deny message on stderr.
Do NOT attempt to also exercise the harness end of the contract — that
requires triggering `isolation: "worktree"`, which the orchestrator is now
prohibited from doing per `DEC-GUARD-WT-005`. The hook-script test suffices
to prove "if the harness emits this event, our hook denies it".

##### DEC-PHASE0-002: `PreToolUse: matcher="EnterWorktree"` is unsupported and removed

**Sources of truth checked:**
1. Official Claude Code docs — `EnterWorktree` is NOT in the event list AND
   NOT in the PreToolUse tool-matcher list. The documented PreToolUse matchers
   are `Bash, Edit, Write, Read, Glob, Grep, Agent, WebFetch, WebSearch,
   AskUserQuestion, ExitPlanMode` plus MCP regex patterns.
2. `runtime/dispatch-debug.jsonl` capture window — 0 hits across 651 events,
   including 38 PreToolUse:Agent and 547 PreToolUse:Bash. If `EnterWorktree`
   were a real PreToolUse tool name, the dispatch-debug capture would have
   logged it (the capture writer is wired on PreToolUse:Bash, PreToolUse:Task,
   and PreToolUse:Agent — not on PreToolUse:EnterWorktree, but the capture
   writer would still be matched if the harness had emitted PreToolUse with
   tool_name=EnterWorktree on any wired matcher; it never has).
3. `hooks/HOOKS.md` — silent on `EnterWorktree`. (Drift item.)

**Decision:** Remove the entire `PreToolUse: matcher="EnterWorktree"` block
from `settings.json` (lines 103-113 of c7a3109). This is dead config. The
worktree-authority policy is preserved through (a) the live `WorktreeCreate`
event hook (DEC-PHASE0-001), (b) the existing `bash_worktree_creation` policy
that denies `git worktree add` from non-Guardian roles via `pre-bash.sh`, and
(c) the `bash_worktree_nesting` policy. No protection is lost.

##### DEC-PHASE0-003: `auto-review.sh` is decommissioned

**Sources of truth checked:**
1. `git show c7a3109 -- settings.json` confirms `auto-review.sh` was removed
   from `PreToolUse:Bash` in c7a3109 and replaced with the dispatch-debug
   logger.
2. `hooks/auto-review.sh` is still tracked (36 KB, 840 lines per HOOKS.md).
   Three scenario tests still exist: `tests/scenarios/test-auto-review.sh`,
   `tests/scenarios/test-auto-review-heredoc.sh`,
   `tests/scenarios/test-auto-review-quoted-pipes.sh`.
3. `hooks/HOOKS.md:136, :166, :264-279` still documents auto-review.sh as
   live. (Drift item P0-H captures.)
4. `tests/runtime/policies/test_enforcement_gaps.py:14` references
   `auto-review.sh heredoc crash (bash-level test in test_auto_review_heredoc.sh)`
   — Gap 3 from INIT-ENFORCE is anchored on a hook the production chain no
   longer runs.
5. Operational history: `DEC-ENFORCE-004` patched a heredoc-induced
   non-zero-exit fail-open in this same file. The classification engine
   duplicated UX logic that could (and did) crash, on top of the policy
   engine's hard-security boundaries.

**Trade-off considered (the alternative branch):**
- *Restore + rewire.* Re-add `auto-review.sh` to `PreToolUse:Bash` after
  `pre-bash.sh`. Re-document in HOOKS.md. Keep all three scenario tests.
  Extend `tests/runtime/test_hook_config.py` to assert it is wired.
  Cost: re-introduces the parallel-mechanism failure mode the policy engine
  was meant to eliminate (Sacred Practice #12). Exposes us to the same class
  of crash bugs DEC-ENFORCE-004 was forced to patch. Re-couples UX-layer
  classification to the security-layer chain.

**Decision: Decommission.** Delete `hooks/auto-review.sh` and the three
scenario tests. Remove HOOKS.md sections that document it (folded into P0-H).
Update `tests/runtime/policies/test_enforcement_gaps.py` to drop the Gap 3
reference comment. The policy engine via `pre-bash.sh` continues to handle
hard security boundaries; permission UX falls back to the harness's native
allow/deny prompt for any command not pre-approved in
`settings.json:permissions.allow`. If a future need for tier-based UX
classification surfaces, the right home is a new policy in
`runtime/core/policies/`, not a parallel shell hook. That work, if it
happens, is its own initiative — not Phase 0.

##### DEC-PHASE0-004: `hooks/HOOKS.md` is reduced in scope, not rewritten

**Sources of truth checked:**
- Official Claude Code docs as the canonical harness contract.
- Repo internals (bash policies, plan-check, state files, runtime bridge,
  hook-safety wrapper) which are NOT documented in the official docs because
  they belong to this project, not to Claude Code.

**Trade-off considered (the alternative branches):**
- *Full rewrite to match official docs.* Cost: HOOKS.md becomes a second
  source of truth for harness semantics, immediately starts drifting again
  the next time the official docs change. Violates Sacred Practice #12.
- *Delete HOOKS.md entirely.* Cost: loses the legitimate internal-mechanism
  documentation (bash policy table, state-file inventory, runtime bridge
  sentinel contract, escalating-gate pattern, enforcement coverage, etc.)
  which has no equivalent in the official docs.

**Decision: Reduce scope.** Strip every claim about harness semantics from
HOOKS.md. Replace with a banner at the top of the file pointing to
`https://code.claude.com/docs/en/hooks` as the sole authority for: hook event
catalog, exit-code semantics, parallel/sequential execution, JSON schemas,
matcher syntax. Retain the sections that describe THIS repo's internal
mechanisms: shared libraries (`log.sh`, `context-lib.sh`,
`runtime-bridge.sh`), bash policy behaviors, plan-check scoring, state-file
inventory, enforcement coverage, the escalating-gate pattern, and the
runtime-bridge sentinel contract (`__FAIL_CLOSED__`). Remove every section
about `auto-review.sh` (folded into P0-C decommission). Add a "Last verified
against official docs on" date stamp.

##### DEC-PHASE0-005: Hook config invariant test is extended, not rewritten

`tests/runtime/test_hook_config.py` currently asserts only that
`stop-review-gate-hook.mjs` is wired into `Stop` and every `SubagentStop`
matcher (47 lines, single test function). It does not enforce the more
general invariant: every `$HOME/.claude/hooks/*.sh` command referenced from
`settings.json` must resolve to a tracked file in `hooks/`.

**Decision:** Add a second test function in the same file
(`test_repo_owned_hook_commands_resolve_to_tracked_files`) that walks every
hook entry in `settings.json`, parses out commands matching the pattern
`$HOME/.claude/hooks/<name>.sh`, and asserts (a) the file exists at
`hooks/<name>.sh` relative to repo root and (b) `git ls-files hooks/<name>.sh`
returns a non-empty result. Commands that do not match the pattern (the
node entrypoints like `node $HOME/.claude/plugins/.../stop-review-gate-hook.mjs`,
the inline shell capture writer `{ cat; echo; } >> ...`) are explicitly
excluded — the test only governs **repo-owned shell hooks**. This is the
mechanical guard that would have caught `block-worktree-create.sh` being
untracked at c7a3109.

##### DEC-PHASE0-006: Hook-path verification gap is identified, fix is partial

`tests/scenarios/test-codex-gate-stop.sh` exercises the dispatch-side of the
codex stop-review gate (it emits `codex_stop_review` events directly via
`cc-policy event emit` and asserts `dispatch process-stop` reads them), but
it never invokes the actual emitter — the file
`plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs`.
The production sequence is `Claude harness fires SubagentStop -> .mjs hook
runs -> hook emits the event -> dispatch_engine reads the event`. The
existing scenario test only covers the second-half of that chain.

**Decision:** This is real coverage debt. Phase 0 acknowledges it but does
NOT close it, because closing it requires building a Node-side test harness
that simulates a `SubagentStop` payload, invokes the `.mjs` file as a
subprocess with a stdin JSON payload, and asserts the resulting events-table
row. That is materially larger than the rest of Phase 0 combined and would
delay the hygiene cleanup.

**Phase 0 deliverable for P0-E:** A backlog issue with the exact target
file (`plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs`),
the exact gap description (production-sequence test missing for the .mjs
emitter half of the codex stop-review path), the exact existing test that
covers the dispatch half (`tests/scenarios/test-codex-gate-stop.sh`), and a
sketch of the proposed Node-subprocess scenario test. This issue is filed
under labels `phase-0-followup, hook-authority, test-coverage`. Phase 0 does
not block on it.

##### DEC-PHASE0-007: Runtime artifact gitignore additions are scoped

Four artifacts are currently uncommitted in the working tree:
- `runtime/cc_state.db` — runtime SQLite state (per-session); never committed.
- `runtime/dispatch-debug.jsonl` — dispatch capture log; the log writer is
  wired in `settings.json:144,159,174,234,251,276,301,326`.
- `runtime/prebash-trace.log` — pre-bash trace log emitted by `pre-bash.sh`.
- `traces/` — historical capture directory used by the capture
  infrastructure (DEC-CAP-001/002).

**Decision:** Add these four entries to `.gitignore` under a new section
`# Runtime capture artifacts`. Do not commit any existing instance. Do NOT
extend the gitignore to cover anything else: this work item is artifact
hygiene, not architectural. The existing `state.db`, `state.db-shm`,
`state.db-wal` entries (lines 8-10 of `.gitignore`) cover top-level state
DBs; the new entries are explicit because the `runtime/` versions are at
non-root paths.

##### DEC-PHASE0-008: Leaked fixture marker is deactivated, root cause is backlog

The active `agent_id='foo'` row in
`/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/.claude/state.db`'s
`agent_markers` table is a fixture leak — a unit test created the marker
against the live project DB instead of an isolated test DB. Implementer for
P0-G runs:
```sql
UPDATE agent_markers
SET is_active = 0, status = 'expired', stopped_at = strftime('%s','now')
WHERE agent_id = 'foo' AND project_root = '/private/tmp/project';
```
against `/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/.claude/state.db`.

**Decision:** Phase 0 deactivates the marker (one-shot cleanup). The
underlying defect (test fixtures writing to the live state DB) is filed as a
separate backlog issue with the exact symptoms and the schema columns
verified during planning (`agent_id, role, started_at, stopped_at,
is_active, workflow_id, status, project_root`). The fix to test isolation is
NOT Phase 0 work because it touches `tests/runtime/conftest.py` and other
test-infrastructure code, which is a meaningfully bigger surface than P0-G's
hygiene mandate.

#### HOOKS.md ↔ official docs delta (input to P0-H)

This is the complete delta produced during Phase 0 planning. Three items
were already known going in (catalogued as the "verified divergences"); the
remaining items were discovered during the planning audit.

| # | HOOKS.md location | HOOKS.md claim | Official docs (https://code.claude.com/docs/en/hooks) | Action in P0-H |
|---|---|---|---|---|
| 1 | line 9 | "Non-zero = hook error (logged, does not block)." | "PreToolUse exit code 2 blocks the tool call" (and similarly for SubagentStop, Stop, UserPromptSubmit, TaskCreated, TaskCompleted, Elicitation, ElicitationResult, WorktreeCreate, ConfigChange). | Strip the blanket claim. Replace with a pointer: "Exit code 2 has event-specific blocking semantics — see the official docs." |
| 2 | line 155 | "Hooks within the same event run sequentially in array order from settings.json. A deny from any PreToolUse hook stops the tool call — later hooks in the chain don't run." | "All matching hooks run in parallel, and identical handlers are deduplicated automatically." | Strip the claim. Replace with: "All matching hooks run in parallel per the official docs. The pre-bash and pre-write chains rely on first-deny-wins inside the policy engine, NOT on bash-script ordering." Adjust any internal description that depended on sequential-order semantics. |
| 3 | lines 136, 166, 264-279 | `auto-review.sh` is documented as live in PreToolUse:Bash and as a 840-line three-tier classifier. | Not applicable to official docs. The c7a3109 diff removed `auto-review.sh` from the live wiring; the file is an orphan and is decommissioned by P0-C. | Delete every reference to `auto-review.sh`. Delete the "Key auto-review.sh Behaviors" section (lines 264-279). |
| 4 | line 21 | `SubagentStart/SubagentStop hooks receive {"subagent_type": "planner|implementer|tester|guardian", ...}. Stop hooks receive {"response": "..."}.` | Stop hooks receive `last_assistant_message` (verified empirically: 651 captured events show `last_assistant_message` as the field name). The repo memory `reference_claude_code_hook_schema.md` confirms: "Response body is `last_assistant_message`, NOT `.assistant_response`." Both keys appear in the JSONL because `assistant_response` is a legacy field. | Update the schema description to name `last_assistant_message` as the canonical field and note `assistant_response` as a legacy alias. |
| 5 | lines 23-56 | Documents three PreToolUse stdout response shapes (deny, rewrite, advisory) with `hookSpecificOutput.permissionDecision`. | Official docs include additional event-specific output schemas not represented in HOOKS.md, including `hookSpecificOutput.worktreePath` for `WorktreeCreate`. | Add a brief mention that PreToolUse is one of many events with hook-specific output shapes; refer to the official docs for the complete catalog. Do NOT attempt to enumerate all events — that creates new drift surface. |
| 6 | line 415 | "Event names: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Notification, SubagentStart, SubagentStop, PreCompact, Stop, SessionEnd" | Official catalog includes 26 events, of which the local list misses: PermissionRequest, PermissionDenied, PostToolUseFailure, TaskCreated, TaskCompleted, StopFailure, TeammateIdle, InstructionsLoaded, ConfigChange, CwdChanged, FileChanged, WorktreeCreate, WorktreeRemove, PostCompact, Elicitation, ElicitationResult. | Strip the local enumeration entirely. Replace with a pointer to the official event reference. |
| 7 | line 416 | "matcher: Pipe-delimited tool names for PreToolUse/PostToolUse, agent types for SubagentStop, event subtypes for SessionStart/Notification. Optional — omit to match all." | The official PreToolUse/PostToolUse matcher list is `Bash, Edit, Write, Read, Glob, Grep, Agent, WebFetch, WebSearch, AskUserQuestion, ExitPlanMode` plus MCP regex patterns. `WorktreeCreate` and `WorktreeRemove` explicitly do not support matchers. | Replace with a pointer to the official matcher reference. Note explicitly: "`Task` is a legacy alias for the Agent tool name; `EnterWorktree` is not a real matcher (DEC-PHASE0-002)." |
| 8 | line 28 (deny output schema) | Schema example uses `hookEventName: "PreToolUse"` inside `hookSpecificOutput`. | This is correct per official docs and per ENFORCE-RCA-11 (which restored `hookEventName` to `_handle_evaluate` JSON output). No drift. | No action needed. (Listed for completeness so the audit is exhaustive.) |
| 9 | lines 297-299 (feedback loops table) | "lint.sh — Linter finds fixable issues" "plan-validate.sh — MASTER_PLAN.md fails structural validation" "forward-motion.sh — Response ends with bare completion". The table claims these are PostToolUse exit-2 feedback loops. | The official docs say PostToolUse cannot block. Exit code 2 in PostToolUse is documented as "additionalContext fed to model" not "blocks the tool call." | The HOOKS.md description is approximately right (it says "feedback loop, model retries") but the framing is misleading. Clarify: PostToolUse exit-2 surfaces stderr to Claude as additionalContext; it does not block. The model deciding to retry is a model-side behavior, not a hook-enforced retry. |
| 10 | lines 195-197 (Stop hooks) | Documents `surface.sh, session-summary.sh, forward-motion.sh` as the Stop chain. | The Stop chain in `settings.json:358-383` now also includes the `stop-review-gate-hook.mjs` invocation (added by ENFORCE-RCA-15). HOOKS.md does not mention this. | Add a brief entry for the stop-review gate to the Stop hook table, or — preferred — add a single sentence pointing the reader at `settings.json` as the authority for live hook chain order, and remove the per-hook tables entirely (they are continuously drifting against `settings.json`). |
| 11 | line 103 (context-lib.sh table) | Documents helpers like `read_evaluation_status`, `current_workflow_id`, etc. | These are repo-internal, not in the official docs. No drift. | Keep as-is. This is the kind of internal-mechanism documentation HOOKS.md should retain. |

**Total drift items: 9 substantive (#1-7, #9, #10), 2 accurate-but-listed-for-completeness (#8, #11).**

#### Work items

The eight work items below each become a discrete dispatch chain. Each chain
runs through the canonical sequence (planner -> guardian provision ->
implementer -> tester -> guardian merge) on a Guardian-provisioned worktree
off `fix/enforce-rca-13-git-shell-classifier` (NOT off main — Phase 0 lands
on top of c7a3109).

##### P0-A: Hook surface audit (planning artifact only)

- **Status:** completed during this planning pass (verdict captured in
  DEC-PHASE0-001 and DEC-PHASE0-002)
- **Goal:** Determine the live status of `WorktreeCreate` and
  `PreToolUse:EnterWorktree` against the installed harness.
- **Verdict:** `WorktreeCreate` = verified-live (official docs).
  `PreToolUse: matcher="EnterWorktree"` = unsupported (absent from official
  docs). Empirical capture in `dispatch-debug.jsonl` (651 events) is
  consistent with both verdicts and adds no further evidence.
- **No implementer dispatch.** The verdicts feed P0-B's wiring decisions.

##### P0-B: Worktree interception cleanup

- **Status:** planned
- **Goal:** Apply DEC-PHASE0-001 and DEC-PHASE0-002 to the repo: track
  `hooks/block-worktree-create.sh`, remove the dead `EnterWorktree` matcher
  from `settings.json`, add a hook-script test for `block-worktree-create.sh`.
- **Acceptance criteria:**
  - `git ls-files hooks/block-worktree-create.sh` returns the file.
  - `settings.json` contains the `WorktreeCreate` block (unchanged from
    c7a3109 lines 92-102).
  - `settings.json` contains NO `PreToolUse` block with
    `matcher: "EnterWorktree"`.
  - A new scenario test `tests/scenarios/test-block-worktree-create.sh`
    pipes a synthetic JSON payload to `bash hooks/block-worktree-create.sh`
    and asserts (a) exit status 2, (b) stderr contains "DENIED:
    Harness-managed worktree creation is disabled", (c) stderr names the
    correct guardian provisioning command.
  - The test is invoked from `tests/scenarios/run-all-scenarios.sh` (or the
    canonical scenario runner — implementer verifies the actual filename
    before adding the entry).
- **Dependencies:** None. (P0-A is a planning artifact only.)
- **Adjacent components:** `bash_worktree_creation.py`,
  `bash_worktree_nesting.py`, the `worktrees` SQLite table. Do NOT modify
  these — the worktree-authority policy is preserved through them.
- **Carve-out note for #34 (`cc-policy worktree remove is DB-only`):** P0-B
  must NOT touch the `cc-policy worktree remove` implementation. #34 is
  adjacent surface, explicitly forbidden in the scope manifest, will be
  handled in its own chain.
- **Decision Log placeholder:** `DEC-PHASE0-WIRING-001` (to be assigned by
  the implementer/tester at completion).

##### P0-C: Auto-review.sh decommission

- **Status:** planned
- **Goal:** Apply DEC-PHASE0-003: delete `hooks/auto-review.sh`, delete the
  three orphan scenario tests, remove HOOKS.md sections that document it,
  remove the Gap 3 reference comment in `test_enforcement_gaps.py`.
- **Acceptance criteria:**
  - `hooks/auto-review.sh` does not exist (`git ls-files | grep auto-review.sh`
    returns empty).
  - `tests/scenarios/test-auto-review.sh`,
    `tests/scenarios/test-auto-review-heredoc.sh`,
    `tests/scenarios/test-auto-review-quoted-pipes.sh` do not exist.
  - `grep -rn "auto-review" hooks/HOOKS.md` returns zero hits (HOOKS.md
    cleanup is partially overlapping with P0-H, but the three sections that
    specifically document auto-review.sh are removed in this work item).
  - `tests/runtime/policies/test_enforcement_gaps.py:14` no longer references
    `auto-review.sh heredoc crash` (the Gap 3 docstring line is updated to
    note the gap is decommissioned; the test_lease_role_mismatch_denied_end_to_end
    test and other Gap 1/2/4/5 tests are NOT touched).
  - `python3 -m pytest tests/runtime -q` reports zero new failures vs the
    pre-change baseline.
  - Full scenario suite (`bash tests/scenarios/run-all-scenarios.sh` or the
    canonical runner) reports zero new failures.
- **Dependencies:** None. Independent of P0-B and P0-D.
- **Removal targets:** `hooks/auto-review.sh`, three scenario tests, three
  HOOKS.md sections.
- **Decision Log placeholder:** `DEC-PHASE0-AUTOREVIEW-001`.

##### P0-D: Hook config invariant test

- **Status:** planned
- **Goal:** Apply DEC-PHASE0-005: extend `tests/runtime/test_hook_config.py`
  with the general invariant test.
- **Acceptance criteria:**
  - New test function `test_repo_owned_hook_commands_resolve_to_tracked_files`
    exists in `tests/runtime/test_hook_config.py`.
  - The test parses every command in `settings.json` under `hooks.*.hooks[].command`,
    extracts paths matching the regex `^\$HOME/\.claude/hooks/([A-Za-z0-9_-]+\.sh)$`
    (or equivalent), and for each match: (a) asserts the file exists at
    `<repo_root>/hooks/<name>.sh`, (b) asserts
    `subprocess.run(["git", "ls-files", "hooks/<name>.sh"], cwd=repo_root,
    capture_output=True, text=True).stdout.strip()` is non-empty.
  - Commands not matching the pattern (node entrypoints, inline shell
    capture writers `{ cat; echo; } >> ...`) are EXCLUDED via the regex.
    The test must NOT fail on `node $HOME/.claude/plugins/.../stop-review-gate-hook.mjs`.
  - The test additionally asserts that `hooks/block-worktree-create.sh` is
    one of the tracked files (this is the specific invariant for P0-B's
    wiring decision).
  - Running the test against c7a3109 (without P0-B's tracking commit)
    FAILS — proving the test would catch the regression. Implementer
    verifies this manually before submission.
  - Running the test after P0-B lands PASSES.
- **Dependencies:** P0-B (`block-worktree-create.sh` must be tracked before
  this test can pass; the planner sequencing recommendation puts P0-D AFTER
  P0-B).
- **Decision Log placeholder:** `DEC-PHASE0-INVARIANT-001`.

##### P0-E: Hook-path verification gap (backlog filing only)

- **Status:** planned (low effort — filing only)
- **Goal:** Apply DEC-PHASE0-006: file the production-sequence test gap as a
  backlog issue with full target-file detail. Phase 0 does NOT close the gap.
- **Acceptance criteria:**
  - A new GitHub issue exists titled along the lines of
    "test-codex-gate-stop.sh bypasses .mjs emitter — production-sequence
    coverage missing". Labels: `phase-0-followup`, `hook-authority`,
    `test-coverage`.
  - The issue body identifies: (a) the existing test
    `tests/scenarios/test-codex-gate-stop.sh`, (b) the exact gap (the test
    emits `codex_stop_review` events directly via `cc-policy event emit`
    instead of invoking the .mjs hook subprocess), (c) the target file that
    should be exercised
    (`plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs`),
    (d) a sketch of the proposed Node-subprocess scenario test
    (`echo '<json>' | node ...stop-review-gate-hook.mjs`, then assert events
    table contents), (e) the rationale for slipping it from Phase 0
    (materially larger surface than the rest of Phase 0 combined).
  - No source files are modified for P0-E. The work item is a backlog file
    operation only.
- **Dependencies:** None.
- **Decision Log placeholder:** `DEC-PHASE0-COVERAGE-001`.

##### P0-F: Runtime artifact gitignore

- **Status:** planned
- **Goal:** Apply DEC-PHASE0-007: add four entries to `.gitignore`.
- **Acceptance criteria:**
  - `.gitignore` contains a new section `# Runtime capture artifacts` with
    exactly these four lines (in this order):
    ```
    runtime/cc_state.db
    runtime/dispatch-debug.jsonl
    runtime/prebash-trace.log
    traces/
    ```
  - `git status --short runtime/cc_state.db runtime/dispatch-debug.jsonl
    runtime/prebash-trace.log traces/` after the change reports zero
    untracked entries (the existing files are now ignored).
  - No existing `.gitignore` lines are modified or removed.
- **Dependencies:** None. Independent of all other P0 work.
- **Decision Log placeholder:** `DEC-PHASE0-IGNORE-001`.

##### P0-G: Leaked fixture marker cleanup + backlog filing

- **Status:** planned
- **Goal:** Apply DEC-PHASE0-008: deactivate the leaked `foo` marker AND
  file the underlying fixture-isolation defect as backlog.
- **Acceptance criteria:**
  - After implementer runs the cleanup, the query
    `SELECT count(*) FROM agent_markers WHERE agent_id='foo' AND is_active=1`
    against `/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/.claude/state.db`
    returns 0.
  - The deactivation uses an UPDATE (not a DELETE) — the historical row is
    preserved as evidence with `is_active=0, status='expired',
    stopped_at=<epoch>`. Implementer must use the verified column names
    (`is_active`, NOT `active`; `started_at`/`stopped_at` are epoch
    seconds).
  - A new GitHub issue is filed titled along the lines of
    "tests/runtime fixtures write to live state.db instead of isolated DB
    (root cause of leaked `foo` marker)". Labels: `phase-0-followup`,
    `hook-authority`, `test-isolation`. Body identifies: the symptom
    (leaked `foo` marker discovered in P0-G), the schema columns observed,
    the candidate root cause (test fixtures missing `CLAUDE_POLICY_DB`
    isolation), the recommended fix scope (`tests/runtime/conftest.py` or
    equivalent harness), the explicit reason it slipped from Phase 0
    (test-infrastructure surface is bigger than P0-G's hygiene mandate).
- **Dependencies:** None.
- **Decision Log placeholder:** `DEC-PHASE0-MARKER-001`.

##### P0-H: HOOKS.md authority reset

- **Status:** planned
- **Goal:** Apply DEC-PHASE0-004: reduce HOOKS.md scope to internal-mechanism
  documentation, remove harness-semantics claims, point readers to the
  official docs.
- **Acceptance criteria:**
  - HOOKS.md begins with a banner block (max 5 lines) stating the official
    docs at `https://code.claude.com/docs/en/hooks` are the sole authority
    for: hook event catalog, exit-code semantics, parallel/sequential
    execution, JSON input/output schemas, matcher syntax. Banner includes a
    "Last verified against official docs on 2026-04-07" date stamp.
  - The 11 delta items in the HOOKS.md drift table above are all addressed:
    items #1-#7, #9, #10 are removed or rewritten per the table; #8 and #11
    are unchanged.
  - The "Key auto-review.sh Behaviors" section (lines 264-279 of c7a3109)
    is deleted (overlapping with P0-C).
  - The "Execution Order (Session Lifecycle)" diagram (lines 129-153) is
    either deleted or replaced with a pointer that "live hook order is
    defined in `settings.json`; this document does not duplicate it."
  - The "settings.json Registration" section (lines 392-418) is replaced
    with a one-line pointer to the official settings docs and the example
    block is removed.
  - Internal-mechanism sections (Shared Libraries, Bash Policy Behaviors,
    plan-check.sh, State Files, Runtime bridge sentinels, Enforcement
    Coverage, Escalating Gates, Feedback Loops as feedback semantics ONLY)
    are RETAINED.
  - `grep -rn "hooks/HOOKS.md" hooks/ runtime/ tests/` shows no
    cross-reference broken — any internal references that pointed to a
    deleted section are updated to point to the official docs instead.
- **Dependencies:** P0-A (verdicts), P0-C (auto-review.sh decommission must
  land before HOOKS.md can lose its auto-review.sh sections cleanly).
- **Decision Log placeholder:** `DEC-PHASE0-HOOKSMD-001`.

#### Sequencing

Phase 0 work items break into three groups by dependency:

**Independent (can run in parallel after Phase 0 starts):**
- P0-B (worktree wiring cleanup)
- P0-C (auto-review.sh decommission)
- P0-E (backlog filing — file-only, no source edits)
- P0-F (gitignore additions)
- P0-G (fixture marker deactivation + backlog)

**Sequenced (must follow specific predecessors):**
- P0-D (hook config invariant test) — must follow P0-B (because the test
  asserts `block-worktree-create.sh` is tracked, and that tracking happens
  in P0-B).
- P0-H (HOOKS.md authority reset) — must follow P0-C (because P0-H removes
  HOOKS.md sections that describe auto-review.sh, which P0-C is decommissioning).

**Critical path:** `P0-B -> P0-D` and `P0-C -> P0-H`. Both critical paths
have length 2. Maximum parallel width is 5 work items in the first wave
(P0-B, P0-C, P0-E, P0-F, P0-G), then 2 in the second wave (P0-D, P0-H).

**Recommended dispatch order if running serially (one chain at a time):**
P0-F -> P0-G -> P0-E -> P0-B -> P0-C -> P0-D -> P0-H. Rationale: cheap
hygiene first (gitignore, marker, backlog) to clear the working tree and
get fast wins; then the wiring cleanup pair (P0-B then P0-D) which has the
strongest mechanical guard once landed; then the documentation pair (P0-C
then P0-H) which is the largest text surface.

#### State-authority map (Phase 0 scope only)

| Domain | Canonical authority | Phase 0 writers | Phase 0 readers |
|---|---|---|---|
| `settings.json` | Sole hook wiring authority | P0-B (removes EnterWorktree matcher) | P0-D (the new invariant test) |
| `hooks/HOOKS.md` | Internal mechanism documentation only (after P0-H) | P0-C (removes auto-review.sh sections), P0-H (full reset) | none in Phase 0 |
| `hooks/block-worktree-create.sh` | New repo-tracked file after P0-B | P0-B (tracks the file via git add) | P0-D (asserts trackedness), P0-B test |
| `tests/runtime/test_hook_config.py` | Hook wiring invariant test | P0-D (extends with the new test function) | none |
| `tests/scenarios/test-block-worktree-create.sh` (NEW) | Hook-script behavior test for block-worktree-create.sh | P0-B (creates) | scenario runner |
| `.gitignore` | Repo gitignore | P0-F | git |
| `agent_markers` table in `.claude/state.db` | runtime/core agent markers domain | P0-G (one UPDATE) | the runtime |
| GitHub issues | Backlog tracking | P0-E (codex .mjs gap), P0-G (fixture isolation) | future planners |
| `tests/runtime/policies/test_enforcement_gaps.py` | Enforcement gap tests (Gaps 1-5) | P0-C (removes Gap 3 docstring reference only) | none |

#### Forbidden touch points (universal across every Phase 0 work item)

These files MUST NOT be modified by any P0 implementer. The orchestrator
writes the Scope Manifest to runtime via `cc-policy workflow scope-set`
before each implementer dispatch with these in the `--forbidden` list:

```
runtime/core/dispatch_engine.py
runtime/core/completions.py
runtime/core/policies/bash_eval_readiness.py
runtime/core/policies/
runtime/core/enforcement_config.py
hooks/pre-bash.sh
hooks/pre-write.sh
hooks/check-implementer.sh
hooks/check-tester.sh
hooks/check-guardian.sh
hooks/post-task.sh
runtime/cc_state.db
plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs
plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs
```

The reviewer-cut surface (`dispatch_engine`, `completions`,
`bash_eval_readiness`, `enforcement_config` reviewer extensions, the codex
.mjs hook) is forbidden because Phase 1+ owns those files. The check-*
hooks and post-task.sh are forbidden because they own dispatch routing
which will be replaced when the reviewer stage lands; touching them now
risks Phase 0 holding state Phase 1 must throw away.

#### Per-work-item Scope Manifests (verbatim, for `cc-policy workflow scope-set`)

Each manifest is provided as the JSON arrays the orchestrator passes to
`cc-policy workflow scope-set <workflow-id> --allowed <json> --required
<json> --forbidden <json> --authorities <json>`. Workflow IDs are in the
form `phase0-<work-item-letter>` (for example `phase0-b`). The `--forbidden`
array is identical across every work item (the universal Phase 0 forbidden
touch points listed immediately above) plus per-item additions where
relevant.

**Why scope-set is NOT pre-written by the planner:** `cc-policy workflow
scope-set` requires a prior `cc-policy workflow bind <id> <worktree_path>
<branch>` call (verified empirically: scope-set against `phase0-a` returned
`workflow_id 'phase0-a' not found in workflow_bindings. Call bind_workflow
first.`). `bind` requires the worktree path and branch, which are only
determined when Guardian provisions the worktree. The planner therefore
captures the scope manifests as canonical text in this section; the
orchestrator copies the matching JSON arrays into a `cc-policy workflow
scope-set` invocation immediately after Guardian provision (after `bind`)
and immediately before implementer dispatch. This split keeps the planner
deliverable fully specified while honoring the bind-then-scope ordering
the runtime enforces.

##### P0-B scope manifest
- `--allowed`:
  `["hooks/block-worktree-create.sh","settings.json","tests/scenarios/test-block-worktree-create.sh","tests/scenarios/run-all-scenarios.sh"]`
  (the runner filename is verified by the implementer before submission;
  if the canonical runner has a different name, the manifest is updated by
  the orchestrator before dispatch)
- `--required`:
  `["hooks/block-worktree-create.sh","settings.json","tests/scenarios/test-block-worktree-create.sh"]`
- `--forbidden`: universal Phase 0 forbidden list above.
- `--authorities`: `["settings.json","worktree_authority_policy"]`
- **Required evidence:** official docs section on `WorktreeCreate` and on
  PreToolUse matchers (DEC-PHASE0-001 and DEC-PHASE0-002 verdicts);
  empirical zero-hit count from `runtime/dispatch-debug.jsonl`.
- **Evaluation Contract (P0-B):**
  1. `git ls-files hooks/block-worktree-create.sh` returns the path.
  2. `python3 -c "import json; s=json.load(open('settings.json'));
     wc=s['hooks'].get('WorktreeCreate'); assert wc and any('block-worktree-create.sh' in h['command'] for g in wc for h in g['hooks']), 'WorktreeCreate wiring missing'"`
     succeeds.
  3. `python3 -c "import json; s=json.load(open('settings.json'));
     pt=s['hooks']['PreToolUse']; assert not any(g.get('matcher')=='EnterWorktree' for g in pt), 'EnterWorktree matcher still present'"`
     succeeds.
  4. `bash tests/scenarios/test-block-worktree-create.sh` exits 0 (the test
     itself asserts the hook exits 2 for synthetic input).
  5. `bash tests/scenarios/run-all-scenarios.sh` (or the canonical runner)
     reports zero new failures vs the pre-change baseline. Implementer
     captures the baseline output before starting and the post-change output
     after.
  6. `python3 -m pytest tests/runtime/test_hook_config.py -q` reports zero
     new failures (the existing single test must still pass).
- **Ready-for-guardian definition:** all six checks above produce green raw
  output, captured by the tester in EVAL_TESTS_PASS=true with EVAL_HEAD_SHA
  matching the implementer's commit.

##### P0-C scope manifest
- `--allowed`:
  `["hooks/auto-review.sh","tests/scenarios/test-auto-review.sh","tests/scenarios/test-auto-review-heredoc.sh","tests/scenarios/test-auto-review-quoted-pipes.sh","hooks/HOOKS.md","tests/runtime/policies/test_enforcement_gaps.py"]`
- `--required`:
  `["hooks/auto-review.sh","tests/scenarios/test-auto-review.sh","tests/scenarios/test-auto-review-heredoc.sh","tests/scenarios/test-auto-review-quoted-pipes.sh","hooks/HOOKS.md","tests/runtime/policies/test_enforcement_gaps.py"]`
  (all must change — the four files are deleted, HOOKS.md and
  test_enforcement_gaps.py are edited)
- `--forbidden`: universal Phase 0 forbidden list. Note that the policy
  engine itself is forbidden — this work item does NOT add a replacement
  policy; auto-review.sh is removed without backfill.
- `--authorities`: `["hooks_documentation","tests_scenarios"]`
- **Required evidence:** `git show c7a3109 -- settings.json` confirming
  auto-review.sh removal from live wiring; the four-line history of
  auto-review.sh in `git log -- hooks/auto-review.sh`; DEC-ENFORCE-004
  history showing the heredoc crash.
- **Evaluation Contract (P0-C):**
  1. `test ! -f hooks/auto-review.sh && echo OK` succeeds.
  2. `test ! -f tests/scenarios/test-auto-review.sh && test ! -f
     tests/scenarios/test-auto-review-heredoc.sh && test ! -f
     tests/scenarios/test-auto-review-quoted-pipes.sh && echo OK` succeeds.
  3. `grep -n "auto-review" hooks/HOOKS.md` returns zero hits.
  4. `grep -n "auto-review.sh heredoc crash" tests/runtime/policies/test_enforcement_gaps.py`
     returns zero hits (the docstring line is updated; the actual Gap 3
     test is preserved or rewritten to note the gap is decommissioned).
  5. `python3 -m pytest tests/runtime -q` matches the pre-change baseline
     (zero new failures, possibly one fewer pass if the Gap 3 docstring
     reference was wired into a parametric test — implementer captures
     before/after).
  6. `bash tests/scenarios/run-all-scenarios.sh` reports zero new failures
     and three fewer passes (the three deleted scenario tests).
  7. `git ls-files hooks/auto-review.sh tests/scenarios/test-auto-review*.sh`
     returns empty.
- **Ready-for-guardian definition:** all seven checks produce green raw
  output. Implementer captures pytest summary lines before and after.

##### P0-D scope manifest
- `--allowed`: `["tests/runtime/test_hook_config.py"]`
- `--required`: `["tests/runtime/test_hook_config.py"]`
- `--forbidden`: universal Phase 0 forbidden list. Note specifically that
  `settings.json` is in the universal-forbidden list — P0-D only READS
  settings.json from inside the test, never modifies it.
- `--authorities`: `["hook_wiring_invariant"]`
- **Required evidence:** `settings.json` content as it stands after P0-B
  lands. Implementer must base off the post-P0-B state, not c7a3109
  directly.
- **Evaluation Contract (P0-D):**
  1. The new test function
     `test_repo_owned_hook_commands_resolve_to_tracked_files` exists in
     `tests/runtime/test_hook_config.py`.
  2. `python3 -m pytest tests/runtime/test_hook_config.py -q` reports
     2 passed (the original test plus the new one). No regressions.
  3. The new test parses `settings.json` via `json.load`, walks every
     `hooks.<event>[].hooks[].command`, and matches commands of the form
     `$HOME/.claude/hooks/<name>.sh`. Implementer demonstrates this by
     running the test in verbose mode and showing the parsed list includes
     at least: `session-init.sh`, `prompt-submit.sh`, `block-worktree-create.sh`,
     `test-gate.sh`, `mock-gate.sh`, `pre-write.sh`, `doc-gate.sh`,
     `pre-bash.sh`, `pre-agent.sh`, `lint.sh`, `track.sh`, `code-review.sh`,
     `plan-validate.sh`, `test-runner.sh`, `notify.sh`, `subagent-start.sh`,
     `check-planner.sh`, `check-implementer.sh`, `check-tester.sh`,
     `check-guardian.sh`, `post-task.sh`, `compact-preserve.sh`, `surface.sh`,
     `session-summary.sh`, `session-end.sh`.
  4. The new test does NOT raise on the node entrypoint
     `node $HOME/.claude/plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs`
     or on the inline shell capture writer
     `{ cat; echo; } >> $HOME/.claude/runtime/dispatch-debug.jsonl`.
     Implementer demonstrates this by running the test against the current
     `settings.json` and showing it passes.
  5. **Regression-catching demonstration:** Implementer shows that if
     `hooks/block-worktree-create.sh` is temporarily deleted (or
     `git rm`-ed in a scratch tree), the new test fails with a clear
     message naming the missing file. Implementer reverts the deletion
     before submitting.
- **Ready-for-guardian definition:** all five checks produce green raw
  output, including the regression-catching demonstration.

##### P0-E scope manifest
- `--allowed`: `[]` (no source edits — backlog filing only)
- `--required`: `[]`
- `--forbidden`: universal Phase 0 forbidden list AND every source file in
  the repo. P0-E may ONLY invoke `gh issue create`.
- `--authorities`: `["github_issues"]`
- **Required evidence:** `tests/scenarios/test-codex-gate-stop.sh` content
  (the implementer reads it but does not modify it);
  `plugins/marketplaces/openai-codex/plugins/codex/scripts/stop-review-gate-hook.mjs`
  (read-only).
- **Evaluation Contract (P0-E):**
  1. `gh issue list --label phase-0-followup --label hook-authority --label test-coverage --json number,title`
     returns at least one issue whose title matches the gap description.
  2. `gh issue view <number>` shows: (a) reference to
     `tests/scenarios/test-codex-gate-stop.sh`, (b) reference to the
     `.mjs` target file, (c) sketch of proposed Node-subprocess test.
  3. `git status` shows ZERO modified files. P0-E touches no source.
- **Ready-for-guardian definition:** the issue exists and the working tree
  is clean.

##### P0-F scope manifest
- `--allowed`: `[".gitignore"]`
- `--required`: `[".gitignore"]`
- `--forbidden`: universal Phase 0 forbidden list.
- `--authorities`: `["gitignore"]`
- **Required evidence:** `git status --short` showing the four runtime
  artifacts as untracked at start; the post-change `git status` showing
  them gone.
- **Evaluation Contract (P0-F):**
  1. `grep -n "Runtime capture artifacts" .gitignore` returns one line.
  2. `grep -n "runtime/cc_state.db" .gitignore && grep -n
     "runtime/dispatch-debug.jsonl" .gitignore && grep -n
     "runtime/prebash-trace.log" .gitignore && grep -n "^traces/$"
     .gitignore` all return one line each.
  3. `git status --short runtime/cc_state.db runtime/dispatch-debug.jsonl
     runtime/prebash-trace.log traces/` returns empty.
  4. `git diff .gitignore` shows ONLY additions — no existing lines
     removed.
- **Ready-for-guardian definition:** all four checks pass with raw output.

##### P0-G scope manifest
- `--allowed`: `[]` (no source edits — DB write + backlog filing only)
- `--required`: `[]`
- `--forbidden`: universal Phase 0 forbidden list AND every source file.
  P0-G may invoke `sqlite3` against
  `/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/.claude/state.db`
  AND may invoke `gh issue create`.
- `--authorities`: `["agent_markers","github_issues"]`
- **Required evidence:** the verified row in `agent_markers` (captured
  during planning); the verified column names (`is_active`, `started_at`,
  `stopped_at`).
- **Evaluation Contract (P0-G):**
  1. Before-state: `sqlite3
     /Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/.claude/state.db
     "SELECT count(*) FROM agent_markers WHERE agent_id='foo' AND
     is_active=1"` returns 1.
  2. After cleanup: same query returns 0.
  3. The historical row is preserved: `sqlite3 ... "SELECT agent_id, role,
     status, is_active, stopped_at FROM agent_markers WHERE agent_id='foo'"`
     returns one row with `status='expired'`, `is_active=0`,
     `stopped_at` non-NULL.
  4. `gh issue list --label phase-0-followup --label hook-authority --label
     test-isolation` returns at least one matching issue.
  5. `gh issue view <number>` shows: (a) reference to the leaked `foo`
     marker symptom, (b) the verified schema columns, (c) candidate root
     cause statement (test fixtures using live DB), (d) recommended fix
     scope (`tests/runtime/conftest.py` or equivalent).
  6. `git status` shows ZERO modified source files. The DB file is in
     `.claude/` which is already gitignored at line 12.
- **Ready-for-guardian definition:** all six checks produce green raw
  output.

##### P0-H scope manifest
- `--allowed`: `["hooks/HOOKS.md"]`
- `--required`: `["hooks/HOOKS.md"]`
- `--forbidden`: universal Phase 0 forbidden list. Specifically NOTE that
  `settings.json` is in the universal-forbidden list — P0-H must NOT touch
  settings.json even if it spots a fix while editing HOOKS.md (those fixes
  belong in P0-B or in a new backlog issue).
- `--authorities`: `["hooks_documentation"]`
- **Required evidence:** the 11-item HOOKS.md drift table above; the
  official docs at `https://code.claude.com/docs/en/hooks` (cached during
  planning) and `https://code.claude.com/docs/en/settings`.
- **Evaluation Contract (P0-H):**
  1. `head -10 hooks/HOOKS.md` shows the new banner block referencing the
     official docs URL and a "Last verified against official docs on
     2026-04-07" date stamp.
  2. `grep -n "Non-zero = hook error" hooks/HOOKS.md` returns zero hits
     (drift item #1 removed).
  3. `grep -n "sequentially in array order" hooks/HOOKS.md` returns zero
     hits (drift item #2 removed).
  4. `grep -n "auto-review" hooks/HOOKS.md` returns zero hits (drift item
     #3 + P0-C overlap).
  5. `grep -ni "assistant_response" hooks/HOOKS.md` returns either zero
     hits OR a line that explicitly notes it as a legacy alias and names
     `last_assistant_message` as canonical (drift item #4).
  6. `grep -n "Event names:" hooks/HOOKS.md` either returns zero hits OR
     returns a line that points to the official docs without enumerating
     events (drift item #6).
  7. `grep -n "Pipe-delimited tool names" hooks/HOOKS.md` either returns
     zero hits OR returns a line clarifying the source of the matcher list
     and noting EnterWorktree is not real (drift item #7).
  8. `grep -nA3 "feedback loop" hooks/HOOKS.md` either returns the
     PostToolUse-cannot-block clarification or removes the misleading
     framing (drift item #9).
  9. The "Shared Libraries" section, "Bash Policy Behaviors" section,
     "plan-check.sh" section, "State Files" section, and
     "Runtime bridge sentinels" section are RETAINED (grep returns
     non-empty for each).
  10. `grep -rn "hooks/HOOKS.md" hooks/ runtime/ tests/ scripts/` shows no
      broken cross-references — any prior reference to a deleted section
      is updated to point to the official docs.
- **Ready-for-guardian definition:** all 10 checks produce green raw
  output. Tester additionally spot-checks that no internal-mechanism
  documentation was lost (sections retained match the list above).

#### Quality gate (planner self-check)

- Every guardian-bound work item (P0-B, P0-C, P0-D, P0-F, P0-G, P0-H) has
  an Evaluation Contract with executable acceptance criteria. **Pass.**
- Every guardian-bound work item has a Scope Manifest with explicit file
  boundaries. **Pass.**
- The reviewer-cut surface is forbidden in EVERY work item via the
  universal Phase 0 forbidden list. **Pass.**
- No work item depends on prose completion language; every check in every
  Evaluation Contract is a runnable command with a measurable result.
  **Pass.**
- Dependencies between work items are minimal (P0-B before P0-D, P0-C
  before P0-H) and the critical path is length 2. **Pass.**
- The Phase 0 plan does not reference any of the reviewer-stage scope
  (`reviewer` role, `workflow_review_*` keys, `cc-policy review run`,
  modifications to `dispatch_engine.py` or `completions.py`). **Pass.**
- No prose claim about hook contract is unsupported by either the official
  docs or the empirical capture. **Pass.**

#### Open questions

None. Every decision called out in the planner brief has been resolved with
explicit rationale (DEC-PHASE0-001 through DEC-PHASE0-008) and inline
evidence. If the implementer or tester for any P0 work item discovers an
ambiguity, escalate to the orchestrator before resolving silently.

### INIT-ADMIT: Bootstrap Admission Atomicity and UX Polish

- **Status:** planned (2026-04-29)
- **Workflow id (runtime):** `bootstrap-admission-polish`
- **Goal id (runtime):** `g-initial-planning`
- **Work item id (runtime):** `wi-initial-planning`
- **Base commit:** `9e8689a` on `main` (the commit that introduced the
  `bootstrap_requests` admission table, `runtime/core/bootstrap_requests.py`,
  and `runtime/core/workflow_bootstrap.py`).
- **Goal (Divine User wording, verbatim from bootstrap brief):**
  > Polish the bootstrap admission gate: (a) flip `consume()` to fire before
  > binding/goal/work-item upserts in
  > `workflow_bootstrap.bootstrap_local_workflow` so write-time races resolve
  > atomically rather than after side-effects (closes #68); (b) improve
  > `resolve_pending()` token-not-found error to include the resolved
  > `db_path` and a hint about per-worktree token scoping so operators with
  > the wrong `--worktree-path` get an actionable message (closes #69). Out
  > of scope: any token revocation primitive (#70 deferred — TTL is the
  > safety net).
- **Scope summary (mirrors the runtime `workflow_scope` row that the planner
  must ship to runtime via `cc-policy workflow scope-sync` before implementer
  dispatch):**
  - Allowed touch points: `runtime/core/workflow_bootstrap.py`,
    `runtime/core/bootstrap_requests.py`,
    `tests/runtime/test_planner_bootstrap.py`.
  - Required touch points: all three of the above (the source flip needs both
    modules, and both invariants belong in the bootstrap test file because
    that is already the admission-gate test home).
  - Forbidden touch points: any new CLI subcommand, any schema change,
    `runtime/cli.py` argparse surface, audit-event names
    (`workflow.bootstrap.requested|consumed|denied`), `runtime/schemas.py`,
    `runtime/core/dispatch_engine.py`, `runtime/core/completions.py`, any
    cross-DB scan helper, any new public function in
    `runtime/core/bootstrap_requests.py` beyond the existing
    `issue|resolve_pending|consume` triad.
  - State authorities touched: `bootstrap_requests` table only. Read-side of
    `workflow_bindings`, `goal_contracts`, `work_items`, and
    `evaluation_state` is observed by tests but not modified beyond what the
    existing bootstrap path already does.

#### Empirical baseline (verified against working tree at base commit)

- `runtime/core/workflow_bootstrap.py:281` calls
  `bootstrap_requests_mod.resolve_pending(...)` (read-only validation).
- `runtime/core/workflow_bootstrap.py:362-397` performs the four state-mutating
  upserts in order: `workflows_mod.bind_workflow`,
  `dwr.upsert_goal`, `dwr.upsert_work_item`, `evaluation_mod.set_status`.
- `runtime/core/workflow_bootstrap.py:398-407` builds the planner stage packet
  via `build_stage_packet` (read-side projection).
- `runtime/core/workflow_bootstrap.py:408-413` finally calls
  `bootstrap_requests_mod.consume(...)`. The atomic `UPDATE ... WHERE token=?
  AND consumed=0` lives inside `consume()` at
  `runtime/core/bootstrap_requests.py:228-239`. This is the *only* race-safe
  gate in the file; it fires *after* all write-side side effects.
- `runtime/core/bootstrap_requests.py:134-145` raises
  `BootstrapRequestError("bootstrap token not found")` when the resolved DB
  has no row matching the token. The function signature already takes
  `worktree_path` as the *expected* worktree (used for the `worktree_mismatch`
  branch at lines 163-178), but it does not surface the *resolved DB path*
  that operators need in order to diagnose a `--worktree-path` mismatch.
  `db_path` is currently known only to the caller in
  `workflow_bootstrap.bootstrap_local_workflow` (`runtime/core/workflow_bootstrap.py:276`).
- Existing admission-gate tests live at
  `tests/runtime/test_planner_bootstrap.py`. Specifically:
  `test_bootstrap_request_records_audit_and_returns_replay_command`
  (line 409) covers issuance audit; `test_bootstrap_local_consumes_token_once`
  (line 469) covers replay denial via `resolve_pending`'s
  `already_consumed` branch. There is currently no test for the
  `worktree_mismatch` *DB-mismatch* case (only the in-DB worktree string
  mismatch). There is no race-condition test for atomic admission ordering.
- Repo is currently dirty with unrelated workflow/runtime work
  (`runtime/cli.py`, `runtime/core/agent_prompt.py`, etc.). The implementer's
  Scope Manifest forbids touching any of those paths so the diff stays
  surgical and reviewable; if those edits collide with this initiative they
  must be rebased or staged separately by the orchestrator before implementer
  dispatch.

#### Goals and non-goals

**Goals:**
1. Move `bootstrap_requests_mod.consume(...)` so it is the *first*
   state-mutating call in `bootstrap_local_workflow`, preceding
   `bind_workflow`, `upsert_goal`, `upsert_work_item`, `set_status`, and
   `build_stage_packet`. The atomic UPDATE inside `consume()` becomes the
   admission gate for downstream writes.
2. Improve `bootstrap_requests.resolve_pending` so the `token_not_found`
   denial includes the resolved DB path and an actionable hint about
   per-worktree token scoping.
3. Add invariant tests for both fixes that fail today and pass after the
   change.
4. Keep the full runtime test suite green (5644 passed baseline per the
   bootstrap brief).

**Non-goals (explicit):**
- Closing #70 (`bootstrap-revoke` / `bootstrap-list-pending` primitives) — TTL
  remains the safety net per the user's directive.
- Any cross-DB scan helper that walks `~/.claude/state.db` or sibling state
  DBs to "find" a token in another worktree's DB. That re-introduces the
  divergence pattern that #59 was created to eliminate.
- Restructuring `bind_workflow` / `upsert_goal` / `upsert_work_item` /
  `set_status` to compose under a single outer transaction. Each helper
  currently uses its own `with conn:` context manager, and Python's
  `sqlite3` does not nest those cleanly. Wrapping them is a separate concern
  with broader implications (every caller of those helpers would need
  re-validation).
- Any change to schemas, audit-event names, the CLI surface, or the existing
  admission protocol semantics (issuance, mismatch denials, expiry, replay).
- Any reordering of the post-consume read-side `build_stage_packet` call's
  semantics. Stage-packet construction may stay where it is or move; what
  matters is that `consume()` precedes the four write-side upserts.

#### Architecture Decisions

##### DEC-ADMIT-001: `consume()` becomes the admission gate, not the audit footer

**Sources of truth checked:**
1. `runtime/core/bootstrap_requests.py:211-254` — `consume()` already issues an
   atomic `UPDATE ... WHERE token=? AND consumed=0` and a `rowcount != 1`
   check. The atomicity is real; the only weakness is *when* the call fires
   in the bootstrap sequence.
2. `runtime/core/workflow_bootstrap.py:281-413` — current ordering: validate
   pending → resolve params → validate existing state → bind/goal/upsert/
   evaluation/packet → consume. Two callers can both pass `resolve_pending`
   (read-only) at line 281, then both race through the four write-side
   helpers (which are individually idempotent with respect to one another's
   final state for the bootstrap case), and only one succeeds the atomic
   UPDATE inside `consume()` at line 408. The loser raises
   `BootstrapRequestError("could not be consumed atomically")` *after* their
   binding/goal/work-item writes have already landed.
3. The existing `lease` pattern in this codebase (claim a lease atomically,
   then perform work under that claim) is the canonical idiom for admission
   in this runtime. Bootstrap currently inverts that idiom.

**Trade-off considered (the alternative branches):**
- *Wrap all four write-side helpers in one outer `BEGIN ... COMMIT`.* Cost:
  every helper composes its own transaction internally; nesting them with
  Python `sqlite3` requires either rewriting their internals or using a
  manual savepoint. Both expand scope, change call-site contracts for
  unrelated callers, and risk regressions in non-bootstrap paths. The user's
  brief explicitly forbids this.
- *Add a separate "claim" row before the writes and reconcile after.* Cost:
  introduces a second admission state machine alongside `consumed`, doubling
  the surface for the same property. Drift risk.
- *Leave the order alone and document the wart.* Cost: state still
  *converges* to the right answer (writes are idempotent for the bootstrap
  case), but the loser sees a confusing "could not be consumed atomically"
  error after their writes appear to have succeeded. The audit log records
  `requested → consumed → consumed` for one token and `requested →
  (no consume)` for the other while the database carries side effects from
  both. This is not a security bug, but it is a transactional wart that
  mis-trains operators.

**Decision:** Adopt the lease idiom. Move the `consume()` call to fire
*immediately after* `_validate_existing_state(...)` and *before*
`workflows_mod.bind_workflow(...)`. The atomic UPDATE inside `consume()`
becomes the admission gate; the loser raises before any writes land.

**Trade-off explicitly accepted (token-burn-on-failure):** With this order,
if any of `bind_workflow`, `upsert_goal`, `upsert_work_item`, or
`set_status` raises *after* the admission gate fires, the token is already
consumed and the operator must re-run `bootstrap-request` to mint a fresh
one. Given the schema is fixed, the table set is small, and these helpers
are well-trodden idempotent upserts (covered by their own tests), the
write-time failure mode is rare and recoverable (re-mint is one CLI call).
The reverse failure mode (the current order: write-time success but
admission denial after the fact) leaves a confusing audit trail and is
worse for operators. This trade-off matches every other lease/admission
gate in the runtime.

**Implementer note (one-line annotation requirement):** add an inline
`@decision DEC-ADMIT-001` comment above the moved `consume()` call so the
ordering choice is discoverable from the source, not just from this plan.

##### DEC-ADMIT-002: `resolve_pending` reports the resolved DB path on `token_not_found`

**Sources of truth checked:**
1. `runtime/core/bootstrap_requests.py:115-145` — `resolve_pending` already
   accepts `workflow_id` and `worktree_path` as the *expected* values it
   checks against, and uses them in the `workflow_mismatch` and
   `worktree_mismatch` denial messages. It does *not* know the path of the
   `sqlite3.Connection` it was handed.
2. `runtime/core/workflow_bootstrap.py:276-286` — the caller resolves
   `db_path = Path(target["db_path"])` and opens the connection itself, so
   it has the canonical resolved DB path on hand. Threading it down is a
   one-argument addition.
3. The `--worktree-path` operator path is the actual failure mode that
   surfaces this UX gap. When the operator passes `--worktree-path <wrong>`,
   the runtime opens a different state DB than the one that holds the token;
   the `worktree_mismatch` branch never fires because the row is simply
   absent. The operator only sees `bootstrap token not found` with no
   indication that DB scoping is the issue.

**Trade-off considered (the alternative branches):**
- *Walk all sibling `~/.claude/state.db` files looking for the token.* Cost:
  re-introduces cross-DB lookups, which is exactly the divergence pattern
  #59 was created to eliminate. The user's brief forbids this.
- *Stash a global breadcrumb in `~/.claude/state.db` when a token is issued
  so we can always resolve "where does this token live?".* Cost: adds a
  second admission authority outside the per-worktree DB, drifts on its own
  schedule, requires its own GC. Same Sacred Practice #12 violation.
- *Embed the source DB path in the token string itself.* Cost: tokens
  become path-bound surface-readable strings; surface-only changes can
  desync from runtime; opaque-token property is lost.

**Decision:** Surface the answer in the existing error message. Add an
optional `db_path: str | None = None` keyword argument to
`bootstrap_requests.resolve_pending`. When the row lookup misses, the error
message names the resolved DB path (when supplied) and explains
per-worktree scoping in operator-actionable terms. The caller in
`workflow_bootstrap.bootstrap_local_workflow` passes `db_path=str(db_path)`
when invoking `resolve_pending`; `consume()` already calls `resolve_pending`
internally and must thread the same `db_path` through (one extra keyword on
its signature too, defaulted to `None` so external callers stay
source-compatible).

**Required new error text (operator-actionable, exact wording is at the
implementer's discretion provided it satisfies all four properties):**
1. Names the resolved DB path the runtime actually opened.
2. States that bootstrap tokens are scoped to the worktree where
   `bootstrap-request` was issued.
3. Tells the operator to verify `--worktree-path` matches that worktree.
4. Tells the operator to re-run `bootstrap-request` from the correct
   worktree if the token was issued elsewhere.

A reference shape (not load-bearing wording — the test asserts the four
properties above via substring checks, not equality):

> `bootstrap token not found in <db_path>. Bootstrap tokens are scoped to
> the worktree where bootstrap-request was issued — verify --worktree-path
> matches that worktree. If you issued the token from a different worktree,
> re-run bootstrap-request from the correct one.`

##### DEC-ADMIT-003: Both invariants live in `tests/runtime/test_planner_bootstrap.py`

`tests/runtime/test_planner_bootstrap.py` is already the admission-gate test
home: it covers issuance audit, replay denial, runtime-issued-token
requirement, non-git rejection, explicit-worktree DB resolution, and stale
work-item normalization. The two new invariants belong in the same file so
the admission-gate test surface stays coherent.

**Decision:** Add two new test functions to that file:

1. `test_bootstrap_local_consume_precedes_writes_under_race`
   (covers DEC-ADMIT-001). The test uses an in-process call into
   `runtime.core.workflow_bootstrap.bootstrap_local_workflow` (not the CLI)
   so it can deterministically interleave two callers via either:
   (a) monkeypatching `bootstrap_requests_mod.consume` to call through to
   the real `consume()` *and* trigger a second concurrent
   `bootstrap_local_workflow` call before the first's `consume()` returns,
   or (b) the simpler equivalent: after the first caller's `consume()`
   succeeds (token row now `consumed=1`), invoke
   `bootstrap_local_workflow` a second time with the same token and assert
   that (i) the second call raises `BootstrapRequestError`, (ii) the
   second-call branch's `bind_workflow`/`upsert_goal`/`upsert_work_item`
   writes did *not* run a second time — verified by reading the
   `workflow_bindings` / `goal_contracts` / `work_items` rows back and
   asserting their values match what the *first* caller produced
   byte-for-byte (no second-call mutation observable). The implementer may
   choose either approach; (b) is the minimum viable race surrogate since
   the moved `consume()` still owns the only atomic gate.

   The implementer must add this test in a way that *fails* against the
   pre-DEC-ADMIT-001 ordering (current `main`) and *passes* after the
   reorder. A test that passes against both orderings is not a valid
   invariant test for this fix.

2. `test_resolve_pending_token_not_found_names_db_path_and_worktree_scoping`
   (covers DEC-ADMIT-002). The test issues a bootstrap token in repo A's
   state DB (via the CLI exactly as
   `test_bootstrap_local_uses_explicit_worktree_path_for_db_resolution`
   does today), then runs `bootstrap-local --worktree-path <repo_B>`
   against the same token. Asserts: (i) returncode is 1; (ii) the JSON
   error message contains the path of repo B's state DB
   (the DB the runtime actually opened — not repo A's); (iii) the
   message contains a substring identifying per-worktree scoping (e.g.
   the literal phrase `scoped to the worktree` or
   `different worktree`); (iv) the message tells the operator to verify
   `--worktree-path`.

   The cleanest fixture here uses two `_make_git_repo(tmp_path, name=...)`
   instances and the existing `extra_env={"CLAUDE_PROJECT_DIR": ...}`
   pattern to avoid CWD ambiguity.

#### Wave decomposition

This initiative is a single wave; the two changes are independent at the
source level but share one Scope Manifest, one Evaluation Contract, and one
PR-shaped landing.

##### W-ADMIT-1: Atomicity flip + UX message + invariant tests

- **Weight:** S (~10 lines of source plus two test functions; estimate
  20-40 lines of test code each).
- **Gate:** review (reviewer must verify the test for DEC-ADMIT-001 actually
  fails against pre-flip ordering — the read-only diff alone cannot prove
  the invariant catches the race).
- **Deps:** none (base commit `9e8689a` is already on `main`).
- **Integration:** `runtime/core/bootstrap_requests.py`,
  `runtime/core/workflow_bootstrap.py`, and
  `tests/runtime/test_planner_bootstrap.py`. No CLI surface change, no
  schema change, no audit-event change, no settings.json change, no
  HOOKS.md change, no MASTER_PLAN principle change.

###### Scope Manifest (write to runtime via `cc-policy workflow scope-sync` before implementer dispatch)

- **Allowed paths:**
  - `runtime/core/workflow_bootstrap.py`
  - `runtime/core/bootstrap_requests.py`
  - `tests/runtime/test_planner_bootstrap.py`
- **Required paths (must be modified):**
  - `runtime/core/workflow_bootstrap.py` (consume reorder + `db_path`
    threading on `resolve_pending` call site at line ~281; preserve all
    other call-site context).
  - `runtime/core/bootstrap_requests.py` (signature addition for
    `resolve_pending(..., db_path=None)`, signature addition for
    `consume(..., db_path=None)` so the upstream caller can thread it
    through, expanded `token_not_found` message satisfying DEC-ADMIT-002's
    four properties).
  - `tests/runtime/test_planner_bootstrap.py` (two new test functions per
    DEC-ADMIT-003).
- **Forbidden paths:**
  - `runtime/cli.py` (no CLI surface change — argparse stays as-is).
  - `runtime/schemas.py` (no schema change).
  - `runtime/core/dispatch_engine.py`,
    `runtime/core/completions.py`,
    `runtime/core/policy_engine.py`,
    `runtime/core/stage_registry.py`,
    `runtime/core/authority_registry.py` (constitution-level files; out
    of scope).
  - `agents/*.md`, `CLAUDE.md`, `MASTER_PLAN.md`, `hooks/HOOKS.md`,
    `settings.json` (governance/derived surfaces; this initiative does
    not change them).
  - Any introduction of `bootstrap-revoke`, `bootstrap-list-pending`, or
    a cross-DB scan helper anywhere in `runtime/`.
- **State authorities touched:** `bootstrap_requests` table only
  (`runtime.schemas.bootstrap_requests`). The bootstrap path also reads
  and writes `workflow_bindings`, `goal_contracts`, `work_items`, and
  `evaluation_state` as it does today; this initiative does not change
  the schema, fields, or write logic of those tables — it only changes
  the *order* relative to the admission gate.

###### Evaluation Contract (Guardian readiness target — reviewer checks all of this before emitting `REVIEW_VERDICT=ready_for_guardian`)

- **Required tests pass:**
  - `tests/runtime/test_planner_bootstrap.py::test_bootstrap_local_consume_precedes_writes_under_race`
    (new, per DEC-ADMIT-003 (1)).
  - `tests/runtime/test_planner_bootstrap.py::test_resolve_pending_token_not_found_names_db_path_and_worktree_scoping`
    (new, per DEC-ADMIT-003 (2)).
  - All existing tests in
    `tests/runtime/test_planner_bootstrap.py` continue to pass
    unmodified (the existing suite already covers issuance audit,
    consume-once replay denial, runtime-issued-token requirement,
    non-git rejection, and explicit-worktree DB resolution; none of
    those properties are intentionally changed).
  - `python3 -m pytest tests/runtime/ -q` reports the same passed
    count as the baseline (5644) plus exactly the two new tests
    (so 5646 passed), with zero new failures, zero new errors, and
    zero new xpassed/xfailed shifts.
- **Required real-path checks (CLI smoke against a fresh tmp git repo,
  reviewer must paste the actual stderr/stdout snippets in the review
  trailer — not a prose summary):**
  1. `cc-policy workflow bootstrap-local <wf>` *without* `--bootstrap-token`
     still rejects at the argparse layer with the original message
     containing `--bootstrap-token` (existing
     `test_bootstrap_local_requires_runtime_issued_token` confirms this;
     the smoke is a live cross-check).
  2. A valid `bootstrap-request` -> `bootstrap-local` round trip still
     seeds binding/goal/work-item correctly and surfaces
     `requested_by`/`justification` on the returned packet's
     `bootstrap` block.
  3. Replaying the consumed token still raises with `already been
     consumed` in the JSON error message.
  4. Issuing a token bound to repo A and then running
     `bootstrap-local --worktree-path <repo_B>` against the same
     token now returns the new informative error containing
     (a) repo B's resolved DB path, (b) a `scoped to the worktree`
     hint, and (c) a `--worktree-path` reference. The reviewer must
     paste the actual returned JSON `message` field from this case.
  5. Cross-binding mismatch (token issued for `wf-A`, used to call
     `bootstrap-local wf-B`) still raises the existing
     `authorizes workflow ... not ...` error verbatim.
- **Required authority invariants:**
  - `runtime/core/bootstrap_requests.py` remains the sole owner of the
    admission token state machine. No other module gains the ability
    to mutate `bootstrap_requests` rows.
  - `runtime/core/workflow_bootstrap.py` remains the sole fresh-project
    bootstrap authority (per `DEC-CLAUDEX-WORKFLOW-BOOTSTRAP-001`).
    No new bootstrap entrypoint is introduced.
  - The audit event names
    (`workflow.bootstrap.requested|consumed|denied`) are unchanged.
    Their `detail` payload shape is unchanged for every existing
    branch. (The `token_not_found` denial event detail does *not* gain
    a new field — the new operator-facing context lives in the
    raised error message, not in the event detail. This is
    intentional: the audit row already records `worktree_path`, which
    a forensics reader can correlate with the bound DB out-of-band;
    operator UX is the missing surface and that's where the fix
    belongs.)
- **Required integration points:**
  - The CLI command `cc-policy workflow bootstrap-local` continues to
    map to `runtime.core.workflow_bootstrap.bootstrap_local_workflow`
    with no new flags.
  - `cc-policy workflow stage-packet ... --stage-id planner` still
    returns a valid planner launch spec after a successful
    bootstrap (existing
    `test_bootstrap_local_followed_by_agent_prompt_succeeds` covers
    this; reviewer cross-checks against current HEAD).
  - The runtime `bootstrap_requests` table schema is unchanged.
- **Forbidden shortcuts (any of these voids readiness):**
  - Wrapping `bind_workflow|upsert_goal|upsert_work_item|set_status`
    in a single outer transaction. The DEC-ADMIT-001 atomicity
    property must come from the relocated `consume()` call alone.
  - Adding cross-DB lookups in `resolve_pending` to "find" the token
    in a sibling state DB. The fix is error-message-only.
  - Adding `bootstrap-revoke` or `bootstrap-list-pending` CLI
    subcommands. #70 is explicitly deferred.
  - Renaming, dropping, or otherwise changing the existing
    `bootstrap_requests` audit event names.
  - Skipping the `@decision DEC-ADMIT-001` inline annotation on the
    moved `consume()` call. The annotation is the discoverability
    contract for future implementers per Sacred Practice 7.
  - Asserting the new `token_not_found` message via byte-for-byte
    string equality. The test must check the four DEC-ADMIT-002
    properties via substring assertions so cosmetic wording tweaks
    do not require test edits.
- **Ready-for-guardian when:**
  - Both new tests are present, pass on the candidate HEAD, and (for
    the race test) the reviewer has *manually* checked out the
    pre-flip ordering and confirmed the test fails there. This
    bidirectional check is the only real proof the test catches the
    bug it claims to catch.
  - Full `python3 -m pytest tests/runtime/ -q` reports the expected
    baseline-plus-two pass count (5646) with no new failures.
  - All five real-path smokes above are pasted verbatim in the review
    trailer, not summarized.
  - Diff stays within the Scope Manifest (verified mechanically by
    `git diff --name-only` against `9e8689a`).
  - The `@decision DEC-ADMIT-001` inline annotation is present at the
    moved `consume()` call site.

#### Rollback story

Both changes are surgically revertible:

- DEC-ADMIT-001 is a pure call-site reorder inside
  `bootstrap_local_workflow`. Reverting is a single `git revert` of the
  W-ADMIT-1 commit, or a manual move of the `consume()` block back to its
  pre-change position (a roughly five-line motion). No schema migration is
  involved; `bootstrap_requests.consumed` rows remain valid in either
  ordering.
- DEC-ADMIT-002 changes a single error message string and adds an optional
  defaulted-`None` keyword argument to two `bootstrap_requests.py`
  functions. External callers that do not pass `db_path=` see no behavior
  change. Reverting is a one-block edit.

If a regression surfaces post-landing, the safe stop-gap is a `git revert`
of W-ADMIT-1; the bootstrap path returns to the c7a3109+9e8689a baseline.

#### Open questions

None. The brief specifies exact files, exact functions, exact closing
issue numbers (#68, #69), the exact deferred issue (#70), and exact
trade-off boundaries (no outer transaction, no cross-DB scan). All planner
decisions are resolved with explicit DEC-IDs above. If the implementer
discovers ambiguity in flight, escalate to the orchestrator before
resolving silently.

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
- `braid-v2` breakglass escalation remains planned work. The authority split is
  now decided, but schema, CLI, adapter, and policy-grant wiring should wait
  until the current real-agent soak and controller cutover slices are complete.
- Daemon promotion and multi-client coordination stay parked until CLI mode is a
  proven stable interface.
- Upstream synchronization remains manual and selective; no merge/rebase flow
  from upstream is allowed into this mainline.
- Plugin ecosystems and auxiliary agent ecosystems remain out of scope for
  core runtime authority. INIT-CDX addresses Codex plugin concurrency as an
  operational concern (state.json locking, stale task reaping) without
  introducing plugin state into the runtime SQLite backend.
