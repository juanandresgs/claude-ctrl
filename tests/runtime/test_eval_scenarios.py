"""Validation tests for the 15 seed eval scenarios (TKT-EVAL-5).

Verifies:
  1. All 15 YAML files (including the pre-existing write-who-deny.yaml) load
     without error via load_scenario().
  2. Each scenario has all required schema fields.
  3. Each scenario references an existing fixture directory.
  4. Each fixture directory contains EVAL_CONTRACT.md and fixture.yaml.

These tests do NOT run the scenarios — they validate that the data is
structurally correct so the runner can execute them.

@decision DEC-EVAL-SCENARIOS-001
Title: test_eval_scenarios.py validates data structure, not execution
Status: accepted
Rationale: Scenarios are data (YAML + fixture files). The runner tests
  (test_eval_runner.py) already cover execution. This module's job is to
  verify the 15 seed scenarios are structurally sound: parseable, referencing
  real fixtures, and containing the required contract files. Separating
  structural validation from execution tests keeps failures actionable —
  a structural failure here means bad YAML or a missing file, not a runner bug.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

import runtime.core.eval_runner as eval_runner
from runtime.eval_schemas import EVAL_CATEGORIES, EVAL_MODES

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SCENARIOS_DIR = REPO_ROOT / "evals" / "scenarios"
FIXTURES_DIR = REPO_ROOT / "evals" / "fixtures"

# All 15 expected scenario names (including the pre-existing write-who-deny)
EXPECTED_SCENARIO_NAMES: frozenset[str] = frozenset(
    {
        # gate (5)
        "write-who-deny",
        "impl-source-allow",
        "guardian-no-lease-deny",
        "eval-invalidation",
        "scope-violation-deny",
        # judgment (5)
        "dual-authority-detection",
        "mock-masking",
        "clean-implementation",
        "unreachable-code",
        "scope-violation-in-impl",
        # adversarial (5)
        "confident-wrong",
        "test-theater",
        "partial-implementation",
        "stale-evaluation",
        "hidden-state-mutation",
    }
)

EXPECTED_CATEGORY_COUNTS: dict[str, int] = {
    "gate": 5,
    "judgment": 5,
    "adversarial": 5,
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _all_yaml_paths() -> list[Path]:
    """Return paths to all scenario YAML files under SCENARIOS_DIR."""
    return sorted(SCENARIOS_DIR.rglob("*.yaml"))


def _load_all() -> list[dict]:
    """Load all discovered scenarios, failing on parse error."""
    scenarios = []
    for yaml_path in _all_yaml_paths():
        scenario = eval_runner.load_scenario(yaml_path)
        scenarios.append(scenario)
    return scenarios


# ---------------------------------------------------------------------------
# Test: all 15 YAML files exist and load without error
# ---------------------------------------------------------------------------


def test_all_15_scenarios_exist():
    """All 15 expected scenario YAML files exist under evals/scenarios/."""
    scenarios = _load_all()
    names = {s["name"] for s in scenarios}
    missing = EXPECTED_SCENARIO_NAMES - names
    assert not missing, f"Missing scenario YAML files: {sorted(missing)}"


def test_exactly_15_scenarios():
    """Exactly 15 scenario YAML files exist (no extras, no duplicates)."""
    scenarios = _load_all()
    names = [s["name"] for s in scenarios]
    assert len(names) == 15, f"Expected 15 scenarios, found {len(names)}: {sorted(names)}"
    # No duplicates
    assert len(names) == len(set(names)), f"Duplicate scenario names: {sorted(names)}"


def test_all_scenarios_parse_without_error():
    """Every scenario YAML under evals/scenarios/ loads via load_scenario()."""
    for yaml_path in _all_yaml_paths():
        # Should not raise
        scenario = eval_runner.load_scenario(yaml_path)
        assert isinstance(scenario, dict), f"load_scenario({yaml_path}) did not return a dict"


# ---------------------------------------------------------------------------
# Test: required schema fields
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("scenario", _load_all())
def test_scenario_has_required_fields(scenario):
    """Each scenario has all fields required by load_scenario() validation."""
    required = ("name", "category", "mode", "fixture", "ground_truth")
    for field in required:
        assert field in scenario, (
            f"Scenario '{scenario.get('name', '?')}' is missing required field: '{field}'"
        )


@pytest.mark.parametrize("scenario", _load_all())
def test_scenario_category_is_valid(scenario):
    """Each scenario's category is in EVAL_CATEGORIES."""
    assert scenario["category"] in EVAL_CATEGORIES, (
        f"Scenario '{scenario['name']}' has invalid category: '{scenario['category']}'"
    )


@pytest.mark.parametrize("scenario", _load_all())
def test_scenario_mode_is_valid(scenario):
    """Each scenario's mode is in EVAL_MODES."""
    assert scenario["mode"] in EVAL_MODES, (
        f"Scenario '{scenario['name']}' has invalid mode: '{scenario['mode']}'"
    )


@pytest.mark.parametrize("scenario", _load_all())
def test_scenario_ground_truth_has_expected_verdict(scenario):
    """Each scenario's ground_truth has an expected_verdict."""
    gt = scenario.get("ground_truth", {})
    assert "expected_verdict" in gt, (
        f"Scenario '{scenario['name']}' ground_truth is missing 'expected_verdict'"
    )
    assert gt["expected_verdict"], f"Scenario '{scenario['name']}' expected_verdict is empty"


# ---------------------------------------------------------------------------
# Test: category distribution
# ---------------------------------------------------------------------------


def test_five_gate_scenarios():
    """Exactly 5 gate scenarios exist."""
    scenarios = _load_all()
    gate = [s for s in scenarios if s["category"] == "gate"]
    assert len(gate) == 5, f"Expected 5 gate scenarios, found {len(gate)}"


