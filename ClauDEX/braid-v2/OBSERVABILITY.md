# braid-v2 Observability and Run Forensics

## Goal

`braid-v2` must retain enough runtime-owned evidence to answer these questions
without scraping raw tmux panes or reconstructing history from operator memory:

- what happened in this bundle, in order
- which seat or session caused each transition
- what the worker, supervisor, and parent dispatcher each saw
- which policy or repair decision was made and why
- whether a run was healthy, blocked, looping wastefully, or silently degraded
- how a child bundle relates to its parent bundle and parent conversation

This document defines the missing observability layer needed for soak
monitoring, post-run diagnosis, evaluator tooling, and future self-improvement
loops.

## Current Gap

The current repository already has useful evidence surfaces, but they stop short
of full run forensics:

- the old bridge stores turns, responses, transcript paths, and events
- the old observer stores only `observer/latest.*`, so captures are overwritten
- the existing runtime `traces` tables are intentionally trace-lite evidence
- the v2 schema already has the right supervision objects, but not the full
  trajectory/export layer

That means the system can often explain the latest state, but it cannot yet
export a complete recursive bundle history in a way that an evaluator or a
later supervisor can consume directly.

## Design Rules

- tmux capture is evidence, never authority
- all retained run-forensics state must be referenced from the runtime-owned
  ledger
- append-only event history beats mutable status snapshots for diagnosis
- transcripts, pane captures, gate excerpts, review payloads, and repair
  results should all be addressable artifacts, not ad hoc files found by
  convention
- parent and child bundles must remain linkable after either side exits
- policy decisions should be linked by reference, not reimplemented inside
  `braid-v2`

## Required Outputs

The observability layer must let an operator, evaluator, or parent supervisor
retrieve:

- a chronological bundle timeline
- paired conversation history for worker, supervisor, dispatcher, and child
  bundles
- retained snapshots at review, gate, timeout, recovery, and archive boundaries
- gate and repair timelines
- a single archive manifest for offline review

## Canonical Objects

### `trajectory_event`

An append-only record of a meaningful runtime transition.

This is the missing backbone for run forensics. Status tables tell us the
current truth; trajectory events explain how the system got there.

Minimum fields:

- `event_id`
- `bundle_id`
- `session_id`
- `seat_id`
- `thread_id`
- `dispatch_attempt_id`
- `review_artifact_id`
- `interaction_gate_id`
- `finding_id`
- `repair_action_id`
- `event_type`
- `summary`
- `payload_ref`
- `policy_decision_ref`
- `created_at`

Initial event vocabulary:

- `bundle_created`
- `bundle_spawn_requested`
- `bundle_spawn_fulfilled`
- `bundle_paused`
- `bundle_archived`
- `session_adopted`
- `session_spawned`
- `session_exited`
- `dispatch_issued`
- `dispatch_claimed`
- `dispatch_acknowledged`
- `dispatch_timed_out`
- `dispatch_failed`
- `review_artifact_created`
- `review_artifact_consumed`
- `interaction_gate_opened`
- `interaction_gate_resolved`
- `heartbeat_recorded`
- `finding_opened`
- `finding_closed`
- `repair_action_requested`
- `repair_action_started`
- `repair_action_succeeded`
- `repair_action_failed`
- `observer_snapshot_recorded`

### `conversation_link`

A durable link between a seat/session and the transcript or conversation history
that belongs to it.

Minimum fields:

- `conversation_id`
- `bundle_id`
- `session_id`
- `seat_id`
- `parent_conversation_id`
- `harness`
- `transport`
- `transcript_ref`
- `conversation_ref`
- `started_at`
- `ended_at`
- `metadata_json`

This is what lets a later export answer:

- which Codex supervisor conversation drove this worker
- which Claude worker transcript belongs to this review artifact
- which child bundle conversations were opened by which parent seat
- which subagent transcripts belong under which session tree

### `snapshot_artifact`

An immutable retained observation, not just the mutable latest capture.

Minimum fields:

- `snapshot_id`
- `bundle_id`
- `session_id`
- `seat_id`
- `dispatch_attempt_id`
- `trigger`
- `source_type`
- `classification`
- `text_ref`
- `svg_ref`
- `json_ref`
- `created_at`

Required triggers:

- dispatch issued
- review artifact created
- interaction gate opened
- timeout or health degradation
- recovery or repair action start
- archive
- periodic soak snapshot

### `bundle_archive`

One durable export unit for offline review and evaluator tooling.

Minimum fields:

- `archive_id`
- `bundle_id`
- `manifest_ref`
- `sqlite_ref`
- `created_at`
- `notes`

Each archive manifest should reference:

- exported SQLite snapshot or logical dump
- trajectory events
- conversation links
- retained snapshots
- review artifacts
- gate records
- findings
- repair actions
- test results
- git metadata

## Artifact Layout

The runtime should keep authoritative references in SQLite and store large
payloads as artifacts beneath a runtime-owned artifact root such as:

```text
artifacts/
  bundles/<bundle_id>/
    conversations/
    snapshots/
    reviews/
    gates/
    repairs/
    archives/
```

`braid-v2` should store artifact references, not infer meaning from file names.

## Conversation Pairing Model

The pairing model should be explicit:

- every seat gets zero or one active `conversation_link`
- every child bundle conversation links back to the parent seat that requested
  it
- supervisor and worker conversations are siblings under the same bundle
- dispatcher conversations can span several bundles but still retain per-bundle
  links
- harness-native transcript paths remain valid evidence, but `braid-v2`
  normalizes them through `conversation_link`

For Claude Code, the first implementation can reference the existing transcript
path. For Codex or Gemini, the adapter should provide an equivalent transcript
or export handle.

## Policy and Decision Trace

`braid-v2` should not copy policy-engine internals. It should record the
decision reference used at runtime:

- policy version or config hash
- policy decision ID when available
- evaluation scope
- verdict
- rationale excerpt or artifact reference

That keeps `braid-v2` integrated with the shared policy engine while still
making supervisory decisions auditable after the fact.

## Automatic Observation and Gate Detection

The missing capability is not basic gate modeling. The missing capability is
runtime-owned automatic seat coverage.

`braid-v2` should not rely on an operator noticing that a pane is blocked.
The runtime should know which seats must be watched, when they should be
sampled, and when a blocked prompt should become a first-class gate record.

### Authority Split

- the adapter owns capture primitives and lightweight transport facts
- the observer owns sensing and artifact creation
- the controller owns health derivation and repair triggers
- the supervisor owns judgment, review, and steering

That keeps pane scraping out of the controller and keeps the supervisor from
becoming an ad hoc polling loop.

### Observation Policy

Every live seat should have an observation policy derived from its role and
runtime state.

Minimum policy dimensions:

- `watch_mode`: `off` | `passive` | `active` | `blocked_recheck`
- `sampling_interval_ms`
- `capture_lines`
- `trigger_set`
- `dedupe_window_ms`

Expected defaults:

- worker seat with inflight dispatch: `active`
- worker seat at review boundary: `passive`
- supervisor seat capable of harness approvals: `passive`, escalated to
  `active` around dispatch/review transitions
- seat already blocked on a gate: `blocked_recheck`
- terminal or archived seat: `off`

### Observer Loop

`braid-v2` should run a dedicated observer loop separate from
`controller_sweep()`.

The observer loop should:

1. select seats whose observation policy says they should be sampled
2. capture pane or session state through the adapter
3. classify the capture for:
   - gate present
   - progress change
   - dead or detached session
   - no meaningful change
4. persist retained artifacts and trajectory events only when the content or
   boundary meaning changed
5. update seat/session liveness records for the controller to consume

`controller_sweep()` should reason over recorded runtime facts. It should not
be the component that performs ad hoc pane capture.

### Trigger-First Behavior

Polling alone is wasteful. The preferred order is:

1. immediate observation on runtime boundaries
2. low-rate background sampling as a fallback

Minimum triggers:

- dispatch issued
- dispatch claim or ack
- review artifact created
- seat or session respawned
- timeout threshold crossed
- open gate unresolved beyond its recheck interval
- repair action started or completed

### Snapshot Retention and Dedupe

The observer should not write a full retained snapshot on every sample.

Instead:

- compute a stable content hash from the meaningful capture body
- if the hash is unchanged and no boundary changed, skip retained artifact
  creation
- if the hash changed, or a gate/review/timeout/recovery/archive boundary was
  crossed, persist a `snapshot_artifact` and a matching `trajectory_event`

