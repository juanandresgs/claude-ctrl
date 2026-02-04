# Claude Code Setup Walkthrough — Team Presentation

**Duration**: 60 minutes
**Audience**: Technically competent engineers new to Claude Code internals
**Materials**: This doc, live demo of hooks firing, your actual `~/.claude` directory

---

## Agenda (60 min)

| Time | Section | Focus |
|------|---------|-------|
| 0:00 | **Mental Model** (10 min) | Why this exists, three principles |
| 0:10 | **CLAUDE.md & Progressive Disclosure** (10 min) | Instruction hierarchy, what goes where |
| 0:20 | **Hooks: Deterministic Enforcement** (15 min) | How hooks work, key hooks demo |
| 0:35 | **Agents: The Team of Excellence** (10 min) | Planner → Implementer → Guardian workflow |
| 0:45 | **Skills & Commands** (5 min) | Research system, /compact, /analyze |
| 0:50 | **Getting Started: Batteries Included** (10 min) | Clone, configure, first workflow |

---

## SECTION 1: Mental Model (10 min)

### The Problem Claude Code Solves

```
Traditional LLM Chat                Claude Code
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
"Write me a function"         →    Integrated IDE agent
Copy-paste into editor        →    Direct file access
No memory between sessions    →    CLAUDE.md + hooks persist
No enforcement                →    Hooks enforce practices
Ad-hoc                        →    Structured workflow
```

### Three Foundational Principles

```
┌──────────────────────────────────────────────────────────┐
│              THE THREE PRINCIPLES                         │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  1. CODE IS TRUTH                                        │
│     Documentation derives from source, never reverse     │
│     @decision annotations capture WHY in the code        │
│                                                          │
│  2. DECISIONS AT IMPLEMENTATION                          │
│     Capture rationale where it happens                   │
│     Not in a separate wiki that goes stale               │
│                                                          │
│  3. DETERMINISTIC ENFORCEMENT                            │
│     Hooks ALWAYS execute (binary: runs or doesn't)       │
│     Instructions DEGRADE with context (fuzzy: followed   │
│     less as context fills up)                            │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

**Key insight**: Instructions in CLAUDE.md compete for context window space with your actual work. Hooks don't — they execute outside the model's context.

### SOTA 2026 Context Management

From research and Anthropic guidance:

- **70% context = practical ceiling** — performance degrades nonlinearly past this
- **Observation masking** — replace old tool outputs with placeholders (52% cost savings)
- **Subagent isolation** — exploration consumes main context permanently; fork it
- **MCP bloat** — "If you're using more than 20k tokens of MCPs, you're crippling Claude"

**Actionable**: Keep CLAUDE.md ≤60 lines. Put everything else in on-demand docs.

---

## SECTION 2: CLAUDE.md & Progressive Disclosure (10 min)

### The Three-Layer Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    ALWAYS LOADED                                 │
│                    (~50-60 lines)                                │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ Root CLAUDE.md                                          │    │
│  │ • Project overview, essential commands                  │    │
│  │ • Tech stack with versions                              │    │
│  │ • Pointers to deeper docs                               │    │
│  │ • "Read relevant docs before starting" directive        │    │
│  └─────────────────────────────────────────────────────────┘    │
├─────────────────────────────────────────────────────────────────┤
│                    ON-DEMAND                                     │
│              (200-500 tokens per file)                           │
│  ┌───────────────┐ ┌───────────────┐ ┌───────────────┐         │
│  │ agents/*.md   │ │ docs/*.md     │ │ Child CLAUDE.md│         │
│  │ Complex       │ │ Architecture  │ │ Per-directory  │         │
│  │ workflows     │ │ decisions     │ │ conventions    │         │
│  └───────────────┘ └───────────────┘ └───────────────┘         │
├─────────────────────────────────────────────────────────────────┤
│                    SPECIALIZED AGENTS                            │
│                  (300-800 tokens each)                           │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ Triggered explicitly via Task tool or subagent          │    │
│  │ Full system prompt for specific domain                  │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

### What Goes In Root CLAUDE.md

**INCLUDE**:
```markdown
# Project build/test/lint commands (put these EARLY)
npm run build && npm run test

