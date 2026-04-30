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
import shlex
from pathlib import Path
from typing import Optional

from runtime.core.command_intent import extract_bash_write_targets
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

_WRAPPER_RE = re.compile(
    r"(^|[;&|()]\s*)(?:bash|zsh)?\s*(?:\./)?scripts/scratchlane-exec\.sh(?:\s|$)"
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


def _wrapper_command(task_slug: str) -> str:
    return " ".join(
        [
            "./scripts/scratchlane-exec.sh",
            "--task-slug",
            shlex.quote(task_slug),
            "--",
            "<command>",
        ]
    )


def _scratchlane_message(*, task_slug: str, scratch_root: str, needs_grant: bool) -> str:
    grant_clause = ""
    if needs_grant:
        grant_clause = f" Ask the user for permission, then run `{_grant_command(task_slug)}`."
    return (
        f"Use the task-local scratchlane `{scratch_root}` for this temporary automation."
        f"{grant_clause} Re-run the command through `{_wrapper_command(task_slug)}` so the "
        "interpreter is confined to the scratchlane."
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
        scratch_root = info.scratch_root or f"tmp/.claude-scratch/{task_slug}"
        if info.kind == PATH_KIND_ARTIFACT_CANDIDATE:
            reason = (
                f"BLOCKED: scratchlane '{task_slug}' is not active for this task yet. "
                f"{_scratchlane_message(task_slug=task_slug, scratch_root=scratch_root, needs_grant=True)}"
            )
        else:
            reason = (
                f"BLOCKED: {target} looks like temporary automation, not repo source. "
                f"{_scratchlane_message(task_slug=task_slug, scratch_root=scratch_root, needs_grant=True)}"
            )
        return PolicyDecision(
            action="deny",
            reason=reason,
            policy_name="bash_scratchlane_gate",
        )

    if _WRAPPER_RE.search(command):
        return None

    script_match = _SCRIPT_INTERPRETER_RE.search(command)
    inline_match = _INLINE_INTERPRETER_RE.search(command)
    if not script_match and not inline_match:
        return None

    task_slug = "ad-hoc"
    scratch_root = f"tmp/.claude-scratch/{task_slug}"
    needs_grant = True
    if script_match:
        script_path = script_match.group("script") or ""
        task_slug = suggest_scratchlane_task_slug(script_path)
        scratch_root = f"tmp/.claude-scratch/{task_slug}"
        resolved_script = _resolve_target_path(script_path, base_dir=base_dir)
        if resolved_script:
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

    return PolicyDecision(
        action="deny",
        reason=(
            "BLOCKED: raw interpreter execution via Bash is opaque to the pre-tool write gate. "
            + _scratchlane_message(
                task_slug=task_slug,
                scratch_root=scratch_root,
                needs_grant=needs_grant,
            )
        ),
        policy_name="bash_scratchlane_gate",
    )


def register(registry) -> None:
    registry.register(
        "bash_scratchlane_gate",
        check,
        event_types=["Bash", "PreToolUse"],
        priority=260,
    )
