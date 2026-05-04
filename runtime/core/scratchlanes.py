"""Project-local scratchlane authority.

Owns both scratchlane tables:

  * ``scratchlane_permits``  — active user-approved task roots
  * ``scratchlane_requests`` — pending yes/no requests awaiting user reply

A scratchlane is a user-approved, task-scoped artifact root under
``tmp/<task_slug>`` inside a project checkout. Scratchlanes
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

import json
import re
import sqlite3
import time
from pathlib import Path
from typing import Optional

from runtime.core.policy_utils import (
    is_path_under,
    legacy_scratchlane_parent,
    legacy_scratchlane_root,
    normalize_path,
    sanitize_token,
    scratchlane_parent,
    scratchlane_root,
)

REQUEST_STATUS_PENDING = "pending"
REQUEST_STATUS_APPROVED = "approved"
REQUEST_STATUS_DENIED = "denied"
REQUEST_STATUS_SUPERSEDED = "superseded"

IGNORABLE_CLEANUP_FILES = frozenset(
    {
        ".DS_Store",
        ".DS_STORE",
        ".localized",
        "Thumbs.db",
        "desktop.ini",
    }
)


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
    session_id: str = "",
    workflow_id: str = "",
    work_item_id: str = "",
    attempt_id: str = "",
    expires_at: int | None = None,
    capabilities: tuple[str, ...] = ("write_scratch", "run_interpreter_wrapped"),
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
            (project_root, task_slug, root_path, session_id, workflow_id,
             work_item_id, attempt_id, capabilities_json, expires_at,
             granted_by, note, created_at, active, revoked_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, NULL)
        """,
        (
            project_root,
            task_slug,
            scratchlane_root(project_root, task_slug),
            session_id or None,
            workflow_id or None,
            work_item_id or None,
            attempt_id or None,
            json.dumps(list(capabilities)),
            expires_at,
            granted_by,
            note,
            now,
        ),
    )
    conn.execute(
        """
        UPDATE scratchlane_requests
        SET    status = ?,
               resolved_at = ?,
               resolution_note = ?
        WHERE  project_root = ?
          AND  task_slug = ?
          AND  status = ?
        """,
        (
            REQUEST_STATUS_APPROVED,
            now,
            "approved by scratchlane grant",
            project_root,
            task_slug,
            REQUEST_STATUS_PENDING,
        ),
    )


def grant(
    conn: sqlite3.Connection,
    project_root: str,
    task_slug: str,
    *,
    granted_by: str = "user",
    note: str = "",
    session_id: str = "",
    workflow_id: str = "",
    work_item_id: str = "",
    attempt_id: str = "",
    expires_at: int | None = None,
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
            session_id=session_id,
            workflow_id=workflow_id,
            work_item_id=work_item_id,
            attempt_id=attempt_id,
            expires_at=expires_at,
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
        SELECT id, project_root, task_slug, root_path, session_id, workflow_id,
               work_item_id, attempt_id, capabilities_json, expires_at,
               granted_by, note, created_at
        FROM   scratchlane_permits
        WHERE  project_root = ?
          AND  task_slug = ?
          AND  active = 1
          AND  (expires_at IS NULL OR expires_at > ?)
        ORDER  BY created_at DESC, id DESC
        LIMIT  1
        """,
        (canonical_project_root, slug, int(time.time())),
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
            SELECT id, project_root, task_slug, root_path, session_id, workflow_id,
                   work_item_id, attempt_id, capabilities_json, expires_at,
                   granted_by, note, created_at
            FROM   scratchlane_permits
            WHERE  active = 1
              AND  project_root = ?
              AND  (expires_at IS NULL OR expires_at > ?)
            ORDER  BY created_at DESC, id DESC
            """,
            (canonical_project_root, int(time.time())),
        ).fetchall()
    else:
        rows = conn.execute(
            """
            SELECT id, project_root, task_slug, root_path, session_id, workflow_id,
                   work_item_id, attempt_id, capabilities_json, expires_at,
                   granted_by, note, created_at
            FROM   scratchlane_permits
            WHERE  active = 1
              AND  (expires_at IS NULL OR expires_at > ?)
            ORDER  BY created_at DESC, id DESC
            """,
            (int(time.time()),),
        ).fetchall()
    return [dict(row) for row in rows]


def _scope_matches(
    item: dict,
    *,
    session_id: str = "",
    workflow_id: str = "",
    work_item_id: str = "",
    attempt_id: str = "",
) -> bool:
    """Return whether an active permit applies to the current actor scope."""
    scoped_fields = {
        "session_id": session_id,
        "workflow_id": workflow_id,
        "work_item_id": work_item_id,
        "attempt_id": attempt_id,
    }
    for key, current in scoped_fields.items():
        value = str(item.get(key) or "")
        if value and value != current:
            return False
    return True


