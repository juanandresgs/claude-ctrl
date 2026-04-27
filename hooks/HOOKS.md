# ClauDEX Hook Adapter Manifest

This document is a derived projection of `runtime.core.hook_manifest.HOOK_MANIFEST` (CUTOVER_PLAN §Authority Map: `hook_wiring`).
Do not hand-edit — regenerate from the runtime manifest via the projection builder in `runtime.core.hook_doc_projection`.

Generator version: `1.0.0`

## SessionStart

- matcher `startup|resume|clear|compact` → `hooks/session-init.sh`
  - _Session bootstrap + context injection (CUTOVER_PLAN H3)._

## UserPromptSubmit

- matcher `(unconditional)` → `hooks/prompt-submit.sh`
  - _Prompt preprocessing and context injection (CUTOVER_PLAN H3)._

## WorktreeCreate

- matcher `(unconditional)` → `hooks/block-worktree-create.sh`
  - _Fail-closed worktree safety adapter (DEC-GUARD-WT-009, DEC-PHASE0-001). Denies harness-managed worktree creation so Guardian remains the sole worktree authority._

## PreToolUse

- matcher `Write|Edit` → `hooks/test-gate.sh`
  - _Pre-write test gate (part of the PostToolUse write pipeline — CUTOVER_PLAN P7)._
- matcher `Write|Edit` → `hooks/mock-gate.sh`
  - _Pre-write mock detector (CUTOVER_PLAN P7)._
- matcher `Write|Edit` → `hooks/pre-write.sh`
  - _Thin pre-write adapter — source WHO + workflow scope enforcement (CUTOVER_PLAN H1)._
- matcher `Write|Edit` → `hooks/doc-gate.sh`
  - _Docs-vs-code consistency gate (CUTOVER_PLAN P7)._
- matcher `Bash` → `hooks/pre-bash.sh`
  - _Thin pre-bash adapter — command-intent + git WHO enforcement (CUTOVER_PLAN H1)._
- matcher `Task` → `hooks/pre-agent.sh`
  - _Pre-agent guard for subagent isolation bypass (CUTOVER_PLAN H2)._
- matcher `Agent` → `hooks/pre-agent.sh`
  - _Pre-agent guard (Agent tool alias of Task) — CUTOVER_PLAN H2._

## PostToolUse

- matcher `Write|Edit` → `hooks/lint.sh`
  - _Post-write lint pipeline (CUTOVER_PLAN H4)._
- matcher `Write|Edit` → `hooks/track.sh`
  - _Post-write source-change tracking + readiness invalidation (CUTOVER_PLAN H4)._
- matcher `Write|Edit` → `hooks/code-review.sh`
  - _Advisory post-write code review (CUTOVER_PLAN H4, Partial)._
- matcher `Write|Edit` → `hooks/plan-validate.sh`
  - _Plan-scope validation on source writes (CUTOVER_PLAN H4)._
- matcher `Write|Edit` → `hooks/test-runner.sh`
  - _Post-write test runner (CUTOVER_PLAN H4 / P7)._
- matcher `Bash` → `hooks/post-bash.sh`
  - _Post-bash source-mutation readiness invalidation (Invariant #15, DEC-EVAL-006)._

## Notification

- matcher `permission_prompt|idle_prompt` → `hooks/notify.sh`
  - _User-facing notifications for permission and idle prompts (CUTOVER_PLAN O5 Later, currently active)._

## SubagentStart

- matcher `(unconditional)` → `hooks/subagent-start.sh`
  - _Subagent lifecycle marker + context injection (CUTOVER_PLAN H2 / H3)._

## SubagentStop

- matcher `planner|Plan` → `hooks/check-planner.sh`
  - _Planner completion assessment (CUTOVER_PLAN W1)._
- matcher `planner|Plan` → `hooks/post-task.sh`
  - _Thin post-task adapter — routes to dispatch_engine.process_agent_stop (DEC-DISPATCH-ENGINE-001)._
- matcher `implementer` → `hooks/check-implementer.sh`
  - _Implementer completion assessment (CUTOVER_PLAN W2)._
- matcher `implementer` → `hooks/implementer-critic.sh`
  - _Dedicated Codex tactical critic for implementer inner-loop routing._
- matcher `implementer` → `hooks/post-task.sh`
  - _Thin post-task adapter for implementer stops._
- matcher `guardian` → `hooks/check-guardian.sh`
  - _Guardian completion assessment (CUTOVER_PLAN W5 / W6)._
- matcher `guardian` → `hooks/post-task.sh`
  - _Thin post-task adapter for guardian stops._
- matcher `reviewer` → `hooks/check-reviewer.sh`
  - _Phase 4 reviewer completion assessment — parses REVIEW_* trailers and submits structured completion record (DEC-CHECK-REVIEWER-001)._
- matcher `reviewer` → `hooks/post-task.sh`
  - _Thin post-task adapter for reviewer stops._

## PreCompact

- matcher `(unconditional)` → `hooks/compact-preserve.sh`
  - _Context preservation before auto-compact._

## Stop

- matcher `(unconditional)` → `hooks/surface.sh`
  - _Surface diagnostics at turn end (CUTOVER_PLAN O2 read-only)._
- matcher `(unconditional)` → `hooks/session-summary.sh`
  - _Stop-time summarization (CUTOVER_PLAN H5 Partial)._
- matcher `(unconditional)` → `hooks/forward-motion.sh`
  - _Advisory Stop-time forward-motion hint; never blocks turn completion._

## SessionEnd

- matcher `(unconditional)` → `hooks/session-end.sh`
  - _Session teardown diagnostics._
