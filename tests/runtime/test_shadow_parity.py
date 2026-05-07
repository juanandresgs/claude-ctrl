"""Tests for runtime/core/shadow_parity.py, the cc-policy shadow CLI, and
the end-to-end invariant sequence through ``process_agent_stop``.

@decision DEC-CLAUDEX-SHADOW-PARITY-TESTS-001
Title: Shadow parity aggregation, CLI output, and end-to-end reason sequence are pinned
Status: proposed (shadow-mode)
Rationale: The shadow observer only earns trust if drift is mechanically
  detectable. These tests pin three layers:

    1. Pure aggregation over synthetic event rows (no SQLite, no CLI). Tests
       the parseability predicate, the stable report shape, malformed
       handling, unknown-reason detection, and the reason-sequence helper.
    2. CLI output shape via subprocess: ``cc-policy shadow parity-report``
       returns valid JSON with a ``report`` key and supports ``--source``
       and ``--since`` filters.
    3. End-to-end invariant walk: drive a full mocked workflow through
       ``runtime.core.dispatch_engine.process_agent_stop`` (planner →
       implementer → reviewer → guardian) using in-memory SQLite and assert
       that the resulting ``shadow_stage_decision`` event stream produces
       exactly the expected reason sequence. Also verifies that live
       routing is unchanged (no regression) and that no event ever carries
       ``reason=unspecified_divergence``.

  Purity rules:
    * Aggregator tests never touch SQLite.
    * CLI tests use a per-test temporary DB via ``CLAUDE_POLICY_DB``.
    * End-to-end test uses an in-memory SQLite connection so it runs fast
      and isolates from real state.
"""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

from runtime.core import (
    completions,
    decision_work_registry as dwr,
    dispatch_shadow,
    enforcement_config,
    events,
    leases,
    shadow_parity,
)
from runtime.core import stage_registry as sr
from runtime.core.dispatch_engine import process_agent_stop
from runtime.schemas import ensure_schema

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


@pytest.fixture
def project_root(tmp_path):
    return str(tmp_path)


# ---------------------------------------------------------------------------
# Synthetic row builders
# ---------------------------------------------------------------------------


def _synthetic_row(
    *,
    row_id: int = 1,
    detail: dict | str | None = None,
    source: str = "workflow:wf-x",
    created_at: int = 1_000_000,
) -> dict:
    """Build a row dict shaped like ``events.query`` output."""
    if isinstance(detail, dict):
        detail_str: str | None = json.dumps(detail)
    else:
        detail_str = detail  # may be None or a raw string
    return {
        "id": row_id,
        "type": "shadow_stage_decision",
        "source": source,
        "detail": detail_str,
        "created_at": created_at,
    }


def _valid_payload(
    *,
    reason: str = dispatch_shadow.REASON_PARITY,
    agreed: bool = True,
    live_role: str = "planner",
    live_verdict: str = "",
    live_next_role: str | None = "guardian",
    shadow_from_stage: str = sr.PLANNER,
    shadow_verdict: str = "next_work_item",
    shadow_next_stage: str = sr.GUARDIAN_PROVISION,
) -> dict:
    return {
        "live_role": live_role,
        "live_verdict": live_verdict,
        "live_next_role": live_next_role,
        "shadow_from_stage": shadow_from_stage,
        "shadow_verdict": shadow_verdict,
        "shadow_next_stage": shadow_next_stage,
        "agreed": agreed,
        "reason": reason,
    }


# ---------------------------------------------------------------------------
# 1. parse_event_detail — pure predicate behavior
# ---------------------------------------------------------------------------


class TestParseEventDetail:
    def test_valid_row_returns_payload_dict(self):
        row = _synthetic_row(detail=_valid_payload())
        payload = shadow_parity.parse_event_detail(row)
        assert payload is not None
        assert payload["reason"] == dispatch_shadow.REASON_PARITY

    def test_missing_detail_returns_none(self):
        row = _synthetic_row(detail=None)
        assert shadow_parity.parse_event_detail(row) is None

    def test_empty_detail_returns_none(self):
        row = _synthetic_row(detail="")
        assert shadow_parity.parse_event_detail(row) is None

    def test_invalid_json_detail_returns_none(self):
        row = _synthetic_row(detail="{not valid json")
        assert shadow_parity.parse_event_detail(row) is None

    def test_non_dict_payload_returns_none(self):
        row = _synthetic_row(detail="[1, 2, 3]")
        assert shadow_parity.parse_event_detail(row) is None

    def test_missing_required_field_returns_none(self):
        payload = _valid_payload()
        del payload["reason"]
        row = _synthetic_row(detail=payload)
        assert shadow_parity.parse_event_detail(row) is None

    def test_non_dict_row_returns_none(self):
        assert shadow_parity.parse_event_detail("not a dict") is None  # type: ignore[arg-type]
        assert shadow_parity.parse_event_detail(None) is None  # type: ignore[arg-type]

    def test_parse_does_not_raise_on_any_input(self):
        # No input should raise.
        for bad in [None, "", "[]", "{}", 42, [], {"detail": 123}, {"detail": None}]:
            shadow_parity.parse_event_detail(bad)  # type: ignore[arg-type]


