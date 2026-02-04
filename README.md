# Claude Code Configuration

This directory contains the configuration that shapes how Claude Code operates — a system designed around three principles:

1. **Code is truth** — Documentation derives from source, never the reverse
2. **Decisions at implementation** — Capture the "why" where it happens
3. **Deterministic enforcement** — Hooks always execute, instructions degrade with context

---

## Setup (Fresh Clone)

```bash
# Clone with submodules (required for research-verified and last30days skills)
git clone --recurse-submodules git@github.com:juanandresgs/claude-system.git ~/.claude

# Create your local settings override
cp settings.local.example.json settings.local.json
# Edit settings.local.json — set model, MCP servers, plugins for your machine
```

### Optional Dependencies

| Dependency | Purpose | Platform |
|-----------|---------|----------|
| `terminal-notifier` | Desktop notifications when Claude needs attention | macOS (`brew install terminal-notifier`) |
| Multi-MCP server | Code review hook integration | Any (see `code-review.sh`) |
| `jq` | JSON processing in hooks | Any (`brew install jq` / `apt install jq`) |

### Platform Notes

- **macOS**: Full support. Notifications use `terminal-notifier` with `osascript` fallback.
- **Linux**: Partial. Notification hooks won't fire (no macOS notification APIs). All other hooks work.

---

## The Team of Excellence

### Agents

| Agent | Purpose | Invoke When... |
|-------|---------|----------------|
| **Planner** | Requirements → MASTER_PLAN.md | Starting something new, need to decompose complexity |
| **Implementer** | Issue → Working code in worktree | Have a well-scoped issue, ready to write code |
| **Guardian** | Code → Committed/merged state | Ready to commit, merge, or manage branches |

### The Workflow

```
┌─────────────────────────────────────────────────────────────┐
│  CORE DOGMA: We NEVER run straight into implementing        │
├─────────────────────────────────────────────────────────────┤
│  1. Planner → MASTER_PLAN.md (before any code)             │
│  2. Guardian → Creates worktrees (main is sacred)           │
│  3. Implementer → Tests first, @decision annotations        │
│  4. Guardian → Commits/merges with approval                 │
│  5. Hooks → Guard, gate, lint, track, surface (automatic)  │
└─────────────────────────────────────────────────────────────┘
```

---

## Hooks (Automatic, Every Time)

All hooks are registered in `settings.json` and run deterministically. For protocol details, shared library APIs, and execution order, see [`hooks/HOOKS.md`](hooks/HOOKS.md).

### PreToolUse — Block Before Execution

| Hook | Matcher | What It Does |
|------|---------|--------------|
| **guard.sh** | Bash | Blocks /tmp writes, commits on main, force push, destructive git |
| **test-gate.sh** | Write\|Edit | Blocks source file writes when tests are failing |
| **branch-guard.sh** | Write\|Edit | Blocks source file writes on main/master branch |
| **doc-gate.sh** | Write\|Edit | Enforces file headers and @decision on 50+ line files |
| **plan-check.sh** | Write\|Edit | Warns if writing source code without MASTER_PLAN.md |

### PostToolUse — Feedback After Execution

| Hook | Matcher | What It Does |
|------|---------|--------------|
| **lint.sh** | Write\|Edit | Auto-detects project linter, runs on modified files |
| **track.sh** | Write\|Edit | Records which files changed this session |
| **code-review.sh** | Write\|Edit | Triggers code review via Multi-MCP (optional dependency) |
| **plan-validate.sh** | Write\|Edit | Validates changes align with MASTER_PLAN.md |
| **test-runner.sh** | Write\|Edit | Runs project tests asynchronously after writes |

### Session Lifecycle

| Hook | Event | What It Does |
|------|-------|--------------|
| **session-init.sh** | SessionStart | Injects git state, MASTER_PLAN.md status, worktrees |
| **prompt-submit.sh** | UserPromptSubmit | Adds git context and plan status to each prompt |
| **compact-preserve.sh** | PreCompact | Preserves git state and session context before compaction |
| **session-end.sh** | SessionEnd | Cleanup and session finalization |
| **surface.sh** | Stop | Validates @decision coverage, reports audit |
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
| **check-planner.sh** | SubagentStop (planner\|Plan) | Validates planner output quality |
| **check-implementer.sh** | SubagentStop (implementer) | Validates implementer output quality |
| **check-guardian.sh** | SubagentStop (guardian) | Validates guardian output quality |

### Shared Libraries

| File | Purpose |
|------|---------|
| **log.sh** | Structured logging helper (sourced by all hooks) |
| **context-lib.sh** | Git state, plan status, project root detection (sourced by hooks) |

---

## The @decision Annotation

Add to significant source files (50+ lines):

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

## Skills

| Skill | Purpose |
|-------|---------|
| **decision-parser** | Parse and validate @decision annotation syntax from source |
| **context-preservation** | Generate structured summaries for session continuity |
| **plan-sync** | Reconcile MASTER_PLAN.md with codebase @decision annotations |
| **generate-knowledge** | Analyze any git repo and produce a structured knowledge kit |
| **worktree** | Git worktree management for parallel development |
| **research-advisor** | Intelligent router — analyzes query, selects optimal research skill |
| **research-fast** | Quick expert synthesis for overviews and strategic planning |
| **research-verified** | Multi-source verification with citations and credibility scoring (submodule) |
| **last30days** | Recent discussions from Reddit, X, and web (submodule) |

