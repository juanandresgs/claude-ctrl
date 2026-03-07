<p align="center">
  <img src="assets/banner.jpeg" alt="The Systems Thinker's Deterministic Claude Code Control Plane" width="100%">
</p>

# The Systems Thinker's Deterministic Claude Code Control Plane

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/juanandresgs/claude-ctrl)](https://github.com/juanandresgs/claude-ctrl/stargazers)
[![Last commit](https://img.shields.io/github/last-commit/juanandresgs/claude-ctrl)](https://github.com/juanandresgs/claude-ctrl/commits/main)
[![Shell](https://img.shields.io/badge/language-bash-green.svg)](hooks/)

**Instructions guide. Hooks enforce.**

A deterministic governance layer for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Shell-script hooks intercept every tool call — Bash commands, file writes, agent dispatches, session boundaries — and enforce development discipline mechanically. Four specialized agents (Planner, Implementer, Tester, Guardian) handle the full lifecycle. The model doesn't decide the process. The hooks do.

---

## Design Philosophy

Tell a model "never commit on main" and it works — until context pressure erases the rule. After compaction, after cognitive load, after forty minutes of deep implementation, constraints that live in the model's memory aren't constraints. They're suggestions. Wire a hook that fires before every Bash command and mechanically denies commits on main — and it works regardless of what the model remembers or forgets.

LLMs are not deterministic systems with probabilistic quirks. They are **probabilistic systems** — and the only way to harness them into producing reliably good outcomes is through deterministic, event-based enforcement. An instruction is a hope. A feedback loop is a mechanism. Cybernetics gave us this framework decades ago.

This system enforces. The observatory analyzes. The traces feed back. The gates adapt. Every version teaches me something about how to govern probabilistic systems, and those lessons feed into the next iteration. I call the end-state goal **Self-Evaluating Self-Adaptive Programs (SESAPs)** — probabilistic systems constrained to deterministically produce a range of desired outcomes. Not controlled through instruction. Controlled through mechanism.

Most AI coding harnesses today rely entirely on prompt-level guidance for constraints. Claude Code is one of the few that provides comprehensive event-based hooks — the mechanical layer that makes deterministic governance possible. Without it, every session is a bet against context pressure. This project is meant to address the disturbing gap between developers at the frontier and the majority of token consumers vibing at the roulette wheel hoping for a payday.

I've never been much of a gambler.

*— JAGS*

---

<h2 align="center">Metanoia v3.0</h2>

<p align="center"><em>metanoia (n.) — a fundamental change in thinking; a transformative shift in approach</em></p>

<p align="center"><strong>617 commits over v2.0</strong> — a ground-up refactor of the hook architecture,<br>state management, and agent governance.</p>

---

### The Headline

17 individual hook scripts consolidated into **4 entry points** backed by **10 lazy-loaded domain libraries**.

The result: **74% less hook overhead** per session. Zero governance loss.

### Before and After

```
v2.0                                    v3.0 (Metanoia)
────────────────────────────────────    ────────────────────────────────────
17 hooks firing independently           4 consolidated entry points
~26s hook overhead/session              ~6.7s hook overhead/session
54 tests                                160+ tests
macOS only                              macOS + Ubuntu CI
Flat-file state                         Per-worktree isolated state store
3 agents                                4 agents (+ Tester with auto-verify)
Manual worktree management              Auto-sweep, roster, CWD recovery
```

### New Capabilities

- **Lint-on-write** — shellcheck/ruff/cargo clippy runs synchronously on every Write/Edit
- **Dispatch enforcement** — hooks mechanically block the orchestrator from writing source code directly
- **Cross-project isolation** — SHA-256 project hashing prevents state contamination across concurrent sessions
- **Proof-before-commit chain** — Implement → Test → Verify → Commit, each gate enforced by hooks
- **Self-validation** — version sentinels, `bash -n` preflight, hooks-gen integrity check at startup
- **Observatory** — self-improving flywheel that analyzes agent traces and surfaces improvement signals

See the full [CHANGELOG](CHANGELOG.md) for the complete list.

---

## What This Changes

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
                │  Tester agent: live E2E verification          │
                │  → proof-of-work evidence written to disk     │
                │  → check-tester.sh: auto-verify or           │
                │    surface report for user approval           │
                └──────────────────────┬───────────────────────┘
                                       ▼
                ┌──────────────────────────────────────────────┐
                │  Guardian agent: commit (requires verified    │
                │  proof-of-work + approval) → merge to main   │
                └──────────────────────────────────────────────┘
```

Every arrow is a hook. Every feedback loop is automatic. The model doesn't choose to follow the process — the hooks won't let it skip. Try to write code without a plan and you're pushed back. Try to commit with failing tests and you're pushed back. Try to skip documentation and you're pushed back. Try to commit without tester sign-off and you're pushed back. The system self-corrects until the work is right.

**The result:** you move faster because you never think about process. The hooks think about it for you. Dangerous commands get denied with corrections (`--force` → use `--force-with-lease`, `/tmp/` → use project `tmp/`). Everything else either flows through or gets caught. You just describe what you want and review what comes out.

---

## Platform at a Glance

```
~/.claude/
├── hooks/          # Hook scripts + shared libraries (the enforcement layer)
├── agents/         # Planner, Implementer, Tester, Guardian
├── skills/         # Research, governance, and workflow skills
├── commands/       # Slash commands (/compact, /backlog)
├── scripts/        # Utility scripts (worktree roster, timing reports, CI watch)
├── observatory/    # Self-improving trace analysis flywheel
├── traces/         # Agent execution archive
├── tests/          # 160+ hook validation tests
├── ARCHITECTURE.md # Definitive technical reference
├── CLAUDE.md       # Session instructions (loaded every time)
└── settings.json   # Hook registration + model config
```

---

## Getting Started

### Prerequisites

bash 3.2+, git 2.20+, jq 1.6+, and standard POSIX utils. Platform-specific: `shasum` or `sha256sum`, `lockf` (macOS) or `flock` (Linux) — both auto-detected. Run `bash scripts/check-deps.sh` after cloning to verify.

### 1. Clone

```bash
# SSH
git clone --recurse-submodules git@github.com:juanandresgs/claude-ctrl.git ~/.claude

# Or HTTPS
git clone --recurse-submodules https://github.com/juanandresgs/claude-ctrl.git ~/.claude
```

If you already have a `~/.claude` directory, back it up first: `tar czf ~/claude-backup-$(date +%Y%m%d).tar.gz ~/.claude`

### 2. Configure

```bash
cp settings.local.example.json settings.local.json
# Edit to set your model preference, MCP servers, plugins
```

Settings are split: `settings.json` (tracked, universal) and `settings.local.json` (gitignored, your overrides). Claude Code merges both, with local taking precedence.

### 3. Verify

On your first `claude` session, you should see the SessionStart hook inject git state, plan status, and worktree info. Try writing a file to `/tmp/test.txt` — `pre-bash.sh` will deny it and direct you to use `tmp/test.txt` in the project root instead.

**Optional extras:** `gh` CLI for issue tracking, `terminal-notifier` for macOS alerts, API keys (OpenAI/Perplexity/Gemini) for the `deep-research` skill. Everything degrades gracefully without them.

### Staying Updated

The harness auto-checks for updates on every new session start. Same-MAJOR-version updates are applied automatically. Breaking changes (different MAJOR version) show a notification — you decide when to apply.

- **Auto-updates enabled by default.** Create `~/.claude/.disable-auto-update` to disable.
- **Manual update:** `cd ~/.claude && git pull --autostash --rebase`
- **Fork users:** Your `origin` points to your fork, so you get your own updates. Add an `upstream` remote to also track the original repo.
- **Local customizations safe:** `settings.local.json` and `CLAUDE.local.md` are gitignored. If you edit tracked files, `--autostash` preserves your changes. If a conflict occurs, the update aborts cleanly and you're notified.

---

## Sacred Practices

Ten rules. Each one enforced by hooks that fire every time, regardless of what the model remembers.

| # | Practice | What Enforces It |
|---|----------|-------------|
| 1 | **Always Use Git** | `session-init.sh` injects git state; `pre-bash.sh` blocks destructive operations |
| 2 | **Main is Sacred** | `pre-write.sh` (branch-guard logic) blocks writes on main; `pre-bash.sh` blocks commits on main |
| 3 | **No /tmp/** | `pre-bash.sh` denies `/tmp/` paths and directs model to use project `tmp/` directory |
| 4 | **Nothing Done Until Tested** | `pre-write.sh` (test-gate logic) warns then blocks source writes when tests fail; `pre-bash.sh` requires test evidence for commits |
| 5 | **Solid Foundations** | `pre-write.sh` (mock-gate logic) detects and escalates internal mocking (warn → deny) |
| 6 | **No Implementation Without Plan** | `pre-write.sh` (plan-check logic) denies source writes without MASTER_PLAN.md |
| 7 | **Code is Truth** | `pre-write.sh` (doc-gate logic) enforces headers and @decision on 50+ line files |
| 8 | **Approval Gates** | `pre-bash.sh` blocks force push; Guardian agent requires approval for all permanent ops |
| 9 | **Track in Issues** | `post-write.sh` (plan-validate logic) checks alignment; `check-planner.sh` validates issue creation |
| 10 | **Proof Before Commit** | `check-tester.sh` auto-verify evaluation; `prompt-submit.sh` user approval gate; `pre-bash.sh` evidence gate on commits |

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
| CWD bricked after worktree deletion | pre-bash.sh Check 0.75 denies cd into worktrees. Use `git -C <path>` or subshell `(cd <path> && cmd)` instead |
| Stale `.proof-status` blocking commits | Delete `.claude/.proof-status` manually, or re-run the tester to generate fresh evidence |

## Recovery and Uninstall

Archived files are stored in `.archive/YYYYMMDD/`. Full backups at `~/claude-backup-*.tar.gz`.

To debug a hook: `echo '{"tool_name":"Bash","tool_input":{"command":"git status"}}' | bash hooks/pre-bash.sh`

**Uninstall:** Remove `~/.claude` and restart Claude Code. It will recreate a default config directory. Your projects are unaffected.

---

## Go Deeper

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — System architecture, design decisions, subsystem deep-dive
- [`hooks/HOOKS.md`](hooks/HOOKS.md) — Full hook reference: protocol, state files, shared libraries
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — How to contribute
- [`CHANGELOG.md`](CHANGELOG.md) — Release history
