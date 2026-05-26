"""Policy: deny harness-managed worktree creation/entry outside Guardian provision.

Bash `git worktree add` is governed by bash_worktree_creation. Claude harness
events such as WorktreeCreate, EnterWorktree, and Agent isolation worktrees need
their own policy surface because they can bypass Bash hooks entirely.
"""

from __future__ import annotations

from typing import Optional

from runtime.core.policy_engine import PolicyDecision, PolicyRequest


_DENY_REASON = (
    "Harness-managed worktree creation/entry bypasses Guardian worktree authority. "
    "Use the v6 capability sequence: planner -> guardian(provision) -> "
    "implementer. Guardian must create worktrees with cc-policy worktree "
    "provision so the runtime records the worktree, workflow binding, scope, "
    "and leases; implementer is launched afterward as an ordinary Agent with "
    "no isolation flag."
)


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    event = request.event_type or ""
    tool = request.tool_name or ""
    isolation = ""
    if isinstance(request.tool_input, dict):
        isolation = str(request.tool_input.get("isolation") or "")

    if event in {"WorktreeCreate", "EnterWorktree"}:
        return PolicyDecision(
            action="deny",
            reason=_DENY_REASON,
            policy_name="worktree_harness_guard",
        )

    if tool in {"WorktreeCreate", "EnterWorktree"}:
        return PolicyDecision(
            action="deny",
            reason=_DENY_REASON,
            policy_name="worktree_harness_guard",
        )

    if tool in {"Agent", "Task"} and isolation == "worktree":
        return PolicyDecision(
            action="deny",
            reason=_DENY_REASON,
            policy_name="worktree_harness_guard",
        )

    return None


def register(registry) -> None:
    registry.register(
        "worktree_harness_guard",
        check,
        event_types=["PreToolUse", "WorktreeCreate", "EnterWorktree"],
        priority=340,
    )
