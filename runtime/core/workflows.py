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
    # @decision DEC-CONV-003
    # Title: bind_workflow removes stale bindings for the same worktree_path (W-CONV-3)
    # Status: accepted
    # Rationale: When an implementer is re-dispatched to a worktree under a new
    #   workflow_id, the old binding remains in workflow_bindings indexed by the
    #   old id. Hooks that scan by worktree_path can then return the stale row.
    #   Fix: within the same transaction, DELETE any row where worktree_path
    #   matches the canonical path AND workflow_id differs from the one being
    #   inserted. This ensures each worktree_path has at most one active binding.
    with conn:
        conn.execute(
            """
            DELETE FROM workflow_bindings
            WHERE worktree_path = ? AND workflow_id != ?
            """,
            (canonical_worktree, workflow_id),
        )
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


def find_binding_for_worktree(
    conn: sqlite3.Connection, worktree_path: str
) -> Optional[dict]:
    """Return the binding row for ``worktree_path``, or None when unbound.

    ``worktree_path`` is normalized through :func:`normalize_path` so callers
    may pass a symlinked or non-canonical path and still resolve the canonical
    binding row.
    """
    canonical_worktree = normalize_path(worktree_path)
    row = conn.execute(
        """
        SELECT workflow_id, worktree_path, branch, base_branch, ticket, initiative,
               created_at, updated_at
        FROM   workflow_bindings
        WHERE  worktree_path = ?
        """,
        (canonical_worktree,),
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
    classified = classify_scope_paths(conn, workflow_id, changed_files)
    if not classified["scope_found"]:
        return {
            "compliant": True,
            "violations": [],
            "in_scope": list(changed_files),
            "note": "no scope manifest; all files accepted",
        }

    violations = [
        f"{item['reason']}: {item['path']}"
        for item in classified["classifications"]
        if item["reason"] is not None
    ]
    in_scope = [
        item["path"]
        for item in classified["classifications"]
        if item["reason"] is None
    ]

    return {
        "compliant": len(violations) == 0,
        "violations": violations,
        "in_scope": in_scope,
    }


def classify_scope_paths(
    conn: sqlite3.Connection,
    workflow_id: str,
    changed_files: list[str],
) -> dict:
    """Classify each changed file against the workflow scope manifest.

    Returns:
        {
          "scope_found": bool,
          "classifications": [
              {"path": str, "reason": None | "FORBIDDEN" | "OUT_OF_SCOPE"}
          ],
          "in_scope": list[str],
          "unexpected": list[{"path": str, "reason": str}],
        }

    This is the single workflow-scope classification authority. Callers that
    need a boolean compliance verdict should use :func:`check_scope_compliance`,
    which derives its return shape from this richer classification instead of
    reimplementing the matching logic.
    """
    scope = get_scope(conn, workflow_id)
    if scope is None:
        classifications = [{"path": path, "reason": None} for path in changed_files]
        return {
            "scope_found": False,
            "classifications": classifications,
            "in_scope": list(changed_files),
            "unexpected": [],
        }

    allowed = scope["allowed_paths"]
    forbidden = scope["forbidden_paths"]
    classifications: list[dict] = []
    in_scope: list[str] = []
    unexpected: list[dict] = []

    for path in changed_files:
        if any(fnmatch.fnmatch(path, pat) for pat in forbidden):
            item = {"path": path, "reason": "FORBIDDEN"}
            classifications.append(item)
            unexpected.append(item)
            continue

        if allowed and not any(fnmatch.fnmatch(path, pat) for pat in allowed):
            item = {"path": path, "reason": "OUT_OF_SCOPE"}
            classifications.append(item)
            unexpected.append(item)
            continue

        classifications.append({"path": path, "reason": None})
        in_scope.append(path)

    return {
        "scope_found": True,
        "classifications": classifications,
        "in_scope": in_scope,
        "unexpected": unexpected,
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
