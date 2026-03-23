# MASTER_PLAN.md

Status: active
Created: 2026-03-23
Last updated: 2026-03-23 (Wave 1 execution detail added)

## Identity

This repository is the hard-fork successor to `claude-config-pro`. It is being
built from the patched `v2.0` kernel outward so the governance layer remains
smaller, more legible, and more mechanically trustworthy than the work it
governs.

## Architecture

- Canonical judgment lives in [CLAUDE.md](CLAUDE.md) and [agents/](agents).
- The active live authority is still the imported patched `v2.0` hook kernel in
  [hooks/](hooks) with [settings.json](settings.json).
- The canonical prompt layer is present, but several of its intended guarantees
  are not yet mechanically enforced in the bootstrap kernel.
- The current hard gaps are: missing write-side WHO enforcement, no real typed
  runtime ownership of shared state, and no revalidated subagent lifecycle
  contract against the installed Claude runtime.
- The current statusline is only a bootstrap HUD. The successor statusline will
  be rebuilt as a runtime-backed read model over the new state machine, not as a
  separate authority path.
- The target architecture is modular: thin hooks, typed runtime, read-only
  sidecars, and strict plan discipline.
- The future shared-state authority moves into [runtime/](runtime), reached
  through [hooks/lib/runtime-bridge.sh](hooks/lib/runtime-bridge.sh).
- No second live control path is allowed during migration. Replacements must cut
  over fully and delete the superseded mechanism.

## Original Intent

Bootstrap a new control-plane fork that preserves the stable determinism of
`v2.0`, carries forward the essential safety and proof fixes, selectively
rebuilds only the genuinely valuable ideas from later versions, and reaches a
full successor spec without dragging `claude-config-pro` complexity wholesale
into the new mainline.

## Principles

1. Start from the working kernel, not from the most complex branch.
2. Prompts shape judgment; hooks enforce local policy; runtime owns shared
   state.
3. Every claimed invariant must be backed by a gate, a state check, or a
   scenario test on the installed Claude runtime.
4. Port proven enforcement from history when it worked; simplify the
   implementation instead of deleting the control property.
5. Delete what you replace. Do not keep fallback authorities alive.
6. Preserve readable ownership boundaries between prompts, hooks, runtime, and
   sidecars.
7. The successor runtime must eliminate flat-file and breadcrumb coordination
   for workflow state; evidence files may exist, but they are never authority.
8. Docs must not claim protection that the running system cannot actually
   enforce.
9. Upstream is a donor, not the mainline.

## Decision Log

- `2026-03-23 — DEC-FORK-001` Bootstrap the successor from the patched `v2.0`
  kernel rather than from `claude-config-pro` `main`.
- `2026-03-23 — DEC-FORK-002` Preserve the canonical prompt rewrite already
  drafted in this repository and layer the kernel beneath it.
- `2026-03-23 — DEC-FORK-003` Initialize the hard fork as a standalone
  repository with its own history and treat upstream only as an import source.
- `2026-03-23 — DEC-FORK-004` Keep the patched `v2.0` bootstrap kernel as the
  sole live authority until each successor replacement hook is proven in
  scenarios and cuts over completely.
- `2026-03-23 — DEC-FORK-005` Port write-side dispatch enforcement from the
  later line into the successor core before broader runtime work; missing WHO
  enforcement on `Write|Edit` is the most important current control gap.
- `2026-03-23 — DEC-FORK-006` Treat the current Claude runtime contract as a
  compatibility surface that must be revalidated now; historical assumptions
  about `Task`, `Agent`, `SubagentStart`, and `SubagentStop` are not trusted
  until proven on the installed version.
- `2026-03-23 — DEC-FORK-007` The typed runtime becomes the sole authority for
  shared workflow state; flat files, breadcrumbs, and session-local marker files
  are not permitted as coordination mechanisms in the successor state machine.
- `2026-03-23 — DEC-FORK-008` No documentation may claim a control guarantee
  unless a scenario test proves it against the installed Claude version.
