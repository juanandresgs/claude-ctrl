#!/usr/bin/env python3
"""Dispatch file construction and state preparation utilities for bazaar skill.

@decision DEC-BAZAAR-013
@title Disk-based state passing — agent reads only BLUFs, Python scripts handle data plumbing
@status accepted
@rationale The forked bazaar agent stalls at Phase 3 because constructing dispatch
JSON inline requires the agent to load and process large data blobs (scenario lists,
obsessive outputs) directly into its context. This script externalizes all data
plumbing: it reads artifacts from disk, constructs dispatch files, and writes them
back to disk. The agent's only job is to call this script and then read the
resulting BLUF. This satisfies REQ-P0-007 (agent reads only BLUFs), REQ-P0-008
(no full JSON reads between phases), and REQ-GOAL-004 (all 6 phases complete
autonomously). The script is idempotent — running it twice produces identical output.

Usage:
    bazaar_prepare.py ideation <output_dir> <providers_json_path>
    bazaar_prepare.py funding <output_dir> <providers_json_path>
    bazaar_prepare.py analysis <output_dir> <providers_json_path>
    bazaar_prepare.py dedup <output_dir>
    bazaar_prepare.py collect-analysts <output_dir>
    bazaar_prepare.py init <output_dir> <question> <providers_json_path>

Outputs (written to output_dir):
    ideation    -> ideation_dispatches.json
    funding     -> judge_dispatches.json
    analysis    -> analyst_dispatches.json
    dedup       -> all_scenarios.json (deduped from ideators/*.json)
    collect-analysts -> analyst_outputs.json (collected from analysts/*.json)
    init        -> bazaar-manifest.json (initial skeleton)
"""

import glob
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


# ── Path setup ────────────────────────────────────────────────────────────────

SCRIPT_DIR = Path(__file__).parent


def _find_claude_root() -> Path:
    """Walk up from this file to find ~/.claude (CLAUDE.md anchor).

    See DEC-BAZAAR-010 in bazaar_dispatch.py for rationale.
    """
    candidate = Path(__file__).resolve().parent
    while candidate != candidate.parent:
        if (candidate / "CLAUDE.md").exists():
            return candidate
        candidate = candidate.parent
    return candidate


CLAUDE_ROOT = _find_claude_root()
ARCHETYPES_DIR = CLAUDE_ROOT / "skills" / "bazaar" / "archetypes"
SKILL_DIR = CLAUDE_ROOT / "skills" / "bazaar"


# ── Provider config helpers ────────────────────────────────────────────────────

def _load_providers(providers_json_path: Path) -> Dict[str, Any]:
    """Load providers.json and return the full config dict."""
    with open(providers_json_path) as f:
        return json.load(f)


def _available_providers(providers_json_path: Path) -> Dict[str, bool]:
    """Detect which providers have API keys available.

    Checks environment variables matching each provider's env_key.
    Returns {provider_name: bool} dict.
    """
    import os
    config = _load_providers(providers_json_path)
    providers = config.get("providers", {})
    return {
        name: bool(os.environ.get(p["env_key"], ""))
        for name, p in providers.items()
    }


def _resolve_provider(
    archetype: str,
    providers_config: Dict[str, Any],
    available: Dict[str, bool],
) -> Tuple[str, str]:
    """Resolve the provider and model for an archetype, with fallback to anthropic.

    Args:
        archetype: Archetype name (e.g., 'methodical', 'contrarian')
        providers_config: Full providers.json config dict
        available: Dict of {provider_name: is_available}

    Returns:
        (provider_name, model_name) tuple
    """
    assignments = providers_config.get("archetype_assignments", {})
    providers = providers_config.get("providers", {})

    desired_provider = assignments.get(archetype, "anthropic")

    # Fallback to anthropic if desired provider unavailable
    if not available.get(desired_provider, False):
        desired_provider = "anthropic"

    provider_cfg = providers.get(desired_provider, {})
    model = provider_cfg.get("default_model", "claude-opus-4-6")

    return desired_provider, model


# ── Subcommand: init ───────────────────────────────────────────────────────────

def cmd_init(output_dir: Path, question: str, providers_json_path: Path) -> None:
    """Create initial bazaar-manifest.json with question, start time, providers.

    This is called at the beginning of a run to establish the manifest before
    any phases execute. Subsequent bazaar_summarize.py calls will update it.

    Args:
        output_dir: The bazaar run output directory (will be created if needed)
        question: The analytical question being investigated
        providers_json_path: Path to providers.json
    """
    output_dir.mkdir(parents=True, exist_ok=True)
    available = _available_providers(providers_json_path)

    manifest = {
        "question": question,
        "started": datetime.now(timezone.utc).isoformat(),
        "completed": None,
        "output_dir": str(output_dir.resolve()),
        "providers": available,
        "phases": {},
        "report_path": None,
        "word_count": None,
        "scenarios_funded": None,
    }

    manifest_path = output_dir / "bazaar-manifest.json"
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)

    print(f"Initialized manifest: {manifest_path}")
    print(f"Question: {question[:80]}...")
    available_list = [p for p, ok in available.items() if ok]
    print(f"Providers available: {', '.join(available_list)}")


