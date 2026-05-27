"""Runtime-owned bash command intent parsing.

This module is the single authority for deriving structured intent from a raw
Bash command string. Hooks should forward raw command text only; the runtime
constructs a typed view once and policies consume that shared object.
"""

from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Optional

from runtime.core.leases import (
    GitInvocation,
    _shell_tokens,
    classify_git_op,
    parse_git_invocation,
)
from runtime.core.policy_utils import (
    extract_cd_target,
    extract_git_target_dir,
    normalize_path,
    resolve_path_from_base,
)

_WORKTREE_ADD_RE = re.compile(r"\bgit\b.*\bworktree\s+add\b")
_WORKTREE_REMOVE_RE = re.compile(r"\bgit\b.*\bworktree\s+remove\b")
_WORKTREE_FLAGS_WITH_VALUE = frozenset(
    [
        "-b",
        "-B",
        "--reason",
        "--orphan",
    ]
)
_WORKTREE_BOOLEAN_FLAGS = frozenset(
    [
        "--no-checkout",
        "--detach",
        "--force",
        "-f",
        "--lock",
        "--quiet",
        "-q",
        "--track",
        "--guess-remote",
    ]
)
_WORKTREE_REMOVE_BOOLEAN_FLAGS = frozenset(["-f", "--force"])
_OUTPUT_REDIRECT_OP_RE = re.compile(r"^(?:\d*)?(?:&>>|&>|>>|>\||>)(.*)$")
_SHELL_WRITE_COMMANDS = frozenset({"cp", "mv", "touch"})


@dataclass(frozen=True)
class BashCommandIntent:
    """Structured intent derived from a raw bash command string."""

    command: str
    shell_parse_error: bool
    git_invocation: Optional[GitInvocation]
    git_op_class: str
    target_cwd: str
    command_cwd: str
    cd_target: str
    cd_target_resolved: str
    worktree_action: Optional[str]
    worktree_target_raw: str
    worktree_target_resolved: str
    shell_write_targets: tuple[str, ...]
    likely_worktree_add: bool
    likely_worktree_remove: bool


def _resolve_from_base(base: str, candidate: str) -> str:
    if not candidate:
        return ""
    resolved = resolve_path_from_base(base, candidate)
    return normalize_path(resolved) if resolved else ""


def _extract_git_c_arg(invocation: Optional[GitInvocation]) -> str:
    """Return the raw argument to git -C, if present."""
    if invocation is None:
        return ""

    argv = list(invocation.argv)
    index = 1
    while index < len(argv):
        token = argv[index]
        if token == "-C" and index + 1 < len(argv):
            return argv[index + 1]
        if token.startswith("-C") and token != "-C":
            return token[2:]
        if token == "-c":
            index += 2
            continue
        if token.startswith("-c") and token != "-c":
            index += 1
            continue
        if token.startswith("-"):
            index += 1
            continue
        break
    return ""


def _extract_worktree_add_target(args: list[str]) -> str:
    if not args or args[0] != "add":
        return ""

    index = 1
    while index < len(args):
        token = args[index]
        if token == "--":
            return args[index + 1] if index + 1 < len(args) else ""
        if token in _WORKTREE_FLAGS_WITH_VALUE:
            index += 2
            continue
        if token in _WORKTREE_BOOLEAN_FLAGS:
            index += 1
            continue
        if token.startswith("-"):
            index += 1
            continue
        return token
    return ""


def _extract_worktree_remove_target(args: list[str]) -> str:
    if not args or args[0] != "remove":
        return ""

    index = 1
    while index < len(args):
        token = args[index]
        if token == "--":
            return args[index + 1] if index + 1 < len(args) else ""
        if token in _WORKTREE_REMOVE_BOOLEAN_FLAGS:
            index += 1
            continue
        if token.startswith("-"):
            index += 1
            continue
        return token
    return ""


def _segment_command_index(segment: list[str]) -> int:
    index = 0
    while index < len(segment) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=.*$", segment[index]):
        index += 1
    while index < len(segment) and segment[index] in {"command", "builtin"}:
        index += 1
    return index


def _is_output_redirect_token(token: str) -> bool:
    return bool(_OUTPUT_REDIRECT_OP_RE.match(token))


def _extract_tee_targets(segment: list[str]) -> list[str]:
    cmd_index = _segment_command_index(segment)
    if cmd_index >= len(segment) or segment[cmd_index] != "tee":
        return []

    targets: list[str] = []
    index = cmd_index + 1
    while index < len(segment):
        token = segment[index]
        if token == "--":
            index += 1
            continue
        if _is_output_redirect_token(token):
            index += 1
            continue
        if token.startswith("-"):
            index += 1
            continue
        targets.append(token)
        index += 1
    return targets