def test_five_judgment_scenarios():
    """Exactly 5 judgment scenarios exist."""
    scenarios = _load_all()
    judgment = [s for s in scenarios if s["category"] == "judgment"]
    assert len(judgment) == 5, f"Expected 5 judgment scenarios, found {len(judgment)}"


def test_five_adversarial_scenarios():
    """Exactly 5 adversarial scenarios exist."""
    scenarios = _load_all()
    adversarial = [s for s in scenarios if s["category"] == "adversarial"]
    assert len(adversarial) == 5, f"Expected 5 adversarial scenarios, found {len(adversarial)}"


# ---------------------------------------------------------------------------
# Test: each scenario references an existing fixture directory
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("scenario", _load_all())
def test_scenario_fixture_directory_exists(scenario):
    """Each scenario's fixture field references an existing directory under evals/fixtures/."""
    fixture_name = scenario["fixture"]
    fixture_dir = FIXTURES_DIR / fixture_name
    assert fixture_dir.is_dir(), (
        f"Scenario '{scenario['name']}' references fixture '{fixture_name}' "
        f"but {fixture_dir} does not exist"
    )


# ---------------------------------------------------------------------------
# Test: each fixture directory contains EVAL_CONTRACT.md and fixture.yaml
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("scenario", _load_all())
def test_fixture_has_eval_contract(scenario):
    """Each fixture directory contains EVAL_CONTRACT.md."""
    fixture_dir = FIXTURES_DIR / scenario["fixture"]
    contract = fixture_dir / "EVAL_CONTRACT.md"
    assert contract.is_file(), f"Fixture '{scenario['fixture']}' is missing EVAL_CONTRACT.md"


@pytest.mark.parametrize("scenario", _load_all())
def test_fixture_has_fixture_yaml(scenario):
    """Each fixture directory contains fixture.yaml."""
    fixture_dir = FIXTURES_DIR / scenario["fixture"]
    fy = fixture_dir / "fixture.yaml"
    assert fy.is_file(), f"Fixture '{scenario['fixture']}' is missing fixture.yaml"


@pytest.mark.parametrize("scenario", _load_all())
def test_fixture_has_source_files(scenario):
    """Each fixture directory contains at least one Python source file."""
    fixture_dir = FIXTURES_DIR / scenario["fixture"]
    src_files = list(fixture_dir.rglob("*.py"))
    assert src_files, f"Fixture '{scenario['fixture']}' contains no Python source files"


# ---------------------------------------------------------------------------
# Test: gate scenarios are deterministic, judgment/adversarial are live
# ---------------------------------------------------------------------------


def test_gate_scenarios_are_deterministic():
    """All gate scenarios have mode=deterministic."""
    scenarios = _load_all()
    for s in scenarios:
        if s["category"] == "gate":
            assert s["mode"] == "deterministic", (
                f"Gate scenario '{s['name']}' has mode='{s['mode']}' (expected deterministic)"
            )


def test_judgment_scenarios_are_live():
    """All judgment scenarios have mode=live."""
    scenarios = _load_all()
    for s in scenarios:
        if s["category"] == "judgment":
            assert s["mode"] == "live", (
                f"Judgment scenario '{s['name']}' has mode='{s['mode']}' (expected live)"
            )


def test_adversarial_scenarios_are_live():
    """All adversarial scenarios have mode=live."""
    scenarios = _load_all()
    for s in scenarios:
        if s["category"] == "adversarial":
            assert s["mode"] == "live", (
                f"Adversarial scenario '{s['name']}' has mode='{s['mode']}' (expected live)"
            )


# ---------------------------------------------------------------------------
# Test: no fixture references files outside its own directory
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("scenario", _load_all())
def test_fixture_yaml_files_are_self_contained(scenario):
    """fixture.yaml's listed files all exist within the fixture directory."""
    import yaml

    fixture_dir = FIXTURES_DIR / scenario["fixture"]
    fy_path = fixture_dir / "fixture.yaml"
    if not fy_path.is_file():
        return  # covered by test_fixture_has_fixture_yaml

    with open(fy_path) as fh:
        meta = yaml.safe_load(fh) or {}

    # Check 'src' and 'tests' fields reference files inside the fixture dir
    for field in ("src", "tests"):
        rel = meta.get(field)
        if rel:
            full = fixture_dir / rel
            assert full.is_file(), (
                f"Fixture '{scenario['fixture']}' fixture.yaml {field}='{rel}' "
                f"does not exist at {full}"
            )


# ---------------------------------------------------------------------------
# Compound-interaction test: discover + load all gate scenarios end-to-end
# ---------------------------------------------------------------------------


def test_discover_all_gate_scenarios_end_to_end():
    """discover_scenarios() finds all 5 gate scenarios and they all load cleanly.

    This is the Compound-Interaction Test: it exercises the real production
    sequence — discover_scenarios() → load_scenario() — crossing the boundary
    between filesystem discovery, YAML parsing, and schema validation. All 5
    gate scenarios must be discoverable and valid.
    """
    gate_scenarios = eval_runner.discover_scenarios(SCENARIOS_DIR, category="gate")
    assert len(gate_scenarios) == 5, (
        f"Expected 5 gate scenarios from discover_scenarios(), found {len(gate_scenarios)}: "
        f"{[s['name'] for s in gate_scenarios]}"
    )
    for s in gate_scenarios:
        assert s["mode"] == "deterministic"
        assert s["category"] == "gate"
        fixture_dir = FIXTURES_DIR / s["fixture"]
        assert fixture_dir.is_dir(), f"Gate scenario '{s['name']}' fixture dir missing"
        assert (fixture_dir / "EVAL_CONTRACT.md").is_file()
        assert (fixture_dir / "fixture.yaml").is_file()
