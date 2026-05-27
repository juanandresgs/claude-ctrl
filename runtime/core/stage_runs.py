"""v6 stage run, launch ledger, and result-contract authority.

@decision DEC-V6-STAGE-RUNS-001
Title: stage_runs + internal launch ledger replace model-facing dispatch ceremony
Status: accepted
Rationale: v5 recorded next actions but still relied on hook text and
  orchestrator compliance for actual dispatch.  v6 persists every stage run;
  canonical Agent launches bind to an internal runtime claim ledger, while
  prompt text is only advisory context.  Suggestion text is now a view; the
  database row is the authority.
"""

from __future__ import annotations

import json
import re
import sqlite3
import subprocess
import time
import uuid
from dataclasses import asdict, dataclass
from typing import Optional

from runtime.core import events, leases, stage_machine, workflows
from runtime.core.policy_utils import normalize_path

TICKET_PREFIX = "CLAUDE_CTRL_TICKET:"
DEFAULT_TICKET_TTL = 900
DEFAULT_STAGE_TTL = 7200
_TICKET_RE = re.compile(r"\bCLAUDE_CTRL_TICKET:([A-Za-z0-9]+)\b")


@dataclass(frozen=True)
class StageResultValidation:
    valid: bool
    missing_fields: list[str]
    verdict: str

    def as_dict(self) -> dict:
        return asdict(self)


def _now() -> int:
    return int(time.time())


def _json_dumps(value: object) -> str:
    return json.dumps(value if value is not None else {}, sort_keys=True)


def _json_loads(raw: str | None, default):
    if not raw:
        return default
    try:
        return json.loads(raw)
    except (TypeError, json.JSONDecodeError):
        return default


def _is_full_sha(value: str) -> bool:
    value = str(value or "")
    return len(value) == 40 and all(c in "0123456789abcdefABCDEF" for c in value)


def _row_to_dict(row: sqlite3.Row | None) -> Optional[dict]:
    if row is None:
        return None
    d = dict(row)
    for key in ("input_json", "result_json", "metadata_json"):
        if key in d:
            d[key[:-5] if key.endswith("_json") else key] = _json_loads(d.get(key), {})
    if "metadata" not in d:
        d["metadata"] = {}
    return d


def _ticket_row_to_dict(row: sqlite3.Row | None) -> Optional[dict]:
    if row is None:
        return None
    d = dict(row)
    d["metadata"] = _json_loads(d.get("metadata_json"), {})
    return d


def _result_row_to_dict(row: sqlite3.Row | None) -> Optional[dict]:
    if row is None:
        return None
    d = dict(row)
    d["payload"] = _json_loads(d.get("payload_json"), {})
    d["missing_fields"] = _json_loads(d.get("missing_fields_json"), [])
    return d


def _pending_next_row_to_dict(row: sqlite3.Row | None) -> Optional[dict]:
    if row is None:
        return None
    d = dict(row)
    d["payload"] = _json_loads(d.get("payload_json"), {})
    return d


def create_stage_run(
    conn: sqlite3.Connection,
    *,
    workflow_id: str,
    stage_id: str,
    goal_id: str = "",
    work_item_id: str = "",
    parent_run_id: str = "",
    worktree_path: str = "",
    input_payload: Optional[dict] = None,
    ttl: int = DEFAULT_STAGE_TTL,
) -> dict:
    """Create a pending stage run.

    ``workflow_id`` and ``stage_id`` are required. Full delivery-path runs
    should pass first-class ``goal_id`` and ``work_item_id`` from
    runtime.core.work_items; direct test/diagnostic calls receive explicit
    diagnostic sentinels.
    """

    workflow_id = str(workflow_id or "").strip()
    stage_id = str(stage_id or "").strip()
    if not workflow_id:
        raise ValueError("stage run workflow_id is required")
    stage_machine.validate_stage(stage_id)
    if not stage_machine.is_active(stage_id):
        raise ValueError(f"cannot create stage run for sink stage {stage_id!r}")

    goal_id = str(goal_id or "diagnostic-goal").strip()
    work_item_id = str(work_item_id or "diagnostic-work-item").strip()
    canonical_worktree = normalize_path(worktree_path) if worktree_path else ""
    now = _now()
    run_id = uuid.uuid4().hex
    payload = input_payload or {}

    with conn:
        conn.execute(
            """
            INSERT INTO stage_runs (
                id, workflow_id, goal_id, work_item_id, stage_id, status,
                parent_run_id, worktree_path, input_json, created_at, updated_at, expires_at
            ) VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?, ?)
            """,
            (
                run_id,
                workflow_id,
                goal_id,
                work_item_id,
                stage_id,
                parent_run_id or None,
                canonical_worktree,
                _json_dumps(payload),
                now,
                now,
                now + ttl,
            ),
        )
    return get_stage_run(conn, run_id) or {"id": run_id}


def get_stage_run(conn: sqlite3.Connection, stage_run_id: str) -> Optional[dict]:
    row = conn.execute("SELECT * FROM stage_runs WHERE id = ?", (stage_run_id,)).fetchone()
    return _row_to_dict(row)


def list_stage_runs(
    conn: sqlite3.Connection,
    *,
    workflow_id: str = "",
    status: str = "",
    limit: int = 50,
) -> list[dict]:
    clauses: list[str] = []
    params: list[object] = []
    if workflow_id:
        clauses.append("workflow_id = ?")
        params.append(workflow_id)
    if status:
        clauses.append("status = ?")
        params.append(status)
    where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
    rows = conn.execute(
        f"SELECT * FROM stage_runs {where} ORDER BY created_at DESC, id DESC LIMIT ?",
        (*params, int(limit)),
    ).fetchall()
    return [_row_to_dict(r) for r in rows if r is not None]


def issue_ticket(
    conn: sqlite3.Connection,
    *,
    stage_run_id: str,
    ttl: int = DEFAULT_TICKET_TTL,
    metadata: Optional[dict] = None,
) -> dict:
    """Issue a one-shot launch ticket for a pending stage run."""

    run = get_stage_run(conn, stage_run_id)
    if not run:
        raise ValueError(f"stage_run_id not found: {stage_run_id}")
    repairable_failed = run["status"] == "failed" and latest_invalid_result_for_stage(conn, stage_run_id)
    if run["status"] not in {"pending", "blocked"} and not repairable_failed:
        raise ValueError(f"cannot issue ticket for stage_run status={run['status']}")
    stage_id = run["stage_id"]
    subagent_type = stage_machine.subagent_type_for_stage(stage_id)
    if not subagent_type:
        raise ValueError(f"stage {stage_id!r} is not launchable")

    ticket_id = uuid.uuid4().hex
    now = _now()
    prompt_digest = f"sha256:{uuid.uuid5(uuid.NAMESPACE_URL, stage_run_id + ':' + stage_id).hex}"
    with conn:
        conn.execute(
            "UPDATE launch_tickets SET status = 'superseded' WHERE stage_run_id = ? AND status = 'pending'",
            (stage_run_id,),
        )
        conn.execute(
            """
            INSERT INTO launch_tickets (
                id, stage_run_id, workflow_id, stage_id, subagent_type,
                worktree_path, status, prompt_digest, metadata_json,
                created_at, expires_at
            ) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?)
            """,
            (
                ticket_id,
                stage_run_id,
                run["workflow_id"],
                stage_id,
                subagent_type,
                run.get("worktree_path") or "",
                prompt_digest,
                _json_dumps(metadata or {}),
                now,
                now + ttl,
            ),
        )
        conn.execute(
            """
            UPDATE stage_runs
            SET launch_ticket_id = ?, status = 'pending', updated_at = ?
            WHERE id = ?
            """,
            (ticket_id, now, stage_run_id),
        )
    return get_ticket(conn, ticket_id) or {"id": ticket_id}