# ---------------------------------------------------------------------------
# 2. summarize — aggregation shape and semantics
# ---------------------------------------------------------------------------


class TestSummarize:
    def test_empty_input_returns_empty_report(self):
        report = shadow_parity.summarize([])
        assert report["total"] == 0
        assert report["parseable"] == 0
        assert report["agreed"] == 0
        assert report["diverged"] == 0
        assert report["malformed"] == 0
        assert report["reasons"] == {}
        assert report["has_unspecified_divergence"] is False
        assert report["has_unknown_reason"] is False
        assert report["first_event_id"] is None
        assert report["last_event_id"] is None
        assert report["oldest_created_at"] is None
        assert report["newest_created_at"] is None
        # known_reasons field is always populated and sorted.
        assert report["known_reasons"] == sorted(shadow_parity.KNOWN_REASONS)

    def test_report_is_json_serialisable(self):
        rows = [
            _synthetic_row(row_id=1, detail=_valid_payload()),
            _synthetic_row(
                row_id=2,
                detail=_valid_payload(
                    reason=dispatch_shadow.REASON_POST_GUARDIAN_CONTINUATION,
                    agreed=False,
                    live_role="guardian",
                    live_verdict="committed",
                    live_next_role=None,
                    shadow_from_stage=sr.GUARDIAN_LAND,
                    shadow_verdict="committed",
                    shadow_next_stage=sr.PLANNER,
                ),
            ),
        ]
        report = shadow_parity.summarize(rows)
        encoded = json.dumps(report)
        decoded = json.loads(encoded)
        assert decoded == report

    def test_parity_row_counts_as_agreed(self):
        rows = [_synthetic_row(detail=_valid_payload())]
        report = shadow_parity.summarize(rows)
        assert report["total"] == 1
        assert report["parseable"] == 1
        assert report["agreed"] == 1
        assert report["diverged"] == 0
        assert report["reasons"] == {dispatch_shadow.REASON_PARITY: 1}
        assert report["has_unspecified_divergence"] is False
        assert report["has_unknown_reason"] is False

    def test_post_guardian_continuation_counts_as_diverged(self):
        payload = _valid_payload(
            reason=dispatch_shadow.REASON_POST_GUARDIAN_CONTINUATION,
            agreed=False,
            live_role="guardian",
            live_verdict="committed",
            live_next_role=None,
            shadow_from_stage=sr.GUARDIAN_LAND,
            shadow_verdict="committed",
            shadow_next_stage=sr.PLANNER,
        )
        report = shadow_parity.summarize([_synthetic_row(detail=payload)])
        assert report["parseable"] == 1
        assert report["agreed"] == 0
        assert report["diverged"] == 1
        assert (
            report["reasons"][dispatch_shadow.REASON_POST_GUARDIAN_CONTINUATION] == 1
        )
        assert report["has_unspecified_divergence"] is False

    def test_malformed_row_counts_as_malformed(self):
        rows = [
            _synthetic_row(detail=_valid_payload()),
            _synthetic_row(detail="garbage"),
            _synthetic_row(detail=None),
        ]
        report = shadow_parity.summarize(rows)
        assert report["total"] == 3
        assert report["parseable"] == 1
        assert report["malformed"] == 2
        assert report["agreed"] == 1

    def test_unknown_reason_is_surfaced(self):
        payload = _valid_payload(reason="surprise_drift_code", agreed=False)
        report = shadow_parity.summarize([_synthetic_row(detail=payload)])
        assert report["has_unknown_reason"] is True
        assert "surprise_drift_code" in report["unknown_reasons"]
        assert report["reasons"]["surprise_drift_code"] == 1

    def test_unspecified_divergence_flag_fires(self):
        payload = _valid_payload(
            reason=dispatch_shadow.REASON_UNSPECIFIED_DIVERGENCE,
            agreed=False,
        )
        report = shadow_parity.summarize([_synthetic_row(detail=payload)])
        assert report["has_unspecified_divergence"] is True
        assert report["has_unknown_reason"] is False  # it's known, just bad

    def test_id_and_timestamp_range_captured(self):
        rows = [
            _synthetic_row(row_id=10, created_at=1000, detail=_valid_payload()),
            _synthetic_row(row_id=5, created_at=500, detail=_valid_payload()),
            _synthetic_row(row_id=7, created_at=2000, detail=_valid_payload()),
        ]
        report = shadow_parity.summarize(rows)
        assert report["first_event_id"] == 5
        assert report["last_event_id"] == 10
        assert report["oldest_created_at"] == 500
        assert report["newest_created_at"] == 2000

    def test_mixed_reason_counts_are_exact(self):
        rows = [
            _synthetic_row(row_id=1, detail=_valid_payload()),
            _synthetic_row(row_id=2, detail=_valid_payload()),
            _synthetic_row(
                row_id=3,
                detail=_valid_payload(
                    reason=dispatch_shadow.REASON_POST_GUARDIAN_CONTINUATION,
                    agreed=False,
                ),
            ),
            _synthetic_row(
                row_id=4,
                detail=_valid_payload(
                    reason=dispatch_shadow.REASON_GUARDIAN_SKIPPED_PLANNER,
                    agreed=False,
                ),
            ),
            _synthetic_row(row_id=5, detail="malformed"),
        ]
        report = shadow_parity.summarize(rows)
        assert report["total"] == 5
        assert report["parseable"] == 4
        assert report["malformed"] == 1
        assert report["agreed"] == 2
        assert report["diverged"] == 2
        assert report["reasons"] == {
            dispatch_shadow.REASON_PARITY: 2,
            dispatch_shadow.REASON_POST_GUARDIAN_CONTINUATION: 1,
            dispatch_shadow.REASON_GUARDIAN_SKIPPED_PLANNER: 1,
        }
        assert report["has_unspecified_divergence"] is False
        assert report["has_unknown_reason"] is False


