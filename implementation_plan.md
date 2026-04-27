# Claude Control Hard Fork: Successor Implementation Plan

## Summary

This fork will be built as the full successor to `claude-config-pro`, but it will
be implemented by rebuilding outward from `v2.0.0` rather than pruning current
`HEAD` in place. The core design rule is unchanged: the governance kernel must
stay simpler than the work it governs.

The new fork will keep the devotional/cornerstone orchestrator voice because the
historical record shows it was load-bearing for output quality, but it will pair
that with a much stricter separation of concerns: prompts shape judgment, hooks
enforce local policy, and a typed runtime owns shared state and cross-client
coordination.

This plan is the authoritative implementation spec for the new fork.

## Source Baseline and Harvest Rules

1. Use `../claude_v2.0.0_backup` as the structural baseline for the kernel.
2. Use `../claude-config-pro` only as a source of bounded imports, never as the
   branch to simplify in place.
3. Treat the forensic reports in `../reports/` as architectural authority when
   current docs and code disagree.
4. Apply a deletion-first rule everywhere: every imported mechanism must replace
   an older one in the fork, not coexist beside it.
5. Park these subsystems outside core on day one: `judge-lib`,
   `general-purpose` governance, `circuit-breaker-lib`, `fvc-lib`,
   `db-safety-lib`, contracts-to-SQLite runtime enforcement, and
   governor/meta-evaluator flows.

## Target Repository Shape

```text
claude-ctrl/
  CLAUDE.md
  AGENTS.md
  settings.json
  MASTER_PLAN.md
  agents/
    planner.md
    implementer.md
    tester.md
    guardian.md
    shared-protocols.md
  hooks/
    pre-bash.sh
    pre-write.sh
    pre-ask.sh
    post-task.sh
    prompt-submit.sh
    session-init.sh
    session-end.sh
    subagent-start.sh
    check-planner.sh
    check-implementer.sh
    check-reviewer.sh
    check-guardian.sh
    HOOKS.md
    lib/
      core.sh
      runtime-bridge.sh
      bash-policy.sh
      write-policy.sh
      dispatch-policy.sh
      proof-policy.sh
      trace-lite.sh
      diagnostics.sh
      worktree-policy.sh
      plan-policy.sh
  runtime/
    core/
      __init__.py
      agent_sessions.py
      config.py
      db.py
      events.py
      proof.py
      dispatch.py
      markers.py
      statusline.py
      supervision.py
      transport_adapters.py
      worktrees.py
      policy.py
    cli.py
    server.py
    schemas.py
  scripts/
    planctl.py
    diagnose.py
    statusline.sh
  docs/
    DISPATCH.md
    ARCHITECTURE.md
    PROMPTS.md
    PLAN_DISCIPLINE.md
  sidecars/
    search/
    observatory/
  tests/
    scenarios/
    hooks/
    runtime/
```

## Canonical Architecture

### 1. Instruction Layer

- `CLAUDE.md` is the sole orchestrator prompt.
- `agents/*.md` are the only governed subagent prompts.
- `shared-protocols.md` contains only cross-agent runtime hygiene, not
  philosophy or system design.

### 2. Thin Hook Layer

- Hooks remain bash entrypoints because Claude Code expects them.
- Hooks do not own shared-state logic.
- Hooks call small shell libs for local checks and the typed runtime for shared
  state operations.
- Every hot-path hook must be readable in one sitting, with a hard target of
  fewer than 300 lines per entrypoint.

### 3. Agent-Agnostic Supervision Fabric

- Supervision is a runtime-owned workflow domain, not a property of a specific
  bridge or provider.
- The runtime models agent sessions, seats, supervision threads, dispatch
  attempts, and review handoffs in canonical state.
- `tmux` is an execution/attachment adapter for arbitrary interactive CLI
  agents; it is never the authority for delivery, progress, or health.
- MCP or agent-native APIs are preferred adapters when a provider exposes
  structured control, but they plug into the same runtime-owned state machine.
- Pane scraping, relay sentinels, pid files, and helper logs are diagnostics or
  transitional transport only, never canonical truth.

### 4. Typed Runtime Layer

- The runtime is the authoritative owner of shared workflow state and
  concurrency.
