"""plan_guard policy — CAN_WRITE_GOVERNANCE + workflow_scope.forbidden_paths gate

@decision DEC-CLAUDEX-WRITE-PLAN-GUARD-FORBIDDEN-PATHS-005
Title: plan_guard consults workflow_scope.forbidden_paths before capability check (Slice A4 → A12 composition)
Status: accepted
Rationale: Slice A4 on the A-branch added a scope-forbidden-path gate to plan_guard.
  A12 composes that gate into current soak HEAD (which has Phase-7-Slice-6
  constitution-level refinements A-branch lacked). Closes the class-of-defect
  where a planner (CAN_WRITE_GOVERNANCE) could write to MASTER_PLAN.md despite
  it being in the active workflow's forbidden_paths. New check consults
  request.context.scope.forbidden_paths via fnmatch glob match (parity with
  bash_workflow_scope._check_compliance) and denies with stable reason-code
  substring `scope_forbidden_path_write` regardless of role capability.
  Ordering preserved: CLAUDE_PLAN_MIGRATION=1 bootstrap override fires first
  (documented higher-order escape hatch); scope-forbidden then fires before
  CAN_WRITE_GOVERNANCE so denial is role-absolute. Malformed forbidden_paths
  JSON → empty list. Priority unchanged (300). Registration unchanged.
Refs DEC-PE-W2-CAP-002 (existing CAN_WRITE_GOVERNANCE gate)
     DEC-FORK-014 (plan-guard.sh origin)

Legacy docstring header:

plan_guard policy — only stages with CAN_WRITE_GOVERNANCE may write governance markdown
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

import fnmatch
import os
from typing import Optional

from runtime.core.authority_registry import CAN_WRITE_GOVERNANCE
from runtime.core.constitution_registry import is_constitution_level, normalize_repo_path
from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import (
    PATH_KIND_CONSTITUTION,
    PATH_KIND_GOVERNANCE,
    classify_policy_path,
    parse_scope_list,
)

# Module-level alias preserves the legacy import surface for existing tests:
#   from runtime.core.policies.write_plan_guard import _parse_scope_list
# Identity: _parse_scope_list is policy_utils.parse_scope_list (verified by
# tests/runtime/policies/test_scope_parser_single_authority.py).
# @decision DEC-DISCIPLINE-SCOPE-PARSER-SINGLE-AUTH-001
_parse_scope_list = parse_scope_list


def _strip_worktree_prefix(path: str) -> str:
    normalized = path.replace("\\", "/").lstrip("/")
    parts = normalized.split("/")
    if len(parts) >= 3 and parts[0] == ".worktrees":
        return "/".join(parts[2:])
    return normalized


def _to_repo_relative(
    file_path: str, project_root: str | None, worktree_path: str | None
) -> str | None:
    """Convert an absolute file_path to a repo-relative POSIX path.

    If *file_path* is already relative, normalise it directly.
    Returns ``None`` when the path cannot be made repo-relative.
    """
    if worktree_path and file_path.startswith(worktree_path + os.sep):
        rel = file_path[len(worktree_path):].lstrip(os.sep).lstrip("/")
        return normalize_repo_path(rel)
    if project_root and file_path.startswith(project_root + os.sep):
        # Strip the root prefix and any trailing separator.
        rel = file_path[len(project_root):].lstrip(os.sep).lstrip("/")
        return normalize_repo_path(_strip_worktree_prefix(rel))
    # Already relative or no project_root — try normalising as-is.
    return normalize_repo_path(_strip_worktree_prefix(file_path))


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

    info = classify_policy_path(
        file_path,
        project_root=project_root or "",
        worktree_path=request.context.worktree_path or "",
        scratch_roots=request.context.scratchlane_roots,
    )
    is_gov = info.kind == PATH_KIND_GOVERNANCE
    is_const = info.kind == PATH_KIND_CONSTITUTION
    repo_rel = info.repo_relative_path

    if not is_gov and not is_const:
        return None

    # CLAUDE_PLAN_MIGRATION=1 is the explicit override for bootstrap migrations
    if os.environ.get("CLAUDE_PLAN_MIGRATION", "") == "1":
        return None

    # A4/A12: consult workflow_scope.forbidden_paths BEFORE the capability
    # check so scope-forbidden denial is role-absolute (neither planner nor
    # implementer CAN_WRITE_GOVERNANCE may bypass). Fires for governance or
    # constitution-level files whose path matches a forbidden-glob entry.
    # @decision DEC-CLAUDEX-WRITE-PLAN-GUARD-FORBIDDEN-PATHS-005 (Slice A4 → A12)
    scope = getattr(request.context, "scope", None) or {}
    if isinstance(scope, dict):
        forbidden = _parse_scope_list(scope.get("forbidden_paths"))
        if forbidden:
            # Prefer repo-relative for fnmatch match; fall back to file_path
            repo_rel_for_match: Optional[str]
            if is_gov:
                repo_rel_for_match = repo_rel
            else:
                repo_rel_for_match = repo_rel  # set in is_const branch above
            target = repo_rel_for_match or file_path
            for pattern in forbidden:
                if fnmatch.fnmatch(target, pattern):
                    workflow_id = scope.get("workflow_id", "<unknown>")
                    return PolicyDecision(
                        action="deny",
                        reason=(
                            f"BLOCKED: scope_forbidden_path_write: {file_path} "
                            f"matches forbidden pattern {pattern!r} for workflow "
                            f"{workflow_id!r}. Only a re-scoped or newly-approved "
                            f"workflow may write this file."
                        ),
                        policy_name="plan_guard",
                    )

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
