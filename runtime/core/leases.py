"""Dispatch lease domain module — execution contracts for agent operations.

@decision DEC-LEASE-001
Title: Dispatch leases replace marker-based WHO enforcement for Check 3
Status: accepted
Rationale: The old Check 3 in guard.sh read the agent_markers table to
  determine if the active agent had "guardian" role before allowing high-risk
  git operations (push, rebase, reset, merge --no-ff). This created a race
  condition: concurrent sessions overwrite the active marker, making role
  determination indeterminate. Dispatch leases fix this by making permission
  explicit and worktree-scoped. The orchestrator issues a lease before
  dispatching an agent; the lease declares what operations are allowed
  (allowed_ops_json); guard.sh validates operations against the active lease
  for the worktree rather than reading global marker state.

  Authority boundary:
    - This module owns the dispatch_leases table exclusively.
    - validate_op() calls evaluation.get() and approvals.list_pending() as
      read-only dependencies — it does NOT write to those tables.
    - classify_git_op() here is the sole classifier for the Check 3 path.
      The bash classifier in context-lib.sh remains for Check 13 only.
    - Markers remain for observability (set by subagent-start.sh) but are
      NOT consulted by Check 3 after this migration.

  Uniqueness invariants:
    - At most one active lease per worktree_path (enforced by issue()).
    - At most one active lease per agent_id (enforced by claim()).
    - Both invariants enforced atomically in single transactions.
"""

from __future__ import annotations

import json
import re
import sqlite3
import time
import uuid
from typing import Optional

from runtime.schemas import DEFAULT_LEASE_TTL
import runtime.core.evaluation as evaluation_mod
import runtime.core.approvals as approvals_mod


# ---------------------------------------------------------------------------
# Git op classifier — sole authority for Check 3 path (DEC-LEASE-001)
# ---------------------------------------------------------------------------


def classify_git_op(command: str) -> str:
    """Classify a git command string into a risk tier.

    Python port of the bash classifier in context-lib.sh:522-536.
    Must produce identical results for any command string.

    Returns:
        "high_risk"      — push, rebase, reset, merge --no-ff
        "routine_local"  — commit or merge (without --no-ff)
        "unclassified"   — anything else (log, status, diff, etc.)

    This function is the sole classifier for the migrated Check 3 path.
    The bash classifier in context-lib.sh is retained for Check 13 only.
    Never return None — all inputs produce one of the three string values.
    """
    # High-risk: push (any form, including git -C /path push)
    if re.search(r"\bgit\b.*\bpush\b", command):
        return "high_risk"
    # High-risk: rebase
    if re.search(r"\bgit\b.*\brebase\b", command):
        return "high_risk"
    # High-risk: reset (any form — --hard, --soft, etc.)
    if re.search(r"\bgit\b.*\breset\b", command):
        return "high_risk"
    # High-risk: non-fast-forward merge (explicit --no-ff flag)
    if re.search(r"\bgit\b.*\bmerge\b.*--no-ff", command):
        return "high_risk"
    # Routine local: commit or merge (local-only, without --no-ff)
    if re.search(r"\bgit\b.*\b(commit|merge)\b", command):
        return "routine_local"
    # Default: unclassified (log, status, diff, show, etc.)
    return "unclassified"


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _parse_json_col(value: Optional[str], default) -> object:
    """Parse a JSON column value, falling back to default on error.

    Follows the pattern from runtime/core/workflows.py get_scope() —
    try json.loads, fall back to empty list (or provided default) on error.
    """
    if value is None:
        return default
    try:
        return json.loads(value)
    except (json.JSONDecodeError, TypeError):
        return default


def _row_to_dict(row: sqlite3.Row) -> dict:
    """Convert a sqlite3.Row to a plain dict with JSON columns parsed."""
    d = dict(row)
    d["allowed_ops"] = _parse_json_col(d.get("allowed_ops_json"), ["routine_local"])
    d["blocked_ops"] = _parse_json_col(d.get("blocked_ops_json"), [])
    d["approval_scope"] = _parse_json_col(d.get("approval_scope_json"), None)
    d["metadata"] = _parse_json_col(d.get("metadata_json"), None)
    return d


