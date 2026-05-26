"""v6 critic worker.

Runs pending critic stage runs outside the SubagentStop hook path.  Hooks enqueue
by creating the critic stage only; this worker executes providers and submits the
critic result when an external provider succeeds.
"""

from __future__ import annotations

import sqlite3

from runtime.core import critic_runner, stage_machine, stage_runs


def pending_critic_runs(conn: sqlite3.Connection, *, workflow_id: str = "", limit: int = 10) -> list[dict]:
    clauses = ["stage_id = ?", "status IN ('pending','launched','blocked')"]
    params: list[object] = [stage_machine.CRITIC]
    if workflow_id:
        clauses.append("workflow_id = ?")
        params.append(workflow_id)
    rows = conn.execute(
        f"""
        SELECT * FROM stage_runs
        WHERE {' AND '.join(clauses)}
        ORDER BY created_at ASC, id ASC
        LIMIT ?
        """,
        (*params, int(limit)),
    ).fetchall()
    out = []
    for row in rows:
        run = stage_runs.get_stage_run(conn, row["id"])
        if run:
            out.append(run)
    return out


def run_once(
    conn: sqlite3.Connection,
    *,
    workflow_id: str = "",
    providers: list[str] | None = None,
    timeout: int = critic_runner.DEFAULT_TIMEOUT,
    limit: int = 10,
    dry_run: bool = False,
    submit: bool = True,
) -> dict:
    processed: list[dict] = []
    for run in pending_critic_runs(conn, workflow_id=workflow_id, limit=limit):
        result = critic_runner.run_critic(
            conn,
            stage_run_id=run["id"],
            providers=providers,
            timeout=timeout,
            dry_run=dry_run,
        )
        if submit and result.get("status") == "completed":
            raw = (result.get("critic_run") or {}).get("raw_output") or ""
            payload = stage_runs.extract_result_block(raw)
            if payload:
                result["submitted_result"] = stage_runs.submit_result(conn, stage_run_id=run["id"], payload=payload)
                _mark_source_actions_completed(conn, run["id"])
            else:
                result["submit_error"] = "critic output did not contain claude_ctrl_result"
        elif result.get("status") == "fallback_required":
            _mark_source_actions_pending(conn, run["id"])
            action = _source_action(conn, run["id"])
            if action:
                result["fallback_launch"] = stage_runs.issue_ticket_for_next_action(conn, int(action["id"]))
        processed.append({"stage_run_id": run["id"], "result": result})
    return {"processed": processed, "count": len(processed)}


def _source_action(conn: sqlite3.Connection, stage_run_id: str) -> dict | None:
    return stage_runs._pending_next_row_to_dict(
        conn.execute(
            "SELECT * FROM dispatch_next_actions_v6 WHERE next_stage_run_id = ? ORDER BY created_at DESC LIMIT 1",
            (stage_run_id,),
        ).fetchone()
    )


def _mark_source_actions_completed(conn: sqlite3.Connection, stage_run_id: str) -> None:
    with conn:
        conn.execute(
            "UPDATE dispatch_next_actions_v6 SET status = 'completed', updated_at = strftime('%s','now') WHERE next_stage_run_id = ?",
            (stage_run_id,),
        )


def _mark_source_actions_pending(conn: sqlite3.Connection, stage_run_id: str) -> None:
    with conn:
        conn.execute(
            "UPDATE dispatch_next_actions_v6 SET status = 'pending', updated_at = strftime('%s','now') WHERE next_stage_run_id = ? AND status = 'worker_pending'",
            (stage_run_id,),
        )
