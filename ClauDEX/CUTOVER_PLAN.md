# ClauDEX Cutover Plan

Status: proposed grounding document
Created: 2026-04-07

## System Overview

ClauDEX is a restart architecture for this repository's control plane. Its
purpose is to replace a drift-prone pile of prompts, hooks, docs, and local
conventions with a system that is explicit, runtime-owned, and mechanically
self-preserving.

The core problem is not just that the existing stack has bugs. The deeper
problem is that the system repeatedly allows the same class of failure:

- a new authority is added without deleting the old one
- hooks quietly regrow policy logic that the runtime already owns
- prompts and docs drift away from actual mechanism truth
- review logic leaks across product boundaries
- later agents rediscover rules by being denied instead of being told the live
  control plane up front

ClauDEX exists to stop that pattern at the architectural level.

### What the System Is

ClauDEX is a deterministic control plane for agentic software work. It combines:

- a Python runtime as the sole owner of control-plane truth
- thin hooks as harness adapters
- a declarative stage graph for workflow routing
- a capability model for legal behavior
- a structured decision/work registry for canonical project memory
- derived prompt packs that explain the live control plane to the acting model
- derived retrieval and graph layers that improve access to memory without
  becoming canonical truth
- invariant tests and scope gates that make architectural drift mechanically
  difficult

In short: the runtime owns the law, prompts describe the current law, hooks
transport requests into the law, and tests ensure later work cannot quietly
invent another law beside it.

### What the System Is For

The system has five primary goals:

1. Preserve one authority per operational fact.
2. Make workflow execution and review routing explicit and configurable.
3. Tell models the live control plane before they act.
4. Keep memory, plans, and decisions current by mechanical reflow instead of
   manual upkeep.
5. Force later architectural work to update the real record, the derived
   surfaces, and the enforcement layer together.

### The Core Loops

The finished system is not a straight pipeline. It is two nested loops.

The inner loop is the work-item convergence loop:

`guardian(provision) -> implementer <-> reviewer -> guardian(land)`

This loop continues until:

- the reviewer marks the current head `ready_for_guardian`
- the reviewer sends the work back with `needs_changes`
- the reviewer routes upstream with `blocked_by_plan`

The outer loop is the goal continuation loop:

`planner -> work-item loop -> guardian(land) -> planner -> ...`

After guardian lands, the system should not assume the user must answer next.
Planner reassesses the goal state and decides whether the larger objective is
complete, whether another work item is already implied, or whether the next move
requires user input.

### Cohesive Design

The design is built out of a few tightly connected ideas.

#### 1. Runtime-Owned Truth

The runtime is the sole owner of:

- workflow identity
- stage routing and legal transitions
- capabilities and forbidden operations
- config defaults and overrides
- review findings and readiness state
- leases, approvals, worktree bindings, and lifecycle
- canonical decision/work records

No hook, prompt, doc, or plugin may define those facts independently.

#### 2. Hooks as Adapters

Hooks are harness shims, not miniature policy engines. They may read stdin,
normalize payloads, invoke runtime operations, and emit correct harness output.
They may not own routing, config truth, or semantic parsing that the runtime
already resolved.

#### 3. Compiled Guidance

The system should not rely on the model learning its operating environment by
hitting invisible walls. Instead, each session or subagent receives a compiled
prompt pack containing:

- constitutional rules
- current stage contract
- workflow scope and evaluation contract
- relevant decisions and supersessions
- current leases, approvals, and branch constraints
- unresolved findings and allowed next moves

This turns the control plane into something the model can operate inside instead
of something it keeps discovering by collision.

#### 4. Canonical Memory with Derived Retrieval

ClauDEX uses a hybrid memory model:

- canonical structured registries for machine-owned truth
- canonical markdown memory for durable human-readable knowledge
- derived retrieval layers such as search indexes and temporal graph exports

This preserves auditability and reviewability while still allowing fast
retrieval, contradiction checks, and temporal reasoning. The graph/search layer
is useful, but it is downstream from canonical truth, never a replacement for
it.

#### 5. Reflow and Freshness

The system stays current by making derived surfaces downstream from canonical
records.

When canonical truth changes:

- the affected projections are identified
- plans, digests, prompt packs, docs, and retrieval indexes are regenerated or
  revalidated
- stale downstream artifacts fail landing until refreshed

This is how the system avoids becoming outdated. It does not depend on someone
remembering to edit every narrative surface by hand.

#### 6. Schema Contracts Everywhere

The system is defined by explicit schema contracts for:

- state
- transitions and inter-component payloads
- derived projections

These schemas give the runtime, providers, hooks, prompts, and tests a shared
legal shape for the system. That is what turns architecture from aspiration into
something enforceable.

#### 7. Evidence, Not Folklore

Git remains important, but as landed evidence rather than live memory authority.
Canonical decisions and work items live in the runtime registry; commits carry
trailers and provenance linking the landed code back to those records. Source
files can point at decisions through resolvable references instead of bloating
into parallel rationale stores.

#### 8. Replacement by Shadow Then Deletion

The cutover should earn modularity before depending on it.

New control-plane authorities must first run in shadow mode beside the donor
path, computing the same answer without owning the live answer yet. Once the new
authority is proven, it becomes canonical and the donor authority is deleted.

This prevents the cutover from becoming another parallel-authority era.

### System Diagram

```text
                         +----------------------+
                         |      The User        |
                         +----------+-----------+
                                    |
                                    v
                    +---------------+----------------+
                    | Harness / CLI / Orchestrator   |
                    +---------------+----------------+
                                    |
                                    v
                         +----------+-----------+
                         |   Hook Adapter Layer |
                         |  stdin -> runtime -> |
                         |  harness output      |
                         +----------+-----------+
                                    |
                                    v
                    +---------------+----------------+
                    |        Runtime Control Plane    |
                    |---------------------------------|
                    | stage registry                  |
                    | capability resolver             |
                    | policy engine                   |
                    | workflow/worktree bindings      |
                    | leases / approvals / lifecycle  |
                    | decision & work registries      |
                    | reviewer findings / readiness   |
                    | schema validation               |
                    +--+---------------+-----------+--+
                       |               |           |
          canonical    |               |           | derived
          truth        |               |           | projections
                       v               v           v
           +-----------+--+   +--------+----+   +------------------+
           | Runtime DB   |   | Markdown KB |   | Prompt Packs     |
           | decisions    |   | policies    |   | session context  |
           | work items   |   | memory      |   | stage contract   |
           | workflow     |   | summaries   |   | next actions     |
           +-----------+--+   +--------+----+   +--------+---------+
                       |               |                  |
                       +-------+-------+                  |
                               |                          |
                               v                          v
                    +----------+---------------------------+---+
                    | Derived Read Models / Reflow Engine      |
                    |------------------------------------------|
                    | rendered MASTER_PLAN / digests           |
                    | validated settings/docs                  |
                    | search indexes / graph exports           |
                    | statusline / summaries / diagnostics     |
                    +----------+---------------------------+---+
                               |                           |
                               v                           v
                    +----------+-----------+    +----------+-----------+
                    | Acting Agent / Stage |    | Guardian / CI Gates |
                    | planner implementer  |    | stale? invalid?     |
                    | reviewer guardian    |    | second authority?   |
                    +----------+-----------+    +----------------------+
                               |
                 work-item loop|
                               v
                    guardian(provision) -> implementer <-> reviewer
                               |
                               v
                         guardian(land)
                               |
                     goal continuation loop
                               v
                            planner
```

