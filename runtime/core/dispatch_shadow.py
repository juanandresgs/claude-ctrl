"""Shadow observer for live dispatch — pure live↔shadow decision mapper.

@decision DEC-CLAUDEX-DISPATCH-SHADOW-001
Title: runtime/core/dispatch_shadow.py is the pure live↔shadow comparator
Status: accepted
Rationale: CUTOVER_PLAN §"Replacement by Shadow Then Deletion" requires the
  new stage registry to earn modularity before owning live routing. This
  module is a pure comparator/audit mapper that converts a live ``(role,
  verdict, next_role)`` routing decision into a structured shadow decision
  payload for parity analysis. ``stage_registry`` is the authoritative
  routing graph — ``completions.determine_next_role()`` delegates all active
  routing roles (planner, implementer, reviewer, guardian) to it. This module
  records what stage_registry would produce and compares it to the live result.

  It is pure by design:

    * No SQLite access.
    * No ``events.emit`` calls.
    * No mutation of any argument.
    * Does not import ``dispatch_engine`` or ``completions`` (avoiding a
      circular import back to the live authority).

  The only runtime dependency is ``runtime.core.stage_registry``.

  The mapping rules encoded below mirror the CUTOVER_PLAN state:

    * Phase 5: live implementer routes to reviewer directly. The shadow
      ``IMPLEMENTER → REVIEWER`` mapping is now direct parity (no collapse).
    * ``guardian`` splits into ``guardian:provision`` vs ``guardian:land``
      based on (a) the live ``guardian_mode`` hint or, when absent, (b) the
      verdict (``provisioned`` forces provision mode).
    * ``planner`` (Phase 6 Slice 4): live path consumes structured planner
      completion records and routes via ``completions.determine_next_role()``
      → ``stage_registry``. Shadow preserves the actual PLAN_VERDICT
      verbatim — no fallback to ``next_work_item`` when empty. An empty
      verdict means the live path errored (no completion record), and
      ``dispatch_engine`` already skips shadow emission in that case.

  Phase 6 Slice 5 closed all planned divergences:

    * ``guardian:land`` with verdict ``committed``, ``merged``, or ``pushed``: live now
      routes to ``planner`` (post-guardian continuation), matching shadow.
      Previously live returned ``None`` (cycle complete).
    * ``guardian:land`` with verdict ``skipped``: live now routes to
      ``planner`` (goal reassessment), matching shadow. Previously live
      routed to ``implementer``.

  Phase 8 Slice 11 retired the legacy ``tester`` role. The legacy
  ``tester → reviewer`` shadow collapse and the
  ``tester(ready_for_guardian) → guardian:land`` legacy mapping were both
  removed; ``tester`` is no longer in ``KNOWN_LIVE_ROLES`` so any residual
  ``live_role="tester"`` input produces ``reason=unknown_live_role`` with
  every shadow field ``None``. All (live_role, verdict) pairs with a live
  role in ``KNOWN_LIVE_ROLES`` are expected to agree. The divergence reason
  codes are retained for backward compatibility with any persisted events
  from before Slice 5.
"""

from __future__ import annotations

from typing import Optional, Tuple

from runtime.core import stage_registry as sr

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

#: Reason codes emitted by ``compute_shadow_decision``. These are part of the
#: public payload contract — consumers (dashboards, tests, future parity
#: analyzers) key off them. Do not rename without updating all callers.
REASON_PARITY: str = "parity"
REASON_POST_GUARDIAN_CONTINUATION: str = "post_guardian_planner_continuation"
REASON_GUARDIAN_SKIPPED_PLANNER: str = "guardian_skipped_routes_to_planner_in_shadow"
REASON_UNKNOWN_LIVE_ROLE: str = "unknown_live_role"
REASON_UNMAPPED_LIVE_DECISION: str = "unmapped_live_decision"
REASON_UNSPECIFIED_DIVERGENCE: str = "unspecified_divergence"

#: Live roles this shadow observer understands. Any other string produces a
#: decision payload with ``reason=unknown_live_role`` and every shadow field
#: set to ``None``. The observer never raises on unknown input.
KNOWN_LIVE_ROLES: frozenset[str] = frozenset(
    {"planner", "implementer", "guardian", "reviewer"}
)


