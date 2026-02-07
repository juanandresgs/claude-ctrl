# Claude Code Configuration System

A multi-agent workflow for Claude Code that enforces plan-first development, worktree isolation, test-first implementation, and approval gates through deterministic hooks.

- **3 specialized agents** — Planner, Implementer, Guardian — each with defined responsibilities and model assignments
- **24 hooks** — Mechanical enforcement of engineering practices at every lifecycle event
- **Research skills** — Multi-model deep research and recent web discussion analysis
- **Split settings** — Tracked universal config + gitignored local overrides

---

## Why This Exists

Claude Code out of the box is capable but undisciplined. It commits directly to main. It writes temporary files to `/tmp`. It starts implementing before understanding the problem. It mocks internal modules instead of testing real behavior. It skips documentation. It force-pushes without thinking.

None of these are bugs — they're defaults. This configuration replaces those defaults with enforced engineering discipline.

Three agents divide responsibilities so no single context handles planning, implementation, and git operations. Twenty-four hooks run deterministically at every lifecycle event — they don't depend on the model remembering instructions, they execute mechanically regardless of context window pressure.

The result: every session starts with context injection, every file write is gated by branch protection and test status, every commit requires approval, every session ends with a structured summary and forward momentum.

This system is opinionated. That's the point. The opinions are:
- Plans before code. Always.
- Main is never touched during development. Never.
- Tests pass before you can commit. No exceptions.
- Decisions are captured where they're made, in the code, not in separate documents.
- Hooks enforce what instructions suggest.

If you disagree with an opinion, change the hook that enforces it. The architecture makes that straightforward.

---

## How It Works

```
┌──────────────────────────────────────────────────────────────┐
│  CORE DOGMA: We NEVER run straight into implementing.        │
│  Plan first. Isolate work. Test everything. Get approval.    │
└──────────────────────────────────────────────────────────────┘
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

Nine practices define how this system operates. Each one has mechanical enforcement — not just instructions that degrade with context, but hooks that execute every time.

| # | Practice | Enforcement |
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
| **guard.sh** | Bash | Blocks `/tmp` writes, commits on main, force push, destructive git; rewrites to safe alternatives |
| **auto-review.sh** | Bash | Three-tier command classifier: auto-approves safe commands, defers risky ones to user |
| **test-gate.sh** | Write\|Edit | Escalating gate: warns on first source write with failing tests, blocks on repeat |
| **mock-gate.sh** | Write\|Edit | Detects internal mocking patterns; warns first, blocks on repeat |
| **branch-guard.sh** | Write\|Edit | Blocks source file writes on main/master branch |
| **doc-gate.sh** | Write\|Edit | Enforces file headers and @decision annotations on 50+ line files |
| **plan-check.sh** | Write\|Edit | Denies source writes without MASTER_PLAN.md; bypasses small files and edits |

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

Three checks use transparent rewrites — the model's command is silently replaced with a safe alternative:

1. `/tmp/` paths → project `tmp/` directory
2. `--force` → `--force-with-lease`
3. `git worktree remove` → prepends `cd` to main worktree first

Commits and merges require a `.test-status` file showing `pass`. A pass of any age satisfies the gate; any non-pass status or missing file = denied.

---

## Decision Annotations

The `@decision` annotation creates a bidirectional mapping between MASTER_PLAN.md and source code. The Planner pre-assigns decision IDs (`DEC-COMPONENT-NNN`) in the plan. The Implementer uses those exact IDs in code annotations. The Guardian verifies coverage at merge time.

`doc-gate.sh` enforces that files over 50 lines include @decision annotations. `surface.sh` audits decision coverage at session end.

**TypeScript/JavaScript:**
```typescript
/**
 * @decision DEC-AUTH-001
 * @title Use PKCE for mobile OAuth
 * @status accepted
 * @rationale Mobile apps cannot securely store client secrets
 */
