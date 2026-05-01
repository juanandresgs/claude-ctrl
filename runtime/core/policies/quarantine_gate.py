"""quarantine_gate — mechanically block untrusted spawned agents.

SubagentStart cannot always prevent the harness from creating an agent process.
When start-time contract validation fails, the runtime records a quarantined
dispatch attempt. This policy is the mechanical enforcement point at the next
PreToolUse boundary.
"""

from __future__ import annotations

from typing import Optional

from runtime.core.policy_engine import PolicyDecision, PolicyRequest


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    attempt = request.context.quarantined_attempt
    if not attempt:
        return None
    reason = str(attempt.get("failure_reason") or "runtime dispatch contract failed")
    return PolicyDecision(
        action="deny",
        reason=(
            "BLOCKED: this agent is quarantined by the runtime dispatch ledger "
            f"({reason}). Relaunch through the canonical Agent dispatch path."
        ),
        policy_name="quarantine_gate",
        metadata={
            "reason_code": "dispatch_attempt_quarantined",
            "attempt_id": attempt.get("attempt_id"),
            "failure_reason": reason,
        },
    )


def register(registry) -> None:
    registry.register(
        "quarantine_gate",
        check,
        event_types=["PreToolUse", "Bash", "Write", "Edit"],
        priority=25,
    )
