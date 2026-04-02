"""Unit tests for runtime/core/completions.py

@decision DEC-COMPLETION-001
Title: Structured completion records gate role-transition routing (v1: tester + guardian)
Status: accepted
Rationale: These tests exercise validate_payload (pure), submit (DB insert),
  latest, list_completions, and determine_next_role against an in-memory SQLite
  database. They prove the v1 enforcement scope (tester + guardian only) and the
  routing table that orchestrators and hooks will rely on.

  Compound-interaction test (test_full_tester_completion_lifecycle) exercises
  the real production sequence: lease issue → submit valid completion →
  latest returns it → determine_next_role routes correctly.
"""

import sqlite3

import pytest

from runtime.schemas import ensure_schema
from runtime.core import completions, leases


# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    """In-memory SQLite connection with full schema applied."""
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


def _valid_tester_payload():
    return {
        "EVAL_VERDICT": "ready_for_guardian",
        "EVAL_TESTS_PASS": "yes",
        "EVAL_NEXT_ROLE": "guardian",
        "EVAL_HEAD_SHA": "abc123",
    }


def _valid_guardian_payload():
    return {
        "LANDING_RESULT": "committed",
        "OPERATION_CLASS": "routine_local",
    }


# ---------------------------------------------------------------------------
# validate_payload — tester
# ---------------------------------------------------------------------------


def test_validate_tester_all_required_valid_verdict():
    result = completions.validate_payload("tester", _valid_tester_payload())
    assert result["valid"] is True
    assert result["verdict"] == "ready_for_guardian"
    assert result["missing_fields"] == []


def test_validate_tester_missing_eval_verdict():
    payload = _valid_tester_payload()
    del payload["EVAL_VERDICT"]
    result = completions.validate_payload("tester", payload)
    assert result["valid"] is False
    assert "EVAL_VERDICT" in result["missing_fields"]


def test_validate_tester_missing_eval_tests_pass():
    payload = _valid_tester_payload()
    del payload["EVAL_TESTS_PASS"]
    result = completions.validate_payload("tester", payload)
    assert result["valid"] is False
    assert "EVAL_TESTS_PASS" in result["missing_fields"]


def test_validate_tester_missing_eval_head_sha():
    payload = _valid_tester_payload()
    del payload["EVAL_HEAD_SHA"]
    result = completions.validate_payload("tester", payload)
    assert result["valid"] is False
    assert "EVAL_HEAD_SHA" in result["missing_fields"]


def test_validate_tester_invalid_verdict_value():
    payload = _valid_tester_payload()
    payload["EVAL_VERDICT"] = "dunno"
    result = completions.validate_payload("tester", payload)
    assert result["valid"] is False
    assert result["verdict"] == "dunno"


def test_validate_tester_empty_string_field_treated_as_missing():
    payload = _valid_tester_payload()
    payload["EVAL_TESTS_PASS"] = ""
    result = completions.validate_payload("tester", payload)
    assert result["valid"] is False
    assert "EVAL_TESTS_PASS" in result["missing_fields"]


# ---------------------------------------------------------------------------
# validate_payload — guardian
# ---------------------------------------------------------------------------


def test_validate_guardian_all_required_valid_verdict():
    result = completions.validate_payload("guardian", _valid_guardian_payload())
    assert result["valid"] is True
    assert result["verdict"] == "committed"
    assert result["missing_fields"] == []


def test_validate_guardian_missing_landing_result():
    payload = _valid_guardian_payload()
    del payload["LANDING_RESULT"]
    result = completions.validate_payload("guardian", payload)
    assert result["valid"] is False
    assert "LANDING_RESULT" in result["missing_fields"]


def test_validate_guardian_missing_operation_class():
    payload = _valid_guardian_payload()
    del payload["OPERATION_CLASS"]
    result = completions.validate_payload("guardian", payload)
    assert result["valid"] is False
    assert "OPERATION_CLASS" in result["missing_fields"]


