"""Tmux transport adapter — second Phase 2b adapter implementation.

Maps tmux-native delivery signals to ``dispatch_attempts`` state transitions
via the ``TransportAdapter`` protocol.

Domain boundary
---------------
This adapter owns the **delivery** domain only: did the instruction reach the
tmux pane process?  Work completion (did the agent finish the task?) is a
separate domain owned by ``completions.py`` and the completion records table.

The adapter is a **pure domain translator**.  It never reads pane state,
never writes to a tmux pane, and never inspects sentinel echo output.  All
pane interaction is the caller's responsibility (see Caller responsibilities
below).  The adapter translates caller-supplied delivery signals into
``dispatch_attempts`` state transitions only.

Why the adapter does NOT track pane state
-----------------------------------------
Pane IDs, sentinel strings, and pane capture output are transport evidence.
Storing them in ``dispatch_attempts`` would make the runtime domain depend on
tmux-specific transport details, breaking the adapter/domain split that is the
entire point of the ``TransportAdapter`` protocol.  The caller (watchdog or
sentinel observer) is the authority on whether a sentinel was echoed; this
adapter is the authority on what that evidence means for delivery state.

This also means the adapter can be tested entirely with in-memory SQLite
without any tmux process involvement.

Why ``tmux`` is the second adapter
------------------------------------
1. The tmux pane write + sentinel echo is the existing bridge delivery
   mechanism.  Mapping it to the ``dispatch_attempts`` state machine replaces
   the current heuristic pane-text inspection with canonical runtime state.
2. ``on_delivery_claimed()`` for tmux requires external observation (watchdog
   polling pane capture), unlike ``claude_code`` where ``SubagentStart`` is a
   deterministic harness event.  Making the caller responsible for the
   observation step keeps the adapter boundary clean.
3. ``on_acknowledged()`` has genuine utility for tmux: the watched process may
   emit an explicit receipt sentinel distinct from the delivery echo, giving a
   clean ``delivered → acknowledged`` terminal transition without polling.

Caller responsibilities
-----------------------
The external observer (watchdog or sentinel reader) is responsible for:

1. Writing the instruction to the target tmux pane (pane_id is transport
   evidence — the adapter never receives or stores it).
2. Polling the pane capture for the delivery sentinel echo.
3. Calling ``on_delivery_claimed(conn, attempt_id)`` once the sentinel is
   confirmed in the pane capture.
4. Calling ``on_timeout(conn, attempt_id)`` if the sentinel is not seen
   within the window defined by ``attempt["timeout_at"]``.
5. Calling ``on_acknowledged(conn, attempt_id)`` if the pane emits an
   explicit receipt sentinel (e.g. ``__RECEIPT_ACK__``).
6. Calling ``on_failed(conn, attempt_id)`` if the pane process exits or the
   pane is destroyed before delivery claim.

Harness event → delivery state mapping
---------------------------------------
::

    Orchestrator writes instruction to tmux pane
      └─► adapter.dispatch(conn, seat_id, instruction)
            → attempt issued (pending)

    External observer confirms sentinel echo in pane capture
      └─► adapter.on_delivery_claimed(conn, attempt_id)
            → pending → delivered

    Pane emits explicit receipt sentinel [optional]
      └─► adapter.on_acknowledged(conn, attempt_id)
            → delivered → acknowledged  (terminal)

    No sentinel echo within timeout_at window
      └─► adapter.on_timeout(conn, attempt_id)
            → pending|delivered → timed_out

    Pane process exits or pane destroyed before delivery claim
      └─► adapter.on_failed(conn, attempt_id)
            → delivered → failed

    [Note: work completion is NOT modelled here]
      Pane-output inspection for task completion is owned by completions.py,
      not by this adapter.

@decision DEC-CLAUDEX-TRANSPORT-TMUX-001
Title: TmuxAdapter maps external pane-sentinel observation to dispatch_attempts;
       pane state never stored in the runtime domain
Status: accepted
Rationale: The tmux transport adapter is the second adapter behind the
  TransportAdapter protocol (first: claude_code, DEC-CLAUDEX-TRANSPORT-CONTRACT-001).
  Key design choices:
  (a) Caller observes pane state; adapter translates to domain transitions.
      Pane IDs and sentinel strings are transport evidence, not runtime state.
  (b) on_delivery_claimed() is NOT triggered automatically by a harness event
      for tmux — the watchdog/observer must call it after confirming the
      sentinel in the pane capture.
  (c) on_acknowledged() has genuine utility here because tmux panes can emit
      a discrete receipt sentinel before beginning work.
  (d) The tmux bridge transport is containment only; the target architecture
      replaces it with MCP adapters.  This adapter provides runtime-owned
      delivery state for the tmux slice without adding tmux-specific coupling
      to the domain layer.
"""