```

**Python/Shell:**
```python
# DECISION: Use PKCE for mobile OAuth. Rationale: Cannot store secrets. Status: accepted.
```

**Go/Rust:**
```go
// DECISION(DEC-AUTH-001): Use PKCE for mobile OAuth. Rationale: Cannot store secrets.
```

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
        │ planner    │  │ 23 scripts │  │ .json      │
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
        │ context    │  │ /todo      │
        │ last30days │  │ /todos     │
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
| `/todo <text>` | Capture idea/task as GitHub Issue — project-scoped by default, `--global` for backlog |
| `/todos` | List, close, triage pending todos — supports `done <#>`, `stale`, `review` |

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

### 3. Todo System (GitHub Issues)

The `/todo` and `/todos` commands persist ideas as GitHub Issues.
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

## Directory Structure

```
~/.claude/
├── CLAUDE.md                     # Workflow rules, dispatch table, sacred practices
├── README.md                     # This guide
├── settings.json                 # Hook registrations, permissions — universal (tracked)
├── settings.local.json           # Machine-specific overrides (gitignored)
├── settings.local.example.json   # Template for local overrides (tracked)
├── .gitmodules                   # Submodule references (last30days)
│
├── hooks/                        # Deterministic enforcement (24 hooks + 2 libraries)
│   ├── HOOKS.md                  # Hook protocol reference and full catalog
│   ├── log.sh                    # Shared: structured logging, stdin caching
│   ├── context-lib.sh            # Shared: git/plan state, source file detection
│   ├── guard.sh                  # PreToolUse(Bash): sacred practice guardrails + rewrites
│   ├── auto-review.sh            # PreToolUse(Bash): intelligent command auto-approval
│   ├── test-gate.sh              # PreToolUse(Write|Edit): test-passing gate
│   ├── mock-gate.sh              # PreToolUse(Write|Edit): internal mock detection
│   ├── branch-guard.sh           # PreToolUse(Write|Edit): main branch protection
│   ├── doc-gate.sh               # PreToolUse(Write|Edit): documentation enforcement
│   ├── plan-check.sh             # PreToolUse(Write|Edit): plan-first warning
│   ├── lint.sh                   # PostToolUse(Write|Edit): auto-detect linter
│   ├── track.sh                  # PostToolUse(Write|Edit): change tracking
│   ├── code-review.sh            # PostToolUse(Write|Edit): code review integration
│   ├── plan-validate.sh          # PostToolUse(Write|Edit): plan alignment check
│   ├── test-runner.sh            # PostToolUse(Write|Edit): async test execution
│   ├── session-init.sh           # SessionStart: project context injection
│   ├── prompt-submit.sh          # UserPromptSubmit: per-prompt context
│   ├── compact-preserve.sh       # PreCompact: context preservation
│   ├── session-end.sh            # SessionEnd: cleanup
│   ├── surface.sh                # Stop: decision audit
│   ├── session-summary.sh        # Stop: session summary
│   ├── forward-motion.sh         # Stop: forward momentum check
│   ├── notify.sh                 # Notification: desktop alerts (macOS)
│   ├── subagent-start.sh         # SubagentStart: context injection
│   ├── check-planner.sh          # SubagentStop: planner validation
│   ├── check-implementer.sh      # SubagentStop: implementer validation
│   └── check-guardian.sh         # SubagentStop: guardian validation
│
├── agents/                       # Specialized agent definitions
│   ├── planner.md                # Core Dogma: plan before implement
│   ├── implementer.md            # Test-first in isolated worktrees
│   └── guardian.md               # Protect repository integrity
│
├── skills/                       # Non-deterministic intelligence
│   ├── context-preservation/     # Survive compaction
│   ├── deep-research/            # Multi-model research (OpenAI + Perplexity + Gemini)
│   └── last30days/               # Recent web discussions (submodule)
│
├── commands/                     # User-invoked slash commands
│   ├── compact.md                # /compact — context preservation
│   ├── todo.md                   # /todo — quick idea capture as GitHub Issue
│   └── todos.md                  # /todos — list, close, triage todos
│
├── scripts/                      # Backend scripts for commands
│   └── todo.sh                   # GitHub Issue management for /todo and /todos
│
├── docs/                         # Design documentation
│   ├── context-management-sota-2026.md
│   └── team-walkthrough-presentation.md
│
└── templates/                    # Templates for generated output
    └── knowledge-kit-template.md
```

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
