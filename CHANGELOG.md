# Changelog

All notable changes to claude-system are documented here.

## [v2.0.0] - 2026-02-08

First public release. Full SDLC enforcement system with 24 deterministic hooks, 3 specialized agents, and research skills.

### Highlights

- **24 hooks + 2 shared libraries** covering every Claude Code lifecycle event
- **3 agents** (Planner, Implementer, Guardian) with defined responsibilities and model assignments
- **Split settings architecture** — tracked universal config + gitignored local overrides
- **Research skills** — multi-model deep research and recent web discussion analysis
- **CI/CD** — GitHub Actions for hook validation, shellcheck, and contract tests
- **Open source infrastructure** — MIT license, contributing guide, issue/PR templates

### Hook System

- `guard.sh` — Sacred practice guardrails: /tmp rewrite, --force-with-lease, main protection, test evidence gate, proof-of-work gate
- `auto-review.sh` — Three-tier intelligent command auto-approval (safe/behavior-dependent/risky)
- `test-gate.sh` — Escalating test-failure gate (warn then block)
- `mock-gate.sh` — Internal mock detection with escalating enforcement
- `branch-guard.sh` — Hard deny for source writes on main/master
- `doc-gate.sh` — File header and @decision annotation enforcement
- `plan-check.sh` — Plan-first enforcement (no code without MASTER_PLAN.md)
- `lint.sh` — Auto-detect project linter, exit 2 retry loop
- `track.sh` — Per-session change tracking
- `code-review.sh` — Multi-MCP code review integration
- `plan-validate.sh` — MASTER_PLAN.md structural validation
- `test-runner.sh` — Async background test execution
- `session-init.sh` — Context injection at session start
- `prompt-submit.sh` — Per-prompt context injection
- `compact-preserve.sh` — Context preservation before compaction
- `session-end.sh` — Session cleanup
- `surface.sh` — @decision coverage audit at session end
- `session-summary.sh` — Deterministic session summary
- `forward-motion.sh` — Forward momentum check
- `notify.sh` — Desktop notifications (macOS)
- `subagent-start.sh` — Agent context injection
- `check-planner.sh` — Planner output validation
- `check-implementer.sh` — Implementer output validation
- `check-guardian.sh` — Guardian output validation

### Development History

Key milestones from 73 commits leading to this release:

- **Initial commit** — Claude System v2.0 framework foundation
- **Living Documentation** — Source-based decision tracking with @decision annotations
- **Hook system overhaul** — Replaced AI-based hooks with deterministic command hooks
- **Core Dogma enforcement** — Hard blocks for plan-first, main-branch, and guardian workflows
- **Test enforcement** — test-before-commit across all agent layers
- **Sacred Practice #9** — Track deferred work in GitHub Issues, not files
- **CLAUDE.md v2.0** — Progressive disclosure rewrite (335 to 75 lines)
- **Split settings** — Portable universal config + machine-specific overrides
- **Feedback Spine** — Closed 9 feedback loop gaps across hook system
- **Deep research integration** — Multi-model research in agent protocols
- **Proof-of-work gate** — User must verify feature before commit
- **Auto-review hook** — Intelligent command classification replaces blanket permission prompts
- **Backlog system** — Persistent todo management via GitHub Issues
- **Public release** — README rewrite, title update, advisory pattern refinement
