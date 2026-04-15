"""Shadow-mode parity aggregation over ``shadow_stage_decision`` events.

@decision DEC-CLAUDEX-SHADOW-PARITY-001
Title: runtime/core/shadow_parity.py is the read-only aggregator for shadow decision audit events
Status: proposed (shadow-mode)
Rationale: CUTOVER_PLAN §"Replacement by Shadow Then Deletion" requires the
  shadow observer (DEC-CLAUDEX-DISPATCH-SHADOW-001) to earn modularity by
  running in parallel with live routing long enough to prove its target
  graph matches reality modulo a small set of labelled divergences. That
  proof has to be cheap to check, which in turn requires a read-only
  aggregator over the ``shadow_stage_decision`` event stream.

  This module is that aggregator. It is intentionally pure:

    * No SQLite access. Callers pass in a list of event rows; the module
      never opens a connection.
    * No writes or mutations — not even to the argument list.
    * No imports of ``dispatch_engine``, ``completions``, or any other live
      authority. The only runtime dependency is ``dispatch_shadow`` for the
      known reason-code set and (optionally) ``stage_registry`` for the
      stage identifiers used when reporting. We pull both in as read-only
      references.

  The two public entry points are:

    * ``parse_event_detail(row)`` — safely decode a single event row's
      ``detail`` JSON into a dict. Returns ``None`` if the row is not
      machine-readable. Callers can use this to filter rows before
      aggregation.
    * ``summarize(rows)`` — aggregate a list of event rows into a stable
      report dict keyed by reason code, agreement counts, and freshness
      metadata.

  Report shape (stable — tests pin it):

      {
          "total":               int,    # rows considered
          "parseable":           int,    # rows whose detail was valid JSON with required fields
          "agreed":              int,    # rows with agreed == True
          "diverged":            int,    # rows with agreed == False and parseable
          "malformed":           int,    # rows that could not be parsed
          "reasons":             {<reason>: count, ...},   # dense dict, one entry per observed reason
          "known_reasons":       [<reason>, ...],          # sorted list of KNOWN reason codes
          "unknown_reasons":     [<reason>, ...],          # sorted list of reasons NOT in KNOWN_REASONS
          "has_unspecified_divergence": bool,              # True if any row carried REASON_UNSPECIFIED_DIVERGENCE
          "has_unknown_reason":  bool,                     # True if any row carried a reason outside KNOWN_REASONS
          "first_event_id":      int | None,               # smallest row id in the set, or None
          "last_event_id":       int | None,               # largest row id in the set, or None
          "oldest_created_at":   int | None,               # min created_at in the set, or None
          "newest_created_at":   int | None,               # max created_at in the set, or None
      }

  The report is JSON-serialisable; tests pin the field set and types.

  Known reason codes come from ``dispatch_shadow``; if a future slice adds
  a new reason there, this module recognises it automatically via
  ``KNOWN_REASONS``. Any reason outside that set shows up in
  ``unknown_reasons`` and flips ``has_unknown_reason`` to True, which is how
  a parity-check CI job would notice drift.
"""

from __future__ import annotations

import json
from typing import Any, FrozenSet, Iterable, Optional

from runtime.core import dispatch_shadow

# ---------------------------------------------------------------------------
# Known reason codes — derived from dispatch_shadow module.
#
# This is the authoritative set for "expected" reasons. Anything outside
# this set in a live event is, by definition, drift.
# ---------------------------------------------------------------------------

KNOWN_REASONS: FrozenSet[str] = frozenset(
    {
        dispatch_shadow.REASON_PARITY,
        dispatch_shadow.REASON_POST_GUARDIAN_CONTINUATION,
        dispatch_shadow.REASON_GUARDIAN_SKIPPED_PLANNER,
        dispatch_shadow.REASON_UNKNOWN_LIVE_ROLE,
        dispatch_shadow.REASON_UNMAPPED_LIVE_DECISION,
        dispatch_shadow.REASON_UNSPECIFIED_DIVERGENCE,
    }
)

