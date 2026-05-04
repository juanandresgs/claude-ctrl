"""Canonical hook-event envelope construction.

Hooks should deliver raw payloads to the runtime. This module owns the first
normalization step: session/tool identity, Bash command intent, command target,
and project-root resolution. Policy evaluation and non-enforcement hook
bookkeeping consume this envelope instead of deriving those facts from shell
cwd or ad hoc JSON parsing.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
import os
from pathlib import Path
import subprocess
from typing import Any, Mapping, Optional

from runtime.core.command_intent import BashCommandIntent, build_bash_command_intent
from runtime.core.policy_utils import normalize_path


@dataclass(frozen=True)
class HookEventEnvelope:
    """Runtime-owned normalized view of a hook payload."""

    event_type: str
    hook_event_name: str
    tool_name: str
    tool_input: dict[str, Any]
    session_id: str
    tool_use_id: str
    cwd: str
    command: str
    target_path: str
    command_intent: Optional[BashCommandIntent]
    target_cwd: str
    project_root: str
    actor_role: str
    actor_id: str
    actor_workflow_id: str

    @property
    def effective_cwd(self) -> str:
        """Directory policies should treat as the command's working dir."""
        return self.target_cwd if self.project_root else self.cwd

    def as_dict(self) -> dict[str, Any]:
        """Return a JSON-serializable diagnostic projection."""
        git_operations: list[dict[str, str]] = []
        if self.command_intent is not None:
            git_operations = [
                {
                    "subcommand": op.invocation.subcommand,
                    "op_class": op.op_class,
                }
                for op in self.command_intent.git_operations
            ]
        return {
            "event_type": self.event_type,
            "hook_event_name": self.hook_event_name,
            "tool_name": self.tool_name,
            "session_id": self.session_id,
            "tool_use_id": self.tool_use_id,
            "cwd": self.cwd,
            "effective_cwd": self.effective_cwd,
            "command": self.command,
            "target_path": self.target_path,
            "target_cwd": self.target_cwd,
            "project_root": self.project_root,
            "actor_role": self.actor_role,
            "actor_id": self.actor_id,
            "actor_workflow_id": self.actor_workflow_id,
            "git_operations": git_operations,
        }


def _payload_dict(payload: Mapping[str, Any] | None) -> dict[str, Any]:
    if isinstance(payload, dict):
        return dict(payload)
    if isinstance(payload, Mapping):
        return dict(payload.items())
    return {}


def _tool_input(payload: Mapping[str, Any]) -> dict[str, Any]:
    value = payload.get("tool_input", {})
    return dict(value) if isinstance(value, Mapping) else {}


def _is_path_under(root: str, path: str) -> bool:
    if not root or not path:
        return False
    canonical_root = normalize_path(root)
    canonical_path = normalize_path(path)
    return canonical_path == canonical_root or canonical_path.startswith(canonical_root + os.sep)


