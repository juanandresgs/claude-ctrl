"""ClauDEX dispatch contract — adapter-shim over authority_registry.

@decision DEC-CLAUDEX-DISPATCH-CONTRACT-ADAPTER-001
Title: dispatch_contract.py is an adapter over authority_registry.
Status: accepted (supersedes the standalone-authority framing of
  DEC-CLAUDEX-DISPATCH-CONTRACT-001 while keeping its public import
  surface for existing consumers).
Rationale: Slice A5R of the CUTOVER_PLAN collapse pass requires a
  single owner for stage -> Agent-tool subagent_type. That owner is
  authority_registry (already owns the canonical STAGE_SUBAGENT_TYPES
  mapping, the full _SUBAGENT_TYPE_ALIASES table, and
  dispatch_subagent_type_for_stage). dispatch_contract now re-exports
  those symbols so existing imports (agent_prompt.py,
  policies/agent_contract_required.py) keep working unchanged while
  the parallel declarations are retired.

  The original justification for a separate module -- "capability model
  vs launch contract" -- is subsumed because the capability registry
  already has the launch-contract surface baked in. Keeping two sources
  of truth created latent drift (the local dispatch_contract._SUBAGENT_TYPE_ALIASES
  had only 1 entry while authority_registry's had 5) -- exactly the kind
  of silent divergence CUTOVER_PLAN Constitutional Rule #1 forbids.

  Invariants (enforced by tests in tests/runtime/test_dispatch_contract.py):
    1. STAGE_SUBAGENT_TYPES is the authority_registry object (identity).
    2. _SUBAGENT_TYPE_ALIASES is the authority_registry object (identity).
    3. dispatch_subagent_type_for_stage delegates byte-identically.
    4. No module-level dict literal re-declares either mapping.
    5. __all__ preserved so existing callers' imports still resolve.

@decision DEC-CLAUDEX-DISPATCH-CONTRACT-001
Title: runtime/core/dispatch_contract.py owns the stage -> Agent-tool
  subagent_type mapping.
Status: superseded by DEC-CLAUDEX-DISPATCH-CONTRACT-ADAPTER-001 (A5R).
Rationale: Original framing kept dispatch_contract as a standalone
  authority separate from authority_registry. Superseded because
  authority_registry already owned the canonical STAGE_SUBAGENT_TYPES
  and _SUBAGENT_TYPE_ALIASES -- keeping both was a dual-authority defect.
"""

from __future__ import annotations

from typing import Optional

from runtime.core.authority_registry import (
    _LIVE_ROLE_ALIASES,  # preserved for backward-compat imports
    _SUBAGENT_TYPE_ALIASES,
    STAGE_SUBAGENT_TYPES,
    dispatch_subagent_type_for_stage as _authority_dispatch_subagent_type_for_stage,
)


def dispatch_subagent_type_for_stage(stage: str) -> Optional[str]:
    """Return the required Agent-tool subagent_type for ``stage``.

    Delegates to authority_registry.dispatch_subagent_type_for_stage --
    the canonical owner -- so dispatch_contract consumers and
    authority_registry consumers cannot disagree.
    """
    return _authority_dispatch_subagent_type_for_stage(stage)


__all__ = [
    "STAGE_SUBAGENT_TYPES",
    "dispatch_subagent_type_for_stage",
]
