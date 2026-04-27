"""Unit tests for runtime/core/completions.py

@decision DEC-COMPLETION-001
Title: Structured completion records gate role-transition routing (v4: planner + reviewer + guardian + implementer)
Status: accepted
Rationale: These tests exercise validate_payload (pure), submit (DB insert),
  latest, list_completions, and determine_next_role against an in-memory SQLite
  database. They prove the v4 enforcement scope (planner + reviewer + guardian +
  implementer) and the routing table that orchestrators and hooks
  will rely on.

  Compound-interaction test (test_full_reviewer_completion_lifecycle) exercises
  the real production sequence: lease issue → submit valid completion →
  latest returns it → determine_next_role routes correctly.

  Phase 4 reviewer tests (DEC-COMPLETION-REVIEWER-001) verify the reviewer
  schema uses explicit REVIEW_* field names sourced from
  stage_registry.REVIEWER_VERDICTS. Reviewer routing in determine_next_role
  derives from stage_registry.next_stage() via _STAGE_TO_ROLE.

  Phase 8 Slice 11 (Tester Bundle 2): the legacy ``tester`` role was retired
  from ROLE_SCHEMAS and _STAGE_TO_ROLE. Tests pin that ``tester`` is treated
  as an unknown role everywhere (validate_payload returns role_not_enforced;
  determine_next_role returns None because there is no routing entry).
"""

import json
import sqlite3

import pytest

from runtime.core import completions, leases
from runtime.schemas import ensure_schema

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


def _valid_guardian_payload():
    return {
        "LANDING_RESULT": "committed",
        "OPERATION_CLASS": "routine_local",
    }


def _valid_planner_payload(verdict="next_work_item"):
    return {
        "PLAN_VERDICT": verdict,
        "PLAN_SUMMARY": "Dispatch implementer for auth middleware rewrite",
    }


# ---------------------------------------------------------------------------
# validate_payload — planner (Phase 6 slice 1)
# ---------------------------------------------------------------------------


def test_validate_planner_all_required_valid_verdict():
    result = completions.validate_payload("planner", _valid_planner_payload())
    assert result["valid"] is True
    assert result["verdict"] == "next_work_item"
    assert result["missing_fields"] == []


def test_validate_planner_all_four_verdicts():
    """All four Phase 6 planner verdicts must validate."""
    for v in ("goal_complete", "next_work_item", "needs_user_decision", "blocked_external"):
        result = completions.validate_payload("planner", _valid_planner_payload(v))
        assert result["valid"] is True, f"planner verdict {v!r} should be valid"
        assert result["verdict"] == v


def test_validate_planner_unknown_verdict_fails_closed():
    payload = _valid_planner_payload("unknown_verdict")
    result = completions.validate_payload("planner", payload)
    assert result["valid"] is False


def test_validate_planner_missing_plan_verdict():
    payload = _valid_planner_payload()
    del payload["PLAN_VERDICT"]
    result = completions.validate_payload("planner", payload)
    assert result["valid"] is False
    assert "PLAN_VERDICT" in result["missing_fields"]


def test_validate_planner_empty_plan_verdict():
    payload = _valid_planner_payload()
    payload["PLAN_VERDICT"] = ""
    result = completions.validate_payload("planner", payload)
    assert result["valid"] is False


def test_validate_planner_missing_plan_summary():
    payload = _valid_planner_payload()
    del payload["PLAN_SUMMARY"]
    result = completions.validate_payload("planner", payload)
    assert result["valid"] is False
    assert "PLAN_SUMMARY" in result["missing_fields"]


def test_validate_planner_empty_plan_summary():
    payload = _valid_planner_payload()
    payload["PLAN_SUMMARY"] = ""
    result = completions.validate_payload("planner", payload)
    assert result["valid"] is False


def test_planner_verdicts_sourced_from_stage_registry():
    """Planner verdict vocabulary must be the stage_registry.PLANNER_VERDICTS
    frozenset, not a duplicated copy."""
    from runtime.core.stage_registry import PLANNER_VERDICTS
    assert completions.ROLE_SCHEMAS["planner"]["valid_verdicts"] is PLANNER_VERDICTS


# ---------------------------------------------------------------------------
# validate_payload — tester retired (Phase 8 Slice 11)
# ---------------------------------------------------------------------------


def test_validate_tester_role_is_unknown_after_slice_11():
    """Phase 8 Slice 11: ``tester`` is no longer a known runtime role.
    validate_payload returns role_not_enforced for any tester payload."""
    sample_payload = {
        "EVAL_VERDICT": "ready_for_guardian",
        "EVAL_TESTS_PASS": "yes",
        "EVAL_NEXT_ROLE": "guardian",
        "EVAL_HEAD_SHA": "abc123",
    }
    result = completions.validate_payload("tester", sample_payload)
    assert result["valid"] is False
    assert "role_not_enforced" in result["missing_fields"]


# ---------------------------------------------------------------------------
# validate_payload — guardian
# ---------------------------------------------------------------------------


def test_validate_guardian_all_required_valid_verdict():
    result = completions.validate_payload("guardian", _valid_guardian_payload())
    assert result["valid"] is True
    assert result["verdict"] == "committed"
    assert result["missing_fields"] == []


def test_validate_guardian_pushed_valid_verdict():
    payload = _valid_guardian_payload()
    payload["LANDING_RESULT"] = "pushed"
    result = completions.validate_payload("guardian", payload)
    assert result["valid"] is True
    assert result["verdict"] == "pushed"
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
    result = completions.validate_payload("wizard", {})
    assert result["valid"] is False
    assert "role_not_enforced" in result["missing_fields"]


def test_validate_completely_unknown_role():
    result = completions.validate_payload("nonexistent_role", {})
    assert result["valid"] is False
    assert "role_not_enforced" in result["missing_fields"]


# ---------------------------------------------------------------------------
# submit()
# ---------------------------------------------------------------------------


def test_submit_valid_payload_stores_valid_1(conn):
    lease = leases.issue(conn, role="reviewer", worktree_path="/repo/wt", workflow_id="wf-1")
    result = completions.submit(conn, lease["lease_id"], "wf-1", "reviewer", _valid_reviewer_payload())
    assert result["valid"] is True
    assert result["verdict"] == "ready_for_guardian"
    assert result["missing_fields"] == []
    # Verify DB row.
    row = conn.execute(
        "SELECT valid FROM completion_records WHERE id = ?", (result["completion_id"],)
    ).fetchone()
    assert row["valid"] == 1


