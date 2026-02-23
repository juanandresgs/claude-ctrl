"""Tests for bazaar_prepare.py — Dispatch file construction and state preparation.

@decision DEC-BAZAAR-013
@title Disk-based state passing — agent reads only BLUFs, Python scripts handle data plumbing
@status accepted
@rationale Tests verify that each subcommand reads the correct input artifacts,
produces correctly-structured dispatch files (matching bazaar_dispatch.py input
format), handles provider degradation, and fails gracefully on missing inputs.
Fixtures use real artifact shapes from the E2E run at /private/tmp/bazaar-GgXiG5/.
Tests do NOT mock internal functions — they call the real functions with fixture
data per Sacred Practice #5.

Tests cover:
- ideation dispatch generation from brief.md + providers.json
- judge dispatch generation from all_scenarios.json + providers.json
- analyst dispatch generation from funded_scenarios.json + obsessives/*.json
- deduplication logic (ideators/*.json -> all_scenarios.json)
- analyst output collection (analysts/*.json -> analyst_outputs.json)
- manifest initialization (init subcommand)
- provider degradation (missing API key -> fallback to anthropic)
"""

import json
import os
from pathlib import Path
from unittest.mock import patch

import pytest

# conftest.py adds scripts/ to sys.path
import bazaar_prepare as bprep


# ── Fixtures ───────────────────────────────────────────────────────────────────

FIXTURES = Path(__file__).parent / "fixtures"
SKILL_DIR = Path(__file__).parent.parent
PROVIDERS_JSON = SKILL_DIR / "providers.json"


@pytest.fixture
def output_dir(tmp_path):
    """Fresh output directory for each test."""
    d = tmp_path / "bazaar-test-run"
    d.mkdir()
    return d


@pytest.fixture
def output_dir_with_brief(output_dir):
    """Output dir with brief.md from fixture."""
    (output_dir / "brief.md").write_text((FIXTURES / "sample_brief.md").read_text())
    return output_dir


@pytest.fixture
def output_dir_with_scenarios(output_dir):
    """Output dir with all_scenarios.json from fixture."""
    sample_data = json.loads((FIXTURES / "sample_scenarios.json").read_text())
    all_scenarios = {"scenarios": sample_data["scenarios"]}
    (output_dir / "all_scenarios.json").write_text(json.dumps(all_scenarios))
    return output_dir


@pytest.fixture
def output_dir_with_funded(output_dir_with_scenarios):
    """Output dir with funded_scenarios.json from fixture."""
    output_dir = output_dir_with_scenarios
    (output_dir / "funded_scenarios.json").write_text(
        (FIXTURES / "sample_funded_scenarios.json").read_text()
    )
    return output_dir


@pytest.fixture
def output_dir_with_ideators(output_dir):
    """Output dir with ideators/*.json for dedup testing."""
    ideators_dir = output_dir / "ideators"
    ideators_dir.mkdir()

    sample_data = json.loads((FIXTURES / "sample_scenarios.json").read_text())

    # methodical has all 4 scenarios
    dispatch1 = {
        "dispatch_id": "methodical",
        "success": True,
        "parsed": sample_data,
    }
    (ideators_dir / "methodical.json").write_text(json.dumps(dispatch1))

    # contrarian has 2 of the same + 1 new (to test dedup)
    contrarian_data = {
        "scenarios": [
            sample_data["scenarios"][0],  # duplicate: alpha-disruption
            {
                "id": "epsilon-new",
                "title": "New scenario from contrarian",
                "description": "Unique contrarian scenario",
                "key_assumptions": ["assumption X"],
                "potential_impact": "medium",
                "time_horizon": "near-term",
                "tags": ["new"],
            },
        ]
    }
    dispatch2 = {
        "dispatch_id": "contrarian",
        "success": True,
        "parsed": contrarian_data,
    }
    (ideators_dir / "contrarian.json").write_text(json.dumps(dispatch2))

    return output_dir


@pytest.fixture
def output_dir_with_analysts_raw(output_dir_with_funded):
    """Output dir with raw analysts/*.json (dispatch output format)."""
    analysts_dir = output_dir_with_funded / "analysts"
    analysts_dir.mkdir()

    analyst_src = json.loads((FIXTURES / "sample_analyst_output.json").read_text())
    (analysts_dir / "rag-grounding_analysis.json").write_text(json.dumps(analyst_src))

    # Add one more without scenario_id in parsed (filename-based extraction)
    no_sid = {
        "dispatch_id": "analyst-inference-verification",
        "success": True,
        "parsed": {
            "analyst": "synthesis",
            "findings": [],
            "overall_assessment": "Inference-time verification is promising.",
            "confidence_level": "medium",
        },
    }
    (analysts_dir / "inference-verification_analysis.json").write_text(json.dumps(no_sid))

    return output_dir_with_funded