- The runtime is designed as a future daemon/policy engine, but bootstrap
  implementation uses a shared Python core plus CLI adapter first.
- The CLI becomes the stable contract; the daemon later exposes the same
  operations over a Unix socket without changing hook semantics.

### 5. Sidecar Layer

- Search and observatory exist as read-only consumers in `sidecars/`.
- Sidecars never sit on deny paths.
- Sidecars may read traces, events, and plan metadata, but they do not gate
  hook execution.

## Typed Runtime Contract

The runtime owns exactly these core domains:

1. `proof_state`
2. `dispatch_cycles`
3. `dispatch_queue`
4. `agent_markers`
5. `events`
6. `worktrees`
7. `agent_sessions`
8. `supervision_threads`

The successor runtime also owns all workflow coordination state. Flat files,
breadcrumb files, session-local marker files, and cache files are not permitted
as workflow authorities once the runtime cutover is complete.

The runtime does not own:

- prompt text
- plan markdown content
- docs rendering
- feature flags for optional sidecars

### Agent-Agnostic Supervision Contract

The successor runtime owns recursive supervision as a first-class domain.

- A `session` identifies one running agent instance bound to one workflow and
  one transport adapter.
- A `seat` identifies the session's role in the control plane:
  `worker`, `supervisor`, `reviewer`, or `observer`.
- A `supervision_thread` records that one seat is attached to another for
  review, steering, or autopilot recursion.
- A `dispatch_attempt` tracks instruction issuance, delivery claim,
  acknowledgment, timeout, retry ceiling, and terminal disposition.
- A `transport_adapter` is an implementation detail behind the runtime
  contract. The runtime may bind a seat to `tmux`, MCP, or another provider
  adapter without changing authority ownership.

Transport adapters must implement the same canonical operations:

- bind a session to a live target
- dispatch a structured instruction
- record or relay delivery claim
- acknowledge completion, timeout, or rejection
- surface transcript or response artifacts
- emit heartbeat and liveness signals
- interrupt or stop a bound seat when policy requires it

No adapter may infer health from pane text alone. A run is healthy only when
the runtime sees recent state transition or a current claimed dispatch attempt.

### No Flatfiles Or Breadcrumbs

The successor state machine must obviate flat-file and breadcrumb coordination.

- Hooks may not coordinate workflow state through files such as
  `.proof-status*`, `.subagent-tracker*`, `.statusline-cache*`,
  `.agent-findings`, or similarly named session breadcrumbs after cutover.
- Filename presence, file timestamps, or directory breadcrumbs are not valid
  workflow authority signals in the successor architecture.
- Trace artifacts may exist for evidence and recovery, but they are never read
  as authority for proof state, dispatch state, active role, or worktree truth.
- Migration helpers may read legacy flat files during cutover, but must delete
  or ignore them once canonical runtime state exists.
- Statusline, diagnostics, and observability read from runtime projections, not
  ad hoc cache files.

### Statusline Read Model

The statusline is a runtime-backed read model, not a governance authority.

- `scripts/statusline.sh` is the renderer only.
- `runtime/core/statusline.py` derives a statusline snapshot from the canonical
  state machine plus Claude-provided stdin metrics.
- No statusline field may become a second source of truth for workflow state.
- The statusline may not depend on `.statusline-cache*` or similar breadcrumb
  files once the successor runtime is live.
- Statusline data must be reconstructable from:
  - `proof_state`
  - `dispatch_cycles`
  - `agent_markers`
  - `worktrees`
  - `events`
  - plan summary metadata
  - Claude runtime stdin fields such as model, tokens, cost, and context usage
- The statusline must degrade gracefully when optional data is missing; it must
  never block the core control plane.
- Rich HUD features from `claude-config-pro` are in scope, but only when
  reimplemented on top of the successor runtime instead of old
  cache/contracts/state coupling.

### Stable CLI Interface

The bootstrap must implement these commands exactly:

