# @decision DEC-CRITIC-CONTEXT-001
# Title: runtime/core/critic_context.py is the single authority for implementer critic context resolution
# Status: accepted
# Rationale: Both hooks/implementer-critic.sh and sidecars/codex-review/scripts/implementer-critic-hook.mjs
#   independently derived workflow_id and lease_id from detect_project_root / CLAUDE_PROJECT_DIR —
#   both of which resolve to the ORCHESTRATOR's project root (not the implementer's) when SubagentStop
#   fires. The hook input JSON carries the implementer's actual cwd in input.cwd and the implementer's
#   agent_id in input.agent_id. This module is the single authority that reads those fields and
#   resolves the correct implementer workflow_id + lease_id by: (1) agent_id first (including
#   recently-released/revoked leases within RECENT_LEASE_TTL_SECONDS), (2) input.cwd as worktree_path
#   fallback. Deleting the parallel inline resolution paths in both callers ensures there is exactly
#   one place to fix if the resolution logic ever needs to change.
#   Alternatives considered: fixing each caller inline — rejected because two copies diverge silently;
#   deriving workflow_id from git branch name when input.cwd is available — forbidden per spec (no
#   current_workflow_id fallback when input.cwd is present); adding get_recent_by_agent_id to
#   leases.py — rejected because leases.get_current semantics (active-only) must remain stable for
#   all other callers; the widening is local to this module only.
#
# @decision DEC-CRITIC-FAIL-CLOSED-001
# Title: Critic context resolver widens agent_id lookup to recently-released/revoked leases
# Status: accepted
# Rationale: By the time SubagentStop fires for an implementer, the harness has already revoked the
#   implementer lease (status transitions active → revoked/released before the stop hook runs).
#   leases.get_current() hardcodes status='active', so it misses the revoked lease even though the
#   agent_id is unique and unambiguous. The fix is a local SQL widening in critic_context.py only —
#   NOT in leases.get_current — using a 300-second TTL window: any lease with the matching agent_id
#   AND (status='active' OR (status IN ('released','revoked') AND released_at >= now-300)) is
#   considered. This preserves leases domain semantics (all other callers stay active-only) while
#   allowing the critic to correctly resolve the implementer lease after revocation.
#
# @decision DEC-CRITIC-FAIL-CLOSED-002
# Title: Critic context not-found returns found=false with no workflow_id fallback
# Status: accepted
# Rationale: When neither agent_id nor cwd resolves a lease, critic_context.resolve() returns
#   found=false with empty workflow_id. Callers (bash wrapper + Node sidecar) MUST emit
#   CRITIC_UNAVAILABLE using the "__unresolved__" sentinel rather than falling back to git branch
#   names. A branch-name fallback silently tags critic_reviews rows with wrong workflow_ids
#   (e.g. 'main' for the orchestrator session), making routing verdicts unroutable and breaking
#   the dispatch_engine correlation. Loud failure (CRITIC_UNAVAILABLE) is correct behavior here.
"""Implementer critic context resolver — single authority.

Resolves the correct workflow_id and lease_id for a critic review row
from the SubagentStop hook input JSON. Called by both bash and Node
wrappers via ``cc-policy critic context resolve --hook-input <json>``
so there is one code path to maintain.

Resolution priority:
  1. ``agent_id`` from hook input -> recently-released/revoked implementer lease
     (within RECENT_LEASE_TTL_SECONDS) — covers the post-revocation window when
     SubagentStop fires after the harness already revoked the lease.
  2. ``cwd`` from hook input   -> ``leases.get_current(worktree_path=...)``
  3. ``worktree_path`` from env / supplied arg

CRITIC_UNAVAILABLE is returned in the result dict (not raised) when
neither identifier resolves an implementer lease. Callers MUST surface
CRITIC_UNAVAILABLE rather than silently falling back to a guessed workflow_id
(e.g. a git branch name). See DEC-CRITIC-FAIL-CLOSED-002.
"""

from __future__ import annotations

import json
import sqlite3
import time
from typing import Optional

# @decision DEC-CRITIC-FAIL-CLOSED-001 (TTL choice)
# 300 seconds (5 minutes) covers the worst-case SubagentStop latency after lease
# revocation. The harness revokes the lease within milliseconds of SubagentStop;
# the hook then fires in the same process. 300s provides ample margin while
# avoiding resolution of ancient stale leases (which would require deliberate
# operator action to issue a new lease for the same agent_id anyway — agent_ids
# are UUIDs, effectively never re-used within a session).
RECENT_LEASE_TTL_SECONDS: int = 300


