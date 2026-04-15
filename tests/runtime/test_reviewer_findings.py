"""Unit tests for runtime/core/reviewer_findings.py

@decision DEC-CLAUDEX-REVIEWER-FINDINGS-DOMAIN-001
Title: Tests for the reviewer findings domain authority (Phase 4)
Status: accepted
Rationale: Exercises schema existence, dataclass validation, insert/get/list
  round trips, upsert determinism, status transitions, and import discipline.
  Proves the ledger can back REVIEW_FINDINGS_JSON from the completion schema
  without requiring evaluation_state or routing imports.
"""

from __future__ import annotations

import ast
import importlib
import inspect
import sqlite3
import time

import pytest

from runtime.core import reviewer_findings as rf
from runtime.schemas import (
    FINDING_SEVERITIES,
    FINDING_STATUSES,
    ensure_schema,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    """In-memory SQLite connection with full schema applied."""
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


def _insert_finding(conn, **overrides):
    defaults = {
        "workflow_id": "wf-1",
        "severity": "blocking",
        "title": "Missing error handling",
        "detail": "The function does not handle the None case.",
    }
    defaults.update(overrides)
    return rf.insert(conn, **defaults)


# ---------------------------------------------------------------------------
# Schema: table and indexes exist
# ---------------------------------------------------------------------------


class TestSchema:
    def test_reviewer_findings_table_exists(self, conn):
        tables = {
            row[0]
            for row in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall()
        }
        assert "reviewer_findings" in tables

    def test_workflow_index_exists(self, conn):
        indexes = {
            row[0]
            for row in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='index'"
            ).fetchall()
        }
        assert "idx_reviewer_findings_workflow" in indexes

    def test_status_index_exists(self, conn):
        indexes = {
            row[0]
            for row in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='index'"
            ).fetchall()
        }
        assert "idx_reviewer_findings_status" in indexes

    def test_severity_index_exists(self, conn):
        indexes = {
            row[0]
            for row in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='index'"
            ).fetchall()
        }
        assert "idx_reviewer_findings_severity" in indexes

    def test_table_has_expected_columns(self, conn):
        columns = {
            row[1]
            for row in conn.execute(
                "PRAGMA table_info(reviewer_findings)"
            ).fetchall()
        }
        expected = {
            "finding_id", "workflow_id", "work_item_id", "reviewer_round",
            "head_sha", "severity", "status", "title", "detail",
            "file_path", "line", "created_at", "updated_at",
        }
        assert expected == columns


# ---------------------------------------------------------------------------
# Dataclass validation
# ---------------------------------------------------------------------------


