"""Runtime-backed statusline snapshot projection.

Read-only projection across all runtime tables. Gathers all state in a single
pass and returns a unified dict suitable for ANSI HUD rendering by
scripts/statusline.sh without that script needing to call multiple subcommands.

TKT-011 promotes this from a stub to the canonical implementation.
TKT-024 adds evaluation_state as the primary readiness display. proof_state
is deprioritized — it is no longer the readiness authority but is retained
in the snapshot for backward compatibility.

@decision DEC-RT-011
Title: Statusline snapshot is a read-only projection across all runtime tables
Status: accepted
Rationale: snapshot() is the single read surface for the statusline HUD. It
  reads evaluation_state (TKT-024 primary), proof_state (deprecated),
  agent_markers, worktrees, dispatch_cycles, completion_records, and events in
  one pass and returns a canonical dict. No writes happen here.
  All fields default to None/0/[] so the statusline never crashes on an empty
  or partially-populated DB. The broad exception handler at the bottom guards
  against unexpected schema errors only; all normal empty-result paths are
  handled individually so partial state is still returned on any single
  query failure.

@decision DEC-EVAL-006
Title: statusline.py shows eval_status as the readiness display (TKT-024)
Status: accepted
Rationale: After TKT-024 cutover, evaluation_state is the sole readiness
  authority. The snapshot surfaces eval_status and eval_workflow as the
  primary readiness fields. proof_status is retained as a legacy field
  (proof_status_legacy) so existing consumers that read it do not crash,
  but it carries zero enforcement meaning.

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
      eval_status         — evaluation_state status (TKT-024 primary readiness)
                            ('idle'/'pending'/'needs_changes'/'ready_for_guardian'/
                            'blocked_by_plan'), or 'idle' when none
      eval_workflow       — workflow_id of the active evaluation row, or None
      eval_head_sha       — head_sha from evaluation_state, or None
      proof_status        — DEPRECATED: legacy proof_state status; zero
                            enforcement effect after TKT-024. Retained for
                            backward compatibility only.
      proof_workflow      — DEPRECATED: workflow_id of proof row, or None
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
      snapshot_at         — Unix epoch when this snapshot was taken
      status              — always 'ok'

    Never raises: returns safe defaults for any missing data.
    """
    now = int(time.time())
    result: dict = {
        "eval_status": "idle",
        "eval_workflow": None,
        "eval_head_sha": None,
        "proof_status": "idle",
        "proof_workflow": None,
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
        "snapshot_at": now,
        "status": "ok",
    }

    try:
        # ------------------------------------------------------------------
        # Proof status — prefer any non-idle row (pending/verified) over idle.
        #
        # @decision DEC-RT-011: Non-idle proof takes precedence because the
        # statusline surfaces active workflow activity. When multiple workflows
        # are tracked, the in-flight one (pending/verified) is the actionable
        # signal; idle rows are background noise. ORDER BY updated_at DESC
        # picks the most recently updated non-idle row when several exist.
        # ------------------------------------------------------------------
        row = conn.execute(
            """
            SELECT workflow_id, status
            FROM   proof_state
            WHERE  status != 'idle'
            ORDER  BY updated_at DESC
            LIMIT  1
            """
        ).fetchone()
        if row:
            result["proof_status"] = row["status"]
            result["proof_workflow"] = row["workflow_id"]

        # ------------------------------------------------------------------
        # Evaluation state (TKT-024) — sole readiness authority.
        # Prefer any non-idle row; most recently updated wins.
        # ------------------------------------------------------------------
        row = conn.execute(
            """
            SELECT workflow_id, status, head_sha
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

        # ------------------------------------------------------------------
        # Active agent — most recently started active marker with age.
        #
        # @decision DEC-RT-023: Use get_active_with_age() so the snapshot
        # carries marker_age_seconds without a second query. The age is
        # computed once at snapshot time and is consistent across all
        # consumers of this dict.
        # ------------------------------------------------------------------
        marker = get_active_with_age(conn)
        if marker:
            result["active_agent"] = marker["role"]
            result["active_agent_id"] = marker["agent_id"]
            result["marker_age_seconds"] = marker["age_seconds"]

        # ------------------------------------------------------------------
        # Worktrees — all active (removed_at IS NULL), full detail rows
        # ------------------------------------------------------------------
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

        # ------------------------------------------------------------------
        # Dispatch — derive next_role from latest completion record.
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

        # ------------------------------------------------------------------
        # Recent events — up to 5 most recent, newest first
        # ------------------------------------------------------------------
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

    except Exception:
        # Never crash the statusline — return whatever we have so far.
        # This guard is for unexpected schema errors only; normal empty-result
        # paths are handled individually above and do not raise.
        pass

    return result