def get_ticket(conn: sqlite3.Connection, ticket_id: str) -> Optional[dict]:
    row = conn.execute("SELECT * FROM launch_tickets WHERE id = ?", (ticket_id,)).fetchone()
    return _ticket_row_to_dict(row)


def get_ticket_by_claim_token(conn: sqlite3.Connection, claim_token: str) -> Optional[dict]:
    row = conn.execute("SELECT * FROM launch_tickets WHERE claim_token = ?", (claim_token,)).fetchone()
    return _ticket_row_to_dict(row)


def ticket_parse_diagnostic(prompt: str) -> dict:
    """Parse an internal launch claim from the first non-empty prompt line.

    Claude sometimes prepends a blank line before model-authored Agent prompts.
    Whitespace before an old claim line is transport noise. Non-claim content
    before the line means the prompt should bind naturally instead.
    """

    first_nonempty_line = 0
    first_nonempty_text = ""
    for line_no, line in enumerate((prompt or "").splitlines(), start=1):
        stripped = line.strip()
        if not stripped:
            continue
        if not first_nonempty_line:
            first_nonempty_line = line_no
            first_nonempty_text = stripped
        if stripped.startswith(TICKET_PREFIX):
            ticket_id = stripped[len(TICKET_PREFIX) :].strip()
            if not re.fullmatch(r"[A-Za-z0-9]+", ticket_id or ""):
                return {
                    "ok": False,
                    "ticket_id": "",
                    "line": line_no,
                    "leading_blank_lines": line_no - 1,
                    "reason": "CLAUDE_CTRL_TICKET line contains extra text or invalid characters",
                }
            return {
                "ok": bool(ticket_id),
                "ticket_id": ticket_id,
                "line": line_no,
                "leading_blank_lines": line_no - 1,
                "reason": "" if ticket_id else "empty launch ticket",
            }
        break

    match = _TICKET_RE.search(prompt or "")
    if match:
        return {
            "ok": False,
            "ticket_id": "",
            "line": 0,
            "leading_blank_lines": 0,
            "reason": (
                "legacy CLAUDE_CTRL_TICKET text appears after natural prompt text; "
                "runtime will prefer natural role binding"
            ),
        }
    if first_nonempty_line:
        return {
            "ok": False,
            "ticket_id": "",
            "line": first_nonempty_line,
            "leading_blank_lines": 0,
            "reason": "natural Agent prompt has no legacy launch claim",
            "first_nonempty": first_nonempty_text[:120],
        }
    return {
        "ok": False,
        "ticket_id": "",
        "line": 0,
        "leading_blank_lines": 0,
        "reason": "empty Agent prompt has no legacy launch claim",
    }


def parse_ticket_from_prompt(prompt: str) -> str:
    parsed = ticket_parse_diagnostic(prompt)
    return str(parsed.get("ticket_id") or "") if parsed.get("ok") else ""


def find_ticket_id_in_text(text: str) -> str:
    match = _TICKET_RE.search(text or "")
    return match.group(1) if match else ""


def latest_invalid_result_for_stage(conn: sqlite3.Connection, stage_run_id: str) -> Optional[dict]:
    row = conn.execute(
        """
        SELECT * FROM stage_results
        WHERE stage_run_id = ? AND valid = 0
        ORDER BY created_at DESC, id DESC
        LIMIT 1
        """,
        (stage_run_id,),
    ).fetchone()
    return _result_row_to_dict(row)