def test_submit_invalid_payload_stores_valid_0(conn):
    lease = leases.issue(conn, role="reviewer", worktree_path="/repo/wt", workflow_id="wf-1")
    bad_payload = {"REVIEW_VERDICT": "dunno"}  # missing required fields + bad verdict
    result = completions.submit(conn, lease["lease_id"], "wf-1", "reviewer", bad_payload)
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
    lease = leases.issue(conn, role="reviewer", worktree_path="/repo/wt", workflow_id="wf-1")
    r1 = completions.submit(conn, lease["lease_id"], "wf-1", "reviewer", _valid_reviewer_payload())
    r2 = completions.submit(conn, lease["lease_id"], "wf-1", "reviewer", _valid_reviewer_payload())
    assert r2["completion_id"] > r1["completion_id"]


# ---------------------------------------------------------------------------
# latest()
# ---------------------------------------------------------------------------


def test_latest_returns_most_recent_for_lease_id(conn):
    lease = leases.issue(conn, role="reviewer", worktree_path="/repo/wt", workflow_id="wf-1")
    completions.submit(conn, lease["lease_id"], "wf-1", "reviewer", _valid_reviewer_payload())
    p2 = _valid_reviewer_payload()
    p2["REVIEW_VERDICT"] = "needs_changes"
    completions.submit(conn, lease["lease_id"], "wf-1", "reviewer", p2)

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
    lease = leases.issue(conn, role="reviewer", worktree_path="/repo/wt", workflow_id="wf-1")
    completions.submit(conn, lease["lease_id"], "wf-1", "reviewer", _valid_reviewer_payload())

    lease_g = leases.issue(conn, role="guardian", worktree_path="/repo/wt2", workflow_id="wf-g")
    completions.submit(conn, lease_g["lease_id"], "wf-g", "guardian", _valid_guardian_payload())

    reviewer_rows = completions.list_completions(conn, role="reviewer")
    guardian_rows = completions.list_completions(conn, role="guardian")

    assert len(reviewer_rows) == 1
    assert reviewer_rows[0]["role"] == "reviewer"
    assert len(guardian_rows) == 1
    assert guardian_rows[0]["role"] == "guardian"


def test_list_completions_valid_only_filters_invalid(conn):
    lease = leases.issue(conn, role="reviewer", worktree_path="/repo/wt", workflow_id="wf-1")
    # Submit one valid, one invalid.
    completions.submit(conn, lease["lease_id"], "wf-1", "reviewer", _valid_reviewer_payload())
    completions.submit(conn, lease["lease_id"], "wf-1", "reviewer", {"REVIEW_VERDICT": "bad"})

    all_rows = completions.list_completions(conn)
    valid_rows = completions.list_completions(conn, valid_only=True)

    assert len(all_rows) == 2
    assert len(valid_rows) == 1
    assert valid_rows[0]["valid"] == 1


def test_list_completions_deterministic_ordering_by_id(conn):
    """list_completions must order by created_at DESC, id DESC so that
    equal-timestamp rows are deterministically ordered by insertion order."""
    lease = leases.issue(conn, role="reviewer", worktree_path="/repo/wt", workflow_id="wf-1")
    r1 = completions.submit(conn, lease["lease_id"], "wf-1", "reviewer", _valid_reviewer_payload())
    r2 = completions.submit(conn, lease["lease_id"], "wf-1", "reviewer", _valid_reviewer_payload())
    # Force identical created_at — only id should differentiate ordering.
    conn.execute("UPDATE completion_records SET created_at = ?", (1000000,))
    rows = completions.list_completions(conn)
    assert len(rows) == 2
    # Higher id (r2) must come first. submit() returns "completion_id",
    # but _row_to_dict uses the SQL column name "id".
    assert rows[0]["id"] == r2["completion_id"]
    assert rows[1]["id"] == r1["completion_id"]
    assert rows[0]["id"] > rows[1]["id"]


# ---------------------------------------------------------------------------
# determine_next_role()
# ---------------------------------------------------------------------------


def test_determine_next_role_tester_returns_none():
    """Phase 8 Slice 11: tester is not a known runtime role; any verdict
    returns None because there is no stage_registry entry for it."""
    assert completions.determine_next_role("tester", "ready_for_guardian") is None
    assert completions.determine_next_role("tester", "needs_changes") is None
    assert completions.determine_next_role("tester", "blocked_by_plan") is None


def test_determine_next_role_guardian_committed_routes_to_planner():
    """Phase 6 Slice 5: guardian committed → planner (post-guardian continuation)."""
    assert completions.determine_next_role("guardian", "committed") == "planner"


def test_determine_next_role_guardian_merged_routes_to_planner():
    """Phase 6 Slice 5: guardian merged → planner (post-guardian continuation)."""
    assert completions.determine_next_role("guardian", "merged") == "planner"


def test_determine_next_role_guardian_pushed_routes_to_planner():
    """Guardian pushed → planner (post-guardian continuation)."""
    assert completions.determine_next_role("guardian", "pushed") == "planner"


def test_determine_next_role_guardian_denied():
    assert completions.determine_next_role("guardian", "denied") == "implementer"


def test_determine_next_role_guardian_skipped_routes_to_planner():
    """Phase 6 Slice 5: guardian skipped → planner (goal reassessment)."""
    assert completions.determine_next_role("guardian", "skipped") == "planner"


def test_determine_next_role_guardian_provisioned_routes_to_implementer():
    """Phase 6 Slice 5: guardian provisioned → implementer (provision complete)."""
    assert completions.determine_next_role("guardian", "provisioned") == "implementer"


def test_guardian_overlapping_verdicts_are_outcome_equivalent():
    """Phase 6 Slice 5 invariant: denied and skipped appear in both guardian
    compound stages (provision and land). The delegated resolver must produce
    the same live role regardless of which stage matches first. This test
    proves the overlap-safe logic does not silently pick a wrong answer."""
    from runtime.core import stage_registry as sr

    for verdict in ("denied", "skipped"):
        # Verify the verdict exists in both stages.
        prov_target = sr.next_stage(sr.GUARDIAN_PROVISION, verdict)
        land_target = sr.next_stage(sr.GUARDIAN_LAND, verdict)
        assert prov_target is not None, f"{verdict} missing from guardian:provision"
        assert land_target is not None, f"{verdict} missing from guardian:land"
        # The delegated resolver should produce a non-None result (not fail closed).
        result = completions.determine_next_role("guardian", verdict)
        assert result is not None, (
            f"guardian({verdict}) returned None despite both stages having transitions"
        )