This keeps traces useful without turning soak into artifact spam.

### Gate Classification

The interaction-gate detector should become a structured classifier, not just a
regex exit hatch.

Minimum output:

- `gate_type`
- `confidence`
- `prompt_excerpt`
- `choices`
- `selected_choice`
- `requires_resolution`

Near-term rule:

- Codex/Claude harness approval prompts such as "Tool call needs your approval"
  should classify as `tool_confirmation`
- trust-directory prompts should classify as `trust_prompt`
- edit confirmation prompts should classify as `edit_approval`
- settings prompts should classify as `settings_approval`
- anything still unresolved falls back to `permission_prompt` or
  `unknown_blocking_prompt`

### Blocked vs. Stale

`blocked on gate` and `stopped making progress` are different runtime states.

Per watched seat, the observer/controller pair should be able to distinguish:

- healthy and actively changing
- healthy and intentionally waiting
- blocked on an open interaction gate
- stale with no gate and no progress change
- dead or detached session

Minimum per-seat progress evidence:

- `last_snapshot_hash`
- `last_change_at`
- `last_observed_at`
- `last_dispatch_event_at`
- `last_review_artifact_at`
- `blocked_reason`

### Seat Coverage Requirement

Automatic observation must cover more than worker seats.

At minimum it should watch:

- worker seats with inflight or recently-issued dispatch attempts
- supervisor seats that can block on harness-native approvals
- dispatcher seats when the dispatcher itself is a live harness session

This is required because supervision itself can block on prompts, not just the
worker lane.

## Diagnostic Surfaces

The CLI and any later MCP surface should expose:

- `braid2 trace tree --bundle <bundle_id>`
- `braid2 trace timeline --bundle <bundle_id>`
- `braid2 trace conversations --bundle <bundle_id>`
- `braid2 trace export --bundle <bundle_id> --format json`
- `braid2 diagnose bundle --bundle <bundle_id>`
- `braid2 archive create --bundle <bundle_id>`

The key requirement is that a supervisor or evaluator should be able to ask the
runtime for a coherent diagnosis instead of scraping panes and stitching files
together ad hoc.

## Incremental Implementation Plan

This should be built as a parallel lane, not as a rewrite of the current v2
kernel work.

### O1: Trajectory Ledger and Retained Snapshots

Deliver:

- `trajectory_events` schema and kernel helpers
- immutable `snapshot_artifacts`
- observer-loop skeleton and seat observation policy
- controller and adapter writes for dispatch, review, gate, timeout, and repair
  boundaries

Do not block:

- kernel skeleton
- tmux adopt/spawn/send work

This lane should start once the current bundle/session/seat/dispatch objects are
stable enough to reference.

### O2: Conversation Pairing

Deliver:

- `conversation_links`
- adapter-level transcript registration for worker and supervisor sessions
- parent-child conversation linkage for spawned bundles
- automatic gate classification coverage for worker and supervisor seats

Do not block:

- basic child bundle spawn
- first single-harness live supervision

This lane should run alongside recursive bundle spawn and harness adapter
hardening.

### O3: Export, Archive, and Diagnose

Deliver:

- bundle export commands
- archive manifest generation
- timeline and conversation queries
- diagnostic summaries for supervisors and evaluators

This should complete before:

- declaring observer-led soak ready
- declaring evaluator tooling ready
- sharing `braid-v2` as an independent package

## Minimal Planning Insertion

To add this without unnecessary interference:

1. Keep the current Phase A through Phase G structure.
2. Add a parallel observability lane rather than renumbering the main phases.
3. Treat O1 as an enabler that can begin after Phase C foundations are stable.
4. Treat O2 as work that rides alongside Phase D and Phase E.
5. Treat O3 as a release-readiness and soak-readiness gate, not as a blocker on
   the first controller or adapter smoke runs.

This keeps the critical path focused on runtime control while ensuring the first
serious soak and the eventual external package both have proper run forensics.

## Definition of Done

The observability lane is complete when:

- a supervisor can explain a bundle from runtime-owned exports alone
- a parent dispatcher can inspect child-bundle history without pane scraping
- repeated failures can be grouped into findings from retained evidence
- archive output is sufficient for offline diagnosis
- evaluator tooling can consume exported traces directly
