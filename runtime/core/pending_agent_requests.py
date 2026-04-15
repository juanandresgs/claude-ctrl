"""
Carrier table helpers for SubagentStart contract delivery.

@decision DEC-CLAUDEX-SA-CARRIER-001
@title pending_agent_requests: SQLite carrier for SubagentStart contract fields
@status accepted
@rationale Real SubagentStart harness payloads carry only harness-injected
  fields (session_id, transcript_path, cwd, agent_id, agent_type,
  hook_event_name). The six request-contract fields (workflow_id, stage_id,
  goal_id, work_item_id, decision_scope, generated_at) are absent from all
  observed production events (pinned by DEC-CLAUDEX-SA-PAYLOAD-SHAPE-001).
  The orchestrator embeds those fields in tool_input.prompt as a
  CLAUDEX_CONTRACT_BLOCK JSON marker at Agent-dispatch time.
  pre-agent.sh (PreToolUse:Agent) extracts the block and writes a row to
  pending_agent_requests, keyed by (session_id, agent_type).
  subagent-start.sh atomically reads and deletes the row at SubagentStart
  time, merging the six contract fields into the hook payload so that the
  runtime-first path (cc-policy prompt-pack subagent-start) fires in
  production — not just in synthetic tests.
  File sidecars are explicitly rejected: a tmp file is a second non-runtime
  authority for a control-plane fact (DEC-CLAUDEX-SA-PAYLOAD-SHAPE-001).
"""
from __future__ import annotations

import json
import sqlite3
import sys
import time
from typing import Optional

__all__ = [
    "write_pending_request",
    "consume_pending_request",
]

_CONTRACT_FIELDS = (
    "workflow_id",
    "stage_id",
    "goal_id",
    "work_item_id",
    "decision_scope",
    "generated_at",
)


def write_pending_request(
    conn: sqlite3.Connection,
    *,
    session_id: str,
    agent_type: str,
    workflow_id: str,
    stage_id: str,
    goal_id: str,
    work_item_id: str,
    decision_scope: str,
    generated_at: int,
    written_at: Optional[int] = None,
) -> None:
    """Insert or replace a pending request row keyed by (session_id, agent_type).

    Uses INSERT OR REPLACE so a repeat orchestrator dispatch for the same
    (session_id, agent_type) pair silently overwrites the stale row rather
    than accumulating orphan rows.
    """
    if written_at is None:
        written_at = int(time.time())
    conn.execute(
        """
        INSERT OR REPLACE INTO pending_agent_requests (
            session_id, agent_type,
            workflow_id, stage_id, goal_id, work_item_id,
            decision_scope, generated_at, written_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            session_id,
            agent_type,
            workflow_id,
            stage_id,
            goal_id,
            work_item_id,
            decision_scope,
            generated_at,
            written_at,
        ),
    )
    conn.commit()


def consume_pending_request(
    conn: sqlite3.Connection,
    *,
    session_id: str,
    agent_type: str,
) -> Optional[dict]:
    """Atomically read and delete the row for (session_id, agent_type).

    Returns a dict of the six contract fields if the row exists, or None if
    no row was found.  The SELECT + DELETE is wrapped in a BEGIN EXCLUSIVE
    transaction to prevent double-consume when concurrent hook invocations
    race on the same (session_id, agent_type) pair.
    """
    conn.execute("BEGIN EXCLUSIVE")
    try:
        row = conn.execute(
            """
            SELECT workflow_id, stage_id, goal_id, work_item_id,
                   decision_scope, generated_at
            FROM pending_agent_requests
            WHERE session_id = ? AND agent_type = ?
            """,
            (session_id, agent_type),
        ).fetchone()
        if row is None:
            conn.execute("ROLLBACK")
            return None
        conn.execute(
            "DELETE FROM pending_agent_requests WHERE session_id = ? AND agent_type = ?",
            (session_id, agent_type),
        )
        conn.execute("COMMIT")
    except Exception:
        try:
            conn.execute("ROLLBACK")
        except Exception:
            pass
        raise

    # sqlite3.Row supports both index and key access; normalise to plain dict.
    if hasattr(row, "keys"):
        return dict(row)
    return {
        "workflow_id": row[0],
        "stage_id": row[1],
        "goal_id": row[2],
        "work_item_id": row[3],
        "decision_scope": row[4],
        "generated_at": row[5],
    }


# ---------------------------------------------------------------------------
# CLI — called by hooks/pre-agent.sh (write) and hooks/subagent-start.sh
# (consume) via `python3 pending_agent_requests.py <cmd> <args...>`.
# Kept minimal: only the two commands the hooks need.
# ---------------------------------------------------------------------------


def _cli_write(db_path: str, session_id: str, agent_type: str, contract_json: str) -> None:
    """Parse contract_json and write a carrier row.  Exits non-zero on error."""
    try:
        data = json.loads(contract_json)
    except json.JSONDecodeError as exc:
        print(f"error: invalid contract JSON: {exc}", file=sys.stderr)
        sys.exit(1)
    missing = [f for f in _CONTRACT_FIELDS if f not in data]
    if missing:
        print(f"error: contract missing fields: {missing}", file=sys.stderr)
        sys.exit(1)
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        write_pending_request(
            conn,
            session_id=session_id,
            agent_type=agent_type,
            workflow_id=str(data["workflow_id"]),
            stage_id=str(data["stage_id"]),
            goal_id=str(data["goal_id"]),
            work_item_id=str(data["work_item_id"]),
            decision_scope=str(data["decision_scope"]),
            generated_at=int(data["generated_at"]),
        )
    finally:
        conn.close()


def _cli_consume(db_path: str, session_id: str, agent_type: str) -> None:
    """Consume a carrier row and print the six-field JSON to stdout.

    Prints nothing (no output) if the row does not exist — the calling shell
    script tests for empty stdout to detect a cache miss.
    """
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        result = consume_pending_request(conn, session_id=session_id, agent_type=agent_type)
    finally:
        conn.close()
    if result is not None:
        print(json.dumps(result))


if __name__ == "__main__":
    _USAGE = (
        "usage: pending_agent_requests.py write <db> <session_id> <agent_type> <contract_json>\n"
        "       pending_agent_requests.py consume <db> <session_id> <agent_type>"
    )
    if len(sys.argv) < 2:
        print(_USAGE, file=sys.stderr)
        sys.exit(1)
    _cmd = sys.argv[1]
    if _cmd == "write":
        if len(sys.argv) != 6:
            print(_USAGE, file=sys.stderr)
            sys.exit(1)
        _cli_write(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    elif _cmd == "consume":
        if len(sys.argv) != 5:
            print(_USAGE, file=sys.stderr)
            sys.exit(1)
        _cli_consume(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        print(f"error: unknown command {sys.argv[1]!r}\n{_USAGE}", file=sys.stderr)
        sys.exit(1)
