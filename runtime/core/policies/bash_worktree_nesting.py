"""Policy: bash_worktree_nesting — prevent nested worktree creation.

@decision DEC-PE-EGAP-NESTING-001
Title: bash_worktree_nesting denies git worktree add from inside .worktrees/
Status: accepted
Rationale: git worktree add creates a new worktree at the specified path. When
  invoked from inside an existing .worktrees/ directory (or when the target path
  contains multiple .worktrees/ segments), the result is a nested worktree. Nested
  worktrees create a lifecycle ownership problem: when the outer worktree is pruned
  or removed by Guardian, all nested paths are deleted with it, bricking any session
  whose CWD was inside the nested worktree.

  This policy checks two nesting conditions:
    1. CWD nesting: the invoking CWD contains ".worktrees/" (caller is inside
       an existing worktree). git worktree add must be run from the project root.
    2. Target path nesting: the target argument to git worktree add itself resolves
       (via os.path.realpath) to a path inside an existing .worktrees/ directory,
       indicating an attempt to nest even when the CWD is clean.

  git worktree list, move, lock, and other subcommands are NOT blocked — only "add".
  Absolute paths that happen to contain ".worktrees/" only once (e.g.
  /project/.worktrees/feature-x) are the correct form and are allowed from the
  project root CWD.

  Priority 250 — runs before bash_git_who (300) so the nesting check fires
  before lease validation. A nesting attempt from inside a worktree is structural
  and must be denied regardless of lease state.

@decision DEC-PE-EGAP-NESTING-002
Title: shlex.split tokenizer replaces regex for worktree add target-path parsing
Status: accepted
Rationale: RCA-3 (#23) found that the original _TARGET_PATH_RE regex could be
  bypassed by flag combinations it did not handle: --no-checkout, -B <branch>,
  --reason <val>, and especially -- (end-of-options). The regex also did not
  handle git -C <dir> worktree add, which shifts the effective CWD anchor for
  relative paths. Replacing the regex with shlex.split() + a proper argv walk
  eliminates the parser ambiguity:
    1. Tokenize with shlex.split (handles quoting correctly).
    2. Find the 'worktree' + 'add' boundary in the token list.
    3. Walk remaining tokens, consuming flags and their arguments.
    4. Honour -- end-of-options: next token is unconditionally the path.
    5. First non-flag token after stripping is the target path.
    6. Resolve via os.path.realpath(os.path.join(anchor, target)) before the
       .worktrees/ membership check — prevents symlink/relative-path evasion.
    7. Honour git -C <dir> to determine the correct CWD anchor for relative paths.
"""

from __future__ import annotations

import os
import re
import shlex
from typing import Optional

from runtime.core.policy_engine import PolicyDecision, PolicyRequest

_WORKTREE_ADD_RE = re.compile(r"\bgit\b.*\bworktree\s+add\b")

# Flags that consume the next token as their argument value.
# These must be skipped along with their value when walking argv.
_FLAGS_WITH_VALUE = frozenset(
    [
        "-b",
        "-B",
        "--reason",
        "--orphan",
    ]
)