```bash
cc-policy init
cc-policy proof get --workflow <id>
cc-policy proof set --workflow <id> --state <idle|pending|verified|committed|failed> --actor <role>
cc-policy proof reset-stale
cc-policy dispatch create-cycle --workflow <id> --session <id>
cc-policy dispatch advance --cycle <id> --phase <implementing|testing|merging|completed|abandoned>
cc-policy dispatch enqueue --type <plan_to_impl|impl_to_test|test_to_guard|guard_to_impl> --workflow <id> --cycle <id> --payload <json>
cc-policy dispatch claim --type <...> --workflow <id>
cc-policy dispatch ack --id <queue_id>
cc-policy marker create --workflow <id> --role <planner|implementer|tester|guardian> --session <id> --trace <path>
cc-policy marker query --workflow <id> --role <...>
cc-policy marker clear-stale
cc-policy statusline snapshot --workflow <id> --session <id> --parent-pid <pid>
cc-policy worktree register --workflow <id> --path <path> --branch <branch> --session <id>
cc-policy worktree heartbeat --path <path> --session <id>
cc-policy worktree list --workflow <id>
cc-policy worktree sweep
cc-policy event emit --type <event_name> --workflow <id> --actor <role> --payload <json>
cc-policy event query --type <event_name> --workflow <id> --limit <n>
```

### Supervision CLI Extension

After the bootstrap CLI is stable, recursive supervision extends the runtime
contract with seat- and transport-aware operations such as:

```bash
cc-policy supervise session-bind --workflow <id> --provider <claude|codex|gemini|generic_cli> --transport <tmux|mcp|native> --target <opaque>
cc-policy supervise seat-open --session <id> --role <worker|supervisor|reviewer|observer>
cc-policy supervise thread-open --controller-seat <id> --subject-seat <id> --mode <review|autopilot|analysis>
cc-policy supervise dispatch --seat <id> --payload <json>
cc-policy supervise claim --attempt <id> --seat <id>
cc-policy supervise ack --attempt <id> --seat <id> --status <accepted|completed|rejected|timed_out>
cc-policy supervise heartbeat --seat <id>
cc-policy supervise interrupt --seat <id>
```

These commands replace blind send-and-infer bridge loops. Delivery, progress,
and timeout handling become runtime facts rather than tmux heuristics.

### Runtime Defaults

- SQLite in WAL mode.
- Python 3.11+.
- All write operations run in explicit transactions.
- `idle` is the neutral proof state for fresh sessions.
- Runtime API errors must be distinguishable from policy denials.

## Hook Policy Boundaries

### `pre-bash.sh`

Owns:

- destructive command policy
- worktree/CWD safety
- git command agent identity checks
- deny-with-corrective-suggestion behavior
- fast local parsing only

Does not own:

- direct SQLite writes
- workflow lifecycle decisions
- search, observatory, or judge logic

### `pre-write.sh`

Owns:

- main/worktree branch protection
- governance-markdown protection
- orchestrator direct-write denial
- plan permanent-section immutability checks via `planctl.py`
- deny-with-suggestion behavior

### `post-task.sh`

Owns:

- dispatch emission only
- critical-path-first ordering
- trace-lite handoff capture

Trace-lite artifacts are evidence only. They must not become coordination
breadcrumbs or workflow authority.

### `check-*.sh`

Own:

- agent-specific validation and return-shape checking
- no orchestration policy beyond their own role contract

### `scripts/statusline.sh`

Owns:

- rendering Claude stdin fields plus runtime snapshot data
- ANSI formatting, truncation, and graceful fallback display
- no policy decisions

Does not own:

- direct workflow-state writes
- ad hoc cache authority
- parallel state derivation separate from runtime truth

## Canonical Prompt Set

### `CLAUDE.md`

The canonical orchestrator must be structurally closest to `v2.5`, with the
devotional core restored and operational bloat removed.

Required section order:

1. `Identity`
2. `Cornerstone Belief`
3. `What Matters`
4. `Interaction Style`
5. `Output Intelligence`
6. `Dispatch Rules`
7. `Sacred Practices`
8. `Code is Truth`
9. `Resources`

Required content rules:

- Keep the current full `Cornerstone Belief` language as the canonical
  devotional spine.
- Keep `What Matters` as the reasoning-calibration layer.
- Keep `Integration Surface Context` in Dispatch Rules.
- Remove inline tool catalogs, large subsystem descriptions, and sidecar details
  from the hot prompt.
- Keep the orchestrator between 140 and 180 lines.

Canonical sacred practices:

