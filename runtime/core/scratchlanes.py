"""Project-local scratchlane authority.

Owns both scratchlane tables:

  * ``scratchlane_permits``  — active user-approved task roots
  * ``scratchlane_requests`` — pending yes/no requests awaiting user reply

A scratchlane is a user-approved, task-scoped artifact root under
``tmp/.claude-scratch/<task_slug>`` inside a project checkout. Scratchlanes
exist so the orchestrator may perform one-off automation work (scripts,
manifests, generated outputs) without being forced into the source-write path.

The runtime must also remember *that approval is currently being asked for* so
the next plain-English user reply ("yes", "no", "allow it") can be resolved
without asking the user to run a command. That pending-request state is part of
the same authority surface as the permit itself.

The module is intentionally narrow:

  * SQLite stores permit state and pending-request state.
  * Filesystem creation is a CLI/hook concern; this module never writes
    directories.
  * The root path is canonical and deterministic: callers never choose an
    arbitrary absolute path outside the project-local scratch parent.

@decision DEC-SCRATCHLANE-001
Title: scratchlane_permits is the sole authority for task-local artifact roots
Status: accepted
Rationale: The control plane needs one mechanically checkable place that says
  "this task may write under this local scratch root". Reusing source/governance
  capabilities would overload the meaning of those authorities and would not
  express the user's per-task approval. A small SQLite table gives one durable
  authority for that approval without widening source-write permissions.

@decision DEC-SCRATCHLANE-002
Title: scratchlane_requests is the sole authority for pending user approval
Status: accepted
Rationale: The smooth UX is "Claude asks once, user says yes/no, runtime
  resolves it". That requires explicit runtime-owned pending state keyed to the
  current session and project. Shell variables or ad-hoc prose are not durable
  enough and would create a second authority for whether approval is outstanding.
"""

from __future__ import annotations

import os
import re
import sqlite3
import time
from typing import Optional

from runtime.core.policy_utils import (
    SCRATCHLANE_PARENT_REL,
    normalize_path,
    sanitize_token,
    scratchlane_root,
)

REQUEST_STATUS_PENDING = "pending"
REQUEST_STATUS_APPROVED = "approved"
REQUEST_STATUS_DENIED = "denied"
REQUEST_STATUS_SUPERSEDED = "superseded"


def _request_row_to_dict(row: sqlite3.Row | None) -> Optional[dict]:
    return dict(row) if row else None


def _grant_active_permit(
    conn: sqlite3.Connection,
    project_root: str,
    task_slug: str,
    *,
    granted_by: str,
    note: str,
    now: int,
) -> None:
    """Write the active permit row inside an existing transaction."""
    conn.execute(
        """
        UPDATE scratchlane_permits
        SET    active = 0,
               revoked_at = ?
        WHERE  project_root = ?
          AND  task_slug = ?
          AND  active = 1
        """,
        (now, project_root, task_slug),
    )
    conn.execute(
        """
        INSERT INTO scratchlane_permits
            (project_root, task_slug, root_path, granted_by, note,
             created_at, active, revoked_at)
        VALUES (?, ?, ?, ?, ?, ?, 1, NULL)
        """,
        (project_root, task_slug, scratchlane_root(project_root, task_slug), granted_by, note, now),
    )


def grant(
    conn: sqlite3.Connection,
    project_root: str,
    task_slug: str,
    *,
    granted_by: str = "user",
    note: str = "",
) -> dict:
    """Create or refresh an active scratchlane permit for ``task_slug``."""
    canonical_project_root = normalize_path(project_root)
    slug = sanitize_token(task_slug)
    now = int(time.time())

    with conn:
        _grant_active_permit(
            conn,
            canonical_project_root,
            slug,
            granted_by=granted_by,
            note=note,
            now=now,
        )

    record = get_active(conn, canonical_project_root, slug)
    if record is None:
        raise RuntimeError("scratchlane grant was written but could not be read back")
    return record


def revoke(conn: sqlite3.Connection, project_root: str, task_slug: str) -> bool:
    """Deactivate the current scratchlane permit, if one exists."""
    canonical_project_root = normalize_path(project_root)
    slug = sanitize_token(task_slug)
    now = int(time.time())
    with conn:
        cursor = conn.execute(
            """
            UPDATE scratchlane_permits
            SET    active = 0,
                   revoked_at = ?
            WHERE  project_root = ?
              AND  task_slug = ?
              AND  active = 1
            """,
            (now, canonical_project_root, slug),
        )
    return cursor.rowcount > 0


def get_active(
    conn: sqlite3.Connection,
    project_root: str,
    task_slug: str,
) -> Optional[dict]:
    """Return the active scratchlane permit for ``task_slug``, or ``None``."""
    canonical_project_root = normalize_path(project_root)
    slug = sanitize_token(task_slug)
    row = conn.execute(
        """
        SELECT id, project_root, task_slug, root_path, granted_by, note, created_at
        FROM   scratchlane_permits
        WHERE  project_root = ?
          AND  task_slug = ?
          AND  active = 1
        ORDER  BY created_at DESC, id DESC
        LIMIT  1
        """,
        (canonical_project_root, slug),
    ).fetchone()
    return dict(row) if row else None