def _revoke_active_for_worktree(conn: sqlite3.Connection, worktree_path: str) -> None:
    """Revoke any existing active lease for this worktree_path.

    Called inside issue() before INSERT to enforce the uniqueness invariant
    (at most one active lease per worktree_path). Caller holds the transaction.
    """
    now = int(time.time())
    conn.execute(
        """UPDATE dispatch_leases
           SET status = 'revoked', released_at = ?
           WHERE worktree_path = ? AND status = 'active'""",
        (now, worktree_path),
    )


def _revoke_active_for_agent(
    conn: sqlite3.Connection, agent_id: str, exclude_lease_id: str
) -> None:
    """Revoke any other active lease for this agent_id.

    Called inside claim() to enforce agent uniqueness invariant
    (at most one active lease per agent_id at a time). Caller holds the transaction.
    """
    now = int(time.time())
    conn.execute(
        """UPDATE dispatch_leases
           SET status = 'revoked', released_at = ?
           WHERE agent_id = ? AND status = 'active' AND lease_id != ?""",
        (now, agent_id, exclude_lease_id),
    )


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def issue(
    conn: sqlite3.Connection,
    role: str,
    worktree_path: Optional[str] = None,
    workflow_id: Optional[str] = None,
    branch: Optional[str] = None,
    allowed_ops: Optional[list] = None,
    blocked_ops: Optional[list] = None,
    requires_eval: bool = True,
    head_sha: Optional[str] = None,
    approval_scope: Optional[object] = None,
    next_step: Optional[str] = None,
    ttl: int = DEFAULT_LEASE_TTL,
    metadata: Optional[object] = None,
) -> dict:
    """Mint a new dispatch lease and return the full lease dict.

    The lease_id is generated as a UUID4 hex string.
    expires_at = now + ttl (default 7200 seconds = 2 hours).

    CRITICAL: Before INSERT, any existing active lease for the same
    worktree_path is revoked atomically in the same transaction.
    This enforces the uniqueness invariant: at most one active lease
    per worktree_path at any time (DEC-LEASE-001).

    Raises ValueError for unknown role or invalid ttl.
    """
    if not role:
        raise ValueError("role is required")
    if ttl <= 0:
        raise ValueError(f"ttl must be positive, got {ttl}")

    lease_id = uuid.uuid4().hex
    now = int(time.time())
    expires_at = now + ttl

    _allowed = allowed_ops if allowed_ops is not None else ["routine_local"]
    _blocked = blocked_ops if blocked_ops is not None else []

    with conn:
        # Revoke existing active lease for same worktree before inserting
        if worktree_path:
            _revoke_active_for_worktree(conn, worktree_path)

        conn.execute(
            """INSERT INTO dispatch_leases
               (lease_id, agent_id, role, workflow_id, worktree_path, branch,
                allowed_ops_json, blocked_ops_json, requires_eval, head_sha,
                approval_scope_json, next_step, status, issued_at, expires_at,
                released_at, metadata_json)
               VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?, NULL, ?)""",
            (
                lease_id,
                role,
                workflow_id,
                worktree_path,
                branch,
                json.dumps(_allowed),
                json.dumps(_blocked),
                1 if requires_eval else 0,
                head_sha,
                json.dumps(approval_scope) if approval_scope is not None else None,
                next_step,
                now,
                expires_at,
                json.dumps(metadata) if metadata is not None else None,
            ),
        )

    return get(conn, lease_id)