1. Always use git.
2. Main is sacred.
3. No `/tmp/`; CWD safety is mandatory.
4. Nothing is done until tested.
5. No implementation without a plan.
6. Code is truth.
7. Approval gates flow through Guardian.
8. Tester owns proof-before-commit.
9. Single source of truth; remove what you replace.
10. Concurrency is the default operating condition.

### `agents/shared-protocols.md`

Target budget: 50 to 80 lines.

Keep only:

- CWD safety
- trace recovery
- final return protocol
- session-end checklist
- mandatory issue filing for discovered out-of-scope bugs

Remove from shared protocols:

- global system philosophy
- state-authority doctrine
- mechanism-discovery essays
- compound interaction doctrine
- tool inventories

### `planner.md`

Target budget: 180 to 240 lines.

Must include:

- create-or-amend detection
- permanent-section immutability
- active-initiative append model
- state authority map section
- wave decomposition
- issue/worktree strategy
- plan closure rules

Must not include:

- exhaustive tool catalogs
- sidecar usage details
- long research ceremony unless tier 3

### `implementer.md`

Target budget: 160 to 220 lines.

Must include:

- worktree-only implementation
- mechanism discovery before stateful changes
- remove-what-you-replace rule
- consumer-first/interface-first rule for multi-file work
- requirement to produce at least one compound interaction test
- trace artifact contract

### `tester.md`

Target budget: 180 to 240 lines.

Must include:

- builder/judge separation
- "the lie tests tell" doctrine
- Tier 1 / Tier 2 / Tier 3 verification
- explicit dual-authority audit
- live evidence format
- auto-verify criteria
- same-worktree verification rule

### `guardian.md`

Target budget: 180 to 240 lines.

Must include:

- fail-fast proof/test gate
- three-dot merge analysis
- "lead with value" return format
- worktree cleanup safety
- authority-count merge audit
- phase-completing merge checklist
- approval execution model

## Approval and Breakglass Authority Split

The successor control plane must keep repository approval policy and live
harness gate handling separate.

Runtime-owned supervision must own:

- live interaction-gate detection and classification
- escalation request routing
- delivery of bounded review artifacts to the next supervising seat
- grant consumption and resolution attempts
- resume, cancel, fail, and expiry handling
- trace and trajectory evidence for the full chain

The shared policy engine must own:

- whether a gate type is eligible for escalation
- which authority may approve it
- grant scope, TTL, and single-use semantics
- audit requirements
- final allow, deny, or require-user decisions

Breakglass approvals are temporary exception leases tied to a concrete
bundle/seat/session/gate, not global bypass flags.

Guardian remains the approval authority for repo-risking git operations.
Breakglass is the separate approval surface for live harness and tool prompts.

Every harness adapter must expose a typed gate taxonomy and typed resolution
actions to the runtime. Transport tricks such as tmux key sends may still be
used, but they are adapter mechanics only and must never become the
authoritative representation of approval state.

## Bootstrap Plan Discipline

The new fork keeps `MASTER_PLAN.md`, but it is narrowed back to what it does
best: persistent human memory.

### `MASTER_PLAN.md` Must Contain

- `Identity`
- `Architecture`
- `Original Intent`
- `Principles`
- append-only `Decision Log`
- `Active Initiatives`
- `Completed Initiatives`
- `Parked Issues`

### `MASTER_PLAN.md` Must Not Be Used As

- the runtime database
- the sole source of progress metrics
- a freeform scratchpad for ad-hoc ideas
- a place where permanent sections are routinely rewritten

### Plan Discipline Enforcement

- `scripts/planctl.py` will own `Last updated` stamping, section validation,
  initiative compression, and immutable-section diff checks.
- `pre-write.sh` must reject edits to `Identity`, `Architecture`,
  `Original Intent`, `Principles`, and historic Decision Log rows unless a
  `plan-migration` mode is explicitly set.
- Every change touching `hooks/`, `agents/`, `CLAUDE.md`, runtime policy
  interfaces, or plan lifecycle must append a DEC row in the same change.
- Active initiatives are capped at 3 at any one time. Additional work must be
  parked or planned, not marked active.
- `/cohere` or equivalent coherence validation becomes mandatory for
  plan/governance changes before merge.

### Structured State Separation

- Planner-generated topology and counts move to structured state, not markdown
  parsing.
