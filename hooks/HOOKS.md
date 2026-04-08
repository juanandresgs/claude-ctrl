# Hook System Reference

Technical reference for the Claude Code hook system. For philosophy and workflow, see `../CLAUDE.md`. For the summary table, see `../README.md`.

---

## Protocol

All hooks receive JSON on **stdin** and emit JSON on **stdout**. Stderr is for logging only. Exit code 0 = success. Non-zero = hook error (logged, does not block).

### Stdin Format

```json
{
  "tool_name": "Write|Edit|Bash|...",
  "tool_input": { "file_path": "...", "command": "..." },
  "cwd": "/current/working/directory"
}
```

SubagentStart/SubagentStop hooks receive `{"subagent_type": "planner|implementer|tester|guardian", ...}`. Stop hooks receive `{"response": "..."}`.

### Stdout Responses (PreToolUse only)

**Deny** — block the tool call:
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Explanation shown to the model"
  }
}
```

**Rewrite** — transparently modify the command (model sees rewritten version):
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "Explanation",
    "updatedInput": { "command": "rewritten command here" }
  }
}
```

**Advisory** — inject context without blocking:
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "Warning or guidance text"
  }
}
```

PostToolUse hooks use `additionalContext` for feedback. Exit code 2 in lint.sh triggers a feedback loop (model retries with linter output).

### Stop Hook Responses

Stop hooks have a **different schema** from PreToolUse/PostToolUse. They do NOT accept `hookSpecificOutput`. Valid fields:

**System message** — inject context into the next turn:
```json
{
  "systemMessage": "Summary text shown as system-reminder"
}
```

**Block** — prevent the response from completing (rare):
```json
{
  "decision": "block",
  "reason": "Explanation of why the response was blocked"
}
```

Stop hooks receive `{"stop_hook_active": true/false, "response": "..."}` on stdin. Check `stop_hook_active` to prevent re-firing loops (if a Stop hook's `systemMessage` triggers another model response, the next Stop invocation will have `stop_hook_active: true`).

### Guard Pattern

The v2.0 backport now prefers **deny with a corrective command** for unsafe Bash.
This keeps the control plane deterministic and makes the model consciously choose
the safe path instead of silently inheriting a rewritten command.

---

## Shared Libraries

### log.sh — Input handling and logging

Source with: `source "$(dirname "$0")/log.sh"`

| Function | Purpose |
|----------|---------|
| `read_input` | Read and cache stdin JSON into `$HOOK_INPUT` (call once) |
| `get_field <jq_path>` | Extract field from cached input (e.g., `get_field '.tool_input.command'`) |
| `detect_project_root` | Returns `$CLAUDE_PROJECT_DIR` → git root → `$HOME` (fallback chain) |
| `log_info <stage> <msg>` | Human-readable stderr log |
| `log_json <stage> <msg>` | Structured JSON stderr log |

### context-lib.sh — Project state detection

Source with: `source "$(dirname "$0")/context-lib.sh"`

| Function | Populates |
|----------|-----------|
| `get_git_state <root>` | `$GIT_BRANCH`, `$GIT_DIRTY_COUNT`, `$GIT_WORKTREES`, `$GIT_WT_COUNT` |
| `get_plan_status <root>` | `$PLAN_EXISTS`, `$PLAN_PHASE`, `$PLAN_TOTAL_PHASES`, `$PLAN_COMPLETED_PHASES`, `$PLAN_IN_PROGRESS_PHASES`, `$PLAN_AGE_DAYS`, `$PLAN_COMMITS_SINCE`, `$PLAN_CHANGED_SOURCE_FILES`, `$PLAN_TOTAL_SOURCE_FILES`, `$PLAN_SOURCE_CHURN_PCT` |
| `get_session_changes <root>` | `$SESSION_CHANGED_COUNT`, `$SESSION_FILE` |
| `get_research_status <root>` | `$RESEARCH_EXISTS`, `$RESEARCH_ENTRY_COUNT` |
| `is_source_file <path>` | Tests against `$SOURCE_EXTENSIONS` regex |
| `is_skippable_path <path>` | Tests for config/test/vendor/generated paths |
| `append_audit <root> <event> <detail>` | Emits audit event via `rt_event_emit` (SQLite event store; `.audit-log` flat file removed in TKT-008) |
| `canonical_session_id` | Stable session ID for per-session files |
| `current_workflow_id <root>` | Stable workflow ID (usually current branch) |
| `file_mtime <path>` | Cross-platform file mtime helper |
| `read_evaluation_status <root> [workflow]` | Evaluation status (`idle`, `pending`, `needs_changes`, `ready_for_guardian`, `blocked_by_plan`) — sole readiness authority (TKT-024) |
| `read_evaluation_state <root> [workflow]` | Full evaluation state JSON including head_sha |
| `write_evaluation_status <root> <status> [wf] [sha]` | Upserts evaluation state — used by check-tester.sh (verdicts), post-task.sh (pending) |
| `current_active_agent_role <root>` | Best-effort current subagent role |
| `is_guardian_role <role>` | True only for Guardian |

`$SOURCE_EXTENSIONS` is the single source of truth for source file detection: `ts|tsx|js|jsx|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php|sh|bash|zsh`

---

## Execution Order (Session Lifecycle)

```
SessionStart    → session-init.sh (git state, plan status, worktree warnings)
                    ↓