class TestDataclassValidation:
    def test_valid_construction(self):
        f = rf.ReviewerFinding(
            finding_id="f-1",
            workflow_id="wf-1",
            severity="blocking",
            status="open",
            title="Test",
            detail="Detail",
            created_at=1000,
            updated_at=1000,
        )
        assert f.finding_id == "f-1"
        assert f.status == "open"
        assert f.severity == "blocking"

    def test_empty_finding_id_rejected(self):
        with pytest.raises(ValueError, match="finding_id"):
            rf.ReviewerFinding(
                finding_id="", workflow_id="wf", severity="note",
                status="open", title="T", detail="D",
                created_at=0, updated_at=0,
            )

    def test_empty_workflow_id_rejected(self):
        with pytest.raises(ValueError, match="workflow_id"):
            rf.ReviewerFinding(
                finding_id="f", workflow_id="", severity="note",
                status="open", title="T", detail="D",
                created_at=0, updated_at=0,
            )

    def test_empty_title_rejected(self):
        with pytest.raises(ValueError, match="title"):
            rf.ReviewerFinding(
                finding_id="f", workflow_id="wf", severity="note",
                status="open", title="", detail="D",
                created_at=0, updated_at=0,
            )

    def test_empty_detail_rejected(self):
        with pytest.raises(ValueError, match="detail"):
            rf.ReviewerFinding(
                finding_id="f", workflow_id="wf", severity="note",
                status="open", title="T", detail="",
                created_at=0, updated_at=0,
            )

    def test_invalid_severity_rejected(self):
        with pytest.raises(ValueError, match="severity"):
            rf.ReviewerFinding(
                finding_id="f", workflow_id="wf", severity="critical",
                status="open", title="T", detail="D",
                created_at=0, updated_at=0,
            )

    def test_invalid_status_rejected(self):
        with pytest.raises(ValueError, match="status"):
            rf.ReviewerFinding(
                finding_id="f", workflow_id="wf", severity="note",
                status="closed", title="T", detail="D",
                created_at=0, updated_at=0,
            )

    def test_negative_reviewer_round_rejected(self):
        with pytest.raises(ValueError, match="reviewer_round"):
            rf.ReviewerFinding(
                finding_id="f", workflow_id="wf", severity="note",
                status="open", title="T", detail="D",
                created_at=0, updated_at=0, reviewer_round=-1,
            )

    def test_negative_line_rejected(self):
        with pytest.raises(ValueError, match="line"):
            rf.ReviewerFinding(
                finding_id="f", workflow_id="wf", severity="note",
                status="open", title="T", detail="D",
                created_at=0, updated_at=0, line=-1,
            )

    def test_negative_created_at_rejected(self):
        with pytest.raises(ValueError, match="created_at"):
            rf.ReviewerFinding(
                finding_id="f", workflow_id="wf", severity="note",
                status="open", title="T", detail="D",
                created_at=-1, updated_at=0,
            )

    def test_negative_updated_at_rejected(self):
        with pytest.raises(ValueError, match="updated_at"):
            rf.ReviewerFinding(
                finding_id="f", workflow_id="wf", severity="note",
                status="open", title="T", detail="D",
                created_at=0, updated_at=-1,
            )

    def test_line_zero_rejected(self):
        with pytest.raises(ValueError, match="line"):
            rf.ReviewerFinding(
                finding_id="f", workflow_id="wf", severity="note",
                status="open", title="T", detail="D",
                created_at=0, updated_at=0, line=0,
            )

    def test_line_one_accepted(self):
        f = rf.ReviewerFinding(
            finding_id="f", workflow_id="wf", severity="note",
            status="open", title="T", detail="D",
            created_at=0, updated_at=0, line=1,
        )
        assert f.line == 1

    def test_bool_reviewer_round_rejected(self):
        with pytest.raises(ValueError, match="must be an int"):
            rf.ReviewerFinding(
                finding_id="f", workflow_id="wf", severity="note",
                status="open", title="T", detail="D",
                created_at=0, updated_at=0, reviewer_round=True,
            )

    def test_bool_line_rejected(self):
        with pytest.raises(ValueError, match="must be an int"):
            rf.ReviewerFinding(
                finding_id="f", workflow_id="wf", severity="note",
                status="open", title="T", detail="D",
                created_at=0, updated_at=0, line=True,
            )

    def test_bool_created_at_rejected(self):
        with pytest.raises(ValueError, match="must be an int"):
            rf.ReviewerFinding(
                finding_id="f", workflow_id="wf", severity="note",
                status="open", title="T", detail="D",
                created_at=True, updated_at=0,
            )

    def test_bool_updated_at_rejected(self):
        with pytest.raises(ValueError, match="must be an int"):
            rf.ReviewerFinding(
                finding_id="f", workflow_id="wf", severity="note",
                status="open", title="T", detail="D",
                created_at=0, updated_at=False,
            )

    def test_all_valid_severities_accepted(self):
        for sev in sorted(FINDING_SEVERITIES):
            f = rf.ReviewerFinding(
                finding_id="f", workflow_id="wf", severity=sev,
                status="open", title="T", detail="D",
                created_at=0, updated_at=0,
            )
            assert f.severity == sev

    def test_all_valid_statuses_accepted(self):
        for st in sorted(FINDING_STATUSES):
            f = rf.ReviewerFinding(
                finding_id="f", workflow_id="wf", severity="note",
                status=st, title="T", detail="D",
                created_at=0, updated_at=0,
            )
            assert f.status == st


# ---------------------------------------------------------------------------
# Insert / get round trip
# ---------------------------------------------------------------------------