# Tech stack with versions
- Node.js 22, TypeScript 5.4, React 19

# Three-tier boundaries
ALWAYS: Run tests before commits
ASK FIRST: Changing auth flow
NEVER: Commit .env files

# Pointer to deeper docs
See agents/planner.md before starting new features
```

**EXCLUDE**:
- Code style rules → delegate to linters
- Vague directives → "write good code" wastes tokens
- Historical context → war stories don't help
- Task-specific instructions → put in skill files

### Live Demo: Show Your CLAUDE.md

```bash
# Show the lean root file
cat ~/.claude/CLAUDE.md | head -80

# Show the dispatch table — this is key
grep -A 10 "Dispatch Rules" ~/.claude/CLAUDE.md
```

**Key callout**: Notice the dispatch rules table — orchestrator doesn't write code directly, it invokes agents.

---

## SECTION 3: Hooks — Deterministic Enforcement (15 min)

### How Hooks Work

```
┌──────────────────────────────────────────────────────────────┐
│                     HOOK EXECUTION FLOW                       │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│   Claude wants to use a tool (Write, Edit, Bash, etc.)       │
│                           │                                  │
│                           ▼                                  │
│   ┌─────────────────────────────────────────────────────┐   │
│   │              PreToolUse Hooks Fire                   │   │
│   │   • Receive: tool name, tool input, cwd (JSON)      │   │
│   │   • Can: BLOCK, REWRITE input, add ADVISORY         │   │
│   └─────────────────────────────────────────────────────┘   │
│                           │                                  │
│                           ▼                                  │
│   ┌─────────────────────────────────────────────────────┐   │
│   │              Tool Executes (if not blocked)          │   │
│   └─────────────────────────────────────────────────────┘   │
│                           │                                  │
│                           ▼                                  │
│   ┌─────────────────────────────────────────────────────┐   │
│   │              PostToolUse Hooks Fire                  │   │
│   │   • Receive: tool name, input, output, cwd          │   │
│   │   • Can: Add ADVISORY context (can't block)         │   │
│   └─────────────────────────────────────────────────────┘   │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### Hook Response Types

| Response | When | Example |
|----------|------|---------|
| **DENY** | Block the action entirely | `guard.sh` blocks `git push --force` to main |
| **REWRITE** | Modify tool input | `guard.sh` rewrites `/tmp/foo` → `./tmp/foo` |
| **ADVISORY** | Add context, don't block | `lint.sh` shows lint warnings after edit |

### The 26 Hooks At-a-Glance

```
PRETOOLUSE (Block Before)          POSTTOOLUSE (Feedback After)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
guard.sh        → Sacred practices  lint.sh        → Auto-lint
test-gate.sh    → Tests must pass   track.sh       → Track changes
branch-guard.sh → No writes on main code-review.sh → MCP review
doc-gate.sh     → @decision enforce plan-validate.sh→ Plan alignment
plan-check.sh   → MASTER_PLAN warn  test-runner.sh → Async tests

SESSION LIFECYCLE                  SUBAGENT LIFECYCLE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
session-init.sh → Inject context   subagent-start.sh → Context inject
prompt-submit.sh→ Per-prompt ctx   check-planner.sh  → Validate output
compact-preserve→ Before compact   check-implementer → Validate output
session-end.sh  → Cleanup          check-guardian.sh → Validate output
surface.sh      → Decision audit
session-summary → Final report
forward-motion  → Next steps
```

### Key Hooks Deep Dive

**1. guard.sh — The Sacred Practice Enforcer**

```bash
# What it blocks:
- /tmp/ paths     → Rewrites to ./tmp/ (don't litter user's machine)
- git commit on main → Forces worktree workflow
- git push --force main → Protects main branch
- Destructive git ops → reset --hard, clean -f, etc.
```

**2. branch-guard.sh — Main is Sacred**

```
User request: "Add this function to utils.js"
                    │
                    ▼
         ┌─────────────────────┐
         │ branch-guard.sh    │
         │ checks: on main?   │
         └─────────┬──────────┘
                   │
        ┌──────────┴──────────┐
        │                     │
        ▼                     ▼
   [on main]             [on feature/]
   BLOCK + message:       ALLOW
   "Create a worktree
    for this work"
```

**3. doc-gate.sh — Code is Truth Enforcer**

```
On Write/Edit of files 50+ lines:
- Checks for file header comment
- Checks for @decision annotation
- Blocks if missing, shows example format
```

### Live Demo: Watch Hooks Fire

```bash
# Start Claude Code in a test directory
cd /tmp/hook-demo && git init && claude

# Try these and watch hooks fire:
# 1. "Write a file to /tmp/test.txt"  → guard.sh rewrites path
# 2. "git push --force origin main"   → guard.sh blocks
# 3. (on main) "Edit src/index.ts"    → branch-guard.sh blocks
```

### settings.json Structure

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{
          "type": "command",
          "command": "$HOME/.claude/hooks/guard.sh",
          "timeout": 5
        }]
      },
      {
        "matcher": "Write|Edit",
        "hooks": [
          {"command": "$HOME/.claude/hooks/test-gate.sh"},
          {"command": "$HOME/.claude/hooks/branch-guard.sh"},
          {"command": "$HOME/.claude/hooks/doc-gate.sh"}
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {"command": "$HOME/.claude/hooks/lint.sh"},
          {"command": "$HOME/.claude/hooks/test-runner.sh", "async": true}
        ]
      }
    ]
  }
}
```

---

## SECTION 4: Agents — The Team of Excellence (10 min)

### The Workflow: Never Run Straight Into Implementing

```
┌─────────────────────────────────────────────────────────────────┐
│                    THE CORE DOGMA                                │
│          "We NEVER run straight into implementing"               │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   User describes feature                                         │
│           │                                                      │
│           ▼                                                      │
│   ┌───────────────────┐                                         │
│   │  PLANNER (Opus)   │  Requirements → MASTER_PLAN.md          │
│   │                   │  + GitHub Issues                         │
│   └─────────┬─────────┘                                         │
│             │ User approves plan                                 │
│             ▼                                                    │
│   ┌───────────────────┐                                         │
│   │ GUARDIAN (Opus)   │  Creates git worktree                   │
│   │                   │  (main is sacred)                        │
│   └─────────┬─────────┘                                         │
│             │                                                    │
│             ▼                                                    │
│   ┌───────────────────┐                                         │
│   │IMPLEMENTER(Sonnet)│  Test-first development                 │
│   │                   │  @decision annotations                   │
│   │                   │  Progress checkpoints                    │
│   └─────────┬─────────┘                                         │
│             │ Code complete, tests pass                          │
│             ▼                                                    │
│   ┌───────────────────┐                                         │
│   │ GUARDIAN (Opus)   │  Review → Approve → Commit → Merge      │
│   │                   │  Update MASTER_PLAN.md                   │
│   └───────────────────┘                                         │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Agent Characteristics