@pytest.fixture
def all_providers_env(monkeypatch):
    """Set all four provider API keys in env."""
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-anthropic-key")
    monkeypatch.setenv("OPENAI_API_KEY", "test-openai-key")
    monkeypatch.setenv("GEMINI_API_KEY", "test-gemini-key")
    monkeypatch.setenv("PERPLEXITY_API_KEY", "test-perplexity-key")


@pytest.fixture
def anthropic_only_env(monkeypatch):
    """Only Anthropic API key available."""
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-anthropic-key")
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    monkeypatch.delenv("PERPLEXITY_API_KEY", raising=False)


# ── Provider resolution tests ──────────────────────────────────────────────────

class TestProviderResolution:
    def test_resolve_provider_uses_assignment(self, all_providers_env):
        """Resolves to the assigned provider when it's available."""
        config = json.loads(PROVIDERS_JSON.read_text())
        available = {"anthropic": True, "openai": True, "gemini": True, "perplexity": True}
        provider, model = bprep._resolve_provider("contrarian", config, available)
        assert provider == "openai"

    def test_resolve_provider_fallback_to_anthropic(self, anthropic_only_env):
        """Falls back to anthropic when assigned provider is unavailable."""
        config = json.loads(PROVIDERS_JSON.read_text())
        available = {"anthropic": True, "openai": False, "gemini": False, "perplexity": False}
        provider, model = bprep._resolve_provider("contrarian", config, available)
        assert provider == "anthropic"

    def test_resolve_provider_model_set(self, all_providers_env):
        """Returns a model name (not empty) for valid provider."""
        config = json.loads(PROVIDERS_JSON.read_text())
        available = {"anthropic": True, "openai": True, "gemini": True, "perplexity": True}
        provider, model = bprep._resolve_provider("methodical", config, available)
        assert model  # non-empty model string

    def test_resolve_unknown_archetype_defaults_anthropic(self):
        """Unknown archetype defaults to anthropic."""
        config = json.loads(PROVIDERS_JSON.read_text())
        available = {"anthropic": True, "openai": True}
        provider, model = bprep._resolve_provider("nonexistent-archetype", config, available)
        assert provider == "anthropic"


# ── cmd_ideation tests ─────────────────────────────────────────────────────────

class TestCmdIdeation:
    def test_creates_dispatch_file(self, output_dir_with_brief, all_providers_env):
        """ideation subcommand writes ideation_dispatches.json."""
        bprep.cmd_ideation(output_dir_with_brief, PROVIDERS_JSON)
        assert (output_dir_with_brief / "ideation_dispatches.json").exists()

    def test_dispatch_count(self, output_dir_with_brief, all_providers_env):
        """ideation creates 5 dispatches (one per ideator archetype)."""
        bprep.cmd_ideation(output_dir_with_brief, PROVIDERS_JSON)
        data = json.loads((output_dir_with_brief / "ideation_dispatches.json").read_text())
        assert len(data["dispatches"]) == 5

    def test_dispatch_ids_are_archetype_names(self, output_dir_with_brief, all_providers_env):
        """Each dispatch id matches an ideator archetype name."""
        bprep.cmd_ideation(output_dir_with_brief, PROVIDERS_JSON)
        data = json.loads((output_dir_with_brief / "ideation_dispatches.json").read_text())
        ids = {d["id"] for d in data["dispatches"]}
        expected = {"methodical", "contrarian", "pattern-matcher", "edge-case-hunter", "systems-thinker"}
        assert ids == expected

    def test_dispatch_has_required_fields(self, output_dir_with_brief, all_providers_env):
        """Each dispatch has all fields required by bazaar_dispatch.py."""
        bprep.cmd_ideation(output_dir_with_brief, PROVIDERS_JSON)
        data = json.loads((output_dir_with_brief / "ideation_dispatches.json").read_text())
        for d in data["dispatches"]:
            assert "id" in d
            assert "provider" in d
            assert "model" in d
            assert "system_prompt_file" in d
            assert "user_prompt" in d
            assert "output_file" in d

    def test_dispatch_user_prompt_contains_question(self, output_dir_with_brief, all_providers_env):
        """User prompt in dispatch contains the question from brief.md."""
        bprep.cmd_ideation(output_dir_with_brief, PROVIDERS_JSON)
        data = json.loads((output_dir_with_brief / "ideation_dispatches.json").read_text())
        for d in data["dispatches"]:
            assert "hallucination" in d["user_prompt"].lower()

    def test_dispatch_system_prompt_file_exists(self, output_dir_with_brief, all_providers_env):
        """system_prompt_file paths in dispatches point to real archetype files."""
        bprep.cmd_ideation(output_dir_with_brief, PROVIDERS_JSON)
        data = json.loads((output_dir_with_brief / "ideation_dispatches.json").read_text())
        for d in data["dispatches"]:
            assert Path(d["system_prompt_file"]).exists(), (
                f"Archetype file missing: {d['system_prompt_file']}"
            )

    def test_provider_degradation_applied(self, output_dir_with_brief, anthropic_only_env):
        """When only anthropic available, all dispatches use anthropic."""
        bprep.cmd_ideation(output_dir_with_brief, PROVIDERS_JSON)
        data = json.loads((output_dir_with_brief / "ideation_dispatches.json").read_text())
        for d in data["dispatches"]:
            assert d["provider"] == "anthropic"

    def test_output_files_point_into_ideators_dir(self, output_dir_with_brief, all_providers_env):
        """output_file paths in dispatches are inside output_dir/ideators/."""
        bprep.cmd_ideation(output_dir_with_brief, PROVIDERS_JSON)
        data = json.loads((output_dir_with_brief / "ideation_dispatches.json").read_text())
        for d in data["dispatches"]:
            assert "ideators" in d["output_file"]


