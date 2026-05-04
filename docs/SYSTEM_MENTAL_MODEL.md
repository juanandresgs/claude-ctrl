# Claude Ctrl HardFork: Current System Mental Model

This note describes the installed `main` behavior as of the current convergence work. It is meant to be an operator-level explanation of how the system now works, which facts are authoritative, and what you should expect from it.

## What Changed

The system is now a runtime-backed control plane instead of a collection of social conventions, flat files, and branch-name heuristics.

The convergence work did four important things:

1. Moved operational authority into the runtime SQLite database.
2. Removed or bypassed the fallback paths that could silently override the new mechanism.
3. Made role handoff and landing readiness deterministic.
4. Made visible status read from the same runtime facts that enforcement uses.

In practical terms, the system now behaves much more like a hook-driven state machine.

## Single Authorities

These are the authoritative facts now:

- Workflow identity: `lease_context().workflow_id`
  - Code anchor: `hooks/context-lib.sh`
- Lease permissioning and allowed git ops: runtime lease validation
  - Code anchor: `runtime/core/leases.py`
- Routing / next role: `determine_next_role()` over structured completion records
  - Code anchor: `runtime/core/completions.py`
- Test readiness: `test_state`
  - Code anchor: `runtime/core/test_state.py`
- Session prompt counts and changed-file memory: `session_activity`, `session_file_changes`
  - Code anchor: `runtime/core/session_activity.py`
- Linter coverage gaps and linter hook memory: `enforcement_gaps`, `lint_profile_cache`, `lint_circuit_breakers`
  - Code anchor: `runtime/core/enforcement_gaps.py`, `runtime/core/lint_state.py`
- Escalating write-policy strike counters: `policy_strikes`
  - Code anchor: `runtime/core/policy_strikes.py`
- Compaction handoff context: `preserved_contexts`
  - Code anchor: `runtime/core/preserved_context.py`
- Bash source-mutation baselines: `bash_source_baselines`
  - Code anchor: `runtime/core/bash_lifecycle.py`
- Evaluator / landing readiness: `evaluation_state`
  - Code anchor: `runtime/core/evaluation.py`
- Workflow binding and scope: runtime workflow tables
  - Code anchor: `runtime/core/workflows.py`
- Findings and handoff breadcrumbs: runtime events
  - Code anchor: runtime event helpers used from hooks
- Visible operational status: runtime-backed statusline snapshot
  - Code anchor: `runtime/core/statusline.py`

These are no longer authoritative:

- Branch-derived workflow identity in leased paths
- `.session-changes-*`, `.prompt-count-*`, `.session-start-epoch`
- `.enforcement-gaps`, `.lint-cache-*`, `.lint-breaker-*`
- `.test-gate-strikes`, `.mock-gate-strikes`
- `tmp/.bash-source-baseline-*`
- `.preserved-context`
- `.test-status`
- `.agent-findings`
- Pre-merge evaluator consumption
- `dispatch_queue` as the source of truth for next-role routing

`dispatch_queue` may still exist in the schema and compatibility helpers, but it is no longer what decides the next role.

## Code-Level Subsystems

```text
                                 settings.json
                                      |
         ----------------------------------------------------------------
         |                    |                  |                       |
     SessionStart        SubagentStart       PreToolUse             SubagentStop
         |                    |             / Write/Edit \               |
         |                    |            /              \              |
  session-init.sh      subagent-start.sh  pre-bash.sh    pre-write.sh   |
         |                    |                |              |          |
         |                    |                |              |          |
         |                    |                |     cc-policy evaluate (10 write-path policies)
         |                    |                |       branch_guard, write_who, plan_guard,
         |                    |                |       plan_exists, plan_immutability,
         |                    |                |       decision_log, test_gate_pretool,
         |                    |                |       doc_gate, mock_gate, enforcement_gap
         |                    |                |
         |                    |                +--> cc-policy evaluate (12 bash-path policies)
         |                    |                       bash_tmp_safety, bash_worktree_cwd,
         |                    |                       bash_git_who, bash_main_sacred,
         |                    |                       bash_force_push, bash_destructive_git,
         |                    |                       bash_worktree_removal, bash_test_gate_merge,
         |                    |                       bash_test_gate_commit, bash_eval_readiness,
         |                    |                       bash_workflow_scope, bash_approval_gate
         |                    |
         |                    +--> lease claim
         |                    +--> active marker set
         |                    +--> workflow bind for leased work
         |                    +--> inject runtime state into agent context
         |
         |                                             PostToolUse
         |                                        / Write/Edit/Bash \
         |                                       /                  \
         |                                  track.sh  test-runner.sh
         |                                      |           |
         |                                      |           |
         |                                      |           +--> writes runtime test_state
         |                                      |
         |                                      +--> invalidates evaluation_state after source changes
         |
         +---------------------------------------------------------------+
                                                                 |
                                                      check-implementer.sh
                                                      check-reviewer.sh
                                                      check-guardian.sh
                                                      post-task.sh
                                                                 |
                                                                 +--> completion_records
                                                                 +--> reviewer convergence -> evaluation_state
                                                                 +--> determine_next_role()
                                                                 +--> next-role suggestion

All hook runtime access goes through:

hooks/context-lib.sh
    -> hooks/lib/runtime-bridge.sh
        -> runtime/cli.py (cc-policy)
            -> runtime/core/*
                -> SQLite runtime DB

Main runtime domains:

- leases.py
- completions.py
- evaluation.py
- test_state.py
- workflows.py
- markers.py
- statusline.py
- approvals.py
- dispatch.py (retained, no longer hot-path routing authority)

Main runtime tables:

- dispatch_leases
- completion_records
- evaluation_state
- test_state
- workflow_bindings
- workflow_scope
- agent_markers
- events
- dispatch_cycles
- dispatch_queue (retained, not authoritative for next-role routing)
```

