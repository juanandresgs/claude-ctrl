"""Runtime-owned bash command intent parsing.

This module is the single authority for deriving structured intent from a raw
Bash command string. Hooks should forward raw command text only; the runtime
constructs a typed view once and policies consume that shared object.
"""

from __future__ import annotations

import os
import shlex
from dataclasses import dataclass
import re
from typing import Optional

from runtime.core.leases import (
    GitInvocation,
    _shell_tokens,
    classify_git_invocation,
    classify_git_op,
    parse_git_invocations,
)
from runtime.core.policy_utils import (
    extract_cd_target,
    extract_git_target_dir,
    normalize_path,
    resolve_path_from_base,
)

_WRITE_TARGET_SHELL_SEPARATORS = frozenset({";", "&&", "||", "|", "&"})
_WRITE_TARGET_REDIRECT_TOKENS = frozenset({">", ">>", "1>", "1>>", "2>", "2>>"})
_WRITE_TARGET_MUTATING_COMMANDS = frozenset({"cp", "mv", "install", "touch", "truncate"})

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


@dataclass(frozen=True)
class GitOperationIntent:
    """One parsed git invocation plus its policy operation class."""

    invocation: GitInvocation
    op_class: str


@dataclass(frozen=True)
class BashCommandIntent:
    """Structured intent derived from a raw bash command string."""

    command: str
    shell_parse_error: bool
    git_invocation: Optional[GitInvocation]
    git_invocations: tuple[GitInvocation, ...]
    git_operations: tuple[GitOperationIntent, ...]
    git_op_class: str
    target_cwd: str
    command_cwd: str
    cd_target: str
    cd_target_resolved: str
    worktree_action: Optional[str]
    worktree_target_raw: str
    worktree_target_resolved: str
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


def _first_worktree_invocation(invocations: tuple[GitInvocation, ...]) -> Optional[GitInvocation]:
    for invocation in invocations:
        if invocation.subcommand == "worktree" and invocation.args:
            return invocation
    return None


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


def extract_bash_write_targets(command: str) -> set[str]:
    """Return the raw shell-level write targets referenced by ``command``.

    Recognizes three classes of write-producing constructs:
      - redirection targets after ``>``, ``>>``, ``1>``, ``1>>``, ``2>``, ``2>>``
      - ``tee`` argument targets (positional, pre-separator)
      - last positional of ``cp`` / ``mv`` / ``install`` / ``touch`` / ``truncate``

    Tokenization uses ``shlex`` with ``><;&|`` as punctuation so redirects glued
    to their targets (``>/etc/x``) split correctly. This is the single
    authority for this form of bash target extraction; policies consume it
    rather than reimplementing tokenization.
    """
    targets: set[str] = set()
    if not command:
        return targets
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars="><;&|")
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:
        return targets

    index = 0
    while index < len(tokens):
        token = tokens[index]

        if token in _WRITE_TARGET_REDIRECT_TOKENS and index + 1 < len(tokens):
            target = tokens[index + 1]
            if (
                target
                and target not in _WRITE_TARGET_SHELL_SEPARATORS
                and target not in _WRITE_TARGET_REDIRECT_TOKENS
            ):
                targets.add(target)
            index += 2
            continue

        cmd = os.path.basename(token)
        if cmd == "tee":
            cursor = index + 1
            while cursor < len(tokens) and tokens[cursor] not in _WRITE_TARGET_SHELL_SEPARATORS:
                arg = tokens[cursor]
                if arg and not arg.startswith("-") and arg not in _WRITE_TARGET_REDIRECT_TOKENS:
                    targets.add(arg)
                cursor += 1
            index = cursor
            continue

        if cmd in _WRITE_TARGET_MUTATING_COMMANDS:
            cursor = index + 1
            args: list[str] = []
            while cursor < len(tokens) and tokens[cursor] not in _WRITE_TARGET_SHELL_SEPARATORS:
                args.append(tokens[cursor])
                cursor += 1
            positional = [a for a in args if a and not a.startswith("-")]
            if positional:
                targets.add(positional[-1])
            index = cursor
            continue

        index += 1

    return targets


def build_bash_command_intent(command: str, *, cwd: str = "") -> Optional[BashCommandIntent]:
    """Build a structured command-intent object from raw bash text.

    The intent carries the single runtime-owned interpretation of the command:
      - git_invocations / git_operations: canonical git classification
      - target_cwd / command_cwd: repo-target and effective execution cwd
      - cd_target*: bare-cd targeting for worktree safety policies
      - worktree_*: explicit add/remove semantics and resolved targets

    Returning None for an empty command keeps non-bash callers lightweight.
    """
    if not command:
        return None

    shell_parse_error = False
    try:
        _shell_tokens(command)
    except ValueError:
        shell_parse_error = True

    git_invocations = parse_git_invocations(command)
    git_invocation = git_invocations[0] if git_invocations else None
    git_operations = tuple(
        GitOperationIntent(invocation=invocation, op_class=classify_git_invocation(invocation))
        for invocation in git_invocations
    )
    git_op_class = classify_git_op(command) if git_invocations else "unclassified"
    base_cwd = normalize_path(cwd) if cwd else ""
    cd_target = extract_cd_target(command) or ""
    cd_target_resolved = _resolve_from_base(base_cwd or cwd, cd_target) if cd_target else ""
    git_c_arg = _extract_git_c_arg(git_invocation)
    command_cwd = cd_target_resolved or _resolve_from_base(base_cwd or cwd, git_c_arg) or base_cwd
    target_cwd = extract_git_target_dir(command, cwd=cwd)
    worktree_action = None
    worktree_target_raw = ""
    worktree_target_resolved = ""
    worktree_invocation = _first_worktree_invocation(git_invocations)
    if worktree_invocation is not None:
        worktree_action = worktree_invocation.args[0]
        if worktree_action == "add":
            worktree_target_raw = _extract_worktree_add_target(list(worktree_invocation.args))
        elif worktree_action == "remove":
            worktree_target_raw = _extract_worktree_remove_target(list(worktree_invocation.args))
        if worktree_target_raw:
            anchor = command_cwd or base_cwd or cwd
            worktree_target_resolved = _resolve_from_base(anchor, worktree_target_raw)

    return BashCommandIntent(
        command=command,
        shell_parse_error=shell_parse_error,
        git_invocation=git_invocation,
        git_invocations=git_invocations,
        git_operations=git_operations,
        git_op_class=git_op_class,
        target_cwd=target_cwd,
        command_cwd=command_cwd,
        cd_target=cd_target,
        cd_target_resolved=cd_target_resolved,
        worktree_action=worktree_action,
        worktree_target_raw=worktree_target_raw,
        worktree_target_resolved=worktree_target_resolved,
        likely_worktree_add=bool(_WORKTREE_ADD_RE.search(command)),
        likely_worktree_remove=bool(_WORKTREE_REMOVE_RE.search(command)),
    )
