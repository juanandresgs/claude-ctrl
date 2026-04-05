"""Dispatch lease lifecycle authority.

@decision DEC-LEASE-001
Title: SQLite-backed dispatch leases bind agent identity to worktree + allowed ops
Status: accepted
Rationale: Subagents today rediscover identity from ambient state (markers, CWD
  inference). This produces wasted turns, partial completions treated as done,
  and no deterministic enforcement. A runtime-issued lease ties the agent role,
  worktree, workflow, allowed operations, and evaluation requirements into one
  durable record at dispatch time. validate_op() then gates git operations
  against the active lease rather than re-inferring from environment variables.

  Uniqueness invariants:
    - One active lease per worktree_path: issuing a new one revokes the old.
    - One active lease per agent_id: claiming revokes any other active lease
      held by the same agent (agents do not hold multiple leases).

  Lifecycle: active → released (normal completion) | revoked (superseded) |
             expired (TTL elapsed, detected by expire_stale).

  validate_op() never consumes approval tokens — it only peeks via list_pending.
  guard.sh Check 13 owns actual token consumption. This separation ensures
  validate_op is safe to call repeatedly without side effects.

  classify_git_op() is the sole Python-side git-command classifier. It is the
  migration target for the bash classifier in guard.sh Check 3. When hook
  wiring lands (Phase 2), guard.sh Check 3 will call this via cc-policy
  lease validate-op rather than inline bash regex.
"""

from __future__ import annotations

import json
import re
import sqlite3
import time
import uuid
from typing import Optional

from runtime.core.policy_utils import normalize_path  # DEC-CONV-001
from runtime.schemas import DEFAULT_LEASE_TTL

# ---------------------------------------------------------------------------
# Role-safe defaults
# ---------------------------------------------------------------------------

# @decision DEC-LEASE-003
# Title: ROLE_DEFAULTS is the single source of per-role allowed_ops and requires_eval defaults
# Status: accepted
# Rationale: Callers of issue() should not need to know what ops each role needs.
#   ROLE_DEFAULTS encodes the role→ops mapping in one place. Unknown roles fall
#   back to ["routine_local"] for safety. Explicit allowed_ops parameter overrides
#   the defaults when the caller has a reason.

ROLE_DEFAULTS: dict[str, dict] = {
    "implementer": {"allowed_ops": ["routine_local"], "requires_eval": True},
    "tester": {"allowed_ops": [], "requires_eval": False},
    "guardian": {
        "allowed_ops": ["routine_local", "high_risk", "admin_recovery"],
        "requires_eval": True,
    },
    "planner": {"allowed_ops": [], "requires_eval": False},
}


# ---------------------------------------------------------------------------
# Classifier
# ---------------------------------------------------------------------------


def _strip_git_paths(command: str) -> str:
    """Strip path arguments from git commands to prevent false subcommand matches.

    Removes:
      - git -C <path> → git
      - cd <path> && → (empty)
      - Quoted paths after -C

    This prevents paths like '/path/feature-rebase-w1' from matching
    subcommand patterns like \\brebase\\b.
    """
    # Strip: git -C "/path/..." or git -C '/path/...' or git -C /path/...
    result = re.sub(r'\bgit\s+-C\s+("([^"]+)"|\'([^\']+)\'|(\S+))', "git", command)
    # Strip: cd "/path" && or cd '/path' && or cd /path &&
    result = re.sub(r'\bcd\s+("([^"]+)"|\'([^\']+)\'|(\S+))\s*&&\s*', "", result)
    return result