# ---------------------------------------------------------------------------
# 3. reason_sequence helper
# ---------------------------------------------------------------------------


class TestReasonSequence:
    def test_returns_reasons_in_order(self):
        rows = [
            _synthetic_row(row_id=1, detail=_valid_payload()),
            _synthetic_row(
                row_id=2,
                detail=_valid_payload(
                    reason=dispatch_shadow.REASON_POST_GUARDIAN_CONTINUATION,
                    agreed=False,
                ),
            ),
        ]
        seq = shadow_parity.reason_sequence(rows)
        assert seq == [
            dispatch_shadow.REASON_PARITY,
            dispatch_shadow.REASON_POST_GUARDIAN_CONTINUATION,
        ]

    def test_malformed_rows_are_skipped(self):
        rows = [
            _synthetic_row(row_id=1, detail="garbage"),
            _synthetic_row(row_id=2, detail=_valid_payload()),
        ]
        seq = shadow_parity.reason_sequence(rows)
        assert seq == [dispatch_shadow.REASON_PARITY]


# ---------------------------------------------------------------------------
# 4. End-to-end invariant sequence through process_agent_stop
# ---------------------------------------------------------------------------


class TestEndToEndReasonSequence:
    """Walks a full mocked workflow through dispatch_engine and asserts the
    exact shadow reason sequence produced.

    Phase 6 Slice 5 canonical chain (all active roles delegated to stage_registry):
      planner stop (verdict=next_work_item)           → parity
      implementer stop (verdict=complete)              → parity
      reviewer stop (verdict=ready_for_guardian)        → parity
      guardian stop (verdict=committed, → planner)      → parity

    Also asserts:
      * Live next_role values match the Phase 5+ behavior exactly.
      * No event carries ``reason=unspecified_divergence``.
      * No unknown reason codes appear.
    """

    def _issue_lease_at(self, conn, role, project_root, workflow_id):
        return leases.issue(
            conn,
            role=role,
            workflow_id=workflow_id,
            worktree_path=project_root,
        )

    def _submit_planner(self, conn, lease_id, wf):
        return completions.submit(
            conn,
            lease_id=lease_id,
            workflow_id=wf,
            role="planner",
            payload={"PLAN_VERDICT": "next_work_item", "PLAN_SUMMARY": "e2e test"},
        )

    def _submit_impl(self, conn, lease_id, wf):
        return completions.submit(
            conn,
            lease_id=lease_id,
            workflow_id=wf,
            role="implementer",
            payload={"IMPL_STATUS": "complete", "IMPL_HEAD_SHA": "sha-e2e"},
        )

    def _submit_reviewer(self, conn, lease_id, wf):
        import json as _json
        return completions.submit(
            conn,
            lease_id=lease_id,
            workflow_id=wf,
            role="reviewer",
            payload={
                "REVIEW_VERDICT": "ready_for_guardian",
                "REVIEW_HEAD_SHA": "sha-e2e",
                "REVIEW_FINDINGS_JSON": _json.dumps({"findings": [
                    {"severity": "note", "title": "Minor", "detail": "Nit"},
                ]}),
            },
        )

    def _submit_guardian(self, conn, lease_id, wf):
        return completions.submit(
            conn,
            lease_id=lease_id,
            workflow_id=wf,
            role="guardian",
            payload={"LANDING_RESULT": "committed", "OPERATION_CLASS": "routine_local"},
        )

    def test_full_workflow_produces_expected_reason_sequence(
        self, conn, project_root
    ):
        wf = "wf-e2e-parity"
        # Phase 6 Slice 6: planner→guardian requires active goal contract.
        dwr.insert_goal(
            conn,
            dwr.GoalRecord(
                goal_id=wf,
                desired_end_state="E2E parity test",
                status="active",
                autonomy_budget=5,
            ),
        )

        # 1. Planner stop (Phase 6 Slice 4: requires lease+completion).
        lease_plan = self._issue_lease_at(conn, "planner", project_root, wf)
        self._submit_planner(conn, lease_plan["lease_id"], wf)
        result_planner = process_agent_stop(conn, "planner", project_root)
        assert result_planner["next_role"] == "guardian"
        assert result_planner["guardian_mode"] == "provision"
        assert result_planner["error"] is None

        # 2. Implementer stop with a valid completion contract.
        enforcement_config.set_(
            conn,
            "critic_enabled_implementer_stop",
            "false",
            scope=f"project={project_root}",
            actor_role="planner",
        )
        lease_impl = self._issue_lease_at(conn, "implementer", project_root, wf)
        self._submit_impl(conn, lease_impl["lease_id"], wf)
        result_impl = process_agent_stop(conn, "implementer", project_root)
        assert result_impl["next_role"] == "reviewer"  # Phase 5
        assert result_impl["error"] is None

        # 3. Reviewer stop with ready_for_guardian verdict (Phase 5: replaces tester).
        lease_rev = self._issue_lease_at(conn, "reviewer", project_root, wf)
        self._submit_reviewer(conn, lease_rev["lease_id"], wf)
        result_reviewer = process_agent_stop(conn, "reviewer", project_root)
        assert result_reviewer["next_role"] == "guardian"
        assert result_reviewer["error"] is None

        # 4. Guardian stop with committed verdict (Phase 6 Slice 5: → planner).
        lease_guard = self._issue_lease_at(conn, "guardian", project_root, wf)
        self._submit_guardian(conn, lease_guard["lease_id"], wf)
        result_guardian = process_agent_stop(conn, "guardian", project_root)
        assert result_guardian["next_role"] == "planner"  # post-guardian continuation
        assert result_guardian["error"] is None

        # Collect shadow events in chronological (insertion) order.
        # events.query returns newest-first; reverse for chronological order.
        rows = list(reversed(events.query(conn, type="shadow_stage_decision", limit=50)))
        assert len(rows) == 4, f"expected 4 shadow events, got {len(rows)}"

        # Assert the exact reason sequence — all PARITY after Phase 6 Slice 5.
        seq = shadow_parity.reason_sequence(rows)
        assert seq == [
            dispatch_shadow.REASON_PARITY,  # planner → guardian(provision)
            dispatch_shadow.REASON_PARITY,  # implementer → reviewer (direct parity)
            dispatch_shadow.REASON_PARITY,  # reviewer → guardian(land)
            dispatch_shadow.REASON_PARITY,  # guardian committed → planner (post-guardian continuation)
        ], f"actual reason sequence: {seq}"

        # Aggregate report sanity checks.
        report = shadow_parity.summarize(rows)
        assert report["total"] == 4
        assert report["parseable"] == 4
        assert report["malformed"] == 0
        assert report["agreed"] == 4
        assert report["diverged"] == 0
        assert report["reasons"] == {
            dispatch_shadow.REASON_PARITY: 4,
        }
        # The scenario must not surface any drift.
        assert report["has_unspecified_divergence"] is False
        assert report["has_unknown_reason"] is False
        assert report["unknown_reasons"] == []

    def test_guardian_skipped_scenario_produces_parity_after_slice5(
        self, conn, project_root
    ):
        """Phase 6 Slice 5: guardian skipped → planner (live matches shadow)."""
        wf = "wf-e2e-skipped"
        lease = leases.issue(
            conn, role="guardian", workflow_id=wf, worktree_path=project_root
        )
        completions.submit(
            conn,
            lease_id=lease["lease_id"],
            workflow_id=wf,
            role="guardian",
            payload={"LANDING_RESULT": "skipped", "OPERATION_CLASS": "routine_local"},
        )
        result = process_agent_stop(conn, "guardian", project_root)
        # Phase 6 Slice 5: live routing for skipped → planner (goal reassessment).
        assert result["next_role"] == "planner"
        assert result["error"] is None

        rows = list(reversed(events.query(conn, type="shadow_stage_decision", limit=10)))
        seq = shadow_parity.reason_sequence(rows)
        assert seq == [dispatch_shadow.REASON_PARITY]

        report = shadow_parity.summarize(rows)
        assert report["diverged"] == 0
        assert report["agreed"] == 1
        assert report["has_unspecified_divergence"] is False
        assert report["has_unknown_reason"] is False


