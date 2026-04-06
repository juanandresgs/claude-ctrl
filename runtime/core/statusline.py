"""Runtime-backed statusline snapshot projection.

Read-only projection across all runtime tables. Gathers all state in a single
pass and returns a unified dict suitable for ANSI HUD rendering by
scripts/statusline.sh without that script needing to call multiple subcommands.

TKT-011 promotes this from a stub to the canonical implementation.
TKT-024 establishes evaluation_state as the sole readiness display.
W-CONV-4 removes proof_state from the snapshot dict entirely — the proof_state
table is retained for storage, but operators must see only one readiness signal.
W-SL-160 introduces per-section partial failure reporting and a last_review
section that shows whether the latest output was reviewed by Codex/Gemini.

@decision DEC-RT-011
Title: Statusline snapshot is a read-only projection across all runtime tables
Status: accepted
Rationale: snapshot() is the single read surface for the statusline HUD. It
  reads evaluation_state (TKT-024 sole readiness authority), agent_markers,
  worktrees, dispatch_cycles, completion_records, and events in one pass and
  returns a canonical dict. No writes happen here.
  All fields default to None/0/[] so the statusline never crashes on an empty
  or partially-populated DB. Per-section try/except (W-SL-160) reports partial
  failures without suppressing successfully-loaded sections: if any section
  fails, status becomes 'partial_failure' and an errors[] list accumulates the
  section name and exception message.

@decision DEC-EVAL-006
Title: statusline.py shows eval_status as the sole readiness display (TKT-024 + W-CONV-4)
Status: accepted
Rationale: After TKT-024 cutover, evaluation_state is the sole readiness
  authority. W-CONV-4 completes the cleanup: proof_status and proof_workflow
  are removed from the snapshot dict entirely. Operators were seeing both
  signals which could contradict each other. proof_state table and proof.py
  module are retained (storage is not removed), but the display surface now
  exposes only eval_status, eval_workflow, and eval_head_sha for readiness.

@decision DEC-WS6-001
Title: dispatch_status derived from completion records, not dispatch_queue
Status: accepted
Rationale: WS6 removes dispatch_queue from the routing hot-path. post-task.sh
  no longer enqueues into dispatch_queue; the queue was a write-only sink with
  no live readers in the enforcement path. dispatch_status is now derived from
  the latest completion record using determine_next_role(role, verdict) — the
  single authoritative routing table in completions.py. dispatch_workflow,
  dispatch_from_role, and dispatch_from_verdict are new fields that let the HUD
  surface where the routing decision came from. dispatch_initiative and
  dispatch_cycle_id remain (read from dispatch_cycles) for initiative-level
  tracking, which is not routing state.

@decision DEC-SL-160
Title: Per-section partial failure reporting and review status indicator
Status: accepted
Rationale: W-SL-160 replaces the single broad try/except with per-section
  isolation. Each query section (eval, markers, worktrees, dispatch, events,
  last_review) is wrapped independently. If any section fails, status becomes
  'partial_failure' and the section name + exception string are appended to
  errors[]. Sections that succeed still populate their fields normally — a bad
  events query does not suppress good eval state. The last_review section
  queries for the most recent codex_stop_review event that postdates the last
  evaluation_state update, so the review indicator resets automatically when a
  new eval cycle starts. Detail format from stop-review-gate-hook.mjs:
  "VERDICT: <ALLOW|BLOCK> — workflow=<id> | <reason>".
"""

from __future__ import annotations

import sqlite3
import time

from runtime.core.completions import determine_next_role
from runtime.core.completions import latest as comp_latest
from runtime.core.markers import get_active_with_age


