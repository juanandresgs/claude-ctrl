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
- Guardian Admission is the non-canonical Guardian mode for the fork between
  durable project onboarding and task-local scratchlane custody. It uses the
  same `guardian` subagent identity as provision and land.
- Phase 8 Slice 11: the legacy `tester` role is retired — `reviewer` is the
  sole evaluator of technical readiness.

## Current Enforcement Surface

The following dispatch rules are mechanically enforced by the hook chain
registered in `settings.json`. These are hard blocks (deny with corrective
message), not advisory warnings.

## Runtime Dispatch Authority

Dispatch identity is owned by the runtime, not by shell glue or prompt text.
`dispatch_attempts` is the canonical attempt ledger. A PreToolUse Agent/Task
request first runs prompt-pack preflight against the same six-field contract
SubagentStart will consume. Only a preflight-valid canonical launch creates an
attempt, issues a dispatch lease, and writes the carrier keyed by `attempt_id`.
SubagentStart may only consume that carrier and claim the already-issued
attempt; it no longer creates fallback leases or invents identity when the
PreToolUse side failed.

The attempt record owns:

- parent session and agent identity
- requested role and prompt-pack id
- target project/worktree metadata
- tool-use and hook invocation ids
- child session/agent identity after SubagentStart claim
- runtime-issued lease id
- status: `pending`, `delivered`, `acknowledged`, `failed`, `timed_out`, or
  `cancelled`

If SubagentStart sees a mismatched role or prompt-pack compile failure for a
carrier-backed launch, it marks that exact attempt `failed`, emits diagnostic
context, and exits without seating markers or claiming leases. There is no
runtime quarantine gate; failed child attempts do not block parent Bash or Agent
calls. Canonical seats without a carrier receive `BLOCKED` context and are not
seated.

Scratchlane permission is also runtime-scoped. Guardian Admission may grant an
obvious task lane, but storage and enforcement remain in `scratchlane_permits`
and `scratchlane_requests`; there is no second scratchlane authority.
`scratchlane_permits` and
`scratchlane_requests` carry optional session, workflow, work-item, and attempt
scope. Runtime approval keeps that scope, and policy evaluation only activates
permits that match the current context. Unscoped manual permits remain possible
for explicit operator use, but prompt-requested scratchlane work is no longer a
global permission.

Guardian Admission returns one of seven custody verdicts:
`ready_for_implementer`, `guardian_provision_required`, `planner_required`,
`workflow_bootstrap_required`, `project_onboarding_required`,
`scratchlane_authorized`, or `user_decision_required`. The user is asked only
for `user_decision_required`; otherwise the verdict names the next authority.
Admission launches use `subagent_type=guardian` with `GUARDIAN_MODE: admission`
as the first prompt line. The PreToolUse Agent path writes a narrow admission
carrier, and SubagentStart consumes that carrier without seating canonical
Guardian markers or leases.
Scratchlane gates classify through `runtime.core.work_admission` only; they do
not hand-build scratchlane verdicts and do not apply permits as policy side
effects. Permit creation happens through Guardian Admission's
`cc-policy admission apply` path.

Auto-dispatch decisions are recorded in `dispatch_next_actions`. Hook output may
still emit `AUTO_DISPATCH:` for the Claude harness, but the structured next
action row is the runtime state that downstream tooling should inspect.

### PreToolUse Write|Edit chain (fires on every Write or Edit call)

All write-path enforcement is handled by `hooks/pre-write.sh`, a thin adapter
that calls `cc-policy evaluate`. The policy engine runs registered Python
policies in priority order (first deny wins):

| Priority | Policy | What it enforces |
|----------|--------|-----------------|
| 100 | `branch_guard` | Source files cannot be written on `main` or `master`. Non-source files, MASTER_PLAN.md, and `.claude/` are exempt. |
| 150 | `write_scratchlane_gate` | Obvious tmp/scratchlane writes are classified by Guardian Admission; tracked files under tmp remain denied. |
| 175 | `write_admission_gate` | Uncustodied source writes route to Guardian Admission before WHO fallback. |
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
that call `cc-policy evaluate`. The policy engine runs registered
PreToolUse/Bash-path policies in priority order:

