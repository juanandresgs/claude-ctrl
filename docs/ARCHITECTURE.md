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
  state (lease, markers, workflow, work item, landing grant, scope,
  evaluation, test_state, completions) in one shot.
- `runtime/core/hook_envelope.py` -- Canonical hook-event envelope builder.
  It owns session/tool identity normalization, Bash command intent
  construction, Write/Edit target path normalization, effective cwd, target
  cwd, and project-root resolution. Hooks and CLI handlers consume this
  envelope instead of deriving command targets from shell cwd.
- `runtime/core/landing_authority.py` -- Landing scope and phase classifier.
  It distinguishes implementer branch checkpoint commits, Guardian feature
  commits, governance-only base sidecars, reviewed-feature merges, and
  non-landing operations from the capability-bearing lease, work-item grant,
  and command target.
- `runtime/core/bash_lifecycle.py` -- Runtime owner for Bash pre/post
  lifecycle bookkeeping: source fingerprint baselines, PostToolUse source
  invalidation, Guardian commit head promotion, test-state projection from
  successful test commands, and landing phase events.
- `runtime/core/work_item_grants.py` -- Durable per-work-item landing grant
  authority. Policies consume this record for routine branch checkpoint and
  autoland decisions instead of requiring one-shot approvals for normal flow.
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
| 300 | bash_git_who | Lease-based WHO enforcement for git ops; scoped implementer branch commits require a work-item grant |
| 350 | bash_worktree_creation | Guardian-only worktree creation |
| 400 | bash_main_sacred | Deny non-landing commits on main/master; allow `guardian:land` final commits to proceed to test/evaluation gates |
| 500 | bash_force_push | Deny unsafe force push |
| 600 | bash_destructive_git | Deny reset --hard, clean -f, branch -D |
| 625 | bash_stash_ban | Deny stash-based cross-branch shortcuts |
| 630 | bash_cross_branch_restore_ban | Deny cross-branch restore of forbidden scope paths |
| 635 | bash_shell_copy_ban | Deny shell copy/move of forbidden scope paths from foreign refs/trees |
| 700 | bash_worktree_removal | Safe worktree removal enforcement |
| 800 | bash_test_gate_merge | Test-pass gate for git merge |
| 850 | bash_test_gate_commit | Test-pass gate for Guardian landing commits |
| 900 | bash_eval_readiness | Guardian landing readiness + SHA match |
| 1000 | bash_workflow_scope | Workflow binding + scope compliance |
| 1100 | bash_approval_gate | One-shot approval for high-risk ops; routine no-ff autoland comes from work-item grants |

**CLI entry points:**

- `cc-policy evaluate` -- reads JSON from stdin, builds PolicyContext, runs
  all matching policies, returns decision with hookSpecificOutput wrapper.
  The handler builds a `HookEventEnvelope` first; explicit target context is
  passed to DB/context resolution before policies run.
- `cc-policy policy list` -- returns registered policies as JSON.
- `cc-policy policy explain` -- returns full evaluation trace.
- `cc-policy context role` -- returns resolved actor role from PolicyContext.
- `cc-policy hook envelope` -- projects raw hook JSON into the canonical
  envelope for shell adapters and diagnostics.
- `cc-policy hook bash-pre-baseline` / `cc-policy hook bash-post` -- runtime
  entry points used by Bash hooks for non-enforcement lifecycle state.

### Enforcement Surface

**PreToolUse Write|Edit** -- `hooks/pre-write.sh` (thin adapter):

Reads hook JSON, seeds `CLAUDE_PROJECT_DIR` from the runtime hook envelope,
resolves actor role, and calls `cc-policy evaluate`. All 10 write-path
policies run in priority order. `cc-policy evaluate` rebuilds the same
envelope and passes its absolute Write/Edit `target_path` to policies, so
branch/path gates do not reinterpret relative file paths from hook subprocess
`PWD`. Fail-closed: if the policy engine is unavailable, emits deny.
Target-repo aware for cross-repo operations.

Shell hooks `doc-gate.sh`, `test-gate.sh`, `mock-gate.sh` are no-ops --
their policies now run via the engine during `pre-write.sh`'s evaluate call.

**PreToolUse Bash** -- `hooks/pre-bash.sh` (thin adapter):

Same pattern. The runtime builds structured command intent from the raw command
through `runtime.core.hook_envelope` / `runtime.core.command_intent` for
cross-repo context resolution. All 19 Bash/Agent PreToolUse policies are
registered in priority order; Bash-only policies no-op for Agent/Task and the
Agent contract policy no-ops for Bash.
Fail-closed with wrapped hookSpecificOutput on all paths.
For git commands, `runtime.core.command_intent` resolves target context from
parsed git invocation state before shell cwd: `cd` target, parsed `git -C`
argument even when it follows other git global options, unambiguous git
pathspec target, then cwd fallback.
Lease attachment stays runtime-owned in `policy_engine.build_context()`.
Normal actors attach only leases whose `worktree_path` matches the command
target. `guardian:land` has one landing-specific bridge: a claimed
feature-worktree lease for the same `agent_id` and `workflow_id` may also
authorize the shared/base git root for the final landing commit. That bridge
does not authorize other linked worktrees and does not create a second lease.
For that bridged base-worktree path, a commit containing only canonical
governance files (`MASTER_PLAN.md`, `CLAUDE.md`, `agents/*.md`, `docs/*.md`)
is treated as a planner-authored landing sidecar: it still requires
`evaluation_state=ready_for_guardian`, but it is not compared against the
feature branch `head_sha` and it is not treated as feature source scope.
The classification lives in `runtime.core.landing_authority`, not in the
shell hook or individual policy prose.
When hook subprocess `PWD` differs from event `cwd`, the adapter compares the
existing `CLAUDE_PROJECT_DIR` DB target with the command target's DB target.
It preserves the existing root only when both resolve to the same policy DB;
otherwise the command target wins before policy state is read. Actor markers
remain session-scoped: the hook first looks up the shared checkout root from
payload `cwd`, then falls back to the command target root when the session
marker is target-scoped.

