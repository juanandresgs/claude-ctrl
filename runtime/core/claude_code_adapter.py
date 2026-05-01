"""ClaudeCode transport adapter — first Phase 2b adapter implementation.

Maps native Claude Code harness events to ``dispatch_attempts`` delivery-state
transitions via the ``TransportAdapter`` protocol.

Domain boundary
---------------
This adapter owns the **delivery** domain only: did the instruction reach the
agent process?  Work completion (did the agent finish the task?) is a separate
domain owned by ``completions.py`` and the completion records table.

``SubagentStop`` is a work-completion event, not a delivery event.  It must
never be used as a delivery receipt signal.

Why ``claude_code`` is the first adapter
-----------------------------------------
1. The Claude Code harness fires deterministic, well-scoped events at the
   Agent dispatch boundary (PreToolUse:Agent, SubagentStart) with no
   pane-scraping or sentinel-echo involvement.
2. The CLAUDEX_CONTRACT_BLOCK wiring (``pre-agent.sh`` + ``subagent-start.sh``)
   already proves the end-to-end hook path fires reliably in production.
3. No broker, watchdog, or tmux pane state is authoritative — the harness
   itself is the single delivery oracle for this transport.

Harness event → delivery state mapping
---------------------------------------
::

    PreToolUse:Agent fires
      └─► adapter.dispatch(conn, seat_id, instruction)
            → attempt issued (pending)

    SubagentStart fires  [harness delivered prompt to subagent process]
      └─► adapter.on_delivery_claimed(conn, attempt_id)
            → pending → delivered

    [No discrete receipt event in claude_code harness]
      on_acknowledged() is available for explicit callers who need the
      delivered → acknowledged terminal state, but it is NOT triggered
      by any automatic harness event for this transport.

    [SubagentStop = WORK COMPLETION — not a delivery event]
      SubagentStop must NOT be mapped here.  Work completion is owned by
      completions.py (completion_records table).

    Explicit caller timeout (e.g. watchdog sweep)
      └─► adapter.on_timeout(conn, attempt_id)
            → pending|delivered → timed_out

    Non-retryable transport failure (harness could not start subagent)
      └─► adapter.on_failed(conn, attempt_id)
            → delivered → failed

Hook wiring note
----------------
The adapter is a pure Python domain layer.  Actual hook plumbing — reading
``attempt_id`` from the pre-agent carrier row and calling these methods at the
right harness event — is the next subsequent slice.  This module proves the
adapter surface is correct and testable before any hook changes land.

@decision DEC-CLAUDEX-TRANSPORT-CONTRACT-001
Title: ClaudeCodeAdapter maps PreToolUse:Agent + SubagentStart to delivery
       state; SubagentStop is not a delivery event
Status: accepted
Rationale: See transport_contract.py rationale.  ``claude_code`` was chosen
  as first adapter because: (a) harness event boundaries are deterministic
  and proven in production (dispatch-debug.jsonl live capture 2026-04-09);
  (b) no auxiliary process is required for delivery confirmation;
  (c) SubagentStart is a reliable delivery oracle.
  SubagentStop was previously (incorrectly) mapped to on_acknowledged; this
  collapses delivery acknowledgment and work completion into one event and
  would create a second authority beside completions.py.  The correction:
  SubagentStart covers both delivery claim and implicit receipt for this
  transport; on_acknowledged() is available but has no automatic harness
  trigger.  SubagentStop belongs to the completions domain exclusively.
"""

from __future__ import annotations

import sqlite3
from typing import Optional

from runtime.core import dispatch_attempts
from runtime.core.transport_contract import TransportAdapter, register

__all__ = ["ClaudeCodeAdapter", "ADAPTER"]

_TRANSPORT_NAME = "claude_code"


class ClaudeCodeAdapter:
    """Transport adapter for the Claude Code CLI harness.

    Translates PreToolUse:Agent / SubagentStart / SubagentStop harness
    events into ``dispatch_attempts`` state transitions.  This class is a
    thin translator — all state-machine logic lives in ``dispatch_attempts``.
    """

    @property
    def transport_name(self) -> str:
        return _TRANSPORT_NAME

    def dispatch(
        self,
        conn: sqlite3.Connection,
        seat_id: str,
        instruction: str,
        *,
        workflow_id: Optional[str] = None,
        work_item_id: str = "",
        goal_id: str = "",
        stage_id: str = "",
        decision_scope: str = "",
        parent_session_id: str = "",
        parent_agent_id: str = "",
        requested_role: str = "",
        target_project_root: str = "",
        worktree_path: str = "",
        prompt_pack_id: str = "",
        contract_json: str = "{}",
        tool_use_id: str = "",
        hook_invocation_id: str = "",
        lease_id: str = "",
        timeout_at: Optional[int] = None,
    ) -> dict:
        """Issue a pending attempt.  Called at PreToolUse:Agent time.

        Returns the full attempt row dict so the caller can extract
        ``attempt_id`` for subsequent delivery events.
        """
        return dispatch_attempts.issue(
            conn,
            seat_id,
            instruction,
            workflow_id=workflow_id,
            work_item_id=work_item_id,
            goal_id=goal_id,
            stage_id=stage_id,
            decision_scope=decision_scope,
            parent_session_id=parent_session_id,
            parent_agent_id=parent_agent_id,
            requested_role=requested_role,
            target_project_root=target_project_root,
            worktree_path=worktree_path,
            prompt_pack_id=prompt_pack_id,
            contract_json=contract_json,
            tool_use_id=tool_use_id,
            hook_invocation_id=hook_invocation_id,
            lease_id=lease_id,
            timeout_at=timeout_at,
        )

    def on_delivery_claimed(self, conn: sqlite3.Connection, attempt_id: str) -> dict:
        """SubagentStart event — harness delivered the prompt to the subagent.

        Transitions: pending → delivered.
        """
        return dispatch_attempts.claim(conn, attempt_id)

    def on_acknowledged(self, conn: sqlite3.Connection, attempt_id: str) -> dict:
        """Explicit delivery receipt confirmation.

        Transitions: delivered → acknowledged  (terminal).

        For ``claude_code``, the harness provides no discrete receipt event
        separate from delivery — ``SubagentStart`` is both claim and implicit
        receipt.  This method is available for callers who explicitly want the
        terminal state (e.g. after a manual confirmation step), but it is NOT
        triggered automatically by any harness event in this transport.

        DO NOT call this on ``SubagentStop``.  ``SubagentStop`` is work
        completion, which is owned by ``completions.py``, not by this adapter.
        """
        return dispatch_attempts.acknowledge(conn, attempt_id)

    def on_failed(self, conn: sqlite3.Connection, attempt_id: str) -> dict:
        """Non-retryable transport-layer delivery failure.

        Transitions: delivered → failed.

        For ``claude_code``, this represents a harness-level failure to start
        or maintain the subagent process — not work failure.  Work failure is
        owned by ``completions.py``.
        """
        return dispatch_attempts.fail(conn, attempt_id)

    def on_timeout(self, conn: sqlite3.Connection, attempt_id: str) -> dict:
        """Explicit timeout signal (e.g. watchdog sweep past timeout_at).

        Transitions: pending|delivered → timed_out.
        """
        return dispatch_attempts.timeout(conn, attempt_id)


# ---------------------------------------------------------------------------
# Module-level singleton — auto-registers when this module is imported.
# ---------------------------------------------------------------------------

ADAPTER: TransportAdapter = ClaudeCodeAdapter()
register(ADAPTER)
