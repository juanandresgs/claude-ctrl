# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- `feature/dispatch-inject`: Dynamic dispatch summary injection — DISPATCH.md maintains a delimited summary section that session-init.sh extracts and injects into session context at startup, single source of truth for dispatch routing; CLAUDE.md v2.4 slims dispatch rules to pointer, removes redundant paragraph (DEC-DISPATCH-INJECT-001)
- `worktree-agent-a72614e7`: Agent context injection optimization — shared-protocols.md reduced 37% (2568->1626 bytes), subagent-start.sh now uses section-aware extraction with per-agent-type conditional injection (governor skips CWD Safety, implementer gets lockfile reminder), HTML comment stripping prevents @decision annotations from entering agent context (DEC-PROMPT-002)

### Fixed
- `worktree-agent-a526b1e3`: Proof gate deadlock when post-task.sh summary.md detection fails — 5-component interlock: loud advisory + signal file (C1), tester dispatch breadcrumb in task-track.sh (C2), AUTOVERIFY relay detection in prompt-submit.sh (C3), .last-tester-trace at SubagentStart (C4), emergency Check 9 override with 300s TTL (C5); 17 dedicated tests (DEC-AV-LOUD-FAIL-001, DEC-AV-BREADCRUMB-001/002, DEC-AV-RELAY-001, DEC-AV-OVERRIDE-001)

### Reverted
- `revert/governance-eff-w1`: Revert 5 commits from Governance Efficiency W1/W2, T2 backstop, and governor wiring — these collectively degraded agent performance by overloading context with governance metadata, blocking auto-verify with an impossible regex, and injecting governor signals unconditionally; reverts e50480f, 90f6a5e, 56ebe16, a94b562, eed29d1; removes 4 test files (2524 lines net reduction across 21 files)

