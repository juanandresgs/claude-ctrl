"""Workflow binding and scope enforcement authority.

Owns the workflow_bindings and workflow_scope tables. Provides:
  - bind_workflow: register a workflow→worktree→branch mapping
  - get_binding: retrieve binding by workflow_id
  - set_scope: attach a scope manifest (allowed/required/forbidden paths)
  - get_scope: retrieve scope with parsed JSON arrays
  - check_scope_compliance: validate changed files against scope
  - list_bindings: enumerate all bindings

@decision DEC-WF-001
Title: Workflow binding as the canonical worktree identity mechanism
Status: accepted
Rationale: Previous system relied on CWD inference and branch name heuristics
  to discover which worktree an implementer was working in. TKT-021 replaces
  this with explicit binding: when an implementer spawns, subagent-start.sh
  calls bind_workflow to register the (workflow_id, worktree_path, branch)
  triple in SQLite. Downstream consumers (guard.sh Check 12, context-lib.sh
  get_workflow_binding) read from this canonical table rather than inferring
  from filesystem state. This eliminates the race condition where two
  concurrent implementers on different branches would have indeterminate
  identity.

@decision DEC-WF-002
Title: forbidden_paths take strict precedence over allowed_paths in compliance check
Status: accepted
Rationale: The Evaluation Contract requires that forbidden_paths take precedence
  over allowed_paths. This means a file matching both allowed_paths AND
  forbidden_paths is still a violation. The check_scope_compliance function
  evaluates forbidden matches first and short-circuits. This is safer than
  the alternative (allowed wins) because scope manifests are written by
  planners who may not anticipate all forbidden patterns at authoring time.
"""

from __future__ import annotations

import fnmatch
import json
import sqlite3
import time
from typing import Optional

from runtime.core.policy_utils import normalize_path


def bind_workflow(
    conn: sqlite3.Connection,
    workflow_id: str,
    worktree_path: str,
    branch: str,
    base_branch: str = "main",
    ticket: Optional[str] = None,
    initiative: Optional[str] = None,
) -> None:
    """INSERT OR REPLACE a workflow binding into workflow_bindings.

    Safe to call multiple times — subsequent calls update worktree_path,
    branch, and other fields while preserving created_at on conflict.

    worktree_path is normalized via normalize_path() (DEC-CONV-001) so the
    stored value is always the canonical realpath form. build_context() looks
    up leases by worktree_path; storing a non-canonical path would cause a
    miss when the lookup key is the git-resolved realpath.
    """
    canonical_worktree = normalize_path(worktree_path)
    now = int(time.time())
    with conn:
        conn.execute(
            """
            INSERT INTO workflow_bindings
                (workflow_id, worktree_path, branch, base_branch, ticket, initiative,
                 created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(workflow_id) DO UPDATE SET
                worktree_path = excluded.worktree_path,
                branch        = excluded.branch,
                base_branch   = excluded.base_branch,
                ticket        = excluded.ticket,
                initiative    = excluded.initiative,
                updated_at    = excluded.updated_at
            """,
            (workflow_id, canonical_worktree, branch, base_branch, ticket, initiative, now, now),
        )


def get_binding(conn: sqlite3.Connection, workflow_id: str) -> Optional[dict]:
    """Return the binding row as a dict, or None if not found."""
    row = conn.execute(
        """
        SELECT workflow_id, worktree_path, branch, base_branch, ticket, initiative,
               created_at, updated_at
        FROM   workflow_bindings
        WHERE  workflow_id = ?
        """,
        (workflow_id,),
    ).fetchone()
    return dict(row) if row else None