from __future__ import annotations

import sqlite3
from typing import Optional

from runtime.core import dispatch_attempts
from runtime.core.transport_contract import TransportAdapter, register

__all__ = ["TmuxAdapter", "ADAPTER"]

_TRANSPORT_NAME = "tmux"


class TmuxAdapter:
    """Transport adapter for tmux pane delivery.

    Translates external pane-sentinel observations into ``dispatch_attempts``
    state transitions.  This class is a thin translator — all state-machine
    logic lives in ``dispatch_attempts``.

    The caller is responsible for all pane interaction and sentinel detection.
    This adapter never reads or writes to a tmux pane.
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
        """Issue a pending attempt.  Called when the instruction is dispatched.

        Returns the full attempt row dict so the caller can extract
        ``attempt_id`` for correlating subsequent delivery signals.

        The caller is expected to write the instruction to the tmux pane
        immediately after this call.  The ``attempt_id`` must be retained for
        later calls to ``on_delivery_claimed()``, ``on_timeout()``, etc.
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
        """Caller confirmed the delivery sentinel in the tmux pane capture.

        Transitions: pending → delivered.

        This is NOT triggered automatically.  The external observer (watchdog
        or sentinel reader) must call this after confirming that the sentinel
        echo appeared in the pane capture output.  Pane ID and sentinel string
        are transport evidence tracked by the caller, not stored here.
        """
        return dispatch_attempts.claim(conn, attempt_id)

    def on_acknowledged(self, conn: sqlite3.Connection, attempt_id: str) -> dict:
        """Pane emitted an explicit receipt sentinel.

        Transitions: delivered → acknowledged  (terminal).

        For tmux, the watched process may emit a discrete receipt sentinel
        (e.g. ``__RECEIPT_ACK__``) before beginning work, providing a clean
        terminal delivery state without polling.  This is the primary use of
        ``on_acknowledged()`` for the tmux transport — unlike ``claude_code``
        where this method has no automatic harness trigger.

        The caller must confirm the receipt sentinel in the pane capture before
        calling this method.
        """
        return dispatch_attempts.acknowledge(conn, attempt_id)

    def on_failed(self, conn: sqlite3.Connection, attempt_id: str) -> dict:
        """Pane process exited or pane was destroyed before delivery claim.

        Transitions: delivered → failed.

        This is a transport-layer delivery failure, not a work failure.  Work
        failure is owned by ``completions.py``.
        """
        return dispatch_attempts.fail(conn, attempt_id)

    def on_timeout(self, conn: sqlite3.Connection, attempt_id: str) -> dict:
        """Sentinel echo not confirmed within the timeout_at window.

        Transitions: pending|delivered → timed_out.

        The caller (watchdog sweep) calls this when the attempt's
        ``timeout_at`` has passed without a delivery sentinel being observed.
        """
        return dispatch_attempts.timeout(conn, attempt_id)


# ---------------------------------------------------------------------------
# Module-level singleton — auto-registers when this module is imported.
# ---------------------------------------------------------------------------

ADAPTER: TransportAdapter = TmuxAdapter()
register(ADAPTER)
