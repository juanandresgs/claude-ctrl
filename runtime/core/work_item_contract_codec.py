"""Pure typed decode bridge from ``WorkItemRecord`` to ``WorkItemContract`` (shadow-only).

@decision DEC-CLAUDEX-WORK-ITEM-CONTRACT-CODEC-LEGACY-ALIAS-001
Title: Decode-time legacy vocabulary normalization for scope_json and evaluation_json
Status: accepted
Rationale: External callers (prompts, earlier CLI versions, hand-authored DB rows) may
  use legacy key names such as ``allowed_files`` (instead of ``allowed_paths``) or
  ``evidence`` (instead of ``required_evidence``). Rather than require callers to
  migrate their stored JSON, the codec absorbs one-way legacy-vocabulary translation at
  decode time, BEFORE the closed-key-set check fires. This keeps the encoder (if/when
  added) strictly canonical, preventing drift amplification: only one code path can
  introduce a legacy alias, and that path is inside this module. The alias maps are
  module-level constants so the legal rename surface is auditable without reading
  function bodies. Duplicate-conflict detection (both alias and canonical present with
  different values) makes misconfigured rows loud failures rather than silent
  last-write-wins bugs. Matching-value duplicates are accepted silently as they are
  idempotent (see TestLegacyVocabularyCompatibility.test_scope_duplicate_match_accepted).
  Cross-reference: DEC-CLAUDEX-WORK-ITEM-CONTRACT-CODEC-001 (parent decode-bridge decision).

@decision DEC-CLAUDEX-WORK-ITEM-CONTRACT-CODEC-001
Title: runtime/core/work_item_contract_codec.py owns the decode-only bridge from decision_work_registry.WorkItemRecord to contracts.WorkItemContract
Status: proposed (shadow-mode, Phase 2 prompt-pack workflow-contract bridge)
Rationale: The Phase 2 prompt-pack capstone helper
  :func:`runtime.core.prompt_pack.compile_prompt_pack_for_stage`
  needs typed :class:`contracts.WorkItemContract` instances, but
  callers should not have to construct them by hand once the
  ``work_items`` table holds the canonical state. The previous
  slice (DEC-CLAUDEX-WORK-ITEM-REVIEWER-ROUND-001) added the last
  missing field — ``reviewer_round`` — so :class:`WorkItemRecord`
  now persistently owns every contract field needed to reconstruct
  the typed contract.

  Decode-only by design:

    * :class:`WorkItemRecord` carries two registry-owned provenance
      fields (``version`` and ``author``) that are NOT part of
      :class:`contracts.WorkItemContract`. A symmetric
      ``encode_work_item_contract`` would have to invent defaults
      for those fields, which would create a second authority for
      the registry's provenance vocabulary. The instruction
      explicitly forbids that.
    * The codec is therefore a one-way function: ``decode``-only
      this slice. A later slice can introduce a typed encoder once
      the provenance fields have a canonical owner outside this
      module.

  Decode policy (pinned by tests):

    1. ``record`` must be a :class:`WorkItemRecord` instance. Any
       other type raises ``ValueError``.
    2. Scalar pass-through fields: ``work_item_id``, ``goal_id``,
       ``title``, ``status``, ``reviewer_round``, ``head_sha``,
       ``created_at``, ``updated_at`` copy through verbatim. The
       record's ``goal_id`` is trusted; this slice does NOT add a
       cross-check (``goal_id`` validation lives in the workflow
       capture helper that will land in a later slice).
    3. ``scope_json`` and ``evaluation_json`` must each parse to a
       JSON object. Non-object top-level (list, scalar, null) is
       a ``ValueError`` naming the field. Malformed JSON is a
       ``ValueError`` that includes the underlying parse error.
    4. The literal ``"{}"`` is legal for both fields and decodes
       to an empty :class:`ScopeManifest` /
       :class:`EvaluationContract`. This is the legacy-compatible
       shape that the persistence default uses; without this rule
       any work-item created before the codec landed would fail to
       decode.
    5. Unknown keys are errors. Both nested decoders enforce a
       closed key set:
         - ``scope_json``: ``allowed_paths``, ``required_paths``,
           ``forbidden_paths``, ``state_domains``.
         - ``evaluation_json``: ``required_tests``,
           ``required_evidence``, ``rollback_boundary``,
           ``acceptance_notes``.
       The ``ValueError`` names the field, the unexpected key, and
       the legal key set so the caller can repair the row.
    6. Missing keys default to the dataclass defaults — empty
       tuple for tuple-valued fields, empty string for
       ``rollback_boundary`` / ``acceptance_notes``. This keeps
       the decoder forward-compatible with sparse legacy rows.
    7. Tuple-valued fields must be JSON lists of strings. Non-list
       values, non-string list elements, and nested-list elements
       all raise ``ValueError`` naming the field and the offending
       index.
    8. ``rollback_boundary`` and ``acceptance_notes`` must be JSON
       strings. Non-string values raise ``ValueError`` naming the
       field.
    9. Status validation flows through
       :class:`contracts.WorkItemContract.__post_init__`, which
       rejects unknown statuses. The codec does not catch that
       error.

  Shadow-only discipline:

    * Imports only ``json`` (stdlib) plus
      :mod:`runtime.core.contracts` and
      :mod:`runtime.core.decision_work_registry`. AST tests pin
      this surface and forbid any live-routing token.
    * Not imported by ``runtime/cli.py``,
      ``runtime/core/prompt_pack.py``, ``dispatch_engine``,
      ``completions``, or ``policy_engine``. Reverse-dep guards
      pin every direction.
    * No filesystem I/O, no subprocess, no SQLite — the caller
      owns the connection and the persistence helpers.

  What this module deliberately does NOT do:

    * No encode function (would require provenance authority).
    * No workflow capture helper (a later slice).
    * No goal_id cross-check (a later slice that owns the
      workflow → goal binding).
    * No ``contracts.py`` or ``decision_work_registry.py`` edits.
    * No CLI / hook / prompt-pack wiring.
"""

