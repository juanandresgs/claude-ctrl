# ClauDEX Overnight Supervision Runbook

This is the fast path for running a fresh Claude Code worker under Codex
supervision tonight without inheriting the current global hardFork hook stack.

For the latest clean-start state and restart slice, also read:

- [CURRENT_STATE.md](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/ClauDEX/CURRENT_STATE.md)

## What This Setup Does

- uses the tested braid bridge run-state and relay mechanism
- does **not** reuse the current global Claude hook config
- loads a repo-local cutover profile from
  [bridge/claude-settings.json](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/ClauDEX/bridge/claude-settings.json)
- keeps only a minimal safety surface:
  - bridge submit hook
  - bridge stop hook
  - `pre-bash.sh` for bash-side git safety
- keeps the old workflow-routing stack out of the critical path

This is the migration profile, not the final ClauDEX runtime.

## Clean Work Rule

Treat the bridge session as disposable execution state. Treat the ClauDEX files
in `ClauDEX/`, `.codex/`, `runtime/core/`, and `tests/runtime/` as the durable
work product.

## Files Added For This

- [bridge/claude-settings.json](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/ClauDEX/bridge/claude-settings.json)
- [claudex-submit-inject.sh](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/hooks/claudex-submit-inject.sh)
- [claudex-stop-relay.sh](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/hooks/claudex-stop-relay.sh)
- [claudex-bridge-up.sh](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/scripts/claudex-bridge-up.sh)
- [claudex-codex-launch.sh](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/scripts/claudex-codex-launch.sh)
- [claudex-claude-launch.sh](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/scripts/claudex-claude-launch.sh)
- [claudex-bridge-status.sh](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/scripts/claudex-bridge-status.sh)
- [claudex-bridge-down.sh](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/scripts/claudex-bridge-down.sh)
- [claudex-watchdog.sh](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/scripts/claudex-watchdog.sh)
- [claudex-progress-monitor.sh](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/scripts/claudex-progress-monitor.sh)
- [.codex/config.toml](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/.codex/config.toml)
- [.codex/hooks.json](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/.codex/hooks.json)
- [.codex/hooks/stop_supervisor.py](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/.codex/hooks/stop_supervisor.py)
- [.codex/prompts/claudex_handoff.txt](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/.codex/prompts/claudex_handoff.txt)
- [.codex/prompts/claudex_supervisor.txt](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/.codex/prompts/claudex_supervisor.txt)
- [claudex-bridge-mcp-server.mjs](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/ClauDEX/bridge/claudex-bridge-mcp-server.mjs)

## Express Setup

1. Open or create a tmux session and decide which pane is the Claude pane.

Example target:

```bash
tmux new -s overnight
```

Then split panes until you have a Claude pane. Its target will look like
`overnight:0.1`.

2. From the repo root, bootstrap the bridge run:

```bash
./scripts/claudex-bridge-up.sh --tmux-target overnight:0.1
```

3. In the Claude pane, start a fresh Claude session with the cutover profile:

```bash
cd /Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork
./scripts/claudex-claude-launch.sh
```

4. In the Codex pane, start the Codex supervisor session:

```bash
cd /Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork
./scripts/claudex-codex-launch.sh
```

This launches Codex with the project-specific handoff prompt in
`.codex/prompts/claudex_handoff.txt`. After that first turn, the repo-local
Codex `Stop` hook keeps the same session alive by re-entering the tighter
supervisor loop from `.codex/prompts/claudex_supervisor.txt`.

5. Check bridge status from any shell at any time:

```bash
./scripts/claudex-bridge-status.sh
```

6. When stopping for the night or cleaning up tomorrow:

```bash
./scripts/claudex-bridge-down.sh --archive
```

## Progress Monitoring

Fresh overnight launches now also start the progress monitor automatically.

- it samples the live bridge run and the Codex operator pane every 30 minutes
- it records whether the cutover loop appears to be advancing
- it flags stale or mismatched handoff state instead of making decisions

Manual launch for an already-running session:

```bash
cd /Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork
tmux new-window -d -t overnight -n claudex-monitor -c /Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork \
  'cd /Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork && exec bash ./scripts/claudex-progress-monitor.sh --codex-target overnight:1.1'
```

## What To Expect

- There will be no active run until step 2.
- Claude will not be bridge-loaded until step 3 starts the fresh session.
- The bridge claims the Claude session on the first relay turn.
- The authoritative supervision loop is:
  - Codex `Stop` hook continues the same session instead of letting it die
  - Codex: `get_status()`
  - Codex: review the handoff if bridge state is `waiting_for_codex`
  - Codex: `wait_for_codex_review()` to return to a blocking state when there
    is nothing immediate to review
  - Codex: `send_instruction()` for the next bounded Claude slice
