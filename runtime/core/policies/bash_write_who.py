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
import shlex
from typing import Optional

from runtime.core.authority_registry import CAN_WRITE_GOVERNANCE, CAN_WRITE_SOURCE
from runtime.core.constitution_registry import is_constitution_level, normalize_repo_path
from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import (
    is_governance_markdown,
    is_skippable_path,
    is_source_file,
    normalize_path,
    resolve_path_from_base,
)

_SHELL_SEPARATORS = frozenset({";", "&&", "||", "|", "&"})
_REDIRECT_TOKENS = frozenset({">", ">>", "1>", "1>>", "2>", "2>>"})
_PATCH_FILE_RE = re.compile(r"(?m)^\*\*\* (?:Add|Update|Delete) File:\s+(.+)$")
_MUTATING_PATH_COMMANDS = frozenset({"cp", "mv", "install", "touch", "truncate"})


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


def _extract_shell_targets(command: str) -> set[str]:
    targets: set[str] = set()
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars="><;&|")
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:
        return targets

    index = 0
    while index < len(tokens):
        token = tokens[index]

        if token in _REDIRECT_TOKENS and index + 1 < len(tokens):
            target = tokens[index + 1]
            if target and target not in _SHELL_SEPARATORS and target not in _REDIRECT_TOKENS:
                targets.add(target)
            index += 2
            continue

        cmd = os.path.basename(token)
        if cmd == "tee":
            cursor = index + 1
            while cursor < len(tokens) and tokens[cursor] not in _SHELL_SEPARATORS:
                arg = tokens[cursor]
                if arg and not arg.startswith("-") and arg not in _REDIRECT_TOKENS:
                    targets.add(arg)
                cursor += 1
            index = cursor
            continue

        if cmd in _MUTATING_PATH_COMMANDS:
            cursor = index + 1
            args: list[str] = []
            while cursor < len(tokens) and tokens[cursor] not in _SHELL_SEPARATORS:
                args.append(tokens[cursor])
                cursor += 1
            positional = [a for a in args if a and not a.startswith("-")]
            if positional:
                targets.add(positional[-1])
            index = cursor
            continue

        index += 1

    return targets


def _strip_worktree_prefix(path: str) -> str:
    normalized = path.replace("\\", "/").lstrip("/")
    parts = normalized.split("/")
    if len(parts) >= 3 and parts[0] == ".worktrees":
        return "/".join(parts[2:])
    return normalized


def _to_repo_relative(path: str, project_root: str, worktree_path: str) -> str | None:
    if not path:
        return None

    if os.path.isabs(path):
        if worktree_path and path.startswith(worktree_path + os.sep):
            rel = path[len(worktree_path) :].lstrip(os.sep).lstrip("/")
            return normalize_repo_path(rel)
        if project_root and path.startswith(project_root + os.sep):
            rel = path[len(project_root) :].lstrip(os.sep).lstrip("/")
            return normalize_repo_path(_strip_worktree_prefix(rel))
        return None

    return normalize_repo_path(_strip_worktree_prefix(path))


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

    raw_targets = _extract_patch_targets(command) | _extract_shell_targets(command)
    if not raw_targets:
        return None

    for raw in raw_targets:
        target = _resolve_target_path(raw, base_dir=base_dir)
        if not target:
            continue

        if project_root and target.startswith(os.path.join(project_root, ".claude") + os.sep):
            continue

        if is_governance_markdown(target):
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

        repo_rel = _to_repo_relative(target, project_root, request.context.worktree_path or "")
        if repo_rel and is_constitution_level(_strip_diff_prefix(repo_rel)):
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

        if is_source_file(target) and not is_skippable_path(target):
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