from __future__ import annotations

import json
from typing import Any, Mapping, Tuple

from runtime.core import contracts
from runtime.core import decision_work_registry as dwr

# ---------------------------------------------------------------------------
# Internal constants
# ---------------------------------------------------------------------------

#: Closed key set for ``scope_json``. Any key outside this frozenset
#: is an error on decode. Symmetric with the four
#: :class:`contracts.ScopeManifest` tuple fields.
_SCOPE_KEYS: frozenset = frozenset(
    {
        "allowed_paths",
        "required_paths",
        "forbidden_paths",
        "state_domains",
    }
)

#: Tuple-valued keys for ``evaluation_json`` (each value must be a
#: JSON list of strings).
_EVAL_TUPLE_KEYS: Tuple[str, ...] = (
    "required_tests",
    "required_evidence",
)

#: String-valued keys for ``evaluation_json`` (each value must be a
#: JSON string).
_EVAL_STRING_KEYS: Tuple[str, ...] = (
    "rollback_boundary",
    "acceptance_notes",
)

#: Closed key set for ``evaluation_json``.
_EVAL_KEYS: frozenset = frozenset(_EVAL_TUPLE_KEYS) | frozenset(_EVAL_STRING_KEYS)

#: Legacy alias map for ``scope_json`` keys.  Renames are applied at decode
#: time BEFORE the closed-key-set check so aliases never widen the legal key
#: surface seen by later validators.  The alias side is the legacy name; the
#: value side is the canonical name in :class:`contracts.ScopeManifest`.
_SCOPE_ALIASES: Mapping[str, str] = {
    "allowed_files": "allowed_paths",
    "forbidden_files": "forbidden_paths",
    "required_files": "required_paths",
    "state_authorities": "state_domains",
    "authority_domains": "state_domains",
}

#: Legacy alias map for ``evaluation_json`` keys.  Same pre-check strategy
#: as ``_SCOPE_ALIASES``.  ``evidence`` is also subject to scalar-string
#: coercion (see :func:`_coerce_legacy_evidence_shape`).
_EVAL_ALIASES: Mapping[str, str] = {
    "acceptance": "acceptance_notes",
    "evidence": "required_evidence",
}


# ---------------------------------------------------------------------------
# Private validation helpers
# ---------------------------------------------------------------------------


def _normalize_legacy_keys(
    field_name: str,
    payload: Mapping[str, Any],
    alias_map: Mapping[str, str],
) -> tuple[dict[str, Any], set[str]]:
    """Rename legacy alias keys to their canonical equivalents on a copy.

    Returns a 2-tuple ``(normalised_payload, aliased_canonicals)`` where
    ``aliased_canonicals`` is the set of canonical key names that were
    populated by a legacy alias during this call.  Callers may use that set
    to apply alias-specific coercions without re-inspecting the alias map.

    A fresh ``dict`` is always returned so the caller works on a mutable
    snapshot and the original mapping is never mutated.

    Conflict policy (pinned by tests):

    * Both alias and canonical present with **different** values →
      ``ValueError`` naming both keys so the caller can repair the row.
    * Both alias and canonical present with **identical** values →
      accepted silently (idempotent write; no information loss).
    * Only alias present → renamed to canonical, alias key removed.
    * Only canonical present (or neither) → passed through unchanged.

    This helper is called before :func:`_require_closed_key_set`, so the
    alias keys never reach the closed-set validator.
    """
    result: dict[str, Any] = dict(payload)
    aliased_canonicals: set[str] = set()
    for alias, canonical in alias_map.items():
        if alias not in result:
            continue
        alias_val = result.pop(alias)
        if canonical in result:
            canonical_val = result[canonical]
            if canonical_val != alias_val:
                raise ValueError(
                    f"decode_work_item_contract: {field_name} contains both "
                    f"legacy key {alias!r} and canonical key {canonical!r} "
                    f"with different values — remove the alias key to resolve "
                    f"the conflict"
                )
            # Identical values: alias key already removed above; canonical
            # key stays. Fall through silently.
        else:
            result[canonical] = alias_val
            aliased_canonicals.add(canonical)
    return result, aliased_canonicals