def active_roots(
    conn: sqlite3.Connection,
    project_root: str,
    *,
    session_id: str = "",
    workflow_id: str = "",
    work_item_id: str = "",
    attempt_id: str = "",
) -> tuple[str, ...]:
    """Return active scratchlane roots applying to this actor scope."""
    items = list_active(conn, project_root=project_root)
    return tuple(
        str(item["root_path"])
        for item in items
        if _scope_matches(
            item,
            session_id=session_id,
            workflow_id=workflow_id,
            work_item_id=work_item_id,
            attempt_id=attempt_id,
        )
    )


def _is_ignorable_cleanup_file(path: Path) -> bool:
    name = path.name
    if name in IGNORABLE_CLEANUP_FILES:
        return path.is_file() and not path.is_symlink()
    if name.startswith("._"):
        return path.is_file() and not path.is_symlink()
    return False


def _effective_empty_plan(root: Path) -> tuple[bool, list[Path], list[Path], list[Path]]:
    """Return whether ``root`` is empty aside from ignorable local clutter.

    The plan contains regular ignorable files and child directories that can be
    removed before removing ``root`` itself. Symlinks are always substantive.
    """
    removable_files: list[Path] = []
    removable_dirs: list[Path] = []
    substantive: list[Path] = []

    def visit(directory: Path) -> bool:
        try:
            entries = list(directory.iterdir())
        except OSError:
            substantive.append(directory)
            return False

        empty = True
        for entry in entries:
            if entry.is_symlink():
                substantive.append(entry)
                empty = False
            elif entry.is_dir():
                if visit(entry):
                    removable_dirs.append(entry)
                else:
                    empty = False
            elif _is_ignorable_cleanup_file(entry):
                removable_files.append(entry)
            else:
                substantive.append(entry)
                empty = False
        return empty

    return visit(root), removable_files, removable_dirs, substantive


def _remove_dir_if_effectively_empty(root: Path) -> dict:
    """Remove ``root`` with rmdir-only semantics when it has no real content."""
    if not root.exists():
        return {"status": "missing", "path": str(root)}
    if not root.is_dir() or root.is_symlink():
        return {"status": "unsafe", "path": str(root), "reason": "not_directory"}

    empty, removable_files, removable_dirs, substantive = _effective_empty_plan(root)
    if not empty:
        return {
            "status": "kept",
            "path": str(root),
            "reason": "not_empty",
            "substantive_entries": [str(path) for path in substantive[:10]],
        }

    try:
        for path in removable_files:
            path.unlink(missing_ok=True)
        for path in sorted(removable_dirs, key=lambda item: len(item.parts), reverse=True):
            path.rmdir()
        root.rmdir()
    except OSError as exc:
        return {
            "status": "kept",
            "path": str(root),
            "reason": "rmdir_failed",
            "error": str(exc),
        }

    return {
        "status": "removed",
        "path": str(root),
        "removed_ignorable_files": len(removable_files),
        "removed_empty_dirs": len(removable_dirs),
    }


def _safe_cleanup_root(project_root: str, task_slug: str, root_path: str) -> tuple[bool, str]:
    if not project_root or not task_slug or not root_path:
        return False, "missing_cleanup_identity"
    canonical_project_root = normalize_path(project_root)
    slug = sanitize_token(task_slug)
    root = normalize_path(root_path)
    allowed_roots = {
        scratchlane_root(canonical_project_root, slug),
        legacy_scratchlane_root(canonical_project_root, slug),
    }
    if root not in allowed_roots:
        return False, "not_registered_scratchlane_root"
    tmp_parent = scratchlane_parent(canonical_project_root)
    if not is_path_under(tmp_parent, root):
        return False, "outside_project_tmp"
    if root in {canonical_project_root, tmp_parent, legacy_scratchlane_parent(canonical_project_root)}:
        return False, "root_too_broad"
    if Path(root).name != slug:
        return False, "task_slug_mismatch"
    return True, ""


def cleanup_empty_roots(
    conn: sqlite3.Connection,
    project_root: str,
    *,
    session_id: str = "",
) -> dict:
    """Remove empty scratchlane roots for a completed session.

    Cleanup is intentionally narrow: it only considers active scratchlane
    permits for ``project_root`` and, when supplied, ``session_id``. A directory
    is deleted only when its permit root matches the canonical local-tmp root
    or the legacy ``tmp/.claude-scratch`` root for that same task. The delete
    itself removes only known ignorable local clutter and empty directories,
    then calls ``rmdir`` on the scratchlane root. Non-empty roots are preserved.
    """
    canonical_project_root = normalize_path(project_root)
    items = list_active(conn, project_root=canonical_project_root)
    if session_id:
        items = [item for item in items if str(item.get("session_id") or "") == session_id]

    results: list[dict] = []
    removed_count = 0
    for item in items:
        task_slug = str(item.get("task_slug") or "")
        root_path = str(item.get("root_path") or "")
        safe, reason = _safe_cleanup_root(canonical_project_root, task_slug, root_path)
        if not safe:
            results.append(
                {
                    "status": "unsafe",
                    "path": root_path,
                    "task_slug": task_slug,
                    "reason": reason,
                }
            )
            continue

        result = _remove_dir_if_effectively_empty(Path(normalize_path(root_path)))
        result["task_slug"] = task_slug
        if result["status"] == "removed":
            removed_count += 1
        results.append(result)

    tmp_cleanup = None
    if removed_count:
        tmp_cleanup = _remove_dir_if_effectively_empty(Path(scratchlane_parent(canonical_project_root)))

    return {
        "project_root": canonical_project_root,
        "session_id": session_id,
        "items": results,
        "removed_count": removed_count,
        "tmp_cleanup": tmp_cleanup,
    }


