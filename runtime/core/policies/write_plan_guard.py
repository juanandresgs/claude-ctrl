"""plan_guard policy — only the planner role may write governance markdown.

Mirrors: hooks/plan-guard.sh (114 lines)

@decision DEC-PE-W2-004
Title: plan_guard is a pure Python port of plan-guard.sh (DEC-FORK-014)
Status: accepted
Rationale: plan-guard.sh restricts governance markdown writes to the planner
  role. This Python port preserves identical semantics: classify the file via
  is_governance_markdown(), honour the CLAUDE_PLAN_MIGRATION=1 escape hatch,
  read the role from context.actor_role, and deny all non-planner roles.
  Priority 300 places this after source-file WHO checks (branch_guard=100,
  write_who=200, enforcement_gap=250) so planner WHO enforcement only fires
  when the earlier source-file gates have passed or returned None (governance
  markdown is not a source file, so branch_guard and write_who skip it).
"""

from __future__ import annotations

import os
from typing import Optional

from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import is_governance_markdown


def plan_guard(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny governance markdown writes from any role other than 'planner'/'Plan'.

    Skip conditions (return None):
      - No file_path in tool_input
      - File is under {project_root}/.claude/ (meta-infrastructure)
      - File is not governance markdown
      - CLAUDE_PLAN_MIGRATION env var is "1" (explicit override)
      - actor_role is "planner" or "Plan"
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

    if role in ("planner", "Plan"):
        return None  # Authorized

    deny_role = role if role else "orchestrator"

    return PolicyDecision(
        action="deny",
        reason=(
            f"BLOCKED: {deny_role} cannot write governance markdown ({file_path}). "
            "Only the planner agent may modify plan and governance files.\n\n"
            "Action: Dispatch a planner agent for this change, or set "
            "CLAUDE_PLAN_MIGRATION=1 for permanent-section migrations."
        ),
        policy_name="plan_guard",
    )