- `2026-03-23 — DEC-FORK-009` Reimplement the richer statusline HUD from the
  later line as a runtime-backed read model. Rendering belongs in
  `scripts/statusline.sh`; state derivation belongs in the successor runtime.
- `2026-03-23 — DEC-FORK-013` Trace artifacts remain evidence and recovery
  material only. No successor control decision may depend on a trace file,
  breadcrumb, or cache file being present.
- `2026-03-23 — DEC-FORK-010` Wave 1 Write|Edit WHO enforcement will be
  implemented by adding role checks to the existing `PreToolUse` (Write|Edit)
  hook chain rather than creating a new hook entrypoint, because the existing
  chain already fires on every Write|Edit call and adding a new file to that
  chain is lower-risk than restructuring the hook wiring in settings.json.
- `2026-03-23 — DEC-FORK-011` TKT-001 runtime payload capture will use
  instrumented wrapper scripts that log raw hook input JSON to a capture
  directory, not modifications to production hooks, so the capture is
  removable without merge risk.
- `2026-03-23 — DEC-FORK-012` The smoke suite (TKT-002) will be shell-based
  scenario tests in `tests/scenarios/` that invoke hook scripts with synthetic
  JSON payloads on stdin, validating output JSON for deny/allow/context
  decisions. This avoids requiring a live Claude runtime for CI.

## Active Initiatives

### INIT-001: Compatibility and Control Closure

- **Status:** in-progress
- **Goal:** Make the current bootstrap truthful, safe, and aligned with the
  installed Claude runtime before deeper successor work continues.
- **Current truth:** `git` WHO enforcement exists, but `Write|Edit` WHO
  enforcement does not; prompts claim dispatch rules that the kernel does not
  fully enforce; subagent lifecycle behavior is not yet validated against the
  current `Agent` runtime contract.
- **Scope:** `settings.json`, runtime compatibility checks, hook payload
  validation, visible deny behavior, write-side WHO routing, planner-only plan
  governance writes, doc corrections where claims exceed reality.
- **Exit:** Orchestrator cannot write governed source or governance markdown
  directly, agent lifecycle behavior is scenario-tested on the installed Claude
  version, and dispatch docs match real behavior.
- **Dependencies:** none
- **Implementation tickets:**
- `TKT-001` Capture and document the current Claude runtime hook payloads and
  agent lifecycle semantics actually emitted on this installation.
- `TKT-002` Build a smoke suite for `SessionStart`, `UserPromptSubmit`, agent
  spawn, `Write` deny, and `git` deny so control claims are test-backed.
- `TKT-003` Add `Write|Edit` WHO enforcement: orchestrator source-write deny,
  implementer-only source writes, and tester source-write deny.
- `TKT-004` Add planner-only governance markdown writes with explicit
  `CLAUDE_PLAN_MIGRATION=1` override for permanent-section migrations.
- `TKT-005` Align [docs/DISPATCH.md](docs/DISPATCH.md),
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), and prompt language to enforced
  behavior only.

#### Wave 1 Execution Detail

**Sequencing:** TKT-001 first (discover runtime contract), then TKT-002
(codify discoveries as tests), then TKT-003 and TKT-004 in parallel (both
are PreToolUse additions with no shared state), then TKT-005 last (docs
can only be corrected after enforcement is live).

**Critical path:** TKT-001 -> TKT-002 -> TKT-003 -> TKT-005. Max width: 2
(TKT-003 and TKT-004 can run in parallel after TKT-002).

##### TKT-001: Runtime Payload Capture

- **Weight:** S
- **Gate:** review (user sees captured payloads)
- **Deps:** none
- **Implementer scope:**
  - Create `tests/scenarios/capture/` directory.
  - Create `tests/scenarios/capture/capture-wrapper.sh` -- a thin wrapper that
    sources `hooks/log.sh`, reads stdin, writes the raw JSON to
    `tests/scenarios/capture/payloads/<event_type>_<timestamp>.json`, then
    exits 0 (pass-through, no deny).
  - Create `tests/scenarios/capture/install-capture.sh` that temporarily
    prepends the capture wrapper to each event chain in a copy of
    settings.json (not the live one) for manual testing.
  - Create `tests/scenarios/capture/README.md` documenting how to run a
    capture session and what fields to look for.
