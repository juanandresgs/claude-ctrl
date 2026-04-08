"""Policy: bash_worktree_removal — safe worktree removal enforcement.

Port of guard.sh lines 230-248 (Check 7).

@decision DEC-PE-W3-005
Title: bash_worktree_removal requires safe CWD before git worktree remove
Status: accepted
Rationale: Running 'git worktree remove' while the shell CWD is inside the
  worktree being removed corrupts the session (cwd no longer exists after
  removal). The command must always be issued from a safe ancestor directory.
  This policy enforces two invariants:
    1. CWD must not be inside the worktree being removed.
    2. The command must include an explicit cd to a safe directory first.
  Both mirror the behavior of guard.sh Check 7.
"""

from __future__ import annotations

import re
import subprocess
from typing import Optional

from runtime.core.policy_engine import PolicyDecision, PolicyRequest

_WORKTREE_REMOVE_PATTERN = re.compile(r"git\s+worktree\s+remove")
_CD_PATTERN = re.compile(r"(^|[;&|]\s*)cd\s+")


def _get_main_worktree(target_dir: str) -> str:
    """Return the main worktree path (first line of git worktree list)."""
    try:
        result = subprocess.run(
            ["git", "-C", target_dir, "worktree", "list"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            first_line = result.stdout.strip().splitlines()[0] if result.stdout.strip() else ""
            if first_line:
                return first_line.split()[0]
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass
    return target_dir


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny git worktree remove when CWD is inside the target worktree,
    or when the command lacks an explicit cd to a safe directory.

    Source: guard.sh lines 230-248 (Check 7).
    """
    intent = request.command_intent
    command = request.tool_input.get("command", "")
    if not command or intent is None:
        return None

    if intent.worktree_action != "remove":
        return None

    wt_path_raw = intent.worktree_target_raw
    if not wt_path_raw:
        return None

    target_dir = intent.command_cwd or request.cwd or ""
    main_wt = _get_main_worktree(target_dir)
    wt_abs = intent.worktree_target_resolved

    input_cwd = request.cwd or ""

    # Check 1: CWD is inside the worktree being removed.
    if input_cwd and wt_abs and input_cwd.startswith(wt_abs):
        return PolicyDecision(
            action="deny",
            reason=(
                f"Cannot remove a worktree while the shell cwd is inside it. "
                f"First move to a safe directory, then run: "
                f'cd "{main_wt}" && git worktree remove "{wt_path_raw}"'
            ),
            policy_name="bash_worktree_removal",
        )

    # Check 2: Command doesn't include an explicit cd to anchor CWD.
    if not _CD_PATTERN.search(command):
        return PolicyDecision(
            action="deny",
            reason=(
                f"git worktree remove must be anchored from a safe cwd. Run: "
                f'cd "{main_wt}" && git worktree remove "{wt_path_raw}"'
            ),
            policy_name="bash_worktree_removal",
        )

    return None


def register(registry) -> None:
    """Register bash_worktree_removal into the given PolicyRegistry."""
    registry.register(
        "bash_worktree_removal",
        check,
        event_types=["Bash", "PreToolUse"],
        priority=700,
    )
