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
    db_path: str | None = None,
) -> dict[str, Any]:
    """Validate a pending bootstrap request without consuming it.

    ``db_path`` is optional but strongly recommended when the caller has already
    resolved the target DB path (e.g. from ``resolve_local_workflow_bootstrap_target``).
    When provided, token-not-found errors include the DB path and a scoping hint
    so operators who passed the wrong ``--worktree-path`` get an actionable message.
    When omitted the error falls back to the terse legacy form.
    """
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
        # @decision DEC-ADMIT-002
        # Title: token-not-found error names the resolved DB path and worktree scope
        # Status: accepted
        # Rationale: Operators passing the wrong --worktree-path see a DB resolved to
        #   the wrong location and get a confusing "token not found" message with no
        #   actionable next step. By surfacing the db_path and a per-worktree scoping
        #   hint we give operators the information they need to rerun bootstrap-request
        #   from the correct worktree. Cross-DB lookups are out of scope (TTL is the
        #   safety net, #70 deferred).
        if db_path is not None:
            raise BootstrapRequestError(
                f"bootstrap token not found in {db_path}. "
                "Bootstrap tokens are scoped to the worktree where bootstrap-request "
                "was run — if you passed a different --worktree-path for bootstrap-local, "
                "rerun `bootstrap-request` from that worktree first, then use the new token."
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
    db_path: str | None = None,
) -> dict[str, Any]:
    """Mark a valid bootstrap request token as consumed and audit it.

    ``db_path`` is threaded through to ``resolve_pending`` so token-not-found
    errors produced during the atomic consume step also carry the actionable
    scoping hint (DEC-ADMIT-002).
    """
    request = resolve_pending(
        conn,
        token=token,
        workflow_id=workflow_id,
        worktree_path=worktree_path,
        db_path=db_path,
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
