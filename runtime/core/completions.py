"""Completion record authority for agent task endings.

@decision DEC-COMPLETION-001
Title: Structured completion records gate role-transition routing (planner + guardian + implementer + reviewer)
Status: accepted
Rationale: Subagents currently signal completion via freeform prose trailers
  (REVIEW_VERDICT, IMPL_STATUS, etc.). These are parsed by grep in shell hooks,
  making them fragile and unverifiable. Completion records replace the grep
  path with a structured SQLite insert at task end. The planner, guardian,
  implementer, and reviewer produce validated records; the routing layer reads
  verdict + valid to determine the next role.

  v2 scope (historical): tester, guardian, and implementer. The implementer
  schema activates the IMPL_STATUS/IMPL_HEAD_SHA contract so dispatch_engine
  can prefer a structured completion record over the heuristic stop-assessment
  signal. The legacy tester schema and its routing were retired in Phase 8
  Slice 11 (Tester Bundle 2); ``tester`` is no longer a known runtime role.

  v4 scope (Phase 6): planner. The planner schema uses explicit PLAN_* field
  names with verdict vocabulary sourced from stage_registry.PLANNER_VERDICTS.
  Planner routing in determine_next_role delegates to stage_registry (Slice 2).
  check-planner.sh submits structured completion records (Slice 3). Live
  dispatch_engine.process_agent_stop() planner-stop consumption is Slice 4.

  v3 scope (Phase 4): reviewer. The reviewer schema uses explicit REVIEW_*
  field names and sources its verdict vocabulary from
  stage_registry.REVIEWER_VERDICTS — the single authority for reviewer
  verdicts. Reviewer replaced the legacy tester evaluator role; after Phase 8
  Slice 11 the reviewer schema is the only evaluator-side schema in ROLE_SCHEMAS.

  The ROLE_SCHEMAS constant is the single source of truth for which roles have
  active validation. Callers must not hard-code role lists — import from here.

  validate_payload() is pure (no DB I/O). submit() calls validate then inserts.
  latest() and list_completions() are read-only diagnostics.

  determine_next_role() encodes the routing table so orchestrators and hooks
  share a single authoritative mapping instead of duplicating role-transition
  logic in bash and Python separately. Planner, implementer, and reviewer
  routing are all derived from stage_registry.next_stage() via _STAGE_TO_ROLE
  so the transition table is not duplicated. Unknown roles (including the
  retired ``tester``) return None.
"""

from __future__ import annotations

import json
import sqlite3
import time
from typing import Optional

from runtime.core.stage_registry import (
    GUARDIAN_LAND_VERDICTS,
    GUARDIAN_PROVISION_VERDICTS,
    PLANNER_VERDICTS,
    REVIEWER_VERDICTS,
)
from runtime.schemas import FINDING_SEVERITIES

# ---------------------------------------------------------------------------
# Role schemas
# ---------------------------------------------------------------------------

# v4 enforced roles — these schemas are active validation targets.
# Planner added in Phase 6 slice 1. Verdict vocabulary sourced from
# stage_registry.PLANNER_VERDICTS. determine_next_role delegates planner
# routing to stage_registry (Slice 2). check-planner.sh submits structured
# completion records (Slice 3). Live dispatch_engine planner-stop
# consumption is Slice 4 scope.
ROLE_SCHEMAS: dict = {
    "planner": {
        "required": ["PLAN_VERDICT", "PLAN_SUMMARY"],
        "valid_verdicts": PLANNER_VERDICTS,
        "verdict_field": "PLAN_VERDICT",
    },
    # Note: the legacy "tester" schema was retired in Phase 8 Slice 11
    # (Tester Bundle 2). ``tester`` is not a known runtime role; passing it
    # to validate_payload returns valid=False with
    # missing_fields=["role_not_enforced"]. The reviewer schema below is the
    # sole evaluator-side schema.
    "guardian": {
        "required": ["LANDING_RESULT", "OPERATION_CLASS"],
        # Guardian is one live role backed by two compound stages. The schema
        # accepts the union; routing still delegates to stage_registry.
        "valid_verdicts": GUARDIAN_PROVISION_VERDICTS | GUARDIAN_LAND_VERDICTS,
        "verdict_field": "LANDING_RESULT",
    },
    "implementer": {
        "required": ["IMPL_STATUS", "IMPL_HEAD_SHA"],
        "valid_verdicts": frozenset({"complete", "partial", "blocked"}),
        "verdict_field": "IMPL_STATUS",
    },
    # Phase 4 (DEC-COMPLETION-REVIEWER-001): reviewer uses explicit REVIEW_*
    # field names. Verdict vocabulary sourced from stage_registry.REVIEWER_VERDICTS
    # — the single authority. REVIEW_FINDINGS_JSON carries structured findings
    # validated against the reviewer findings ledger shape (severity vocabulary
    # from FINDING_SEVERITIES, per-finding required fields: severity/title/detail,
    # optional fields type-checked where the ledger would reject them).
    # Findings persistence from completions is a later Phase 4 slice.
    "reviewer": {
        "required": ["REVIEW_VERDICT", "REVIEW_HEAD_SHA", "REVIEW_FINDINGS_JSON"],
        "valid_verdicts": REVIEWER_VERDICTS,
        "verdict_field": "REVIEW_VERDICT",
    },
}