def test_guardian_overlap_conflict_fails_closed_when_roles_differ(monkeypatch):
    """Overlap-safe resolver: if two guardian stages match the same verdict but
    translate to different live roles, determine_next_role must return None
    (fail closed) rather than silently picking one.

    Uses monkeypatching to create a synthetic conflict without modifying
    real stage_registry transitions."""
    from runtime.core import stage_registry as _sr

    _original_next_stage = _sr.next_stage

    def _patched_next_stage(from_stage, verdict):
        if verdict == "synthetic_conflict":
            if from_stage == _sr.GUARDIAN_PROVISION:
                return "implementer"  # maps to "implementer" via _STAGE_TO_ROLE
            if from_stage == _sr.GUARDIAN_LAND:
                return "planner"  # maps to "planner" via _STAGE_TO_ROLE
        return _original_next_stage(from_stage, verdict)

    monkeypatch.setattr(_sr, "next_stage", _patched_next_stage)
    result = completions.determine_next_role("guardian", "synthetic_conflict")
    assert result is None, (
        "overlapping verdict with conflicting target roles must fail closed"
    )


def test_guardian_overlap_conflict_with_sink_fails_closed(monkeypatch):
    """Overlap-safe resolver: if one guardian stage maps to a sink (None via
    _STAGE_TO_ROLE) and another maps to a live role, the resolver must detect
    the conflict regardless of iteration order.

    This is the sentinel correctness test: without a sentinel, resolved_role
    starts as None, making it indistinguishable from a sink translation, so the
    first-sink-then-live-role path silently accepts the live role instead of
    failing closed."""
    from runtime.core import stage_registry as _sr

    _original_next_stage = _sr.next_stage

    # Scenario A: provision → sink (terminal), land → live role (implementer).
    def _patched_sink_first(from_stage, verdict):
        if verdict == "sink_conflict":
            if from_stage == _sr.GUARDIAN_PROVISION:
                return "terminal"  # _STAGE_TO_ROLE["terminal"] = None
            if from_stage == _sr.GUARDIAN_LAND:
                return "implementer"  # _STAGE_TO_ROLE["implementer"] = "implementer"
        return _original_next_stage(from_stage, verdict)

    monkeypatch.setattr(_sr, "next_stage", _patched_sink_first)
    result_a = completions.determine_next_role("guardian", "sink_conflict")
    assert result_a is None, (
        "sink-then-live-role conflict must fail closed (sentinel bug if this passes as 'implementer')"
    )

    # Scenario B: provision → live role, land → sink (reversed order).
    def _patched_live_first(from_stage, verdict):
        if verdict == "sink_conflict":
            if from_stage == _sr.GUARDIAN_PROVISION:
                return "implementer"
            if from_stage == _sr.GUARDIAN_LAND:
                return "terminal"
        return _original_next_stage(from_stage, verdict)

    monkeypatch.setattr(_sr, "next_stage", _patched_live_first)
    result_b = completions.determine_next_role("guardian", "sink_conflict")
    assert result_b is None, (
        "live-role-then-sink conflict must also fail closed"
    )

    # Both results must be the same — order-independent.
    assert result_a == result_b, "conflict detection must be order-independent"


def test_guardian_overlap_both_sinks_returns_none(monkeypatch):
    """Overlap-safe resolver: if two guardian stages both map to sinks (None),
    they agree — the result is None (not fail-closed but legitimate agreement
    on a terminal route)."""
    from runtime.core import stage_registry as _sr

    _original_next_stage = _sr.next_stage

    def _patched_both_sinks(from_stage, verdict):
        if verdict == "both_terminal":
            if from_stage in (_sr.GUARDIAN_PROVISION, _sr.GUARDIAN_LAND):
                return "terminal"  # Both map to None
        return _original_next_stage(from_stage, verdict)

    monkeypatch.setattr(_sr, "next_stage", _patched_both_sinks)
    result = completions.determine_next_role("guardian", "both_terminal")
    assert result is None, "two sinks agreeing on None is a legitimate None return"


def test_determine_next_role_unknown_role_is_none():
    assert completions.determine_next_role("wizard", "some_verdict") is None


def test_determine_next_role_unknown_verdict_is_none():
    # Reviewer is known, but 'unknown_verdict' is not in its verdict set.
    assert completions.determine_next_role("reviewer", "unknown_verdict") is None


def test_determine_next_role_implementer_complete():
    assert completions.determine_next_role("implementer", "complete") == "reviewer"


def test_determine_next_role_implementer_partial():
    assert completions.determine_next_role("implementer", "partial") == "reviewer"


def test_determine_next_role_implementer_blocked():
    assert completions.determine_next_role("implementer", "blocked") == "reviewer"


# ---------------------------------------------------------------------------
# validate_payload — implementer
# ---------------------------------------------------------------------------


def test_validate_implementer_all_required_valid():
    result = completions.validate_payload(
        "implementer",
        {"IMPL_STATUS": "complete", "IMPL_HEAD_SHA": "abc123"},
    )
    assert result["valid"] is True
    assert result["verdict"] == "complete"


def test_validate_implementer_missing_impl_status():
    result = completions.validate_payload("implementer", {"IMPL_HEAD_SHA": "abc123"})
    assert result["valid"] is False
    assert "IMPL_STATUS" in result["missing_fields"]


def test_validate_implementer_missing_head_sha():
    result = completions.validate_payload("implementer", {"IMPL_STATUS": "complete"})
    assert result["valid"] is False
    assert "IMPL_HEAD_SHA" in result["missing_fields"]


def test_validate_implementer_invalid_verdict():
    result = completions.validate_payload(
        "implementer",
        {"IMPL_STATUS": "dunno", "IMPL_HEAD_SHA": "abc123"},
    )
    assert result["valid"] is False


def test_validate_implementer_partial():
    result = completions.validate_payload(
        "implementer",
        {"IMPL_STATUS": "partial", "IMPL_HEAD_SHA": "abc123"},
    )
    assert result["valid"] is True
    assert result["verdict"] == "partial"


def test_validate_implementer_blocked():
    result = completions.validate_payload(
        "implementer",
        {"IMPL_STATUS": "blocked", "IMPL_HEAD_SHA": "abc123"},
    )
    assert result["valid"] is True
    assert result["verdict"] == "blocked"


# ---------------------------------------------------------------------------
# Compound interaction — full reviewer completion lifecycle
# ---------------------------------------------------------------------------


