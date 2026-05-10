"""Agent marker authority.

Owns the agent_markers table. Tracks which agent roles are active at any
point in time. Supersedes the flat-file .subagent-tracker mechanism
(DEC-SUBAGENT-001) once TKT-007 lands.

@decision DEC-RT-001
Title: Canonical SQLite schema for all shared workflow state
Status: accepted
Rationale: agent_markers replaces .subagent-tracker flat-file coordination.
  The is_active flag lets queries find the current active marker without
  scanning all rows. deactivate() sets stopped_at and clears is_active in
  a single transaction so there is never a window where a marker is
  stopped but still appears active.

@decision DEC-CONV-002
Title: Marker authority scoped by project_root and workflow_id (W-CONV-2)
Status: accepted
Rationale: Before W-CONV-2, get_active() returned the globally newest active
  marker with no project or workflow scoping. Explore/Bash/general-purpose
  agents also created markers, so the "newest active" could be a lightweight
  agent that was never deactivated, silently overriding the real
  implementer/reviewer/guardian role in build_context().

  Three changes fix this:
  1. set_active() now accepts optional project_root and workflow_id and
     persists them to the new project_root column added by the schemas.py
     migration. Callers that do not pass these (lifecycle.py before W-CONV-2
     callers, statusline) continue to work — the columns default to NULL.
  2. get_active() accepts optional project_root and workflow_id. When either
     is provided the SQL WHERE clause is narrowed to only rows that match.
     If scoping params are given and no row matches, None is returned — there
     is no global fallback when scoping is requested.
  3. get_active() without params retains the original unscoped behaviour
     (newest active globally) for backward compatibility with statusline.py
     which does not have a per-project context.

  The subagent-start.sh filter (change 4 in DEC-CONV-002) prevents
  lightweight agents from ever writing markers in the first place, but the
  cleanup migration in schemas.py handles accumulated ghost markers from
  before the filter was deployed.

@decision DEC-CLAUDEX-HARNESS-AGENT-ID-SOLE-IDENTITY-AUTHORITY-001
Title: One-active-marker-per-project-workflow invariant (Part A — supersede scope)
Status: accepted
Rationale: Bug A: set_active formerly scoped its supersede UPDATE by
  (role, project_root, workflow_id). This left prior markers of OTHER roles
  with is_active=1 in the same project+workflow. A new guardian:land seating
  did NOT deactivate a prior reviewer or implementer marker for the same
  workflow, causing multiple active markers to coexist. markers.get_active()
  then returned whichever had the latest started_at — NOT necessarily the
  live harness agent.

  Fix (conditional supersede — two paths):

  Path A — Scoped caller (project_root is not None): the supersede UPDATE
  removes the `role = ?` discriminator, retaining only
  (project_root, workflow_id, agent_id <> ?) as the scope. This enforces
  the invariant: at most one active marker per (project_root, workflow_id)
  at any time. Sequential dispatch — planner → guardian:provision →
  implementer → reviewer → guardian:land — is the only production pattern
  within a single workflow; each SubagentStart supersedes the prior stage's
  marker for that workflow. This is the P1-relevant path: real harness
  seating always provides project_root.

  Path B — Unscoped caller (project_root is None AND workflow_id is None):
  retains the legacy role-scoped supersede (`role = ?` is kept). Callers
  such as statusline.py that do not supply a project context create
  informational-only markers. Different roles in this context-less space are
  intentionally independent — expire_stale must be able to age out old
  markers without a newer different-role marker having already converted them
  to 'replaced'. Keeping role-scoped supersede here preserves that behavior.

  Multi-workflow independence is preserved: markers in the same project_root
  but different workflow_ids are NOT superseded by each other, consistent
  with the pre-existing test_markers.py scoping behaviour.

  The INSERT/ON CONFLICT block (upsert semantics for same agent_id restarts)
  is unchanged. Only the preceding supersede UPDATE WHERE clauses change.
"""

from __future__ import annotations

