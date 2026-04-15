"""Unit tests for runtime/core/reviewer_convergence.py

@decision DEC-CLAUDEX-REVIEWER-CONVERGENCE-001
Title: Tests for the reviewer convergence/readiness domain authority (Phase 4)
Status: accepted
Rationale: Exercises all readiness conditions and failure modes, proves the
  module composes existing authorities (completions, reviewer_findings,
  stage_registry) without importing routing, evaluation, hooks, or policies.
"""

from __future__ import annotations

import ast
import inspect
import sqlite3

import pytest

from runtime.core import completions
from runtime.core import reviewer_convergence as rc
from runtime.core import reviewer_findings as rf
from runtime.schemas import ensure_schema


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


def _submit_reviewer_completion(
    conn,
    *,
    workflow_id="wf-1",
    verdict="ready_for_guardian",
    head_sha="abc123",
    findings_json='{"findings": []}',
    lease_id="lease-1",
    valid=True,
):
    """Submit a reviewer completion record. If valid=False, uses an invalid
    verdict so the completion record is stored with valid=0."""
    if valid:
        payload = {
            "REVIEW_VERDICT": verdict,
            "REVIEW_HEAD_SHA": head_sha,
            "REVIEW_FINDINGS_JSON": findings_json,
        }
    else:
        payload = {
            "REVIEW_VERDICT": "not_a_real_verdict",
            "REVIEW_HEAD_SHA": head_sha,
            "REVIEW_FINDINGS_JSON": findings_json,
        }
    return completions.submit(conn, lease_id, workflow_id, "reviewer", payload)


def _insert_blocking_finding(conn, *, workflow_id="wf-1", work_item_id=None):
    """Insert an open blocking finding."""
    kwargs = {
        "workflow_id": workflow_id,
        "severity": "blocking",
        "title": "Blocking issue",
        "detail": "This blocks landing.",
    }
    if work_item_id is not None:
        kwargs["work_item_id"] = work_item_id
    return rf.insert(conn, **kwargs)


# ---------------------------------------------------------------------------
# Ready (all conditions met)
# ---------------------------------------------------------------------------


class TestReady:
    def test_all_conditions_met(self, conn):
        _submit_reviewer_completion(conn, head_sha="abc123")
        result = rc.assess(conn, workflow_id="wf-1", current_head_sha="abc123")
        assert result.ready_for_guardian is True
        assert result.reason == rc.REASON_READY
        assert result.stale_head is False
        assert result.open_blocking_count == 0
        assert result.reviewer_verdict == "ready_for_guardian"
        assert result.reviewer_head_sha == "abc123"
        assert result.current_head_sha == "abc123"
        assert result.workflow_id == "wf-1"

    def test_ready_with_non_blocking_findings(self, conn):
        """Open 'concern' and 'note' findings do not block readiness."""
        _submit_reviewer_completion(conn, head_sha="abc123")
        rf.insert(
            conn, workflow_id="wf-1", severity="concern",
            title="Minor", detail="Not blocking",
        )
        rf.insert(
            conn, workflow_id="wf-1", severity="note",
            title="FYI", detail="Informational",
        )
        result = rc.assess(conn, workflow_id="wf-1", current_head_sha="abc123")
        assert result.ready_for_guardian is True
        assert result.reason == rc.REASON_READY
        assert result.open_blocking_count == 0

    def test_ready_with_resolved_blocking_finding(self, conn):
        """Resolved blocking findings do not block readiness."""
        _submit_reviewer_completion(conn, head_sha="abc123")
        f = _insert_blocking_finding(conn)
        rf.resolve(conn, f.finding_id)
        result = rc.assess(conn, workflow_id="wf-1", current_head_sha="abc123")
        assert result.ready_for_guardian is True
        assert result.reason == rc.REASON_READY

    def test_ready_with_waived_blocking_finding(self, conn):
        """Waived blocking findings do not block readiness."""
        _submit_reviewer_completion(conn, head_sha="abc123")
        f = _insert_blocking_finding(conn)
        rf.waive(conn, f.finding_id)
        result = rc.assess(conn, workflow_id="wf-1", current_head_sha="abc123")
        assert result.ready_for_guardian is True
        assert result.reason == rc.REASON_READY


