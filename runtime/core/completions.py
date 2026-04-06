"""Completion record authority for agent task endings.

@decision DEC-COMPLETION-001
Title: Structured completion records gate role-transition routing (v2: tester + guardian + implementer)
Status: accepted
Rationale: Subagents currently signal completion via freeform prose trailers
  (EVAL_VERDICT, IMPL_STATUS, etc.). These are parsed by grep in shell hooks,
  making them fragile and unverifiable. Completion records replace the grep path
  with a structured SQLite insert at task end. The evaluator (tester),
  guardian, and implementer produce validated records; the routing layer reads
  verdict + valid to determine the next role.

  v2 scope: tester, guardian, and implementer. The implementer schema activates
  the IMPL_STATUS/IMPL_HEAD_SHA contract so dispatch_engine can prefer a
  structured completion record over the heuristic stop-assessment signal.
  Planner schema is deferred until check-planner.sh hook exists to enforce it.

  The ROLE_SCHEMAS constant is the single source of truth for which roles have
  active validation. Callers must not hard-code role lists — import from here.

  validate_payload() is pure (no DB I/O). submit() calls validate then inserts.
  latest() and list_completions() are read-only diagnostics.

  determine_next_role() encodes the routing table so orchestrators and hooks
  share a single authoritative mapping instead of duplicating role-transition
  logic in bash and Python separately.
"""

from __future__ import annotations

import json
import sqlite3
import time
from typing import Optional

# ---------------------------------------------------------------------------
# Role schemas — v1 enforced roles only
# ---------------------------------------------------------------------------

# v2 enforced roles — these schemas are active validation targets.
ROLE_SCHEMAS: dict = {
    "tester": {
        "required": ["EVAL_VERDICT", "EVAL_TESTS_PASS", "EVAL_NEXT_ROLE", "EVAL_HEAD_SHA"],
        "valid_verdicts": frozenset({"ready_for_guardian", "needs_changes", "blocked_by_plan"}),
        "verdict_field": "EVAL_VERDICT",
    },
    "guardian": {
        "required": ["LANDING_RESULT", "OPERATION_CLASS"],
        # "provisioned" is the W-GWT-1 verdict for worktree provisioning mode.
        # It routes guardian -> implementer so the planner -> guardian ->
        # implementer chain is complete (DEC-GUARD-WT-001).
        "valid_verdicts": frozenset({"committed", "merged", "denied", "skipped", "provisioned"}),
        "verdict_field": "LANDING_RESULT",
    },
    "implementer": {
        "required": ["IMPL_STATUS", "IMPL_HEAD_SHA"],
        "valid_verdicts": frozenset({"complete", "partial", "blocked"}),
        "verdict_field": "IMPL_STATUS",
    },
}

# Future schemas — NOT active yet. Defined here for documentation only.
# When check-planner.sh hook exists, move planner into ROLE_SCHEMAS.
# _FUTURE_SCHEMAS = {
#     "planner": {
#         "required": ["PLAN_STATUS"],
#         "valid_verdicts": frozenset({"complete", "needs_input", "blocked"}),
#         "verdict_field": "PLAN_STATUS",
#     },
# }


# ---------------------------------------------------------------------------
# Pure validation
# ---------------------------------------------------------------------------


def validate_payload(role: str, payload: dict) -> dict:
    """Validate a completion payload against the role's schema.

    Returns:
        {
            "valid": bool,
            "verdict": str,
            "missing_fields": list[str],
            "role": str,
        }

    If role is not in ROLE_SCHEMAS, returns valid=False with
    missing_fields=["role_not_enforced"]. This signals "cannot validate" for
    unknown/unenforced roles — it does NOT mean the role is permitted to skip
    validation; tester and guardian are always enforced.

    Empty string field values are treated as missing.
    """
    if role not in ROLE_SCHEMAS:
        return {
            "valid": False,
            "verdict": "",
            "missing_fields": ["role_not_enforced"],
            "role": role,
        }

    schema = ROLE_SCHEMAS[role]
    required = schema["required"]
    valid_verdicts = schema["valid_verdicts"]
    verdict_field = schema["verdict_field"]

    missing_fields = [f for f in required if not payload.get(f, "")]

    verdict = payload.get(verdict_field, "")
    verdict_valid = verdict in valid_verdicts

    if not verdict_valid and verdict_field not in missing_fields:
        # Verdict field is present but has an invalid value — treat as invalid.
        pass

    valid = len(missing_fields) == 0 and verdict_valid

    return {
        "valid": valid,
        "verdict": verdict,
        "missing_fields": missing_fields,
        "role": role,
    }


# ---------------------------------------------------------------------------
# DB writes
# ---------------------------------------------------------------------------