UserPromptSubmit → prompt-submit.sh (keyword-based context injection)
                    ↓
PreToolUse:Bash → pre-bash.sh (thin adapter → cc-policy evaluate, 12 bash policies)
                   auto-review.sh (intelligent command auto-approval)
PreToolUse:W/E  → pre-write.sh (thin adapter → cc-policy evaluate, 10 write policies)
                   test-gate.sh, mock-gate.sh, doc-gate.sh (no-ops — policies run via engine)
                    ↓
[Tool executes]
                    ↓
PostToolUse:W/E → lint.sh → track.sh → code-review.sh → plan-validate.sh → test-runner.sh (async)
                    ↓
SubagentStart   → subagent-start.sh (agent-specific context)
SubagentStop    → check-planner.sh | check-implementer.sh | check-tester.sh | check-guardian.sh
                    ↓
Stop            → surface.sh (decision audit) → session-summary.sh → forward-motion.sh
                    ↓
PreCompact      → compact-preserve.sh (context preservation)
                    ↓
SessionEnd      → session-end.sh (cleanup)
```

Hooks within the same event run **sequentially** in array order from settings.json. A deny from any PreToolUse hook stops the tool call — later hooks in the chain don't run.

---

## Hook Details

### PreToolUse — Block Before Execution

| Hook | Matcher | What It Does |
|------|---------|--------------|
| **pre-bash.sh** | Bash | Thin adapter: calls `cc-policy evaluate` which runs 12 bash policies (tmp_safety, worktree_cwd, git_who, main_sacred, force_push, destructive_git, worktree_removal, test_gate_merge, test_gate_commit, eval_readiness, workflow_scope, approval_gate). Fail-closed. Target-repo context resolution for `git -C` commands. |
| **auto-review.sh** | Bash | Three-tier command classifier: auto-approves safe commands, defers risky ones to user |
| **pre-write.sh** | Write\|Edit | Thin adapter: calls `cc-policy evaluate` which runs 10 write policies (branch_guard, write_who, enforcement_gap, plan_guard, plan_exists, plan_immutability, decision_log, test_gate_pretool, doc_gate, mock_gate). Fail-closed. |
| **test-gate.sh** | Write\|Edit | No-op — policy runs via engine (test_gate_pretool) |
| **mock-gate.sh** | Write\|Edit | No-op — policy runs via engine (mock_gate) |
| **doc-gate.sh** | Write\|Edit | No-op — policy runs via engine (doc_gate) |

### PostToolUse — Feedback After Execution

| Hook | Matcher | What It Does |
|------|---------|--------------|
| **lint.sh** | Write\|Edit | Auto-detects project linter per extension (ruff, black, shellcheck, etc.), runs on modified files. Exit 2 = feedback loop. If no linter exists for the extension (unsupported) or the binary is missing (missing_dep), records an enforcement gap in `.enforcement-gaps`, emits advisory `additionalContext`, and exits 0 — hard DENY for persistent gaps (encounter_count > 1) is issued by the policy engine (`write_enforcement_gap.py`, DEC-LINT-002) on the next Write/Edit, not by lint.sh. Shell files always map to shellcheck with no config required |
| **track.sh** | Write\|Edit | Records file changes to `.session-changes-$SESSION_ID`. Invalidates evaluation_state (ready_for_guardian→pending) when source files change after evaluator clearance — ensuring the evaluated HEAD and the committed HEAD are the same (TKT-024) |
| **code-review.sh** | Write\|Edit | Fires on 20+ line source files (skips tests and config). Injects diff context and suggests `mcp__multi__codereview` for multi-model analysis. Falls back silently if Multi-MCP is unavailable |
| **plan-validate.sh** | Write\|Edit | Validates MASTER_PLAN.md structure on every write: phase Status fields (`planned`/`in-progress`/`completed`), Decision Log content for completed phases, original intent section preserved, DEC-COMPONENT-NNN ID format. Exit 2 = feedback loop with fix instructions |
| **test-runner.sh** | Write\|Edit | **Async** — doesn't block Claude. Auto-detects test framework (pytest, vitest, jest, npm-test, cargo-test, go-test). 2s debounce lets rapid writes settle. 10s cooldown between runs. Lock file ensures single instance (kills previous run if superseded). Writes `test_state` SQLite table (via `rt_test_state_set`) as the primary enforcement authority. `.test-status` flat-file write has been removed (WS-DOC-CLEAN). Reports results via `systemMessage` |

### Session Lifecycle

| Hook | Event | What It Does |
|------|-------|--------------|
| **session-init.sh** | SessionStart | Injects git state, MASTER_PLAN.md status, active worktrees, evaluation state (TKT-024), todo HUD, unresolved agent findings, preserved context from pre-compaction. Resets prompt count for first-prompt fallback. Note: stale `.test-status` clearing was removed when the flat file was eliminated (WS-DOC-CLEAN); runtime `test_state` is session-scoped by HEAD SHA. Known: SessionStart has a bug ([#10373](https://github.com/anthropics/claude-code/issues/10373)) where output may not inject for brand-new sessions — works for `/clear`, `/compact`, resume |
| **prompt-submit.sh** | UserPromptSubmit | First-prompt mitigation for SessionStart bug: on the first prompt of any session, injects full session context (same as session-init.sh) as a reliability fallback. On subsequent prompts: keyword-based context injection — file references trigger @decision status, "plan"/"implement" trigger MASTER_PLAN phase status, "merge"/"commit" trigger git dirty state. Also: auto-claims issue refs ("fix #42"), detects deferred-work language ("later", "eventually") and suggests `/backlog`, flags large multi-step tasks for scope confirmation. Note: proof verification on user "verified" reply was removed in TKT-024 — readiness is now set exclusively by check-tester.sh via evaluation_state |
| **compact-preserve.sh** | PreCompact | Dual output: (1) persistent `.preserved-context` file that survives compaction and is re-injected by session-init.sh, and (2) `additionalContext` including a compaction directive instructing the model to generate a structured context summary (objective, active files, constraints, continuity handoff). Captures git state, plan status, session changes, @decision annotations, test status, agent findings, and audit trail |
| **session-end.sh** | SessionEnd | Kills lingering async test-runner processes, releases todo claims for this session, cleans session-scoped files (`.session-changes-*`, `.prompt-count-*`, `.lint-cache`, strike counters). Cross-session flat files `.audit-log`, `.plan-drift`, and `.agent-findings` are no longer written or read (TKT-008/TKT-018/WS4/W-CONV-6); agent findings now flow through the runtime event store (`agent_finding` events) |

### Stop Hooks

| Hook | Event | What It Does |
|------|-------|--------------|
| **surface.sh** | Stop | Full decision audit pipeline: (1) extract — scans project source directories for @decision annotations using ripgrep (with grep fallback); (2) validate — checks changed files over 50 lines for @decision presence and rationale; (3) reconcile — compares DEC-IDs in MASTER_PLAN.md vs code, identifies unplanned decisions (in code but not plan) and unimplemented decisions (in plan but not code), respects deprecated/superseded status; (4) persist — audit events route through `rt_event_emit` (`.plan-drift` flat file removed in W-CONV-6). Reports via `systemMessage` |
| **session-summary.sh** | Stop | Deterministic (<2s runtime). Counts unique files changed (source vs config), @decision annotations added. Reports git branch, dirty/clean state, test status (waits briefly for in-flight async test-runner). Generates workflow-aware next-action guidance: on main → "create plan" or "create worktrees"; on feature branch → "fix tests", "run tests", "review changes", or "merge to main" based on current state. Includes pending todo count |
| **forward-motion.sh** | Stop | Deterministic regex check (not AI). Extracts the last paragraph of the assistant's response and checks for forward motion indicators: `?`, "want me to", "shall I", "let me know", "would you like", "next step", etc. Returns exit 2 (feedback loop) only if the response ends with a bare completion statement ("done", "finished", "all set") and no question mark — prompting the model to add a suggestion or offer |

### Notifications

| Hook | Matcher | What It Does |
|------|---------|--------------|
| **notify.sh** | permission_prompt\|idle_prompt | Desktop notification when Claude needs attention (macOS only). Uses `terminal-notifier` (activates terminal on click) with `osascript` fallback. Sound varies by urgency: `Ping` for permission prompts, `Glass` for idle prompts |

### Subagent Lifecycle

| Hook | Event / Matcher | What It Does |
|------|-----------------|--------------|
| **subagent-start.sh** | SubagentStart | Creates runtime agent marker via `rt_marker_set` (TKT-016). Injects git state + plan status into every subagent. Agent-type-specific guidance: **Implementer** gets worktree creation warning (if none exist), test status, and a Tester handoff reminder. **Tester** gets evaluation state context and REQUIRED EVAL_* trailer instructions (TKT-024). **Guardian** gets plan update rules, test status, and evaluation_state authority reminders. **Planner** gets research log status. Lightweight agents (Bash, Explore) get minimal context |
| **check-planner.sh** | SubagentStop (planner\|Plan) | Deactivates runtime agent marker via `rt_marker_deactivate` (TKT-016). 5 checks: (1) MASTER_PLAN.md exists, (2) has `## Phase N` headers, (3) has intent/vision section, (4) has issues/tasks, (5) approval-loop detection (agent ended with question but no plan completion confirmation). Advisory only — always exit 0. Persists findings via `rt_event_emit "agent_finding"` (WS4: flat file `.agent-findings` removed) |
| **check-implementer.sh** | SubagentStop (implementer) | Deactivates runtime agent marker (TKT-016). 5 checks: (1) current branch is not main/master (worktree was used), (2) @decision coverage on 50+ line source files changed this session, (3) approval-loop detection, (4) test status verification (recent failures = "implementation not complete"), (5) verification handoff note so Tester is the next role. Advisory only. Persists findings |
| **check-tester.sh** | SubagentStop (tester) | Deactivates runtime agent marker (TKT-016). Sole writer of evaluation_state verdicts (TKT-024): parses EVAL_VERDICT/EVAL_TESTS_PASS/EVAL_NEXT_ROLE/EVAL_HEAD_SHA trailers from tester output, writes evaluation_state. Fail-closed: missing or malformed trailers → needs_changes. Also: advisory evidence check, test status check. Persists findings |
| **check-guardian.sh** | SubagentStop (guardian) | Deactivates runtime agent marker (TKT-016). 6 checks: (1) MASTER_PLAN.md freshness — only for phase-completing merges, must be updated within 300s, (2) git status is clean (no uncommitted changes), (3) branch info for context, (4) approval-loop detection, (5) test status for git operations (CRITICAL if tests failing when merge/commit detected), (6) evaluation_state for completed git operations — Guardian should only operate when eval_status == ready_for_guardian (TKT-024). Advisory only. Persists findings |
| **post-task.sh** | SubagentStop (all types) | Completion routing (TKT-009/WS6). Sets evaluation_state=pending on implementer completion (TKT-024). Routes tester/guardian completion via completion records and `determine_next_role()`: ready_for_guardian→guardian, needs_changes→implementer, blocked_by_plan→planner. Emits next-role suggestion via hookSpecificOutput (DEC-WS6-001: dispatch_queue no longer written) |