- `claudex-bridge-up.sh` also starts the watchdog. Its job is only transport and handoff:
  - restart `auto-submit` if the pid is stale
  - restart the broker if the socket disappears
  - classify `queued + no inflight + repeated auto-submit timeout` as
    `dispatch_stalled`, not healthy
  - invoke the one authoritative dispatch repair path
    `./scripts/claudex-dispatch-recover.sh` when the current run is marked
    `dispatch_stalled`
  - restart the supervisor path through `scripts/claudex-supervisor-restart.sh`
    when the progress monitor reports a degraded current-run snapshot or the
    latest snapshot ages past its freshness window
  - write a `ready-for-codex` flag and a `pending-review.json` artifact when
    Claude finishes and returns to `waiting_for_codex`
- `claudex-progress-monitor.sh` samples the run every 30 minutes and records:
  - active run id
  - bridge state and updated_at
  - latest response file
  - pending-review run/instruction ids
  - a hash/excerpt of the Codex operator pane
  - whether the loop appears to be advancing
  - any alert conditions such as `pending_review_run_mismatch`
- The current global hardFork `SubagentStop` orchestration should not be in
  play for this session, because the launch command excludes user settings and
  loads only the explicit cutover settings file.

## Operator Notes

- This setup intentionally does **not** use `braid up`, because the installed
  bridge status hint is stale in this environment.
- The bridge runtime still lives in `/Users/turla/Code/braid`; these repo-local
  wrappers keep the overnight control surface codified here.
- Tonight's objective is a stable supervised worker session. The deeper
  cross-project bridge cleanup still belongs in the braid repo.
- The watchdog is not a planner. It does not invent next tasks or accept/reject
  slices; it only keeps the bridge alive and leaves the run in a clean
  `waiting_for_codex` handoff state.
- The progress monitor is also not a planner. It is only an observer:
  - healthy snapshots are written to `$CLAUDEX_STATE_DIR/progress-monitor.latest.json`
  - alerts are written to `$CLAUDEX_STATE_DIR/progress-monitor.alert.json`
  - dispatch stalls are written to `$CLAUDEX_STATE_DIR/dispatch-stall.state.json`
  - preserved recovery bundles are written to `$CLAUDEX_STATE_DIR/recovery/`
  - both are surfaced by `./scripts/claudex-bridge-status.sh`
  - the watchdog may consume those artifacts to trigger the one authoritative
    supervisor or dispatch repair path, but the monitor itself never restarts
    panes
- The real self-continuation now lives on the Codex side:
  - repo-local `.codex/config.toml` swaps the bridge server to the local
    wrapper with `wait_for_codex_review()`
  - repo-local `.codex/hooks.json` installs the Codex `Stop` hook
  - `.codex/hooks/stop_supervisor.py` keeps the same Codex session alive as
    long as the bridge run is active
  - `.codex/prompts/claudex_handoff.txt` is the initial project-specific
    kickoff prompt
  - `.codex/prompts/claudex_supervisor.txt` is the steady-state loop that the
    Stop hook reuses indefinitely
- If the Codex driver turn is interrupted, the recovery artifact is
  `$CLAUDEX_STATE_DIR/pending-review.json`. It records the latest run id,
  instruction id, response path, transcript path, completion time, and a short
  response preview so the next Codex turn can resume deterministically instead
  of guessing from logs.
- If the run enters `dispatch_stalled`, the supervisor should not keep
  re-arming forever. The repo-local Codex `Stop` hook now exits normally for a
  stalled active run so the watchdog can own recovery without burning more
  Codex turns.

## Carrier Path Verification (completed 2026-04-09)

The carrier + producer + wiring path is implemented, mechanically proven, and
live-verified. Production reachability is confirmed.

**Evidence in `runtime/dispatch-debug.jsonl`:**
- Entry 39 of 39: `tool_name=Agent`, `tool_input.prompt` starts with
  `CLAUDEX_CONTRACT_BLOCK:{"workflow_id":"claudex-cutover","stage_id":"planner",...}`
- Before this session: 38 Agent entries, 0 with the contract prefix
- After: 39 entries, 1 confirmed match

Phase 2b (agent-agnostic supervision fabric) is now the active cutover slice.
See `ClauDEX/CURRENT_STATE.md` for the current Phase 2b progress.

## Safety Model Tonight

- source edits are allowed
- subagent spawning is disallowed in the cutover profile
- direct git commit/push/merge/rebase/reset are denied in the cutover profile
- `pre-bash.sh` remains active for bash-side policy enforcement

This is deliberate: the overnight worker should be able to implement, but not
land or mutate the repo state irreversibly.
