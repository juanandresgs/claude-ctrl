# Architecture

## Live System

The hard fork runs on the patched `v2.0` kernel with a live SQLite-backed
typed runtime. The governance kernel has been rebuilt through INIT-001 and
INIT-002; the hook chain, runtime, and statusline are all active.

### Enforcement Surface

The live control plane is the hook chain registered in `settings.json`. Each
hook is a standalone shell script that reads JSON from stdin and emits a JSON
response to stdout. Hooks enforce policy; they delegate shared-state operations
to the `cc-policy` CLI via `hooks/lib/runtime-bridge.sh`. Hook denials include
a `blockingHook` field identifying the specific check that fired (TKT-017).

**PreToolUse Write|Edit** -- consolidated entrypoint `hooks/pre-write.sh`:

Policy checks are delegated to `hooks/lib/write-policy.sh`, which calls the
individual policy hooks in sequence. The first deny wins and is annotated with
`blockingHook`. Individual policy hooks that participate:

1. `hooks/branch-guard.sh` -- Denies source file writes on `main`/`master`.
   Exempts non-source files, MASTER_PLAN.md, and `.claude/` meta-infrastructure.
2. `hooks/write-guard.sh` -- WHO enforcement: only the `implementer` role may
   write source files. All other roles (orchestrator, planner, tester, guardian)
   are denied. Non-source files pass through. Role detection uses runtime
   agent markers via `context-lib.sh`.
3. `hooks/plan-guard.sh` -- Governance markdown authority: only the `planner`
   (or `Plan`) role may write MASTER_PLAN.md, CLAUDE.md, `agents/*.md`, or
   `docs/*.md`. Override: `CLAUDE_PLAN_MIGRATION=1` env var. `.claude/` exempt.
4. `hooks/doc-gate.sh` -- Documentation quality: source files must have a doc
   header; 50+ line files must have `@decision` annotation. Warns (does not
   block) on Edit to headerless files. Warns against new root-level markdown.
5. `hooks/plan-check.sh` -- Plan-first gate: denies source file Write (20+
   lines) when no MASTER_PLAN.md exists. Staleness check uses source churn
   percentage and a commit-count heuristic (`.plan-drift` flat-file scoring was
   removed in TKT-018; `plan-check.sh` no longer reads it). Uses `-e .git`
   instead of `-d .git` to correctly detect worktree environments (TKT-017).

**PreToolUse Bash** -- consolidated entrypoint `hooks/pre-bash.sh`:

Policy checks delegated to `hooks/lib/bash-policy.sh`, which calls
`hooks/guard.sh`. Denials annotated with `blockingHook`.

1. `hooks/guard.sh` -- Multi-check gate:
   - WHO: only `guardian` role may `git commit/merge/push`.
   - WHERE: cannot commit on `main`/`master` (MASTER_PLAN.md-only commits
     exempt).
   - SAFETY: denies `git reset --hard`, `git clean -f`, `git branch -D`, raw
     `--force` push, force push to main/master, worktree CWD hazards, `/tmp/`
     writes.
   - GATES: requires runtime `test_state` = pass (from `test_state` table via
     `rt_test_state_get`) and `evaluation_state` = `ready_for_guardian` with
     matching `head_sha` before commit or merge.

**SubagentStart** (fires on every agent spawn):

- `hooks/subagent-start.sh` -- Creates a runtime agent marker via
  `rt_marker_set`. Injects role-specific context. Does not deny.

**SubagentStop** (fires on every agent stop):

- `hooks/check-planner.sh` / `check-implementer.sh` / `check-tester.sh` /
  `check-guardian.sh` -- Agent-specific validation checks. Each deactivates the
  runtime agent marker via `rt_marker_deactivate` (TKT-016).
- `hooks/post-task.sh` -- Completion routing (DEC-WS6-001). Detects completing
  agent role, routes next role via completion records and `determine_next_role()`,
  emits suggestion via hookSpecificOutput. Wired into SubagentStop for all agent
  types by TKT-016.

**SessionStart** (fires on session start, /clear, /compact, resume):

- `hooks/session-init.sh` -- Injects git state, plan status, proof state.
  Clears stale session artifacts. Does not deny.

**UserPromptSubmit** (fires on every user prompt):

- `hooks/prompt-submit.sh` -- Records proof verification on "verified" reply.
  Injects contextual HUD. Auto-claims referenced issues. Does not deny.

### Typed Runtime (Live)

The typed runtime is the authoritative owner of shared workflow state:

- **Location:** `runtime/core/*.py` with `runtime/cli.py` as the CLI adapter.
- **CLI:** `cc-policy` (571 lines). Implements `init`, `proof`, `dispatch`,
  `marker`, `statusline`, `worktree`, and `event` command groups. 42ms median
  latency.
