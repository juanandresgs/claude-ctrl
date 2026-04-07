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
      200  write_who          -- only implementer may write source files
      250  enforcement_gap    -- deny persistent linter gaps
      300  plan_guard         -- only planner may write governance markdown
      400  plan_exists        -- MASTER_PLAN.md must exist + staleness gate
      500  plan_immutability  -- permanent sections may not be rewritten
      600  decision_log       -- decision log entries are append-only
      650  test_gate_pretool  -- escalating gate: fail tests → block writes
      700  doc_gate           -- header + @decision annotation enforcement
      750  mock_gate          -- escalating gate: internal mocks in test files

    Bash-path priorities (PE-W3 + enforcement-gaps):
      100  bash_tmp_safety           -- deny /tmp writes
      200  bash_worktree_cwd         -- deny bare cd into .worktrees/
      250  bash_worktree_nesting     -- deny worktree add from inside .worktrees/ (Gap 5)
      300  bash_git_who              -- lease-based WHO enforcement for git ops (expanded Gap 1)
      400  bash_main_sacred          -- deny commits on main/master
      500  bash_force_push           -- deny unsafe force push
      600  bash_destructive_git      -- hard deny reset --hard, clean -f, branch -D
      700  bash_worktree_removal     -- safe worktree removal enforcement
      800  bash_test_gate_merge      -- test-pass gate for git merge
      850  bash_test_gate_commit     -- test-pass gate for git commit
      900  bash_eval_readiness       -- eval_state=ready_for_guardian gate
     1000  bash_workflow_scope       -- workflow binding + scope compliance
     1100  bash_approval_gate        -- one-shot approval for high-risk git ops
    """
    # PE-W2: write-path policies
    from runtime.core.policies.write_branch import branch_guard
    from runtime.core.policies.write_decision_log import decision_log
    from runtime.core.policies.write_enforcement_gap import enforcement_gap
    from runtime.core.policies.write_plan_exists import plan_exists
    from runtime.core.policies.write_plan_guard import plan_guard
    from runtime.core.policies.write_plan_immutability import plan_immutability
    from runtime.core.policies.write_who import write_who

    registry.register(
        "branch_guard",
        branch_guard,
        event_types=["Write", "Edit"],
        priority=100,
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
        bash_approval_gate,
        bash_destructive_git,
        bash_eval_readiness,
        bash_force_push,
        bash_git_who,
        bash_main_sacred,
        bash_test_gate,
        bash_tmp_safety,
        bash_workflow_scope,
        bash_worktree_cwd,
        bash_worktree_nesting,
        bash_worktree_removal,
    )

    bash_tmp_safety.register(registry)
    bash_worktree_cwd.register(registry)
    bash_worktree_nesting.register(
        registry
    )  # Gap 5: prevent nested worktree creation (priority 250)
    bash_git_who.register(registry)
    bash_main_sacred.register(registry)
    bash_force_push.register(registry)
    bash_destructive_git.register(registry)
    bash_worktree_removal.register(registry)
    bash_test_gate.register(registry)
    bash_eval_readiness.register(registry)
    bash_workflow_scope.register(registry)
    bash_approval_gate.register(registry)