# ── Subcommand: ideation ───────────────────────────────────────────────────────

# Archetype definitions: name → archetype file stem
IDEATOR_ARCHETYPES = [
    "methodical",
    "contrarian",
    "pattern-matcher",
    "edge-case-hunter",
    "systems-thinker",
]


def cmd_ideation(output_dir: Path, providers_json_path: Path) -> None:
    """Build ideation_dispatches.json from archetype paths + providers.

    Reads brief.md for the question and brief content. Applies provider
    degradation rules from providers.json. Writes ideation_dispatches.json.

    Args:
        output_dir: The bazaar run output directory
        providers_json_path: Path to providers.json
    """
    providers_config = _load_providers(providers_json_path)
    available = _available_providers(providers_json_path)

    # Read brief
    brief_path = output_dir / "brief.md"
    if brief_path.exists():
        brief_content = brief_path.read_text()
    else:
        brief_content = "(no brief available)"

    # Extract question from brief
    question = ""
    for line in brief_content.splitlines():
        if line.strip().startswith("**Question**:"):
            question = line.strip().split(":", 1)[-1].strip()
            break
    if not question:
        question = "(see brief.md)"

    user_prompt_template = (
        "Analytical question: {question}\n\nBrief:\n{brief}"
    )

    dispatches = []
    for archetype in IDEATOR_ARCHETYPES:
        provider, model = _resolve_provider(archetype, providers_config, available)
        archetype_file = ARCHETYPES_DIR / "ideators" / f"{archetype}.md"

        dispatch = {
            "id": archetype,
            "provider": provider,
            "model": model,
            "system_prompt_file": str(archetype_file),
            "user_prompt": user_prompt_template.format(
                question=question,
                brief=brief_content,
            ),
            "output_file": str(output_dir / "ideators" / f"{archetype}.json"),
        }
        dispatches.append(dispatch)

    output_path = output_dir / "ideation_dispatches.json"
    with open(output_path, "w") as f:
        json.dump({"dispatches": dispatches}, f, indent=2)

    print(f"Wrote {len(dispatches)} ideation dispatches to {output_path}")
    for d in dispatches:
        print(f"  {d['id']}: {d['provider']}/{d['model']}")


# ── Subcommand: dedup ──────────────────────────────────────────────────────────

def cmd_dedup(output_dir: Path) -> None:
    """Deduplicate scenarios from ideators/*.json and write all_scenarios.json.

    Reads all ideator output files, collects scenarios, deduplicates by ID,
    and writes the canonical all_scenarios.json used by Phase 3.

    Args:
        output_dir: The bazaar run output directory
    """
    ideator_paths = sorted(glob.glob(str(output_dir / "ideators" / "*.json")))
    ideator_paths = [p for p in ideator_paths if not Path(p).name.startswith("dispatch_")]

    scenarios: List[Dict] = []
    seen_ids: set = set()
    skipped = 0

    for path in ideator_paths:
        try:
            with open(path) as f:
                data = json.load(f)
            parsed = data.get("parsed") or {}
            for s in parsed.get("scenarios", []):
                sid = s.get("id", "")
                if sid and sid not in seen_ids:
                    scenarios.append(s)
                    seen_ids.add(sid)
        except Exception as e:
            print(f"Skipping {path}: {e}", file=sys.stderr)
            skipped += 1

    output_path = output_dir / "all_scenarios.json"
    with open(output_path, "w") as f:
        json.dump({"scenarios": scenarios}, f, indent=2)

    print(f"Collected {len(scenarios)} unique scenarios from {len(ideator_paths)} ideators")
    if skipped:
        print(f"  ({skipped} ideator files skipped due to errors)", file=sys.stderr)


# ── Subcommand: funding ────────────────────────────────────────────────────────

JUDGE_ARCHETYPES = [
    "pragmatist",
    "visionary",
    "risk-manager",
    "quant",
]