### End-State Behavior

In the finished system:

- the runtime owns workflow law
- prompts are generated from workflow law
- hooks only translate between the harness and workflow law
- memory and decisions are canonical in registries plus durable markdown
- graphs, indexes, plans, and docs are regenerated from that canonical layer
- reviewer is a read-only first-class stage
- guardian is the sole landing authority
- planner owns goal continuation after landing
- architectural drift becomes a failing invariant instead of a future cleanup

The rest of this document specifies that system in detail: what comes over from
the current line, what gets deleted, what invariants preserve the design, and
what phased cutover establishes the new authority model.

## Purpose

This document is the grounding plan for restarting the project around the
ClauDEX concept:

- Python runtime is the control-plane authority
- hooks are thin transport adapters
- stage routing is declarative and capability-driven
- workflow review and regular Stop review are separate products
- architecture is preserved by executable constraints, not by prompt reminders

This plan is intentionally replacement-oriented. It does not aim to "tidy up"
the existing stack indefinitely. Each migration slice must either cut over or
explicitly remain outside the cutover boundary.

## Why Restart

The current line has repeatedly drifted away from its own intended model:

- old authorities survive after new ones are added
- shell hooks re-grow semantics the runtime already owns
- repo docs and live harness behavior diverge
- provider-specific review logic leaks into workflow routing
- historical fixes are applied locally without collapsing the underlying split

The problem is not only bugs. The problem is that the system does not
mechanically prevent future agents from creating a second authority.

The ClauDEX restart exists to solve that root cause.

## North Star

The end state is a control plane where:

1. every operational fact has exactly one authority
2. every derived surface is generated from or validated against that authority
3. every role is enforced through capabilities, not duplicated role folklore
4. every migration removes the superseded path
5. every later agent is constrained by invariant tests, scope manifests, and
   architecture gates instead of relying on institutional memory

## Constitutional Rules

These rules govern the cutover.

1. One authority per operational fact.
   Workflow identity, stage routing, review readiness, git landing authority,
   hook wiring, config defaults, and policy decisions may not be derivable from
   multiple competing paths.
2. Hooks are adapters.
   Hooks may read stdin, normalize harness payloads, invoke the runtime, and
   return harness-shaped stdout or stderr. They may not become alternate owners
   of routing, shared state, or business semantics already owned by Python.
3. Derived surfaces are not hand-authored truth.
   `settings.json`, hook docs, role lists, config defaults, and provider
   toggles must be generated from or validated against the authority layer.
4. Capabilities beat role-name repetition.
   The runtime should enforce `can_write_source`, `can_land_git`,
   `read_only_review`, `can_set_config`, and similar capabilities rather than
   scattering raw role-name checks across shell and Python.
5. No parallel authorities as transition strategy.
   Temporary compatibility mirrors are acceptable only when one side is
   explicitly non-authoritative and the same migration defines how it will be
   removed.
6. Architecture changes are bundles.
   Every authority change must include source change, invariant coverage, doc
   updates, and removal or bypass of the superseded path.
7. Official harness behavior outranks repo lore.
   When harness semantics are load-bearing, official docs plus installed truth
   outrank repo-local explanations.

## Scope Boundary

This cutover covers the control plane of this repository:

- prompts and role contracts
- hook entrypoints and wiring
- runtime schemas, CLI, and policy engine
- dispatch and workflow review routing
- worktree and lease control
- configuration authority
- architecture docs and invariant tests

This cutover does not aim to:

- preserve every historical hook or policy surface
- maintain tester as a permanent stage
- keep speculative or undocumented harness behavior in production config
- make all historical docs authoritative again

## Target Architecture

### 1. Runtime Kernel

The runtime owns:

- stage graph and transition rules
- workflow identity and bindings
- capabilities and authority resolution
- enforcement config and defaults
- review findings and convergence state
- leases, worktrees, lifecycle, and events

The runtime exposes stable operations through `cc-policy` first. A daemon is an
optional later transport, not a new authority.

### 2. Hook Adapter Layer

Hooks become thin transport adapters:

- parse harness payload
- call a runtime command or module
- emit harness-compliant output

Hook-specific behavior is allowed only when the harness itself requires it.
Anything else belongs in the runtime.

### 2a. Agent-Agnostic Supervision Fabric

Supervision is its own runtime-owned domain. It must not be encoded implicitly
in tmux panes, hook-local files, or a provider-specific bridge.

The target control plane models:

- `agent_session`
  One live agent instance bound to one workflow and one transport adapter.
- `seat`
  A named role inside a session such as `worker`, `supervisor`, `reviewer`, or
  `observer`.
- `supervision_thread`
  An attached analysis/review/autopilot relationship where one seat steers or
  audits another.
- `dispatch_attempt`
  A single issued instruction with delivery claim, acknowledgment, retry, and
  timeout state.

Design rules:

- `tmux` is an execution and attachment surface for arbitrary interactive CLI
  agents. It is useful precisely because it is agent-agnostic, but it is not
  the authority for queue state, delivery, health, or completion.
- MCP or provider-native APIs are preferred adapters when an agent exposes a
  structured control surface, but they plug into the same runtime-owned state
  machine.
- The runtime owns dispatch claim/ack, review handoff, seat binding, and
  timeout policy. Pane scraping, relay sentinels, helper logs, and pid files
  are diagnostics only.
- Recursive supervision is represented explicitly as a relationship between
  seats. "Open an attached analysis thread on the running worker" is therefore
  a first-class runtime action, not a special-case bridge trick.

### 3. Stage Registry

The stage graph becomes a first-class authority, not a convention scattered
through prompts, hooks, and routing code.

Target workflow graph:

`planner -> guardian(provision) -> implementer <-> reviewer -> guardian(land) -> planner`

Allowed reviewer verdicts:

- `ready_for_guardian`
- `needs_changes`
- `blocked_by_plan`

Target transitions:

- `planner -> guardian(provision)`
- `guardian(provisioned) -> implementer`
- `implementer -> reviewer`
- `reviewer(ready_for_guardian) -> guardian(land)`
- `reviewer(needs_changes) -> implementer`
- `reviewer(blocked_by_plan) -> planner`
- `guardian(denied) -> implementer`
- `guardian(skipped) -> planner`
- `guardian(committed|merged) -> planner`
- `planner(goal_complete) -> terminal`
- `planner(next_work_item) -> guardian(provision)`
- `planner(needs_user_decision) -> user`
- `planner(blocked_external) -> terminal`

### 4. Goal Contract and Work-Item Contract

The cutover must separate the outer goal loop from the inner work-item loop.

Work-item contract:

- scope manifest
- required tests and evidence
- rollback boundary
- reviewer convergence rules
- file and authority boundaries

Goal contract:

- desired end state
- autonomy budget
- continuation rules after guardian
- stop conditions
- escalation boundaries
- user-decision boundaries

This separation is what allows the system to continue after guardian without
becoming runaway automation.

### 5. Capability Model

Roles describe workflow position. Capabilities describe allowed behavior.

Minimum capability set:

- `can_write_source`
- `can_write_governance`
- `can_land_git`
- `can_provision_worktree`
- `can_set_control_config`
- `read_only_review`
- `can_emit_dispatch_transition`

Target role intent:

- `planner`: governance and workflow planning, no source writes
- `guardian`: git landing and worktree provisioning authority
- `implementer`: source change authority inside scoped workflow boundaries
- `reviewer`: read-only evaluation authority; may inspect, diff, and run tests,
  but may not edit files or mutate repo state

### 6. Two Review Lanes

The cutover explicitly separates review into two products.

Regular Stop review:

- user-facing turn-based steering
- advisory or block-for-user only
- provider-backed, but not part of workflow routing

Workflow reviewer:

- part of the dispatch graph
- structured completion authority before guardian can land changes
- provider-backed and read-only

These two lanes may share provider code, but they must not share routing
authority.

### 7. Convergence Model

Convergence is a data model, not a prose impression.

The workflow reviewer should maintain a structured findings ledger including:

- `finding_id`
- `status = open|fixed|rebutted|accepted|deferred`
- `severity`
- `reviewed_head_sha`
- `round`
- `repeat_disagreement_count`

Guardian may land only when:

- the latest reviewer verdict is `ready_for_guardian`
- the reviewer evaluated the current head
- no blocking findings remain open
- required tests/evals have passed
- derived projections are fresh

Any source change after reviewer clearance invalidates readiness and forces
another reviewer pass.

## Authority Map

| Operational fact | Sole authority | Derived surfaces | Forbidden secondary authorities |
| --- | --- | --- | --- |
| Stage transitions | runtime stage registry | prompts, dispatch suggestions, docs | shell hook routing logic, freeform prompt lore |
| Workflow review readiness | reviewer completion + findings store | statusline, session summaries | `codex_stop_review` event gate as workflow authority |
| Goal continuation after landing | planner completion + goal contract | next-work suggestions, summaries | reviewer verdicts or hook heuristics deciding what comes next |
| Regular Stop review state | runtime config + provider adapter | plugin UX, setup commands | plugin-local flat-file config as sole truth |
| Agent session binding | runtime session registry | launch scripts, status surfaces, prompt packs | tmux pane ids, MCP handles, hook env vars as standalone truth |
| Dispatch delivery and timeout state | runtime dispatch attempts + claim/ack ledger | watchdog, dashboards, recovery prompts | queue-file timestamps, sentinel echoes, pane text heuristics |
| Recursive supervision state | runtime supervision-thread registry | operator views, restart helpers, prompt packs | stop-hook loops, bridge helper pids, ad hoc recovery bundles |
| Hook wiring | runtime-declared hook manifest or validated settings | `settings.json`, hook docs | speculative settings edits without invariant coverage |
| Capabilities | runtime capability resolver | policy checks, prompts | repeated raw role-name checks across bash and Python |
| Worktree ownership | runtime worktree bindings + guardian authority | prompts, summaries, docs | undocumented harness worktree surfaces kept live without proof |
| Config defaults | runtime schema/bootstrap | plugin UI mirrors, docs | scattered hardcoded defaults |

## Default Bring-Over Decisions

The following matrix is the de facto migration baseline. Future planning may
override individual rows only by explicit decision. The default assumption is
that these recommendations stand unless the user chooses otherwise.

Recommendation meanings:

- `Yes` — bring this concept into ClauDEX as part of the target architecture
- `Yes (rebuild)` — preserve the control property, not the current
  implementation
- `Partial` — retain the valuable part, simplify or redesign the rest
- `No` — do not bring this into the restart architecture
- `Later` — not part of the restart kernel; only revisit after core cutover

### Foundation

| ID | Feature | Recommendation | Rationale |
| --- | --- | --- | --- |
| F1 | SQLite-backed runtime state | Yes | The runtime needs one durable shared-state authority. SQLite is already the strongest practical fit in this repo. |
| F2 | Python policy engine | Yes | Centralized policy evaluation is the best existing direction and should remain the heart of enforcement. |
| F3 | Runtime-owned command intent parsing | Yes | Intent parsing is exactly the kind of fact that must not be duplicated across hooks and policies. |
| F4 | Runtime config authority | Yes (rebuild) | Keep one runtime-owned config surface, but simplify defaults, scope handling, and compatibility mirrors. |
| F5 | Stage registry as runtime authority | Yes | Dispatch truth must move out of scattered code paths into one explicit graph. |
| F6 | Capability model | Yes | Capabilities preserve architecture better than role-name repetition. |
| F7 | Dual-write / compatibility mirrors as standing design | No | These are tolerated only during migration and must not survive as architecture. |
| F8 | Flat-file workflow authorities | No | Flat files are donor-era debt and should not survive the cutover kernel. |

### Workflow and Roles

| ID | Feature | Recommendation | Rationale |
| --- | --- | --- | --- |
| W1 | Planner role | Yes | Planning, scope manifests, and evaluation contracts remain critical. |
| W2 | Implementer role | Yes | Source mutation still needs an isolated build role with scoped authority. |
| W3 | Tester role as a permanent first-class stage | No | Replace it with a reviewer stage instead of preserving the current split. |
| W4 | Reviewer stage, read-only, provider-backed | Yes | This is the intended successor to tester and the center of the workflow review lane. |
| W5 | Guardian as sole git landing authority | Yes | This boundary is one of the clearest and most valuable control-plane decisions. |
| W6 | Guardian provision mode + land mode | Yes | Provisioning and landing are different authorities and should stay separate. |
| W7 | Evaluation Contract + Scope Manifest discipline | Yes | These are reusable orchestration primitives and reduce ambiguity for all later work. |
| W8 | Auto-dispatch chaining | Yes (rebuild) | Keep the chaining property, but drive it only from the stage registry. |