def claim(
    conn: sqlite3.Connection,
    agent_id: str,
    lease_id: Optional[str] = None,
    worktree_path: Optional[str] = None,
) -> Optional[dict]:
    """Bind an agent_id to a lease. Returns the claimed lease dict or None.

    Finds the active lease by lease_id (preferred) or worktree_path.
    Sets agent_id on the matched lease.

    Also revokes any OTHER active lease with the same agent_id (agent
    uniqueness invariant: one agent = one execution context at a time).

    Returns None when no matching active lease is found.
    """
    if not agent_id:
        raise ValueError("agent_id is required")

    # Find the target lease
    row = None
    if lease_id:
        row = conn.execute(
            """SELECT * FROM dispatch_leases
               WHERE lease_id = ? AND status = 'active'""",
            (lease_id,),
        ).fetchone()
    elif worktree_path:
        row = conn.execute(
            """SELECT * FROM dispatch_leases
               WHERE worktree_path = ? AND status = 'active'""",
            (worktree_path,),
        ).fetchone()

    if row is None:
        return None

    target_lease_id = row["lease_id"]

    with conn:
        # Set agent_id on the target lease
        conn.execute(
            """UPDATE dispatch_leases SET agent_id = ? WHERE lease_id = ?""",
            (agent_id, target_lease_id),
        )
        # Revoke any other active lease for this agent_id (agent uniqueness)
        _revoke_active_for_agent(conn, agent_id, target_lease_id)

    return get(conn, target_lease_id)


def get(conn: sqlite3.Connection, lease_id: str) -> Optional[dict]:
    """Direct lookup by primary key. Returns lease dict or None."""
    row = conn.execute(
        """SELECT * FROM dispatch_leases WHERE lease_id = ?""",
        (lease_id,),
    ).fetchone()
    return _row_to_dict(row) if row else None


def get_current(
    conn: sqlite3.Connection,
    lease_id: Optional[str] = None,
    worktree_path: Optional[str] = None,
    agent_id: Optional[str] = None,
    workflow_id: Optional[str] = None,
) -> Optional[dict]:
    """Resolve the current active lease. Resolution priority:
    lease_id > agent_id > worktree_path > workflow_id.

    Only returns status='active' leases. Returns None when no active
    lease matches any of the provided identifiers.
    """
    row = None

    if lease_id:
        row = conn.execute(
            """SELECT * FROM dispatch_leases
               WHERE lease_id = ? AND status = 'active'""",
            (lease_id,),
        ).fetchone()
    elif agent_id:
        row = conn.execute(
            """SELECT * FROM dispatch_leases
               WHERE agent_id = ? AND status = 'active'""",
            (agent_id,),
        ).fetchone()
    elif worktree_path:
        row = conn.execute(
            """SELECT * FROM dispatch_leases
               WHERE worktree_path = ? AND status = 'active'""",
            (worktree_path,),
        ).fetchone()
    elif workflow_id:
        row = conn.execute(
            """SELECT * FROM dispatch_leases
               WHERE workflow_id = ? AND status = 'active'""",
            (workflow_id,),
        ).fetchone()

    return _row_to_dict(row) if row else None


