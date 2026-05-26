"""v6 runtime stage machine authority.

@decision DEC-V6-STAGE-MACHINE-001
Title: stage_machine.py is the sole v6 workflow transition authority
Status: accepted
Rationale: v5's useful stage-registry idea was undermined by late role/path
  inference and AUTO_DISPATCH text as the real transport.  v6 collapses the
  dispatch graph into this pure table.  Hooks and orchestrators may render
  suggestions, but they must not encode independent role-transition logic.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import FrozenSet, Optional, Tuple

# Stages --------------------------------------------------------------------

PLANNER = "planner"
GUARDIAN_PROVISION = "guardian:provision"
IMPLEMENTER = "implementer"
CRITIC = "critic"
REVIEWER = "reviewer"
GUARDIAN_LAND = "guardian:land"
TERMINAL = "terminal"
USER = "user"
BLOCKED = "blocked"

ACTIVE_STAGES: FrozenSet[str] = frozenset(
    {PLANNER, GUARDIAN_PROVISION, IMPLEMENTER, CRITIC, REVIEWER, GUARDIAN_LAND}
)
SINK_STAGES: FrozenSet[str] = frozenset({TERMINAL, USER, BLOCKED})
ALL_STAGES: FrozenSet[str] = ACTIVE_STAGES | SINK_STAGES

# Verdict vocabularies ------------------------------------------------------

PLANNER_VERDICTS: FrozenSet[str] = frozenset(
    {"next_work_item", "goal_complete", "needs_user_decision", "blocked_external"}
)
GUARDIAN_PROVISION_VERDICTS: FrozenSet[str] = frozenset({"provisioned", "denied", "skipped"})
IMPLEMENTER_VERDICTS: FrozenSet[str] = frozenset({"complete", "partial", "blocked"})
CRITIC_VERDICTS: FrozenSet[str] = frozenset(
    {"ready_for_reviewer", "try_again", "blocked_by_plan", "unavailable"}
)
REVIEWER_VERDICTS: FrozenSet[str] = frozenset(
    {"ready_for_guardian", "needs_changes", "blocked_by_plan"}
)
GUARDIAN_LAND_VERDICTS: FrozenSet[str] = frozenset({"landed", "denied", "skipped"})

STAGE_VERDICTS: dict[str, FrozenSet[str]] = {
    PLANNER: PLANNER_VERDICTS,
    GUARDIAN_PROVISION: GUARDIAN_PROVISION_VERDICTS,
    IMPLEMENTER: IMPLEMENTER_VERDICTS,
    CRITIC: CRITIC_VERDICTS,
    REVIEWER: REVIEWER_VERDICTS,
    GUARDIAN_LAND: GUARDIAN_LAND_VERDICTS,
}

# Stage metadata ------------------------------------------------------------

STAGE_SUBAGENT_TYPE: dict[str, str] = {
    PLANNER: "planner",
    GUARDIAN_PROVISION: "guardian",
    IMPLEMENTER: "implementer",
    CRITIC: "critic",
    REVIEWER: "reviewer",
    GUARDIAN_LAND: "guardian",
}

STAGE_LEASE_ROLE: dict[str, str] = {
    PLANNER: "planner",
    GUARDIAN_PROVISION: "guardian",
    IMPLEMENTER: "implementer",
    CRITIC: "critic",
    REVIEWER: "reviewer",
    GUARDIAN_LAND: "guardian",
}

READ_ONLY_STAGES: FrozenSet[str] = frozenset({CRITIC, REVIEWER})
GIT_CUSTODY_STAGES: FrozenSet[str] = frozenset({GUARDIAN_PROVISION, GUARDIAN_LAND})

# Transitions ---------------------------------------------------------------


@dataclass(frozen=True)
class Transition:
    from_stage: str
    verdict: str
    to_stage: str
    terminal_reason: str = ""
    requires_user: bool = False
    retry_limit: int = 0
    escalation_stage: str = ""

    def as_dict(self) -> dict:
        return asdict(self)


TRANSITIONS: Tuple[Transition, ...] = (
    Transition(PLANNER, "next_work_item", GUARDIAN_PROVISION),
    Transition(PLANNER, "goal_complete", TERMINAL, terminal_reason="goal_complete"),
    Transition(PLANNER, "needs_user_decision", USER, requires_user=True),
    Transition(PLANNER, "blocked_external", BLOCKED, terminal_reason="blocked_external"),
    Transition(GUARDIAN_PROVISION, "provisioned", IMPLEMENTER),
    Transition(GUARDIAN_PROVISION, "denied", PLANNER),
    Transition(GUARDIAN_PROVISION, "skipped", IMPLEMENTER),
    Transition(IMPLEMENTER, "complete", CRITIC),
    Transition(IMPLEMENTER, "partial", CRITIC),
    Transition(IMPLEMENTER, "blocked", PLANNER),
    Transition(CRITIC, "ready_for_reviewer", REVIEWER),
    Transition(CRITIC, "try_again", IMPLEMENTER, retry_limit=2, escalation_stage=REVIEWER),
    Transition(CRITIC, "blocked_by_plan", PLANNER),
    Transition(CRITIC, "unavailable", BLOCKED, terminal_reason="critic_unavailable"),
    Transition(REVIEWER, "ready_for_guardian", GUARDIAN_LAND),
    Transition(REVIEWER, "needs_changes", IMPLEMENTER),
    Transition(REVIEWER, "blocked_by_plan", PLANNER),
    Transition(GUARDIAN_LAND, "landed", PLANNER),
    Transition(GUARDIAN_LAND, "denied", IMPLEMENTER),
    Transition(GUARDIAN_LAND, "skipped", PLANNER),
)

_INDEX: dict[tuple[str, str], Transition] = {(t.from_stage, t.verdict): t for t in TRANSITIONS}


def is_active(stage_id: str) -> bool:
    return stage_id in ACTIVE_STAGES


def is_sink(stage_id: str) -> bool:
    return stage_id in SINK_STAGES


def allowed_verdicts(stage_id: str) -> FrozenSet[str]:
    return STAGE_VERDICTS.get(stage_id, frozenset())


def transition_for(stage_id: str, verdict: str) -> Optional[Transition]:
    return _INDEX.get((stage_id, verdict))


def resolve_transition(stage_id: str, verdict: str, *, retry_count: int = 0) -> Optional[Transition]:
    t = transition_for(stage_id, verdict)
    if t is None:
        return None
    if t.retry_limit and t.escalation_stage and retry_count > t.retry_limit:
        return Transition(
            t.from_stage,
            t.verdict,
            t.escalation_stage,
            terminal_reason=f"retry_limit_exceeded:{t.retry_limit}",
        )
    return t


def next_stage(stage_id: str, verdict: str, *, retry_count: int = 0) -> Optional[str]:
    t = resolve_transition(stage_id, verdict, retry_count=retry_count)
    return t.to_stage if t else None


def subagent_type_for_stage(stage_id: str) -> Optional[str]:
    return STAGE_SUBAGENT_TYPE.get(stage_id)


def lease_role_for_stage(stage_id: str) -> Optional[str]:
    return STAGE_LEASE_ROLE.get(stage_id)


def validate_stage(stage_id: str) -> None:
    if stage_id not in ALL_STAGES:
        raise ValueError(f"unknown v6 stage_id: {stage_id!r}")


def validate_verdict(stage_id: str, verdict: str) -> None:
    validate_stage(stage_id)
    if verdict not in allowed_verdicts(stage_id):
        raise ValueError(
            f"verdict {verdict!r} is not valid for stage {stage_id!r}; "
            f"expected one of {sorted(allowed_verdicts(stage_id))}"
        )


def graph() -> dict:
    return {
        "active_stages": sorted(ACTIVE_STAGES),
        "sink_stages": sorted(SINK_STAGES),
        "transitions": [t.as_dict() for t in TRANSITIONS],
        "stage_subagent_type": dict(STAGE_SUBAGENT_TYPE),
        "read_only_stages": sorted(READ_ONLY_STAGES),
        "git_custody_stages": sorted(GIT_CUSTODY_STAGES),
    }


__all__ = [
    "PLANNER",
    "GUARDIAN_PROVISION",
    "IMPLEMENTER",
    "CRITIC",
    "REVIEWER",
    "GUARDIAN_LAND",
    "TERMINAL",
    "USER",
    "BLOCKED",
    "ACTIVE_STAGES",
    "SINK_STAGES",
    "ALL_STAGES",
    "Transition",
    "TRANSITIONS",
    "allowed_verdicts",
    "transition_for",
    "resolve_transition",
    "next_stage",
    "subagent_type_for_stage",
    "lease_role_for_stage",
    "validate_stage",
    "validate_verdict",
    "graph",
]
