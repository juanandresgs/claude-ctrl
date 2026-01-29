# Claude Code Configuration

This directory contains the configuration that shapes how Claude Code operates — a system designed around three principles:

1. **Code is truth** — Documentation derives from source, never the reverse
2. **Decisions at implementation** — Capture the "why" where it happens
3. **Deterministic enforcement** — Hooks always execute, instructions degrade with context

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
├─────────────────────────────────────────────────────────────┤
│  COMMAND: /compact (preserve context before compaction)     │
└─────────────────────────────────────────────────────────────┘
```

---

## Hooks (Automatic, Every Time)

### Layer 1: PreToolUse — Block Before Execution

| Hook | Matcher | What It Does |
|------|---------|--------------|
| **guard.sh** | Bash | Blocks /tmp writes, commits on main, force push, destructive git |
| **doc-gate.sh** | Write\|Edit | Enforces file documentation headers and @decision on 50+ line files |
| **plan-check.sh** | Write\|Edit | Warns if writing source code without MASTER_PLAN.md |

### Layer 2: PostToolUse — Feedback After Execution

| Hook | Matcher | What It Does |
|------|---------|--------------|
| **lint.sh** | Write\|Edit | Auto-detects project linter, runs on modified files, exit 2 feedback loop |
| **track.sh** | Write\|Edit | Records which files changed this session |

### Layer 3: Session Lifecycle

| Hook | Event | What It Does |
|------|-------|--------------|
| **session-init.sh** | SessionStart | Injects git state, MASTER_PLAN.md status, worktrees |
| **compact-preserve.sh** | PreCompact | Preserves git state and session context before compaction |
| **surface.sh** | Stop | Validates @decision coverage, reports audit at session end |

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

## Command

| Command | Purpose |
|---------|---------|
| `/compact` | Create context summary before compaction |

---

## Directory Structure

```
~/.claude/
├── CLAUDE.md              # Sacred philosophical foundation
├── settings.json          # Configuration (hooks, permissions)
├── README.md              # This guide
│
├── hooks/                 # Deterministic enforcement
│   ├── log.sh             # Helper: structured logging (sourced by all hooks)
│   ├── guard.sh           # PreToolUse(Bash): sacred practice guardrails
│   ├── doc-gate.sh        # PreToolUse(Write|Edit): documentation enforcement
│   ├── plan-check.sh      # PreToolUse(Write|Edit): plan-first warning
│   ├── lint.sh            # PostToolUse(Write|Edit): auto-detect linter
│   ├── track.sh           # PostToolUse(Write|Edit): change tracking
│   ├── session-init.sh    # SessionStart: project context injection
│   ├── compact-preserve.sh # PreCompact: context preservation
│   └── surface.sh         # Stop: decision audit and validation
│
├── agents/                # The team of excellence
│   ├── planner.md         # Core Dogma: plan before implement
│   ├── implementer.md     # Test-first in isolated worktrees
│   └── guardian.md        # Protect repository integrity
│
├── skills/                # Non-deterministic intelligence
│   ├── decision-parser/   # Parse @decision syntax
│   └── context-preservation/ # Survive compaction
│
└── commands/              # User-invoked operations
    └── compact.md         # /compact context preservation
```

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

## Recovery

If needed, archived files are in `.archive/YYYYMMDD/`. Full backup at `~/.claude-backup-*.tar.gz`.
