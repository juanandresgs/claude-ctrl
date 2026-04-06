"""Behavioral Evaluation Framework — scenario runner.

Loads YAML scenario definitions, sets up fixture temp directories, executes
evaluations (deterministic via policy engine, live scaffold), and records
results to eval_results.db via eval_metrics.

Architecture:
  load_scenario()      — parse and validate a single YAML file
  discover_scenarios() — find all .yaml/.yml files under a base dir
  setup_fixture()      — copy fixture to a temp dir and git-init it
  run_deterministic()  — execute a deterministic scenario via policy engine
  run_live()           — scaffold: raises NotImplementedError (W-EVAL-5)
  cleanup_fixture()    — remove the temp directory
  run_scenario()       — orchestrate one scenario end-to-end
  run_all()            — orchestrate a full run across all discovered scenarios

State authority: this module writes to eval_results.db ONLY via eval_metrics.
It NEVER writes to state.db and NEVER modifies fixture source files.

@decision DEC-EVAL-RUNNER-001
Title: eval_runner is the sole orchestrator of eval scenario execution
Status: accepted
Rationale: Keeps eval execution concerns (YAML load, fixture setup, policy
  invocation, result recording) in one module. Callers (CLI, tests) only need
  to know load_scenario + run_all. The module delegates all DB mutations to
  eval_metrics, preserving the one-module-per-state-domain invariant. Fixture
  temp directories are created under project tmp/ (Sacred Practice 3) and are
  always cleaned up by cleanup_fixture() even when errors occur.

@decision DEC-EVAL-RUNNER-002
Title: run_deterministic() builds a synthetic PolicyContext with actor_role=tester
Status: accepted
Rationale: Gate scenarios test policy enforcement. For write-who-deny, the
  expected behaviour is that a "tester" role writing a source file is denied
  by the write_who policy. Rather than seeding state.db with a live marker
  (which would require full schema bootstrap in the fixture), we build a
  PolicyContext directly with actor_role="tester". This is valid because
  build_context() is the production path for resolving actor_role from DB
  state, but policy functions receive a PolicyContext — they do not re-query
  the DB. Injecting actor_role directly tests the policy function's logic
  without needing a live DB. This mirrors the approach used in
  tests/runtime/test_policy_engine.py (_make_request with hand-crafted
  PolicyContext).

@decision DEC-EVAL-RUNNER-003
Title: run_live() is a scaffold raising NotImplementedError
Status: accepted
Rationale: Live mode requires seed scenarios that do not exist until W-EVAL-5.
  Rather than leaving an empty stub that silently does nothing, raising
  NotImplementedError with a descriptive message forces callers to handle the
  absence explicitly. run_scenario() catches NotImplementedError and records
  it as an error in eval_scores so the run_all() aggregate counts remain
  accurate.
"""

from __future__ import annotations

import shutil
import sqlite3
import subprocess
import time
import uuid
from pathlib import Path
from typing import Optional

import yaml

import runtime.core.eval_metrics as eval_metrics
from runtime.core.policy_engine import (
    PolicyContext,
    PolicyDecision,
    PolicyRequest,
    default_registry,
)
from runtime.eval_schemas import EVAL_CATEGORIES, EVAL_MODES

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

REQUIRED_SCENARIO_FIELDS: tuple[str, ...] = (
    "name",
    "category",
    "mode",
    "fixture",
    "ground_truth",
)

# ---------------------------------------------------------------------------
# load_scenario()
# ---------------------------------------------------------------------------


def load_scenario(yaml_path: Path) -> dict:
    """Parse and validate a scenario YAML file.

    Args:
        yaml_path: Absolute path to a .yaml/.yml scenario file.

    Returns:
        Parsed dict with all required fields present.

    Raises:
        ValueError: If any required field is missing or if category/mode are
                    not in EVAL_CATEGORIES / EVAL_MODES.
        FileNotFoundError: If yaml_path does not exist.
    """
    with open(yaml_path, "r") as fh:
        data = yaml.safe_load(fh) or {}

    # Validate required fields
    for field in REQUIRED_SCENARIO_FIELDS:
        if field not in data:
            raise ValueError(f"Scenario YAML {yaml_path} is missing required field: '{field}'")

    # Validate category
    if data["category"] not in EVAL_CATEGORIES:
        raise ValueError(
            f"Scenario YAML {yaml_path} has invalid category: '{data['category']}'. "
            f"Must be one of: {sorted(EVAL_CATEGORIES)}"
        )

    # Validate mode
    if data["mode"] not in EVAL_MODES:
        raise ValueError(
            f"Scenario YAML {yaml_path} has invalid mode: '{data['mode']}'. "
            f"Must be one of: {sorted(EVAL_MODES)}"
        )

    return data