---

## Key Bash Policy Behaviors (formerly guard.sh)

The bash-path policies (migrated from guard.sh in INIT-PE) cover worktree
safety, WHO enforcement, destructive git protection, and evidence gates.

**Hard blocks** (deny with explanation and a safe replacement when useful):

| Check | Trigger | Why |
|-------|---------|-----|
| 1 | `/tmp/` or `/private/tmp/` write | Artifacts must stay in project-local `tmp/` |
| 2 | bare `cd` into `.worktrees/` | Prevents CWD-related worktree deletion failures |
| 3 | `git commit`, `merge`, or `push` by non-Guardian | Permanent git authority belongs to Guardian only |
| 4 | `git commit` on main/master | Sacred Practice #2 (exempts `~/.claude` meta-repo and MASTER_PLAN.md-only commits) |
| 5 | raw `git push --force` | Must use `--force-with-lease`; main/master force push is denied outright |
| 6 | `git reset --hard`, `git clean -f`, `git branch -D` | Destructive operations — suggests safe alternatives |
| 7 | unsafe `git worktree remove` | Requires an explicit safe `cd` away from the target worktree |

**Evidence gates** (require evidence before commit/merge):

| Check | Requires | State Source | Exemption |
|-------|----------|------------|-----------|
| 8-9 | `test_state` = `pass` | `test_state` SQLite table via `rt_test_state_get` (HEAD-SHA-aligned; format: `result|fail_count|timestamp|head_sha`) | `~/.claude` meta-repo (no test framework by design) |
| 10 | `evaluation_state.status` = `ready_for_guardian` AND `head_sha` matches current HEAD | `evaluation_state` table via `read_evaluation_status` / `read_evaluation_state` (runtime SQLite) | `~/.claude` meta-repo |
| 12 | workflow binding + scope | `workflow_bindings` + `workflow_scope` tables | `~/.claude` meta-repo |

