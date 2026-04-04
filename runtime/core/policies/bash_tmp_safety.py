"""Policy: bash_tmp_safety — deny writes to /tmp and /private/tmp.

Port of guard.sh lines 84-96 (Check 1).

@decision DEC-PE-W3-001
Title: bash_tmp_safety is the sole authority for /tmp write enforcement
Status: accepted
Rationale: Sacred Practice #3 requires artifacts stay with their project.
  Writing to /tmp scatters artifacts across the system and makes them
  invisible to git. This policy enforces the rule at the hook layer so
  no agent can accidentally or intentionally litter the system /tmp.
  Claude's own scratchpad (/private/tmp/claude-*) is the sole exception —
  that directory is managed by Claude Code itself, not by agent commands.
"""

from __future__ import annotations

import re
from typing import Optional

from runtime.core.policy_engine import PolicyDecision, PolicyRequest

# Pattern: writes, moves, copies, tees, and mkdir targeting /tmp or /private/tmp.
# On macOS /tmp is a symlink to /private/tmp — both must be caught.
_TMP_PATTERN = re.compile(
    r"(>|>>|mv\s+.*|cp\s+.*|tee)\s*(/private)?/tmp/"
    r"|mkdir\s+(-p\s+)?(/private)?/tmp/",
    re.IGNORECASE,
)

# Exception: Claude Code's own scratchpad directory.
_CLAUDE_SCRATCHPAD = "/private/tmp/claude-"


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny shell commands that write into /tmp or /private/tmp.

    Allow: /private/tmp/claude-* (Claude Code scratchpad — managed by the harness).
    Deny: any other write, redirect, move, copy, tee, or mkdir into /tmp.

    Source: guard.sh lines 84-96 (Check 1).
    """
    command = request.tool_input.get("command", "")
    if not command:
        return None

    if not _TMP_PATTERN.search(command):
        return None

    # Claude scratchpad exception
    if _CLAUDE_SCRATCHPAD in command:
        return None

    project_root = request.context.project_root or ""
    project_tmp = f"{project_root}/tmp" if project_root else "PROJECT_ROOT/tmp"

    # Suggest the corrected command: replace /private/tmp/ and /tmp/ with project tmp.
    suggested = command.replace("/private/tmp/", "/tmp/").replace("/tmp/", f"{project_tmp}/")

    return PolicyDecision(
        action="deny",
        reason=(
            f"Do not write artifacts under /tmp. Sacred Practice #3 keeps artifacts with "
            f'their project. Use: mkdir -p "{project_tmp}" && {suggested}'
        ),
        policy_name="bash_tmp_safety",
    )


def register(registry) -> None:
    """Register bash_tmp_safety into the given PolicyRegistry."""
    registry.register(
        "bash_tmp_safety",
        check,
        event_types=["Bash", "PreToolUse"],
        priority=100,
    )