- **Tester scope:**
  - Run a capture session manually (or review the implementer's capture
    output).
  - Document the actual JSON schema for: `SubagentStart` (confirm field
    `.agent_type` exists and values match `planner|Plan`, `implementer`,
    `tester`, `guardian`, `Bash`, `Explore`), `SubagentStop` (confirm what
    fields exist in the stop payload and whether `.response` is present),
    `PreToolUse` for Write|Edit (confirm `.tool_input.file_path` and
    `.tool_input.content` for Write, `.tool_input.old_string` for Edit),
    `PreToolUse` for Bash (confirm `.tool_input.command`).
  - Produce a `tests/scenarios/capture/PAYLOAD_CONTRACT.md` documenting
    every confirmed field, its type, and whether it was observed empty or
    absent in any sample.
- **Acceptance criteria:**
  - At least one captured payload per event type: SessionStart,
    UserPromptSubmit, SubagentStart, SubagentStop, PreToolUse (Write),
    PreToolUse (Edit), PreToolUse (Bash), PostToolUse (Write), Stop.
  - PAYLOAD_CONTRACT.md exists and documents field presence for each.
  - No production hooks were modified.
- **File boundaries:**
  - Creates: `tests/scenarios/capture/` (all files within)
  - Reads: `hooks/log.sh` (source only)
  - Does NOT modify: any file in `hooks/`, `settings.json`, `agents/`,
    `docs/`

##### TKT-002: Smoke Suite

- **Weight:** M
- **Gate:** review (user sees test output)
- **Deps:** TKT-001 (needs PAYLOAD_CONTRACT.md for accurate synthetic
  payloads)
- **Implementer scope:**
  - Create `tests/scenarios/test-runner.sh` -- a minimal test harness that
    runs each scenario script, counts pass/fail, and exits nonzero if any
    fail.
  - Create scenario scripts (one per file) in `tests/scenarios/`:
    - `test-session-start.sh` -- feeds synthetic SessionStart JSON to
      `hooks/session-init.sh`, verifies exit 0 and JSON output structure.
    - `test-prompt-submit.sh` -- feeds synthetic UserPromptSubmit JSON to
      `hooks/prompt-submit.sh`, verifies exit 0.
    - `test-agent-spawn.sh` -- feeds synthetic SubagentStart JSON for each
      known agent type to `hooks/subagent-start.sh`, verifies
      `additionalContext` is present in output and contains role-specific
      keywords.
    - `test-write-deny-main.sh` -- feeds synthetic PreToolUse Write JSON
      with a `.ts` file path to `hooks/branch-guard.sh` from a git repo on
      main, verifies `permissionDecision: deny`.
    - `test-write-allow-worktree.sh` -- same as above but from a non-main
      branch, verifies exit 0 with no deny.
    - `test-git-deny-non-guardian.sh` -- feeds synthetic PreToolUse Bash
      JSON with `git commit` command to `hooks/guard.sh` without Guardian
      role active, verifies `permissionDecision: deny`.
    - `test-git-allow-guardian.sh` -- same but with Guardian role marker
      present, verifies no deny (proof and test gates will need to be
      satisfied or the test must set up `.test-status` and `.proof-status`
      files).
    - `test-plan-required.sh` -- feeds synthetic PreToolUse Write JSON to
      `hooks/plan-check.sh` in a git repo with no MASTER_PLAN.md, verifies
      deny.
  - Each test script must:
    - Set up a temporary git repo in `tmp/` (not `/tmp/`)
    - Clean up after itself
    - Print PASS or FAIL with test name
    - Exit 0 on pass, 1 on fail
- **Tester scope:**
  - Run `tests/scenarios/test-runner.sh` and paste raw output.
  - Verify each test exercises the real hook script (not a mock).
  - Verify cleanup is complete (no leftover tmp/ directories).
