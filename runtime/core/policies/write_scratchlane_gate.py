"""write_scratchlane_gate — task-local artifact lane for ad-hoc automation.

This policy sits before source/governance write gates and recognizes the two
temporary-automation cases that previously felt awkward:

  * ``tmp/.claude-scratch/<task>/...`` — the canonical scratchlane root
  * source-looking files directly under ``tmp/`` (for example ``tmp/dedup.py``)

The first case requires an active user-approved scratchlane permit for the
task. The second case is redirected into the canonical scratchlane root so the
user gets one clean place for ephemeral scripts and outputs rather than an
arbitrary scattering of ``tmp/*.py`` files.
"""

from __future__ import annotations

import shlex
from typing import Optional

from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import (
    PATH_KIND_ARTIFACT,
    PATH_KIND_ARTIFACT_CANDIDATE,
    PATH_KIND_TMP_SOURCE_CANDIDATE,
    classify_policy_path,
    is_tracked_repo_path,
    suggest_scratchlane_task_slug,
)


def _grant_command(task_slug: str) -> str:
    return " ".join(
        [
            "python3",
            "runtime/cli.py",
            "scratchlane",
            "grant",
            "--task-slug",
            shlex.quote(task_slug),
        ]
    )


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    file_path: str = request.tool_input.get("file_path", "") or ""
    if not file_path:
        return None

    info = classify_policy_path(
        file_path,
        project_root=request.context.project_root or "",
        worktree_path=request.context.worktree_path or "",
        scratch_roots=request.context.scratchlane_roots,
    )
    if info.kind not in {
        PATH_KIND_ARTIFACT,
        PATH_KIND_ARTIFACT_CANDIDATE,
        PATH_KIND_TMP_SOURCE_CANDIDATE,
    }:
        return None

    if is_tracked_repo_path(request.context.project_root or "", info.repo_relative_path):
        return PolicyDecision(
            action="deny",
            reason=(
                f"BLOCKED: {file_path} lives under the scratchlane path but is tracked by git. "
                "Tracked repo files may not use the artifact lane. Move this work out of the "
                "tracked path or treat it as a real source change."
            ),
            policy_name="write_scratchlane_gate",
        )

    if info.kind == PATH_KIND_ARTIFACT:
        return None

    task_slug = info.task_slug or suggest_scratchlane_task_slug(file_path)
    scratch_root = info.scratch_root or f"tmp/.claude-scratch/{task_slug}"
    grant_cmd = _grant_command(task_slug)

    if info.kind == PATH_KIND_ARTIFACT_CANDIDATE:
        return PolicyDecision(
            action="deny",
            reason=(
                f"BLOCKED: scratchlane '{task_slug}' is not active for this task yet. "
                f"Ask the user for permission to work under {scratch_root}, then run "
                f"`{grant_cmd}` and retry the write."
            ),
            policy_name="write_scratchlane_gate",
        )

    return PolicyDecision(
        action="deny",
        reason=(
            f"BLOCKED: {file_path} looks like temporary automation, not repo source. "
            f"Ask the user for permission to open scratchlane '{task_slug}', then run "
            f"`{grant_cmd}` and write this file under `{scratch_root}/` instead."
        ),
        policy_name="write_scratchlane_gate",
    )

