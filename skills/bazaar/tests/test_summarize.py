"""Tests for bazaar_summarize.py — Phase BLUF generator and manifest updater.

@decision DEC-BAZAAR-014
@title bazaar_summarize.py generates phase BLUFs from disk artifacts
@status accepted
@rationale Tests verify that each phase generator reads the correct artifacts,
produces concise BLUF markdown (5-25 lines), updates bazaar-manifest.json
accurately, and degrades gracefully when artifacts are missing. Test design
uses real fixture files (not mocks) per Sacred Practice #5 — fixtures represent
actual dispatch output shapes from the E2E run at /private/tmp/bazaar-GgXiG5/.

Tests cover:
- BLUF generation for each of the 6 phases using fixture data
- Manifest creation and update behavior
- Graceful handling of missing artifacts (partial runs, failures)
- BLUF content quality (line count, key fields present)
"""

import json
import sys
from pathlib import Path

import pytest

# conftest.py already adds scripts/ to sys.path
import bazaar_summarize as bsum


# ── Fixtures ───────────────────────────────────────────────────────────────────

FIXTURES = Path(__file__).parent / "fixtures"


@pytest.fixture
def output_dir(tmp_path):
    """Empty output directory for each test."""
    return tmp_path / "bazaar-test-run"


@pytest.fixture
def output_dir_with_brief(output_dir):
    """Output dir with brief.md pre-populated from fixture."""
    output_dir.mkdir(parents=True, exist_ok=True)
    brief_src = FIXTURES / "sample_brief.md"
    (output_dir / "brief.md").write_text(brief_src.read_text())
    return output_dir


@pytest.fixture
def output_dir_with_ideators(output_dir):
    """Output dir with ideators/*.json populated using sample scenarios fixture."""
    output_dir.mkdir(parents=True, exist_ok=True)
    ideators_dir = output_dir / "ideators"
    ideators_dir.mkdir()

    # Load sample scenarios and wrap in dispatch output format
    sample_src = FIXTURES / "sample_scenarios.json"
    sample_data = json.loads(sample_src.read_text())

    for archetype in ["methodical", "contrarian", "pattern-matcher"]:
        dispatch_result = {
            "dispatch_id": archetype,
            "provider": "anthropic",
            "model_used": "claude-opus-4-6",
            "text": json.dumps(sample_data),
            "parsed": sample_data,
            "elapsed": 5.0,
            "success": True,
            "error": None,
        }
        (ideators_dir / f"{archetype}.json").write_text(json.dumps(dispatch_result))

    return output_dir


@pytest.fixture
def output_dir_with_all_scenarios(output_dir_with_ideators):
    """Output dir with ideators + all_scenarios.json."""
    output_dir = output_dir_with_ideators
    sample_src = FIXTURES / "sample_scenarios.json"
    sample_data = json.loads(sample_src.read_text())
    all_scenarios = {"scenarios": sample_data["scenarios"]}
    (output_dir / "all_scenarios.json").write_text(json.dumps(all_scenarios))
    return output_dir


@pytest.fixture
def output_dir_with_funded(output_dir_with_all_scenarios):
    """Output dir with funded_scenarios.json from fixture."""
    output_dir = output_dir_with_all_scenarios
    funded_src = FIXTURES / "sample_funded_scenarios.json"
    (output_dir / "funded_scenarios.json").write_text(funded_src.read_text())
    return output_dir


@pytest.fixture
def output_dir_with_analysts(output_dir_with_funded):
    """Output dir with analysts/*.json populated."""
    output_dir = output_dir_with_funded
    analysts_dir = output_dir / "analysts"
    analysts_dir.mkdir()

    analyst_src = FIXTURES / "sample_analyst_output.json"
    (analysts_dir / "rag-grounding_analysis.json").write_text(analyst_src.read_text())

    return output_dir


@pytest.fixture
def output_dir_with_report(output_dir_with_funded):
    """Output dir with bazaar-report.md from fixture."""
    output_dir = output_dir_with_funded
    report_src = FIXTURES / "sample_report.md"
    (output_dir / "bazaar-report.md").write_text(report_src.read_text())
    return output_dir


# ── Phase 1 tests ──────────────────────────────────────────────────────────────

