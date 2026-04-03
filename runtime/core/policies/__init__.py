"""Policy modules for the cc-policy engine.

Individual policy modules register themselves via register_all().
Import this package to get all policies loaded into a registry.

PE-W3 adds bash-path policies — all 13 checks from guard.sh migrated
into 11 Python policy modules (test_gate shares one module for two checks).

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

    Priority order (ascending = runs first):
      100  bash_tmp_safety        — deny /tmp writes
      200  bash_worktree_cwd      — deny bare cd into .worktrees/
      300  bash_git_who           — lease-based WHO enforcement for git ops
      400  bash_main_sacred       — deny commits on main/master
      500  bash_force_push        — deny unsafe force push
      600  bash_destructive_git   — hard deny reset --hard, clean -f, branch -D
      700  bash_worktree_removal  — safe worktree removal enforcement
      800  bash_test_gate_merge   — test-pass gate for git merge
      850  bash_test_gate_commit  — test-pass gate for git commit
      900  bash_eval_readiness    — eval_state=ready_for_guardian gate
     1000  bash_workflow_scope    — workflow binding + scope compliance
     1100  bash_approval_gate     — one-shot approval for high-risk git ops
    """
    # PE-W2: from runtime.core.policies import write_path; write_path.register(registry)

    # PE-W3: bash-path policies (guard.sh migration)
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
        bash_worktree_removal,
    )

    bash_tmp_safety.register(registry)
    bash_worktree_cwd.register(registry)
    bash_git_who.register(registry)
    bash_main_sacred.register(registry)
    bash_force_push.register(registry)
    bash_destructive_git.register(registry)
    bash_worktree_removal.register(registry)
    bash_test_gate.register(registry)
    bash_eval_readiness.register(registry)
    bash_workflow_scope.register(registry)
    bash_approval_gate.register(registry)
