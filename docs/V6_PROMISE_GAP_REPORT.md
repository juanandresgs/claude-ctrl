# v6 Promise Gap Report

Status: draft audit
Date: 2026-05-18
Baseline: `full-refactor-v4` at `c7a3109`
Compared against: `origin/main` / v5 at `8b5781e`; IronCurtain at `3c89120`

## Executive finding

v4 won user experience because it was smaller and easier for Claude to stay inside: fewer moving parts, fewer contracts to restate, fewer hidden lanes, and less prompt/runtime ceremony. v5 has the right enterprise primitives — SQLite runtime, policy engine, hook adapters, stage registry, worktree authority, critic/reviewer separation — but the implementation let those primitives become parallel authorities instead of one simple control plane.

The v6 target should not be “v5 plus fixes.” It should be a v4-sized operating loop backed by v5-grade runtime primitives: one stage machine, one launch-ticket mechanism, one result contract, one critic lane, one git custody path, and one policy engine.

## Evidence reviewed

- v4/pre-ClauDEX baseline: `c7a31092588f7dbeb0d6f51038817bcc17e87f01`
- v5 latest upstream: `8b5781e` (`Merge feature/fix-critic-fail-closed into main`)
- v5 README/CLAUDE/docs promise surfaces
- v4/v5 hooks, runtime, policies, dispatch, completion, critic, prompt-pack, agent prompts
- IronCurtain workflow/security-runtime docs and implementation patterns
- Targeted v5 validation:
  - `python3 runtime/cli.py hook validate-settings` passed
  - `python3 runtime/cli.py hook doc-check` passed
  - 346 targeted dispatch/critic tests passed
  - 641 prompt-pack/subagent dispatch tests passed
  - 193 policy/landing tests passed
  - `tests/scenarios/test-implementer-critic-hook.sh` failed on the “active control-plane DB” scenario

## Size and complexity delta

| Surface | v4 baseline | v5 latest | Delta |
|---|---:|---:|---:|
| tracked files | 481 | 678 | +197 |
| core/hooks/sidecar LOC | ~19,837 | ~58,538 | ~3x |
| policy count | 22 | 33 | +11 |
| dispatch roles | planner/guardian/implementer/tester | planner/guardian/implementer/reviewer + admission/critic side paths | more expressive, less legible |

This is the core UX regression: v5 added enterprise controls but exposed too much of their ceremony to the agent loop.

## Promise-to-implementation distance

| README / docs promise | Current implementation reality | Distance | v6 requirement |
|---|---|---|---|
| “Instructions guide. Hooks enforce. Runtime decides.” | PreToolUse enforcement is runtime-owned, but dispatch still depends on hook text (`AUTO_DISPATCH:`) and orchestrator compliance. | Partial. Runtime records next actions but does not own consumption. | Runtime stage machine issues launch tickets; Agent launches are denied unless they consume a pending ticket. |
| “Operational truth lives in SQLite; no outdated flatfiles.” | v5 moved most state to SQLite. Some files are legitimate artifacts, but prompt/contract delivery still uses text carriers and hook output as control transport. | Mostly true for storage, false for dispatch authority. | SQLite owns state, hook text is a view only. |
| “Code reviews enforced to convergence using Codex/Gemini CLI critic with execution proof.” | Critic exists, but the latest scenario test failed in the context/DB split path. The loop is also bounded by retry limits and can escalate to reviewer, not literal convergence. | Overclaimed. | Promise bounded critic convergence: `try_again` loops to limit, then reviewer/planner/user boundary; external critic required only when configured and proven. |
| “Dispatch driven by structured completion records and stage registry.” | `stage_registry.py` exists and completions delegate to it. But `dispatch process-stop` takes only `agent_type` + `project_root`; guardian mode/stage is reconstructed indirectly. | Strong primitive, weak identity binding. | Every stage run has `stage_id`, `attempt_id`, `workflow_id`, `work_item_id`; stop processing is keyed by stage run, not role/path inference. |
| “Auto-dispatch is live.” | `dispatch_next_actions` rows are inserted, but no CLI consumer exists beyond tests/docs. `AUTO_DISPATCH:` text remains the real transport. | Not authoritative. | Add `dispatch next/claim/issue-ticket` CLI and make PreToolUse Agent enforce it. |
| “Canonical subagent seats backed by carrier rows, leases, and prompt packs.” | Pre-agent contract policy and SubagentStart carrier path exist. SubagentStart cannot deny harness spawn; it only injects BLOCKED context. | Good boundary awareness, too much ceremony. | PreToolUse Agent denies invalid launches before spawn; SubagentStart only seats already-issued ticket attempts. Prompt prefix becomes a short ticket, not a large JSON contract. |
| “Guardian provisions controlled worktrees; Agent worktree isolation denied.” | PreToolUse Agent denies `isolation:"worktree"`; Guardian provision and retire CLIs exist. | Mostly true. | Keep and simplify. Worktree ownership is one runtime table + one CLI. |
| “Routine landing is automatic after reviewer/test/scope/lease gates.” | Landing gates exist. Implementer checkpoint commits are allowed by default via work-item grants, which conflicts with user expectation that implementers avoid git. | Policy mismatch. | Default: implementers never commit. Optional checkpoint grants require explicit planner/operator narrowing. Guardian owns all git mutations by default. |
| “Reviewer is readiness authority.” | Reviewer completion schema and convergence path exist; tester retired. | Good primitive. | Keep. Reviewer writes findings/readiness via one result contract. |
| “Fewer unsafe shortcuts, fewer unnecessary user bounces.” | v5 added Guardian Admission, scratchlane, prompt packs, bootstraps, critic sidecars, and hidden hook reviews; users see more delay and more ambiguous failures. | UX regression. | v6 default path is one loop with short tickets and bounded context. Optional enterprise lanes are plugins, not core path. |