| Agent | Model | Writes Code? | Key Responsibility |
|-------|-------|--------------|-------------------|
| **Planner** | Opus | No | Decompose requirements → issues |
| **Implementer** | Sonnet | Yes | Test-first code in worktree |
| **Guardian** | Opus | No | Git operations with approval |

### Agent File Structure

```markdown
# agents/planner.md (excerpt)

## Identity
You are the Planner agent. You transform requirements into
architecture and create MASTER_PLAN.md before any implementation.

## Phases
1. Requirement Analysis
2. Architecture Design
3. Issue Decomposition
4. MASTER_PLAN.md Generation
5. GitHub Issue Creation

## Output
- MASTER_PLAN.md with phases, decisions, success criteria
- One GitHub issue per implementation task
```

**Key insight**: Agent files are SYSTEM PROMPTS, not user prompts. They configure how the subagent behaves.

### The @decision Annotation

Captures architectural decisions at implementation point:

```typescript
/**
 * @decision DEC-AUTH-001
 * @title Use PKCE for mobile OAuth
 * @status accepted
 * @rationale Mobile apps cannot securely store client secrets.
 *            PKCE provides equivalent security without secrets.
 * @alternatives Considered: client credentials (rejected: secret storage),
 *               implicit flow (rejected: deprecated, less secure)
 */
export function initializeAuth() { ... }
```