class TestInsertGet:
    def test_insert_returns_finding_with_open_status(self, conn):
        f = _insert_finding(conn)
        assert f.status == "open"
        assert f.severity == "blocking"
        assert f.finding_id  # non-empty

    def test_insert_generates_finding_id(self, conn):
        f = _insert_finding(conn)
        assert len(f.finding_id) > 0

    def test_insert_with_explicit_finding_id(self, conn):
        f = _insert_finding(conn, finding_id="custom-id")
        assert f.finding_id == "custom-id"

    def test_get_returns_inserted_finding(self, conn):
        f = _insert_finding(conn, finding_id="f-get")
        got = rf.get(conn, "f-get")
        assert got is not None
        assert got.finding_id == "f-get"
        assert got.workflow_id == f.workflow_id
        assert got.severity == f.severity
        assert got.title == f.title
        assert got.detail == f.detail

    def test_get_nonexistent_returns_none(self, conn):
        assert rf.get(conn, "nonexistent") is None

    def test_insert_with_all_optional_fields(self, conn):
        f = _insert_finding(
            conn,
            finding_id="f-full",
            work_item_id="wi-1",
            reviewer_round=2,
            head_sha="abc123",
            file_path="src/main.py",
            line=42,
        )
        got = rf.get(conn, "f-full")
        assert got is not None
        assert got.work_item_id == "wi-1"
        assert got.reviewer_round == 2
        assert got.head_sha == "abc123"
        assert got.file_path == "src/main.py"
        assert got.line == 42

    def test_insert_timestamps_are_positive(self, conn):
        f = _insert_finding(conn)
        assert f.created_at > 0
        assert f.updated_at > 0

    def test_duplicate_finding_id_raises(self, conn):
        _insert_finding(conn, finding_id="dup")
        with pytest.raises(sqlite3.IntegrityError):
            _insert_finding(conn, finding_id="dup")


# ---------------------------------------------------------------------------
# List findings
# ---------------------------------------------------------------------------


class TestListFindings:
    def test_list_all(self, conn):
        _insert_finding(conn, finding_id="f-1")
        _insert_finding(conn, finding_id="f-2")
        results = rf.list_findings(conn)
        assert len(results) == 2

    def test_list_by_workflow_id(self, conn):
        _insert_finding(conn, finding_id="f-1", workflow_id="wf-a")
        _insert_finding(conn, finding_id="f-2", workflow_id="wf-b")
        results = rf.list_findings(conn, workflow_id="wf-a")
        assert len(results) == 1
        assert results[0].workflow_id == "wf-a"

    def test_list_by_status(self, conn):
        _insert_finding(conn, finding_id="f-1")
        _insert_finding(conn, finding_id="f-2")
        rf.resolve(conn, "f-1")
        results = rf.list_findings(conn, status="open")
        assert len(results) == 1
        assert results[0].finding_id == "f-2"

    def test_list_by_severity(self, conn):
        _insert_finding(conn, finding_id="f-1", severity="blocking")
        _insert_finding(conn, finding_id="f-2", severity="note")
        results = rf.list_findings(conn, severity="blocking")
        assert len(results) == 1
        assert results[0].severity == "blocking"

    def test_list_by_work_item_id(self, conn):
        _insert_finding(conn, finding_id="f-1", work_item_id="wi-a")
        _insert_finding(conn, finding_id="f-2", work_item_id="wi-b")
        results = rf.list_findings(conn, work_item_id="wi-a")
        assert len(results) == 1

    def test_list_by_reviewer_round(self, conn):
        _insert_finding(conn, finding_id="f-1", reviewer_round=0)
        _insert_finding(conn, finding_id="f-2", reviewer_round=1)
        results = rf.list_findings(conn, reviewer_round=1)
        assert len(results) == 1
        assert results[0].reviewer_round == 1

    def test_list_empty(self, conn):
        results = rf.list_findings(conn, workflow_id="nonexistent")
        assert results == []

    # Filter validation
    def test_invalid_status_filter_raises(self, conn):
        with pytest.raises(ValueError, match="Invalid status filter"):
            rf.list_findings(conn, status="closed")

    def test_invalid_severity_filter_raises(self, conn):
        with pytest.raises(ValueError, match="Invalid severity filter"):
            rf.list_findings(conn, severity="critical")

    def test_negative_reviewer_round_filter_raises(self, conn):
        with pytest.raises(ValueError, match="reviewer_round filter must be >= 0"):
            rf.list_findings(conn, reviewer_round=-1)

    def test_bool_reviewer_round_filter_raises(self, conn):
        with pytest.raises(ValueError, match="reviewer_round filter must be an int"):
            rf.list_findings(conn, reviewer_round=True)


