"""
Runtime-owned producer for Agent tool prompt bodies.

@decision DEC-CLAUDEX-AGENT-PROMPT-001
@title agent_prompt: runtime-owned Agent dispatch prompt producer
@status accepted
@rationale The orchestrator (Claude LLM) constructs Agent tool call prompts.
  For the carrier path (DEC-CLAUDEX-SA-CARRIER-001) to fire in production, those
  prompts must contain a CLAUDEX_CONTRACT_BLOCK: line carrying the six contract
  fields that pre-agent.sh extracts and writes to pending_agent_requests.
  This module is the repo-owned producer for that block, sourcing the six fields
  from runtime state (active goal/work_item for the workflow) so the orchestrator
  does not need to discover or copy them individually.
  The orchestrator calls ``cc-policy dispatch agent-prompt`` before issuing the
  Agent tool call, and prepends the returned ``prompt_prefix`` (which already
  contains the block line on line 1) to whatever task instructions it writes.
  The LLM is responsible only for calling the CLI and prepending the prefix —
  it is NOT responsible for constructing the block line content.
  This is the minimum viable producer for approach B (DEC-CLAUDEX-SA-CARRIER-001).
"""

from __future__ import annotations

import json
import sqlite3
import subprocess
import time
from typing import Optional

from runtime.core.authority_registry import (
    canonical_stage_id,
    dispatch_subagent_type_for_stage,
)
from runtime.core import completions as _completions
import runtime.core.decision_work_registry as _dwr
from runtime.core import stage_registry as _stage_registry
from runtime.core import workflows as _workflows
from runtime.core.dispatch_contract import (
    dispatch_subagent_type_for_stage as _dispatch_subagent_type_for_stage,
)

__all__ = [
    "build_agent_dispatch_prompt",
]

_CONTRACT_BLOCK_MARKER = "CLAUDEX_CONTRACT_BLOCK"

# Classification tag embedded in every guard failure so operators (and any
# log-scanner) can tell this class of error apart from planner-stage stalls.
# The tag text MUST stay stable; callers grep for it.
_HEAD_SHA_SHAPE_CLASS = "[commit-shape/config mismatch — not a planner stall]"


def _resolve_stage_id_for_dispatch(
    conn: sqlite3.Connection,
    *,
    workflow_id: str,
    stage_id: str,
) -> str:
    """Resolve a caller-supplied stage id to a canonical active stage.

    ``guardian`` is the only ambiguous delivery-path name: one repo-owned
    Guardian agent serves both ``guardian:provision`` and ``guardian:land``.
    For the high-friction live path, infer the compound stage from the latest
    valid completion when the workflow has just routed to Guardian. Otherwise
    fail with an actionable message instead of the generic "unknown active
    stage 'guardian'" error.
    """
    stage_key = stage_id.strip()
    resolved_stage_id = canonical_stage_id(stage_key)
    if resolved_stage_id:
        return resolved_stage_id

    if stage_key != "guardian":
        raise ValueError(f"unknown active stage {stage_id!r}")

    latest = _completions.latest(conn, workflow_id=workflow_id)
    if latest and int(latest.get("valid") or 0) == 1:
        role = str(latest.get("role") or "")
        verdict = str(latest.get("verdict") or "")
        if role == "reviewer" and verdict == "ready_for_guardian":
            return _stage_registry.GUARDIAN_LAND
        if role == "planner" and verdict == "next_work_item":
            return _stage_registry.GUARDIAN_PROVISION

    raise ValueError(
        "ambiguous guardian stage: use --stage-id guardian:land after a valid "
        "reviewer ready_for_guardian completion, or --stage-id "
        "guardian:provision after a valid planner next_work_item completion. "
        "Bare --stage-id guardian can only be resolved when the latest valid "
        "completion for the workflow proves which Guardian mode is next."
    )


