"""plan_guard policy — only stages with CAN_WRITE_GOVERNANCE may write governance markdown
or constitution-level files.

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

@decision DEC-PE-W2-CAP-002
Title: plan_guard uses CAN_WRITE_GOVERNANCE capability gate (Phase 3 migration)
Status: accepted
Rationale: Raw role-name checks ("planner", "Plan") were a dual-string check
  in this policy. The "Plan" alias (capitalized, seen in live SubagentStart
  payloads) is now resolved in authority_registry._LIVE_ROLE_ALIASES so the
  alias mapping lives in one place. context.capabilities carries the resolved
  frozenset so this policy remains a pure function.

@decision DEC-PE-W2-CONSTITUTION-001
Title: plan_guard gates constitution-level files via constitution_registry
Status: accepted
Rationale: Phase 7 Slice 6 extends plan_guard to deny writes to any file
  declared concrete in constitution_registry.CONCRETE_PATHS, unless the actor
  holds CAN_WRITE_GOVERNANCE or CLAUDE_PLAN_MIGRATION=1 is set. The registry
  is the sole authority for the file set — no hardcoded list in the policy.
  Governance-markdown classification remains the first check; constitution-
  level classification fires second for non-markdown files that are still
  constitution-scoped (e.g. runtime/cli.py, runtime/core/stage_registry.py).
"""

from __future__ import annotations

import os
from typing import Optional

from runtime.core.authority_registry import CAN_WRITE_GOVERNANCE
from runtime.core.constitution_registry import is_constitution_level, normalize_repo_path
from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import is_governance_markdown


def _to_repo_relative(file_path: str, project_root: str | None) -> str | None:
    """Convert an absolute file_path to a repo-relative POSIX path.

    If *file_path* is already relative, normalise it directly.
    Returns ``None`` when the path cannot be made repo-relative.
    """
    if project_root and file_path.startswith(project_root):
        # Strip the root prefix and any trailing separator.
        rel = file_path[len(project_root):].lstrip(os.sep).lstrip("/")
        return normalize_repo_path(rel)
    # Already relative or no project_root — try normalising as-is.
    return normalize_repo_path(file_path)


def plan_guard(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny writes to governance markdown or constitution-level files from
    any actor lacking CAN_WRITE_GOVERNANCE.

    Skip conditions (return None):
      - No file_path in tool_input
      - File is under {project_root}/.claude/ (meta-infrastructure)
      - File is neither governance markdown nor constitution-level
      - CLAUDE_PLAN_MIGRATION env var is "1" (explicit override)
      - actor has CAN_WRITE_GOVERNANCE capability
    """
    file_path: str = request.tool_input.get("file_path", "")
    if not file_path:
        return None

    # Skip meta-infrastructure
    project_root = request.context.project_root
    if project_root and file_path.startswith(os.path.join(project_root, ".claude") + os.sep):
        return None

    # Classify: governance markdown or constitution-level file?
    is_gov = is_governance_markdown(file_path)
    is_const = False
    if not is_gov:
        repo_rel = _to_repo_relative(file_path, project_root)
        if repo_rel is not None:
            is_const = is_constitution_level(repo_rel)

    if not is_gov and not is_const:
        return None

    # CLAUDE_PLAN_MIGRATION=1 is the explicit override for bootstrap migrations
    if os.environ.get("CLAUDE_PLAN_MIGRATION", "") == "1":
        return None

    if CAN_WRITE_GOVERNANCE in request.context.capabilities:
        return None  # Authorized

    role = request.context.actor_role or ""
    deny_role = role if role else "orchestrator"

    if is_const:
        return PolicyDecision(
            action="deny",
            reason=(
                f"BLOCKED: {deny_role} cannot write constitution-level file "
                f"({file_path}). Only actors with CAN_WRITE_GOVERNANCE may "
                "modify constitution-scoped files.\n\n"
                "Action: Dispatch a planner agent for this change, or set "
                "CLAUDE_PLAN_MIGRATION=1 for bootstrap migrations."
            ),
            policy_name="plan_guard",
        )

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
