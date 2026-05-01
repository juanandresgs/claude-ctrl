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
  pre-agent.sh (PreToolUse:Agent) forwards the payload to cc-policy evaluate;
  after agent_contract_required allows the launch, the runtime writes a row to
  pending_agent_requests, keyed by the runtime dispatch attempt id.
  subagent-start.sh atomically reads and consumes the next pending row at SubagentStart
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
import uuid
from pathlib import Path
from typing import Optional

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from runtime.schemas import ensure_schema

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


def _connect_cli_db(db_path: str) -> sqlite3.Connection:
    """Open a carrier DB for CLI use, creating parent dirs/schema as needed."""
    path = Path(db_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path))
    conn.row_factory = sqlite3.Row
    ensure_schema(conn)
    return conn


def write_pending_request(
    conn: sqlite3.Connection,
    *,
    attempt_id: str | None = None,
    session_id: str,
    agent_type: str,
    workflow_id: str,
    stage_id: str,
    goal_id: str,
    work_item_id: str,
    decision_scope: str,
    generated_at: int,
    parent_agent_id: str = "",
    tool_use_id: str = "",
    target_project_root: str = "",
    worktree_path: str = "",
    contract_json: str | dict | None = None,
    written_at: Optional[int] = None,
) -> dict:
    """Insert a pending request row keyed by dispatch ``attempt_id``.

    Multiple same-role dispatches in one parent session are preserved as
    independent rows. SubagentStart consumes the oldest pending row for the
    ``(session_id, agent_type)`` pair, carrying its attempt id forward to the
    delivery claim.
    """
    if written_at is None:
        written_at = int(time.time())
    if not attempt_id:
        attempt_id = uuid.uuid4().hex
    if isinstance(contract_json, dict):
        contract_json = json.dumps(contract_json, sort_keys=True)
    elif contract_json is None:
        contract_json = json.dumps(
            {
                "workflow_id": workflow_id,
                "stage_id": stage_id,
                "goal_id": goal_id,
                "work_item_id": work_item_id,
                "decision_scope": decision_scope,
                "generated_at": generated_at,
            },
            sort_keys=True,
        )
    conn.execute(
        """
        INSERT INTO pending_agent_requests (
            attempt_id, session_id, agent_type,
            workflow_id, stage_id, goal_id, work_item_id,
            decision_scope, generated_at, written_at, status,
            consumed_at, parent_agent_id, tool_use_id, target_project_root,
            worktree_path, contract_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', NULL, ?, ?, ?, ?, ?)
        """,
        (
            attempt_id,
            session_id,
            agent_type,
            workflow_id,
            stage_id,
            goal_id,
            work_item_id,
            decision_scope,
            generated_at,
            written_at,
            parent_agent_id,
            tool_use_id,
            target_project_root,
            worktree_path,
            contract_json,
        ),
    )
    conn.commit()
    row = conn.execute(
        "SELECT * FROM pending_agent_requests WHERE attempt_id = ?",
        (attempt_id,),
    ).fetchone()
    return dict(row) if row is not None else {"attempt_id": attempt_id}


def consume_pending_request(
    conn: sqlite3.Connection,
    *,
    session_id: str,
    agent_type: str,
) -> Optional[dict]:
    """Atomically read and delete the oldest pending row for a seat.

    Returns a dict of the contract fields plus attempt identity if a pending
    row exists, or None if no row was found. The SELECT + DELETE is wrapped in
    a BEGIN EXCLUSIVE transaction to prevent double-consume when concurrent
    hook invocations race on the same ``(session_id, agent_type)`` pair.
    """
    conn.execute("BEGIN EXCLUSIVE")
    try:
        row = conn.execute(
            """
            SELECT attempt_id, workflow_id, stage_id, goal_id, work_item_id,
                   decision_scope, generated_at, parent_agent_id, tool_use_id,
                   target_project_root, worktree_path, contract_json
            FROM pending_agent_requests
            WHERE session_id = ? AND agent_type = ?
              AND status = 'pending'
            ORDER BY written_at ASC, rowid ASC
            LIMIT 1
            """,
            (session_id, agent_type),
        ).fetchone()
        if row is None:
            conn.execute("ROLLBACK")
            return None
        conn.execute(
            """
            DELETE FROM pending_agent_requests
            WHERE attempt_id = ?
            """,
            (row["attempt_id"] if hasattr(row, "keys") else row[0],),
        )
        conn.execute("COMMIT")
    except Exception:
        try:
            conn.execute("ROLLBACK")
        except Exception:
            pass
        raise

    if hasattr(row, "keys"):
        return dict(row)
    return {
        "attempt_id": row[0],
        "workflow_id": row[1],
        "stage_id": row[2],
        "goal_id": row[3],
        "work_item_id": row[4],
        "decision_scope": row[5],
        "generated_at": row[6],
        "parent_agent_id": row[7],
        "tool_use_id": row[8],
        "target_project_root": row[9],
        "worktree_path": row[10],
        "contract_json": row[11],
    }


# ---------------------------------------------------------------------------
# CLI — retained for compatibility with older hook tests/manual debugging.
# The live PreToolUse write path now runs through `cc-policy evaluate`; the
# consume path is still called by hooks/subagent-start.sh.
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
    conn = _connect_cli_db(db_path)
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
    conn = _connect_cli_db(db_path)
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