### Policy Families

| ID | Feature | Recommendation | Rationale |
| --- | --- | --- | --- |
| P1 | Source write WHO + main-branch guard | Yes | This is baseline source-control safety and should remain mechanical. |
| P2 | Governance ownership + plan immutability | Yes | Architecture and plan discipline need mechanical protection if they are to stay trustworthy. |
| P3 | Workflow scope + lease-based git WHO | Yes | This is core to deterministic control and role isolation. |
| P4 | Git safety policies (`main_sacred`, destructive git, force push) | Yes | High-value boundaries with clear risk reduction. |
| P5 | One-shot approval gate for high-risk git ops | Yes | Keeps irreversible operations tied to explicit user consent. |
| P6 | Worktree safety policies | Yes (rebuild) | Keep only on documented and empirically verified surfaces. |
| P7 | Lint-gap, mock, and test-failure gates | Partial | Preserve the control property, but simplify the mechanism and severity model. |
| P8 | Current evaluation-state readiness shortcuts | No | Replace with reviewer verdicts and convergence state, not more evaluation-state complexity. |

### Hook Layer

| ID | Feature | Recommendation | Rationale |
| --- | --- | --- | --- |
| H1 | Thin `pre-write.sh` / `pre-bash.sh` adapters | Yes | This is the correct hook shape and should become the norm. |
| H2 | `pre-agent.sh` guard for worktree/isolation bypass | Yes | Keep the idea, but only on verified harness surfaces. |
| H3 | SessionStart / UserPromptSubmit context injection | Yes (simplify) | Useful as advisory HUD/context, but must stay out of authority paths. |
| H4 | PostToolUse write feedback pipeline | Partial | Some feedback loops are useful, but too much hook-side machinery will re-grow alternate control paths. |
| H5 | Stop-time summarization hooks | Partial | Keep lightweight user-facing summarization, not extra routing or control logic. |
| H6 | Regular Stop provider review hook | Yes (split) | Keep as a separate user-facing lane, not as workflow-routing authority. |
| H7 | `auto-review.sh` command auto-approval engine | No | Too much policy weight in shell for the restart kernel. |
| H8 | Speculative `WorktreeCreate` / `EnterWorktree` wiring | No | Unsupported or unverified harness surfaces do not belong in the restart baseline. |

### Dispatch and Runtime Domains

| ID | Feature | Recommendation | Rationale |
| --- | --- | --- | --- |
| D1 | Workflow bindings and scope storage | Yes | Required for scoped authority and reproducible workflow identity. |
| D2 | Leases | Yes | Strong primitive for git, workflow, and worktree authority. |
| D3 | Agent markers + lifecycle tracking | Yes (rebuild) | Useful, but they need cleaner scoping and stale-marker handling. |
| D4 | Completion records | Yes (rebuild) | Structured completions are valuable if they are driven by the stage registry. |
| D5 | `dispatch_queue` as a side path | No | A non-authoritative queue invites ambiguity about what really routes work. |
| D6 | Events table | Yes | Good audit/read-model substrate as long as it does not become routing authority by accident. |
| D7 | `evaluation_state` as readiness truth | No | Replace with reviewer verdicts, findings, and convergence state. |
| D8 | Worktree registry + provision command | Yes | Strong match for guardian-owned worktree lifecycle. |

### Observability and Support

| ID | Feature | Recommendation | Rationale |
| --- | --- | --- | --- |
| O1 | Runtime-backed statusline | Yes (later) | Valuable read model, but not a cutover-kernel blocker. |
| O2 | Traces and observatory | Yes (read-only) | Useful diagnostics, but must never sit on deny paths. |
| O3 | Bugs / approvals / todos / tokens tables | Later | Useful support domains, not required to establish the new architecture. |
| O4 | Write-triggered code-review hook | Later | Keep only as advisory analysis after the control plane is stable. |
| O5 | Notification hooks | Later | Nice operational surface, not architecture-critical. |
| O6 | Sidecars / shadow services | Later | Preserve the read-only rule, but keep them out of the kernel. |

### Docs and Test Discipline

| ID | Feature | Recommendation | Rationale |
| --- | --- | --- | --- |
| T1 | Scenario tests for real hook paths | Yes | This is how the system proves control claims against the installed harness. |
| T2 | Architecture invariants as tests | Yes | This is the main anti-drift mechanism for future agents. |
| T3 | Repo docs as mechanism authority | No | Docs should describe or validate the system, not outrank code and installed truth. |
| T4 | Official-docs + installed-truth verification habit | Yes | Load-bearing harness assumptions must be verified, not inherited. |
| T5 | Historical plans/docs as donor inputs | Yes | They remain useful only when explicitly ported into the cutover line. |

## Ultimate Design Overview

The intended end state is a small number of explicit authorities connected by
thin adapters.

### Control Flow

1. The user or orchestrator initiates work.
2. A hook adapter receives the harness payload and forwards it to the runtime.
3. The runtime resolves identity, workflow, lease, capability, and scope.
4. The policy engine evaluates the request using runtime-owned facts.
5. If the action is workflow-related, the stage registry determines the next
   valid transition.
6. If the action is review-related, it is routed into one of two lanes:
   - regular Stop review for user-facing turn steering
   - workflow reviewer for technical readiness in the dispatch graph
7. The runtime emits the authoritative result.
8. Hooks only translate that result into harness output.
9. Read models such as statusline, summaries, and diagnostics consume runtime
   projections without becoming authorities themselves.

### Runtime Kernel

The runtime kernel is the only place where the following facts are decided:

- what workflow is active
- what role or capability is active
- what stage the workflow is in
- whether a transition is valid
- whether git landing is permitted
- whether a review verdict is sufficient for the next stage
- what config defaults and overrides are in effect

### Stage Graph

The stage graph is explicit and machine-owned:

`planner -> guardian(provision) -> implementer -> reviewer -> guardian(land)`

This graph is not repeated in prompts, hooks, summaries, or docs as a second
authority. Those other surfaces derive from the runtime registry.

### Two Review Lanes

The design deliberately separates:

- **Regular Stop review**
  User-facing, turn-based, advisory or block-for-user only.
- **Workflow reviewer**
  Read-only, provider-backed, and authoritative for technical readiness before
  guardian can land changes.

