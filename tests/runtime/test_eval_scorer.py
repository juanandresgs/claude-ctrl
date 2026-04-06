"""Tests for runtime.core.eval_scorer — parse, score, and aggregate functions.

These tests exercise the real production sequence: raw evaluator output text
goes in, structured score dicts come out, and aggregation functions run over
in-memory SQLite populated by eval_metrics.

No mocks of internal modules. External boundary: SQLite connection comes from
connect_memory() + ensure_eval_schema(), matching the pattern in
test_eval_metrics.py.

@decision DEC-EVAL-SCORER-001
Title: test_eval_scorer uses in-memory SQLite with real schema
Status: accepted
Rationale: The scorer reads eval_results.db via eval_metrics — tests must
  bootstrap the same schema. connect_memory() + ensure_eval_schema() is the
  established pattern in this codebase; using it keeps tests hermetic and
  avoids any disk I/O side-effects.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

import runtime.core.eval_scorer as scorer

import runtime.core.eval_metrics as eval_metrics
from runtime.core.db import connect_memory
from runtime.eval_schemas import ensure_eval_schema

# ---------------------------------------------------------------------------
# Shared fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    c = connect_memory()
    ensure_eval_schema(c)
    yield c
    c.close()


# Realistic evaluator output that follows agents/tester.md format exactly.
SAMPLE_EVALUATOR_OUTPUT = """\
## What Was Built

The implementer added write_who policy enforcement to the pre-tool hook.

## What I Observed

The write_who policy denied the source file write as expected.
The tester agent received a denial response containing "write_who" and "deny".
All 12 tests passed. No warnings detected.

## Try It Yourself

  python3 -m pytest tests/runtime/test_policy_engine.py -x -q

## Assessment

**Methodology:** Ran test suite, inspected hook output, verified policy state.

**Contract Evaluation:**
- write_who policy denies source write for tester role: met

**Coverage:**
| Area | Tier | Status | Evidence |
|------|------|--------|----------|
| Test suite substance | T1 | Fully verified | 12 tests covering write_who paths |
| Test suite results | T1 | Fully verified | 12 passed, 0 failed |
| Live feature | T2 | Fully verified | Hook denied write as expected |
| Integration wiring | -- | Fully verified | Reachable from pre-tool hook |
| Dual-Authority Audit | T3 | Fully verified | Single authority confirmed |

**What Could Not Be Tested:** None.
**Confidence Level:** **High** — all contract items met, live feature verified.
**Recommended Follow-Up:** None.

EVAL_VERDICT: ready_for_guardian
EVAL_TESTS_PASS: true
EVAL_NEXT_ROLE: guardian
EVAL_HEAD_SHA: abc1234def567890
"""

SAMPLE_EVALUATOR_NEEDS_CHANGES = """\
## What I Observed

Tests failed. The write_who policy did not deny the write.
Missing keyword in evidence output. Error encountered during run.

## Coverage

| Area | Tier | Status | Evidence |
|------|------|--------|----------|
| Test suite substance | T1 | Not verified | Tests rely on mocks |
| Test suite results | T1 | Failed | 3 passed, 2 failed |
| Live feature | T2 | Not verified | Feature not reachable |
| Integration wiring | -- | Not verified | No entry point found |
| Dual-Authority Audit | T3 | Fully verified | Single authority |

**Confidence Level:** **Low** — multiple contract items not met.