def _resolve_git_project_root(target_cwd: str) -> str:
    if not target_cwd or not os.path.isdir(target_cwd):
        return ""
    try:
        result = subprocess.run(
            ["git", "-C", target_cwd, "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        result = None
    if result is not None and result.returncode == 0 and result.stdout.strip():
        return normalize_path(result.stdout.strip())
    return ""


def _resolve_state_project_root(target_cwd: str) -> str:
    if not target_cwd or not os.path.isdir(target_cwd):
        return ""
    state_root = ""
    home_root = normalize_path(str(Path.home()))
    for candidate in (Path(target_cwd), *Path(target_cwd).parents):
        normalized_candidate = normalize_path(str(candidate))
        if normalized_candidate == home_root:
            continue
        if (candidate / ".claude" / "state.db").is_file():
            state_root = normalized_candidate
    return state_root


def _resolve_project_root(target_cwd: str, *, cwd: str = "", target_path: str = "") -> str:
    """Resolve the single project root authority for a hook event.

    Git roots win. For non-git projects, an existing ancestor state DB wins.
    Otherwise, writes under the session cwd are anchored to that cwd instead of
    the deepest existing target directory. This prevents first writes in
    subdirectories from creating nested ``.claude/state.db`` authorities.
    """
    git_root = _resolve_git_project_root(target_cwd)
    if git_root:
        return git_root

    state_root = _resolve_state_project_root(target_cwd)
    if state_root:
        return state_root

    normalized_cwd = normalize_path(cwd) if cwd and os.path.isdir(cwd) else ""
    if normalized_cwd:
        git_root = _resolve_git_project_root(normalized_cwd)
        if git_root:
            return git_root
        state_root = _resolve_state_project_root(normalized_cwd)
        if state_root:
            return state_root
        if _is_path_under(normalized_cwd, target_cwd) or (
            target_path and _is_path_under(normalized_cwd, target_path)
        ):
            return normalized_cwd

    return normalize_path(target_cwd)


def _existing_parent(path: str) -> str:
    candidate = Path(path).expanduser()
    if candidate.is_dir():
        return normalize_path(str(candidate))
    if candidate.is_file():
        return normalize_path(str(candidate.parent))
    for parent in (candidate.parent, *candidate.parents):
        if parent.is_dir():
            return normalize_path(str(parent))
    return ""


def _write_target_path(tool_input: Mapping[str, Any], cwd: str) -> str:
    file_path = str(tool_input.get("file_path") or "")
    if not file_path:
        return ""
    if os.path.isabs(file_path):
        return normalize_path(file_path)
    return normalize_path(os.path.join(cwd, file_path))


def build_hook_event_envelope(payload: Mapping[str, Any] | None) -> HookEventEnvelope:
    """Build the canonical runtime envelope from raw hook JSON.

    Resolution order for Bash command targets:
      1. explicit ``payload.target_cwd`` override
      2. runtime-owned BashCommandIntent target_cwd
      3. payload cwd

    The explicit override is preserved for older tests and non-Claude callers,
    but command parsing remains centralized here.
    """
    data = _payload_dict(payload)
    tool_input = _tool_input(data)
    cwd = normalize_path(str(data.get("cwd") or os.getcwd()))
    tool_name = str(data.get("tool_name") or "")
    event_type = str(data.get("event_type") or data.get("hook_event_name") or "")
    hook_event_name = str(data.get("hook_event_name") or event_type)
    command = str(tool_input.get("command") or "") if tool_name == "Bash" else ""
    target_path = _write_target_path(tool_input, cwd) if tool_name in {"Write", "Edit"} else ""
    if target_path:
        # Policies consume envelope.tool_input, so make the runtime-owned target
        # path the value seen by branch/path gates instead of leaving each policy
        # to reinterpret a raw relative hook path.
        tool_input = {**tool_input, "file_path": target_path}

    command_intent = (
        build_bash_command_intent(command, cwd=cwd)
        if tool_name == "Bash" and command
        else None
    )

    target_cwd = str(data.get("target_cwd") or "")
    if target_cwd:
        target_cwd = normalize_path(target_cwd)
        if command_intent is not None:
            command_intent = replace(command_intent, target_cwd=target_cwd)
    elif command_intent is not None and command_intent.target_cwd:
        target_cwd = normalize_path(command_intent.target_cwd)
    elif target_path:
        target_cwd = _existing_parent(target_path)
    else:
        target_cwd = cwd

    project_root = _resolve_project_root(target_cwd, cwd=cwd, target_path=target_path)

    return HookEventEnvelope(
        event_type=event_type,
        hook_event_name=hook_event_name,
        tool_name=tool_name,
        tool_input=tool_input,
        session_id=str(data.get("session_id") or ""),
        tool_use_id=str(data.get("tool_use_id") or ""),
        cwd=cwd,
        command=command,
        target_path=target_path,
        command_intent=command_intent,
        target_cwd=target_cwd,
        project_root=project_root,
        actor_role=str(data.get("actor_role") or ""),
        actor_id=str(data.get("actor_id") or ""),
        actor_workflow_id=str(data.get("actor_workflow_id") or ""),
    )