# ---------------------------------------------------------------------------
# No reviewer completion
# ---------------------------------------------------------------------------


class TestNoCompletion:
    def test_no_completion_at_all(self, conn):
        result = rc.assess(conn, workflow_id="wf-1", current_head_sha="abc123")
        assert result.ready_for_guardian is False
        assert result.reason == rc.REASON_NO_COMPLETION
        assert result.reviewer_head_sha is None
        assert result.reviewer_verdict is None

    def test_only_invalid_completions_is_not_no_completion(self, conn):
        """An invalid completion exists — this is invalid_reviewer_completion,
        NOT no_reviewer_completion."""
        _submit_reviewer_completion(conn, head_sha="abc123", valid=False)
        result = rc.assess(conn, workflow_id="wf-1", current_head_sha="abc123")
        assert result.ready_for_guardian is False
        assert result.reason == rc.REASON_INVALID_COMPLETION

    def test_completion_for_different_workflow(self, conn):
        _submit_reviewer_completion(conn, workflow_id="wf-other", head_sha="abc123")
        result = rc.assess(conn, workflow_id="wf-1", current_head_sha="abc123")
        assert result.ready_for_guardian is False
        assert result.reason == rc.REASON_NO_COMPLETION

    def test_non_reviewer_completion_ignored(self, conn):
        """A valid tester completion is not a reviewer completion."""
        completions.submit(
            conn, "lease-t", "wf-1", "tester",
            {
                "EVAL_VERDICT": "ready_for_guardian",
                "EVAL_TESTS_PASS": "true",
                "EVAL_NEXT_ROLE": "guardian",
                "EVAL_HEAD_SHA": "abc123",
            },
        )
        result = rc.assess(conn, workflow_id="wf-1", current_head_sha="abc123")
        assert result.ready_for_guardian is False
        assert result.reason == rc.REASON_NO_COMPLETION


# ---------------------------------------------------------------------------
# Invalid reviewer completion
# ---------------------------------------------------------------------------


class TestInvalidCompletion:
    def test_invalid_completion_distinct_reason(self, conn):
        """Latest invalid reviewer completion produces REASON_INVALID_COMPLETION."""
        _submit_reviewer_completion(conn, head_sha="abc123", valid=False)
        result = rc.assess(conn, workflow_id="wf-1", current_head_sha="abc123")
        assert result.ready_for_guardian is False
        assert result.reason == rc.REASON_INVALID_COMPLETION
        # Payload fields are still populated from the invalid completion.
        assert result.reviewer_head_sha == "abc123"

    def test_latest_invalid_beats_older_valid(self, conn):
        """An older valid ready_for_guardian completion must NOT be used when
        the latest completion is invalid. Fail closed — even when both have
        identical created_at, the higher-id invalid row is latest."""
        # First: valid ready completion.
        _submit_reviewer_completion(
            conn, head_sha="abc123", verdict="ready_for_guardian",
            lease_id="lease-old", valid=True,
        )
        # Second: newer invalid completion (higher id).
        _submit_reviewer_completion(
            conn, head_sha="abc123", lease_id="lease-new", valid=False,
        )
        # Force identical timestamps so the test can only pass via id ordering.
        conn.execute(
            "UPDATE completion_records SET created_at = ?", (1000000,),
        )
        result = rc.assess(conn, workflow_id="wf-1", current_head_sha="abc123")
        assert result.ready_for_guardian is False
        assert result.reason == rc.REASON_INVALID_COMPLETION

    def test_invalid_completion_populates_verdict_from_payload(self, conn):
        """Even for invalid completions, reviewer_verdict is populated when
        a verdict field is available in the payload."""
        _submit_reviewer_completion(conn, head_sha="abc123", valid=False)
        result = rc.assess(conn, workflow_id="wf-1", current_head_sha="abc123")
        # The invalid completion used "not_a_real_verdict" as verdict.
        assert result.reviewer_verdict == "not_a_real_verdict"


# ---------------------------------------------------------------------------
# Deterministic latest selection
# ---------------------------------------------------------------------------


