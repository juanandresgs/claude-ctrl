# Architecture: Claude Code Configuration System

**@decision DEC-ARCH-001**
**@title Architectural overview document for system structure and data flow**
**@status accepted**
**@rationale** Provides the definitive technical reference for understanding system
components, hook execution model, and key design decisions. Complements README.md
(user guide) and HOOKS.md (protocol reference) by explaining HOW the pieces fit
together and WHY they're structured this way.

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Hook Engine — Lifecycle and Protocol](#2-hook-engine--lifecycle-and-protocol)
3. [Gate Hooks — Pre-Execution Enforcement](#3-gate-hooks--pre-execution-enforcement)
4. [Feedback Hooks — Post-Execution Quality](#4-feedback-hooks--post-execution-quality)
5. [Session Lifecycle Hooks](#5-session-lifecycle-hooks)
6. [Agent System](#6-agent-system)
7. [Proof Pipeline — Verification Chain](#7-proof-pipeline--verification-chain)
8. [Observatory System — Self-Improvement Flywheel](#8-observatory-system--self-improvement-flywheel)
9. [Trace Protocol — Persistent Agent Evidence](#9-trace-protocol--persistent-agent-evidence)
10. [Checkpoint and Recovery](#10-checkpoint-and-recovery)
11. [Status Bar and Diagnostics](#11-status-bar-and-diagnostics)
12. [Shared Libraries](#12-shared-libraries)
13. [State File Registry](#13-state-file-registry)
14. [Data Flow: Feature Request End-to-End](#14-data-flow-feature-request-end-to-end)
15. [Extension Points](#15-extension-points)
16. [Anti-Patterns](#16-anti-patterns)
17. [Decision Log](#17-decision-log)
18. [Glossary](#18-glossary)

---

## 1. System Overview

The `~/.claude` repository is a Claude Code configuration system that enforces
development practices across every project Claude touches. It operates at the
operating-system level — intercepting every tool call, every agent spawn, every
session start — via Claude Code's hook system.

The system has four layers:

1. **Instruction layer** — `CLAUDE.md` and agent prompts tell Claude what to do.
2. **Hook layer** — Hook scripts and shared libraries enforce it mechanically, regardless of instructions.
3. **Agent layer** — 4 specialized agents (Planner, Implementer, Tester, Guardian)
   divide complex work into deterministic phases.
4. **State layer** — ~20 state files persist information between hooks, agents, and sessions.

No single layer is sufficient alone. Instructions drift under context pressure.
Hooks enforce deterministically but can't plan. Agents plan but need enforcement.
State files bridge the gap — hooks communicate with each other through files, not memory.

### Directory Map

```
~/.claude/
├── hooks/                    # Hook scripts and shared libraries
│   ├── guard.sh              # PreToolUse:Bash — 11-check safety gate
│   ├── doc-freshness.sh      # PreToolUse:Bash — documentation freshness enforcement at merge
│   ├── auto-review.sh        # PreToolUse:Bash — three-tier command classification
│   ├── branch-guard.sh       # PreToolUse:Write|Edit — main branch protection
│   ├── doc-gate.sh           # PreToolUse:Write|Edit — documentation enforcement
│   ├── test-gate.sh          # PreToolUse:Write|Edit — escalating test failure gate
│   ├── mock-gate.sh          # PreToolUse:Write|Edit — mock detection gate
│   ├── plan-check.sh         # PreToolUse:Write|Edit — MASTER_PLAN.md enforcement
│   ├── checkpoint.sh         # PreToolUse:Write|Edit — git ref checkpoints
│   ├── task-track.sh         # PreToolUse:Task — agent dispatch gates
│   ├── track.sh              # PostToolUse:Write|Edit — session change tracking
│   ├── lint.sh               # PostToolUse:Write|Edit — auto-linting with feedback loop
│   ├── code-review.sh        # PostToolUse:Write|Edit — complexity advisory
│   ├── plan-validate.sh      # PostToolUse:Write|Edit — plan alignment check
│   ├── test-runner.sh        # PostToolUse:Write|Edit — async test execution
│   ├── webfetch-fallback.sh  # PostToolUse:WebFetch — suggest alternatives on failure
│   ├── playwright-cleanup.sh # PostToolUse:mcp__playwright__browser_snapshot
│   ├── skill-result.sh       # PostToolUse:Skill — skill completion tracking
│   ├── session-init.sh       # SessionStart — context injection
│   ├── prompt-submit.sh      # UserPromptSubmit — verification gate + dynamic context
│   ├── compact-preserve.sh   # PreCompact — context preservation before compaction
│   ├── subagent-start.sh     # SubagentStart — agent context injection + trace init
│   ├── check-planner.sh      # SubagentStop:planner|Plan — planner validation
│   ├── check-implementer.sh  # SubagentStop:implementer — implementation validation
│   ├── check-tester.sh       # SubagentStop:tester — tester auto-verify
│   ├── check-guardian.sh     # SubagentStop:guardian — guardian validation
│   ├── check-explore.sh      # SubagentStop:Explore|explore — Explore agent output validation
│   ├── check-general-purpose.sh # SubagentStop:general-purpose — general agent output validation
│   ├── surface.sh            # Stop — decision audit
│   ├── session-summary.sh    # Stop — session summary
│   ├── forward-motion.sh     # Stop — suggest next steps
│   ├── session-end.sh        # SessionEnd — cleanup
│   ├── notify.sh             # Notification — permission/idle alerts
│   ├── context-lib.sh        # Shared library — context builders, state I/O
│   ├── log.sh                # Shared library — JSON I/O, path utilities
│   └── source-lib.sh         # Shared library — bootstrapper for log.sh + context-lib.sh
├── agents/                   # 4 agent prompt definitions
│   ├── planner.md            # Planner agent — MASTER_PLAN.md creation
│   ├── implementer.md        # Implementer agent — test-first development
│   ├── tester.md             # Tester agent — e2e verification
│   └── guardian.md           # Guardian agent — git operations
├── skills/                   # 7 skill directories
│   ├── deep-research/        # Multi-provider research synthesis
│   ├── decide/               # Interactive decision configurator
│   ├── consume-content/      # URL → structured digest
│   ├── context-preservation/ # Pre-compaction context capture (/compact)
│   ├── diagnose/             # System health diagnostics
│   ├── rewind/               # Checkpoint recovery (/rewind)
│   └── prd/                  # PRD generation
├── commands/                 # Slash commands (lightweight, no context fork)
│   ├── backlog.md            # /backlog — GitHub Issues integration
│   └── compact.md            # /compact — context preservation
├── scripts/                  # Utility scripts
│   ├── statusline.sh         # Status bar renderer
│   ├── worktree-roster.sh    # Worktree lifecycle tracking
│   ├── update-check.sh       # Git-based auto-update
│   └── batch-fetch.py        # Cascade-proof multi-URL fetcher
├── traces/                   # Agent trace store
│   ├── index.jsonl           # Global trace index (one entry per trace)
│   ├── .active-<type>-<id>   # Active agent markers
│   └── <trace_id>/           # Per-agent trace directory
│       ├── manifest.json     # Trace metadata (agent type, project, outcome)
│       ├── summary.md        # Agent's own summary (≤1500 tokens)
│       └── artifacts/        # Evidence files (test-output.txt, diff.patch, etc.)
├── tests/                    # Hook validation suite
│   ├── run-hooks.sh          # Main test runner
│   ├── fixtures/             # Input/expected-output fixture pairs
│   └── test-*.sh             # 30+ specialized test scripts
└── settings.json             # Hook registry — 10 event types
```

### Component Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                        User describes feature                        │
└──────────────────────────────┬──────────────────────────────────────┘
                               ▼
                 ┌──────────────────────────────┐
                 │   CLAUDE.md (instructions)   │
                 │   - Cornerstone Belief       │
                 │   - Sacred Practices         │
                 │   - Dispatch Rules           │
                 └──────────────┬───────────────┘
                                ▼
        ┌──────────────────────────────────────────────┐
        │         Orchestrator (main context)          │
        │   Reads → Analyzes → Dispatches to agents   │
        └───┬────────────┬────────────┬────────────────┘
            │            │            │
            ▼            ▼            ▼
    ┌───────────┐  ┌────────────┐  ┌──────────┐  ┌────────┐
    │  Planner  │  │Implementer │  │  Tester  │  │Guardian│
    │   opus    │  │   sonnet   │  │  sonnet  │  │  opus  │
    │ Phase 1-2 │  │  Phase 3-4 │  │  Phase 5 │  │Commits │
    └─────┬─────┘  └─────┬──────┘  └────┬─────┘  └────┬───┘
          │              │               │              │
          ▼              ▼               ▼              ▼
    MASTER_PLAN.md  .worktrees/    .proof-status   git commit
    GitHub Issues   feature-name   = verified      git merge

┌─────────────────────────────────────────────────────────────────────┐
│                     Hook System (enforcement layer)                  │
├─────────────────────────────────────────────┬───────────────────────┤
│ PreToolUse (9 hooks)                        │ PostToolUse (7 hooks) │
│                                             │                       │
│ Bash: guard.sh, auto-review.sh             │ Write|Edit:           │
│ Write|Edit: test-gate.sh, mock-gate.sh,    │   lint.sh             │
│   branch-guard.sh, doc-gate.sh,            │   track.sh            │
│   plan-check.sh, checkpoint.sh             │   code-review.sh      │
│ Task: task-track.sh                        │   plan-validate.sh    │
│                                             │   test-runner.sh      │
│                                             │ WebFetch:             │
│                                             │   webfetch-fallback.sh│
│                                             │ Skill: skill-result.sh│
├─────────────────────────────────────────────┴───────────────────────┤
│ SessionStart: session-init.sh (startup|resume|clear|compact)        │
│ UserPromptSubmit: prompt-submit.sh                                  │
│ PreCompact: compact-preserve.sh                                     │
│ SubagentStart: subagent-start.sh                                    │
│ SubagentStop: check-planner.sh, check-implementer.sh,              │
│              check-tester.sh, check-guardian.sh,                    │
│              check-explore.sh, check-general-purpose.sh             │
│ Stop: surface.sh, session-summary.sh, forward-motion.sh            │
│ SessionEnd: session-end.sh                                          │
│ Notification: notify.sh                                             │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 2. Hook Engine — Lifecycle and Protocol

**What it does:** Intercepts every Claude Code action at 10 lifecycle events.
Each event runs one or more shell scripts that receive structured JSON on stdin
and emit structured JSON on stdout to control Claude's behavior.

**Why it exists:** Instruction-following degrades under context pressure.
Long sessions accumulate context that crowds out early instructions. Hooks are
deterministic — they run unconditionally on every matching event regardless of
context state. A hook that denies unsafe git operations does so on turn 1 and
turn 150 identically.

**What you can count on:**
- Every Write/Edit tool call runs 6 PreToolUse hooks and 5 PostToolUse hooks, in registration order.
- Every Bash tool call runs 2 PreToolUse hooks (guard.sh, auto-review.sh).
- Every Task tool call runs 1 PreToolUse hook (task-track.sh).
- A hook that crashes (unhandled error under `set -euo pipefail`) causes deny-on-crash behavior for safety-critical hooks.
- `exit 0` with no stdout = hook passes silently with no effect.
- Hook failures are logged to stderr; they do not stop Claude's operation.

**How it works:** Settings are registered in `~/.claude/settings.json` under the
`hooks` key. Each entry specifies an event name, optional matcher pattern, and
the command to run. Claude Code dispatches hooks synchronously (except
`test-runner.sh` which is `async: true`) before or after the matched tool executes.

### Hook Input Format

All hooks receive JSON on stdin:

```json
// PreToolUse / PostToolUse
{
  "tool_name": "Bash|Write|Edit|Read|Grep|...",
  "tool_input": {
    "command": "git commit -m 'fix'",     // Bash
    "file_path": "/path/to/file.ts",       // Write|Edit
    "content": "...",                       // Write
    "new_string": "..."                     // Edit
  },
  "cwd": "/current/working/directory"
}

// SubagentStart / SubagentStop
{
  "agent_type": "planner|implementer|tester|guardian",
  "response": "...agent output..."          // SubagentStop only
}

// SessionStart
{
  "trigger": "startup|resume|clear|compact"
}

// UserPromptSubmit
{
  "prompt": "user's message text",
  "session_id": "..."
}

// Stop
{
  "stop_hook_active": true|false   // prevents re-firing loops
}
```

### Hook Output Formats

**PreToolUse: Deny** — blocks the tool call completely
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Cannot commit on main. Create a worktree."
  }
}
```

**PreToolUse: Allow with rewrite** — transparently replaces the command
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "Rewrote /tmp/ to project tmp/",
    "updatedInput": {
      "command": "mkdir -p /project/tmp && mv file /project/tmp/"
    }
  }
}
```

**Important:** `updatedInput` is NOT supported in `PreToolUse` hooks — it silently
fails. It only works in `PermissionRequest` hooks. guard.sh's `rewrite()` function
produces this output format, but the rewrites are non-functional in practice.
All active command modifications in guard.sh have been converted from rewrite() to
deny() with the corrected command in the reason message. See upstream issue
anthropics/claude-code#26506. The `updatedInput` format above is documented for
reference only.

**PreToolUse / PostToolUse: Advisory** — injects context without blocking
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "Warning: plan is stale (20% source churn)"
  }
}
```

**PostToolUse: Feedback loop** — exit code 2 triggers model retry with the context
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "Linter found 3 issues:\n  - unused import at line 5\n  - ..."
  }
}
```
Exit code 2 on a PostToolUse hook causes the model to retry the operation
with the `additionalContext` injected. `lint.sh` uses this for auto-fix loops.

**Stop / SubagentStop: System message or block**
```json
{
  "systemMessage": "Session summary: 12 files changed, 3 @decisions added"
}

{
  "decision": "block",
  "reason": "Implementer output missing required test results"
}
```

**SessionStart / SubagentStart: Context injection**
```json
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "Git: branch=main | 19 dirty | Plan: Phase 3/5"
  }
}
```

### Lifecycle Events

| Event | Matcher | When | Hooks Registered |
|-------|---------|------|------------------|
| **SessionStart** | `startup\|resume\|clear\|compact` | Fresh session, /clear, /compact | session-init.sh |
| **UserPromptSubmit** | (all) | Every user prompt | prompt-submit.sh |
| **PreToolUse** | `Write\|Edit` | Before Write or Edit tool | test-gate.sh, mock-gate.sh, branch-guard.sh, doc-gate.sh, plan-check.sh, checkpoint.sh |
| **PreToolUse** | `Bash` | Before every Bash call | guard.sh, auto-review.sh |
| **PreToolUse** | `Task` | Before every agent dispatch | task-track.sh |
| **PostToolUse** | `Write\|Edit` | After Write or Edit completes | lint.sh, track.sh, code-review.sh, plan-validate.sh, test-runner.sh |
| **PostToolUse** | `WebFetch` | After WebFetch | webfetch-fallback.sh |
| **PostToolUse** | `mcp__playwright__browser_snapshot` | After Playwright snapshot | playwright-cleanup.sh |
| **PostToolUse** | `Skill` | After skill execution | skill-result.sh |
| **PreCompact** | (all) | Before /compact context summarization | compact-preserve.sh |
| **SubagentStart** | (all) | When any agent begins | subagent-start.sh |
| **SubagentStop** | `planner\|Plan` | When planner agent completes | check-planner.sh |
| **SubagentStop** | `implementer` | When implementer completes | check-implementer.sh |
| **SubagentStop** | `tester` | When tester completes | check-tester.sh |
| **SubagentStop** | `guardian` | When guardian completes | check-guardian.sh |
| **SubagentStop** | `Explore\|explore` | When Explore agent completes | check-explore.sh |
| **SubagentStop** | `general-purpose` | When general-purpose agent completes | check-general-purpose.sh |
| **Stop** | (all) | After Claude finishes responding | surface.sh, session-summary.sh, forward-motion.sh |
| **SessionEnd** | (all) | Session termination | session-end.sh |
| **Notification** | `permission_prompt\|idle_prompt` | Permission prompts, idle state | notify.sh |

### Execution Order

Within each event, hooks execute in registration order (top-to-bottom in `settings.json`).
For PreToolUse:Write|Edit, the order is:
1. `test-gate.sh` — check test status first (fastest)
2. `mock-gate.sh` — detect mocking patterns
3. `branch-guard.sh` — block main branch writes
4. `doc-gate.sh` — enforce documentation headers
5. `plan-check.sh` — require MASTER_PLAN.md
6. `checkpoint.sh` — create git ref checkpoint

If any hook denies, subsequent hooks in the same event do not run.

---

## 3. Gate Hooks — Pre-Execution Enforcement

These hooks run PreToolUse — before the tool executes. They can deny (block),
rewrite (transparently fix), or advise (inject context). They are the mechanical
enforcement layer that instructions cannot replace.

---

### guard.sh

**What it does:** Multi-tier safety gate for all Bash commands. 11 numbered
checks run in sequence. Any check can deny or rewrite the command. Covers
nuclear destruction, CWD safety, main branch protection, force push handling,
destructive git commands, and test/proof gates.

**Why it exists:** Bash is the most dangerous tool Claude has. A single mistyped
command can destroy files, corrupt git history, or fork-bomb the machine.
Instruction-level safety ("be careful with git") cannot prevent accidents.
guard.sh catches them at the system level.

**What you can count on:**
- `rm -rf /`, `rm -rf ~`, fork bombs, `dd to /dev/*`, `mkfs`, `curl | bash`,
  SQL `DROP DATABASE`, `shutdown`, and `chmod 777 /` are ALWAYS denied (Check 0).
- If guard.sh crashes under `set -euo pipefail`, the EXIT trap fires deny-on-crash
  so safety is never sacrificed for convenience.
- Commands on main/master branch without a MASTER_PLAN.md-only exception are ALWAYS
  denied for commits (Check 2).
- Force pushes to main/master are ALWAYS denied; `--force` elsewhere is rewritten
  to `--force-with-lease` (Check 3).
- `git reset --hard`, `git clean -f`, and `git branch -D` are ALWAYS denied (Check 4).
- Worktree removal is ALWAYS rewritten to cd to main first (Check 5).
- Tests must be passing for merges (Check 6) and commits (Check 7).
- `.proof-status` must be `verified` for commits and merges when the gate is active (Check 8).
- No agent can write `verified` to `.proof-status` directly (Check 9).
- `.proof-status` cannot be deleted while verification is active (Check 10).

**How it works:**

```
Check 0:  Nuclear deny — filesystem/disk/fork-bomb/permission/shutdown/RCE/SQL
Check 0.75: Deny cd-into-worktree (CWD death prevention)
Check 1:  /tmp/ writes → deny; corrected project tmp/ path in message
Check 2:  Commits on main/master → deny (exceptions: MASTER_PLAN.md only, MERGE_HEAD)
Check 3:  Force push to main/master → deny; --force elsewhere → deny with --force-with-lease suggestion
Check 4:  git reset --hard, git clean -f, git branch -D → deny
Check 5:  git worktree remove → deny; corrected safe command (cd first) in message
Check 5b: rm -rf .worktrees/ → deny; corrected safe command in message
Check 6:  git merge with failing tests → deny
Check 7:  git commit with failing tests → deny
Check 8:  git commit/merge without .proof-status = verified → deny
Check 9:  Agent writes verified to .proof-status → deny
Check 10: rm of .proof-status when gate active → deny

Note: updatedInput (transparent rewrite) is NOT supported in PreToolUse hooks —
it silently fails. All corrections use deny() with the safe alternative in the
reason message. See upstream issue anthropics/claude-code#26506.
```

**State files read:**
- `.claude/.test-status` — `pass|fail_count|epoch` format
- `.claude/.proof-status` — `verified|needs-verification|pending|epoch` format
- `.claude/.cwd-recovery-needed` — canary file for CWD recovery (one-shot)

**Configuration:** guard.sh has no configuration options. All thresholds are
constants in `context-lib.sh` (`TEST_STALENESS_THRESHOLD=600` seconds).

---

### auto-review.sh

**What it does:** Three-tier command classification engine for Bash commands.
Decomposes compound commands (&&, ||, ;, |) and recursively analyzes each
segment. Emits approve/advise decisions.

**Why it exists:** `settings.json` permission rules use static prefix matching —
`Bash(git *)` cannot distinguish `git log` (safe) from `git reset --hard` (dangerous).
auto-review.sh understands subcommands, flags, and composition.

**What you can count on:**
- Tier 1 commands (ls, cat, grep, echo, pwd, git log, git status, etc.) always auto-approve.
- Tier 3 commands (rm, sudo, kill, pkill) always inject advisory context.
- Compound commands containing any risky segment defer to user.
- Command substitutions `$()` are recursively analyzed up to depth 2.

**How it works:** classify() function categorizes the primary command token.
Tier 2 commands (git, npm, docker) are further analyzed by their subcommand.
The approve() function emits a PreToolUse allow. The advise() function emits
additionalContext explaining the risk without blocking.

---

### branch-guard.sh

**What it does:** Blocks source file writes on main/master branches.
Fires on Write|Edit for source files in git repos where main/master is checked out.

**Why it exists:** guard.sh blocked git commits on main but allowed agents to
accumulate substantial work in the wrong branch before hitting the commit gate.
branch-guard.sh catches edits at write-time, before any work is done.

**What you can count on:**
- Source file writes on main/master are ALWAYS denied.
- The `~/.claude` directory itself is exempt (meta-infrastructure).
- `MASTER_PLAN.md` is exempt (planning documents are written on main by design).
- Non-source files (config, docs, markdown, JSON, YAML) are NOT checked.
- Files outside git repos are NOT checked.

**State files read:** None. Reads git branch via `git symbolic-ref`.

---

### doc-gate.sh

**What it does:** Documentation enforcement for Write|Edit operations.
Checks that new source files have a documentation header. For 50+ line files,
also checks for a `@decision` annotation.

**Why it exists:** Sacred Practice #7: Code is Truth. Documentation must live
with the code, not in separate wiki pages. doc-gate.sh enforces headers at
write-time before the code can accumulate without them.

**What you can count on:**
- Write to a new source file without a doc header → DENIED with template suggestion.
- Write to a source file ≥50 lines without `@decision` → DENIED.
- Edit to a file that already has a header → allowed (edits don't add new files).
- Edit to a file ≥50 lines missing `@decision` → advisory warning, not deny.
- The `~/.claude/hooks/` directory itself is exempt.
- Test files, config files, vendor directories are exempt.
- New markdown files in project root get an advisory against violating Sacred Practice #9.

**Language support:** Python (`"""`), TypeScript/JavaScript (`/** */` or `//`),
Go (`// Package...`), Rust (`//!`), Shell (`# comment`), C/C++ (`/** */` or `//`),
Java/Kotlin/Swift (`/** */`), Ruby (`#`), PHP (`/** */` or `#`).

**State files read:** None.

**Configuration:** `DECISION_LINE_THRESHOLD=50` in `context-lib.sh`.

---

### test-gate.sh

**What it does:** Escalating gate that blocks source writes when tests are failing.
Reads `.test-status` (written by `test-runner.sh`) and applies a strike system.

**Why it exists:** test-runner.sh runs async — results arrive after the write.
Without test-gate.sh, agents can compound errors by writing more source code
while tests are failing, creating a failing-test feedback loop.

**What you can count on:**
- No `.test-status` → allow (no test data yet; cold-start advisory if framework detected).
- Tests passing → allow, reset strikes.
- Tests stale (>10 minutes) → allow (may have been fixed externally).
- Tests failing, strike 1 → advisory warning, allow.
- Tests failing, strike 2+ → DENY with trajectory-aware guidance.
- Test files are ALWAYS allowed (so fixes can proceed).
- Non-source files are ALWAYS allowed.

**Trajectory awareness:** On deny, reads `.session-events.jsonl` to identify
which file has been most-edited without resolving failures. Reports the most-edited
file and the failing assertion if available (via `detect_approach_pivots()`).

**State files read:** `.claude/.test-status`, `.claude/.test-gate-strikes`, `.claude/.session-events.jsonl`
**State files written:** `.claude/.test-gate-strikes`

**Configuration:** `TEST_STALENESS_THRESHOLD=600` in `context-lib.sh`.

---

### mock-gate.sh

**What it does:** Detects internal mock usage in test files and applies an
escalating strike system. Strike 1 → advisory. Strike 2+ → deny.

**Why it exists:** Sacred Practice #5: Real unit tests, not mocks. arXiv 2602.00409
found agents mock 95% of test doubles vs humans at 91%. The `@mock-exempt`
annotation provides an escape hatch for genuinely necessary external mocks.

**What you can count on:**
- Non-test files are ALWAYS allowed.
- Test files with `@mock-exempt` annotation are ALWAYS allowed.
- Mocks targeting external boundaries (HTTP, Redis, SQL, AWS, etc.) are allowed.
- Internal mocks (mocking your own modules/classes): strike 1 = advisory, strike 2+ = deny.

**Detection patterns (internal mocks):**
- Python: `MagicMock`, `@patch` on non-external targets, `mocker.patch` on internals
- JavaScript/TypeScript: `jest.mock(non-external)`, `.mockImplementation`, `sinon.stub`
- Go: `gomock.`, `mockgen`, `EXPECT().()`

**External boundary allowlist:** requests, httpx, redis, psycopg, sqlalchemy, urllib,
http.client, smtplib, socket, subprocess, boto3, aiohttp, pymongo, mysql, sqlite3,
axios, node-fetch, undici, http, https, fs, child_process, ioredis, pg, mongodb, aws-sdk.

**State files read/written:** `.claude/.mock-gate-strikes`

---

### plan-check.sh

**What it does:** Blocks source writes without `MASTER_PLAN.md`. Also detects
stale plans using composite signal: source file churn percentage + decision drift count.

**Why it exists:** Sacred Practice #6: No Implementation Without Plan. Advisory
warnings were ignored by agents — this hook enforces with hard denies.

**What you can count on:**
- Write to source file in a git repo with no `MASTER_PLAN.md` → DENIED.
- `MASTER_PLAN.md` exists but all initiatives completed (`PLAN_LIFECYCLE=dormant`) → DENIED with message "All initiatives are completed. Add a new initiative before implementing."
- Living-document format: `PLAN_LIFECYCLE` is `none`/`active`/`dormant` (never `completed`). Dormant means all `### Initiative:` blocks have status completed — add a new initiative to resume work.
- Legacy format (no `### Initiative:` headers): `PLAN_LIFECYCLE` is `none`/`active`/`dormant` (was `completed` pre-Phase 2). All-phases-done → dormant.
- Source churn ≥35% since plan update → DENIED.
- Decision drift ≥5 out-of-sync decisions → DENIED.
- Source churn 15-34% or drift 2-4 → advisory warning.
- Edit tool (substring replacement) → skipped (inherently scoped).
- Files <20 lines → fast-mode bypass with advisory.
- The `~/.claude` directory → exempt.
- Non-git directories → exempt.

**Staleness calculation:**
- **Source churn %** = `changed_source_files / total_source_files * 100` since plan last modified.
- **Decision drift** = unplanned DEC-IDs + unimplemented DEC-IDs from last surface.sh audit.
- Churn is cached in `.claude/.plan-churn-cache` keyed on `HEAD_SHORT|plan_mod_epoch`.

**State files read:** `MASTER_PLAN.md`, `.claude/.plan-drift`, `.claude/.plan-churn-cache`

**Configuration:** `PLAN_CHURN_WARN=15`, `PLAN_CHURN_DENY=35` (overridable via env).

---

### task-track.sh

**What it does:** PreToolUse:Task hook that tracks agent dispatches and enforces
three pre-dispatch gates.

**Why it exists:** SubagentStart hooks do not fire reliably in Claude Code v2.1.38.
PreToolUse:Task demonstrably fires before every Task dispatch, making it the
reliable interception point for agent lifecycle management.

**What you can count on (three gates):**

**Gate A (Guardian dispatch):** Requires `.proof-status = verified` when the gate
is active (file exists). Missing file = no implementation in progress = allow.
Prevents Guardian from committing unverified work.

**Gate B (Tester dispatch):** Blocks tester dispatch if an implementer trace is
still active (checking `.active-implementer-*` marker in traces/). Prevents
premature tester dispatch before implementer returns.

**Gate C (Implementer dispatch):**
- Gate C.1: Blocks implementer on main/master branch.
- Gate C.2: Creates `.proof-status = needs-verification` to activate Gate A.
- Gate C.3: Writes `.active-worktree-path` breadcrumb (most-recent non-main worktree)
  so `resolve_proof_file()` can find `.proof-status` in worktree scenarios.

**State files read:** `.claude/.proof-status`, `traces/.active-implementer-*`
**State files written:** `.claude/.proof-status` (creates), `.claude/.active-worktree-path` (breadcrumb)

---

### checkpoint.sh

**What it does:** Creates git refs at `refs/checkpoints/<branch>/<N>` before
file writes. Does not touch the working copy or index — uses git plumbing commands.

**Why it exists:** Provides mid-session recovery without stash pollution. Snapshots
the working directory state before each write so any write can be rewound with `/rewind`.

**What you can count on:**
- Checkpoint created on every 5th write (threshold).
- Checkpoint created on first modification of any file in the session.
- Checkpoints do NOT affect `git status`, `git diff`, or `git stash list`.
- Checkpoints survive garbage collection because they are named refs.
- Only fires on feature branches (not main/master).
- Only fires in git repos.
- Exempt for meta-repo (`~/.claude`).

**How it works:** Copies the real index to a temp file, runs `git add -A` against
it, calls `git write-tree` to get a tree SHA, then `git commit-tree` to create a
commit object. Finally `git update-ref refs/checkpoints/<branch>/<N> <SHA>`.

**State files read/written:** `.claude/.checkpoint-counter`, `.claude/.session-changes-<session_id>`

---

## 4. Feedback Hooks — Post-Execution Quality

These hooks run PostToolUse — after the tool has executed. They cannot undo the
write but they can inject feedback, update state, and trigger retry loops.

---

### lint.sh

**What it does:** Auto-detects the project linter and runs it on the modified file.
Injects linter output as `additionalContext`. Exit code 2 triggers model retry.

**Why it exists:** Linting errors compound quickly. lint.sh catches them
immediately after write, before the next file is touched.

**What you can count on:**
- Linter detection is cached in `.claude/.lint-cache` (project-scoped).
- If no linter detected, exits silently.
- Exit code 2 on linter failure triggers the model to fix the issue.
- Circuit breaker: `.lint-breaker` file prevents infinite retry loops.

**Detected linters:** ruff (Python), black (Python), flake8 (Python), eslint (JS/TS),
prettier (JS/TS), tsc (TypeScript), clippy (Rust), golangci-lint (Go), rubocop (Ruby).

**State files read/written:** `.claude/.lint-cache`, `.claude/.lint-breaker`

---

### track.sh

**What it does:** Records every Write/Edit operation to a session-scoped tracking
file. Also invalidates `.proof-status = verified` when source files change after
verification.

**Why it exists:** check-implementer.sh, surface.sh, and check-guardian.sh all
need to know which files changed in the current session. A single-pass tracking
file is faster than re-scanning git status on every Stop hook.

**What you can count on:**
- Every file path written this session appears in `.session-changes-<SESSION_ID>`.
- Append-only, deduplicated by sort -u callers.
- Source file changes after `verified` status reset proof to `pending`.

**State files written:** `.claude/.session-changes-<SESSION_ID>`, `.claude/.proof-status`
**State files read:** `.claude/.proof-status`

---

### test-runner.sh

**What it does:** Auto-detects the project test framework and runs the full suite
asynchronously after every Write/Edit. Writes results to `.test-status`.

**Why it exists:** Sacred Practice #4: Nothing Done Until Tested. Running tests
automatically catches regressions immediately rather than at commit time.

**What you can count on:**
- Runs async (`async: true` in settings.json) — does not block Claude.
- Detects pytest, vitest, jest, cargo test, go test, npm test.
- Writes `pass|0|<epoch>` or `fail|N|<epoch>` to `.test-status`.
- Results available on next conversation turn via `additionalContext`.

**State files written:** `.claude/.test-status`

---

### code-review.sh

**What it does:** Lightweight complexity advisory for source files. Detects
high cyclomatic complexity patterns and injects advisory context.

**Why it exists:** Provides real-time quality feedback without blocking writes.

**State files:** None.

---

### plan-validate.sh

**What it does:** Checks source writes against MASTER_PLAN.md for alignment.
Detects when implementation diverges from planned requirements.

**Why it exists:** Catches plan drift at write-time rather than at session end.

**State files:** None.

---

### webfetch-fallback.sh

**What it does:** After a failed WebFetch, suggests alternative fetch methods.

**Why it exists:** WebFetch fails for bot-blocked domains and JS-rendered sites.
The fallback suggests `mcp__fetch__fetch` (simpler HTTP) or Playwright (full browser).

**State files:** None.

---

### playwright-cleanup.sh

**What it does:** After a Playwright browser_snapshot, suggests closing stale
browser sessions to free resources.

**State files:** None.

---

### skill-result.sh

**What it does:** Tracks skill execution results in the session event log.

**State files written:** `.claude/.session-events.jsonl`

---

## 5. Session Lifecycle Hooks

These hooks manage the session context — injecting information at start,
capturing it before compaction, and summarizing at end.

---

### session-init.sh

**What it does:** Fires at session start (startup, resume, /clear, /compact).
Builds a `CONTEXT_PARTS` array of context strings and emits them as `additionalContext`.

**Why it exists:** Every session starts cold. Session-init gives Claude the
context it needs to orient immediately: what project, what branch, what plan,
what agent is active, what needs attention.

**Context injected (in order):**
1. Update notification (from previous session's background update-check result, one-shot).
2. Launches background update-check for next session.
3. Git state: branch, dirty count, worktree count, main-branch warning.
4. Stale worktree detection (via `worktree-roster.sh prune`).
5. MASTER_PLAN.md preamble (first 30 lines before `---`).
6. Plan status: phase progress, age, staleness warning (≥10% churn).
7. Research log status: entry count, recent topics.
8. Preserved context from pre-compaction (if `.preserved-context` exists).
9. Stale session files from crashed sessions.
10. Trace protocol: crashed trace detection, last completed trace for project.
11. Pending agent findings from `.agent-findings`.
12. Syntax gate: validates `source-lib.sh`, `log.sh`, `context-lib.sh` before sourcing.

**State files read:** `.update-status`, `.preserved-context`, `.session-changes*`,
`.agent-findings`, traces index
**State files written:** `.statusline-cache`, `.prompt-count-*` (reset)

---

### prompt-submit.sh

**What it does:** UserPromptSubmit hook — fires on every user prompt. Serves
two critical functions: the only path for user verification to reach
`.proof-status`, and dynamic context injection based on prompt keywords.

**Why it exists:** Dual purpose: verification gate enforcement and contextual
help. All approval keywords must go through this hook to prevent agents from
self-approving their own work.

**What you can count on:**
- The ONLY path to write `verified` to `.proof-status` is via this hook.
- No agent can write `verified` directly (guard.sh Check 9 blocks it).
- Approval keywords detected: `verified`, `approved`, `lgtm`, `looks good`, `ship it`, `approve for commit`.
- Dual-writes to both the worktree's `.proof-status` and orchestrator's `.proof-status`.
- On first prompt of session (`.prompt-count` file absent): injects full session context as session-init fallback.
- Auto-claims GitHub issues referenced in action prompts (`work on #42` → claim issue 42).
- Injects pending agent findings from `.agent-findings` (one-shot, clears after injection).

**State files read:** `.claude/.proof-status` (via `resolve_proof_file()`),
`.claude/.agent-findings`, `.claude/.prompt-count-<SESSION_ID>`
**State files written:** `.claude/.proof-status` (verified), `.claude/.prompt-count-<SESSION_ID>`

---

### compact-preserve.sh

**What it does:** PreCompact hook — fires before `/compact` context summarization.
Saves a snapshot of current session state to `.preserved-context` so the
post-compaction session can reconstruct what was happening.

**Why it exists:** Compaction summarizes the conversation but loses structured
state. `.preserved-context` carries the resume directive, active worktree,
plan status, and pending decisions into the new context window.

**What you can count on:**
- `.preserved-context` is written before compaction and read by session-init.sh after.
- Contains a `RESUME DIRECTIVE:` block with actionable continuation steps.
- session-init.sh reads and then deletes it (one-shot delivery).

**State files written:** `.claude/.preserved-context`

---

### session-end.sh

**What it does:** SessionEnd hook — fires on session termination (any reason).
Cleans up session-scoped files, releases todo claims, kills orphaned async
processes, and writes a session index entry for cross-session learning.

**What you can count on:**
- Session-scoped files are always cleaned up on normal exit:
  `.session-changes-<ID>`, `.session-decisions-<ID>`, `.lint-cache`, `.test-gate-strikes`,
  `.mock-gate-strikes`, `.test-gate-cold-warned`, `.skill-result*`, `.track.*`.
- Persists: `.audit-log`, `.agent-findings`, `.lint-breaker`, `.plan-drift`, `.test-status`.
- Kills lingering `test-runner.sh` processes.
- Archives `.session-events.jsonl` to project-specific archive directory.
- Writes session index entry (project hash, outcome, duration, test result, proof status).
- Scoped subagent tracker `.subagent-tracker-<SESSION_ID>` deleted on clean exit.

---

### surface.sh

**What it does:** Stop hook — decision audit pipeline. Scans session-changed
source files for `@decision` coverage, REQ-ID traceability, and plan drift.
Emits `systemMessage` with findings.

**Why it exists:** session-end.sh provides cleanup; surface.sh provides insight.
Running at every Stop (after Claude finishes responding) catches missing annotations
while they're still easy to fix.

**What you can count on:**
- Fires only when source files were modified this session.
- Checks `@decision` coverage for changed files ≥50 lines.
- Checks REQ-ID traceability (P0 requirements addressed by DEC-IDs).
- Emits `systemMessage` with coverage report.
- Writes `.plan-drift` file for plan-check.sh staleness detection.

**State files read:** `.session-changes-<SESSION_ID>`
**State files written:** `.claude/.plan-drift`

---

### session-summary.sh

**What it does:** Stop hook — builds session summary from state files and
injects it as `systemMessage`. Reports files changed, @decision count, test
status, and active proof-status.

**State files read:** `.session-changes-*`, `.test-status`, `.proof-status`

---

### forward-motion.sh

**What it does:** Stop hook — suggests the next logical action based on current
session state. Reads plan status and suggests "next phase," "run tests," etc.

**State files read:** `MASTER_PLAN.md`, `.test-status`

---

## 6. Agent System

**What it does:** Four specialized agents divide complex work into phases with
clear handoffs. Each agent has a dedicated prompt, a model assignment, and
SubagentStop validation.

**Why it exists:** A single context window cannot maintain the full state of
planner + implementer + verifier + committer simultaneously. Specialization
lets each agent go deep on its role without context dilution.

**What you can count on:**
- Orchestrator (main context) dispatches agents via Task tool — it does NOT write source code.
- Each agent handoff is enforced by SubagentStop hooks.
- Dispatch order is enforced by task-track.sh gates (implementer → tester → guardian).
- max_turns are set by the orchestrator on every Task invocation.

### The Four Agents

| Agent | Model | max_turns | Primary Output | SubagentStop Validator |
|-------|-------|-----------|----------------|------------------------|
| Planner | claude-opus-4-6 | 40 | MASTER_PLAN.md + GitHub Issues | check-planner.sh |
| Implementer | claude-sonnet-4-6 | 75 | Tests + source code in worktree | check-implementer.sh |
| Tester | claude-sonnet-4-6 | 25 | .proof-status + verification report | check-tester.sh |
| Guardian | claude-opus-4-6 | 30 | git commit + merge + cleanup | check-guardian.sh |

### Planner Agent (agents/planner.md)

**Input:** User feature description, existing codebase, prior research.
**Output:** `MASTER_PLAN.md` updated with a new `### Initiative:` block (or created fresh),
requirements (REQ-P0-NNN), decisions (DEC-NNN), and GitHub Issues (one per phase).

**Create-or-amend workflow:**
- If `MASTER_PLAN.md` with `## Identity` exists → **amend**: add new `### Initiative:` block
  under `## Active Initiatives`. Preserve existing content. Never overwrite.
- If `MASTER_PLAN.md` does not exist → **create**: full living-document structure with
  `## Identity`, `## Architecture`, `## Principles`, `## Decision Log`, `## Active Initiatives`,
  `## Completed Initiatives` sections.
- Completing an initiative → update its `**Status:**` to `completed`, then call
  `compress_initiative()` or instruct Guardian to compress it after the final phase merge.

**Phases:**
1. Problem decomposition — requirements (P0/P1/P2), success metrics, evidence gathering.
2. Architecture + Research gate — check `.claude/research-log.md`, invoke `/deep-research` if gaps.
3. Plan output — add initiative to MASTER_PLAN.md with decision rationale, worktree strategy.
4. GitHub Issues — one per phase, linked from plan.

**SubagentStop check (check-planner.sh):**
- Living-document format: MASTER_PLAN.md exists with `## Identity`, `## Architecture`, `## Decision Log`, at least one `### Initiative:` header with `**Status:**`.
- Legacy format: MASTER_PLAN.md exists and has at least one `## Phase N` header.
- At least one GitHub Issue created.
- Plan includes `@decision` annotations.

### Implementer Agent (agents/implementer.md)

**Input:** Issue number, worktree path, TRACE_DIR.
**Output:** Tests passing in isolated worktree, TRACE_DIR/artifacts populated.

**Phases:**
1. Requirement verification — parse issue, identify edge cases.
2. Worktree setup — `git worktree add .worktrees/feature-<name> -b feature/<name>`.
3. Test-first implementation — failing tests → implementation → passing tests.
4. Decision annotation — `@decision` on all 50+ line source files.
5. Evidence writing — `TRACE_DIR/artifacts/{test-output.txt, diff.patch, files-changed.txt}`.

**SubagentStop check (check-implementer.sh):**
1. Branch is NOT main/master (worktree was used).
2. All changed source files ≥50 lines have `@decision` annotation.
3. Agent did NOT end with unanswered approval question.
4. Tests are passing (`.test-status = pass`).
5. Required trace artifacts present (`test-output.txt`, `files-changed.txt`).

### Tester Agent (agents/tester.md)

**Input:** Implementer trace directory, feature description.
**Output:** Live verification report with evidence, `.proof-status = pending`.

**Methodology:**
1. Read implementer's trace for context.
2. Discover available tools (Playwright, browser, CLI).
3. Collect evidence: test output, live demo, screenshots.
4. Write `.proof-status = pending|<epoch>` to worktree's `.claude/`.
5. Present verification assessment with: methodology, coverage gaps, confidence level.
6. If AUTOVERIFY: CLEAN conditions met → check-tester.sh auto-writes `verified`.

**SubagentStop check (check-tester.sh) — auto-verify critical path:**
1. `.proof-status` exists (tester wrote `pending`).
2. If response contains `AUTOVERIFY: CLEAN`:
   - Secondary validation: `**High**` confidence present.
   - No `Partially verified` in coverage.
   - No non-environmental `Not tested` entries.
   - If all pass → hook writes `verified|<epoch>` (bypasses manual approval).
3. Otherwise → `systemMessage` advisory, user must approve manually.

### Guardian Agent (agents/guardian.md)

**Input:** Files to commit, issue numbers, push intent.
**Output:** Commit + merge + push + worktree cleanup.

**Sequence:**
1. Verify `.proof-status = verified` (task-track.sh Gate A already checked).
2. Scan changed files for `@decision` annotation gaps.
3. Present: diff summary, @decision coverage, commit message draft.
4. Await user approval (one approval covers: stage → commit → close issue → push).
5. Merge feature branch to main.
6. Push to origin.
7. Clean up worktree (`safe_cleanup` from context-lib.sh).

**SubagentStop check (check-guardian.sh):**
- Commit was created (git log shows new commit).
- No uncommitted changes remain.
- Worktree cleanup completed.
- Writes `.cwd-recovery-needed` canary if worktree was removed.

### subagent-start.sh

**What it does:** SubagentStart hook — injects fresh context into every agent
before it begins. Also initializes the trace directory for the new agent run.

**Context injected:**
- Current git state (branch, dirty, worktrees).
- Plan status (active phase).
- Agent-type-specific guidance:
  - Planner: research log status, trace directory.
  - Implementer: proof pipeline status, TRACE_DIR env var.
  - Tester: implementer trace to review.
  - Guardian: session event log for richer commit messages.
- Project architecture from MASTER_PLAN.md preamble.
- Trace directory path as `TRACE_DIR` so agent knows where to write artifacts.

**Trace initialization:** Calls `init_trace()` from context-lib.sh, which creates
`traces/<agent_type>-<timestamp>-<hash>/manifest.json` and
`traces/.active-<agent_type>-<session_id>` marker.

---

## 7. Proof Pipeline — Verification Chain

**What it does:** Enforces that every feature is verified live before it can be
committed. No agent can self-approve its own work.

**Why it exists:** Sacred Practice #10: Proof Before Commit. The tester runs the
feature, presents evidence, and gets user or auto-verification. Only then is
Guardian allowed to commit.

**What you can count on:**
- No Guardian dispatch without `.proof-status = verified` (task-track.sh Gate A).
- No git commit/merge without `.proof-status = verified` (guard.sh Check 8).
- No agent can write `verified` to `.proof-status` (guard.sh Check 9 blocks Bash writes).
- `prompt-submit.sh` is the only path for human-verified status.
- `check-tester.sh` is the only path for auto-verified status.
- Source file changes after `verified` reset status to `pending` (track.sh).

### 9-Step Verification Lifecycle

```
Step 1: Orchestrator dispatches implementer
        → task-track.sh Gate C writes ".proof-status = needs-verification"
        → Gate A now active: Guardian blocked

Step 2: Implementer runs in worktree
        → Writes test-output.txt, diff.patch to TRACE_DIR/artifacts/

Step 3: Implementer returns
        → check-implementer.sh validates: branch, @decision, tests, artifacts

Step 4: Orchestrator dispatches tester
        → task-track.sh Gate B checks: is implementer still active? (no → allow)
        → subagent-start.sh injects implementer trace context

Step 5: Tester verifies feature live
        → Writes ".proof-status = pending|<epoch>" to worktree .claude/
        → Presents: test results, screenshots, API responses

Step 6: check-tester.sh fires (SubagentStop:tester)
        → Phase 1 (critical path, <2s): check .proof-status, scan for AUTOVERIFY: CLEAN
        → Auto-verify path: High confidence + full coverage + no caveats
          → writes ".proof-status = verified|<epoch>"
          → Orchestrator presents report + dispatches Guardian in parallel
        → Manual path: emits advisory, waits for user

Step 7: User sees evidence and responds (manual path only)
        → User types "approved", "lgtm", "looks good", "verified", or "ship it"
        → prompt-submit.sh detects keyword → writes ".proof-status = verified|<epoch>"
        → Dual-write to both worktree and orchestrator .proof-status

Step 8: Orchestrator dispatches Guardian
        → task-track.sh Gate A: reads ".proof-status = verified" → allow

Step 9: Guardian commits
        → guard.sh Check 8: reads ".proof-status = verified" → allow
        → Commit proceeds, worktree cleaned up
        → track.sh: any subsequent source writes reset to "pending"
```

### State File: .proof-status

**Location:** `.claude/.proof-status` (relative to project root or worktree root).
**Format:** `status|epoch` (pipe-delimited, one line).
**States:**
- `needs-verification|<epoch>` — created by task-track.sh at implementer dispatch. Gate active.
- `pending|<epoch>` — written by tester after live verification. Awaiting approval.
- `verified|<epoch>` — written by prompt-submit.sh (user) or check-tester.sh (auto). Gate open.

**Resolution in worktree scenarios:** `resolve_proof_file()` in `log.sh` reads
`.active-worktree-path` breadcrumb (written by task-track.sh) to find the correct
`.proof-status` path. Without the breadcrumb, hooks default to the orchestrator's
`CLAUDE_DIR/.proof-status`.

---

## 8. Observatory System — Self-Improvement Flywheel

**What it does:** Analyzes accumulated agent traces to surface data quality signals,
ranks improvements by impact and feasibility, proposes one improvement at a time,
and tracks the implementation history. Each accepted improvement makes traces
richer, which enables better analysis — a flywheel.

**Why it exists:** Without systematic analysis, the system cannot learn from its
own operation. The observatory makes agent failures and partial successes visible
and actionable.

**What you can count on:**
- `state.json` version 3 is the authoritative source of improvement history.
- One suggestion at a time: the user sees a concrete improvement proposal.
- Accepted suggestions are tracked in `implemented[]`; rejected in `rejected[]`.
- Analysis is cached in `analysis-cache.json` (invalidated when new traces arrive).

### Skills Available

| Command | Description |
|---------|-------------|
| `/observatory` or `/observatory run` | Full cycle: analyze → suggest → report → approve/defer/reject |
| `/observatory report` | Generate full assessment report (all signals, batches, backlog) |
| `/observatory status` | Show current state (pending, implemented count, acceptance rate) |
| `/observatory history` | Show recent action log from history.jsonl |
| `/observatory analyze-only` | Run analysis only, no suggestion |
| `/observatory backlog` | Show deferred items with reassessment status |
| `/observatory batch <label>` | Approve an entire batch of related signals |

### State Files

**`observatory/state.json` (v3):**
```json
{
  "version": 3,
  "last_analysis_at": null,
  "pending_suggestion": null,
  "pending_title": null,
  "pending_priority": null,
  "implemented": [{"sug_id": "SUG-001", "signal_id": "SIG-...", "implemented_at": "..."}],
  "rejected": [],
  "deferred": []
}
```

**`observatory/history.jsonl`:** One JSON entry per action (accepted/rejected/deferred),
with timestamp and suggestion details.

**`observatory/analysis-cache.json`:** Full analysis output from the last run.
Includes signal list, comparison matrix, batch assignments, assessment report.

**`observatory/analysis-cache.prev.json`:** Previous run's cache (for comparison).

**`observatory/comparison-matrix.json`:** Signal ranking by impact × feasibility.

**`observatory/suggestions/`:** Per-batch assessment files.

---

## 9. Trace Protocol — Persistent Agent Evidence

**What it does:** Every non-trivial agent run creates a trace directory with a
manifest, summary, and artifacts. Traces persist across sessions, crashes, and
compactions — they are the durable evidence of what each agent did.

**Why it exists:** Without traces, agent work is ephemeral. A session crash means
losing all context. With traces, the orchestrator can recover any agent run from
disk by reading `summary.md`. The observatory can analyze 489+ traces to find
patterns. session-init.sh surfaces the last completed trace at startup.

**What you can count on:**
- Every Planner, Implementer, Tester, and Guardian run gets a trace directory.
- Trace ID format: `<agent_type>-<YYYYMMDD-HHMMSS>-<session_hash>`.
- `manifest.json` is written at trace start; finalized by `finalize_trace()` at SubagentStop.
- `summary.md` should be ≤1500 tokens (agent's own summary). If missing, check-*.sh writes the agent's response text as fallback.
- `artifacts/` contains evidence files the agent chose to write.
- Stale `.active-*` markers (>2 hours) are cleaned up on every `init_trace()` call.
- `traces/index.jsonl` is updated by `index_trace()` for cross-project searching.

### Trace Directory Structure

```
traces/<trace_id>/
├── manifest.json        # Metadata: agent type, project, branch, started_at, outcome
├── summary.md           # Agent's summary (≤1500 tokens)
└── artifacts/
    ├── test-output.txt  # Full test framework output (implementer)
    ├── diff.patch       # git diff of all changes (implementer)
    ├── files-changed.txt # One file path per line (implementer)
    ├── proof-evidence.txt # Test output + implementation evidence (tester)
    └── env-requirements.txt # Required env vars (if any)
```

### Trace Lifecycle

1. `subagent-start.sh` calls `init_trace()` → creates `manifest.json` + `.active-<type>-<session>`.
2. Agent writes `summary.md` and artifact files to `TRACE_DIR` (injected via context).
3. SubagentStop hook calls `finalize_trace()` → updates manifest with outcome, duration, test result, files changed.
4. `index_trace()` appends to `traces/index.jsonl`.
5. `.active-*` marker is deleted.
6. Crashed traces: marker becomes stale (>2 hours) → session-init.sh detects and finalizes.

### manifest.json Fields

```json
{
  "version": "1",
  "trace_id": "implementer-20260218-133935-e2cd5f",
  "agent_type": "implementer",
  "session_id": "<CLAUDE_SESSION_ID>",
  "project": "/path/to/project",
  "project_name": "myproject",
  "branch": "feature/my-feature",
  "started_at": "2026-02-18T13:39:35Z",
  "status": "active|completed|crashed",
  "outcome": "success|failure|partial|timeout|skipped",
  "duration_seconds": 3600,
  "test_result": "pass|fail|unknown",
  "proof_status": "verified|pending|unknown",
  "files_changed": 5
}
```

### Outcome Classification

| Outcome | Condition |
|---------|-----------|
| `success` | test_result = pass |
| `failure` | test_result = fail |
| `timeout` | duration > 600s AND test_result = unknown |
| `skipped` | artifacts directory missing or empty |
| `partial` | artifacts present but tests unknown |

---

## 10. Checkpoint and Recovery

**What it does:** Creates git refs before each Write/Edit so any write can be
recovered without touching the working copy.

**Why it exists:** Agents make mistakes. Without checkpoints, a bad write can only
be recovered by `git checkout` (which changes HEAD) or `git stash` (which is
visible and confusing). Git refs at `refs/checkpoints/` are invisible to normal
git operations and can be cherry-picked precisely.

**What you can count on:**
- Checkpoints are created every 5 writes or on first write to any file this session.
- Refs are named `refs/checkpoints/<branch>/<N>` — sequential per branch.
- No modification to the working copy, git index, or `git stash list`.
- Checkpoints survive garbage collection (they are named refs).
- The `/rewind` skill provides an interactive UI to browse and restore checkpoints.

### How Checkpoints Work

1. checkpoint.sh fires PreToolUse:Write|Edit.
2. Increments `.checkpoint-counter` in `.claude/`.
3. If counter % 5 = 0, or file not yet seen this session → `CREATE=true`.
4. Copies the real git index to a temp file.
5. Runs `GIT_INDEX_FILE=<tmp> git add -A` to stage everything.
6. Runs `GIT_INDEX_FILE=<tmp> git write-tree` to get a tree SHA.
7. Runs `git commit-tree <tree> -p HEAD -m "checkpoint:<epoch>:before:<filename>"`.
8. Runs `git update-ref refs/checkpoints/<branch>/<N> <commit_sha>`.

### Recovery with /rewind

The `/rewind` skill lists checkpoints with `git for-each-ref refs/checkpoints/`
and lets the user pick one to restore. Restore uses `git checkout <sha> -- .`
(restores files without changing HEAD) or `git reset --soft <sha>` (changes
staging area only).

### CWD Protection

guard.sh Check 0.5 and 0.75 are part of a defense-in-depth CWD protection system:

**The problem:** When a worktree is deleted, any process whose CWD is inside
the deleted directory fails with `ENOENT` on macOS (posix_spawn). This breaks
ALL subsequent hooks (not just Bash) because the shell cannot spawn child processes.

**Prevention (Check 0.75):** Deny `cd .worktrees/foo && <commands>`. Force resubmission
with subshell wrapping: `( cd .worktrees/foo && <commands> )`. Subshell CWD is isolated.

**Recovery (Check 0.5):**
- Path A: `.cwd` field in hook input is an invalid directory → walk up to nearest git root → emit rewrite with `cd <recovery_dir> && <original_command>`.
- Path B: `.cwd-recovery-needed` canary file → prepend inline `{ cd . 2>/dev/null || cd "$HOME"; }` guard and continue. Canary is one-shot (deleted on read).

**Canary writes:** guard.sh Check 5 (git worktree remove) and Check 5b (rm -rf .worktrees/)
write the deleted worktree path to `.cwd-recovery-needed` before the removal executes.
check-guardian.sh also writes the canary after detecting worktree removal.

---

## 11. Status Bar and Diagnostics

### statusline.sh

**What it does:** Renders the Claude Code status bar. Reads JSON from stdin
(model, workspace, version) and `.statusline-cache` for enriched segments.

**Why it exists:** The status bar gives at-a-glance project state without asking.
Dirty count, worktree count, plan phase, test status, and active agents are
all visible without any commands.

**Status segments (when non-empty):**
```
claude-opus-4-6  myproject  │  14:23:01  │  19 dirty  │  WT:5  │  Phase 3/5  │  ✓ tests  │  ⚡2 agents (implementer)  │  3 todos  │  v1.2.3
```

- **Model** (dim): current Claude model
- **Workspace** (bold cyan): current directory basename
- **Time** (yellow): current HH:MM:SS
- **Dirty** (red): uncommitted file count — shown only when >0
- **WT:N** (cyan): worktree count — shown only when >0; `(N stale)` annotation if stale
- **Phase X/Y** (blue): plan phase progress — dim when "no plan"
- **✓ tests** (green) / **✗ tests** (red): test status — hidden when unknown
- **⚡N agents** (yellow): active agent count and types — shown only when >0
- **Todos** (magenta): pending todo count — shown only when >0
- **Community** (bold white): open PRs + issues from monitored repos — shown when active
- **Version** (green): Claude Code version

**Data source:** `.statusline-cache` (written by hooks via `write_statusline_cache()`).
The cache is JSON: `{dirty, worktrees, plan, test, updated, agents_active, agents_types, agents_total}`.

**Configuration:** Registered as `settings.json statusLine.command`.

---

### notify.sh

**What it does:** Notification hook for permission prompts and idle state.
Sends system notification so user knows Claude is waiting.

**Triggers:** `permission_prompt` (Claude needs permission), `idle_prompt` (Claude is idle).

---

### /diagnose skill

Provides interactive system health diagnostics. Checks:
- settings.json validity
- Hook script syntax
- State file formats
- Worktree roster consistency
- Test suite status

---

## 12. Shared Libraries

Three files form the shared library layer. All hooks source `source-lib.sh`
which bootstraps `log.sh` and `context-lib.sh`.

---

### source-lib.sh (bootstrapper)

**What it does:** Sources `log.sh` and `context-lib.sh`. Also recovers from
deleted-CWD before any hook logic runs.

**Why it exists:** Before the library caching approach was removed (DEC-SRCLIB-001),
each hook individually sourced the libraries. A centralized bootstrapper eliminates
the redundancy and adds the CWD recovery guard at the single point all hooks share.

**What you can count on:**
- `[[ ! -d "${PWD:-}" ]] && { cd "${HOME}" 2>/dev/null || cd /; }` runs before any other logic.
- All hooks source this file as their first dependency.

---

### log.sh (JSON I/O + path utilities)

**What it does:** Provides the four foundational utilities every hook needs:
stdin caching, field extraction, logging, and path detection.

**Functions:**
- `read_input()` — reads and caches stdin JSON (prevents double-read on piped input).
- `get_field <jq_path>` — extracts a field from cached input via jq.
- `log_json <stage> <message>` — structured JSON logging to stderr.
- `log_info <stage> <message>` — human-readable logging to stderr.
- `detect_project_root()` — finds git root, falls back to `CLAUDE_PROJECT_DIR`, then `$HOME`.
- `get_claude_dir()` — returns `.claude` dir path. For `~/.claude` itself, returns the path without double-nesting (fixes #77).
- `resolve_proof_file()` — breadcrumb-based proof-status path resolution for worktree scenarios.

**Why `resolve_proof_file()` exists:** In worktree scenarios, task-track.sh writes
`.proof-status` to the worktree's `.claude/` and writes `.active-worktree-path` breadcrumb.
The tester agent runs inside the worktree and writes proof-status there. prompt-submit.sh
and guard.sh need to find the same file. `resolve_proof_file()` reads the breadcrumb
and returns the worktree path when active; falls back to CLAUDE_DIR otherwise.

---

### context-lib.sh (state builders + shared utilities)

**What it does:** The largest library (57KB). Provides all state-reading functions,
constants, helper predicates, subagent tracking, trace protocol functions, and utilities.

**Constants:**
```bash
DECISION_LINE_THRESHOLD=50        # Lines before @decision is required
TEST_STALENESS_THRESHOLD=600      # 10 minutes — stale test status is ignored
SESSION_STALENESS_THRESHOLD=1800  # 30 minutes
SOURCE_EXTENSIONS='ts|tsx|js|jsx|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php|sh|bash|zsh'
TRACE_STORE="$HOME/.claude/traces"
```

**State-reading functions:**
- `get_git_state <root>` → `GIT_BRANCH`, `GIT_DIRTY_COUNT`, `GIT_WORKTREES`, `GIT_WT_COUNT`
- `get_plan_status <root>` → `PLAN_EXISTS`, `PLAN_PHASE`, `PLAN_TOTAL_PHASES`, `PLAN_COMPLETED_PHASES`, `PLAN_SOURCE_CHURN_PCT`, `PLAN_LIFECYCLE` (none/active/dormant), `PLAN_ACTIVE_INITIATIVES` (count), `PLAN_TOTAL_INITIATIVES` (count). Living-document format detected by `### Initiative:` headers. Dormant = plan exists but no active initiatives remain — add a new initiative, not a new plan.
- `get_session_changes <root>` → `SESSION_CHANGED_COUNT`
- `get_drift_data <root>` → `DRIFT_UNPLANNED_COUNT`, `DRIFT_UNIMPLEMENTED_COUNT`, `DRIFT_LAST_AUDIT_EPOCH`
- `get_research_status <root>` → `RESEARCH_EXISTS`, `RESEARCH_ENTRY_COUNT`, `RESEARCH_RECENT_TOPICS`
- `read_test_status <root>` → `TEST_RESULT`, `TEST_FAILS`, `TEST_TIME`, `TEST_AGE`

**Helper predicates:**
- `is_source_file <file>` — checks extension against SOURCE_EXTENSIONS
- `is_skippable_path <file>` — checks for test, config, vendor, build directories
- `is_test_file <file>` — checks for .test., .spec., __tests__, _test.go, test_*.py, /tests/
- `is_claude_meta_repo <root>` — returns true if root is ~/.claude (meta-infrastructure)
- `validate_state_file <file> <field_count>` — guards corrupt/empty file reads

**State-writing functions:**
- `write_statusline_cache <root>` — writes JSON to `.statusline-cache` (atomic)
- `atomic_write <target> <content>` — temp-file-then-mv for POSIX-safe atomic writes
- `safe_cleanup <target> <fallback>` — cd-out-first before deletion to prevent CWD death
- `archive_plan <root>` — moves MASTER_PLAN.md to archived-plans/ with date prefix. **Deprecated for living-document format** — use `compress_initiative()` instead, which preserves the plan.
- `compress_initiative <root> <initiative_name>` — moves a completed initiative from `## Active Initiatives` to `## Completed Initiatives` as a table row (~5 lines). Keeps the plan growing in place. Use after Guardian confirms all phases in the initiative are done.
- `append_audit <root> <event> <detail>` — appends to `.audit-log`
- `append_session_event <event> <json> <root>` — appends to `.session-events.jsonl`

**Subagent tracking:**
- `track_subagent_start <root> <type>` — appends `ACTIVE|<type>|<epoch>` to tracker
- `track_subagent_stop <root> <type>` — converts oldest matching ACTIVE to `DONE|<type>|<start>|<duration>`
- `get_subagent_status <root>` → `SUBAGENT_ACTIVE_COUNT`, `SUBAGENT_ACTIVE_TYPES`, `SUBAGENT_TOTAL_COUNT`

**Trace protocol:**
- `init_trace <root> <agent_type>` — creates trace directory + manifest + active marker
- `detect_active_trace <root> <agent_type>` — finds trace_id for current session
- `finalize_trace <trace_id> <root> <agent_type>` — updates manifest with outcome, duration, files changed
- `index_trace <trace_id>` — appends to `traces/index.jsonl`

**Churn cache:** `get_plan_status` caches expensive git calculations in
`.claude/.plan-churn-cache` keyed on `HEAD_SHORT|plan_mod_epoch`. Cache format:
`HEAD_SHORT|plan_mod|commits_since|churn_pct|changed_files|total_files`.

---

## 13. State File Registry

Complete table of every persistent state file. All paths are relative to the
project root unless marked as `~/.claude/` (global).

| File | Location | Format | Written by | Read by | Purpose |
|------|----------|--------|------------|---------|---------|
| `.test-status` | `.claude/` | `result\|fail_count\|epoch` | test-runner.sh | guard.sh, test-gate.sh, session-init.sh | Gate commits; block source writes while failing |
| `.proof-status` | `.claude/` | `status\|epoch` | task-track.sh (create), prompt-submit.sh (verify), check-tester.sh (auto-verify) | guard.sh, task-track.sh, check-tester.sh | Verification gate — must be `verified` to commit |
| `.session-changes-<ID>` | `.claude/` | One path per line | track.sh, checkpoint.sh | check-implementer.sh, surface.sh, check-guardian.sh | Track modified files per session |
| `.session-events.jsonl` | `.claude/` | JSONL (one event per line) | track.sh, skill-result.sh, session-init.sh | test-gate.sh (trajectory), session-end.sh | Session trajectory for diagnosis |
| `.audit-log` | `.claude/` | `ISO8601\|event\|detail` per line | context-lib.sh `append_audit()` | (human review) | Persistent audit trail of all gate events |
| `.agent-findings` | `.claude/` | `agent\|issue;issue` per line | check-implementer.sh, check-planner.sh | session-init.sh, prompt-submit.sh | Surface validation issues to next prompt |
| `.statusline-cache` | `.claude/` | JSON | context-lib.sh `write_statusline_cache()` | statusline.sh | Status bar enrichment without re-computation |
| `.subagent-tracker-<ID>` | `.claude/` | `ACTIVE\|type\|epoch` / `DONE\|type\|start\|duration` per line | context-lib.sh track_subagent_*() | statusline.sh (via get_subagent_status) | Real-time agent activity display |
| `.plan-drift` | `.claude/` | `key=value` per line | surface.sh | plan-check.sh | Decision drift data for staleness detection |
| `.plan-churn-cache` | `.claude/` | `HEAD\|mod\|commits\|churn%\|changed\|total` | context-lib.sh get_plan_status() | context-lib.sh get_plan_status() | Cache git churn calculations (keyed on HEAD+plan_mod) |
| `.test-gate-strikes` | `.claude/` | `strike_count\|epoch` | test-gate.sh | test-gate.sh | Escalating test gate counter |
| `.mock-gate-strikes` | `.claude/` | `strike_count\|epoch` | mock-gate.sh | mock-gate.sh | Escalating mock gate counter |
| `.checkpoint-counter` | `.claude/` | Integer | checkpoint.sh | checkpoint.sh | Write counter for threshold-based checkpoints |
| `.lint-cache` | `.claude/` | Linter name string | lint.sh | lint.sh | Cache linter detection result |
| `.lint-breaker` | `.claude/` | (exists or not) | lint.sh | lint.sh | Circuit breaker for lint retry loops |
| `.preserved-context` | `.claude/` | Text with `RESUME DIRECTIVE:` section | compact-preserve.sh | session-init.sh | Context snapshot before compaction (one-shot) |
| `.active-worktree-path` | `.claude/` | Absolute path (one line) | task-track.sh | log.sh `resolve_proof_file()` | Breadcrumb: which worktree is the active implementation target |
| `.update-status` | `~/.claude/` | `status\|local\|remote\|count\|epoch\|summary` | update-check.sh | session-init.sh | One-shot update notification (cleared after display) |
| `.worktree-roster.tsv` | `~/.claude/` | TSV: `path\|branch\|issue\|session\|pid\|created_at` | worktree-roster.sh | session-init.sh, statusline.sh | Worktree lifecycle tracking |
| `.cwd-recovery-needed` | `~/.claude/` | Deleted worktree path | guard.sh (Check 5/5b), check-guardian.sh | guard.sh (Check 0.5 Path B) | One-shot CWD recovery canary |
| `traces/index.jsonl` | `~/.claude/` | JSONL (one entry per trace) | context-lib.sh `index_trace()` | session-init.sh | Global trace index for cross-project searching |

---

## 14. Data Flow: Feature Request End-to-End

```
User: "Add email validation to the signup form"
   │
   ▼
[SessionStart: session-init.sh fires]
   │ Reads: MASTER_PLAN.md, git status, traces/index.jsonl
   │ Injects: "Git: branch=main | 3 dirty | Plan: Phase 2/5"
   │
   ▼
Orchestrator analyzes request
   │ Checks: MASTER_PLAN.md exists? Is this planned?
   │ Decision: Not in plan → dispatch to Planner
   │
   ▼
PLANNER AGENT (agents/planner.md, claude-opus-4-6, max_turns=40)
   │
   ├─ [SubagentStart: subagent-start.sh]
   │   Injects: git state, research log status, TRACE_DIR
   │
   ├─ Phase 1: Problem decomposition → REQ-P0-001, REQ-P1-001
   ├─ Phase 2: Architecture → selects validation library, worktree strategy
   ├─ Output: MASTER_PLAN.md + GitHub Issues #42
   │
   └─ [SubagentStop: check-planner.sh]
       Checks: MASTER_PLAN.md exists, issues created, @decision present
       Emits: additionalContext with findings
   │
   ▼
Orchestrator dispatches to Guardian for worktree setup
   │
   ▼
GUARDIAN AGENT (agents/guardian.md, claude-opus-4-6, max_turns=30)
   │
   ├─ git worktree add .worktrees/signup-validation -b feature/signup-validation
   └─ worktree-roster.sh register .worktrees/signup-validation --issue=42
   │
   ▼
Orchestrator dispatches to Implementer
   │ [PreToolUse:Task → task-track.sh fires]
   │   Gate C.1: Is branch main? No (worktree created) → allow
   │   Gate C.2: Writes ".proof-status = needs-verification"
   │   Gate C.3: Writes ".active-worktree-path" breadcrumb
   │
   ▼
IMPLEMENTER AGENT (agents/implementer.md, claude-sonnet-4-6, max_turns=75)
   │
   ├─ [SubagentStart: subagent-start.sh]
   │   Injects: worktree state, TRACE_DIR env var
   │
   ├─ Write failing tests
   │   [PreToolUse: test-gate.sh → no test status yet, allow]
   │   [PreToolUse: branch-guard.sh → not on main, allow]
   │   [PreToolUse: doc-gate.sh → test files exempt]
   │   [PostToolUse: track.sh → appends to .session-changes]
   │   [PostToolUse: test-runner.sh (async) → runs tests, writes .test-status = fail]
   │
   ├─ Implement feature
   │   [PreToolUse: test-gate.sh → .test-status = fail, strike 1 → advisory]
   │   [PreToolUse: doc-gate.sh → checks header + @decision]
   │   [PostToolUse: lint.sh → runs ruff/eslint, exit 2 if fails → retry]
   │
   ├─ Tests pass
   │   [PostToolUse: test-runner.sh (async) → writes .test-status = pass|0|epoch]
   │
   ├─ Add @decision DEC-SIGNUP-001 to validation.ts
   │
   ├─ Write TRACE_DIR/artifacts/{test-output.txt, diff.patch, files-changed.txt}
   │
   └─ [SubagentStop: check-implementer.sh]
       Check 1: branch != main → OK
       Check 2: validation.ts @decision present → OK
       Check 3: no unanswered approval question → OK
       Check 4: .test-status = pass → OK
       Check 5: trace artifacts present → OK
       Emits: "Implementer validation: OK"
   │
   ▼
Orchestrator dispatches to Tester
   │ [PreToolUse:Task → task-track.sh fires]
   │   Gate B: implementer trace no longer active → allow
   │
   ▼
TESTER AGENT (agents/tester.md, claude-sonnet-4-6, max_turns=25)
   │
   ├─ Reads implementer trace (TRACE_DIR/summary.md)
   ├─ Runs live verification: npm run dev, open browser, test validation
   ├─ Writes ".proof-status = pending|<epoch>" to worktree .claude/
   ├─ Presents: test pass screenshot, form validation demo
   │
   └─ [SubagentStop: check-tester.sh]
       Phase 1: reads .proof-status = pending
       Scans response for "AUTOVERIFY: CLEAN"
       Secondary check: High confidence? Full coverage? No non-env "Not tested"?
       → Auto-verify path: writes ".proof-status = verified"
       OR
       → Manual path: emits advisory, user must approve
   │
   ▼
User sees evidence, responds "lgtm"
   │ [UserPromptSubmit: prompt-submit.sh]
   │   Detects "lgtm" keyword
   │   Reads .proof-status = pending (via resolve_proof_file)
   │   Writes ".proof-status = verified|<epoch>"
   │   Dual-writes to orchestrator CLAUDE_DIR/.proof-status
   │
   ▼
Orchestrator dispatches to Guardian
   │ [PreToolUse:Task → task-track.sh Gate A]
   │   Reads .proof-status = verified → allow
   │
   ▼
GUARDIAN AGENT (agents/guardian.md, claude-opus-4-6, max_turns=30)
   │
   ├─ Presents: diff summary, commit message draft
   ├─ Awaits approval
   │
   ├─ git add src/validation.ts tests/validation.test.ts
   ├─ git commit -m "feat: add email validation to signup form"
   │   [PreToolUse:Bash → guard.sh Check 7: .test-status = pass → allow]
   │   [PreToolUse:Bash → guard.sh Check 8: .proof-status = verified → allow]
   │
   ├─ git checkout main && git merge feature/signup-validation
   │   [PreToolUse:Bash → guard.sh Check 6: .test-status = pass → allow]
   │
   ├─ git push origin main
   ├─ gh issue close 42
   │
   └─ safe_cleanup .worktrees/signup-validation "$PROJECT_ROOT"
       [check-guardian.sh: writes .cwd-recovery-needed canary]
   │
   ▼
[Stop: surface.sh, session-summary.sh, forward-motion.sh]
   │ surface.sh: validation.ts has @decision → OK; writes .plan-drift
   │ session-summary.sh: "12 files, 1 @decision, tests pass, verified"
   │ forward-motion.sh: "Consider implementing REQ-P0-002 next"
   │
[SessionEnd: session-end.sh]
   │ Cleans up .session-changes, .lint-cache, .test-gate-strikes
   │ Archives .session-events.jsonl
   │ Writes session index entry to traces/

Done. Feature merged to main.
```

---

## 15. Extension Points

### Adding a New Hook

1. Create `hooks/my-gate.sh` with shebang + documentation header.
2. Source the bootstrap: `source "$(dirname "$0")/source-lib.sh"`.
3. Read input: `HOOK_INPUT=$(read_input)`.
4. Implement logic; emit JSON response.
5. Register in `settings.json`:
   ```json
   {
     "matcher": "Write|Edit",
     "hooks": [{"type": "command", "command": "$HOME/.claude/hooks/my-gate.sh", "timeout": 5}]
   }
   ```
6. Write tests in `tests/fixtures/my-gate/` and a test script.

### Adding a New Agent

1. Create `agents/my-agent.md` with frontmatter (name, description, model, color).
2. Define phases, inputs, outputs.
3. Add SubagentStop validation in `hooks/check-my-agent.sh`.
4. Register SubagentStop hook in `settings.json`.
5. Update dispatch rules in `CLAUDE.md`.

### Adding State Files

1. Choose format: pipe-delimited (`status|field2|epoch`), JSON, or line-based.
2. Use `atomic_write()` from context-lib.sh for writes.
3. Use `validate_state_file()` before reads.
4. Add to `.gitignore`.
5. Document in this file's State File Registry.

---

## 16. Anti-Patterns

### Don't: Rely on instructions alone
**Problem:** Context window pressure at 100+ turns degrades instruction adherence.
**Solution:** Enforce via hooks. Instructions guide, hooks enforce unconditionally.

### Don't: Use /tmp/ for artifacts
**Problem:** Littering the system, hard to debug, survives crashes unexpectedly.
**Solution:** `project/tmp/` directory. guard.sh Check 1 rewrites automatically.

### Don't: Mock internal modules
**Problem:** Tests become brittle, verify the mock not the code.
**Solution:** Test real implementations. mock-gate.sh denies on strike 2.

### Don't: Work on main branch
**Problem:** Cannot rollback, no isolation, pollutes shared history.
**Solution:** git worktrees. branch-guard.sh blocks source writes. task-track.sh blocks implementer dispatch.

### Don't: Commit without tests
**Problem:** Regressions ship. Debugging time wasted.
**Solution:** test-gate.sh blocks source writes while failing. guard.sh Check 7 blocks commits.

### Don't: Self-approve verification
**Problem:** Agent cannot be both builder and judge. Conflicts of interest.
**Solution:** guard.sh Check 9 blocks agent writes to .proof-status. Only prompt-submit.sh (user) or check-tester.sh (auto-verify) can write `verified`.

### Don't: cd into a worktree from the orchestrator
**Problem:** If the worktree is deleted, posix_spawn ENOENT kills ALL subsequent hooks.
**Solution:** Use `git -C <path>` for git operations. guard.sh Check 0.75 denies chained cd-into-worktree commands.

### Don't: Track tasks in files
**Problem:** No timestamps, no mobile access, easy to lose, violates Sacred Practice #9.
**Solution:** GitHub Issues via `/backlog`. Durable, searchable, timestamped.

---

## 17. Decision Log

| Decision | File | Status | Summary |
|----------|------|--------|---------|
| DEC-GUARD-001 | guard.sh | accepted | Multi-tier command safety gate with transparent rewrites and fail-closed crash trap |
| DEC-GUARD-CWD-001 | guard.sh | accepted | Two-path CWD recovery: Path A (broken .cwd) and Path B (canary file) |
| DEC-GUARD-CWD-002 | guard.sh | accepted | Canary file as second CWD recovery detection path |
| DEC-GUARD-CWD-003 | guard.sh | accepted | Deny cd-into-worktree with chained commands; suggest subshell resubmit |
| DEC-GUARD-002 | guard.sh | accepted | Two-tier worktree CWD safety: git worktree remove + raw rm |
| DEC-GUARD-CHECK5-001 | guard.sh | accepted | Use extract_git_target_dir + git -C for worktree removal rewrite |
| DEC-INTEGRITY-001 | context-lib.sh | accepted | validate_state_file guards corrupt-file reads in guard.sh |
| DEC-INTEGRITY-002 | guard.sh | accepted | Deny-on-crash EXIT trap for fail-closed behavior |
| DEC-INTEGRITY-004 | context-lib.sh | accepted | Atomic write via temp-file-then-mv for state file safety |
| DEC-AUTOREVIEW-001 | auto-review.sh | accepted | Three-tier command classification with recursive analysis |
| DEC-MOCK-001 | mock-gate.sh | accepted | Escalating mock detection gate with external-boundary allowlist |
| DEC-TEST-001 | test-runner.sh | accepted | Automatic background test execution after source changes |
| DEC-CACHE-001 | context-lib.sh | accepted | Statusline cache for status bar enrichment without re-computation |
| DEC-CACHE-002 | statusline.sh | accepted | Status bar enrichment with cached hook data |
| DEC-CACHE-003 | task-track.sh | accepted | PreToolUse:Task as SubagentStart replacement |
| DEC-SUBAGENT-001 | context-lib.sh | accepted | Subagent lifecycle tracking via state file |
| DEC-SUBAGENT-002 | context-lib.sh | accepted | Session-scoped subagent tracker files (prevents phantom counts) |
| DEC-COMPACT-001 | prompt-submit.sh | accepted | First-prompt fallback for session-init bug (#10373) |
| DEC-UPDATE-001 | update-check.sh | accepted | Git-based auto-update with breaking change detection |
| DEC-UPDATE-BG-001 | session-init.sh | accepted | Background update-check with previous-session result display |
| DEC-UPDATE-BG-002 | session-init.sh | accepted | Background update-check: display result in next session |
| DEC-LOG-001 | log.sh | accepted | Shared logging and path utilities for all hooks |
| DEC-PROOF-PATH-002 | log.sh | accepted | resolve_proof_file: breadcrumb-based worktree proof-status resolution |
| DEC-QUICKFIX-001 | log.sh | accepted | Fix double-nested paths when PROJECT_ROOT is ~/.claude |
| DEC-SRCLIB-001 | source-lib.sh | accepted | Direct hook library sourcing (replaces session-scoped caching) |
| DEC-TASK-GATE-001 | task-track.sh | accepted | Block implementer dispatch on main/master branch |
| DEC-CHURN-CACHE-001 | context-lib.sh | accepted | Cache plan churn calculation keyed on HEAD+plan_mod |
| DEC-TESTER-001 | check-tester.sh | accepted | Tester SubagentStop with auto-verify for clean e2e verifications |
| DEC-IMPL-STOP-001 | check-implementer.sh | accepted | Implementer SubagentStop without proof-of-work check (moved to tester) |
| DEC-V2-002 | checkpoint.sh | accepted | Git ref-based checkpoints via plumbing commands |
| DEC-WORKTREE-001 | worktree-roster.sh | accepted | Worktree lifecycle tracking via TSV registry |
| DEC-PROMPT-001 | prompt-submit.sh | accepted | User verification gate and dynamic context injection |
| DEC-OBS-018 | context-lib.sh | accepted | Normalize agent_type in init_trace |
| DEC-OBS-019 | context-lib.sh | accepted | Distinguish no-git from branch capture failures in traces |
| DEC-OBS-020 | context-lib.sh | accepted | Age-based cleanup of orphaned .active-* markers |
| DEC-OBS-DURATION-001 | context-lib.sh | accepted | Use date -u +%s for UTC-consistent duration calculation |
| DEC-OBS-OUTCOME-001 | context-lib.sh | accepted | Expand outcome classification with timeout and skipped states |
| DEC-OBS-SUG002 | context-lib.sh | accepted | Add .test-status fallback to finalize_trace |
| DEC-OBS-SUG003 | context-lib.sh | accepted | Add git diff fallback to finalize_trace files_changed count |

---

## 18. Glossary

**Sacred Practices:** Ten core principles enforced mechanically by hooks. Main is
Sacred, Nothing Done Until Tested, No /tmp/, etc.

**Worktree:** Isolated git working directory. Feature work happens in
`.worktrees/feature-name`. Main stays clean and deployable.

**@decision:** Annotation format for documenting significant implementation choices.
Required for 50+ line files. Format: `@decision DEC-COMPONENT-NNN`, `@title`,
`@status`, `@rationale`.

**Proof-of-work:** Verification that the feature works live (not just tests passing).
The tester agent collects evidence. Only prompt-submit.sh (user) or check-tester.sh
(auto-verify) can write `verified` status.

**Test status gate:** guard.sh Checks 7-8. Commits and merges blocked when
`.test-status != pass` or `.proof-status != verified`.

**Transparent rewrite:** guard.sh's `rewrite()` function emits `updatedInput` output,
but `updatedInput` is NOT supported in PreToolUse hooks (silently fails — see upstream
issue anthropics/claude-code#26506). All enforcement uses `deny()` with the corrected
command in the reason message so the model can resubmit safely.

**Fail-closed:** If guard.sh crashes, the EXIT trap denies the command (not allows).
Safety is preserved even under error conditions.

**State file:** Persistence mechanism for hook-to-hook communication. Stored in
`.claude/`. Atomic writes prevent race conditions.

**Phase boundary:** Completion of a major MASTER_PLAN.md phase. Triggers plan
status update and Decision Log population.

**Claude scratchpad:** `/private/tmp/claude-*/` directories. Exempt from /tmp/
rewrite rule (guard.sh Check 1) because Claude Code uses them internally.

**Meta-repo:** The `~/.claude` configuration repository itself. Exempt from test
gates, proof-of-work requirements, and branch-guard (source writes on main allowed
for small config fixes).

**Session acclimation:** The pattern by which session-init.sh and prompt-submit.sh
inject fresh project context so Claude orients quickly regardless of prior context.

**Canary file:** `.claude/.cwd-recovery-needed` — a one-shot signal written before
worktree deletion so guard.sh Check 0.5 can recover the orchestrator's CWD on the
next Bash command.

**TRACE_DIR:** Environment variable injected by subagent-start.sh into agent context.
Points to the agent's trace directory (`~/.claude/traces/<trace_id>`). Agents write
`summary.md` and `artifacts/` here.

**Auto-verify:** check-tester.sh path that bypasses manual approval when the tester
signals `AUTOVERIFY: CLEAN` with High confidence and full coverage. Writes `verified`
directly so Guardian can commit without waiting for user.

**Flywheel:** The observatory's self-improvement loop: analyze traces → propose
improvement → implement → richer traces → better analysis → repeat.

---

**Last updated:** 2026-02-18
**Maintainers:** See CLAUDE.md Cornerstone Belief — Future Implementers rely on this doc