def _resolve_git_commit(worktree_path: str, ref: str) -> str:
    ref = str(ref or "").strip()
    if _is_full_sha(ref):
        return ref
    if not worktree_path or not re.fullmatch(r"[0-9A-Fa-f]{7,39}", ref):
        return ""
    try:
        proc = subprocess.run(
            ["git", "-C", worktree_path, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    resolved = proc.stdout.strip().splitlines()[0] if proc.stdout.strip() else ""
    return resolved if proc.returncode == 0 and _is_full_sha(resolved) else ""


def _normalize_payload_head_sha(run: dict, payload: dict) -> dict:
    if run["stage_id"] not in {stage_machine.IMPLEMENTER, stage_machine.REVIEWER, stage_machine.GUARDIAN_LAND}:
        return payload
    head_sha = str(payload.get("head_sha") or "").strip()
    if not head_sha or _is_full_sha(head_sha):
        return payload
    resolved = _resolve_git_commit(run.get("worktree_path") or "", head_sha)
    if not resolved:
        return payload
    normalized = dict(payload)
    aliases = dict(normalized.get("runtime_aliases") or {})
    aliases["submitted_head_sha_ref"] = head_sha
    normalized["runtime_aliases"] = aliases
    normalized["head_sha"] = resolved
    return normalized


def claim_ticket(
    conn: sqlite3.Connection,
    *,
    ticket_id: str,
    subagent_type: str,
    session_id: str = "",
    agent_id: str = "",
) -> dict:
    """Claim a pending launch ticket before the harness spawns a canonical agent."""

    ticket = get_ticket(conn, ticket_id)
    if not ticket:
        claimed = get_ticket_by_claim_token(conn, ticket_id)
        if claimed:
            raise ValueError(
                "value is an internal V6 claim token, not a CLAUDE_CTRL_TICKET launch ticket"
            )
        raise ValueError(f"launch ticket not found: {ticket_id}")
    now = _now()
    if ticket["status"] != "pending":
        raise ValueError(f"launch ticket {ticket_id} is {ticket['status']}, not pending")
    if int(ticket.get("expires_at") or 0) < now:
        with conn:
            conn.execute("UPDATE launch_tickets SET status = 'expired' WHERE id = ?", (ticket_id,))
            conn.execute(
                "UPDATE stage_runs SET status = 'expired', updated_at = ? WHERE id = ?",
                (now, ticket["stage_run_id"]),
            )
        raise ValueError(f"launch ticket expired: {ticket_id}")
    if subagent_type and subagent_type != ticket["subagent_type"]:
        raise ValueError(
            f"ticket {ticket_id} requires subagent_type={ticket['subagent_type']!r}, got {subagent_type!r}"
        )

    run = get_stage_run(conn, ticket["stage_run_id"])
    if not run:
        raise ValueError(f"stage run not found for ticket {ticket_id}")

    lease_id = ""
    lease_role = stage_machine.lease_role_for_stage(ticket["stage_id"]) or ticket["subagent_type"]
    worktree_path = ticket.get("worktree_path") or run.get("worktree_path") or ""
    if worktree_path:
        existing = leases.get_current(
            conn,
            worktree_path=worktree_path,
            workflow_id=ticket["workflow_id"],
        )
        if existing and existing.get("role") == lease_role:
            lease_id = existing["lease_id"]
        else:
            issued = leases.issue(
                conn,
                lease_role,
                worktree_path=worktree_path,
                workflow_id=ticket["workflow_id"],
                allowed_ops=_allowed_ops_for_stage(ticket["stage_id"]),
                requires_eval=ticket["stage_id"] == stage_machine.GUARDIAN_LAND,
                metadata={"stage_run_id": run["id"], "ticket_id": ticket_id},
            )
            lease_id = issued["lease_id"]
    if lease_id and agent_id:
        leases.claim(conn, agent_id, lease_id=lease_id, expected_role=lease_role)

    claim_token = uuid.uuid4().hex
    with conn:
        conn.execute(
            """
            UPDATE launch_tickets
            SET status = 'claimed', claimed_at = ?, session_id = ?, agent_id = ?, claim_token = ?
            WHERE id = ?
            """,
            (now, session_id or None, agent_id or None, claim_token, ticket_id),
        )
        conn.execute(
            """
            UPDATE stage_runs
            SET status = 'launched', session_id = ?, agent_id = ?, lease_id = ?, updated_at = ?
            WHERE id = ?
            """,
            (session_id or None, agent_id or None, lease_id or None, now, run["id"]),
        )
    claimed = get_ticket(conn, ticket_id) or {}
    claimed["stage_run"] = get_stage_run(conn, run["id"])
    claimed["lease_id"] = lease_id
    claimed["claim_token"] = claim_token
    return claimed


def _prompt_implies_guardian_provision(prompt: str) -> bool:
    text = " ".join((prompt or "").lower().split())
    return any(
        token in text
        for token in (
            "worktree",
            "provision",
            "create branch",
            "new branch",
            "feature branch",
            "isolate",
            "setup branch",
        )
    )


def _natural_stage_for_subagent_type(subagent_type: str, prompt: str) -> str:
    subagent_type = str(subagent_type or "").strip()
    if subagent_type == "planner":
        return stage_machine.PLANNER
    if subagent_type == "implementer":
        return stage_machine.IMPLEMENTER
    if subagent_type == "critic":
        return stage_machine.CRITIC
    if subagent_type == "reviewer":
        return stage_machine.REVIEWER
    if subagent_type == "guardian":
        return (
            stage_machine.GUARDIAN_PROVISION
            if _prompt_implies_guardian_provision(prompt)
            else stage_machine.GUARDIAN_LAND
        )
    return ""


def _active_marker_exists_for_stage(conn: sqlite3.Connection, run: dict) -> bool:
    role = stage_machine.subagent_type_for_stage(run.get("stage_id") or "")
    if not role:
        return False
    project_root = normalize_path(run.get("worktree_path") or "") if run.get("worktree_path") else ""
    clauses = ["is_active = 1", "role = ?"]
    params: list[object] = [role]
    if project_root:
        clauses.append("project_root = ?")
        params.append(project_root)
    row = conn.execute(
        f"SELECT 1 FROM agent_markers WHERE {' AND '.join(clauses)} LIMIT 1",
        params,
    ).fetchone()
    return row is not None


def reconcile_orphaned_launches(
    conn: sqlite3.Connection,
    *,
    workflow_id: str = "",
    worktree_path: str = "",
    stale_after: int = 90,
) -> int:
    """Move launched/running stages with no live role marker back to blocked.

    A canonical launch can die before submitting a result. If no active marker
    remains for that role/project, the stage is no longer actually running and
    should be relaunchable without asking the user to understand tickets.
    """

    now = _now()
    clauses = ["status IN ('launched', 'running')", "updated_at <= ?"]
    params: list[object] = [now - int(stale_after)]
    if workflow_id:
        clauses.append("workflow_id = ?")
        params.append(workflow_id)
    if worktree_path:
        clauses.append("worktree_path = ?")
        params.append(normalize_path(worktree_path))
    rows = conn.execute(
        f"SELECT * FROM stage_runs WHERE {' AND '.join(clauses)}",
        params,
    ).fetchall()
    repaired = 0
    with conn:
        for row in rows:
            run = _row_to_dict(row)
            if not run or _active_marker_exists_for_stage(conn, run):
                continue
            metadata = dict(run.get("metadata") or {})
            metadata["orphan_reconciled_at"] = now
            metadata["orphan_reconcile_reason"] = "launched_or_running_without_active_marker"
            conn.execute(
                """
                UPDATE stage_runs
                SET status = 'blocked', metadata_json = ?, updated_at = ?
                WHERE id = ?
                """,
                (_json_dumps(metadata), now, run["id"]),
            )
            repaired += 1
    return repaired


def _pending_ticket_for_run(conn: sqlite3.Connection, run: dict) -> Optional[dict]:
    if run.get("launch_ticket_id"):
        existing = get_ticket(conn, run["launch_ticket_id"])
        if existing and existing.get("status") == "pending" and int(existing.get("expires_at") or 0) >= _now():
            existing["prompt_prefix"] = f"{TICKET_PREFIX}{existing['id']}"
            return existing
    if run.get("status") in {"pending", "blocked", "failed"}:
        ticket = issue_ticket(conn, stage_run_id=run["id"])
        ticket["prompt_prefix"] = f"{TICKET_PREFIX}{ticket['id']}"
        return ticket
    return None


def _claim_launch_ticket(
    conn: sqlite3.Connection,
    *,
    ticket: dict,
    subagent_type: str,
    session_id: str,
    launch_agent_id: str,
) -> dict:
    if ticket.get("status") == "claimed":
        return {
            "claimed": True,
            "source": "already_claimed",
            "ticket": ticket,
            "stage_run": get_stage_run(conn, ticket["stage_run_id"]),
        }
    claimed = claim_ticket(
        conn,
        ticket_id=ticket["id"],
        subagent_type=subagent_type,
        session_id=session_id,
        agent_id=launch_agent_id,
    )
    return {
        "claimed": True,
        "source": "claimed",
        "ticket": claimed,
        "stage_run": claimed.get("stage_run") or get_stage_run(conn, claimed["stage_run_id"]),
    }


def claim_natural_agent_launch(
    conn: sqlite3.Connection,
    *,
    subagent_type: str,
    workflow_id: str,
    worktree_path: str,
    prompt: str = "",
    session_id: str = "",
    agent_id: str = "",
    launch_tool_id: str = "",
    goal_id: str = "",
    work_item_id: str = "",
) -> dict:
    """Best-effort runtime binding for natural Agent launches.

    Tickets remain the internal ledger, but they are not a user/model-facing
    launch ceremony. When an Agent is called without a ticket, bind it to the
    current pending stage for that role or create an ad-hoc role stage so hooks
    can still enforce authority by role.
    """

    subagent_type = str(subagent_type or "").strip()
    workflow_id = str(workflow_id or "default").strip() or "default"
    worktree_path = normalize_path(worktree_path) if worktree_path else ""
    launch_agent_id = str(launch_tool_id or agent_id or "").strip()
    if not subagent_type:
        return {"claimed": False, "source": "missing_subagent_type"}

    prompt_ticket_id = parse_ticket_from_prompt(prompt) or find_ticket_id_in_text(prompt)
    if prompt_ticket_id:
        ticket = get_ticket(conn, prompt_ticket_id)
        if ticket and ticket.get("subagent_type") == subagent_type:
            return {
                **_claim_launch_ticket(
                    conn,
                    ticket=ticket,
                    subagent_type=subagent_type,
                    session_id=session_id,
                    launch_agent_id=launch_agent_id,
                ),
                "source": "prompt_ticket",
            }

    reconcile_orphaned_launches(conn, workflow_id=workflow_id, worktree_path=worktree_path)
    workflow_ids = [workflow_id]
    active_workflows = conn.execute(
        """
        SELECT DISTINCT workflow_id, MAX(updated_at) AS latest
        FROM stage_runs
        WHERE status IN ('pending', 'blocked', 'failed')
        GROUP BY workflow_id
        ORDER BY latest DESC
        LIMIT 50
        """
    ).fetchall()
    for row in active_workflows:
        wf = str(row["workflow_id"] or "")
        if wf and wf not in workflow_ids:
            workflow_ids.append(wf)

    for candidate_workflow_id in workflow_ids:
        actions = conn.execute(
            """
            SELECT * FROM dispatch_next_actions_v6
            WHERE workflow_id = ? AND status IN ('pending', 'ticketed')
            ORDER BY created_at ASC, id ASC
            """,
            (candidate_workflow_id,),
        ).fetchall()
        for row in actions:
            action = _pending_next_row_to_dict(row)
            if not action:
                continue
            if stage_machine.subagent_type_for_stage(action["next_stage"]) != subagent_type:
                continue
            ticket = issue_ticket_for_next_action(conn, int(action["id"]))
            return {
                **_claim_launch_ticket(
                    conn,
                    ticket=ticket,
                    subagent_type=subagent_type,
                    session_id=session_id,
                    launch_agent_id=launch_agent_id,
                ),
                "source": "next_action",
            }

        rows = conn.execute(
            """
            SELECT * FROM stage_runs
            WHERE workflow_id = ? AND status IN ('pending', 'blocked', 'failed')
            ORDER BY updated_at DESC, created_at DESC, id DESC
            LIMIT 50
            """,
            (candidate_workflow_id,),
        ).fetchall()
        for row in rows:
            run = _row_to_dict(row)
            if not run:
                continue
            if stage_machine.subagent_type_for_stage(run["stage_id"]) != subagent_type:
                continue
            ticket = _pending_ticket_for_run(conn, run)
            if ticket:
                return {
                    **_claim_launch_ticket(
                        conn,
                        ticket=ticket,
                        subagent_type=subagent_type,
                        session_id=session_id,
                        launch_agent_id=launch_agent_id,
                    ),
                    "source": "active_stage_run",
                }

    stage_id = _natural_stage_for_subagent_type(subagent_type, prompt)
    if not stage_id:
        return {"claimed": False, "source": "unknown_subagent_type", "subagent_type": subagent_type}
    workflow_id = resume_workflow_id(conn, preferred_workflow_id=workflow_id, worktree_path=worktree_path)
    run = create_stage_run(
        conn,
        workflow_id=workflow_id,
        stage_id=stage_id,
        goal_id=goal_id or "natural-goal",
        work_item_id=work_item_id or "natural-work-item",
        worktree_path=worktree_path,
        input_payload={
            "source": "natural_agent_launch",
            "requested_subagent_type": subagent_type,
            "prompt": (prompt or "")[:2000],
        },
    )
    ticket = issue_ticket(conn, stage_run_id=run["id"])
    ticket["prompt_prefix"] = f"{TICKET_PREFIX}{ticket['id']}"
    return {
        **_claim_launch_ticket(
            conn,
            ticket=ticket,
            subagent_type=subagent_type,
            session_id=session_id,
            launch_agent_id=launch_agent_id,
        ),
        "source": "natural_stage",
    }


def _allowed_ops_for_stage(stage_id: str) -> list[str]:
    if stage_id in {stage_machine.GUARDIAN_PROVISION, stage_machine.GUARDIAN_LAND}:
        return ["routine_local", "high_risk", "admin_recovery"]
    return ["routine_local"]


def _lineage_retry_count(conn: sqlite3.Connection, run: dict, *, stage_id: str, verdict: str) -> int:
    count = 0
    parent = run.get("parent_run_id") or ""
    while parent:
        prev = get_stage_run(conn, parent)
        if not prev:
            break
        payload = prev.get("result") or {}
        if prev.get("stage_id") == stage_id and payload.get("verdict") == verdict:
            count += 1
        parent = prev.get("parent_run_id") or ""
    return count


def validate_result(stage_id: str, payload: dict, *, expected_stage_run_id: str = "") -> StageResultValidation:
    missing: list[str] = []
    verdict = str(payload.get("verdict") or "").strip()
    if not verdict:
        missing.append("verdict")
    else:
        try:
            stage_machine.validate_verdict(stage_id, verdict)
        except ValueError as exc:
            missing.append(f"invalid_verdict:{exc}")

    # Common evidence fields.  Keep this intentionally small; detailed evidence
    # remains in the free-form body and payload extensions.
    if not str(payload.get("summary") or "").strip():
        missing.append("summary")
    if expected_stage_run_id:
        payload_run_id = str(payload.get("stage_run_id") or "").strip()
        if not payload_run_id:
            missing.append("stage_run_id")
        elif payload_run_id != expected_stage_run_id:
            missing.append("stage_run_id_mismatch")
    if stage_id in {stage_machine.IMPLEMENTER, stage_machine.REVIEWER, stage_machine.GUARDIAN_LAND}:
        head_sha = str(payload.get("head_sha") or "").strip()
        if not head_sha:
            missing.append("head_sha")
        elif not _is_full_sha(head_sha):
            missing.append("head_sha_full_40")
    payload_stage_id = str(payload.get("stage_id") or "").strip()
    if not payload_stage_id:
        missing.append("stage_id")
    elif payload_stage_id != stage_id:
        missing.append("stage_id_mismatch")
    if stage_id == stage_machine.REVIEWER and "findings" not in payload:
        missing.append("findings")
    if stage_id == stage_machine.CRITIC:
        proof = payload.get("execution_proof")
        if not isinstance(proof, dict) or proof.get("valid") is not True or not proof.get("provider"):
            missing.append("execution_proof")
        if "findings" not in payload:
            missing.append("findings")
    return StageResultValidation(valid=not missing, missing_fields=missing, verdict=verdict)


def _stage_run_id_for_ref(conn: sqlite3.Connection, ref: str) -> str:
    ref = str(ref or "").strip()
    if not ref:
        return ""
    if get_stage_run(conn, ref):
        return ref
    ticket = get_ticket(conn, ref)
    if ticket:
        return str(ticket.get("stage_run_id") or "")
    return ""


def _normalize_payload_stage_run_ref(conn: sqlite3.Connection, payload: dict, *, stage_run_id: str) -> dict:
    payload_ref = str(payload.get("stage_run_id") or "").strip()
    if not payload_ref or payload_ref == stage_run_id:
        return payload
    if _stage_run_id_for_ref(conn, payload_ref) != stage_run_id:
        return payload

    normalized = dict(payload)
    aliases = dict(normalized.get("runtime_aliases") or {})
    aliases["submitted_stage_run_ref"] = payload_ref
    if get_ticket(conn, payload_ref):
        aliases["submitted_ticket_id"] = payload_ref
    normalized["runtime_aliases"] = aliases
    normalized["stage_run_id"] = stage_run_id
    return normalized


def submit_result(
    conn: sqlite3.Connection,
    *,
    stage_run_id: str,
    payload: dict,
) -> dict:
    """Validate and record a canonical v6 result contract."""

    requested_stage_run_ref = str(stage_run_id or "").strip()
    stage_run_id = _stage_run_id_for_ref(conn, requested_stage_run_ref)
    run = get_stage_run(conn, stage_run_id)
    if not run:
        raise ValueError(f"stage_run_id not found: {requested_stage_run_ref}")
    payload = _normalize_payload_stage_run_ref(conn, dict(payload), stage_run_id=stage_run_id)
    payload = _normalize_payload_head_sha(run, payload)
    stage_id = run["stage_id"]
    validation = validate_result(stage_id, payload, expected_stage_run_id=stage_run_id)
    now = _now()
    retry_count = _lineage_retry_count(conn, run, stage_id=stage_id, verdict=validation.verdict) + 1
    transition = (
        stage_machine.resolve_transition(stage_id, validation.verdict, retry_count=retry_count)
        if validation.valid
        else None
    )

    with conn:
        cur = conn.execute(
            """
            INSERT INTO stage_results (
                stage_run_id, workflow_id, stage_id, verdict, valid,
                payload_json, missing_fields_json, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                stage_run_id,
                run["workflow_id"],
                stage_id,
                validation.verdict,
                1 if validation.valid else 0,
                _json_dumps(payload),
                _json_dumps(validation.missing_fields),
                now,
            ),
        )
        conn.execute(
            """
            UPDATE stage_runs
            SET status = ?, result_json = ?, updated_at = ?
            WHERE id = ?
            """,
            (
                "completed" if validation.valid else "blocked",
                _json_dumps(payload),
                now,
                stage_run_id,
            ),
        )
        metadata = run.get("metadata") or {}
        metadata["last_retry_count"] = retry_count
        if transition and transition.terminal_reason:
            metadata["transition_terminal_reason"] = transition.terminal_reason
        conn.execute(
            "UPDATE stage_runs SET metadata_json = ? WHERE id = ?",
            (_json_dumps(metadata), stage_run_id),
        )

    result = _result_row_to_dict(
        conn.execute("SELECT * FROM stage_results WHERE id = ?", (cur.lastrowid,)).fetchone()
    )
    next_run = None
    next_action = None
    repair_ticket = None
    if validation.valid and transition is not None and stage_machine.is_active(transition.to_stage):
        next_run = create_stage_run(
            conn,
            workflow_id=run["workflow_id"],
            stage_id=transition.to_stage,
            goal_id=run["goal_id"],
            work_item_id=run["work_item_id"],
            parent_run_id=run["id"],
            worktree_path=_next_worktree_path(conn, run, transition.to_stage),
            input_payload={
                "from_stage_run_id": run["id"],
                "from_stage": stage_id,
                "verdict": validation.verdict,
                "summary": payload.get("summary", ""),
            },
        )
        next_action = _create_next_action(conn, run, next_run, transition, payload)
        if next_run["stage_id"] == stage_machine.GUARDIAN_LAND:
            from runtime.core import landing_readiness as _landing_readiness

            _landing_readiness.ensure_for_guardian_stage(conn, next_run["id"])
        if next_run["stage_id"] == stage_machine.CRITIC and next_action:
            with conn:
                conn.execute(
                    "UPDATE dispatch_next_actions_v6 SET status = 'worker_pending', updated_at = ? WHERE id = ?",
                    (_now(), next_action["id"]),
                )
            next_action = get_next_action(conn, next_action["id"])
    elif validation.valid and transition is not None:
        events.emit(
            conn,
            type="v6_stage_sink",
            source=f"workflow:{run['workflow_id']}",
            detail=f"{stage_id}:{validation.verdict}->{transition.to_stage}",
        )
    elif not validation.valid and stage_machine.is_active(stage_id):
        repair_ticket = issue_ticket(conn, stage_run_id=stage_run_id)
        repair_ticket["prompt_prefix"] = f"{TICKET_PREFIX}{repair_ticket['id']}"

    return {
        "result": result,
        "validation": validation.as_dict(),
        "transition": transition.as_dict() if transition else None,
        "next_stage_run": next_run,
        "next_action": next_action,
        "repair_ticket": repair_ticket,
    }


def _next_worktree_path(conn: sqlite3.Connection, run: dict, to_stage: str) -> str:
    if to_stage in {stage_machine.IMPLEMENTER, stage_machine.CRITIC, stage_machine.REVIEWER}:
        if run.get("worktree_path"):
            return run["worktree_path"]
        binding = workflows.get_binding(conn, run["workflow_id"])
        if binding:
            return binding.get("worktree_path") or ""
    if to_stage == stage_machine.GUARDIAN_LAND:
        binding = workflows.get_binding(conn, run["workflow_id"])
        if binding:
            return binding.get("worktree_path") or run.get("worktree_path") or ""
    return run.get("worktree_path") or ""


def _create_next_action(
    conn: sqlite3.Connection,
    current_run: dict,
    next_run: dict,
    transition: stage_machine.Transition,
    payload: dict,
) -> dict:
    now = _now()
    with conn:
        cur = conn.execute(
            """
            INSERT INTO dispatch_next_actions_v6 (
                workflow_id, source_stage_run_id, next_stage_run_id,
                source_stage, next_stage, reason, payload_json, status, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?)
            """,
            (
                current_run["workflow_id"],
                current_run["id"],
                next_run["id"],
                current_run["stage_id"],
                next_run["stage_id"],
                f"{current_run['stage_id']}:{payload.get('verdict')}->{next_run['stage_id']}",
                _json_dumps({
                    "transition": transition.as_dict(),
                    "source_summary": payload.get("summary", ""),
                }),
                now,
            ),
        )
    return get_next_action(conn, cur.lastrowid) or {"id": cur.lastrowid}


def get_next_action(conn: sqlite3.Connection, action_id: int) -> Optional[dict]:
    row = conn.execute("SELECT * FROM dispatch_next_actions_v6 WHERE id = ?", (action_id,)).fetchone()
    return _pending_next_row_to_dict(row)


def next_action(conn: sqlite3.Connection, *, workflow_id: str = "") -> Optional[dict]:
    clauses = ["status IN ('pending','worker_pending')"]
    params: list[object] = []
    if workflow_id:
        clauses.append("workflow_id = ?")
        params.append(workflow_id)
    row = conn.execute(
        f"""
        SELECT * FROM dispatch_next_actions_v6
        WHERE {' AND '.join(clauses)}
        ORDER BY created_at ASC, id ASC
        LIMIT 1
        """,
        params,
    ).fetchone()
    return _pending_next_row_to_dict(row)


def issue_ticket_for_next_action(conn: sqlite3.Connection, action_id: int) -> dict:
    action = get_next_action(conn, action_id)
    if not action:
        raise ValueError(f"next action not found: {action_id}")
    if action["status"] == "ticketed" and action.get("ticket_id"):
        existing = get_ticket(conn, action["ticket_id"])
        if existing and existing.get("status") == "pending" and int(existing.get("expires_at") or 0) >= _now():
            existing["next_action_id"] = action_id
            existing["prompt_prefix"] = f"{TICKET_PREFIX}{existing['id']}"
            return existing
    if action["status"] == "worker_pending":
        raise ValueError(
            f"next action {action_id} is worker_pending; critic worker must complete or publish fallback before ticketing"
        )
    if action["status"] not in {"pending", "ticketed"}:
        raise ValueError(f"next action {action_id} is {action['status']}, not pending")
    ticket = issue_ticket(conn, stage_run_id=action["next_stage_run_id"])
    now = _now()
    with conn:
        conn.execute(
            "UPDATE dispatch_next_actions_v6 SET status = 'ticketed', ticket_id = ?, updated_at = ? WHERE id = ?",
            (ticket["id"], now, action_id),
        )
    ticket["next_action_id"] = action_id
    ticket["prompt_prefix"] = f"{TICKET_PREFIX}{ticket['id']}"
    return ticket


def resume_workflow_id(
    conn: sqlite3.Connection,
    *,
    preferred_workflow_id: str = "",
    worktree_path: str = "",
) -> str:
    """Choose the workflow most likely meant by a dispatch-resume prompt."""

    preferred_workflow_id = str(preferred_workflow_id or "").strip()
    canonical_worktree = normalize_path(worktree_path) if worktree_path else ""
    rows = conn.execute(
        """
        SELECT * FROM stage_runs
        WHERE status IN ('pending', 'blocked', 'failed', 'launched', 'running')
        ORDER BY updated_at DESC, created_at DESC, id DESC
        LIMIT 50
        """
    ).fetchall()
    best: tuple[int, int, str] | None = None
    for row in rows:
        run = _row_to_dict(row)
        if not run:
            continue
        if run["status"] == "failed" and not latest_invalid_result_for_stage(conn, run["id"]):
            continue
        score = 100
        if run["status"] in {"launched", "running"}:
            score -= 5
        if run["stage_id"] != stage_machine.PLANNER:
            score += 50
        if run["workflow_id"] == preferred_workflow_id:
            score += 10
        if canonical_worktree and normalize_path(run.get("worktree_path") or "") == canonical_worktree:
            score += 5
        updated_at = int(run.get("updated_at") or 0)
        candidate = (score, updated_at, run["workflow_id"])
        if best is None or candidate[:2] > best[:2]:
            best = candidate
    return best[2] if best else preferred_workflow_id


def bootstrap_planner(
    conn: sqlite3.Connection,
    *,
    workflow_id: str,
    worktree_path: str,
    goal_id: str = "",
    work_item_id: str = "",
    prompt: str = "",
    recover_orphans: bool = False,
) -> dict:
    """Ensure a v6 launch ticket exists for the next canonical dispatch.

    This is the UX bootstrap used by UserPromptSubmit. It never asks the user to
    hand-write `CLAUDE_CTRL_TICKET`; it creates or reuses the runtime ticket the
    orchestrator should pass to Agent line 1.
    """

    workflow_id = str(workflow_id or "").strip()
    if not workflow_id:
        raise ValueError("workflow_id is required for v6 bootstrap")
    worktree_path = normalize_path(worktree_path) if worktree_path else ""
    if recover_orphans:
        reconcile_orphaned_launches(conn, workflow_id=workflow_id, stale_after=0)

    action = next_action(conn, workflow_id=workflow_id)
    if action is not None:
        if action.get("status") == "worker_pending":
            return {
                "created": False,
                "source": "worker_pending",
                "workflow_id": workflow_id,
                "stage_run": get_stage_run(conn, action["next_stage_run_id"]),
                "ticket": None,
                "prompt_prefix": "",
                "subagent_type": stage_machine.subagent_type_for_stage(action["next_stage"]),
                "stage_id": action["next_stage"],
                "message": "critic worker is running or queued; no launch ticket is issued until external critic completion or explicit fallback",
            }
        ticket = issue_ticket_for_next_action(conn, int(action["id"]))
        return {
            "created": False,
            "source": "next_action",
            "workflow_id": workflow_id,
            "stage_run": get_stage_run(conn, ticket["stage_run_id"]),
            "ticket": ticket,
            "prompt_prefix": ticket["prompt_prefix"],
            "subagent_type": ticket["subagent_type"],
            "stage_id": ticket["stage_id"],
        }

    row = conn.execute(
        """
        SELECT * FROM stage_runs
        WHERE workflow_id = ? AND status IN ('pending','launched','running','blocked','failed')
        ORDER BY created_at DESC, id DESC
        LIMIT 1
        """,
        (workflow_id,),
    ).fetchone()
    active = _row_to_dict(row)
    if active:
        ticket = None
        if active.get("launch_ticket_id"):
            existing = get_ticket(conn, active["launch_ticket_id"])
            if existing and existing.get("status") == "pending" and int(existing.get("expires_at") or 0) >= _now():
                ticket = existing
        if ticket is None and active.get("status") in {"pending", "blocked", "failed"}:
            ticket = issue_ticket(conn, stage_run_id=active["id"])
        if ticket is not None:
            ticket["prompt_prefix"] = f"{TICKET_PREFIX}{ticket['id']}"
            return {
                "created": False,
                "source": "active_stage_run",
                "workflow_id": workflow_id,
                "stage_run": get_stage_run(conn, active["id"]),
                "ticket": ticket,
                "prompt_prefix": ticket["prompt_prefix"],
                "subagent_type": ticket["subagent_type"],
                "stage_id": ticket["stage_id"],
            }
        return {
            "created": False,
            "source": "active_stage_run",
            "workflow_id": workflow_id,
            "stage_run": active,
            "ticket": None,
            "prompt_prefix": "",
            "subagent_type": stage_machine.subagent_type_for_stage(active["stage_id"]),
            "stage_id": active["stage_id"],
            "message": "active stage is already launched/running; no new ticket issued",
        }

    run = create_stage_run(
        conn,
        workflow_id=workflow_id,
        stage_id=stage_machine.PLANNER,
        goal_id=goal_id,
        work_item_id=work_item_id,
        worktree_path=worktree_path,
        input_payload={"bootstrap_prompt": prompt[:2000]} if prompt else {},
    )
    ticket = issue_ticket(conn, stage_run_id=run["id"])
    ticket["prompt_prefix"] = f"{TICKET_PREFIX}{ticket['id']}"
    return {
        "created": True,
        "source": "new_planner_stage_run",
        "workflow_id": workflow_id,
        "stage_run": get_stage_run(conn, run["id"]),
        "ticket": ticket,
        "prompt_prefix": ticket["prompt_prefix"],
        "subagent_type": ticket["subagent_type"],
        "stage_id": ticket["stage_id"],
    }


def bootstrap_native_plan_handoff(
    conn: sqlite3.Connection,
    *,
    workflow_id: str,
    worktree_path: str,
    goal_id: str = "",
    work_item_id: str = "",
    prompt: str = "",
    recover_orphans: bool = False,
) -> dict:
    """Bootstrap Guardian provisioning when native Plan mode already planned.

    Native Plan mode can produce a decision-complete plan outside the v6 stage
    graph. When the user then says to implement/follow that plan, the runtime
    records a synthetic planner result and issues the next canonical Guardian
    ticket. The graph stays intact without forcing a redundant planner agent.
    """

    workflow_id = str(workflow_id or "").strip()
    if not workflow_id:
        raise ValueError("workflow_id is required for v6 bootstrap")
    worktree_path = normalize_path(worktree_path) if worktree_path else ""
    if recover_orphans:
        reconcile_orphaned_launches(conn, workflow_id=workflow_id, stale_after=0)

    action = next_action(conn, workflow_id=workflow_id)
    if action is not None:
        if action.get("status") == "worker_pending":
            return {
                "created": False,
                "source": "worker_pending",
                "workflow_id": workflow_id,
                "stage_run": get_stage_run(conn, action["next_stage_run_id"]),
                "ticket": None,
                "prompt_prefix": "",
                "subagent_type": stage_machine.subagent_type_for_stage(action["next_stage"]),
                "stage_id": action["next_stage"],
                "message": "critic worker is running or queued; no launch ticket is issued until external critic completion or explicit fallback",
            }
        ticket = issue_ticket_for_next_action(conn, int(action["id"]))
        return {
            "created": False,
            "source": "next_action",
            "workflow_id": workflow_id,
            "stage_run": get_stage_run(conn, ticket["stage_run_id"]),
            "ticket": ticket,
            "prompt_prefix": ticket["prompt_prefix"],
            "subagent_type": ticket["subagent_type"],
            "stage_id": ticket["stage_id"],
        }

    row = conn.execute(
        """
        SELECT * FROM stage_runs
        WHERE workflow_id = ? AND status IN ('pending','launched','running','blocked','failed')
        ORDER BY created_at DESC, id DESC
        LIMIT 1
        """,
        (workflow_id,),
    ).fetchone()
    active = _row_to_dict(row)
    planner_run = None
    if active and active.get("stage_id") == stage_machine.PLANNER:
        planner_run = active
    elif active:
        ticket = None
        if active.get("launch_ticket_id"):
            existing = get_ticket(conn, active["launch_ticket_id"])
            if existing and existing.get("status") == "pending" and int(existing.get("expires_at") or 0) >= _now():
                ticket = existing
        if ticket is None and active.get("status") in {"pending", "blocked", "failed"}:
            ticket = issue_ticket(conn, stage_run_id=active["id"])
        if ticket is not None:
            ticket["prompt_prefix"] = f"{TICKET_PREFIX}{ticket['id']}"
            return {
                "created": False,
                "source": "active_stage_run",
                "workflow_id": workflow_id,
                "stage_run": get_stage_run(conn, active["id"]),
                "ticket": ticket,
                "prompt_prefix": ticket["prompt_prefix"],
                "subagent_type": ticket["subagent_type"],
                "stage_id": ticket["stage_id"],
            }
        return {
            "created": False,
            "source": "active_stage_run",
            "workflow_id": workflow_id,
            "stage_run": active,
            "ticket": None,
            "prompt_prefix": "",
            "subagent_type": stage_machine.subagent_type_for_stage(active["stage_id"]),
            "stage_id": active["stage_id"],
            "message": "active stage is already launched/running; no new ticket issued",
        }

    if planner_run is None:
        planner_run = create_stage_run(
            conn,
            workflow_id=workflow_id,
            stage_id=stage_machine.PLANNER,
            goal_id=goal_id,
            work_item_id=work_item_id,
            worktree_path=worktree_path,
            input_payload={"bootstrap_prompt": prompt[:2000], "source": "native_plan_mode"},
        )
    elif planner_run.get("launch_ticket_id"):
        with conn:
            conn.execute(
                "UPDATE launch_tickets SET status = 'superseded' WHERE id = ? AND status = 'pending'",
                (planner_run["launch_ticket_id"],),
            )

    submitted = submit_result(
        conn,
        stage_run_id=planner_run["id"],
        payload={
            "stage_run_id": planner_run["id"],
            "stage_id": stage_machine.PLANNER,
            "verdict": "next_work_item",
            "summary": "Native Plan mode already produced the implementation plan; proceed to Guardian provisioning.",
            "source": "native_plan_mode",
        },
    )
    action = submitted.get("next_action")
    if not action:
        raise ValueError("native Plan mode handoff did not create a Guardian next action")
    ticket = issue_ticket_for_next_action(conn, int(action["id"]))
    return {
        "created": True,
        "source": "native_plan_handoff",
        "workflow_id": workflow_id,
        "stage_run": get_stage_run(conn, ticket["stage_run_id"]),
        "ticket": ticket,
        "prompt_prefix": ticket["prompt_prefix"],
        "subagent_type": ticket["subagent_type"],
        "stage_id": ticket["stage_id"],
        "planner_stage_run": get_stage_run(conn, planner_run["id"]),
    }


def prompt_context_for_ticket(conn: sqlite3.Connection, ticket_id: str) -> dict:
    ticket = get_ticket(conn, ticket_id)
    if not ticket:
        raise ValueError(f"launch ticket not found: {ticket_id}")
    run = get_stage_run(conn, ticket["stage_run_id"])
    if not run:
        raise ValueError(f"stage run not found for ticket {ticket_id}")
    return {
        "ticket": ticket,
        "stage_run": run,
        "allowed_verdicts": sorted(stage_machine.allowed_verdicts(run["stage_id"])),
        "result_contract": result_contract_for_stage(run["stage_id"], run["id"]),
        "context_text": render_context_text(ticket, run),
    }


def start_context_for_claimed_ticket(
    conn: sqlite3.Connection,
    *,
    subagent_type: str,
    session_id: str = "",
    agent_id: str = "",
    agent_ref: str = "",
    claim_token: str = "",
    ticket_id: str = "",
    workflow_id: str = "",
    worktree_path: str = "",
    prompt: str = "",
) -> Optional[dict]:
    """Return SubagentStart context for a claimed or naturally bound launch.

    PreToolUse Agent normally creates the internal launch claim before spawn.
    SubagentStart resolves by exact claim token, explicit internal id, launch
    tool id/child metadata, then falls back to natural role/workflow binding so
    missing prompt ceremony never blocks a canonical role from receiving runtime
    context.
    """

    subagent_type = str(subagent_type or "").strip()
    if not subagent_type:
        return None
    if claim_token:
        row = conn.execute(
            """
            SELECT * FROM launch_tickets
            WHERE status = 'claimed' AND subagent_type = ? AND claim_token = ?
            LIMIT 1
            """,
            (subagent_type, claim_token),
        ).fetchone()
    elif ticket_id:
        row = conn.execute(
            """
            SELECT * FROM launch_tickets
            WHERE status = 'claimed' AND subagent_type = ? AND id = ?
            LIMIT 1
            """,
            (subagent_type, ticket_id),
        ).fetchone()
    elif agent_ref or agent_id:
        refs = [ref for ref in (agent_ref, agent_id) if ref]
        placeholders = ",".join("?" for _ in refs)
        row = conn.execute(
            f"""
            SELECT * FROM launch_tickets
            WHERE status = 'claimed'
              AND subagent_type = ?
              AND agent_id IN ({placeholders})
            ORDER BY claimed_at DESC, created_at DESC
            LIMIT 1
            """,
            (subagent_type, *refs),
        ).fetchone()
    else:
        row = None
    ticket = _ticket_row_to_dict(row)
    if not ticket:
        claimed = claim_natural_agent_launch(
            conn,
            subagent_type=subagent_type,
            workflow_id=workflow_id or "default",
            worktree_path=worktree_path,
            prompt=prompt,
            session_id=session_id,
            agent_id=agent_id,
            launch_tool_id=agent_ref or agent_id,
        )
        ticket = claimed.get("ticket") if claimed.get("claimed") else None
    if not ticket:
        return None
    run = get_stage_run(conn, ticket["stage_run_id"])
    if not run:
        return None

    now = _now()
    lease_id = run.get("lease_id") or ""
    lease_role = stage_machine.lease_role_for_stage(run["stage_id"]) or subagent_type
    if lease_id and agent_id:
        leases.claim(conn, agent_id, lease_id=lease_id, expected_role=lease_role)
    with conn:
        conn.execute(
            """
            UPDATE launch_tickets
            SET session_id = COALESCE(NULLIF(?, ''), session_id),
                agent_id = COALESCE(NULLIF(?, ''), agent_id)
            WHERE id = ?
            """,
            (session_id, agent_id, ticket["id"]),
        )
        conn.execute(
            """
            UPDATE stage_runs
            SET status = 'running',
                session_id = COALESCE(NULLIF(?, ''), session_id),
                agent_id = COALESCE(NULLIF(?, ''), agent_id),
                updated_at = ?
            WHERE id = ?
            """,
            (session_id, agent_id, now, run["id"]),
        )
    ctx = prompt_context_for_ticket(conn, ticket["id"])
    ctx["lease_id"] = lease_id
    return ctx


def result_contract_for_stage(stage_id: str, stage_run_id: str) -> dict:
    base = {
        "stage_run_id": stage_run_id,
        "stage_id": stage_id,
        "verdict": f"one of: {', '.join(sorted(stage_machine.allowed_verdicts(stage_id)))}",
        "summary": "one-line evidence summary",
    }
    if stage_id in {stage_machine.IMPLEMENTER, stage_machine.REVIEWER, stage_machine.GUARDIAN_LAND}:
        base["head_sha"] = "current git HEAD full 40-character SHA from `git rev-parse HEAD`"
    if stage_id == stage_machine.REVIEWER:
        base["findings"] = []
    if stage_id == stage_machine.CRITIC:
        base["findings"] = []
        base["execution_proof"] = {"provider": "codex|gemini|test", "valid": True}
    return base


def render_context_text(ticket: dict, run: dict) -> str:
    contract = result_contract_for_stage(run["stage_id"], run["id"])
    lines = [
        "v6 Runtime Context",
        f"internal_launch_id: {ticket['id']}",
        f"stage_run_id: {run['id']}",
        f"workflow_id: {run['workflow_id']}",
        f"stage_id: {run['stage_id']}",
        f"work_item_id: {run['work_item_id']}",
        f"worktree_path: {run.get('worktree_path') or '(project root)'}",
        "Allowed verdicts: " + ", ".join(sorted(stage_machine.allowed_verdicts(run["stage_id"]))),
        "Final response must end with a fenced JSON block:",
        "```claude_ctrl_result",
        json.dumps(contract, indent=2, sort_keys=True),
        "```",
    ]
    return "\n".join(lines)


def extract_result_block(text: str, *, require_final: bool = False) -> Optional[dict]:
    marker = "```claude_ctrl_result"
    text = text or ""
    if marker not in text:
        return None
    before, after = text.rsplit(marker, 1)
    del before
    if "```" not in after:
        return None
    block, tail = after.split("```", 1)
    if require_final and tail.strip():
        raise ValueError("claude_ctrl_result must be the final fenced block with no trailing text")
    block = block.strip()
    if not block:
        return None
    return json.loads(block)


def extract_and_submit_result(conn: sqlite3.Connection, *, stage_run_id: str, response_text: str) -> dict:
    payload = extract_result_block(response_text, require_final=True)
    if payload is None:
        raise ValueError("response did not contain a final claude_ctrl_result block")
    return submit_result(conn, stage_run_id=stage_run_id, payload=payload)


def extract_and_submit_response(conn: sqlite3.Connection, *, response_text: str) -> dict:
    payload = extract_result_block(response_text, require_final=True)
    if payload is None:
        raise ValueError("response did not contain a final claude_ctrl_result block")
    stage_run_id = str(payload.get("stage_run_id") or "").strip()
    if not stage_run_id:
        raise ValueError("claude_ctrl_result missing stage_run_id")
    return submit_result(conn, stage_run_id=stage_run_id, payload=payload)
