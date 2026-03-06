# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- `feature/fix-bootstrap-paradox`: Bootstrap paradox mitigation — M1: CAS failure diagnostic counter in prompt-submit.sh warns orchestrator after 2+ consecutive cas_proof_status failures (detects broken gate infrastructure); M2: @plan-update/@no-source annotations bypass proof-status gate in task-track.sh for documentation-only merges; 8 new bootstrap mitigation tests (DEC-BOOTSTRAP-PARADOX-001, DEC-BOOTSTRAP-PARADOX-002, DEC-BOOTSTRAP-TEST-001) (#105)
- `feature/fix-proof-status-accumulation`: Prevent .proof-status-* dotfile accumulation — _SHA256_CMD init guard in core-lib.sh (Bug A), trailing-slash normalization in get_claude_dir() (Bug B), 4h TTL sweep of stale proof files in session-end.sh (Bug C), post-read cleanup after outcome derivation (Bug D), legacy double-nested path removal (Bug E); 4 new proof-cleanup tests (DEC-SHA256-INIT-001, DEC-PROOF-SWEEP-001)
- `worktree-agent-af02ba8c`: Statusline term_w clamping — COLUMNS < 80 now clamps to 120 instead of aggressive responsive dropping; lets Claude Code UI handle final clipping (DEC-STATUSLINE-TERMWIDTH-002)
- `feature/fix-guardian-double-ask`: Include AUTO-VERIFY-APPROVED in manual approval dispatch so Guardian skips its Interactive Approval Protocol when user has already approved via prompt-submit.sh gate; added "Manual Approval Fast Path" documentation to DISPATCH.md
- `feature/fix-prompt-submit-104`: Fix prompt-submit.sh verification gate silent failure — fast path checks approval keywords immediately (<500ms) before library loading; deferred require_*() calls to point of first use; CAS lock timeout 5s to 2s with stale lock cleanup and signal trap; breadcrumb notification (.proof-gate-pending) warns on interrupted verification; fix _HOOK_NAME initialization clobbering in core-lib.sh; hook timeout 5s to 10s; pre-write.sh recognizes /.claude/worktrees/ paths; 4 new proof lifecycle tests T12-T15 (DEC-PROMPT-FAST-001, DEC-PROMPT-BREADCRUMB-001)
- `feature/fix-statusline-bugs`: Statusline truncation, empty banner, and token path bugs — terminal width COLUMNS=0 fallback chain with [40,200] clamp (DEC-STATUSLINE-TERMWIDTH-001); planned-phase banner fallback renders dim `[planned]` label when no in-progress phase (DEC-PLANLIB-PLANNED-PHASE-001, DEC-STATUSLINE-PLANNED-PHASE-001); token persistence path aligned with get_claude_dir() to fix double-nesting for ~/.claude projects (DEC-STATUSLINE-TOKEN-PATH-001)
- `feature/fix-zombie-code`: 5-layer zombie code prevention — tester Phase 2 entry-point-first verification (Layer 1), implementer Phase 3.25 integration wiring step (Layer 2), tester Phase 2.5 cross-component integration for phase-completing dispatches (Layer 3), post-task.sh auto-verify backstop blocks when no integration assessment found (DEC-AV-IWIRE-001) (Layer 4), extract dispatch protocol to docs/DISPATCH.md for token efficiency (DEC-DISPATCH-EXTRACT-001) (Layer 5)
- `feature/fix-statusline-flicker`: Startup banner flicker — consolidated 13 separate jq subprocess calls into 1 batched read with unit-separator delimiter (DEC-TODO-SPLIT-002 update); always emit Line 3 newline regardless of initiative presence so status bar height is stable at 3 lines, eliminating resize-triggered flicker during cache population (DEC-STATUSLINE-005)
- `feature/fix-wiring-gate-bugs`: Resolve 3 integration wiring gate bugs — broaden Check 7b path filter to cover `/scripts/` (#101), remove 36 lines of dead community-check.sh code and phantom source-lib.sh comment (#102), remove phantom skill entries (uplevel, generate-paper-snapshot) from CLAUDE.md and create missing observatory/SKILL.md (#103)
- `feature/fix-fd-leak`: FD inheritance bug — background heartbeat in task-track.sh held inherited pipe FDs from `$()` command substitution, causing test-proof-gate.sh to hang ~5min; defensive `>/dev/null 2>&1` on all background spawns in 4 hooks; SECONDS timing regression test; CI timeout-minutes: 5 (DEC-GUARDIAN-HEARTBEAT-002)
- `fix/test-health-audit`: Stale test cleanup and CI coverage — delete test-trace-orphan-fix.sh (tested removed function), fix JSON assertion regex in test-guard-commit-msg.sh, update hooks list 29->34 in test-source-lib.sh, add 9 standalone test suites to CI validate.yml
- `fix/guardian-perf`: Guardian agent performance overhaul — Step 0 fail-fast precondition check (RC1: wasted turns on doomed dispatches), merge classification tiers Simple/Phase-Completing (RC2-RC5: unnecessary plan reads and drift analysis on simple merges), Gate A.0 duplicate guardian detection in task-track.sh (RC7: burst dispatch prevention), heartbeat ceiling 3->5 min (RC6: premature timeout with max_turns=35), CHANGELOG commit on feature branch before merge, auto-verify bypass scope reduction (DEC-GUARDIAN-HEARTBEAT-002)
- `fix/native-lock`: OS-native file locking — replace `_portable_flock()` (homebrew Cellar glob discovery) with `_lock_fd()` using `uname -s` detection: `lockf` on macOS, `flock` on Linux; zero external dependencies; added `lockf` bare fallback in log.sh, prompt-submit.sh, state-lib.sh (DEC-LOCK-NATIVE-001)
- `fix/remediation-silent-failures`: Phase 1 hook cleanup path silent failures — glob pattern for `.active-*` markers includes trailing `*` for phash suffix; `.proof-epoch` cleanup in session-end.sh and check-guardian.sh; marker cleanup in task-track.sh Gate B scoped to current project's phash; pre-bash.sh Check 10 uses `resolve_proof_file()` instead of inline fallback; 2 new regression tests
- `fix/flock-macos`: Portable flock(1) for macOS — `_portable_flock()` helper in core-lib.sh discovers flock from PATH, homebrew ARM, homebrew Intel, or degrades gracefully; replaced `declare -A` with case-based helper in log.sh for bash 3.2 compatibility; fallback chains in prompt-submit.sh and state-lib.sh (DEC-FLOCK-COMPAT-001)
- `feature/fix-silent-return`: Silent return bug — 73% of agent completions bypassed post-task.sh fallback because it gated on `tool_name=Task` while agents fire with `tool_name=Agent`; added IS_SUBAGENT normalization, _write_diagnostic_summary() for auto-reconstructing missing summary.md, extended subagent type detection to all 4 agent types, reduced stale marker threshold 7200s to 1800s; 14 new tests (#158)
- PostToolUse matcher `Task` -> `Task|Agent` — auto-verify hook (post-task.sh) never fired because the dispatched tool is named "Agent", not "Task"; also bumped check-tester.sh timeout 5s -> 15s for 308+ trace dirs; added SP#8 auto-verify exception to CLAUDE.md
- `feature/fix-bootstrap-amendment`: Bootstrap vs amendment flow — hooks now detect whether MASTER_PLAN.md is already tracked and only permit first-time creation on main; amendments route through worktrees
- `feature/fix-comment-false-positive`: Strip bash comments from `_stripped_cmd` in pre-bash.sh — prevents false-positive guard denials when agent-generated comments mention git keywords like "git commit"; adds Tests 14-15 for regression coverage (DEC-GUARD-002)
- `feature/autoverify-race-fix`: Auto-verify race condition — `.active-autoverify-*` markers protect the `proof-status = verified` window between auto-verify write and Guardian dispatch, preventing `post-write.sh` from invalidating the status (#56)
- `feature/proof-lifecycle`: Proof lifecycle reliability — detect_project_root() reads .cwd from HOOK_INPUT, write_proof_status() pre-creates guardian marker + state.json dual-write, post-task.sh emits DISPATCH TESTER NOW after implementer, prompt-submit.sh emits DISPATCH GUARDIAN NOW on verification; new state-lib.sh coordination layer; 11 new tests
- `fix/sigpipe-crashes`: SIGPIPE (exit 141) crashes in session-init.sh and context-lib.sh when MASTER_PLAN.md has large sections — replaced 20 pipe patterns with SIGPIPE-safe equivalents (awk inline limits, bash builtins, single-pass awk); added 14-test SIGPIPE resistance suite
- `fix/stale-marker-blocking-tester`: Stale `.active-*` marker race condition blocking tester dispatch — reorder `finalize_trace` before timeout-heavy ops in check-implementer.sh and check-guardian.sh, add marker cleanup in `refinalize_trace()`, add completed-status fast path in task-track.sh Gate B
- Observatory SUG-ID instability across runs (force state v1→v3 migration)
- Observatory duration UTC timezone bug in finalize_trace
- Guard long-form force-deletion variant detection in branch guard
- Check 5 worktree-remove crash on paths with spaces
- Proof-status path mismatch in git worktree scenarios
- Verification gate: escape hatch, empty-prompt awareness, env whitelist
- Tester AND logic for completeness gate + finalize_trace verification fallback
- Post-compaction amnesia with computed resume directives
- Meta-repo exemption for guard.sh proof-status deletion check
- Subagent tracker scoped to per-session thread
- Hook library race condition during git merge (session-scoped caching)
- Cross-platform stat for Linux CI (4 trace contract test failures)
- Shellcheck failures: tilde bug + expanded exclusions
- README documentation for `update-check.sh` location (lives in `scripts/`, called by `session-init.sh`)
- Observatory .test-status fallback to finalize_trace test result detection

### Added
- `feature/dispatch-gate`: Gate 0 (dispatch-confirmation-deny) in pre-ask.sh — mechanically blocks orchestrator dispatch-confirmation questions ("Want me to dispatch Guardian?") enforcing CLAUDE.md auto-dispatch rules; fires before orchestrator bypass so it catches this specific anti-pattern while allowing legitimate questions through; 3 new test fixtures + 3 new test cases (DEC-ASK-GATE-001 updated)
- `feature/production-reliability`: Production Reliability Phase 4+5 — macOS CI matrix (ubuntu-latest + macos-latest) with 10min timeout, shellcheck extended to tests/ and scripts/; README.md and ARCHITECTURE.md updated from old individual hook names to consolidated entry points (pre-bash.sh, pre-write.sh, post-write.sh, stop.sh)
- `feature/phase2-state-consolidation`: State management consolidation — `_lock_fd()` wired into state-lib.sh and log.sh replacing inline flock fallback chains; `cas_proof_status()` in prompt-submit.sh rewritten for true atomic CAS with lattice validation; Gate C.2 in task-track.sh routed through `write_proof_status()`; check-guardian.sh adds "committed" transition before cleanup; pre-bash.sh Checks 9+10 adopt `is_protected_state_file()` registry (DEC-STATE-REGISTRY-002); `state_write_locked()` removed (dead code); 15 concurrency tests updated (DEC-STATE-CAS-002, DEC-STATE-LATTICE-001)
- `feature/production-reliability`: Production Reliability Phase 1+2 — CI auto-discovers test files via `find` instead of hardcoded list in validate.yml; grep-to-jq JSON parsing conversions in test-pre-ask.sh and test-ci-feedback.sh; `run_hook()`/`run_hook_ec()` capture stderr to `$HOOK_STDERR` instead of swallowing; cleanup traps added to 31 test files; JSONL rotation (1000 lines), timing log rotation, orphan marker sweep in session-init.sh; TTL sentinels scoped to `$CLAUDE_SESSION_ID` in stop.sh; MASTER_PLAN.md amended with new initiative (5 phases, 16 work items)
- `feature/integration-gates`: Strengthen integration wiring gates — declaration-trap warnings in tester Phase 2.5 and implementer checklist (catch `mod`/`import` declarations without actual consumers); phantom-reference Check 7b in check-implementer.sh verifies settings.json hook command paths resolve to existing files (DEC-IWIRE-002)
- `feature/phase1-coordination`: Phase 1 coordination protocol — protected state file registry in core-lib.sh with `is_protected_state_file()`, CAS (compare-and-swap) semantics via `state_write_locked()` in state-lib.sh, `.proof-epoch` session initialization, `cas_proof_status()` delegation in prompt-submit.sh, Gate 0 refactored to use registry; 12 new concurrency tests + `--scope concurrency` in run-hooks.sh (DEC-STATE-REGISTRY-001, DEC-STATE-CAS-001, DEC-PROOF-CAS-REFACTOR-001, DEC-CONCURRENCY-TEST-001) (#76)
- `feature/responsive-statusline`: Priority-based responsive segment dropping — when terminal width is insufficient, segments drop from lowest priority first (fully, not mid-word); `ansi_visible_width()` helper; cold-start cache fix in track-agent-tokens.sh writes full 14-field schema; SIGPIPE fix in test-statusline.sh (exit 141) converting 22 direct-pipe patterns to capture-then-extract; 6 new responsive tests + 1 cold-start test (66/66 + 11/11) (DEC-RESPONSIVE-001)
- `feature/backlog-gaps`: Phase 3 unified gaps report — gaps-report.sh (575 lines) combines debt markers, missing @decision annotations, stale issues, unclosed worktrees, and hook coverage into a single accountability report; /gaps command wrapper; hook dead-code cleanup in log.sh, prompt-submit.sh, state-lib.sh, task-track.sh; 13 new gaps tests (78 total) (#83)
- `feature/backlog-scanner`: scan-backlog.sh rg-based codebase debt marker scanner (TODO, FIXME, HACK, WORKAROUND, OPTIMIZE, TEMP, XXX) with JSON/table/text output formats, grep fallback, recursive directory scanning; /scan command wrapper for orchestrator dispatch; 15 new scan tests (#82)
- `feature/statusline-banner`: Redesign initiative segment as Line 0 banner — replace cryptic inline "Robust+1:P0" with dedicated top-line showing full initiative name, phase progress (N/M), and phase title with em dash subtitle; statusline is now 3 lines when active initiative exists, 2 lines otherwise (backward compatible); per-initiative phase counting (DEC-STATUSLINE-004); Group 12 rewritten with 6 banner tests (#91)
- `feature/statusline-initiative`: Initiative/phase context in statusline — shows active initiative name and in-progress phase (e.g. "Backlog:P3") between workspace and git clusters; truncates long names, +N suffix for multiple initiatives; 6 new tests (#91)
- `feature/subagent-token-tracking`: Universal SubagentStop hook parses agent transcript JSONL to accumulate token usage; statusline shows combined tokens as `tokens: 145k (Σ240k)` with sigma grand total; 10 new tests (cc-todos#37)
- `feature/backlog-foundation`: todo.sh backlog backing layer (hud/count/claim/create) + fire-and-forget auto-capture of deferred-work language in prompt-submit.sh; 15 new tests (#81)
- `feature/cache-audit`: @decision annotations for statusline dependency chain (DEC-STATUSLINE-DEPS-001) and prompt cache semantics (DEC-CACHE-RESEARCH-001); .gitignore entries for `.session-cost-history` and `.test-status` (#66, #70)
- `feature/project-isolation`: Cross-project state isolation via 8-char SHA-256 project hash — scopes .proof-status, .active-worktree-path, and trace markers per project root to prevent state contamination across concurrent Claude Code sessions; three-tier backward-compatible lookup; 20 new isolation tests
- `feature/plan-redesign-tests`: Phase 4 test suite for living plan format — 16 new tests across 2 suites (test-plan-lifecycle.sh, test-plan-injection.sh) validating initiative lifecycle edge cases and bounded session injection; bug fix for empty Active Initiatives section returning active instead of dormant (#142)
- **Documentation audit** — 38 discrepancies resolved: hardcoded hook counts removed, 3 undocumented hooks documented, /approve eradicated, updatedInput contradiction corrected, tester max_turns fixed
- **doc-freshness.sh** — PreToolUse:Bash hook enforcing documentation freshness at merge time; blocks merges to main when tracked docs are critically stale
- **check-explore.sh** — SubagentStop:Explore hook for post-exploration validation of Explore agent output quality
- **check-general-purpose.sh** — SubagentStop:general-purpose hook for post-execution validation of general-purpose agent output quality
- **Worktree Sweep** — Three-way reconciliation (filesystem/git/registry) with session-init orphan scan, post-merge Check 7b auto-cleanup, and proof-status leak fix (`scripts/worktree-roster.sh`, `hooks/session-init.sh`, `hooks/check-guardian.sh`)
- **Trace Analysis System** — Agent trace indexing and outcome classification (`hooks/context-lib.sh`)
- **Tester Agent** — Fourth agent for end-to-end verification with auto-verify fast path (`agents/tester.md`, `hooks/check-tester.sh`)
- **Checkpoint System** — Git ref-based snapshots before writes with `/rewind` restore skill (`hooks/checkpoint.sh`, `skills/rewind/`)
- **CWD Recovery** — Three-path system for worktree deletion CWD death spiral: directed recovery (Check 0.5 Path A), canary-based recovery (Path B), prevention (Check 0.75) in `guard.sh`
- **Cross-Session Learning** — Session-aware hooks with trajectory guidance, friction pattern detection (v2 Phase 4)
- **Session Summaries in Commits** — Structured session context embedded in commit metadata (v2 Phase 2)
- **Session-Aware Hooks** — Trajectory-based guidance, compaction-safe resume directives (v2 Phase 3)
- **SDLC Integrity Layer** — Guard hardening, state hygiene, preflight checks (Phase A)
- **Tester Completeness Gate** — Check 3 in check-tester.sh validates verification coverage
- **Deterministic Comparison Matrix** — Deep-research two-pass matching with content-based analysis
- **Environment Variable Handoff** — Implementer-to-tester environment variable propagation
- **/diagnose Skill** — System health checks integrated into agent pipeline
- **/approve Command** — Quick-approve verification gate
- **Guard Check 0.75** — Subshell containment for `cd` into `.worktrees/` directories
- Security policy (SECURITY.md) with vulnerability reporting guidelines
- Changelog following Keep a Changelog format
- Standards compliance documentation
- ARCHITECTURE.md comprehensive technical reference (this release)

### Changed
- `feature/statusline-data`: Phase 2 data pipeline — todo split display (`todos: 3p 7g` with project/global counts), session cost persistence to `.session-cost-history`, lifetime cost annotation (`Σ~$12.40`) next to session cost; +9 new tests (48 total dedicated) (#72)
- `feature/statusline-rendering`: Statusline rendering overhaul — domain-clustered labels (`dirty:`, `wt:`, `agents:`, `todos:`), aggregate token segment with K/M notation, `~$` cost prefix; +12 new tests (39 total dedicated)
- `feature/statusline-redesign`: Two-line status HUD — line 1 shows project context (model, workspace, dirty files, worktrees, agents, todos), line 2 shows session metrics (context window bar, cost, duration, lines changed, cache efficiency); removed plan phase, test status, community segment, version, and stale worktree detection from statusline; 26 new dedicated tests
- `feature/dispatch-reliability`: Dispatch sizing rules, turn-budget discipline, and planner dispatch plans — orchestrator splits large phases into 2-3 item batches, implementer self-regulates with budget notes and early return at 15 turns, planner generates per-phase dispatch plans (#43)
- `feature/observatory-stdout`: Observatory report.sh now prints a concise stdout summary (regressions, health, signals, batches) after writing the full report file, so callers get actionable output without reading the file
- `feature/living-plan-hooks`: Living MASTER_PLAN format — initiative-level lifecycle with dormant/active states, get_plan_status() rewrite, plan-validate.sh structural validation, bounded session-init injection (796->81 lines), compress_initiative() for archival (#140)
- `refactor/shared-library`: Phase 8 shared library consolidation — 13 hooks converted from raw jq to `get_field()`, `get_session_changes()` ported to context-lib.sh with glob fallback, SOURCE_EXTENSIONS unified, context-lib.sh chmod 755; plus DEC-PROOF-PATH-003 meta-repo proof-status double-nesting fix (#7, #137)
- **Planner create-or-amend workflow** — `agents/planner.md` rewritten (391->629 lines) to support both creating new MASTER_PLAN.md and amending existing living documents with new initiatives; auto-detects plan format via `## Identity` marker (#139)
- **Tester agent rewrite** — 8 targeted fixes for 37.5% failure rate: feature-match validation, test infrastructure discovery, early proof-status write, hook/script table split, worktree path safety, meta-infra exception, retry limits, mandatory trace protocol
- **Auto-verify restructured** — Runs before heavy I/O for faster verification path
- **Observatory assessment overhaul** — Comprehensive reports, comparison matrix, deferred lifecycle management
- **Observatory signal catalog** — Extended from 5 to 12 signals across 4 categories
- **Session-init performance** — Startup latency reduced from 2-10s to 0.3-2s with 4 targeted fixes
- **Guardian auto-cleans worktrees** after merge instead of delegating to user
- **Deep-research matrix matching** — Simplified to heading-only with LLM unmatched_hints
- GitHub Actions now pin to commit SHAs for supply chain security
- Guard rewrite calls converted to deny — `updatedInput` not supported in PreToolUse hooks

### Security
- Cross-project git guard prevents accidental operations on wrong repositories
- Credential exposure protection via `.env` read deny rules

## [2.0.0] - 2026-02-08

### Added
- **Core System Architecture**
  - Three-agent system: Planner, Implementer, Guardian with role separation
  - 20+ deterministic hooks across 8 lifecycle events
  - Worktree-based isolation with main branch protection
  - Test-first enforcement via `test-gate.sh` and proof-of-work verification
  - Documentation requirements via `doc-gate.sh` for 50+ line files

- **Decision Intelligence**
  - `/decide` skill: Interactive decision configurator with HTML wizards
  - Bidirectional decision tracking: `MASTER_PLAN.md` ↔ `@decision` annotations in code
  - Plan lifecycle state machine with completed-plan source write protection
  - `surface.sh` decision audit on session end

- **Research & Context**
  - `deep-research` skill: Multi-model synthesis across research providers
  - `prd` skill: Deep-dive product requirement documents
  - `context-preservation` skill: Structured summaries across compaction
  - Dual-path compaction preservation (persistent file + directive)

- **Backlog Management**
  - `/backlog` command: Unified todo interface over GitHub Issues
  - Global and project-scoped issue tracking
  - Component grouping and image attachment support
  - Staleness detection (14-day threshold)

- **Safety & Enforcement**
  - `guard.sh`: Nuclear deny for destructive commands, transparent rewrites for `/tmp/` → `tmp/`, `--force` → `--force-with-lease`
  - `branch-guard.sh`: Blocks source writes on main, enforces worktree workflow
  - `mock-gate.sh`: Prevents internal mocking, allows external boundary mocks only
  - `plan-check.sh`: Requires MASTER_PLAN.md before implementation
  - Safe cleanup utilities to prevent CWD deletion bugs

- **Session Lifecycle**
  - `session-init.sh`: Git state, plan status, worktrees, todo HUD injection on startup
  - `prompt-submit.sh`: Keyword-based context injection, deferred-work detection
  - `session-summary.sh`: Decision audit, worktree status, forward momentum check
  - `forward-motion.sh`: Ensures user receives actionable next steps

- **Subagent Quality Gates**
  - `check-planner.sh`: Verifies MASTER_PLAN.md exists and is valid
  - `check-implementer.sh`: Enforces proof-of-work (live demo + tests) before commits
  - `check-guardian.sh`: Validates commit message format and issue linkage
  - Task tracking via `task-track.sh` for subagent state monitoring

- **Code Quality**
  - `lint.sh`: Auto-detect and run linters (shellcheck, python, etc.) with feedback loop
  - `code-review.sh`: Optional LLM-based review integration
  - `auto-review.sh`: Interpreter analyzer (distinguishes safe vs risky python/node/ruby/perl)
  - `test-runner.sh`: Async test execution with `.test-status` evidence file

- **Testing Infrastructure**
  - Contract tests for all hooks (`tests/run-hooks.sh`)
  - 54/54 passing test suite
  - GitHub Actions CI with shellcheck and contract validation
  - Test harness auto-update system

### Changed
- Promoted 16 safe utilities to global allow list in `settings.json`
- Removed LLM review hook (external command review discontinued)
- Removed version system in favor of git tags
- Professionalized repository structure with issue templates

### Fixed
- Inlined update-check into session-init to eliminate startup race condition
- Wired subagent tracking to status bar via PreToolUse:Task hook
- Replaced bare `rm -rf` with `safe_cleanup` in test runner
- Resolved all shellcheck warnings
- Fixed Guardian bypass via git global flags (enforced dispatch for commit/push/merge)
- Fixed test harness subshell bug that silently swallowed failures
- Prevented CWD-deletion ENOENT in Stop hooks
- Recognized meta-repo worktrees in `guard.sh`
- Anchored Category 5 nuclear deny to command position
- Stopped deep research from silently swallowing provider failures

### Security
- Cross-project git guard prevents accidental operations on wrong repositories
- Credential exposure protection via `.env` read deny rules
- Hook input sanitization via `log.sh` shared library
- Safe temporary directory handling (project `tmp/`, not `/tmp/`)

[Unreleased]: https://github.com/juanandresgs/claude-ctrl/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/juanandresgs/claude-ctrl/releases/tag/v2.0.0