def test_full_reviewer_completion_lifecycle(conn):
    """Compound test: lease issue → submit → latest → determine_next_role.

    Phase 8 Slice 11: reviewer is the canonical evaluator role after the
    tester retirement. A ready_for_guardian verdict must route to guardian
    via stage_registry.
    """
    # Step 1: Issue lease for reviewer.
    lease = leases.issue(
        conn, role="reviewer", worktree_path="/repo/feature", workflow_id="wf-prod"
    )
    assert lease["status"] == "active"

    # Step 2: Submit valid completion.
    payload = _valid_reviewer_payload()
    result = completions.submit(conn, lease["lease_id"], "wf-prod", "reviewer", payload)
    assert result["valid"] is True
    assert result["verdict"] == "ready_for_guardian"

    # Step 3: latest() returns this record.
    record = completions.latest(conn, lease_id=lease["lease_id"])
    assert record is not None
    assert record["valid"] == 1
    assert record["verdict"] == "ready_for_guardian"

    # Step 4: Reviewer ready_for_guardian routes to guardian via stage_registry.
    next_role = completions.determine_next_role(record["role"], record["verdict"])
    assert next_role == "guardian"


# ---------------------------------------------------------------------------
# validate_payload — reviewer (Phase 4, DEC-COMPLETION-REVIEWER-001)
# ---------------------------------------------------------------------------


def _valid_reviewer_payload(verdict="ready_for_guardian"):
    return {
        "REVIEW_VERDICT": verdict,
        "REVIEW_HEAD_SHA": "abc123def",
        "REVIEW_FINDINGS_JSON": '{"findings": []}',
    }


def test_validate_reviewer_ready_for_guardian():
    result = completions.validate_payload("reviewer", _valid_reviewer_payload("ready_for_guardian"))
    assert result["valid"] is True
    assert result["verdict"] == "ready_for_guardian"
    assert result["missing_fields"] == []


def test_validate_reviewer_needs_changes():
    result = completions.validate_payload("reviewer", _valid_reviewer_payload("needs_changes"))
    assert result["valid"] is True
    assert result["verdict"] == "needs_changes"


def test_validate_reviewer_blocked_by_plan():
    result = completions.validate_payload("reviewer", _valid_reviewer_payload("blocked_by_plan"))
    assert result["valid"] is True
    assert result["verdict"] == "blocked_by_plan"


def test_validate_reviewer_invalid_verdict():
    payload = _valid_reviewer_payload()
    payload["REVIEW_VERDICT"] = "looks_fine"
    result = completions.validate_payload("reviewer", payload)
    assert result["valid"] is False
    assert result["verdict"] == "looks_fine"


def test_validate_reviewer_missing_review_verdict():
    payload = _valid_reviewer_payload()
    del payload["REVIEW_VERDICT"]
    result = completions.validate_payload("reviewer", payload)
    assert result["valid"] is False
    assert "REVIEW_VERDICT" in result["missing_fields"]


def test_validate_reviewer_missing_review_head_sha():
    payload = _valid_reviewer_payload()
    del payload["REVIEW_HEAD_SHA"]
    result = completions.validate_payload("reviewer", payload)
    assert result["valid"] is False
    assert "REVIEW_HEAD_SHA" in result["missing_fields"]


def test_validate_reviewer_missing_review_findings_json():
    payload = _valid_reviewer_payload()
    del payload["REVIEW_FINDINGS_JSON"]
    result = completions.validate_payload("reviewer", payload)
    assert result["valid"] is False
    assert "REVIEW_FINDINGS_JSON" in result["missing_fields"]


def test_validate_reviewer_empty_findings_treated_as_missing():
    payload = _valid_reviewer_payload()
    payload["REVIEW_FINDINGS_JSON"] = ""
    result = completions.validate_payload("reviewer", payload)
    assert result["valid"] is False
    assert "REVIEW_FINDINGS_JSON" in result["missing_fields"]


def test_validate_reviewer_empty_head_sha_treated_as_missing():
    payload = _valid_reviewer_payload()
    payload["REVIEW_HEAD_SHA"] = ""
    result = completions.validate_payload("reviewer", payload)
    assert result["valid"] is False
    assert "REVIEW_HEAD_SHA" in result["missing_fields"]


# ---------------------------------------------------------------------------
# Reviewer REVIEW_FINDINGS_JSON structural validation (Phase 4)
# ---------------------------------------------------------------------------


def test_validate_reviewer_valid_empty_findings():
    """Empty findings list is structurally valid."""
    payload = _valid_reviewer_payload()
    payload["REVIEW_FINDINGS_JSON"] = '{"findings": []}'
    result = completions.validate_payload("reviewer", payload)
    assert result["valid"] is True
    assert result["missing_fields"] == []


def test_validate_reviewer_valid_one_finding():
    """Single finding with all required fields is valid."""
    payload = _valid_reviewer_payload()
    payload["REVIEW_FINDINGS_JSON"] = json.dumps({
        "findings": [{
            "severity": "blocking",
            "title": "Missing null check",
            "detail": "Line 42 dereferences without guard",
        }]
    })
    result = completions.validate_payload("reviewer", payload)
    assert result["valid"] is True
    assert result["missing_fields"] == []


def test_validate_reviewer_valid_finding_with_optional_fields():
    """Findings with optional fields accepted by the ledger are valid."""
    payload = _valid_reviewer_payload()
    payload["REVIEW_FINDINGS_JSON"] = json.dumps({
        "findings": [{
            "severity": "concern",
            "title": "Style issue",
            "detail": "Inconsistent naming",
            "work_item_id": "WI-1",
            "file_path": "src/app.py",
            "line": 10,
            "reviewer_round": 2,
            "head_sha": "abc123",
            "finding_id": "f-001",
        }]
    })
    result = completions.validate_payload("reviewer", payload)
    assert result["valid"] is True
    assert result["missing_fields"] == []


def test_validate_reviewer_malformed_json():
    """Non-JSON string is invalid."""
    payload = _valid_reviewer_payload()
    payload["REVIEW_FINDINGS_JSON"] = "not json at all"
    result = completions.validate_payload("reviewer", payload)
    assert result["valid"] is False
    assert "REVIEW_FINDINGS_JSON_INVALID_JSON" in result["missing_fields"]


