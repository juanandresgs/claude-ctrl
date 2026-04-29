"""One-shot admission tokens for local workflow bootstrap.

Bootstrap request tokens are the narrow authority that allows
``workflow bootstrap-local`` to mutate runtime state for a fresh repo. They are
separate from destructive git approvals because they govern workflow genesis,
not landing-time history mutation.
"""

from __future__ import annotations

import json
import secrets
import sqlite3
import time
from typing import Any

from runtime.core import events as events_mod

DEFAULT_TTL_SECONDS = 30 * 60


class BootstrapRequestError(ValueError):
    """Raised when bootstrap admission cannot be issued or consumed."""


def _event_source(workflow_id: str) -> str:
    return f"workflow:{workflow_id}"


def _detail(**payload: Any) -> str:
    return json.dumps(payload, sort_keys=True)


def issue(
    conn: sqlite3.Connection,
    *,
    workflow_id: str,
    worktree_path: str,
    requested_by: str,
    justification: str,
    payload: dict[str, Any],
    ttl_seconds: int = DEFAULT_TTL_SECONDS,
) -> dict[str, Any]:
    """Create a one-shot bootstrap request token and audit the issuance."""
    workflow_id = (workflow_id or "").strip()
    worktree_path = (worktree_path or "").strip()
    requested_by = (requested_by or "").strip()
    justification = (justification or "").strip()

    if not workflow_id:
        raise BootstrapRequestError("workflow_id must be a non-empty string")
    if not worktree_path:
        raise BootstrapRequestError("worktree_path must be a non-empty string")
    if not requested_by:
        raise BootstrapRequestError("--requested-by is required")
    if not justification:
        raise BootstrapRequestError("--justification is required")
    if ttl_seconds <= 0:
        raise BootstrapRequestError("--ttl-seconds must be a positive integer")

    now = int(time.time())
    expires_at = now + ttl_seconds
    token = f"bsr_{secrets.token_urlsafe(18)}"
    payload_json = json.dumps(payload, sort_keys=True)
    with conn:
        conn.execute(
            """
            INSERT INTO bootstrap_requests (
                token,
                workflow_id,
                worktree_path,
                requested_by,
                justification,
                payload_json,
                created_at,
                expires_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                token,
                workflow_id,
                worktree_path,
                requested_by,
                justification,
                payload_json,
                now,
                expires_at,
            ),
        )
        events_mod.emit(
            conn,
            "workflow.bootstrap.requested",
            source=_event_source(workflow_id),
            detail=_detail(
                workflow_id=workflow_id,
                worktree_path=worktree_path,
                requested_by=requested_by,
                justification=justification,
                expires_at=expires_at,
            ),
        )
    return {
        "token": token,
        "workflow_id": workflow_id,
        "worktree_path": worktree_path,
        "requested_by": requested_by,
        "justification": justification,
        "payload": payload,
        "created_at": now,
        "expires_at": expires_at,
        "consumed": False,
    }


def resolve_pending(
    conn: sqlite3.Connection,
    *,
    token: str,
    workflow_id: str,
    worktree_path: str,
) -> dict[str, Any]:
    """Validate a pending bootstrap request without consuming it."""
    now = int(time.time())
    row = conn.execute(
        """
        SELECT token, workflow_id, worktree_path, requested_by, justification,
               payload_json, created_at, expires_at, consumed, consumed_at, consumed_by
        FROM bootstrap_requests
        WHERE token = ?
        """,
        (token,),
    ).fetchone()

    if row is None:
        events_mod.emit(
            conn,
            "workflow.bootstrap.denied",
            source=_event_source(workflow_id),
            detail=_detail(
                workflow_id=workflow_id,
                worktree_path=worktree_path,
                reason="token_not_found",
            ),
        )
        raise BootstrapRequestError("bootstrap token not found")

    result = dict(row)
    if result["workflow_id"] != workflow_id:
        events_mod.emit(
            conn,
            "workflow.bootstrap.denied",
            source=_event_source(workflow_id),
            detail=_detail(
                workflow_id=workflow_id,
                worktree_path=worktree_path,
                reason="workflow_mismatch",
                token_workflow_id=result["workflow_id"],
            ),
        )
        raise BootstrapRequestError(
            f"bootstrap token authorizes workflow {result['workflow_id']!r}, not {workflow_id!r}"
        )
    if result["worktree_path"] != worktree_path:
        events_mod.emit(
            conn,
            "workflow.bootstrap.denied",
            source=_event_source(workflow_id),
            detail=_detail(
                workflow_id=workflow_id,
                worktree_path=worktree_path,
                reason="worktree_mismatch",
                token_worktree_path=result["worktree_path"],
            ),
        )
        raise BootstrapRequestError(
            "bootstrap token authorizes a different worktree path; "
            f"expected {result['worktree_path']!r}, got {worktree_path!r}"
        )
    if int(result["consumed"] or 0):
        events_mod.emit(
            conn,
            "workflow.bootstrap.denied",
            source=_event_source(workflow_id),
            detail=_detail(
                workflow_id=workflow_id,
                worktree_path=worktree_path,
                reason="already_consumed",
                consumed_at=result["consumed_at"],
            ),
        )
        raise BootstrapRequestError("bootstrap token has already been consumed")
    if int(result["expires_at"]) < now:
        events_mod.emit(
            conn,
            "workflow.bootstrap.denied",
            source=_event_source(workflow_id),
            detail=_detail(
                workflow_id=workflow_id,
                worktree_path=worktree_path,
                reason="expired",
                expires_at=result["expires_at"],
            ),
        )
        raise BootstrapRequestError("bootstrap token has expired; request a new bootstrap token")

    payload = json.loads(result["payload_json"] or "{}")
    result["payload"] = payload
    return result


def consume(
    conn: sqlite3.Connection,
    *,
    token: str,
    workflow_id: str,
    worktree_path: str,
    consumed_by: str = "workflow bootstrap-local",
) -> dict[str, Any]:
    """Mark a valid bootstrap request token as consumed and audit it."""
    request = resolve_pending(
        conn,
        token=token,
        workflow_id=workflow_id,
        worktree_path=worktree_path,
    )
    now = int(time.time())
    with conn:
        cursor = conn.execute(
            """
            UPDATE bootstrap_requests
            SET consumed = 1, consumed_at = ?, consumed_by = ?
            WHERE token = ? AND consumed = 0
            """,
            (now, consumed_by, token),
        )
        if cursor.rowcount != 1:
            raise BootstrapRequestError(
                "bootstrap token could not be consumed atomically; request a new token"
            )
        events_mod.emit(
            conn,
            "workflow.bootstrap.consumed",
            source=_event_source(workflow_id),
            detail=_detail(
                workflow_id=workflow_id,
                worktree_path=worktree_path,
                requested_by=request["requested_by"],
                consumed_by=consumed_by,
            ),
        )
    request["consumed"] = True
    request["consumed_at"] = now
    request["consumed_by"] = consumed_by
    return request


__all__ = [
    "BootstrapRequestError",
    "DEFAULT_TTL_SECONDS",
    "consume",
    "issue",
    "resolve_pending",
]
