"""Pure typed workflow-contract capture helper (shadow-only).

@decision DEC-CLAUDEX-WORKFLOW-CONTRACT-CAPTURE-001
Title: runtime/core/workflow_contract_capture.py chains the four existing helpers into a single read-only (goal_id, work_item_id) -> (GoalContract, WorkItemContract) capture
Status: proposed (shadow-mode, Phase 2 prompt-pack workflow-contract bridge)
Rationale: The Phase 2 capstone helper
  :func:`runtime.core.prompt_pack.compile_prompt_pack_for_stage`
  still requires caller-built ``contracts.GoalContract`` and
  ``contracts.WorkItemContract`` instances. Previous slices landed
  every primitive needed to resolve them from SQLite:

    * ``goal_contracts`` table + ``dwr.get_goal``
      (DEC-CLAUDEX-GOAL-CONTRACTS-001)
    * ``goal_contract_codec.decode_goal_contract``
      (DEC-CLAUDEX-GOAL-CONTRACT-CODEC-001)
    * ``work_items.reviewer_round`` column + ``dwr.get_work_item``
      (DEC-CLAUDEX-WORK-ITEM-REVIEWER-ROUND-001)
    * ``work_item_contract_codec.decode_work_item_contract``
      (DEC-CLAUDEX-WORK-ITEM-CONTRACT-CODEC-001)

  This module is the final piece: a thin deterministic helper that
  chains those four reads into a single entry point so a future
  prompt-pack wiring slice can call
  ``capture_workflow_contracts(conn, goal_id=..., work_item_id=...)``
  and receive the typed ``(GoalContract, WorkItemContract)`` tuple
  the capstone helper already accepts.

  Scope discipline:

    * **Read-only.** The helper issues only two ``SELECT`` queries
      via the existing ``dwr.get_*`` helpers. No writes, no
      transaction, no schema changes. A dedicated test snapshots
      ``conn.total_changes`` across the call.
    * **Single owner of the goal_id cross-check.** The individual
      decoders deliberately do not cross-check ``goal_id`` because
      they decode from a single record and have no authority over
      the relationship between the two records. This helper is
      the right place for that check because it owns both reads.
      ``LookupError`` is raised for missing records; ``ValueError``
      is raised for the cross-check mismatch — the two error
      classes are distinct on purpose so callers can handle them
      differently.
    * **No new authority.** The helper owns no state and declares
      no new operational fact. It is a thin read surface on top
      of the existing authority modules.
    * **No CLI / hook / prompt-pack wiring.** Not imported by
      ``runtime/cli.py``, ``runtime/core/prompt_pack.py``, any hook
      adapter, ``dispatch_engine``, ``completions``, or
      ``policy_engine``. AST tests pin every direction.
    * **Error ordering is deterministic.** When multiple
      conditions fail (e.g. both records missing, or one missing
      and the other mismatched), the helper checks in a fixed
      order so tests can pin which error surfaces first:
        1. missing goal → ``LookupError``
        2. missing work item → ``LookupError``
        3. ``work_item.goal_id`` mismatch → ``ValueError``
      A caller that needs both errors can catch and retry after
      the first surfaces.
"""

from __future__ import annotations

import sqlite3
from typing import Tuple

from runtime.core import contracts
from runtime.core import decision_work_registry as dwr
from runtime.core import goal_contract_codec
from runtime.core import work_item_contract_codec


def capture_workflow_contracts(
    conn: sqlite3.Connection,
    *,
    goal_id: str,
    work_item_id: str,
) -> Tuple["contracts.GoalContract", "contracts.WorkItemContract"]:
    """Capture the typed ``(GoalContract, WorkItemContract)`` pair for a workflow.

    Chains four existing read helpers into one deterministic,
    read-only pipeline:

      1. ``dwr.get_goal(conn, goal_id)``
      2. ``dwr.get_work_item(conn, work_item_id)``
      3. ``goal_contract_codec.decode_goal_contract(...)``
      4. ``work_item_contract_codec.decode_work_item_contract(...)``

    Parameters:

      * ``conn`` — open SQLite connection owned by the caller. The
        helper issues only ``SELECT`` queries via the registry's
        ``get_*`` helpers; no writes, no transaction.
      * ``goal_id`` — required non-empty string identifying the
        goal whose contract should be captured.
      * ``work_item_id`` — required non-empty string identifying
        the work item whose contract should be captured.

    Returns a ``(goal_contract, work_item_contract)`` tuple of
    canonical typed contract instances suitable for the prompt-pack
    capstone helper's ``goal`` / ``work_item`` arguments.

    Raises:

      * ``LookupError`` when no goal row exists for ``goal_id``.
        The error message names ``goal_id`` explicitly.
      * ``LookupError`` when no work-item row exists for
        ``work_item_id``. The error message names ``work_item_id``
        explicitly.
      * ``ValueError`` when the work-item record's ``goal_id``
        column does not match the caller-supplied ``goal_id``.
        The error message names both ids so the caller can
        diagnose the mismatch without inspecting the records.
      * Any ``ValueError`` raised by the two underlying codecs —
        malformed nested JSON, unknown keys, non-string list
        elements, etc. The capture helper does not catch those
        errors; they indicate corrupt persisted rows that the
        caller must repair.

    The helper is pure (apart from the caller's connection): no
    filesystem I/O, no subprocess, no time calls, no RNG. A test
    pins that ``conn.total_changes`` is unchanged across the call.
    """
    goal_record = dwr.get_goal(conn, goal_id)
    if goal_record is None:
        raise LookupError(
            f"capture_workflow_contracts: no goal row for goal_id={goal_id!r}"
        )

    work_item_record = dwr.get_work_item(conn, work_item_id)
    if work_item_record is None:
        raise LookupError(
            "capture_workflow_contracts: no work-item row for "
            f"work_item_id={work_item_id!r}"
        )

    if work_item_record.goal_id != goal_id:
        raise ValueError(
            "capture_workflow_contracts: work_item.goal_id="
            f"{work_item_record.goal_id!r} does not match caller goal_id="
            f"{goal_id!r} (work_item_id={work_item_id!r})"
        )

    goal_contract = goal_contract_codec.decode_goal_contract(goal_record)
    work_item_contract = work_item_contract_codec.decode_work_item_contract(
        work_item_record
    )
    return goal_contract, work_item_contract


__all__ = [
    "capture_workflow_contracts",
]