import sqlite3
import time
from typing import Optional


def _row_to_dict(row: sqlite3.Row) -> dict:
    return dict(row)


def set_active(
    conn: sqlite3.Connection,
    agent_id: str,
    role: str,
    project_root: str | None = None,
    workflow_id: str | None = None,
) -> None:
    """Upsert an active marker for agent_id with the given role.

    Any existing marker for this agent_id is replaced (PRIMARY KEY conflict).
    started_at is always reset to now on upsert so restarts are tracked.
    status is set to 'active' on upsert.

    Args:
        conn:         Open SQLite connection with schema applied.
        agent_id:     Unique agent identifier (e.g. session UUID or pid).
        role:         Role string (implementer, reviewer, guardian, planner).
        project_root: Optional canonical project root path (normalize_path applied
                      by caller before passing). Stored in the project_root column
                      so get_active(project_root=X) can filter to this project.
        workflow_id:  Optional workflow identifier matching workflow_bindings.
                      Stored alongside project_root for fine-grained scoping.
    """
    now = int(time.time())
    # DEC-CLAUDEX-HARNESS-AGENT-ID-SOLE-IDENTITY-AUTHORITY-001 (Part A):
    # Conditional supersede scope — see @decision block at top of module.
    #
    # Path A (project_root is not None — real harness seating): drop `role = ?`
    # so the new stage supersedes ALL prior active markers for this
    # project+workflow, regardless of role. Enforces the one-active-per-workflow
    # invariant on the P1-relevant sequential dispatch chain.
    #
    # Path B (project_root is None AND workflow_id is None — legacy/statusline
    # context-less callers): keep `role = ?` so different-role markers remain
    # independent. expire_stale must still find and age out old-role markers
    # when a newer different-role marker is present; converting them to
    # 'replaced' here would hide them from expire_stale's 'active' filter.
    clauses = ["is_active = 1", "agent_id <> ?"]
    params: list[object] = [agent_id]
    unscoped = project_root is None and workflow_id is None
    if unscoped:
        # Path B: legacy context-less caller — keep role-scoped supersede.
        clauses.append("role = ?")
        params.append(role)
        clauses.append("project_root IS NULL")
        clauses.append("workflow_id IS NULL")
    else:
        # Path A: scoped caller — project-scoped supersede (no role filter).
        if project_root is None:
            clauses.append("project_root IS NULL")
        else:
            clauses.append("project_root = ?")
            params.append(project_root)
        if workflow_id is None:
            clauses.append("workflow_id IS NULL")
        else:
            clauses.append("workflow_id = ?")
            params.append(workflow_id)
    where = " AND ".join(clauses)
    with conn:
        conn.execute(
            f"""
            UPDATE agent_markers
            SET    stopped_at = ?,
                   is_active  = 0,
                   status     = 'replaced'
            WHERE  {where}
            """,
            [now, *params],
        )
    with conn:
        conn.execute(
            """
            INSERT INTO agent_markers
                (agent_id, role, started_at, stopped_at, is_active, status,
                 project_root, workflow_id)
            VALUES (?, ?, ?, NULL, 1, 'active', ?, ?)
            ON CONFLICT(agent_id) DO UPDATE SET
                role         = excluded.role,
                started_at   = excluded.started_at,
                stopped_at   = NULL,
                is_active    = 1,
                status       = 'active',
                project_root = excluded.project_root,
                workflow_id  = excluded.workflow_id
            """,
            (agent_id, role, now, project_root, workflow_id),
        )


