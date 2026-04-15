"""Pure typed bridge between ``contracts.GoalContract`` and ``GoalRecord`` (shadow-only).

@decision DEC-CLAUDEX-GOAL-CONTRACT-CODEC-001
Title: runtime/core/goal_contract_codec.py owns the field-for-field codec between contracts.GoalContract and decision_work_registry.GoalRecord
Status: proposed (shadow-mode, Phase 2 prompt-pack workflow-contract bridge)
Rationale: The previous slice (DEC-CLAUDEX-GOAL-CONTRACTS-001) added the
  ``goal_contracts`` SQLite table and the
  :class:`runtime.core.decision_work_registry.GoalRecord` persistence
  shape, but deliberately did NOT couple persistence to a specific
  typed encoder/decoder. This slice supplies that codec as a
  separate, additive module so a later prompt-pack workflow capture
  helper can resolve a stored ``goal_id`` directly into the
  :class:`runtime.core.contracts.GoalContract` instance the Phase 2
  capstone helper
  :func:`runtime.core.prompt_pack.compile_prompt_pack_for_stage`
  already accepts.

  Scope discipline:

    * **Pure functions.** ``encode_goal_contract`` and
      ``decode_goal_contract`` are deterministic, side-effect free,
      and read no I/O. They take an instance, return an instance.
    * **Field-for-field mapping.** Simple scalars map 1:1. The four
      tuple-shaped contract fields
      (``continuation_rules`` / ``stop_conditions`` /
      ``escalation_boundaries`` / ``user_decision_boundaries``)
      round-trip via deterministic JSON encoding into the matching
      ``*_json`` columns on :class:`GoalRecord`. No second authority
      for the JSON shape; tests pin the exact bytes produced.
    * **Read-only / no DB.** This module never opens a SQLite
      connection. The caller is responsible for the persistence
      round-trip via :func:`decision_work_registry.insert_goal` /
      ``upsert_goal`` / ``get_goal``.
    * **No CLI / hook / bridge wiring.** The module is shadow-only
      and is not imported by ``runtime/cli.py``, any hook adapter,
      ``dispatch_engine``, ``completions``, or ``policy_engine``.
      Tests pin all of those invariants via AST inspection.
    * **No second authority.** This codec does not declare any new
      operational fact. Status validation flows through
      :class:`contracts.GoalContract` and :class:`GoalRecord`'s own
      ``__post_init__`` checks — the codec deliberately does not
      duplicate them.

  Deterministic JSON policy (pinned by tests):

    * Tuple fields are serialized via
      ``json.dumps(list(value), separators=(",", ":"), ensure_ascii=False)``.
    * Compact separators (``","`` and ``":"``) eliminate insignificant
      whitespace, so the byte form is identical for byte-equal
      input.
    * ``ensure_ascii=False`` keeps non-ASCII content as-is so the
      bytes round-trip via UTF-8 without escape inflation. Python's
      ``json`` module is deterministic for both modes; the choice
      here favors readability of stored rows.
    * Element order is **preserved verbatim** — the contract
      tuples are ordered, and the ordering is significant (it is
      the planner's authoring order). The codec never sorts.
    * The empty tuple round-trips to the literal ``"[]"`` and back
      to ``()``.

  Validation rules:

    * ``encode_goal_contract`` rejects non-:class:`contracts.GoalContract`
      input with a clear ``ValueError`` naming the observed type.
    * ``encode_goal_contract`` rejects any tuple element that is
      not a string, with a ``ValueError`` that names the field and
      the offending element. ``contracts.GoalContract`` does not
      enforce this itself, so the codec is the gate that prevents
      malformed payloads from being persisted.
    * ``decode_goal_contract`` rejects non-:class:`GoalRecord`
      input with a clear ``ValueError``.
    * ``decode_goal_contract`` rejects malformed JSON with a
      ``ValueError`` that names the field and includes the
      underlying parse error.
    * ``decode_goal_contract`` rejects JSON whose top-level value
      is not a list with a ``ValueError`` that names the field
      and the observed JSON type.
    * ``decode_goal_contract`` rejects JSON list elements that are
      not strings with a ``ValueError`` that names the field and
      the offending element.
    * Status validation is delegated to
      :class:`contracts.GoalContract.__post_init__`, which raises
      ``ValueError`` on unknown statuses. The codec does not catch
      that error.

  What this module deliberately does NOT do:

    * It does not open a SQLite connection.
    * It does not invent a workflow capture helper.
    * It does not infer goal contracts from any other authority.
    * It does not modify ``runtime/core/contracts.py`` or
      ``runtime/core/decision_work_registry.py``.
    * It does not extend ``runtime/cli.py``, hooks, or any
      live-routing module.
"""

from __future__ import annotations

import json
from typing import Any, Tuple

from runtime.core import contracts
from runtime.core import decision_work_registry as dwr

# ---------------------------------------------------------------------------
# Internal constants
# ---------------------------------------------------------------------------

#: ``json.dumps`` keyword arguments that produce the canonical
#: deterministic byte form for the four tuple-shaped fields. Tests
#: pin the exact bytes produced for representative inputs so a
#: future change to this policy is a deliberate decision, not an
#: accidental drift.
_JSON_DUMPS_KWARGS = {
    "separators": (",", ":"),
    "ensure_ascii": False,
}

#: The four (contract field name, record field name) pairs that
#: round-trip through JSON. Centralised so the encode and decode
#: paths cannot disagree about the mapping.
_TUPLE_FIELD_MAP: Tuple[Tuple[str, str], ...] = (
    ("continuation_rules", "continuation_rules_json"),
    ("stop_conditions", "stop_conditions_json"),
    ("escalation_boundaries", "escalation_boundaries_json"),
    ("user_decision_boundaries", "user_decision_boundaries_json"),
)


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------


