# braid-v2 Command Surface

The command surface below assumes a single `braid2` CLI. It can later back a
local CLI, MCP server, or HTTP control plane.

## Design Rules

- commands target runtime entities, not raw panes
- all commands are idempotent where practical
- commands may return references to policy-engine work, but do not embed repo
  policy logic themselves
- spawn and adopt are equally first-class
- the policy surface is shared with the ClauDEX runtime policy engine; `braid2`
  requests decisions and prompt packs from that authority rather than
  re-implementing repo law locally

## Concurrent Run Note

Until `braid-v2` replaces the singleton bridge wrapper, concurrent live soaks
must run from an isolated workspace with an isolated braid runtime root.

Preparation path:

```bash
cd /Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork
./ClauDEX/braid-v2/prepare_isolated_workspace.sh
cd /tmp/claudex-braid-v2-workspace
./ClauDEX/braid-v2/start_isolated_overnight.sh --session overnight-braid-v2 --no-attach
```

## Top-Level Namespaces

- `bundle`
- `session`
- `seat`
- `thread`
- `dispatch`
- `review`
- `gate`
- `finding`
- `repair`
- `observe`
- `controller`

## `bundle`

### `bundle create`

Create an empty bundle before provisioning seats.

```bash
braid2 bundle create \
  --bundle-type coding_loop \
  --goal-ref goal-123 \
  --work-item-ref wi-045
```

### `bundle adopt`

Adopt an already-running harness instance into runtime state.

```bash
braid2 bundle adopt \
  --bundle-id bundle-root \
  --harness claude_code \
  --transport tmux \
  --endpoint overnight-prod5:1.2 \
  --role worker \
  --cwd /Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork
```

### `bundle spawn`

Spawn a new child supervised loop under a parent seat.

```bash
braid2 bundle spawn \
  --parent-bundle bundle-root \
  --requested-by seat-meta-dispatch \
  --worker-harness claude_code \
  --supervisor-harness codex \
  --transport tmux \
  --goal-ref soak-fix-001 \
  --work-item-ref wi-soak-001
```

### `bundle tree`

Show recursive topology.

```bash
braid2 bundle tree --bundle-id bundle-root
```

## `session`

### `session spawn`

Provision a new harness process through an adapter.

```bash
braid2 session spawn \
  --bundle-id bundle-child \
  --harness claude_code \
  --transport tmux \
  --launch-profile claudex-cutover
```

### `session attach`

Attach an additional endpoint or metadata surface to a session.

```bash
braid2 session attach \
  --session sess-child-worker \
  --endpoint-kind transcript \
  --endpoint-ref /path/to/transcript.jsonl
```

### `session stop`

Terminate a session cleanly.

```bash
braid2 session stop --session sess-child-worker
```

## `seat`

### `seat create`

```bash
braid2 seat create \
  --bundle-id bundle-child \
  --session sess-child-worker \
  --role worker \
  --label child-worker
```

### `seat spawn-supervisor`

Create a local supervisor around an existing worker seat.

```bash
braid2 seat spawn-supervisor \
  --target-seat seat-child-worker \
  --supervisor-harness codex \
  --transport tmux
```

### `seat resume`

Wake a paused supervisor or observer seat.

```bash
braid2 seat resume --seat seat-child-supervisor
```

## `thread`

### `thread create`

Create an explicit supervision relationship.

```bash
braid2 thread create \
  --supervisor-seat seat-meta-dispatch \
  --target-bundle bundle-child \
  --thread-type supervise
```

### `thread spawn-analysis`

Open a bounded analysis thread attached to a target seat or bundle.

```bash
braid2 thread spawn-analysis \
  --requested-by seat-meta-dispatch \
  --target-seat seat-child-supervisor \
  --harness claude_code \
  --transport tmux \
  --mode observe
```

This is the command that enables the recursive pattern without requiring a new
bridge design each time.

### `thread pause`

```bash
braid2 thread pause --thread thread-child-supervise
```

## `dispatch`

### `dispatch issue`

Issue a runtime-tracked instruction to one seat.