# ---------------------------------------------------------------------------
# 5. CLI integration — subprocess tests
# ---------------------------------------------------------------------------

_WORKTREE = Path(__file__).resolve().parent.parent.parent
_CLI = str(_WORKTREE / "runtime" / "cli.py")


def _run_cli(args: list[str], db_path: str) -> tuple[int, dict]:
    env = {
        **os.environ,
        "CLAUDE_POLICY_DB": db_path,
        "PYTHONPATH": str(_WORKTREE),
    }
    result = subprocess.run(
        [sys.executable, _CLI] + args,
        capture_output=True,
        text=True,
        env=env,
    )
    output = result.stdout.strip() or result.stderr.strip()
    try:
        parsed = json.loads(output)
    except json.JSONDecodeError:
        parsed = {"_raw": output}
    return result.returncode, parsed


def _seed_shadow_event(
    db_path: str,
    *,
    detail: dict,
    source: str | None = "workflow:wf-cli",
    created_at_offset: int = 0,
) -> None:
    import time as _time

    c = sqlite3.connect(db_path)
    try:
        ensure_schema(c)
        c.row_factory = sqlite3.Row
        now = int(_time.time()) + created_at_offset
        with c:
            c.execute(
                "INSERT INTO events (type, source, detail, created_at) VALUES (?, ?, ?, ?)",
                ("shadow_stage_decision", source, json.dumps(detail), now),
            )
    finally:
        c.close()