**Why this matters**:
- Decisions stay with code (never goes stale)
- `doc-gate.sh` enforces this on 50+ line files
- `surface.sh` audits coverage at session end

---

## SECTION 5: Skills & Commands (5 min)

### Skills: Non-Deterministic Intelligence

Unlike hooks (deterministic, binary), skills require judgment:

| Skill | Purpose | Invoke |
|-------|---------|--------|
| **research-advisor** | Routes to optimal research method | `/research [query]` |
| **research-fast** | Quick synthesis via Gemini | `/research-fast [topic]` |
| **research-verified** | Multi-source with citations | `/research-verified [topic]` |
| **plan-sync** | Reconcile plan ↔ code | `/plan-sync` |
| **context-preservation** | Survive compaction | `/compact` |
| **generate-knowledge** | Analyze repo → knowledge kit | `/generate-knowledge` |

### Commands

| Command | What It Does |
|---------|--------------|
| `/compact` | Before context compaction — saves state to survive |
| `/analyze` | Bootstrap session with repo knowledge (loads generated kit) |

### Research System Architecture

```
          ┌────────────────────────┐
          │   /research [query]    │
          └───────────┬────────────┘
                      │
                      ▼
          ┌────────────────────────┐
          │   research-advisor     │
          │   (analyzes query)     │
          └───────────┬────────────┘
                      │
        ┌─────────────┼─────────────┐
        │             │             │
        ▼             ▼             ▼
   ┌─────────┐  ┌──────────┐  ┌──────────┐
   │research-│  │research- │  │last30days│
   │  fast   │  │ verified │  │          │
   │ 1-2 min │  │ 4-10 min │  │  2-5 min │
   │ Gemini  │  │ Citations│  │ Reddit/X │
   └─────────┘  └──────────┘  └──────────┘
```

---

## SECTION 6: Getting Started — Batteries Included (10 min)

### Step 1: Clone the Configuration

```bash
# Clone with submodules (research-verified, last30days)
git clone --recurse-submodules git@github.com:juanandresgs/claude-system.git ~/.claude

# Verify structure
ls ~/.claude/
# Should see: CLAUDE.md, hooks/, agents/, skills/, settings.json
```

### Step 2: Create Local Settings

```bash
cd ~/.claude
cp settings.local.example.json settings.local.json
```

Edit `settings.local.json` for your machine:
```json
{
  "model": "sonnet",
  "permissions": {
    "allow": ["Bash(sqlite3*)"]
  },
  "mcpServers": {
    "your-custom-mcp": { ... }
  }
}
```

### Step 3: Install Optional Dependencies

```bash
# macOS — desktop notifications
brew install terminal-notifier

# JSON processing (most hooks need this)
brew install jq  # or: apt install jq

# Research-fast skill (optional)
pip install google-generativeai
# Then set GEMINI_API_KEY in ~/.config/research-fast/.env
```

### Step 4: First Workflow — Watch It Work

```bash
# Start in a project
cd ~/my-project
claude

# Try the full workflow:
# 1. "I want to add a dark mode toggle"
#    → Planner creates MASTER_PLAN.md + issues
#
# 2. "Implement the first issue"
#    → Guardian creates worktree
#    → Implementer writes tests + code
#
# 3. "Commit and merge"
#    → Guardian reviews, asks approval, merges
```

### What You'll See

```
┌─────────────────────────────────────────────────────────────┐
│ Session starts:                                              │
│   session-init.sh → "Branch: main, 0 uncommitted files"     │
│                                                              │
│ You ask to implement:                                        │
│   plan-check.sh → "No MASTER_PLAN.md found. Create one?"    │
│                                                              │
│ You try to write on main:                                    │
│   branch-guard.sh → "BLOCKED: Create worktree first"        │
│                                                              │
│ You write code:                                              │
│   doc-gate.sh → "Add @decision annotation (50+ lines)"      │
│   lint.sh → "ESLint: 2 warnings"                            │
│   test-runner.sh → "Tests running..."                        │
│                                                              │
│ Session ends:                                                │
│   session-summary.sh → "Changed: 3 files, Next: merge PR"   │
└─────────────────────────────────────────────────────────────┘
```