# Future schemas — NOT active yet. Defined here for documentation only.
# (Planner was moved into ROLE_SCHEMAS in Phase 6 slice 1. No remaining
# deferred schemas at this time.)


# ---------------------------------------------------------------------------
# Pure validation
# ---------------------------------------------------------------------------

# Per-finding required fields — these are the minimum fields the reviewer
# findings ledger (ReviewerFinding dataclass) requires for a structurally
# valid finding.
_FINDING_REQUIRED_FIELDS: tuple[str, ...] = ("severity", "title", "detail")

# Per-finding optional fields accepted by the ledger. Values that would be
# rejected by the ReviewerFinding dataclass are caught here so malformed
# payloads surface at completion time, not at persistence time.
_FINDING_OPTIONAL_FIELDS: frozenset[str] = frozenset({
    "work_item_id", "file_path", "line", "reviewer_round",
    "head_sha", "finding_id",
})

_FINDING_ALL_FIELDS: frozenset[str] = (
    frozenset(_FINDING_REQUIRED_FIELDS) | _FINDING_OPTIONAL_FIELDS
)


def _validate_findings_json(raw: str) -> list[str]:
    """Validate the REVIEW_FINDINGS_JSON string structurally.

    Returns a list of violation markers (empty list = valid). Each marker
    is a human-readable string prefixed with ``REVIEW_FINDINGS_JSON_``
    following the repo's existing missing/violation marker style.
    """
    violations: list[str] = []

    try:
        parsed = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return ["REVIEW_FINDINGS_JSON_INVALID_JSON"]

    if not isinstance(parsed, dict):
        return ["REVIEW_FINDINGS_JSON_NOT_OBJECT"]

    if "findings" not in parsed:
        return ["REVIEW_FINDINGS_JSON_MISSING_FINDINGS_KEY"]

    findings = parsed["findings"]
    if not isinstance(findings, list):
        return ["REVIEW_FINDINGS_JSON_FINDINGS_NOT_LIST"]

    for i, item in enumerate(findings):
        if not isinstance(item, dict):
            violations.append(f"REVIEW_FINDINGS_JSON_ITEM_{i}_NOT_OBJECT")
            continue

        # Required fields
        for field in _FINDING_REQUIRED_FIELDS:
            val = item.get(field)
            if not isinstance(val, str) or not val.strip():
                violations.append(
                    f"REVIEW_FINDINGS_JSON_ITEM_{i}_MISSING_{field.upper()}"
                )

        # Severity vocabulary
        sev = item.get("severity")
        if isinstance(sev, str) and sev.strip() and sev not in FINDING_SEVERITIES:
            violations.append(
                f"REVIEW_FINDINGS_JSON_ITEM_{i}_INVALID_SEVERITY"
            )

        # Optional field type guards — match the ReviewerFinding dataclass
        # constraints exactly so malformed payloads surface at completion
        # time, not at persistence time.
        #   line: _require_positive_int → int, not bool, >= 1
        #   reviewer_round: _require_non_negative_int → int, not bool, >= 0
        if "line" in item and item["line"] is not None:
            v = item["line"]
            if isinstance(v, bool) or not isinstance(v, int) or v < 1:
                violations.append(
                    f"REVIEW_FINDINGS_JSON_ITEM_{i}_LINE_NOT_INT"
                )
        if "reviewer_round" in item and item["reviewer_round"] is not None:
            v = item["reviewer_round"]
            if isinstance(v, bool) or not isinstance(v, int) or v < 0:
                violations.append(
                    f"REVIEW_FINDINGS_JSON_ITEM_{i}_REVIEWER_ROUND_NOT_INT"
                )

    return violations


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
    validation; reviewer and guardian are always enforced. The retired
    ``tester`` role falls into the "unknown" bucket after Phase 8 Slice 11.

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

    # Reviewer structural findings validation — only when the field is
    # present and non-empty (missing/empty is already caught above).
    findings_violations: list[str] = []
    if role == "reviewer":
        raw_findings = payload.get("REVIEW_FINDINGS_JSON", "")
        if raw_findings:
            findings_violations = _validate_findings_json(raw_findings)

    valid = (
        len(missing_fields) == 0
        and verdict_valid
        and len(findings_violations) == 0
    )

    return {
        "valid": valid,
        "verdict": verdict,
        "missing_fields": missing_fields + findings_violations,
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

    For valid reviewer completions, also persists findings from
    ``REVIEW_FINDINGS_JSON`` into the reviewer findings ledger via
    :func:`runtime.core.reviewer_findings.ingest_completion_findings`.
    The completion insert and findings persist are wrapped in a single
    transaction — if findings persistence fails, the completion record
    is rolled back so the system never records a valid reviewer
    completion with missing ledger findings.

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

        # Persist findings for valid reviewer completions inside the
        # same transaction. Invalid completions do not persist findings.
        if role == "reviewer" and validation["valid"]:
            from runtime.core import reviewer_findings as _rf

            parsed = json.loads(payload["REVIEW_FINDINGS_JSON"])
            _rf.ingest_completion_findings(
                conn,
                workflow_id=workflow_id,
                findings=parsed["findings"],
                default_head_sha=payload.get("REVIEW_HEAD_SHA"),
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
    """List completion records with optional filters, ordered by created_at DESC, id DESC."""
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
        f"SELECT * FROM completion_records {where} ORDER BY created_at DESC, id DESC",
        params,
    ).fetchall()
    return [_row_to_dict(r) for r in rows]


# ---------------------------------------------------------------------------
# Routing
# ---------------------------------------------------------------------------


# Stage-to-live-role mapping. Compound stage names (e.g. "guardian:land")
# map to the live role name used by dispatch. Terminal/user sinks map to
# None. This is the single boundary between stage_registry's compound
# stage namespace and the live role namespace used by determine_next_role.
_STAGE_TO_ROLE: dict[str, Optional[str]] = {
    "planner": "planner",
    "implementer": "implementer",
    "reviewer": "reviewer",
    "guardian:provision": "guardian",
    "guardian:land": "guardian",
    "terminal": None,
    "user": None,
}


def determine_next_role(role: str, verdict: str) -> Optional[str]:
    """Deterministic routing from (role, verdict) to the next role.

    Returns None for cycle-complete terminal states or unknown combinations.
    This is the single authoritative routing table — orchestrators and hooks
    must import from here rather than duplicating transition logic.

    All active routing roles (planner, implementer, reviewer, guardian) are
    derived from ``stage_registry.next_stage()`` via ``_STAGE_TO_ROLE`` so the
    transition table is not duplicated. Guardian has two compound stages
    (``guardian:provision`` / ``guardian:land``) whose verdict sets partially
    overlap (``denied`` and ``skipped`` appear in both). The resolver tries
    both stages, collects matches, and accepts the result only when all
    matches translate to the same live role — failing closed (``None``) if
    future overlapping verdicts would map to conflicting roles.
    Unknown roles (including the retired ``tester``, removed in Phase 8
    Slice 11) return None by absence from the active-routing map.

    """
    # All active routing — derived from stage_registry.next_stage().
    # stage_registry is the single routing authority; _STAGE_TO_ROLE maps
    # compound stage names to live role names. Unknown roles return None.
    from runtime.core import stage_registry as _sr

    _ROLE_TO_STAGES: dict[str, tuple[str, ...]] = {
        "planner": (_sr.PLANNER,),
        "implementer": (_sr.IMPLEMENTER,),
        "reviewer": (_sr.REVIEWER,),
        # Guardian has two compound stages whose verdict sets partially
        # overlap (denied/skipped appear in both). Current overlaps are
        # outcome-equivalent (same target role), but the resolver collects
        # all matches and fails closed if they ever diverge.
        "guardian": (_sr.GUARDIAN_PROVISION, _sr.GUARDIAN_LAND),
    }

    _NO_MATCH = object()  # Sentinel: distinct from None (a valid sink role).

    stages = _ROLE_TO_STAGES.get(role)
    if stages is not None:
        resolved_role: object = _NO_MATCH
        for stage_id in stages:
            target_stage = _sr.next_stage(stage_id, verdict)
            if target_stage is not None:
                candidate = _STAGE_TO_ROLE.get(target_stage)
                if resolved_role is _NO_MATCH:
                    resolved_role = candidate
                elif resolved_role != candidate:
                    # Overlapping verdict maps to conflicting live roles —
                    # fail closed rather than silently picking one.
                    return None
        if resolved_role is _NO_MATCH:
            return None
        return resolved_role  # type: ignore[return-value]

    return None