def cmd_funding(output_dir: Path, providers_json_path: Path) -> None:
    """Build judge_dispatches.json from all_scenarios.json + providers.

    Reads all_scenarios.json to build the scenario prompt. Creates dispatch
    entries for each judge archetype with provider degradation applied.

    Args:
        output_dir: The bazaar run output directory
        providers_json_path: Path to providers.json
    """
    providers_config = _load_providers(providers_json_path)
    available = _available_providers(providers_json_path)

    # Load all scenarios
    all_scenarios_path = output_dir / "all_scenarios.json"
    if not all_scenarios_path.exists():
        print(f"Error: {all_scenarios_path} not found. Run 'dedup' first.", file=sys.stderr)
        sys.exit(1)

    with open(all_scenarios_path) as f:
        all_data = json.load(f)
    scenarios = all_data.get("scenarios", [])

    # Build scenario prompt
    lines = ["Scenarios to evaluate:"]
    for s in scenarios:
        desc = s.get("description", "")[:100]
        lines.append(f"  - {s.get('id', '?')}: {s.get('title', '?')} — {desc}")
    scenarios_prompt = "\n".join(lines)

    dispatches = []
    for archetype in JUDGE_ARCHETYPES:
        provider, model = _resolve_provider(archetype, providers_config, available)
        archetype_file = ARCHETYPES_DIR / "judges" / f"{archetype}.md"

        user_prompt = f"{scenarios_prompt}\n\nAllocate 1000 units across these scenarios."

        dispatch = {
            "id": archetype,
            "provider": provider,
            "model": model,
            "system_prompt_file": str(archetype_file),
            "user_prompt": user_prompt,
            "output_file": str(output_dir / "judges" / f"{archetype}.json"),
        }
        dispatches.append(dispatch)

    output_path = output_dir / "judge_dispatches.json"
    with open(output_path, "w") as f:
        json.dump({"dispatches": dispatches}, f, indent=2)

    print(f"Wrote {len(dispatches)} judge dispatches to {output_path}")
    print(f"  ({len(scenarios)} scenarios in prompt)")
    for d in dispatches:
        print(f"  {d['id']}: {d['provider']}/{d['model']}")


# ── Subcommand: analysis ───────────────────────────────────────────────────────

def cmd_analysis(output_dir: Path, providers_json_path: Path) -> None:
    """Build analyst_dispatches.json from funded scenarios + obsessive outputs.

    Reads funded_scenarios.json, all_scenarios.json, and obsessives/*.json.
    Creates one analyst dispatch per funded scenario with all research signals
    embedded in the prompt.

    Args:
        output_dir: The bazaar run output directory
        providers_json_path: Path to providers.json
    """
    providers_config = _load_providers(providers_json_path)
    available = _available_providers(providers_json_path)

    # Load funded scenarios
    funded_path = output_dir / "funded_scenarios.json"
    if not funded_path.exists():
        print(f"Error: {funded_path} not found. Run Phase 3 first.", file=sys.stderr)
        sys.exit(1)
    with open(funded_path) as f:
        funded_data = json.load(f)
    funded_scenarios = funded_data.get("funded_scenarios", [])

    # Load all scenarios for description lookup
    all_scenarios_path = output_dir / "all_scenarios.json"
    all_scenarios: Dict[str, Dict] = {}
    if all_scenarios_path.exists():
        with open(all_scenarios_path) as f:
            all_data = json.load(f)
        all_scenarios = {s["id"]: s for s in all_data.get("scenarios", [])}

    # Resolve analyst provider/model
    provider, model = _resolve_provider("analyst", providers_config, available)
    analyst_archetype = ARCHETYPES_DIR / "analysts" / "analyst.md"

    dispatches = []
    for funded in funded_scenarios:
        sid = funded["scenario_id"]
        scenario = all_scenarios.get(sid, {"id": sid, "title": sid, "description": ""})

        # Collect research signals from obsessives
        signals = []
        for pattern in [
            str(output_dir / "obsessives" / f"{sid}_domain.json"),
            str(output_dir / "obsessives" / f"{sid}_search.json"),
        ]:
            for path in glob.glob(pattern):
                try:
                    with open(path) as f:
                        data = json.load(f)
                    parsed = data.get("parsed") or data
                    signals.append(json.dumps(parsed, indent=2))
                except Exception:
                    pass

        research_block = (
            "\n\n---\n\n".join(signals) if signals else "No research signals available."
        )

        user_prompt = (
            f"Scenario to analyze:\n"
            f"ID: {sid}\n"
            f"Title: {scenario.get('title', sid)}\n"
            f"Description: {scenario.get('description', '')}\n"
            f"Funding: {funded['funding_percent']:.1f}%\n\n"
            f"Research signals gathered by obsessives:\n"
            f"{research_block}\n\n"
            f"Follow the analyst archetype protocol. "
            f"Translate these signals into structured findings."
        )

        dispatch = {
            "id": f"analyst-{sid}",
            "provider": provider,
            "model": model,
            "system_prompt_file": str(analyst_archetype),
            "user_prompt": user_prompt,
            "output_file": str(output_dir / "analysts" / f"{sid}_analysis.json"),
        }
        dispatches.append(dispatch)

    output_path = output_dir / "analyst_dispatches.json"
    with open(output_path, "w") as f:
        json.dump({"dispatches": dispatches}, f, indent=2)

    print(f"Wrote {len(dispatches)} analyst dispatches to {output_path}")
    for d in dispatches:
        print(f"  {d['id']}: {d['provider']}/{d['model']}")