class TestShadowCli:
    def test_parity_report_empty_db_returns_ok_and_empty_report(self, tmp_path):
        db = str(tmp_path / "empty.db")
        code, out = _run_cli(["shadow", "parity-report"], db)
        assert code == 0, f"stderr: {out}"
        assert out["status"] == "ok"
        assert "report" in out
        report = out["report"]
        assert report["total"] == 0
        assert report["reasons"] == {}
        assert report["has_unspecified_divergence"] is False
        assert report["has_unknown_reason"] is False
        # Known reasons list is always populated.
        assert dispatch_shadow.REASON_PARITY in report["known_reasons"]

    def test_parity_report_with_seeded_events(self, tmp_path):
        db = str(tmp_path / "seeded.db")
        _seed_shadow_event(db, detail=_valid_payload())
        _seed_shadow_event(
            db,
            detail=_valid_payload(
                reason=dispatch_shadow.REASON_POST_GUARDIAN_CONTINUATION,
                agreed=False,
                live_role="guardian",
                live_verdict="committed",
                live_next_role=None,
                shadow_from_stage=sr.GUARDIAN_LAND,
                shadow_verdict="committed",
                shadow_next_stage=sr.PLANNER,
            ),
        )
        code, out = _run_cli(["shadow", "parity-report"], db)
        assert code == 0
        report = out["report"]
        assert report["total"] == 2
        assert report["parseable"] == 2
        assert report["agreed"] == 1
        assert report["diverged"] == 1
        assert report["reasons"][dispatch_shadow.REASON_PARITY] == 1
        assert (
            report["reasons"][dispatch_shadow.REASON_POST_GUARDIAN_CONTINUATION] == 1
        )
        assert report["has_unspecified_divergence"] is False
        assert report["has_unknown_reason"] is False

    def test_parity_report_source_filter(self, tmp_path):
        db = str(tmp_path / "source.db")
        _seed_shadow_event(
            db, detail=_valid_payload(), source="workflow:wf-keep"
        )
        _seed_shadow_event(
            db, detail=_valid_payload(), source="workflow:wf-drop"
        )
        code, out = _run_cli(
            ["shadow", "parity-report", "--source", "workflow:wf-keep"], db
        )
        assert code == 0
        report = out["report"]
        assert report["total"] == 1
        assert report["agreed"] == 1

    def test_parity_report_surfaces_unspecified_divergence(self, tmp_path):
        db = str(tmp_path / "unspec.db")
        _seed_shadow_event(
            db,
            detail=_valid_payload(
                reason=dispatch_shadow.REASON_UNSPECIFIED_DIVERGENCE,
                agreed=False,
            ),
        )
        code, out = _run_cli(["shadow", "parity-report"], db)
        assert code == 0
        report = out["report"]
        assert report["has_unspecified_divergence"] is True
        assert report["diverged"] == 1

    def test_parity_report_surfaces_unknown_reason(self, tmp_path):
        db = str(tmp_path / "unknown.db")
        _seed_shadow_event(
            db, detail=_valid_payload(reason="unrecognised_code", agreed=False)
        )
        code, out = _run_cli(["shadow", "parity-report"], db)
        assert code == 0
        report = out["report"]
        assert report["has_unknown_reason"] is True
        assert "unrecognised_code" in report["unknown_reasons"]

    def test_parity_report_since_filter(self, tmp_path):
        db = str(tmp_path / "since.db")
        # Old event, well outside the window.
        _seed_shadow_event(
            db, detail=_valid_payload(), created_at_offset=-3600
        )
        # Recent event.
        _seed_shadow_event(db, detail=_valid_payload(), created_at_offset=0)
        import time as _time

        # --since one minute ago should only pick up the recent event.
        code, out = _run_cli(
            ["shadow", "parity-report", "--since", str(int(_time.time()) - 60)],
            db,
        )
        assert code == 0
        report = out["report"]
        assert report["total"] == 1