def _same_pending_request(
    existing: dict | None,
    *,
    task_slug: str,
    root_path: str,
    requested_path: str,
    tool_name: str,
    request_reason: str,
    requested_by: str,
) -> bool:
    if existing is None:
        return False
    return (
        str(existing.get("task_slug") or "") == task_slug
        and str(existing.get("root_path") or "") == root_path
        and str(existing.get("requested_path") or "") == requested_path
        and str(existing.get("tool_name") or "") == tool_name
        and str(existing.get("request_reason") or "") == request_reason
        and str(existing.get("requested_by") or "") == requested_by
    )


def _request_with_state(record: dict, request_state: str) -> dict:
    return {**record, "request_state": request_state}


def request_approval(
    conn: sqlite3.Connection,
    *,
    session_id: str,
    project_root: str,
    task_slug: str,
    workflow_id: str = "",
    work_item_id: str = "",
    attempt_id: str = "",
    expires_at: int | None = None,
    requested_path: str = "",
    tool_name: str = "",
    request_reason: str = "",
    requested_by: str = "runtime",
) -> dict:
    """Record a pending scratchlane approval request for this session/project.

    At most one pending request remains active per ``(session_id, project_root)``
    pair. A newer distinct request supersedes the older pending one. An
    identical pending request is reused so repeated retries do not create
    duplicate state or repeated notifications.
    """
    if not session_id:
        raise ValueError("session_id is required for scratchlane approval requests")

    canonical_project_root = normalize_path(project_root)
    slug = sanitize_token(task_slug)
    root_path = scratchlane_root(canonical_project_root, slug)
    requested_path = requested_path or ""
    tool_name = tool_name or ""
    request_reason = request_reason or ""
    requested_by = requested_by or "runtime"
    existing = get_pending(conn, session_id=session_id, project_root=canonical_project_root)
    if _same_pending_request(
        existing,
        task_slug=slug,
        root_path=root_path,
        requested_path=requested_path,
        tool_name=tool_name,
        request_reason=request_reason,
        requested_by=requested_by,
    ):
        return _request_with_state(existing, "existing")

    now = int(time.time())

    with conn:
        if existing is not None:
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
                (session_id, project_root, task_slug, root_path, workflow_id,
                 work_item_id, attempt_id, capabilities_json, expires_at,
                 requested_path, tool_name, request_reason, requested_by,
                 requested_at, status, resolved_at, resolution_note)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, '')
            """,
            (
                session_id,
                canonical_project_root,
                slug,
                root_path,
                workflow_id or None,
                work_item_id or None,
                attempt_id or None,
                json.dumps(["write_scratch", "run_interpreter_wrapped"]),
                expires_at,
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
    request_state = "replaced" if existing is not None else "created"
    return _request_with_state(record, request_state)


def get_pending(
    conn: sqlite3.Connection,
    *,
    session_id: str,
    project_root: str,
) -> Optional[dict]:
    """Return the active pending request for this session/project, if any."""
    row = conn.execute(
        """
        SELECT id, session_id, project_root, task_slug, root_path, workflow_id,
               work_item_id, attempt_id, capabilities_json, expires_at, requested_path,
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
        SELECT id, session_id, project_root, task_slug, root_path, workflow_id,
               work_item_id, attempt_id, capabilities_json, expires_at, requested_path,
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


def build_pending_notification(request: dict) -> dict:
    """Return the user-attention notification payload for a pending request."""
    task_slug = str(request.get("task_slug") or "task")
    root_path = str(request.get("root_path") or "")
    requested_path = str(request.get("requested_path") or "")
    message = (
        f"Reply yes or no to approve scratchlane {root_path} for task '{task_slug}'."
    )
    if requested_path:
        message += f" Blocked path: {requested_path}."
    return {
        "notification_type": "scratchlane_approval_needed",
        "title": "Scratchlane Approval Needed",
        "message": message,
        "task_slug": task_slug,
        "root_path": root_path,
        "requested_path": requested_path,
    }


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
            "tmp/",
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
                session_id=str(request.get("session_id") or ""),
                workflow_id=str(request.get("workflow_id") or ""),
                work_item_id=str(request.get("work_item_id") or ""),
                attempt_id=str(request.get("attempt_id") or ""),
                expires_at=request.get("expires_at"),
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
            "additional_context": _resolution_message(
                request,
                resolution="approved",
                permit=permit,
            ),
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