#: Required fields a parseable shadow_stage_decision detail payload must
#: contain. Missing fields → treated as malformed.
REQUIRED_PAYLOAD_FIELDS: FrozenSet[str] = frozenset(
    {
        "live_role",
        "live_verdict",
        "live_next_role",
        "shadow_from_stage",
        "shadow_verdict",
        "shadow_next_stage",
        "agreed",
        "reason",
    }
)


# ---------------------------------------------------------------------------
# Parse
# ---------------------------------------------------------------------------


def parse_event_detail(row: dict) -> Optional[dict]:
    """Parse a single event row's ``detail`` JSON into a payload dict.

    Returns ``None`` when the row has no detail, the JSON is invalid, the
    decoded value is not a dict, or any required field is missing. Callers
    that want to distinguish those cases should inspect the row directly;
    this function is the "can I aggregate this?" predicate.

    Pure: no mutation, no exceptions for any input.
    """
    if not isinstance(row, dict):
        return None
    detail = row.get("detail")
    if not isinstance(detail, str) or not detail.strip():
        return None
    try:
        payload = json.loads(detail)
    except (ValueError, TypeError):
        return None
    if not isinstance(payload, dict):
        return None
    if not REQUIRED_PAYLOAD_FIELDS <= set(payload.keys()):
        return None
    return payload


# ---------------------------------------------------------------------------
# Summarize
# ---------------------------------------------------------------------------


def _empty_report() -> dict:
    return {
        "total": 0,
        "parseable": 0,
        "agreed": 0,
        "diverged": 0,
        "malformed": 0,
        "reasons": {},
        "known_reasons": sorted(KNOWN_REASONS),
        "unknown_reasons": [],
        "has_unspecified_divergence": False,
        "has_unknown_reason": False,
        "first_event_id": None,
        "last_event_id": None,
        "oldest_created_at": None,
        "newest_created_at": None,
    }


def summarize(rows: Iterable[dict]) -> dict:
    """Aggregate shadow decision event rows into a stable report.

    ``rows`` is any iterable of event-row dicts (as returned by
    ``events.query``). The caller is responsible for filtering by
    ``type="shadow_stage_decision"`` before passing rows in — this function
    does not check type, so it can also be used on a manually constructed
    row stream in tests.

    The returned dict is JSON-serialisable; every value is a primitive,
    list, or nested dict.

    This function is pure: it does not sort, mutate, or otherwise touch the
    input iterable beyond a single forward pass.
    """
    report = _empty_report()
    reason_counts: dict[str, int] = {}
    unknown: set[str] = set()

    ids: list[int] = []
    timestamps: list[int] = []

    for row in rows:
        report["total"] += 1
        payload = parse_event_detail(row)
        if payload is None:
            report["malformed"] += 1
            continue
        report["parseable"] += 1

        # Count per-reason even when the reason is malformed-looking so the
        # report surfaces drift rather than hiding it.
        reason = payload.get("reason")
        if not isinstance(reason, str) or not reason:
            reason = "<missing>"
        reason_counts[reason] = reason_counts.get(reason, 0) + 1
        if reason not in KNOWN_REASONS:
            unknown.add(reason)

        if reason == dispatch_shadow.REASON_UNSPECIFIED_DIVERGENCE:
            report["has_unspecified_divergence"] = True

        agreed = payload.get("agreed")
        if agreed is True:
            report["agreed"] += 1
        elif agreed is False:
            report["diverged"] += 1
        # Any other value (None, non-bool) is counted as parseable but not
        # classified — it shows up in reason_counts only.

        # Row-level freshness metadata. Event rows from events.query() carry
        # integer id and created_at; tolerate missing values in synthetic
        # input rows.
        _id = row.get("id")
        if isinstance(_id, int):
            ids.append(_id)
        _ts = row.get("created_at")
        if isinstance(_ts, int):
            timestamps.append(_ts)

    report["reasons"] = reason_counts
    report["unknown_reasons"] = sorted(unknown)
    report["has_unknown_reason"] = bool(unknown)

    if ids:
        report["first_event_id"] = min(ids)
        report["last_event_id"] = max(ids)
    if timestamps:
        report["oldest_created_at"] = min(timestamps)
        report["newest_created_at"] = max(timestamps)

    return report