- **Acceptance criteria:**
  - All 8+ scenario tests pass.
  - Each test creates its own isolated git repo, feeds real JSON to real
    hook scripts, and validates the output JSON.
  - `tests/scenarios/test-runner.sh` exits 0 when all pass, nonzero when
    any fail.
  - No production hooks were modified.
- **File boundaries:**
  - Creates: `tests/scenarios/test-runner.sh`, `tests/scenarios/test-*.sh`
  - Reads: all hooks in `hooks/` (invokes them with synthetic stdin)
  - Creates temp state: `tmp/` (cleaned up per test)
  - Does NOT modify: any file in `hooks/`, `settings.json`, `agents/`,
    `docs/`

##### TKT-003: Write|Edit WHO Enforcement

- **Weight:** M
- **Gate:** approve (user must approve the deny behavior before merge)
- **Deps:** TKT-002 (tests must exist to validate the new enforcement)
- **Implementer scope:**
  - Create `hooks/write-guard.sh` -- a new PreToolUse hook for Write|Edit
    that enforces WHO rules. This is a NEW file, not a modification to
    existing hooks.
  - The hook must:
    1. Source `hooks/log.sh` and `hooks/context-lib.sh`.
    2. Read the file path from `.tool_input.file_path`.
    3. Detect the current active agent role via
       `current_active_agent_role`.
    4. Apply these rules:
       - **Source files** (matching `SOURCE_EXTENSIONS`): DENY if role is
         empty (orchestrator direct write), `planner`, `tester`, or
         `guardian`. ALLOW only if role is `implementer`. Skip if file is
         in `.claude/`, is a test file, or is in a skippable path.
       - **Non-source files**: EXIT 0 (no WHO enforcement for config,
         docs, markdown -- TKT-004 handles governance markdown separately).
    5. The deny message must say which role attempted the write and direct
       to the correct agent.
  - Wire `hooks/write-guard.sh` into `settings.json` PreToolUse Write|Edit
    chain. Insert it AFTER `branch-guard.sh` and BEFORE `doc-gate.sh` so
    branch protection fires first and doc-gate only fires for allowed
    writes.
  - Add scenario tests:
    - `tests/scenarios/test-write-guard-orchestrator-deny.sh` -- no active
      role, source file write, expects deny.
    - `tests/scenarios/test-write-guard-implementer-allow.sh` --
      implementer role active, source file write, expects allow.
    - `tests/scenarios/test-write-guard-tester-deny.sh` -- tester role
      active, source file write, expects deny.
    - `tests/scenarios/test-write-guard-planner-deny.sh` -- planner role
      active, source file write, expects deny.
    - `tests/scenarios/test-write-guard-config-allow.sh` -- any role,
      non-source file, expects allow (no enforcement).
- **Tester scope:**
  - Run all new and existing scenario tests.
  - Verify that an orchestrator-level Write call to a `.ts` file is denied.
  - Verify that an implementer-level Write call to a `.ts` file is allowed.
  - Verify that non-source files (`.json`, `.md`, `.yaml`) pass through
    without WHO checks.
  - Verify existing tests still pass (no regression).
- **Acceptance criteria:**
  - `hooks/write-guard.sh` exists and is wired in settings.json.
  - Orchestrator source writes are denied with clear message.
  - Implementer source writes are allowed.
  - Tester, planner, and guardian source writes are denied.
  - Non-source files are unaffected.
  - All scenario tests pass including pre-existing ones.
- **File boundaries:**
  - Creates: `hooks/write-guard.sh`
  - Modifies: `settings.json` (add one hook entry to PreToolUse Write|Edit
    array)
  - Creates: `tests/scenarios/test-write-guard-*.sh` (5 test files)
  - Does NOT modify: any existing hook script, any agent prompt, any doc

##### TKT-004: Planner-Only Governance Markdown Writes