# ---------------------------------------------------------------------------
# Upsert
# ---------------------------------------------------------------------------


class TestUpsert:
    def test_upsert_inserts_new_finding(self, conn):
        f = rf.upsert(
            conn,
            finding_id="f-new",
            workflow_id="wf-1",
            severity="concern",
            status="open",
            title="New",
            detail="New detail",
        )
        assert f.finding_id == "f-new"
        got = rf.get(conn, "f-new")
        assert got is not None
        assert got.status == "open"

    def test_upsert_updates_existing_finding(self, conn):
        _insert_finding(conn, finding_id="f-up", severity="note", title="Original")
        rf.upsert(
            conn,
            finding_id="f-up",
            workflow_id="wf-1",
            severity="blocking",
            status="resolved",
            title="Updated",
            detail="Updated detail",
            head_sha="newsha",
            reviewer_round=2,
        )
        got = rf.get(conn, "f-up")
        assert got is not None
        assert got.severity == "blocking"
        assert got.status == "resolved"
        assert got.title == "Updated"
        assert got.detail == "Updated detail"
        assert got.head_sha == "newsha"
        assert got.reviewer_round == 2

    def test_upsert_preserves_created_at(self, conn):
        original = _insert_finding(conn, finding_id="f-ts")
        original_created = original.created_at
        # Small delay to ensure updated_at would differ
        rf.upsert(
            conn,
            finding_id="f-ts",
            workflow_id="wf-1",
            severity="note",
            status="waived",
            title="T",
            detail="D",
        )
        got = rf.get(conn, "f-ts")
        assert got is not None
        assert got.created_at == original_created

    def test_upsert_updates_file_path_and_line(self, conn):
        _insert_finding(conn, finding_id="f-loc", file_path="old.py", line=10)
        rf.upsert(
            conn,
            finding_id="f-loc",
            workflow_id="wf-1",
            severity="blocking",
            status="open",
            title="T",
            detail="D",
            file_path="new.py",
            line=42,
        )
        got = rf.get(conn, "f-loc")
        assert got is not None
        assert got.file_path == "new.py"
        assert got.line == 42

    def test_upsert_workflow_mismatch_raises(self, conn):
        """Upsert with a different workflow_id on an existing finding must
        raise ValueError — findings cannot silently migrate between workflows."""
        _insert_finding(conn, finding_id="f-wf", workflow_id="wf-original")
        with pytest.raises(ValueError, match="workflow_id mismatch"):
            rf.upsert(
                conn,
                finding_id="f-wf",
                workflow_id="wf-different",
                severity="note",
                status="open",
                title="T",
                detail="D",
            )
        # Verify original row is unchanged.
        got = rf.get(conn, "f-wf")
        assert got is not None
        assert got.workflow_id == "wf-original"

    def test_upsert_same_workflow_succeeds(self, conn):
        """Upsert with matching workflow_id proceeds normally."""
        _insert_finding(conn, finding_id="f-same-wf", workflow_id="wf-match")
        result = rf.upsert(
            conn,
            finding_id="f-same-wf",
            workflow_id="wf-match",
            severity="concern",
            status="resolved",
            title="Updated",
            detail="Updated detail",
        )
        assert result.workflow_id == "wf-match"
        assert result.severity == "concern"

    def test_upsert_updates_work_item_id(self, conn):
        """Upsert deterministically updates work_item_id to the caller's value."""
        _insert_finding(conn, finding_id="f-wi", work_item_id="wi-old")
        result = rf.upsert(
            conn,
            finding_id="f-wi",
            workflow_id="wf-1",
            severity="blocking",
            status="open",
            title="T",
            detail="D",
            work_item_id="wi-new",
        )
        assert result.work_item_id == "wi-new"

    def test_upsert_clears_work_item_id_to_none(self, conn):
        """Upsert with work_item_id=None clears the stored value."""
        _insert_finding(conn, finding_id="f-wi-clear", work_item_id="wi-old")
        result = rf.upsert(
            conn,
            finding_id="f-wi-clear",
            workflow_id="wf-1",
            severity="blocking",
            status="open",
            title="T",
            detail="D",
            work_item_id=None,
        )
        assert result.work_item_id is None

    def test_upsert_return_preserves_created_at(self, conn):
        """The returned object from upsert (not just a subsequent get) must
        carry the original created_at from the DB, not the fresh timestamp."""
        original = _insert_finding(conn, finding_id="f-ret-ts")
        original_created = original.created_at
        result = rf.upsert(
            conn,
            finding_id="f-ret-ts",
            workflow_id="wf-1",
            severity="note",
            status="waived",
            title="T",
            detail="D",
        )
        assert result.created_at == original_created

    # Upsert status-transition enforcement (single authority: _VALID_TRANSITIONS)

    def test_upsert_resolved_to_waived_raises(self, conn):
        """resolved -> waived is invalid; upsert must not bypass transitions."""
        _insert_finding(conn, finding_id="f-rw")
        rf.resolve(conn, "f-rw")
        with pytest.raises(ValueError, match="invalid status transition"):
            rf.upsert(
                conn,
                finding_id="f-rw",
                workflow_id="wf-1",
                severity="blocking",
                status="waived",
                title="T",
                detail="D",
            )
        # Row unchanged.
        got = rf.get(conn, "f-rw")
        assert got.status == "resolved"

    def test_upsert_waived_to_resolved_raises(self, conn):
        """waived -> resolved is invalid; upsert must not bypass transitions."""
        _insert_finding(conn, finding_id="f-wr")
        rf.waive(conn, "f-wr")
        with pytest.raises(ValueError, match="invalid status transition"):
            rf.upsert(
                conn,
                finding_id="f-wr",
                workflow_id="wf-1",
                severity="blocking",
                status="resolved",
                title="T",
                detail="D",
            )
        # Row unchanged.
        got = rf.get(conn, "f-wr")
        assert got.status == "waived"

    def test_upsert_open_to_open_allowed(self, conn):
        """Same-status upsert (no transition) is always allowed."""
        _insert_finding(conn, finding_id="f-oo")
        result = rf.upsert(
            conn,
            finding_id="f-oo",
            workflow_id="wf-1",
            severity="concern",
            status="open",
            title="Updated",
            detail="Updated",
        )
        assert result.status == "open"
        assert result.title == "Updated"

    def test_upsert_valid_transition_open_to_resolved(self, conn):
        """open -> resolved is valid; upsert should accept it."""
        _insert_finding(conn, finding_id="f-or")
        result = rf.upsert(
            conn,
            finding_id="f-or",
            workflow_id="wf-1",
            severity="blocking",
            status="resolved",
            title="T",
            detail="D",
        )
        assert result.status == "resolved"

    def test_upsert_invalid_transition_does_not_mutate(self, conn):
        """Failed status transition via upsert must not change any field."""
        _insert_finding(conn, finding_id="f-nomut", severity="note", title="Original")
        rf.resolve(conn, "f-nomut")
        before = rf.get(conn, "f-nomut")
        with pytest.raises(ValueError):
            rf.upsert(
                conn,
                finding_id="f-nomut",
                workflow_id="wf-1",
                severity="blocking",
                status="waived",
                title="Changed",
                detail="Changed",
            )
        after = rf.get(conn, "f-nomut")
        assert after.status == before.status
        assert after.severity == before.severity
        assert after.title == before.title
        assert after.updated_at == before.updated_at