def test_validate_reviewer_findings_not_object():
    """Top-level value must be an object, not a list."""
    payload = _valid_reviewer_payload()
    payload["REVIEW_FINDINGS_JSON"] = "[]"
    result = completions.validate_payload("reviewer", payload)
    assert result["valid"] is False
    assert "REVIEW_FINDINGS_JSON_NOT_OBJECT" in result["missing_fields"]


def test_validate_reviewer_missing_findings_key():
    """Top-level object must contain 'findings' key."""
    payload = _valid_reviewer_payload()
    payload["REVIEW_FINDINGS_JSON"] = '{"verdict": "ok"}'
    result = completions.validate_payload("reviewer", payload)
    assert result["valid"] is False
    assert "REVIEW_FINDINGS_JSON_MISSING_FINDINGS_KEY" in result["missing_fields"]


def test_validate_reviewer_findings_not_list():
    """'findings' must be a list, not a string."""
    payload = _valid_reviewer_payload()
    payload["REVIEW_FINDINGS_JSON"] = '{"findings": "none"}'
    result = completions.validate_payload("reviewer", payload)
    assert result["valid"] is False
    assert "REVIEW_FINDINGS_JSON_FINDINGS_NOT_LIST" in result["missing_fields"]


def test_validate_reviewer_finding_item_not_object():
    """Each item in findings must be an object."""
    payload = _valid_reviewer_payload()
    payload["REVIEW_FINDINGS_JSON"] = '{"findings": ["not an object"]}'
    result = completions.validate_payload("reviewer", payload)
    assert result["valid"] is False
    assert "REVIEW_FINDINGS_JSON_ITEM_0_NOT_OBJECT" in result["missing_fields"]


def test_validate_reviewer_finding_invalid_severity():
    """Severity must use the canonical vocabulary from FINDING_SEVERITIES."""
    payload = _valid_reviewer_payload()
    payload["REVIEW_FINDINGS_JSON"] = json.dumps({
        "findings": [{
            "severity": "critical",
            "title": "Bug",
            "detail": "Something broke",
        }]
    })
    result = completions.validate_payload("reviewer", payload)
    assert result["valid"] is False
    assert "REVIEW_FINDINGS_JSON_ITEM_0_INVALID_SEVERITY" in result["missing_fields"]


def test_validate_reviewer_finding_missing_required_fields():
    """Each finding must have severity, title, detail."""
    payload = _valid_reviewer_payload()
    payload["REVIEW_FINDINGS_JSON"] = '{"findings": [{}]}'
    result = completions.validate_payload("reviewer", payload)
    assert result["valid"] is False
    markers = result["missing_fields"]
    assert "REVIEW_FINDINGS_JSON_ITEM_0_MISSING_SEVERITY" in markers
    assert "REVIEW_FINDINGS_JSON_ITEM_0_MISSING_TITLE" in markers
    assert "REVIEW_FINDINGS_JSON_ITEM_0_MISSING_DETAIL" in markers


def test_validate_reviewer_finding_line_not_int():
    """Optional 'line' field must be an int if present."""
    payload = _valid_reviewer_payload()
    payload["REVIEW_FINDINGS_JSON"] = json.dumps({
        "findings": [{
            "severity": "note",
            "title": "Observation",
            "detail": "Detail text",
            "line": "ten",
        }]
    })
    result = completions.validate_payload("reviewer", payload)
    assert result["valid"] is False
    assert "REVIEW_FINDINGS_JSON_ITEM_0_LINE_NOT_INT" in result["missing_fields"]


def test_validate_reviewer_finding_reviewer_round_not_int():
    """Optional 'reviewer_round' must be an int if present."""
    payload = _valid_reviewer_payload()
    payload["REVIEW_FINDINGS_JSON"] = json.dumps({
        "findings": [{
            "severity": "note",
            "title": "Observation",
            "detail": "Detail text",
            "reviewer_round": "two",
        }]
    })
    result = completions.validate_payload("reviewer", payload)
    assert result["valid"] is False
    assert "REVIEW_FINDINGS_JSON_ITEM_0_REVIEWER_ROUND_NOT_INT" in result["missing_fields"]


def test_validate_reviewer_finding_line_zero_rejected():
    """line=0 is rejected — ledger requires line >= 1."""
    payload = _valid_reviewer_payload()
    payload["REVIEW_FINDINGS_JSON"] = json.dumps({
        "findings": [{
            "severity": "note",
            "title": "Obs",
            "detail": "D",
            "line": 0,
        }]
    })
    result = completions.validate_payload("reviewer", payload)
    assert result["valid"] is False
    assert "REVIEW_FINDINGS_JSON_ITEM_0_LINE_NOT_INT" in result["missing_fields"]


def test_validate_reviewer_finding_line_negative_rejected():
    """Negative line is rejected — ledger requires line >= 1."""
    payload = _valid_reviewer_payload()
    payload["REVIEW_FINDINGS_JSON"] = json.dumps({
        "findings": [{
            "severity": "note",
            "title": "Obs",
            "detail": "D",
            "line": -5,
        }]
    })
    result = completions.validate_payload("reviewer", payload)
    assert result["valid"] is False
    assert "REVIEW_FINDINGS_JSON_ITEM_0_LINE_NOT_INT" in result["missing_fields"]


def test_validate_reviewer_finding_line_bool_rejected():
    """line=True is rejected — bool is an int subclass but not a valid line."""
    payload = _valid_reviewer_payload()
    payload["REVIEW_FINDINGS_JSON"] = json.dumps({
        "findings": [{
            "severity": "note",
            "title": "Obs",
            "detail": "D",
            "line": True,
        }]
    })
    result = completions.validate_payload("reviewer", payload)
    assert result["valid"] is False
    assert "REVIEW_FINDINGS_JSON_ITEM_0_LINE_NOT_INT" in result["missing_fields"]


def test_validate_reviewer_finding_line_one_accepted():
    """line=1 is the minimum valid value."""
    payload = _valid_reviewer_payload()
    payload["REVIEW_FINDINGS_JSON"] = json.dumps({
        "findings": [{
            "severity": "note",
            "title": "Obs",
            "detail": "D",
            "line": 1,
        }]
    })
    result = completions.validate_payload("reviewer", payload)
    assert result["valid"] is True


def test_validate_reviewer_finding_reviewer_round_negative_rejected():
    """reviewer_round=-1 is rejected — ledger requires >= 0."""
    payload = _valid_reviewer_payload()
    payload["REVIEW_FINDINGS_JSON"] = json.dumps({
        "findings": [{
            "severity": "note",
            "title": "Obs",
            "detail": "D",
            "reviewer_round": -1,
        }]
    })
    result = completions.validate_payload("reviewer", payload)
    assert result["valid"] is False
    assert "REVIEW_FINDINGS_JSON_ITEM_0_REVIEWER_ROUND_NOT_INT" in result["missing_fields"]


