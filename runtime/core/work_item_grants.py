"""Work-item landing grants.

This module owns the durable permission envelope attached to a work item.
Policies consume this as data instead of asking the user again for routine
branch commits or Guardian landing operations.
"""

from __future__ import annotations

import json
import sqlite3
import time
from dataclasses import dataclass
from typing import Iterable, Optional

from runtime.schemas import APPROVAL_OP_TYPES

MERGE_STRATEGIES: frozenset[str] = frozenset({"no_ff", "ff_only", "squash", "manual"})
DEFAULT_REQUIRES_USER_APPROVAL: tuple[str, ...] = (
    "rebase",
    "reset",
    "force_push",
    "destructive_cleanup",
    "plumbing",
    "admin_recovery",
)


@dataclass(frozen=True)
class WorkItemGrant:
    """Durable git/landing grant for a work item."""

    work_item_id: str
    workflow_id: str
    can_commit_branch: bool = True
    can_request_review: bool = True
    can_autoland: bool = True
    merge_strategy: str = "no_ff"
    requires_user_approval: tuple[str, ...] = DEFAULT_REQUIRES_USER_APPROVAL
    granted_by: str = "planner"
    created_at: int = 0
    updated_at: int = 0
    source: str = "persisted"

    def __post_init__(self) -> None:
        if not self.work_item_id:
            raise ValueError("work_item_id must be non-empty")
        if not self.workflow_id:
            raise ValueError("workflow_id must be non-empty")
        if self.merge_strategy not in MERGE_STRATEGIES:
            raise ValueError(
                f"unknown merge_strategy {self.merge_strategy!r}; "
                f"valid: {sorted(MERGE_STRATEGIES)}"
            )
        unknown = sorted(set(self.requires_user_approval) - set(APPROVAL_OP_TYPES))
        if unknown:
            raise ValueError(
                f"unknown approval op(s) {unknown}; valid: {sorted(APPROVAL_OP_TYPES)}"
            )
        if not self.granted_by:
            raise ValueError("granted_by must be non-empty")

    def as_dict(self) -> dict:
        return {
            "work_item_id": self.work_item_id,
            "workflow_id": self.workflow_id,
            "can_commit_branch": self.can_commit_branch,
            "can_request_review": self.can_request_review,
            "can_autoland": self.can_autoland,
            "merge_strategy": self.merge_strategy,
            "requires_user_approval": list(self.requires_user_approval),
            "granted_by": self.granted_by,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "source": self.source,
        }


def _json_list(values: Iterable[str]) -> str:
    return json.dumps(tuple(values), separators=(",", ":"))


def _parse_required_ops(raw: object) -> tuple[str, ...]:
    if raw in (None, ""):
        return DEFAULT_REQUIRES_USER_APPROVAL
    if isinstance(raw, str):
        parsed = json.loads(raw)
    else:
        parsed = raw
    if not isinstance(parsed, list):
        raise ValueError("requires_user_approval_json must be a JSON list")
    result: list[str] = []
    for index, value in enumerate(parsed):
        if not isinstance(value, str) or not value:
            raise ValueError(
                "requires_user_approval_json must contain non-empty strings "
                f"(bad item at index {index})"
            )
        result.append(value)
    return tuple(result)


def default_grant(
    *,
    workflow_id: str,
    work_item_id: str,
    granted_by: str = "planner",
    source: str = "default",
) -> WorkItemGrant:
    """Return the default grant every new work item receives."""
    now = int(time.time())
    return WorkItemGrant(
        workflow_id=workflow_id,
        work_item_id=work_item_id,
        granted_by=granted_by,
        created_at=now,
        updated_at=now,
        source=source,
    )


def _row_to_grant(row: sqlite3.Row) -> WorkItemGrant:
    return WorkItemGrant(
        work_item_id=row["work_item_id"],
        workflow_id=row["workflow_id"],
        can_commit_branch=bool(row["can_commit_branch"]),
        can_request_review=bool(row["can_request_review"]),
        can_autoland=bool(row["can_autoland"]),
        merge_strategy=row["merge_strategy"],
        requires_user_approval=_parse_required_ops(row["requires_user_approval_json"]),
        granted_by=row["granted_by"],
        created_at=int(row["created_at"]),
        updated_at=int(row["updated_at"]),
        source="persisted",
    )


def upsert(conn: sqlite3.Connection, grant: WorkItemGrant) -> WorkItemGrant:
    """Insert or update a work-item grant."""
    now = int(time.time())
    created_at = grant.created_at or now
    updated_at = now
    with conn:
        conn.execute(
            """
            INSERT INTO work_item_grants (
                work_item_id, workflow_id, can_commit_branch, can_request_review,
                can_autoland, merge_strategy, requires_user_approval_json,
                granted_by, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(work_item_id) DO UPDATE SET
                workflow_id = excluded.workflow_id,
                can_commit_branch = excluded.can_commit_branch,
                can_request_review = excluded.can_request_review,
                can_autoland = excluded.can_autoland,
                merge_strategy = excluded.merge_strategy,
                requires_user_approval_json = excluded.requires_user_approval_json,
                granted_by = excluded.granted_by,
                updated_at = excluded.updated_at
            """,
            (
                grant.work_item_id,
                grant.workflow_id,
                1 if grant.can_commit_branch else 0,
                1 if grant.can_request_review else 0,
                1 if grant.can_autoland else 0,
                grant.merge_strategy,
                _json_list(grant.requires_user_approval),
                grant.granted_by,
                created_at,
                updated_at,
            ),
        )
    return get(conn, grant.work_item_id) or WorkItemGrant(
        **{**grant.as_dict(), "created_at": created_at, "updated_at": updated_at}
    )


def ensure_default(
    conn: sqlite3.Connection,
    *,
    workflow_id: str,
    work_item_id: str,
    granted_by: str = "planner",
) -> WorkItemGrant:
    """Create the default grant for a work item if none exists."""
    existing = get(conn, work_item_id)
    if existing is not None:
        return existing
    return upsert(
        conn,
        default_grant(
            workflow_id=workflow_id,
            work_item_id=work_item_id,
            granted_by=granted_by,
        ),
    )


def get(conn: sqlite3.Connection, work_item_id: str) -> Optional[WorkItemGrant]:
    """Return a persisted work-item grant, or None when absent."""
    row = conn.execute(
        """
        SELECT work_item_id, workflow_id, can_commit_branch, can_request_review,
               can_autoland, merge_strategy, requires_user_approval_json,
               granted_by, created_at, updated_at
        FROM work_item_grants
        WHERE work_item_id = ?
        """,
        (work_item_id,),
    ).fetchone()
    return _row_to_grant(row) if row else None


def effective(
    conn: sqlite3.Connection,
    *,
    workflow_id: str,
    work_item_id: str,
) -> WorkItemGrant:
    """Return the persisted grant or the default grant for legacy work items."""
    existing = get(conn, work_item_id)
    if existing is not None:
        return existing
    return default_grant(
        workflow_id=workflow_id,
        work_item_id=work_item_id,
        source="legacy_default",
    )


__all__ = [
    "DEFAULT_REQUIRES_USER_APPROVAL",
    "MERGE_STRATEGIES",
    "WorkItemGrant",
    "default_grant",
    "effective",
    "ensure_default",
    "get",
    "upsert",
]