## Workflow-Level Diagram

```text
User / Orchestrator
    |
    | issue lease + workflow_id + scope + allowed ops
    v
Planner
    |
    | governance / plan authority
    | can write planning/governance surfaces
    v
post-task
    |
    +--> next role: implementer

Implementer
    |
    | can write source
    | cannot land
    | source writes are tracked
    v
post-task
    |
    +--> evaluation_state = pending
    +--> next role: reviewer

Reviewer
    |
    | cannot write source
    | runs tests + live verification
    | must emit machine-parsed trailers:
    |   REVIEW_VERDICT
    |   REVIEW_HEAD_SHA
    |   REVIEW_FINDINGS_JSON
    v
check-reviewer.sh (SubagentStop reviewer adapter)
    |
    +--> validates trailers fail-closed
    +--> writes completion_record and reviewer findings
    +--> dispatch_engine projects convergence into evaluation_state
    v
post-task
    |
    +--> determine_next_role(role, verdict)
          |
          +--> needs_changes      -> implementer
          +--> blocked_by_plan    -> planner
          +--> ready_for_guardian -> guardian

Guardian
    |
    | only role allowed to commit / merge / push
    | pre-bash.sh -> cc-policy evaluate enforces:
    |   - valid active lease (bash_git_who)
    |   - passing test_state (bash_test_gate_commit, bash_test_gate_merge)
    |   - evaluation_state == ready_for_guardian + SHA match (bash_eval_readiness)
    |   - workflow binding and scope (bash_workflow_scope)
    |   - approval token for high-risk ops (bash_approval_gate)
    |   - no force push without --force-with-lease (bash_force_push)
    v
landing succeeds
    |
    | guardian emits LANDING_RESULT / OPERATION_CLASS
    v
check-guardian.sh
    |
    +--> writes guardian completion record
    +--> consumes evaluation_state only after confirmed landing
    v
cycle complete
```

## How the System Behaves Now

### 1. Leases are the operational identity

If a leased path is in play, the workflow identity comes from the lease, not from the branch name, worktree path, or current directory.

This matters because multi-worktree and detached-head flows no longer depend on name guessing.

### 2. Reviewer output now materially governs landing

Reviewer output is not just advisory anymore. The SubagentStop reviewer adapter (`check-reviewer.sh` in the current live chain; Phase 8 Slice 10 retired the legacy tester evaluator adapter, and Slice 11 removed the `tester` role from the runtime entirely) parses structured trailers into completion records. `dispatch_engine.py` projects valid reviewer convergence into `evaluation_state`.

Guardian cannot land unless:

- the test state is passing
- the evaluator verdict is `ready_for_guardian`
- the evaluated `head_sha` matches the current HEAD

If any of that is missing or stale, landing is denied.

### 3. Source changes after clearance reopen readiness

`track.sh` invalidates `evaluation_state` when source files change after evaluator clearance. That means a previously approved state cannot silently carry forward to a different tree.

### 4. Role boundaries are real

The write and git hooks now enforce role boundaries at action time:

- Planner: governance / planning surfaces
- Implementer: source changes
- Reviewer: verification, no source authority
- Guardian: permanent repo mutations only

### 5. Visibility reads runtime truth

The statusline now reflects runtime-backed truth rather than queue artifacts or flat files. The visible "what comes next" picture comes from the same completion logic that the system uses internally.

## What You Can Expect In Practice

You should expect the following behavior:

- Wrong-role writes are denied immediately.
- Unleased git operations in enforced paths are denied immediately.
- Guardian cannot commit, merge, or push without the right lease and scope.
- Guardian cannot land with failing or stale test state.
- Guardian cannot land if the Reviewer cleared a different SHA than the one currently checked out.
- If code changes after the Reviewer clears it, readiness goes back to pending.
- Reviewer verdicts route work back to Implementer, Planner, or forward to Guardian in a deterministic way.
- Missing or malformed reviewer trailers fail closed.
- The system should produce fewer confusing "it fell back to something else" cases.

## Operator Cheat Sheet

### Planner

- Owns planning and governance surfaces
- Does not own source implementation
- Usually hands off to Implementer

### Implementer

- Owns source changes
- Does not own landing
- Completion reopens evaluation and hands off to Reviewer

### Reviewer

- Owns the verification verdict
- Must emit valid `REVIEW_*` trailers
- Can send the workflow back to Implementer, back to Planner, or forward to Guardian

### Guardian

- Owns commit / merge / push
- Must satisfy lease, scope, tests, evaluator readiness, and approval policy

## Practical Truths

If you want to know what the system believes, trust the runtime-backed surfaces:

- lease / workflow identity -> lease context
- next role -> completion routing
- landing readiness -> evaluation state
- test readiness -> test state
- current operational picture -> statusline snapshot

Do not trust:

- leftover flat-file intuitions
- branch-name guesses
- old queue-based expectations

## Bottom Line

The main accomplishment of the convergence streams is that the control logic is now centralized and mechanically enforced.

Before, the system could look disciplined while silently falling back to legacy paths.

Now, if required state is missing, stale, cross-role, or ambiguous, it generally fails closed instead of improvising.