def classify_git_op(command: str) -> str:
    """Classify a git command string into an operation class.

    Returns one of: "routine_local", "high_risk", "admin_recovery",
    "unclassified".

    This is the sole classifier for the migrated Check 3 path. Word-boundary
    matching prevents substring false positives (e.g. 'git remote' does not
    match 'git reset'). Path arguments are stripped first to prevent false
    matches on path components (e.g. '/path/feature-rebase-w1' should not
    trigger the rebase classifier).

    Classification precedence (first match wins):
      admin_recovery: merge --abort, reset --merge (governed recovery, not landing)
      high_risk:      push, rebase, reset, merge --no-ff
      routine_local:  commit, merge (without --no-ff)
      unclassified:   everything else

    @decision DEC-LEASE-002
    Title: admin_recovery op class exempts merge --abort / reset --merge from
           evaluation-readiness gate
    Status: accepted
    Rationale: merge --abort and reset --merge are governed administrative recovery
      operations — they undo an in-progress merge, not land new code. Requiring
      evaluation_state=ready_for_guardian for these operations is wrong because
      there is no "feature" to evaluate; the purpose is to return the repo to a
      clean state. They still require a lease and an approval token (same model as
      high_risk), but bypass Check 10's eval-readiness gate. The admin_recovery
      class is checked BEFORE the generic reset/merge patterns so the specific
      variants win over the broader classification.
    """
    # Strip path arguments to prevent false subcommand matches
    cmd = _strip_git_paths(command)

    # Admin recovery: merge --abort (governed recovery, not a landing operation)
    if re.search(r"\bmerge\b.*--abort", cmd):
        return "admin_recovery"
    # Admin recovery: reset --merge (backed-out merge recovery)
    if re.search(r"\breset\b.*--merge", cmd):
        return "admin_recovery"
    # High-risk: push
    if re.search(r"\bpush\b", cmd):
        return "high_risk"
    # High-risk: rebase
    if re.search(r"\brebase\b", cmd):
        return "high_risk"
    # High-risk: reset (any form not already caught by admin_recovery above)
    if re.search(r"\breset\b", cmd):
        return "high_risk"
    # High-risk: merge --no-ff (must check before plain merge)
    if re.search(r"\bmerge\b", cmd) and "--no-ff" in cmd:
        return "high_risk"
    # Routine local: commit
    if re.search(r"\bcommit\b", cmd):
        return "routine_local"
    # Routine local: merge (without --no-ff already handled above)
    if re.search(r"\bmerge\b", cmd):
        return "routine_local"
    return "unclassified"


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _row_to_dict(row: sqlite3.Row) -> dict:
    return dict(row)


def _revoke_active_for_worktree(conn: sqlite3.Connection, worktree_path: str, now: int) -> None:
    """Revoke any active leases for worktree_path (called inside an open transaction)."""
    conn.execute(
        """UPDATE dispatch_leases
           SET status = 'revoked', released_at = ?
           WHERE worktree_path = ? AND status = 'active'""",
        (now, worktree_path),
    )


def _revoke_active_for_agent(conn: sqlite3.Connection, agent_id: str, now: int) -> None:
    """Revoke any active leases for agent_id (called inside an open transaction)."""
    conn.execute(
        """UPDATE dispatch_leases
           SET status = 'revoked', released_at = ?
           WHERE agent_id = ? AND status = 'active'""",
        (now, agent_id),
    )


def _fetch_active(conn: sqlite3.Connection, **filters) -> Optional[sqlite3.Row]:
    """Fetch first active lease matching the given column=value filters.

    worktree_path is normalized via normalize_path() (DEC-CONV-001) before
    the SQL WHERE comparison, so raw symlink paths match normalized stored values.
    """
    clauses = ["status = 'active'"]
    params = []
    for col, val in filters.items():
        # DEC-CONV-001: normalize worktree_path at every query boundary so that
        # raw paths (e.g. /var/... on macOS) match stored canonical realpaths.
        if col == "worktree_path" and val is not None:
            val = normalize_path(val)
        clauses.append(f"{col} = ?")
        params.append(val)
    sql = f"SELECT * FROM dispatch_leases WHERE {' AND '.join(clauses)} LIMIT 1"
    return conn.execute(sql, params).fetchone()


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
    approval_scope: Optional[list] = None,
    next_step: Optional[str] = None,
    ttl: int = DEFAULT_LEASE_TTL,
    metadata: Optional[dict] = None,
) -> dict:
    """Issue a new dispatch lease for a role.

    If worktree_path is provided, any existing active lease for that path is
    revoked within the same transaction (one-active-per-worktree invariant).
    Returns the full lease row as a dict.

    worktree_path is normalized via normalize_path() (DEC-CONV-001) before
    being stored. build_context() looks up active leases by worktree_path;
    if the stored path uses a different form (symlink vs realpath) than the
    lookup key the lease becomes invisible.
    """
    # DEC-CONV-001: normalize worktree_path to canonical realpath form.
    canonical_worktree = normalize_path(worktree_path) if worktree_path else worktree_path

    lease_id = uuid.uuid4().hex
    now = int(time.time())
    expires_at = now + ttl

    if allowed_ops is None:
        _defaults = ROLE_DEFAULTS.get(role, {})
        allowed_ops = _defaults.get("allowed_ops", ["routine_local"])
    if blocked_ops is None:
        blocked_ops = []

    allowed_ops_json = json.dumps(allowed_ops)
    blocked_ops_json = json.dumps(blocked_ops)
    approval_scope_json = json.dumps(approval_scope) if approval_scope is not None else None
    metadata_json = json.dumps(metadata) if metadata is not None else None

    with conn:
        # Enforce uniqueness: one active lease per worktree.
        if canonical_worktree:
            _revoke_active_for_worktree(conn, canonical_worktree, now)

        conn.execute(
            """INSERT INTO dispatch_leases (
                   lease_id, role, workflow_id, worktree_path, branch,
                   allowed_ops_json, blocked_ops_json, requires_eval,
                   head_sha, approval_scope_json, next_step,
                   status, issued_at, expires_at, metadata_json
               ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?, ?)""",
            (
                lease_id,
                role,
                workflow_id,
                canonical_worktree,
                branch,
                allowed_ops_json,
                blocked_ops_json,
                int(requires_eval),
                head_sha,
                approval_scope_json,
                next_step,
                now,
                expires_at,
                metadata_json,
            ),
        )

    return get(conn, lease_id)