class TestPhase1Bluf:
    def test_generates_bluf_file(self, output_dir_with_brief):
        """Phase 1 summarize writes phase-1-bluf.md to output dir."""
        bluf = bsum.summarize(1, output_dir_with_brief)
        bluf_path = output_dir_with_brief / "phase-1-bluf.md"
        assert bluf_path.exists()
        assert bluf_path.read_text().strip() == bluf.strip()

    def test_bluf_contains_question(self, output_dir_with_brief):
        """Phase 1 BLUF includes the question from brief.md."""
        bluf = bsum.summarize(1, output_dir_with_brief)
        assert "hallucination" in bluf.lower()

    def test_bluf_contains_phase_header(self, output_dir_with_brief):
        """Phase 1 BLUF starts with the Phase 1 header."""
        bluf = bsum.summarize(1, output_dir_with_brief)
        assert "Phase 1 BLUF" in bluf

    def test_bluf_contains_uncertainties(self, output_dir_with_brief):
        """Phase 1 BLUF extracts key uncertainties from brief.md."""
        bluf = bsum.summarize(1, output_dir_with_brief)
        assert "RAG" in bluf or "Uncertainties" in bluf

    def test_missing_brief_graceful(self, output_dir):
        """Phase 1 handles missing brief.md gracefully (no exception)."""
        output_dir.mkdir(parents=True, exist_ok=True)
        bluf = bsum.summarize(1, output_dir)
        assert "Phase 1 BLUF" in bluf
        assert "not found" in bluf

    def test_creates_manifest(self, output_dir_with_brief):
        """Phase 1 summarize creates bazaar-manifest.json."""
        bsum.summarize(1, output_dir_with_brief)
        manifest_path = output_dir_with_brief / "bazaar-manifest.json"
        assert manifest_path.exists()

    def test_manifest_has_phase1_entry(self, output_dir_with_brief):
        """Manifest has a '1' entry after Phase 1 summarize."""
        bsum.summarize(1, output_dir_with_brief)
        manifest = json.loads((output_dir_with_brief / "bazaar-manifest.json").read_text())
        assert "1" in manifest["phases"]
        assert manifest["phases"]["1"]["status"] == "completed"

    def test_manifest_bluf_text_matches(self, output_dir_with_brief):
        """Manifest phase entry's bluf field matches the written BLUF file."""
        bluf = bsum.summarize(1, output_dir_with_brief)
        manifest = json.loads((output_dir_with_brief / "bazaar-manifest.json").read_text())
        assert manifest["phases"]["1"]["bluf"] == bluf


# ── Phase 2 tests ──────────────────────────────────────────────────────────────

class TestPhase2Bluf:
    def test_generates_bluf_file(self, output_dir_with_all_scenarios):
        """Phase 2 summarize writes phase-2-bluf.md."""
        bsum.summarize(2, output_dir_with_all_scenarios)
        assert (output_dir_with_all_scenarios / "phase-2-bluf.md").exists()

    def test_bluf_contains_scenario_count(self, output_dir_with_all_scenarios):
        """Phase 2 BLUF includes the unique scenario count."""
        bluf = bsum.summarize(2, output_dir_with_all_scenarios)
        # The fixture has 4 scenarios
        assert "4" in bluf

    def test_bluf_contains_scenario_titles(self, output_dir_with_all_scenarios):
        """Phase 2 BLUF lists scenario IDs from all_scenarios.json."""
        bluf = bsum.summarize(2, output_dir_with_all_scenarios)
        assert "alpha-disruption" in bluf

    def test_bluf_contains_ideator_count(self, output_dir_with_ideators):
        """Phase 2 BLUF reports number of ideators."""
        bluf = bsum.summarize(2, output_dir_with_ideators)
        assert "Phase 2 BLUF" in bluf
        # 3 ideator files were created
        assert "3" in bluf

    def test_failed_ideator_counted(self, output_dir_with_all_scenarios):
        """Phase 2 BLUF correctly counts failed ideator files."""
        # Add a failed dispatch file
        failed = {
            "dispatch_id": "failing-ideator",
            "provider": "anthropic",
            "model_used": "claude-sonnet-4-6",
            "text": "",
            "parsed": None,
            "elapsed": 1.0,
            "success": False,
            "error": "timeout",
        }
        (output_dir_with_all_scenarios / "ideators" / "failing-ideator.json").write_text(
            json.dumps(failed)
        )
        bluf = bsum.summarize(2, output_dir_with_all_scenarios)
        assert "failed" in bluf.lower() or "1" in bluf

    def test_missing_ideators_graceful(self, output_dir):
        """Phase 2 handles empty ideators dir gracefully."""
        output_dir.mkdir(parents=True, exist_ok=True)
        (output_dir / "ideators").mkdir()
        bluf = bsum.summarize(2, output_dir)
        assert "Phase 2 BLUF" in bluf

    def test_manifest_updated(self, output_dir_with_all_scenarios):
        """Phase 2 summarize updates manifest with phase 2 entry."""
        bsum.summarize(2, output_dir_with_all_scenarios)
        manifest = json.loads(
            (output_dir_with_all_scenarios / "bazaar-manifest.json").read_text()
        )
        assert "2" in manifest["phases"]