class TestDeterministicLatest:
    @staticmethod
    def _force_equal_created_at(conn, timestamp=1000000):
        """Set all completion_records rows to the same created_at so tie-break
        can only be resolved by the id column."""
        conn.execute(
            "UPDATE completion_records SET created_at = ?", (timestamp,),
        )

    def test_tie_breaking_uses_highest_id(self, conn):
        """When two completions have identical created_at, the one with the
        higher id (inserted later) wins. Proves list_completions ordering
        by created_at DESC, id DESC is deterministic."""
        _submit_reviewer_completion(
            conn, verdict="needs_changes", head_sha="abc123",
            lease_id="lease-first",
        )
        _submit_reviewer_completion(
            conn, verdict="ready_for_guardian", head_sha="abc123",
            lease_id="lease-second",
        )
        # Force identical timestamps — the only differentiator is id.
        self._force_equal_created_at(conn)
        result = rc.assess(conn, workflow_id="wf-1", current_head_sha="abc123")
        # Second (higher id) should win — ready_for_guardian.
        assert result.reviewer_verdict == "ready_for_guardian"
        assert result.ready_for_guardian is True
        assert result.reason == rc.REASON_READY

    def test_tie_breaking_invalid_higher_id_wins(self, conn):
        """When a valid and invalid completion have identical created_at,
        the higher-id invalid one wins and blocks readiness."""
        _submit_reviewer_completion(
            conn, verdict="ready_for_guardian", head_sha="abc123",
            lease_id="lease-valid",
        )
        _submit_reviewer_completion(
            conn, head_sha="abc123", lease_id="lease-invalid", valid=False,
        )
        # Force identical timestamps.
        self._force_equal_created_at(conn)
        result = rc.assess(conn, workflow_id="wf-1", current_head_sha="abc123")
        assert result.ready_for_guardian is False
        assert result.reason == rc.REASON_INVALID_COMPLETION


# ---------------------------------------------------------------------------
# Verdict not ready
# ---------------------------------------------------------------------------


class TestVerdictNotReady:
    def test_needs_changes_verdict(self, conn):
        _submit_reviewer_completion(
            conn, verdict="needs_changes", head_sha="abc123",
        )
        result = rc.assess(conn, workflow_id="wf-1", current_head_sha="abc123")
        assert result.ready_for_guardian is False
        assert result.reason == rc.REASON_VERDICT_NOT_READY
        assert result.reviewer_verdict == "needs_changes"

    def test_blocked_by_plan_verdict(self, conn):
        _submit_reviewer_completion(
            conn, verdict="blocked_by_plan", head_sha="abc123",
        )
        result = rc.assess(conn, workflow_id="wf-1", current_head_sha="abc123")
        assert result.ready_for_guardian is False
        assert result.reason == rc.REASON_VERDICT_NOT_READY
        assert result.reviewer_verdict == "blocked_by_plan"


# ---------------------------------------------------------------------------
# Stale head
# ---------------------------------------------------------------------------


class TestStaleHead:
    def test_head_sha_mismatch(self, conn):
        _submit_reviewer_completion(conn, head_sha="old-sha")
        result = rc.assess(conn, workflow_id="wf-1", current_head_sha="new-sha")
        assert result.ready_for_guardian is False
        assert result.reason == rc.REASON_STALE_HEAD
        assert result.stale_head is True
        assert result.reviewer_head_sha == "old-sha"
        assert result.current_head_sha == "new-sha"

    def test_stale_head_still_reports_open_blocking(self, conn):
        """Even when stale_head is the reason, open_blocking_count is populated."""
        _submit_reviewer_completion(conn, head_sha="old-sha")
        _insert_blocking_finding(conn)
        result = rc.assess(conn, workflow_id="wf-1", current_head_sha="new-sha")
        assert result.reason == rc.REASON_STALE_HEAD
        assert result.open_blocking_count == 1


# ---------------------------------------------------------------------------
# Open blocking findings
# ---------------------------------------------------------------------------


