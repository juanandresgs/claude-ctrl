<p align="center">
  <img src="assets/banner.jpeg" alt="The Systems Thinker's Vibecoding Starter Kit" width="100%">
</p>

# The Systems Thinker's Vibecoding Starter Kit

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/juanandresgs/claude-system)](https://github.com/juanandresgs/claude-system/stargazers)
[![Last commit](https://img.shields.io/github/last-commit/juanandresgs/claude-system)](https://github.com/juanandresgs/claude-system/commits/main)
[![Shell](https://img.shields.io/badge/language-bash-green.svg)](hooks/)

JAGS' batteries-included Claude Code config

Claude Code out of the box is capable but undisciplined. It commits directly to main. It skips tests. It starts implementing before understanding the problem. It force-pushes without thinking. None of these are bugs — they're defaults.

This system replaces those defaults with mechanical enforcement. Three specialized agents divide the work — Planner, Implementer, Guardian — so no single context handles planning, implementation, and git operations. Hooks run deterministically at every lifecycle event. They don't depend on the model remembering instructions. They execute regardless of context window pressure.

**Instructions guide. Hooks enforce.**

---

## Without This vs With This

**Default Claude Code** — you describe a feature and:

```
idea → code → commit → push → discover the mess
```

The model writes on main, skips tests, force-pushes, and forgets the plan once the context window fills up. Every session is a coin flip.

**With this system** — the same feature request triggers a self-correcting pipeline:

```
                ┌─────────────────────────────────────────┐
                │           You describe a feature         │
                └──────────────────┬──────────────────────┘
                                   ▼
                ┌──────────────────────────────────────────┐
                │  Planner agent:                          │
                │    1a. Problem decomposition (evidence)   │
                │    1b. User requirements (P0/P1/P2)      │
                │    1c. Success metrics                   │
                │    2.  Research gate → architecture       │
                │  → MASTER_PLAN.md + GitHub Issues         │
                └──────────────────┬───────────────────────┘
                                   ▼
                ┌──────────────────────────────────────────┐
                │  Guardian agent creates isolated worktree │
                └──────────────────┬───────────────────────┘
                                   ▼
              ┌────────────────────────────────────────────────┐
              │              Implementer codes                  │
              │                                                 │
              │   write src/ ──► test-gate: tests passing? ─┐   │
              │       ▲              no? warn, then block   │   │
              │       └──── fix tests, write again ◄────────┘   │
              │                                                 │
              │   write src/ ──► plan-check: plan stale? ───┐   │
              │       ▲              yes? block              │   │
              │       └──── update plan, write again ◄──────┘   │
              │                                                 │
              │   write src/ ──► doc-gate: documented? ─────┐   │
              │       ▲              no? block               │   │
              │       └──── add headers + @decision ◄───────┘   │
              └────────────────────────┬───────────────────────┘
                                       ▼
                ┌──────────────────────────────────────────────┐
                │  Guardian agent: commit (requires test       │
                │  evidence + your approval) → merge to main   │
                └──────────────────────────────────────────────┘
```

Every arrow is a hook. Every feedback loop is automatic. The model doesn't choose to follow the process — the hooks won't let it skip. Try to write code without a plan and you're pushed back. Try to commit with failing tests and you're pushed back. Try to skip documentation and you're pushed back. The system self-corrects until the work is right.

**The result:** you move faster because you never think about process. The hooks think about it for you. Dangerous commands get silently rewritten (`--force` → `--force-with-lease`, `/tmp/` → project `tmp/`). Everything else either flows through or gets caught. You just describe what you want and review what comes out.

---

## Why Hooks, Not Instructions

Most Claude Code configs rely on CLAUDE.md instructions — guidance that works early in a session but degrades as the context window fills up or compaction throws everything off a cliff. This system puts enforcement in **deterministic hooks**: shell scripts that fire before and after every event, regardless of context pressure.

Instructions are probabilistic. Hooks are mechanical. That's the difference.

---

## Getting Started

### 1. Clone

```bash
# SSH
git clone --recurse-submodules git@github.com:juanandresgs/claude-system.git ~/.claude

# Or HTTPS
git clone --recurse-submodules https://github.com/juanandresgs/claude-system.git ~/.claude
```

If you already have a `~/.claude` directory, back it up first: `tar czf ~/claude-backup-$(date +%Y%m%d).tar.gz ~/.claude`

### 2. Configure

```bash
cp settings.local.example.json settings.local.json
# Edit to set your model preference, MCP servers, plugins
```

Settings are split: `settings.json` (tracked, universal) and `settings.local.json` (gitignored, your overrides). Claude Code merges both, with local taking precedence.

### 3. Verify

On your first `claude` session, you should see the SessionStart hook inject git state, plan status, and worktree info. Try writing a file to `/tmp/test.txt` — `guard.sh` should rewrite it to `tmp/test.txt` in the project root.

**Optional:** `/backlog` command uses GitHub Issues via `gh` CLI (`gh auth login`). Research skills (`deep-research`) accept OpenAI/Perplexity/Gemini API keys but degrade gracefully without them. Desktop notifications need `terminal-notifier` (macOS: `brew install terminal-notifier`).

### Staying Updated

The harness auto-checks for updates on every new session start. Same-MAJOR-version updates are applied automatically. Breaking changes (different MAJOR version) show a notification — you decide when to apply.

- **Auto-updates enabled by default.** Create `~/.claude/.disable-auto-update` to disable.
- **Manual update:** `cd ~/.claude && git pull --autostash --rebase`
- **Fork users:** Your `origin` points to your fork, so you get your own updates. Add an `upstream` remote to also track the original repo.
- **Local customizations safe:** `settings.local.json` and `CLAUDE.local.md` are gitignored. If you edit tracked files, `--autostash` preserves your changes. If a conflict occurs, the update aborts cleanly and you're notified.

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
| **Planner** | Opus | Complexity assessment (Brief/Standard/Full tiers), problem decomposition, requirements (P0/P1/P2 with acceptance criteria), success metrics, architecture design, research gate | MASTER_PLAN.md (with REQ-IDs + DEC-IDs), GitHub Issues, research log |
| **Implementer** | Sonnet | Test-first coding in isolated worktrees | Working code, tests, @decision annotations |
| **Guardian** | Opus | Git operations, merge analysis, plan evolution | Commits, merges, phase reviews, plan updates |

The orchestrator dispatches to agents but never writes source code itself. Each agent handles its own approval cycle: present the work, wait for approval, execute, verify, suggest next steps.

---

## Sacred Practices

These are non-negotiable. Each one is enforced by hooks that run every time, regardless of context window state or model behavior.

| # | Practice | What Enforces It |
|---|----------|-------------|
| 1 | **Always Use Git** | `session-init.sh` injects git state; `guard.sh` blocks destructive operations |
| 2 | **Main is Sacred** | `branch-guard.sh` blocks writes on main; `guard.sh` blocks commits on main |
| 3 | **No /tmp/** | `guard.sh` rewrites `/tmp/` paths to project `tmp/` directory |
| 4 | **Nothing Done Until Tested** | `test-gate.sh` warns then blocks source writes when tests fail; `guard.sh` requires test evidence for commits |
| 5 | **Solid Foundations** | `mock-gate.sh` detects and escalates internal mocking (warn → deny) |
| 6 | **No Implementation Without Plan** | `plan-check.sh` denies source writes without MASTER_PLAN.md |
| 7 | **Code is Truth** | `doc-gate.sh` enforces headers and @decision on 50+ line files |
| 8 | **Approval Gates** | `guard.sh` blocks force push; Guardian agent requires approval for all permanent ops |
| 9 | **Track in Issues** | `plan-validate.sh` checks alignment; `check-planner.sh` validates issue creation |

---

## Hook System

All hooks are registered in `settings.json` and run deterministically — JSON in on stdin, JSON out on stdout. Hooks fire at four lifecycle points: before tool use (block or rewrite), after tool use (lint, track, validate), at session boundaries (context injection, cleanup), and around subagents (inject context, verify output).

For the full protocol, detailed tables, enforcement patterns, state files, and shared library APIs, see [`hooks/HOOKS.md`](hooks/HOOKS.md).

| Hook | Event | Purpose |
|------|-------|---------|
| **guard.sh** | PreToolUse:Bash | `/tmp/` rewrite, main protection, `--force-with-lease`, test evidence gate |
| **auto-review.sh** | PreToolUse:Bash | Three-tier command classifier: auto-approve safe, defer risky to user |
| **test-gate.sh** | PreToolUse:Write\|Edit | Escalating gate: warn then block when tests fail |
| **mock-gate.sh** | PreToolUse:Write\|Edit | Detect and escalate internal mocking |
| **branch-guard.sh** | PreToolUse:Write\|Edit | Block source writes on main/master |
| **doc-gate.sh** | PreToolUse:Write\|Edit | Enforce file headers and @decision on 50+ line files |
| **plan-check.sh** | PreToolUse:Write\|Edit | Deny source writes without plan; staleness scoring |
| **lint.sh** | PostToolUse:Write\|Edit | Auto-detect linter, run on modified files, feedback loop |
| **track.sh** | PostToolUse:Write\|Edit | Record changes, invalidate proof-of-work on source edits |
| **test-runner.sh** | PostToolUse:Write\|Edit | Async test execution, writes `.test-status` for evidence gate |
| **session-init.sh** | SessionStart | Inject git state, update status, plan status, worktrees, todo HUD (calls `scripts/update-check.sh`) |
| **prompt-submit.sh** | UserPromptSubmit | Keyword-based context injection, deferred-work detection |
| **compact-preserve.sh** | PreCompact | Dual-path context preservation across compaction |
| **surface.sh** | Stop | Decision audit: extract, validate, reconcile @decision coverage, REQ-ID traceability |
| **session-summary.sh** | Stop | File counts, git state, workflow-aware next-action guidance |
| **forward-motion.sh** | Stop | Ensure response ends with question, suggestion, or offer |
| **plan-validate.sh** | PostToolUse:Write\|Edit | Validate MASTER_PLAN.md format, REQ-ID syntax, decision linkage |
| **code-review.sh** | PostToolUse:Write\|Edit | Optional LLM-based code review integration (requires Multi-MCP) |
| **task-track.sh** | PreToolUse:Task | Track subagent state and update status bar |
| **notify.sh** | Notification | Desktop alert when Claude needs attention (macOS) |
| **subagent-start.sh** | SubagentStart | Agent-specific context injection |
| **check-planner.sh** | SubagentStop:planner | Verify MASTER_PLAN.md exists and is valid |
| **check-implementer.sh** | SubagentStop:implementer | Enforce proof-of-work (live demo + tests) before commits |
| **check-guardian.sh** | SubagentStop:guardian | Validate commit message format and issue linkage |
| **session-end.sh** | SessionEnd | Cleanup session files, kill async processes |

---

## Decision Annotations

The `@decision` annotation maps MASTER_PLAN.md decision IDs to source code. The Planner pre-assigns IDs (`DEC-COMPONENT-NNN`), the Implementer annotates code, the Guardian verifies coverage at merge time. `doc-gate.sh` enforces annotations on files over 50 lines.

```typescript
/**
 * @decision DEC-AUTH-001
 * @title Use PKCE for mobile OAuth
 * @status accepted
 * @rationale Mobile apps cannot securely store client secrets
 */
```

Also supported: `# DECISION:` (Python/Shell) and `// DECISION:` (Go/Rust/C). Detection regex: `@decision|# DECISION:|// DECISION:`. See [`hooks/HOOKS.md`](hooks/HOOKS.md) for enforcement details.

### Two-Tier Traceability

Requirements and decisions live in a single artifact (MASTER_PLAN.md) with bidirectional linkage to source code:

```
MASTER_PLAN.md                         Source Code
REQ-P0-001 (requirement)               @decision DEC-AUTH-001
DEC-AUTH-001 (decision)                   Addresses: REQ-P0-001
  Addresses: REQ-P0-001
```

REQ-IDs (`REQ-{CATEGORY}-{NNN}`) are assigned during planning. DEC-IDs link to REQ-IDs via `Addresses:`. Phases reference which REQ-IDs they satisfy. `surface.sh` audits unaddressed P0 requirements at session end. `plan-validate.sh` validates REQ-ID format on every MASTER_PLAN.md write.

---

## Skills and Commands

| Skill | Purpose |
|-------|---------|
| **uplevel** | Comprehensive repository health audit — security, testing, quality, docs, staleness, standards |
| **decide** | Interactive decision configurator — explore trade-offs, costs, effort estimates with filtering UI |
| **deep-research** | Multi-model research via OpenAI + Perplexity + Gemini with comparative synthesis |
| **last30days** | Recent discussions from Reddit, X, and web with engagement metrics (submodule) |
| **prd** | Optional deep-dive PRD: problem statement, user journeys, requirements, success metrics |
| **context-preservation** | Structured summaries for session continuity across compaction |

| Command | Purpose |
|---------|---------|
| `/compact` | Generate structured context summary before compaction (prevents amnesia) |
| `/backlog` | Unified backlog management — list, create, close, triage todos via GitHub Issues |

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
| Context loss | Compaction loses everything | Dual-path preservation: persistent file + compaction directive |
| Commits | Executes on request | Requires approval via Guardian agent; test + proof-of-work evidence |
| Code review | None | Suggested on significant file writes (when Multi-MCP available) |

---

## Customization

**Safe to change:** `settings.local.json` (model, MCP servers, plugins), API keys for research skills, hook timeouts in `settings.json`.

**Change with understanding:** Agent definitions (`agents/*.md`), hook scripts (`hooks/*.sh`), `CLAUDE.md` dispatch rules and sacred practices.

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Hook timeout errors | Increase `timeout` in `settings.json` for the slow hook |
| Desktop notifications not firing | Install `terminal-notifier` (macOS only): `brew install terminal-notifier` |
| test-gate blocking unexpectedly | Check `.claude/.test-status` — stale from previous session? Delete it |
| SessionStart not injecting context | Known bug ([#10373](https://github.com/anthropics/claude-code/issues/10373)). `prompt-submit.sh` mitigates on first prompt |

## Recovery and Uninstall

Archived files are stored in `.archive/YYYYMMDD/`. Full backups at `~/claude-backup-*.tar.gz`.

To debug a hook: `echo '{"tool_name":"Bash","tool_input":{"command":"git status"}}' | bash hooks/guard.sh`

**Uninstall:** Remove `~/.claude` and restart Claude Code. It will recreate a default config directory. Your projects are unaffected.

---

## References

- [`hooks/HOOKS.md`](hooks/HOOKS.md) — Full hook reference: protocol, detailed tables, enforcement patterns, state files, shared libraries
- [`agents/planner.md`](agents/planner.md) — Planning process, research gate, MASTER_PLAN.md format
- [`agents/implementer.md`](agents/implementer.md) — Test-first workflow, worktree setup, verification checkpoints
- [`agents/guardian.md`](agents/guardian.md) — Approval protocol, merge analysis, phase-boundary plan updates
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — How to contribute
- [`CHANGELOG.md`](CHANGELOG.md) — Release history
