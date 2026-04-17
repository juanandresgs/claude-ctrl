"""Policy: agent_contract_required — enforce canonical contract-bearing Agent launches.

Dispatch-significant subagent types (planner, implementer, guardian, reviewer,
Plan) MUST carry a CLAUDEX_CONTRACT_BLOCK: line at the start of their prompt.
That block is produced by ``cc-policy dispatch agent-prompt`` and carries the
six contract fields that pre-agent.sh extracts for the carrier path
(DEC-CLAUDEX-SA-CARRIER-001).

Lightweight subagent types (Explore, general-purpose, statusline-setup, empty)
pass through without a contract requirement only when they are *not* attempting
to carry a runtime dispatch contract.
"""

from __future__ import annotations

import json
from typing import Optional

from runtime.core.dispatch_contract import dispatch_subagent_type_for_stage
from runtime.core.policy_engine import PolicyDecision, PolicyRequest

DISPATCH_SIGNIFICANT: frozenset[str] = frozenset({
    "planner",
    "implementer",
    "guardian",
    "reviewer",
    "Plan",
})

LIGHTWEIGHT: frozenset[str] = frozenset({
    "Explore",
    "general-purpose",
    "statusline-setup",
    "",
})

_CONTRACT_PREFIX = "CLAUDEX_CONTRACT_BLOCK:"


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
                    "CLAUDEX_CONTRACT_BLOCK payload. Call `cc-policy dispatch "
                    "agent-prompt --workflow-id <id> --stage-id <stage>` and "
                    "prepend the returned `prompt_prefix` verbatim."
                ),
                policy_name="agent_contract_required",
            )

        stage_id = (contract.get("stage_id") or "").strip()
        expected_subagent_type = dispatch_subagent_type_for_stage(stage_id)
        if not expected_subagent_type:
            return PolicyDecision(
                action="deny",
                reason=(
                    f"Dispatch contract names unknown stage_id={stage_id!r}. "
                    "Call `cc-policy dispatch agent-prompt --workflow-id <id> "
                    "--stage-id <stage>` to mint a valid runtime-owned contract."
                ),
                policy_name="agent_contract_required",
            )
        if not subagent_type:
            return PolicyDecision(
                action="deny",
                reason=(
                    f"Dispatch contract for stage_id={stage_id!r} omitted "
                    "tool_input.subagent_type. Call `cc-policy dispatch "
                    "agent-prompt --workflow-id <id> --stage-id <stage>` and "
                    "set subagent_type to the returned required_subagent_type."
                ),
                policy_name="agent_contract_required",
            )
        if subagent_type != expected_subagent_type:
            return PolicyDecision(
                action="deny",
                reason=(
                    f"Dispatch contract for stage_id={stage_id!r} must launch "
                    f"with subagent_type={expected_subagent_type!r}, not "
                    f"{subagent_type!r}. Call `cc-policy dispatch agent-prompt "
                    f"--workflow-id <id> --stage-id {stage_id}` and use the "
                    "returned `required_subagent_type` / `prompt_prefix` verbatim."
                ),
                policy_name="agent_contract_required",
            )
        return None

    if subagent_type in LIGHTWEIGHT or not subagent_type:
        return None

    if subagent_type in DISPATCH_SIGNIFICANT:
        return PolicyDecision(
            action="deny",
            reason=(
                f"Dispatch-significant Agent launch (subagent_type={subagent_type!r}) "
                f"requires a runtime-issued contract. The prompt must start with "
                f"'{_CONTRACT_PREFIX}' on line 1. Call `cc-policy dispatch agent-prompt "
                f"--workflow-id <id> --stage-id <stage>` and prepend the returned "
                f"`prompt_prefix` verbatim to the Agent prompt."
            ),
            policy_name="agent_contract_required",
        )

    return None


def register(registry) -> None:
    registry.register(
        "agent_contract_required",
        check,
        event_types=["PreToolUse"],
        priority=150,
    )