def test_validate_guardian_invalid_verdict():
    payload = _valid_guardian_payload()
    payload["LANDING_RESULT"] = "exploded"
    result = completions.validate_payload("guardian", payload)
    assert result["valid"] is False


# ---------------------------------------------------------------------------
# validate_payload — unknown role
# ---------------------------------------------------------------------------


def test_validate_unknown_role_returns_role_not_enforced():
    result = completions.validate_payload("implementer", {"IMPL_STATUS": "complete"})
    assert result["valid"] is False
    assert "role_not_enforced" in result["missing_fields"]


def test_validate_completely_unknown_role():
    result = completions.validate_payload("wizard", {})
    assert result["valid"] is False
    assert "role_not_enforced" in result["missing_fields"]


# ---------------------------------------------------------------------------
# submit()
# ---------------------------------------------------------------------------


def test_submit_valid_payload_stores_valid_1(conn):
    lease = leases.issue(conn, role="tester", worktree_path="/repo/wt", workflow_id="wf-1")
    result = completions.submit(conn, lease["lease_id"], "wf-1", "tester", _valid_tester_payload())
    assert result["valid"] is True
    assert result["verdict"] == "ready_for_guardian"
    assert result["missing_fields"] == []
    # Verify DB row.
    row = conn.execute(
        "SELECT valid FROM completion_records WHERE id = ?", (result["completion_id"],)
    ).fetchone()
    assert row["valid"] == 1


def test_submit_invalid_payload_stores_valid_0(conn):
    lease = leases.issue(conn, role="tester", worktree_path="/repo/wt", workflow_id="wf-1")
    bad_payload = {"EVAL_VERDICT": "dunno"}  # missing required fields + bad verdict
    result = completions.submit(conn, lease["lease_id"], "wf-1", "tester", bad_payload)
    assert result["valid"] is False
    row = conn.execute(
        "SELECT valid FROM completion_records WHERE id = ?", (result["completion_id"],)
    ).fetchone()
    assert row["valid"] == 0


def test_submit_returns_completion_id(conn):
    lease = leases.issue(conn, role="guardian", worktree_path="/repo/wt", workflow_id="wf-g")
    result = completions.submit(
        conn, lease["lease_id"], "wf-g", "guardian", _valid_guardian_payload()
    )
    assert isinstance(result["completion_id"], int)
    assert result["completion_id"] > 0


def test_submit_increments_completion_id(conn):
    lease = leases.issue(conn, role="tester", worktree_path="/repo/wt", workflow_id="wf-1")
    r1 = completions.submit(conn, lease["lease_id"], "wf-1", "tester", _valid_tester_payload())
    r2 = completions.submit(conn, lease["lease_id"], "wf-1", "tester", _valid_tester_payload())
    assert r2["completion_id"] > r1["completion_id"]


# ---------------------------------------------------------------------------
# latest()
# ---------------------------------------------------------------------------


def test_latest_returns_most_recent_for_lease_id(conn):
    lease = leases.issue(conn, role="tester", worktree_path="/repo/wt", workflow_id="wf-1")
    completions.submit(conn, lease["lease_id"], "wf-1", "tester", _valid_tester_payload())
    p2 = _valid_tester_payload()
    p2["EVAL_VERDICT"] = "needs_changes"
    completions.submit(conn, lease["lease_id"], "wf-1", "tester", p2)

    record = completions.latest(conn, lease_id=lease["lease_id"])
    assert record is not None
    assert record["verdict"] == "needs_changes"  # most recent


def test_latest_returns_none_when_no_records(conn):
    result = completions.latest(conn, lease_id="nonexistent-lease")
    assert result is None


def test_latest_by_workflow_id(conn):
    lease = leases.issue(conn, role="guardian", worktree_path="/repo/wt", workflow_id="wf-g")
    completions.submit(conn, lease["lease_id"], "wf-g", "guardian", _valid_guardian_payload())
    record = completions.latest(conn, workflow_id="wf-g")
    assert record is not None
    assert record["workflow_id"] == "wf-g"
    assert record["found"] is True