### Added
- `feature/state-unify-w5-1`: State Unification W5-1 — remaining hook migrations (compact-preserve, log, prompt-submit, session-init, session-lib, stop) to SQLite state_emit/require_state; removes type guard fallbacks from migrated hooks; event emission for session lifecycle and hook activity; dual-write cleanup comments for W5-2 (#219)
- `feature/state-unify-w3-2`: State Unification W3-2 — agent marker hook migration to SQLite; check-guardian, check-implementer, check-tester, post-write, subagent-start, and task-track now write marker lifecycle events (started/completed) via marker_update() with dotfile fallback; dual-write pattern preserves backward compatibility until W5-2 removes dotfiles (DEC-STATE-UNIFY-004, #217)
- `feature/state-unify-w1-1`: State Unification Wave 1-1 — upgrade all SQLite write transactions to BEGIN IMMEDIATE for WAL-mode deadlock prevention, add _migrations table with per-migration checksums for schema versioning, idempotent migration runner with checksum validation and dry-run support; state_migrate() public API for explicit migration triggers (DEC-STATE-UNIFY-001, DEC-STATE-UNIFY-002, #214)
- `feature/state-unify-w1-2`: State Unification Wave 1-2 — proof_state typed table with CHECK constraint enforcing valid status values (none/needs-verification/pending/verified/committed), monotonic lattice enforcement in proof_state_set() preventing backward transitions without epoch bump, dual-read fallback from SQLite to flat proof-status files, proof_epoch_reset() for intentional state regression; 3 public API functions (DEC-STATE-UNIFY-003, #214)
- `initiative/state-unification`: State Unification initiative plan — replaces four overlapping state management eras (dotfiles, state.json+jq, atomic tmp->mv, shadow SQLite) with SQLite as sole authority; 6-wave plan covering schema+migration framework, proof state typed table, agent markers, event ledger, hook migrations, and lint enforcement; 9 P0 requirements, 7 architectural decisions (DEC-STATE-UNIFY-001 through 007), supersedes parked SQLite Unified State Store (#128-#134); issues #213-#221
- `initiative/db-safety`: Database Safety Framework Waves 1-5 — defense-in-depth interception preventing AI agents from destroying databases through CLI, ORM, IaC, MCP, or container commands; 5-layer architecture: nuclear deny (state.db protection, state-diag.sh diagnostics), CLI-aware detection (psql/mysql/sqlite3/mongosh/redis-cli with forced safety flags), IaC/container interception (terraform destroy, docker volume rm, migration allowlists), Database Guardian subagent (agents/db-guardian.md with policy engine, simulation helpers, approval gate), MCP governance layer (hooks/pre-mcp.sh with JSON-RPC argument inspection); environment tiering (dev=permissive, staging=approval, prod=read-only, unknown=deny); 24 new files, 430 tests across 9 test scopes (DEC-DBSAFE-001 through DEC-DBSAFE-006, DEC-DBGUARD-001 through DEC-DBGUARD-009, DEC-MCP-001 through DEC-MCP-003, #197-#199)
- `feature/tester-verification-w2`: Tier 2 evidence backstop for auto-verify — post-task.sh now mechanically verifies Coverage table contains T2 "Fully verified" rows before granting auto-verify signal, fixes bash 3.2 negative subscript bug that silently killed secondary validation pipeline; test phash mismatch fix for worktree-to-main resolution (DEC-AV-TIER2-001), 7 new tests
- `feature/tester-verification-integrity`: Two-Tier Verification Protocol for tester agent — T1 (tests pass) and T2 (feature works in production context) now explicitly tracked in coverage tables and AUTOVERIFY blockers; implementer.md gains Production Reality Check checklist requiring identification of production triggers and common sequences before declaring tests complete (DEC-TESTER-TIER-001, DEC-IMPL-PRODCHECK-001), 5 tests
- `feature/governance-efficiency-w2`: Cross-hook signal deduplication Wave 2 — cached git/plan state producers in session-init.sh with `_cached_git_state`/`_cached_plan_state` consumer API in git-lib.sh and plan-lib.sh, wired into all 8 consumer hooks (check-guardian/implementer/planner/tester, compact-preserve, prompt-submit, stop, subagent-start), session-end.sh cleanup, prompt-vs-hook overlap analysis documented as DEC-EFF-014; 15 new tests, 68/68 total pass, all deny gates preserved (DEC-EFF-012 through DEC-EFF-014, #209)
- `feature/session-label`: Session-specific statusline Line 3 — when agents are dispatched, Line 3 now shows the worktree branch name or agent description instead of the static initiative, letting concurrent sessions display unique identifiers; falls back to initiative when no agent is active; 4 decisions (DEC-SESSION-LABEL-001 through 004), 12 new tests
- `feature/governor-wiring`: Wire mechanical governor triggers — check-planner.sh emits GOVERNOR ADVISORY when planner returns multi-wave initiatives, session-init.sh surfaces last governor pulse timestamp and verdict at session start with staleness warnings for meta-infrastructure, reckoning SKILL.md Phase 2e dispatches governor in reckoning-input mode for structured health assessment (DEC-GOV-WIRE-002, DEC-GOV-WIRE-003), 42 tests
- `initiative/governance-efficiency`: Governance Efficiency initiative added to MASTER_PLAN.md — targeted signal noise reduction, caching, and deduplication to address 60-310% governance token overhead on easy tasks; 2-wave plan (W1: advisory demotions + caching, W2: cross-hook deduplication), 7 P0 requirements with safety invariants, 5 architectural decisions (DEC-EFF-001 through DEC-EFF-005), issues #208 and #209
- `feature/governance-efficiency-w1`: Signal noise reduction Wave 1 — 6 optimizations: demote 2 pre-write.sh advisories to debug log with churn cache, doc-freshness fire-once-per-session in pre-bash.sh, keyword match caching in prompt-submit.sh, trajectory narrative caching in stop.sh, session-end.sh cleanup for 4 new cache patterns; 27 new tests, all deny gates preserved unconditionally (DEC-EFF-006 through DEC-EFF-011, #208)

### Fixed
- `feature/fix-sweep-noise`: Fix sweep report explosion in check-guardian.sh Check 7b — sweep call extracted from per-worktree loop to run once instead of N times, worktree-roster.sh `--auto` mode suppresses empty category headers so clean systems produce zero noise (DEC-SWEEP-DEDUP-001)
- `feature/fix-proof-path`: Fix proof-status path mismatch bug — safety-net writes in check-tester.sh and post-task.sh now use `write_proof_status()` for dual-write to both canonical paths, preventing proof gate from getting stuck when one path has `verified` and the other has stale `needs-verification` (DEC-PROOF-DUALWRITE-001, #81)
- `fix/statusline-lifetime-tokens`: Fix statusline lifetime tokens display — double-nesting path guard in `write_statusline_cache()` for `~/.claude` meta-project, time-based cache pruning (1-hour TTL replacing keep-3-newest), and 4-line layout splitting metrics across two lines so lifetime tokens are never truncated; 21 new tests (DEC-DOUBLE-NEST-FIX-001, DEC-CACHE-PRUNE-001, DEC-STATUSLINE-4LINE-001, DEC-LIFETIME-TOKENS-001)
- `fix/governor-null-date`: Fix null `started_at` display in governor pulse surfacing — jq -r emits the string "null" for JSON null fields, which passed through to the statusline as "Last governor pulse: null"; now normalised to empty string with "date unknown" fallback and proactive pulse recommendation when date is unresolvable
- `feature/shellcheck-fixes`: Shellcheck cleanup in test-token-history-format.sh (remove unused vars, fix compute_phash subshell reference) and gate-denied trace records in task-track.sh — blocked agent dispatches now write `outcome: "gate-denied"` traces instead of phantom 0-duration crashed/unknown entries that skewed observatory metrics (DEC-GATE-DENIED-001, #174)
- `fix/sourcelib-worktree-path`: Fix source-lib.sh path resolution in worktrees — add fallback to canonical `$HOME/.claude/hooks` when `_SRCLIB_DIR` resolves to a directory without expected sibling files (log.sh), 2 new tests T8/T9 (DEC-SRCLIB-FALLBACK-001, #207)
- `worktree-agent-a4dd9cf8`: Statusline dark grey system blocks (ESC[90m) for dark terminal visibility; resolve worktree CWD to main repo root in detect_project_root() so project_hash, lifetime tokens, and proof-status lookups work correctly from worktrees (DEC-WORKTREE-RESOLVE-001)
- `fix/governance-self-bypass`: Close governance self-bypass vectors — extend pre-write.sh branch guard to governance-critical markdown (agents/*.md, docs/*.md, CLAUDE.md, ARCHITECTURE.md), narrow task-track.sh @plan-update bypass to plan-only commits, add specific governance-file error messages in pre-bash.sh commit guard, 26 new test cases (DEC-RECK-011)
- `feature/fix-token-format`: Token formatting consistency — capitalize K in K-notation (145K not 145k) and add space before `tks` suffix in all three display locations (session, subagent, lifetime)

### Changed
- `fix/autoverify-guardian-infer`: AUTOVERIFY reliability Wave 2 — Guardian inference-based fallback (INFER-VERIFY) for when AUTO-VERIFY-APPROVED is absent but tester evidence is clean; 5 validation criteria in guardian.md, INFER-VERIFY dispatch docs in DISPATCH.md, Wave 2 tests 9-12 (DEC-AV-GUARDIAN-001, #196)
- `feature/autoverify-reliability`: AUTOVERIFY reliability Wave 1 — rewrite tester Auto-Verify Signal section with positive-default framing (emit CLEAN unless blockers apply), fix check-tester.sh Phase 2 audit from misleading `auto_verify_rejected` to accurate `auto_verify_advisory`, add post-task.sh inference check for missed AUTOVERIFY signals on clean assessments (DEC-TESTER-AUTOVERIFY-001, DEC-AV-MISS-001, #194, #195)
- `housekeeping/plan-maintenance`: MASTER_PLAN.md housekeeping batch — close Prompt Purpose Restoration and Governance Signal Audit initiatives (moved to Completed with narratives), add RSM completed summary, fix Created date and architecture counts, add 15 Decision Log entries (DEC-RECK-010 through DEC-RECK-016 and others)
- `worktree-agent-a9bc4dc5`: Statusline aesthetic + cache discovery — system blocks changed from ▓ to █ with dim color for cleaner visuals, cache discovery fallback finds most recent `.statusline-cache-*` when CLAUDE_SESSION_ID unavailable (DEC-DUALBAR-004), core-lib.sh `is_protected_state_file()` non-dot patterns use exact match to prevent false positives
- `feature/dual-color-bar`: Dual-color context pressure bar — statusline now renders three visual regions (system overhead in dim, conversation usage in severity-colored, empty space), with fingerprint-based baseline capture and invalidation on compaction or config drift (DEC-DUALBAR-001, DEC-DUALBAR-002)
- `docs/readme-mermaid-and-polish`: Replace ASCII pipeline diagram in README.md with Mermaid flowchart; move DEC-ARCH-001 @decision in ARCHITECTURE.md to HTML comment (still grepable, invisible when rendered)
- `feature/slim-agents`: Slim all 4 agent prompts — remove shared-protocol boilerplate (CWD safety, trace protocol, return message, session-end checklist) now injected at dispatch time via subagent-start.sh; strengthen purpose language at top of each prompt; Guardian gains Merge Presentation section and AUTO-VERIFY-APPROVED bypass; 1,481 to 1,320 lines total (#146)
- `feature/claude-md-restore`: Restore CLAUDE.md purpose-sandwich structure (v2.3) -- full Cornerstone Belief, "What Matters" quality-of-thought section with agent initiative language, dispatch table relocated to DISPATCH.md reference (#144)

### Added
- `initiative/governor-subagent`: Governor Subagent — 5th agent with two-tier evaluation model (health pulse ~3-5K tokens + full eval ~15-20K tokens), SubagentStop validation hook (check-governor.sh, advisory), dispatch wiring in settings.json/subagent-start.sh/DISPATCH.md/CLAUDE.md, 416-line wiring test suite (DEC-GOV-001 through DEC-GOV-006, #169, #182-#185)
- `feature/evaluator-agent`: Governor Subagent initiative added to MASTER_PLAN.md — 5th agent (mechanical feedback mechanism) with 4+4 dimension scoring rubric, 3 trigger contexts, 4-wave implementation plan, 5 architectural decisions (DEC-GOV-001 through DEC-GOV-005), dispatch/hook integration specs
- `feature/shared-protocols`: Shared defensive protocols — extract duplicated session-end checklist, CWD safety, and output rules from 4 agent prompts into `agents/shared-protocols.md`; inject via `subagent-start.sh` so all agents inherit standardized boilerplate (DEC-PROMPT-002, closes #143)
- `feature/signal-map`: Governance signal map — comprehensive reference documenting all 24 hook registrations with signal routing, context injection volumes, gate types, firing frequency, overlap analysis, and noise assessment (#145)
- `feature/sqlite-w1`: SQLite WAL-based state store (Wave 1) — rewrite hooks/state-lib.sh with sqlite3 backend (state_update, state_read, state_cas, state_delete, workflow_id), WAL mode with busy_timeout=5000ms, per-workflow isolation via workflow_id column, SQL injection prevention, lattice-enforced CAS, legacy jq functions preserved as _legacy_* for Wave 2 migration; 20-test suite in test-sqlite-state.sh covering schema, CRUD, CAS, lattice, concurrency, and injection; `--scope sqlite` in run-hooks.sh (DEC-SQLITE-001 through DEC-SQLITE-010, closes #128, #129)
- `feature/sqlite-state-store`: SQLite Unified State Store initiative added to MASTER_PLAN.md — 4-wave implementation plan replacing scattered flat-file state with single SQLite WAL database, 8 architectural decisions (DEC-SQLITE-001 through 008), 9 P0 requirements, issues #128-#134

### Fixed
- `feature/backfill-null-fallback`: Fix CLAUDE_SESSION_ID always "unknown" — extract session_id from Claude Code hook stdin JSON in read_input() (log.sh), session-end.sh, and trace-lib.sh; backfill script now uses exact session_id matching (Tier 0) before two-tier timestamp fallback (DEC-SESSION-ID-001, #175)
- `fix/statusline-column-collapse`: Reserve 65 chars for Claude Code right-panel in statusline width calculation — prevents metrics line from collapsing when Claude Code's right-aligned info occupies ~60-70 visible characters; floor clamped to 60 to avoid negative/tiny widths (DEC-STATUSLINE-TERMWIDTH-003)
- `fix/statusline-baseline-pid`: Fix PID-scoped baseline filename — `$$` produced unique file per render, making baseline == current always (0 conversation blocks, entire bar system color); now uses single `.statusline-baseline` per workspace with one-time cleanup of proliferated old files (DEC-DUALBAR-003)
- `fix/trace-null-projects`: Fix null project_name in trace index — finalize_trace() now backfills null project fields from detect_project_root() at trace seal time (DEC-BACKFILL-003); new backfill scripts (backfill-trace-projects.sh/.py) rebuilt index clean (564 entries, 0 nulls); 10+11 test suite (#173)
- `fix/dual-color-bar-colors`: Change system blocks in dual-color context bar from dim (`\033[2m`) to cyan (`\033[36m`), brackets bold cyan, percentage inherits severity color — fixes indistinguishable system/empty blocks on dark terminals
- `fix/statusline-lifetime-tokens`: Fix lifetime token/cost persistence across cache writes, add per-project token history columns (project_hash, project_name) with backward-compatible 5-to-7-column format, remove 100-entry trims from session history files, add backfill script for retroactive project tagging; 3 new test suites (DEC-LIFETIME-PERSIST-001, DEC-NO-TRIM-001, DEC-PROJECT-TOKEN-HISTORY-001, #160)
- `fix/guardian-stale-marker`: Fix Gate A.0 false blocks in task-track.sh — validate trace manifest status before denying Guardian dispatch, preventing stale markers from blocking legitimate dispatches after session crashes, finalize_trace failures, or pre-dispatch marker orphans (DEC-STALE-MARKER-004); 7-test suite in test-guardian-stale-marker.sh
- `worktree-agent-ab54ee08`: Fix pre-bash.sh Check 2 bootstrap exception — `git ls-tree` exit code check replaced with output-content check since ls-tree returns exit 0 even for absent paths; new 219-line test suite validates bootstrap allow/deny behavior (#150)
- `fix/ci-sqlite-tests`: Update 4 failing CI tests for SQLite WAL state backend — verify_library_consistency() updated for per-library version pinning, T02 comment updated, T01/T05 check state.db and SQLite WAL concurrency, T10 checks state.db + sqlite3 presence
- `fix/lint-full-coverage`: Extend `--scope lint` from 34 hooks to 97 files (hooks + tests + scripts) matching CI's full shellcheck coverage — define `_SC_HOOKS_EXCLUDE` and `_SC_TESTS_EXCLUDE` as single source of truth matching validate.yml exclusion sets; 101 total lint tests (#127)
- `fix/125-autoverify-sort`: Fix auto-verify trace discovery — replace `sort -r` (alphabetical) with `ls -t` (mtime-ordered) in Tier 2 and Tier 3 fallback scans so current-session traces are found first; add ghost trace detection to skip stale active traces with no summary after 60s (DEC-AV-GHOST-001)
- `feature/xplatform-reliability`: Portable `_file_mtime()` and `_with_timeout()` wrappers in core-lib.sh — replace 25 inline `stat -f %m` patterns across 12 files with Linux-first stat order (DEC-XPLAT-001), replace 10 bare `timeout` commands across 5 files with GNU timeout + Perl alarm fallback (DEC-XPLAT-002)

### Added
- `feature/lint-on-write`: Multi-language lint-on-write hook (hooks/lint.sh) — synchronous PostToolUse on Write/Edit runs shellcheck/ruff/go vet/cargo clippy with CI-matching exclusions, 3s cooldown per file, linter install suggestions; Check 6b post-commit shellcheck advisory in check-guardian.sh; 38 lint-scope tests in run-hooks.sh; fix SC2116 and SC2059 x2 in existing scripts (DEC-LINT-001)
- `feature/dispatch-enforcement-tests`: Orchestrator guard test suite — 8 tests across 6 scenarios for Gate 1.5 (DEC-DISPATCH-003): deny orchestrator, allow subagent, backward compat (missing SID), non-source bypass, and protected file registry (DEC-TEST-ORCH-GUARD-001)
- `feature/dispatch-enforcement`: Gate 1.5 in pre-write.sh blocks orchestrator from writing source code directly — compares CLAUDE_SESSION_ID against .orchestrator-sid (written by session-init.sh) to detect orchestrator context; dispatch routing table restored to CLAUDE.md; .orchestrator-sid lifecycle managed by session-init/session-end (DEC-DISPATCH-001, DEC-DISPATCH-002, DEC-DISPATCH-003)
- `feature/operational-mode-system`: Operational Mode System initiative added to MASTER_PLAN.md — 4-tier mode taxonomy (Observe/Amend/Patch/Build) with proportional governance, 5 waves of 15 work items, 9 architectural decisions (DEC-MODE-*), issues #114-#118
- `feature/rsm-phase4`: Self-validation infrastructure — version sentinels in all library files, `bash -n` syntax preflight in session-init.sh, `hooks-gen` integrity check via post-merge git hook, 292-line self-validation test suite (test-self-validation.sh), source-lib.sh `lib_files()` enumerator for consistent library discovery

### Fixed
- `feature/xplat-w1b`: Update 10 stale context-lib.sh section names in run-hooks.sh to correct library names (core-lib.sh, git-lib.sh, session-lib.sh) after metanoia decomposition (#120)
- `worktree-test-cleanup`: Test infrastructure cleanup — delete 23 dead test files (~10K lines) testing removed features, fix 12 failing standalone tests (proof-path, guard, state-lifecycle, orchestrator-governance), remove 4 duplicate inline delegations from run-hooks.sh, add `if: always()` to CI standalone step, update context-lib.sh refs to core-lib.sh
- `feature/fix-ci-round2`: Fix remaining 4 Ubuntu CI failures — move `_PHASH` computation to top-level in session-init.sh (was inside TRACE_STORE conditional, causing `set -u` crash), add `mkdir -p "$TRACE_STORE"` in task-track.sh (find on non-existent dir triggers `set -eo pipefail` crash)
- `feature/fix-ci`: Resolve 15+ CI failures — SC2168 fix in session-init.sh, mkdir -p before timing log (Ubuntu crash), canonical proof-status paths in tests, context-lib.sh to source-lib.sh migration, removed V2 duplicate test sections, updated diagnose lib health check list
- `worktree-fix-test-failures`: Fix remaining test failures — source-lib.sh idempotency guard to prevent EXIT trap stacking (exit 139), align proof-gate Check 10 tests with marker-based ownership (DEC-PROOF-DELETE-SOFTEN-001), fix proof-lifecycle T13 network timeout via gh stub
- `feature/fix-dispatch-integrity`: Restore dispatch protocol integrity after Task-to-Agent rename — migrate all test fixtures/scripts from Task to Agent tool name, remove non-existent max_turns parameter, add Gate D (plan vs planner advisory) and Gate E (worktree isolation advisory) to task-track.sh, add tool-name canary to session-init.sh for future rename detection, add Wave Dispatch section to DISPATCH.md, update turn budget docs to prompt-based

### Changed
- `worktree-agent-a9bc4dc5`: Statusline aesthetic + cache discovery — system blocks changed from ▓ to █ with dim color for cleaner visuals, cache discovery fallback finds most recent `.statusline-cache-*` when CLAUDE_SESSION_ID unavailable (DEC-DUALBAR-004), core-lib.sh `is_protected_state_file()` non-dot patterns use exact match to prevent false positives
- `feature/impl-perf-fixes`: Remove CYCLE_MODE auto-flow entirely (orchestrator controls cycle with visible dispatches); slim implementer.md 289->223 lines by removing hook-enforced redundancies; fix subagent token cache path to session-scoped; raise stale marker threshold 15min->60min; add TEST_SCOPE signal for proportional testing
- `feature/rsm-phase3`: Unified state directory with dual-write migration — `state_dir()` in state-lib.sh provides `state/{phash}/` per-project directories; proof-status, test-status, and session hooks migrated to state directories with backward-compatible fallback reads from legacy dotfile paths; breadcrumb system retired; 50+ new state directory migration tests (DEC-RSM-STATEDIR-001, DEC-RSM-STATEDIR-TEST-001)
- `feature/fix-subagent-latency`: Subagent latency remediation — deduplicate dispatch work in task-track.sh (early exit for non-gated agents, remove duplicate require_* calls); cap trace scanning loops (10 manifest, 5 tertiary fallback, combined jq @tsv calls); merge token tracking into check-*.sh hooks (track_agent_tokens() in session-lib.sh, delete standalone track-agent-tokens.sh + SubagentStop hook entry)
- `feature/wave-planning-metrics`: Replace serial phase-based planning with DAG-based wave decomposition — Phase 3 output format uses dependency graphs to compute waves of parallelizable work; new per-item metrics (Weight S/M/L/XL, Gate none/review/approve, Deps W-ID list); initiative-level summary metrics (critical path, max width); 4 new DAG validation checklist items; issue labels `phase-N` to `wave-N`; both templates (master-plan.md, initiative-block.md) updated consistently

### Fixed
- `feature/proof-sweep-marker-based`: Replace TTL-based proof-status sweep with marker-based ownership check — session-end.sh now checks for .active-*-{phash} markers in TRACE_STORE instead of 4h mtime TTL; no markers means orphaned, safe to delete; empty-hash files (Bug A) always deleted; PC-03 rewritten for marker logic, PC-05 added for empty-hash coverage (DEC-PROOF-SWEEP-001 updated)

## [3.0.0] - 2026-03-05

### Fixed
- `feature/fix-proof-lifecycle`: Proof lifecycle fixes — resolve_proof_file() prioritizes CLAUDE_PROJECT_DIR for stable cross-hook phash (DEC-PROOF-STABLE-001, #106); post-task.sh AUTOVERIFY fallback validates agent_type from manifest.json to prevent non-tester traces triggering auto-verify (DEC-AV-AGENT-TYPE-001, #4); 4 new proof lifecycle tests
- `feature/fix-dispatch-reliability`: Dispatch reliability — pre-ask.sh Gate 0 expanded with CI monitoring patterns and declarative forms (DEC-ASK-GATE-002, #107); per-gate error isolation via _run_gate()/_run_blocking_gate() wrappers + set +e sandwiching for advisory sections (DEC-GATE-ISOLATE-001 through DEC-GATE-ISOLATE-004, #63); 12 new tests
- `feature/fix-housekeeping`: Housekeeping — MASTER_PLAN.md Backlog Auto-Capture phases 1-3 status synced to completed; CHANGELOG deduplicated (3 duplicate backlog-gaps Phase 3 entries removed); context-lib.sh backward-compat shim removed (#65), consumers migrated to source-lib.sh + require_*()
- `feature/statusline-cache-scope`: Per-instance statusline cache scoping — cache file uses `.statusline-cache-${CLAUDE_SESSION_ID}` instead of shared `.statusline-cache`, preventing multi-instance state collision; session-end.sh cleans own cache on exit + sweeps stale caches >4h
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
- `worktree-agent-a9bc4dc5`: Statusline aesthetic + cache discovery — system blocks changed from ▓ to █ with dim color for cleaner visuals, cache discovery fallback finds most recent `.statusline-cache-*` when CLAUDE_SESSION_ID unavailable (DEC-DUALBAR-004), core-lib.sh `is_protected_state_file()` non-dot patterns use exact match to prevent false positives
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
- `worktree-agent-a9bc4dc5`: Statusline aesthetic + cache discovery — system blocks changed from ▓ to █ with dim color for cleaner visuals, cache discovery fallback finds most recent `.statusline-cache-*` when CLAUDE_SESSION_ID unavailable (DEC-DUALBAR-004), core-lib.sh `is_protected_state_file()` non-dot patterns use exact match to prevent false positives
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

[Unreleased]: https://github.com/juanandresgs/claude-ctrl/compare/v3.0.0...HEAD
[3.0.0]: https://github.com/juanandresgs/claude-ctrl/compare/v2.0.0...v3.0.0
[2.0.0]: https://github.com/juanandresgs/claude-ctrl/releases/tag/v2.0.0