Test evidence: only `pass` satisfies the gate. Any non-pass status (`fail` of any age, unknown, missing file) = denied. Recent failures (< 10 min) get a specific error message with failure count; older failures get a generic "did not pass" message.

Evaluator readiness (TKT-024): the Tester evaluates the implementation and emits EVAL_VERDICT/EVAL_TESTS_PASS/EVAL_NEXT_ROLE/EVAL_HEAD_SHA trailers. `check-tester.sh` parses these and writes `evaluation_state`. Only `ready_for_guardian` with a matching `head_sha` passes Check 10. Source changes after evaluator clearance invalidate readiness via `track.sh` (ready_for_guardian→pending). `proof_state` table and helpers were removed in W-CONV-6 — `evaluation_state` is the sole readiness authority.

---

## Key plan-check.sh Behaviors

Beyond checking for MASTER_PLAN.md existence, this hook scores plan staleness using two signals:

| Signal | What It Measures | Warn Threshold | Deny Threshold |
|--------|-----------------|----------------|----------------|
| **Source churn %** | Percentage of tracked source files changed since plan update | 15% | 35% |
| **Decision drift** | Count of unplanned + unimplemented @decision IDs (from `surface.sh` audit) | 2 IDs | 5 IDs |

The composite score takes the worst tier across both signals. If either hits deny threshold, writes are blocked until the plan is updated. This is self-normalizing — a 3-file project and a 300-file project both trigger at the same percentage.

