"""write_who policy — only stages with CAN_WRITE_SOURCE may write source files.

Mirrors: hooks/write-guard.sh (98 lines)

@decision DEC-PE-W2-002
Title: write_who is a pure Python port of write-guard.sh (DEC-FORK-005)
Status: accepted
Rationale: The original shell hook (write-guard.sh) closed the gap where any
  agent could write source files before the git commit gate triggered. This
  Python port preserves the same semantics: only the implementer role is
  authorized to write source files. Role is read from context.actor_role,
  which build_context() resolves from the active lease, agent_marker, or
  CLI-injected actor_role field. Priority 200 matches the second position in
  the CHECKS list in pre-write.sh (after branch_guard at 100).

@decision DEC-PE-W2-CAP-001
Title: write_who uses CAN_WRITE_SOURCE capability gate (Phase 3 migration)
Status: accepted
Rationale: Raw role-name checks ("implementer") are a policy-scattered
  authority for write authorization. Migrating to capability gates means the
  authority_registry is the single place that declares which stages may write
  source files. New stages or aliases only need to be declared there.
  context.capabilities is populated by build_context() via
  authority_registry.capabilities_for(resolved_role) so this policy remains
  a pure function with no I/O.

@decision DEC-DISCIPLINE-WRITE-SCOPE-FORBIDDEN-001
Title: write_who extends to enforce context.scope.forbidden_paths for CAN_WRITE_SOURCE
  actors; tool-path and git-path forbidden-scope enforcement share the same
  forbidden_paths authority.
Status: accepted
Rationale: Slice 8 extends write_who with a secondary scope check: when the
  actor holds CAN_WRITE_SOURCE (implementer) AND context.scope is seated AND
  the write target matches a forbidden_paths glob, the write is denied with
  reason-code 'scope_forbidden_path_write'. This is a tightening of the
  implementer gate, not a widening of the orchestrator gate. Pattern from
  write_plan_guard.py (DEC-CLAUDEX-WRITE-PLAN-GUARD-FORBIDDEN-PATHS-005):
  fnmatch glob match on repo-relative path against forbidden_paths list.
  Conservative exemption: if context.scope is None (no active workflow scope
  row), skip the new check and preserve prior behavior — protects ad-hoc
  implementer sessions where no scope was seated. Allowed-path matches pass
  implicitly because they are not in forbidden_paths (forbidden is authoritative
  over allowed per workflow_scope contract). Gate is CAN_WRITE_SOURCE so
  orchestrator-initiated writes to allowed docs are not affected beyond the
  existing write_who rules. This policy is the sole enforcement authority for
  tool-write forbidden-path discipline (bash_cross_branch_restore_ban owns the
  git-command path). Integration note: if scope is None, the existing allow/deny
  path is unchanged — no regression for pre-scope sessions.
"""

from __future__ import annotations

import fnmatch
import json
import os
from typing import Optional

from runtime.core.authority_registry import CAN_WRITE_SOURCE
from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import is_skippable_path, is_source_file


# ---------------------------------------------------------------------------
# Scope-forbidden helpers
# ---------------------------------------------------------------------------


def _parse_scope_list(raw: object) -> list[str]:
    """Decode a workflow_scope JSON-TEXT column to list[str].

    Mirrors write_plan_guard._parse_scope_list semantics: list passthrough,
    JSON-string decode, malformed/unknown → []. Fail-open on malformed.
    """
    if isinstance(raw, list):
        return [str(x) for x in raw if isinstance(x, str)]
    if isinstance(raw, str):
        try:
            decoded = json.loads(raw)
            if isinstance(decoded, list):
                return [str(x) for x in decoded if isinstance(x, str)]
        except (ValueError, TypeError):
            pass
    return []


def _strip_worktree_prefix(path: str) -> str:
    """Strip .worktrees/<name>/ prefix if present."""
    normalized = path.replace("\\", "/").lstrip("/")
    parts = normalized.split("/")
    if len(parts) >= 3 and parts[0] == ".worktrees":
        return "/".join(parts[2:])
    return normalized


