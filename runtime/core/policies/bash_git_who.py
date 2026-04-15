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
Title: classify_git_op is the sole git-op gate for bash_git_who
Status: accepted
Rationale: The prior _GIT_OP_RE layer duplicated classify_git_op() with a
  weaker, shell-unaware regex. It drifted from the canonical classifier and,
  under ENFORCE-RCA-13, matched phrases like "git commit" inside quoted
  natural-language prompt text passed to non-git commands. bash_git_who now
  classifies first and skips when the result is "unclassified", so only real
  git invocations proceed to lease enforcement.

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
import time
from typing import Optional

from runtime.core.authority_registry import READ_ONLY_REVIEW
from runtime.core.policy_engine import PolicyDecision, PolicyRequest

def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny git operations requiring a Guardian lease when no valid active lease covers the op.

    Logic:
      1. Skip if meta-repo.
      2. Classify the command; skip if it is not a real git op.
      2b. If READ_ONLY_REVIEW in capabilities: deny unconditionally (Phase 3).
      3. If no lease in context: deny with guidance to issue a lease.
      4. Belt-and-suspenders role check: if lease.role doesn't match actor_role, deny.
      5. If lease expired: deny with effects to expire stale leases.
      6. If op_class is blocked or not in allowed_ops: deny.
      7. If all checks pass: return None (allow through to later policies).

    Source: guard.sh lines 140-178 (Check 3).
    """
    intent = request.command_intent
    if intent is None:
        return None

    op_class = intent.git_op_class
    if op_class == "unclassified":
        return None

    # Meta-repo bypass.
    if request.context.is_meta_repo:
        return None

    # Phase 3 capability gate: read-only stages (reviewer) must not run git
    # operations regardless of lease contents. Changes and landing must route
    # through implementer and guardian respectively.
    if READ_ONLY_REVIEW in request.context.capabilities:
        return PolicyDecision(
            action="deny",
            reason=(
                "Read-only stage cannot run git operations. "
                "Source changes must route through an implementer; "
                "git landing must route through a guardian."
            ),
            policy_name="bash_git_who",
        )

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