def validate_op(
    conn: sqlite3.Connection,
    command: str,
    lease_id: Optional[str] = None,
    worktree_path: Optional[str] = None,
    agent_id: Optional[str] = None,
    workflow_id: Optional[str] = None,
) -> dict:
    """Validate whether a git command is permitted under the active lease.

    ALWAYS classifies the command first (even when no lease exists) and
    includes op_class in the result. This lets guard.sh make the
    routine_local exception decision without a second classifier call.

    Return contract:
      {
        "allowed": bool,
        "reason": str,
        "lease_id": str | None,
        "role": str | None,
        "workflow_id": str | None,
        "op_class": "routine_local" | "high_risk" | "unclassified",
        "requires_eval": bool,
        "eval_ok": bool | None,
        "requires_approval": bool,
        "approval_ok": bool | None,
      }

    When no lease is found: allowed=False with op_class populated.
    When lease found: sole authority — checks allowed_ops, blocked_ops,
      worktree match, eval state (for routine_local), approvals (for high_risk).
    """
    # Step 1: classify regardless of lease existence
    op_class = classify_git_op(command)

    base = {
        "allowed": False,
        "reason": "",
        "lease_id": None,
        "role": None,
        "workflow_id": None,
        "op_class": op_class,
        "requires_eval": False,
        "eval_ok": None,
        "requires_approval": False,
        "approval_ok": None,
    }

    # Step 2: find active lease
    lease = get_current(
        conn,
        lease_id=lease_id,
        worktree_path=worktree_path,
        agent_id=agent_id,
        workflow_id=workflow_id,
    )

    if lease is None:
        wt_desc = worktree_path or agent_id or workflow_id or lease_id or "unknown"
        base["reason"] = f"no active lease for worktree {wt_desc}"
        base["lease_id"] = None
        return base

    # Lease found — populate base fields
    base["lease_id"] = lease["lease_id"]
    base["role"] = lease["role"]
    base["workflow_id"] = lease["workflow_id"]
    base["requires_eval"] = bool(lease.get("requires_eval", 1))

    # Step 3: worktree_path match check
    # Only enforce when BOTH the lease has a worktree_path AND the caller provided one
    lease_wt = lease.get("worktree_path")
    if lease_wt and worktree_path and lease_wt != worktree_path:
        base["reason"] = (
            f"lease worktree_path '{lease_wt}' does not match "
            f"requested worktree_path '{worktree_path}'"
        )
        return base

    # Step 4: op_class allowed/blocked check
    allowed_ops = lease.get("allowed_ops", ["routine_local"])
    blocked_ops = lease.get("blocked_ops", [])

    if op_class in blocked_ops:
        base["reason"] = f"op '{op_class}' is in blocked_ops for this lease"
        return base

    if op_class not in allowed_ops:
        base["reason"] = f"op '{op_class}' is not in allowed_ops {allowed_ops} for this lease"
        return base

    # Step 5: eval readiness check (for routine_local ops with requires_eval)
    eval_ok = None
    if base["requires_eval"] and op_class == "routine_local":
        lw = lease.get("workflow_id")
        if lw:
            eval_row = evaluation_mod.get(conn, lw)
            if eval_row and eval_row.get("status") == "ready_for_guardian":
                eval_ok = True
            else:
                eval_ok = False
                eval_status = eval_row.get("status", "idle") if eval_row else "idle"
                base["eval_ok"] = eval_ok
                base["reason"] = f"evaluation_state is '{eval_status}', need 'ready_for_guardian'"
                return base
        else:
            # No workflow_id on lease — cannot check eval; treat as ok
            eval_ok = True
    base["eval_ok"] = eval_ok

    # Step 6: approval check for high_risk ops (read-only — does NOT consume)
    approval_ok = None
    requires_approval = False
    if op_class == "high_risk":
        requires_approval = True
        lw = lease.get("workflow_id")
        if lw:
            # Check for any pending approval for this workflow (read-only list)
            pending = approvals_mod.list_pending(conn, lw)
            approval_ok = len(pending) > 0
        else:
            # No workflow_id — cannot check approvals; treat as no approval
            approval_ok = False

        if not approval_ok:
            base["requires_approval"] = requires_approval
            base["approval_ok"] = approval_ok
            base["reason"] = (
                "high_risk op requires an unconsumed approval token "
                "(cc-policy approval grant <workflow_id> <op_type>)"
            )
            return base

    base["requires_approval"] = requires_approval
    base["approval_ok"] = approval_ok
    base["allowed"] = True
    base["reason"] = "allowed"
    return base


def list_leases(
    conn: sqlite3.Connection,
    status: Optional[str] = None,
    workflow_id: Optional[str] = None,
    role: Optional[str] = None,
    worktree_path: Optional[str] = None,
) -> list[dict]:
    """Return a filtered list of leases as dicts with parsed JSON columns."""
    clauses = []
    params = []

    if status is not None:
        clauses.append("status = ?")
        params.append(status)
    if workflow_id is not None:
        clauses.append("workflow_id = ?")
        params.append(workflow_id)
    if role is not None:
        clauses.append("role = ?")
        params.append(role)
    if worktree_path is not None:
        clauses.append("worktree_path = ?")
        params.append(worktree_path)

    where = ("WHERE " + " AND ".join(clauses)) if clauses else ""
    rows = conn.execute(
        f"SELECT * FROM dispatch_leases {where} ORDER BY issued_at DESC",
        params,
    ).fetchall()
    return [_row_to_dict(r) for r in rows]


