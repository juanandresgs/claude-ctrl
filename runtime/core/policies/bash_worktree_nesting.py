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
    2. Target path nesting: the target argument to git worktree add itself contains
       ".worktrees/" more than once, indicating an attempt to nest inside an existing
       worktree even when the CWD is clean.

  git worktree list, move, lock, and other subcommands are NOT blocked — only "add".
  Absolute paths that happen to contain ".worktrees/" only once (e.g.
  /project/.worktrees/feature-x) are the correct form and are allowed from the
  project root CWD.

  Priority 250 — runs before bash_git_who (300) so the nesting check fires
  before lease validation. A nesting attempt from inside a worktree is structural
  and must be denied regardless of lease state.
"""

from __future__ import annotations

import re
from typing import Optional

from runtime.core.policy_engine import PolicyDecision, PolicyRequest

_WORKTREE_ADD_RE = re.compile(r"\bgit\b.*\bworktree\s+add\b")

# Matches the target path argument after "worktree add" with optional flags.
# Handles: git worktree add [flags] <path> [<branch>]
# Flags: -b/-B <branch>, -f, --detach, --lock, --reason <str>, --track
_TARGET_PATH_RE = re.compile(
    r"\bworktree\s+add\s+"
    r"(?:(?:-[bBf]|--(detach|lock|force|track|reason\s+\S+))\s+\S*\s*)*"
    r'["\']?([^\s"\']+)'
)


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny git worktree add when CWD is inside an existing worktree, or when
    the target path would create a nested .worktrees/ structure.

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

    # Check 2: Target path nesting — target arg contains ".worktrees/" more than once.
    # A single ".worktrees/" occurrence is the correct form (e.g. .worktrees/feature-x).
    m = _TARGET_PATH_RE.search(command)
    if m:
        target = m.group(2)
        if target and target.count(".worktrees/") > 1:
            return PolicyDecision(
                action="deny",
                reason=(
                    f"Nested worktree detected in target path '{target}'. "
                    "Create worktrees from the project root only. "
                    "Use: git worktree add .worktrees/<name> -b <branch>"
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
