"""Policy: bash_write_who — capability gate for bash-based file mutations.

Hard-blocks role bypass where source/governance files are modified through the
Bash tool instead of Write/Edit. This closes the "orchestrator did coding/PRD
directly via shell" path by enforcing the same capability boundaries:

  - source files      -> CAN_WRITE_SOURCE (implementer only)
  - governance files  -> CAN_WRITE_GOVERNANCE (planner only)
  - constitution file -> CAN_WRITE_GOVERNANCE (planner only)
"""

from __future__ import annotations

import os
import re
from typing import Optional

from runtime.core.authority_registry import CAN_WRITE_GOVERNANCE, CAN_WRITE_SOURCE
from runtime.core.command_intent import extract_bash_write_targets
from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import (
    PATH_KIND_CONSTITUTION,
    PATH_KIND_GOVERNANCE,
    PATH_KIND_SOURCE,
    classify_policy_path,
    normalize_path,
    resolve_path_from_base,
)

_PATCH_FILE_RE = re.compile(r"(?m)^\*\*\* (?:Add|Update|Delete) File:\s+(.+)$")


def _strip_quotes(token: str) -> str:
    token = token.strip()
    if len(token) >= 2 and token[0] == token[-1] and token[0] in {"'", '"'}:
        return token[1:-1]
    return token


def _strip_diff_prefix(path: str) -> str:
    if path.startswith("a/") or path.startswith("b/"):
        return path[2:]
    return path


def _resolve_target_path(raw_path: str, *, base_dir: str) -> str:
    candidate = _strip_quotes(raw_path).strip()
    if not candidate or candidate in {"-", "/dev/null"}:
        return ""
    if os.path.isabs(candidate):
        return normalize_path(candidate)
    resolved = resolve_path_from_base(base_dir, candidate)
    return normalize_path(resolved) if resolved else ""


def _extract_patch_targets(command: str) -> set[str]:
    targets: set[str] = set()
    for match in _PATCH_FILE_RE.finditer(command):
        raw = _strip_diff_prefix(_strip_quotes(match.group(1).strip()))
        if raw:
            targets.add(raw)
    return targets


def _role_label(request: PolicyRequest) -> str:
    role = request.context.actor_role or ""
    return role if role else "orchestrator (no active agent)"


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    intent = request.command_intent
    if intent is None:
        return None

    if request.context.is_meta_repo:
        return None

    command = request.tool_input.get("command", "") or ""
    if not command.strip():
        return None

    project_root = request.context.project_root or ""
    base_dir = intent.command_cwd or request.cwd or project_root

    raw_targets = _extract_patch_targets(command) | extract_bash_write_targets(command)
    if not raw_targets:
        return None

    for raw in raw_targets:
        target = _resolve_target_path(raw, base_dir=base_dir)
        if not target:
            continue

        if project_root and target.startswith(os.path.join(project_root, ".claude") + os.sep):
            continue

        info = classify_policy_path(
            target,
            project_root=project_root,
            worktree_path=request.context.worktree_path or "",
            scratch_roots=request.context.scratchlane_roots,
        )

        if info.kind == PATH_KIND_GOVERNANCE:
            if CAN_WRITE_GOVERNANCE not in request.context.capabilities:
                return PolicyDecision(
                    action="deny",
                    reason=(
                        f"BLOCKED: {_role_label(request)} cannot modify governance files "
                        f"via Bash ({target}). Dispatch planner with a runtime-issued "
                        "contract and canonical planner seat."
                    ),
                    policy_name="bash_write_who",
                )
            continue

        if info.kind == PATH_KIND_CONSTITUTION:
            if CAN_WRITE_GOVERNANCE not in request.context.capabilities:
                return PolicyDecision(
                    action="deny",
                    reason=(
                        f"BLOCKED: {_role_label(request)} cannot modify constitution-level "
                        f"file via Bash ({target}). Dispatch planner with a runtime-issued "
                        "contract and canonical planner seat."
                    ),
                    policy_name="bash_write_who",
                )
            continue

        if info.kind == PATH_KIND_SOURCE:
            if CAN_WRITE_SOURCE not in request.context.capabilities:
                return PolicyDecision(
                    action="deny",
                    reason=(
                        f"BLOCKED: {_role_label(request)} cannot modify source files via "
                        f"Bash ({target}). Dispatch implementer with a runtime-issued "
                        "contract and canonical implementer seat."
                    ),
                    policy_name="bash_write_who",
                )

    return None


def register(registry) -> None:
    registry.register(
        "bash_write_who",
        check,
        event_types=["Bash", "PreToolUse"],
        priority=275,
    )
