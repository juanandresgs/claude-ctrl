"""Guarded fast-path classifiers for routine local commits and small source fixes.

@decision DEC-POLICY-FASTPATH-001
Title: Non-source commit fast path is a shared policy classifier
Status: accepted
Rationale: v6 source landing remains gated by reviewer readiness, but small
  docs/config changes do not need the full source-review chain. The exception
  must be one shared classifier so lease, test, readiness, main-branch, and
  scope policies agree on exactly the same narrow boundary.
"""

from __future__ import annotations

import os
import re
import subprocess
from dataclasses import dataclass

from runtime.core.policy_engine import PolicyRequest
from runtime.core.policy_utils import is_governance_markdown, is_source_file

_ALLOWED_NON_SOURCE_ACTORS = frozenset({"", "root", "orchestrator", "planner", "Plan", "guardian"})
_SMALL_SOURCE_ACTOR = "guardian"
_MAX_FILES = 2
_SECRET_RE = re.compile(
    r"(BEGIN [A-Z ]*PRIVATE KEY|AWS_SECRET_ACCESS_KEY|API[_-]?KEY|PASSWORD|SECRET|TOKEN)",
    re.IGNORECASE,
)
_PROTECTED_SECTION_RE = re.compile(r"^[-+]\s{0,3}#{1,3}\s+(Identity|Architecture|Principles|Decision Log)\b")


@dataclass(frozen=True)
class FastPathDecision:
    eligible: bool
    reason: str
    files: tuple[str, ...] = ()


def guarded_non_source_commit(request: PolicyRequest) -> FastPathDecision:
    """Return whether this request qualifies for the guarded docs/config commit path."""

    intent = request.command_intent
    invocation = intent.git_invocation if intent is not None else None
    if invocation is None or invocation.subcommand != "commit":
        return FastPathDecision(False, "not_git_commit")
    if intent.git_op_class != "routine_local":
        return FastPathDecision(False, "not_routine_local")

    actor = request.context.actor_role or ""
    if actor not in _ALLOWED_NON_SOURCE_ACTORS:
        return FastPathDecision(False, f"actor_not_allowed:{actor or 'unknown'}")

    target_dir = request.context.project_root or intent.target_cwd or request.cwd or ""
    if not target_dir or not os.path.isdir(target_dir):
        return FastPathDecision(False, "target_dir_unavailable")

    files = _staged_files(target_dir)
    if not files:
        return FastPathDecision(False, "no_staged_files")
    if len(files) > _MAX_FILES:
        return FastPathDecision(False, f"too_many_files:{len(files)}")

    for path in files:
        if is_source_file(path):
            return FastPathDecision(False, f"source_file:{path}", tuple(files))
        if _looks_like_state_authority(path):
            return FastPathDecision(False, f"state_authority:{path}", tuple(files))

    diff = _staged_diff(target_dir, files)
    if _SECRET_RE.search(diff):
        return FastPathDecision(False, "secret_like_content", tuple(files))
    for path in files:
        if is_governance_markdown(path) and _PROTECTED_SECTION_RE.search(diff):
            return FastPathDecision(False, f"protected_governance_section:{path}", tuple(files))

    return FastPathDecision(True, "guarded_non_source_commit", tuple(files))