def claim(
    conn: sqlite3.Connection,
    agent_id: str,
    lease_id: Optional[str] = None,
    worktree_path: Optional[str] = None,
    expected_role: Optional[str] = None,
) -> Optional[dict]:
    """Claim an active lease by associating agent_id with it.

    Lookup priority: lease_id > worktree_path.
    Any other active lease held by agent_id is revoked (one-lease-per-agent).
    Returns the claimed lease dict, or None if no active lease found.

    If expected_role is provided, the lease's role must match exactly. A
    mismatch returns None — this prevents a tester from claiming a guardian
    lease (DEC-LEASE-003).
    """
    now = int(time.time())

    # Find target lease
    # DEC-CONV-001: normalize worktree_path at query boundary so symlink paths
    # match stored canonical realpaths.
    canonical_worktree = normalize_path(worktree_path) if worktree_path else worktree_path

    target_row = None
    if lease_id:
        row = conn.execute(
            "SELECT * FROM dispatch_leases WHERE lease_id = ? AND status = 'active'",
            (lease_id,),
        ).fetchone()
        target_row = row
    elif canonical_worktree:
        target_row = _fetch_active(conn, worktree_path=canonical_worktree)

    if target_row is None:
        return None

    # Verify role matches expectation when specified (DEC-LEASE-003).
    if expected_role is not None and target_row["role"] != expected_role:
        return None

    target_lease_id = target_row["lease_id"]

    with conn:
        # Revoke any other active lease for this agent (excluding the target).
        conn.execute(
            """UPDATE dispatch_leases
               SET status = 'revoked', released_at = ?
               WHERE agent_id = ? AND status = 'active' AND lease_id != ?""",
            (now, agent_id, target_lease_id),
        )
        # Associate agent_id with the target lease.
        conn.execute(
            "UPDATE dispatch_leases SET agent_id = ? WHERE lease_id = ?",
            (agent_id, target_lease_id),
        )

    return get(conn, target_lease_id)


