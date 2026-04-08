"""Policy: bash_destructive_git — deny git reset --hard, clean -f, branch -D.

Port of guard.sh lines 217-228 (Check 6).

@decision DEC-PE-W3-004
Title: bash_destructive_git is the hard block for three destructive git patterns
Status: accepted
Rationale: These three commands permanently discard work with no recovery path
  short of reflog archaeology. They are unconditionally denied — no approval
  token can override them. Users who genuinely need these operations must do
  so outside the agent session. The guard exists to protect agents from
  accidentally destroying work during automated operations.
"""

from __future__ import annotations

import re
from typing import Optional

from runtime.core.policy_engine import PolicyDecision, PolicyRequest

_RESET_HARD = re.compile(r"\bgit\b.*\breset\b.*--hard")
_CLEAN_F = re.compile(r"\bgit\b.*\bclean\b.*-f")
_BRANCH_D = re.compile(r"\bgit\b.*\bbranch\b.*-D\b")


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Hard-deny git reset --hard, git clean -f, and git branch -D.

    These are unconditional denies — no approval token overrides them.
    Check 13 (approval_gate) fires after this check in priority order,
    but these patterns are caught first (priority=600 < approval_gate=1100).

    Source: guard.sh lines 217-228 (Check 6).
    """
    intent = request.command_intent
    if intent is None:
        return None

    invocation = intent.git_invocation
    if invocation is None:
        return None

    canonical = " ".join(invocation.argv)

    if _RESET_HARD.search(canonical):
        return PolicyDecision(
            action="deny",
            reason=(
                "git reset --hard is destructive and discards uncommitted work. "
                "Use git stash or create a backup branch first."
            ),
            policy_name="bash_destructive_git",
        )

    if _CLEAN_F.search(canonical):
        return PolicyDecision(
            action="deny",
            reason=(
                "git clean -f permanently deletes untracked files. "
                "Use git clean -n (dry run) first to see what would be deleted."
            ),
            policy_name="bash_destructive_git",
        )

    if _BRANCH_D.search(canonical):
        return PolicyDecision(
            action="deny",
            reason=(
                "git branch -D force-deletes a branch even if unmerged. "
                "Use git branch -d (lowercase) for safe deletion."
            ),
            policy_name="bash_destructive_git",
        )

    return None


def register(registry) -> None:
    """Register bash_destructive_git into the given PolicyRegistry."""
    registry.register(
        "bash_destructive_git",
        check,
        event_types=["Bash", "PreToolUse"],
        priority=600,
    )
