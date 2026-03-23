# Agent Handoffs

This document contains the concrete handoff packets for Claude Code agents to
execute the first successor wave defined in [MASTER_PLAN.md](../MASTER_PLAN.md).

Use these packets as the orchestrator dispatch context. They are written to fit
the canonical role flow:

1. `planner`
2. `implementer`
3. `tester`
4. `guardian`

## Current Truth

- The hard fork is running on the imported patched `v2.0` kernel.
- The highest-priority gap is missing `Write|Edit` WHO enforcement.
- The installed Claude runtime must be treated as the source of truth for hook
  payloads and agent lifecycle behavior.
- The richer future statusline HUD is in scope, but it must be rebuilt on top of
  the successor runtime state machine rather than old cache/contracts coupling.
- There are unrelated local modifications in `settings.json` and
  `hooks/check-guardian.sh`. Do not revert or rewrite them unless the ticket
  explicitly requires it.

## Wave 1 Objective

Close `INIT-001` in [MASTER_PLAN.md](../MASTER_PLAN.md):

- `TKT-001` Capture and document the current Claude runtime hook payloads and
  agent lifecycle semantics.
- `TKT-002` Build a smoke suite for session, prompt, agent, write deny, and git
  deny behavior.
- `TKT-003` Add `Write|Edit` WHO enforcement.
- `TKT-004` Add planner-only governance markdown writes with explicit migration
  override.
- `TKT-005` Align docs and prompt claims to enforced behavior only.

## Shared Constraints

- Do not import `state-lib.sh`, `judge-lib.sh`, `general-purpose` governance, or
  other parked subsystems from `claude-config-pro`.
- Do not create a second live control path beside the bootstrap kernel.
- Do not create new flat-file or breadcrumb coordination paths. Evidence files
  are allowed; workflow authority files are not.
- Prefer additions that are easy to delete after successor cutover.
- If a hook/runtime claim cannot be proven on the installed Claude version, mark
  it as unproven and adjust docs accordingly.
- Do not touch unrelated dirty files.

## Suggested Sequencing

1. Planner packet: confirm wave scope, evidence targets, and file boundaries.
2. Implementer packet A: runtime compatibility capture and smoke suite.
3. Tester packet A: verify the smoke suite against the current install.
4. Implementer packet B: write-side WHO enforcement and planner-only plan
   governance writes.
5. Tester packet B: verify write and git routing behavior end-to-end.
6. Implementer packet C: doc and prompt alignment cleanup.
7. Guardian packet: review, commit, and merge only after tester evidence is
   clean.

## Orchestrator Kickoff

Paste this to the orchestrator when starting the wave:

```text
Execute Wave 1 from docs/AGENT_HANDOFFS.md and MASTER_PLAN.md.

Follow the canonical role flow:
1. planner
2. implementer
3. tester
4. guardian

Do not write governed source directly from orchestrator context.
Do not claim a control property unless the installed Claude runtime proves it.
Use worktrees for implementer work.

Start with the Planner packet in docs/AGENT_HANDOFFS.md, then continue through
the wave in sequence.
```

## Planner Packet

Paste this when dispatching the planner:

```text
Task: Prepare Wave 1 execution for the hard-fork successor control plane.

Primary tickets:
- TKT-001
- TKT-002
- TKT-003
- TKT-004
- TKT-005

Goal:
- Turn the existing Wave 1 definition in MASTER_PLAN.md into a concrete
  execution map for implementer and tester work without expanding scope.

State domains touched:
- hook payload assumptions
- agent lifecycle assumptions
- write routing and role authority
- plan governance markdown authority
- documentation truthfulness

Adjacent components:
- settings.json
- hooks/subagent-start.sh
- hooks/check-planner.sh
- hooks/check-implementer.sh
- hooks/check-tester.sh
- hooks/check-guardian.sh
- hooks/branch-guard.sh
- hooks/plan-check.sh
- hooks/guard.sh
- hooks/context-lib.sh
- docs/DISPATCH.md
- docs/ARCHITECTURE.md
- docs/PLAN_DISCIPLINE.md
- CLAUDE.md
- MASTER_PLAN.md

Canonical authority:
- Current live policy authority is the bootstrap hook kernel in hooks/.
- Current plan authority is MASTER_PLAN.md.
- Current runtime truth must be derived from the installed Claude Code behavior,
  not from old assumptions.

Removal targets:
- Any doc or prompt claim that says dispatch enforcement already exists where
  the kernel cannot actually enforce it.
- Any stale assumption that still relies on Task/Subagent behavior if the
  installed runtime emits Agent semantics instead.

Required output:
- Exact work order for implementer and tester.
- Any required plan amendments to MASTER_PLAN.md only if they are necessary to
  reflect reality discovered during planning.
- Explicit file boundaries for Wave 1 so implementers do not spread changes
  across unrelated subsystems.
- Clear acceptance criteria for each ticket.
```

