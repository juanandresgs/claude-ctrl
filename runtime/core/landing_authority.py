"""Guardian landing authority and phase classification.

This module owns the runtime interpretation of Guardian landing scopes. Policy
modules may ask it whether a command is the feature-worktree commit, the
governance-only base sidecar, or the reviewed-feature merge. Hooks and shell
adapters must not duplicate these distinctions.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Literal

from runtime.core.authority_registry import CAN_LAND_GIT, CAN_WRITE_SOURCE
from runtime.core.config import _resolve_shared_git_root
from runtime.core.policy_utils import is_governance_repo_path, normalize_path

LandingOperation = Literal[
    "not_landing",
    "feature_commit",
    "governance_record",
    "merge_reviewed_feature",
]

LANDING_READY = "ready_for_guardian"
FEATURE_COMMIT_LANDED = "feature_commit_landed"
GOVERNANCE_RECORD_LANDED = "governance_record_landed"
MERGE_LANDED = "merge_landed"
CLEANUP_COMPLETE = "cleanup_complete"


@dataclass(frozen=True)
class LandingScope:
    """Structured classification of one landing command."""

    operation: LandingOperation
    target_dir: str
    lease_worktree: str
    shared_base: str
    path_class: str
    paths: tuple[str, ...]

    @property
    def is_landing(self) -> bool:
        return self.operation != "not_landing"


def _context_lease(context: Any) -> dict:
    lease = getattr(context, "lease", None) or {}
    return lease if isinstance(lease, dict) else {}


def _context_capabilities(context: Any) -> set[str]:
    return set(getattr(context, "capabilities", frozenset()) or frozenset())


def _shared_git_root(path: str) -> str:
    if not path:
        return ""
    try:
        root = _resolve_shared_git_root(Path(path))
    except Exception:
        root = None
    return normalize_path(str(root)) if root is not None else ""


def has_guardian_landing_capability(context: Any) -> bool:
    """Return True when the current actor has the runtime landing capability."""
    lease = _context_lease(context)
    return (
        CAN_LAND_GIT in _context_capabilities(context)
        and (lease.get("role") or "") == "guardian"
    )


def _context_landing_grant(context: Any) -> dict:
    grant = getattr(context, "landing_grant", None) or {}
    return grant if isinstance(grant, dict) else {}


def has_branch_commit_grant(context: Any) -> bool:
    """Return True when the work-item grant allows source-branch commits."""
    grant = _context_landing_grant(context)
    if not grant:
        return False
    return bool(grant.get("can_commit_branch"))


def is_branch_checkpoint_commit(context: Any, target_dir: str) -> bool:
    """Return True for an implementer checkpoint commit inside its worktree.

    Branch commits are rollback/checkpoint artifacts, not integration
    boundaries. They are allowed only for can_write_source actors, only on the
    lease worktree, and only when the work-item grant allows them.
    """
    if CAN_WRITE_SOURCE not in _context_capabilities(context):
        return False
    if not has_branch_commit_grant(context):
        return False
    lease_worktree = normalize_path(_context_lease(context).get("worktree_path", "") or "")
    target = normalize_path(target_dir or "")
    if not lease_worktree or not target or lease_worktree != target:
        return False
    branch = str(getattr(context, "branch", "") or "")
    if branch in {"main", "master"}:
        return False
    return True


def is_guardian_land_shared_base_target(context: Any, target_dir: str) -> bool:
    """Return True for the base-worktree side of a Guardian landing."""
    if not has_guardian_landing_capability(context):
        return False

    lease_worktree = normalize_path(_context_lease(context).get("worktree_path", "") or "")
    target = normalize_path(target_dir or "")
    if not lease_worktree or not target or lease_worktree == target:
        return False
    return _shared_git_root(lease_worktree) == target


def paths_are_governance_only(paths: Iterable[str]) -> bool:
    """Return True when every path is a canonical governance path."""
    path_list = [path for path in paths if path]
    if not path_list:
        return False
    return all(is_governance_repo_path(path) for path in path_list)


def classify_paths(paths: Iterable[str]) -> str:
    """Classify a command's path set for landing-policy decisions."""
    path_tuple = tuple(path for path in paths if path)
    if not path_tuple:
        return "empty"
    if paths_are_governance_only(path_tuple):
        return "governance_only"
    return "non_governance"


def classify_landing_scope(
    context: Any,
    *,
    subcommand: str,
    target_dir: str,
    paths: Iterable[str] = (),
) -> LandingScope:
    """Classify a git landing operation against its lease and target scope."""
    target = normalize_path(target_dir or "")
    lease = _context_lease(context)
    lease_worktree = normalize_path(lease.get("worktree_path", "") or "")
    shared_base = _shared_git_root(lease_worktree)
    path_tuple = tuple(path for path in paths if path)
    path_class = classify_paths(path_tuple)

    operation: LandingOperation = "not_landing"
    if has_guardian_landing_capability(context):
        if subcommand == "commit" and target and target == lease_worktree:
            operation = "feature_commit"
        elif (
            subcommand == "commit"
            and target
            and target == shared_base
            and target != lease_worktree
            and path_class == "governance_only"
        ):
            operation = "governance_record"
        elif (
            subcommand == "merge"
            and target
            and target == shared_base
            and target != lease_worktree
        ):
            operation = "merge_reviewed_feature"

    return LandingScope(
        operation=operation,
        target_dir=target,
        lease_worktree=lease_worktree,
        shared_base=shared_base,
        path_class=path_class,
        paths=path_tuple,
    )


def phase_for_operation(operation: LandingOperation) -> str:
    """Return the landing phase reached by a successful operation."""
    if operation == "feature_commit":
        return FEATURE_COMMIT_LANDED
    if operation == "governance_record":
        return GOVERNANCE_RECORD_LANDED
    if operation == "merge_reviewed_feature":
        return MERGE_LANDED
    return LANDING_READY
