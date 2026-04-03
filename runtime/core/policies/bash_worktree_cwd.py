"""Policy: bash_worktree_cwd — deny bare cd into .worktrees/ directories.

Port of guard.sh lines 129-133 (Check 2).

@decision DEC-PE-W3-002
Title: bash_worktree_cwd denies bare cd into worktrees
Status: accepted
Rationale: Sacred Practice #3/#2 — entering a worktree with bare cd bricks
  the session if the worktree is later removed (cwd no longer exists).
  Use git -C or a subshell instead. This policy enforces the restriction
  at the hook layer before the cd executes.
"""

from __future__ import annotations

from typing import Optional

from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import extract_cd_target


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny bare cd into a .worktrees/ subdirectory.

    Allow: all other cd targets.
    Deny: any cd whose target path contains '.worktrees/'.

    Source: guard.sh lines 129-133 (Check 2).
    """
    command = request.tool_input.get("command", "")
    if not command:
        return None

    cd_target = extract_cd_target(command)
    if not cd_target:
        return None

    if ".worktrees/" not in cd_target:
        return None

    return PolicyDecision(
        action="deny",
        reason=(
            f"Do not enter worktrees with bare cd. "
            f"Use 'git -C \"{cd_target}\" <command>' for git, "
            f"or '(cd \"{cd_target}\" && <command>)' in a subshell "
            f"so the session cannot be bricked by later cleanup."
        ),
        policy_name="bash_worktree_cwd",
    )


def register(registry) -> None:
    """Register bash_worktree_cwd into the given PolicyRegistry."""
    registry.register(
        "bash_worktree_cwd",
        check,
        event_types=["Bash", "PreToolUse"],
        priority=200,
    )
