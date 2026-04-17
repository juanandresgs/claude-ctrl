"""ClauDEX dispatch contract — stage → required subagent_type mapping.

@decision DEC-CLAUDEX-DISPATCH-CONTRACT-001
Title: runtime/core/dispatch_contract.py owns the stage → Agent-tool
  subagent_type mapping used by the contract injection path.
Status: accepted (extracted from authority_registry.py to unblock the
  guardian-landing / canonical-stage checkpoint bundle without dragging
  contract-dispatch authority into the capability registry)
Rationale: ``authority_registry.py`` owns the capability vocabulary, the
  stage → capability mapping, the operational-fact table, and the capability
  contracts. Those are claims about what a stage may do.

  The stage → ``subagent_type`` mapping is a different concern: it is the
  runtime contract for which ``tool_input.subagent_type`` value the Agent
  launch MUST carry so the dispatch-contract path (``agent_contract_required``
  policy + ``agent_prompt`` producer) can enforce a canonical launch shape.
  Keeping those two concerns in separate modules prevents the capability
  registry from accruing dispatch-surface drift and keeps each authority
  single-purpose:

    * authority_registry  →  capability model
    * dispatch_contract   →  Agent-tool launch contract

  The only shared dependency is ``_LIVE_ROLE_ALIASES`` from
  ``authority_registry`` (so harness-emitted role strings like ``"Plan"``
  resolve consistently). Importing that symbol does not create a cycle —
  authority_registry does not import dispatch_contract.

  Invariants this module owns (enforced by targeted tests, not narrated):
    1. STAGE_SUBAGENT_TYPES keys are exactly the active stages from
       ``stage_registry``; no stage is missing and no unknown stage is
       present.
    2. Guardian modes (``guardian:provision`` / ``guardian:land``) both map
       to the ``"guardian"`` subagent_type — the Agent tool does not carry
       the provision/land distinction; that distinction lives on the policy
       side via canonicalization.
    3. ``dispatch_subagent_type_for_stage`` returns ``None`` for unknown
       stages, sinks, and empty input — fail-closed.
    4. Harness-level aliases (``_SUBAGENT_TYPE_ALIASES``) are applied after
       the canonical stage lookup so downstream adapters see the live
       subagent_type string the harness actually emits.
"""

from __future__ import annotations

from typing import Mapping, Optional

from runtime.core import stage_registry as sr
from runtime.core.authority_registry import _LIVE_ROLE_ALIASES

# ---------------------------------------------------------------------------
# Stage → required subagent_type mapping
#
# A contract stage_id deterministically maps to the only valid
# tool_input.subagent_type for that Agent-tool launch. Guardian provision
# and land modes both use the bare "guardian" subagent_type — the live
# harness does not distinguish them at the Agent tool surface; that
# distinction is resolved on the policy side via canonical_actor_stage.
# ---------------------------------------------------------------------------

STAGE_SUBAGENT_TYPES: Mapping[str, str] = {
    sr.PLANNER: "planner",
    sr.GUARDIAN_PROVISION: "guardian",
    sr.IMPLEMENTER: "implementer",
    sr.REVIEWER: "reviewer",
    sr.GUARDIAN_LAND: "guardian",
}

# Harness subagent-type aliases. The live harness emits the capitalised
# "Plan" variant for planner launches; this mapping lets the policy enforce
# against the exact string the harness will produce.
_SUBAGENT_TYPE_ALIASES: Mapping[str, str] = {
    "Plan": "planner",
}


def dispatch_subagent_type_for_stage(stage: str) -> Optional[str]:
    """Return the required Agent-tool subagent_type for ``stage``.

    Resolves stage aliases via ``authority_registry._LIVE_ROLE_ALIASES``
    before lookup and returns ``None`` for unknown stages/sinks
    (fail-closed). The returned value is the string the policy engine
    expects the Agent-tool ``tool_input.subagent_type`` field to carry.
    """
    if not stage:
        return None
    canonical_stage = stage
    if canonical_stage not in STAGE_SUBAGENT_TYPES:
        canonical_stage = _LIVE_ROLE_ALIASES.get(stage, "")
    if not canonical_stage:
        return None
    required = STAGE_SUBAGENT_TYPES.get(canonical_stage)
    if required is None:
        return None
    return _SUBAGENT_TYPE_ALIASES.get(required, required)


__all__ = [
    "STAGE_SUBAGENT_TYPES",
    "dispatch_subagent_type_for_stage",
]