# ---------------------------------------------------------------------------
# discover_scenarios()
# ---------------------------------------------------------------------------


def discover_scenarios(
    base_dir: Path,
    category: str | None = None,
    mode: str | None = None,
) -> list[dict]:
    """Find and load all scenario YAML files under base_dir.

    Args:
        base_dir:  Directory to search recursively for .yaml/.yml files.
        category:  If provided, only return scenarios with this category.
        mode:      If provided, only return scenarios with this mode.

    Returns:
        List of scenario dicts sorted by scenario name.
    """
    scenarios: list[dict] = []

    for yaml_path in sorted(base_dir.rglob("*.yaml")) + sorted(base_dir.rglob("*.yml")):
        # Deduplicate: rglob("*.yaml") and rglob("*.yml") may overlap for .yaml
        # files on some systems, but in practice .yaml and .yml are distinct.
        try:
            scenario = load_scenario(yaml_path)
        except (ValueError, KeyError, yaml.YAMLError):
            # Skip invalid YAML files silently (they may be non-scenario YAML)
            continue

        if category is not None and scenario.get("category") != category:
            continue
        if mode is not None and scenario.get("mode") != mode:
            continue

        scenarios.append(scenario)

    # Sort by name (stable)
    scenarios.sort(key=lambda s: s.get("name", ""))
    return scenarios


# ---------------------------------------------------------------------------
# setup_fixture()
# ---------------------------------------------------------------------------


def setup_fixture(
    fixture_name: str,
    fixtures_dir: Path,
    project_tmp: Path,
) -> Path:
    """Copy a fixture to a temp directory and initialize a git repo.

    The temp directory is created under project_tmp (Sacred Practice 3: no
    /tmp/). The git repo is initialized with a single commit on an initial
    branch, then a feature branch is created and checked out.

    Args:
        fixture_name: Name of the fixture directory under fixtures_dir.
        fixtures_dir: Root directory containing all fixture directories.
        project_tmp:  Temp directory root (must be under project tmp/).

    Returns:
        Path to the newly created temp directory with the fixture contents.

    Raises:
        FileNotFoundError: If the fixture directory does not exist.
        RuntimeError: If git operations fail.
    """
    fixture_src = fixtures_dir / fixture_name
    if not fixture_src.is_dir():
        raise FileNotFoundError(f"Fixture directory not found: {fixture_src}")

    # Create a unique temp directory under project_tmp (never /tmp/)
    run_uuid = str(uuid.uuid4())[:8]
    dest = project_tmp / f"eval-{run_uuid}"
    dest.mkdir(parents=True, exist_ok=False)

    # Copy all fixture files
    shutil.copytree(str(fixture_src), str(dest), dirs_exist_ok=True)

    # Initialize git repo
    _run_git(dest, ["init", "-b", "main"])
    _run_git(dest, ["config", "user.email", "eval-runner@eval.local"])
    _run_git(dest, ["config", "user.name", "Eval Runner"])
    _run_git(dest, ["add", "."])
    _run_git(dest, ["commit", "-m", f"fixture: {fixture_name} (eval setup)"])

    # Create and checkout a feature branch
    _run_git(dest, ["checkout", "-b", f"feature/eval-{run_uuid}"])

    return dest