def test_validate_reviewer_finding_reviewer_round_bool_rejected():
    """reviewer_round=True is rejected — bool is an int subclass."""
    payload = _valid_reviewer_payload()
    payload["REVIEW_FINDINGS_JSON"] = json.dumps({
        "findings": [{
            "severity": "note",
            "title": "Obs",
            "detail": "D",
            "reviewer_round": True,
        }]
    })
    result = completions.validate_payload("reviewer", payload)
    assert result["valid"] is False
    assert "REVIEW_FINDINGS_JSON_ITEM_0_REVIEWER_ROUND_NOT_INT" in result["missing_fields"]


def test_validate_reviewer_finding_reviewer_round_zero_accepted():
    """reviewer_round=0 is the minimum valid value."""
    payload = _valid_reviewer_payload()
    payload["REVIEW_FINDINGS_JSON"] = json.dumps({
        "findings": [{
            "severity": "note",
            "title": "Obs",
            "detail": "D",
            "reviewer_round": 0,
        }]
    })
    result = completions.validate_payload("reviewer", payload)
    assert result["valid"] is True


def test_validate_reviewer_findings_severity_uses_canonical_vocabulary():
    """Severity vocabulary must come from runtime.schemas.FINDING_SEVERITIES."""
    from runtime.schemas import FINDING_SEVERITIES
    assert completions.FINDING_SEVERITIES is FINDING_SEVERITIES


def test_validate_reviewer_findings_all_valid_severities_accepted():
    """Every canonical severity value is accepted."""
    from runtime.schemas import FINDING_SEVERITIES
    for sev in sorted(FINDING_SEVERITIES):
        payload = _valid_reviewer_payload()
        payload["REVIEW_FINDINGS_JSON"] = json.dumps({
            "findings": [{
                "severity": sev,
                "title": "Test",
                "detail": "Detail",
            }]
        })
        result = completions.validate_payload("reviewer", payload)
        assert result["valid"] is True, f"severity {sev!r} should be valid"


def test_validate_reviewer_findings_does_not_affect_guardian():
    """Structural findings validation is reviewer-only; guardian is unaffected."""
    result = completions.validate_payload("guardian", _valid_guardian_payload())
    assert result["valid"] is True
    assert result["missing_fields"] == []


def test_validate_reviewer_findings_does_not_affect_implementer():
    """Structural findings validation is reviewer-only; implementer is unaffected."""
    result = completions.validate_payload(
        "implementer",
        {"IMPL_STATUS": "complete", "IMPL_HEAD_SHA": "abc123"},
    )
    assert result["valid"] is True
    assert result["missing_fields"] == []


# ---------------------------------------------------------------------------
# Reviewer schema invariants
# ---------------------------------------------------------------------------


def test_reviewer_verdicts_sourced_from_stage_registry():
    """Reviewer valid_verdicts must be the same object as
    stage_registry.REVIEWER_VERDICTS — not a copy or a competing literal."""
    from runtime.core.stage_registry import REVIEWER_VERDICTS
    assert completions.ROLE_SCHEMAS["reviewer"]["valid_verdicts"] is REVIEWER_VERDICTS


def test_reviewer_uses_review_prefix_not_eval():
    """Reviewer required fields must use REVIEW_* prefix, not EVAL_*."""
    for field in completions.ROLE_SCHEMAS["reviewer"]["required"]:
        assert field.startswith("REVIEW_"), (
            f"Reviewer field {field!r} does not use REVIEW_* prefix"
        )
    assert completions.ROLE_SCHEMAS["reviewer"]["verdict_field"] == "REVIEW_VERDICT"


def test_tester_removed_from_role_schemas_slice_11():
    """Phase 8 Slice 11: tester is not a key in ROLE_SCHEMAS."""
    assert "tester" not in completions.ROLE_SCHEMAS


# ---------------------------------------------------------------------------
# Reviewer findings persistence from submit() (Phase 4)
# ---------------------------------------------------------------------------


def test_submit_reviewer_valid_empty_findings_no_ledger_rows(conn):
    """Valid reviewer completion with empty findings list creates a completion
    record but no ledger findings."""
    from runtime.core import reviewer_findings as rf

    lease = leases.issue(conn, role="reviewer", worktree_path="/repo/wt", workflow_id="wf-r")
    payload = _valid_reviewer_payload()
    payload["REVIEW_FINDINGS_JSON"] = '{"findings": []}'
    result = completions.submit(conn, lease["lease_id"], "wf-r", "reviewer", payload)
    assert result["valid"] is True
    assert rf.list_findings(conn, workflow_id="wf-r") == []


def test_submit_reviewer_valid_one_finding_persists_to_ledger(conn):
    """Valid reviewer completion with one finding inserts both a completion
    record and one ledger finding."""
    from runtime.core import reviewer_findings as rf

    lease = leases.issue(conn, role="reviewer", worktree_path="/repo/wt", workflow_id="wf-r")
    payload = _valid_reviewer_payload()
    payload["REVIEW_FINDINGS_JSON"] = json.dumps({
        "findings": [{
            "severity": "blocking",
            "title": "Null deref",
            "detail": "Missing guard on line 42",
        }]
    })
    result = completions.submit(conn, lease["lease_id"], "wf-r", "reviewer", payload)
    assert result["valid"] is True

    findings = rf.list_findings(conn, workflow_id="wf-r")
    assert len(findings) == 1
    f = findings[0]
    assert f.severity == "blocking"
    assert f.title == "Null deref"
    assert f.detail == "Missing guard on line 42"
    assert f.workflow_id == "wf-r"
    assert f.status == "open"


def test_submit_reviewer_omitted_head_sha_defaults_from_review_head_sha(conn):
    """When a finding item omits head_sha, REVIEW_HEAD_SHA is used."""
    from runtime.core import reviewer_findings as rf

    lease = leases.issue(conn, role="reviewer", worktree_path="/repo/wt", workflow_id="wf-r")
    payload = _valid_reviewer_payload()
    payload["REVIEW_HEAD_SHA"] = "sha-from-completion"
    payload["REVIEW_FINDINGS_JSON"] = json.dumps({
        "findings": [{
            "severity": "note",
            "title": "Obs",
            "detail": "D",
            # no head_sha in item
        }]
    })
    completions.submit(conn, lease["lease_id"], "wf-r", "reviewer", payload)

    findings = rf.list_findings(conn, workflow_id="wf-r")
    assert len(findings) == 1
    assert findings[0].head_sha == "sha-from-completion"


