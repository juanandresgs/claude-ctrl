"""write_scratchlane_gate — task-local artifact lane for ad-hoc automation.

This policy sits before source/governance write gates and recognizes the two
temporary-automation cases that previously felt awkward:

  * ``tmp/<task>/...`` — the canonical scratchlane root
  * source-looking files directly under ``tmp/`` (for example ``tmp/dedup.py``)

The first case requires an active user-approved scratchlane permit for the
task. The second case is redirected into the canonical scratchlane root so the
user gets one clean place for ephemeral scripts and outputs rather than an
arbitrary scattering of ``tmp/*.py`` files.
"""

from __future__ import annotations

from typing import Optional

from runtime.core import work_admission
from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import (
    PATH_KIND_ARTIFACT,
    PATH_KIND_ARTIFACT_CANDIDATE,
    PATH_KIND_TMP_SOURCE_CANDIDATE,
    classify_policy_path,
    is_tracked_repo_path,
    normalize_path,
    suggest_scratchlane_task_slug,
)


def _admission_effect(
    *,
    request: PolicyRequest,
    task_slug: str,
    scratch_root: str,
    requested_path: str,
    request_reason: str,
) -> dict:
    return {
        "apply_guardian_admission": {
            "trigger": "source_write",
            "cwd": request.cwd,
            "project_root": request.context.project_root,
            "target_path": requested_path,
            "workflow_id": request.context.workflow_id,
            "session_id": request.context.session_id,
            "tool_name": request.tool_name,
            "user_prompt": f"obvious scratchlane candidate: {request_reason}",
            "task_slug": task_slug,
            "root_path": scratch_root,
        }
    }


def _root_display(root: str, fallback: str) -> str:
    display = root or fallback
    return display if display.endswith("/") else display + "/"


def _active_root(root: str, scratch_roots: frozenset[str]) -> str:
    if not root:
        return ""
    expected = normalize_path(root)
    for item in scratch_roots:
        candidate = normalize_path(str(item))
        if candidate == expected:
            return candidate
    return ""


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
    scratch_root = info.scratch_root or ""
    scratch_root_display = f"tmp/{task_slug}/"
    active_root = _active_root(scratch_root, request.context.scratchlane_roots)

    if active_root:
        return PolicyDecision(
            action="deny",
            reason=(
                f"BLOCKED: scratchlane '{task_slug}' is active at "
                f"`{_root_display(active_root, scratch_root_display)}`, but this write "
                f"targets `{info.normalized_path or file_path}`. Retry the write under "
                "the active scratchlane root."
            ),
            policy_name="write_scratchlane_gate",
        )

    admission_effect = _admission_effect(
        request=request,
        task_slug=task_slug,
        scratch_root=scratch_root,
        requested_path=info.normalized_path or file_path,
        request_reason=info.kind,
    )
    admission_result = {
        "verdict": work_admission.VERDICT_SCRATCHLANE_AUTHORIZED,
        "next_authority": "scratchlane",
        "reason": "Target is an obvious task-local tmp scratchlane candidate.",
        "target_path": info.normalized_path or file_path,
        "scratchlane": {
            "task_slug": task_slug,
            "root_path": scratch_root,
            "relative_path": scratch_root_display,
        },
    }

    if info.kind == PATH_KIND_ARTIFACT_CANDIDATE:
        return PolicyDecision(
            action="deny",
            reason=(
                "ADMISSION_REQUIRED: Guardian Admission authorized task "
                f"scratchlane `{scratch_root_display}` for this obvious temporary "
                "target. The runtime will activate the permit automatically; "
                f"retry the write under `{_root_display(scratch_root, scratch_root_display)}`."
            ),
            policy_name="write_scratchlane_gate",
            effects=admission_effect,
            metadata={"guardian_admission": admission_result},
        )

    return PolicyDecision(
        action="deny",
        reason=(
            f"ADMISSION_REQUIRED: {file_path} looks like temporary automation, "
            f"not repo source. Guardian Admission authorized scratchlane "
            f"`{scratch_root_display}`; retry the write under "
            f"`{_root_display(scratch_root, scratch_root_display)}` instead."
        ),
        policy_name="write_scratchlane_gate",
        effects=admission_effect,
        metadata={"guardian_admission": admission_result},
    )