- `MASTER_PLAN.md` remains the narrative memory.
- Runtime/plan validation tools may compare markdown against structured state,
  but hooks do not parse markdown for hot-path authority decisions.

## Bounded Imports From `claude-config-pro`

Import into core:

- lazy load pattern from `source-lib.sh`, but only for minimal shell libs
- `tester` role and proof-before-commit pipeline
- CWD/worktree deletion protections
- cross-platform `mtime` and timeout wrappers
- trace-lite manifests and summaries
- the useful statusline HUD concepts, but only when they read runtime
  projections instead of flat-file caches or breadcrumb markers
- per-gate audit events
- integration-surface dispatch context
- simple task fast path, but only with full WHO enforcement and planner fallback
- statusline information architecture and useful HUD segments, reimplemented on
  top of runtime-backed snapshot reads rather than old cache/contracts coupling

Import as sidecars later:

- searchable knowledge base
- observatory
- coherence tooling

Do not import into core:

- judge gate
- governor/general-purpose agent
- contracts runtime enforcement pipeline
- db-safety
- circuit breaker
- FVC
- giant `state-lib.sh` style consolidation

## Implementation Phases

### Phase 1: Fork Bootstrap

- Initialize the fork from `v2.0.0` structure.
- Remove cached/session garbage and backup artifacts from the copied baseline.
- Create the new directory layout and empty file stubs listed above.
- Copy only the stable baseline prompts and hooks needed to preserve working
  behavior.
- Success criterion: repo boots with `planner`, `implementer`, and `guardian`
  from `v2` shape and no current `HEAD` mega-libs.

### Phase 2: Canonical Prompt Rewrite

- Replace the bootstrap prompts with the canonical prompt set specified above.
- Add the `tester` prompt.
- Trim `shared-protocols.md` to runtime hygiene only.
- Write `docs/PROMPTS.md` to record prompt budgets, section order, and
  non-goals.
- Success criterion: prompt set is complete, budgets are met, and no agent
  prompt duplicates global philosophy.

### Phase 3: Typed Runtime Core

- Implement `runtime/core/*.py`, `runtime/cli.py`, and
  `hooks/lib/runtime-bridge.sh`.
- Migrate proof, dispatch, markers, events, and worktree coordination to
  runtime calls.
- Implement `runtime/core/statusline.py` and `cc-policy statusline snapshot` as
  a projection over runtime state plus Claude stdin metrics.
- Prohibit direct `sqlite3` usage in hook entrypoints.
- Success criterion: no core hook writes shared state except through
  `cc-policy`.

### Phase 4: Hook Decomposition

- Rebuild `pre-bash.sh`, `pre-write.sh`, `post-task.sh`, and `check-*.sh`
  around the thin-hook model.
- Split policy logic into `hooks/lib/*.sh` by domain.
- Rebuild `scripts/statusline.sh` as a renderer over runtime statusline
  snapshots, not hook-owned ad hoc cache files.
- Front-load all critical emissions before heavy loads.
- Add per-gate audit events and timing logs.
- Success criterion: hot-path hooks are readable, timed, and locally testable.

### Phase 5: Proof, Dispatch, and WHO Enforcement

- Add the neutral proof lifecycle with `idle` default.
- Enforce `planner -> implementer -> tester -> guardian`.
- Enforce agent identity for git operations.
- Add orchestrator source-write denial and Guardian-only commit/merge/push.
- Success criterion: a fresh session is not deadlocked, and all merge/commit
  operations respect WHO and proof state.

### Phase 6: Plan Discipline System

- Implement `planctl.py`.
- Enforce permanent-section immutability.
- Separate structured plan topology from markdown.
- Add auto `Last updated` stamping and initiative compression.
- Success criterion: the March 7 style plan rewrite is mechanically blocked.

### Phase 7: Full Successor Sidecars

- Reintroduce search and observatory as sidecars in shadow mode.
- Add `docs/PLAN_DISCIPLINE.md` and `docs/ARCHITECTURE.md`.
- Keep sidecars read-only relative to policy.
- Success criterion: successor feature set is present without hot-path coupling.

### Phase 8: Service Promotion

- Promote the Python core to a Unix-socket daemon using the same internal
  modules and schemas.