def test_submit_reviewer_item_head_sha_overrides_default(conn):
    """Item-supplied head_sha takes precedence over REVIEW_HEAD_SHA."""
    from runtime.core import reviewer_findings as rf

    lease = leases.issue(conn, role="reviewer", worktree_path="/repo/wt", workflow_id="wf-r")
    payload = _valid_reviewer_payload()
    payload["REVIEW_HEAD_SHA"] = "default-sha"
    payload["REVIEW_FINDINGS_JSON"] = json.dumps({
        "findings": [{
            "severity": "note",
            "title": "Obs",
            "detail": "D",
            "head_sha": "item-sha",
        }]
    })
    completions.submit(conn, lease["lease_id"], "wf-r", "reviewer", payload)

    findings = rf.list_findings(conn, workflow_id="wf-r")
    assert len(findings) == 1
    assert findings[0].head_sha == "item-sha"


def test_submit_reviewer_optional_fields_preserved(conn):
    """Item-supplied work_item_id, line, reviewer_round, finding_id are
    persisted to the ledger."""
    from runtime.core import reviewer_findings as rf

    lease = leases.issue(conn, role="reviewer", worktree_path="/repo/wt", workflow_id="wf-r")
    payload = _valid_reviewer_payload()
    payload["REVIEW_FINDINGS_JSON"] = json.dumps({
        "findings": [{
            "severity": "concern",
            "title": "Style",
            "detail": "Inconsistent naming",
            "work_item_id": "WI-1",
            "file_path": "src/app.py",
            "line": 10,
            "reviewer_round": 2,
            "finding_id": "f-custom-001",
        }]
    })
    completions.submit(conn, lease["lease_id"], "wf-r", "reviewer", payload)

    findings = rf.list_findings(conn, workflow_id="wf-r")
    assert len(findings) == 1
    f = findings[0]
    assert f.work_item_id == "WI-1"
    assert f.file_path == "src/app.py"
    assert f.line == 10
    assert f.reviewer_round == 2
    assert f.finding_id == "f-custom-001"


def test_submit_reviewer_invalid_does_not_persist_findings(conn):
    """Invalid reviewer completion must not persist any ledger findings."""
    from runtime.core import reviewer_findings as rf

    lease = leases.issue(conn, role="reviewer", worktree_path="/repo/wt", workflow_id="wf-r")
    payload = _valid_reviewer_payload()
    payload["REVIEW_VERDICT"] = "invalid_verdict"  # makes it invalid
    payload["REVIEW_FINDINGS_JSON"] = json.dumps({
        "findings": [{
            "severity": "blocking",
            "title": "Should not persist",
            "detail": "This finding must not reach the ledger",
        }]
    })
    result = completions.submit(conn, lease["lease_id"], "wf-r", "reviewer", payload)
    assert result["valid"] is False
    assert rf.list_findings(conn, workflow_id="wf-r") == []


def test_submit_guardian_does_not_persist_reviewer_findings(conn):
    """Guardian submit must not trigger findings persistence."""
    from runtime.core import reviewer_findings as rf

    lease = leases.issue(conn, role="guardian", worktree_path="/repo/wt", workflow_id="wf-g")
    completions.submit(conn, lease["lease_id"], "wf-g", "guardian", _valid_guardian_payload())
    assert rf.list_findings(conn, workflow_id="wf-g") == []


def test_submit_implementer_does_not_persist_reviewer_findings(conn):
    """Implementer submit must not trigger findings persistence."""
    from runtime.core import reviewer_findings as rf

    lease = leases.issue(conn, role="implementer", worktree_path="/repo/wt", workflow_id="wf-i")
    completions.submit(
        conn, lease["lease_id"], "wf-i", "implementer",
        {"IMPL_STATUS": "complete", "IMPL_HEAD_SHA": "abc123"},
    )
    assert rf.list_findings(conn, workflow_id="wf-i") == []


def test_completions_does_not_directly_import_reviewer_findings_at_module_level():
    """completions.py must not module-level import reviewer_findings — the
    import is function-scoped in submit() to preserve shadow discipline."""
    import ast
    import inspect

    source = inspect.getsource(completions)
    tree = ast.parse(source)
    for node in ast.iter_child_nodes(tree):
        if isinstance(node, ast.ImportFrom):
            if node.module and "reviewer_findings" in node.module:
                raise AssertionError(
                    "completions.py has a module-level import of reviewer_findings; "
                    "the import should be function-scoped in submit()"
                )
        elif isinstance(node, ast.Import):
            for alias in node.names:
                if "reviewer_findings" in alias.name:
                    raise AssertionError(
                        "completions.py has a module-level import of reviewer_findings"
                    )


def test_submit_reviewer_duplicate_finding_id_rolls_back_atomically(conn):
    """Atomicity regression: two findings with the same explicit finding_id
    should fail on the duplicate INSERT. Neither the completion record nor
    any reviewer finding row should be persisted for this workflow."""
    from runtime.core import reviewer_findings as rf

    lease = leases.issue(conn, role="reviewer", worktree_path="/repo/wt", workflow_id="wf-dup")
    payload = _valid_reviewer_payload()
    payload["REVIEW_FINDINGS_JSON"] = json.dumps({
        "findings": [
            {
                "severity": "blocking",
                "title": "First",
                "detail": "First finding",
                "finding_id": "f-dup-id",
            },
            {
                "severity": "note",
                "title": "Second",
                "detail": "Second finding — same id triggers UNIQUE violation",
                "finding_id": "f-dup-id",
            },
        ]
    })
    with pytest.raises(Exception):
        completions.submit(conn, lease["lease_id"], "wf-dup", "reviewer", payload)

    # Neither the completion record nor any finding should exist.
    assert rf.list_findings(conn, workflow_id="wf-dup") == []
    rows = completions.list_completions(conn, workflow_id="wf-dup")
    assert rows == []


# ---------------------------------------------------------------------------
# determine_next_role — reviewer routing (Phase 4)
# ---------------------------------------------------------------------------


def test_determine_next_role_reviewer_ready_for_guardian():
    assert completions.determine_next_role("reviewer", "ready_for_guardian") == "guardian"


