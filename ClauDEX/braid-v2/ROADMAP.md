# braid-v2 Build Roadmap

This roadmap is for building the new supervision kernel without disturbing the
current live bridge.

## Phase A: Kernel Skeleton

Deliver:

- SQLite schema from [SCHEMA.sql](SCHEMA.sql)
- ID generation and CRUD helpers
- one controller process that can run a single sweep

Exit criteria:

- bundle, session, seat, thread, dispatch, finding, repair rows can be created
- no transport-specific code yet

## Phase B: tmux Adapter With Adopt Mode

Deliver:

- tmux adapter implementing:
  - adopt session
  - spawn session
  - send instruction
  - capture observation
  - detect native interaction gates
  - terminate
- adopt existing Claude Code worker into one bundle
- attach one supervisor session to it

Exit criteria:

- current-style loops can be brought under runtime authority without file queue
  canon
- native edit/trust/permission prompts can be recorded as interaction gates
  instead of being left as pane text only

## Phase C: Controller-Driven Keepalive

Deliver:

- event-driven controller
- heartbeat records
- stale dispatch detection
- review-artifact wakeups
- interaction-gate escalation routing
- grant-consumption and expiry handling for approved gate resolutions
- bounded retry and archive policies

Exit criteria:

- no stop-hook recursion required for ordinary keepalive
- blocked gates can escalate to the correct higher authority without manual
  tmux babysitting

## Phase D: Recursive Child Bundle Spawn

Deliver:

- spawn_request flow
- child bundle provisioning
- parent-to-child supervision relationships
- bundle tree and observe tree views

Exit criteria:

- a meta dispatcher can keep supervising an existing loop while opening a new
  child supervised loop

## Phase E: Claude Code Adapter

Deliver:

- harness-specific adapter behavior for Claude Code
- explicit mapping of transport delivery events
- structured review artifact production where possible
- native gate-resolution actions that can consume scoped approval grants

Exit criteria:

- Codex supervising Claude Code works under braid-v2
- Claude Code supervising Claude Code also works
- native prompt blocks can be escalated and resolved through runtime state
  rather than manual pane handling

## Phase F: Soak Findings and Repair Bundles

Deliver:

- finding rules
- repair_action rules
- observe_only / propose_repair / bounded_auto_repair modes

Exit criteria:

- the system can monitor a live config over time and open bounded repair loops
  in situ

## Phase G: Additional Harness Adapters

Candidates:

- Codex CLI
- Gemini CLI
- MCP-backed agents

Exit criteria:

- the same bundle/thread model works across multiple harness types

## Parallel Lane O: Observability and Run Forensics

Purpose:

- make bundle history exportable without scraping tmux panes
- pair worker, supervisor, dispatcher, and child-bundle conversations
- retain snapshots at review, gate, timeout, repair, and archive boundaries
- produce archive bundles suitable for evaluator tooling and offline diagnosis

Reference:

- [OBSERVABILITY.md](OBSERVABILITY.md)

### O1: Trajectory Ledger and Retained Snapshots

Deliver:

- append-only trajectory events
- immutable snapshot artifacts
- observer-loop skeleton and seat observation policy
- event writes from controller and adapters for dispatch, review, gate,
  timeout, repair, and escalation boundaries

Scheduling:

- start after Phase C foundations are stable
- do not block Phase A or Phase B

### O2: Conversation Pairing

Deliver:

- conversation links for worker, supervisor, dispatcher, and child bundles
- harness transcript registration through adapters
- parent-child conversation linkage for spawned bundles
- automatic gate-classification coverage for worker and supervisor seats

Scheduling:

- run alongside Phase D and Phase E
- do not block the first narrow single-bundle supervision slice

### O3: Export, Diagnose, Archive

Deliver:

- trace tree and timeline queries
- conversation export
- bundle archive manifests
- diagnostic summaries for supervisor and evaluator use

Scheduling:

- complete before calling observer-led soak ready
- complete before external sharing

## Migration Rule

Do not delete or replace the current bridge until:

- adopt mode works
- controller-driven keepalive works
- recursive child bundle spawn works
- observability lane O2 is in place for live bundle history retention
- one live soak period completes without relying on file-backed queue truth
