"""Reviewer convergence/readiness domain authority.

Computes whether a workflow's reviewer state is ready for guardian landing.
This is pure domain logic that queries existing authorities — it does not
own any tables, does not modify state, and does not import routing, hooks,
evaluation, or policies.

@decision DEC-CLAUDEX-REVIEWER-CONVERGENCE-001
Title: reviewer_convergence is the sole authority for reviewer readiness computation
Status: accepted
Rationale: CUTOVER_PLAN Phase 4 requires mechanical convergence assessment from
  structured reviewer findings and completion records. This module composes
  existing domain authorities (completions, reviewer_findings, stage_registry)
  into a single readiness result with deterministic reason codes. Orchestrators
  and hooks consume this result instead of reimplementing convergence logic.

Authority scope
---------------
- Reads valid reviewer completions from ``runtime/core/completions.py``
- Reads reviewer verdict vocabulary from ``runtime/core/stage_registry.py``
- Reads open blocking findings from ``runtime/core/reviewer_findings.py``
- Does NOT import dispatch_engine, evaluation_state, evaluation, hooks, or policies
- Does NOT write to any table — all functions are read-only queries + computation

Reason codes
------------
- ``ready``: all readiness conditions met
- ``no_reviewer_completion``: no reviewer completion exists for the workflow at all
- ``invalid_reviewer_completion``: latest reviewer completion has ``valid != 1``
- ``verdict_not_ready``: latest reviewer verdict is not ``ready_for_guardian``
- ``stale_head``: completion REVIEW_HEAD_SHA does not match current head SHA
- ``open_blocking_findings``: open findings with severity ``blocking`` exist
"""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from typing import Optional

from runtime.core import completions
from runtime.core import reviewer_findings as rf
from runtime.core.stage_registry import REVIEWER_VERDICTS
from runtime.schemas import FINDING_SEVERITY_BLOCKING

__all__ = [
    "ReviewerReadiness",
    "REASON_READY",
    "REASON_NO_COMPLETION",
    "REASON_INVALID_COMPLETION",
    "REASON_VERDICT_NOT_READY",
    "REASON_STALE_HEAD",
    "REASON_OPEN_BLOCKING",
    "assess",
]


# ---------------------------------------------------------------------------
# Reason codes
# ---------------------------------------------------------------------------

REASON_READY: str = "ready"
REASON_NO_COMPLETION: str = "no_reviewer_completion"
REASON_INVALID_COMPLETION: str = "invalid_reviewer_completion"
REASON_VERDICT_NOT_READY: str = "verdict_not_ready"
REASON_STALE_HEAD: str = "stale_head"
REASON_OPEN_BLOCKING: str = "open_blocking_findings"


# ---------------------------------------------------------------------------
# Typed result shape
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ReviewerReadiness:
    """Machine-readable reviewer convergence assessment for a workflow.

    All fields are always populated — callers never need to guess which
    fields are present based on the reason code.
    """

    workflow_id: str
    current_head_sha: str
    reviewer_head_sha: Optional[str]
    reviewer_verdict: Optional[str]
    ready_for_guardian: bool
    stale_head: bool
    open_blocking_count: int
    reason: str


# ---------------------------------------------------------------------------
# Assessment
# ---------------------------------------------------------------------------


