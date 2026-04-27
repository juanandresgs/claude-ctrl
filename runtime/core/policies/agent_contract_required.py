"""Policy: agent_contract_required — enforce canonical contract-bearing Agent launches.

Dispatch-significant subagent types (planner, implementer, guardian, reviewer,
Plan) MUST carry a CLAUDEX_CONTRACT_BLOCK: line at the start of their prompt.
That block is produced by ``cc-policy dispatch agent-prompt`` and carries the
six contract fields that pre-agent.sh extracts for the carrier path
(DEC-CLAUDEX-SA-CARRIER-001).

Non-canonical subagent types (Explore, general-purpose, statusline-setup, empty,
and any unknown value) pass through without a contract requirement only when they
are *not* attempting to carry a runtime dispatch contract.

@decision DEC-CLAUDEX-AGENT-CONTRACT-REQUIRED-AUTHORITY-SOAK-001
@title Retire DISPATCH_SIGNIFICANT/LIGHTWEIGHT frozensets; route through authority_registry
@status accepted
@rationale A6 soak-parity slice. Mirrors the A1 pattern already applied on the
  A-branch: instead of a module-level frozen set that must be kept in sync with
  authority_registry.CANONICAL_DISPATCH_SUBAGENT_TYPES, we call
  authority_registry.canonical_dispatch_subagent_type(subagent_type) at call
  time. A non-None return means the type is dispatch-significant; None means
  pass-through. Single authority for dispatch-seat classification per
  DEC-CLAUDEX-SA-CARRIER-001.

@decision DEC-CLAUDEX-AGENT-CONTRACT-AUTHENTICITY-A8-001
@title Six-field shape validation for contract-bearing launches (A8 authenticity)
@status accepted
@rationale A8 soak slice. Closes the bypass where a canonical seat could launch
  with a forged/partial CLAUDEX_CONTRACT_BLOCK that omits required fields beyond
  stage_id, causing the carrier write to write a partial row and subagent-start.sh
  to silently fall back to the legacy guidance path. Shape-check order (after JSON
  parse + is-dict check):
    1. workflow_id present + str + non-empty after strip
    2. stage_id present + str + non-empty after strip (then existing active-stage check)
    3. goal_id present + str + non-empty after strip
    4. work_item_id present + str + non-empty after strip
    5. decision_scope present + str + non-empty after strip
    6. generated_at present + int (or int-coercible str) + >0
    7. stage_id in ACTIVE_STAGES check (existing)
    8. subagent_type presence + mismatch check (existing)
  Stable reason-code substrings (used by tests):
    contract_block_missing_workflow_id, contract_block_empty_workflow_id,
    contract_block_missing_goal_id, contract_block_missing_work_item_id,
    contract_block_missing_decision_scope, contract_block_missing_generated_at,
    contract_block_invalid_generated_at
  Previously stable reason-code substrings (unchanged):
    contract_block_malformed_json, contract_block_missing_stage,
    contract_block_unknown_stage, contract_block_missing_subagent_type,
    contract_block_stage_subagent_type_mismatch
"""

from __future__ import annotations

import json
from typing import Optional

import runtime.core.authority_registry as authority_registry
from runtime.core.dispatch_contract import dispatch_subagent_type_for_stage
from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.stage_packet import dispatch_bootstrap_guidance

_CONTRACT_PREFIX = "CLAUDEX_CONTRACT_BLOCK:"


def _repair_hint(stage_id: str | None = None) -> str:
    return dispatch_bootstrap_guidance(stage_id)