```bash
braid2 dispatch issue \
  --seat seat-child-worker \
  --instruction-file /tmp/instruction.txt \
  --timeout-seconds 900
```

### `dispatch claim`

Record transport-level delivery claim.

```bash
braid2 dispatch claim --attempt attempt-123
```

### `dispatch timeout`

```bash
braid2 dispatch timeout --attempt attempt-123
```

### `dispatch fail`

```bash
braid2 dispatch fail --attempt attempt-123 --reason transport_start_failed
```

## `review`

### `review submit`

Write a structured review artifact that should wake a supervisor or dispatcher.

```bash
braid2 review submit \
  --bundle-id bundle-child \
  --producing-seat seat-child-worker \
  --artifact-type stop_review \
  --payload-ref /path/to/review.json
```

### `review consume`

```bash
braid2 review consume \
  --artifact artifact-123 \
  --seat seat-child-supervisor
```

## `gate`

### `gate open`

Adapter records a harness-native blocking prompt.

```bash
braid2 gate open \
  --seat seat-child-worker \
  --attempt attempt-123 \
  --gate-type edit_approval \
  --prompt-excerpt "Do you want to make this edit to CLAUDE.md?"
```

### `gate resolve`

Resolve a gate explicitly.

```bash
braid2 gate resolve \
  --gate gate-123 \
  --resolved-by seat-child-supervisor \
  --resolution allow
```

### `gate list`

```bash
braid2 gate list --bundle-id bundle-root
```

## `finding`

### `finding open`

```bash
braid2 finding open \
  --bundle-id bundle-child \
  --severity warning \
  --finding-type loop_waste \
  --summary "worker returned to prompt while supervisor kept waking"
```

### `finding close`

```bash
braid2 finding close --finding finding-123 --status fixed
```

## `repair`

### `repair run`

Apply a bounded runtime action.

```bash
braid2 repair run \
  --finding finding-123 \
  --action-type spawn_repair_bundle
```

### `repair spawn-bundle`

Open a child repair loop instead of hiding repair behavior in shell.

```bash
braid2 repair spawn-bundle \
  --finding finding-123 \
  --worker-harness claude_code \
  --supervisor-harness codex \
  --transport tmux
```

## `observe`

### `observe capture`

Adapter or observer emits a read-only observation.

```bash
braid2 observe capture \
  --seat seat-child-worker \
  --source-type adapter \
  --state working \
  --details-json /tmp/details.json
```

### `observe tree`

```bash
braid2 observe tree --bundle-id bundle-root
```

## `controller`

### `controller run`

Run the event-driven keepalive controller.

```bash
braid2 controller run --db /path/to/braid-v2.db
```

### `controller sweep`

One bounded maintenance pass.

```bash
braid2 controller sweep --bundle-id bundle-root
```

## Canonical Example: Central Dispatch Spawning a Child Loop

1. Adopt the current Claude worker:

```bash
braid2 bundle adopt \
  --bundle-id bundle-root \
  --harness claude_code \
  --transport tmux \
  --endpoint overnight-prod5:1.2 \
  --role worker
```

2. Attach a Codex supervisor:

```bash
braid2 seat spawn-supervisor \
  --target-seat seat-root-worker \
  --supervisor-harness codex \
  --transport tmux
```

3. Let a meta dispatcher spawn a child supervised bundle:

```bash
braid2 bundle spawn \
  --parent-bundle bundle-root \
  --requested-by seat-meta-dispatch \
  --worker-harness claude_code \
  --supervisor-harness claude_code \
  --transport tmux \
  --goal-ref analyze-config-drift \
  --work-item-ref wi-meta-002
```

4. Monitor both bundles:

```bash
braid2 bundle tree --bundle-id bundle-root
braid2 observe tree --bundle-id bundle-root
```

5. If the child worker hits a native edit approval prompt, record and route it:

```bash
braid2 gate open \
  --seat seat-child-worker \
  --attempt attempt-child-01 \
  --gate-type edit_approval \
  --prompt-excerpt "Do you want to make this edit?"
```

The controller should then route that gate to the child supervisor first, not
straight to the human operator.
