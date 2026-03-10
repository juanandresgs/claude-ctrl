<!--
@decision DEC-SIGNAL-MAP-001
@title Governance Signal Map — canonical reference for all 24 hooks
@status accepted
@rationale Produced from comprehensive audit (tmp/explore-overflow-20260307-115656.md).
  Maps every hook, event, output type, injection size, and gate. Intended as
  reference for Initiative 2 Wave 2 optimization proposals. Format optimized
  for quick lookup: table per lifecycle stage, then budget/redundancy/noise
  analysis sections.
-->

# Governance Signal Map

> **Generated from:** `tmp/explore-overflow-20260307-115656.md` (audit run 2026-03-07)
> **Hook count:** 24 registered hooks across 8 event lifecycle stages
> **Referenced by:** Initiative 2 Wave 2 (signal optimization proposals)

## Overview

The Claude Code governance layer consists of 24 shell hooks wired to 10 event
types in `settings.json`. They operate as a deterministic enforcement layer,
injecting context, emitting denies, and triggering side-effects without touching
model logic. All hooks are consolidated into composite scripts (Phase 2) —
multi-hook merges reduced per-turn latency by ~350ms.

**Output types used throughout this document:**

| Type | Meaning |
|------|---------|
| `deny` | Hard block — tool call refused, reason returned to model |
| `advisory` | Soft warning — tool call proceeds, guidance injected |
| `context` | `additionalContext` injected into model's conversation |
| `side-effect` | State mutation (file writes, cache updates) — no model output |
| `systemMessage` | Injected as a system message (used by Stop hook) |

---

## Signal Flow by Lifecycle Event

### SessionStart

**Hook:** `session-init.sh`

| Attribute | Value |
|-----------|-------|
| Event | `SessionStart` |
| Matcher | `startup\|resume\|clear\|compact` |
| Frequency | Once per session start / resume / /clear / /compact |
| Output type | `context` (additionalContext) |
| Injection size | ~800 bytes typical (600–1200 bytes range) |
| Libraries | source-lib.sh, context-lib.sh, session-lib.sh, plan-lib.sh, trace-lib.sh |

**Purpose:** Bootstrap the session with current project state before the first
model turn.

**Signals injected:**
- Git branch, dirty file count, linked worktree count
- MASTER_PLAN.md status: existence, active phase, initiative progress
- Todo HUD (pending GitHub issues labeled `claude-todo`)
- Syntax gate: denies if source-lib.sh or log.sh has parse errors (corruption detection)

**Known issue:** #10373 — output silently dropped on brand-new sessions (no
prior history). Fires correctly on /clear, /compact, and resume. The
`prompt-submit.sh` first-prompt mitigation compensates.

---

### UserPromptSubmit

**Hook:** `prompt-submit.sh`

| Attribute | Value |
|-----------|-------|
| Event | `UserPromptSubmit` |
| Matcher | _(none — fires always)_ |
| Frequency | Every user prompt |
| Output type | `context` (additionalContext) |
| Injection size | 200–2000 bytes (typical 400–600 bytes; spike to 2000 on deferred work) |
| Libraries | source-lib.sh, state-lib.sh, session-lib.sh, trace-lib.sh |

**Purpose:** Dynamic context injection keyed on prompt keywords, plus the
approval fast-path for the proof-of-work state machine.

**Signals injected (conditional):**

