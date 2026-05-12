# @decision DEC-CRITIC-CONTEXT-001
# Title: runtime/core/critic_context.py is the single authority for implementer critic context resolution
# Status: accepted
# Rationale: Both hooks/implementer-critic.sh and sidecars/codex-review/scripts/implementer-critic-hook.mjs
#   independently derived workflow_id and lease_id from detect_project_root / CLAUDE_PROJECT_DIR —
#   both of which resolve to the ORCHESTRATOR's project root (not the implementer's) when SubagentStop
#   fires. The hook input JSON carries the implementer's actual cwd in input.cwd and the implementer's
#   agent_id in input.agent_id. This module is the single authority that reads those fields and
#   resolves the correct implementer workflow_id + lease_id by: (1) agent_id first, (2) input.cwd
#   as worktree_path fallback. Deleting the parallel inline resolution paths in both callers ensures
#   there is exactly one place to fix if the resolution logic ever needs to change.
#   Alternatives considered: fixing each caller inline — rejected because two copies diverge silently;
#   deriving workflow_id from git branch name when input.cwd is available — forbidden per spec (no
#   current_workflow_id fallback when input.cwd is present).
"""Implementer critic context resolver — single authority.

Resolves the correct workflow_id and lease_id for a critic review row
from the SubagentStop hook input JSON. Called by both bash and Node
wrappers via ``cc-policy critic context resolve --hook-input <json>``
so there is one code path to maintain.

Resolution priority:
  1. ``agent_id`` from hook input -> ``leases.get_current(agent_id=...)``
  2. ``cwd`` from hook input   -> ``leases.get_current(worktree_path=...)``
  3. ``worktree_path`` from env / supplied arg

CRITIC_UNAVAILABLE is returned in the result dict (not raised) when
neither identifier resolves to an active implementer lease. Callers
must surface CRITIC_UNAVAILABLE rather than silently submitting with
the wrong workflow_id.
"""

from __future__ import annotations

import json
import sqlite3
from typing import Optional


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

    # --- Priority 1: resolve by agent_id ---
    if agent_id:
        lease = leases.get_current(conn, agent_id=agent_id)
        if lease and str(lease.get("role") or "").lower() == "implementer":
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
        "No active implementer lease found; tried: "
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
