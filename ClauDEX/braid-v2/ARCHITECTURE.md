# braid-v2 Architecture

## Goal

Build a runtime-owned supervision kernel that can manage recursive,
multi-harness coding loops without making tmux, stop hooks, file queues, or
provider-specific bridges authoritative.

The first real deployment target is:

- Codex supervising Claude Code

But the architecture must also support:

- Claude Code supervising another Claude Code worker
- Codex supervising Gemini CLI
- a central dispatcher seat watching several supervised loops at once

## Core Principle

Supervision is its own product and its own authority domain.

`braid-v2` should know:

- what loops exist
- which seats belong to each loop
- who supervises whom
- what instruction is currently outstanding
- whether delivery was claimed
- whether review is needed
- whether a loop is healthy
- whether a finding should open a bounded repair loop

It should not guess these facts from pane text.

## Runtime Objects

### `loop_bundle`

A `loop_bundle` is the smallest unit of recursively managed work.

It groups the seats that together form one monitored loop:

- one worker seat
- zero or one local supervisor seat
- zero or one reviewer seat
- zero or one observer seat
- optional child bundles

This is the missing layer between raw seats and the user's mental model of
"that worker plus its supervisor."

### `agent_session`

One live harness instance.

Examples:

- a Claude Code process in a tmux pane
- a Codex process in a tmux pane
- a Gemini CLI process in a tmux pane
- a provider-backed MCP connection

Sessions own transport identity, not workflow law.

### `seat`

A role attached to an `agent_session`.

Examples:

- `worker`
- `supervisor`
- `reviewer`
- `observer`
- `dispatcher`

Seats are the runtime addressable entities for dispatch and supervision.

### `supervision_thread`

An explicit relationship between two seats.

Examples:

- `codex-supervisor-seat` supervises `claude-worker-seat`
- `meta-dispatch-seat` supervises `codex-supervisor-seat`
- `observer-seat` monitors `child-bundle`

This is what makes recursive meta-analysis first-class instead of a stop-hook
trick.

### `dispatch_attempt`

One instruction issued to one seat.

It must track:

- issued
- delivery claimed
- optionally acknowledged when a transport really supports that
- timed out
- failed
- superseded

Completion is not acknowledgment. Completion is a different domain.

### `review_artifact`

A structured handoff produced by a supervised seat when it reaches a review or
decision boundary.

This is what should wake a supervisor seat, not generic turn boundaries.

### `interaction_gate`

A native harness prompt that blocks forward progress inside an otherwise live
attempt.

Examples:

- "Do you want to make this edit?"
- trust-directory prompt
- permission approval prompt
- "allow Claude to edit settings for this session?"

This is not the same thing as a review artifact.

- a `review_artifact` is work produced for a supervisor
- an `interaction_gate` is a harness decision boundary that must be answered,
  deferred, or escalated before the same attempt can continue

The screenshot case from the live bridge is exactly this class of problem:
the worker is neither dead nor healthy. It is blocked inside the harness on an
approval question that the current bridge mostly sees as pane text.

### `finding`

A durable anomaly, defect, or soak-period observation.

Examples:

- repeated timeout on one adapter
- worker returned to raw prompt without changing dispatch state
- same review artifact re-opened repeatedly
- transport adapter contradicts declared state

Findings can remain open across sessions and bundles.

### `repair_action`

A bounded, runtime-owned response to a finding.

Examples:

- restart a seat
- archive a dead bundle
- requeue one dispatch attempt
- open a child repair bundle
- pause a bundle and wait for user input

This keeps repair behavior explicit instead of hidden in watchdog scripts.

## Authority Boundaries

### braid-v2 Owns

- execution bundle topology
- seat/session identity
- transport adapter state
- dispatch delivery ledger
- interaction gates
- health calculations
- review-needed wakeups
- soak findings
- repair action history

### Policy Engine Owns

- prompt pack generation
- scope manifests
- leases
- branch policy
- repo write rules
- review criteria
- approval policy

The intended implementation is the existing ClauDEX runtime policy engine in
[policy_engine.py](../../runtime/core/policy_engine.py), backed by
[authority_registry.py](../../runtime/core/authority_registry.py),
[prompt_pack.py](../../runtime/core/prompt_pack.py), and
[prompt_pack_resolver.py](../../runtime/core/prompt_pack_resolver.py).
`braid-v2` should integrate with that policy surface, not fork it.

### tmux Owns

- process hosting
- pane attachment
- input delivery
- pane capture

`tmux` does not own:

- queue truth
- completion truth
- health truth
- retry truth

## Recursive Central Dispatch

The central dispatch model is:

