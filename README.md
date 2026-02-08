# The Systems Thinker's Vibecoding Starter Kit

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/juanandresgs/claude-system)](https://github.com/juanandresgs/claude-system/stargazers)
[![Last commit](https://img.shields.io/github/last-commit/juanandresgs/claude-system)](https://github.com/juanandresgs/claude-system/commits/main)
[![Shell](https://img.shields.io/badge/language-bash-green.svg)](hooks/)
[![Validate Hooks](https://github.com/juanandresgs/claude-system/actions/workflows/validate.yml/badge.svg)](https://github.com/juanandresgs/claude-system/actions/workflows/validate.yml)

JAGS' batteries-included Claude Code config

Claude Code out of the box is capable but undisciplined. It commits directly to main. It skips tests. It starts implementing before understanding the problem. It force-pushes without thinking. None of these are bugs — they're defaults.

This system replaces those defaults with mechanical enforcement. Three specialized agents divide the work — Planner, Implementer, Guardian — so no single context handles planning, implementation, and git operations. Twenty-four hooks run deterministically at every lifecycle event. They don't depend on the model remembering instructions. They execute regardless of context window pressure.

**Instructions guide. Hooks enforce.**

---

## What This Looks Like

No configuration. No hoping the model remembers. Just mechanical enforcement:

```
You:     echo 'test' > /tmp/scratch.txt
guard.sh: ✅ REWRITE → mkdir -p tmp && echo 'test' > tmp/scratch.txt
          /tmp/ is forbidden. Transparently rewritten to project tmp/.

You:     git push --force origin feature
guard.sh: ✅ REWRITE → git push --force-with-lease origin feature
          --force rewritten to --force-with-lease. Your reflog says thanks.

You:     git commit -m "quick fix"          (on main branch)
guard.sh: ❌ DENY — Cannot commit on main. Sacred Practice #2.
          Action: Use Guardian agent to create an isolated worktree.

You:     [writes src/auth.ts]               (tests are failing)
test-gate.sh: ⚠️ WARNING — Tests failing. Strike 1 of 2.
              [writes again]
test-gate.sh: ❌ DENY — Tests still failing. Fix tests before continuing.

You:     [writes src/auth.ts]               (no MASTER_PLAN.md exists)
plan-check.sh: ❌ DENY — No plan found. Sacred Practice #6.
               Action: Invoke Planner agent first.
```

Every check runs deterministically via hooks — not instructions that degrade with context pressure. The model doesn't need to remember the rules. The hooks enforce them.

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
| **lint.sh** | Write\|Edit | Auto-detects project linter, runs on modified files (exit 2 = retry loop) |
| **track.sh** | Write\|Edit | Records which files changed this session |
| **code-review.sh** | Write\|Edit | Suggests code review via Multi-MCP on significant changes (optional dependency) |
| **plan-validate.sh** | Write\|Edit | Validates MASTER_PLAN.md structural integrity (phases, status fields, decision IDs) |
| **test-runner.sh** | Write\|Edit | Runs project tests asynchronously after writes |

### Session Lifecycle

| Hook | Event | What It Does |
|------|-------|--------------|
| **session-init.sh** | SessionStart | Injects git state, MASTER_PLAN.md status, active worktrees |
| **prompt-submit.sh** | UserPromptSubmit | Adds git context and plan status to each prompt |
| **compact-preserve.sh** | PreCompact | Preserves git state and session context before compaction |
| **session-end.sh** | SessionEnd | Cleanup and session finalization |
| **surface.sh** | Stop | Validates @decision coverage, reports audit results |
| **session-summary.sh** | Stop | Deterministic session summary (files changed, git state, next action) |
| **forward-motion.sh** | Stop | Ensures session ends with forward momentum |

### Notifications

| Hook | Matcher | What It Does |
|------|---------|--------------|
| **notify.sh** | permission_prompt\|idle_prompt | Desktop notification when Claude needs attention (macOS) |

### Subagent Lifecycle

| Hook | Event / Matcher | What It Does |
|------|-----------------|--------------|
| **subagent-start.sh** | SubagentStart | Injects context when subagents launch |
| **check-planner.sh** | SubagentStop (planner\|Plan) | Validates planner output quality and issue creation |
| **check-implementer.sh** | SubagentStop (implementer) | Validates implementer output quality |
| **check-guardian.sh** | SubagentStop (guardian) | Validates guardian output quality |

### Shared Libraries

| File | Purpose |
|------|---------|
| **log.sh** | Structured logging, stdin caching, field extraction (sourced by all hooks) |
| **context-lib.sh** | Git state, plan status, project root detection, source file identification |

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

Test evidence: a pass of any age satisfies the gate. A `fail` within 10 minutes, any non-pass status, or missing file = denied.

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
| Commits | Executes on request | Requires approval via Guardian agent; test evidence required |
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