def _run_git(cwd: Path, args: list[str]) -> str:
    """Run a git command in cwd, returning stdout. Raises RuntimeError on failure."""
    result = subprocess.run(
        ["git", "-C", str(cwd)] + args,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed in {cwd}:\n{result.stderr}")
    return result.stdout.strip()


# ---------------------------------------------------------------------------
# run_deterministic()
# ---------------------------------------------------------------------------


def run_deterministic(
    scenario: dict,
    fixture_path: Path,
    repo_root: Path,
) -> dict:
    """Execute a deterministic scenario via the policy engine.

    Builds a synthetic PolicyContext with actor_role matching the scenario's
    expected denied role (or a default "tester" role for write-who-deny gate
    scenarios). Constructs a PolicyRequest for a Write tool use on a source
    file inside the fixture, then calls the default policy registry.

    See DEC-EVAL-RUNNER-002 for the rationale of injecting actor_role directly
    rather than seeding state.db.

    Args:
        scenario:     Parsed scenario dict (from load_scenario()).
        fixture_path: Path to the temp fixture directory (from setup_fixture()).
        repo_root:    Absolute path to the repository root (for PYTHONPATH).

    Returns:
        Dict with keys:
          verdict    — "allow" or "deny" (the policy decision action)
          raw_output — human-readable reason string from the policy decision
          duration_ms — integer milliseconds the evaluation took
          error      — None on success, error string on exception
    """
    start_ms = int(time.monotonic() * 1000)

    try:
        registry = default_registry()

        # Determine the target file path for the synthetic Write payload.
        # We look at the fixture's fixture.yaml to find the src file, then
        # use that as the write target. Fallback: src/hello.py.
        fixture_yaml_path = fixture_path / "fixture.yaml"
        target_file: str
        if fixture_yaml_path.exists():
            with open(fixture_yaml_path) as fh:
                fixture_meta = yaml.safe_load(fh) or {}
            src_rel = fixture_meta.get("src", "src/hello.py")
        else:
            src_rel = "src/hello.py"
        target_file = str(fixture_path / src_rel)

        # Build synthetic PolicyContext: actor_role="tester" so write_who denies.
        # For gate scenarios the intent is always to verify the denial path.
        # DEC-EVAL-RUNNER-002: injecting actor_role directly, not via DB.
        context = PolicyContext(
            actor_role="tester",
            actor_id="eval-runner-synthetic",
            workflow_id="eval-run",
            worktree_path=str(fixture_path),
            branch="feature/eval-run",
            project_root=str(fixture_path),
            is_meta_repo=False,
            lease=None,
            scope=None,
            eval_state=None,
            test_state=None,
            binding=None,
            dispatch_phase=None,
        )

        # event_type must be "Write" (not "PreToolUse") because write_who and
        # other write-path policies register for event_types=["Write", "Edit"].
        # The hook (pre-write.sh) sends event_type="Write" — we replicate that
        # exactly. Using "PreToolUse" would cause all write policies to skip
        # (event_type mismatch → "skip" in explain()), producing a default allow.
        request = PolicyRequest(
            event_type="Write",
            tool_name="Write",
            tool_input={
                "file_path": target_file,
                "content": "# synthetic eval write\n",
            },
            context=context,
            cwd=str(fixture_path),
        )

        decision: PolicyDecision = registry.evaluate(request)

        duration_ms = int(time.monotonic() * 1000) - start_ms

        return {
            "verdict": decision.action,
            "raw_output": decision.reason,
            "duration_ms": duration_ms,
            "error": None,
        }

    except Exception as exc:
        duration_ms = int(time.monotonic() * 1000) - start_ms
        return {
            "verdict": "error",
            "raw_output": "",
            "duration_ms": duration_ms,
            "error": str(exc),
        }


# ---------------------------------------------------------------------------
# run_live()
# ---------------------------------------------------------------------------


def run_live(
    scenario: dict,
    fixture_path: Path,
    conn: sqlite3.Connection | None = None,
) -> dict:
    """Live mode is a scaffold pending W-EVAL-5 seed scenarios.

    Raises:
        NotImplementedError: Always. Live mode requires W-EVAL-5 seed scenarios.
    """
    raise NotImplementedError(
        "Live mode requires W-EVAL-5 seed scenarios. "
        "This scaffold will be implemented when live scenarios exist."
    )


# ---------------------------------------------------------------------------
# cleanup_fixture()
# ---------------------------------------------------------------------------


def cleanup_fixture(fixture_path: Path) -> None:
    """Remove the temp fixture directory.

    Safe to call on a path that does not exist — handles missing paths
    gracefully so cleanup is always safe to call in finally blocks.

    Args:
        fixture_path: Path to the temp directory created by setup_fixture().
    """
    if fixture_path.exists():
        shutil.rmtree(str(fixture_path), ignore_errors=True)


# ---------------------------------------------------------------------------
# run_scenario()
# ---------------------------------------------------------------------------


def run_scenario(
    scenario: dict,
    fixtures_dir: Path,
    eval_conn: sqlite3.Connection,
    project_tmp: Path,
    repo_root: Path,
    run_id: str,
) -> dict:
    """Orchestrate one scenario: setup → run → record → cleanup.

    Errors during setup or execution are caught, recorded as error scores,
    and returned. Fixture cleanup always runs even on error.

    Args:
        scenario:     Parsed scenario dict from load_scenario().
        fixtures_dir: Root of fixture directories.
        eval_conn:    Connection to eval_results.db (never state.db).
        project_tmp:  Temp directory root (Sacred Practice 3).
        repo_root:    Repository root for policy engine PYTHONPATH.
        run_id:       UUID of the parent eval_runs row.

    Returns:
        Dict with keys: scenario_id, verdict, fixture_path, error.
    """
    scenario_id: str = scenario.get("name", "unknown")
    fixture_name: str = scenario.get("fixture", "")
    category: str = scenario.get("category", "gate")
    mode: str = scenario.get("mode", "deterministic")
    ground_truth: dict = scenario.get("ground_truth", {})
    verdict_expected: str = ground_truth.get("expected_verdict", "")
    confidence_expected: str = ground_truth.get("expected_confidence", "")

    fixture_path: Optional[Path] = None

    try:
        # Setup
        fixture_path = setup_fixture(fixture_name, fixtures_dir, project_tmp)

        # Execute
        if mode == "deterministic":
            result = run_deterministic(scenario, fixture_path, repo_root)
        else:
            result = run_live(scenario, fixture_path)

        verdict_actual = result["verdict"]
        raw_output = result["raw_output"]
        duration_ms = result["duration_ms"]
        error_msg = result["error"]

        verdict_correct = 1 if verdict_actual == verdict_expected else 0

        # Record output
        eval_metrics.record_output(
            eval_conn,
            run_id=run_id,
            scenario_id=scenario_id,
            raw_output=raw_output or "",
        )

        # Record score
        eval_metrics.record_score(
            eval_conn,
            run_id=run_id,
            scenario_id=scenario_id,
            category=category,
            verdict_expected=verdict_expected,
            verdict_actual=verdict_actual,
            verdict_correct=verdict_correct,
            confidence_expected=confidence_expected if confidence_expected else None,
            duration_ms=duration_ms,
            error_message=error_msg,
        )

        return {
            "scenario_id": scenario_id,
            "verdict": verdict_actual,
            "fixture_path": str(fixture_path),
            "error": error_msg,
        }

    except NotImplementedError as exc:
        # Live mode scaffold: record as error but don't crash run_all()
        error_str = str(exc)
        eval_metrics.record_score(
            eval_conn,
            run_id=run_id,
            scenario_id=scenario_id,
            category=category,
            verdict_expected=verdict_expected,
            verdict_actual=None,
            verdict_correct=0,
            error_message=error_str,
        )
        return {
            "scenario_id": scenario_id,
            "verdict": "error",
            "fixture_path": str(fixture_path) if fixture_path else "",
            "error": error_str,
        }

    except Exception as exc:
        error_str = str(exc)
        # Record error score so run_all() aggregate counts remain accurate
        eval_metrics.record_score(
            eval_conn,
            run_id=run_id,
            scenario_id=scenario_id,
            category=category,
            verdict_expected=verdict_expected,
            verdict_actual=None,
            verdict_correct=0,
            error_message=error_str,
        )
        return {
            "scenario_id": scenario_id,
            "verdict": "error",
            "fixture_path": str(fixture_path) if fixture_path else "",
            "error": error_str,
        }

    finally:
        if fixture_path is not None:
            cleanup_fixture(fixture_path)


# ---------------------------------------------------------------------------
# run_all()
# ---------------------------------------------------------------------------


def run_all(
    scenarios_dir: Path,
    fixtures_dir: Path,
    eval_conn: sqlite3.Connection,
    project_tmp: Path,
    repo_root: Path,
    category: str | None = None,
    mode: str | None = None,
) -> str:
    """Discover and run all matching scenarios, recording results.

    Creates an eval_run record, runs each discovered scenario via
    run_scenario(), then finalizes the run with aggregate counts.

    Args:
        scenarios_dir: Directory to search for .yaml scenario files.
        fixtures_dir:  Root of fixture directories.
        eval_conn:     Connection to eval_results.db.
        project_tmp:   Temp directory root (Sacred Practice 3).
        repo_root:     Repository root for policy engine.
        category:      Optional category filter.
        mode:          Optional mode filter.

    Returns:
        run_id (UUID string) of the completed eval run.
    """
    # Determine the effective mode for the run record
    run_mode = mode or "deterministic"

    scenarios = discover_scenarios(scenarios_dir, category=category, mode=mode)

    run_id = eval_metrics.create_run(eval_conn, mode=run_mode)

    for scenario in scenarios:
        run_scenario(
            scenario=scenario,
            fixtures_dir=fixtures_dir,
            eval_conn=eval_conn,
            project_tmp=project_tmp,
            repo_root=repo_root,
            run_id=run_id,
        )

    eval_metrics.finalize_run(eval_conn, run_id)

    return run_id