1. A top-level dispatcher seat owns the overall mission.
2. It may supervise one or more local supervisor seats.
3. Any supervisor seat may request a child `loop_bundle`.
4. That child bundle gets its own worker and optionally its own supervisor.
5. The parent dispatcher continues monitoring both the original loop and the
   child loop.

That allows the "opposite direction" case:

- a meta-supervisor thread can keep supervising the current Claude loop
- it can also spawn another Claude loop with its own plan
- it can also attach a local supervisor to that child loop
- it remains the central dispatcher above both

### Resulting Topology

```text
bundle root
  dispatcher seat (Codex or Claude)
    ├─ supervises supervisor seat A
    │    └─ supervises worker seat A (Claude Code)
    └─ supervises supervisor seat B
         └─ supervises worker seat B (Claude Code or other harness)
```

The dispatcher does not need to inspect raw tmux state for both loops. It reads
runtime state and only uses the adapter when it needs to act.

## Self-Adaptation Rule

Self-adaptation should not be approved by the same seat that proposed it.

The runtime rule should be:

1. a local supervisor seat may propose a self-change or child-loop spawn
2. a parent `dispatcher` seat acts as the arbiter for that request
3. the policy engine decides whether that class of self-adaptation is allowed
   at all

That keeps arbitration and policy separate:

- `dispatcher` or meta-supervisor seat: runtime approval-routing authority
- policy engine: repo-law authority for whether the request is permitted

Examples:

- a local supervisor may propose spawning a child loop
- the parent dispatcher decides whether that request should advance
- the shared ClauDEX policy engine decides whether that class of spawn or
  self-change is allowed under current repo law
- `braid-v2` provisions the result only after both conditions are satisfied

For the first implementation, `dispatcher` is the arbiter role. A separate
`arbiter` seat type is optional later if the vocabulary needs to split more
finely.

## Keepalive Strategy

The keepalive model should be controller-driven, not stop-hook-driven.

### Controller Responsibilities

- watch the canonical database for stale dispatch attempts
- watch adapter heartbeats
- detect review artifacts that require supervisor wakeup
- detect unhealthy loops
- execute a bounded repair policy

### Supervisor Responsibilities

- review returned work
- issue the next bounded instruction
- escalate when a user boundary is reached

### Observer Responsibilities

- sample text or adapter telemetry
- write observations and anomaly candidates
- never mutate workflow state directly

### Health Rules

A loop is healthy only if:

- its worker session exists
- its controlling supervisor or dispatcher session exists when required
- its active dispatch attempt has recent progress or a valid outstanding window
- it is not stuck behind an unresolved interaction gate unless the gate is
  intentionally delegated and within SLA
- review artifacts are fresh and not repeatedly re-consumed
- no stale repair action is spinning on the same condition

### Anti-Waste Rule

Repeated wakeups on the same unchanged condition are not progress.

The controller must suppress repeated restarts or repeated supervisor wakeups
when:

- the same review artifact has already been consumed
- the same attempt has already timed out and no retry budget remains
- the worker is idle and the bundle is already marked blocked
- the same interaction gate is still open and no new resolution path exists

## Interaction Gates

This is the explicit fix for the scenario in the screenshot.

The controller and adapters must distinguish:

- `review_artifact`
  The worker finished a bounded unit and needs supervision.
- `interaction_gate`
  The worker is blocked inside the harness on a local approval or trust prompt.

### Required Gate Types

- `trust_prompt`
- `edit_approval`
- `settings_approval`
- `permission_prompt`
- `tool_confirmation`
- `unknown_blocking_prompt`

### Required Gate Behavior

1. Adapter detects the gate and records it against:
   - session
   - seat
   - current dispatch attempt when one exists
2. Seat status becomes `blocked`.
3. Controller suppresses new dispatch issuance to that seat.
4. If local policy allows automatic resolution, the adapter may answer it.
5. Otherwise the controller creates a review artifact or escalation for the
   correct supervising seat.
6. When resolved, the gate is closed and the attempt either resumes or fails
   explicitly.

### Why This Matters

Without an explicit gate model, the system confuses several different states:

- worker is productively running
- worker is waiting for human approval
- worker is at a dead prompt
- worker is safe to auto-answer

That confusion is one of the reasons the current bridge wastes turns.

### Breakglass Escalation

Not every gate should collapse directly to the user.

`braid-v2` should model a typed escalation path for gates that cannot be
resolved locally but may be resolved by a higher authority.

The runtime side owns:

- gate detection
- escalation request routing
- review artifact delivery to the next supervising seat
- gate resolution attempts
- resume/cancel mechanics
- trajectory evidence for the full chain

The policy side owns:

- whether this gate type is eligible for escalation
- which higher seat or user boundary is allowed to approve it
- grant scope
- TTL
- single-use vs reusable semantics
- audit requirements

The intended chain is:

`interaction_gate` -> `gate_escalation_request` -> policy decision ->
`approval_grant` -> gate resolution -> seat resumes or fails explicitly

This keeps authorities clean:

- `braid-v2` manages the live blocked situation
- the policy engine decides whether an exception is permitted
- the adapter executes the approved allow/deny/cancel action

### Breakglass Runtime Components

`braid-v2` should add:

- `gate_escalation_request`
- `gate_resolution_attempt`
- escalation-aware review artifacts for parent supervisor or dispatcher seats
- trajectory events for request, grant, consume, deny, expire, and execution

These are runtime objects, not policy objects, because they describe the live
state of a blocked bundle.

### Breakglass Policy Components

The shared policy engine should add:

- `breakglass_policy`
- `approval_hierarchy`
- `approval_grant`
- `grant_scope`
- `grant_expiry`
- `grant_consumption`

The grant should be a narrow temporary exception lease, not a generic bypass.

Minimum grant shape:

- `grant_id`
- `bundle_id`
- `seat_id`
- `session_id`
- `gate_id`
- `gate_type`
- `approved_by`
- `scope`
- `resolution`
- `expires_at`
- `single_use`
- `reason`
- `policy_decision_ref`

### Why This Belongs Here

Without a breakglass path, every hard gate degenerates into one of two bad
options:

- halt the whole supervision chain and wait for a human watching tmux
- smuggle an approval through an untyped manual override

The breakglass path keeps recursion intact:

- worker can escalate to supervisor
- supervisor can escalate to dispatcher
- dispatcher can escalate to user only when policy requires it

The same runtime shape then works for Claude Code, Codex, Gemini, and later
providers without changing authority ownership.

### Transitional Current-Bridge Handling

The current bridge can only approximate this using:

- tmux pane capture from the watchdog path
- a run-scoped gate artifact
- explicit tmux key send for resolution

That is acceptable as containment, but it is not the desired authority shape.
In `braid-v2`, the gate record is canonical and tmux key send is merely one
adapter action for resolving it.

## Transport Model

Each transport adapter must expose the same contract:

- `spawn_session`
- `adopt_session`
- `send_instruction`
- `capture_observation`
- `claim_delivery`
- `mark_failed`
- `mark_timeout`
- `interrupt`
- `terminate`

Optional capabilities:

- `structured_ack`
- `structured_completion`
- `heartbeat`
- `list_children`

### tmux Adapter

Good for:

- generic CLI agents
- adopt-existing-pane workflows
- recursive spawning from inside one host session
- capturing native blocking prompts as interaction gates

Limits:

- weak structure
- delivery and health require adapter logic plus observation, not just pane text

### MCP / Provider Adapter

Good for:

- structured control
- explicit replies and delivery metadata
- less reliance on pane capture

Limits:

- harness-specific
- may not support adopt-existing-session as cleanly as tmux

## Spawn and Adopt Modes

### Adopt Mode

Used when a live coding loop already exists.

Example:

- discover an existing Claude Code pane
- create an `agent_session`
- bind a `worker` seat to it
- attach a new `supervisor` seat in another session
- mark the resulting pair as one `loop_bundle`

### Spawn Mode

Used when a new loop should be created from a parent dispatcher or supervisor.

Example:

- parent seat requests a child bundle
- runtime allocates a new bundle id
- tmux adapter opens worker pane and supervisor pane
- policy engine generates prompt packs for both
- central dispatcher receives the child bundle id and monitors it

## Recursive Decision Routing

When a child loop hits an interaction gate, the answer should not default to
the human operator.

Preferred routing order:

1. child-local supervisor seat if policy permits
2. parent dispatcher seat
3. human operator only when the gate crosses a declared approval boundary

That allows the "meta supervisor" pattern to stay alive during recursive work
instead of collapsing every local approval prompt back to the user.

## Soak Monitoring

Soak mode exists to keep a config or harness live long enough to expose real
operational defects and then fix them in place without ad hoc babysitting.

It should support three modes:

- `observe_only`
- `propose_repair`
- `bounded_auto_repair`

In `bounded_auto_repair`, the controller may open a child repair bundle when:

- a finding matches a known repair policy
- retry budget is available
- the repair scope is below the configured autonomy budget

Repairs should be normal bundles with their own worker and optional supervisor,
not hidden shell scripts.

## Separation From the Current Setup

This design should not be implemented by mutating the current live bridge into a
different shape.

Instead:

- keep the current bridge running only as containment
- build `braid-v2` as a separate kernel
- prove it against adopt-mode first
- only then migrate the current live path behind it
