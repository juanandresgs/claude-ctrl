"""Policy: bash_approval_gate — require one-shot approval for high-risk git ops.

Port of guard.sh lines 424-483 (Check 13).

@decision DEC-PE-W3-011
Title: bash_approval_gate uses effects to consume approval tokens
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

  Guard.sh Checks 5-6 (hard denies for reset --hard, push --force, clean -f,
  branch -D) fire at priority 500-600, BEFORE this check at priority 1100.
  Those patterns cannot be approved via token — they are unconditional denies.
"""

from __future__ import annotations

import re
from typing import Optional

from runtime.core.leases import classify_git_op
from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import (
    current_workflow_id,
    extract_merge_ref,
    sanitize_token,
)

_GIT_RE = re.compile(r"\bgit\b")


def _resolve_op_type(command: str) -> Optional[str]:
    """Determine the approval op_type string for a high-risk or admin_recovery command."""
    if re.search(r"\bgit\b.*\bpush\b", command):
        return "push"
    if re.search(r"\bgit\b.*\brebase\b", command):
        return "rebase"
    if re.search(r"\bmerge\b.*--abort", command):
        return "admin_recovery"
    if re.search(r"\breset\b.*--merge", command):
        return "admin_recovery"
    if re.search(r"\bgit\b.*\breset\b", command):
        return "reset"
    if re.search(r"\bgit\b.*\bmerge\b.*--no-ff", command):
        return "non_ff_merge"
    return None


def _resolve_workflow_id(request: PolicyRequest, command: str) -> str:
    lease = request.context.lease
    if lease:
        wf = lease.get("workflow_id", "")
        if wf:
            return wf
    if re.search(r"\bgit\b.*\bmerge\b", command):
        merge_ref = extract_merge_ref(command)
        if merge_ref:
            return sanitize_token(merge_ref)
    return current_workflow_id(request.context.project_root or "")


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Require a one-shot approval token for high-risk and admin_recovery git ops.

    Classification (via classify_git_op from leases.py):
      high_risk      → push, rebase, reset (any), merge --no-ff
      admin_recovery → merge --abort, reset --merge

    Routine local ops (commit, plain merge) are gated by eval_readiness
    (priority=900) — no approval token needed here.

    Hard denies (reset --hard, push --force, clean -f, branch -D) are handled
    by bash_destructive_git (priority=600) and bash_force_push (priority=500)
    — they fire before this check and cannot be overridden by a token.

    Source: guard.sh lines 424-483 (Check 13).
    """
    command = request.tool_input.get("command", "")
    if not command:
        return None

    if not _GIT_RE.search(command):
        return None

    op_class = classify_git_op(command)
    if op_class not in ("high_risk", "admin_recovery"):
        return None

    op_type = _resolve_op_type(command)
    if not op_type:
        return None

    workflow_id = _resolve_workflow_id(request, command)

    # Check for a pending (unconsumed) approval token in context.
    # build_context() does not pre-load approval tokens — they are stateful
    # and consumption is a write. We signal consumption via effects and
    # require the CLI handler to validate + consume atomically.
    #
    # The policy checks the approval via effects rather than querying the DB.
    # This means we must trust the CLI handler to do the consumption.
    # We return action="deny" with effects={"check_and_consume_approval": ...}
    # so the CLI handler can:
    #   1. Call approvals.check_and_consume(conn, workflow_id, op_type)
    #   2. If True: override the deny to allow.
    #   3. If False: emit the deny reason.
    #
    # This is the cleanest pure-function approach given the constraints.
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