# ---------------------------------------------------------------------------
# 6. Pure check_invariants helper
# ---------------------------------------------------------------------------


class TestCheckInvariants:
    def test_empty_report_is_healthy(self):
        report = shadow_parity.summarize([])
        inv = shadow_parity.check_invariants(report)
        assert inv["healthy"] is True
        assert inv["violations"] == []
        assert inv["details"] == {}

    def test_all_parity_rows_are_healthy(self):
        rows = [
            _synthetic_row(row_id=1, detail=_valid_payload()),
            _synthetic_row(row_id=2, detail=_valid_payload()),
        ]
        report = shadow_parity.summarize(rows)
        inv = shadow_parity.check_invariants(report)
        assert inv["healthy"] is True
        assert inv["violations"] == []

    def test_known_divergence_is_still_healthy(self):
        # Known planned divergences (post_guardian_continuation, guardian
        # skipped reroute) are NOT violations — they're expected drift
        # against the current live graph.
        rows = [
            _synthetic_row(
                row_id=1,
                detail=_valid_payload(
                    reason=dispatch_shadow.REASON_POST_GUARDIAN_CONTINUATION,
                    agreed=False,
                ),
            ),
            _synthetic_row(
                row_id=2,
                detail=_valid_payload(
                    reason=dispatch_shadow.REASON_GUARDIAN_SKIPPED_PLANNER,
                    agreed=False,
                ),
            ),
        ]
        report = shadow_parity.summarize(rows)
        inv = shadow_parity.check_invariants(report)
        assert inv["healthy"] is True
        assert inv["violations"] == []

    def test_unspecified_divergence_flags_violation(self):
        rows = [
            _synthetic_row(
                detail=_valid_payload(
                    reason=dispatch_shadow.REASON_UNSPECIFIED_DIVERGENCE,
                    agreed=False,
                )
            )
        ]
        report = shadow_parity.summarize(rows)
        inv = shadow_parity.check_invariants(report)
        assert inv["healthy"] is False
        assert shadow_parity.VIOLATION_UNSPECIFIED_DIVERGENCE in inv["violations"]

    def test_unknown_reason_flags_violation_and_lists_details(self):
        rows = [
            _synthetic_row(
                detail=_valid_payload(reason="rogue_reason_code", agreed=False)
            )
        ]
        report = shadow_parity.summarize(rows)
        inv = shadow_parity.check_invariants(report)
        assert inv["healthy"] is False
        assert shadow_parity.VIOLATION_UNKNOWN_REASON in inv["violations"]
        assert (
            "rogue_reason_code"
            in inv["details"][shadow_parity.VIOLATION_UNKNOWN_REASON]
        )

    def test_both_violations_present(self):
        rows = [
            _synthetic_row(
                row_id=1,
                detail=_valid_payload(
                    reason=dispatch_shadow.REASON_UNSPECIFIED_DIVERGENCE,
                    agreed=False,
                ),
            ),
            _synthetic_row(
                row_id=2,
                detail=_valid_payload(reason="rogue", agreed=False),
            ),
        ]
        report = shadow_parity.summarize(rows)
        inv = shadow_parity.check_invariants(report)
        assert inv["healthy"] is False
        assert shadow_parity.VIOLATION_UNSPECIFIED_DIVERGENCE in inv["violations"]
        assert shadow_parity.VIOLATION_UNKNOWN_REASON in inv["violations"]

    def test_malformed_rows_alone_are_not_a_violation(self):
        # A single corrupt event should not block the invariant check.
        rows = [
            _synthetic_row(row_id=1, detail="garbage"),
            _synthetic_row(row_id=2, detail=_valid_payload()),
        ]
        report = shadow_parity.summarize(rows)
        inv = shadow_parity.check_invariants(report)
        assert inv["healthy"] is True

    def test_invariant_result_is_json_serialisable(self):
        inv = shadow_parity.check_invariants(shadow_parity.summarize([]))
        assert json.loads(json.dumps(inv)) == inv

    def test_partial_report_does_not_raise(self):
        # Tolerate a caller passing a partially-populated dict.
        inv = shadow_parity.check_invariants({})
        assert inv["healthy"] is True
        assert inv["violations"] == []

    def test_unknown_reasons_not_list_is_tolerated(self):
        bad = {
            "has_unspecified_divergence": False,
            "has_unknown_reason": True,
            "unknown_reasons": "not-a-list",
        }
        inv = shadow_parity.check_invariants(bad)
        assert inv["healthy"] is False
        assert shadow_parity.VIOLATION_UNKNOWN_REASON in inv["violations"]
        assert inv["details"][shadow_parity.VIOLATION_UNKNOWN_REASON] == []