This separation is a defining architectural boundary. No event gate or plugin
shim may collapse those two lanes back together.

### Hook Model

Hooks are treated as transport shims bound to the harness contract.

Hooks may:

- read stdin
- normalize payload shape
- invoke runtime commands
- return correct harness outputs

Hooks may not:

- own workflow routing
- own config truth
- reparse semantics the runtime already resolved
- become sidecar policy engines

### Read Models

Statusline, summaries, surface views, diagnostics, and observatory outputs are
read-only projections from runtime state. They exist to make truth visible, not
to define it.

### Runtime-Compiled Prompt Packs

The control plane must describe itself to the models before they act. The
system should not rely on agents learning repo law by denial.

Prompt surfaces are therefore treated as compiled runtime projections rather
than hand-maintained prose authorities.

Every active session or subagent launch should receive a prompt pack built from
the current runtime authorities:

- constitutional rules
- stage and capability state
- workflow scope and evaluation contract
- relevant decisions for the touched domains or files
- current leases, approvals, and git constraints
- unresolved reviewer findings and current readiness state
- legal next actions from the current state

The base static prompt files such as `CLAUDE.md` and `AGENTS.md` remain
important as stable doctrine, but they are not sufficient on their own. The
live prompt must be a compiled view of current law.

#### Prompt Pack Layers

Each prompt pack should be composed from six runtime-owned layers:

1. **Constitution**
   Stable repo-wide invariants and non-negotiable authority rules.
2. **Stage Contract**
   Current role, capabilities, forbidden operations, required outputs, and next
   transition expectations.
3. **Workflow Contract**
   Active work item, scope manifest, rollback boundary, evaluation contract, and
   success criteria.
4. **Local Decision Pack**
   Only the relevant decisions and supersessions for the current file or domain
   surface.
5. **Runtime State Pack**
   Current branch, worktree, lease state, approval state, stale surfaces, and
   unresolved findings.
6. **Next Actions**
   Concrete legal moves from the current state, including the expected recovery
   path when a boundary is hit.

#### Prompt Pack Design Rule

Prompt packs are derived artifacts and must carry provenance metadata:

- generator version
- source registry versions
- generated timestamp
- workflow id
- stage id
- stale markers if upstream state changed after generation

If a constitution-level authority changes, prompt packs must be regenerated.
Stale prompt packs are a failing condition once the prompt compiler is live.

### Canonical Memory and Knowledge Architecture

The restart should adopt a compiled-memory model rather than a chat-history
model.

The strongest current pattern is a hybrid:

- canonical structured registry for machine-owned truth
- canonical markdown memory and durable knowledge for human-readable truth
- derived graph and search layers for retrieval, contradiction analysis, and
  temporal reasoning

This follows the best parts of recent memory work:

- Karpathy's `LLM Wiki` pattern contributes the right canonical structure:
  `raw sources -> persistent wiki -> schema`
- graph-memory systems contribute better retrieval, contradiction handling, and
  temporal reasoning
- git-backed memory systems contribute durability, rollback, and auditable
  evolution

The graph is not canonical truth. It is a compiled read model built from the
canonical registry, markdown memory corpus, and event stream.

#### Canonical Layers

1. **Runtime Registry**
   Structured state for decisions, work items, workflow state, reviewer
   findings, leases, approvals, supersessions, and authority ownership.
2. **Markdown Memory / Durable Knowledge**
   Human-readable policy, decision, and domain memory files kept under version
   control and updated by rule-governed workflows.
3. **Raw Inputs**
   Source docs, traces, captures, and empirical artifacts that feed the memory
   and decision layers without being silently rewritten.

#### Derived Layers

1. **Human Projections**
   `MASTER_PLAN.md`, decision digests, indexes, summaries, and generated docs.
2. **Retrieval Models**
   Search indexes, temporal knowledge graph exports, vector indexes, and
   relevance views.
3. **Agent Context Packs**
   Prompt packs, local decision packs, and workflow summaries injected into
   active agents.

#### Reflow Rule

Every meaningful canonical change must trigger reflow of the dependent derived
surfaces. If a canonical source changed and the affected projections were not
rebuilt or revalidated, the result is stale and must fail landing.

This is the mechanism behind "never outdated":

- canonical truth changes
- generator computes the affected downstream surfaces
- downstream surfaces are re-rendered or revalidated
- stale derived state blocks guardian or CI until refreshed

### Decision and Work Record Architecture

The current `MASTER_PLAN.md` append discipline and `@decision` annotations were
useful bootstrap mechanisms, but they are not the ideal final architecture.

The better final model is layered:

1. **Runtime decision/work registry as canonical authority**
2. **Git commit trailers as landed evidence**
3. **Human-readable projections as derived views**
4. **Lightweight source-level decision references for local comprehension**

#### Canonical Registry

The runtime should own machine-readable records for:

- decisions
- work items
- scope manifests
- evaluation contracts
- supersessions
- authority changes
- links to landed commits once merged

This replaces markdown append-only logs as the canonical machine surface.

#### Git as Evidence, Not Live Memory

Git history remains essential, but as evidentiary trace rather than active
authority.

Constitution-level changes should carry commit trailers such as:

- `Decision: DEC-...`
- `Work-Item: W-...`
- `Authority-Changed: ...`
- `Supersedes: DEC-...`

Git log then serves as landed proof and audit trail. It does not replace the
runtime registry because it is not optimized for pre-commit enforcement,
relevance retrieval, or current-state injection.

#### Human Projections and Source References

`MASTER_PLAN.md` stays, but as a rendered or validated roadmap/execution view.
It should no longer be the sole canonical decision log.

Source-level annotations should evolve from large freeform `@decision`
narratives into resolvable references such as `@decision-ref DEC-...`, so files
can point to active or superseded decisions without becoming parallel stores of
rationale.

### Schema Contract Stack

Schemas are part of the architecture spine. They should define not only API
payloads, but the legal shapes of state, transitions, and derived artifacts.

The cutover should establish three layers of schema contracts.

#### 1. State Schemas

These define what truth may exist in the control plane.

Examples:

- `Decision`
- `WorkItem`
- `ScopeManifest`
- `StageDefinition`
- `CapabilityPolicy`
- `WorkflowState`
- `ReviewerFinding`
- `Lease`
- `Approval`
- `ProjectionMetadata`

Each state schema should define:

- required fields
- ownership and provenance fields
- version field
- status enums
- supersession model where relevant

#### 2. Interaction Schemas

These define legal messages between control-plane components.

Examples:

- hook request and response payloads
- dispatch completion records
- reviewer verdict payloads
- guardian landing results
- deny responses
- prompt-pack payloads
- event records