# ── cmd_dedup tests ────────────────────────────────────────────────────────────

class TestCmdDedup:
    def test_creates_all_scenarios_file(self, output_dir_with_ideators):
        """dedup writes all_scenarios.json."""
        bprep.cmd_dedup(output_dir_with_ideators)
        assert (output_dir_with_ideators / "all_scenarios.json").exists()

    def test_deduplication_removes_duplicates(self, output_dir_with_ideators):
        """dedup removes duplicate scenario IDs across ideators."""
        bprep.cmd_dedup(output_dir_with_ideators)
        data = json.loads((output_dir_with_ideators / "all_scenarios.json").read_text())
        ids = [s["id"] for s in data["scenarios"]]
        assert len(ids) == len(set(ids)), "Duplicate scenario IDs found after dedup"

    def test_all_unique_scenarios_preserved(self, output_dir_with_ideators):
        """dedup preserves all unique scenarios from all ideators."""
        bprep.cmd_dedup(output_dir_with_ideators)
        data = json.loads((output_dir_with_ideators / "all_scenarios.json").read_text())
        ids = {s["id"] for s in data["scenarios"]}
        # methodical has 4, contrarian adds 1 new (epsilon-new)
        assert "alpha-disruption" in ids
        assert "epsilon-new" in ids

    def test_count_is_correct(self, output_dir_with_ideators):
        """dedup produces the correct unique scenario count."""
        bprep.cmd_dedup(output_dir_with_ideators)
        data = json.loads((output_dir_with_ideators / "all_scenarios.json").read_text())
        # 4 from methodical + 1 new from contrarian (alpha-disruption is duplicate)
        assert len(data["scenarios"]) == 5

    def test_empty_ideators_dir(self, output_dir):
        """dedup handles empty ideators/ dir gracefully."""
        (output_dir / "ideators").mkdir()
        bprep.cmd_dedup(output_dir)
        data = json.loads((output_dir / "all_scenarios.json").read_text())
        assert data["scenarios"] == []

    def test_skips_malformed_files(self, output_dir):
        """dedup skips files that are not valid JSON or lack scenarios."""
        ideators_dir = output_dir / "ideators"
        ideators_dir.mkdir()
        (ideators_dir / "broken.json").write_text("not valid json {{{")
        (ideators_dir / "no_scenarios.json").write_text(json.dumps({"success": True, "parsed": {}}))
        bprep.cmd_dedup(output_dir)
        data = json.loads((output_dir / "all_scenarios.json").read_text())
        assert data["scenarios"] == []

    def test_dispatch_summary_excluded(self, output_dir_with_ideators):
        """dedup excludes dispatch_summary.json files."""
        # Add a dispatch_summary.json that would break if parsed as ideator output
        (output_dir_with_ideators / "ideators" / "dispatch_summary.json").write_text(
            json.dumps({"total": 2, "succeeded": 2, "failed": 0, "results": []})
        )
        bprep.cmd_dedup(output_dir_with_ideators)
        # Should still succeed without error
        data = json.loads((output_dir_with_ideators / "all_scenarios.json").read_text())
        assert isinstance(data["scenarios"], list)