def _coerce_legacy_evidence_shape(
    payload: dict[str, Any],
    aliased_canonicals: set[str],
) -> dict[str, Any]:
    """Wrap a bare string ``required_evidence`` into a singleton list.

    This coercion fires ONLY when ``required_evidence`` was populated via
    the ``evidence`` legacy alias (i.e. ``"required_evidence"`` appears in
    ``aliased_canonicals``).  A payload that already carries
    ``required_evidence`` with a canonical key is NOT coerced, preserving
    the existing "string value rejected" behaviour for that path.

    When the ``evidence`` alias is used with a scalar string the alias
    normalizer renames the key to ``required_evidence`` but leaves the
    value as a ``str``.  The existing :func:`_decode_string_list` validator
    would then reject it as "not a JSON list".  This coercion converts the
    scalar string to ``["value"]`` so the caller experiences seamless legacy
    compatibility.

    Non-string, non-list values (``int``, ``dict``, ``None``) are left
    untouched; :func:`_decode_string_list` will raise ``ValueError`` for
    them as normal.

    A new ``dict`` copy is returned only when a coercion is needed; the
    caller's dict is returned directly otherwise to avoid unnecessary
    allocation.
    """
    if "required_evidence" not in aliased_canonicals:
        return payload
    value = payload.get("required_evidence")
    if isinstance(value, str):
        result = dict(payload)
        result["required_evidence"] = [value]
        return result
    return payload


def _parse_json_object(field_name: str, raw: Any) -> Mapping[str, Any]:
    """Parse ``raw`` as a JSON object, raising ``ValueError`` on any failure.

    The field name is included in every error message so the caller
    can identify which column failed without inspecting the parse
    error itself.
    """
    if not isinstance(raw, str):
        raise ValueError(
            f"decode_work_item_contract: {field_name} must be a JSON "
            f"string; got {type(raw).__name__}"
        )
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError(
            f"decode_work_item_contract: {field_name} contains malformed "
            f"JSON: {exc}"
        ) from exc
    if not isinstance(parsed, dict):
        raise ValueError(
            f"decode_work_item_contract: {field_name} must be a JSON "
            f"object; got {type(parsed).__name__}"
        )
    return parsed


def _require_closed_key_set(
    field_name: str,
    payload: Mapping[str, Any],
    legal_keys: frozenset,
) -> None:
    """Reject any key in ``payload`` that is not in ``legal_keys``.

    The error message names the field, the offending key, and the
    legal key set so a future caller can repair the row without
    consulting the codec source.
    """
    for key in payload.keys():
        if key not in legal_keys:
            raise ValueError(
                f"decode_work_item_contract: {field_name} contains "
                f"unexpected key {key!r}; legal keys: {sorted(legal_keys)}"
            )


def _decode_string_list(
    field_name: str,
    nested_key: str,
    payload: Mapping[str, Any],
) -> Tuple[str, ...]:
    """Decode ``payload[nested_key]`` as a tuple of strings.

    Missing key → empty tuple (the dataclass default). Present
    value must be a JSON list of strings; anything else raises
    ``ValueError`` naming both the parent field and the nested
    key. The nested key participates in the error message so a
    caller scanning the trace can immediately locate the offending
    fragment.
    """
    if nested_key not in payload:
        return ()
    value = payload[nested_key]
    if not isinstance(value, list):
        raise ValueError(
            f"decode_work_item_contract: {field_name}.{nested_key} must "
            f"be a JSON list; got {type(value).__name__}"
        )
    for index, element in enumerate(value):
        if not isinstance(element, str):
            raise ValueError(
                f"decode_work_item_contract: {field_name}.{nested_key}"
                f"[{index}] must be a string; got "
                f"{type(element).__name__} ({element!r})"
            )
    return tuple(value)


def _decode_string(
    field_name: str,
    nested_key: str,
    payload: Mapping[str, Any],
) -> str:
    """Decode ``payload[nested_key]`` as a string. Missing → empty string."""
    if nested_key not in payload:
        return ""
    value = payload[nested_key]
    if not isinstance(value, str):
        raise ValueError(
            f"decode_work_item_contract: {field_name}.{nested_key} must "
            f"be a JSON string; got {type(value).__name__}"
        )
    return value


