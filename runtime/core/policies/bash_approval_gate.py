"""Policy: bash_approval_gate — require one-shot approval for guarded git ops.

Port of guard.sh lines 424-483 (Check 13), excluding straightforward push.

@decision DEC-PE-W3-011
Title: bash_approval_gate uses effects to consume approval tokens for guarded ops
Status: accepted
Rationale: approvals.check_and_consume() mutates the DB (consumes a token).
  Policies are pure functions and must not perform DB writes directly.
  The effects mechanism handles this: when an approval exists we return
  effects={"consume_approval": {"workflow_id": "...", "op_type": "..."}}
  and action="allow" (not None — we need to signal the effect). The CLI
  handler in _handle_evaluate() applies the effect after the decision.

  When no approval exists we return a deny with the same effect shape set
  to None — the CLI handler skips consumption. This is semantically clean:
  the policy decides the verdict, the CLI handler applies side effects.

  classify_git_op() from leases.py is the canonical classifier (DEC-LEASE-002).
  We import it directly — no subprocess needed.

  Straightforward `git push` is no longer approval-token gated. Guardian owns
  push after reviewer/test/lease clearance; this policy now gates only the
  remaining approval-token operations (rebase, reset, non-ff merge, and
  admin recovery). Force push and destructive git remain hard-denied earlier in
  the stack.

  Guard.sh Checks 5-6 (hard denies for reset --hard, push --force, clean -f,
  branch -D) fire at priority 500-600, BEFORE this check at priority 1100.
  Those patterns cannot be approved via token — they are unconditional denies.
"""

from __future__ import annotations

from typing import Optional

from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import (
    current_workflow_id,
    extract_merge_ref,
    sanitize_token,
)


def _resolve_op_type(request: PolicyRequest | str) -> Optional[str]:
    """Determine the approval op_type string for an approval-gated git command.

    Accepts either a PolicyRequest (production path) or a raw command string
    (unit-test convenience / backwards compatibility).
    """
    if isinstance(request, str):
        from runtime.core.command_intent import build_bash_command_intent

        intent = build_bash_command_intent(request)
    else:
        intent = request.command_intent
    invocation = intent.git_invocation if intent is not None else None
    if invocation is None:
        return None

    if invocation.subcommand == "rebase":
        return "rebase"
    if invocation.subcommand == "merge" and "--abort" in invocation.args:
        return "admin_recovery"
    if invocation.subcommand == "reset" and "--merge" in invocation.args:
        return "admin_recovery"
    if invocation.subcommand == "reset":
        return "reset"
    if invocation.subcommand == "merge" and "--no-ff" in invocation.args:
        return "non_ff_merge"
    return None


def _resolve_workflow_id(request: PolicyRequest) -> str:
    lease = request.context.lease
    if lease:
        wf = lease.get("workflow_id", "")
        if wf:
            return wf
    intent = request.command_intent
    invocation = intent.git_invocation if intent is not None else None
    if invocation is not None and invocation.subcommand == "merge":
        merge_ref = extract_merge_ref(" ".join(invocation.argv))
        if merge_ref:
            return sanitize_token(merge_ref)
    return current_workflow_id(request.context.project_root or "")


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Require a one-shot approval token for approval-gated git ops.

    Classification (via classify_git_op from leases.py):
      high_risk      → rebase, reset (any), merge --no-ff
      admin_recovery → merge --abort, reset --merge

    Routine Guardian landing ops (commit, plain merge, straightforward push)
    are gated by eval_readiness / landing authority — no approval token needed
    here.

    Hard denies (reset --hard, push --force, clean -f, branch -D) are handled
    by bash_destructive_git (priority=600) and bash_force_push (priority=500)
    — they fire before this check and cannot be overridden by a token.

    Source: guard.sh lines 424-483 (Check 13).
    """
    intent = request.command_intent
    if intent is None:
        return None

    invocation = intent.git_invocation
    if invocation is None:
        return None

    op_class = intent.git_op_class
    if op_class not in ("high_risk", "admin_recovery"):
        return None

    op_type = _resolve_op_type(request)
    if not op_type:
        return None

    workflow_id = _resolve_workflow_id(request)

    # Check for a pending (unconsumed) approval token in context.
    # build_context() does not pre-load approval tokens — they are stateful
    # and consumption is a write. We signal consumption via effects and
    # require the CLI handler to validate + consume atomically.
    return PolicyDecision(
        action="deny",
        reason=(
            f"Operation '{op_type}' (class: {op_class}) requires explicit approval. "
            f"Grant via: cc-policy approval grant {workflow_id} {op_type}"
        ),
        policy_name="bash_approval_gate",
        effects={
            "check_and_consume_approval": {
                "workflow_id": workflow_id,
                "op_type": op_type,
            }
        },
    )


def register(registry) -> None:
    """Register bash_approval_gate into the given PolicyRegistry."""
    registry.register(
        "bash_approval_gate",
        check,
        event_types=["Bash", "PreToolUse"],
        priority=1100,
    )