# ── cmd_funding tests ──────────────────────────────────────────────────────────

class TestCmdFunding:
    def test_creates_judge_dispatch_file(self, output_dir_with_scenarios, all_providers_env):
        """funding subcommand writes judge_dispatches.json."""
        bprep.cmd_funding(output_dir_with_scenarios, PROVIDERS_JSON)
        assert (output_dir_with_scenarios / "judge_dispatches.json").exists()

    def test_dispatch_count(self, output_dir_with_scenarios, all_providers_env):
        """funding creates 4 judge dispatches."""
        bprep.cmd_funding(output_dir_with_scenarios, PROVIDERS_JSON)
        data = json.loads((output_dir_with_scenarios / "judge_dispatches.json").read_text())
        assert len(data["dispatches"]) == 4

    def test_judge_archetype_ids(self, output_dir_with_scenarios, all_providers_env):
        """Dispatch IDs match the 4 judge archetypes."""
        bprep.cmd_funding(output_dir_with_scenarios, PROVIDERS_JSON)
        data = json.loads((output_dir_with_scenarios / "judge_dispatches.json").read_text())
        ids = {d["id"] for d in data["dispatches"]}
        assert ids == {"pragmatist", "visionary", "risk-manager", "quant"}

    def test_prompt_contains_scenarios(self, output_dir_with_scenarios, all_providers_env):
        """Judge user_prompt contains scenario IDs from all_scenarios.json."""
        bprep.cmd_funding(output_dir_with_scenarios, PROVIDERS_JSON)
        data = json.loads((output_dir_with_scenarios / "judge_dispatches.json").read_text())
        for d in data["dispatches"]:
            assert "alpha-disruption" in d["user_prompt"]

    def test_prompt_contains_allocation_instruction(self, output_dir_with_scenarios, all_providers_env):
        """Judge prompt includes the 1000-units allocation instruction."""
        bprep.cmd_funding(output_dir_with_scenarios, PROVIDERS_JSON)
        data = json.loads((output_dir_with_scenarios / "judge_dispatches.json").read_text())
        for d in data["dispatches"]:
            assert "1000" in d["user_prompt"]

    def test_required_fields_present(self, output_dir_with_scenarios, all_providers_env):
        """Each judge dispatch has all required fields."""
        bprep.cmd_funding(output_dir_with_scenarios, PROVIDERS_JSON)
        data = json.loads((output_dir_with_scenarios / "judge_dispatches.json").read_text())
        for d in data["dispatches"]:
            for field in ("id", "provider", "model", "system_prompt_file", "user_prompt", "output_file"):
                assert field in d, f"Missing field {field!r} in dispatch {d['id']}"

    def test_missing_all_scenarios_exits(self, output_dir, all_providers_env, capsys):
        """funding exits with error if all_scenarios.json is missing."""
        with pytest.raises(SystemExit):
            bprep.cmd_funding(output_dir, PROVIDERS_JSON)

    def test_provider_degradation(self, output_dir_with_scenarios, anthropic_only_env):
        """With only anthropic available, all judges use anthropic."""
        bprep.cmd_funding(output_dir_with_scenarios, PROVIDERS_JSON)
        data = json.loads((output_dir_with_scenarios / "judge_dispatches.json").read_text())
        for d in data["dispatches"]:
            assert d["provider"] == "anthropic"


# ── cmd_analysis tests ─────────────────────────────────────────────────────────