- **Weight:** M
- **Gate:** approve (user must approve the deny behavior before merge)
- **Deps:** TKT-002 (tests must exist to validate)
- **Implementer scope:**
  - Create `hooks/plan-guard.sh` -- a new PreToolUse hook for Write|Edit
    that enforces governance markdown authority. This is a NEW file.
  - The hook must:
    1. Source `hooks/log.sh` and `hooks/context-lib.sh`.
    2. Read the file path from `.tool_input.file_path`.
    3. Define governance markdown as: `MASTER_PLAN.md`, `CLAUDE.md`,
       `agents/*.md`, `docs/*.md`.
    4. If the file is NOT governance markdown, EXIT 0 (not this hook's
       concern).
    5. If the file IS governance markdown:
       - ALLOW if role is `planner` or `Plan`.
       - ALLOW if `CLAUDE_PLAN_MIGRATION=1` is set in the environment
         (explicit override for permanent-section migrations by any role).
       - ALLOW if the file is in `.claude/` (meta-infrastructure, not
         governed).
       - DENY otherwise, with a message directing to the planner agent.
    6. Special case: `MASTER_PLAN.md` writes by the orchestrator (empty
       role) should be ALLOWED because the planner agent prompt IS the
       orchestrator's planner persona in this bootstrap. This avoids
       deadlock where the planner cannot write the plan. Revisit when
       `CLAUDE_AGENT_ROLE` is confirmed available from the runtime.
  - Wire `hooks/plan-guard.sh` into `settings.json` PreToolUse Write|Edit
    chain. Insert it AFTER `write-guard.sh` (TKT-003) so source-file WHO
    fires first.
  - Add scenario tests:
    - `tests/scenarios/test-plan-guard-planner-allow.sh` -- planner role,
      MASTER_PLAN.md write, expects allow.
    - `tests/scenarios/test-plan-guard-implementer-deny.sh` -- implementer
      role, MASTER_PLAN.md write, expects deny.
    - `tests/scenarios/test-plan-guard-migration-override.sh` -- any role
      with `CLAUDE_PLAN_MIGRATION=1`, MASTER_PLAN.md write, expects allow.
    - `tests/scenarios/test-plan-guard-non-governance.sh` -- any role,
      non-governance file, expects allow (pass-through).
- **Tester scope:**
  - Run all new and existing scenario tests.
  - Verify implementer cannot write MASTER_PLAN.md.
  - Verify planner can write MASTER_PLAN.md.
  - Verify migration override works.
  - Verify non-governance files are unaffected.
- **Acceptance criteria:**
  - `hooks/plan-guard.sh` exists and is wired in settings.json.
  - Only planner role (or migration override) can write governance markdown.
  - Non-governance files pass through.
  - All scenario tests pass.
- **File boundaries:**
  - Creates: `hooks/plan-guard.sh`
  - Modifies: `settings.json` (add one hook entry to PreToolUse Write|Edit
    array)
  - Creates: `tests/scenarios/test-plan-guard-*.sh` (4 test files)
  - Does NOT modify: any existing hook script, any agent prompt, any doc

##### TKT-005: Doc Alignment

- **Weight:** S
- **Gate:** review (user reviews corrected docs)
- **Deps:** TKT-003 and TKT-004 (docs must reflect what is actually enforced)
- **Implementer scope:**
  - Edit `docs/DISPATCH.md`:
    - Remove the claim "Dispatch semantics are already enforced there."
    - Replace with accurate statement of what IS enforced: git WHO (Guardian
      only for commit/merge/push via guard.sh), Write|Edit WHO (implementer
      only for source files via write-guard.sh), governance markdown
      authority (planner only via plan-guard.sh), main branch protection
      (source files blocked on main via branch-guard.sh).
    - List what is NOT yet enforced: typed runtime dispatch queue,
      automatic planner-to-implementer-to-tester-to-guardian sequencing,
      orchestrator direct dispatch denial.
  - Edit `docs/ARCHITECTURE.md`:
    - Add a "Current Enforcement Surface" subsection under "Current
      Bootstrap" listing the actual PreToolUse chain and what each hook
      enforces.
    - Remove or qualify any language that implies the successor runtime is
      active.
  - Edit `docs/PLAN_DISCIPLINE.md`:
    - Add a "Current Enforcement" subsection listing what plan-check.sh
      and plan-guard.sh actually enforce today.
    - Note that planctl.py is still a scaffold.
  - Do NOT edit `CLAUDE.md` or `agents/*.md` -- prompt language is
    aspirational by design and will be aligned when the successor hooks
    fully replace the bootstrap. The docs are the claim surface that must
    match reality per DEC-FORK-008.
