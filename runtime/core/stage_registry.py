"""ClauDEX stage registry — authority for the target workflow graph.

@decision DEC-CLAUDEX-STAGE-REGISTRY-001
Title: runtime/core/stage_registry.py is the sole owner of the target ClauDEX stage graph
Status: accepted (live for all active routing roles via completions.determine_next_role)
Rationale: CUTOVER_PLAN Phase 1 ("Constitutional Kernel") requires an explicit,
  runtime-owned stage registry before reviewer introduction, tester role
  retirement, or goal continuation activation. (The tester retirement
  completed in Phase 8 Slice 11.) All active routing roles (planner, implementer,
  reviewer, guardian) in ``completions.determine_next_role`` delegate to
  ``next_stage()`` via ``_STAGE_TO_ROLE`` (Phase 6 Slice 5 completed guardian
  migration; Phase 6 Slice 4 completed planner migration; Phase 5 completed
  implementer/reviewer migration).

  This module encodes the ClauDEX stage graph (CUTOVER_PLAN §Target
  Architecture → Stage Registry and §Core Loops) as an explicit, immutable
  transition table:

      planner
        -> guardian(provision)
        -> implementer <-> reviewer
        -> guardian(land)
        -> planner
        -> (terminal | user | next work-item loop)

  ``completions.determine_next_role`` delegates all active routing roles
  (planner, implementer, reviewer, guardian) to ``next_stage()`` via
  ``_STAGE_TO_ROLE``. ``dispatch_shadow`` uses this module for parity
  analysis.

  Invariants this module must preserve (enforced by tests, not narrated):
    1. Every transition is declared in TRANSITIONS; nothing else in this
       module encodes routing.
    2. Guardian has two distinct stages keyed by mode — ``guardian:provision``
       and ``guardian:land``. Some error/recovery verdict labels intentionally
       overlap (``denied``, ``skipped``); current overlaps are
       outcome-equivalent (same target role via ``_STAGE_TO_ROLE``).
    3. Reviewer is read-only and has exactly three verdicts:
       ``ready_for_guardian``, ``needs_changes``, ``blocked_by_plan``.
    4. Post-guardian planner continuation is explicit: ``guardian:land`` with
       ``committed`` or ``merged`` routes back to planner, and planner owns
       the next-move decision (``goal_complete``, ``next_work_item``,
       ``needs_user_decision``, ``blocked_external``). The reviewer never
       decides what comes next after landing.
    5. ``TERMINAL`` and ``USER`` are accepted as legal resolution sinks and
       have no outgoing transitions.
    6. ``next_stage`` is a pure function: no DB, no I/O, no mutation.

  What this module deliberately does NOT do:
    - It does not read from or write to SQLite.
    - It does not run any prompt-pack or reflow machinery.

  Delegation status: ``completions.determine_next_role`` delegates all active
  routing roles (planner, implementer, reviewer, guardian) here. Guardian
  compound-stage resolution was completed in Phase 6 Slice 5. Planner
  delegation was completed in Phase 6 Slice 4. Implementer/reviewer
  delegation was completed in Phase 5. Tester entries were removed in
  Phase 5 slice 1.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import FrozenSet, Optional, Tuple

# ---------------------------------------------------------------------------
# Stage identifiers
#
# Stages are flat strings so they can be logged, persisted, and compared
# without importing this module in every caller. Guardian is split into two
# stages because the CUTOVER_PLAN treats provision and land as distinct
# authorities. Some error/recovery verdict labels (denied, skipped)
# intentionally overlap; current overlaps route to the same live role.
# ---------------------------------------------------------------------------

PLANNER: str = "planner"
GUARDIAN_PROVISION: str = "guardian:provision"
IMPLEMENTER: str = "implementer"
REVIEWER: str = "reviewer"
GUARDIAN_LAND: str = "guardian:land"

# Terminal sinks. ``TERMINAL`` means the goal converged or was externally
# blocked; ``USER`` means planner handed control back to the user for a
# decision. Both are legal resting points and have no outgoing transitions.
TERMINAL: str = "terminal"
USER: str = "user"

ACTIVE_STAGES: FrozenSet[str] = frozenset(
    {
        PLANNER,
        GUARDIAN_PROVISION,
        IMPLEMENTER,
        REVIEWER,
        GUARDIAN_LAND,
    }
)

SINK_STAGES: FrozenSet[str] = frozenset({TERMINAL, USER})

ALL_STAGES: FrozenSet[str] = ACTIVE_STAGES | SINK_STAGES


# ---------------------------------------------------------------------------
# Verdict vocabularies — one per active stage.
#
# Verdicts are the only legal payloads a stage can emit to request a
# transition. The pure ``next_stage`` function rejects any (stage, verdict)
# pair not declared below, which is what keeps the graph closed.
# ---------------------------------------------------------------------------

PLANNER_VERDICTS: FrozenSet[str] = frozenset(
    {
        "next_work_item",
        "goal_complete",
        "needs_user_decision",
        "blocked_external",
    }
)

GUARDIAN_PROVISION_VERDICTS: FrozenSet[str] = frozenset(
    {
        "provisioned",
        # Provisioning can legitimately fail. Rather than inventing a new
        # verdict here, we reuse the land-side error vocabulary for denied
        # (guardian refused to provision) and skipped (worktree already
        # exists / no provision needed). Both route back to implementer or
        # planner respectively so the outer loop stays recoverable.
        "denied",
        "skipped",
    }
)

IMPLEMENTER_VERDICTS: FrozenSet[str] = frozenset(
    {
        # Implementer routing is verdict-insensitive in the target graph:
        # every completion (or partial) flows to reviewer. ``partial`` and
        # ``blocked`` still exist for completion-record quality but do not
        # branch the graph. This matches the current DEC-IMPL-CONTRACT-001
        # behavior where verdict affects stop quality, not routing.
        "complete",
        "partial",
        "blocked",
    }
)

REVIEWER_VERDICTS: FrozenSet[str] = frozenset(
    {
        "ready_for_guardian",
        "needs_changes",
        "blocked_by_plan",
    }
)

GUARDIAN_LAND_VERDICTS: FrozenSet[str] = frozenset(
    {
        "committed",
        "merged",
        "denied",
        "skipped",
    }
)


# ---------------------------------------------------------------------------
# Transition table
#
# A Transition is (from_stage, verdict, to_stage). The table below is the
# single authoritative declaration of every legal move in the target graph.
# No other module in this package may define a stage transition — tests pin
# this invariant.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Transition:
    """A legal move in the target ClauDEX stage graph.

    ``from_stage`` and ``to_stage`` are stage identifiers declared at the top
    of this module. ``verdict`` is a string drawn from the owning stage's
    verdict vocabulary.
    """

    from_stage: str
    verdict: str
    to_stage: str


TRANSITIONS: Tuple[Transition, ...] = (
    # --- Planner: owns goal continuation after landing and goal initiation --
    Transition(PLANNER, "next_work_item", GUARDIAN_PROVISION),
    Transition(PLANNER, "goal_complete", TERMINAL),
    Transition(PLANNER, "needs_user_decision", USER),
    Transition(PLANNER, "blocked_external", TERMINAL),
    # --- Guardian (provision mode): provisions a worktree for the implementer
    Transition(GUARDIAN_PROVISION, "provisioned", IMPLEMENTER),
    Transition(GUARDIAN_PROVISION, "denied", IMPLEMENTER),
    Transition(GUARDIAN_PROVISION, "skipped", PLANNER),
    # --- Implementer: always flows to reviewer ------------------------------
    Transition(IMPLEMENTER, "complete", REVIEWER),
    Transition(IMPLEMENTER, "partial", REVIEWER),
    Transition(IMPLEMENTER, "blocked", REVIEWER),
    # --- Reviewer: convergence authority for the work-item inner loop -------
    Transition(REVIEWER, "ready_for_guardian", GUARDIAN_LAND),
    Transition(REVIEWER, "needs_changes", IMPLEMENTER),
    Transition(REVIEWER, "blocked_by_plan", PLANNER),
    # --- Guardian (land mode): sole git-landing authority -------------------
    Transition(GUARDIAN_LAND, "committed", PLANNER),
    Transition(GUARDIAN_LAND, "merged", PLANNER),
    Transition(GUARDIAN_LAND, "denied", IMPLEMENTER),
    Transition(GUARDIAN_LAND, "skipped", PLANNER),
)


# Build a lookup table once at import time. The tuple above remains the
# canonical declaration; this dict is a derived index for O(1) lookups in the
# pure routing function.
_TRANSITION_INDEX: dict[tuple[str, str], str] = {
    (t.from_stage, t.verdict): t.to_stage for t in TRANSITIONS
}

# Verdict vocabulary per active stage. Used by ``allowed_verdicts`` and by the
# invariant tests that prove every Transition's verdict is declared.
_STAGE_VERDICTS: dict[str, FrozenSet[str]] = {
    PLANNER: PLANNER_VERDICTS,
    GUARDIAN_PROVISION: GUARDIAN_PROVISION_VERDICTS,
    IMPLEMENTER: IMPLEMENTER_VERDICTS,
    REVIEWER: REVIEWER_VERDICTS,
    GUARDIAN_LAND: GUARDIAN_LAND_VERDICTS,
}


# ---------------------------------------------------------------------------
# Pure routing / introspection API
#
# Everything below this line is a pure function on the module-level tables.
# No I/O, no mutation, no hidden state.
# ---------------------------------------------------------------------------


def next_stage(from_stage: str, verdict: str) -> Optional[str]:
    """Return the target stage for ``(from_stage, verdict)``, or ``None``.

    This is the pure routing function. It consults ``TRANSITIONS`` and
    returns:

    * the destination stage string when the pair is declared in the table,
    * ``None`` when the pair is not declared (unknown stage, unknown verdict,
      or an unreachable combination).

    It never raises, never reads from the database, and never mutates any
    state. It is safe to call from tests, shadow observers, or prompt-pack
    generators.
    """
    return _TRANSITION_INDEX.get((from_stage, verdict))


def allowed_verdicts(stage: str) -> FrozenSet[str]:
    """Return the declared verdict vocabulary for ``stage``.

    Sink stages (``TERMINAL``, ``USER``) and unknown stages return an empty
    frozenset — they legally have no outgoing moves.
    """
    return _STAGE_VERDICTS.get(stage, frozenset())


def is_terminal(stage: str) -> bool:
    """Return True when ``stage`` is a legal resting sink (no outgoing moves)."""
    return stage in SINK_STAGES


def is_active(stage: str) -> bool:
    """Return True when ``stage`` is an active (non-sink) stage."""
    return stage in ACTIVE_STAGES


def outgoing(stage: str) -> Tuple[Transition, ...]:
    """Return the declared outgoing transitions for ``stage``, in table order."""
    return tuple(t for t in TRANSITIONS if t.from_stage == stage)


def incoming(stage: str) -> Tuple[Transition, ...]:
    """Return the declared incoming transitions targeting ``stage``."""
    return tuple(t for t in TRANSITIONS if t.to_stage == stage)


__all__ = [
    # Stage identifiers
    "PLANNER",
    "GUARDIAN_PROVISION",
    "IMPLEMENTER",
    "REVIEWER",
    "GUARDIAN_LAND",
    "TERMINAL",
    "USER",
    "ACTIVE_STAGES",
    "SINK_STAGES",
    "ALL_STAGES",
    # Verdict vocabularies
    "PLANNER_VERDICTS",
    "GUARDIAN_PROVISION_VERDICTS",
    "IMPLEMENTER_VERDICTS",
    "REVIEWER_VERDICTS",
    "GUARDIAN_LAND_VERDICTS",
    # Transition table
    "Transition",
    "TRANSITIONS",
    # Pure API
    "next_stage",
    "allowed_verdicts",
    "is_terminal",
    "is_active",
    "outgoing",
    "incoming",
]