These schemas make provider-backed stages interchangeable without weakening the
runtime. A reviewer verdict must be a valid record, not just convincing prose.

#### 3. Projection Schemas

These define the shapes and freshness metadata of derived artifacts.

Examples:

- rendered `MASTER_PLAN.md`
- rendered decision digest
- prompt pack
- hook-doc projection
- graph export
- search-index metadata

Each projection schema should carry:

- generator version
- source versions or hashes
- generated timestamp
- stale condition
- provenance links to upstream records

### Guidance, Memory, and Schema Interaction

These pieces are intended to reinforce each other:

- the decision/work registry supplies canonical facts
- markdown memory preserves durable human-readable knowledge
- schema contracts define valid state and transition shapes
- prompt packs compile the relevant subset into model-visible context
- retrieval and graph layers help the model find the right context quickly
- projection freshness checks stop stale guidance from surviving silently

The result is a self-describing control plane:

- models are told the live rules before they act
- runtime validates outputs against schemas
- guardian blocks stale or unmatched derived state
- later agents do not need to remember the architecture because the system
  injects it into their working context

## Principles Embodied by the Design

1. **Single authority over narrated confidence.**
   Operational facts live in one place and can be tested directly.
2. **Deletion-first migration.**
   Replacements remove the superseded path instead of coexisting beside it.
3. **Constraint over convention.**
   The repo should fail loudly when later work tries to create a second
   authority.
4. **Capabilities over folklore.**
   Allowed behavior is expressed in runtime capabilities, not remembered role
   conventions.
5. **Derived surfaces stay derived.**
   Wiring, docs, and role descriptions must not silently outgrow their source
   authorities.
6. **Official harness truth over repo lore.**
   Hook semantics are verified from official docs and installed behavior.
7. **Read-only observers.**
   Diagnostics and sidecars can see state but do not gate action.
8. **Workflow review is a system concern, not a plugin side effect.**
   Technical readiness belongs to the dispatch graph, not to an advisory hook.
9. **Prompts are compiled from live law.**
   The model should receive current authority, scope, and next-move context
   before acting, not discover them by collision.
10. **Canonical truth, derived retrieval.**
    Registries and durable markdown hold truth; graph/search/index layers are
    compiled read models.
11. **Schemas define legality.**
    State, interactions, and projections all require explicit contract layers.
12. **Reflow or fail.**
    If canonical truth changed and derived surfaces were not regenerated or
    revalidated, the state is stale and cannot land.
13. **Git is evidence, not memory authority.**
    Git captures landed proof and provenance; it does not replace live runtime
    registries.
14. **Convergence is explicit.**
    Reviewer/implementer looping is governed by structured findings and invalidation
    rules, not by vague “looks good now” language.
15. **Continuation is planner-owned.**
    After guardian, the planner decides whether the goal continues, completes, or
    requires user input.

## Enforcement Mechanisms

The architecture preserves itself through mechanical enforcement.

### 1. Stage Registry Invariants

The repo must fail tests if:

- stage transitions are defined outside the registry
- reviewer and tester both act as workflow review authorities
- regular Stop review is able to mutate workflow routing

### 2. Capability-Gated Policy

The runtime resolves capabilities for the acting workflow stage and policy
checks key off those capabilities. This prevents shell hooks or ad-hoc modules
from growing their own competing role logic.

### 3. Derived-Surface Validation

`settings.json`, hook docs, and other declarative surfaces are generated from
or validated against the runtime authority layer. A hook path referenced in
config without a real tracked implementation is a failing invariant.

### 4. Constitution-Level Scope Gates

Changes to constitution-level files require:

- explicit architecture-scoped workflow coverage
- matching invariant updates
- decision annotations where applicable

This prevents casual edits to routing, schemas, hook wiring, and authority docs
from bypassing the cutover model.

### 5. Hook-Path Scenario Tests

Every claimed hook control property must be backed by a scenario that exercises
the real hook path, not just the internal runtime helper behind it.

### 6. Installed-Truth Verification

When harness behavior is load-bearing, the repo must verify claims against:

1. official docs
2. empirical capture on the installed runtime
3. only then repo docs

This prevents the system from preserving stale harness assumptions as law.

### 7. Removal Targets as Required Deliverables

Any migration that introduces a new authority surface must name the old one and
remove or bypass it in the same plan slice. A change is not complete if the old
authority still remains live by default.

### 7A. Legacy Freeze During Cutover

The donor path is not a feature runway during migration.

While a subsystem is being cut over:

- no new architectural features should be added to the donor path
- only safety fixes and bridge work are allowed there
- all forward architecture work lands in the new runtime-owned authority path

This keeps migration effort from strengthening the wrong system.

### 8. Prompt-Pack Freshness Enforcement

Prompt packs are generated artifacts. The repo must fail checks if:

- prompt packs are built from stale authority inputs
- prompt packs omit the current stage, capabilities, or workflow contract
- a live prompt surface diverges from the compiled authority declaration

This prevents static prompt files from becoming a second live control plane.

### 9. Schema Validation Across State, Transitions, and Projections

The runtime must validate:

- canonical records on write
- inter-component payloads on send/receive
- derived artifacts at generation or landing time

This ensures that runtime state, hook outputs, reviewer verdicts, and prompt
packs all share enforceable shapes instead of folk contracts.

### 10. Reflow and Staleness Enforcement

Derived surfaces must carry provenance and freshness metadata. If canonical
sources changed and dependent projections were not re-rendered or revalidated,
landing fails.

At minimum this applies to:

- prompt packs
- `MASTER_PLAN.md` and decision digests
- generated or validated hook/config docs
- retrieval indexes and graph exports where present

### 11. Decision and Work-Item Linkage Enforcement

Constitution-level changes must link to runtime decision/work records and landed
git evidence.

This should be enforced through:

- linked decision/work ids in the change context
- commit trailers on landed architecture changes
- resolvable `@decision-ref` references for local code/document context where
  applicable

### 12. Context Injection Enforcement

The system should automatically inject relevant decision, scope, and authority
context on `SessionStart`, `UserPromptSubmit`, `SubagentStart`, and reviewer
launches.

Agents should not be expected to rediscover current rules through grep or denial
messages alone.

## Execution Model

Until the reviewer stage is live, implementation work still uses the current
chain. The cutover does not pretend the new graph exists before it is proven.

The current braid/tmux supervisor stack is containment machinery, not the end
state. During the cutover, it is acceptable to keep using tmux and bridge
helpers to hold Codex in the driver seat. It is not acceptable to let those
helpers become the lasting authority for dispatch, delivery, or recursion.
The target model is a runtime-owned supervision fabric with transport adapters;
the existing bridge is a temporary adapter bundle that will either collapse
behind that interface or be deleted.

