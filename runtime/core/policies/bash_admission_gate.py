"""bash_admission_gate — route uncustodied Bash source writes to Guardian Admission."""

from __future__ import annotations

import os
import re
from typing import Optional

from runtime.core import work_admission
from runtime.core.authority_registry import CAN_WRITE_SOURCE
from runtime.core.command_intent import extract_bash_write_targets
from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import (
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


def _extract_patch_targets(command: str) -> set[str]:
    targets: set[str] = set()
    for match in _PATCH_FILE_RE.finditer(command):
        raw = _strip_diff_prefix(_strip_quotes(match.group(1).strip()))
        if raw:
            targets.add(raw)
    return targets


def _resolve_target_path(raw_path: str, *, base_dir: str) -> str:
    candidate = _strip_quotes(raw_path).strip()
    if not candidate or candidate in {"-", "/dev/null"}:
        return ""
    if os.path.isabs(candidate):
        return normalize_path(candidate)
    resolved = resolve_path_from_base(base_dir, candidate)
    return normalize_path(resolved) if resolved else ""


def _payload(request: PolicyRequest, target_path: str, command: str) -> dict:
    return {
        "trigger": "bash_file_mutation",
        "cwd": request.cwd,
        "project_root": request.context.project_root,
        "target_path": target_path,
        "workflow_id": request.context.workflow_id,
        "session_id": request.context.session_id,
        "actor_role": request.context.actor_role,
        "actor_id": request.context.actor_id,
        "tool_name": request.tool_name,
        "user_prompt": command,
    }


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    if CAN_WRITE_SOURCE in request.context.capabilities:
        return None
    if request.command_intent is None:
        return None
    if request.context.is_meta_repo:
        return None

    command = request.tool_input.get("command", "") or ""
    if not command.strip():
        return None

    project_root = request.context.project_root or ""
    base_dir = request.command_intent.command_cwd or request.cwd or project_root
    raw_targets = _extract_patch_targets(command) | extract_bash_write_targets(command)
    for raw in raw_targets:
        target = _resolve_target_path(raw, base_dir=base_dir)
        if not target:
            continue

        info = classify_policy_path(
            target,
            project_root=project_root,
            worktree_path=request.context.worktree_path or "",
            scratch_roots=request.context.scratchlane_roots,
        )
        if info.kind != PATH_KIND_SOURCE:
            continue

        payload = _payload(request, info.normalized_path or target, command)
        result = work_admission.classify_context(request.context, payload)
        return PolicyDecision(
            action="deny",
            reason=work_admission.format_admission_reason(result),
            policy_name="bash_admission_gate",
            metadata={"guardian_admission": result},
        )

    return None


def register(registry) -> None:
    registry.register(
        "bash_admission_gate",
        check,
        event_types=["Bash", "PreToolUse"],
        priority=270,
    )