# ---------------------------------------------------------------------------
# Pure live → shadow mappers
# ---------------------------------------------------------------------------


def map_live_to_shadow_stage(
    live_role: str,
    live_verdict: str,
    guardian_mode: str,
) -> Tuple[Optional[str], Optional[str]]:
    """Map a live ``(role, verdict)`` to the shadow ``(stage, verdict)`` pair.

    This encodes the guardian mode split (provision vs land). The return
    value is a tuple ``(shadow_from_stage, shadow_verdict)``; both members
    are ``None`` when the live role is not one of ``KNOWN_LIVE_ROLES``.

    Arguments:
        live_role: Normalised live role string (``planner``, ``implementer``,
            ``guardian``, ``reviewer``). Case-sensitive.
        live_verdict: Live completion verdict. All routing roles now have
            structured completion records (planner added Phase 6 Slice 4).
            Empty string means the live path errored before reading the
            completion — ``dispatch_engine`` skips shadow emission in that
            case, so empty verdicts should not reach this function in
            production.
        guardian_mode: Hint from the live dispatch engine. ``"provision"`` on
            the planner→guardian leg, empty string otherwise. Used only when
            ``live_role == "guardian"``.
    """
    if live_role == "planner":
        # Phase 6 Slice 4: planner has a structured completion contract.
        # Preserve the actual verdict verbatim — no fallback. If the caller
        # passes empty, sr.next_stage("planner", "") returns None (no
        # matching transition), which is correct: there is no routing
        # decision to compare.
        return sr.PLANNER, live_verdict

    if live_role == "implementer":
        # Implementer verdicts (complete/partial/blocked) all feed into
        # reviewer in the shadow graph. Preserve the verdict verbatim so the
        # payload carries the real completion status.
        return sr.IMPLEMENTER, live_verdict or "complete"

    if live_role == "reviewer":
        # Reviewer is identity-mapped — it already is the shadow stage.
        # Verdicts are identical (ready_for_guardian / needs_changes /
        # blocked_by_plan).
        return sr.REVIEWER, live_verdict

    if live_role == "guardian":
        # Provision vs land disambiguation:
        #   1. Explicit guardian_mode hint wins when present.
        #   2. Fallback: verdict "provisioned" forces provision mode.
        #   3. Otherwise default to land mode (the dominant live path).
        if guardian_mode == "provision" or live_verdict == "provisioned":
            return sr.GUARDIAN_PROVISION, live_verdict
        return sr.GUARDIAN_LAND, live_verdict

    return None, None


def translate_live_next_role(
    live_role: str,
    live_verdict: str,
    live_next_role: Optional[str],
    guardian_mode: str,
) -> Optional[str]:
    """Translate a live ``next_role`` string into the shadow stage space.

    This is what makes the ``agreed`` flag meaningful: the live and shadow
    tables speak different vocabularies (guardian is a single role split
    across two shadow stages), so a string comparison on raw values would
    always disagree. This function produces the shadow-space equivalent of
    whatever the live dispatcher decided.

    Returns ``None`` when the live next_role is ``None`` (cycle complete) or
    unrecognised.
    """
    if live_next_role is None or live_next_role == "":
        return None

    if live_next_role == "planner":
        return sr.PLANNER
    if live_next_role == "implementer":
        return sr.IMPLEMENTER
    if live_next_role == "reviewer":
        return sr.REVIEWER
    if live_next_role == "guardian":
        # Determine which guardian mode the live path is heading into.
        # The live dispatcher only sets guardian_mode on the planner leg.
        if guardian_mode == "provision":
            return sr.GUARDIAN_PROVISION
        # reviewer(ready_for_guardian) → guardian is always land mode.
        if live_role == "reviewer" and live_verdict == "ready_for_guardian":
            return sr.GUARDIAN_LAND
        # Unknown destination mode — refuse to guess.
        return None
    return None


# ---------------------------------------------------------------------------
# Decision computation
# ---------------------------------------------------------------------------