# ---------------------------------------------------------------------------
# list_completions()
# ---------------------------------------------------------------------------


def test_list_completions_filtered_by_role(conn):
    lease = leases.issue(conn, role="tester", worktree_path="/repo/wt", workflow_id="wf-1")
    completions.submit(conn, lease["lease_id"], "wf-1", "tester", _valid_tester_payload())

    lease_g = leases.issue(conn, role="guardian", worktree_path="/repo/wt2", workflow_id="wf-g")
    completions.submit(conn, lease_g["lease_id"], "wf-g", "guardian", _valid_guardian_payload())

    tester_rows = completions.list_completions(conn, role="tester")
    guardian_rows = completions.list_completions(conn, role="guardian")

    assert len(tester_rows) == 1
    assert tester_rows[0]["role"] == "tester"
    assert len(guardian_rows) == 1
    assert guardian_rows[0]["role"] == "guardian"


def test_list_completions_valid_only_filters_invalid(conn):
    lease = leases.issue(conn, role="tester", worktree_path="/repo/wt", workflow_id="wf-1")
    # Submit one valid, one invalid.
    completions.submit(conn, lease["lease_id"], "wf-1", "tester", _valid_tester_payload())
    completions.submit(conn, lease["lease_id"], "wf-1", "tester", {"EVAL_VERDICT": "bad"})

    all_rows = completions.list_completions(conn)
    valid_rows = completions.list_completions(conn, valid_only=True)

    assert len(all_rows) == 2
    assert len(valid_rows) == 1
    assert valid_rows[0]["valid"] == 1


# ---------------------------------------------------------------------------
# determine_next_role()
# ---------------------------------------------------------------------------


def test_determine_next_role_tester_ready_for_guardian():
    assert completions.determine_next_role("tester", "ready_for_guardian") == "guardian"


def test_determine_next_role_tester_needs_changes():
    assert completions.determine_next_role("tester", "needs_changes") == "implementer"


def test_determine_next_role_tester_blocked_by_plan():
    assert completions.determine_next_role("tester", "blocked_by_plan") == "planner"


def test_determine_next_role_guardian_committed_is_none():
    assert completions.determine_next_role("guardian", "committed") is None


def test_determine_next_role_guardian_merged_is_none():
    assert completions.determine_next_role("guardian", "merged") is None


def test_determine_next_role_guardian_denied():
    assert completions.determine_next_role("guardian", "denied") == "implementer"


def test_determine_next_role_unknown_role_is_none():
    assert completions.determine_next_role("wizard", "some_verdict") is None


def test_determine_next_role_unknown_verdict_is_none():
    assert completions.determine_next_role("tester", "unknown_verdict") is None


# ---------------------------------------------------------------------------
# Compound interaction — full tester completion lifecycle
# ---------------------------------------------------------------------------


def test_full_tester_completion_lifecycle(conn):
    """Compound test: lease issue → submit → latest → determine_next_role routes.

    This exercises the real production sequence:
      1. Orchestrator issues a lease for a tester.
      2. Tester submits completion with EVAL_VERDICT=ready_for_guardian.
      3. latest() returns the valid record.
      4. determine_next_role() routes to 'guardian'.
    """
    # Step 1: Issue lease for tester.
    lease = leases.issue(conn, role="tester", worktree_path="/repo/feature", workflow_id="wf-prod")
    assert lease["status"] == "active"

    # Step 2: Submit valid completion.
    payload = _valid_tester_payload()
    result = completions.submit(conn, lease["lease_id"], "wf-prod", "tester", payload)
    assert result["valid"] is True
    assert result["verdict"] == "ready_for_guardian"

    # Step 3: latest() returns this record.
    record = completions.latest(conn, lease_id=lease["lease_id"])
    assert record is not None
    assert record["valid"] == 1
    assert record["verdict"] == "ready_for_guardian"

    # Step 4: determine_next_role routes to guardian.
    next_role = completions.determine_next_role(record["role"], record["verdict"])
    assert next_role == "guardian"