# ---------------------------------------------------------------------------
# Nested decoders (private)
# ---------------------------------------------------------------------------


def _decode_scope_manifest(scope_json: str) -> "contracts.ScopeManifest":
    """Decode the persisted ``scope_json`` payload to a typed manifest.

    Empty ``"{}"`` decodes to a default :class:`ScopeManifest` with
    all four tuple fields set to ``()``. Missing keys default to
    empty tuples; unknown keys are errors.

    Legacy alias normalization is applied before the closed-key-set
    check so alias keys do not widen the legal key surface seen by
    downstream validators.
    """
    payload = _parse_json_object("scope_json", scope_json)
    payload, _aliased = _normalize_legacy_keys("scope_json", payload, _SCOPE_ALIASES)
    _require_closed_key_set("scope_json", payload, _SCOPE_KEYS)
    return contracts.ScopeManifest(
        allowed_paths=_decode_string_list("scope_json", "allowed_paths", payload),
        required_paths=_decode_string_list(
            "scope_json", "required_paths", payload
        ),
        forbidden_paths=_decode_string_list(
            "scope_json", "forbidden_paths", payload
        ),
        state_domains=_decode_string_list("scope_json", "state_domains", payload),
    )


def _decode_evaluation_contract(
    evaluation_json: str,
) -> "contracts.EvaluationContract":
    """Decode the persisted ``evaluation_json`` payload to a typed contract.

    Empty ``"{}"`` decodes to a default
    :class:`EvaluationContract` (empty tuples + empty strings).
    Missing tuple keys default to ``()``; missing string keys
    default to ``""``. Unknown keys are errors.

    Legacy alias normalization is applied before the closed-key-set
    check (same pre-check strategy as :func:`_decode_scope_manifest`).
    A scalar-string ``required_evidence`` value originating from the
    ``evidence`` alias is coerced to a singleton list before the
    list-of-strings validator runs.
    """
    payload = _parse_json_object("evaluation_json", evaluation_json)
    payload, aliased = _normalize_legacy_keys("evaluation_json", payload, _EVAL_ALIASES)
    payload = _coerce_legacy_evidence_shape(payload, aliased)
    _require_closed_key_set("evaluation_json", payload, _EVAL_KEYS)
    return contracts.EvaluationContract(
        required_tests=_decode_string_list(
            "evaluation_json", "required_tests", payload
        ),
        required_evidence=_decode_string_list(
            "evaluation_json", "required_evidence", payload
        ),
        rollback_boundary=_decode_string(
            "evaluation_json", "rollback_boundary", payload
        ),
        acceptance_notes=_decode_string(
            "evaluation_json", "acceptance_notes", payload
        ),
    )


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def decode_work_item_contract(
    record: "dwr.WorkItemRecord",
) -> "contracts.WorkItemContract":
    """Decode a :class:`WorkItemRecord` into a typed :class:`WorkItemContract`.

    Pass-through scalar fields: ``work_item_id``, ``goal_id``,
    ``title``, ``status``, ``reviewer_round``, ``head_sha``,
    ``created_at``, ``updated_at``.

    Nested JSON fields:

      * ``scope_json`` → :class:`ScopeManifest` via
        :func:`_decode_scope_manifest`.
      * ``evaluation_json`` → :class:`EvaluationContract` via
        :func:`_decode_evaluation_contract`.

    Raises ``ValueError`` when:

      * ``record`` is not a :class:`WorkItemRecord`.
      * either nested JSON field is malformed.
      * either nested JSON top-level is not an object.
      * any nested key is outside its closed legal key set.
      * any tuple-valued nested field is not a JSON list of
        strings.
      * either string-valued evaluation field is not a JSON string.

    Status / required-string validation is delegated to
    :class:`contracts.WorkItemContract.__post_init__`. The codec
    does not catch errors raised by the dataclass.

    The codec is pure: no I/O, no time calls, no SQLite access. The
    caller is responsible for fetching the record (typically via
    :func:`runtime.core.decision_work_registry.get_work_item`).
    """
    if not isinstance(record, dwr.WorkItemRecord):
        raise ValueError(
            "decode_work_item_contract: record must be a "
            "decision_work_registry.WorkItemRecord instance; "
            f"got {type(record).__name__}"
        )

    scope = _decode_scope_manifest(record.scope_json)
    evaluation = _decode_evaluation_contract(record.evaluation_json)

    return contracts.WorkItemContract(
        work_item_id=record.work_item_id,
        goal_id=record.goal_id,
        title=record.title,
        scope=scope,
        evaluation=evaluation,
        status=record.status,
        reviewer_round=record.reviewer_round,
        head_sha=record.head_sha,
        created_at=record.created_at,
        updated_at=record.updated_at,
    )


__all__ = [
    "decode_work_item_contract",
]