def get(conn: sqlite3.Connection, lease_id: str) -> Optional[dict]:
    """Direct lookup by lease_id. Returns dict or None."""
    row = conn.execute(
        "SELECT * FROM dispatch_leases WHERE lease_id = ?",
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
    """Resolve the active lease with priority: lease_id > agent_id > worktree_path > workflow_id.

    Only returns status='active' leases. Returns None if no active lease found
    for any of the supplied identifiers.

    worktree_path is normalized via normalize_path() (DEC-CONV-001) before the
    SQL WHERE comparison so that raw symlink paths (e.g. /var/... on macOS) match
    the canonical realpaths stored by issue().
    """
    # DEC-CONV-001: normalize worktree_path at every query boundary.
    canonical_worktree = normalize_path(worktree_path) if worktree_path else worktree_path

    row = None
    if lease_id:
        row = conn.execute(
            "SELECT * FROM dispatch_leases WHERE lease_id = ? AND status = 'active'",
            (lease_id,),
        ).fetchone()
    if row is None and agent_id:
        row = _fetch_active(conn, agent_id=agent_id)
    if row is None and canonical_worktree:
        row = _fetch_active(conn, worktree_path=canonical_worktree)
    if row is None and workflow_id:
        row = _fetch_active(conn, workflow_id=workflow_id)
    return _row_to_dict(row) if row else None


def validate_op(
    conn: sqlite3.Connection,
    command: str,
    lease_id: Optional[str] = None,
    worktree_path: Optional[str] = None,
    agent_id: Optional[str] = None,
    workflow_id: Optional[str] = None,
) -> dict:
    """Composite validation of a git command against the active lease.

    Always returns a dict with the full validation surface. Does NOT consume
    approval tokens — only peeks via list_pending. guard.sh Check 13 owns
    token consumption.

    Return keys:
      allowed          bool  — True only when all applicable checks pass
      reason           str   — human-readable explanation
      lease_id         str|None
      role             str|None
      workflow_id      str|None
      op_class         str   — always present: routine_local|high_risk|unclassified
      requires_eval    bool
      eval_ok          bool|None  — None when eval check not applicable
      requires_approval bool
      approval_ok      bool|None  — None when approval check not applicable
    """
    import runtime.core.approvals as approvals_mod
    import runtime.core.evaluation as evaluation_mod

    op_class = classify_git_op(command)

    result = {
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

    # Resolve active lease.
    lease = get_current(
        conn,
        lease_id=lease_id,
        worktree_path=worktree_path,
        agent_id=agent_id,
        workflow_id=workflow_id,
    )

    if lease is None:
        result["reason"] = "no active lease found"
        return result

    # Check lease is not expired (get_current only returns status=active, but
    # expire_stale may not have run yet — check expires_at defensively).
    now = int(time.time())
    if lease["expires_at"] < now:
        result["reason"] = "lease has expired"
        return result

    result["lease_id"] = lease["lease_id"]
    result["role"] = lease["role"]
    result["workflow_id"] = lease["workflow_id"]
    result["requires_eval"] = bool(lease["requires_eval"])

    # Deserialise allowed/blocked op lists.
    try:
        allowed_ops = json.loads(lease["allowed_ops_json"] or "[]")
        blocked_ops = json.loads(lease["blocked_ops_json"] or "[]")
    except (json.JSONDecodeError, TypeError):
        allowed_ops = ["routine_local"]
        blocked_ops = []

    # Check op is permitted by the lease.
    if op_class in blocked_ops:
        result["reason"] = f"op_class '{op_class}' is in blocked_ops"
        return result
    if op_class not in allowed_ops:
        result["reason"] = f"op_class '{op_class}' not in allowed_ops {allowed_ops}"
        return result

    # Eval check (when requires_eval and op is not unclassified or admin_recovery).
    # admin_recovery (merge --abort, reset --merge) skips the eval gate because
    # these are governed recovery operations, not landing operations — there is no
    # feature to evaluate. They still require a lease and approval token (below).
    eval_ok = None
    if lease["requires_eval"] and op_class not in ("unclassified", "admin_recovery"):
        wf_id = lease["workflow_id"]
        if wf_id:
            eval_state = evaluation_mod.get(conn, wf_id)
            if (
                eval_state is not None
                and eval_state.get("status") == "ready_for_guardian"
                and (lease["head_sha"] is None or eval_state.get("head_sha") == lease["head_sha"])
            ):
                eval_ok = True
            else:
                eval_ok = False
        else:
            # No workflow_id on lease — cannot check eval, treat as ok.
            eval_ok = True

    result["eval_ok"] = eval_ok

    if eval_ok is False:
        result["reason"] = "evaluation_state is not ready_for_guardian (or SHA mismatch)"
        return result

    # Approval check: high_risk AND admin_recovery both require an unconsumed token.
    # admin_recovery shares the approval requirement with high_risk because these
    # operations (merge --abort, reset --merge) are still significant repo-state
    # changes that must be explicitly sanctioned — just not evaluated for code quality.
    requires_approval = op_class in ("high_risk", "admin_recovery")
    result["requires_approval"] = requires_approval
    approval_ok = None

    if requires_approval:
        wf_id = lease["workflow_id"]
        pending = approvals_mod.list_pending(conn, workflow_id=wf_id)
        # Map op_class to the approval op_type we'd look for.
        # high_risk and admin_recovery ops may have different sub-types;
        # for now we accept any pending token for the workflow.
        approval_ok = len(pending) > 0

    result["approval_ok"] = approval_ok

    if requires_approval and not approval_ok:
        result["reason"] = "op requires an unconsumed approval token (high_risk or admin_recovery)"
        return result

    result["allowed"] = True
    result["reason"] = "ok"
    return result


def list_leases(
    conn: sqlite3.Connection,
    status: Optional[str] = None,
    workflow_id: Optional[str] = None,
    role: Optional[str] = None,
    worktree_path: Optional[str] = None,
) -> list[dict]:
    """List leases with optional filters, ordered by issued_at DESC.

    worktree_path is normalized via normalize_path() (DEC-CONV-001) before
    the SQL WHERE comparison so raw symlink paths match stored canonical realpaths.
    """
    # DEC-CONV-001: normalize worktree_path at query boundary.
    canonical_worktree = normalize_path(worktree_path) if worktree_path else worktree_path

    clauses = []
    params = []
    if status:
        clauses.append("status = ?")
        params.append(status)
    if workflow_id:
        clauses.append("workflow_id = ?")
        params.append(workflow_id)
    if role:
        clauses.append("role = ?")
        params.append(role)
    if canonical_worktree:
        clauses.append("worktree_path = ?")
        params.append(canonical_worktree)

    where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
    rows = conn.execute(
        f"SELECT * FROM dispatch_leases {where} ORDER BY issued_at DESC",
        params,
    ).fetchall()
    return [_row_to_dict(r) for r in rows]


def release(conn: sqlite3.Connection, lease_id: str) -> bool:
    """Transition active → released. Returns True if updated, False otherwise."""
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
    """Transition active → revoked. Returns True if updated, False otherwise."""
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
    """Transition all active leases past their expires_at to status='expired'.

    Returns the count of leases that were expired.
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
    """Compact read model: active_lease, recent_leases (last 5), has_active.

    worktree_path is normalized via normalize_path() (DEC-CONV-001) before
    any SQL filtering so raw symlink paths match stored canonical realpaths.
    """
    # DEC-CONV-001: normalize worktree_path at query boundary.
    canonical_worktree = normalize_path(worktree_path) if worktree_path else worktree_path

    active = get_current(conn, worktree_path=canonical_worktree, workflow_id=workflow_id)

    # Recent leases (last 5) filtered by supplied context.
    clauses = []
    params = []
    if canonical_worktree:
        clauses.append("worktree_path = ?")
        params.append(canonical_worktree)
    if workflow_id:
        clauses.append("workflow_id = ?")
        params.append(workflow_id)
    where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
    recent_rows = conn.execute(
        f"SELECT * FROM dispatch_leases {where} ORDER BY issued_at DESC LIMIT 5",
        params,
    ).fetchall()

    return {
        "active_lease": active,
        "recent_leases": [_row_to_dict(r) for r in recent_rows],
        "has_active": active is not None,
    }


def render_startup_contract(lease: dict) -> str:
    """Render a human-readable text block from a lease dict.

    Used by the CLI to print context for the agent at dispatch time.
    """
    import datetime

    expires_dt = datetime.datetime.fromtimestamp(
        lease.get("expires_at", 0), tz=datetime.timezone.utc
    ).isoformat()

    try:
        allowed_ops = json.loads(lease.get("allowed_ops_json") or "[]")
        allowed_str = ", ".join(allowed_ops) if allowed_ops else "(none)"
    except (json.JSONDecodeError, TypeError):
        allowed_str = "(parse error)"

    return (
        f"LEASE_ID={lease.get('lease_id', '')}\n"
        f"Role: {lease.get('role', '')}\n"
        f"Workflow: {lease.get('workflow_id', '')}\n"
        f"Worktree: {lease.get('worktree_path', '')}\n"
        f"Branch: {lease.get('branch', '')}\n"
        f"Allowed ops: {allowed_str}\n"
        f"Next step: {lease.get('next_step', '')}\n"
        f"Expires: {expires_dt}"
    )