def set_scope(
    conn: sqlite3.Connection,
    workflow_id: str,
    allowed_paths: list,
    required_paths: list,
    forbidden_paths: list,
    authority_domains: list,
) -> None:
    """INSERT OR REPLACE scope for a workflow_id.

    Raises ValueError if workflow_id does not exist in workflow_bindings —
    scope without a binding is a logic error.
    """
    if get_binding(conn, workflow_id) is None:
        raise ValueError(
            f"workflow_id '{workflow_id}' not found in workflow_bindings. Call bind_workflow first."
        )
    now = int(time.time())
    with conn:
        conn.execute(
            """
            INSERT INTO workflow_scope
                (workflow_id, allowed_paths, required_paths, forbidden_paths,
                 authority_domains, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(workflow_id) DO UPDATE SET
                allowed_paths     = excluded.allowed_paths,
                required_paths    = excluded.required_paths,
                forbidden_paths   = excluded.forbidden_paths,
                authority_domains = excluded.authority_domains,
                updated_at        = excluded.updated_at
            """,
            (
                workflow_id,
                json.dumps(allowed_paths),
                json.dumps(required_paths),
                json.dumps(forbidden_paths),
                json.dumps(authority_domains),
                now,
            ),
        )


def get_scope(conn: sqlite3.Connection, workflow_id: str) -> Optional[dict]:
    """Return scope with all JSON columns parsed into Python lists, or None."""
    row = conn.execute(
        """
        SELECT workflow_id, allowed_paths, required_paths, forbidden_paths,
               authority_domains, updated_at
        FROM   workflow_scope
        WHERE  workflow_id = ?
        """,
        (workflow_id,),
    ).fetchone()
    if row is None:
        return None
    d = dict(row)
    # Parse JSON arrays back to lists; treat NULL / malformed JSON as empty list
    for key in ("allowed_paths", "required_paths", "forbidden_paths", "authority_domains"):
        raw = d.get(key)
        try:
            d[key] = json.loads(raw) if raw else []
        except (json.JSONDecodeError, TypeError):
            d[key] = []
    return d


def check_scope_compliance(
    conn: sqlite3.Connection,
    workflow_id: str,
    changed_files: list[str],
) -> dict:
    """Check whether changed_files comply with the workflow's scope manifest.

    Returns:
        {
          "compliant": bool,
          "violations": list[str],   # files that violated scope rules
          "in_scope": list[str],     # files that matched allowed_paths
        }

    Rules (DEC-WF-002):
    1. Each changed file must match at least one allowed_paths glob.
    2. No changed file may match any forbidden_paths glob.
    3. forbidden_paths take strict precedence — a file in both allowed and
       forbidden is a violation.

    If no scope exists for workflow_id, returns compliant=True with a note
    in violations (advisory, not blocking — guard.sh enforces the hard deny
    separately when scope is absent).
    """
    scope = get_scope(conn, workflow_id)
    if scope is None:
        return {
            "compliant": True,
            "violations": [],
            "in_scope": list(changed_files),
            "note": "no scope manifest; all files accepted",
        }

    allowed = scope["allowed_paths"]
    forbidden = scope["forbidden_paths"]

    violations: list[str] = []
    in_scope: list[str] = []

    for f in changed_files:
        # Rule 2 + 3: forbidden takes precedence
        if any(fnmatch.fnmatch(f, pat) for pat in forbidden):
            violations.append(f"FORBIDDEN: {f}")
            continue

        # Rule 1: must match at least one allowed pattern
        if allowed and not any(fnmatch.fnmatch(f, pat) for pat in allowed):
            violations.append(f"OUT_OF_SCOPE: {f}")
            continue

        in_scope.append(f)

    return {
        "compliant": len(violations) == 0,
        "violations": violations,
        "in_scope": in_scope,
    }


def list_bindings(conn: sqlite3.Connection) -> list[dict]:
    """Return all workflow bindings ordered by created_at descending."""
    rows = conn.execute(
        """
        SELECT workflow_id, worktree_path, branch, base_branch, ticket, initiative,
               created_at, updated_at
        FROM   workflow_bindings
        ORDER  BY created_at DESC
        """
    ).fetchall()
    return [dict(r) for r in rows]