# ── Subcommand: collect-analysts ───────────────────────────────────────────────

def cmd_collect_analysts(output_dir: Path) -> None:
    """Collect analyst outputs from analysts/*.json into analyst_outputs.json.

    Reads all analyst output files, extracts parsed content, and writes the
    consolidated analyst_outputs.json used by Phase 6 report generation.

    Args:
        output_dir: The bazaar run output directory
    """
    analyst_paths = sorted(glob.glob(str(output_dir / "analysts" / "*.json")))
    analyst_paths = [p for p in analyst_paths if not Path(p).name.startswith("dispatch_")]

    analyst_outputs: Dict[str, Any] = {}
    collected = 0
    skipped = 0

    for path in analyst_paths:
        try:
            with open(path) as f:
                data = json.load(f)
            parsed = data.get("parsed")
            if parsed and "scenario_id" in parsed:
                analyst_outputs[parsed["scenario_id"]] = parsed
                collected += 1
            else:
                # Try to extract scenario_id from filename
                stem = Path(path).stem  # e.g., "adversarial-ensemble-poisoning_analysis"
                sid = stem.replace("_analysis", "")
                if parsed:
                    parsed["scenario_id"] = sid
                    analyst_outputs[sid] = parsed
                    collected += 1
                else:
                    skipped += 1
        except Exception as e:
            print(f"Skipping {path}: {e}", file=sys.stderr)
            skipped += 1

    output_path = output_dir / "analyst_outputs.json"
    with open(output_path, "w") as f:
        json.dump(analyst_outputs, f, indent=2)

    print(f"Collected {collected} analyst outputs to {output_path}")
    if skipped:
        print(f"  ({skipped} files skipped)", file=sys.stderr)


# ── CLI dispatch ───────────────────────────────────────────────────────────────

def main():
    """CLI entry point for bazaar_prepare.py subcommands."""
    usage = """Usage:
    bazaar_prepare.py ideation <output_dir> <providers_json>
    bazaar_prepare.py funding <output_dir> <providers_json>
    bazaar_prepare.py analysis <output_dir> <providers_json>
    bazaar_prepare.py dedup <output_dir>
    bazaar_prepare.py collect-analysts <output_dir>
    bazaar_prepare.py init <output_dir> <question> <providers_json>
"""

    if len(sys.argv) < 3:
        print(usage, file=sys.stderr)
        sys.exit(1)

    subcommand = sys.argv[1]
    output_dir = Path(sys.argv[2])

    try:
        if subcommand == "ideation":
            if len(sys.argv) < 4:
                print("Usage: bazaar_prepare.py ideation <output_dir> <providers_json>", file=sys.stderr)
                sys.exit(1)
            cmd_ideation(output_dir, Path(sys.argv[3]))

        elif subcommand == "funding":
            if len(sys.argv) < 4:
                print("Usage: bazaar_prepare.py funding <output_dir> <providers_json>", file=sys.stderr)
                sys.exit(1)
            cmd_funding(output_dir, Path(sys.argv[3]))

        elif subcommand == "analysis":
            if len(sys.argv) < 4:
                print("Usage: bazaar_prepare.py analysis <output_dir> <providers_json>", file=sys.stderr)
                sys.exit(1)
            cmd_analysis(output_dir, Path(sys.argv[3]))

        elif subcommand == "dedup":
            cmd_dedup(output_dir)

        elif subcommand == "collect-analysts":
            cmd_collect_analysts(output_dir)

        elif subcommand == "init":
            if len(sys.argv) < 5:
                print("Usage: bazaar_prepare.py init <output_dir> <question> <providers_json>", file=sys.stderr)
                sys.exit(1)
            question = sys.argv[3]
            providers_json = Path(sys.argv[4])
            cmd_init(output_dir, question, providers_json)

        else:
            print(f"Unknown subcommand: {subcommand!r}", file=sys.stderr)
            print(usage, file=sys.stderr)
            sys.exit(1)

    except FileNotFoundError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"Error: JSON parse failed: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