| Trigger | Signal | Size |
|---------|--------|------|
| "verified", "approved", "lgtm", "looks good", "ship it" | CAS transition pending → verified; emits `AUTO-VERIFY-APPROVED` | ~100 bytes |
| Empty prompt (Enter only) | Approval/continuation hint | ~80 bytes |
| `.proof-gate-pending` breadcrumb detected | Interrupted verification warning | ~120 bytes |
| `.subagent-tracker` active entries | Active-agent advisory with elapsed times | ~150 bytes |
| "plan", "implement", "feature", "build" keywords | Plan status: dormant warning or active initiative count | 200–400 bytes |
| "merge", "commit", "push" keywords | Git state: branch, dirty count, main-is-sacred warning | ~200 bytes |
| "ci", "test", "build" keywords | Cached CI status injection | ~150 bytes |
| "later", "defer", "backlog", "eventually", "park", "future" | Auto-capture to GitHub issue (background subprocess) | ~100 bytes + fire-and-forget |
| "research", "investigate", "explore" keywords | Research log status | ~100 bytes |
| Prompt count = 35 or 60, or session age = 45 or 90 min | /compact suggestion | ~80 bytes |
| First prompt of session (issue #10373 workaround) | Re-inject full session-init context | ~800 bytes |

**Key gates:**
- CAS (compare-and-swap) with file lock for atomic proof-status transitions
- Guardian active TTL (600s) prevents thundering-herd re-dispatch
- Keyword detection uses `grep -qiE` (no external processes)

---

### PreToolUse

Four hooks fire on different tool matchers before the tool executes.

---

#### `pre-write.sh` — Write / Edit gate

| Attribute | Value |
|-----------|-------|
| Event | `PreToolUse` |
| Matcher | `Write\|Edit` |
| Frequency | Every Write or Edit call |
| Output type | `deny` + `advisory` |
| Injection size | 0 bytes context (all denies/advisories) |
| Libraries | source-lib.sh, core-lib.sh, plan-lib.sh, session-lib.sh, doc-lib.sh |
| Consolidated from | 6 hooks: branch-guard, plan-check, test-gate, mock-gate, defprog-gate, doc-gate, checkpoint |

**Purpose:** Hard safety gates (branch isolation, plan existence) + quality
gates (test status, mock policy, exception handling) + side-effect checkpointing.

**Gates (ordered fastest-deny-first):**

| # | Gate | Type | Condition | Worktree behavior |
|---|------|------|-----------|-------------------|
| 0 | Proof-status write guard | deny | Direct Write/Edit to `.proof-status` or `.test-status` files | Active |
| 1 | Branch guard | deny | Source writes on main/master | Active; exceptions: first MASTER_PLAN.md commit, merge conflict resolution |
| 1.5 | Orchestrator source guard | deny | Source writes from orchestrator session (not implementer) | Active |
| 2 | Plan check | deny | No MASTER_PLAN.md exists; plan dormant; churn >35% or drift >5 decisions | Skipped in worktrees |
| 3 | Test gate | escalating | Tests failing: advisory on strike 1, hard deny on strike 2+ | Active |
| 4 | Mock gate | escalating | Internal mocks in test files: advisory strike 1, deny strike 2+ | Active |
| 4.5 | Defprog gate | escalating | Silent exception swallowing: advisory strike 1, deny strike 2+ | Active |
| 5 | Doc gate | advisory/deny | New .md in project root; missing doc header; missing @decision on 50+ line files | Skipped in worktrees |
| 6 | Checkpoint | side-effect | Every 5th write: create `refs/checkpoints/{branch}/{N}` | Skipped on main and meta-repos |

**Worktree optimization (DEC-PERF-003):** Gates 2 (plan-check) and 5 (doc-gate)
fully skipped in worktrees to reduce advisory noise during iteration.

---

#### `pre-bash.sh` — Bash command gate

| Attribute | Value |
|-----------|-------|
| Event | `PreToolUse` |
| Matcher | `Bash` |
| Frequency | Every Bash call |
| Output type | `deny` + `advisory` |
| Injection size | 0 bytes context |
| Libraries | source-lib.sh, core-lib.sh, session-lib.sh, doc-lib.sh |
| Consolidated from | guard.sh + doc-freshness.sh |

**Purpose:** All structural git safety + nuclear filesystem safety +
documentation freshness before commit.

**Gates (ordered):**

| # | Gate | Type | Condition |
|---|------|------|-----------|
| 0 | Nuclear deny | deny | Filesystem destruction, disk/device wipe, fork bomb, permission destruction, shutdown/reboot, RCE (curl\|bash pipe), SQL database destruction |
| 0.75 | Worktree cd guard | deny | Any `cd`/`pushd` into `.worktrees/` (CWD safety, ENOENT prevention) |
| 1 | /tmp/ redirect | deny | Writes to /tmp/; suggests project `tmp/` instead |
| 9 | Proof-status write guard | deny | `echo`/`tee` redirect to `.proof-status` with "verified" |
| 10 | Proof-status delete guard | deny | `rm .proof-status` when verification active (pending/needs-verification) |
| 5b | Worktree rm CWD safety | deny | `rm -rf .worktrees/` requires safe CWD (main repo, not inside worktree) |
| — | Early-exit gate | side-effect | Non-git commands skip git-specific checks (defers session-lib + doc-lib loads) |
| 2 | Main sacred | deny | `git commit` on main/master |
| 3 | Force push safety | deny | Force push to main/master; advisory for `--force-with-lease` on other branches |
| 3b | Local CI pre-push gate | deny/advisory | Runs local CI script if found; blocks push on failure; advisory if not found |
| 4 | Destructive git | deny | `git reset --hard`, `git clean -f` |
| 4b | Branch -D requires Guardian | deny | Force-delete (`git branch -D`) only in Guardian context |
| 5 | Worktree removal CWD safety | deny | Requires safe CWD; `--force` requires Guardian context |
| 6 | Merge test gate | deny | `git merge` with failing tests |
| 7 | Commit test gate | deny | `git commit` with failing tests |
| 8 | Proof gate | deny | `git commit`/`git merge` when `.proof-status` ≠ verified |
| — | Doc-freshness section | advisory/deny | Fires only on `git commit`/`git merge`; stale docs block merge to main, advisory on branch commits |

---

#### `task-track.sh` — Task / Agent dispatch gate

| Attribute | Value |
|-----------|-------|
| Event | `PreToolUse` |
| Matcher | `Task\|Agent` |
| Frequency | Every Agent (subagent) dispatch |
| Output type | `deny` + `advisory` |
| Injection size | 0 bytes context |
| Libraries | source-lib.sh, session-lib.sh, git-lib.sh, plan-lib.sh, trace-lib.sh |

**Purpose:** Subagent dispatch governance — proof gates, worktree isolation
enforcement, trace management.

**Gates:**

| Gate | Type | Condition |
|------|------|-----------|
| A.0: Duplicate guardian detection | deny | Active `.active-guardian-*-{phash}` marker within TTL (600s); prevents burst dispatch |
| A: Guardian proof gate | deny | `.proof-status` ≠ verified before Guardian dispatch; exceptions: plan-only merges, bootstrap path |
| B: Tester trace gate | advisory | Implementer trace still active (must return first); self-heals after 5 min stale |
| C.1: Implementer dispatch gate | deny | No linked worktree (dispatching implementer from main without worktree) |
| C.2: Proof gate activation | side-effect | Sets `.proof-status = needs-verification` on implementer dispatch (workflow-scoped or project-wide) |
| D: Plan vs planner advisory | advisory | Warns when `subagent_type=Plan` used for MASTER_PLAN.md work |
| E: isolation:worktree advisory | advisory | Warns when governance agents use `isolation: worktree` bypass |

**Performance:** Non-gated agents (explore, plan, bash) bypass all library loads
(~70% parse time saved). (DEC-LATENCY-001)

---

#### `pre-ask.sh` — AskUserQuestion merit gate

| Attribute | Value |
|-----------|-------|
| Event | `PreToolUse` |
| Matcher | `AskUserQuestion` |
| Frequency | Every AskUserQuestion call |
| Output type | `deny` + `advisory` |
| Injection size | 0 bytes context |
| Libraries | source-lib.sh, core-lib.sh |

**Purpose:** Merit gate — prevents low-value user interruptions that waste
attention on already-prescribed actions.

**Gates:**

| # | Gate | Type | Applies to |
|---|------|------|-----------|
| 0 | Dispatch-confirmation deny | deny | Orchestrator: blocks "Want me to dispatch Guardian/tester?", CI monitoring patterns |
| 1 | Forward-motion deny | deny | Subagents: blocks "should we continue/proceed/go ahead?" |
| 2 | Duplicate-gate deny | deny | Subagents: blocks "should I commit/merge/push?" |
| 3 | Obvious-answer deny | deny | All agents: blocks questions with ≤2 options where one is "(Recommended)" |
| 4 | Agent-context advisory | advisory | Implementers: non-blocking reminder to check the plan before escalating |

**Always-allow bypasses:** Orchestrator (after Gate 0), tester env-var questions.

---

### PostToolUse

#### `post-write.sh` — Write / Edit tracking and linting

| Attribute | Value |
|-----------|-------|
| Event | `PostToolUse` |
| Matcher | `Write\|Edit` |
| Frequency | Every Write or Edit call |
| Output type | `advisory` + `side-effect` |
| Injection size | 0 bytes context (advisories only) |
| Libraries | source-lib.sh, core-lib.sh, plan-lib.sh, session-lib.sh, doc-lib.sh |
| Consolidated from | track.sh + plan-validate.sh + lint.sh |

**Purpose:** Session tracking, plan structural validation, linting feedback.

**Steps (gate-isolated with `set +e`):**

| Step | Type | Action |
|------|------|--------|
| 1: Track | side-effect | Append file path to `.session-changes-{SID}`; update `.agent-progress` breadcrumb; append to `.session-events.jsonl`; invalidate doc/lint cache; reset `.proof-status` to pending on non-test source changes |
| 2: Plan validate | advisory | MASTER_PLAN.md structural validation if that file was written (required sections, phase structure, initiative format) |
| 3: Lint | advisory | Auto-detect linter (eslint, pylint, shellcheck, etc.); run with project config; results cached in `.lint-cache` |

---

#### `post-task.sh` — Agent completion handler

| Attribute | Value |
|-----------|-------|
| Event | `PostToolUse` |
| Matcher | `Task\|Agent` |
| Frequency | After every Agent tool completion |
| Output type | `context` (on auto-verify) + `side-effect` |
| Injection size | 100–200 bytes on auto-verify only |
| Libraries | source-lib.sh, session-lib.sh, trace-lib.sh |

**Purpose:** Auto-verify clean tester results; trace cleanup for non-tester agents.

**Logic:**
1. Detect `AUTOVERIFY: CLEAN` in tester's `summary.md`
2. Validate: **High** confidence (bold), no **Medium**/**Low**, no "Partially verified"
3. On success: write verified status to three paths (worktree, project, legacy); emit `AUTO-VERIFIED` directive
4. If no `SUBAGENT_TYPE`: finalize any active trace (fallback for non-tester agents)

---

#### `skill-result.sh` — Skill result injection

| Attribute | Value |
|-----------|-------|
| Event | `PostToolUse` |
| Matcher | `Skill` |
| Frequency | After every Skill call |
| Output type | `context` |
| Injection size | Up to 3800 bytes (truncated if >4000 bytes) |
| Libraries | source-lib.sh, session-lib.sh |

**Purpose:** Surface forked-skill results back to the parent context (context:fork
skills run in isolation; this bridge returns their output).

**Also:** Logs every Skill invocation to `.session-events.jsonl` with
`{skill, agent_type, args}` for forensic visibility.

---

#### `webfetch-fallback.sh` — WebFetch failure handler

| Attribute | Value |
|-----------|-------|
| Event | `PostToolUse` |
| Matcher | `WebFetch` |
| Frequency | After every WebFetch call |
| Output type | `context` (failure only) |
| Injection size | ~200 bytes on failure only (0 on success) |
| Libraries | _(none)_ |

**Purpose:** Deterministic recovery — detects blocked/failed fetches and
suggests alternatives: `mcp__fetch__fetch` (single URL), `batch-fetch.py`
(3+ URLs), Playwright MCP (JS-rendered sites).

---

#### `playwright-cleanup.sh` — Browser artifact cleanup

| Attribute | Value |
|-----------|-------|
| Event | `PostToolUse` |
| Matcher | `mcp__playwright__browser_snapshot` |
| Frequency | After every browser_snapshot call |
| Output type | `side-effect` |
| Injection size | 0 bytes |
| Libraries | _(minimal)_ |

**Purpose:** Clean up browser session artifacts after snapshot operations.

---

> **Note:** No `PostToolUse:Bash` hook is registered. Bash results flow directly
> to the model.

---

### SubagentStart

**Hook:** `subagent-start.sh`

| Attribute | Value |
|-----------|-------|
| Event | `SubagentStart` |
| Matcher | _(none — fires for all agent types)_ |
| Frequency | Once per subagent dispatch |
| Output type | `context` (additionalContext) |
| Injection size | ~900 bytes typical (600–1200 bytes range) |
| Libraries | source-lib.sh, session-lib.sh, git-lib.sh, plan-lib.sh, trace-lib.sh |

**Purpose:** Bootstrap each subagent with fresh project state and initialize
its trace.

**Signals injected:**
- Git state: branch, dirty count, worktree count
- MASTER_PLAN.md: existence, active phase/initiatives, architecture section
- Session event: `{type: agent_type}`
- Trace init: `init_trace()` creates `TRACE_ID/manifest.json` with metadata
- Subagent tracking: updates `.subagent-tracker`, refreshes statusline cache

**Guardian-specific (DEC-V2-005):** Injects session event log summary for
richer commit messages.

**Exemption:** `Bash|Explore` agents skip trace init (line 39).

---

### SubagentStop

Six specialized hooks fire when specific agent types complete.

---

#### `check-tester.sh`

| Attribute | Value |
|-----------|-------|
| Event | `SubagentStop` |
| Matcher | `tester` |
| Frequency | Once per tester completion |
| Output type | `context` |
| Injection size | 200–500 bytes |
| Libraries | source-lib.sh, session-lib.sh, trace-lib.sh, git-lib.sh, plan-lib.sh |

**Purpose:** Validate tester output and auto-verify clean e2e runs.

**Phase 1 (critical path, <2s budget):**
- Read tester's `summary.md` from trace directory
- Detect `AUTOVERIFY: CLEAN` keyword
- Validate: **High** confidence (bold), no **Medium**/**Low**, no "Partially verified"
- On success: write verified status to three paths; emit `AUTO-VERIFIED` directive; return immediately
- CAS failure counter: diagnostic if `cas_proof_status` failed 2+ times

**Phase 2 (advisory, best-effort):**
- Track subagent stop, finalize trace
- Git state, plan state injections
- Completeness gate: check if tester ran all tests (HAS_VERIFICATION)
- Auto-capture verification output
- Response size advisory; allow or request re-run decision

---

#### `check-implementer.sh`

| Attribute | Value |
|-----------|-------|
| Event | `SubagentStop` |
| Matcher | `implementer` |
| Frequency | Once per implementer completion |
| Output type | `context` |
| Injection size | 200–400 bytes |
| Libraries | source-lib.sh, session-lib.sh, trace-lib.sh, git-lib.sh, plan-lib.sh, doc-lib.sh |

**Purpose:** Validate implementer output and clean up traces.

**Process (5s timeout, trace finalization first):**
- Finalize trace immediately (beats timeout)
- Auto-capture: files-changed, test-output (best-effort, may timeout)
- Check: worktree usage, @decision annotation coverage, test status
- Note: proof-of-work check moved to tester (not here)

---

#### `check-guardian.sh`

| Attribute | Value |
|-----------|-------|
| Event | `SubagentStop` |
| Matcher | `guardian` |
| Frequency | Once per guardian completion |
| Output type | `context` |
| Injection size | 200–500 bytes |
| Libraries | source-lib.sh, session-lib.sh, trace-lib.sh, git-lib.sh, plan-lib.sh, ci-lib.sh |

**Purpose:** Validate guardian output and reset the proof gate for the next cycle.

**Process:**
- Track subagent stop, finalize trace
- Emit `commit` event if HEAD changed (compare guardian-start-sha to current HEAD)
- Plan recency check (compare MASTER_PLAN.md mtime to commit)
- Git cleanliness check (dirty count post-commit)
- Test status verification
- Phase B: clean up `.proof-status-{phash}` (resets verification cycle for next iteration)
- CI status injection if CI was run

---

#### `check-planner.sh`

| Attribute | Value |
|-----------|-------|
| Event | `SubagentStop` |
| Matcher | `planner\|Plan` |
| Frequency | Once per planner completion |
| Output type | `context` |
| Injection size | 200–400 bytes |
| Libraries | source-lib.sh, session-lib.sh, trace-lib.sh, git-lib.sh, plan-lib.sh |

**Purpose:** Validate planner output and clean up traces.

**Process (5s timeout, trace finalization first):**
- Plan existence and structure validation
- Phase validation (each phase is actionable?)
- Initiative validation (SMART initiatives?)
- Decision audit (compare @decision coverage in code vs plan)

---

#### `check-explore.sh`

| Attribute | Value |
|-----------|-------|
| Event | `SubagentStop` |
| Matcher | `Explore\|explore` |
| Frequency | Once per explore completion |
| Output type | `context` |
| Injection size | ~250 bytes (overflow flag only if triggered) |
| Libraries | source-lib.sh, session-lib.sh, trace-lib.sh |

**Purpose:** Explore result capture and overflow-to-disk fallback.

**Overflow detection:** If response >1200 words without a temp file written,
saves content to `tmp/explore-overflow-{timestamp}.md` and flags orchestrator.
(Note: Explore agents skip trace init — subagent-start.sh line 39 exempts `Bash|Explore`.)

---

#### `check-general-purpose.sh`

| Attribute | Value |
|-----------|-------|
| Event | `SubagentStop` |
| Matcher | `general-purpose` |
| Frequency | Once per general-purpose completion |
| Output type | `context` |
| Injection size | ~100 bytes (minimal) |
| Libraries | source-lib.sh, session-lib.sh, trace-lib.sh |

**Purpose:** General-purpose agent trace cleanup. No output contract validation.

---

### PreCompact

**Hook:** `compact-preserve.sh`

| Attribute | Value |
|-----------|-------|
| Event | `PreCompact` |
| Matcher | _(none — fires always)_ |
| Frequency | Before every /compact command |
| Output type | `context` (additionalContext) + `side-effect` (persistent file) |
| Injection size | ~700 bytes total (~500 bytes persistent file + ~200 bytes instructions) |
| Libraries | source-lib.sh, session-lib.sh, git-lib.sh, plan-lib.sh, trace-lib.sh |

**Purpose:** Preserve session intent across context compaction.

**Preserves:**
- Git state (branch, dirty count, linked worktrees)
- MASTER_PLAN.md preamble (Identity + Architecture sections)
- Active initiatives list
- Session trajectory narrative
- Todo HUD

**Output:**
1. `.claude/.preserved-context` — survives compaction, restored on resume
2. `additionalContext` — instructions for context-preservation skill

---

### Stop

**Hook:** `stop.sh`

| Attribute | Value |
|-----------|-------|
| Event | `Stop` |
| Matcher | _(none — fires after every model response)_ |
| Frequency | After every model response |
| Output type | `systemMessage` |
| Injection size | ~1500 bytes typical (1000–2000 bytes range) |
| Libraries | source-lib.sh, session-lib.sh, git-lib.sh, plan-lib.sh, trace-lib.sh, doc-lib.sh |
| Consolidated from | surface.sh + session-summary.sh + forward-motion.sh |

**Purpose:** Session context summary and trajectory narrative for the next turn.

**Sections (each gate-isolated with `set +e`):**

| Section | Type | Content |
|---------|------|---------|
| Surface | side-effect | @decision audit: coverage and drift detection; plan reconciliation; DECISIONS.md generation |
| Session summary | context | Files changed this turn; git state; test status; trajectory narrative |
| Forward motion | advisory | Feedback gate if response ends with call-to-action; advisory otherwise |

**Caching (DEC-PERF-004):**
- `.stop-plan-cache-{SID}` — TTL 300s
- `.stop-git-cache-{SID}` — TTL 60s
- Warm-path reduced from ~385ms to ~50ms per turn

---

### SessionEnd

**Hook:** `session-end.sh`

| Attribute | Value |
|-----------|-------|
| Event | `SessionEnd` |
| Matcher | _(none — fires always)_ |
| Frequency | Once per session termination |
| Output type | `side-effect` (cleanup only) |
| Injection size | 0 bytes |
| Libraries | source-lib.sh, session-lib.sh |

**Purpose:** Clean session-scoped scratch files and record session outcome.

**Cleans up:**
- `.session-changes-*`, `.session-decisions-*`, `.subagent-tracker-*`
- `.lint-cache`, test gate strikes/warnings, `.track.*`, `.skill-result*`
- Async test-runner processes

**Persists:**
- `.audit-log`, `.agent-findings`, `.proof-status` files, `.test-status`

**Session index (DEC-V2-PHASE4-002):** Writes outcome to `.session-index`
(cross-session learning, trimmed to 20 entries).

---

### Notification

**Hook:** `notify.sh`

| Attribute | Value |
|-----------|-------|
| Event | `Notification` |
| Matcher | `permission_prompt\|idle_prompt` |
| Frequency | When Claude requests permission or goes idle |
| Output type | `side-effect` (desktop notification) |
| Injection size | 0 bytes |
| Libraries | source-lib.sh |

**Purpose:** Desktop notification with terminal activation (macOS
`terminal-notifier` or `osascript` fallback). macOS only.

---

## Context Budget Summary

### Per-Session Injection (One-Time)

| Hook | When | Size |
|------|------|------|
| `session-init.sh` | Session start | ~800 bytes |
| `compact-preserve.sh` | On /compact | ~700 bytes |
| `subagent-start.sh` | Per subagent dispatched | ~900 bytes × N |

**Base total (cold start, no subagents):** ~800 bytes

### Per-Prompt Injection (Recurring)

| Hook | Typical | Range |
|------|---------|-------|
| `prompt-submit.sh` | ~600 bytes | 200–2000 bytes |

**Spike conditions:** Deferred work capture (~800 bytes extra), first-prompt
mitigation (~800 bytes, issue #10373 workaround), concurrent agent detection.

### Per-Tool-Use Injection

| Tool | Hook | Size |
|------|------|------|
| Write / Edit | pre-write.sh | 0 bytes (denies/advisories only) |
| Bash | pre-bash.sh | 0 bytes (denies/advisories only) |
| Write / Edit | post-write.sh | 0 bytes (side-effects + advisories) |
| Task / Agent | task-track.sh | 0 bytes (denies only) |
| Task / Agent | post-task.sh | 100–200 bytes (on auto-verify only) |
| Skill | skill-result.sh | 0–3800 bytes (if .skill-result.md exists) |
| WebFetch | webfetch-fallback.sh | 0–200 bytes (failure only) |
| browser_snapshot | playwright-cleanup.sh | 0 bytes |

### Per-SubagentStop Injection

| Agent | Hook | Size |
|-------|------|------|
| tester | check-tester.sh | 200–500 bytes |
| implementer | check-implementer.sh | 200–400 bytes |
| guardian | check-guardian.sh | 200–500 bytes |
| planner | check-planner.sh | 200–400 bytes |
| explore | check-explore.sh | ~250 bytes |
| general-purpose | check-general-purpose.sh | ~100 bytes |

### Post-Response (Stop Hook)

| Hook | Typical | Range |
|------|---------|-------|
| `stop.sh` | ~1500 bytes | 1000–2000 bytes |

Warm-path cached: plan (300s TTL), git (60s TTL).

### Estimated Session Budget

| Scenario | Calculation | Total |
|----------|-------------|-------|
| Cold start (0 prompts) | session-init: 800 | ~800 bytes |
| Single warm turn (no subagent) | prompt-submit: 600 + stop: 1500 | ~2100 bytes |
| Full implement–test–merge cycle | 3× SubagentStart (900) + 3× SubagentStop (350 avg) + 3× stop (1500) | ~9750 bytes overhead |
| 5-prompt block with 1 cycle | 5 × 600 (prompt) + cycle overhead + 5 × 1500 (stop) | ~18750 bytes |
| **Per-prompt average (amortized)** | Warm turn with subagent overhead | **~1320 bytes/prompt** |

---

## Redundancy Analysis

### Signals Appearing in Multiple Hooks

| Signal | Hooks | Rationale |
|--------|-------|-----------|
| Git branch + dirty count | session-init.sh, prompt-submit.sh (on commit/merge keywords), subagent-start.sh, compact-preserve.sh, stop.sh | Foundational context; redundancy intentional — each hook has a different consumption target |
| MASTER_PLAN.md phase/status | session-init.sh, prompt-submit.sh (on plan keywords), subagent-start.sh, compact-preserve.sh, stop.sh | Central to dispatch decisions; 5 hooks |
| Worktree count | session-init.sh, subagent-start.sh, compact-preserve.sh | Lightweight signal for branch context; 3 hooks |
| Todo HUD | session-init.sh, prompt-submit.sh (first-prompt fallback only) | Startup + bug #10373 workaround; 1–2 hooks |
| Auto-verify logic | post-task.sh (PostToolUse) + check-tester.sh (SubagentStop) | Two-path redundancy is intentional: post-task fires on completion tool event; check-tester fires on SubagentStop event. Race coverage. |

### Prompt vs Hook Enforcement Overlap

| Policy | Enforced in prompt | Enforced in hook |
|--------|-------------------|-----------------|
| "Main is sacred" | CLAUDE.md text | pre-write.sh Gate 1, pre-bash.sh Check 2 |
| "Dispatch tester first" | CLAUDE.md dispatch rules | task-track.sh Gate A (proof gate) |
| "Don't ask obvious questions" | CLAUDE.md interaction style | pre-ask.sh Gates 0–3 |
| "No /tmp/" | CLAUDE.md Sacred Practice #3 | pre-bash.sh Check 1 |
| "Add @decision to 50+ line files" | agents/implementer.md | pre-write.sh Gate 5 |
| "Tests before merge" | CLAUDE.md Sacred Practice #4 | pre-bash.sh Checks 6–7 |


---

## Noise Assessment

### High-Value Signals (Do Not Reduce)

| Signal | Hook | Why Essential |
|--------|------|--------------|
| Proof-status state machine | prompt-submit.sh, task-track.sh | Gates entire merge cycle; fires rarely (<1% of prompts) |
| Plan-check deny | pre-write.sh Gate 2 | Sacred Practice #6 enforcement; fires once per project setup |
| Test-gate deny | pre-write.sh Gate 3 | Prevents test regression; fires <5% of writes |
| Branch guard | pre-write.sh Gate 1 | Main is sacred; most important architectural invariant |
| AUTO-VERIFIED directive | post-task.sh, check-tester.sh | Critical dispatch signal; fires only on clean test runs |

### Appropriate Noise (Justified)

| Signal | Hook | Justification |
|--------|------|--------------|
| Per-prompt baseline context | prompt-submit.sh | 200–300 bytes absorbed by context window; conditional injection is valuable |
| Deferred-work auto-capture | prompt-submit.sh | Fire-and-forget (0 latency); prevents idea loss |
| Stop trajectory narrative | stop.sh | ~600 bytes; essential for model continuity across turns |
| First-prompt mitigation | prompt-submit.sh | ~800 bytes one-time; compensates for issue #10373; eliminates silently dropped sessions |

### Optimization Candidates

| Signal | Hook | Assessment | Opportunity |
|--------|------|-----------|-------------|
| Fast-mode bypass advisory | pre-write.sh | Low signal — advisory only, write still proceeds | Demote to debug logging; not injected into model |
| Cold test-gate advisory | pre-write.sh | Low signal — cold-start only, doesn't block | Demote to debug logging |
| Doc-freshness advisory | pre-bash.sh | Medium signal — appropriate on commit/merge | Keep deny gates, consider suppressing bare advisory |
| Per-prompt keyword detection | prompt-submit.sh | ~50–100ms regex re-evaluation every prompt | Cache keyword match across consecutive identical-context prompts; invalidate on plan/git change |
| Trajectory narrative | stop.sh | ~300–400ms regeneration every turn | Cache if no major state changes between consecutive stops |
| Plan churn detection | pre-write.sh Gate 2 | Nested git/grep calls for every source write | Skip drift audit if churn <5% |

---

## Critical Design Patterns

### Atomic Proof-of-Work State Machine

```
State: pending → verified → committed → pending (cycle)
```

- **CAS (Compare-And-Swap):** `cas_proof_status()` uses file locks
  (`.claude/state/locks/proof.lock`, 2s timeout, 10s stale cleanup)
- **Dual-write migration:** New path `.claude/state/{phash}/proof-status` +
  old `.claude/.proof-status-{phash}` (backward compat)
- **Bootstrap paradox detection:** Tracks CAS failures; 2+ failures → diagnostic
  warning injected

### Gate Isolation and Crash Recovery

All composite hooks (`pre-write.sh`, `pre-bash.sh`, `post-write.sh`, `stop.sh`)
use `set +e / set -e` sandwiching to isolate crashes in advisory sections without
blocking critical deny gates. An exit trap (`_hook_crash_deny`) provides
fail-closed behavior if the hook crashes before completion.

### Trace Protocol

- **Active marker files:** `.active-{agent_type}-{session_id}-{phash}`
- **TTL enforcement:** 600s; Guardian heartbeat refreshes every 60s (5-iteration ceiling)
- **Trace sealing:** `finalize_trace()` writes completed manifest, removes active marker
- **Race prevention:** task-track.sh pre-creates Guardian marker at dispatch (before agent spawns)

### Proof Gate Scoping

- **Workflow-scoped (new):** `.claude/state/{phash}/worktrees/{name}/proof-status`
- **Project-wide (backward compat):** `.claude/state/{phash}/proof-status`
- Dual-write during migration supports both paths simultaneously

### Session Event Log

- **Format:** JSONL append-only (`.session-events.jsonl`)
- **Fields:** `{timestamp, event, detail, context}`
- **Consumed by:** stop.sh (trajectory narrative), check-*.sh (artifact capture)

### TTL-Based Caching (DEC-PERF-004)

| Cache | File | TTL | Warm speedup |
|-------|------|-----|-------------|
| Plan state | `.stop-plan-cache-{SID}` | 300s | ~335ms saved |
| Git state | `.stop-git-cache-{SID}` | 60s | ~50ms saved |
| Lint results | `.lint-cache` | Until file changes | Avoid re-lint |

### Breadcrumb Patterns

| File | Written by | Read by | Purpose |
|------|-----------|---------|---------|
| `.proof-gate-pending` | prompt-submit.sh (CAS start) | prompt-submit.sh (next prompt) | Timestamps interrupted verification |
| `.cas-failures` | prompt-submit.sh | prompt-submit.sh | Bootstrap-paradox diagnostic counter |
| `.guardian-start-sha` | task-track.sh | check-guardian.sh | Detect if HEAD changed during Guardian run |
| `.agent-progress` | post-write.sh | statusline script | Per-write breadcrumb for statusline display |

---

## Summary Statistics

| Metric | Value |
|--------|-------|
| Total hooks registered | 24 |
| Event stages covered | 8 (SessionStart, UserPromptSubmit, PreToolUse ×4, PostToolUse ×5, SubagentStart, SubagentStop ×6, PreCompact, Stop, SessionEnd, Notification) |
| Total gates declared | 50+ (23 in pre-write.sh, 17 in pre-bash.sh, 5 in task-track.sh, 5 in pre-ask.sh, distributed in others) |
| Libraries (shared) | 10 (source-lib, context-lib, session-lib, git-lib, plan-lib, trace-lib, state-lib, doc-lib, ci-lib, core-lib) |
| Per-session context (cold start) | ~800 bytes |
| Per-prompt context (warm, typical) | ~600 bytes |
| Per-stop context | ~1500 bytes |
| Per-subagent context (start) | ~900 bytes |
| Per-subagent context (stop) | 100–500 bytes |
| Library load cost (hot, consolidated) | ~60ms per hook |
| Consolidation savings (Phase 2) | ~350ms per complex turn |
| Proof-status states | pending → verified → committed |
| Guardian marker TTL | 600s (60s heartbeat refresh, 5-iteration ceiling) |
| Plan cache TTL | 300s |
| Git state cache TTL | 60s |
| Proof lock timeout | 2s (10s stale cleanup) |
| Explore overflow threshold | 1200 words (spillover to `tmp/explore-overflow-*.md`) |
| Skill result size budget | 3800 bytes (truncated if >4000) |
| Session index retention | 20 entries (trimmed at SessionEnd) |
