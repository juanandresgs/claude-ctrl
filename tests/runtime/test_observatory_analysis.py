"""Unit tests for W-OBS-3: cross_analysis, pattern_detection, generate_report,
and the updated summary() delegation.

Tests use in-memory SQLite with the full schema applied. No mocks — all
assertions run through real SQLite. Enrichment tables (traces, evaluation_state,
completion_records, agent_markers) may be empty; null-tolerance is verified
by design.

Production trigger sequence (W-OBS-3):
  1. Hooks emit obs_metrics rows throughout an agent session.
  2. Periodically, cc-policy obs summary calls summary() → generate_report().
  3. generate_report() calls cross_analysis() and pattern_detection() to build
     the full operational picture, including LEFT-JOIN enrichment from traces,
     evaluation_state, and completion_records.
  4. The /observatory skill calls cc-policy obs summary --window-hours 24 and
     presents findings to the LLM for synthesis and suggestion proposals.

These tests exercise that sequence end-to-end (test_full_production_sequence_obs3).

@decision DEC-OBS-004
Title: W-OBS-3 analysis uses LEFT JOIN for all enrichment tables
Status: accepted
Rationale: obs_metrics is the primary data source. Enrichment tables may have
  zero rows in early sessions or test environments. All cross-table queries use
  LEFT JOIN so null enrichment columns produce NULL rather than empty result sets.
  This ensures cross_analysis always produces a usable report regardless of which
  other tables have data.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

import runtime.core.observatory as obs
from runtime.core.db import connect_memory
from runtime.schemas import ensure_schema

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    c = connect_memory()
    ensure_schema(c)
    yield c
    c.close()


@pytest.fixture
def conn_with_metrics(conn):
    """DB with representative obs_metrics data for analysis tests."""
    # Agent duration metrics for multiple roles
    for v in [30.0, 35.0, 32.0, 28.0, 40.0]:
        obs.emit_metric(conn, "agent_duration_s", v, role="implementer", session_id="sess-impl-1")
    for v in [15.0, 18.0, 12.0]:
        obs.emit_metric(conn, "agent_duration_s", v, role="reviewer", session_id="sess-test-1")

    # Test results
    for _ in range(7):
        obs.emit_metric(conn, "test_result", 1.0, role="reviewer")
    for _ in range(3):
        obs.emit_metric(conn, "test_result", 0.0, role="reviewer")

    # Guard denials
    obs.emit_metric(conn, "guard_denial", 1.0, labels={"policy": "branch-guard"})
    obs.emit_metric(conn, "guard_denial", 1.0, labels={"policy": "branch-guard"})
    obs.emit_metric(conn, "guard_denial", 1.0, labels={"policy": "scope-guard"})

    # Eval verdicts
    obs.emit_metric(conn, "eval_verdict", 1.0, labels={"verdict": "pass"})
    obs.emit_metric(conn, "eval_verdict", 0.0, labels={"verdict": "needs_changes"})
    obs.emit_metric(conn, "eval_verdict", 1.0, labels={"verdict": "pass"})

    # Review metrics
    obs.emit_metric(
        conn, "review_verdict", 1.0, labels={"verdict": "approved", "provider": "codex"}
    )
    obs.emit_metric(
        conn, "review_verdict", 0.0, labels={"verdict": "changes_requested", "provider": "codex"}
    )
    obs.emit_metric(conn, "review_duration_s", 45.0, labels={"provider": "codex"})
    obs.emit_metric(conn, "review_infra_failure", 1.0, labels={"provider": "codex"})

    return conn


# ---------------------------------------------------------------------------
# EC-1: cross_analysis returns dict with all 6 expected keys
# ---------------------------------------------------------------------------


def test_cross_analysis_returns_all_six_keys(conn_with_metrics):
    """EC-1: cross_analysis with populated obs_metrics returns dict with all 6 keys."""
    result = obs.cross_analysis(conn_with_metrics)
    assert isinstance(result, dict)
    assert "agent_stats" in result
    assert "test_health" in result
    assert "denial_patterns" in result
    assert "evaluation_trends" in result
    assert "convergence_status" in result
    assert "review_gate_health" in result


def test_cross_analysis_agent_stats_populated(conn_with_metrics):
    """agent_stats contains per-role metrics for roles with data."""
    result = obs.cross_analysis(conn_with_metrics)
    agent_stats = result["agent_stats"]
    assert isinstance(agent_stats, list)
    # At least implementer and reviewer should appear
    roles_found = {row["role"] for row in agent_stats}
    assert "implementer" in roles_found
    assert "reviewer" in roles_found
    # Each entry has required keys
    for entry in agent_stats:
        assert "role" in entry
        assert "count" in entry
        assert "avg_duration" in entry


def test_cross_analysis_test_health_populated(conn_with_metrics):
    """test_health reflects the seeded pass/fail counts."""
    result = obs.cross_analysis(conn_with_metrics)
    th = result["test_health"]
    assert th["total"] == 10
    assert th["passed"] == 7
    assert th["failed"] == 3
    assert th["pass_rate"] == pytest.approx(0.7)


def test_cross_analysis_denial_patterns_populated(conn_with_metrics):
    """denial_patterns groups by policy and returns counts."""
    result = obs.cross_analysis(conn_with_metrics)
    dp = result["denial_patterns"]
    assert isinstance(dp, list)
    policies = {row["policy"] for row in dp}
    assert "branch-guard" in policies
    branch_row = next(r for r in dp if r["policy"] == "branch-guard")
    assert branch_row["count"] == 2


def test_cross_analysis_review_gate_health_populated(conn_with_metrics):
    """review_gate_health contains infra failure stats and verdict distribution."""
    result = obs.cross_analysis(conn_with_metrics)
    rgh = result["review_gate_health"]
    assert "total_reviews" in rgh
    assert "infra_failures" in rgh
    assert "infra_failure_rate" in rgh
    assert rgh["total_reviews"] >= 1
    assert rgh["infra_failures"] == 1


# ---------------------------------------------------------------------------
# EC-2: null-tolerance — cross_analysis with EMPTY enrichment tables
# ---------------------------------------------------------------------------


def test_cross_analysis_null_tolerance_empty_enrichment(conn):
    """EC-2 (CRITICAL): cross_analysis with obs_metrics populated but traces,
    completion_records, evaluation_state, agent_markers all EMPTY must return
    a valid dict with all 6 keys and produce no crash.

    This proves LEFT JOIN correctness — enrichment-empty DBs still produce
    a usable analysis.
    """
    # Seed ONLY obs_metrics
    for v in [10.0, 20.0, 30.0]:
        obs.emit_metric(conn, "agent_duration_s", v, role="implementer")
    obs.emit_metric(conn, "test_result", 1.0)
    obs.emit_metric(conn, "guard_denial", 1.0, labels={"policy": "p1"})

    # Verify enrichment tables are empty
    assert conn.execute("SELECT COUNT(*) FROM traces").fetchone()[0] == 0
    assert conn.execute("SELECT COUNT(*) FROM completion_records").fetchone()[0] == 0
    assert conn.execute("SELECT COUNT(*) FROM evaluation_state").fetchone()[0] == 0
    assert conn.execute("SELECT COUNT(*) FROM agent_markers").fetchone()[0] == 0

    # Should not raise and must return all 6 keys
    result = obs.cross_analysis(conn)
    assert isinstance(result, dict)
    assert "agent_stats" in result
    assert "test_health" in result
    assert "denial_patterns" in result
    assert "evaluation_trends" in result
    assert "convergence_status" in result
    assert "review_gate_health" in result


def test_cross_analysis_completely_empty_db(conn):
    """cross_analysis on a completely empty DB returns valid structure with zero counts."""
    result = obs.cross_analysis(conn)
    assert isinstance(result, dict)
    assert result["test_health"]["total"] == 0
    assert result["agent_stats"] == []
    assert result["denial_patterns"] == []
    assert result["evaluation_trends"] == []


# ---------------------------------------------------------------------------
# EC-3: pattern_detection — repeated_denial
# ---------------------------------------------------------------------------


def test_pattern_detection_repeated_denial(conn):
    """EC-3: pattern_detection identifies repeated_denial when same policy denied 3+ times."""
    # Emit 4 denials for the same policy
    for _ in range(4):
        obs.emit_metric(conn, "guard_denial", 1.0, labels={"policy": "branch-guard"})
    # Emit 2 for another (below threshold)
    for _ in range(2):
        obs.emit_metric(conn, "guard_denial", 1.0, labels={"policy": "scope-guard"})

    patterns = obs.pattern_detection(conn)
    assert isinstance(patterns, list)
    denial_patterns = [p for p in patterns if p["pattern_type"] == "repeated_denial"]
    assert len(denial_patterns) >= 1
    # branch-guard should be flagged
    branch_pattern = next(
        (
            p
            for p in denial_patterns
            if "branch-guard" in str(p.get("description", ""))
            or "branch-guard" in str(p.get("evidence", []))
        ),
        None,
    )
    assert branch_pattern is not None, (
        f"expected repeated_denial for branch-guard, got: {denial_patterns}"
    )
    assert branch_pattern["severity_score"] > 0
    assert "suggested_action" in branch_pattern
    assert "evidence" in branch_pattern


def test_pattern_detection_repeated_denial_below_threshold(conn):
    """Policies with < 3 denials do NOT trigger repeated_denial pattern."""
    obs.emit_metric(conn, "guard_denial", 1.0, labels={"policy": "scope-guard"})
    obs.emit_metric(conn, "guard_denial", 1.0, labels={"policy": "scope-guard"})

    patterns = obs.pattern_detection(conn)
    denial_patterns = [p for p in patterns if p["pattern_type"] == "repeated_denial"]
    scope_pattern = next(
        (p for p in denial_patterns if "scope-guard" in str(p.get("description", ""))),
        None,
    )
    assert scope_pattern is None


# ---------------------------------------------------------------------------
# EC-4: pattern_detection — slow_agent
# ---------------------------------------------------------------------------


def test_pattern_detection_slow_agent_increasing(conn):
    """EC-4: pattern_detection identifies slow_agent when agent duration trend has slope > 0.1."""
    # Emit monotonically increasing durations for implementer so slope is high
    for v in [10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0, 90.0, 100.0]:
        obs.emit_metric(conn, "agent_duration_s", float(v), role="implementer")

    patterns = obs.pattern_detection(conn)
    slow_patterns = [p for p in patterns if p["pattern_type"] == "slow_agent"]
    # At least implementer should be flagged (slope = (100-10)/10 = 9.0 > 0.1)
    assert len(slow_patterns) >= 1
    impl_pattern = next(
        (p for p in slow_patterns if "implementer" in str(p.get("description", ""))),
        None,
    )
    assert impl_pattern is not None
    assert impl_pattern["severity_score"] > 0


def test_pattern_detection_slow_agent_flat_not_flagged(conn):
    """Flat agent durations (slope ~0) do NOT trigger slow_agent."""
    for _ in range(5):
        obs.emit_metric(conn, "agent_duration_s", 30.0, role="reviewer")

    patterns = obs.pattern_detection(conn)
    slow_patterns = [p for p in patterns if p["pattern_type"] == "slow_agent"]
    reviewer_pattern = next(
        (p for p in slow_patterns if "reviewer" in str(p.get("description", ""))),
        None,
    )
    assert reviewer_pattern is None


# ---------------------------------------------------------------------------
# EC-5: pattern_detection — review_quality
# ---------------------------------------------------------------------------


def test_pattern_detection_review_quality_high_infra_failures(conn):
    """EC-5: pattern_detection flags review_quality when infra failure rate > 20%."""
    # 3 infra failures out of 5 total reviews = 60% failure rate
    for _ in range(3):
        obs.emit_metric(conn, "review_infra_failure", 1.0, labels={"provider": "codex"})
    for _ in range(5):
        obs.emit_metric(
            conn, "review_verdict", 1.0, labels={"verdict": "approved", "provider": "codex"}
        )

    patterns = obs.pattern_detection(conn)
    quality_patterns = [p for p in patterns if p["pattern_type"] == "review_quality"]
    assert len(quality_patterns) >= 1
    assert quality_patterns[0]["severity_score"] > 0
    assert "suggested_action" in quality_patterns[0]


def test_pattern_detection_review_quality_low_infra_failures(conn):
    """Low infra failure rate (<=20%) does NOT trigger review_quality pattern."""
    # 1 failure out of 10 reviews = 10% — below threshold
    obs.emit_metric(conn, "review_infra_failure", 1.0, labels={"provider": "codex"})
    for _ in range(10):
        obs.emit_metric(
            conn, "review_verdict", 1.0, labels={"verdict": "approved", "provider": "codex"}
        )

    patterns = obs.pattern_detection(conn)
    quality_patterns = [p for p in patterns if p["pattern_type"] == "review_quality"]
    assert len(quality_patterns) == 0


# ---------------------------------------------------------------------------
# EC-6: generate_report returns all expected keys
# ---------------------------------------------------------------------------


def test_generate_report_returns_all_keys(conn_with_metrics):
    """EC-6: generate_report returns dict with all expected top-level keys."""
    result = obs.generate_report(conn_with_metrics)
    assert isinstance(result, dict)
    assert "metrics_summary" in result
    assert "trends" in result
    assert "patterns" in result
    assert "suggestions" in result
    assert "convergence" in result
    assert "review_gate_health" in result


def test_generate_report_metrics_summary_structure(conn_with_metrics):
    """metrics_summary has total, by_type, by_role keys."""
    result = obs.generate_report(conn_with_metrics)
    ms = result["metrics_summary"]
    assert "total" in ms
    assert "by_type" in ms
    assert "by_role" in ms
    assert ms["total"] > 0
    assert isinstance(ms["by_type"], dict)
    assert isinstance(ms["by_role"], dict)


def test_generate_report_records_obs_run(conn_with_metrics):
    """EC-6: generate_report calls record_run, incrementing obs_runs count."""
    before = conn_with_metrics.execute("SELECT COUNT(*) FROM obs_runs").fetchone()[0]
    obs.generate_report(conn_with_metrics)
    after = conn_with_metrics.execute("SELECT COUNT(*) FROM obs_runs").fetchone()[0]
    assert after == before + 1


def test_generate_report_trends_contains_key_metrics(conn_with_metrics):
    """trends output contains entries for key metric names."""
    result = obs.generate_report(conn_with_metrics)
    trends = result["trends"]
    assert isinstance(trends, dict)
    # All key metrics have trend entries (even if count=0)
    expected_metrics = ["agent_duration_s", "test_result", "guard_denial"]
    for m in expected_metrics:
        assert m in trends, f"expected trend for {m}, got keys: {list(trends.keys())}"


# ---------------------------------------------------------------------------
# EC-7: summary delegates to generate_report and records obs_run
# ---------------------------------------------------------------------------


def test_summary_delegates_to_generate_report(conn_with_metrics):
    """EC-7: summary() calls generate_report() — result has all generate_report keys."""
    result = obs.summary(conn_with_metrics)
    # generate_report keys must be present
    assert "metrics_summary" in result
    assert "trends" in result
    assert "patterns" in result
    assert "suggestions" in result
    assert "convergence" in result
    assert "review_gate_health" in result


def test_summary_records_obs_run(conn_with_metrics):
    """EC-7: summary records an obs_run entry (delegation must not drop this)."""
    before = conn_with_metrics.execute("SELECT COUNT(*) FROM obs_runs").fetchone()[0]
    obs.summary(conn_with_metrics)
    after = conn_with_metrics.execute("SELECT COUNT(*) FROM obs_runs").fetchone()[0]
    assert after == before + 1


def test_summary_empty_db_does_not_crash(conn):
    """summary on empty DB returns valid structure."""
    result = obs.summary(conn)
    assert isinstance(result, dict)
    assert "metrics_summary" in result


# ---------------------------------------------------------------------------
# Compound interaction: full production sequence for W-OBS-3
# ---------------------------------------------------------------------------


def test_full_production_sequence_obs3(conn):
    """Compound-interaction test: exercises W-OBS-3 analysis across all
    component boundaries in the real production sequence.

    Sequence:
      1. Hooks emit obs_metrics (batch-style, as real hooks do)
      2. cross_analysis produces the operational picture
      3. pattern_detection surfaces actionable patterns
      4. generate_report assembles everything and records obs_run
      5. Patterns trigger suggestions via obs.suggest
      6. summary() delegates to generate_report (verifies delegation)
      7. check_convergence runs (no suggestions ready yet)
      8. Final state verified: obs_runs incremented, suggestions exist

    This crosses: emit_metric → query layer → cross_analysis → pattern_detection →
    generate_report → suggest lifecycle → summary delegation → check_convergence.
    """
    # Step 1: emit a realistic session's metrics
    # Agent durations (implementer trending up — slow_agent pattern)
    for v in [20.0, 25.0, 30.0, 35.0, 40.0, 45.0, 50.0, 55.0, 60.0, 65.0]:
        obs.emit_metric(conn, "agent_duration_s", v, role="implementer", session_id="sess-e2e")

    # Repeated denials (branch-guard 4x triggers repeated_denial)
    for _ in range(4):
        obs.emit_metric(conn, "guard_denial", 1.0, labels={"policy": "branch-guard"})

    # High infra failure rate (5 failures / 6 reviews = 83% — triggers review_quality)
    for _ in range(5):
        obs.emit_metric(conn, "review_infra_failure", 1.0, labels={"provider": "codex"})
    for _ in range(6):
        obs.emit_metric(
            conn, "review_verdict", 1.0, labels={"verdict": "approved", "provider": "codex"}
        )

    # Test results: 8 pass, 2 fail
    for _ in range(8):
        obs.emit_metric(conn, "test_result", 1.0)
    for _ in range(2):
        obs.emit_metric(conn, "test_result", 0.0)

    # Eval verdicts
    obs.emit_metric(conn, "eval_verdict", 1.0, labels={"verdict": "pass"})
    obs.emit_metric(conn, "eval_verdict", 1.0, labels={"verdict": "pass"})
    obs.emit_metric(conn, "eval_verdict", 0.0, labels={"verdict": "needs_changes"})

    # Step 2: cross_analysis
    analysis = obs.cross_analysis(conn)
    assert len(analysis["agent_stats"]) >= 1
    assert analysis["test_health"]["total"] == 10
    assert analysis["test_health"]["pass_rate"] == pytest.approx(0.8)
    assert len(analysis["denial_patterns"]) >= 1
    assert analysis["review_gate_health"]["infra_failures"] == 5

    # Step 3: pattern_detection surfaces all three patterns
    patterns = obs.pattern_detection(conn)
    pattern_types = {p["pattern_type"] for p in patterns}
    assert "repeated_denial" in pattern_types, f"patterns found: {pattern_types}"
    assert "slow_agent" in pattern_types, f"patterns found: {pattern_types}"
    assert "review_quality" in pattern_types, f"patterns found: {pattern_types}"

    # Step 4: generate_report assembles everything
    runs_before = conn.execute("SELECT COUNT(*) FROM obs_runs").fetchone()[0]
    report = obs.generate_report(conn)
    runs_after = conn.execute("SELECT COUNT(*) FROM obs_runs").fetchone()[0]
    assert runs_after == runs_before + 1
    assert report["metrics_summary"]["total"] > 0

    # Step 5: propose suggestions based on detected patterns
    for p in patterns:
        obs.suggest(
            conn,
            category=p["pattern_type"],
            title=p["description"],
            body=str(p.get("suggested_action", "")),
        )
    sugg_count = conn.execute(
        "SELECT COUNT(*) FROM obs_suggestions WHERE status='proposed'"
    ).fetchone()[0]
    assert sugg_count == len(patterns)

    # Step 6: summary delegates to generate_report
    runs_before2 = conn.execute("SELECT COUNT(*) FROM obs_runs").fetchone()[0]
    summary_result = obs.summary(conn)
    runs_after2 = conn.execute("SELECT COUNT(*) FROM obs_runs").fetchone()[0]
    assert runs_after2 == runs_before2 + 1
    # summary must expose generate_report keys
    assert "metrics_summary" in summary_result
    assert "patterns" in summary_result

    # Step 7: convergence — none ready (all future measure_after)
    convergence = obs.check_convergence(conn)
    assert convergence == []

    # Step 8: final state
    total_runs = conn.execute("SELECT COUNT(*) FROM obs_runs").fetchone()[0]
    assert total_runs >= 2  # generate_report + summary each added one
    total_suggestions = conn.execute("SELECT COUNT(*) FROM obs_suggestions").fetchone()[0]
    assert total_suggestions == len(patterns)