def compute_shadow_decision(
    *,
    live_role: str,
    live_verdict: str,
    live_next_role: Optional[str],
    guardian_mode: str = "",
) -> dict:
    """Compute a shadow decision payload for a live dispatch outcome.

    This is the single public entry point. Callers pass the live routing
    facts and receive a dict shaped like::

        {
            "live_role":         str,
            "live_verdict":      str,
            "live_next_role":    str | None,
            "shadow_from_stage": str | None,
            "shadow_verdict":    str | None,
            "shadow_next_stage": str | None,
            "agreed":            bool,
            "reason":            str,
        }

    The payload is JSON-serialisable (all values are primitives or None).
    The function never raises — unknown inputs produce a payload with
    ``reason`` set to one of ``REASON_UNKNOWN_LIVE_ROLE`` or
    ``REASON_UNMAPPED_LIVE_DECISION`` and every shadow field set to ``None``.
    """
    payload: dict = {
        "live_role": live_role or "",
        "live_verdict": live_verdict or "",
        "live_next_role": live_next_role,
        "shadow_from_stage": None,
        "shadow_verdict": None,
        "shadow_next_stage": None,
        "agreed": False,
        "reason": REASON_UNSPECIFIED_DIVERGENCE,
    }

    if live_role not in KNOWN_LIVE_ROLES:
        payload["reason"] = REASON_UNKNOWN_LIVE_ROLE
        return payload

    shadow_from_stage, shadow_verdict = map_live_to_shadow_stage(
        live_role, live_verdict, guardian_mode
    )
    payload["shadow_from_stage"] = shadow_from_stage
    payload["shadow_verdict"] = shadow_verdict

    if shadow_from_stage is None:
        payload["reason"] = REASON_UNMAPPED_LIVE_DECISION
        return payload

    shadow_next_stage = sr.next_stage(shadow_from_stage, shadow_verdict or "")
    payload["shadow_next_stage"] = shadow_next_stage

    translated_live = translate_live_next_role(
        live_role, live_verdict, live_next_role, guardian_mode
    )

    agreed = shadow_next_stage == translated_live
    payload["agreed"] = agreed
    payload["reason"] = _diagnose(
        agreed=agreed,
        live_role=live_role,
        live_verdict=live_verdict,
        live_next_role=live_next_role,
        shadow_next_stage=shadow_next_stage,
    )
    return payload


def _diagnose(
    *,
    agreed: bool,
    live_role: str,
    live_verdict: str,
    live_next_role: Optional[str],
    shadow_next_stage: Optional[str],
) -> str:
    """Return a stable reason code for a live/shadow outcome."""
    if agreed:
        return REASON_PARITY

    # Legacy divergence classifier 1 (pre-Slice-5 records only):
    # Before Phase 6 Slice 5, live guardian committed/merged returned None
    # (cycle complete) while shadow routed to planner. These patterns no
    # longer occur in live routing (guardian now routes to planner), but this
    # classifier is retained for backward compatibility with persisted events
    # written before the cutover.
    if (
        live_role == "guardian"
        and live_verdict in ("committed", "merged", "pushed")
        and (live_next_role is None or live_next_role == "")
        and shadow_next_stage == sr.PLANNER
    ):
        return REASON_POST_GUARDIAN_CONTINUATION

    # Legacy divergence classifier 2 (pre-Slice-5 records only):
    # Before Phase 6 Slice 5, live guardian skipped routed to implementer
    # while shadow routed to planner. Live now also routes to planner.
    # Retained for backward compatibility with pre-cutover persisted events.
    if (
        live_role == "guardian"
        and live_verdict == "skipped"
        and live_next_role == "implementer"
        and shadow_next_stage == sr.PLANNER
    ):
        return REASON_GUARDIAN_SKIPPED_PLANNER

    return REASON_UNSPECIFIED_DIVERGENCE


__all__ = [
    "REASON_PARITY",
    "REASON_POST_GUARDIAN_CONTINUATION",
    "REASON_GUARDIAN_SKIPPED_PLANNER",
    "REASON_UNKNOWN_LIVE_ROLE",
    "REASON_UNMAPPED_LIVE_DECISION",
    "REASON_UNSPECIFIED_DIVERGENCE",
    "KNOWN_LIVE_ROLES",
    "map_live_to_shadow_stage",
    "translate_live_next_role",
    "compute_shadow_decision",
]