def _to_repo_relative(
    file_path: str,
    project_root: Optional[str],
    worktree_path: Optional[str],
) -> Optional[str]:
    """Convert an absolute file_path to a repo-relative POSIX path.

    Mirrors write_plan_guard._to_repo_relative exactly for path-resolution
    consistency between the two forbidden-path enforcement surfaces.
    Returns None when the path cannot be made repo-relative.
    """
    if worktree_path and file_path.startswith(worktree_path + os.sep):
        rel = file_path[len(worktree_path):].lstrip(os.sep).lstrip("/")
        return _strip_worktree_prefix(rel) or rel
    if project_root and file_path.startswith(project_root + os.sep):
        rel = file_path[len(project_root):].lstrip(os.sep).lstrip("/")
        return _strip_worktree_prefix(rel)
    # Already relative or no project_root — normalise as-is.
    return _strip_worktree_prefix(file_path) or file_path


def _check_scope_forbidden(
    file_path: str,
    scope: object,
    project_root: Optional[str],
    worktree_path: Optional[str],
) -> Optional[str]:
    """Return the matched forbidden pattern string if file_path is forbidden,
    else None. Called only when scope is not None.

    @decision DEC-DISCIPLINE-WRITE-SCOPE-FORBIDDEN-001 (implementation site)
    """
    if not isinstance(scope, dict):
        return None
    forbidden = _parse_scope_list(scope.get("forbidden_paths", []))
    if not forbidden:
        return None

    repo_rel = _to_repo_relative(file_path, project_root, worktree_path)
    target = repo_rel or file_path

    for pattern in forbidden:
        if fnmatch.fnmatch(target, pattern):
            return pattern
    return None


# ---------------------------------------------------------------------------
# Main policy function
# ---------------------------------------------------------------------------


def write_who(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny source-file writes from any actor lacking CAN_WRITE_SOURCE capability.
    Also deny CAN_WRITE_SOURCE writes to paths in context.scope.forbidden_paths.

    Skip conditions (return None):
      - No file_path in tool_input
      - File is under {project_root}/.claude/ (meta-infrastructure)
      - File is not a source file
      - File is a skippable path

    For CAN_WRITE_SOURCE actors (implementers):
      - If context.scope is not None: check forbidden_paths glob match
        (DEC-DISCIPLINE-WRITE-SCOPE-FORBIDDEN-001). Deny on match.
      - Otherwise: return None (authorized — preserve prior behavior).

    For non-CAN_WRITE_SOURCE actors:
      - Deny with role-label reason (existing behavior, unchanged).
    """
    file_path: str = request.tool_input.get("file_path", "")
    if not file_path:
        return None

    # Skip meta-infrastructure
    project_root = request.context.project_root
    if project_root and file_path.startswith(os.path.join(project_root, ".claude") + os.sep):
        return None

    # WHO enforcement applies only to source files
    if not is_source_file(file_path):
        return None

    # Skip test/config/vendor/generated paths
    if is_skippable_path(file_path):
        return None

    if CAN_WRITE_SOURCE in request.context.capabilities:
        # DEC-DISCIPLINE-WRITE-SCOPE-FORBIDDEN-001: scope-forbidden check for
        # CAN_WRITE_SOURCE actors. Fires before the existing allow-return so
        # forbidden-path denial is authoritative for implementers.
        scope = getattr(request.context, "scope", None)
        if scope is not None:
            matched_pattern = _check_scope_forbidden(
                file_path,
                scope,
                project_root,
                request.context.worktree_path,
            )
            if matched_pattern is not None:
                workflow_id = scope.get("workflow_id", "<unknown>") if isinstance(scope, dict) else "<unknown>"
                return PolicyDecision(
                    action="deny",
                    reason=(
                        f"BLOCKED: scope_forbidden_path_write: {file_path} "
                        f"matches forbidden pattern {matched_pattern!r} for workflow "
                        f"{workflow_id!r}. "
                        f"Implementer is authorized to write source files (CAN_WRITE_SOURCE) "
                        f"but this path is excluded from the active workflow scope. "
                        f"Only a re-scoped or newly-approved workflow may write this file. "
                        f"(write_who, DEC-DISCIPLINE-WRITE-SCOPE-FORBIDDEN-001)"
                    ),
                    policy_name="write_who",
                )
        return None  # Authorized (no scope, or no forbidden match)

    # All other roles: deny
    role = request.context.actor_role or ""
    role_label = role if role else "orchestrator (no active agent)"

    return PolicyDecision(
        action="deny",
        reason=(
            f"BLOCKED: {role_label} cannot write source files. "
            "Only the implementer agent may write source code.\n\n"
            "Action: Dispatch an implementer agent for this change."
        ),
        policy_name="write_who",
    )