- **Schema:** 10 core tables (`proof_state`, `agent_markers`, `events`,
  `worktrees`, `dispatch_cycles`, `dispatch_queue` (non-authoritative),
  `test_state`, `evaluation_state`, `dispatch_leases`, `completion_records`)
  plus domain-specific tables
  for traces, todos, and tokens. SQLite in WAL mode.
- **Bridge:** `hooks/lib/runtime-bridge.sh` (129 lines) provides shell
  wrappers (`rt_proof_get`, `rt_proof_set`, `rt_marker_set`,
  `rt_marker_deactivate`, `rt_event_emit`, etc.) for all runtime domains.
- **Context:** `hooks/context-lib.sh` reads runtime-first. Flat-file fallback
  paths for `.proof-status-*`, `.subagent-tracker`, and `.statusline-cache`
  have been eliminated.

### Hook Policy Libraries (Live)

The individual policy files in `hooks/lib/` are live and sourced by the
consolidated entrypoints:

- `hooks/lib/write-policy.sh` (102 lines) -- Delegates Write|Edit policy checks.
- `hooks/lib/bash-policy.sh` (26 lines) -- Delegates Bash policy checks.
- `hooks/lib/plan-policy.sh` (97 lines) -- Plan governance enforcement.
- `hooks/lib/dispatch-helpers.sh` -- Dispatch queue helpers for `post-task.sh`.
- `hooks/lib/runtime-bridge.sh` (129 lines) -- Shell wrappers for `cc-policy`.

### Statusline (Live)

The statusline is a runtime-backed read model:

- `runtime/core/statusline.py` derives a statusline snapshot from the canonical
  state machine plus Claude-provided stdin metrics.
- `scripts/statusline.sh` renders from `cc-policy statusline snapshot`.
- No `.statusline-cache` flat file is read or written. All statusline data
  derives from runtime projections.

### Scripts (Live)

- `scripts/planctl.py` (557 lines) -- Plan discipline utility. Validates
  MASTER_PLAN.md section presence, structure, and integrity. Stamps `Last
  updated` timestamps. Used by plan-validate.sh feedback loop.

### Flat-File State (Remaining)

The following flat files are still written or read by the live hook chain. They
are candidates for future runtime migration but remain operational:

| File | Status | Written By | Read By |
|------|--------|-----------|---------|
| `.agent-findings` | Removed (WS4) | ~~check-planner.sh, check-implementer.sh, check-tester.sh, check-guardian.sh~~ | ~~prompt-submit.sh, compact-preserve.sh~~ | Replaced by `rt_event_emit "agent_finding"` / runtime event store |
| `.plan-drift` | Dead write | surface.sh | (no reader -- plan-check.sh removed its read in TKT-018) |
| `.audit-log` | Dead | (append_audit routes through runtime) | compact-preserve.sh (stale reader) |
| `.test-status` | Removed (WS-DOC-CLEAN) | ~~test-runner.sh~~ | ~~guard.sh, test-gate.sh, session-summary.sh, etc.~~ | Replaced by `test_state` SQLite table via `rt_test_state_get` |
| `.session-changes-*` | Active (session-scoped) | track.sh | surface.sh, session-summary.sh |

Eliminated flat files (no longer written or read):

- `.proof-status-*` -- replaced by `proof_state` table
- `.subagent-tracker` -- replaced by `agent_markers` table
- `.statusline-cache` -- replaced by runtime statusline snapshot
- `.test-status` -- replaced by `test_state` table via `rt_test_state_get` (WS-DOC-CLEAN)
- `.agent-findings` -- replaced by `events` table via `rt_event_emit "agent_finding"` (WS4)

### Sidecars (Shadow Mode)

Read-only sidecars exist in `sidecars/` (TKT-015). They observe traces, events,
and plan metadata but never sit on deny paths and never gate hook execution.
They remain in shadow mode until the kernel acceptance suite is green for two
consecutive passes.

## Achieved Architecture

The system now implements layers 1-4 of the target architecture:

1. Canonical prompts in `CLAUDE.md` and `agents/`
2. Thin hook entrypoints (`pre-write.sh`, `pre-bash.sh`) with shell policy libs
3. Typed runtime (`cc-policy` CLI + SQLite) for shared state
4. Runtime-backed read models (statusline snapshot)
5. Read-only sidecars (shadow mode, not yet promoted)

The remaining gap is plan discipline mechanical enforcement: permanent-section
immutability, append-only decision log, and initiative compression are prompt
conventions, not yet mechanically enforced by hooks.
