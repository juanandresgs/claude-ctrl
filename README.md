# The Systems Thinker's Vibecoding Starter Kit

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/juanandresgs/claude-system)](https://github.com/juanandresgs/claude-system/stargazers)
[![Last commit](https://img.shields.io/github/last-commit/juanandresgs/claude-system)](https://github.com/juanandresgs/claude-system/commits/main)
[![Shell](https://img.shields.io/badge/language-bash-green.svg)](hooks/)

JAGS' batteries-included Claude Code config

Claude Code out of the box is capable but undisciplined. It commits directly to main. It skips tests. It starts implementing before understanding the problem. It force-pushes without thinking. None of these are bugs — they're defaults.

This system replaces those defaults with mechanical enforcement. Three specialized agents divide the work — Planner, Implementer, Guardian — so no single context handles planning, implementation, and git operations. Twenty-four hooks run deterministically at every lifecycle event. They don't depend on the model remembering instructions. They execute regardless of context window pressure.

**Instructions guide. Hooks enforce.**

---

## What This Looks Like

No configuration. No hoping the model remembers. Just mechanical enforcement.

#### Dangerous paths get silently rewritten

```
You:      echo 'test' > /tmp/scratch.txt
guard.sh: REWRITE → mkdir -p tmp && echo 'test' > tmp/scratch.txt
```
> `/tmp/` is forbidden. Transparently rewritten to project `tmp/`.

#### Force push becomes force-with-lease

```
You:      git push --force origin feature
guard.sh: REWRITE → git push --force-with-lease origin feature
```
> `--force` rewritten to `--force-with-lease`. Your reflog says thanks.

#### Main branch is protected at every level

```
You:      git commit -m "quick fix"     # on main branch
guard.sh: DENY — Cannot commit on main. Sacred Practice #2.
```
> Use Guardian agent to create an isolated worktree.

#### Tests must pass before you can keep writing

```
You:           [writes src/auth.ts]     # tests are failing
test-gate.sh:  WARNING — Tests failing. Strike 1 of 2.

               [writes again]
test-gate.sh:  DENY — Tests still failing. Fix tests before continuing.
```

#### No code without a plan

```
You:            [writes src/auth.ts]    # no MASTER_PLAN.md exists
plan-check.sh:  DENY — No plan found. Sacred Practice #6.
```
> Invoke Planner agent first.

Every check runs deterministically via hooks — not instructions that degrade with context pressure.

---

## The Opinions

This system is opinionated. That's the point. Every opinion has a hook that enforces it.

- **Plans before code.** `plan-check.sh` denies source writes without a MASTER_PLAN.md.
- **Main is never touched.** `branch-guard.sh` blocks writes on main. `guard.sh` blocks commits on main.
- **Tests pass first.** `test-gate.sh` warns on the first write with failing tests, blocks on the second. `guard.sh` requires test evidence for commits.
- **Real tests, not mocks.** `mock-gate.sh` detects internal mocking patterns — warns first, blocks on repeat.
- **Decisions live in code.** `doc-gate.sh` enforces headers and `@decision` annotations on files over 50 lines.
- **Approval gates on permanent operations.** `guard.sh` blocks force push. Guardian agent requires approval for all commits and merges.

If you disagree with an opinion, change the hook that enforces it.

---

## What Makes This Different

Most Claude Code configurations rely on indeterministic instructions in CLAUDE.md — guidance that works well in the beginning but degrades as the context window fills up or compaction throws us off a cliff. This system puts enforcement in **deterministic hooks**: shell scripts that run before and after events, regardless of context fatigue and whose outputs persist beyond session clearing.

| Capability | How It's Enforced |
|---|---|
| **Plan-first development** | `plan-check.sh` hard-denies source writes without MASTER_PLAN.md |
| **Branch protection** | `branch-guard.sh` blocks source writes on main at the tool level, not just at commit time |
| **Test gating** | `test-gate.sh` escalates (warn → block); `guard.sh` requires test evidence for commits |
| **Mock discipline** | `mock-gate.sh` detects internal mocks, warns first, blocks on repeat |
| **Safe rewrites** | `guard.sh` transparently rewrites `/tmp/` → project `tmp/`, `--force` → `--force-with-lease` |
| **Decision tracking** | `doc-gate.sh` enforces @decision annotations; `surface.sh` audits coverage |
| **Agent separation** | Planner, Implementer, Guardian — each owns a phase, none overlap |
| **Session continuity** | Context injected at start, preserved at compaction, summarized at end |

---

## How It Works

```
┌────────────────────────────────────────────────────────────────────┐
│  The model doesn't decide the workflow. The hooks do.              │
│  Plan first. Segment and isolate. Test everything. Get approval.   │
└────────────────────────────────────────────────────────────────────┘
```

### Agent Workflow

```
                    ┌──────────┐
                    │   User   │
                    └────┬─────┘
                         │ requirement
                         ▼
                  ┌──────────────┐
                  │   Planner    │──── MASTER_PLAN.md + GitHub Issues
                  │  (opus)      │
                  └──────┬───────┘
                         │ approved plan
                         ▼
                  ┌──────────────┐
                  │   Guardian   │──── git worktree create
                  │  (opus)      │
                  └──────┬───────┘
                         │ isolated branch
                         ▼
                  ┌──────────────┐
                  │ Implementer  │──── tests + code + @decision
                  │  (sonnet)    │
                  └──────┬───────┘
                         │ verified feature
                         ▼
                  ┌──────────────┐
                  │   Guardian   │──── commit + merge + plan update
                  │  (opus)      │
                  └──────┬───────┘
                         │ approval gate
                         ▼
                    ┌──────────┐
                    │   Main   │ ← clean, tested, annotated
                    └──────────┘
```

| Agent | Model | Role | Key Output |
|-------|-------|------|------------|
| **Planner** | Opus | Requirements analysis, architecture design, research gate | MASTER_PLAN.md, GitHub Issues, research log |
| **Implementer** | Sonnet | Test-first coding in isolated worktrees | Working code, tests, @decision annotations |
| **Guardian** | Opus | Git operations, merge analysis, plan evolution | Commits, merges, phase reviews, plan updates |

The orchestrator dispatches to agents but never writes source code itself. Planning goes to Planner. Implementation goes to Implementer. Git operations go to Guardian. The orchestrator reads code and coordinates — that's it.

Each agent handles its own approval cycle: present the work, wait for approval, execute, verify, suggest next steps. They don't end conversations with unanswered questions.

---

## Sacred Practices

These are non-negotiable. Each one is enforced by hooks that run every time, regardless of context window state or model behavior. They are not suggestions.

| # | Practice | What Enforces It |
|---|----------|-------------|
| 1 | **Always Use Git** | `session-init.sh` injects git state; `guard.sh` blocks destructive operations |
| 2 | **Main is Sacred** | `branch-guard.sh` blocks writes on main; `guard.sh` blocks commits on main |
| 3 | **No /tmp/** | `guard.sh` rewrites `/tmp/` paths to project `tmp/` directory |
| 4 | **Nothing Done Until Tested** | `test-gate.sh` warns then blocks source writes when tests fail (escalating); `guard.sh` requires test evidence for commits |
| 5 | **Solid Foundations** | `mock-gate.sh` detects and escalates internal mocking (warn → deny) |
| 6 | **No Implementation Without Plan** | `plan-check.sh` denies source writes without MASTER_PLAN.md |
| 7 | **Code is Truth** | `doc-gate.sh` enforces headers and @decision on 50+ line files |
| 8 | **Approval Gates** | `guard.sh` blocks force push; Guardian agent requires approval for all permanent ops |
| 9 | **Track in Issues** | `plan-validate.sh` checks alignment; `check-planner.sh` validates issue creation |

---

## Hook System

All hooks are registered in `settings.json` and run deterministically — JSON in on stdin, JSON out on stdout. For the full protocol (deny/rewrite/advisory responses, stop hook schema, shared library APIs), see [`hooks/HOOKS.md`](hooks/HOOKS.md).

### Hook Execution Flow

```
Session Start ──► session-init.sh (git state, plan status, worktrees)
       │
       ▼
User Prompt ────► prompt-submit.sh (context injection per prompt)
       │
       ▼
Pre Tool Use ───► [Bash] guard.sh ◄── /tmp rewrite, main protect,
       │                                force-with-lease, test evidence
       │                auto-review.sh ◄── intelligent command auto-approval
       │         [Write|Edit] test-gate.sh → mock-gate.sh →
       │                      branch-guard.sh → doc-gate.sh →
       │                      plan-check.sh
       │
       ▼
 [Tool Executes]
       │
       ▼
Post Tool Use ──► [Write|Edit] lint.sh → track.sh → code-review.sh →
       │                       plan-validate.sh → test-runner.sh (async)
       │
       ▼
Subagent Start ─► subagent-start.sh (agent-specific context)
Subagent Stop ──► check-planner.sh | check-implementer.sh |
       │          check-guardian.sh
       │
       │  (async) ─► notify.sh (desktop alert on permission/idle)
       │
       ▼
Stop ───────────► surface.sh (decision audit) → session-summary.sh →
       │          forward-motion.sh
       │
       ▼
Pre Compact ────► compact-preserve.sh (context preservation)
       │
       ▼
Session End ────► session-end.sh (cleanup)
```

Hooks within the same event run sequentially in array order. A deny from any PreToolUse hook stops the tool call — later hooks in the chain don't execute.

### PreToolUse — Block Before Execution

| Hook | Matcher | What It Does |
|------|---------|--------------|
| **guard.sh** | Bash | 8 checks: rewrites `/tmp/` paths, `--force` → `--force-with-lease`, worktree CWD safety; blocks commits on main, force push to main, destructive git (`reset --hard`, `clean -f`, `branch -D`); requires test evidence + proof-of-work verification for commits and merges |
| **auto-review.sh** | Bash | Three-tier command classifier: auto-approves safe commands, defers risky ones to user |
| **test-gate.sh** | Write\|Edit | Escalating gate: warns on first source write with failing tests, blocks on repeat |
| **mock-gate.sh** | Write\|Edit | Detects internal mocking patterns; warns first, blocks on repeat |
| **branch-guard.sh** | Write\|Edit | Blocks source file writes on main/master branch |
| **doc-gate.sh** | Write\|Edit | Enforces file headers and @decision annotations on 50+ line files; Write = hard deny, Edit = advisory; warns on new root-level markdown files (Sacred Practice #9) |
| **plan-check.sh** | Write\|Edit | Denies source writes without MASTER_PLAN.md; composite staleness scoring (source churn % + decision drift) warns then blocks when plan diverges from code; bypasses Edit tool, small writes (<20 lines), non-git dirs |

### PostToolUse — Feedback After Execution

| Hook | Matcher | What It Does |
|------|---------|--------------|
| **lint.sh** | Write\|Edit | Auto-detects project linter (ruff, black, prettier, eslint, etc.), runs on modified files. Exit 2 = feedback loop (Claude retries the fix automatically) |
| **track.sh** | Write\|Edit | Records file changes to `.session-changes-$SESSION_ID`. Also invalidates `.proof-status` when verified source files change — ensuring the user always verifies the final state, not an intermediate one |
| **code-review.sh** | Write\|Edit | Fires on 20+ line source files (skips tests and config). Injects diff context and suggests `mcp__multi__codereview` for multi-model analysis. Falls back silently if Multi-MCP is unavailable |
| **plan-validate.sh** | Write\|Edit | Validates MASTER_PLAN.md structure on every write: phase Status fields (`planned`/`in-progress`/`completed`), Decision Log content for completed phases, original intent section preserved, DEC-COMPONENT-NNN ID format. Exit 2 = feedback loop with fix instructions |
| **test-runner.sh** | Write\|Edit | **Async** — doesn't block Claude. Auto-detects test framework (pytest, vitest, jest, npm-test, cargo-test, go-test). 2s debounce lets rapid writes settle. 10s cooldown between runs. Lock file ensures single instance (kills previous run if superseded). Writes `.test-status` (`pass\|0\|timestamp` or `fail\|count\|timestamp`) consumed by test-gate.sh and guard.sh. Reports results via `systemMessage` |

### Session Lifecycle

| Hook | Event | What It Does |
|------|-------|--------------|
| **session-init.sh** | SessionStart | Injects git state, MASTER_PLAN.md status, active worktrees, todo HUD, unresolved agent findings, preserved context from pre-compaction. Clears stale `.test-status` from previous sessions (prevents old passes from satisfying the commit gate). Resets prompt count for first-prompt fallback. Known: SessionStart has a bug ([#10373](https://github.com/anthropics/claude-code/issues/10373)) where output may not inject for brand-new sessions — works for `/clear`, `/compact`, resume |
| **prompt-submit.sh** | UserPromptSubmit | First-prompt mitigation for SessionStart bug: on the first prompt of any session, injects full session context (same as session-init.sh) as a reliability fallback. On subsequent prompts: keyword-based context injection — file references trigger @decision status, "plan"/"implement" trigger MASTER_PLAN phase status, "merge"/"commit" trigger git dirty state. Also: auto-claims issue refs ("fix #42"), detects deferred-work language ("later", "eventually") and suggests `/backlog`, flags large multi-step tasks for scope confirmation |
| **compact-preserve.sh** | PreCompact | Dual output: (1) persistent `.preserved-context` file that survives compaction and is re-injected by session-init.sh, and (2) `additionalContext` including a compaction directive instructing the model to generate a structured context summary (objective, active files, constraints, continuity handoff). Captures git state, plan status, session changes, @decision annotations, test status, agent findings, and audit trail |
| **session-end.sh** | SessionEnd | Kills lingering async test-runner processes, releases todo claims for this session, cleans session-scoped files (`.session-changes-*`, `.prompt-count-*`, `.lint-cache`, strike counters). Preserves cross-session state (`.audit-log`, `.agent-findings`, `.plan-drift`). Trims audit log to last 100 entries |
| **surface.sh** | Stop | Full decision audit pipeline: (1) extract — scans project source directories for @decision annotations using ripgrep (with grep fallback); (2) validate — checks changed files over 50 lines for @decision presence and rationale; (3) reconcile — compares DEC-IDs in MASTER_PLAN.md vs code, identifies unplanned decisions (in code but not plan) and unimplemented decisions (in plan but not code), respects deprecated/superseded status; (4) persist — writes structured drift data to `.plan-drift` for consumption by plan-check.sh next session. Reports via `systemMessage` |
| **session-summary.sh** | Stop | Deterministic (<2s runtime). Counts unique files changed (source vs config), @decision annotations added. Reports git branch, dirty/clean state, test status (waits briefly for in-flight async test-runner). Generates workflow-aware next-action guidance: on main → "create plan" or "create worktrees"; on feature branch → "fix tests", "run tests", "review changes", or "merge to main" based on current state. Includes pending todo count |
| **forward-motion.sh** | Stop | Deterministic regex check (not AI). Extracts the last paragraph of the assistant's response and checks for forward motion indicators: `?`, "want me to", "shall I", "let me know", "would you like", "next step", etc. Returns exit 2 (feedback loop) only if the response ends with a bare completion statement ("done", "finished", "all set") and no question mark — prompting the model to add a suggestion or offer |

### Notifications

| Hook | Matcher | What It Does |
|------|---------|--------------|
| **notify.sh** | permission_prompt\|idle_prompt | Desktop notification when Claude needs attention (macOS only). Uses `terminal-notifier` (activates terminal on click) with `osascript` fallback. Sound varies by urgency: `Ping` for permission prompts, `Glass` for idle prompts |

### Subagent Lifecycle

| Hook | Event / Matcher | What It Does |
|------|-----------------|--------------|
| **subagent-start.sh** | SubagentStart | Injects git state + plan status into every subagent. Agent-type-specific guidance: **Implementer** gets worktree creation warning (if none exist), test status, verification protocol instructions. **Guardian** gets plan update rules (only at phase boundaries) and test status. **Planner** gets research log status. Lightweight agents (Bash, Explore) get minimal context |
| **check-planner.sh** | SubagentStop (planner\|Plan) | 5 checks: (1) MASTER_PLAN.md exists, (2) has `## Phase N` headers, (3) has intent/vision section, (4) has issues/tasks, (5) approval-loop detection (agent ended with question but no plan completion confirmation). Advisory only — always exit 0. Persists findings to `.agent-findings` for next-prompt injection |
| **check-implementer.sh** | SubagentStop (implementer) | 5 checks: (1) current branch is not main/master (worktree was used), (2) @decision coverage on 50+ line source files changed this session, (3) approval-loop detection, (4) test status verification (recent failures = "implementation not complete"), (5) proof-of-work status (`verified`/`pending`/missing). Advisory only. Persists findings |
| **check-guardian.sh** | SubagentStop (guardian) | 5 checks: (1) MASTER_PLAN.md freshness — only for phase-completing merges, must be updated within 300s, (2) git status is clean (no uncommitted changes), (3) branch info for context, (4) approval-loop detection, (5) test status for git operations (CRITICAL if tests failing when merge/commit detected). Advisory only. Persists findings |

### Shared Libraries

| File | Exports |
|------|---------|
| **log.sh** | `read_input` — reads and caches stdin JSON (prevents double-read). `get_field` — jq extraction from cached input. `log_json`/`log_info` — stderr logging (doesn't interfere with hook JSON output). `detect_project_root` — resolution chain: `CLAUDE_PROJECT_DIR` → git root → `$HOME` fallback |
| **context-lib.sh** | `get_git_state` — populates `GIT_BRANCH`, `GIT_DIRTY_COUNT`, `GIT_WORKTREES`, `GIT_WT_COUNT`. `get_plan_status` — populates `PLAN_EXISTS`, `PLAN_PHASE`, `PLAN_TOTAL_PHASES`, `PLAN_COMPLETED_PHASES`, `PLAN_AGE_DAYS`, `PLAN_SOURCE_CHURN_PCT`. `get_session_changes` — file count for current session. `get_drift_data` — reads `.plan-drift` file from last surface audit. `get_research_status` — research log entry count and recent topics. `is_source_file`/`is_skippable_path` — extension matching and directory filtering. `append_audit` — timestamped audit trail. `SOURCE_EXTENSIONS` — single source of truth for source file extensions across all hooks |

### Key guard.sh Behaviors

The most complex hook — 8 checks covering 3 rewrites, 3 hard blocks, and 2 evidence gates.

**Transparent rewrites** (model's command silently replaced with safe alternative):

| Check | Trigger | Rewrite |
|-------|---------|---------|
| 1 | `/tmp/` or `/private/tmp/` write | → project `tmp/` directory (macOS symlink-aware; exempts Claude scratchpad) |
| 3 | `git push --force` (not to main) | → `--force-with-lease` |
| 5 | `git worktree remove` | → prepends `cd` to main worktree (prevents CWD death spiral) |

**Hard blocks** (deny with explanation):

| Check | Trigger | Why |
|-------|---------|-----|
| 2 | `git commit` on main/master | Sacred Practice #2 (exempts `~/.claude` meta-repo and MASTER_PLAN.md-only commits) |
| 3 | `git push --force` to main/master | Destructive to shared history |
| 4 | `git reset --hard`, `git clean -f`, `git branch -D` | Destructive operations — suggests safe alternatives |

**Evidence gates** (require proof before commit/merge):

| Check | Requires | State File | Exemption |
|-------|----------|------------|-----------|
| 6-7 | `.test-status` = `pass` | `.claude/.test-status` (format: `result\|fail_count\|timestamp`) | `~/.claude` meta-repo (no test framework by design) |
| 8 | `.proof-status` = `verified` | `.claude/.proof-status` (format: `status\|timestamp`) | `~/.claude` meta-repo |

Test evidence: only `pass` satisfies the gate. Any non-pass status (`fail` of any age, unknown, missing file) = denied. Recent failures (< 10 min) get a specific error message with failure count; older failures get a generic "did not pass" message.

Proof-of-work: the user must see the feature work before code is committed. `track.sh` resets proof status to `pending` when source files change after verification — ensuring the user always verifies the final state.

### Key plan-check.sh Behaviors

Beyond checking for MASTER_PLAN.md existence, this hook scores plan staleness using two signals:

| Signal | What It Measures | Warn Threshold | Deny Threshold |
|--------|-----------------|----------------|----------------|
| **Source churn %** | Percentage of tracked source files changed since plan update | 15% | 35% |
| **Decision drift** | Count of unplanned + unimplemented @decision IDs (from `surface.sh` audit) | 2 IDs | 5 IDs |

The composite score takes the worst tier across both signals. If either hits deny threshold, writes are blocked until the plan is updated. This is self-normalizing — a 3-file project and a 300-file project both trigger at the same percentage.

**Bypasses:** Edit tool (inherently scoped), Write under 20 lines (trivial), non-source files, test files, non-git directories, `~/.claude` meta-infrastructure.

### Key auto-review.sh Behaviors

An 840-line policy engine that replaces the blunt "allow or ask" permission model with intelligent classification:

| Tier | Behavior | How It Decides |
|------|----------|---------------|
| **1 — Safe** | Auto-approve | Command is inherently read-only: `ls`, `cat`, `grep`, `cd`, `echo`, `sort`, `wc`, `date`, etc. |
| **2 — Behavior-dependent** | Analyze subcommand + flags | `git status` ✅ auto-approve; `git rebase` ⚠️ advisory. Compound commands (`&&`, `\|\|`, `;`, `\|`) decomposed — every segment must be safe |
| **3 — Always risky** | Advisory context → defer to user | `rm`, `sudo`, `kill`, `ssh`, `eval`, `bash -c` — risk reason injected so the permission prompt explains *why* |

**Recursive analysis:** Command substitutions (`$()` and backticks) are analyzed to depth 2. `cd $(git rev-parse --show-toplevel)` auto-approves because both `cd` (Tier 1) and `git rev-parse` (Tier 2 → read-only) are safe.

**Dangerous flag escalation:** `--force`, `--hard`, `--no-verify`, `-f` (on git) escalate any command to risky regardless of tier.

**Interaction with guard.sh:** Guard runs first (sequential in settings.json). If guard denies, auto-review never executes. If guard allows/passes through, auto-review classifies. This means guard handles the hard security boundaries, auto-review handles the UX of permission prompts.

### Enforcement Patterns

Three patterns recur across the hook system:

**Escalating gates** — warn on first offense, block on repeat. Used when the model may have a legitimate reason to proceed once, but repeat violations indicate a broken workflow.

| Hook | Strike File | Warn | Block |
|------|------------|------|-------|
| **test-gate.sh** | `.test-gate-strikes` | First source write with failing tests | Second source write without fixing tests |
| **mock-gate.sh** | `.mock-gate-strikes` | First internal mock detected | Second internal mock (external boundary mocks always allowed) |

**Feedback loops** — exit code 2 tells Claude Code to retry the operation with the hook's output as guidance, rather than failing outright. The model gets a chance to fix the issue automatically.

| Hook | Triggers exit 2 when |
|------|---------------------|
| **lint.sh** | Linter finds fixable issues in the written file |
| **plan-validate.sh** | MASTER_PLAN.md fails structural validation (missing Status fields, empty Decision Log, bad DEC-ID format) |
| **forward-motion.sh** | Response ends with bare completion ("done") and no question, suggestion, or offer |

**Transparent rewrites** — the model's command is silently replaced with a safe alternative. No denial, no feedback — the model doesn't even know the command was changed.

| Hook | Rewrites |
|------|----------|
| **guard.sh** | `/tmp/` → project `tmp/`, `--force` → `--force-with-lease`, `worktree remove` → prepends safe `cd` |

### State Files

Hooks communicate across events through state files in the project's `.claude/` directory. This is the backbone that connects async test execution to commit-time evidence gates, session tracking to end-of-session audits, and compaction preservation to next-session context injection.

**Session-scoped** (cleaned up by session-end.sh):

| File | Written By | Read By | Contents |
|------|-----------|---------|----------|
| `.session-changes-$ID` | track.sh | surface.sh, session-summary.sh, check-implementer.sh, compact-preserve.sh | One file path per line — every Write/Edit this session |
| `.prompt-count-$ID` | prompt-submit.sh | prompt-submit.sh | Tracks whether first-prompt mitigation has fired |
| `.test-gate-strikes` | test-gate.sh | test-gate.sh | Strike count for escalating enforcement |
| `.mock-gate-strikes` | mock-gate.sh | mock-gate.sh | Strike count for escalating enforcement |
| `.test-runner.lock` | test-runner.sh | test-runner.sh | PID of active test process (prevents concurrent runs) |
| `.test-runner.last-run` | test-runner.sh | test-runner.sh | Epoch timestamp of last run (10s cooldown) |

**Cross-session** (preserved by session-end.sh):

| File | Written By | Read By | Contents |
|------|-----------|---------|----------|
| `.test-status` | test-runner.sh | guard.sh (evidence gate), test-gate.sh, session-summary.sh, check-implementer.sh, check-guardian.sh, subagent-start.sh | `result\|fail_count\|timestamp` — cleared at session start by session-init.sh to prevent stale passes from satisfying the commit gate |
| `.proof-status` | user verification flow | guard.sh (evidence gate), track.sh (invalidation), check-implementer.sh | `status\|timestamp` — `verified` or `pending`. track.sh resets to `pending` when source files change after verification |
| `.plan-drift` | surface.sh | plan-check.sh (staleness scoring) | Structured key=value: `unplanned_count`, `unimplemented_count`, `missing_decisions`, `total_decisions`, `source_files_changed` |
| `.agent-findings` | check-planner.sh, check-implementer.sh, check-guardian.sh | session-init.sh, prompt-submit.sh, compact-preserve.sh | `agent_type\|issue1;issue2` — cleared after injection (one-shot delivery) |
| `.preserved-context` | compact-preserve.sh | session-init.sh | Full session state snapshot — injected after compaction, then deleted (one-time use) |
| `.audit-log` | surface.sh, test-runner.sh, check-*.sh | compact-preserve.sh, session-summary.sh | Timestamped event trail — trimmed to last 100 entries by session-end.sh |

---

## Decision Annotations

The `@decision` annotation creates a bidirectional mapping between MASTER_PLAN.md and source code. The Planner pre-assigns decision IDs (`DEC-COMPONENT-NNN`) in the plan. The Implementer uses those exact IDs in code annotations. The Guardian verifies coverage at merge time.

`doc-gate.sh` enforces that files over 50 lines include @decision annotations. `surface.sh` audits decision coverage at session end.

**TypeScript/JavaScript** (detected by `@decision`):
```typescript
/**
 * @decision DEC-AUTH-001
 * @title Use PKCE for mobile OAuth
 * @status accepted
 * @rationale Mobile apps cannot securely store client secrets
 */
```

**Python/Shell** (detected by `# DECISION:`):
```python
# DECISION: DEC-AUTH-001 — Use PKCE for mobile OAuth. Rationale: Cannot store secrets. Status: accepted.
```

**Go/Rust/C** (detected by `// DECISION:`):
```go
// DECISION: DEC-AUTH-001 — Use PKCE for mobile OAuth. Rationale: Cannot store secrets.
```

Detection regex in `doc-gate.sh`: `@decision|# DECISION:|// DECISION:` — all three patterns are matched.

---

## Skills and Commands

### System Architecture

```
                        ┌─────────────┐
                        │  CLAUDE.md  │
                        │  (loaded    │
                        │  every      │
                        │  session)   │
                        └──────┬──────┘
                               │ governs
               ┌───────────────┼───────────────┐
               ▼               ▼               ▼
        ┌────────────┐  ┌────────────┐  ┌────────────┐
        │   Agents   │  │   Hooks    │  │  Settings  │
        │            │  │            │  │            │
        │ planner    │  │ 24 hooks   │  │ .json      │
        │ implementer│  │ in hooks/  │  │ (universal │
        │ guardian   │  │            │  │  + local)  │
        └─────┬──────┘  └─────┬──────┘  └────────────┘
              │               │
     instruction-based   deterministic
     (degrades with      (always executes)
      context pressure)
              │               │
              ▼               ▼
        ┌────────────┐  ┌────────────┐
        │   Skills   │  │  Commands  │
        │            │  │            │
        │ research   │  │ /compact   │
        │ context    │  │ /backlog   │
        │ last30days │  │            │
        └────────────┘  └────────────┘
```

### Skills

| Skill | Purpose | When to Use |
|-------|---------|-------------|
| **deep-research** | Multi-model research via OpenAI + Perplexity + Gemini with comparative synthesis | Technology comparisons, architecture decisions, complex trade-offs |
| **last30days** | Recent discussions from Reddit, X, and web with engagement metrics (submodule) | Community sentiment, current practices, "what are people using in 2026" |
| **context-preservation** | Structured summaries for session continuity across compaction | Long sessions, before `/compact`, complex multi-session work |

The `deep-research` skill uses API keys for OpenAI, Perplexity, and Gemini but degrades gracefully with fewer providers. The `last30days` skill works without any API keys. The core workflow (agents + hooks) is independent of both.

### Commands

| Command | Purpose |
|---------|---------|
| `/compact` | Generate structured context summary before compaction (prevents amnesia) |
| `/backlog` | Unified backlog management — list, create, close, triage todos (GitHub Issues). No args = list; `/backlog <text>` = create; `/backlog done <#>` = close; `/backlog review` = interactive triage |

---

## Getting Started

### 1. Clone

```bash
# Clone with submodules (last30days skill is a submodule)
git clone --recurse-submodules git@github.com:juanandresgs/claude-system.git ~/.claude
```

If you already have a `~/.claude` directory, back it up first:
```bash
tar czf ~/claude-backup-$(date +%Y%m%d).tar.gz ~/.claude
```

### 2. Local Settings

The system uses a split settings architecture:

- **`settings.json`** (tracked) — Universal configuration: hook registrations, permissions, status line. Works on any machine. Only includes freely available MCP servers (context7).
- **`settings.local.json`** (gitignored) — Your machine-specific overrides: model preference, additional MCP servers, plugins, extra permissions.

Claude Code merges both files, with local taking precedence.

```bash
cp settings.local.example.json settings.local.json
# Edit to set your model preference, MCP servers, plugins
```

### 3. Backlog System (GitHub Issues)

The `/backlog` command persists ideas as GitHub Issues.
On first use, auto-detects your GitHub username and creates a private `cc-todos` repo.

**Requirements:** `gh` CLI installed and authenticated (`gh auth login`)

**Manual override:** `echo "GLOBAL_REPO=myorg/my-repo" > ~/.config/cc-todos/config`

### 4. Optional API Keys

| Key | Used By | Without It |
|-----|---------|-----------|
| OpenAI API key | `deep-research` skill | Skill degrades (fewer models in comparison) |
| Perplexity API key | `deep-research` skill | Skill degrades (fewer models in comparison) |
| Gemini API key | `deep-research` skill | Skill degrades (fewer models in comparison) |

Research skills are optional — the core workflow (agents + hooks) works without any API keys.

### 5. Verify Installation

On your first `claude` session in any project directory, you should see:

- **SessionStart hook fires** — injects git state, plan status, worktree info
- **Plan mode by default** — `settings.json` sets `"defaultMode": "plan"` so Claude thinks before acting
- **Prompt context** — each prompt gets git branch and plan status injected

Try writing a file to `/tmp/test.txt` — `guard.sh` should rewrite it to `tmp/test.txt` in the project root.

### 6. Optional Dependencies

| Dependency | Purpose | Install |
|-----------|---------|---------|
| `terminal-notifier` | Desktop notifications when Claude needs attention | `brew install terminal-notifier` (macOS) |
| `jq` | JSON processing in hooks | `brew install jq` / `apt install jq` |
| Multi-MCP server | Code review hook integration | See `code-review.sh` |

### Platform Notes

- **macOS**: Full support. Notifications use `terminal-notifier` with `osascript` fallback.
- **Linux**: Partial support. Notification hooks won't fire (no macOS notification APIs). All other hooks work.

---

## What Changes From Default Claude Code

| Behavior | Default CC | With This System |
|----------|-----------|-----------------|
| Branch management | Works on whatever branch | Blocked from writing on main; worktree isolation enforced |
| Temporary files | Writes to `/tmp/` | Rewritten to project `tmp/` directory |
| Force push | Executes directly | Rewritten to `--force-with-lease`; requires approval |
| Test discipline | Tests optional | Writes blocked when tests fail; commits require test evidence |
| Mocking | Mocks anything | Internal mocks warned then blocked; external boundary mocks only |
| Planning | Implements immediately | Plan mode by default; MASTER_PLAN.md required before code |
| Documentation | Optional | File headers and @decision enforced on 50+ line files |
| Session end | Just stops | Decision audit + session summary + forward momentum check |
| Session start | Cold start | Git state, plan status, worktrees, todo HUD, agent findings injected |
| Context loss | Compaction loses everything | Dual-path preservation: persistent file + compaction directive. Context survives |
| Commits | Executes on request | Requires approval via Guardian agent; test + proof-of-work evidence required |
| Code review | None | Suggested on significant file writes (when Multi-MCP available) |

---

## Customization

**Safe to change:**
- `settings.local.json` — model preference, MCP servers, plugins, extra permissions
- API keys for research skills — add or remove without breaking anything
- Hook timeouts in `settings.json` — adjust if hooks are timing out on your machine

**Change with understanding:**
- Agent definitions (`agents/*.md`) — modifying agent behavior changes the workflow
- Hook scripts (`hooks/*.sh`) — each hook enforces a specific practice; removing one removes that enforcement
- `CLAUDE.md` — the dispatch rules and sacred practices that govern agent behavior

**Architecture insight:** Hooks are deterministic — they always execute, regardless of context window state. `CLAUDE.md` instructions are probabilistic — they work well but degrade as the context window fills. This is why enforcement lives in hooks, not instructions. When you modify the system, put hard requirements in hooks and soft guidance in `CLAUDE.md`.

---

## Recovery

Archived files are stored in `.archive/YYYYMMDD/`. Full backups at `~/claude-backup-*.tar.gz`.

To debug a hook: run it manually with JSON on stdin:
```bash
echo '{"tool_name":"Bash","tool_input":{"command":"git status"}}' | bash hooks/guard.sh
```

## References

- [`hooks/HOOKS.md`](hooks/HOOKS.md) — Hook protocol, shared library APIs, execution order, testing guide
- [`agents/planner.md`](agents/planner.md) — Planning process, research gate, MASTER_PLAN.md format
- [`agents/implementer.md`](agents/implementer.md) — Test-first workflow, worktree setup, verification checkpoints
- [`agents/guardian.md`](agents/guardian.md) — Approval protocol, merge analysis, phase-boundary plan updates