def _extract_simple_write_targets(segment: list[str]) -> list[str]:
    cmd_index = _segment_command_index(segment)
    if cmd_index >= len(segment):
        return []

    command = segment[cmd_index]
    if command not in _SHELL_WRITE_COMMANDS:
        return []

    operands = [
        token
        for token in segment[cmd_index + 1 :]
        if not token.startswith("-") and not _is_output_redirect_token(token)
    ]
    if command in {"cp", "mv"}:
        return operands[-1:] if len(operands) >= 2 else []
    return operands


_SHELL_SEGMENT_SEPARATORS = frozenset({"|", "&&", "||", ";", "&"})


def _split_shell_segments(tokens: list[str]) -> list[list[str]]:
    """Split token list into segments separated by shell operators."""
    segments: list[list[str]] = []
    current: list[str] = []
    for token in tokens:
        if token in _SHELL_SEGMENT_SEPARATORS:
            if current:
                segments.append(current)
            current = []
        else:
            current.append(token)
    if current:
        segments.append(current)
    return segments


def _extract_shell_write_target_tokens(tokens: list[str]) -> list[str]:
    targets: list[str] = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        match = _OUTPUT_REDIRECT_OP_RE.match(token)
        if match:
            attached = match.group(1)
            if attached:
                targets.append(attached)
            elif index + 1 < len(tokens):
                targets.append(tokens[index + 1])
                index += 1
        index += 1

    for segment in _split_shell_segments(tokens):
        targets.extend(_extract_tee_targets(segment))
        targets.extend(_extract_simple_write_targets(segment))
    return targets


def build_bash_command_intent(command: str, *, cwd: str = "") -> Optional[BashCommandIntent]:
    """Build a structured command-intent object from raw bash text.

    The intent carries the single runtime-owned interpretation of the command:
      - git_invocation / git_op_class: canonical git classification
      - target_cwd / command_cwd: repo-target and effective execution cwd
      - cd_target*: bare-cd targeting for worktree safety policies
      - worktree_*: explicit add/remove semantics and resolved targets

    Returning None for an empty command keeps non-bash callers lightweight.
    """
    if not command:
        return None

    shell_parse_error = False
    tokens: list[str] = []
    try:
        tokens = _shell_tokens(command)
    except ValueError:
        shell_parse_error = True

    git_invocation = parse_git_invocation(command)
    git_op_class = classify_git_op(command) if git_invocation is not None else "unclassified"
    base_cwd = normalize_path(cwd) if cwd else ""
    cd_target = extract_cd_target(command) or ""
    cd_target_resolved = _resolve_from_base(base_cwd or cwd, cd_target) if cd_target else ""
    git_c_arg = _extract_git_c_arg(git_invocation)
    command_cwd = cd_target_resolved or _resolve_from_base(base_cwd or cwd, git_c_arg) or base_cwd
    target_cwd = extract_git_target_dir(command, cwd=cwd)
    worktree_action = None
    worktree_target_raw = ""
    worktree_target_resolved = ""
    if git_invocation is not None and git_invocation.subcommand == "worktree" and git_invocation.args:
        worktree_action = git_invocation.args[0]
        if worktree_action == "add":
            worktree_target_raw = _extract_worktree_add_target(list(git_invocation.args))
        elif worktree_action == "remove":
            worktree_target_raw = _extract_worktree_remove_target(list(git_invocation.args))
        if worktree_target_raw:
            anchor = command_cwd or base_cwd or cwd
            worktree_target_resolved = _resolve_from_base(anchor, worktree_target_raw)
    shell_write_targets: list[str] = []
    for target in _extract_shell_write_target_tokens(tokens):
        if not target or target.startswith("&"):
            continue
        anchor = command_cwd or base_cwd or cwd
        shell_write_targets.append(_resolve_from_base(anchor, target))

    return BashCommandIntent(
        command=command,
        shell_parse_error=shell_parse_error,
        git_invocation=git_invocation,
        git_op_class=git_op_class,
        target_cwd=target_cwd,
        command_cwd=command_cwd,
        cd_target=cd_target,
        cd_target_resolved=cd_target_resolved,
        worktree_action=worktree_action,
        worktree_target_raw=worktree_target_raw,
        worktree_target_resolved=worktree_target_resolved,
        shell_write_targets=tuple(shell_write_targets),
        likely_worktree_add=bool(_WORKTREE_ADD_RE.search(command)),
        likely_worktree_remove=bool(_WORKTREE_REMOVE_RE.search(command)),
    )