# ---------------------------------------------------------------------------
# Status transitions
# ---------------------------------------------------------------------------


class TestStatusTransitions:
    """Enforced transition model:
    open → resolved, open → waived, resolved → open, waived → open.
    All other transitions raise ValueError."""

    def test_resolve_from_open(self, conn):
        _insert_finding(conn, finding_id="f-res")
        result = rf.resolve(conn, "f-res")
        assert result is not None
        assert result.status == "resolved"

    def test_waive_from_open(self, conn):
        _insert_finding(conn, finding_id="f-waive")
        result = rf.waive(conn, "f-waive")
        assert result is not None
        assert result.status == "waived"

    def test_reopen_from_resolved(self, conn):
        _insert_finding(conn, finding_id="f-reopen")
        rf.resolve(conn, "f-reopen")
        result = rf.reopen(conn, "f-reopen")
        assert result is not None
        assert result.status == "open"

    def test_reopen_from_waived(self, conn):
        _insert_finding(conn, finding_id="f-reopen-w")
        rf.waive(conn, "f-reopen-w")
        result = rf.reopen(conn, "f-reopen-w")
        assert result is not None
        assert result.status == "open"

    def test_transition_updates_updated_at(self, conn):
        original = _insert_finding(conn, finding_id="f-time")
        original_updated = original.updated_at
        result = rf.resolve(conn, "f-time")
        assert result is not None
        assert result.updated_at >= original_updated

    def test_transition_nonexistent_returns_none(self, conn):
        result = rf.resolve(conn, "nonexistent")
        assert result is None

    # Invalid transitions
    def test_resolve_already_resolved_raises(self, conn):
        _insert_finding(conn, finding_id="f-rr")
        rf.resolve(conn, "f-rr")
        with pytest.raises(ValueError, match="Invalid status transition"):
            rf.resolve(conn, "f-rr")

    def test_waive_already_waived_raises(self, conn):
        _insert_finding(conn, finding_id="f-ww")
        rf.waive(conn, "f-ww")
        with pytest.raises(ValueError, match="Invalid status transition"):
            rf.waive(conn, "f-ww")

    def test_waive_resolved_raises(self, conn):
        """resolved → waived is not a valid transition."""
        _insert_finding(conn, finding_id="f-rw")
        rf.resolve(conn, "f-rw")
        with pytest.raises(ValueError, match="Invalid status transition"):
            rf.waive(conn, "f-rw")

    def test_resolve_waived_raises(self, conn):
        """waived → resolved is not a valid transition."""
        _insert_finding(conn, finding_id="f-wr")
        rf.waive(conn, "f-wr")
        with pytest.raises(ValueError, match="Invalid status transition"):
            rf.resolve(conn, "f-wr")

    def test_reopen_already_open_raises(self, conn):
        """open → open is not a valid transition."""
        _insert_finding(conn, finding_id="f-oo")
        with pytest.raises(ValueError, match="Invalid status transition"):
            rf.reopen(conn, "f-oo")

    def test_invalid_transition_does_not_mutate(self, conn):
        """Failed transition must leave the finding unchanged."""
        _insert_finding(conn, finding_id="f-nomut")
        rf.resolve(conn, "f-nomut")
        original = rf.get(conn, "f-nomut")
        with pytest.raises(ValueError):
            rf.resolve(conn, "f-nomut")
        after = rf.get(conn, "f-nomut")
        assert after is not None
        assert after.status == original.status
        assert after.updated_at == original.updated_at

    def test_valid_transitions_table_covers_all_statuses(self):
        """Every status in FINDING_STATUSES has an entry in _VALID_TRANSITIONS."""
        for status in FINDING_STATUSES:
            assert status in rf._VALID_TRANSITIONS, (
                f"Status {status!r} missing from _VALID_TRANSITIONS"
            )


