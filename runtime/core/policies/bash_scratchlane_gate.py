"""bash_scratchlane_gate — artifact-lane routing plus opaque interpreter deny.

This module closes two related gaps in the Bash surface:

  * shell-visible writes into ``tmp`` should steer into the canonical
    task-local scratchlane instead of being mistaken for repo source work.
  * opaque interpreter execution must be classified by Guardian Admission
    before it may use the dedicated scratchlane runner.
"""

from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Optional

from runtime.core import work_admission
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
    scratchlane_root,
    sanitize_token,
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
_PIPE_INLINE_FILTER_RE = re.compile(
    r"\|\s*(?:/usr/bin/env\s+)?(?:python[0-9.]*|node|ruby|perl|php)\s+"
    r"(?:-[cCeErR])\s+(?P<quote>['\"])(?P<code>.*?)(?P=quote)\s*$",
    re.IGNORECASE | re.DOTALL,
)
_FILTER_READ_MARKERS = ("sys.stdin", "stdin", "json.load", "json.loads")
_FILTER_OUTPUT_MARKERS = ("print(", "sys.stdout", "console.log")
_FILTER_MUTATION_MARKERS = (
    "__import__",
    "compile(",
    "eval(",
    "exec(",
    "import os",
    "import pathlib",
    "import shutil",
    "import socket",
    "import subprocess",
    "open(",
    "pathlib",
    "requests",
    "shutil.",
    "socket.",
    "subprocess.",
    "urllib",
    ".write(",
    "write_text(",
    "write_bytes(",
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


def _admission_payload(
    request: PolicyRequest,
    *,
    trigger: str,
    target_path: str,
    user_prompt: str,
    task_slug: str = "",
) -> dict:
    return {
        "trigger": trigger,
        "cwd": request.cwd,
        "project_root": request.context.project_root,
        "target_path": target_path,
        "workflow_id": request.context.workflow_id,
        "session_id": request.context.session_id,
        "actor_role": request.context.actor_role,
        "actor_id": request.context.actor_id,
        "tool_name": request.tool_name,
        "user_prompt": user_prompt,
        "task_slug": task_slug,
    }


def _admission_decision(
    request: PolicyRequest,
    *,
    trigger: str,
    target_path: str,
    user_prompt: str,
    task_slug: str,
    policy_name: str = "bash_scratchlane_gate",
) -> PolicyDecision:
    payload = _admission_payload(
        request,
        trigger=trigger,
        target_path=target_path,
        user_prompt=user_prompt,
        task_slug=task_slug,
    )
    admission_result = work_admission.classify_context(request.context, payload)
    return PolicyDecision(
        action="deny",
        reason=work_admission.format_admission_reason(admission_result),
        policy_name=policy_name,
        metadata={"guardian_admission": admission_result},
    )


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


def _active_scratch_root_for_task(
    *,
    project_root: str,
    task_slug: str,
    scratch_roots: frozenset[str],
) -> str:
    if not project_root or not task_slug:
        return ""
    expected_root = normalize_path(scratchlane_root(project_root, task_slug))
    for root in scratch_roots:
        if normalize_path(str(root)) == expected_root:
            return expected_root
    return ""


def _context_task_slug(request: PolicyRequest, *, fallback: str = "") -> str:
    candidates: list[str] = []
    lease = request.context.lease if isinstance(request.context.lease, dict) else {}
    for key in ("work_item_id", "workflow_id"):
        value = str(lease.get(key) or "")
        if value:
            candidates.append(value)
    for value in (request.context.workflow_id, request.context.branch, fallback):
        if value:
            candidates.append(str(value))
    for value in candidates:
        slug = sanitize_token(value)
        if slug:
            return slug
    return "scratchlane"


def _is_read_only_inline_filter(command: str) -> bool:
    if extract_bash_write_targets(command):
        return False
    match = _PIPE_INLINE_FILTER_RE.search(command)
    if not match:
        return False
    code = (match.group("code") or "").lower()
    if not code:
        return False
    if any(marker in code for marker in _FILTER_MUTATION_MARKERS):
        return False
    return (
        any(marker in code for marker in _FILTER_READ_MARKERS)
        and any(marker in code for marker in _FILTER_OUTPUT_MARKERS)
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
        scratch_root_display = f"tmp/{task_slug}/"
        active_root = _active_root(scratch_root, request.context.scratchlane_roots)
        if active_root:
            return PolicyDecision(
                action="deny",
                reason=(
                    f"BLOCKED: scratchlane '{task_slug}' is active at "
                    f"`{_root_display(active_root, scratch_root_display)}`, but this "
                    f"command targets `{target}`. Retry the command with the write "
                    "target under the active scratchlane root."
                ),
                policy_name="bash_scratchlane_gate",
            )
        return _admission_decision(
            request,
            trigger="bash_file_mutation",
            target_path=target,
            user_prompt=f"obvious scratchlane candidate: {info.kind}",
            task_slug=task_slug,
        )

    simple_argv = _simple_command_argv(command)
    wrapper_executable = _simple_command_executable(simple_argv)
    if wrapper_executable:
        if _is_scratchlane_exec_path(wrapper_executable, base_dir=base_dir):
            task_slug = sanitize_token(
                _wrapper_option(simple_argv, "--task-slug") or _context_task_slug(request)
            )
            if project_root and not _wrapper_project_root_matches(
                simple_argv,
                base_dir=base_dir,
                project_root=project_root,
            ):
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
            if project_root and not _active_scratch_root_for_task(
                project_root=project_root,
                task_slug=task_slug,
                scratch_roots=request.context.scratchlane_roots,
            ):
                scratch_root = scratchlane_root(project_root, task_slug)
                return _admission_decision(
                    request,
                    trigger="bash_opaque_interpreter",
                    target_path=os.path.join(scratch_root, ".scratchlane"),
                    user_prompt="runtime scratchlane wrapper declared an inactive task lane",
                    task_slug=task_slug,
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

    if _is_read_only_inline_filter(command):
        return None

    script_match = _SCRIPT_INTERPRETER_RE.search(command)
    inline_match = _INLINE_INTERPRETER_RE.search(command)
    if not script_match and not inline_match:
        return None

    task_slug = _context_task_slug(request)
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
    if not scratch_root:
        scratch_root = _active_scratch_root_for_task(
            project_root=project_root,
            task_slug=task_slug,
            scratch_roots=request.context.scratchlane_roots,
        )
    if scratch_root:
        needs_grant = False
    if not needs_grant:
        scratch_root_display = f"tmp/{task_slug}/"
        return PolicyDecision(
            action="deny",
            reason=(
                "BLOCKED: raw interpreter execution via Bash is opaque to the "
                "pre-tool write gate. Re-run the command through "
                f"`{_wrapper_command(task_slug, project_root=project_root)}` so "
                f"the interpreter is confined to `{scratch_root_display}`."
            ),
            policy_name="bash_scratchlane_gate",
        )

    return _admission_decision(
        request,
        trigger="bash_opaque_interpreter",
        target_path=requested_path,
        user_prompt=command,
        task_slug=task_slug,
    )


def register(registry) -> None:
    registry.register(
        "bash_scratchlane_gate",
        check,
        event_types=["Bash", "PreToolUse"],
        priority=260,
    )
