"""bash_scratchlane_gate — artifact-lane guidance plus opaque interpreter deny.

This module closes two related gaps in the Bash surface:

  * shell-visible writes into ``tmp`` should steer into the canonical
    task-local scratchlane instead of being mistaken for repo source work.
  * raw interpreter execution (``python -c``, heredocs, direct script
    execution) is opaque to the pre-tool gate and must go through the
    dedicated scratchlane runner.
"""

from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Optional

from runtime.core.command_intent import (
    extract_bash_write_targets,
    extract_single_simple_command_argv,
)
from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import (
    PATH_KIND_ARTIFACT,
    PATH_KIND_ARTIFACT_CANDIDATE,
    PATH_KIND_TMP_SOURCE_CANDIDATE,
    classify_policy_path,
    is_tracked_repo_path,
    normalize_path,
    resolve_path_from_base,
    suggest_scratchlane_task_slug,
)

_ENV_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=.*$")
_SHELL_SCRIPT_WRAPPERS = frozenset({"bash", "sh", "zsh"})
_RUNTIME_ROOT = Path(__file__).resolve().parents[3]
_SCRATCHLANE_EXEC = normalize_path(
    str(_RUNTIME_ROOT / "scripts" / "scratchlane-exec.sh")
)
_INLINE_INTERPRETER_RE = re.compile(
    r"(^|[;&|()]\s*)(?:/usr/bin/env\s+)?"
    r"(python[0-9.]*|node|ruby|perl|php)\s+(?:-[cCeErR]\b|-\s*(?:<<|$))",
    re.IGNORECASE,
)
_SCRIPT_INTERPRETER_RE = re.compile(
    r"(^|[;&|()]\s*)(?:/usr/bin/env\s+)?"
    r"(python[0-9.]*|node|ruby|perl|php)\s+"
    r"(?P<script>(?!-)[^\s;&|]+?\.(?:py|py3|js|mjs|cjs|rb|pl|php))\b",
    re.IGNORECASE,
)


def _resolve_target_path(raw_path: str, *, base_dir: str) -> str:
    candidate = raw_path.strip().strip("'\"")
    if not candidate or candidate in {"-", "/dev/null"}:
        return ""
    if os.path.isabs(candidate):
        return normalize_path(candidate)
    resolved = resolve_path_from_base(base_dir, candidate)
    return normalize_path(resolved) if resolved else ""


def _shell_quote(value: str) -> str:
    """Quote a display command argument without importing shell tokenizers."""
    if re.fullmatch(r"[A-Za-z0-9_./:=@%+-]+", value):
        return value
    return "'" + value.replace("'", "'\"'\"'") + "'"


def _resolve_executable_path(raw_path: str, *, base_dir: str) -> str:
    candidate = raw_path.strip()
    if not candidate:
        return ""
    if candidate.startswith("~/"):
        candidate = os.path.expanduser(candidate)
    if os.path.isabs(candidate):
        return normalize_path(candidate)
    resolved = resolve_path_from_base(base_dir, candidate)
    return normalize_path(resolved) if resolved else ""


def _simple_command_argv(command: str) -> tuple[str, ...]:
    argv = extract_single_simple_command_argv(command)
    if not argv:
        return ()
    return argv


def _simple_command_executable(argv: tuple[str, ...]) -> str:
    if not argv:
        return ""

    index = 0
    while index < len(argv) and _ENV_ASSIGN_RE.match(argv[index]):
        index += 1
    if index >= len(argv):
        return ""

    command_name = os.path.basename(argv[index])
    if command_name == "env":
        index += 1
        while index < len(argv) and (
            _ENV_ASSIGN_RE.match(argv[index]) or argv[index].startswith("-")
        ):
            index += 1
        if index >= len(argv):
            return ""
        command_name = os.path.basename(argv[index])

    if command_name in _SHELL_SCRIPT_WRAPPERS:
        index += 1
        if index < len(argv) and argv[index] == "--":
            index += 1
        if index >= len(argv) or argv[index].startswith("-"):
            return ""
        return argv[index]

    return argv[index]