def snapshot(conn: sqlite3.Connection) -> dict:
    """Return a read-only projection of runtime state for status display.

    Fields returned:
      eval_status         — evaluation_state status (TKT-024 sole readiness)
                            ('idle'/'pending'/'needs_changes'/'ready_for_guardian'/
                            'blocked_by_plan'), or 'idle' when none
      eval_workflow       — workflow_id of the active evaluation row, or None
      eval_head_sha       — head_sha from evaluation_state, or None
      active_agent        — role of the most recently started active marker,
                            or None
      active_agent_id     — agent_id of that marker, or None
      marker_age_seconds  — age in seconds of the active marker, or None
      worktree_count      — number of active (non-removed) worktrees
      worktrees           — list of {path, branch, ticket} for each active wt
      dispatch_status     — next role derived from the latest completion record
                            via determine_next_role(role, verdict), or None
                            when no valid completion exists or cycle is done
                            (DEC-WS6-001: no longer reads dispatch_queue)
      dispatch_workflow   — workflow_id of the completion record that produced
                            dispatch_status, or None
      dispatch_from_role  — role of the agent that produced the completion
                            record, or None
      dispatch_from_verdict — verdict from that completion record, or None
      dispatch_initiative — initiative name of the current active cycle,
                            or None
      dispatch_cycle_id   — id of the current active cycle, or None
      recent_event_count  — count of the most recent events returned (up to 5)
      recent_events       — list of up to 5 events, newest first, each with
                            {type, detail, created_at}
      last_review         — review status scoped to the current eval cycle
                            (DEC-SL-160): {reviewed: bool, reviewer: str|None,
                             verdict: str|None, reviewed_at: int|None}.
                            reviewed=False when no codex_stop_review event
                            postdates the most recent evaluation_state update.
      snapshot_at         — Unix epoch when this snapshot was taken
      status              — 'ok' when all sections succeeded, 'partial_failure'
                            when one or more sections raised an exception
      errors              — list of {section: str, error: str} for each failed
                            section; empty list when status is 'ok'

    Never raises. On partial failure, successfully-loaded sections still
    populate their fields (DEC-SL-160: per-section isolation).
    """
    now = int(time.time())
    result: dict = {
        "eval_status": "idle",
        "eval_workflow": None,
        "eval_head_sha": None,
        # proof_status / proof_workflow removed (W-CONV-4 / DEC-EVAL-006):
        # operators were seeing two contradictory readiness signals. The
        # proof_state table is retained for storage; only the display is
        # removed. evaluation_state is the sole readiness surface.
        "active_agent": None,
        "active_agent_id": None,
        "marker_age_seconds": None,
        "worktree_count": 0,
        "worktrees": [],
        "dispatch_status": None,
        "dispatch_workflow": None,
        "dispatch_from_role": None,
        "dispatch_from_verdict": None,
        "dispatch_initiative": None,
        "dispatch_cycle_id": None,
        "recent_event_count": 0,
        "recent_events": [],
        "last_review": {
            "reviewed": False,
            "reviewer": None,
            "verdict": None,
            "reviewed_at": None,
        },
        "snapshot_at": now,
        "status": "ok",
        "errors": [],
    }

    # Tracks the updated_at of the most recent non-idle evaluation_state row.
    # Used by the last_review section to scope review events to the current
    # eval cycle — a review event before the last eval reset does not count.
    _eval_updated_at: int | None = None

    # ------------------------------------------------------------------
    # Section: Evaluation state (TKT-024 / W-CONV-4) — sole readiness
    # authority. proof_state is no longer queried here (DEC-EVAL-006).
    # Prefer any non-idle row; most recently updated wins.
    # We also read updated_at here to scope last_review correctly.
    # ------------------------------------------------------------------
    try:
        row = conn.execute(
            """
            SELECT workflow_id, status, head_sha, updated_at
            FROM   evaluation_state
            WHERE  status != 'idle'
            ORDER  BY updated_at DESC
            LIMIT  1
            """
        ).fetchone()
        if row:
            result["eval_status"] = row["status"]
            result["eval_workflow"] = row["workflow_id"]
            result["eval_head_sha"] = row["head_sha"]
            _eval_updated_at = row["updated_at"]
    except Exception as exc:
        result["status"] = "partial_failure"
        result["errors"].append({"section": "eval", "error": str(exc)})

    # ------------------------------------------------------------------
    # Section: Active agent — most recently started active marker with age.
    #
    # @decision DEC-RT-023: Use get_active_with_age() so the snapshot
    # carries marker_age_seconds without a second query. The age is
    # computed once at snapshot time and is consistent across all
    # consumers of this dict.
    # ------------------------------------------------------------------
    try:
        marker = get_active_with_age(conn)
        if marker:
            result["active_agent"] = marker["role"]
            result["active_agent_id"] = marker["agent_id"]
            result["marker_age_seconds"] = marker["age_seconds"]
    except Exception as exc:
        result["status"] = "partial_failure"
        result["errors"].append({"section": "markers", "error": str(exc)})

    # ------------------------------------------------------------------
    # Section: Worktrees — all active (removed_at IS NULL), full detail rows
    # ------------------------------------------------------------------
    try:
        rows = conn.execute(
            """
            SELECT path, branch, ticket
            FROM   worktrees
            WHERE  removed_at IS NULL
            ORDER  BY created_at DESC
            """
        ).fetchall()
        wt_list = [{"path": r["path"], "branch": r["branch"], "ticket": r["ticket"]} for r in rows]
        result["worktree_count"] = len(wt_list)
        result["worktrees"] = wt_list
    except Exception as exc:
        result["status"] = "partial_failure"
        result["errors"].append({"section": "worktrees", "error": str(exc)})

    # ------------------------------------------------------------------
    # Section: Dispatch — derive next_role from latest completion record.
    #
    # @decision DEC-WS6-001: dispatch_queue is no longer the routing
    # authority. post-task.sh stopped enqueuing into dispatch_queue —
    # the queue was a write-only sink with no live readers in the
    # enforcement path. Routing is now determined by
    # determine_next_role(role, verdict) applied to the most recent
    # completion record. dispatch_initiative and dispatch_cycle_id are
    # retained from dispatch_cycles — that is initiative-level tracking,
    # not routing state.
    # ------------------------------------------------------------------
    try:
        comp = comp_latest(conn)
        if comp and comp.get("valid"):
            _next = determine_next_role(comp["role"], comp.get("verdict", ""))
            result["dispatch_status"] = _next  # None means cycle complete
            result["dispatch_workflow"] = comp.get("workflow_id")
            result["dispatch_from_role"] = comp["role"]
            result["dispatch_from_verdict"] = comp.get("verdict", "")

        row = conn.execute(
            """
            SELECT id, initiative
            FROM   dispatch_cycles
            WHERE  status = 'active'
            ORDER  BY created_at DESC
            LIMIT  1
            """
        ).fetchone()
        if row:
            result["dispatch_initiative"] = row["initiative"]
            result["dispatch_cycle_id"] = row["id"]
    except Exception as exc:
        result["status"] = "partial_failure"
        result["errors"].append({"section": "dispatch", "error": str(exc)})

    # ------------------------------------------------------------------
    # Section: Recent events — up to 5 most recent, newest first
    # ------------------------------------------------------------------
    try:
        rows = conn.execute(
            """
            SELECT type, detail, created_at
            FROM   events
            ORDER  BY id DESC
            LIMIT  5
            """
        ).fetchall()
        evt_list = [
            {"type": r["type"], "detail": r["detail"], "created_at": r["created_at"]} for r in rows
        ]
        result["recent_event_count"] = len(evt_list)
        result["recent_events"] = evt_list
    except Exception as exc:
        result["status"] = "partial_failure"
        result["errors"].append({"section": "events", "error": str(exc)})

    # ------------------------------------------------------------------
    # Section: Last review — most recent codex_stop_review event scoped
    # to the current eval cycle (DEC-SL-160).
    #
    # Scope rule: the review event must strictly postdate the most recent
    # evaluation_state.updated_at so that a review from a previous step
    # does not carry forward to the new step. Strict greater-than
    # (created_at > updated_at) prevents same-second eval resets from
    # retaining a stale review (Bug #2 fix).
    #
    # Workflow scoping (Bug #1 fix): when eval_workflow is known and
    # non-idle, we additionally require the event detail to contain
    # "workflow=<eval_workflow>". This prevents a review for wf-b from
    # appearing when the active eval is wf-a. When eval is idle or no
    # workflow is set, last_review stays at the default (reviewed=False).
    #
    # Detail format written by stop-review-gate-hook.mjs:
    #   "VERDICT: <ALLOW|BLOCK> — workflow=<id> | <reason>"
    # source field carries the provider when present (future use); for
    # now we default to "codex" since that is the sole writer (DEC-AD-002).
    # ------------------------------------------------------------------
    try:
        _eval_wf = result.get("eval_workflow")
        _eval_st = result.get("eval_status")

        # Only look for reviews when there is an active (non-idle) workflow.
        # An idle eval or missing workflow means no review should surface.
        if _eval_wf and _eval_st != "idle" and _eval_updated_at is not None:
            _since = _eval_updated_at
            _wf_pattern = f"workflow={_eval_wf}"

            row = conn.execute(
                """
                SELECT source, detail, created_at
                FROM   events
                WHERE  type = 'codex_stop_review'
                  AND  created_at > ?
                  AND  detail LIKE '%' || ? || '%'
                ORDER  BY id DESC
                LIMIT  1
                """,
                (_since, _wf_pattern),
            ).fetchone()
        else:
            row = None

        if row:
            detail = row["detail"] or ""
            # source field is not currently populated by the hook; fall back
            # to "codex" — the only provider that emits codex_stop_review.
            reviewer: str = row["source"] or "codex"

            # Parse verdict from detail string.
            verdict: str | None = None
            if "VERDICT: ALLOW" in detail:
                verdict = "ALLOW"
            elif "VERDICT: BLOCK" in detail:
                verdict = "BLOCK"
            elif "VERDICT: PASS" in detail:
                verdict = "PASS"
            elif "VERDICT: CONTINUE" in detail:
                verdict = "CONTINUE"

            result["last_review"] = {
                "reviewed": True,
                "reviewer": reviewer,
                "verdict": verdict,
                "reviewed_at": row["created_at"],
            }
    except Exception as exc:
        result["status"] = "partial_failure"
        result["errors"].append({"section": "last_review", "error": str(exc)})

    return result