def test_determine_next_role_reviewer_needs_changes():
    assert completions.determine_next_role("reviewer", "needs_changes") == "implementer"


def test_determine_next_role_reviewer_blocked_by_plan():
    assert completions.determine_next_role("reviewer", "blocked_by_plan") == "planner"


def test_determine_next_role_reviewer_unknown_verdict_is_none():
    assert completions.determine_next_role("reviewer", "unknown_verdict") is None


def test_reviewer_routing_matches_stage_registry():
    """Reviewer routing in determine_next_role must agree with
    stage_registry.next_stage() — it derives from it, not from a
    duplicated transition table."""
    from runtime.core import stage_registry as sr

    expected_map = {
        "ready_for_guardian": "guardian",
        "needs_changes": "implementer",
        "blocked_by_plan": "planner",
    }
    for verdict, expected_role in expected_map.items():
        target_stage = sr.next_stage(sr.REVIEWER, verdict)
        assert target_stage is not None, (
            f"stage_registry.next_stage(REVIEWER, {verdict!r}) returned None"
        )
        live_role = completions._STAGE_TO_ROLE.get(target_stage)
        assert live_role == expected_role, (
            f"_STAGE_TO_ROLE[{target_stage!r}] = {live_role!r}, "
            f"expected {expected_role!r}"
        )
        # And the end-to-end function agrees.
        assert completions.determine_next_role("reviewer", verdict) == expected_role


# ---------------------------------------------------------------------------
# determine_next_role — tester retired, implementer via stage_registry
# ---------------------------------------------------------------------------


def test_determine_next_role_tester_no_longer_live_authority():
    """Phase 8 Slice 11: tester is not a known runtime role.
    determine_next_role returns None because there is no stage_registry
    entry mapping tester to a successor stage."""
    assert completions.determine_next_role("tester", "ready_for_guardian") is None
    assert completions.determine_next_role("tester", "needs_changes") is None
    assert completions.determine_next_role("tester", "blocked_by_plan") is None


def test_determine_next_role_implementer_routes_to_reviewer():
    """Phase 5: implementer routes to reviewer, not tester."""
    for verdict in ("complete", "partial", "blocked"):
        assert completions.determine_next_role("implementer", verdict) == "reviewer"


def test_implementer_routing_matches_stage_registry():
    """Implementer routing in determine_next_role must agree with
    stage_registry.next_stage() — it derives from it, not from a
    duplicated transition table."""
    from runtime.core import stage_registry as sr

    expected_map = {
        "complete": "reviewer",
        "partial": "reviewer",
        "blocked": "reviewer",
    }
    for verdict, expected_role in expected_map.items():
        target_stage = sr.next_stage(sr.IMPLEMENTER, verdict)
        assert target_stage is not None, (
            f"stage_registry.next_stage(IMPLEMENTER, {verdict!r}) returned None"
        )
        live_role = completions._STAGE_TO_ROLE.get(target_stage)
        assert live_role == expected_role, (
            f"_STAGE_TO_ROLE[{target_stage!r}] = {live_role!r}, "
            f"expected {expected_role!r}"
        )
        # And the end-to-end function agrees.
        assert completions.determine_next_role("implementer", verdict) == expected_role


def test_determine_next_role_planner_next_work_item():
    """Phase 6: planner next_work_item routes to guardian (provision)."""
    assert completions.determine_next_role("planner", "next_work_item") == "guardian"


def test_determine_next_role_planner_goal_complete():
    """Phase 6: planner goal_complete is terminal (None)."""
    assert completions.determine_next_role("planner", "goal_complete") is None


def test_determine_next_role_planner_needs_user_decision():
    """Phase 6: planner needs_user_decision is a user sink (None)."""
    assert completions.determine_next_role("planner", "needs_user_decision") is None


def test_determine_next_role_planner_blocked_external():
    """Phase 6: planner blocked_external is terminal (None)."""
    assert completions.determine_next_role("planner", "blocked_external") is None


def test_determine_next_role_planner_unknown_verdict():
    assert completions.determine_next_role("planner", "unknown_verdict") is None


def test_planner_routing_matches_stage_registry():
    """Planner routing in determine_next_role must agree with
    stage_registry.next_stage() — it derives from it, not from a
    duplicated transition table."""
    from runtime.core import stage_registry as sr

    expected_map = {
        "next_work_item": "guardian",
        "goal_complete": None,
        "needs_user_decision": None,
        "blocked_external": None,
    }
    for verdict, expected_role in expected_map.items():
        target_stage = sr.next_stage(sr.PLANNER, verdict)
        assert target_stage is not None, (
            f"stage_registry.next_stage(PLANNER, {verdict!r}) returned None"
        )
        live_role = completions._STAGE_TO_ROLE.get(target_stage)
        assert live_role == expected_role, (
            f"_STAGE_TO_ROLE[{target_stage!r}] = {live_role!r}, "
            f"expected {expected_role!r}"
        )
        assert completions.determine_next_role("planner", verdict) == expected_role


def test_no_literal_routing_for_registry_delegated_roles():
    """AST structural invariant: the _routing dict literal inside
    determine_next_role must NOT contain tuple keys whose first element is
    'planner', 'implementer', 'reviewer', 'guardian', or the retired 'tester'.
    All active routing is delegated to stage_registry; tester is not a
    known runtime role after Phase 8 Slice 11."""
    import ast
    import inspect
    import textwrap

    source = inspect.getsource(completions.determine_next_role)
    source = textwrap.dedent(source)
    tree = ast.parse(source)

    forbidden_roles = {"planner", "implementer", "reviewer", "guardian", "tester"}
    violations = []

    for node in ast.walk(tree):
        # Look for dict literals: {(role, verdict): target, ...}
        if not isinstance(node, ast.Dict):
            continue
        for key in node.keys:
            if key is None:
                continue
            # Match Tuple(Constant("role"), Constant("verdict"))
            if not isinstance(key, ast.Tuple) or len(key.elts) != 2:
                continue
            first = key.elts[0]
            if isinstance(first, ast.Constant) and first.value in forbidden_roles:
                second = key.elts[1]
                verdict_str = second.value if isinstance(second, ast.Constant) else "?"
                violations.append(f"({first.value!r}, {verdict_str!r})")

    assert not violations, (
        f"Literal routing entries found for registry-delegated/neutralized roles: "
        f"{', '.join(violations)}. Planner, implementer, reviewer, and guardian "
        f"must derive from stage_registry; retired 'tester' must be absent."
    )