def _is_scratchlane_exec_path(path: str, *, base_dir: str) -> bool:
    resolved = _resolve_executable_path(path, base_dir=base_dir)
    return bool(resolved and resolved == _SCRATCHLANE_EXEC)


def _looks_like_scratchlane_exec(path: str) -> bool:
    return os.path.basename(path.strip()) == "scratchlane-exec.sh"


def _wrapper_option(argv: tuple[str, ...], option: str) -> str:
    seen_wrapper = False
    index = 0
    while index < len(argv):
        token = argv[index]
        if _looks_like_scratchlane_exec(token):
            seen_wrapper = True
            index += 1
            continue
        if not seen_wrapper:
            index += 1
            continue
        if token == "--":
            return ""
        if token == option:
            return argv[index + 1] if index + 1 < len(argv) else ""
        index += 1
    return ""


def _wrapper_project_root_matches(
    argv: tuple[str, ...],
    *,
    base_dir: str,
    project_root: str,
) -> bool:
    declared = _wrapper_option(argv, "--project-root")
    if not declared:
        return False
    resolved = _resolve_executable_path(declared, base_dir=base_dir)
    return bool(resolved and resolved == normalize_path(project_root))


def _wrapper_command(task_slug: str, *, project_root: str = "") -> str:
    parts = [
        _shell_quote(_SCRATCHLANE_EXEC),
        "--task-slug",
        _shell_quote(task_slug),
    ]
    if project_root:
        parts.extend(["--project-root", _shell_quote(project_root)])
    parts.extend(["--", "<command>"])
    return " ".join(parts)


def _approval_prompt(task_slug: str) -> str:
    return f"Allow task scratchlane `tmp/.claude-scratch/{task_slug}/` for this task?"


def _approval_effect(
    *,
    task_slug: str,
    scratch_root: str,
    requested_path: str,
    tool_name: str,
    request_reason: str,
) -> dict:
    return {
        "request_scratchlane_approval": {
            "task_slug": task_slug,
            "root_path": scratch_root,
            "requested_path": requested_path,
            "tool_name": tool_name,
            "request_reason": request_reason,
            "requested_by": "bash_scratchlane_gate",
        }
    }


