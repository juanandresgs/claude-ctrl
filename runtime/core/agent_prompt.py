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
import time
from typing import Optional

import runtime.core.decision_work_registry as _dwr

__all__ = [
    "build_agent_dispatch_prompt",
]

_CONTRACT_BLOCK_MARKER = "CLAUDEX_CONTRACT_BLOCK"


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

    Raises ``ValueError`` when a required state lookup fails (e.g. no active goal
    found, no in_progress work item found for the goal).
    """
    if not workflow_id or not workflow_id.strip():
        raise ValueError("workflow_id must be a non-empty string")
    if not stage_id or not stage_id.strip():
        raise ValueError("stage_id must be a non-empty string")

    # Resolve goal_id from runtime state when not supplied.
    if not goal_id:
        active_goals = _dwr.list_goals(conn, status="active")
        if not active_goals:
            raise ValueError(
                f"no active goal found in DB for workflow {workflow_id!r}; "
                "a goal must be in 'active' status before an Agent prompt can be produced"
            )
        goal_id = active_goals[0].goal_id

    # Resolve work_item_id from runtime state when not supplied.
    if not work_item_id:
        in_progress = _dwr.list_work_items(conn, goal_id=goal_id, status="in_progress")
        if not in_progress:
            raise ValueError(
                f"no in_progress work item found for goal {goal_id!r}; "
                "a work item must be in 'in_progress' status before dispatch"
            )
        work_item_id = in_progress[0].work_item_id

    if generated_at is None:
        generated_at = int(time.time())

    contract = {
        "workflow_id": workflow_id,
        "stage_id": stage_id,
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
        f"[ClauDEX dispatch: {workflow_id} / {stage_id} / {goal_id}]\n"
    )

    return {
        "contract": contract,
        "contract_block_line": contract_block_line,
        "prompt_prefix": prompt_prefix,
    }