- **Tester scope:**
  - Read each modified doc and verify every factual claim against the
    actual hook code.
  - Verify no doc claims enforcement that does not exist in the hook chain.
  - Verify no removed claims were actually true (i.e., confirm the removal
    was correct).
- **Acceptance criteria:**
  - `docs/DISPATCH.md` accurately lists enforced vs unenforced dispatch
    semantics.
  - `docs/ARCHITECTURE.md` has a current enforcement surface subsection.
  - `docs/PLAN_DISCIPLINE.md` has a current enforcement subsection.
  - No doc claims a protection the hook chain cannot deliver.
  - No factual errors in the corrected docs.
- **File boundaries:**
  - Modifies: `docs/DISPATCH.md`, `docs/ARCHITECTURE.md`,
    `docs/PLAN_DISCIPLINE.md`
  - Does NOT modify: `CLAUDE.md`, `agents/*.md`, any hook, `settings.json`

#### Wave 1 State Authority Map

| State Domain | Current Authority | Wave 1 Change |
|---|---|---|
| Git WHO (commit/merge/push) | `hooks/guard.sh` check 3 via `context-lib.sh` | No change |
| Write|Edit WHO (source) | **NONE** | `hooks/write-guard.sh` (TKT-003) |
| Governance markdown authority | **NONE** | `hooks/plan-guard.sh` (TKT-004) |
| Main branch protection (writes) | `hooks/branch-guard.sh` | No change |
| Plan existence gate | `hooks/plan-check.sh` | No change |
| Agent role tracking | `.subagent-tracker` via `subagent-start.sh` | No change; TKT-001 validates |
| Proof-of-work lifecycle | `.proof-status-*` via `context-lib.sh` | No change |
| Test status | `.test-status` via `test-runner.sh` | No change |
| Hook input JSON schema | Assumed from observation | TKT-001 validates; TKT-002 codifies |

#### Wave 1 Known Risks

1. **Role detection depends on `.subagent-tracker` file timing.** If
   `subagent-start.sh` has not fired yet (e.g., orchestrator writes before
   any agent is spawned), the role will be empty. TKT-003 treats empty role
   as "orchestrator" and denies source writes. This is correct behavior but
   may surprise during testing.
2. **TKT-004 orchestrator-MASTER_PLAN.md special case.** The planner agent
   prompt runs as the orchestrator in this bootstrap (no separate
   `CLAUDE_AGENT_ROLE`). plan-guard.sh must allow empty-role writes to
   MASTER_PLAN.md to avoid deadlocking the planning workflow. This is a
   known imprecision that gets resolved when the runtime provides reliable
   role identity.
3. **settings.json is a shared dirty file.** The user's working copy has
   local modifications. TKT-003 and TKT-004 both need to add entries to the
   PreToolUse Write|Edit array. Implementers must coordinate with the user
   on the settings.json merge.

### INIT-002: Runtime MVP and Thin Hook Cutover

- **Status:** ready
- **Goal:** Replace bootstrap shared-state ownership with a real typed runtime
  and small hook entrypoints without reintroducing `claude-config-pro` style
  complexity.
- **Current truth:** [runtime/cli.py](runtime/cli.py),
  [scripts/planctl.py](scripts/planctl.py), and [hooks/lib/](hooks/lib) are
  scaffolds; the live kernel still owns proof, markers, worktree tracking, and
  related workflow state. The current statusline is also still a bootstrap cache
  reader rather than a runtime-backed projection.
