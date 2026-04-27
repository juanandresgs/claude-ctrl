"""Policy: bash_stash_ban — deny destructive stash sub-ops for can_write_source actors.

Capability-gated on CAN_WRITE_SOURCE (implementer role). Non-implementer actors
are not subject to this policy — return None so other policies can proceed.

Background (DEC-DISCIPLINE-STASH-BAN-001):
  In slices 4 and 5 of the global-soak lane, a `git stash pop` materialised
  WIP from a different feature lane into the implementer's worktree, causing
  cross-lane contamination that required manual recovery. Banned sub-ops
  (`pop`, `apply`, `drop`, `clear`, `branch`) all share the property that they
  can introduce arbitrary stash-hosted WIP into the current working tree.
  Allowed sub-ops (`push`, `save`, `show`, `list`, `store`, `create`) and bare
  `git stash` (which defaults to `push`) are safe checkpointing operations and
  remain available to implementers.

Parsing note: stash sub-op classification is driven exclusively by
  `request.command_intent.git_invocation` (pre-parsed, Rule B compliant).
  Raw command string access for .split() is forbidden by Rule B of the
  command-intent single-authority contract.

@decision DEC-DISCIPLINE-STASH-BAN-001
Title: bash_stash_ban is the sole enforcement authority for stash-sub-op contamination
Status: accepted
Rationale: Implementers (can_write_source actors) must not materialise stash WIP
  from any stash entry — regardless of which lane created the stash — into their
  worktree. The `pop`/`apply`/`drop`/`clear`/`branch` sub-ops are the contamination
  vector documented in slices 4 and 5. This policy closes that vector at priority 625,
  between bash_destructive_git (600) and bash_worktree_removal (700), so it fires
  after hard-deny destructive patterns but before the worktree guard sweep.
  Capability-gated on CAN_WRITE_SOURCE, not actor_role string, so the gate degrades
  gracefully if roles are renamed without updating this module.
  Sub-op extraction uses request.command_intent.git_invocation exclusively (Rule B).
"""

from __future__ import annotations

from typing import Optional

from runtime.core.authority_registry import CAN_WRITE_SOURCE
from runtime.core.policy_engine import PolicyDecision, PolicyRequest

# ---------------------------------------------------------------------------
# Sub-op classification
# ---------------------------------------------------------------------------

# Sub-ops that materialise arbitrary stash WIP into the working tree.
# These are unconditionally denied for CAN_WRITE_SOURCE actors.
_BANNED_SUBOPS: frozenset[str] = frozenset({"pop", "apply", "drop", "clear", "branch"})

# Sub-ops that are safe checkpointing/inspection operations.
# Listed for documentation; any sub-op NOT in _BANNED_SUBOPS is allowed.
_ALLOWED_SUBOPS: frozenset[str] = frozenset({"push", "save", "show", "list", "store", "create"})


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny destructive stash sub-ops when the actor carries CAN_WRITE_SOURCE.

    Logic:
      1. If CAN_WRITE_SOURCE not in capabilities: return None (not our gate).
      2. Require git_invocation via command_intent (Rule B: no raw .split()).
         If command_intent or git_invocation is absent: return None (not a git op).
      3. If git_invocation.subcommand != 'stash': return None (not stash).
      4. Extract sub-op from git_invocation.args[0] (first non-flag token pre-parsed).
         Bare `git stash` has empty args → no sub-op → defaults to push → allow.
      5. If sub-op is in _BANNED_SUBOPS: deny with incident-class reason.
      6. Otherwise: return None (allow).

    Capability gate is on CAN_WRITE_SOURCE, not actor_role string, to ensure
    this policy tracks the capability vocabulary (DEC-CLAUDEX-AUTHORITY-REGISTRY-001)
    rather than duplicating role-name folklore.
    """
    # Gate 1: only apply to CAN_WRITE_SOURCE actors (implementers).
    if CAN_WRITE_SOURCE not in request.context.capabilities:
        return None

    # Gate 2: require pre-parsed git invocation (Rule B compliant — no raw split).
    intent = request.command_intent
    if intent is None or not intent.git_invocations:
        return None

    invocation = next(
        (candidate for candidate in intent.git_invocations if candidate.subcommand == "stash"),
        None,
    )
    if invocation is None:
        return None

    # Gate 4: extract sub-op from pre-parsed args.
    # git_invocation.args contains everything after the subcommand, pre-parsed.
    # For `git stash pop`: args=('pop',)
    # For `git stash branch foo`: args=('branch', 'foo')
    # For `git stash` (bare): args=()
    # The sub-op is the first non-flag token in args; flags start with '-'.
    stash_subop: Optional[str] = None
    for token in invocation.args:
        if not token.startswith("-"):
            stash_subop = token
            break
    # stash_subop is None → bare `git stash` → treated as push → allow.

    # Gate 5: classify sub-op.
    if stash_subop is None:
        # Bare `git stash` — defaults to push — safe.
        return None

    if stash_subop not in _BANNED_SUBOPS:
        # Allowed sub-op (push, save, show, list, store, create, or future op).
        return None

    return PolicyDecision(
        action="deny",
        reason=(
            f"Implementer cannot run `git stash {stash_subop}` — this sub-op class "
            f"materialises arbitrary stash WIP into the worktree and caused "
            f"cross-lane contamination in slices 4 and 5. "
            f"Use `git stash push` / `git stash save` if you need to checkpoint, "
            f"or dispatch a guardian for recovery. "
            f"(bash_stash_ban, capability-gated on can_write_source)"
        ),
        policy_name="bash_stash_ban",
    )


def register(registry) -> None:
    """Register bash_stash_ban into the given PolicyRegistry.

    Priority 625: between bash_destructive_git (600) and bash_worktree_removal (700).
    Fires after hard-deny patterns are cleared but before the worktree guard sweep.
    """
    registry.register(
        "bash_stash_ban",
        check,
        event_types=["Bash", "PreToolUse"],
        priority=625,
    )
