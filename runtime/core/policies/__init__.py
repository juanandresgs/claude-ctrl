"""Policy modules for the cc-policy engine.

Individual policy modules register themselves via register_all().
Import this package to get all policies loaded into a registry.

In W1 this package is empty — no policies are migrated yet.
PE-W2 will add write-path policies (branch-guard, doc-gate, plan-guard).
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
    W2 will add write-path policies here.
    W3 will add bash-path policies here.
    """
    # PE-W2: from runtime.core.policies import write_path; write_path.register(registry)
    # PE-W3: from runtime.core.policies import bash_path; bash_path.register(registry)
    pass