def submit(
    conn: sqlite3.Connection,
    lease_id: str,
    workflow_id: str,
    role: str,
    payload: dict,
) -> dict:
    """Validate payload and insert a completion record.

    Returns:
        {
            "valid": bool,
            "verdict": str,
            "missing_fields": list,
            "lease_id": str,
            "completion_id": int,
            "role": str,
        }
    """
    validation = validate_payload(role, payload)
    now = int(time.time())

    with conn:
        cursor = conn.execute(
            """INSERT INTO completion_records
               (lease_id, workflow_id, role, verdict, valid, payload_json, missing_fields, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                lease_id,
                workflow_id,
                role,
                validation["verdict"],
                1 if validation["valid"] else 0,
                json.dumps(payload),
                json.dumps(validation["missing_fields"]),
                now,
            ),
        )

    return {
        "valid": validation["valid"],
        "verdict": validation["verdict"],
        "missing_fields": validation["missing_fields"],
        "lease_id": lease_id,
        "completion_id": cursor.lastrowid,
        "role": role,
    }


# ---------------------------------------------------------------------------
# Reads
# ---------------------------------------------------------------------------


def _row_to_dict(row: sqlite3.Row) -> dict:
    d = dict(row)
    # Deserialise JSON columns for convenience.
    for col in ("payload_json", "missing_fields"):
        if col in d and isinstance(d[col], str):
            try:
                d[col] = json.loads(d[col])
            except (json.JSONDecodeError, TypeError):
                pass
    d["found"] = True
    return d


def latest(
    conn: sqlite3.Connection,
    lease_id: Optional[str] = None,
    workflow_id: Optional[str] = None,
) -> Optional[dict]:
    """Return the most recent completion record.

    Priority: filter by lease_id if given, else by workflow_id.
    Returns None if no records exist for the given filter.
    """
    if lease_id:
        row = conn.execute(
            """SELECT * FROM completion_records
               WHERE lease_id = ?
               ORDER BY created_at DESC, id DESC LIMIT 1""",
            (lease_id,),
        ).fetchone()
    elif workflow_id:
        row = conn.execute(
            """SELECT * FROM completion_records
               WHERE workflow_id = ?
               ORDER BY created_at DESC, id DESC LIMIT 1""",
            (workflow_id,),
        ).fetchone()
    else:
        row = conn.execute(
            "SELECT * FROM completion_records ORDER BY created_at DESC, id DESC LIMIT 1"
        ).fetchone()

    return _row_to_dict(row) if row else None


def list_completions(
    conn: sqlite3.Connection,
    lease_id: Optional[str] = None,
    workflow_id: Optional[str] = None,
    role: Optional[str] = None,
    valid_only: bool = False,
) -> list[dict]:
    """List completion records with optional filters, ordered by created_at DESC."""
    clauses = []
    params = []
    if lease_id:
        clauses.append("lease_id = ?")
        params.append(lease_id)
    if workflow_id:
        clauses.append("workflow_id = ?")
        params.append(workflow_id)
    if role:
        clauses.append("role = ?")
        params.append(role)
    if valid_only:
        clauses.append("valid = 1")

    where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
    rows = conn.execute(
        f"SELECT * FROM completion_records {where} ORDER BY created_at DESC",
        params,
    ).fetchall()
    return [_row_to_dict(r) for r in rows]


# ---------------------------------------------------------------------------
# Routing
# ---------------------------------------------------------------------------


def determine_next_role(role: str, verdict: str) -> Optional[str]:
    """Deterministic routing from (role, verdict) to the next role.

    Returns None for cycle-complete terminal states or unknown combinations.
    This is the single authoritative routing table — orchestrators and hooks
    must import from here rather than duplicating transition logic.
    """
    _routing: dict[tuple[str, str], Optional[str]] = {
        ("tester", "ready_for_guardian"): "guardian",
        ("tester", "needs_changes"): "implementer",
        ("tester", "blocked_by_plan"): "planner",
        ("guardian", "committed"): None,
        ("guardian", "merged"): None,
        ("guardian", "denied"): "implementer",
        ("guardian", "skipped"): "implementer",
        # W-GWT-1 (DEC-GUARD-WT-001): Guardian in provision mode routes to
        # implementer after creating the worktree. The planner -> guardian ->
        # implementer chain uses this entry. The "provisioned" verdict is only
        # valid when guardian_mode="provision" (set by dispatch_engine planner
        # block); the merge path uses "committed"/"merged"/"denied"/"skipped".
        ("guardian", "provisioned"): "implementer",
        # Implementer routing is always → tester regardless of verdict.
        # The contract affects stop quality (agent_complete vs agent_stopped),
        # not routing destination (DEC-IMPL-CONTRACT-001).
        ("implementer", "complete"): "tester",
        ("implementer", "partial"): "tester",
        ("implementer", "blocked"): "tester",
    }
    return _routing.get((role, verdict))