**Bypasses:** Edit tool (inherently scoped), Write under 20 lines (trivial), non-source files, test files, non-git directories, `~/.claude` meta-infrastructure.

---

## Key auto-review.sh Behaviors

An 840-line policy engine that replaces the blunt "allow or ask" permission model with intelligent classification:

| Tier | Behavior | How It Decides |
|------|----------|---------------|
| **1 — Safe** | Auto-approve | Command is inherently read-only: `ls`, `cat`, `grep`, `cd`, `echo`, `sort`, `wc`, `date`, etc. |
| **2 — Behavior-dependent** | Analyze subcommand + flags | `git status` ✅ auto-approve; `git rebase` ⚠️ advisory. Compound commands (`&&`, `\|\|`, `;`, `\|`) decomposed — every segment must be safe |
| **3 — Always risky** | Advisory context → defer to user | `rm`, `sudo`, `kill`, `ssh`, `eval`, `bash -c` — risk reason injected so the permission prompt explains *why* |

**Recursive analysis:** Command substitutions (`$()` and backticks) are analyzed to depth 2. `cd $(git rev-parse --show-toplevel)` auto-approves because both `cd` (Tier 1) and `git rev-parse` (Tier 2 → read-only) are safe.

**Dangerous flag escalation:** `--force`, `--hard`, `--no-verify`, `-f` (on git) escalate any command to risky regardless of tier.

