# Dispatch

The canonical role flow is:

1. `planner`
2. `implementer`
3. `tester`
4. `guardian`

## Rules

- The orchestrator does not write source code directly.
- Implementer builds and hands off.
- Tester verifies and owns evidence.
- Guardian is the only role allowed to commit, merge, or push.

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
| 300 | `plan_guard` | Only the `planner` role may write governance markdown. `CLAUDE_PLAN_MIGRATION=1` overrides. |
| 400 | `plan_exists` | Source writes (20+ lines) require MASTER_PLAN.md. Staleness check. |
| 500 | `plan_immutability` | Permanent MASTER_PLAN.md sections cannot be rewritten (via planctl.py). |
| 600 | `decision_log` | Decision log entries are append-only (via planctl.py). |
| 650 | `test_gate_pretool` | Escalating gate: warn then block on failing tests. |
| 700 | `doc_gate` | Source files need headers; 50+ line files need @decision. |
| 750 | `mock_gate` | Escalating gate: warn then block on internal mocks. |

### PreToolUse Bash chain (fires on every Bash call)

All bash-path enforcement is handled by `hooks/pre-bash.sh`, a thin adapter
that calls `cc-policy evaluate`. The policy engine runs 12 registered Python
policies in priority order:

| Priority | Policy | What it enforces |
|----------|--------|-----------------|
| 100 | `bash_tmp_safety` | Deny /tmp writes (Sacred Practice #3). |
| 200 | `bash_worktree_cwd` | Deny bare cd into .worktrees/. |
| 300 | `bash_git_who` | Lease-based WHO enforcement for git ops. |
| 400 | `bash_main_sacred` | Cannot commit on main/master. |
| 500 | `bash_force_push` | Deny unsafe force push (require --force-with-lease). |
| 600 | `bash_destructive_git` | Deny reset --hard, clean -f, branch -D. |
| 700 | `bash_worktree_removal` | Safe worktree removal enforcement. |
| 800 | `bash_test_gate_merge` | Test-pass gate for git merge. |
| 850 | `bash_test_gate_commit` | Test-pass gate for git commit. |
| 900 | `bash_eval_readiness` | Requires evaluation_state=ready_for_guardian + SHA match. |
| 1000 | `bash_workflow_scope` | Workflow binding + scope compliance. |
| 1100 | `bash_approval_gate` | One-shot approval for high-risk git ops. |

### SubagentStart (fires on every agent spawn)

| Hook | What it enforces |
|------|-----------------|
| `hooks/subagent-start.sh` | Registers agent via `cc-policy dispatch agent-start`. Injects role-specific context. Does not deny — context injection only. |

### SessionStart (fires on session start, /clear, /compact, resume)

| Hook | What it enforces |
|------|-----------------|
| `hooks/session-init.sh` | Injects git state, plan status, research status, proof state, stale session files, todo HUD. Clears stale session artifacts. Does not deny — context injection only. |

### UserPromptSubmit (fires on every user prompt)

| Hook | What it enforces |
|------|-----------------|
| `hooks/prompt-submit.sh` | Records proof verification when user replies "verified". Injects contextual HUD (git state, plan status, agent findings, compaction suggestions). Auto-claims referenced issues. Does not deny — context injection and state recording only. |

## Not Yet Enforced

The following dispatch properties exist as prompt guidance in CLAUDE.md and
`agents/*.md` but are **not mechanically enforced by any hook or gate**:

- **Automatic role sequencing.** The planner-to-implementer-to-tester-to-guardian
  flow is a convention the orchestrator follows from prompt instructions. No hook
  blocks dispatching out of order.
- **Orchestrator direct dispatch denial.** The orchestrator can still dispatch
  any agent type at any time. No hook prevents skipping the planner or tester.
- **Typed runtime dispatch queue.** `dispatch_queue` exists (INIT-002/TKT-009)
  but is non-authoritative (DEC-WS6-001). Routing uses completion records via
  `determine_next_role()`. The queue is retained for manual orchestration only.
- **Plan section immutability.** Now enforced by `plan_immutability` and
  `decision_log` policies via planctl.py subprocess (INIT-PE/PE-W2).
- **Orchestrator source-write prevention at dispatch level.** The orchestrator
  cannot write source files (enforced by `write_who` policy), but this is
  role-based write denial, not dispatch-level prevention.