def assess(
    conn: sqlite3.Connection,
    *,
    workflow_id: str,
    current_head_sha: str,
    work_item_id: Optional[str] = None,
) -> ReviewerReadiness:
    """Compute reviewer readiness for a workflow.

    Readiness is true only when ALL of the following hold:
      1. A reviewer completion exists for the workflow.
      2. The latest reviewer completion (by ``created_at DESC, id DESC``) is
         valid (``valid == 1``).
      3. The latest reviewer verdict is ``ready_for_guardian``.
      4. The completion's ``REVIEW_HEAD_SHA`` exactly matches ``current_head_sha``.
      5. There are zero open blocking findings for the workflow (optionally
         scoped to ``work_item_id`` if supplied).

    Failure modes are deterministic and fail closed — if any condition is not
    met, ``ready_for_guardian`` is False and ``reason`` identifies the first
    failing check (evaluated in priority order above). An invalid latest
    reviewer completion is never silently skipped in favour of an older valid
    one; it produces the distinct ``invalid_reviewer_completion`` reason code.

    This function is read-only: it queries completions and reviewer_findings
    but never writes to any table.
    """
    if not workflow_id:
        raise ValueError("workflow_id must be non-empty")
    if not current_head_sha:
        raise ValueError("current_head_sha must be non-empty")

    # 1. Latest reviewer completion (any validity) for this workflow.
    #    list_completions orders by created_at DESC, id DESC — deterministic.
    all_reviewer = completions.list_completions(
        conn, workflow_id=workflow_id, role="reviewer",
    )
    if not all_reviewer:
        return ReviewerReadiness(
            workflow_id=workflow_id,
            current_head_sha=current_head_sha,
            reviewer_head_sha=None,
            reviewer_verdict=None,
            ready_for_guardian=False,
            stale_head=False,
            open_blocking_count=0,
            reason=REASON_NO_COMPLETION,
        )

    latest = all_reviewer[0]

    # Extract payload fields from the latest completion regardless of validity.
    verdict = latest.get("verdict", "")
    payload = latest.get("payload_json", {})
    if isinstance(payload, str):
        payload = {}
    reviewer_head_sha = payload.get("REVIEW_HEAD_SHA", "")

    # 2. Validity check — latest must be valid.
    if not latest.get("valid"):
        return ReviewerReadiness(
            workflow_id=workflow_id,
            current_head_sha=current_head_sha,
            reviewer_head_sha=reviewer_head_sha or None,
            reviewer_verdict=verdict or None,
            ready_for_guardian=False,
            stale_head=False,
            open_blocking_count=0,
            reason=REASON_INVALID_COMPLETION,
        )

    # 3. Verdict check — must be ready_for_guardian.
    head_stale = reviewer_head_sha != current_head_sha

    # Count open blocking findings.
    # @decision DEC-CLAUDEX-FINDING-SEVERITY-SENTINEL-AUTH-001
    # Title: severity filter value MUST be FINDING_SEVERITY_BLOCKING, not a bare literal
    # Status: accepted
    # Rationale: using a bare "blocking" string would create a parallel authority to
    #   schemas.FINDING_SEVERITIES. If the vocabulary renames this member the filter
    #   silently becomes a no-op (zero matches → false-ready-for-guardian). The named
    #   sentinel from runtime.schemas ensures a single authoritative definition.
    finding_filters = {"workflow_id": workflow_id, "status": "open", "severity": FINDING_SEVERITY_BLOCKING}
    if work_item_id is not None:
        finding_filters["work_item_id"] = work_item_id
    open_blocking = rf.list_findings(conn, **finding_filters)
    open_blocking_count = len(open_blocking)

    if verdict != "ready_for_guardian":
        return ReviewerReadiness(
            workflow_id=workflow_id,
            current_head_sha=current_head_sha,
            reviewer_head_sha=reviewer_head_sha or None,
            reviewer_verdict=verdict or None,
            ready_for_guardian=False,
            stale_head=head_stale,
            open_blocking_count=open_blocking_count,
            reason=REASON_VERDICT_NOT_READY,
        )

    # 4. Head SHA match.
    if head_stale:
        return ReviewerReadiness(
            workflow_id=workflow_id,
            current_head_sha=current_head_sha,
            reviewer_head_sha=reviewer_head_sha or None,
            reviewer_verdict=verdict,
            ready_for_guardian=False,
            stale_head=True,
            open_blocking_count=open_blocking_count,
            reason=REASON_STALE_HEAD,
        )

    # 5. No open blocking findings.
    if open_blocking_count > 0:
        return ReviewerReadiness(
            workflow_id=workflow_id,
            current_head_sha=current_head_sha,
            reviewer_head_sha=reviewer_head_sha,
            reviewer_verdict=verdict,
            ready_for_guardian=False,
            stale_head=False,
            open_blocking_count=open_blocking_count,
            reason=REASON_OPEN_BLOCKING,
        )

    # All conditions met.
    return ReviewerReadiness(
        workflow_id=workflow_id,
        current_head_sha=current_head_sha,
        reviewer_head_sha=reviewer_head_sha,
        reviewer_verdict=verdict,
        ready_for_guardian=True,
        stale_head=False,
        open_blocking_count=0,
        reason=REASON_READY,
    )
