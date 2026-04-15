"""Pure decision-capture helper for the prompt-pack path (shadow-only).

@decision DEC-CLAUDEX-PROMPT-PACK-DECISIONS-001
Title: runtime/core/prompt_pack_decisions.py materializes a tuple of DecisionRecord values for a given scope
Status: proposed (shadow-mode, Phase 2 prompt-pack decision capture)
Rationale: The prompt-pack resolver's
  :func:`runtime.core.prompt_pack_resolver.local_decision_summary_from_records`
  bridge consumes a ``tuple[DecisionRecord, ...]`` but leaves the
  actual record selection to the caller. This slice delivers the
  bootstrap helper that produces that tuple from the existing
  canonical decision authority
  (:mod:`runtime.core.decision_work_registry`). It is symmetric
  with :mod:`runtime.core.prompt_pack_state`, which performs the
  same bootstrap role for the ``runtime_state_pack`` layer.

  Scope discipline:

    * **Exact-scope match only.** The helper is a thin wrapper
      over :func:`decision_work_registry.list_decisions` with
      ``scope=<caller_input>``. No fuzzy file matching, no
      domain inference, no fallback scopes, no second relevance
      model. A decision whose ``scope`` column does not match
      the caller's string exactly is not returned. This keeps
      the bootstrap contract small and testable; a later slice
      can introduce a richer relevance walker that still falls
      back to this helper when the richer matcher produces no
      hits.
    * **Read-only.** The helper issues only a SELECT via the
      authority module's list function. No writes, no opened
      transactions. A dedicated test pins that
      ``conn.total_changes`` is unchanged across the call.
    * **Tuple return, not list.** The authority returns a
      ``list[DecisionRecord]`` by convention; this wrapper
      converts to a tuple so the bridge boundary is immutable
      and hashable. The ordering is preserved as-is —
      :func:`decision_work_registry.list_decisions` already
      returns records sorted by ``(created_at ASC, decision_id
      ASC)``, which is the canonical order the
      ``local_decision_summary_from_records`` bridge normalizes
      against.
    * **No new authority.** This module declares no new
      operational fact and owns no state. It is a read surface
      on top of ``decision_work_registry``, full stop.
    * **Shadow-only imports.** Only ``sqlite3``, ``typing``, and
      ``runtime.core.decision_work_registry``. AST tests pin
      that no live routing or CLI module imports this helper
      and that this helper imports no live modules.

  Validation:

    * ``scope`` must be a non-empty, non-whitespace-only string.
      Empty / whitespace-only input raises ``ValueError`` with a
      clear message naming the offending value. Non-string input
      raises ``ValueError`` with the observed type.
    * ``conn`` is not validated beyond the authority module's
      own expectations — passing ``None`` or a closed connection
      will surface the underlying sqlite3 error at query time.
      The helper does not catch those errors; they indicate
      caller bugs that the authority module's error messages
      already describe.

  What this module deliberately does NOT do:

    * It does not open a SQLite connection.
    * It does not run any write / UPDATE / DELETE on the
      ``decisions`` table.
    * It does not sort, filter, or merge the records beyond
      what :func:`decision_work_registry.list_decisions` already
      does.
    * It does not wrap the records in another dataclass; the
      caller gets canonical :class:`DecisionRecord` instances
      that feed straight into
      :func:`local_decision_summary_from_records`.
"""

from __future__ import annotations

import sqlite3
from typing import Tuple

from runtime.core import decision_work_registry as dwr


def capture_relevant_decisions(
    conn: sqlite3.Connection,
    *,
    scope: str,
) -> Tuple[dwr.DecisionRecord, ...]:
    """Return all :class:`DecisionRecord` values whose scope matches exactly.

    Parameters:

      * ``conn`` — open SQLite connection owned by the caller.
        The helper issues only a SELECT via
        :func:`runtime.core.decision_work_registry.list_decisions`;
        no writes, no transaction.
      * ``scope`` — the exact scope string to match. Must be a
        non-empty, non-whitespace-only string.

    Returns a tuple of :class:`DecisionRecord` values sorted by
    ``(created_at ASC, decision_id ASC)`` — the canonical order
    the authority module already produces. The tuple is empty
    when no records match the scope.

    Raises ``ValueError`` when ``scope`` is not a non-empty
    string. The helper does not swallow sqlite3 errors; a closed
    or invalid connection surfaces the underlying exception at
    query time.
    """
    if not isinstance(scope, str):
        raise ValueError(
            "capture_relevant_decisions: scope must be a string; "
            f"got {type(scope).__name__}"
        )
    if not scope.strip():
        raise ValueError(
            "capture_relevant_decisions: scope must be a non-empty, "
            "non-whitespace-only string"
        )

    records = dwr.list_decisions(conn, scope=scope)
    return tuple(records)


__all__ = [
    "capture_relevant_decisions",
]