Execution during the cutover:

- legacy authorities are frozen except for safety fixes and bridge work
- new control-plane modules may run in shadow mode before they become canonical
- Phase 0 through reviewer introduction use the current live chain where needed
- the `reviewer` stage becomes active only after the stage registry, completion
  contract, and provider adapter are proven together
- old tester authority is removed only when the new reviewer lane is the sole
  workflow review authority
- post-guardian planner continuation only becomes live after planner completion
  contracts and goal contracts are proven together

## Phase Plan

### Phase 0 — Hook Authority Reset

Goal:
Re-establish a trustworthy hook/config surface before deeper cutover work.

Scope:

- audit repo hook docs against official harness docs
- verify supported hook event and matcher surfaces empirically
- resolve speculative worktree-hook wiring
- decide the fate of `auto-review.sh`
- strengthen hook config invariants
- clean gitignore and local-state hygiene defects

Must not touch:

- stage routing semantics
- reviewer-stage introduction
- tester replacement
- provider abstraction

Exit criteria:

- no repo-owned hook is referenced from config without a tracked file
- no speculative harness surface remains live without evidence
- hook docs no longer claim behavior contradicted by official docs
- Phase 0 outcomes are captured as explicit decisions, not ad hoc comments

### Phase 1 — Constitutional Kernel

Goal:
Create the explicit architecture authorities the rest of the cutover depends on.

Scope:

- introduce a runtime stage registry
- introduce an authority map / capability registry in code
- introduce canonical decision/work registries
- introduce goal contracts and work-item contracts as separate runtime domains
- define the schema contract families for state, interaction, and projection
- centralize derived config validation
- define constitution-level files and invariant test entrypoints

Exit criteria:

- no authoritative stage transition logic exists outside the registry
- decision/work records exist as runtime-owned canonical entities
- goal and work-item state are represented separately in canonical schemas
- the initial schema contract stack is defined and versioned
- constitution-level files are enumerated and validated
- routing and capability ownership are explicit in code

### Phase 2 — Hook Adapter Reduction

Goal:
Move live shell semantics back behind the runtime boundary.

Scope:

- remove duplicated shell-side parsing and routing logic
- keep hooks focused on payload normalization and runtime invocation
- eliminate shell-only alternate decisions where Python already owns the fact
- route hook-side context injection through runtime-generated prompt packs

Exit criteria:

- no hook silently reimplements runtime-owned routing or shared-state logic
- hook outputs are thin translations of runtime results
- hook-delivered guidance comes from compiled runtime context rather than
  hand-maintained local prompt fragments

### Phase 2b — Agent-Agnostic Supervision Cutover

Goal:
Replace the current blind bridge loop with a runtime-owned supervision fabric
that can drive any supported coding agent without making tmux or MCP the
authority.

Scope:

- define runtime schemas for agent sessions, seats, supervision threads, and
  dispatch attempts
- define a transport-adapter contract with at least `tmux` and MCP-backed
  implementations
- move queue claim/ack and timeout truth behind runtime-owned state
- represent attached analysis/autopilot supervision explicitly as seat
  relationships instead of ad hoc stop-hook recursion
- demote pane scraping, relay sentinels, helper pids, and recovery bundles to
  diagnostics or transitional adapters only
- migrate current braid/tmux helper scripts behind the new adapter contract or
  delete them when superseded

Exit criteria:

- a queued instruction is not considered healthy until a transport adapter
  records delivery claim in canonical runtime state
- `tmux` may host a worker or supervisor seat, but pane ids are not a control
  authority
- an MCP-capable agent and a generic tmux-hosted CLI agent both use the same
  runtime dispatch and supervision model
- recursive supervision is visible in runtime state as seat/thread records
- the system can stop or recover a dead delivery loop without relying on
  repeated stop-hook turns as the primary liveness mechanism

### Phase 3 — Capability-Gated Policy Model

Goal:
Replace repeated role-name logic with explicit capability enforcement.

Scope:

- define capability resolution in the runtime
- migrate policy checks to capabilities
- lock reviewer behavior to read-only capabilities
- define stage-specific forbidden operations and legal next moves for prompt-pack
  compilation
- define guardian and planner continuation permissions separately from reviewer
  permissions

Exit criteria:

- reviewer read-only rules are enforceable mechanically
- policy modules no longer depend on scattered role folklore
- stage contracts can be projected into prompt packs deterministically
- planner and guardian have distinct continuation authorities

### Phase 4 — Workflow Reviewer Introduction

Goal:
Introduce `reviewer` as a first-class workflow stage without yet removing the
legacy path.

Scope:

- add reviewer completion schema
- add reviewer findings and convergence state
- add runtime commands for provider-backed review execution and submission
- define reviewer verdict handling in the stage registry
- wire reviewer prompt packs to current findings, scope, and read-only
  capability state
- add invalidation rules so source changes after reviewer clearance reopen the
  work-item loop

Exit criteria:

- the runtime can represent reviewer completions and findings natively
- reviewer is read-only by policy
- the new workflow lane can run in a shadow or staged mode without split
  authority claims
- reviewer outputs are validated against interaction schemas instead of accepted
  as freeform prose
- convergence state is explicit and invalidates correctly on post-review source
  changes

### Phase 5 — Loop Activation and Tester Removal

Goal:
Make workflow review and regular Stop review fully separate, activate the new
work-item loop, and remove tester as a routing authority.

Scope:

- switch workflow routing to `implementer -> reviewer -> guardian`
- keep regular Stop review in its own user-facing lane
- remove workflow-routing dependence on stop-review events
- remove tester from the authoritative dispatch path
- activate `reviewer(needs_changes) -> implementer` as the canonical convergence
  loop

Exit criteria:

- workflow routing no longer depends on tester
- regular Stop review cannot affect workflow routing
- reviewer is the sole technical readiness authority before guardian
- the implementer/reviewer loop is canonical and test-backed

### Phase 6 — Goal Continuation Activation

Goal:
Teach the system what happens after guardian without turning reviewer into a
planner surrogate.

Scope:

- add planner completion contracts
- add planner verdict handling for `goal_complete`, `next_work_item`,
  `needs_user_decision`, and `blocked_external`
- activate `guardian(land) -> planner` as the default post-land continuation
- enforce autonomy-budget and user-decision boundaries
- make planner the only authority for deciding what comes next after landing

Exit criteria:

- post-guardian continuation is planner-owned
- the system can continue automatically only within the current approved goal
- user re-entry boundaries are explicit and test-backed