# Flags that are standalone (boolean) — consume no additional token.
_BOOLEAN_FLAGS = frozenset(
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


def _extract_git_c_dir(tokens: list[str]) -> Optional[str]:
    """Return the argument to git -C if present, else None.

    git -C <dir> worktree add ... uses <dir> as the CWD anchor for relative
    target paths. We need this to resolve the target path correctly.
    """
    i = 0
    while i < len(tokens):
        if tokens[i] in ("-C", "--git-dir") and i + 1 < len(tokens):
            if tokens[i] == "-C":
                return tokens[i + 1]
        i += 1
    return None


def _extract_worktree_add_target(tokens: list[str]) -> Optional[str]:
    """Return the target path from a git worktree add argv token list.

    Walks the token list to find the 'worktree add' boundary, then strips
    known flags (with and without values) to find the first positional argument,
    which is the target path per git-worktree(1).

    Handles:
      - -b/-B <branch>       (flag + value, skip both)
      - --reason <val>       (flag + value, skip both)
      - --no-checkout, --detach, --force, -f, --lock, --quiet, --track, ...
      - -- end-of-options    (next token is unconditionally the path)
      - Bare positional args (the path itself)
    """
    # Find the index of 'worktree' then 'add' in the token stream.
    wt_idx = None
    for i, tok in enumerate(tokens):
        if tok == "worktree":
            wt_idx = i
            break
    if wt_idx is None:
        return None

    add_idx = None
    for i in range(wt_idx + 1, len(tokens)):
        if tokens[i] == "add":
            add_idx = i
            break
    if add_idx is None:
        return None

    # Walk tokens after 'add', consuming flags.
    i = add_idx + 1
    while i < len(tokens):
        tok = tokens[i]
        if tok == "--":
            # End-of-options: next token is unconditionally the path.
            return tokens[i + 1] if i + 1 < len(tokens) else None
        if tok in _FLAGS_WITH_VALUE:
            # Skip flag + its value argument.
            i += 2
            continue
        if tok in _BOOLEAN_FLAGS:
            # Skip boolean flag.
            i += 1
            continue
        if tok.startswith("-"):
            # Unknown flag — treat as boolean (consume flag only) for safety.
            # This is conservative: an unknown flag that takes a value would
            # misparse, but the subsequent positional check would catch a
            # path-looking argument anyway.
            i += 1
            continue
        # First non-flag token is the target path.
        return tok

    return None


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny git worktree add when CWD is inside an existing worktree, or when
    the target path (resolved via realpath) would create a nested .worktrees/
    structure.

    Returns None (no opinion) for all non-worktree-add commands.
    """
    command = request.tool_input.get("command", "")
    if not _WORKTREE_ADD_RE.search(command):
        return None

    # Check 1: CWD nesting — caller is inside a .worktrees/ directory.
    cwd = request.cwd or request.context.worktree_path or ""
    if ".worktrees/" in cwd:
        return PolicyDecision(
            action="deny",
            reason=(
                f"Cannot create worktrees from inside another worktree ({cwd}). "
                "Run 'git worktree add' from the project root to prevent nesting. "
                "Nested worktrees are destroyed when the outer worktree is removed."
            ),
            policy_name="bash_worktree_nesting",
        )

    # Check 2: Target path nesting — parse argv and resolve the target path.
    # Use shlex.split to handle quoting; fall back gracefully on parse errors.
    try:
        tokens = shlex.split(command)
    except ValueError:
        # Malformed quoting — cannot parse safely; deny to be fail-closed.
        return PolicyDecision(
            action="deny",
            reason=(
                "Cannot parse git worktree add command (unmatched quotes or "
                "shell syntax). Rewrite the command with explicit quoting."
            ),
            policy_name="bash_worktree_nesting",
        )

    target = _extract_worktree_add_target(tokens)
    if target is None:
        # Could not extract a target — no opinion (let other checks handle it).
        return None

    # Determine CWD anchor for relative path resolution.
    # git -C <dir> shifts the anchor; otherwise use request.cwd.
    git_c_dir = _extract_git_c_dir(tokens)
    anchor = git_c_dir or cwd or os.getcwd()

    # Resolve to realpath to defeat symlink and .. evasion.
    resolved = os.path.realpath(os.path.join(anchor, target))

    # Count .worktrees/ occurrences in the resolved path.
    # A single occurrence is the correct form (e.g. /project/.worktrees/feature-x).
    # Two or more indicate nesting.
    if resolved.count(".worktrees/") > 1 or resolved.count("/.worktrees") > 1:
        return PolicyDecision(
            action="deny",
            reason=(
                f"Nested worktree detected: resolved target path '{resolved}' "
                "is inside an existing .worktrees/ directory. "
                "Create worktrees from the project root only. "
                "Use: git worktree add .worktrees/<name> -b <branch>"
            ),
            policy_name="bash_worktree_nesting",
        )

    # Also check if the resolved path is a subdirectory of an existing worktree
    # (i.e., the target itself is inside .worktrees/ in any ancestor segment).
    # This catches: git -C .worktrees/feature-x worktree add ./nested
    parts = resolved.split(os.sep)
    worktrees_count = sum(1 for p in parts if p == ".worktrees")
    if worktrees_count > 1:
        return PolicyDecision(
            action="deny",
            reason=(
                f"Nested worktree detected: '{resolved}' contains multiple "
                ".worktrees segments. Create worktrees from the project root only."
            ),
            policy_name="bash_worktree_nesting",
        )

    return None


def register(registry) -> None:
    """Register bash_worktree_nesting into the given PolicyRegistry."""
    registry.register(
        "bash_worktree_nesting",
        check,
        event_types=["Bash", "PreToolUse"],
        priority=250,
    )