**Interaction with pre-bash.sh:** The policy engine (via pre-bash.sh) runs first (sequential in settings.json). If a bash policy denies, auto-review never executes. If all policies pass, auto-review classifies. This means the policy engine handles the hard security boundaries, auto-review handles the UX of permission prompts.

---

## Enforcement Patterns

Three patterns recur across the hook system:

**Escalating gates** — warn on first offense, block on repeat. Used when the model may have a legitimate reason to proceed once, but repeat violations indicate a broken workflow.

| Hook | Strike File | Warn | Block |
|------|------------|------|-------|
| **test_gate_pretool** (policy) | `.test-gate-strikes` | First source write with failing tests | Second source write without fixing tests |
| **mock_gate** (policy) | `.mock-gate-strikes` | First internal mock detected | Second internal mock (external boundary mocks always allowed) |

**Feedback loops** — exit code 2 tells Claude Code to retry the operation with the hook's output as guidance, rather than failing outright. The model gets a chance to fix the issue automatically.

| Hook | Triggers exit 2 when |
|------|---------------------|
| **lint.sh** | Linter finds fixable issues in the written file (enforcement-gap deny moved to policy engine per DEC-LINT-002) |
| **plan-validate.sh** | MASTER_PLAN.md fails structural validation (missing Status fields, empty Decision Log, bad DEC-ID format) |
| **forward-motion.sh** | Response ends with bare completion ("done") and no question, suggestion, or offer |

**Corrective denies** — the hook blocks the unsafe command and tells the model the exact safe pattern to use instead.

| Hook | Corrective behavior |
|------|--------------------|
| **bash policies** (via engine) | Denies unsafe `/tmp/`, raw force push, and unsafe worktree removal with explicit replacement commands |

---

## Enforcement Coverage

Every source file type in `SOURCE_EXTENSIONS` must have an active linter or the system must say so loudly. Silent non-enforcement is a policy violation, not a neutral skip.

### Philosophy

**Unsupported coverage** — a source extension in `SOURCE_EXTENSIONS` that has no configured linter profile — is a policy gap. The old behaviour was `exit 0` (silent pass). The new behaviour is `exit 2` with `additionalContext` explaining the gap, a persisted record in `.enforcement-gaps`, and a GitHub Issue filed on first encounter.

**Missing enforcer dependency** — a linter profile is detected (e.g., shellcheck for `.sh`) but the binary is not on `PATH` — is a degraded enforcement state. Same treatment as unsupported.

**Self-healing** — when lint.sh runs and the linter is now available for a previously-gapped extension, it removes the gap entry automatically. No manual cleanup needed.

**No source write ends with "no enforcement ran and nobody was told."** If enforcement cannot run, the model is told, the gap is recorded, and writes are eventually blocked until the gap is resolved.

### Four Signal Paths