class TestOpenBlocking:
    def test_single_open_blocking(self, conn):
        _submit_reviewer_completion(conn, head_sha="abc123")
        _insert_blocking_finding(conn)
        result = rc.assess(conn, workflow_id="wf-1", current_head_sha="abc123")
        assert result.ready_for_guardian is False
        assert result.reason == rc.REASON_OPEN_BLOCKING
        assert result.open_blocking_count == 1

    def test_multiple_open_blocking(self, conn):
        _submit_reviewer_completion(conn, head_sha="abc123")
        _insert_blocking_finding(conn)
        _insert_blocking_finding(conn)
        result = rc.assess(conn, workflow_id="wf-1", current_head_sha="abc123")
        assert result.ready_for_guardian is False
        assert result.reason == rc.REASON_OPEN_BLOCKING
        assert result.open_blocking_count == 2

    def test_work_item_scoping(self, conn):
        """When work_item_id is supplied, only findings for that work item count."""
        _submit_reviewer_completion(conn, head_sha="abc123")
        _insert_blocking_finding(conn, work_item_id="wi-target")
        _insert_blocking_finding(conn, work_item_id="wi-other")
        result = rc.assess(
            conn, workflow_id="wf-1", current_head_sha="abc123",
            work_item_id="wi-target",
        )
        assert result.open_blocking_count == 1
        assert result.ready_for_guardian is False
        assert result.reason == rc.REASON_OPEN_BLOCKING

    def test_work_item_scoping_no_match_is_ready(self, conn):
        """Blocking findings for a different work_item_id don't block."""
        _submit_reviewer_completion(conn, head_sha="abc123")
        _insert_blocking_finding(conn, work_item_id="wi-other")
        result = rc.assess(
            conn, workflow_id="wf-1", current_head_sha="abc123",
            work_item_id="wi-target",
        )
        assert result.ready_for_guardian is True
        assert result.reason == rc.REASON_READY
        assert result.open_blocking_count == 0


# ---------------------------------------------------------------------------
# Priority ordering — earlier failure modes take precedence
# ---------------------------------------------------------------------------


class TestPriorityOrdering:
    def test_no_completion_is_highest_priority(self, conn):
        """No completion is the highest priority failure."""
        _insert_blocking_finding(conn)
        result = rc.assess(conn, workflow_id="wf-1", current_head_sha="abc123")
        assert result.reason == rc.REASON_NO_COMPLETION

    def test_invalid_completion_before_verdict(self, conn):
        """Invalid completion is checked before verdict analysis."""
        _submit_reviewer_completion(conn, head_sha="abc123", valid=False)
        _insert_blocking_finding(conn)
        result = rc.assess(conn, workflow_id="wf-1", current_head_sha="abc123")
        assert result.reason == rc.REASON_INVALID_COMPLETION

    def test_verdict_not_ready_before_stale_head(self, conn):
        """Non-ready verdict is checked before stale head."""
        _submit_reviewer_completion(
            conn, verdict="needs_changes", head_sha="old-sha",
        )
        result = rc.assess(conn, workflow_id="wf-1", current_head_sha="new-sha")
        assert result.reason == rc.REASON_VERDICT_NOT_READY

    def test_stale_head_before_open_blocking(self, conn):
        """Stale head is checked before open blocking findings."""
        _submit_reviewer_completion(conn, head_sha="old-sha")
        _insert_blocking_finding(conn)
        result = rc.assess(conn, workflow_id="wf-1", current_head_sha="new-sha")
        assert result.reason == rc.REASON_STALE_HEAD


# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------


class TestInputValidation:
    def test_empty_workflow_id_raises(self, conn):
        with pytest.raises(ValueError, match="workflow_id"):
            rc.assess(conn, workflow_id="", current_head_sha="abc123")

    def test_empty_current_head_sha_raises(self, conn):
        with pytest.raises(ValueError, match="current_head_sha"):
            rc.assess(conn, workflow_id="wf-1", current_head_sha="")


# ---------------------------------------------------------------------------
# Result shape
# ---------------------------------------------------------------------------