- **Scope:** SQLite schema, `cc-policy` command implementation, runtime bridge,
  proof/marker/worktree/event domains, statusline projection,
  `pre-write.sh`, `pre-bash.sh`, `post-task.sh`, and hook-lib cutover.
- **Exit:** Shared workflow state flows through `cc-policy`; no hot-path hook
  entrypoint owns workflow state directly; successor hook entrypoints are
  readable, timed, and locally testable; statusline reads runtime-backed
  snapshots rather than separate cache authority; flat-file and breadcrumb
  coordination paths are removed.
- **Dependencies:** INIT-001
- **Implementation tickets:**
- `TKT-006` Implement the SQLite-backed runtime schema and real `cc-policy`
  commands for `proof_state`, `agent_markers`, `events`, and `worktrees`.
- `TKT-007` Replace bootstrap shared-state reads and writes with
  [hooks/lib/runtime-bridge.sh](hooks/lib/runtime-bridge.sh) calls and delete
  superseded flat-file and breadcrumb authorities after cutover.
- `TKT-008` Implement real
  [pre-write.sh](hooks/pre-write.sh) and [pre-bash.sh](hooks/pre-bash.sh) thin
  entrypoints over the hook libs in [hooks/lib/](hooks/lib).
- `TKT-009` Implement
  [post-task.sh](hooks/post-task.sh) dispatch emission and queue handling for
  `planner -> implementer -> tester -> guardian`.
- `TKT-011` Implement a runtime-backed statusline snapshot path and define the
  canonical fields exposed to `scripts/statusline.sh`.
- `TKT-012` Rebuild `scripts/statusline.sh` so the richer HUD derives its
  worktree, active-agent, initiative, proof, and workflow display from runtime
  snapshots with graceful fallback behavior.

### INIT-003: Plan Discipline and Successor Validation

- **Status:** planned
- **Goal:** Finish the successor kernel so its plan discipline, verification, and
  release claims are mechanically trustworthy.
- **Current truth:** [scripts/planctl.py](scripts/planctl.py) only validates
  section presence and stamps a placeholder timestamp; `MASTER_PLAN.md`
  discipline is still largely social rather than enforced.
- **Scope:** plan immutability, decision-log closure rules, trace-lite, scenario
  acceptance suite, statusline render/round-trip validation, shadow-mode
  sidecars, and readiness for daemon promotion.
- **Exit:** March 7-style plan replacement is mechanically blocked, the kernel
  acceptance suite passes twice consecutively, and sidecars remain read-only
  until the kernel is stable.
- **Dependencies:** INIT-001, INIT-002
- **Implementation tickets:**
- `TKT-010` Expand [scripts/planctl.py](scripts/planctl.py) into real section
  immutability, `Last updated`, append-only decision-log, and initiative
  compression enforcement.
- **Post-ticket continuation:** Add trace-lite manifests and summaries, complete
  the full acceptance suite in `tests/scenarios/`, including runtime-backed
  statusline render and round-trip checks; reintroduce search and observatory in
  shadow mode only; then promote `cc-policy` to daemon mode after CLI mode
  proves stable.

## Completed Initiatives

- Standalone hard-fork repository bootstrapped from the patched `v2.0` kernel.
- Canonical prompt set drafted in `CLAUDE.md` and `agents/`.
- Successor implementation spec written in `implementation_plan.md`.
- Successor runtime, hook-lib, sidecar, and docs directories scaffolded so work
  can land against stable paths.

## Parked Issues

- Search and observatory sidecars remain parked from hot-path authority until
  the kernel acceptance suite is green twice consecutively.
- Daemon promotion and multi-client coordination stay parked until CLI mode is a
  proven stable interface.
- Upstream synchronization remains manual and selective; no merge/rebase flow
  from upstream is allowed into this mainline.
- Plugin ecosystems, auxiliary agent ecosystems, and non-core experiments remain
  out of scope until the kernel and runtime authority are stable.