EVAL_VERDICT: needs_changes
EVAL_TESTS_PASS: false
EVAL_NEXT_ROLE: implementer
EVAL_HEAD_SHA: deadbeef00001111
"""

SAMPLE_GARBAGE = "This is not evaluator output at all. Random text. 42 foo bar."


# ---------------------------------------------------------------------------
# parse_trailer() tests
# ---------------------------------------------------------------------------


def test_parse_trailer_valid():
    """All 4 fields extracted from real evaluator output format."""
    result = scorer.parse_trailer(SAMPLE_EVALUATOR_OUTPUT)
    assert result["EVAL_VERDICT"] == "ready_for_guardian"
    assert result["EVAL_TESTS_PASS"] == "true"
    assert result["EVAL_NEXT_ROLE"] == "guardian"
    assert result["EVAL_HEAD_SHA"] == "abc1234def567890"


def test_parse_trailer_missing_fields():
    """Returns None for fields absent from the output."""
    # Only EVAL_VERDICT present
    partial = "Some output text.\nEVAL_VERDICT: needs_changes\n"
    result = scorer.parse_trailer(partial)
    assert result["EVAL_VERDICT"] == "needs_changes"
    assert result["EVAL_TESTS_PASS"] is None
    assert result["EVAL_NEXT_ROLE"] is None
    assert result["EVAL_HEAD_SHA"] is None


def test_parse_trailer_malformed():
    """Handles garbage input gracefully — all None."""
    result = scorer.parse_trailer(SAMPLE_GARBAGE)
    assert result["EVAL_VERDICT"] is None
    assert result["EVAL_TESTS_PASS"] is None
    assert result["EVAL_NEXT_ROLE"] is None
    assert result["EVAL_HEAD_SHA"] is None


def test_parse_trailer_partial():
    """Returns None for missing fields when only EVAL_VERDICT is present."""
    partial = "Preamble text.\nEVAL_VERDICT: blocked_by_plan\n"
    result = scorer.parse_trailer(partial)
    assert result["EVAL_VERDICT"] == "blocked_by_plan"
    assert result["EVAL_TESTS_PASS"] is None
    assert result["EVAL_NEXT_ROLE"] is None
    assert result["EVAL_HEAD_SHA"] is None


def test_parse_trailer_needs_changes():
    """Parse trailer from needs_changes output."""
    result = scorer.parse_trailer(SAMPLE_EVALUATOR_NEEDS_CHANGES)
    assert result["EVAL_VERDICT"] == "needs_changes"
    assert result["EVAL_TESTS_PASS"] == "false"
    assert result["EVAL_NEXT_ROLE"] == "implementer"
    assert result["EVAL_HEAD_SHA"] == "deadbeef00001111"


def test_parse_trailer_returns_dict_with_all_keys():
    """Always returns dict with all 4 expected keys, even for garbage."""
    result = scorer.parse_trailer(SAMPLE_GARBAGE)
    assert set(result.keys()) == {
        "EVAL_VERDICT",
        "EVAL_TESTS_PASS",
        "EVAL_NEXT_ROLE",
        "EVAL_HEAD_SHA",
    }


# ---------------------------------------------------------------------------
# extract_evidence() tests
# ---------------------------------------------------------------------------


def test_extract_evidence_with_section():
    """Finds the 'What I Observed' section."""
    result = scorer.extract_evidence(SAMPLE_EVALUATOR_OUTPUT)
    assert "write_who" in result
    assert "denied" in result


def test_extract_evidence_missing():
    """Returns empty string when section not found."""
    result = scorer.extract_evidence(SAMPLE_GARBAGE)
    assert result == ""


def test_extract_evidence_returns_string():
    """Return type is always str."""
    assert isinstance(scorer.extract_evidence(SAMPLE_EVALUATOR_OUTPUT), str)
    assert isinstance(scorer.extract_evidence(""), str)


def test_extract_evidence_contains_relevant_text():
    """The extracted section contains the observed content, not the header."""
    result = scorer.extract_evidence(SAMPLE_EVALUATOR_OUTPUT)
    # Should contain actual evidence, not just the section title
    assert len(result) > 10


# ---------------------------------------------------------------------------
# extract_coverage() tests
# ---------------------------------------------------------------------------


def test_extract_coverage_valid_table():
    """Parses the markdown Coverage table into list of dicts."""
    result = scorer.extract_coverage(SAMPLE_EVALUATOR_OUTPUT)
    assert isinstance(result, list)
    assert len(result) == 5
    # Check field names
    row = result[0]
    assert "area" in row
    assert "tier" in row
    assert "status" in row
    assert "evidence" in row


def test_extract_coverage_area_values():
    """Area values match the table content."""
    result = scorer.extract_coverage(SAMPLE_EVALUATOR_OUTPUT)
    areas = [r["area"] for r in result]
    assert "Test suite substance" in areas
    assert "Test suite results" in areas
    assert "Live feature" in areas


def test_extract_coverage_status_values():
    """Status values are extracted correctly."""
    result = scorer.extract_coverage(SAMPLE_EVALUATOR_OUTPUT)
    statuses = {r["status"] for r in result}
    assert "Fully verified" in statuses


def test_extract_coverage_empty():
    """Returns empty list when no table found."""
    result = scorer.extract_coverage(SAMPLE_GARBAGE)
    assert result == []


def test_extract_coverage_malformed():
    """Handles malformed tables gracefully — returns empty or partial list."""
    malformed = "| Area | Tier |\n|---|\n| broken row |"
    result = scorer.extract_coverage(malformed)
    # Must not raise; may return empty list or skip malformed rows
    assert isinstance(result, list)


def test_extract_coverage_failed_statuses():
    """Status 'Failed' and 'Not verified' are extracted in needs_changes output."""
    result = scorer.extract_coverage(SAMPLE_EVALUATOR_NEEDS_CHANGES)
    assert isinstance(result, list)
    statuses = {r["status"] for r in result}
    assert "Failed" in statuses or "Not verified" in statuses


# ---------------------------------------------------------------------------
# score_verdict() tests
# ---------------------------------------------------------------------------


def test_score_verdict_match():
    """Exact match returns 1.0."""
    assert scorer.score_verdict("ready_for_guardian", "ready_for_guardian") == 1.0


def test_score_verdict_mismatch():
    """Mismatch returns 0.0."""
    assert scorer.score_verdict("needs_changes", "ready_for_guardian") == 0.0


def test_score_verdict_none_actual():
    """None actual returns 0.0."""
    assert scorer.score_verdict(None, "ready_for_guardian") == 0.0


def test_score_verdict_none_expected():
    """None expected returns 0.0."""
    assert scorer.score_verdict("ready_for_guardian", None) == 0.0


def test_score_verdict_both_none():
    """Both None returns 0.0 (not a match — missing is not correct)."""
    assert scorer.score_verdict(None, None) == 0.0


def test_score_verdict_case_sensitive():
    """Verdict comparison is case-sensitive (canonical values are lowercase)."""
    assert scorer.score_verdict("Ready_For_Guardian", "ready_for_guardian") == 0.0


# ---------------------------------------------------------------------------
# score_defect_recall() tests
# ---------------------------------------------------------------------------


DEFECT_LIST = [
    {"keyword": "write_who"},
    {"keyword": "deny"},
    {"keyword": "tester"},
]


def test_score_defect_recall_full():
    """All keywords found returns 1.0."""
    evidence = "The write_who policy will deny the tester agent."
    assert scorer.score_defect_recall(evidence, DEFECT_LIST) == 1.0


def test_score_defect_recall_partial():
    """Some keywords found returns correct ratio."""
    evidence = "The write_who check failed."
    # Only 1 of 3 found
    result = scorer.score_defect_recall(evidence, DEFECT_LIST)
    assert abs(result - 1 / 3) < 1e-9


def test_score_defect_recall_zero():
    """No keywords found returns 0.0."""
    evidence = "Everything looks fine."
    assert scorer.score_defect_recall(evidence, DEFECT_LIST) == 0.0


def test_score_defect_recall_empty_expected():
    """Empty expected defects list returns 1.0."""
    assert scorer.score_defect_recall("any text", []) == 1.0


def test_score_defect_recall_case_insensitive():
    """Keyword matching is case-insensitive."""
    defects = [{"keyword": "WRITE_WHO"}, {"keyword": "DENY"}]
    evidence = "write_who will deny the request."
    assert scorer.score_defect_recall(evidence, defects) == 1.0


def test_score_defect_recall_two_of_three():
    """Two of three keywords found returns 2/3."""
    evidence = "The write_who and deny checks ran."
    result = scorer.score_defect_recall(evidence, DEFECT_LIST)
    assert abs(result - 2 / 3) < 1e-9


# ---------------------------------------------------------------------------
# score_evidence_quality() tests
# ---------------------------------------------------------------------------


def test_score_evidence_quality_full():
    """All expected phrases found returns 1.0."""
    evidence = "write_who policy applied, deny response returned."
    expected = ["write_who", "deny"]
    assert scorer.score_evidence_quality(evidence, expected) == 1.0


def test_score_evidence_quality_partial():
    """Some phrases found returns correct ratio."""
    evidence = "write_who check ran."
    expected = ["write_who", "deny", "tester"]
    result = scorer.score_evidence_quality(evidence, expected)
    assert abs(result - 1 / 3) < 1e-9


def test_score_evidence_quality_empty_expected():
    """Empty expected list returns 1.0."""
    assert scorer.score_evidence_quality("any text", []) == 1.0


def test_score_evidence_quality_case_insensitive():
    """Phrase matching is case-insensitive."""
    evidence = "WRITE_WHO denied the WRITE."
    expected = ["write_who", "denied"]
    assert scorer.score_evidence_quality(evidence, expected) == 1.0


def test_score_evidence_quality_none_found():
    """No phrases found returns 0.0."""
    evidence = "Nothing relevant here."
    expected = ["write_who", "deny"]
    assert scorer.score_evidence_quality(evidence, expected) == 0.0


# ---------------------------------------------------------------------------
# score_false_positives() tests
# ---------------------------------------------------------------------------


def test_score_false_positives_clean():
    """No false positives when all expected-clean areas pass."""
    coverage = [
        {"area": "Test suite substance", "status": "Fully verified"},
        {"area": "Live feature", "status": "Fully verified"},
    ]
    clean_areas = ["Test suite substance", "Live feature"]
    assert scorer.score_false_positives(coverage, clean_areas) == 0


def test_score_false_positives_with_failures():
    """Counts areas marked failed/not-verified that should be clean."""
    coverage = [
        {"area": "Test suite substance", "status": "Not verified"},
        {"area": "Live feature", "status": "Fully verified"},
        {"area": "Integration wiring", "status": "Failed"},
    ]
    clean_areas = ["Test suite substance", "Live feature", "Integration wiring"]
    # "Test suite substance" and "Integration wiring" are failures
    count = scorer.score_false_positives(coverage, clean_areas)
    assert count == 2


def test_score_false_positives_empty_clean_areas():
    """Empty expected_clean_areas returns 0."""
    coverage = [{"area": "Something", "status": "Failed"}]
    assert scorer.score_false_positives(coverage, []) == 0


def test_score_false_positives_mixed_status_words():
    """Detects 'failed' (case-insensitive) and 'not verified' as non-passing."""
    coverage = [
        {"area": "Area A", "status": "FAILED"},
        {"area": "Area B", "status": "NOT VERIFIED"},
        {"area": "Area C", "status": "Fully verified"},
    ]
    clean_areas = ["Area A", "Area B", "Area C"]
    assert scorer.score_false_positives(coverage, clean_areas) == 2


# ---------------------------------------------------------------------------
# score_confidence() tests
# ---------------------------------------------------------------------------


def test_score_confidence_match():
    """Exact confidence match returns 1.0."""
    assert scorer.score_confidence("High", "High") == 1.0
    assert scorer.score_confidence("Medium", "Medium") == 1.0
    assert scorer.score_confidence("Low", "Low") == 1.0


def test_score_confidence_adjacent_high_medium():
    """High/Medium adjacency returns 0.5."""
    assert scorer.score_confidence("High", "Medium") == 0.5
    assert scorer.score_confidence("Medium", "High") == 0.5


def test_score_confidence_adjacent_medium_low():
    """Medium/Low adjacency returns 0.5."""
    assert scorer.score_confidence("Medium", "Low") == 0.5
    assert scorer.score_confidence("Low", "Medium") == 0.5


def test_score_confidence_distant():
    """High/Low distance returns 0.0."""
    assert scorer.score_confidence("High", "Low") == 0.0
    assert scorer.score_confidence("Low", "High") == 0.0


def test_score_confidence_none_actual():
    """None actual returns 0.0."""
    assert scorer.score_confidence(None, "High") == 0.0


def test_score_confidence_none_expected():
    """None expected returns 0.0."""
    assert scorer.score_confidence("High", None) == 0.0


def test_score_confidence_both_none():
    """Both None returns 0.0."""
    assert scorer.score_confidence(None, None) == 0.0


# ---------------------------------------------------------------------------
# score_scenario() end-to-end tests
# ---------------------------------------------------------------------------


GROUND_TRUTH_FULL = {
    "expected_verdict": "ready_for_guardian",
    "expected_defects": [{"keyword": "write_who"}, {"keyword": "deny"}],
    "expected_evidence": ["write_who", "denied"],
    "expected_confidence": "High",
    "expected_clean_areas": [],
}

SCORING_WEIGHTS_FULL = {
    "verdict_weight": 0.5,
    "defect_recall_weight": 0.2,
    "evidence_weight": 0.2,
    "false_positive_weight": 0.1,
}


def test_score_scenario_end_to_end():
    """Full scoring with realistic evaluator output — exercises all sub-scorers."""
    result = scorer.score_scenario(SAMPLE_EVALUATOR_OUTPUT, GROUND_TRUTH_FULL, SCORING_WEIGHTS_FULL)

    assert isinstance(result, dict)
    # Verdict matched
    assert result["verdict_actual"] == "ready_for_guardian"
    assert result["verdict_correct"] == 1
    # Defect recall: both keywords present in evidence
    assert result["defect_recall"] > 0.0
    # Evidence quality: both phrases in evidence
    assert result["evidence_score"] > 0.0
    # False positives: 0 since no clean areas specified
    assert result["false_positive_count"] == 0
    # Total score: weighted, >0 since verdict is correct
    assert result["total_score"] > 0.0
    assert result["error_message"] is None


def test_score_scenario_applies_weights():
    """Weights affect total score correctly."""
    # Scenario where verdict matches but nothing else does
    ground_truth_verdict_only = {
        "expected_verdict": "ready_for_guardian",
        "expected_defects": [{"keyword": "NOT_IN_OUTPUT_AT_ALL_XYZ123"}],
        "expected_evidence": ["NOT_IN_OUTPUT_AT_ALL_ABC456"],
        "expected_confidence": "High",
        "expected_clean_areas": [],
    }
    weights_verdict_only = {
        "verdict_weight": 1.0,
        "defect_recall_weight": 0.0,
        "evidence_weight": 0.0,
        "false_positive_weight": 0.0,
    }
    result = scorer.score_scenario(
        SAMPLE_EVALUATOR_OUTPUT, ground_truth_verdict_only, weights_verdict_only
    )
    # Only verdict weight matters; verdict matched = 1.0
    assert abs(result["total_score"] - 1.0) < 1e-9
    assert result["verdict_correct"] == 1


def test_score_scenario_mismatch_verdict():
    """Wrong verdict leads to lower total score."""
    ground_truth_wrong = {
        "expected_verdict": "needs_changes",  # output says ready_for_guardian
        "expected_defects": [],
        "expected_evidence": [],
        "expected_confidence": "High",
        "expected_clean_areas": [],
    }
    weights = {
        "verdict_weight": 1.0,
        "defect_recall_weight": 0.0,
        "evidence_weight": 0.0,
        "false_positive_weight": 0.0,
    }
    result = scorer.score_scenario(SAMPLE_EVALUATOR_OUTPUT, ground_truth_wrong, weights)
    assert result["verdict_correct"] == 0
    assert result["total_score"] == 0.0


def test_score_scenario_returns_required_keys():
    """score_scenario returns all keys required by record_score()."""
    result = scorer.score_scenario(SAMPLE_EVALUATOR_OUTPUT, GROUND_TRUTH_FULL, SCORING_WEIGHTS_FULL)
    required_keys = {
        "verdict_actual",
        "verdict_correct",
        "defect_recall",
        "evidence_score",
        "false_positive_count",
        "confidence_actual",
        "duration_ms",
        "error_message",
        "total_score",
    }
    assert required_keys.issubset(set(result.keys()))


def test_score_scenario_empty_output():
    """Empty evaluator output produces graceful zero scores."""
    result = scorer.score_scenario("", GROUND_TRUTH_FULL, SCORING_WEIGHTS_FULL)
    assert result["verdict_actual"] is None
    assert result["verdict_correct"] == 0
    assert result["total_score"] == 0.0


# ---------------------------------------------------------------------------
# get_category_breakdown() tests
# ---------------------------------------------------------------------------


@pytest.fixture
def run_with_categories(conn):
    """Create a run with scores across multiple categories."""
    run_id = eval_metrics.create_run(conn, mode="deterministic")
    # gate: 3 pass, 1 fail, 0 error
    for i in range(3):
        eval_metrics.record_score(
            conn,
            run_id,
            f"gate-s{i}",
            "gate",
            "deny",
            verdict_actual="deny",
            verdict_correct=1,
            defect_recall=0.9,
        )
    eval_metrics.record_score(
        conn,
        run_id,
        "gate-fail",
        "gate",
        "deny",
        verdict_actual="pending",
        verdict_correct=0,
        defect_recall=0.5,
    )
    # judgment: 1 pass, 1 fail, 1 error
    eval_metrics.record_score(
        conn,
        run_id,
        "j-pass",
        "judgment",
        "needs_changes",
        verdict_actual="needs_changes",
        verdict_correct=1,
        defect_recall=0.8,
    )
    eval_metrics.record_score(
        conn,
        run_id,
        "j-fail",
        "judgment",
        "needs_changes",
        verdict_actual="idle",
        verdict_correct=0,
        defect_recall=0.3,
    )
    eval_metrics.record_score(
        conn,
        run_id,
        "j-err",
        "judgment",
        "needs_changes",
        verdict_actual=None,
        verdict_correct=0,
        error_message="timeout",
    )
    # adversarial: 2 pass, 0 fail, 0 error
    for i in range(2):
        eval_metrics.record_score(
            conn,
            run_id,
            f"adv-s{i}",
            "adversarial",
            "pending",
            verdict_actual="pending",
            verdict_correct=1,
            defect_recall=1.0,
        )
    eval_metrics.finalize_run(conn, run_id)
    return run_id


def test_get_category_breakdown_keys(conn, run_with_categories):
    """Returns a dict with expected category keys."""
    result = eval_metrics.get_category_breakdown(conn, run_with_categories)
    assert isinstance(result, dict)
    assert "gate" in result
    assert "judgment" in result
    assert "adversarial" in result


def test_get_category_breakdown_gate_counts(conn, run_with_categories):
    """Gate category has correct pass/fail/error counts."""
    result = eval_metrics.get_category_breakdown(conn, run_with_categories)
    gate = result["gate"]
    assert gate["pass"] == 3
    assert gate["fail"] == 1
    assert gate["error"] == 0


def test_get_category_breakdown_judgment_counts(conn, run_with_categories):
    """Judgment category has correct pass/fail/error counts."""
    result = eval_metrics.get_category_breakdown(conn, run_with_categories)
    j = result["judgment"]
    assert j["pass"] == 1
    assert j["fail"] == 1
    assert j["error"] == 1


def test_get_category_breakdown_avg_score(conn, run_with_categories):
    """avg_score is computed (non-negative float)."""
    result = eval_metrics.get_category_breakdown(conn, run_with_categories)
    for cat in ("gate", "judgment", "adversarial"):
        assert isinstance(result[cat]["avg_score"], float)
        assert result[cat]["avg_score"] >= 0.0


def test_get_category_breakdown_empty_run(conn):
    """Empty run returns empty dict or all-zero categories."""
    run_id = eval_metrics.create_run(conn, mode="deterministic")
    result = eval_metrics.get_category_breakdown(conn, run_id)
    assert isinstance(result, dict)
    # No scores means no categories
    assert len(result) == 0


# ---------------------------------------------------------------------------
# get_regression_check() tests
# ---------------------------------------------------------------------------


def _insert_scores_for_scenario(conn, scenario_id: str, scores: list[float]) -> None:
    """Helper: create runs and insert defect_recall scores for regression tests."""
    for score_val in scores:
        run_id = eval_metrics.create_run(conn, mode="deterministic")
        eval_metrics.record_score(
            conn,
            run_id,
            scenario_id,
            "gate",
            "deny",
            verdict_actual="deny",
            verdict_correct=1 if score_val >= 0.5 else 0,
            defect_recall=score_val,
        )


def test_get_regression_check_no_regression(conn):
    """Stable scores do not trigger regression flag."""
    _insert_scores_for_scenario(conn, "stable-scenario", [0.9, 0.88, 0.92, 0.87, 0.91])
    result = eval_metrics.get_regression_check(conn, "stable-scenario", window=5)
    assert result["scenario_id"] == "stable-scenario"
    assert result["regression"] is False
    assert isinstance(result["latest_score"], float)
    assert isinstance(result["window_avg"], float)
    assert isinstance(result["delta"], float)


def test_get_regression_check_with_regression(conn):
    """A >20% drop from window average triggers regression=True."""
    # Window of 4 stable scores at 0.9, then one at 0.5 (drop of ~44%)
    _insert_scores_for_scenario(conn, "regressed-scenario", [0.9, 0.9, 0.9, 0.9, 0.5])
    result = eval_metrics.get_regression_check(conn, "regressed-scenario", window=5)
    assert result["regression"] is True
    assert result["latest_score"] == pytest.approx(0.5, abs=1e-9)


def test_get_regression_check_returns_all_keys(conn):
    """Returns dict with all expected keys."""
    _insert_scores_for_scenario(conn, "check-keys", [0.8, 0.75, 0.85])
    result = eval_metrics.get_regression_check(conn, "check-keys", window=3)
    assert set(result.keys()) == {
        "scenario_id",
        "latest_score",
        "window_avg",
        "regression",
        "delta",
    }


def test_get_regression_check_no_data(conn):
    """Scenario with no data returns safe defaults."""
    result = eval_metrics.get_regression_check(conn, "nonexistent-scenario", window=5)
    assert result["scenario_id"] == "nonexistent-scenario"
    assert result["regression"] is False


def test_get_regression_check_boundary_20_percent(conn):
    """Exactly 20% drop should NOT trigger regression (strictly >20%)."""
    # window_avg = 1.0, latest = 0.8 → delta = 0.2 = 20% (not >20%)
    _insert_scores_for_scenario(conn, "boundary-scenario", [1.0, 1.0, 1.0, 1.0, 0.8])
    result = eval_metrics.get_regression_check(conn, "boundary-scenario", window=5)
    assert result["regression"] is False


# ---------------------------------------------------------------------------
# get_variance() tests
# ---------------------------------------------------------------------------


def test_get_variance_correct_computation(conn):
    """Variance and std_dev are computed correctly."""
    scores = [0.6, 0.7, 0.8, 0.9, 1.0]
    _insert_scores_for_scenario(conn, "var-scenario", scores)
    result = eval_metrics.get_variance(conn, "var-scenario", window=5)

    assert result["scenario_id"] == "var-scenario"
    assert result["run_count"] == 5
    assert result["window"] == 5

    # Manual: mean = 0.8, var = ((0.04+0.01+0+0.01+0.04)/5) = 0.02
    import statistics

    expected_mean = statistics.mean(scores)
    expected_var = statistics.pvariance(scores)
    expected_std = expected_var**0.5

    assert abs(result["mean"] - expected_mean) < 1e-9
    assert abs(result["variance"] - expected_var) < 1e-9
    assert abs(result["std_dev"] - expected_std) < 1e-9


def test_get_variance_returns_all_keys(conn):
    """Returns dict with all expected keys."""
    _insert_scores_for_scenario(conn, "var-keys", [0.8, 0.9, 0.7])
    result = eval_metrics.get_variance(conn, "var-keys", window=3)
    assert set(result.keys()) == {
        "scenario_id",
        "window",
        "mean",
        "variance",
        "std_dev",
        "run_count",
    }


def test_get_variance_no_data(conn):
    """No data returns safe zeros."""
    result = eval_metrics.get_variance(conn, "empty-var", window=5)
    assert result["scenario_id"] == "empty-var"
    assert result["run_count"] == 0
    assert result["mean"] == 0.0
    assert result["variance"] == 0.0
    assert result["std_dev"] == 0.0


def test_get_variance_single_run(conn):
    """Single run returns variance of 0.0."""
    _insert_scores_for_scenario(conn, "single-run", [0.75])
    result = eval_metrics.get_variance(conn, "single-run", window=5)
    assert result["run_count"] == 1
    assert result["variance"] == 0.0


# ---------------------------------------------------------------------------
# Compound interaction: full production sequence end-to-end
# ---------------------------------------------------------------------------


def test_full_scorer_production_sequence(conn):
    """Exercise the real production sequence end-to-end.

    Production sequence:
      1. eval_runner produces raw evaluator output
      2. eval_scorer.parse_trailer() extracts structured trailer
      3. eval_scorer.score_scenario() computes scored dict
      4. eval_metrics.record_score() persists the score
      5. eval_metrics.get_category_breakdown() aggregates
      6. eval_metrics.get_regression_check() checks regression

    This test crosses parse_trailer, extract_evidence, extract_coverage,
    score_scenario, record_score, get_category_breakdown, get_regression_check.
    """
    # Step 1+2: parse raw evaluator output
    trailer = scorer.parse_trailer(SAMPLE_EVALUATOR_OUTPUT)
    assert trailer["EVAL_VERDICT"] == "ready_for_guardian"

    # Step 3: score the scenario
    ground_truth = {
        "expected_verdict": "ready_for_guardian",
        "expected_defects": [{"keyword": "write_who"}, {"keyword": "deny"}],
        "expected_evidence": ["write_who", "denied"],
        "expected_confidence": "High",
        "expected_clean_areas": [],
    }
    weights = {
        "verdict_weight": 0.5,
        "defect_recall_weight": 0.2,
        "evidence_weight": 0.2,
        "false_positive_weight": 0.1,
    }
    scored = scorer.score_scenario(SAMPLE_EVALUATOR_OUTPUT, ground_truth, weights)
    assert scored["verdict_correct"] == 1
    assert scored["total_score"] > 0.5

    # Step 4: persist
    run_id = eval_metrics.create_run(conn, mode="deterministic")
    eval_metrics.record_score(
        conn,
        run_id,
        "write-who-deny",
        "gate",
        verdict_expected="ready_for_guardian",
        verdict_actual=scored["verdict_actual"],
        verdict_correct=scored["verdict_correct"],
        defect_recall=scored["defect_recall"],
        evidence_score=scored["evidence_score"],
        false_positive_count=scored["false_positive_count"],
        confidence_actual=scored["confidence_actual"],
        duration_ms=scored["duration_ms"],
        error_message=scored["error_message"],
    )
    eval_metrics.finalize_run(conn, run_id)

    # Step 5: aggregate
    breakdown = eval_metrics.get_category_breakdown(conn, run_id)
    assert "gate" in breakdown
    assert breakdown["gate"]["pass"] == 1

    # Step 6: regression check (only 1 run, no regression possible)
    reg = eval_metrics.get_regression_check(conn, "write-who-deny", window=5)
    assert reg["scenario_id"] == "write-who-deny"
    assert reg["regression"] is False