def _fetch_recent_by_agent_id(
    conn: sqlite3.Connection,
    agent_id: str,
    ttl_seconds: int = RECENT_LEASE_TTL_SECONDS,
) -> Optional[dict]:
    """Fetch the most recent implementer lease for agent_id including recently-released/revoked rows.

    @decision DEC-CRITIC-FAIL-CLOSED-001
    This helper exists ONLY in critic_context.py.  It intentionally widens the
    status filter to include recently-released and recently-revoked leases within
    ``ttl_seconds``.  Do NOT add this helper to runtime/core/leases.py — that
    module's _fetch_active and get_current must remain status='active'-only for
    all other callers.  The widening is scoped to this module to avoid
    unintended side effects on lease validation, approval gating, and
    worktree provision logic.
    """
    now = int(time.time())
    cutoff = now - ttl_seconds
    row = conn.execute(
        """
        SELECT * FROM dispatch_leases
        WHERE agent_id = ?
          AND role = 'implementer'
          AND (
            status = 'active'
            OR (status IN ('released', 'revoked') AND released_at >= ?)
          )
        ORDER BY
          CASE status WHEN 'active' THEN 0 ELSE 1 END ASC,
          released_at DESC,
          issued_at DESC
        LIMIT 1
        """,
        (agent_id, cutoff),
    ).fetchone()
    return dict(row) if row else None


def resolve(
    conn: sqlite3.Connection,
    hook_input: dict,
    *,
    fallback_worktree_path: str = "",
) -> dict:
    """Resolve implementer workflow_id and lease_id from SubagentStop hook input.

    Args:
        conn:                  Open SQLite connection with schema applied.
        hook_input:            Parsed SubagentStop hook input JSON dict.
                               Expected fields: ``agent_id``, ``cwd``.
        fallback_worktree_path: Last-resort path used when neither agent_id
                               nor cwd resolves a lease.  When empty and
                               resolution fails, the caller should emit
                               CRITIC_UNAVAILABLE.

    Returns:
        dict with keys:
          found          bool   -- True when an implementer lease was resolved.
          workflow_id    str    -- resolved workflow_id (non-empty only when found).
          lease_id       str    -- resolved lease_id (non-empty only when found).
          worktree_path  str    -- resolved worktree_path from the lease.
          agent_id       str    -- agent_id from the input (may be empty).
          resolve_path   str    -- which resolution path succeeded:
                                   "agent_id" | "cwd" | "fallback" | "not_found".
          error          str    -- human-readable failure reason when not found.
    """
    # Lazy import to avoid circular dependency at module load time.
    from runtime.core import leases

    agent_id = str(hook_input.get("agent_id") or "").strip()
    cwd = str(hook_input.get("cwd") or "").strip()

    # --- Priority 1: resolve by agent_id (includes recently-released/revoked leases) ---
    # @decision DEC-CRITIC-FAIL-CLOSED-001
    # Use _fetch_recent_by_agent_id instead of leases.get_current so that a
    # revoked lease (which the harness sets before SubagentStop fires) is still
    # resolvable within the RECENT_LEASE_TTL_SECONDS window.
    if agent_id:
        lease = _fetch_recent_by_agent_id(conn, agent_id)
        if lease:
            return _found(lease, agent_id, "agent_id")

    # --- Priority 2: resolve by cwd (the implementer's actual working dir) ---
    if cwd:
        lease = leases.get_current(conn, worktree_path=cwd)
        if lease and str(lease.get("role") or "").lower() == "implementer":
            return _found(lease, agent_id, "cwd")

    # --- Priority 3: explicit fallback_worktree_path (caller-supplied) ---
    if fallback_worktree_path:
        lease = leases.get_current(conn, worktree_path=fallback_worktree_path)
        if lease and str(lease.get("role") or "").lower() == "implementer":
            return _found(lease, agent_id, "fallback")

    # --- Not found ---
    tried = []
    if agent_id:
        tried.append(f"agent_id={agent_id!r}")
    if cwd:
        tried.append(f"cwd={cwd!r}")
    if fallback_worktree_path:
        tried.append(f"fallback_worktree_path={fallback_worktree_path!r}")

    error_msg = (
        "No implementer lease found (active or recently-released/revoked); tried: "
        + (", ".join(tried) if tried else "no identifiers available")
        + ". critic_context cannot resolve workflow_id; "
        "emit CRITIC_UNAVAILABLE instead of submitting with wrong workflow_id."
    )
    return {
        "found": False,
        "workflow_id": "",
        "lease_id": "",
        "worktree_path": "",
        "agent_id": agent_id,
        "resolve_path": "not_found",
        "error": error_msg,
    }


def _found(lease: dict, agent_id: str, resolve_path: str) -> dict:
    """Build a successful resolution result from a lease row."""
    return {
        "found": True,
        "workflow_id": str(lease.get("workflow_id") or ""),
        "lease_id": str(lease.get("lease_id") or ""),
        "worktree_path": str(lease.get("worktree_path") or ""),
        "agent_id": agent_id,
        "resolve_path": resolve_path,
        "error": "",
    }


def resolve_from_json_string(
    conn: sqlite3.Connection,
    hook_input_json: str,
    *,
    fallback_worktree_path: str = "",
) -> dict:
    """Convenience wrapper: parse ``hook_input_json`` then call ``resolve``."""
    try:
        hook_input = json.loads(hook_input_json) if hook_input_json.strip() else {}
    except (json.JSONDecodeError, TypeError):
        hook_input = {}
    return resolve(conn, hook_input, fallback_worktree_path=fallback_worktree_path)
