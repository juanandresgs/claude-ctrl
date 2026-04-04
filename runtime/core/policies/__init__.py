"""Policy modules for the cc-policy engine.

Individual policy modules register themselves via register_all().
Import this package to get all policies loaded into a registry.

PE-W2 adds write-path policies (branch_guard, write_who, enforcement_gap,
plan_guard, plan_exists, plan_immutability, decision_log).
PE-W3 will add bash-path policies (guard.sh checks).

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
    Priority order matches the pre-write.sh CHECKS list:
      100  branch_guard       — block source writes on main/master
      200  write_who          — only implementer may write source files
      250  enforcement_gap    — deny persistent linter gaps
      300  plan_guard         — only planner may write governance markdown
      400  plan_exists        — MASTER_PLAN.md must exist + staleness gate
      500  plan_immutability  — permanent sections may not be rewritten
      600  decision_log       — decision log entries are append-only
    """
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