- Keep `cc-policy` CLI as a stable client wrapper.
- Add multi-client coordination semantics for Claude Code, Codex, Gemini, or
  other clients.
- Success criterion: cross-client concurrency works against one authority
  without changing hook contracts.

## Public Interfaces and Breaking Changes

### New Required Interfaces

- `cc-policy` CLI is the new stable policy/runtime interface.
- `planctl.py` is the new stable plan-discipline utility.
- `CLAUDE.md` and `agents/*.md` are rewritten to the canonical section and
  budget rules above.

### Removed or Parked Interfaces

- direct `state-lib.sh` style shared-state ownership in bash
- judge-based plan bookkeeping bypass
- general-purpose agent routing
- flat-file or breadcrumb-based workflow coordination
- direct sidecar participation in deny paths

### New Environment Variables

- `CLAUDE_AGENT_ROLE`
- `CLAUDE_SESSION_ID`
- `CLAUDE_WORKFLOW_ID`
- `CLAUDE_TRACE_DIR`
- `CLAUDE_POLICY_SOCKET` for daemon mode later
- `CLAUDE_PLAN_MIGRATION=1` for explicit permanent-section migrations only

## Test Cases and Scenarios

1. Fresh session starts with `proof_state=idle` and Guardian is not blocked.
2. Planner creates a new `MASTER_PLAN.md` from template without mutating
   permanent sections afterward.
3. Planner amends an existing plan by appending an initiative instead of
   rewriting the file.
4. Orchestrator cannot write governed source or governance markdown directly.
5. Implementer cannot work outside a worktree.
6. Guardian is the only role that can commit, merge, or push.
7. Tester is auto-dispatched after implementer and can block promotion on weak
   evidence.
8. `plan_to_impl`, `impl_to_test`, `test_to_guard`, and `guard_to_impl` all
   survive a live dispatch cycle.
9. CWD safety prevents deleting or operating from volatile worktree paths.
10. Two Claude Code instances on one project coordinate through shared workflow
    and worktree state without divergence.
11. A second client type using the same runtime can observe and coordinate
    against the same active workflow.
12. Sidecars can crash or be absent without blocking core hook execution.
13. `MASTER_PLAN.md` permanent-section rewrite attempts are denied.
14. Architectural changes without a Decision Log append are denied.
15. Cross-platform timeout and `mtime` behavior is consistent on macOS and
    Linux.
16. `statusline.sh` renders successfully from runtime snapshots when all data is
    present and when optional fields are absent.
17. Statusline fields for worktrees, active agents, proof state, and initiative
    are derived from canonical runtime state rather than separate cache
    authority.
18. Rich HUD segments from the successor statusline do not block prompts or hook
    execution when runtime reads fail; they degrade to safe defaults.
19. No successor hook, script, or validation path requires flat-file or
    breadcrumb coordination for proof state, dispatch state, active role, or
    statusline truth.

## Rollout and Validation

- Every phase must end with one live end-to-end cycle, not just unit tests.
- Every infrastructure phase must prove behavior by querying runtime state, not
  by trusting prompt text or hook stdout alone.
- Sidecars stay shadow-only until the kernel acceptance suite is green for two
  consecutive passes.
- Daemon mode is not enabled by default until CLI mode has passed concurrency
  tests with multiple clients.

## Assumptions and Defaults

- The fork remains bash-first at the hook boundary because Claude Code requires
  shell hook entrypoints.
- The fork remains devotional in the orchestrator prompt because that is the
  canonical quality anchor.
- The fork becomes a full successor, but it still ships in layers: kernel
  first, sidecars second, daemonized cross-client runtime third.
- Python is an acceptable bootstrap dependency for this fork.
- SQLite remains the persistence layer for the runtime.
- `MASTER_PLAN.md` is kept, but only as institutional memory, not as the
  runtime database.
- Search and observatory are included in the successor roadmap, but not in the
  deny path.
- The richer statusline HUD from `claude-config-pro` is part of the successor
  roadmap, but only as a runtime-backed read model, never as an independent
  authority path.
- Trace files may remain as evidence artifacts, but the successor state machine
  does not use flat files or breadcrumbs for workflow coordination.
- This file is the authoritative successor bootstrap plan for
  `claude-ctrl`.