class TestResultShape:
    def test_result_is_frozen(self, conn):
        result = rc.assess(conn, workflow_id="wf-1", current_head_sha="abc123")
        with pytest.raises(AttributeError):
            result.ready_for_guardian = True  # type: ignore[misc]

    def test_all_fields_populated_on_ready(self, conn):
        _submit_reviewer_completion(conn, head_sha="abc123")
        result = rc.assess(conn, workflow_id="wf-1", current_head_sha="abc123")
        assert result.workflow_id == "wf-1"
        assert result.current_head_sha == "abc123"
        assert result.reviewer_head_sha is not None
        assert result.reviewer_verdict is not None
        assert isinstance(result.ready_for_guardian, bool)
        assert isinstance(result.stale_head, bool)
        assert isinstance(result.open_blocking_count, int)
        assert isinstance(result.reason, str)

    def test_all_fields_populated_on_no_completion(self, conn):
        result = rc.assess(conn, workflow_id="wf-1", current_head_sha="abc123")
        assert result.workflow_id == "wf-1"
        assert result.current_head_sha == "abc123"
        assert result.reviewer_head_sha is None
        assert result.reviewer_verdict is None
        assert result.ready_for_guardian is False
        assert result.stale_head is False
        assert result.open_blocking_count == 0
        assert result.reason == rc.REASON_NO_COMPLETION


# ---------------------------------------------------------------------------
# Reason code constants
# ---------------------------------------------------------------------------


class TestReasonCodes:
    def test_reason_codes_are_distinct(self):
        codes = {
            rc.REASON_READY,
            rc.REASON_NO_COMPLETION,
            rc.REASON_INVALID_COMPLETION,
            rc.REASON_VERDICT_NOT_READY,
            rc.REASON_STALE_HEAD,
            rc.REASON_OPEN_BLOCKING,
        }
        assert len(codes) == 6, "Reason codes must be distinct strings"

    def test_reason_codes_are_non_empty(self):
        for code in [
            rc.REASON_READY,
            rc.REASON_NO_COMPLETION,
            rc.REASON_INVALID_COMPLETION,
            rc.REASON_VERDICT_NOT_READY,
            rc.REASON_STALE_HEAD,
            rc.REASON_OPEN_BLOCKING,
        ]:
            assert len(code) > 0


# ---------------------------------------------------------------------------
# Import discipline
# ---------------------------------------------------------------------------


class TestImportDiscipline:
    """reviewer_convergence must not import routing, evaluation, hooks, or policies."""

    def _get_import_modules(self):
        source = inspect.getsource(rc)
        tree = ast.parse(source)
        modules = []
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom) and node.module:
                modules.append(node.module)
            elif isinstance(node, ast.Import):
                for alias in node.names:
                    modules.append(alias.name)
        return modules

    def test_no_dispatch_engine_import(self):
        for mod in self._get_import_modules():
            assert "dispatch_engine" not in mod

    def test_no_evaluation_state_import(self):
        for mod in self._get_import_modules():
            assert "evaluation_state" not in mod
            assert "evaluation" not in mod or mod == "runtime.core.evaluation"
            # Allow exact module name but not evaluation_state

    def test_no_evaluation_import(self):
        for mod in self._get_import_modules():
            assert mod != "runtime.core.evaluation"

    def test_no_hook_import(self):
        for mod in self._get_import_modules():
            assert "hook" not in mod.lower()

    def test_no_policy_import(self):
        for mod in self._get_import_modules():
            assert "policy" not in mod.lower()

    def test_imports_only_expected_authorities(self):
        """Positive check: the module should import exactly completions,
        reviewer_findings, and stage_registry from runtime.core."""
        source = inspect.getsource(rc)
        tree = ast.parse(source)
        runtime_core_imports = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom) and node.module:
                if node.module.startswith("runtime.core"):
                    # "from runtime.core import X" has module="runtime.core"
                    # and names=[X]. "from runtime.core.X import Y" has
                    # module="runtime.core.X". Normalise both forms.
                    if node.module == "runtime.core":
                        for alias in node.names:
                            runtime_core_imports.add(f"runtime.core.{alias.name}")
                    else:
                        runtime_core_imports.add(node.module)
        allowed = {
            "runtime.core.completions",
            "runtime.core.reviewer_findings",
            "runtime.core.stage_registry",
        }
        for mod in runtime_core_imports:
            assert mod in allowed, (
                f"Unexpected runtime.core import: {mod!r}; "
                f"allowed: {sorted(allowed)}"
            )
