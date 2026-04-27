# Architecture

## Live System

The hard fork runs on the patched `v2.0` kernel with a live SQLite-backed
typed runtime and a Python policy engine. The governance kernel has been
rebuilt through INIT-001, INIT-002, and INIT-PE; the hook chain, runtime,
policy engine, and statusline are all active.

### Policy Engine (INIT-PE)

All PreToolUse enforcement decisions flow through a single Python policy
engine. Shell hooks are thin transport adapters that normalize Claude event
JSON into a policy request and forward the decision.

**Core components:**

- `runtime/core/policy_engine.py` -- PolicyRegistry, PolicyContext,
  PolicyRequest, PolicyDecision. `evaluate()` runs policies in priority
  order with first-deny-wins semantics. `explain()` returns the full
  evaluation trace for debugging. `build_context()` resolves all SQLite
  state (lease, markers, workflow, scope, evaluation, test_state,
  completions) in one shot.
- `runtime/core/policy_utils.py` -- Python ports of shell classification
  helpers (is_source_file, is_governance_markdown, extract_git_target_dir,
  classify_git_op, etc.).
- `runtime/core/policies/` -- 29 registered policy modules (10 write-path
  + 19 Bash/Agent PreToolUse policies).

**29 registered policies:**

Write-path (event_types=["Write","Edit"]):

| Priority | Name | Purpose |
|----------|------|---------|
| 100 | branch_guard | Block source writes on main/master |
| 200 | write_who | Only implementer may write source |
| 250 | enforcement_gap | Deny persistent linter gaps (count > 1) |
| 300 | plan_guard | Only planner may write governance markdown |
| 400 | plan_exists | MASTER_PLAN.md must exist + staleness gate |
| 500 | plan_immutability | Permanent sections (via planctl.py subprocess) |
| 600 | decision_log | Append-only decision log (via planctl.py subprocess) |
| 650 | test_gate_pretool | Escalating strike: fail tests -> block writes |
| 700 | doc_gate | Header + @decision annotation enforcement |
| 750 | mock_gate | Escalating strike: internal mocks in test files |

Bash/Agent PreToolUse path (event_types=["Bash","PreToolUse"]):

