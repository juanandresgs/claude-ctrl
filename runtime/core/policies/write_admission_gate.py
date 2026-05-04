"""write_admission_gate — route uncustodied source writes to Guardian Admission."""

from __future__ import annotations

from typing import Optional

from runtime.core import work_admission
from runtime.core.authority_registry import CAN_WRITE_SOURCE
from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import PATH_KIND_SOURCE, classify_policy_path


def _payload(request: PolicyRequest, target_path: str) -> dict:
    return {
        "trigger": "source_write",
        "cwd": request.cwd,
        "project_root": request.context.project_root,
        "target_path": target_path,
        "workflow_id": request.context.workflow_id,
        "session_id": request.context.session_id,
        "actor_role": request.context.actor_role,
        "actor_id": request.context.actor_id,
        "tool_name": request.tool_name,
    }


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    file_path: str = request.tool_input.get("file_path", "") or ""
    if not file_path:
        return None

    if CAN_WRITE_SOURCE in request.context.capabilities:
        return None

    info = classify_policy_path(
        file_path,
        project_root=request.context.project_root or "",
        worktree_path=request.context.worktree_path or "",
        scratch_roots=request.context.scratchlane_roots,
    )
    if info.kind != PATH_KIND_SOURCE:
        return None

    payload = _payload(request, info.normalized_path or file_path)
    result = work_admission.classify_context(request.context, payload)
    return PolicyDecision(
        action="deny",
        reason=work_admission.format_admission_reason(result),
        policy_name="write_admission_gate",
        metadata={"guardian_admission": result},
    )