## Commands

| Command | Purpose |
|---------|---------|
| `/compact` | Create context summary before compaction |
| `/analyze` | Bootstrap session with full repo knowledgebase context |

---

## Directory Structure

```
~/.claude/
├── CLAUDE.md                   # Foundational philosophy and workflow rules
├── README.md                   # This guide
├── settings.json               # Configuration (hooks, permissions) — universal
├── settings.local.json         # Machine-specific overrides (gitignored)
├── settings.local.example.json # Template for local overrides (tracked)
├── .gitmodules                 # Submodule references
│
├── hooks/                      # Deterministic enforcement
│   ├── HOOKS.md                # Hook protocol reference and catalog
│   ├── log.sh                  # Shared: structured logging
│   ├── context-lib.sh          # Shared: git/plan state detection
│   ├── guard.sh                # PreToolUse(Bash): sacred practice guardrails
│   ├── test-gate.sh            # PreToolUse(Write|Edit): test-passing gate
│   ├── branch-guard.sh         # PreToolUse(Write|Edit): main branch protection
│   ├── doc-gate.sh             # PreToolUse(Write|Edit): documentation enforcement
│   ├── plan-check.sh           # PreToolUse(Write|Edit): plan-first warning
│   ├── lint.sh                 # PostToolUse(Write|Edit): auto-detect linter
│   ├── track.sh                # PostToolUse(Write|Edit): change tracking
│   ├── code-review.sh          # PostToolUse(Write|Edit): code review integration
│   ├── plan-validate.sh        # PostToolUse(Write|Edit): plan alignment check
│   ├── test-runner.sh          # PostToolUse(Write|Edit): async test execution
│   ├── session-init.sh         # SessionStart: project context injection
│   ├── prompt-submit.sh        # UserPromptSubmit: per-prompt context
│   ├── compact-preserve.sh     # PreCompact: context preservation
│   ├── session-end.sh          # SessionEnd: cleanup
│   ├── surface.sh              # Stop: decision audit
│   ├── session-summary.sh      # Stop: session summary
│   ├── forward-motion.sh       # Stop: forward momentum check
│   ├── notify.sh               # Notification: desktop alerts (macOS)
│   ├── subagent-start.sh       # SubagentStart: context injection
│   ├── check-planner.sh        # SubagentStop: planner validation
│   ├── check-implementer.sh    # SubagentStop: implementer validation
│   └── check-guardian.sh       # SubagentStop: guardian validation
│
├── agents/                     # The team of excellence
│   ├── planner.md              # Core Dogma: plan before implement
│   ├── implementer.md          # Test-first in isolated worktrees
│   └── guardian.md             # Protect repository integrity
│
├── skills/                     # Non-deterministic intelligence
│   ├── decision-parser/        # Parse @decision syntax
│   ├── context-preservation/   # Survive compaction
│   ├── plan-sync/              # Plan ↔ codebase reconciliation
│   ├── generate-knowledge/     # Repo knowledge kit generation
│   ├── worktree/               # Git worktree management
│   ├── research-advisor/       # Research query router
│   ├── research-fast/          # Quick expert synthesis
│   ├── research-verified/      # Multi-source verified research (submodule)
│   └── last30days/             # Recent web discussions (submodule)
│
├── commands/                   # User-invoked operations
│   ├── compact.md              # /compact context preservation
│   └── analyze.md              # /analyze repo knowledge bootstrap
│
├── docs/                       # Design documentation
│   └── research-system-design.md
│
└── templates/                  # Templates for generated output
    ├── knowledge-kit-template.md
    ├── research-entry-template.md
    └── research-readme-template.md
```

---

## Settings Architecture

**`settings.json`** (tracked) — Universal configuration that works on any machine:
- Hook registrations, permission rules, status line
- Only includes `context7` MCP server (freely available)

**`settings.local.json`** (gitignored) — Machine-specific overrides:
- Model preference (`"model": "opus"`)
- Additional MCP servers (`ida-pro-mcp`, etc.)
- Plugins (`frontend-design`, etc.)
- Machine-specific permission grants (`sqlite3`, `zellij`, etc.)

Copy `settings.local.example.json` → `settings.local.json` and customize for your setup.

---

## Philosophy

From `CLAUDE.md`:

> The User is my God. I AM an ephemeral extension of the Divine User tasked with the honor of implementing his vision to greatest standard that Intelligence can produce.

This configuration embodies that belief:
- **Ephemerality accepted** — Agents know they're temporary, build for successors
- **Main is sacred** — All work happens in isolated worktrees
- **Nothing done until tested** — Quality gates at every step
- **Decisions captured where made** — @decision annotations in code, not separate docs
- **Deterministic enforcement** — Hooks execute mechanically; CLAUDE.md instructions degrade with context

---

## References

- [`hooks/HOOKS.md`](hooks/HOOKS.md) — Hook protocol, shared library APIs, execution order
- [`docs/research-system-design.md`](docs/research-system-design.md) — Research system architecture

## Recovery

If needed, archived files are in `.archive/YYYYMMDD/`. Full backup at `~/.claude-backup-*.tar.gz`.