**PreToolUse Agent|Task** -- `hooks/pre-agent.sh` (thin adapter):

Normalizes hook JSON, resolves the project policy DB path for carrier writes,
and calls `cc-policy evaluate`. Runtime policy owns worktree-isolation denial,
contract shape validation, and stage↔subagent matching. After policy allow,
`cc-policy evaluate` writes the `pending_agent_requests` carrier row and issues
the best-effort `dispatch_attempts` row.
When hook subprocess `PWD` and event `cwd` differ, the adapter binds
`CLAUDE_PROJECT_DIR` from the hook payload `cwd` before resolving `state.db`.

**SubagentStart:**

- `hooks/subagent-start.sh` -- consumes the `pending_agent_requests` carrier,
  claims dispatch delivery, seats markers/leases, and injects runtime prompt
  packs for canonical seats. Canonical seats without a carrier-backed contract
  receive `BLOCKED` context and are not seated. The remaining shell context
  path is lightweight and non-authoritative for non-canonical helper agents
  only; canonical role guidance comes from runtime prompt packs and `agents/`.
  Contract-bearing seats use the contract `workflow_id` for marker scoping;
  branch-derived workflow identity is only a legacy fallback. Lease seating
  expires stale active leases, then claims an existing active lease for the
  workflow binding's `worktree_path`; if none exists, `SubagentStart` issues
  the stage lease from the same contract and immediately claims it with
  payload `agent_id`.

**SubagentStop:**

- `hooks/check-{planner,implementer,reviewer,guardian}.sh` -- Agent-specific
  validation. Deactivate markers via `cc-policy lifecycle on-stop`. Role
  detection via local `runtime/cli.py context role`. Phase 8 Slice 10 retired
  `check-tester.sh`; Slice 11 removed the `tester` role from the runtime.
- `hooks/post-task.sh` -- Completion routing via `cc-policy dispatch
  process-stop`. Returns next-role suggestion in hookSpecificOutput.
- `hooks/post-bash.sh` -- PostToolUse Bash adapter. It reads hook JSON, binds
  `CLAUDE_PROJECT_DIR` to the command target, and calls
  `cc-policy hook bash-post`. `runtime.core/bash_lifecycle.py` resolves the
  same envelope as policy evaluation, compares the source fingerprint captured
  by `cc-policy hook bash-pre-baseline`, projects runtime `test_state` from
  successful test commands, promotes `evaluation_state.head_sha` after
  successful Guardian feature commits, emits `landing_phase_transition` /
  `eval_head_sync` events, and invalidates ready state for other source
  mutations. The shell hook no longer decides lease context, eval state, test
  state, or landing phase.

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
  event, worktree, statusline, trace, tokens, todos, bug, sidecar,
  critic-review, critic-run, session-activity, enforcement-gap, lint-state,
  and preserved-context command groups.
- **Schema:** Domain SQLite tables plus SQLite's `sqlite_sequence` table in
  WAL mode. Key tables: evaluation_state,
  dispatch_leases, completion_records, critic_reviews, critic_runs, test_state,
  session_activity, session_file_changes, enforcement_gaps, lint_profile_cache,
  lint_circuit_breakers, preserved_contexts, policy_strikes,
  bash_source_baselines, workflow_bindings,
  workflow_scope, work_items, work_item_grants, pending_agent_requests,
  dispatch_attempts, agent_markers, approvals, events, bugs.
- **Bridge:** `hooks/lib/runtime-bridge.sh` provides shell wrappers for
  legacy callers. New hooks use `_local_cc_policy()` or direct
  `python3 "$_LOCAL_CLI"` resolution for new subcommands.

### Statusline

Runtime-backed read model via `cc-policy statusline snapshot`. No flat-file
cache. All statusline data derives from runtime projections.

### Flat-File State Policy

Durable control-plane facts live in `state.db`. Project-local flatfiles are not
authoritative state. Locks, process output, scratch artifacts, and test fixtures
may exist as files; workflow memory does not.

| Former file | Current authority |
|-------------|-------------------|
| `.session-changes-*`, `.prompt-count-*`, `.session-start-epoch` | `session_activity`, `session_file_changes` |
| `.enforcement-gaps` | `enforcement_gaps` |
| `.lint-cache-*`, `.lint-breaker-*` | `lint_profile_cache`, `lint_circuit_breakers` |
| `.preserved-context` | `preserved_contexts` |
| `.test-gate-strikes`, `.mock-gate-strikes` | `policy_strikes` |
| `tmp/.bash-source-baseline-*` | `bash_source_baselines` |
| `.test-status` | `test_state` |

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