## Specific broken or fragile points

1. **Critic routing is still fragile.** Latest v5 scenario failure:
   - Hook emitted `CRITIC_UNAVAILABLE` with workflow `__unresolved__`.
   - Dispatch for `wf-global-db-split` returned `PROCESS ERROR: implementer critic did not run.`
   - This is exactly the class of failure the May 12 repair initiative claims to close.

2. **`dispatch_next_actions` is not consumed.** It is inserted in `dispatch_engine.py` and asserted in tests, but there is no public `cc-policy dispatch next/claim` CLI and no hook/orchestrator path that treats it as the source of truth.

3. **Stage identity is inferred too late.** Runtime routing receives role/path, not a stage-run id. Compound stages (`guardian:provision`, `guardian:land`) are modeled in `stage_registry`, but live stop processing reconstructs mode from completions and suggestion text.

4. **The prompt contract is too heavy.** `CLAUDEX_CONTRACT_BLOCK:{...}` on line 1 plus prompt-pack machinery gives correctness hooks something to validate, but it increases token load and creates another shape agents must preserve. A short launch ticket can provide the same authority.

5. **The critic runs in the wrong layer.** A 900s SubagentStop hook hides an external reviewer behind an agent stop event. That makes progress hard to see, context resolution brittle, and dispatch semantics indirect.

6. **Implementer git authority drifted.** v5 default grants allow branch checkpoint commits. That may be useful for long-running enterprise workflows, but it contradicts the simpler, safer doctrine users expect: implementers write code; Guardian does git.

7. **Public README overpromises.** v5 README claims convergence and autonomy that are not yet represented by a closed, consumed runtime state machine. v6 docs must be mechanically test-backed.

## What to keep from v5

- Python policy engine and policy registry
- `hook_envelope` / command intent normalization ideas
- Capability registry approach
- Stage registry concept
- Reviewer findings/readiness model
- Worktree provision/retire as runtime-owned git side effects
- Hook manifest/settings validation
- Execution-proof concept for external critics
- Runtime-backed statusline/read models

## What to restore from v4

- Small, legible hot path
- Fewer role-specific detours
- Minimal prompt overhead
- Deterministic hooks that are easy to inspect
- No hidden multi-minute sidecar unless explicitly part of the stage machine
- Git discipline: Guardian owns git by default

## IronCurtain design lessons applicable to v6

1. **Use an explicit state machine.** IronCurtain workflows are XState-driven; transitions are deterministic, guards are named, and agent output is parsed into a strict status block. v6 should make dispatch a real runtime state machine instead of hook text + orchestrator habit.

2. **Separate directive from status.** IronCurtain fixed directive loss by forwarding the full previous body minus status block, while keeping a strict status schema. v6 should similarly separate rich human-readable evidence from the small machine result contract.

3. **Default deny and most-restrictive-wins.** IronCurtain’s policy engine denies unknown tools and lets structural invariants run before compiled rules. v6 policies should preserve first-deny-wins, but classify hard security gates separately from quality/advisory gates.

4. **Audit every outcome.** Even unknown-tool and invalid-argument denials are audited. v6 should log every allow/deny/dispatch/critic/landing result as an event tied to a stage run.

5. **Trusted user intent is a separate signal.** Approval/auto-approval should derive from explicit user intent and never be treated as technical proof. v6 Guardian approvals should remain separate from reviewer readiness.

## v6 thesis

v6 should be the final form of `claude-ctrl`: a deterministic Claude Code control plane whose public promises are exactly the tests it ships.

The core loop becomes:

```text
planner -> guardian:provision -> implementer -> critic -> reviewer -> guardian:land -> planner|terminal
                  ^                    |          |          |
                  |                    v          v          v
                  +------ bounded retry/plan/user boundary <-+
```

But the implementation surface should feel like v4:

- one short launch ticket
- one result JSON block
- one runtime stage machine
- one policy engine
- one Guardian git path
- one bounded critic lane