def build_agent_dispatch_prompt(
    conn: sqlite3.Connection,
    *,
    workflow_id: str,
    stage_id: str,
    goal_id: Optional[str] = None,
    work_item_id: Optional[str] = None,
    decision_scope: str = "kernel",
    generated_at: Optional[int] = None,
) -> dict:
    """Build a prompt prefix for Agent tool dispatch.

    Resolves the six contract fields from runtime state:
    - ``workflow_id`` and ``stage_id`` are supplied by the caller (the orchestrator
      knows which workflow it is dispatching into and which role/stage).
    - ``goal_id`` is resolved from the first active goal in the DB when omitted.
    - ``work_item_id`` is resolved from the first in_progress work item for the
      resolved goal when omitted.
    - ``decision_scope`` defaults to ``"kernel"``; callers may override for
      non-kernel dispatch contexts.
    - ``generated_at`` defaults to the current wall-clock second.

    Returns a dict with three keys:

    ``contract``
        Plain dict of the six fields.  Matches the shape expected by
        ``pending_agent_requests.write_pending_request`` and
        ``runtime.core.prompt_pack_validation.validate_subagent_start_prompt_pack_request``.

    ``contract_block_line``
        The literal ``CLAUDEX_CONTRACT_BLOCK:{...}`` string — a single line with no
        trailing newline.  This is what pre-agent.sh greps for with
        ``grep '^CLAUDEX_CONTRACT_BLOCK:'``.

    ``prompt_prefix``
        A ready-to-prepend string consisting of the block line followed by a
        minimal context banner.  The orchestrator concatenates its task
        instructions after this prefix.

    ``required_subagent_type``
        The canonical Agent-tool ``subagent_type`` the orchestrator must use
        for this stage so Claude loads the repo-owned stage prompt
        (``agents/planner.md``, ``agents/implementer.md``, etc.) instead of a
        generic seat.

    Raises ``ValueError`` when a required state lookup fails (e.g. no active goal
    found, no in_progress work item found for the goal).
    """
    if not workflow_id or not workflow_id.strip():
        raise ValueError("workflow_id must be a non-empty string")
    if not stage_id or not stage_id.strip():
        raise ValueError("stage_id must be a non-empty string")
    resolved_stage_id = _resolve_stage_id_for_dispatch(
        conn,
        workflow_id=workflow_id,
        stage_id=stage_id,
    )
    required_subagent_type = dispatch_subagent_type_for_stage(resolved_stage_id)
    if not required_subagent_type:
        raise ValueError(f"no canonical subagent type for stage {resolved_stage_id!r}")

    # DEC-CLAUDEX-DW-WORKFLOW-JOIN-002: the explicit-override path must enforce
    # the same workflow-ownership discipline as the default-resolution path.
    # Before this slice, explicit goal_id / work_item_id were trusted verbatim
    # and the producer emitted a contract block binding the caller's
    # workflow_id to a goal/work_item owned by a different workflow (or with
    # NULL workflow_id). That re-opened the cross-workflow contract bleed the
    # default-path filter was supposed to close. The override path now:
    #
    #   * validates explicit work_item_id belongs to workflow_id
    #   * validates explicit goal_id belongs to workflow_id
    #   * when both are explicit, cross-validates work_item.goal_id == goal_id
    #   * when only work_item_id is explicit, derives goal_id from the
    #     validated work item so the contract fields stay internally consistent
    #
    # Every failure raises ValueError whose message names both the requested
    # workflow_id and the offending row's actual workflow_id / goal_id so the
    # operator can route the fix unambiguously. Fail-closed in every branch.

    # Validate explicit work_item_id first (it may also pin goal_id).
    if work_item_id:
        wi_record = _dwr.get_work_item(conn, work_item_id)
        if wi_record is None:
            raise ValueError(
                f"explicit work_item_id {work_item_id!r} not found in "
                f"work_items; cannot issue a dispatch contract for an "
                f"unknown work item. See DEC-CLAUDEX-DW-WORKFLOW-JOIN-002."
            )
        if wi_record.workflow_id != workflow_id:
            raise ValueError(
                f"explicit work_item_id {work_item_id!r} ownership mismatch: "
                f"requested workflow_id={workflow_id!r} but work_item.workflow_id="
                f"{wi_record.workflow_id!r}. Re-dispatch under the owning "
                f"workflow, or re-seed the work item with the correct "
                f"workflow_id. See DEC-CLAUDEX-DW-WORKFLOW-JOIN-002."
            )
        # Validated work item pins the goal_id. If caller also supplied
        # goal_id, cross-check them; otherwise derive it from the work item.
        if goal_id and goal_id != wi_record.goal_id:
            raise ValueError(
                f"explicit goal_id/work_item_id mismatch: requested "
                f"goal_id={goal_id!r} but work_item {work_item_id!r} owns "
                f"goal_id={wi_record.goal_id!r}. The two explicit IDs must "
                f"agree. See DEC-CLAUDEX-DW-WORKFLOW-JOIN-002."
            )
        if not goal_id:
            goal_id = wi_record.goal_id

    # Validate explicit goal_id (whether supplied by the caller or just
    # derived from an explicit work_item) against the workflow.
    if goal_id:
        g_record = _dwr.get_goal(conn, goal_id)
        if g_record is None:
            raise ValueError(
                f"explicit goal_id {goal_id!r} not found in goal_contracts; "
                f"cannot issue a dispatch contract for an unknown goal. "
                f"See DEC-CLAUDEX-DW-WORKFLOW-JOIN-002."
            )
        if g_record.workflow_id != workflow_id:
            raise ValueError(
                f"explicit goal_id {goal_id!r} ownership mismatch: requested "
                f"workflow_id={workflow_id!r} but goal.workflow_id="
                f"{g_record.workflow_id!r}. Re-dispatch under the owning "
                f"workflow, or re-seed the goal with the correct "
                f"workflow_id. See DEC-CLAUDEX-DW-WORKFLOW-JOIN-002."
            )

    # Resolve goal_id from runtime state when still not supplied.
    #
    # DEC-CLAUDEX-DW-WORKFLOW-JOIN-001: the default-resolution path MUST be
    # scoped by workflow_id. Before this slice the producer did a workflow-
    # blind global scan (`list_goals(status="active")[0]`) and leaked an
    # unrelated workflow's active goal into the caller's contract block when
    # the caller had not yet created its own goal. We now filter by
    # workflow_id so legacy rows (workflow_id IS NULL) and rows owned by
    # other workflows are both excluded. Producer fails closed — no
    # fall-through to global scan — when nothing matches.
    if not goal_id:
        active_goals = _dwr.list_goals(
            conn, status="active", workflow_id=workflow_id
        )
        if not active_goals:
            planner_bootstrap_note = ""
            if resolved_stage_id == "planner":
                from runtime.core.planner_bootstrap import planner_bootstrap_guidance

                planner_bootstrap_note = planner_bootstrap_guidance() + " "
            raise ValueError(
                f"no active goal found for workflow {workflow_id!r}; "
                "a goal scoped to this workflow must be in 'active' status "
                "before a canonical stage launch can be produced. "
                + planner_bootstrap_note
                + "Seed a goal first with `cc-policy workflow goal-set`, "
                "then seed an in-progress work item with "
                "`cc-policy workflow work-item-set`. "
                "If you only want ad hoc helper parallelism, use a "
                "general-purpose/non-canonical seat instead of planner/implementer/"
                "reviewer/guardian. The previous behaviour of falling back "
                "to the first globally-active goal was removed under "
                "DEC-CLAUDEX-DW-WORKFLOW-JOIN-001 to prevent cross-workflow "
                "contract bleed."
            )
        goal_id = active_goals[0].goal_id

    # Resolve work_item_id from runtime state when not supplied. Same
    # discipline: workflow_id is an explicit filter, and the producer
    # refuses to return an unrelated workflow's in-progress work item.
    if not work_item_id:
        in_progress = _dwr.list_work_items(
            conn,
            goal_id=goal_id,
            status="in_progress",
            workflow_id=workflow_id,
        )
        if not in_progress:
            planner_bootstrap_note = ""
            if resolved_stage_id == "planner":
                from runtime.core.planner_bootstrap import planner_bootstrap_guidance

                planner_bootstrap_note = planner_bootstrap_guidance() + " "
            raise ValueError(
                f"no in_progress work item found for goal {goal_id!r} "
                f"scoped to workflow {workflow_id!r}; a workflow-scoped "
                "work item must be in 'in_progress' status before "
                "dispatch. "
                + planner_bootstrap_note
                + "Seed one with `cc-policy workflow work-item-set`, "
                "or use a general-purpose/non-canonical seat for ad hoc helper "
                "work that should not enter the canonical workflow chain. "
                "See DEC-CLAUDEX-DW-WORKFLOW-JOIN-001 for why the global "
                "fall-through was removed."
            )
        work_item_id = in_progress[0].work_item_id

    # Producer-side commit-shape guard.  Load the resolved work-item and,
    # when it carries a ``head_sha``, verify the SHA is (a) a real commit in
    # the workflow-bound repo and (b) has a non-empty delta vs ``base_branch``.
    # Failures here are classified as commit-shape/config mismatches — NOT
    # planner stalls — so operators do not waste time chasing a downstream
    # planner bug for what is actually a mis-seeded head_sha.  See
    # DEC-CLAUDEX-AGENT-PROMPT-GUARD-001 below.
    work_item_record = _dwr.get_work_item(conn, work_item_id)
    if work_item_record is None:
        # This is internal inconsistency (the resolver just returned this id),
        # not a head_sha-shape issue — surface it as its own error.
        raise ValueError(
            f"work_item {work_item_id!r} resolved but not present in "
            f"work_items table; seed state is inconsistent"
        )
    if work_item_record.head_sha:
        _validate_head_sha_commit_shape(
            conn=conn,
            workflow_id=workflow_id,
            work_item_id=work_item_id,
            head_sha=work_item_record.head_sha,
        )

    if generated_at is None:
        generated_at = int(time.time())

    contract = {
        "workflow_id": workflow_id,
        "stage_id": resolved_stage_id,
        "goal_id": goal_id,
        "work_item_id": work_item_id,
        "decision_scope": decision_scope,
        "generated_at": generated_at,
    }

    # Build the block line — must start at column 0 so pre-agent.sh's
    # `grep '^CLAUDEX_CONTRACT_BLOCK:'` finds it.
    contract_block_line = f"{_CONTRACT_BLOCK_MARKER}:{json.dumps(contract, separators=(',', ':'))}"

    # Build the prompt prefix: the block line on line 1 so it is always
    # the first grep hit, followed by a minimal dispatch banner.
    prompt_prefix = (
        f"{contract_block_line}\n"
        f"\n"
        f"[ClauDEX dispatch: {workflow_id} / {resolved_stage_id} / {goal_id} | "
        f"subagent={required_subagent_type}]\n"
    )

    return {
        "contract": contract,
        "contract_block_line": contract_block_line,
        "prompt_prefix": prompt_prefix,
        "required_subagent_type": required_subagent_type,
    }


