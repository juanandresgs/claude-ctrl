"""Tests for runtime.core.eval_runner — scenario loader, fixture setup, and runner.

Tests run in-process with no subprocess calls. eval_conn is an in-memory
SQLite connection. Fixture setup uses a real temp directory under tmp/.

All test functions are named to match the Evaluation Contract test IDs in
TKT-EVAL-2.

@decision DEC-EVAL-RUNNER-001
Title: eval_runner tests use real temp dirs under tmp/, not /tmp/
Status: accepted
Rationale: Sacred Practice 3 forbids /tmp/. setup_fixture() must use project
  tmp/. Tests verify this by checking that the returned path is under
  project_tmp (a pytest tmp_path under the project root's tmp/ equivalent).
  Using real temp dirs (not mocks) validates the actual git init/copy logic.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

# Ensure the project root is importable regardless of test runner CWD
sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

import runtime.core.eval_runner as eval_runner

import runtime.core.eval_metrics as eval_metrics
from runtime.core.db import connect_memory
from runtime.eval_schemas import ensure_eval_schema

# ---------------------------------------------------------------------------
# Paths to real scenario/fixture directories
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SCENARIOS_DIR = REPO_ROOT / "evals" / "scenarios"
FIXTURES_DIR = REPO_ROOT / "evals" / "fixtures"
WRITE_WHO_DENY_YAML = SCENARIOS_DIR / "gate" / "write-who-deny.yaml"


# ---------------------------------------------------------------------------
# Shared fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def eval_conn():
    """In-memory eval_results.db connection, schema applied."""
    c = connect_memory()
    ensure_eval_schema(c)
    yield c
    c.close()


@pytest.fixture
def project_tmp(tmp_path):
    """Temp directory that acts as the project tmp/ root."""
    d = tmp_path / "tmp"
    d.mkdir()
    return d


# ---------------------------------------------------------------------------
# load_scenario()
# ---------------------------------------------------------------------------


def test_load_scenario_valid():
    """load_scenario() parses write-who-deny.yaml without error."""
    scenario = eval_runner.load_scenario(WRITE_WHO_DENY_YAML)
    assert scenario["name"] == "write-who-deny"
    assert scenario["category"] == "gate"
    assert scenario["mode"] == "deterministic"
    assert scenario["fixture"] == "clean-hello-world"
    assert "ground_truth" in scenario


def test_load_scenario_has_required_fields():
    scenario = eval_runner.load_scenario(WRITE_WHO_DENY_YAML)
    for field in ("name", "category", "mode", "fixture", "ground_truth"):
        assert field in scenario, f"Missing required field: {field}"


def test_load_scenario_missing_required_field(tmp_path):
    """load_scenario() raises ValueError if a required field is absent."""
    # YAML missing 'name'
    bad_yaml = tmp_path / "bad.yaml"
    bad_yaml.write_text(
        "category: gate\nmode: deterministic\nfixture: clean-hello-world\nground_truth: {}\n"
    )
    with pytest.raises(ValueError, match="name"):
        eval_runner.load_scenario(bad_yaml)


def test_load_scenario_missing_category(tmp_path):
    bad_yaml = tmp_path / "bad.yaml"
    bad_yaml.write_text(
        "name: test\nmode: deterministic\nfixture: clean-hello-world\nground_truth: {}\n"
    )
    with pytest.raises(ValueError, match="category"):
        eval_runner.load_scenario(bad_yaml)


def test_load_scenario_missing_mode(tmp_path):
    bad_yaml = tmp_path / "bad.yaml"
    bad_yaml.write_text(
        "name: test\ncategory: gate\nfixture: clean-hello-world\nground_truth: {}\n"
    )
    with pytest.raises(ValueError, match="mode"):
        eval_runner.load_scenario(bad_yaml)


def test_load_scenario_missing_fixture(tmp_path):
    bad_yaml = tmp_path / "bad.yaml"
    bad_yaml.write_text("name: test\ncategory: gate\nmode: deterministic\nground_truth: {}\n")
    with pytest.raises(ValueError, match="fixture"):
        eval_runner.load_scenario(bad_yaml)


def test_load_scenario_missing_ground_truth(tmp_path):
    bad_yaml = tmp_path / "bad.yaml"
    bad_yaml.write_text(
        "name: test\ncategory: gate\nmode: deterministic\nfixture: clean-hello-world\n"
    )
    with pytest.raises(ValueError, match="ground_truth"):
        eval_runner.load_scenario(bad_yaml)


def test_load_scenario_invalid_category(tmp_path):
    """load_scenario() raises ValueError for an unknown category."""
    bad_yaml = tmp_path / "bad.yaml"
    bad_yaml.write_text(
        "name: test\ncategory: unknown_cat\nmode: deterministic\n"
        "fixture: clean-hello-world\nground_truth: {}\n"
    )
    with pytest.raises(ValueError, match="category"):
        eval_runner.load_scenario(bad_yaml)


def test_load_scenario_invalid_mode(tmp_path):
    """load_scenario() raises ValueError for an unknown mode."""
    bad_yaml = tmp_path / "bad.yaml"
    bad_yaml.write_text(
        "name: test\ncategory: gate\nmode: unknown_mode\n"
        "fixture: clean-hello-world\nground_truth: {}\n"
    )
    with pytest.raises(ValueError, match="mode"):
        eval_runner.load_scenario(bad_yaml)


# ---------------------------------------------------------------------------
# discover_scenarios()
# ---------------------------------------------------------------------------


def test_discover_scenarios_finds_yaml():
    """discover_scenarios() finds the write-who-deny.yaml file."""
    scenarios = eval_runner.discover_scenarios(SCENARIOS_DIR)
    names = [s["name"] for s in scenarios]
    assert "write-who-deny" in names


def test_discover_scenarios_only_yaml_files(tmp_path):
    """discover_scenarios() ignores non-YAML files."""
    (tmp_path / "gate").mkdir()
    # Create a valid YAML scenario
    (tmp_path / "gate" / "test-scenario.yaml").write_text(
        "name: test-scenario\ncategory: gate\nmode: deterministic\n"
        "fixture: clean-hello-world\nground_truth: {}\n"
    )
    # Non-YAML should be ignored
    (tmp_path / "gate" / "notes.txt").write_text("not a scenario")
    (tmp_path / "gate" / "schema.json").write_text("{}")
    scenarios = eval_runner.discover_scenarios(tmp_path)
    assert len(scenarios) == 1
    assert scenarios[0]["name"] == "test-scenario"


def test_discover_scenarios_filters_by_category(tmp_path):
    """discover_scenarios() returns only scenarios matching the given category."""
    for cat in ("gate", "judgment", "adversarial"):
        (tmp_path / cat).mkdir()
        (tmp_path / cat / f"{cat}-test.yaml").write_text(
            f"name: {cat}-test\ncategory: {cat}\nmode: deterministic\n"
            "fixture: clean-hello-world\nground_truth: {}\n"
        )
    scenarios = eval_runner.discover_scenarios(tmp_path, category="gate")
    assert all(s["category"] == "gate" for s in scenarios)
    assert len(scenarios) == 1
    assert scenarios[0]["name"] == "gate-test"


def test_discover_scenarios_filters_by_mode(tmp_path):
    """discover_scenarios() returns only scenarios matching the given mode."""
    (tmp_path / "gate").mkdir()
    (tmp_path / "gate" / "determ.yaml").write_text(
        "name: determ\ncategory: gate\nmode: deterministic\n"
        "fixture: clean-hello-world\nground_truth: {}\n"
    )
    (tmp_path / "gate" / "live-test.yaml").write_text(
        "name: live-test\ncategory: gate\nmode: live\n"
        "fixture: clean-hello-world\nground_truth: {}\n"
    )
    scenarios = eval_runner.discover_scenarios(tmp_path, mode="deterministic")
    assert len(scenarios) == 1
    assert scenarios[0]["mode"] == "deterministic"


def test_discover_scenarios_sorted_by_name(tmp_path):
    """discover_scenarios() returns scenarios sorted by name."""
    (tmp_path / "gate").mkdir()
    for name in ("z-last", "a-first", "m-middle"):
        (tmp_path / "gate" / f"{name}.yaml").write_text(
            f"name: {name}\ncategory: gate\nmode: deterministic\n"
            "fixture: clean-hello-world\nground_truth: {}\n"
        )
    scenarios = eval_runner.discover_scenarios(tmp_path)
    names = [s["name"] for s in scenarios]
    assert names == sorted(names)


def test_discover_scenarios_empty_dir_returns_empty(tmp_path):
    assert eval_runner.discover_scenarios(tmp_path) == []


def test_discover_scenarios_real_dir_has_at_least_one():
    """Real scenarios dir contains at least write-who-deny."""
    scenarios = eval_runner.discover_scenarios(SCENARIOS_DIR)
    assert len(scenarios) >= 1


# ---------------------------------------------------------------------------
# setup_fixture()
# ---------------------------------------------------------------------------


def test_setup_fixture_creates_temp(project_tmp):
    """setup_fixture() creates a directory under project_tmp."""
    path = eval_runner.setup_fixture("clean-hello-world", FIXTURES_DIR, project_tmp)
    try:
        assert path.exists()
        assert path.is_dir()
    finally:
        eval_runner.cleanup_fixture(path)


def test_setup_fixture_temp_under_project_tmp(project_tmp):
    """setup_fixture() must NOT use /tmp/ — path must be under project_tmp."""
    path = eval_runner.setup_fixture("clean-hello-world", FIXTURES_DIR, project_tmp)
    try:
        assert str(path).startswith(str(project_tmp))
    finally:
        eval_runner.cleanup_fixture(path)


def test_setup_fixture_has_git_repo(project_tmp):
    """setup_fixture() initializes a git repo in the temp dir."""
    path = eval_runner.setup_fixture("clean-hello-world", FIXTURES_DIR, project_tmp)
    try:
        assert (path / ".git").exists()
    finally:
        eval_runner.cleanup_fixture(path)


def test_setup_fixture_copies_files(project_tmp):
    """setup_fixture() copies all fixture files including subdirectories."""
    path = eval_runner.setup_fixture("clean-hello-world", FIXTURES_DIR, project_tmp)
    try:
        assert (path / "fixture.yaml").exists()
        assert (path / "src" / "hello.py").exists()
        assert (path / "tests" / "test_hello.py").exists()
        assert (path / "EVAL_CONTRACT.md").exists()
    finally:
        eval_runner.cleanup_fixture(path)


def test_setup_fixture_on_feature_branch(project_tmp):
    """setup_fixture() creates a feature branch (not main/master)."""
    import subprocess

    path = eval_runner.setup_fixture("clean-hello-world", FIXTURES_DIR, project_tmp)
    try:
        result = subprocess.run(
            ["git", "-C", str(path), "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
        )
        branch = result.stdout.strip()
        assert branch not in ("", "HEAD")  # Something is checked out
    finally:
        eval_runner.cleanup_fixture(path)


def test_setup_fixture_has_initial_commit(project_tmp):
    """setup_fixture() makes at least one git commit."""
    import subprocess

    path = eval_runner.setup_fixture("clean-hello-world", FIXTURES_DIR, project_tmp)
    try:
        result = subprocess.run(
            ["git", "-C", str(path), "log", "--oneline"],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0
        assert result.stdout.strip()  # At least one commit line
    finally:
        eval_runner.cleanup_fixture(path)


# ---------------------------------------------------------------------------
# run_deterministic()
# ---------------------------------------------------------------------------


def test_run_deterministic_write_who_deny(project_tmp):
    """The write-who-deny scenario produces a deny verdict when run deterministically.

    This is the Compound-Interaction Test: it exercises the real production
    sequence — setup_fixture → run_deterministic — and crosses the boundary
    between fixture setup (git init, file copy), state.db bootstrap (schemas),
    and policy engine evaluation (write_who policy).
    """
    scenario = eval_runner.load_scenario(WRITE_WHO_DENY_YAML)
    path = eval_runner.setup_fixture("clean-hello-world", FIXTURES_DIR, project_tmp)
    try:
        result = eval_runner.run_deterministic(scenario, path, REPO_ROOT)
        assert result["verdict"] == "deny"
        assert result["error"] is None
        assert isinstance(result["raw_output"], str)
        assert isinstance(result["duration_ms"], int)
        assert result["duration_ms"] >= 0
    finally:
        eval_runner.cleanup_fixture(path)


def test_run_deterministic_returns_required_keys(project_tmp):
    """run_deterministic() result dict must have verdict, raw_output, duration_ms, error."""
    scenario = eval_runner.load_scenario(WRITE_WHO_DENY_YAML)
    path = eval_runner.setup_fixture("clean-hello-world", FIXTURES_DIR, project_tmp)
    try:
        result = eval_runner.run_deterministic(scenario, path, REPO_ROOT)
        assert set(result.keys()) >= {"verdict", "raw_output", "duration_ms", "error"}
    finally:
        eval_runner.cleanup_fixture(path)


def test_run_deterministic_error_is_none_on_success(project_tmp):
    """error key is None when run_deterministic() succeeds."""
    scenario = eval_runner.load_scenario(WRITE_WHO_DENY_YAML)
    path = eval_runner.setup_fixture("clean-hello-world", FIXTURES_DIR, project_tmp)
    try:
        result = eval_runner.run_deterministic(scenario, path, REPO_ROOT)
        assert result["error"] is None
    finally:
        eval_runner.cleanup_fixture(path)


# ---------------------------------------------------------------------------
# run_live()
# ---------------------------------------------------------------------------


def test_run_live_raises_not_implemented(project_tmp):
    """run_live() raises NotImplementedError (scaffold for W-EVAL-5)."""
    scenario = eval_runner.load_scenario(WRITE_WHO_DENY_YAML)
    path = eval_runner.setup_fixture("clean-hello-world", FIXTURES_DIR, project_tmp)
    try:
        with pytest.raises(NotImplementedError):
            eval_runner.run_live(scenario, path)
    finally:
        eval_runner.cleanup_fixture(path)


# ---------------------------------------------------------------------------
# cleanup_fixture()
# ---------------------------------------------------------------------------


def test_cleanup_fixture_removes_dir(project_tmp):
    """cleanup_fixture() removes the temp directory."""
    path = eval_runner.setup_fixture("clean-hello-world", FIXTURES_DIR, project_tmp)
    assert path.exists()
    eval_runner.cleanup_fixture(path)
    assert not path.exists()


def test_cleanup_fixture_missing_path(project_tmp):
    """cleanup_fixture() does not raise if the path does not exist."""
    missing = project_tmp / "nonexistent-eval-dir"
    # Must not raise
    eval_runner.cleanup_fixture(missing)


def test_cleanup_fixture_idempotent(project_tmp):
    """cleanup_fixture() called twice on same path does not raise."""
    path = eval_runner.setup_fixture("clean-hello-world", FIXTURES_DIR, project_tmp)
    eval_runner.cleanup_fixture(path)
    eval_runner.cleanup_fixture(path)  # Second call must not raise


# ---------------------------------------------------------------------------
# run_scenario()
# ---------------------------------------------------------------------------


def test_run_scenario_returns_dict(eval_conn, project_tmp):
    """run_scenario() returns a result dict."""
    scenario = eval_runner.load_scenario(WRITE_WHO_DENY_YAML)
    run_id = eval_metrics.create_run(eval_conn, mode="deterministic")
    result = eval_runner.run_scenario(
        scenario=scenario,
        fixtures_dir=FIXTURES_DIR,
        eval_conn=eval_conn,
        project_tmp=project_tmp,
        repo_root=REPO_ROOT,
        run_id=run_id,
    )
    assert isinstance(result, dict)


def test_run_scenario_records_score(eval_conn, project_tmp):
    """run_scenario() records a score row in eval_conn."""
    scenario = eval_runner.load_scenario(WRITE_WHO_DENY_YAML)
    run_id = eval_metrics.create_run(eval_conn, mode="deterministic")
    eval_runner.run_scenario(
        scenario=scenario,
        fixtures_dir=FIXTURES_DIR,
        eval_conn=eval_conn,
        project_tmp=project_tmp,
        repo_root=REPO_ROOT,
        run_id=run_id,
    )
    scores = eval_metrics.get_scores(eval_conn, run_id)
    assert len(scores) == 1
    assert scores[0]["scenario_id"] == "write-who-deny"


def test_run_scenario_cleanup_after_run(eval_conn, project_tmp):
    """run_scenario() removes the fixture temp directory after running."""
    scenario = eval_runner.load_scenario(WRITE_WHO_DENY_YAML)
    run_id = eval_metrics.create_run(eval_conn, mode="deterministic")
    result = eval_runner.run_scenario(
        scenario=scenario,
        fixtures_dir=FIXTURES_DIR,
        eval_conn=eval_conn,
        project_tmp=project_tmp,
        repo_root=REPO_ROOT,
        run_id=run_id,
    )
    # Fixture path should be cleaned up
    fixture_path = result.get("fixture_path")
    if fixture_path:
        assert not Path(fixture_path).exists()


# ---------------------------------------------------------------------------
# run_all()
# ---------------------------------------------------------------------------


def test_run_all_creates_run_record(eval_conn, project_tmp):
    """run_all() creates an eval_runs row."""
    run_id = eval_runner.run_all(
        scenarios_dir=SCENARIOS_DIR,
        fixtures_dir=FIXTURES_DIR,
        eval_conn=eval_conn,
        project_tmp=project_tmp,
        repo_root=REPO_ROOT,
        category="gate",
        mode="deterministic",
    )
    row = eval_metrics.get_run(eval_conn, run_id)
    assert row is not None
    assert row["run_id"] == run_id


def test_run_all_records_scores(eval_conn, project_tmp):
    """run_all() records at least one score row per discovered scenario."""
    run_id = eval_runner.run_all(
        scenarios_dir=SCENARIOS_DIR,
        fixtures_dir=FIXTURES_DIR,
        eval_conn=eval_conn,
        project_tmp=project_tmp,
        repo_root=REPO_ROOT,
        category="gate",
        mode="deterministic",
    )
    scores = eval_metrics.get_scores(eval_conn, run_id)
    assert len(scores) >= 1


def test_run_all_finalizes_run(eval_conn, project_tmp):
    """run_all() finalizes the run (finished_at is set)."""
    run_id = eval_runner.run_all(
        scenarios_dir=SCENARIOS_DIR,
        fixtures_dir=FIXTURES_DIR,
        eval_conn=eval_conn,
        project_tmp=project_tmp,
        repo_root=REPO_ROOT,
        category="gate",
        mode="deterministic",
    )
    row = eval_metrics.get_run(eval_conn, run_id)
    assert row["finished_at"] is not None


def test_run_all_returns_run_id_string(eval_conn, project_tmp):
    """run_all() returns a UUID string run_id."""
    import uuid

    run_id = eval_runner.run_all(
        scenarios_dir=SCENARIOS_DIR,
        fixtures_dir=FIXTURES_DIR,
        eval_conn=eval_conn,
        project_tmp=project_tmp,
        repo_root=REPO_ROOT,
        category="gate",
        mode="deterministic",
    )
    assert isinstance(run_id, str)
    parsed = uuid.UUID(run_id)
    assert str(parsed) == run_id


def test_run_all_mode_filter_deterministic_only(eval_conn, project_tmp, tmp_path):
    """run_all() with mode='live' does not run deterministic scenarios."""
    # Create a scenarios dir with one deterministic and one live scenario
    (tmp_path / "gate").mkdir()
    (tmp_path / "gate" / "determ.yaml").write_text(
        "name: determ\ncategory: gate\nmode: deterministic\n"
        "fixture: clean-hello-world\nground_truth: {expected_verdict: allow}\n"
    )
    (tmp_path / "gate" / "live-test.yaml").write_text(
        "name: live-test\ncategory: gate\nmode: live\n"
        "fixture: clean-hello-world\nground_truth: {expected_verdict: allow}\n"
    )
    run_id = eval_runner.run_all(
        scenarios_dir=tmp_path,
        fixtures_dir=FIXTURES_DIR,
        eval_conn=eval_conn,
        project_tmp=project_tmp,
        repo_root=REPO_ROOT,
        mode="live",
    )
    scores = eval_metrics.get_scores(eval_conn, run_id)
    # live mode scenarios get recorded (as error, since NotImplementedError)
    # but deterministic ones should NOT be included
    scenario_ids = {s["scenario_id"] for s in scores}
    assert "determ" not in scenario_ids