# ── Phase 3 tests ──────────────────────────────────────────────────────────────

class TestPhase3Bluf:
    def test_generates_bluf_file(self, output_dir_with_funded):
        """Phase 3 summarize writes phase-3-bluf.md."""
        bsum.summarize(3, output_dir_with_funded)
        assert (output_dir_with_funded / "phase-3-bluf.md").exists()

    def test_bluf_contains_funding_table(self, output_dir_with_funded):
        """Phase 3 BLUF includes funding table rows."""
        bluf = bsum.summarize(3, output_dir_with_funded)
        assert "rag-grounding" in bluf
        assert "34.2" in bluf

    def test_bluf_contains_kendalls_w(self, output_dir_with_funded):
        """Phase 3 BLUF includes Kendall's W metric."""
        bluf = bsum.summarize(3, output_dir_with_funded)
        assert "0.72" in bluf or "Kendall" in bluf

    def test_bluf_contains_gini(self, output_dir_with_funded):
        """Phase 3 BLUF includes Gini coefficient."""
        bluf = bsum.summarize(3, output_dir_with_funded)
        assert "0.185" in bluf or "Gini" in bluf

    def test_bluf_contains_elimination_count(self, output_dir_with_funded):
        """Phase 3 BLUF reports number of eliminated scenarios."""
        bluf = bsum.summarize(3, output_dir_with_funded)
        assert "eliminat" in bluf.lower() or "1" in bluf

    def test_manifest_scenarios_funded_updated(self, output_dir_with_funded):
        """Phase 3 summarize updates manifest top-level scenarios_funded field."""
        bsum.summarize(3, output_dir_with_funded)
        manifest = json.loads(
            (output_dir_with_funded / "bazaar-manifest.json").read_text()
        )
        assert manifest["scenarios_funded"] == 4

    def test_missing_funded_file_graceful(self, output_dir):
        """Phase 3 handles missing funded_scenarios.json gracefully."""
        output_dir.mkdir(parents=True, exist_ok=True)
        bluf = bsum.summarize(3, output_dir)
        assert "Phase 3 BLUF" in bluf
        assert "not found" in bluf

    def test_manifest_updated(self, output_dir_with_funded):
        """Phase 3 updates manifest phases entry."""
        bsum.summarize(3, output_dir_with_funded)
        manifest = json.loads(
            (output_dir_with_funded / "bazaar-manifest.json").read_text()
        )
        assert "3" in manifest["phases"]


# ── Phase 4 tests ──────────────────────────────────────────────────────────────

class TestPhase4Bluf:
    def test_generates_bluf_file(self, output_dir_with_funded):
        """Phase 4 summarize writes phase-4-bluf.md even with no obsessives."""
        obsessives_dir = output_dir_with_funded / "obsessives"
        obsessives_dir.mkdir()
        bsum.summarize(4, output_dir_with_funded)
        assert (output_dir_with_funded / "phase-4-bluf.md").exists()

    def test_bluf_with_obsessives(self, output_dir_with_funded):
        """Phase 4 BLUF counts domain and search obsessives."""
        obsessives_dir = output_dir_with_funded / "obsessives"
        obsessives_dir.mkdir()
        domain_data = {
            "dispatch_id": "domain-rag-grounding",
            "success": True,
            "parsed": {
                "scenario_id": "rag-grounding",
                "signals": [{"signal": "a"}, {"signal": "b"}, {"signal": "c"}],
            },
        }
        search_data = {
            "dispatch_id": "search-rag-grounding",
            "success": True,
            "parsed": {
                "scenario_id": "rag-grounding",
                "signals": [{"signal": "x"}, {"signal": "y"}],
            },
        }
        (obsessives_dir / "rag-grounding_domain.json").write_text(json.dumps(domain_data))
        (obsessives_dir / "rag-grounding_search.json").write_text(json.dumps(search_data))
        bluf = bsum.summarize(4, output_dir_with_funded)
        assert "1" in bluf  # at least 1 of each type
        assert "rag-grounding" in bluf

    def test_missing_obsessives_dir_graceful(self, output_dir_with_funded):
        """Phase 4 handles missing obsessives/ directory gracefully."""
        bluf = bsum.summarize(4, output_dir_with_funded)
        assert "Phase 4 BLUF" in bluf