def _encode_tuple_field(field_name: str, value: Any) -> str:
    """Validate and JSON-encode a single tuple-shaped contract field.

    Accepts a tuple (or any iterable) of strings. Rejects any
    non-string element with a ``ValueError`` that names the field
    and the offending element.
    """
    if not isinstance(value, tuple):
        raise ValueError(
            f"encode_goal_contract: {field_name} must be a tuple of strings; "
            f"got {type(value).__name__}"
        )
    for index, element in enumerate(value):
        if not isinstance(element, str):
            raise ValueError(
                f"encode_goal_contract: {field_name}[{index}] must be a "
                f"string; got {type(element).__name__} ({element!r})"
            )
    return json.dumps(list(value), **_JSON_DUMPS_KWARGS)


def _decode_tuple_field(field_name: str, value: Any) -> Tuple[str, ...]:
    """Validate and JSON-decode a single tuple-shaped record field.

    Accepts a JSON-encoded string whose top-level value is a list
    of strings. Rejects malformed JSON, non-list top-levels, and
    non-string elements with ``ValueError``s that name the field.
    """
    if not isinstance(value, str):
        raise ValueError(
            f"decode_goal_contract: {field_name} must be a JSON string; "
            f"got {type(value).__name__}"
        )
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as exc:
        raise ValueError(
            f"decode_goal_contract: {field_name} contains malformed JSON: {exc}"
        ) from exc
    if not isinstance(parsed, list):
        raise ValueError(
            f"decode_goal_contract: {field_name} must be a JSON list; got "
            f"{type(parsed).__name__}"
        )
    for index, element in enumerate(parsed):
        if not isinstance(element, str):
            raise ValueError(
                f"decode_goal_contract: {field_name}[{index}] must be a "
                f"string; got {type(element).__name__} ({element!r})"
            )
    return tuple(parsed)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def encode_goal_contract(
    goal: "contracts.GoalContract",
) -> "dwr.GoalRecord":
    """Encode a :class:`contracts.GoalContract` into a :class:`GoalRecord`.

    Field mapping:

      * Scalar fields (``goal_id``, ``desired_end_state``, ``status``,
        ``autonomy_budget``, ``created_at``, ``updated_at``) are
        copied verbatim.
      * The four tuple-shaped fields are JSON-encoded into the
        matching ``*_json`` columns via
        :func:`_encode_tuple_field`.

    Raises ``ValueError`` when ``goal`` is not a
    :class:`contracts.GoalContract` instance, or when any tuple
    element is not a string. Status / timestamp validation is
    delegated to :class:`GoalRecord.__post_init__`.
    """
    if not isinstance(goal, contracts.GoalContract):
        raise ValueError(
            "encode_goal_contract: goal must be a contracts.GoalContract "
            f"instance; got {type(goal).__name__}"
        )

    encoded_tuples = {}
    for contract_field, record_field in _TUPLE_FIELD_MAP:
        encoded_tuples[record_field] = _encode_tuple_field(
            contract_field, getattr(goal, contract_field)
        )

    return dwr.GoalRecord(
        goal_id=goal.goal_id,
        desired_end_state=goal.desired_end_state,
        status=goal.status,
        autonomy_budget=goal.autonomy_budget,
        continuation_rules_json=encoded_tuples["continuation_rules_json"],
        stop_conditions_json=encoded_tuples["stop_conditions_json"],
        escalation_boundaries_json=encoded_tuples["escalation_boundaries_json"],
        user_decision_boundaries_json=encoded_tuples[
            "user_decision_boundaries_json"
        ],
        created_at=goal.created_at,
        updated_at=goal.updated_at,
    )


def decode_goal_contract(
    record: "dwr.GoalRecord",
) -> "contracts.GoalContract":
    """Decode a :class:`GoalRecord` back into a :class:`contracts.GoalContract`.

    Inverse of :func:`encode_goal_contract`. Same field mapping:
    scalar fields copy verbatim, JSON-encoded tuple fields parse
    via :func:`_decode_tuple_field`.

    Raises ``ValueError`` when ``record`` is not a
    :class:`GoalRecord` instance, when any JSON field is malformed,
    when any JSON top-level is not a list, or when any list
    element is not a string. Status / timestamp validation is
    delegated to :class:`contracts.GoalContract.__post_init__`.
    """
    if not isinstance(record, dwr.GoalRecord):
        raise ValueError(
            "decode_goal_contract: record must be a "
            "decision_work_registry.GoalRecord instance; "
            f"got {type(record).__name__}"
        )

    decoded_tuples = {}
    for contract_field, record_field in _TUPLE_FIELD_MAP:
        decoded_tuples[contract_field] = _decode_tuple_field(
            record_field, getattr(record, record_field)
        )

    return contracts.GoalContract(
        goal_id=record.goal_id,
        desired_end_state=record.desired_end_state,
        status=record.status,
        autonomy_budget=record.autonomy_budget,
        continuation_rules=decoded_tuples["continuation_rules"],
        stop_conditions=decoded_tuples["stop_conditions"],
        escalation_boundaries=decoded_tuples["escalation_boundaries"],
        user_decision_boundaries=decoded_tuples["user_decision_boundaries"],
        created_at=record.created_at,
        updated_at=record.updated_at,
    )


__all__ = [
    "encode_goal_contract",
    "decode_goal_contract",
]