def guarded_small_source_commit(request: PolicyRequest) -> FastPathDecision:
    """Return whether this request qualifies for Guardian's small source lane."""

    intent = request.command_intent
    invocation = intent.git_invocation if intent is not None else None
    if invocation is None or invocation.subcommand != "commit":
        return FastPathDecision(False, "not_git_commit")
    if intent.git_op_class != "routine_local":
        return FastPathDecision(False, "not_routine_local")

    actor = request.context.actor_role or ""
    if actor != _SMALL_SOURCE_ACTOR:
        return FastPathDecision(False, f"actor_not_allowed:{actor or 'unknown'}")

    target_dir = request.context.project_root or intent.target_cwd or request.cwd or ""
    if not target_dir or not os.path.isdir(target_dir):
        return FastPathDecision(False, "target_dir_unavailable")

    files = _staged_files(target_dir)
    if not files:
        return FastPathDecision(False, "no_staged_files")
    if len(files) > _MAX_FILES:
        return FastPathDecision(False, f"too_many_files:{len(files)}", tuple(files))
    if not any(is_source_file(path) for path in files):
        return FastPathDecision(False, "no_source_files", tuple(files))

    for path in files:
        if _looks_like_state_authority(path):
            return FastPathDecision(False, f"state_authority:{path}", tuple(files))

    diff = _staged_diff(target_dir, files)
    if _SECRET_RE.search(diff):
        return FastPathDecision(False, "secret_like_content", tuple(files))
    for path in files:
        if is_governance_markdown(path) and _PROTECTED_SECTION_RE.search(diff):
            return FastPathDecision(False, f"protected_governance_section:{path}", tuple(files))

    return FastPathDecision(True, "guarded_small_source_commit", tuple(files))


def guardian_small_source_write_allowed(request: PolicyRequest, path: str) -> bool:
    """Return whether Guardian may edit one bounded source target directly."""

    actor = request.context.actor_role or ""
    if actor != _SMALL_SOURCE_ACTOR:
        return False
    if not is_source_file(path):
        return False
    check_path = _relative_to_project(request, path)
    if _looks_like_state_authority(check_path):
        return False
    target_dir = request.context.project_root or request.context.worktree_path or request.cwd or ""
    if not target_dir or not os.path.isdir(target_dir):
        return False
    files = set(_changed_files(target_dir))
    if check_path:
        files.add(check_path)
    if len(files) > _MAX_FILES:
        return False
    payload_text = _request_text_payload(request)
    if payload_text and _SECRET_RE.search(payload_text):
        return False
    return True


def _staged_files(target_dir: str) -> list[str]:
    try:
        proc = subprocess.run(
            ["git", "-C", target_dir, "diff", "--cached", "--name-only", "--diff-filter=ACMR"],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    if proc.returncode != 0:
        return []
    return [line.strip() for line in proc.stdout.splitlines() if line.strip()]


def _changed_files(target_dir: str) -> list[str]:
    try:
        proc = subprocess.run(
            ["git", "-C", target_dir, "status", "--porcelain", "--untracked-files=all"],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    if proc.returncode != 0:
        return []
    files: list[str] = []
    for line in proc.stdout.splitlines():
        if len(line) < 4:
            continue
        path = line[3:].strip()
        if " -> " in path:
            path = path.rsplit(" -> ", 1)[1].strip()
        if path:
            files.append(path)
    return files


def _staged_diff(target_dir: str, files: list[str]) -> str:
    try:
        proc = subprocess.run(
            ["git", "-C", target_dir, "diff", "--cached", "--unified=0", "--", *files],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return proc.stdout if proc.returncode == 0 else ""


def _looks_like_state_authority(path: str) -> bool:
    normalized = path.replace("\\", "/")
    return normalized.startswith(("runtime/", "hooks/", "sidecars/", "scripts/"))


def _relative_to_project(request: PolicyRequest, path: str) -> str:
    root = request.context.project_root or ""
    if not root:
        return path
    try:
        root_real = os.path.realpath(root)
        path_real = os.path.realpath(path)
        if path_real == root_real or path_real.startswith(root_real + os.sep):
            return os.path.relpath(path_real, root_real)
    except (OSError, ValueError):
        return path
    return path


def _request_text_payload(request: PolicyRequest) -> str:
    if not isinstance(request.tool_input, dict):
        return ""
    parts: list[str] = []
    for key in ("content", "new_string", "old_string", "command"):
        value = request.tool_input.get(key)
        if isinstance(value, str):
            parts.append(value)
    return "\n".join(parts)