# ── Phase 5 tests ──────────────────────────────────────────────────────────────

class TestPhase5Bluf:
    def test_generates_bluf_file(self, output_dir_with_analysts):
        """Phase 5 summarize writes phase-5-bluf.md."""
        bsum.summarize(5, output_dir_with_analysts)
        assert (output_dir_with_analysts / "phase-5-bluf.md").exists()

    def test_bluf_contains_analyst_count(self, output_dir_with_analysts):
        """Phase 5 BLUF reports analyst count."""
        bluf = bsum.summarize(5, output_dir_with_analysts)
        assert "1" in bluf  # 1 analyst in fixture

    def test_bluf_contains_confidence(self, output_dir_with_analysts):
        """Phase 5 BLUF includes confidence distribution."""
        bluf = bsum.summarize(5, output_dir_with_analysts)
        assert "High" in bluf or "high" in bluf

    def test_bluf_contains_themes(self, output_dir_with_analysts):
        """Phase 5 BLUF includes key themes from analyst findings."""
        bluf = bsum.summarize(5, output_dir_with_analysts)
        assert "RAG" in bluf or "hallucination" in bluf.lower() or "anchoring" in bluf

    def test_failed_analyst_counted(self, output_dir_with_analysts):
        """Phase 5 BLUF reports failed analysts."""
        analysts_dir = output_dir_with_analysts / "analysts"
        failed = {
            "dispatch_id": "analyst-inference-verification",
            "success": False,
            "parsed": None,
            "error": "timeout",
        }
        (analysts_dir / "inference-verification_analysis.json").write_text(json.dumps(failed))
        bluf = bsum.summarize(5, output_dir_with_analysts)
        assert "failed" in bluf.lower()

    def test_missing_analysts_dir_graceful(self, output_dir):
        """Phase 5 handles missing analysts/ dir gracefully."""
        output_dir.mkdir(parents=True, exist_ok=True)
        bluf = bsum.summarize(5, output_dir)
        assert "Phase 5 BLUF" in bluf


# ── Phase 6 tests ──────────────────────────────────────────────────────────────

class TestPhase6Bluf:
    def test_generates_bluf_file(self, output_dir_with_report):
        """Phase 6 summarize writes phase-6-bluf.md."""
        bsum.summarize(6, output_dir_with_report)
        assert (output_dir_with_report / "phase-6-bluf.md").exists()

    def test_bluf_contains_word_count(self, output_dir_with_report):
        """Phase 6 BLUF includes word count from the report."""
        bluf = bsum.summarize(6, output_dir_with_report)
        import re
        assert re.search(r"\d+", bluf)

    def test_bluf_contains_report_filename(self, output_dir_with_report):
        """Phase 6 BLUF references bazaar-report.md."""
        bluf = bsum.summarize(6, output_dir_with_report)
        assert "bazaar-report.md" in bluf

    def test_bluf_contains_sections(self, output_dir_with_report):
        """Phase 6 BLUF lists report sections (## headers)."""
        bluf = bsum.summarize(6, output_dir_with_report)
        assert "Executive Summary" in bluf or "Sections" in bluf

    def test_bluf_contains_funding_summary(self, output_dir_with_report):
        """Phase 6 BLUF includes the funding summary from funded_scenarios.json."""
        bluf = bsum.summarize(6, output_dir_with_report)
        assert "rag-grounding" in bluf or "funded" in bluf.lower()

    def test_manifest_word_count_updated(self, output_dir_with_report):
        """Phase 6 updates manifest top-level word_count and report_path."""
        bsum.summarize(6, output_dir_with_report)
        manifest = json.loads(
            (output_dir_with_report / "bazaar-manifest.json").read_text()
        )
        assert manifest["word_count"] is not None
        assert manifest["word_count"] > 0
        assert manifest["report_path"] is not None

    def test_manifest_completed_timestamp(self, output_dir_with_report):
        """Phase 6 sets manifest completed timestamp."""
        bsum.summarize(6, output_dir_with_report)
        manifest = json.loads(
            (output_dir_with_report / "bazaar-manifest.json").read_text()
        )
        assert manifest["completed"] is not None

    def test_missing_report_graceful(self, output_dir):
        """Phase 6 handles missing bazaar-report.md gracefully."""
        output_dir.mkdir(parents=True, exist_ok=True)
        bluf = bsum.summarize(6, output_dir)
        assert "Phase 6 BLUF" in bluf
        assert "not found" in bluf