def list_active(
    conn: sqlite3.Connection,
    *,
    project_root: str | None = None,
) -> list[dict]:
    """Return active scratchlane permits, newest first."""
    if project_root is not None:
        canonical_project_root = normalize_path(project_root)
        rows = conn.execute(
            """
            SELECT id, project_root, task_slug, root_path, granted_by, note, created_at
            FROM   scratchlane_permits
            WHERE  active = 1
              AND  project_root = ?
            ORDER  BY created_at DESC, id DESC
            """,
            (canonical_project_root,),
        ).fetchall()
    else:
        rows = conn.execute(
            """
            SELECT id, project_root, task_slug, root_path, granted_by, note, created_at
            FROM   scratchlane_permits
            WHERE  active = 1
            ORDER  BY created_at DESC, id DESC
            """
        ).fetchall()
    return [dict(row) for row in rows]


def active_roots(conn: sqlite3.Connection, project_root: str) -> tuple[str, ...]:
    """Return the active scratchlane roots for ``project_root``."""
    items = list_active(conn, project_root=project_root)
    return tuple(str(item["root_path"]) for item in items)


def request_approval(
    conn: sqlite3.Connection,
    *,
    session_id: str,
    project_root: str,
    task_slug: str,
    requested_path: str = "",
    tool_name: str = "",
    request_reason: str = "",
    requested_by: str = "runtime",
) -> dict:
    """Record a pending scratchlane approval request for this session/project.

    At most one pending request remains active per ``(session_id, project_root)``
    pair. A newer request supersedes the older pending one.
    """
    if not session_id:
        raise ValueError("session_id is required for scratchlane approval requests")

    canonical_project_root = normalize_path(project_root)
    slug = sanitize_token(task_slug)
    root_path = scratchlane_root(canonical_project_root, slug)
    requested_path = requested_path or ""
    now = int(time.time())

    with conn:
        conn.execute(
            """
            UPDATE scratchlane_requests
            SET    status = ?,
                   resolved_at = ?,
                   resolution_note = ?
            WHERE  session_id = ?
              AND  project_root = ?
              AND  status = ?
            """,
            (
                REQUEST_STATUS_SUPERSEDED,
                now,
                "superseded by newer scratchlane request",
                session_id,
                canonical_project_root,
                REQUEST_STATUS_PENDING,
            ),
        )
        conn.execute(
            """
            INSERT INTO scratchlane_requests
                (session_id, project_root, task_slug, root_path, requested_path,
                 tool_name, request_reason, requested_by, requested_at,
                 status, resolved_at, resolution_note)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, '')
            """,
            (
                session_id,
                canonical_project_root,
                slug,
                root_path,
                requested_path,
                tool_name,
                request_reason,
                requested_by,
                now,
                REQUEST_STATUS_PENDING,
            ),
        )

    record = get_pending(conn, session_id=session_id, project_root=canonical_project_root)
    if record is None:
        raise RuntimeError("scratchlane request was written but could not be read back")
    return record


def get_pending(
    conn: sqlite3.Connection,
    *,
    session_id: str,
    project_root: str,
) -> Optional[dict]:
    """Return the active pending request for this session/project, if any."""
    row = conn.execute(
        """
        SELECT id, session_id, project_root, task_slug, root_path, requested_path,
               tool_name, request_reason, requested_by, requested_at,
               status, resolved_at, resolution_note
        FROM   scratchlane_requests
        WHERE  session_id = ?
          AND  project_root = ?
          AND  status = ?
        ORDER  BY requested_at DESC, id DESC
        LIMIT  1
        """,
        (session_id, normalize_path(project_root), REQUEST_STATUS_PENDING),
    ).fetchone()
    return _request_row_to_dict(row)


def list_pending(
    conn: sqlite3.Connection,
    *,
    project_root: str | None = None,
    session_id: str | None = None,
) -> list[dict]:
    """List pending requests newest-first, optionally filtered."""
    clauses = ["status = ?"]
    params: list[object] = [REQUEST_STATUS_PENDING]
    if project_root is not None:
        clauses.append("project_root = ?")
        params.append(normalize_path(project_root))
    if session_id is not None:
        clauses.append("session_id = ?")
        params.append(session_id)
    where = " AND ".join(clauses)
    rows = conn.execute(
        f"""
        SELECT id, session_id, project_root, task_slug, root_path, requested_path,
               tool_name, request_reason, requested_by, requested_at,
               status, resolved_at, resolution_note
        FROM   scratchlane_requests
        WHERE  {where}
        ORDER  BY requested_at DESC, id DESC
        """
        ,
        params,
    ).fetchall()
    return [_request_row_to_dict(row) for row in rows if row is not None]