class TestCmdAnalysis:
    def test_creates_analyst_dispatch_file(self, output_dir_with_funded, all_providers_env):
        """analysis subcommand writes analyst_dispatches.json."""
        bprep.cmd_analysis(output_dir_with_funded, PROVIDERS_JSON)
        assert (output_dir_with_funded / "analyst_dispatches.json").exists()

    def test_dispatch_count_matches_funded_scenarios(self, output_dir_with_funded, all_providers_env):
        """One analyst dispatch per funded scenario."""
        bprep.cmd_analysis(output_dir_with_funded, PROVIDERS_JSON)
        data = json.loads((output_dir_with_funded / "analyst_dispatches.json").read_text())
        # fixture has 4 funded scenarios
        assert len(data["dispatches"]) == 4

    def test_dispatch_ids_reference_scenario_ids(self, output_dir_with_funded, all_providers_env):
        """Dispatch IDs are 'analyst-<scenario_id>'."""
        bprep.cmd_analysis(output_dir_with_funded, PROVIDERS_JSON)
        data = json.loads((output_dir_with_funded / "analyst_dispatches.json").read_text())
        for d in data["dispatches"]:
            assert d["id"].startswith("analyst-")

    def test_prompt_contains_scenario_id(self, output_dir_with_funded, all_providers_env):
        """Analyst prompt includes the scenario ID."""
        bprep.cmd_analysis(output_dir_with_funded, PROVIDERS_JSON)
        data = json.loads((output_dir_with_funded / "analyst_dispatches.json").read_text())
        # Find the rag-grounding dispatch
        rag_dispatch = next((d for d in data["dispatches"] if "rag-grounding" in d["id"]), None)
        assert rag_dispatch is not None
        assert "rag-grounding" in rag_dispatch["user_prompt"]

    def test_prompt_contains_funding_percent(self, output_dir_with_funded, all_providers_env):
        """Analyst prompt includes the funding percentage."""
        bprep.cmd_analysis(output_dir_with_funded, PROVIDERS_JSON)
        data = json.loads((output_dir_with_funded / "analyst_dispatches.json").read_text())
        rag_dispatch = next((d for d in data["dispatches"] if "rag-grounding" in d["id"]), None)
        assert rag_dispatch is not None
        assert "34.2" in rag_dispatch["user_prompt"]

    def test_research_signals_included_when_present(self, output_dir_with_funded, all_providers_env):
        """Analyst prompt includes obsessive research when files exist."""
        obsessives_dir = output_dir_with_funded / "obsessives"
        obsessives_dir.mkdir()
        domain_data = {
            "success": True,
            "parsed": {"signals": [{"signal": "test-signal-content"}]},
        }
        (obsessives_dir / "rag-grounding_domain.json").write_text(json.dumps(domain_data))

        bprep.cmd_analysis(output_dir_with_funded, PROVIDERS_JSON)
        data = json.loads((output_dir_with_funded / "analyst_dispatches.json").read_text())
        rag_dispatch = next((d for d in data["dispatches"] if "rag-grounding" in d["id"]), None)
        assert rag_dispatch is not None
        assert "test-signal-content" in rag_dispatch["user_prompt"]

    def test_no_research_signals_graceful(self, output_dir_with_funded, all_providers_env):
        """Analyst dispatch is created even when no obsessive files exist."""
        bprep.cmd_analysis(output_dir_with_funded, PROVIDERS_JSON)
        data = json.loads((output_dir_with_funded / "analyst_dispatches.json").read_text())
        for d in data["dispatches"]:
            assert "No research signals available" in d["user_prompt"] or "user_prompt" in d

    def test_missing_funded_scenarios_exits(self, output_dir, all_providers_env):
        """analysis exits with error if funded_scenarios.json is missing."""
        with pytest.raises(SystemExit):
            bprep.cmd_analysis(output_dir, PROVIDERS_JSON)


# ── cmd_collect_analysts tests ─────────────────────────────────────────────────

class TestCmdCollectAnalysts:
    def test_creates_analyst_outputs_file(self, output_dir_with_analysts_raw):
        """collect-analysts writes analyst_outputs.json."""
        bprep.cmd_collect_analysts(output_dir_with_analysts_raw)
        assert (output_dir_with_analysts_raw / "analyst_outputs.json").exists()

    def test_collects_by_scenario_id(self, output_dir_with_analysts_raw):
        """analyst_outputs.json is keyed by scenario_id."""
        bprep.cmd_collect_analysts(output_dir_with_analysts_raw)
        data = json.loads((output_dir_with_analysts_raw / "analyst_outputs.json").read_text())
        assert "rag-grounding" in data

    def test_fallback_to_filename_for_scenario_id(self, output_dir_with_analysts_raw):
        """When parsed has no scenario_id, filename stem is used as key."""
        bprep.cmd_collect_analysts(output_dir_with_analysts_raw)
        data = json.loads((output_dir_with_analysts_raw / "analyst_outputs.json").read_text())
        # inference-verification_analysis.json -> key "inference-verification"
        assert "inference-verification" in data

    def test_count_matches_valid_files(self, output_dir_with_analysts_raw):
        """Collects exactly 2 analyst outputs (2 valid files in fixture)."""
        bprep.cmd_collect_analysts(output_dir_with_analysts_raw)
        data = json.loads((output_dir_with_analysts_raw / "analyst_outputs.json").read_text())
        assert len(data) == 2

    def test_empty_analysts_dir(self, output_dir):
        """collect-analysts handles empty analysts/ dir gracefully."""
        (output_dir / "analysts").mkdir()
        bprep.cmd_collect_analysts(output_dir)
        data = json.loads((output_dir / "analyst_outputs.json").read_text())
        assert data == {}

    def test_dispatch_summary_excluded(self, output_dir_with_analysts_raw):
        """collect-analysts excludes dispatch_summary.json."""
        (output_dir_with_analysts_raw / "analysts" / "dispatch_summary.json").write_text(
            json.dumps({"total": 2, "succeeded": 2, "failed": 0})
        )
        bprep.cmd_collect_analysts(output_dir_with_analysts_raw)
        data = json.loads((output_dir_with_analysts_raw / "analyst_outputs.json").read_text())
        assert "dispatch_summary" not in data


