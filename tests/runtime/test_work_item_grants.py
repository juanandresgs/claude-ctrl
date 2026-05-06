"""Tests for durable work-item landing grants."""

from __future__ import annotations

import sqlite3

import pytest

from runtime.core import work_item_grants as wig
from runtime.schemas import ensure_schema


@pytest.fixture
def conn():
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


def test_ensure_default_persists_autoland_grant(conn):
    grant = wig.ensure_default(
        conn,
        workflow_id="wf-grant",
        work_item_id="wi-grant",
        granted_by="planner",
    )

    assert grant.can_commit_branch is True
    assert grant.can_request_review is True
    assert grant.can_autoland is True
    assert grant.merge_strategy == "no_ff"
    assert "non_ff_merge" not in grant.requires_user_approval

    stored = wig.get(conn, "wi-grant")
    assert stored is not None
    assert stored.as_dict()["source"] == "persisted"


def test_upsert_can_disable_autoland(conn):
    stored = wig.upsert(
        conn,
        wig.WorkItemGrant(
            workflow_id="wf-grant",
            work_item_id="wi-grant",
            can_commit_branch=False,
            can_request_review=True,
            can_autoland=False,
            merge_strategy="manual",
            requires_user_approval=("non_ff_merge", "admin_recovery"),
            granted_by="user",
        ),
    )

    assert stored.can_commit_branch is False
    assert stored.can_autoland is False
    assert stored.merge_strategy == "manual"
    assert stored.requires_user_approval == ("non_ff_merge", "admin_recovery")
    assert stored.granted_by == "user"


def test_effective_returns_legacy_default_without_write(conn):
    before = conn.total_changes
    grant = wig.effective(conn, workflow_id="wf-legacy", work_item_id="wi-legacy")

    assert grant.source == "legacy_default"
    assert grant.can_autoland is True
    assert conn.total_changes == before


def test_unknown_approval_op_is_rejected():
    with pytest.raises(ValueError, match="unknown approval op"):
        wig.WorkItemGrant(
            workflow_id="wf",
            work_item_id="wi",
            requires_user_approval=("not_an_op",),
        )