def _normalized_prompt(prompt: str) -> str:
    collapsed = re.sub(r"\s+", " ", prompt or "").strip().lower()
    return collapsed


def classify_prompt_response(prompt: str, *, task_slug: str) -> Optional[str]:
    """Classify a plain-English yes/no reply for a pending scratchlane request.

    Returns ``"approve"``, ``"deny"``, or ``None`` when the reply is ambiguous.
    The heuristic is intentionally conservative: short explicit yes/no replies
    resolve immediately; longer prompts must mention the scratchlane/task.
    """
    normalized = _normalized_prompt(prompt)
    if not normalized:
        return None

    short_reply = len(normalized.split()) <= 4
    task_text = task_slug.lower()
    task_words = task_text.replace("-", " ")
    mentions_request = any(
        token and token in normalized
        for token in (
            "scratchlane",
            "scratch lane",
            "task lane",
            ".claude-scratch",
            task_text,
            task_words,
        )
    )

    if re.search(r"\b(no|nope|deny|denied|don't|do not|not now|skip)\b", normalized):
        if short_reply or mentions_request:
            return "deny"

    if re.search(
        r"\b(yes|yeah|yep|approve|approved|allow|allowed|ok|okay|sure|fine|"
        r"go ahead|use it|open it|create it|do it|sounds good)\b",
        normalized,
    ):
        if short_reply or mentions_request:
            return "approve"

    return None


def _resolution_message(
    request: dict,
    *,
    resolution: str,
    permit: Optional[dict] = None,
) -> str:
    task_slug = str(request.get("task_slug") or "")
    root_path = str((permit or request).get("root_path") or "")
    requested_path = str(request.get("requested_path") or "")
    if resolution == "approved":
        target_note = f" Originally blocked path: {requested_path}." if requested_path else ""
        return (
            f"Scratchlane approved: task '{task_slug}' is active at {root_path}. "
            "Continue the interrupted temporary-automation task and keep all temporary "
            f"scripts, manifests, and outputs there.{target_note} Do not ask the user "
            "to run any command."
        )
    return (
        f"Scratchlane denied: task '{task_slug}' was not approved for {root_path}. "
        "Do not retry the blocked scratchlane path. Ask the user whether they want "
        "a different approach."
    )


def resolve_pending_from_prompt(
    conn: sqlite3.Connection,
    *,
    session_id: str,
    project_root: str,
    prompt: str,
    granted_by: str = "user_prompt",
) -> dict:
    """Resolve the pending request from a plain-English user reply.

    Returns a machine-readable result:
      resolution: ``none`` | ``pending`` | ``approved`` | ``denied``
      request:    current or resolved request row
      permit:     active permit when approved, else ``None``
      additional_context: user-facing guidance for UserPromptSubmit
    """
    canonical_project_root = normalize_path(project_root)
    request = get_pending(conn, session_id=session_id, project_root=canonical_project_root)
    if request is None:
        return {
            "found": False,
            "resolution": "none",
            "request": None,
            "permit": None,
            "additional_context": "",
        }

    decision = classify_prompt_response(prompt, task_slug=str(request["task_slug"]))
    if decision is None:
        return {
            "found": True,
            "resolution": "pending",
            "request": request,
            "permit": None,
            "additional_context": "",
        }

    now = int(time.time())
    if decision == "approve":
        with conn:
            _grant_active_permit(
                conn,
                canonical_project_root,
                str(request["task_slug"]),
                granted_by=granted_by,
                note="approved from user prompt reply",
                now=now,
            )
            conn.execute(
                """
                UPDATE scratchlane_requests
                SET    status = ?,
                       resolved_at = ?,
                       resolution_note = ?
                WHERE  id = ?
                """,
                (
                    REQUEST_STATUS_APPROVED,
                    now,
                    "approved from user prompt reply",
                    request["id"],
                ),
            )
        permit = get_active(conn, canonical_project_root, str(request["task_slug"]))
        return {
            "found": True,
            "resolution": "approved",
            "request": {
                **request,
                "status": REQUEST_STATUS_APPROVED,
                "resolved_at": now,
                "resolution_note": "approved from user prompt reply",
            },
            "permit": permit,
            "additional_context": _resolution_message(request, resolution="approved", permit=permit),
        }

    with conn:
        conn.execute(
            """
            UPDATE scratchlane_requests
            SET    status = ?,
                   resolved_at = ?,
                   resolution_note = ?
            WHERE  id = ?
            """,
            (
                REQUEST_STATUS_DENIED,
                now,
                "denied from user prompt reply",
                request["id"],
            ),
        )
    return {
        "found": True,
        "resolution": "denied",
        "request": {
            **request,
            "status": REQUEST_STATUS_DENIED,
            "resolved_at": now,
            "resolution_note": "denied from user prompt reply",
        },
        "permit": None,
        "additional_context": _resolution_message(request, resolution="denied"),
    }
