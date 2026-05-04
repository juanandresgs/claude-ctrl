"""Policy modules for the cc-policy engine.

Individual policy modules register themselves via register_all().
Import this package to get all policies loaded into a registry.

PE-W2 adds write-path policies (branch_guard, write_who, enforcement_gap,
plan_guard, plan_exists, plan_immutability, decision_log).
PE-W3 adds bash-path policies — all 13 checks from guard.sh migrated
into 11 Python policy modules (test_gate shares one module for two checks).
PE-W5 adds three write-gate policies ported from shell hooks (doc_gate,
test_gate_pretool, mock_gate). Their shell hook counterparts become no-ops.

@decision DEC-PE-006
Title: policies/__init__.py is the sole aggregation point for policy registration
Status: accepted
Rationale: default_registry() in policy_engine.py imports this package and
  calls register_all(registry). Each future wave (W2, W3) adds imports here
  so new policies are automatically included in every default_registry()
  call without modifying policy_engine.py. This keeps the engine stable
  across waves and makes the set of active policies enumerable by reading
  this file.
"""

from __future__ import annotations

from runtime.core.policy_engine import PolicyRegistry


def register_all(registry: PolicyRegistry) -> None:
    """Register all active policies into the given registry.

    Called by default_registry() in policy_engine.py.

    Write-path priorities (PE-W2 + PE-W5):
      100  branch_guard       -- block source writes on main/master
      150  write_scratchlane_gate -- task-local artifact lane under tmp/
      175  write_admission_gate -- Guardian Admission custody fork for uncustodied source writes
      200  write_who          -- only implementer may write source files
      250  enforcement_gap    -- deny persistent linter gaps
      300  plan_guard         -- requires CAN_WRITE_GOVERNANCE for governance markdown or constitution-level files
      400  plan_exists        -- MASTER_PLAN.md must exist + staleness gate
      500  plan_immutability  -- permanent sections may not be rewritten
      600  decision_log       -- decision log entries are append-only
      650  test_gate_pretool  -- escalating gate: fail tests → block writes
      700  doc_gate           -- header + @decision annotation enforcement
      750  mock_gate          -- escalating gate: internal mocks in test files

    Bash-path priorities (PE-W3 + enforcement-gaps):
       25  quarantine_gate           -- deny tool use by SubagentStart-quarantined agents
      100  bash_tmp_safety           -- deny /tmp writes
      150  agent_contract_required   -- canonical stage↔subagent Agent launch contract
      200  bash_worktree_cwd         -- deny bare cd into .worktrees/
      250  bash_worktree_nesting     -- deny worktree add from inside .worktrees/ (Gap 5)
      260  bash_scratchlane_gate     -- task-local artifact lane + opaque interpreter wrapper
      270  bash_admission_gate       -- Guardian Admission custody fork for Bash source writes
      275  bash_write_who            -- capability gate for bash-based source/governance writes
      300  bash_git_who              -- lease-based WHO enforcement for git ops (expanded Gap 1)
      350  bash_worktree_creation    -- deny git worktree add from non-guardian roles (W-GWT-3)
      400  bash_main_sacred          -- deny non-landing commits on main/master
      500  bash_force_push           -- deny unsafe force push
      600  bash_destructive_git      -- hard deny reset --hard, clean -f, branch -D
      625  bash_stash_ban            -- deny destructive stash sub-ops for can_write_source actors
      630  bash_cross_branch_restore_ban -- deny cross-branch git restore/checkout contamination
      635  bash_shell_copy_ban       -- deny shell file-op writes (cp/mv/rsync/ln/install/tar/redirect) to forbidden scope paths
      700  bash_worktree_removal     -- safe worktree removal enforcement
      800  bash_test_gate_merge      -- test-pass gate for git merge
      850  bash_test_gate_commit     -- test-pass gate for git commit
      900  bash_eval_readiness       -- eval_state=ready_for_guardian gate
     1000  bash_workflow_scope       -- workflow binding + scope compliance
     1100  bash_approval_gate        -- one-shot approval for guarded git ops
    """
    # PE-W2: write-path policies
    from runtime.core.policies.write_branch import branch_guard
    from runtime.core.policies.write_decision_log import decision_log
    from runtime.core.policies.write_enforcement_gap import enforcement_gap
    from runtime.core.policies.write_plan_exists import plan_exists
    from runtime.core.policies.write_plan_guard import plan_guard
    from runtime.core.policies.write_plan_immutability import plan_immutability
    from runtime.core.policies.write_scratchlane_gate import check as write_scratchlane_gate
    from runtime.core.policies.write_admission_gate import check as write_admission_gate
    from runtime.core.policies.write_who import write_who

    registry.register(
        "branch_guard",
        branch_guard,
        event_types=["Write", "Edit"],
        priority=100,
    )
    registry.register(
        "write_scratchlane_gate",
        write_scratchlane_gate,
        event_types=["Write", "Edit"],
        priority=150,
    )
    registry.register(
        "write_admission_gate",
        write_admission_gate,
        event_types=["Write", "Edit"],
        priority=175,
    )
    registry.register(
        "write_who",
        write_who,
        event_types=["Write", "Edit"],
        priority=200,
    )
    registry.register(
        "enforcement_gap",
        enforcement_gap,
        event_types=["Write", "Edit"],
        priority=250,
    )
    registry.register(
        "plan_guard",
        plan_guard,
        event_types=["Write", "Edit"],
        priority=300,
    )
    registry.register(
        "plan_exists",
        plan_exists,
        event_types=["Write", "Edit"],
        priority=400,
    )
    registry.register(
        "plan_immutability",
        plan_immutability,
        event_types=["Write", "Edit"],
        priority=500,
    )
    registry.register(
        "decision_log",
        decision_log,
        event_types=["Write", "Edit"],
        priority=600,
    )

    # PE-W5: write-gate policies (shell hook ports)
    from runtime.core.policies.write_doc_gate import doc_gate
    from runtime.core.policies.write_mock_gate import mock_gate
    from runtime.core.policies.write_test_gate import check_test_gate_pretool

    registry.register(
        "test_gate_pretool",
        check_test_gate_pretool,
        event_types=["Write", "Edit"],
        priority=650,
    )
    registry.register(
        "doc_gate",
        doc_gate,
        event_types=["Write", "Edit"],
        priority=700,
    )
    registry.register(
        "mock_gate",
        mock_gate,
        event_types=["Write", "Edit"],
        priority=750,
    )

    # PE-W3: bash-path policies (guard.sh migration + enforcement-gaps fixes)
    from runtime.core.policies import (
        agent_contract_required,
        bash_approval_gate,
        bash_admission_gate,
        bash_cross_branch_restore_ban,
        bash_destructive_git,
        bash_eval_readiness,
        bash_force_push,
        bash_git_who,
        bash_main_sacred,
        bash_scratchlane_gate,
        bash_shell_copy_ban,
        bash_stash_ban,
        bash_test_gate,
        bash_tmp_safety,
        bash_workflow_scope,
        bash_worktree_creation,
        bash_worktree_cwd,
        bash_worktree_nesting,
        bash_worktree_removal,
        bash_write_who,
        quarantine_gate,
    )

    quarantine_gate.register(registry)
    bash_tmp_safety.register(registry)
    agent_contract_required.register(registry)
    bash_worktree_cwd.register(registry)
    bash_worktree_nesting.register(
        registry
    )  # Gap 5: prevent nested worktree creation (priority 250)
    bash_scratchlane_gate.register(registry)
    bash_admission_gate.register(registry)
    bash_write_who.register(registry)
    bash_git_who.register(registry)
    bash_worktree_creation.register(registry)
    bash_main_sacred.register(registry)
    bash_force_push.register(registry)
    bash_destructive_git.register(registry)
    bash_stash_ban.register(registry)  # priority 625: cross-lane stash contamination guard
    bash_cross_branch_restore_ban.register(registry)  # priority 630: cross-branch restore contamination guard
    bash_shell_copy_ban.register(registry)  # priority 635: shell file-op contamination guard (slice 10, DEC-DISCIPLINE-SHELL-COPY-BAN-001)
    bash_worktree_removal.register(registry)
    bash_test_gate.register(registry)
    bash_eval_readiness.register(registry)
    bash_workflow_scope.register(registry)
    bash_approval_gate.register(registry)