def _approval_clause(task_slug: str) -> str:
    return (
        f'Ask the user: "{_approval_prompt(task_slug)}" If they approve, the runtime '
        "will activate it automatically. Do not tell the user to run any command."
    )


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    intent = request.command_intent
    if intent is None:
        return None

    command = request.tool_input.get("command", "") or ""
    if not command.strip():
        return None

    project_root = request.context.project_root or ""
    base_dir = intent.command_cwd or request.cwd or project_root

    for raw_target in extract_bash_write_targets(command):
        target = _resolve_target_path(raw_target, base_dir=base_dir)
        if not target:
            continue
        info = classify_policy_path(
            target,
            project_root=project_root,
            worktree_path=request.context.worktree_path or "",
            scratch_roots=request.context.scratchlane_roots,
        )
        if info.kind not in {
            PATH_KIND_ARTIFACT,
            PATH_KIND_ARTIFACT_CANDIDATE,
            PATH_KIND_TMP_SOURCE_CANDIDATE,
        }:
            continue

        if is_tracked_repo_path(project_root, info.repo_relative_path):
            return PolicyDecision(
                action="deny",
                reason=(
                    f"BLOCKED: {target} lives under the scratchlane path but is tracked by git. "
                    "Tracked repo files may not use the artifact lane."
                ),
                policy_name="bash_scratchlane_gate",
            )

        if info.kind == PATH_KIND_ARTIFACT:
            continue

        task_slug = info.task_slug or suggest_scratchlane_task_slug(target)
        scratch_root = info.scratch_root or ""
        scratch_root_display = f"tmp/.claude-scratch/{task_slug}/"
        approval_effect = _approval_effect(
            task_slug=task_slug,
            scratch_root=scratch_root,
            requested_path=target,
            tool_name=request.tool_name,
            request_reason=info.kind,
        )
        if info.kind == PATH_KIND_ARTIFACT_CANDIDATE:
            reason = (
                f"BLOCKED: scratchlane '{task_slug}' is not active for this task yet. "
                f"{_approval_clause(task_slug)} Retry the command after approval."
            )
        else:
            reason = (
                f"BLOCKED: {target} looks like temporary automation, not repo source. "
                f"{_approval_clause(task_slug)} Retry it with the write target moved "
                f"under `{scratch_root_display}`."
            )
        return PolicyDecision(
            action="deny",
            reason=reason,
            policy_name="bash_scratchlane_gate",
            effects=approval_effect,
        )

    simple_argv = _simple_command_argv(command)
    wrapper_executable = _simple_command_executable(simple_argv)
    if wrapper_executable:
        if _is_scratchlane_exec_path(wrapper_executable, base_dir=base_dir):
            if project_root and not _wrapper_project_root_matches(
                simple_argv,
                base_dir=base_dir,
                project_root=project_root,
            ):
                task_slug = _wrapper_option(simple_argv, "--task-slug") or "ad-hoc"
                return PolicyDecision(
                    action="deny",
                    reason=(
                        "BLOCKED: scratchlane execution must declare the governed "
                        f"project root. Re-run through "
                        f"`{_wrapper_command(task_slug, project_root=project_root)}` "
                        "with the same task slug and command so permit lookup and "
                        "sandbox confinement use the target repo, not ambient shell "
                        "state."
                    ),
                    policy_name="bash_scratchlane_gate",
                )
            return None
        if _looks_like_scratchlane_exec(wrapper_executable):
            return PolicyDecision(
                action="deny",
                reason=(
                    "BLOCKED: scratchlane execution must use the runtime-owned "
                    f"wrapper `{_shell_quote(_SCRATCHLANE_EXEC)}`. The requested "
                    f"wrapper `{wrapper_executable}` does not resolve to the "
                    "installed control-plane executor."
                ),
                policy_name="bash_scratchlane_gate",
            )

    script_match = _SCRIPT_INTERPRETER_RE.search(command)
    inline_match = _INLINE_INTERPRETER_RE.search(command)
    if not script_match and not inline_match:
        return None

    task_slug = "ad-hoc"
    scratch_root = ""
    needs_grant = True
    requested_path = ""
    if script_match:
        script_path = script_match.group("script") or ""
        task_slug = suggest_scratchlane_task_slug(script_path)
        resolved_script = _resolve_target_path(script_path, base_dir=base_dir)
        if resolved_script:
            requested_path = resolved_script
            info = classify_policy_path(
                resolved_script,
                project_root=project_root,
                worktree_path=request.context.worktree_path or "",
                scratch_roots=request.context.scratchlane_roots,
            )
            if info.task_slug:
                task_slug = info.task_slug
            if info.scratch_root:
                scratch_root = info.scratch_root
            needs_grant = info.kind != PATH_KIND_ARTIFACT
    scratch_root_display = f"tmp/.claude-scratch/{task_slug}/"
    reason = (
        "BLOCKED: raw interpreter execution via Bash is opaque to the pre-tool write gate. "
    )
    if needs_grant:
        reason += (
            f"{_approval_clause(task_slug)} Then re-run the command through "
            f"`{_wrapper_command(task_slug, project_root=project_root)}` so the "
            f"interpreter is confined to `{scratch_root_display}`."
        )
    else:
        reason += (
            f"Re-run the command through "
            f"`{_wrapper_command(task_slug, project_root=project_root)}` so the "
            f"interpreter is confined to `{scratch_root_display}`."
        )

    return PolicyDecision(
        action="deny",
        reason=reason,
        policy_name="bash_scratchlane_gate",
        effects=(
            _approval_effect(
                task_slug=task_slug,
                scratch_root=scratch_root,
                requested_path=requested_path,
                tool_name=request.tool_name,
                request_reason="opaque_interpreter",
            )
            if needs_grant
            else None
        ),
    )


def register(registry) -> None:
    registry.register(
        "bash_scratchlane_gate",
        check,
        event_types=["Bash", "PreToolUse"],
        priority=260,
    )
