# braid-v2 Workspace

This folder is an isolated design-and-build workspace for the next version of
`braid`.

It does not replace the current live bridge. It is the clean-room target for
the system that should eventually supersede the current file-backed
tmux-centered containment loop.

## Purpose

`braid-v2` is the execution-supervision kernel for recursive agentic work.

It should be able to:

- adopt an already-running coding loop into managed runtime state
- spawn a fresh supervised loop around any supported coding harness
- let one supervising seat spawn another supervised bundle beneath it
- keep multiple related loops alive under one central dispatcher
- run long soak periods that observe, diagnose, and open bounded repair loops
  without turning observers into hidden planners

## Authority Split

`braid-v2` is not the repo policy engine.

- `braid-v2` owns runtime supervision truth:
  - sessions
  - seats
  - supervision relationships
  - dispatch delivery state
  - health
  - findings
  - repair actions
- the policy engine owns repo law:
  - prompt packs
  - scope manifests
  - leases
  - branch and write policy
  - evaluator and reviewer rules

`braid-v2` should call the policy engine. It should not clone it.

## Shared Policy Authority

The intended policy authority for `braid-v2` is the same ClauDEX runtime
policy engine already being built in this repo, not a second v2-specific
policy stack.

That means the future steady-state split is:

- [policy_engine.py](../../runtime/core/policy_engine.py)
  evaluates repo-law decisions
- [authority_registry.py](../../runtime/core/authority_registry.py)
  declares capability and authority ownership
- [prompt_pack.py](../../runtime/core/prompt_pack.py)
  and [prompt_pack_resolver.py](../../runtime/core/prompt_pack_resolver.py)
  compile runtime-owned guidance for seats and sessions
- `braid-v2` consumes those decisions and projections while owning runtime
  topology, dispatch, gates, findings, and repair actions

The design goal is one shared policy engine across Claude Code, Codex, Gemini,
and any later harness that `braid-v2` supervises.

## Why This Exists

The current bridge is useful as containment, but it has the wrong authority
shape:

- file-backed run state is the canonical ledger
- stop-hook recursion is doing too much of the keepalive work
- tmux pane state is carrying operational meaning it should not own
- health is partly inferred from relay behavior instead of being a first-class
  runtime model

`braid-v2` fixes that by making supervision explicit and agent-agnostic.

## Recursive Model

The important change is that supervision can go both directions:

- a central dispatch seat can adopt a running worker and attach a supervisor
- that supervisor can request a new child loop
- the child loop can have its own worker seat, supervisor seat, and observer
- the parent dispatcher can monitor both the original loop and the child loop
  at the same time

That gives a recursive tree of monitored work instead of one blind relay.

## Folder Contents

- [ARCHITECTURE.md](ARCHITECTURE.md)
  Core model, authority boundaries, recursion model, keepalive strategy.
- [SCHEMA.sql](SCHEMA.sql)
  Concrete SQLite schema for the supervision kernel.
- [COMMANDS.md](COMMANDS.md)
  Proposed CLI/API surface.
- [FLOWS.md](FLOWS.md)
  Canonical operational flows, including recursive spawn and soak repair.
- [OBSERVABILITY.md](OBSERVABILITY.md)
  Run-forensics model for trajectories, conversation pairing, retained
  snapshots, exports, and archive bundles.
- [ROADMAP.md](ROADMAP.md)
  Ordered build plan for implementing the kernel without disturbing the live
  setup.
- [EXTERNALIZATION_CHECKLIST.md](EXTERNALIZATION_CHECKLIST.md)
  Release/readiness gates before `braid-v2` is treated as a shareable package.

## Intended First Implementation Order

1. SQLite kernel and controller daemon
2. tmux adapter with adopt/spawn support
3. Claude Code harness adapter
4. Codex supervisor adapter
5. recursive bundle spawn
6. soak findings and bounded repair actions
7. Gemini or other harness adapters

## Current Implemented Slice

The current repo implementation is intentionally narrow:

- standalone Python CLI at [cli.py](cli.py)
- SQLite bootstrap from [SCHEMA.sql](SCHEMA.sql)
- runtime package in [braid2](braid2)
- tmux adapter with:
  - pane adopt
  - worker window spawn
  - supervisor pane spawn
  - text send
  - pane capture
- executable command path for:
  - `bundle create`
  - `bundle adopt`
  - `bundle spawn`
  - `bundle tree`
  - `dispatch issue`
  - `observe capture`
  - `controller sweep`

This is enough to create a supervised tmux bundle under runtime-owned SQLite
state without reusing the live bridge's file-backed queue truth.

## Isolation Path

The current overnight bridge wrapper is still singleton. It shares:

- `BRAID_ROOT/runs/active-run`
- repo-local `.claude/claudex/*`

That means `braid-v2` must not be started as a second live supervised thread
from this same repo checkout if the original ClauDEX cutover run is still
active.

Use the isolation helpers in this folder instead:

```bash
cd /path/to/claude-ctrl
SOURCE_BRAID_ROOT=/path/to/braid ./ClauDEX/braid-v2/prepare_isolated_workspace.sh
cd /tmp/claudex-braid-v2-workspace
./ClauDEX/braid-v2/start_isolated_overnight.sh --session overnight-braid-v2 --no-attach
```

That path copies the current repo tree and a separate braid runtime root into
independent workspace paths so the v2 soak can run without trampling the main
cutover bridge state.

## Non-Goals

- no further refinement of the current relay bridge in this workspace
- no new file-backed canonical state
- no embedding repo policy logic into `braid-v2`
- no assumption that tmux is the permanent transport
