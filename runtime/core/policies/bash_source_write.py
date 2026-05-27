"""Policy: bash_source_write — prevent shell redirection from bypassing source write guards."""

from __future__ import annotations

import os
import subprocess
from typing import Optional

from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policies.fast_path import guardian_small_source_write_allowed
from runtime.core.policy_utils import is_skippable_path, is_source_file, normalize_path


def _branch_for_target(target: str, fallback: str) -> str:
    target_dir = os.path.dirname(target) or target
    for args in (
        ["git", "-C", target_dir, "symbolic-ref", "--short", "HEAD"],
        ["git", "-C", target_dir, "rev-parse", "--abbrev-ref", "HEAD"],
    ):
        try:
            result = subprocess.run(args, capture_output=True, text=True, timeout=5)
        except (FileNotFoundError, OSError, subprocess.TimeoutExpired):
            continue
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    return fallback


def _source_targets(request: PolicyRequest) -> list[str]:
    intent = request.command_intent
    if intent is None:
        return []

    project_root = normalize_path(request.context.project_root) if request.context.project_root else ""
    meta_prefix = os.path.join(project_root, ".claude") + os.sep if project_root else ""
    targets: list[str] = []
    seen: set[str] = set()
    for target in intent.shell_write_targets:
        normalized = normalize_path(target)
        if normalized in seen:
            continue
        seen.add(normalized)
        if meta_prefix and normalized.startswith(meta_prefix):
            continue
        if not is_source_file(normalized):
            continue
        if is_skippable_path(normalized):
            continue
        targets.append(normalized)
    return targets


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    targets = _source_targets(request)
    if not targets:
        return None

    branch = _branch_for_target(targets[0], request.context.branch or "")
    role = request.context.actor_role or ""
    if role == "guardian" and all(
        guardian_small_source_write_allowed(request, target) for target in targets
    ):
        return None

    if branch in {"main", "master"}:
        return PolicyDecision(
            action="deny",
            reason=(
                f"BLOCKED: Bash command writes source files on {branch} branch. "
                "Sacred Practice #2 applies to shell redirection too.\n\n"
                "Action: For a bounded <=2 file source fix, launch Guardian in "
                "small-source mode with the exact proposed patch and focused "
                "test. Guardian may apply it directly only if it remains narrow; "
                "otherwise Guardian must require provision -> implementer."
            ),
            policy_name="bash_source_write",
            metadata={"targets": targets},
        )

    if role == "implementer":
        return None

    role_label = role if role else "orchestrator (no active agent)"
    target_list = ", ".join(targets[:3])
    if len(targets) > 3:
        target_list += ", ..."
    return PolicyDecision(
        action="deny",
        reason=(
            f"BLOCKED: {role_label} cannot write source files via Bash "
            f"redirection or shell file commands ({target_list}) through this lane. "
            "Source writes require either an implementer in the provisioned worktree "
            "or Guardian small-source mode for a bounded fix.\n\n"
            "Action: For a bounded <=2 file source fix, launch Guardian in "
            "small-source mode with the exact proposed patch and focused test. "
            "Guardian may apply it directly only if it remains narrow; "
            "otherwise Guardian must require provision -> implementer. Do not "
            "retry the source edit from the orchestrator."
        ),
        policy_name="bash_source_write",
        metadata={"targets": targets},
    )


def register(registry) -> None:
    registry.register(
        "bash_source_write",
        check,
        event_types=["Bash", "PreToolUse"],
        priority=275,
    )
