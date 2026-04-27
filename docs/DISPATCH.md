# Dispatch

The canonical role flow is:

1. `planner`
2. `guardian` (provision)
3. `implementer`
4. `reviewer`
5. `guardian` (land)

## Rules

- The orchestrator does not write source code directly.
- Planner writes the Evaluation Contract and Scope Manifest.
- Guardian (provision) issues the implementer lease and provisions the worktree.
- Implementer builds in the worktree and hands off.
- Reviewer verifies against the Evaluation Contract and owns findings.
- Guardian (land) is the only role allowed to commit, merge, or push.
- Phase 8 Slice 11: the legacy `tester` role is retired — `reviewer` is the
  sole evaluator of technical readiness.

## Current Enforcement Surface

The following dispatch rules are mechanically enforced by the hook chain
registered in `settings.json`. These are hard blocks (deny with corrective
message), not advisory warnings.

### PreToolUse Write|Edit chain (fires on every Write or Edit call)

All write-path enforcement is handled by `hooks/pre-write.sh`, a thin adapter
that calls `cc-policy evaluate`. The policy engine runs 10 registered Python
policies in priority order (first deny wins):

| Priority | Policy | What it enforces |
|----------|--------|-----------------|
| 100 | `branch_guard` | Source files cannot be written on `main` or `master`. Non-source files, MASTER_PLAN.md, and `.claude/` are exempt. |
| 200 | `write_who` | Only the `implementer` role may write source files. |
| 250 | `enforcement_gap` | Deny writes to extensions with unresolved linter gaps (count > 1). |
| 300 | `plan_guard` | Only actors with `CAN_WRITE_GOVERNANCE` may write governance markdown or constitution-level files. `CLAUDE_PLAN_MIGRATION=1` overrides. |
| 400 | `plan_exists` | Source writes (20+ lines) require MASTER_PLAN.md. Staleness check. |
| 500 | `plan_immutability` | Permanent MASTER_PLAN.md sections cannot be rewritten (via planctl.py). |
| 600 | `decision_log` | Decision log entries are append-only (via planctl.py). |
| 650 | `test_gate_pretool` | Escalating gate: warn then block on failing tests. |
| 700 | `doc_gate` | Source files need headers; 50+ line files need @decision. |
| 750 | `mock_gate` | Escalating gate: warn then block on internal mocks. |

### PreToolUse Bash/Agent chain (fires on Bash and Agent/Task calls)

All bash-path enforcement is handled by `hooks/pre-bash.sh`, and Agent/Task
launch enforcement is handled by `hooks/pre-agent.sh`. Both are thin adapters
that call `cc-policy evaluate`. The policy engine currently reports 19
PreToolUse/Bash-path policies in priority order:

| Priority | Policy | What it enforces |
|----------|--------|-----------------|
| 100 | `bash_tmp_safety` | Deny /tmp writes (Sacred Practice #3). |
| 150 | `agent_contract_required` | Deny Agent worktree isolation and enforce canonical stage↔subagent contracts. |
| 200 | `bash_worktree_cwd` | Deny bare cd into .worktrees/. |
| 250 | `bash_worktree_nesting` | Prevent nested worktree creation. |
| 275 | `bash_write_who` | Capability-gated WHO enforcement for shell writes. |
| 300 | `bash_git_who` | Lease-based WHO enforcement for git ops. |
| 350 | `bash_worktree_creation` | Guardian-only worktree creation. |
| 400 | `bash_main_sacred` | Cannot commit on main/master. |
| 500 | `bash_force_push` | Deny unsafe force push (require --force-with-lease). |
| 600 | `bash_destructive_git` | Deny reset --hard, clean -f, branch -D. |
| 625 | `bash_stash_ban` | Deny stash-based cross-branch shortcuts. |
| 630 | `bash_cross_branch_restore_ban` | Deny cross-branch restore/checkout of forbidden scope paths. |
| 635 | `bash_shell_copy_ban` | Deny shell copy/move of forbidden scope paths from foreign refs/trees. |
| 700 | `bash_worktree_removal` | Safe worktree removal enforcement. |
| 800 | `bash_test_gate_merge` | Test-pass gate for git merge. |
| 850 | `bash_test_gate_commit` | Test-pass gate for git commit. |
| 900 | `bash_eval_readiness` | Requires evaluation_state=ready_for_guardian + SHA match. |
| 1000 | `bash_workflow_scope` | Workflow binding + scope compliance. |
| 1100 | `bash_approval_gate` | One-shot approval for high-risk git ops. |

### SubagentStart (fires on every agent spawn)

| Hook | What it enforces |
|------|-----------------|
| `hooks/subagent-start.sh` | Consumes the PreToolUse Agent carrier row, claims dispatch delivery, seats markers/leases, and injects runtime prompt-pack context. SubagentStart cannot emit a permission deny, but canonical seats without carrier-backed contracts receive `BLOCKED` context and are not seated. The remaining shell-built context path is sparse and non-authoritative for non-canonical helper agents only. |

### SessionStart (fires on session start, /clear, /compact, resume)

| Hook | What it enforces |
|------|-----------------|
| `hooks/session-init.sh` | Injects git state, plan status, research status, evaluation state (sole readiness authority — TKT-024/W-CONV-4), stale session files, todo HUD. Clears stale session artifacts. Does not deny — context injection only. Note: proof_state is no longer surfaced in the session HUD (W-CONV-4); `evaluation_state` is the only readiness signal shown. |

### UserPromptSubmit (fires on every user prompt)

| Hook | What it enforces |
|------|-----------------|
| `hooks/prompt-submit.sh` | Injects contextual HUD (git state, plan status, agent findings, compaction suggestions). Auto-claims referenced issues. Does not deny — context injection and state recording only. Note: prompt-driven proof verification ("verified" reply) was removed in TKT-024 — reviewer readiness now flows through `check-reviewer.sh` → `completion_records` / reviewer findings → `dispatch_engine.py` → `evaluation_state`. Phase 8 Slice 10 retired the legacy tester evaluator producer. |

## Auto-Dispatch (Live)

Automatic role sequencing is live. After each agent stop, `dispatch_engine.py`
determines the next role from completion records and emits `AUTO_DISPATCH: <role>`
on stdout when a clean transition is ready. `post-task.sh` passes this signal
through to the SubagentStop hook output. The orchestrator reads `AUTO_DISPATCH:`
directives and chains the next role immediately without asking the user.

The canonical planner → guardian(provision) → implementer → reviewer →
guardian(land) flow chains automatically when:

- The stopping agent emits valid structured trailers (e.g. `PLAN_VERDICT`,
  `IMPL_STATUS`, `REVIEW_VERDICT`).
- No `BLOCKED` or `ERROR` signal is present in hook output.
- The `AUTO_DISPATCH:` directive names a valid next role.

The orchestrator stops the chain only when hook output contains `BLOCKED`,
`ERROR`, or `PROCESS ERROR`, or when Guardian needs user approval for high-risk
ops (history rewrite, destructive recovery, ambiguous publish target, or
non-straightforward push) gated by `bash_approval_gate` policy.

The Codex stop-review gate (`stop-review-gate-hook.mjs`) is wired in
`settings.json` for regular `Stop` only. Repo settings are the sole wiring
authority; the vendored plugin no longer self-registers a separate `Stop` hook.
The deterministic SubagentStop Codex braid is `hooks/implementer-critic.sh`,
which persists `critic_reviews` before `post-task.sh` routes the workflow.
The broad stop-review gate is a **user-facing Stop audit lane only** and does
not affect workflow `auto_dispatch` or `next_role`
(DEC-PHASE5-STOP-REVIEW-SEPARATION-001).

### Properties that remain prompt-level (not mechanically blocked)

- **Orchestrator direct dispatch denial.** The orchestrator can still dispatch
  any agent type at any time. No hook prevents skipping the planner or reviewer.
  Role sequencing is driven by `AUTO_DISPATCH:` signal compliance, not a hard
  block on out-of-order dispatch.
- **Typed runtime dispatch queue.** `dispatch_queue` exists (INIT-002/TKT-009)
  but is non-authoritative (DEC-WS6-001). Routing uses completion records via
  `determine_next_role()`. The queue is retained for manual orchestration only.
- **Orchestrator source-write prevention at dispatch level.** The orchestrator
  cannot write source files (enforced by `write_who` policy), but this is
  role-based write denial, not dispatch-level prevention.