def get_active(
    conn: sqlite3.Connection,
    project_root: str | None = None,
    workflow_id: str | None = None,
    require_active_lease: bool = False,
) -> Optional[dict]:
    """Return the most recently started active marker, or None.

    When project_root and/or workflow_id are provided the query is scoped
    to only rows that match those values. If no matching row exists, None
    is returned — there is no global fallback when scoping params are given.

    When called with no params the original unscoped behaviour is preserved:
    the globally newest active marker is returned. This keeps backward
    compatibility for statusline.py which calls get_active_with_age(conn)
    without a project context.

    When require_active_lease=True the query LEFT JOINs dispatch_leases on
    agent_id and filters out any marker whose owning lease has been released,
    revoked, or expired (i.e. status != 'active'). Markers with no owning
    lease (NULL join) are still returned — they represent pre-lease-era or
    lifecycle.py-spawned agents that legitimately lack a lease row.

    This opt-in flag is the defense-in-depth complement to the Stop-hook
    deactivate path (DEC-LIFECYCLE-003). It defends against the
    dropped-Stop-signal failure class: a marker survives past its owning
    agent's lease release because the Stop hook never fired (yakcc#171).

    @decision DEC-IMPL-STOP-MARKER-001
    Title: Resolver-side lease-aware marker skip (Option B, yakcc#171)
    Status: accepted
    Rationale: Option A (Stop hook deactivate) is already implemented at
      hooks/check-implementer.sh via cc-policy lifecycle on-stop. It is
      fragile against the dropped-Stop-signal class: process kill, harness
      crash, or out-of-band lease release leave a marker with is_active=1
      even though the owning agent is gone. Option B adds a defense-in-depth
      read-side filter: LEFT JOIN dispatch_leases on agent_id, skip markers
      whose lease.status is not 'active'. Markers with no lease row (NULL
      join) pass through unchanged — they are legacy/lifecycle-path markers
      that legitimately lack a lease. The parameter defaults to False so
      existing callers (statusline.py, lifecycle.py, CLI) are unaffected;
      only policy_engine.py:build_context opts in (DEC-PE-EGAP-BUILD-CTX-001).
      Cross-reference: yakcc#171, DEC-IMPL-STOP-MARKER-002 (test file).

    Args:
        conn:                Open SQLite connection with schema applied.
        project_root:        Optional canonical project root to scope the query.
        workflow_id:         Optional workflow_id to further scope within a project.
        require_active_lease: When True, skip markers whose owning lease is not
                             'active'. Defaults to False for backward compatibility.
    """
    if require_active_lease and project_root is None and workflow_id is None:
        raise ValueError(
            "require_active_lease=True requires project_root or workflow_id scope "
            "(see DEC-IMPL-STOP-MARKER-001 — the lease JOIN requires a scope to avoid "
            "cross-project pollution)"
        )

    if project_root is not None or workflow_id is not None:
        # Scoped query — build WHERE clauses dynamically for the provided params.
        # Only include workflow_id predicate when both are given; if only
        # workflow_id is given (unusual) scope by that alone.
        params: list = []
        if project_root is not None:
            params.append(project_root)
        if workflow_id is not None:
            params.append(workflow_id)

        if require_active_lease:
            # DEC-IMPL-STOP-MARKER-001: LEFT JOIN dispatch_leases on agent_id.
            # Skip markers whose lease exists AND is not 'active' (released,
            # revoked, expired). NULL-join rows (no lease) pass through — they
            # are pre-lease / lifecycle callers that legitimately lack a lease.
            # Raise on SQL error rather than silently falling back (Sacred #5).
            join_clauses = ["am.is_active = 1"]
            if project_root is not None:
                join_clauses.append("am.project_root = ?")
            if workflow_id is not None:
                join_clauses.append("am.workflow_id = ?")
            where = " AND ".join(join_clauses)
            row = conn.execute(
                f"""
                SELECT am.agent_id, am.role, am.started_at, am.stopped_at,
                       am.is_active, am.status, am.project_root, am.workflow_id
                FROM   agent_markers AS am
                LEFT JOIN dispatch_leases AS dl
                       ON dl.agent_id = am.agent_id
                WHERE  {where}
                  AND  (dl.agent_id IS NULL OR dl.status = 'active')
                ORDER  BY am.started_at DESC
                LIMIT  1
                """,
                params,
            ).fetchone()
        else:
            plain_clauses = ["is_active = 1"]
            if project_root is not None:
                plain_clauses.append("project_root = ?")
            if workflow_id is not None:
                plain_clauses.append("workflow_id = ?")
            where = " AND ".join(plain_clauses)
            row = conn.execute(
                f"""
                SELECT agent_id, role, started_at, stopped_at, is_active, status,
                       project_root, workflow_id
                FROM   agent_markers
                WHERE  {where}
                ORDER  BY started_at DESC
                LIMIT  1
                """,
                params,
            ).fetchone()
        return _row_to_dict(row) if row else None

    # Unscoped: return globally newest active marker (backward compat).
    # require_active_lease is not applied on the unscoped path — the lease JOIN
    # requires a project_root or workflow_id scope to avoid cross-project
    # pollution, and statusline.py (the only unscoped caller) intentionally
    # uses the global newest-active view.
    row = conn.execute(
        """
        SELECT agent_id, role, started_at, stopped_at, is_active, status,
               project_root, workflow_id
        FROM   agent_markers
        WHERE  is_active = 1
        ORDER  BY started_at DESC
        LIMIT  1
        """
    ).fetchone()
    return _row_to_dict(row) if row else None


