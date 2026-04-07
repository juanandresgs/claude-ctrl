"""Policy: bash_worktree_creation — deny `git worktree add` from non-guardian roles.

W-GWT-3 enforcement: Guardian is the sole worktree lifecycle authority
(DEC-GUARD-WT-002). The provision CLI (`cc-policy worktree provision`)
is the only sanctioned creation path — it handles git side effects,
DB registration, lease issuance, and workflow binding atomically.

Any non-guardian agent running `git worktree add` directly bypasses the
provision sequence, leaving the new worktree without:
  - A Guardian lease at PROJECT_ROOT (check-guardian.sh can't find it)
  - An implementer lease at worktree_path (subagent-start.sh has no claim)
  - A workflow binding (dispatch_engine can't route the rework path)

This policy catches the bypass at the PreToolUse boundary so the failure
is immediate and the error message is actionable.

@decision DEC-GWT-3-POLICY-001
Title: bash_worktree_creation enforces Guardian as sole worktree lifecycle authority
Status: accepted
Rationale: W-GWT-2 made Guardian the sole creator of worktrees via
  `cc-policy worktree provision`. Without this policy, implementers (and other
  roles) could still run `git worktree add` directly, bypassing the provision
  sequence and leaving the system in an inconsistent state: worktree on the
  filesystem but no DB registration, no leases, no workflow binding. The policy
  denies the command before the filesystem changes, so the error is clean and
  recoverable. Guardian is exempt because it IS the authority — provision mode
  calls `git worktree add` via subprocess, so the guardian's shell-level command
  must also be allowed for manual recovery paths.
"""

from __future__ import annotations

import re
from typing import Optional

from runtime.core.policy_engine import PolicyDecision, PolicyRequest

# Match `git worktree add` in both forms:
#   git worktree add ...
#   git -C /path worktree add ...
_WORKTREE_ADD_RE = re.compile(r"\bgit\b.*\bworktree\s+add\b")


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny `git worktree add` when the current role is not guardian.

    Guardian is exempt because it is the sole worktree lifecycle authority.
    All other roles must receive a provisioned worktree via the dispatch chain
    (planner -> guardian(provision) -> implementer).

    Matches:
      - git worktree add .worktrees/feature-name -b feature/name
      - git -C /project worktree add .worktrees/feature-name -b feature/name

    Skips:
      - git worktree list  (read-only introspection)
      - git worktree remove  (governed by bash_worktree_removal)
      - git worktree prune  (maintenance, not creation)
      - Any command not containing `git ... worktree add`
    """
    command = request.tool_input.get("command", "")
    if not command:
        return None

    if not _WORKTREE_ADD_RE.search(command):
        return None

    # Guardian is the sole worktree lifecycle authority — exempt.
    actor_role = request.context.actor_role or ""
    if actor_role == "guardian":
        return None

    return PolicyDecision(
        action="deny",
        reason=(
            "Worktree creation is reserved for Guardian. "
            "Use the dispatch chain: the orchestrator dispatches Guardian in "
            "provision mode (`AUTO_DISPATCH: guardian (mode=provision, ...)`), "
            "Guardian runs `cc-policy worktree provision`, and the resulting "
            "worktree_path is passed to the implementer via AUTO_DISPATCH. "
            "Do NOT run `git worktree add` directly."
        ),
        policy_name="bash_worktree_creation",
    )


def register(registry) -> None:
    """Register bash_worktree_creation into the given PolicyRegistry."""
    registry.register(
        "bash_worktree_creation",
        check,
        event_types=["Bash", "PreToolUse"],
        priority=350,
    )