# ---------------------------------------------------------------------------
# Vocabulary constants
# ---------------------------------------------------------------------------


class TestVocabularyConstants:
    def test_finding_statuses_match_schema(self):
        assert FINDING_STATUSES == frozenset({"open", "resolved", "waived"})

    def test_finding_severities_match_schema(self):
        assert FINDING_SEVERITIES == frozenset({"blocking", "concern", "note"})

    def test_domain_module_re_exports_statuses(self):
        assert rf.FINDING_STATUSES is FINDING_STATUSES

    def test_domain_module_re_exports_severities(self):
        assert rf.FINDING_SEVERITIES is FINDING_SEVERITIES


# ---------------------------------------------------------------------------
# Import discipline
# ---------------------------------------------------------------------------


class TestImportDiscipline:
    """reviewer_findings must not import routing, evaluation_state, or hooks."""

    def test_no_evaluation_state_import(self):
        source = inspect.getsource(rf)
        tree = ast.parse(source)
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom) and node.module:
                assert "evaluation_state" not in node.module, (
                    "reviewer_findings must not import evaluation_state"
                )

    def test_no_routing_import(self):
        source = inspect.getsource(rf)
        tree = ast.parse(source)
        forbidden = {"dispatch_engine", "completions", "policy_engine"}
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom) and node.module:
                for f in forbidden:
                    assert f not in node.module, (
                        f"reviewer_findings must not import {f}"
                    )

    def test_no_hook_import(self):
        source = inspect.getsource(rf)
        assert "hooks" not in source.split("from")[0] if "from" in source else True
        tree = ast.parse(source)
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom) and node.module:
                assert "hook" not in node.module.lower(), (
                    "reviewer_findings must not import hook modules"
                )