def release(conn: sqlite3.Connection, lease_id: str) -> bool:
    """Transition lease from active → released. Returns True if transitioned."""
    now = int(time.time())
    with conn:
        cursor = conn.execute(
            """UPDATE dispatch_leases
               SET status = 'released', released_at = ?
               WHERE lease_id = ? AND status = 'active'""",
            (now, lease_id),
        )
    return cursor.rowcount > 0


def revoke(conn: sqlite3.Connection, lease_id: str) -> bool:
    """Transition lease from active → revoked. Returns True if transitioned."""
    now = int(time.time())
    with conn:
        cursor = conn.execute(
            """UPDATE dispatch_leases
               SET status = 'revoked', released_at = ?
               WHERE lease_id = ? AND status = 'active'""",
            (now, lease_id),
        )
    return cursor.rowcount > 0


def expire_stale(conn: sqlite3.Connection, now: Optional[int] = None) -> int:
    """Expire active leases whose expires_at is in the past.

    Transitions active leases past their TTL to 'expired' status.
    Returns the count of leases transitioned.
    Called by session-init.sh on every session start to clean up
    leases from crashed or abandoned agents.
    """
    if now is None:
        now = int(time.time())
    with conn:
        cursor = conn.execute(
            """UPDATE dispatch_leases
               SET status = 'expired', released_at = ?
               WHERE status = 'active' AND expires_at < ?""",
            (now, now),
        )
    return cursor.rowcount


def summary(
    conn: sqlite3.Connection,
    worktree_path: Optional[str] = None,
    workflow_id: Optional[str] = None,
) -> dict:
    """Return a compact read model of lease state.

    Suitable for context injection and status display. Shows the active
    lease (if any) plus counts by status for the given scope.
    """
    filters = {}
    if worktree_path:
        filters["worktree_path"] = worktree_path
    if workflow_id:
        filters["workflow_id"] = workflow_id

    active = get_current(
        conn,
        worktree_path=worktree_path,
        workflow_id=workflow_id,
    )

    # Count by status for the scope
    all_leases = list_leases(conn, worktree_path=worktree_path, workflow_id=workflow_id)
    counts: dict[str, int] = {}
    for lz in all_leases:
        s = lz.get("status", "unknown")
        counts[s] = counts.get(s, 0) + 1

    return {
        "active_lease": active,
        "counts_by_status": counts,
        "worktree_path": worktree_path,
        "workflow_id": workflow_id,
    }


def render_startup_contract(lease: dict) -> str:
    """Render a human-readable startup contract text block from a lease dict.

    The orchestrator pastes this into the agent prompt. Format mirrors
    the plan's startup_contract field example for consistency.
    """
    import datetime

    lines = [f"LEASE_ID={lease.get('lease_id', 'unknown')}"]
    lines.append(f"Role: {lease.get('role', 'unknown')}")

    wf = lease.get("workflow_id")
    if wf:
        lines.append(f"Workflow: {wf}")

    wt = lease.get("worktree_path")
    if wt:
        lines.append(f"Worktree: {wt}")

    branch = lease.get("branch")
    if branch:
        lines.append(f"Branch: {branch}")

    allowed = lease.get("allowed_ops", ["routine_local"])
    if isinstance(allowed, list):
        lines.append(f"Allowed ops: {', '.join(allowed)}")

    blocked = lease.get("blocked_ops", [])
    if blocked:
        lines.append(f"Blocked ops: {', '.join(blocked)}")

    ns = lease.get("next_step")
    if ns:
        lines.append(f"Next step: {ns}")

    expires_at = lease.get("expires_at")
    if expires_at:
        try:
            dt = datetime.datetime.fromtimestamp(expires_at, tz=datetime.timezone.utc)
            lines.append(f"Expires: {dt.strftime('%Y-%m-%dT%H:%M:%SZ')}")
        except (ValueError, OSError):
            lines.append(f"Expires: {expires_at}")

    return "\n".join(lines)