| Path | Mechanism | When | Effect |
|------|-----------|------|--------|
| **Immediate feedback** | `lint.sh` PostToolUse `additionalContext` + exit 2 | Every gap encounter | Model sees the gap in the same turn |
| **Persisted gap state** | `.claude/.enforcement-gaps` | First + subsequent encounters | Survives session boundaries |
| **Repeated-write deny** | `pre-write.sh` `check_enforcement_gap` PreToolUse `permissionDecision=deny` | When `encounter_count > 1` for the target file's extension | True deterministic block — write is rejected before it happens |
| **Backlog/support record** | `scripts/todo.sh add --global` (GitHub Issue) | First encounter only, best-effort | Durable record visible outside Claude |

### Gap State File Format

`.claude/.enforcement-gaps` — one line per unique gap, keyed on `type|ext`:

```
type|ext|tool|first_epoch|encounter_count
```

- `type`: `unsupported` (no profile) or `missing_dep` (profile exists, binary missing)
- `ext`: file extension without the dot (e.g., `java`, `sh`)
- `tool`: linter name or `none`
- `first_epoch`: Unix timestamp of first encounter
- `encounter_count`: total encounters (incremented on each lint.sh run for this ext)

The file is NOT cleaned by `session-end.sh`. It represents unresolved repo state. It IS cleaned when lint.sh runs successfully for the same extension (self-healing).

### Shell File Enforcement

Shell files (`.sh`, `.bash`, `.zsh`) now always map to `shellcheck` — no project config file is required. This is intentional: shell is the primary hook language for this system, so enforcement must be unconditional. If `shellcheck` is not installed, a `missing_dep` gap fires instead of silent pass.

---

## State Files

Hooks communicate across events through state files in the project's `.claude/` directory. This is the backbone that connects async test execution to commit-time evidence gates, session tracking to end-of-session audits, and compaction preservation to next-session context injection.

**Session-scoped** (cleaned up by session-end.sh):

| File | Written By | Read By | Contents |
|------|-----------|---------|----------|
| `.session-changes-$ID` | track.sh | surface.sh, session-summary.sh, check-implementer.sh, compact-preserve.sh | One file path per line — every Write/Edit this session |
| `.prompt-count-$ID` | prompt-submit.sh | prompt-submit.sh | Tracks whether first-prompt mitigation has fired |
| `.test-gate-strikes` | test-gate.sh | test-gate.sh | Strike count for escalating enforcement |
| `.mock-gate-strikes` | mock-gate.sh | mock-gate.sh | Strike count for escalating enforcement |
| `.test-runner.lock` | test-runner.sh | test-runner.sh | PID of active test process (prevents concurrent runs) |
| `.test-runner.last-run` | test-runner.sh | test-runner.sh | Epoch timestamp of last run (10s cooldown) |

**Cross-session** (preserved by session-end.sh):

| File | Written By | Read By | Contents |
|------|-----------|---------|----------|
| `.test-status` | ELIMINATED (WS-DOC-CLEAN) | ~~guard.sh, test-gate.sh, session-summary.sh, check-implementer.sh, check-guardian.sh, subagent-start.sh~~ | Replaced by `test_state` SQLite table (`rt_test_state_set`/`rt_test_state_get`). All enforcement hooks now read from runtime. |
| `.agent-findings` | ~~check-planner.sh, check-implementer.sh, check-tester.sh, check-guardian.sh~~ | ~~prompt-submit.sh, compact-preserve.sh~~ | ELIMINATED (WS4/A5): all writers migrated to `rt_event_emit "agent_finding"` and all readers migrated to `event query --type agent_finding`. File is no longer created or read. |
| `.preserved-context` | compact-preserve.sh | session-init.sh | Full session state snapshot — injected after compaction, then deleted (one-time use) |
| `.enforcement-gaps` | lint.sh | pre-write.sh (check_enforcement_gap), session-init.sh, prompt-submit.sh | `type\|ext\|tool\|first_epoch\|encounter_count` — one line per unique gap; NOT cleaned by session-end.sh (represents unresolved repo state, not session ephemeral data); self-healed by lint.sh when tool is installed |

**Eliminated flat files** (no longer written or read as state authority):