## Implementer Packet A

Paste this when dispatching the first implementer:

```text
Task: Implement TKT-001 and TKT-002 for the hard-fork successor.

Goal:
- Capture the actual installed Claude runtime hook payloads and agent lifecycle
  semantics.
- Build a smoke suite that proves the current runtime behavior for the control
  properties Wave 1 depends on.

State domains touched:
- hook event payloads
- agent lifecycle visibility
- scenario test evidence
- docs describing current runtime behavior

Adjacent components:
- settings.json
- hooks/HOOKS.md
- hooks/subagent-start.sh
- hooks/check-planner.sh
- hooks/check-implementer.sh
- hooks/check-tester.sh
- hooks/check-guardian.sh
- hooks/session-init.sh
- hooks/prompt-submit.sh
- tests/scenarios/
- docs/ARCHITECTURE.md
- docs/DISPATCH.md

Canonical authority:
- The installed Claude runtime behavior is the authority for payload and agent
  lifecycle semantics.
- The imported patched v2 hook kernel is the authority for current live control
  behavior.

Removal targets:
- Unproven assumptions about Task/Subagent payloads.
- Doc claims that state lifecycle behavior without test evidence.

Required deliverables:
- A reproducible smoke suite covering:
  - SessionStart
  - UserPromptSubmit
  - agent spawn visibility
  - source write deny behavior
  - git authority deny behavior
- Updated docs or test notes capturing the real runtime payload shape.
- Raw command output proving the smoke suite runs.

Constraints:
- Do not change shared-state architecture yet.
- Do not import later SQLite marker systems wholesale.
- Keep the work limited to compatibility capture and scenario proof.
```

## Tester Packet A

Paste this when dispatching the tester after Implementer A:

```text
Task: Verify TKT-001 and TKT-002.

Goal:
- Prove that the new smoke suite actually exercises the installed Claude runtime
  and correctly captures the hook and agent lifecycle semantics the kernel will
  rely on.

State domains touched:
- test scenario evidence
- runtime compatibility truth
- hook behavior claims

Adjacent components:
- tests/scenarios/
- settings.json
- hooks/subagent-start.sh
- hooks/session-init.sh
- hooks/prompt-submit.sh
- docs/ARCHITECTURE.md
- docs/DISPATCH.md

Canonical authority:
- The installed Claude runtime behavior as observed during the test run.

Required checks:
- The scenarios fail if the claimed hook or agent behavior is absent.
- The scenarios do not just grep static files; they validate runtime-observed
  evidence.
- The docs match the test results.

Required output:
- Raw test output.
- Exact observed runtime semantics.
- Any mismatch between claimed and observed behavior.
- AUTOVERIFY only if the evidence is clean and complete.
```

## Implementer Packet B

Paste this when dispatching the second implementer:

```text
Task: Implement TKT-003 and TKT-004.

Goal:
- Add write-side WHO enforcement to the bootstrap kernel.
- Add planner-only governance markdown authority with explicit migration mode.

State domains touched:
- active agent role detection
- source write policy
- governance markdown write policy
- plan migration override behavior

Adjacent components:
- hooks/branch-guard.sh
- hooks/plan-check.sh
- hooks/context-lib.sh
- hooks/prompt-submit.sh
- hooks/session-init.sh
- settings.json
- docs/DISPATCH.md
- docs/PLAN_DISCIPLINE.md
- CLAUDE.md
- agents/planner.md
- agents/implementer.md
- agents/tester.md
- MASTER_PLAN.md

Canonical authority:
- The bootstrap hook kernel remains the live authority.
- Git WHO enforcement in hooks/guard.sh is the existing model to mirror on the
  write side.
- Governance markdown rules are defined by MASTER_PLAN.md and docs/PLAN_DISCIPLINE.md.

Removal targets:
- Prompt-only enforcement for orchestrator source-write denial.
- Any path where planner/implementer/tester/orchestrator authority over writes
  is ambiguous.

Required behavior:
- Orchestrator cannot write governed source directly.
- Implementer can write source only in the permitted context.
- Tester cannot modify governed source.
- Planner can update plan/governance markdown only where allowed.
- Permanent-section plan rewrites require explicit `CLAUDE_PLAN_MIGRATION=1`.
- Denials must be visible and corrective, not silent.

Required output:
- Diff summary.
- Raw test results or scenario output proving each deny/allow path.
- Honest note about any runtime limitations that still prevent perfect role
  detection.
```