def _validate_head_sha_commit_shape(
    *,
    conn: sqlite3.Connection,
    workflow_id: str,
    work_item_id: str,
    head_sha: str,
) -> None:
    """Reject work-item dispatch when ``head_sha`` is shape-invalid.

    Runs two git checks, both scoped to the workflow-bound repo:

    1. ``git -C <worktree_path> rev-parse --verify <head_sha>^{commit}``
       proves the SHA resolves to a commit in that repo.
    2. ``git -C <worktree_path> diff --name-only <base_branch>...<head_sha>``
       proves the SHA has a non-empty delta against the base branch — so it
       is neither already absorbed into the base nor identical to it.

    Both checks are gated on a ``workflow_bindings`` row existing for
    ``workflow_id`` with ``worktree_path`` set.  Without a binding we cannot
    meaningfully run git at all, so the guard soft-passes — downstream
    guardian/reviewer still apply their own checks once the chain is alive.

    Failures raise :class:`ValueError` whose message always begins with
    :data:`_HEAD_SHA_SHAPE_CLASS` so log-scanners can distinguish this class
    of failure from planner-stage stalls.
    """
    binding = _workflows.get_binding(conn, workflow_id)
    if binding is None:
        return
    worktree_path = binding.get("worktree_path")
    if not worktree_path:
        return

    # 1) Commit must resolve in the bound worktree.
    rev = subprocess.run(
        ["git", "-C", worktree_path, "rev-parse", "--verify",
         f"{head_sha}^{{commit}}"],
        capture_output=True,
        text=True,
    )
    if rev.returncode != 0:
        stderr = rev.stderr.strip() or f"rev-parse exit {rev.returncode}"
        raise ValueError(
            f"{_HEAD_SHA_SHAPE_CLASS} work_item {work_item_id!r} for "
            f"workflow {workflow_id!r} has head_sha={head_sha!r} that does "
            f"not resolve to a commit in worktree {worktree_path!r}: "
            f"{stderr}. This is a mis-seeded SHA (wrong value, wrong "
            f"branch, or not yet fetched into this repo); fix the seed "
            f"before redispatching."
        )

    # 2) Delta vs base_branch must be non-empty.  Skip silently when the
    #    binding carries no base_branch — nothing to compare against.
    base_branch = binding.get("base_branch")
    if not base_branch:
        return
    diff = subprocess.run(
        ["git", "-C", worktree_path, "diff", "--name-only",
         f"{base_branch}...{head_sha}"],
        capture_output=True,
        text=True,
    )
    if diff.returncode != 0:
        stderr = diff.stderr.strip() or f"diff exit {diff.returncode}"
        raise ValueError(
            f"{_HEAD_SHA_SHAPE_CLASS} work_item {work_item_id!r} for "
            f"workflow {workflow_id!r} cannot compute diff "
            f"{base_branch!r}...{head_sha!r} in worktree {worktree_path!r}: "
            f"{stderr}. Most common causes: base_branch ref is missing in "
            f"this worktree (fetch required) or the SHA is on an unrelated "
            f"history."
        )
    if not diff.stdout.strip():
        raise ValueError(
            f"{_HEAD_SHA_SHAPE_CLASS} work_item {work_item_id!r} for "
            f"workflow {workflow_id!r} has head_sha={head_sha!r} with empty "
            f"diff vs base_branch {base_branch!r}: the SHA is either "
            f"already an ancestor of the base (already-landed) or has no "
            f"unique delta to land. Re-seed head_sha to the correct commit, "
            f"or move the work item to a terminal status."
        )