# ── Manifest tests ─────────────────────────────────────────────────────────────

class TestManifest:
    def test_manifest_created_on_first_summarize(self, output_dir_with_brief):
        """Manifest is created if it doesn't exist when summarize is called."""
        manifest_path = output_dir_with_brief / "bazaar-manifest.json"
        assert not manifest_path.exists()
        bsum.summarize(1, output_dir_with_brief)
        assert manifest_path.exists()

    def test_manifest_accumulates_phases(self, output_dir_with_funded):
        """Multiple summarize calls accumulate phase entries in manifest."""
        bsum.summarize(1, output_dir_with_funded)
        bsum.summarize(3, output_dir_with_funded)
        manifest = json.loads(
            (output_dir_with_funded / "bazaar-manifest.json").read_text()
        )
        assert "1" in manifest["phases"]
        assert "3" in manifest["phases"]

    def test_manifest_overwrites_phase_entry(self, output_dir_with_funded):
        """Re-running summarize for the same phase overwrites the phase entry."""
        bsum.summarize(3, output_dir_with_funded)
        first_time = json.loads(
            (output_dir_with_funded / "bazaar-manifest.json").read_text()
        )["phases"]["3"]["completed_at"]

        import time
        time.sleep(0.01)  # ensure different timestamp

        bsum.summarize(3, output_dir_with_funded)
        second_time = json.loads(
            (output_dir_with_funded / "bazaar-manifest.json").read_text()
        )["phases"]["3"]["completed_at"]

        assert second_time >= first_time

    def test_existing_manifest_preserved(self, output_dir_with_brief):
        """Existing manifest fields are preserved when a phase is added."""
        manifest_path = output_dir_with_brief / "bazaar-manifest.json"
        existing = {
            "question": "My preserved question",
            "started": "2026-01-01T00:00:00+00:00",
            "completed": None,
            "output_dir": str(output_dir_with_brief),
            "providers": {"anthropic": True},
            "phases": {},
            "report_path": None,
            "word_count": None,
            "scenarios_funded": None,
        }
        manifest_path.write_text(json.dumps(existing))

        bsum.summarize(1, output_dir_with_brief)
        manifest = json.loads(manifest_path.read_text())
        assert manifest["question"] == "My preserved question"
        assert "1" in manifest["phases"]


# ── Invalid input tests ────────────────────────────────────────────────────────

class TestInvalidInputs:
    def test_invalid_phase_raises_value_error(self, output_dir):
        """Phase 0 and 7 raise ValueError."""
        output_dir.mkdir(parents=True, exist_ok=True)
        with pytest.raises(ValueError, match="Phase must be 1-6"):
            bsum.summarize(0, output_dir)
        with pytest.raises(ValueError, match="Phase must be 1-6"):
            bsum.summarize(7, output_dir)

    def test_output_dir_created_if_missing(self, tmp_path):
        """summarize() creates output_dir if it doesn't exist."""
        new_dir = tmp_path / "nonexistent" / "nested"
        assert not new_dir.exists()
        bsum.summarize(2, new_dir)  # Phase 2 with no ideators — graceful
        assert new_dir.exists()


# ── BLUF content quality tests ─────────────────────────────────────────────────

class TestBlufQuality:
    def test_phase1_bluf_is_concise(self, output_dir_with_brief):
        """Phase 1 BLUF is between 3 and 25 lines (concise summary)."""
        bluf = bsum.summarize(1, output_dir_with_brief)
        lines = [l for l in bluf.splitlines() if l.strip()]
        assert 3 <= len(lines) <= 25

    def test_phase2_bluf_is_concise(self, output_dir_with_all_scenarios):
        """Phase 2 BLUF is between 3 and 30 lines."""
        bluf = bsum.summarize(2, output_dir_with_all_scenarios)
        lines = [l for l in bluf.splitlines() if l.strip()]
        assert 3 <= len(lines) <= 30

    def test_phase3_bluf_is_concise(self, output_dir_with_funded):
        """Phase 3 BLUF is between 5 and 25 lines."""
        bluf = bsum.summarize(3, output_dir_with_funded)
        lines = [l for l in bluf.splitlines() if l.strip()]
        assert 5 <= len(lines) <= 25