def get_active_with_age(conn: sqlite3.Connection) -> Optional[dict]:
    """Return the active marker with computed age_seconds field.

    age_seconds = current_time - started_at. Returns None if no active marker.

    Called unscoped by statusline.py — backward-compatible with the no-params
    signature of get_active().

    @decision DEC-RT-023
    @title get_active_with_age computes marker age at read time
    @status accepted
    @rationale TKT-023 requires the statusline to display how long the current
      marker has been active so operators can detect stale subagent markers.
      Age is computed at read time (not stored) to avoid write-side churn on
      a hot read path. The max(0, ...) guard handles clock skew.
    """
    marker = get_active(conn)
    if marker is None:
        return None
    now = int(time.time())
    marker["age_seconds"] = max(0, now - (marker.get("started_at") or now))
    return marker


def deactivate(conn: sqlite3.Connection, agent_id: str) -> None:
    """Mark agent_id as stopped. No-op if agent_id is not found."""
    now = int(time.time())
    with conn:
        conn.execute(
            """
            UPDATE agent_markers
            SET    stopped_at = ?,
                   is_active  = 0,
                   status     = 'stopped'
            WHERE  agent_id   = ?
            """,
            (now, agent_id),
        )


def list_all(conn: sqlite3.Connection) -> list[dict]:
    """Return all agent_markers rows ordered by started_at descending."""
    rows = conn.execute(
        """
        SELECT agent_id, role, started_at, stopped_at, is_active, status,
               project_root, workflow_id
        FROM   agent_markers
        ORDER  BY started_at DESC
        """
    ).fetchall()
    return [_row_to_dict(r) for r in rows]


def expire_stale(
    conn: sqlite3.Connection,
    ttl: int = 7200,
    now: int | None = None,
) -> int:
    """Deactivate markers older than ttl seconds. Returns count expired.

    Transitions status from 'active' to 'expired' and clears is_active for
    any marker whose started_at is more than ttl seconds before now. This
    prevents ghost markers from crashed sessions blocking new dispatch.

    @decision DEC-STAB-A4-002
    Title: expire_stale uses started_at age rather than a separate expires_at
    Status: accepted
    Rationale: agent_markers has no expires_at column (unlike dispatch_leases).
      Using started_at + ttl as the expiry boundary avoids a schema migration
      that would require altering existing rows. The 2-hour default TTL matches
      DEFAULT_LEASE_TTL in schemas.py so marker and lease cleanup are aligned.
    """
    if now is None:
        now = int(time.time())
    cutoff = now - ttl
    with conn:
        cursor = conn.execute(
            """
            UPDATE agent_markers
            SET    status    = 'expired',
                   is_active = 0
            WHERE  status    = 'active'
              AND  started_at < ?
            """,
            (cutoff,),
        )
    return cursor.rowcount