| Priority | Name | Purpose |
|----------|------|---------|
| 100 | bash_tmp_safety | Deny /tmp writes (Sacred Practice #3) |
| 150 | agent_contract_required | Enforce canonical stage↔subagent Agent contracts |
| 200 | bash_worktree_cwd | Deny bare cd into .worktrees/ |
| 250 | bash_worktree_nesting | Prevent nested worktree creation |
| 275 | bash_write_who | Capability-gated WHO enforcement for shell writes |
| 300 | bash_git_who | Lease-based WHO enforcement for git ops |
| 350 | bash_worktree_creation | Guardian-only worktree creation |
| 400 | bash_main_sacred | Deny non-landing commits on main/master; allow `guardian:land` final commits to proceed to test/evaluation gates |
| 500 | bash_force_push | Deny unsafe force push |
| 600 | bash_destructive_git | Deny reset --hard, clean -f, branch -D |
| 625 | bash_stash_ban | Deny stash-based cross-branch shortcuts |
| 630 | bash_cross_branch_restore_ban | Deny cross-branch restore of forbidden scope paths |
| 635 | bash_shell_copy_ban | Deny shell copy/move of forbidden scope paths from foreign refs/trees |
| 700 | bash_worktree_removal | Safe worktree removal enforcement |
| 800 | bash_test_gate_merge | Test-pass gate for git merge |
| 850 | bash_test_gate_commit | Test-pass gate for git commit |
| 900 | bash_eval_readiness | evaluation_state readiness + SHA match |
| 1000 | bash_workflow_scope | Workflow binding + scope compliance |
| 1100 | bash_approval_gate | One-shot approval for rebase/reset/non-ff merge/admin recovery/direct plumbing |

**CLI entry points:**

- `cc-policy evaluate` -- reads JSON from stdin, builds PolicyContext, runs
  all matching policies, returns decision with hookSpecificOutput wrapper.
- `cc-policy policy list` -- returns registered policies as JSON.
- `cc-policy policy explain` -- returns full evaluation trace.
- `cc-policy context role` -- returns resolved actor role from PolicyContext.

### Enforcement Surface

**PreToolUse Write|Edit** -- `hooks/pre-write.sh` (thin adapter):

Reads hook JSON, resolves actor role, calls `cc-policy evaluate`. All 10
write-path policies run in priority order. Fail-closed: if the policy engine
is unavailable, emits deny. Target-repo aware for cross-repo operations.

Shell hooks `doc-gate.sh`, `test-gate.sh`, `mock-gate.sh` are no-ops --
their policies now run via the engine during `pre-write.sh`'s evaluate call.

**PreToolUse Bash** -- `hooks/pre-bash.sh` (thin adapter):

Same pattern. The runtime builds structured command intent from the raw command
for cross-repo context resolution. All 19 Bash/Agent PreToolUse policies are
registered in priority order; Bash-only policies no-op for Agent/Task and the
Agent contract policy no-ops for Bash.
Fail-closed with wrapped hookSpecificOutput on all paths.

**PreToolUse Agent|Task** -- `hooks/pre-agent.sh` (thin adapter):

Normalizes hook JSON, resolves the project policy DB path for carrier writes,
and calls `cc-policy evaluate`. Runtime policy owns worktree-isolation denial,
contract shape validation, and stage↔subagent matching. After policy allow,
`cc-policy evaluate` writes the `pending_agent_requests` carrier row and issues
the best-effort `dispatch_attempts` row.

**SubagentStart:**

- `hooks/subagent-start.sh` -- consumes the `pending_agent_requests` carrier,
  claims dispatch delivery, seats markers/leases, and injects runtime prompt
  packs for canonical seats. Canonical seats without a carrier-backed contract
  receive `BLOCKED` context and are not seated. The remaining shell context
  path is lightweight and non-authoritative for non-canonical helper agents
  only; canonical role guidance comes from runtime prompt packs and `agents/`.

**SubagentStop:**

- `hooks/check-{planner,implementer,reviewer,guardian}.sh` -- Agent-specific
  validation. Deactivate markers via `cc-policy lifecycle on-stop`. Role
  detection via local `runtime/cli.py context role`. Phase 8 Slice 10 retired
  `check-tester.sh`; Slice 11 removed the `tester` role from the runtime.
- `hooks/post-task.sh` -- Completion routing via `cc-policy dispatch
  process-stop`. Returns next-role suggestion in hookSpecificOutput.

### Dispatch Engine

- `runtime/core/dispatch_engine.py` -- `process_agent_stop()` is the
  single authority for agent completion routing. Resolves workflow from
  lease, routes via `completions.determine_next_role()`, releases lease
  after routing. No dispatch_queue writes (DEC-WS6-001).
- `runtime/core/lifecycle.py` -- `on_agent_start()` / `on_stop_by_role()`
  are the single authority for marker activation/deactivation.

### Typed Runtime

The typed runtime owns all shared workflow state:

- **CLI:** `cc-policy` with evaluate, policy, dispatch, lifecycle, context,
  marker, evaluation, lease, completion, workflow, test-state, approval,
  event, worktree, statusline, trace, tokens, todos, bug, sidecar, proof
  command groups.
- **Schema:** 29 domain SQLite tables plus SQLite's `sqlite_sequence` table in
  WAL mode. Key tables: evaluation_state,
  dispatch_leases, completion_records, test_state, workflow_bindings,
  workflow_scope, work_items, pending_agent_requests, dispatch_attempts,
  agent_markers, approvals, events, bugs.
- **Bridge:** `hooks/lib/runtime-bridge.sh` provides shell wrappers for
  legacy callers. New hooks use `_local_cc_policy()` or direct
  `python3 "$_LOCAL_CLI"` resolution for new subcommands.

### Statusline

Runtime-backed read model via `cc-policy statusline snapshot`. No flat-file
cache. All statusline data derives from runtime projections.

### Flat-File State (Remaining)

| File | Status | Notes |
|------|--------|-------|
| `.session-changes-*` | Active (session-scoped) | Written by track.sh, read by surface.sh |
| `.enforcement-gaps` | Active (operational) | Written by lint.sh, read by enforcement_gap policy |
| `.test-gate-strikes` | Active (session-scoped) | Written/read by test_gate_pretool policy |
| `.mock-gate-strikes` | Active (session-scoped) | Written/read by mock_gate policy |

### Deleted Shell Files (INIT-PE)

- `hooks/guard.sh` (486 LOC) -- 13 checks migrated into runtime policies
- `hooks/lib/write-policy.sh` (174 LOC) -- 7 checks migrated to write policies
- `hooks/lib/plan-policy.sh` (97 LOC) -- immutability/decision-log policies
- `hooks/lib/bash-policy.sh` (26 LOC) -- delegation to guard.sh
- `hooks/lib/dispatch-helpers.sh` (69 LOC) -- deprecated per DEC-WS6-001

### Sidecars (Shadow Mode)

Read-only sidecars in `sidecars/` observe traces, events, and plan metadata
but never sit on deny paths. They remain in shadow mode until the acceptance
suite is green for two consecutive passes.

## Achieved Architecture

1. Canonical prompts in `CLAUDE.md` and `agents/`
2. Thin hook adapters (`pre-write.sh`, `pre-bash.sh`, `pre-agent.sh`) calling `cc-policy evaluate`
3. Python policy engine with 29 registered policies (PolicyRegistry)
4. Typed runtime (`cc-policy` CLI + SQLite) for shared state
5. Dispatch engine and lifecycle authority in Python
6. Runtime-backed read models (statusline snapshot)
7. Read-only sidecars (shadow mode, not yet promoted)