## Tester Packet B

Paste this when dispatching the tester after Implementer B:

```text
Task: Verify TKT-003 and TKT-004.

Goal:
- Prove that write-side WHO enforcement now matches the role model the fork
  claims to follow.

State domains touched:
- source write routing
- governance markdown write routing
- visible deny behavior
- role-based authority checks

Adjacent components:
- hooks/branch-guard.sh
- hooks/plan-check.sh
- hooks/context-lib.sh
- settings.json
- tests/scenarios/
- CLAUDE.md
- docs/DISPATCH.md
- docs/PLAN_DISCIPLINE.md

Canonical authority:
- Live hook behavior under the installed Claude runtime.

Required checks:
- Orchestrator source write is denied.
- Implementer path succeeds only in the intended context.
- Tester source write is denied.
- Planner governance path works for allowed edits and blocks forbidden
  permanent-section rewrites without migration override.
- The deny messages tell the next correct action.

Required output:
- Raw verification output.
- Any bypass or ambiguity still present.
- Confidence level and follow-up items.
- AUTOVERIFY only if the evidence is clean and complete.
```

## Implementer Packet C

Paste this when dispatching the third implementer:

```text
Task: Implement TKT-005.

Goal:
- Align docs and prompts so they describe only the control properties now
  actually enforced by the kernel.

State domains touched:
- dispatch documentation
- architecture documentation
- plan discipline wording
- orchestrator and agent prompt claims

Adjacent components:
- docs/DISPATCH.md
- docs/ARCHITECTURE.md
- docs/PLAN_DISCIPLINE.md
- CLAUDE.md
- agents/planner.md
- agents/implementer.md
- agents/tester.md
- agents/guardian.md
- MASTER_PLAN.md

Canonical authority:
- Enforced hook behavior and proven scenario tests.

Removal targets:
- Any language claiming dispatch enforcement where only prompt guidance exists.
- Any stale reference to historical runtime behavior not proven on the installed
  Claude version.

Required output:
- Diff summary.
- List of claims removed, corrected, or newly justified by tests.
- Raw lint or validation output if docs tooling exists.
```

## Guardian Packet

Paste this when dispatching guardian after the tester has produced clean
evidence:

```text
Task: Review and integrate Wave 1.

Scope:
- TKT-001
- TKT-002
- TKT-003
- TKT-004
- TKT-005

Required checks:
- Proof state is verified.
- Scenario evidence exists for runtime compatibility and write-side WHO
  enforcement.
- The merge diff does not introduce a second live control path.
- Docs no longer overclaim beyond tested enforcement.
- No unrelated dirty files are swept into the commit.

Lead with value:
- What control property the fork gained.
- What class of failure is now blocked.
- What remains for INIT-002.

Do not proceed without explicit approval unless the tester delivered a clean
auto-verify path and the current control rules allow it.
```

## Wave 2 Preview: Runtime-Backed Statusline

Statusline work begins after the runtime MVP starts landing.

- `TKT-011` Implement a runtime-backed statusline snapshot path and define the
  canonical fields exposed to `scripts/statusline.sh`.
- `TKT-012` Rebuild `scripts/statusline.sh` so the richer HUD derives its
  worktree, active-agent, initiative, proof, and workflow display from runtime
  snapshots with graceful fallback behavior.

When dispatching this wave later, use these requirements:

- Statusline is a read model, not an authority.
- `scripts/statusline.sh` renders only; it does not derive governance truth on
  its own.
- Statusline fields must come from canonical runtime state plus Claude stdin
  metrics.
- The statusline implementation may not introduce `.statusline-cache*` or other
  breadcrumb files as authority.
- The HUD may be rich, but it must degrade safely when optional runtime data is
  absent.