# @decision DEC-CLAUDEX-AGENT-PROMPT-GUARD-001
# @title agent_prompt: producer-side commit-shape guard on work_item.head_sha
# @status accepted
# @rationale Prior-session incident (cutover-maintenance slice 0019/0020): a
#   work_item seed pointed head_sha at a SHA that had already been absorbed
#   into the base branch. The producer returned status=ok, the planner was
#   dispatched, and only the planner's own stop-condition caught the scope
#   mismatch — after several role invocations and operator round-trips.
#   This guard moves the same check upstream into the producer, before any
#   role dispatch fires. The error message is deliberately classified
#   ("commit-shape/config mismatch — not a planner stall") so operators
#   reading logs can route the failure to a seed fix, not a planner
#   investigation. The contract surface is unchanged: head_sha stays a
#   commit reference; staged/index-only bundle state is NOT introduced here.
#   When a valid workflow binding is absent, the guard soft-passes and
#   downstream stages still apply their own checks — this is intentional
#   to avoid breaking early-lifecycle dispatches where no binding yet exists.


# @decision DEC-CLAUDEX-DW-WORKFLOW-JOIN-002
# @title agent_prompt: explicit-override ownership check closes cross-workflow bleed
# @status accepted
# @rationale DEC-CLAUDEX-DW-WORKFLOW-JOIN-001 added workflow_id filtering to
#   the default resolution paths for goal_id / work_item_id, but the explicit-
#   override path still called ``get_work_item(conn, id)`` and
#   ``get_goal(conn, id)`` without verifying workflow ownership. A caller
#   passing ``workflow_id="wf-a"`` with ``work_item_id="WI-owned-by-wf-b"``
#   (or with ``workflow_id IS NULL`` in the row) got a valid-looking contract
#   block that bound the caller's workflow identity to another workflow's
#   work item — exactly the cross-workflow contract bleed DEC-001 was
#   supposed to prevent. This decision closes that gap: the override path
#   validates ownership of both goal_id and work_item_id against the
#   requested workflow_id, cross-validates when both are explicit, and
#   derives goal_id from a validated explicit work_item when omitted so
#   the contract fields stay internally consistent. Every mismatch raises
#   ValueError with explicit ownership language so the operator can route
#   the fix. Fail-closed in every branch. Ownership check uses the existing
#   decision_work_registry accessors — no new authority table introduced.