### Customization Paths

| Want To... | Do This |
|------------|---------|
| Add a hook | Create script in `hooks/`, register in `settings.json` |
| Add an agent | Create `agents/myagent.md` with system prompt |
| Add a skill | Create `skills/myskill/SKILL.md` |
| Add a command | Create `commands/mycommand.md` |
| Override locally | Edit `settings.local.json` (gitignored) |

---

## Quick Reference Card (Handout)

```
┌─────────────────────────────────────────────────────────────────┐
│                 CLAUDE CODE QUICK REFERENCE                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  COMMANDS                                                        │
│    /compact      Save context before compaction                  │
│    /analyze      Bootstrap with repo knowledge                   │
│    /research     Smart research routing                          │
│    /hooks        Interactive hook editor (built-in)              │
│    /agents       Interactive agent editor (built-in)             │
│                                                                  │
│  AGENTS                                                          │
│    Planner       Plan before code (Opus)                         │
│    Implementer   Test-first code (Sonnet)                        │
│    Guardian      Git ops with approval (Opus)                    │
│                                                                  │
│  KEY HOOKS                                                       │
│    guard.sh      Sacred practices (no /tmp, no force push)       │
│    branch-guard  No writes on main                               │
│    doc-gate      @decision on 50+ line files                     │
│    test-gate     Tests must pass to write                        │
│                                                                  │
│  SACRED PRACTICES                                                │
│    1. Always use git                                             │
│    2. Main is sacred (use worktrees)                             │
│    3. No /tmp/ (use ./tmp/)                                      │
│    4. Nothing done until tested                                  │
│    5. Solid foundations (real tests, fail loudly)                │
│    6. No implementation without plan                             │
│    7. Code is truth (@decision annotations)                      │
│    8. Approval gates (commits need approval)                     │
│    9. Track in issues, not files                                 │
│                                                                  │
│  FILES                                                           │
│    ~/.claude/CLAUDE.md           Root instructions               │
│    ~/.claude/settings.json       Hook registration               │
│    ~/.claude/settings.local.json Machine-specific (gitignored)   │
│    ~/.claude/hooks/              Hook scripts                    │
│    ~/.claude/agents/             Agent prompts                   │
│    ~/.claude/skills/             Skill definitions               │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Appendix: Comparison to SOTA 2026 Recommendations

| Recommendation | Your Setup | Status |
|----------------|------------|--------|
| CLAUDE.md ≤60 lines | 75 lines (v2.0) | ✅ Close |
| Progressive disclosure | 3-layer architecture | ✅ Yes |
| Hooks for deterministic rules | 26 hooks | ✅ Yes |
| Subagent isolation | Planner/Implementer/Guardian | ✅ Yes |
| Proactive compaction | /compact + compact-preserve.sh | ✅ Yes |
| @decision in code | doc-gate.sh enforces | ✅ Yes |
| AGENTS.md cross-tool | CLAUDE.md (similar pattern) | ⚠️ Consider adding |
| MCP token awareness | Only context7 in base settings | ✅ Yes |

---

## Sources

- [Anthropic: Effective Context Engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
- [Anthropic: Claude Code Best Practices](https://www.anthropic.com/engineering/claude-code-best-practices)
- [GitHub: How to Write a Great AGENTS.md](https://github.blog/ai-and-ml/github-copilot/how-to-write-a-great-agents-md-lessons-from-over-2500-repositories/)
- [JetBrains Research: Efficient Context Management](https://blog.jetbrains.com/research/2025/12/efficient-context-management/)
- [Claude Code Docs: Custom Subagents](https://code.claude.com/docs/en/sub-agents)
- [Claude Code Hooks Mastery](https://github.com/disler/claude-code-hooks-mastery)
