"""Policy: bash_force_push — deny unsafe force pushes.

Port of guard.sh lines 206-215 (Check 5).

@decision DEC-PE-W3-003
Title: bash_force_push blocks force push to main and raw --force
Status: accepted
Rationale: Force pushing rewrites shared history. Pushing to main/master
  is always denied. Pushing with raw --force (instead of --force-with-lease)
  is denied because --force-with-lease preserves remote changes as a safety net.
  This policy fires before the push executes.
"""

from __future__ import annotations

import re
from typing import Optional

from runtime.core.policy_engine import PolicyDecision, PolicyRequest

_FORCE_PUSH_PATTERN = re.compile(r"\bgit\b.*\bpush\b.*(-f\b|--force\b)", re.DOTALL)
_MAIN_MASTER_PATTERN = re.compile(r"(origin|upstream)\s+(main|master)\b")
_FORCE_WITH_LEASE_PATTERN = re.compile(r"--force-with-lease")


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny force pushes that target main/master or omit --force-with-lease.

    Cases:
      1. git push --force (or -f) targeting main/master → hard deny.
      2. git push --force (or -f) without --force-with-lease → deny with suggestion.
      3. git push --force-with-lease → no opinion (allow through).

    Source: guard.sh lines 206-215 (Check 5).
    """
    command = request.tool_input.get("command", "")
    if not command:
        return None

    if not _FORCE_PUSH_PATTERN.search(command):
        return None

    # Case 1: force push to main/master — hard deny regardless of flag form.
    if _MAIN_MASTER_PATTERN.search(command):
        return PolicyDecision(
            action="deny",
            reason=(
                "Cannot force push to main/master. "
                "This is a destructive action that rewrites shared history."
            ),
            policy_name="bash_force_push",
        )

    # Case 2: raw --force without --force-with-lease.
    if not _FORCE_WITH_LEASE_PATTERN.search(command):
        safer = re.sub(r"--force(?!-with-lease)", "--force-with-lease", command)
        safer = re.sub(r"\s-f(\s|$)", " --force-with-lease\\1", safer)
        return PolicyDecision(
            action="deny",
            reason=(
                f"Do not use raw force push. Use --force-with-lease so remote changes "
                f"are protected: {safer}"
            ),
            policy_name="bash_force_push",
        )

    return None


def register(registry) -> None:
    """Register bash_force_push into the given PolicyRegistry."""
    registry.register(
        "bash_force_push",
        check,
        event_types=["Bash", "PreToolUse"],
        priority=500,
    )