| Priority | Policy | What it enforces |
|----------|--------|-----------------|
| 100 | `bash_tmp_safety` | Deny /tmp writes (Sacred Practice #3). |
| 150 | `agent_contract_required` | Deny Agent worktree isolation, enforce canonical stage↔subagent contracts, run prompt-pack preflight, create the runtime dispatch attempt, issue the dispatch lease, and write the attempt-keyed carrier. |
| 200 | `bash_worktree_cwd` | Deny bare cd into .worktrees/. |
| 250 | `bash_worktree_nesting` | Prevent nested worktree creation. |
| 260 | `bash_scratchlane_gate` | Shell tmp/interpreter scratchlane work classifies through Guardian Admission; active permits must use the runtime-owned scratchlane executor. |
| 270 | `bash_admission_gate` | Uncustodied Bash source writes route to Guardian Admission before WHO fallback. |
| 275 | `bash_write_who` | Capability-gated WHO enforcement for shell writes. |
| 300 | `bash_git_who` | Lease-based WHO enforcement for git ops. |
| 350 | `bash_worktree_creation` | Guardian-only worktree creation. |
| 400 | `bash_main_sacred` | Deny non-landing commits on main/master; `guardian:land` final commits pass through to test/evaluation gates. |
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
| 1100 | `bash_approval_gate` | One-shot approval for rebase/reset/non-ff merge/admin recovery/direct plumbing; routine Guardian landing needs reviewer/test/lease clearance, not an extra approval token. |

### SubagentStart (fires on every agent spawn)

| Hook | What it enforces |
|------|-----------------|
| `hooks/subagent-start.sh` | Consumes the attempt-keyed PreToolUse Agent carrier row, claims dispatch delivery against that exact attempt, compiles the runtime prompt pack before marker seating or lease claiming, seats runtime-issued leases only after compile success, and injects runtime prompt-pack context. SubagentStart cannot emit a permission deny, but canonical seats without carrier-backed contracts receive `BLOCKED` context and are not seated. Compile failures mark the carrier attempt `failed` and do not block the parent. Guardian admission consumes its own narrow carrier and injects admission-only guidance without seating canonical Guardian state. The remaining shell-built context path is sparse and non-authoritative for non-canonical helper agents only. |

### Guardian Admission Stop Handling

| Hook | What it enforces |
|------|-----------------|
| `hooks/check-guardian.sh` | Recognizes `ADMISSION_*` trailers from `guardian` admission mode, delegates trailer parsing to the admission audit path, and exits before Guardian completion-record handling. |
| `hooks/post-task.sh` | Skips canonical dispatch routing for Guardian admission stops so admission never creates dispatch markers, leases, or canonical completion records. |

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
determines the next role from completion records, persists a
`dispatch_next_actions` row, and emits `AUTO_DISPATCH: <role>` on stdout when a
clean transition is ready. `post-task.sh` passes this signal through to the
SubagentStop hook output. The orchestrator reads `AUTO_DISPATCH:` directives and
chains the next role immediately without asking the user.

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

Regular `Stop` is deterministic: `surface.sh`, `session-summary.sh`, and
`stop-advisor.sh`. The advisor only blocks obvious "do the routine thing" asks
so Claude acts, files the item, or dispatches the owning authority instead of
asking the user. The deterministic SubagentStop Codex braid is
`hooks/implementer-critic.sh`, which persists `critic_reviews` before
`post-task.sh` routes the workflow. Broad Codex/Gemini review is explicit or
critic-lane work; it is not a default regular-Stop blocker and does not affect
workflow `auto_dispatch` or `next_role`
(DEC-PHASE5-STOP-REVIEW-SEPARATION-001, DEC-STOP-ADVISOR-001).

### Remaining Harness Boundary

- **Harness spawn cannot be denied at SubagentStart.** Claude's SubagentStart
  hook can only inject context. The runtime fails invalid canonical launches
  before Agent spawn when possible; if SubagentStart still detects a compile
  failure, it reports context and marks only that child attempt failed.
- **Runtime next-action state is authoritative.** `AUTO_DISPATCH:` remains the
  harness transport signal; `dispatch_next_actions` is the inspectable runtime
  state for queued next-role decisions.
- **Orchestrator source-write prevention remains policy-level.** The
  orchestrator cannot write source files because write policies deny it. The
  dispatch ledger records identity and phase; write authority is still enforced
  by policy capabilities and leases.
