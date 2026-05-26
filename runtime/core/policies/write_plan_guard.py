"""plan_guard policy — governance markdown write-role boundary.

Mirrors: hooks/plan-guard.sh (114 lines)

@decision DEC-PE-W2-004
Title: plan_guard allows only planning and guarded non-source authorities
Status: accepted
Rationale: v6 keeps implementer/tester/critic/reviewer away from governance
  markdown. Planner remains the primary authority, while root/orchestrator and
  Guardian may perform guarded docs/config fast-path maintenance. Permanent
  MASTER_PLAN sections remain protected by plan_immutability.
"""

from __future__ import annotations

import os
from typing import Optional

from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import is_governance_markdown


def plan_guard(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny governance markdown writes from roles outside the docs fast path.

    Skip conditions (return None):
      - No file_path in tool_input
      - File is under {project_root}/.claude/ (meta-infrastructure)
      - File is not governance markdown
      - CLAUDE_PLAN_MIGRATION env var is "1" (explicit override)
      - actor_role is root/orchestrator, "planner"/"Plan", or "guardian"
    """
    file_path: str = request.tool_input.get("file_path", "")
    if not file_path:
        return None

    # Skip meta-infrastructure
    project_root = request.context.project_root
    if project_root and file_path.startswith(os.path.join(project_root, ".claude") + os.sep):
        return None

    # Only fires for governance markdown
    if not is_governance_markdown(file_path):
        return None

    # CLAUDE_PLAN_MIGRATION=1 is the explicit override for bootstrap migrations
    if os.environ.get("CLAUDE_PLAN_MIGRATION", "") == "1":
        return None

    role = request.context.actor_role or ""

    if role in ("", "root", "orchestrator", "planner", "Plan", "guardian"):
        return None  # Authorized

    deny_role = role if role else "orchestrator"

    return PolicyDecision(
        action="deny",
        reason=(
            f"BLOCKED: {deny_role} cannot write governance markdown ({file_path}). "
            "Only planner, Guardian, or the root docs/config fast path may modify "
            "governance files.\n\n"
            "Action: Dispatch planner/Guardian for this change, or set "
            "CLAUDE_PLAN_MIGRATION=1 for explicit permanent-section migrations."
        ),
        policy_name="plan_guard",
    )