def _validate_contract_shape(contract: dict) -> Optional[PolicyDecision]:
    """Validate all six required contract fields are present and well-formed.

    Returns a deny PolicyDecision if any field fails validation, None if all pass.
    Shape-check order matches the A8 spec (DEC-CLAUDEX-AGENT-CONTRACT-AUTHENTICITY-A8-001).
    """
    # 1. workflow_id: must be present, string, non-empty after strip
    if "workflow_id" not in contract:
        return PolicyDecision(
            action="deny",
            reason=(
                "CLAUDEX_CONTRACT_BLOCK is missing required field workflow_id "
                "(contract_block_missing_workflow_id). "
                + _repair_hint()
            ),
            policy_name="agent_contract_required",
        )
    raw_wf = contract["workflow_id"]
    if not isinstance(raw_wf, str) or not raw_wf.strip():
        return PolicyDecision(
            action="deny",
            reason=(
                "CLAUDEX_CONTRACT_BLOCK has empty or non-string workflow_id "
                "(contract_block_empty_workflow_id). "
                + _repair_hint()
            ),
            policy_name="agent_contract_required",
        )

    # 2. stage_id: must be present, string, non-empty after strip (active-stage check done below)
    # (missing stage_id is handled here; empty stage_id causes unknown-stage deny later)
    if "stage_id" not in contract:
        return PolicyDecision(
            action="deny",
            reason=(
                "CLAUDEX_CONTRACT_BLOCK is missing stage_id "
                "(contract_block_missing_stage). "
                + _repair_hint()
            ),
            policy_name="agent_contract_required",
        )

    # 3. goal_id: must be present, string, non-empty after strip
    if "goal_id" not in contract:
        return PolicyDecision(
            action="deny",
            reason=(
                "CLAUDEX_CONTRACT_BLOCK is missing required field goal_id "
                "(contract_block_missing_goal_id). "
                + _repair_hint()
            ),
            policy_name="agent_contract_required",
        )
    raw_goal = contract["goal_id"]
    if not isinstance(raw_goal, str) or not raw_goal.strip():
        return PolicyDecision(
            action="deny",
            reason=(
                "CLAUDEX_CONTRACT_BLOCK has empty or non-string goal_id "
                "(contract_block_missing_goal_id). "
                + _repair_hint()
            ),
            policy_name="agent_contract_required",
        )

    # 4. work_item_id: must be present, string, non-empty after strip
    if "work_item_id" not in contract:
        return PolicyDecision(
            action="deny",
            reason=(
                "CLAUDEX_CONTRACT_BLOCK is missing required field work_item_id "
                "(contract_block_missing_work_item_id). "
                + _repair_hint()
            ),
            policy_name="agent_contract_required",
        )
    raw_wi = contract["work_item_id"]
    if not isinstance(raw_wi, str) or not raw_wi.strip():
        return PolicyDecision(
            action="deny",
            reason=(
                "CLAUDEX_CONTRACT_BLOCK has empty or non-string work_item_id "
                "(contract_block_missing_work_item_id). "
                + _repair_hint()
            ),
            policy_name="agent_contract_required",
        )

    # 5. decision_scope: must be present, string, non-empty after strip
    if "decision_scope" not in contract:
        return PolicyDecision(
            action="deny",
            reason=(
                "CLAUDEX_CONTRACT_BLOCK is missing required field decision_scope "
                "(contract_block_missing_decision_scope). "
                + _repair_hint()
            ),
            policy_name="agent_contract_required",
        )
    raw_ds = contract["decision_scope"]
    if not isinstance(raw_ds, str) or not raw_ds.strip():
        return PolicyDecision(
            action="deny",
            reason=(
                "CLAUDEX_CONTRACT_BLOCK has empty or non-string decision_scope "
                "(contract_block_missing_decision_scope). "
                + _repair_hint()
            ),
            policy_name="agent_contract_required",
        )

    # 6. generated_at: must be present + int (or int-coercible from str) + >0
    # Booleans are excluded: isinstance(True, int) is True in Python, but bool
    # values must not be accepted as generated_at timestamps.
    if "generated_at" not in contract:
        return PolicyDecision(
            action="deny",
            reason=(
                "CLAUDEX_CONTRACT_BLOCK is missing required field generated_at "
                "(contract_block_missing_generated_at). "
                + _repair_hint()
            ),
            policy_name="agent_contract_required",
        )
    raw_ga = contract["generated_at"]
    ga_int: Optional[int] = None
    if isinstance(raw_ga, bool):
        pass  # booleans explicitly rejected below
    elif isinstance(raw_ga, int):
        ga_int = raw_ga
    elif isinstance(raw_ga, str):
        try:
            ga_int = int(raw_ga)
        except (ValueError, TypeError):
            pass
    if ga_int is None or ga_int <= 0:
        return PolicyDecision(
            action="deny",
            reason=(
                f"CLAUDEX_CONTRACT_BLOCK has invalid generated_at={raw_ga!r} "
                "(contract_block_invalid_generated_at). Must be a positive integer "
                "Unix timestamp. "
                + _repair_hint()
            ),
            policy_name="agent_contract_required",
        )

    return None  # all shape checks passed


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny malformed or non-canonical contract-bearing Agent/Task launches."""
    if request.tool_name not in ("Agent", "Task"):
        return None

    tool_input = request.tool_input if isinstance(request.tool_input, dict) else {}
    subagent_type = (tool_input.get("subagent_type") or "").strip()
    prompt = tool_input.get("prompt", "") or ""
    first_line = prompt.split("\n", 1)[0] if prompt else ""
    has_contract = first_line.startswith(_CONTRACT_PREFIX)

    if has_contract:
        contract_raw = first_line[len(_CONTRACT_PREFIX):]
        try:
            contract = json.loads(contract_raw)
        except json.JSONDecodeError:
            return PolicyDecision(
                action="deny",
                reason=(
                    "Dispatch-significant Agent launch carries an invalid "
                    "CLAUDEX_CONTRACT_BLOCK payload (contract_block_malformed_json). "
                    + _repair_hint()
                ),
                policy_name="agent_contract_required",
            )

        if not isinstance(contract, dict):
            return PolicyDecision(
                action="deny",
                reason=(
                    "CLAUDEX_CONTRACT_BLOCK JSON payload must be an object "
                    "(contract_block_malformed_json). "
                    + _repair_hint()
                ),
                policy_name="agent_contract_required",
            )

        # A8: six-field shape validation before stage/subagent_type checks.
        shape_deny = _validate_contract_shape(contract)
        if shape_deny is not None:
            return shape_deny

        stage_id = (contract.get("stage_id") or "").strip()
        expected_subagent_type = dispatch_subagent_type_for_stage(stage_id)
        if not expected_subagent_type:
            return PolicyDecision(
                action="deny",
                reason=(
                    f"Dispatch contract names unknown stage_id={stage_id!r} "
                    "(contract_block_unknown_stage). "
                    + _repair_hint(stage_id)
                ),
                policy_name="agent_contract_required",
            )
        if not subagent_type:
            return PolicyDecision(
                action="deny",
                reason=(
                    f"Dispatch contract for stage_id={stage_id!r} omitted "
                    "tool_input.subagent_type "
                    "(contract_block_missing_subagent_type). "
                    + _repair_hint(stage_id)
                ),
                policy_name="agent_contract_required",
            )
        if subagent_type != expected_subagent_type:
            return PolicyDecision(
                action="deny",
                reason=(
                    f"Dispatch contract for stage_id={stage_id!r} must launch "
                    f"with subagent_type={expected_subagent_type!r}, not "
                    f"{subagent_type!r} "
                    f"(contract_block_stage_subagent_type_mismatch). "
                    + _repair_hint(stage_id)
                ),
                policy_name="agent_contract_required",
            )
        return None

    # A6: classification resolved via authority_registry at call time.
    if not subagent_type:
        return None
    canonical = authority_registry.canonical_dispatch_subagent_type(subagent_type)
    if not canonical:
        return None  # non-canonical → pass-through
    return PolicyDecision(
        action="deny",
        reason=(
            f"Dispatch-significant Agent launch (subagent_type={subagent_type!r}) "
            f"requires a runtime-issued contract. The prompt must start with "
            f"'{_CONTRACT_PREFIX}' on line 1. "
            + _repair_hint(subagent_type)
        ),
        policy_name="agent_contract_required",
    )


def register(registry) -> None:
    registry.register(
        "agent_contract_required",
        check,
        event_types=["PreToolUse"],
        priority=150,
    )