### Phase 7 — Derived Surface Generation and Enforcement

Goal:
Make drift harder to reintroduce.

Scope:

- generate or validate `settings.json` from authority declarations
- validate docs against authority surfaces
- render or validate `MASTER_PLAN.md` and decision digests from the canonical
  registry
- add prompt-pack generation and freshness checks
- add projection metadata and reflow enforcement
- add retrieval-model generation hooks where justified
- add architecture linting or invariant checks for duplicated routing/config
  logic
- add scope-gated enforcement for constitution-level files

Exit criteria:

- changing a constitution-level authority without its invariant updates fails
- hook wiring and docs cannot silently drift from runtime declarations
- stale prompt packs and stale decision/plan projections fail landing
- derived retrieval layers are provably downstream from canonical state

### Phase 8 — Legacy Deletion and Final Cutover

Goal:
Delete superseded authorities and close the migration cleanly.

Scope:

- remove tester-era routing authority
- remove obsolete hook docs and wiring
- remove compatibility mirrors that outlived migration usefulness
- collapse remaining duplicate control surfaces

Exit criteria:

- only one live authority remains for each operational fact in the authority map
- no compatibility path is mistaken for an active control path

## Invariants That Must Become Tests

The cutover is not complete without mechanical checks.

1. No stage transitions are defined outside the stage registry.
2. No workflow-routing dependency remains on Stop-review events.
3. No repo-owned hook path in `settings.json` points to a missing file.
4. No constitution-level config default is defined outside the schema/bootstrap
   authority.
5. No policy module reparses command semantics already supplied by runtime
   intent objects.
6. Reviewer capabilities are read-only and cannot land git or edit source.
7. Regular Stop review and workflow review cannot mutate each other's routing
   state.
8. Docs that claim harness behavior are either generated, validated, or clearly
   marked as non-authoritative reference.
9. Prompt packs are generated from runtime authority and carry freshness
   metadata.
10. Canonical decision/work records exist outside markdown-only logs.
11. `@decision-ref` links resolve to active or explicitly superseded decisions.
12. Derived projections fail validation when upstream canonical state changed
   without reflow.
13. Retrieval and graph layers are derived read models and never treated as
   legal source of truth.
14. Post-guardian continuation is planner-owned, not reviewer- or hook-owned.
15. Any source change after reviewer clearance invalidates readiness.
16. Automatic continuation beyond guardian is allowed only within the active
   goal contract and autonomy budget.

## Constitution-Level Files

These files or areas are constitution-level during the cutover and must not be
edited casually:

- `CLAUDE.md`
- `AGENTS.md`
- `settings.json`
- `implementation_plan.md`
- `MASTER_PLAN.md`
- `hooks/HOOKS.md`
- `runtime/cli.py`
- `runtime/schemas.py`
- `runtime/core/dispatch_engine.py`
- `runtime/core/completions.py`
- `runtime/core/policy_engine.py`
- `runtime/core/prompt_pack.py` (promoted from planned area in Phase 2)
- `runtime/core/stage_registry.py` (promoted from planned area in Phase 7 Slice 3)
- `runtime/core/authority_registry.py` (promoted from planned area in Phase 7 Slice 3)
- `runtime/core/decision_work_registry.py` (promoted from planned area in Phase 7 Slice 4)
- `runtime/core/projection_schemas.py` (promoted from planned area in Phase 7 Slice 5)
- `runtime/core/hook_doc_projection.py` (promoted from planned area in Phase 7 Slice 5)
- `runtime/core/hook_doc_validation.py` (promoted from planned area in Phase 7 Slice 5)
- `runtime/core/prompt_pack_validation.py` (promoted from planned area in Phase 7 Slice 5)
- `runtime/core/hook_manifest.py` (added as concrete in Phase 7 Slice 8)
- `runtime/core/prompt_pack_resolver.py` (added as concrete in Phase 7 Slice 10)
- `runtime/core/decision_digest_projection.py` (added as concrete in Phase 7 Slice 13)
- `runtime/core/projection_reflow.py` (promoted from planned area in Phase 7 Slice 16)
- `runtime/core/memory_retrieval.py` (promoted from planned area in Phase 7 Slice 17)

Rule:
changes to these files require explicit architecture-scoped plan coverage,
decision annotation where relevant, and invariant test updates.

## Donor Surfaces and Historical Inputs

The following documents remain donor material, not cutover authority:

- `implementation_plan.md`
- `MASTER_PLAN.md`
- `docs/ARCHITECTURE.md`
- `docs/DISPATCH.md`

They may be harvested, but the restart is grounded here. If a historical doc is
still right, port the decision into the ClauDEX line explicitly.

## Phase Deliverables

Each phase must produce:

1. a plan entry with scope and non-goals
2. a scope manifest covering allowed and forbidden files
3. an evaluation contract
4. invariant updates
5. explicit removal targets
6. a statement of which operational facts changed authority, if any
7. schema changes and migration notes, if any
8. prompt-pack or projection updates required by the slice
9. whether the slice runs in shadow mode, live mode, or deletion mode

## Non-Negotiable Cutover Rules

1. Do not patch around an architectural split without naming the split.
2. Do not keep both old and new workflow authorities alive by default.
3. Do not let provider-specific review logic own dispatch.
4. Do not trust repo docs over official harness behavior.
5. Do not start the reviewer stage cut until Phase 0 has reset hook authority.
6. Do not claim success without showing which old authority was removed.
7. Do not let prompt files become a second live control plane.
8. Do not let graph or retrieval layers become canonical truth.
9. Do not land constitution-level changes without linked decision/work records.
10. Do not use reviewer as a substitute planner for what happens after landing.
11. Do not enable autonomous continuation beyond the current approved goal
    contract.

## Final Acceptance Condition

The cutover is complete only when:

- the runtime is the sole owner of workflow routing, review readiness, config
  defaults, and capability resolution
- hooks are thin adapters rather than competing policy engines
- workflow reviewer is a first-class, read-only stage
- the implementer/reviewer loop converges through structured findings rather than
  prompt folklore
- planner owns post-guardian continuation and goal completion decisions
- regular Stop review is separated from workflow routing
- `settings.json`, docs, and role surfaces are derived from or validated
  against runtime authority
- prompt packs are compiled from live authority, scope, decisions, and runtime
  state
- canonical decisions and work items live in a runtime registry with git-linked
  evidence
- schema contracts govern state, transitions, and projections
- derived projections and retrieval layers reflow automatically or fail as stale
- invariant tests fail when a future agent tries to reintroduce a second
  authority

At that point, later work can extend the architecture without quietly
redefining it.