# ---------------------------------------------------------------------------
# Convenience helper: extract reason sequence from a row stream.
#
# This is used by the end-to-end invariant test to assert that a driven
# workflow produced the exact expected reason sequence. It is also cheap
# for a parity dashboard to consume.
# ---------------------------------------------------------------------------


def reason_sequence(rows: Iterable[dict]) -> list[str]:
    """Return the list of reason codes from a row iterable, in input order.

    Malformed rows are skipped (not replaced with a placeholder) so the
    caller sees exactly what was parseable. If the caller needs to know
    about malformed rows, use ``summarize`` instead.
    """
    sequence: list[str] = []
    for row in rows:
        payload = parse_event_detail(row)
        if payload is None:
            continue
        reason = payload.get("reason")
        if isinstance(reason, str):
            sequence.append(reason)
    return sequence


# ---------------------------------------------------------------------------
# Invariant check
#
# ``check_invariants`` derives a healthy/violations view from a summary
# report. It is pure and deterministic: given the same report, it returns
# the same result. The CLI layer uses this to decide whether to exit zero
# or non-zero; tests can call it directly on synthetic reports.
#
# The health model is conservative: any unspecified divergence or any
# unknown reason code is a violation, because both indicate drift in the
# shadow observer that a future live cutover slice would depend on.
# Malformed rows are counted but NOT currently classified as a violation —
# a single corrupt event should not block the whole invariant check. If
# malformed rows become a problem in practice, add a ``max_malformed``
# threshold via ``check_invariants(..., max_malformed=N)`` rather than
# flipping the default.
# ---------------------------------------------------------------------------

#: Violation code strings returned by ``check_invariants``. Stable contract —
#: CLI output and tests pin these exact strings.
VIOLATION_UNSPECIFIED_DIVERGENCE: str = "unspecified_divergence_present"
VIOLATION_UNKNOWN_REASON: str = "unknown_reason_present"

KNOWN_VIOLATIONS: FrozenSet[str] = frozenset(
    {
        VIOLATION_UNSPECIFIED_DIVERGENCE,
        VIOLATION_UNKNOWN_REASON,
    }
)


def check_invariants(report: dict) -> dict:
    """Derive a healthy/violations view from a ``summarize`` report.

    Returns a dict with stable fields::

        {
            "healthy":    bool,
            "violations": list[str],          # codes from KNOWN_VIOLATIONS
            "details":    dict[str, list],    # per-violation details when applicable
        }

    ``healthy`` is True iff ``violations`` is empty. ``details`` carries
    per-violation context so a CLI consumer can render a helpful error
    message without re-parsing the full report. In particular:

        * ``details[VIOLATION_UNKNOWN_REASON]`` lists the unknown reason
          codes observed (sorted).

    This function is pure: it reads ``report`` only. It tolerates a
    malformed or partially populated report — missing fields are treated
    as falsy rather than raising.
    """
    violations: list[str] = []
    details: dict[str, list] = {}

    if report.get("has_unspecified_divergence"):
        violations.append(VIOLATION_UNSPECIFIED_DIVERGENCE)

    unknown = report.get("unknown_reasons") or []
    # Guard against a malformed report where has_unknown_reason is True but
    # unknown_reasons is not a list.
    if report.get("has_unknown_reason") or unknown:
        violations.append(VIOLATION_UNKNOWN_REASON)
        if isinstance(unknown, list):
            details[VIOLATION_UNKNOWN_REASON] = sorted(str(r) for r in unknown)
        else:
            details[VIOLATION_UNKNOWN_REASON] = []

    return {
        "healthy": not violations,
        "violations": violations,
        "details": details,
    }


__all__ = [
    "KNOWN_REASONS",
    "REQUIRED_PAYLOAD_FIELDS",
    "VIOLATION_UNSPECIFIED_DIVERGENCE",
    "VIOLATION_UNKNOWN_REASON",
    "KNOWN_VIOLATIONS",
    "parse_event_detail",
    "summarize",
    "reason_sequence",
    "check_invariants",
]
