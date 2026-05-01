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

@decision DEC-PE-GIT-WHO-LEASE-DENY-DIAG-001
Title: bash_git_who distinguishes "no lease" from "lease exists but not attachable"
Status: accepted
Rationale: Before this change, both scenarios surfaced identical deny text:
  "No active dispatch lease for this worktree" — even when an active lease
  actually existed and the real problem was that the caller's actor_role did
  not match the lease holder's role. Operators chased "re-issue the lease"
  remediations that did nothing. bash_git_who now reads the diagnostic field
  ``context.worktree_lease_suppressed_roles`` (populated by build_context,
  DEC-PE-LEASE-DENY-DIAG-001) and emits a distinct message naming the real
  cause: actor-role unresolved (orchestrator) vs. actor-role mismatch
  (non-owner). Enforcement is IDENTICAL in all three branches — every path
  still denies. Only the reason text and classification change, so operators
  can route remediations correctly. No relaxation of lease WHO.
"""

from __future__ import annotations

import json
import time
from typing import Optional

from runtime.core.authority_registry import (
    CAN_LAND_GIT,
    READ_ONLY_REVIEW,
    actor_matches_lease_role,
)
from runtime.core.leases import op_class_label
from runtime.core.policy_engine import PolicyDecision, PolicyRequest

# @decision DEC-WHO-LANDING-001
# Landing subcommands (commit, merge, push) require CAN_LAND_GIT capability.
# Only guardian:land carries this capability. This gate fires AFTER the
# lease-expired check but BEFORE allowed_ops, so actors with valid leases
# but without landing authority are denied before op-class checks.
# admin_recovery ops (e.g. merge --abort) are exempt — they undo state,
# not land code.
_LANDING_SUBCOMMANDS = frozenset({"commit", "merge", "push"})
_PLUMBING_SUBCOMMANDS = frozenset(
    {"commit-tree", "update-ref", "symbolic-ref", "filter-branch", "filter-repo"}
)

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

    git_operations = tuple(
        op for op in intent.git_operations if op.op_class != "unclassified"
    )
    if not git_operations:
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
        # Distinguish "no lease exists at all" (operator must issue one) from
        # "lease exists on this worktree but the caller cannot attach it
        # because actor_role is unresolved or mismatched" (operator does not
        # need to re-issue — they need an actor-role context matching the
        # existing lease). See DEC-PE-LEASE-DENY-DIAG-001. Enforcement is
        # identical in both branches — this is diagnostic-only classification
        # so operators do not waste time on the wrong remediation.
        suppressed = request.context.worktree_lease_suppressed_roles
        actor = (request.context.actor_role or "").strip()
        if suppressed:
            roles_text = ", ".join(sorted(suppressed))
            if not actor:
                # Orchestrator path — DEC-PE-EGAP-BUILD-CTX-001 suppresses
                # worktree-path lease inheritance when actor_role is empty.
                reason = (
                    f"Active lease(s) for role(s) [{roles_text}] exist on "
                    f"this worktree, but the caller has no resolved actor "
                    f"role and cannot attach a role-specific lease "
                    f"(DEC-PE-EGAP-BUILD-CTX-001). Git operations from the "
                    f"orchestrator are not authorised — dispatch the matching "
                    f"role via the canonical chain so the lease is consumed "
                    f"under the correct actor. Do NOT re-issue the lease; "
                    f"the lease is fine, the caller is not."
                )
            else:
                # Actor role is set but does not match any active lease role
                # on this worktree.
                reason = (
                    f"Active lease(s) for role(s) [{roles_text}] exist on "
                    f"this worktree, but the caller's actor role "
                    f"{actor!r} does not match any of them. Only the "
                    f"lease-holder role may use a role-specific lease "
                    f"(DEC-PE-EGAP-BUILD-CTX-001). Re-dispatch under the "
                    f"matching role, or issue a new lease for "
                    f"{actor!r} if that role is the intended operator."
                )
            return PolicyDecision(
                action="deny",
                reason=reason,
                policy_name="bash_git_who",
                effects={"expire_stale_leases": True},
                metadata={
                    "reason_code": "lease_not_attachable",
                    "observed": {
                        "actor_role": actor,
                        "target_worktree": request.context.project_root or request.cwd,
                        "active_lease_roles": sorted(suppressed),
                    },
                    "repair": (
                        "dispatch the matching canonical stage so the existing "
                        "lease is consumed by the lease-holder actor"
                    ),
                },
            )
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
            metadata={
                "reason_code": "missing_dispatch_lease",
                "observed": {
                    "target_worktree": request.context.project_root or request.cwd,
                    "actor_role": request.context.actor_role,
                    "workflow_id": request.context.workflow_id,
                },
                "repair": (
                    "issue or dispatch a lease for the command target worktree "
                    "before running mutating git operations"
                ),
            },
        )

    # Belt-and-suspenders role check (DEC-PE-EGAP-GIT-WHO-002):
    # If the lease carries a role, the actor must match it. Uses
    # actor_matches_lease_role (DEC-WHO-STAGE-LEASE-MATCH-001) to bridge
    # compound stage IDs to lease-level roles.
    lease_role_str = (lease.get("role") or "").strip()
    if lease_role_str and not actor_matches_lease_role(
        request.context.actor_role or "", lease_role_str
    ):
        actor_display = (request.context.actor_role or "").lower().strip()
        return PolicyDecision(
            action="deny",
            reason=(
                f"Lease role '{lease_role_str.lower()}' does not match actor role '{actor_display}'. "
                "Only the lease holder may use this lease for git operations. "
                "Dispatch via: cc-policy lease issue-for-dispatch "
                "--role <role> --worktree-path <path>"
            ),
            policy_name="bash_git_who",
            metadata={
                "reason_code": "lease_role_mismatch",
                "observed": {
                    "lease_role": lease_role_str,
                    "actor_role": request.context.actor_role,
                    "workflow_id": request.context.workflow_id,
                },
                "repair": "run the command from the actor that claimed the lease",
            },
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

    # CAN_LAND_GIT capability gate (DEC-WHO-LANDING-001): landing subcommands
    # require CAN_LAND_GIT. admin_recovery ops (merge --abort) are exempt.
    for operation in git_operations:
        invocation = operation.invocation
        op_class = operation.op_class
        if (
            invocation.subcommand in _LANDING_SUBCOMMANDS
            and op_class != "admin_recovery"
        ):
            if CAN_LAND_GIT not in request.context.capabilities:
                return PolicyDecision(
                    action="deny",
                    reason=(
                        f"Landing authority required: git {invocation.subcommand} "
                        f"requires the {CAN_LAND_GIT} capability. Only guardian:land "
                        f"carries this capability. Current actor "
                        f"'{request.context.actor_role}' does not have it."
                    ),
                    policy_name="bash_git_who",
                    metadata={
                        "reason_code": "missing_landing_capability",
                        "observed": {
                            "subcommand": invocation.subcommand,
                            "actor_role": request.context.actor_role,
                            "capabilities": sorted(request.context.capabilities),
                            "workflow_id": request.context.workflow_id,
                        },
                        "repair": "dispatch guardian:land after reviewer readiness",
                    },
                )
        if invocation.subcommand in _PLUMBING_SUBCOMMANDS:
            if CAN_LAND_GIT not in request.context.capabilities:
                return PolicyDecision(
                    action="deny",
                    reason=(
                        f"Direct git plumbing (`git {invocation.subcommand}`) requires "
                        f"the {CAN_LAND_GIT} capability. Use the canonical Guardian "
                        "landing path (`git commit`, plain `git merge`, or straightforward "
                        "`git push`) under guardian:land instead."
                    ),
                    policy_name="bash_git_who",
                )

    for operation in git_operations:
        op_class = operation.op_class
        if op_class in blocked_ops:
            return PolicyDecision(
                action="deny",
                reason=(
                    f"Execution contract denied: {op_class_label(op_class)} operation "
                    f"is blocked by this lease: in blocked_ops "
                    f"(internal op_class '{op_class}'). "
                    "Check lease allowed_ops or evaluation_state."
                ),
                policy_name="bash_git_who",
            )
        if op_class not in allowed_ops:
            return PolicyDecision(
                action="deny",
                reason=(
                    f"Execution contract denied: {op_class_label(op_class)} operation "
                    f"is not in allowed_ops {allowed_ops} "
                    f"(internal op_class '{op_class}'). "
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
