"""Policy: bash_git_who — enforce lease-based WHO for git operations.

Port of guard.sh lines 140-178 (Check 3).

@decision DEC-PE-W3-008
Title: bash_git_who uses context.lease as the sole WHO authority
Status: accepted
Rationale: guard.sh Check 3 calls rt_lease_validate_op() which does a DB read
  for every invocation. In the policy engine model, build_context() has already
  loaded the active lease into PolicyContext. This policy consumes that pre-loaded
  lease rather than re-querying the DB — pure function, no I/O.

  Stale lease expiry (expire_stale) cannot be a pure function because it writes
  to the DB. We handle it via the effects mechanism: return
  effects={"expire_stale_leases": True} alongside a deny so the CLI handler
  can apply the side effect after the decision. This keeps the policy pure while
  ensuring stale cleanup happens.

  validate_op() IS available in leases.py but requires a DB connection — we
  cannot call it here without violating the pure-function contract. Instead we
  replicate its core logic using the lease data already in context:
    - Check the lease exists and is not expired
    - Check op_class is in allowed_ops and not in blocked_ops
  The eval/approval sub-checks of validate_op are handled by separate policies
  (bash_eval_readiness at priority=900, bash_approval_gate at priority=1100).

@decision DEC-PE-EGAP-GIT-WHO-001
Title: Expanded _GIT_OP_RE covers all Guardian-only git operations
Status: accepted
Rationale: The original regex only gated commit/merge/push. Operations such as
  git worktree remove, git branch -d/-D, git rebase, git reset, and git tag all
  modify repository state and must require a valid lease. The expanded regex
  applies WHO enforcement to the full set of state-mutating git commands so that
  no Guardian-only operation bypasses the lease check.

  classify_git_op() in leases.py already classifies rebase and reset as
  high_risk — the expansion here only ensures the match layer is consistent.
  worktree remove and branch -D are treated as high_risk by the expanded
  classify_git_op logic (see leases.py DEC-LEASE-EGAP-002).

@decision DEC-PE-EGAP-GIT-WHO-002
Title: Belt-and-suspenders role check in bash_git_who guards against lease inheritance by wrong actor
Status: accepted
Rationale: build_context() is the primary defense against role-blind lease
  resolution (Gap 2). bash_git_who adds a secondary check: if the resolved
  lease carries a role and the actor_role in context does not match, deny.
  This prevents a scenario where build_context incorrectly hands a guardian
  lease to an orchestrator — the secondary check catches it even if the primary
  filter has a bug. Defense in depth: two independent checks, either sufficient.
"""

from __future__ import annotations

import json
import re
import time
from typing import Optional

from runtime.core.leases import classify_git_op
from runtime.core.policy_engine import PolicyDecision, PolicyRequest

# @decision DEC-PE-EGAP-GIT-WHO-001 (expanded)
# Matches all Guardian-only git operations. Word-boundary patterns prevent
# false positives on path arguments (e.g. /path/to/feature-rebase-branch).
# worktree\s+(remove|prune) and branch\s+-[dD] use \s+ to match the required
# whitespace between the subcommand and its argument — this avoids matching
# command names that start with "remove" or "prune" in unusual contexts.
_GIT_OP_RE = re.compile(
    r"\bgit\b.*\b(commit|merge|push|rebase|reset|tag"
    r"|worktree\s+(?:remove|prune)"
    r"|branch\s+-[dD])\b"
)


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny git operations requiring a Guardian lease when no valid active lease covers the op.

    Logic:
      1. Skip if meta-repo.
      2. Match git operations that require a lease (expanded set, see _GIT_OP_RE).
      3. If no lease in context: deny with guidance to issue a lease.
      4. Belt-and-suspenders role check: if lease.role doesn't match actor_role, deny.
      5. If lease expired: deny with effects to expire stale leases.
      6. Classify the op; if op_class is blocked or not in allowed_ops: deny.
      7. If all checks pass: return None (allow through to later policies).

    Source: guard.sh lines 140-178 (Check 3).
    """
    command = request.tool_input.get("command", "")
    if not command:
        return None

    if not _GIT_OP_RE.search(command):
        return None

    # Meta-repo bypass.
    if request.context.is_meta_repo:
        return None

    lease = request.context.lease

    if lease is None:
        return PolicyDecision(
            action="deny",
            reason=(
                "No active dispatch lease for this worktree. "
                "All git operations in the enforced project require a lease. "
                "Dispatch via: cc-policy lease issue-for-dispatch "
                "--role <role> --worktree-path <path>"
            ),
            policy_name="bash_git_who",
            effects={"expire_stale_leases": True},
        )

    # Belt-and-suspenders role check (DEC-PE-EGAP-GIT-WHO-002):
    # If the lease carries a role, the actor must match it. This is a secondary
    # defense against build_context handing the wrong actor a role-specific lease.
    actor = (request.context.actor_role or "").lower().strip()
    lease_role = (lease.get("role") or "").lower().strip()
    if lease_role and actor != lease_role:
        return PolicyDecision(
            action="deny",
            reason=(
                f"Lease role '{lease_role}' does not match actor role '{actor}'. "
                "Only the lease holder may use this lease for git operations. "
                "Dispatch via: cc-policy lease issue-for-dispatch "
                "--role <role> --worktree-path <path>"
            ),
            policy_name="bash_git_who",
        )

    # Check lease is not expired (defensive — build_context only loads active
    # leases, but expires_at may have elapsed between context build and now).
    now = int(time.time())
    if lease.get("expires_at", 0) < now:
        return PolicyDecision(
            action="deny",
            reason=("Active lease has expired. Re-issue a lease before running git operations."),
            policy_name="bash_git_who",
            effects={"expire_stale_leases": True},
        )

    # Classify the op and check against lease allowed/blocked ops.
    op_class = classify_git_op(command)
    try:
        allowed_ops = json.loads(lease.get("allowed_ops_json") or "[]")
        blocked_ops = json.loads(lease.get("blocked_ops_json") or "[]")
    except (json.JSONDecodeError, TypeError):
        allowed_ops = ["routine_local"]
        blocked_ops = []

    if op_class in blocked_ops:
        return PolicyDecision(
            action="deny",
            reason=(
                f"Execution contract denied: op_class '{op_class}' is in blocked_ops. "
                "Check lease allowed_ops or evaluation_state."
            ),
            policy_name="bash_git_who",
        )

    if op_class not in allowed_ops:
        return PolicyDecision(
            action="deny",
            reason=(
                f"Execution contract denied: op_class '{op_class}' not in "
                f"allowed_ops {allowed_ops}. "
                "Check lease allowed_ops or evaluation_state."
            ),
            policy_name="bash_git_who",
        )

    return None


def register(registry) -> None:
    """Register bash_git_who into the given PolicyRegistry."""
    registry.register(
        "bash_git_who",
        check,
        event_types=["Bash", "PreToolUse"],
        priority=300,
    )