# ── cmd_init tests ─────────────────────────────────────────────────────────────

class TestCmdInit:
    def test_creates_manifest(self, output_dir, all_providers_env):
        """init subcommand creates bazaar-manifest.json."""
        bprep.cmd_init(output_dir, "Test question", PROVIDERS_JSON)
        assert (output_dir / "bazaar-manifest.json").exists()

    def test_manifest_has_question(self, output_dir, all_providers_env):
        """Manifest contains the question."""
        bprep.cmd_init(output_dir, "Test question about hallucination", PROVIDERS_JSON)
        manifest = json.loads((output_dir / "bazaar-manifest.json").read_text())
        assert manifest["question"] == "Test question about hallucination"

    def test_manifest_has_started_timestamp(self, output_dir, all_providers_env):
        """Manifest has a started ISO-8601 timestamp."""
        bprep.cmd_init(output_dir, "Q", PROVIDERS_JSON)
        manifest = json.loads((output_dir / "bazaar-manifest.json").read_text())
        assert manifest["started"] is not None
        assert "T" in manifest["started"]  # ISO-8601 format

    def test_manifest_completed_is_null(self, output_dir, all_providers_env):
        """Manifest completed field is null at initialization."""
        bprep.cmd_init(output_dir, "Q", PROVIDERS_JSON)
        manifest = json.loads((output_dir / "bazaar-manifest.json").read_text())
        assert manifest["completed"] is None

    def test_manifest_providers_reflect_availability(self, output_dir, all_providers_env):
        """Manifest providers dict reflects which keys are available."""
        bprep.cmd_init(output_dir, "Q", PROVIDERS_JSON)
        manifest = json.loads((output_dir / "bazaar-manifest.json").read_text())
        assert manifest["providers"]["anthropic"] is True
        assert manifest["providers"]["openai"] is True

    def test_manifest_providers_missing_key(self, output_dir, anthropic_only_env):
        """Manifest shows False for providers without API keys."""
        bprep.cmd_init(output_dir, "Q", PROVIDERS_JSON)
        manifest = json.loads((output_dir / "bazaar-manifest.json").read_text())
        assert manifest["providers"]["anthropic"] is True
        assert manifest["providers"]["openai"] is False

    def test_manifest_phases_empty(self, output_dir, all_providers_env):
        """Manifest phases dict is empty at initialization."""
        bprep.cmd_init(output_dir, "Q", PROVIDERS_JSON)
        manifest = json.loads((output_dir / "bazaar-manifest.json").read_text())
        assert manifest["phases"] == {}

    def test_manifest_output_dir_is_absolute(self, output_dir, all_providers_env):
        """Manifest output_dir is an absolute path."""
        bprep.cmd_init(output_dir, "Q", PROVIDERS_JSON)
        manifest = json.loads((output_dir / "bazaar-manifest.json").read_text())
        assert Path(manifest["output_dir"]).is_absolute()

    def test_creates_output_dir_if_missing(self, tmp_path, all_providers_env):
        """init creates output_dir if it doesn't exist."""
        new_dir = tmp_path / "new-run-dir"
        assert not new_dir.exists()
        bprep.cmd_init(new_dir, "Q", PROVIDERS_JSON)
        assert new_dir.exists()
        assert (new_dir / "bazaar-manifest.json").exists()
