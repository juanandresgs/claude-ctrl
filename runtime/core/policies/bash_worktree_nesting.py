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
Title: bash_worktree_nesting consumes runtime-owned command intent, not a local parser
Status: accepted
Rationale: RCA-3 (#23) found that policy-local regex parsing for
  `git worktree add` was brittle around flags like --no-checkout, -B, --reason,
  and -- end-of-options, and it duplicated the shell/token interpretation that
  other policies also needed. The parser authority now lives in
  runtime/core/command_intent.py, which tokenizes the command once and exposes:
    1. The effective command cwd, including git -C and cd ... prefixes.
    2. The parsed worktree action (add/remove).
    3. The resolved worktree target path.
    4. A fail-closed shell_parse_error signal for malformed commands.
  This policy now consumes that shared intent instead of reparsing raw bash.
"""

from __future__ import annotations

import os
from typing import Optional

from runtime.core.policy_engine import PolicyDecision, PolicyRequest


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny git worktree add when CWD is inside an existing worktree, or when
    the target path (resolved via realpath) would create a nested .worktrees/
    structure.

    Returns None (no opinion) for all non-worktree-add commands.
    """
    intent = request.command_intent
    if intent is None:
        return None

    if intent.shell_parse_error and intent.likely_worktree_add:
        return PolicyDecision(
            action="deny",
            reason=(
                "Cannot parse git worktree add command (unmatched quotes or "
                "shell syntax). Rewrite the command with explicit quoting."
            ),
            policy_name="bash_worktree_nesting",
        )

    if intent.worktree_action != "add":
        return None

    # Check 1: CWD nesting — caller is inside a .worktrees/ directory.
    effective_cwd = intent.command_cwd or request.cwd or request.context.worktree_path or ""
    if ".worktrees/" in effective_cwd or "/.worktrees/" in effective_cwd:
        return PolicyDecision(
            action="deny",
            reason=(
                f"Cannot create worktrees from inside another worktree ({effective_cwd}). "
                "Run 'git worktree add' from the project root to prevent nesting. "
                "Nested worktrees are destroyed when the outer worktree is removed."
            ),
            policy_name="bash_worktree_nesting",
        )

    resolved = intent.worktree_target_resolved
    if not resolved:
        # Could not extract a target — no opinion (let other checks handle it).
        return None

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
