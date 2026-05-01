"""Transport-adapter contract for the Phase 2b supervision fabric.

Defines the ``TransportAdapter`` Protocol that every transport implementation
must satisfy, plus a module-level registry so callers can look up the right
adapter by name without importing adapter modules directly.

Authority split
---------------
- **This module** owns the contract and registry only.
- **Each adapter module** owns the mapping from that transport's native events
  to ``dispatch_attempts`` state transitions.
- ``dispatch_attempts.py`` owns the actual state-machine transitions; adapters
  must call it, never duplicate its logic.

Transport names must match ``agent_sessions.transport`` values so the
supervision fabric can correlate sessions with their delivery ledger.

@decision DEC-CLAUDEX-TRANSPORT-CONTRACT-001
Title: TransportAdapter Protocol is the sole contract for adapter-to-runtime
       delivery event mapping
Status: accepted
Rationale: CUTOVER_PLAN §Phase 2b exit criterion — "a queued instruction is
  not considered healthy until a transport adapter records delivery claim in
  canonical runtime state."  Before this contract, there was no defined surface
  for an adapter to do that recording.  The Protocol + registry pattern:

    1. Makes the required adapter surface explicit and statically checkable.
    2. Lets callers look up an adapter by transport name (matching the value
       stored in agent_sessions.transport) without knowing the adapter's module.
    3. Keeps the runtime-owned state transitions in dispatch_attempts.py —
       adapters are thin translators, not second ledgers.

  The first adapter is ``claude_code`` (``ClaudeCodeAdapter`` in
  ``runtime.core.claude_code_adapter``).  It is auto-registered on import.
  ``tmux`` and MCP adapters follow in later slices.
"""

from __future__ import annotations

import sqlite3
from typing import Optional, Protocol, runtime_checkable

__all__ = [
    "TransportAdapter",
    "register",
    "get_adapter",
    "list_adapters",
]


@runtime_checkable
class TransportAdapter(Protocol):
    """Protocol every transport adapter must implement.

    Adapters translate their transport's native events into the canonical
    ``dispatch_attempts`` state machine transitions.  Each method corresponds
    to one logical delivery event; implementations call the matching function
    in ``runtime.core.dispatch_attempts``.

    All methods receive an open SQLite connection — the adapter never opens
    its own connection.  This keeps transactions composable and lets tests
    inject in-memory databases.
    """

    @property
    def transport_name(self) -> str:
        """Unique identifier for this transport.

        Must match the value stored in ``agent_sessions.transport`` for
        sessions using this adapter.  Examples: ``"claude_code"``, ``"tmux"``,
        ``"mcp"``.
        """
        ...

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
        """Issue a new pending dispatch attempt for the given seat.

        Called by the orchestrator immediately before sending the instruction
        through the transport layer.  Returns the full attempt row dict
        (including ``attempt_id``) which the caller uses to correlate
        subsequent delivery events.

        Implementations must call ``dispatch_attempts.issue()`` and return
        its result unchanged.
        """
        ...

    def on_delivery_claimed(self, conn: sqlite3.Connection, attempt_id: str) -> dict:
        """Transport has confirmed the instruction reached the agent process.

        Transitions: ``pending`` → ``delivered``.

        For ``claude_code`` this maps to the SubagentStart harness event.
        For ``tmux`` this would map to a confirmed pane write + sentinel echo.
        Implementations must call ``dispatch_attempts.claim()``.
        """
        ...

    def on_acknowledged(self, conn: sqlite3.Connection, attempt_id: str) -> dict:
        """Agent has sent an explicit receipt confirmation for the instruction.

        Transitions: ``delivered`` → ``acknowledged``  (terminal).

        This event exists for transports that provide a discrete out-of-band
        receipt signal — for example, a message-based transport where the agent
        sends an explicit "I got it" before beginning work.

        **Not all transports support this event.**  For ``claude_code``,
        ``SubagentStart`` is both the delivery claim and the implicit receipt
        in a single atomic harness event; there is no discrete subsequent ack.
        The ``claude_code`` adapter therefore does not wire this method to any
        harness event — callers may invoke it directly when they need the
        ``delivered → acknowledged`` terminal transition, but it has no
        automatic trigger.

        **Critical:** ``SubagentStop`` is work *completion*, not receipt
        acknowledgment.  Work completion is owned by ``completions.py`` and
        must not be modelled as delivery acknowledgment.

        Implementations must call ``dispatch_attempts.acknowledge()``.
        """
        ...

    def on_failed(self, conn: sqlite3.Connection, attempt_id: str) -> dict:
        """Non-retryable delivery failure detected by the transport layer.

        Transitions: ``delivered`` → ``failed``.

        Implementations must call ``dispatch_attempts.fail()``.
        """
        ...

    def on_timeout(self, conn: sqlite3.Connection, attempt_id: str) -> dict:
        """Explicit timeout signal from the transport layer.

        Transitions: ``pending`` or ``delivered`` → ``timed_out``.

        Implementations must call ``dispatch_attempts.timeout()``.
        """
        ...


# ---------------------------------------------------------------------------
# Module-level registry
# ---------------------------------------------------------------------------

_REGISTRY: dict[str, TransportAdapter] = {}


def register(adapter: TransportAdapter) -> None:
    """Register a transport adapter instance under its ``transport_name``.

    Registering a second adapter with the same name replaces the first.
    Adapters should call this at module level so they are available as soon
    as their module is imported.
    """
    if not isinstance(adapter, TransportAdapter):
        raise TypeError(
            f"register() requires a TransportAdapter instance; got {type(adapter).__name__!r}"
        )
    _REGISTRY[adapter.transport_name] = adapter


def get_adapter(transport_name: str) -> TransportAdapter:
    """Return the registered adapter for ``transport_name``.

    Raises ``KeyError`` with a descriptive message if the transport is not
    registered.  Callers that handle optional transport are responsible for
    catching ``KeyError``; the registry never returns ``None``.
    """
    if transport_name not in _REGISTRY:
        known = sorted(_REGISTRY)
        raise KeyError(
            f"No adapter registered for transport {transport_name!r}. "
            f"Registered: {known}"
        )
    return _REGISTRY[transport_name]


def list_adapters() -> list[str]:
    """Return sorted list of registered transport names."""
    return sorted(_REGISTRY)