| File | Former Role | Replacement | Removed By |
|------|------------|-------------|-----------|
| `.proof-status-<workflow>` | Proof state authority | `evaluation_state` table (TKT-024); `proof_state` table and helpers removed in W-CONV-6 | TKT-007/TKT-018/TKT-024/W-CONV-6 |
| `.subagent-tracker` | Active agent role tracking | `agent_markers` table via `rt_marker_set`/`rt_marker_deactivate` | TKT-007/TKT-018 |
| `.statusline-cache` | Statusline data cache | `cc-policy statusline snapshot` runtime projection | TKT-012/TKT-018 |
| `.audit-log` | Audit trail file | `events` table via `rt_event_emit` (through `append_audit`) | TKT-008. Note: `compact-preserve.sh` still has a stale reader |
| `.plan-drift` | Drift scoring data | Dead write removed in W-CONV-6; `plan-check.sh` uses commit-count heuristic | TKT-018/W-CONV-6 |
| `.test-status` | Test result evidence gate | `test_state` SQLite table via `rt_test_state_set`/`rt_test_state_get` | WS-DOC-CLEAN (flat-file write removed from test-runner.sh) |

---

## settings.json Registration

Hook registration in `../settings.json` → `hooks` object:

```json
{
  "hooks": {
    "<EventName>": [
      {
        "matcher": "ToolName|OtherTool",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.claude/hooks/script.sh",
            "timeout": 5,
            "async": false
          }
        ]
      }
    ]
  }
}
```

- **Event names**: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `SubagentStart`, `SubagentStop`, `PreCompact`, `Stop`, `SessionEnd`
- **matcher**: Pipe-delimited tool names for PreToolUse/PostToolUse, agent types for SubagentStop, event subtypes for SessionStart/Notification. Optional — omit to match all.
- **timeout**: Seconds before hook is killed (default varies by event)
- **async**: `true` for fire-and-forget hooks (e.g., test-runner.sh)

---

## Testing

### runtime-bridge.sh — Enforcement Config Wrappers (DEC-CONFIG-AUTHORITY-001)

Two wrappers let hook scripts read and write enforcement toggles without
parsing JSON directly. Both are sourced transitively through `context-lib.sh`.

#### `rt_config_get <key> [scope]`

Reads a value from `enforcement_config` via `cc-policy config get`. Returns
the string value on success, or the sentinel `__FAIL_CLOSED__` on any error
(CLI unavailable, table missing, timeout, empty key argument).

```bash
gate=$(rt_config_get "review_gate_regular_stop")
```

**Sentinel contract** — callers MUST distinguish three return states:

| Return value | Meaning | Caller action |
|---|---|---|
| `"true"` / `"false"` / any string | Key found, value returned | Use the value |
| `""` (empty) | Key exists, explicitly set to empty | Fall back to built-in default |
| `"__FAIL_CLOSED__"` | Lookup failed (runtime unavailable) | Default to the **more restrictive** posture (gate ON) |

The fail-closed sentinel prevents silent fail-open behaviour when the policy
engine is temporarily unavailable. Any caller that receives `__FAIL_CLOSED__`
MUST treat the gate as enabled.

#### `rt_config_set <key> <value> [scope]`

Writes a value to `enforcement_config` via `cc-policy config set`. The caller
must have `CLAUDE_AGENT_ROLE=guardian` in the environment; the Python WHO gate
raises `PermissionError` and returns non-zero for any other role.

```bash
CLAUDE_AGENT_ROLE=guardian rt_config_set "review_gate_regular_stop" "true"
rt_config_set "review_gate_provider" "gemini" "project=/my/project"
```

Returns non-zero on any error (permission denied, missing key/value, CLI
failure). Callers should check `$?` if the write is load-bearing.

---

```bash
# PreToolUse:Write hook
echo '{"tool_name":"Write","tool_input":{"file_path":"/test.ts"}}' | bash hooks/<name>.sh

# PreToolUse:Bash hook
echo '{"tool_name":"Bash","tool_input":{"command":"git status"}}' | bash hooks/pre-bash.sh

# Validate settings.json
python3 -m json.tool ../settings.json

# Query audit trail (now in SQLite event store)
cc-policy event query --type audit --limit 20

# Check test state (runtime authority)
cc-policy test-state get <workflow-id>
```
