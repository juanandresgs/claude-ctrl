# Dual Lane Stability Handoff

Date: 2026-04-14
Repo: `/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork`

## Current Truth

### Lane 1: `85`

- Braid root:
  `/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/.b2r-policy-v2-85`
- Lane state:
  `/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/.claude/claudex/b2r-policy-v2-85`
- Current truth: no active run pointer. Treat this lane as stopped, not healthy.
- Latest accepted artifact:
  `/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/.b2r-policy-v2-85/runs/1776199356-73451-e822adca/responses/1776201255364-0001-4f0gia.json`
- Latest accepted conclusion:
  - branch `feat/claudex-cutover`
  - HEAD `c7a3109`
  - 263 staged paths
  - no unstaged paths
  - no untracked paths
  - no staged `.claude/`, `.b2r`, `*.jsonl`, or `*.trace` artifacts
  - final acceptance `12/12`
  - phase 8 exit criteria `2/2`
  - remaining blocker is the outer Claude harness approval gate on
    `git commit` / `git push`
- Mission if relaunched:
  checkpoint only. Do not reopen architecture work. Only inspect git state,
  verify the already-staged cutover bundle, retry non-destructive commit/push,
  and stop again if the outer harness approval gate blocks.

### Lane 2: `overnight-braid-v2-stable`

- Braid root:
  `/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/.b2r-v2-stable`
- Lane state:
  `/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/.worktrees/claudex-braid-v2-live-checkpoint/.claude/claudex/b2r-v2-stable`
- Worktree root:
  `/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/.worktrees/claudex-braid-v2-live-checkpoint`
- Current truth:
  session exists, worker finished a slice, supervisor is currently stuck on a
  `queued` / `user_driving` / `relay_paused` boundary with queued instruction
  `1776202431547-0002-7lcyci`
- Mission:
  keep the `braid-v2` implementation lane moving on bounded slices only

## Important Fix Already Landed

The missing-response / stale-`inflight` class is already patched in both
watchdogs:

- `/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/scripts/claudex-watchdog.sh`
- `/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/.worktrees/claudex-braid-v2-live-checkpoint/scripts/claudex-watchdog.sh`

That patch recovers `responses/<instruction>.json` from the Claude transcript
when Claude clearly finished the turn but the bridge missed the response
artifact write. Do not re-debug that failure mode unless the patch is proven
insufficient.

## Replacement Supervisor Instructions

You are taking over two ClauDEX lanes in:

`/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork`

You must inspect live truth at every conversation start. Do not trust cached
summaries.

Operating rules:

- At every conversation start inspect:
  - tmux sessions
  - both pane tails
  - lane-local `pending-review.json`
  - active-run pointer
  - run `status.json`
- Never treat `bridge active` as healthy by itself.
- Healthy means:
  - session exists
  - worker pane exists
  - helper stack is single-owned
  - queue / inflight / review artifacts are coherent
  - there is a fresh state transition or real claimed work
- Unhealthy means:
  - session missing
  - worker at prompt while supervisor loops
  - `queued` + `user_driving` + `relay_paused` with no movement
  - repeated helper starts or repeated sentinel sends
  - missing response artifact after Claude has clearly finished a turn
- Do not manually `nohup` extra helpers. Use the repo scripts only.
- One helper stack per lane. If ownership drifts, fix ownership; do not stack
  more auto-submit / watchdog processes.
- Use lane-local env vars. Never let `85` and `v2` share state roots.
- For `85`, if the only blocker is the outer Claude harness approval gate on
  commit/push, do not keep the lane alive just to spin. Report `READY PENDING
  CHECKPOINT` and stop cleanly with `CLAUDEX_SUPERVISOR_STOP`.
- For `v2`, do not stop while queued / inflight is stale or the relay is paused
  incorrectly. Recover it.

Preferred recovery order:

1. Inspect truth.
2. If the session exists and the run exists, use `watchdog --once` and
   `supervisor-restart` before any destructive reset.
3. If no active run exists for `85`, start a fresh checkpoint-only session.
4. If `v2` remains `queued` / `user_driving` after restart and watchdog tick,
   escalate to a clean lane-local bridge reset. Do not improvise extra helpers.

Do not:

- widen `85` into new architecture work
- run repo-global defaults when lane-local roots exist
- spawn overlapping helper stacks
- call a lane healthy unless it is making bounded forward progress

## Commands

### Recover `v2` in place

```bash
cd /Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork

BRAID_ROOT="$PWD/.b2r-v2-stable" \
CLAUDEX_STATE_DIR="$PWD/.worktrees/claudex-braid-v2-live-checkpoint/.claude/claudex/b2r-v2-stable" \
./scripts/claudex-watchdog.sh --once --tmux-target overnight-braid-v2-stable:1.2

BRAID_ROOT="$PWD/.b2r-v2-stable" \
CLAUDEX_STATE_DIR="$PWD/.worktrees/claudex-braid-v2-live-checkpoint/.claude/claudex/b2r-v2-stable" \
./scripts/claudex-supervisor-restart.sh --codex-target overnight-braid-v2-stable:1.1
```

### Start a fresh `85` checkpoint-only session

```bash
cd /Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork

BRAID_ROOT="$PWD/.b2r-policy-v2-85" \
CLAUDEX_STATE_DIR="$PWD/.claude/claudex/b2r-policy-v2-85" \
./scripts/claudex-overnight-start.sh --session 85
```

## Notes

- `85` should not be "resumed" from the dead run. Start fresh.
- `v2` should be resumed in place first.
- The real remaining fragility is helper ownership / queued relay recovery, not
  the old missing-response artifact class.