# ---------------------------------------------------------------------------
# 7. CLI parity-invariant command — pass / fail exit code and payload shape
# ---------------------------------------------------------------------------


class TestShadowParityInvariantCli:
    def test_empty_db_exits_healthy(self, tmp_path):
        db = str(tmp_path / "empty-invariant.db")
        code, out = _run_cli(["shadow", "parity-invariant"], db)
        assert code == 0
        assert out["status"] == "ok"
        assert "report" in out
        assert "invariant" in out
        assert out["invariant"]["healthy"] is True
        assert out["invariant"]["violations"] == []
        assert out["invariant"]["details"] == {}

    def test_only_known_reasons_exits_healthy(self, tmp_path):
        db = str(tmp_path / "known-only.db")
        _seed_shadow_event(db, detail=_valid_payload())
        _seed_shadow_event(
            db,
            detail=_valid_payload(
                reason=dispatch_shadow.REASON_POST_GUARDIAN_CONTINUATION,
                agreed=False,
                live_role="guardian",
                live_verdict="committed",
                live_next_role=None,
                shadow_from_stage=sr.GUARDIAN_LAND,
                shadow_verdict="committed",
                shadow_next_stage=sr.PLANNER,
            ),
        )
        code, out = _run_cli(["shadow", "parity-invariant"], db)
        assert code == 0
        assert out["status"] == "ok"
        assert out["invariant"]["healthy"] is True
        report = out["report"]
        assert report["total"] == 2
        assert report["agreed"] == 1
        assert report["diverged"] == 1

    def test_unspecified_divergence_exits_non_zero(self, tmp_path):
        db = str(tmp_path / "unspec-invariant.db")
        _seed_shadow_event(
            db,
            detail=_valid_payload(
                reason=dispatch_shadow.REASON_UNSPECIFIED_DIVERGENCE,
                agreed=False,
            ),
        )
        code, out = _run_cli(["shadow", "parity-invariant"], db)
        assert code == 1
        # Payload still present on stdout so CI can parse it.
        assert "report" in out
        assert "invariant" in out
        assert out["invariant"]["healthy"] is False
        assert (
            shadow_parity.VIOLATION_UNSPECIFIED_DIVERGENCE
            in out["invariant"]["violations"]
        )
        assert out["status"] == "violation"

    def test_unknown_reason_exits_non_zero_with_details(self, tmp_path):
        db = str(tmp_path / "unknown-invariant.db")
        _seed_shadow_event(
            db, detail=_valid_payload(reason="banana_drift", agreed=False)
        )
        code, out = _run_cli(["shadow", "parity-invariant"], db)
        assert code == 1
        assert out["status"] == "violation"
        assert out["invariant"]["healthy"] is False
        assert (
            shadow_parity.VIOLATION_UNKNOWN_REASON
            in out["invariant"]["violations"]
        )
        assert (
            "banana_drift"
            in out["invariant"]["details"][shadow_parity.VIOLATION_UNKNOWN_REASON]
        )

    def test_both_violations_reported_together(self, tmp_path):
        db = str(tmp_path / "both-invariant.db")
        _seed_shadow_event(
            db,
            detail=_valid_payload(
                reason=dispatch_shadow.REASON_UNSPECIFIED_DIVERGENCE,
                agreed=False,
            ),
        )
        _seed_shadow_event(
            db, detail=_valid_payload(reason="other_drift", agreed=False)
        )
        code, out = _run_cli(["shadow", "parity-invariant"], db)
        assert code == 1
        violations = out["invariant"]["violations"]
        assert shadow_parity.VIOLATION_UNSPECIFIED_DIVERGENCE in violations
        assert shadow_parity.VIOLATION_UNKNOWN_REASON in violations

    def test_source_filter_isolates_workflows(self, tmp_path):
        db = str(tmp_path / "source-invariant.db")
        # Drift in workflow A
        _seed_shadow_event(
            db,
            source="workflow:wf-bad",
            detail=_valid_payload(reason="rogue", agreed=False),
        )
        # Healthy workflow B
        _seed_shadow_event(
            db, source="workflow:wf-good", detail=_valid_payload()
        )

        # Scope to wf-good → healthy.
        code, out = _run_cli(
            ["shadow", "parity-invariant", "--source", "workflow:wf-good"], db
        )
        assert code == 0
        assert out["invariant"]["healthy"] is True

        # Scope to wf-bad → non-zero.
        code, out = _run_cli(
            ["shadow", "parity-invariant", "--source", "workflow:wf-bad"], db
        )
        assert code == 1
        assert out["invariant"]["healthy"] is False

    def test_end_to_end_workflow_passes_invariant(self, tmp_path):
        # Drive a real workflow through process_agent_stop (using the
        # same temp DB the CLI will read) and then invoke the invariant
        # CLI. Phase 5+ canonical chain: planner → implementer → reviewer → guardian.
        import json as _json

        db = str(tmp_path / "e2e-invariant.db")
        conn_local = sqlite3.connect(db)
        conn_local.row_factory = sqlite3.Row
        ensure_schema(conn_local)
        try:
            wf = "wf-e2e-inv"
            project = str(tmp_path / "project")
            os.makedirs(project, exist_ok=True)

            # Phase 6 Slice 6: planner→guardian requires active goal contract.
            dwr.insert_goal(
                conn_local,
                dwr.GoalRecord(
                    goal_id=wf,
                    desired_end_state="CLI E2E invariant test",
                    status="active",
                    autonomy_budget=5,
                ),
            )

            # Planner stop (Phase 6 Slice 4: requires lease+completion)
            lease_plan = leases.issue(
                conn_local, role="planner", workflow_id=wf, worktree_path=project,
            )
            completions.submit(
                conn_local,
                lease_id=lease_plan["lease_id"],
                workflow_id=wf,
                role="planner",
                payload={"PLAN_VERDICT": "next_work_item", "PLAN_SUMMARY": "e2e"},
            )
            process_agent_stop(conn_local, "planner", project)

            # Implementer stop
            enforcement_config.set_(
                conn_local,
                "critic_enabled_implementer_stop",
                "false",
                scope=f"project={project}",
                actor_role="planner",
            )
            lease_impl = leases.issue(
                conn_local, role="implementer", workflow_id=wf, worktree_path=project,
            )
            completions.submit(
                conn_local,
                lease_id=lease_impl["lease_id"],
                workflow_id=wf,
                role="implementer",
                payload={"IMPL_STATUS": "complete", "IMPL_HEAD_SHA": "sha-cli"},
            )
            process_agent_stop(conn_local, "implementer", project)

            # Reviewer stop (Phase 5: replaces tester in canonical chain)
            lease_rev = leases.issue(
                conn_local, role="reviewer", workflow_id=wf, worktree_path=project,
            )
            completions.submit(
                conn_local,
                lease_id=lease_rev["lease_id"],
                workflow_id=wf,
                role="reviewer",
                payload={
                    "REVIEW_VERDICT": "ready_for_guardian",
                    "REVIEW_HEAD_SHA": "sha-cli",
                    "REVIEW_FINDINGS_JSON": _json.dumps({"findings": [
                        {"severity": "note", "title": "OK", "detail": "LGTM"},
                    ]}),
                },
            )
            process_agent_stop(conn_local, "reviewer", project)

            # Guardian stop (committed → planner, Phase 6 Slice 5)
            lease_guard = leases.issue(
                conn_local, role="guardian", workflow_id=wf, worktree_path=project,
            )
            completions.submit(
                conn_local,
                lease_id=lease_guard["lease_id"],
                workflow_id=wf,
                role="guardian",
                payload={
                    "LANDING_RESULT": "committed",
                    "OPERATION_CLASS": "routine_local",
                },
            )
            process_agent_stop(conn_local, "guardian", project)
        finally:
            conn_local.close()

        code, out = _run_cli(["shadow", "parity-invariant"], db)
        assert code == 0, (
            "end-to-end workflow must not produce unspecified or unknown drift"
        )
        assert out["invariant"]["healthy"] is True
        assert out["invariant"]["violations"] == []
        # Phase 6 Slice 5: all 4 transitions are now parity.
        report = out["report"]
        assert report["total"] == 4
        assert report["reasons"].get(dispatch_shadow.REASON_PARITY) == 4

    def test_invariant_does_not_affect_live_routing(self, conn, project_root):
        # Run the live dispatch engine then compare its results to the
        # pre-invariant expectations. The CLI is read-only, so this is
        # primarily a re-assertion of the existing dispatch contract —
        # included here to keep the slice's scope visible in one file.
        # Phase 5+: use reviewer (replaces tester in canonical chain).
        import json as _json

        wf = "wf-live-unchanged"
        lease = leases.issue(
            conn, role="reviewer", workflow_id=wf, worktree_path=project_root
        )
        completions.submit(
            conn,
            lease_id=lease["lease_id"],
            workflow_id=wf,
            role="reviewer",
            payload={
                "REVIEW_VERDICT": "ready_for_guardian",
                "REVIEW_HEAD_SHA": "sha-live",
                "REVIEW_FINDINGS_JSON": _json.dumps({"findings": [
                    {"severity": "note", "title": "OK", "detail": "LGTM"},
                ]}),
            },
        )
        result = process_agent_stop(conn, "reviewer", project_root)
        assert result["next_role"] == "guardian"
        assert result["error"] is None
        assert result["auto_dispatch"] is True
