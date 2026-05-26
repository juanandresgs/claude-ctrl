#!/usr/bin/env python3
"""Judgment evaluation: run the tester agent against fixtures with known defects.

Usage:
    python3 scripts/eval_judgment.py                        # Run all scenarios
    python3 scripts/eval_judgment.py --scenario dual-authority-detection
    python3 scripts/eval_judgment.py --category judgment
    python3 scripts/eval_judgment.py --dry-run               # Show what would run

Set TESTER_CMD to override how the tester agent is invoked:
    TESTER_CMD="claude -p" python3 scripts/eval_judgment.py

Results are printed to stdout and saved to tmp/eval-results.json.

@decision DEC-EVAL-JUDGMENT-001
Title: eval_judgment.py is a self-contained replacement for the bloated eval_runner infrastructure
Status: accepted
Rationale: The prior infrastructure (~8,400 lines) handled deterministic gate scenarios via
  a full policy-engine pipeline, SQLite result recording, and a live-mode scaffold that always
  raised NotImplementedError. The judgment + adversarial scenarios are exclusively live-mode —
  they require a tester agent to read source code and form a verdict. This script replaces the
  live-mode stub with a real implementation: copy fixture, build prompt, invoke claude CLI,
  parse EVAL_VERDICT trailer, check against expected. No SQLite. Results go to stdout + JSON.
  Zero imports from runtime/core/eval_*. Fully self-contained so it can be run by anyone
  without the full runtime stack.

@decision DEC-EVAL-JUDGMENT-002
Title: Fixture temp dirs go under project tmp/, never /tmp/
Status: accepted
Rationale: Sacred Practice #3. Using /tmp/ would litter the user's machine and violate
  the project convention. Project tmp/ is .gitignored and is the correct home for
  short-lived evaluation artifacts.

@decision DEC-EVAL-JUDGMENT-003
Title: TESTER_CMD env var allows override without code changes
Status: accepted
Rationale: The tester is invoked via the claude CLI by default. In CI or when testing the
  script itself, callers may want to substitute an echo stub or a different model/flags.
  Env var override is the simplest, least-invasive contract for that without adding flags
  or config files. The default is "claude -p" (print mode, non-interactive).

@decision DEC-EVAL-JUDGMENT-004
Title: Scenario YAML format is flattened — no nested ground_truth, scoring, evaluation_contract
Status: accepted
Rationale: The old format had 5+ nested sections (ground_truth, scoring, evaluation_contract,
  authority_invariants, forbidden_shortcuts). Only name, fixture, expected_verdict, must_mention,
  must_cite, and description are load-bearing for the judgment runner. The rest were either dead
  data (scoring weights were never used for live mode) or duplicated EVAL_CONTRACT.md content
  (evaluation_contract section). Flattening removes the duplication and makes each YAML trivially
  readable in one glance.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Optional

import yaml

# ---------------------------------------------------------------------------
# Path anchors
# ---------------------------------------------------------------------------

# Repo root: two parents up from scripts/eval_judgment.py
_REPO_ROOT = Path(__file__).resolve().parent.parent
_SCENARIOS_DIR = _REPO_ROOT / "evals" / "scenarios"
_FIXTURES_DIR = _REPO_ROOT / "evals" / "fixtures"
_TESTER_PROMPT_PATH = _REPO_ROOT / "agents" / "tester.md"
_TMP_DIR = _REPO_ROOT / "tmp"
_RESULTS_PATH = _TMP_DIR / "eval-results.json"

# ---------------------------------------------------------------------------
# load_scenario()
# ---------------------------------------------------------------------------

REQUIRED_SCENARIO_FIELDS = ("name", "fixture", "expected_verdict")


def load_scenario(yaml_path: Path) -> dict:
    """Load and validate a scenario YAML file.

    Required fields: name, fixture, expected_verdict.
    Optional: must_mention (list), must_cite (list), description (str).

    Args:
        yaml_path: Path to the .yaml scenario file.

    Returns:
        Parsed dict with at minimum the required fields present.

    Raises:
        ValueError: If a required field is missing.
        FileNotFoundError: If yaml_path does not exist.
        yaml.YAMLError: If the file is not valid YAML.
    """
    with open(yaml_path, "r") as fh:
        data = yaml.safe_load(fh) or {}

    for field in REQUIRED_SCENARIO_FIELDS:
        if field not in data:
            raise ValueError(f"Scenario {yaml_path.name} is missing required field: '{field}'")

    # Normalise optional list fields so callers never need None-guards
    data.setdefault("must_mention", [])
    data.setdefault("must_cite", [])
    data.setdefault("description", "")

    # Attach the source path so callers can report it
    data["_yaml_path"] = str(yaml_path)

    # Derive category from the parent directory name (e.g. "judgment", "adversarial")
    data.setdefault("category", yaml_path.parent.name)

    return data


# ---------------------------------------------------------------------------
# discover_scenarios()
# ---------------------------------------------------------------------------


def discover_scenarios(
    scenarios_dir: Path,
    category: Optional[str] = None,
    name: Optional[str] = None,
) -> list[dict]:
    """Find all .yaml scenario files under scenarios_dir.

    Skips .gitkeep and any file that fails load_scenario() validation —
    those are non-scenario YAML files (e.g. fixture.yaml inside a fixture dir).

    Args:
        scenarios_dir: Root directory to search recursively.
        category:      If set, only return scenarios whose derived category matches.
        name:          If set, only return the scenario with this name.

    Returns:
        List of scenario dicts sorted by (category, name).
    """
    scenarios: list[dict] = []

    for yaml_path in sorted(scenarios_dir.rglob("*.yaml")):
        if yaml_path.name == ".gitkeep":
            continue
        try:
            scenario = load_scenario(yaml_path)
        except (ValueError, KeyError, yaml.YAMLError):
            # Not a valid judgment scenario — skip silently
            continue

        if category is not None and scenario.get("category") != category:
            continue
        if name is not None and scenario.get("name") != name:
            continue

        scenarios.append(scenario)

    scenarios.sort(key=lambda s: (s.get("category", ""), s.get("name", "")))
    return scenarios


# ---------------------------------------------------------------------------
# setup_fixture()
# ---------------------------------------------------------------------------


def setup_fixture(fixture_name: str, fixtures_dir: Path) -> Path:
    """Copy fixture to tmp/eval-<name>-<pid>/, init git, return the path.

    The temp directory is created under the project tmp/ directory
    (DEC-EVAL-JUDGMENT-002: never /tmp/). A git repo is initialized with one
    commit on main, then a feature branch is checked out.

    Args:
        fixture_name: Directory name under fixtures_dir.
        fixtures_dir: Root directory that contains fixture directories.

    Returns:
        Path to the temp directory containing the fixture copy.

    Raises:
        FileNotFoundError: If the fixture directory does not exist.
        RuntimeError: If git operations fail.
    """
    fixture_src = fixtures_dir / fixture_name
    if not fixture_src.is_dir():
        raise FileNotFoundError(f"Fixture not found: {fixture_src}")

    dest = _TMP_DIR / f"eval-{fixture_name}-{os.getpid()}"
    if dest.exists():
        shutil.rmtree(str(dest))
    dest.mkdir(parents=True)

    shutil.copytree(
        str(fixture_src),
        str(dest),
        dirs_exist_ok=True,
        ignore=shutil.ignore_patterns("__pycache__", "*.pyc", ".git"),
    )

    # Init git repo so the tester can run git commands
    _git(dest, ["init", "-b", "main"])
    _git(dest, ["config", "user.email", "eval-judgment@eval.local"])
    _git(dest, ["config", "user.name", "Eval Judgment"])
    _git(dest, ["add", "."])
    _git(dest, ["commit", "-m", f"fixture: {fixture_name}"])
    _git(dest, ["checkout", "-b", f"feature/eval-{fixture_name}"])

    return dest


def _git(cwd: Path, args: list[str]) -> str:
    """Run a git command, returning stdout. Raises RuntimeError on failure."""
    result = subprocess.run(
        ["git", "-C", str(cwd)] + args,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed in {cwd}:\n{result.stderr.strip()}")
    return result.stdout.strip()


# ---------------------------------------------------------------------------
# build_prompt()
# ---------------------------------------------------------------------------


def build_prompt(
    fixture_path: Path,
    scenario: dict,
    tester_prompt_path: Path,
) -> str:
    """Build the full prompt to send to the tester agent.

    Concatenates:
    1. Content of tester.md (the tester agent system prompt)
    2. The EVAL_CONTRACT.md from the fixture
    3. Scenario description
    4. Repository context (fixture path + HEAD SHA)
    5. Evaluation instructions

    Args:
        fixture_path:       Path to the temp fixture directory (from setup_fixture).
        scenario:           Parsed scenario dict.
        tester_prompt_path: Path to agents/tester.md.

    Returns:
        Multi-section prompt string.
    """
    # 1. Tester system prompt
    tester_content = tester_prompt_path.read_text()

    # 2. EVAL_CONTRACT.md from the fixture
    contract_path = fixture_path / "EVAL_CONTRACT.md"
    if contract_path.exists():
        contract_content = contract_path.read_text()
    else:
        contract_content = "(No EVAL_CONTRACT.md found in this fixture.)"

    # 3. Scenario description
    description = scenario.get("description", "").strip()
    if not description:
        description = f"Evaluate the {scenario['name']} fixture."

    # 4. HEAD SHA for the fixture repo
    try:
        head_sha = _git(fixture_path, ["rev-parse", "HEAD"])
    except RuntimeError:
        head_sha = "unknown"

    parts = [
        tester_content,
        "",
        "## Evaluation Contract",
        "",
        contract_content,
        "",
        "## Scenario",
        "",
        description,
        "",
        "## Repository",
        "",
        f"Fixture path: {fixture_path}",
        f"HEAD SHA: {head_sha}",
        f"Branch: feature/eval-{scenario['fixture']}",
        "",
        "## Instructions",
        "",
        "Evaluate the implementation in the repository above against the Evaluation Contract.",
        "Apply all three verification tiers (Tests, Production Reality, Dual-Authority Audit).",
        "End your response with the EVAL_VERDICT trailer block exactly as specified.",
    ]

    return "\n".join(parts)


# ---------------------------------------------------------------------------
# run_tester()
# ---------------------------------------------------------------------------


def run_tester(fixture_path: Path, prompt: str) -> tuple[str, int]:
    """Invoke the tester agent with the given prompt.

    Uses TESTER_CMD env var if set (DEC-EVAL-JUDGMENT-003), otherwise
    defaults to: claude -p "<prompt>" --cwd <fixture_path>

    If neither TESTER_CMD is set nor `claude` is on PATH, prints a helpful
    error and returns an error sentinel.

    Args:
        fixture_path: Working directory to pass to the tester.
        prompt:       Full prompt string to send.

    Returns:
        (stdout_text, return_code) tuple.
    """
    tester_cmd = os.environ.get("TESTER_CMD", "").strip()

    if tester_cmd:
        # Custom command: treat as a shell command prefix, append --cwd and prompt
        cmd = tester_cmd.split() + [prompt, "--cwd", str(fixture_path)]
    else:
        # Default: claude CLI
        claude_bin = shutil.which("claude")
        if claude_bin is None:
            msg = (
                "ERROR: 'claude' CLI not found on PATH and TESTER_CMD is not set.\n"
                "Install the claude CLI or set TESTER_CMD to a stub command.\n"
                "Example: TESTER_CMD='echo' python3 scripts/eval_judgment.py --dry-run"
            )
            print(msg, file=sys.stderr)
            return (msg, 1)
        cmd = [claude_bin, "-p", prompt, "--cwd", str(fixture_path)]

    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=300,  # 5-minute per-scenario ceiling
    )

    # Combine stdout + stderr so parsing sees full agent output
    output = result.stdout
    if result.stderr:
        output += "\n" + result.stderr

    return (output, result.returncode)


# ---------------------------------------------------------------------------
# parse_verdict()
# ---------------------------------------------------------------------------

# Regex patterns for the four trailer fields
_VERDICT_RE = re.compile(
    r"^EVAL_VERDICT:\s*(needs_changes|ready_for_guardian|blocked_by_plan)\s*$",
    re.MULTILINE,
)
_TESTS_PASS_RE = re.compile(
    r"^EVAL_TESTS_PASS:\s*(true|false)\s*$",
    re.MULTILINE,
)
_NEXT_ROLE_RE = re.compile(
    r"^EVAL_NEXT_ROLE:\s*(implementer|guardian|planner)\s*$",
    re.MULTILINE,
)
_HEAD_SHA_RE = re.compile(
    r"^EVAL_HEAD_SHA:\s*([a-f0-9]{7,40}|unknown)\s*$",
    re.MULTILINE,
)


def parse_verdict(output: str) -> dict:
    """Extract EVAL_VERDICT trailer fields from tester output.

    Args:
        output: Full stdout from the tester agent.

    Returns:
        Dict with keys: verdict, tests_pass, next_role, head_sha.
        Each value is the parsed string or None if the field was absent.
    """
    verdict_match = _VERDICT_RE.search(output)
    tests_pass_match = _TESTS_PASS_RE.search(output)
    next_role_match = _NEXT_ROLE_RE.search(output)
    head_sha_match = _HEAD_SHA_RE.search(output)

    return {
        "verdict": verdict_match.group(1) if verdict_match else None,
        "tests_pass": tests_pass_match.group(1) if tests_pass_match else None,
        "next_role": next_role_match.group(1) if next_role_match else None,
        "head_sha": head_sha_match.group(1) if head_sha_match else None,
    }


# ---------------------------------------------------------------------------
# check_result()
# ---------------------------------------------------------------------------


def check_result(output: str, verdict: dict, scenario: dict) -> dict:
    """Compare tester output against expected scenario results.

    Args:
        output:   Full tester stdout text.
        verdict:  Parsed trailer dict from parse_verdict().
        scenario: Scenario dict (provides expected_verdict, must_mention, must_cite).

    Returns:
        Dict with keys:
          verdict_match      — bool: actual verdict == expected_verdict
          keywords_found     — list[str]: must_mention items found in output
          keywords_missing   — list[str]: must_mention items NOT found in output
          citations_found    — list[str]: must_cite items found in output
          citations_missing  — list[str]: must_cite items NOT found in output
          pass               — bool: verdict matches AND no required keywords missing
    """
    expected = scenario.get("expected_verdict", "")
    actual = verdict.get("verdict")
    verdict_match = actual == expected

    # Keyword check (case-insensitive substring search)
    output_lower = output.lower()
    keywords_found = []
    keywords_missing = []
    for kw in scenario.get("must_mention", []):
        if kw.lower() in output_lower:
            keywords_found.append(kw)
        else:
            keywords_missing.append(kw)

    # Citation check (look for file path / name in output)
    citations_found = []
    citations_missing = []
    for cite in scenario.get("must_cite", []):
        if cite in output:
            citations_found.append(cite)
        else:
            citations_missing.append(cite)

    passed = verdict_match and not keywords_missing and not citations_missing

    return {
        "verdict_match": verdict_match,
        "keywords_found": keywords_found,
        "keywords_missing": keywords_missing,
        "citations_found": citations_found,
        "citations_missing": citations_missing,
        "pass": passed,
    }


# ---------------------------------------------------------------------------
# cleanup()
# ---------------------------------------------------------------------------


def cleanup(fixture_path: Path) -> None:
    """Remove the temp fixture directory.

    Safe to call on a path that does not exist.

    Args:
        fixture_path: Path returned by setup_fixture().
    """
    if fixture_path and fixture_path.exists():
        shutil.rmtree(str(fixture_path), ignore_errors=True)


# ---------------------------------------------------------------------------
# run_one()
# ---------------------------------------------------------------------------


def run_one(
    scenario: dict,
    fixtures_dir: Path,
    tester_prompt: Path,
    dry_run: bool,
) -> dict:
    """Orchestrate one scenario end-to-end.

    Sequence: setup_fixture → build_prompt → run_tester → parse_verdict →
    check_result → cleanup.

    In dry-run mode, prints the prompt and returns a synthetic result without
    invoking the tester agent.

    Args:
        scenario:      Parsed scenario dict.
        fixtures_dir:  Root fixture directory.
        tester_prompt: Path to agents/tester.md.
        dry_run:       If True, skip tester invocation.

    Returns:
        Result dict suitable for JSON serialisation and table printing.
    """
    name = scenario["name"]
    fixture_name = scenario["fixture"]
    fixture_path: Optional[Path] = None

    try:
        fixture_path = setup_fixture(fixture_name, fixtures_dir)
        prompt = build_prompt(fixture_path, scenario, tester_prompt)

        if dry_run:
            print(f"\n--- DRY RUN: {name} ---")
            print(f"Fixture: {fixture_path}")
            print(f"Expected verdict: {scenario['expected_verdict']}")
            print(f"Must mention: {scenario.get('must_mention', [])}")
            print(f"Must cite: {scenario.get('must_cite', [])}")
            print(f"Prompt length: {len(prompt)} chars")
            print("--- END DRY RUN ---")
            return {
                "scenario": name,
                "category": scenario.get("category", ""),
                "fixture": fixture_name,
                "expected_verdict": scenario["expected_verdict"],
                "actual_verdict": None,
                "verdict_match": None,
                "keywords_found": [],
                "keywords_missing": [],
                "citations_found": [],
                "citations_missing": [],
                "pass": None,
                "dry_run": True,
                "error": None,
            }

        output, return_code = run_tester(fixture_path, prompt)
        parsed = parse_verdict(output)
        check = check_result(output, parsed, scenario)

        return {
            "scenario": name,
            "category": scenario.get("category", ""),
            "fixture": fixture_name,
            "expected_verdict": scenario["expected_verdict"],
            "actual_verdict": parsed["verdict"],
            "verdict_match": check["verdict_match"],
            "keywords_found": check["keywords_found"],
            "keywords_missing": check["keywords_missing"],
            "citations_found": check["citations_found"],
            "citations_missing": check["citations_missing"],
            "pass": check["pass"],
            "tester_return_code": return_code,
            "raw_output_excerpt": output[-2000:] if len(output) > 2000 else output,
            "dry_run": False,
            "error": None if return_code == 0 else f"tester exited {return_code}",
        }

    except Exception as exc:
        return {
            "scenario": name,
            "category": scenario.get("category", ""),
            "fixture": fixture_name,
            "expected_verdict": scenario.get("expected_verdict"),
            "actual_verdict": None,
            "verdict_match": False,
            "keywords_found": [],
            "keywords_missing": [],
            "citations_found": [],
            "citations_missing": [],
            "pass": False,
            "dry_run": dry_run,
            "error": str(exc),
        }

    finally:
        if fixture_path is not None:
            cleanup(fixture_path)


# ---------------------------------------------------------------------------
# main()
# ---------------------------------------------------------------------------


def main() -> None:
    """Parse args, discover scenarios, run each, print table, save JSON."""
    parser = argparse.ArgumentParser(
        description="Run the tester agent against eval fixtures and check verdicts."
    )
    parser.add_argument(
        "--scenario",
        metavar="NAME",
        help="Run only the scenario with this name.",
    )
    parser.add_argument(
        "--category",
        metavar="CATEGORY",
        help="Run only scenarios in this category (e.g. judgment, adversarial).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Discover scenarios and build prompts without invoking the tester.",
    )
    parser.add_argument(
        "--scenarios-dir",
        metavar="DIR",
        default=str(_SCENARIOS_DIR),
        help=f"Scenario YAML directory (default: {_SCENARIOS_DIR})",
    )
    parser.add_argument(
        "--fixtures-dir",
        metavar="DIR",
        default=str(_FIXTURES_DIR),
        help=f"Fixtures directory (default: {_FIXTURES_DIR})",
    )
    args = parser.parse_args()

    scenarios_dir = Path(args.scenarios_dir)
    fixtures_dir = Path(args.fixtures_dir)

    scenarios = discover_scenarios(
        scenarios_dir,
        category=args.category,
        name=args.scenario,
    )

    if not scenarios:
        print("No scenarios found matching the given filters.", file=sys.stderr)
        sys.exit(1)

    print(f"\nJudgment Evaluation{' (DRY RUN)' if args.dry_run else ''}")
    print(f"Scenarios: {len(scenarios)}")
    print("=" * 60)

    results = []
    for scenario in scenarios:
        result = run_one(
            scenario=scenario,
            fixtures_dir=fixtures_dir,
            tester_prompt=_TESTER_PROMPT_PATH,
            dry_run=args.dry_run,
        )
        results.append(result)

        # Print result row immediately (streaming progress)
        _print_row(result)

    print("=" * 60)
    _print_summary(results, dry_run=args.dry_run)

    # Persist to tmp/eval-results.json
    _TMP_DIR.mkdir(parents=True, exist_ok=True)
    with open(_RESULTS_PATH, "w") as fh:
        json.dump(results, fh, indent=2, default=str)
    print(f"\nResults saved to: {_RESULTS_PATH}")


def _print_row(result: dict) -> None:
    """Print one result row in the summary table format."""
    name = result["scenario"]
    category = result.get("category", "")
    expected = result.get("expected_verdict", "?")
    actual = result.get("actual_verdict")
    is_pass = result.get("pass")
    is_dry = result.get("dry_run")
    error = result.get("error")

    kw_found = len(result.get("keywords_found", []))
    kw_total = kw_found + len(result.get("keywords_missing", []))
    cite_found = len(result.get("citations_found", []))
    cite_total = cite_found + len(result.get("citations_missing", []))

    if is_dry:
        status = " DRY "
        verdict_info = f"[{expected}]"
    elif error and actual is None:
        status = " ERR "
        verdict_info = f"ERROR: {error[:60]}"
    elif is_pass:
        status = " PASS"
        verdict_info = f"[{actual}]"
    else:
        status = " FAIL"
        if actual is None:
            verdict_info = f"[no verdict] expected [{expected}]"
        elif actual != expected:
            verdict_info = f"[{actual} != {expected}]"
        else:
            verdict_info = f"[{actual}]"

    keyword_str = f"keywords: {kw_found}/{kw_total}" if kw_total > 0 else ""
    citation_str = f"citations: {cite_found}/{cite_total}" if cite_total > 0 else ""
    extras = "  ".join(x for x in [keyword_str, citation_str] if x)

    row = f"  {status}  {category}/{name:<40} {verdict_info}"
    if extras:
        row += f"  {extras}"
    print(row)


def _print_summary(results: list[dict], dry_run: bool) -> None:
    """Print aggregate pass/fail counts."""
    if dry_run:
        print(f"\nDry run complete. {len(results)} scenario(s) discovered.")
        return

    total = len(results)
    passed = sum(1 for r in results if r.get("pass"))
    failed = sum(1 for r in results if r.get("pass") is False and not r.get("error"))
    errors = sum(1 for r in results if r.get("error") and r.get("actual_verdict") is None)

    pct = int(100 * passed / total) if total else 0
    print(f"\nResults: {passed}/{total} pass ({pct}%)")
    if failed:
        print(f"  Failed:  {failed}")
    if errors:
        print(f"  Errors:  {errors}")


if __name__ == "__main__":
    main()
