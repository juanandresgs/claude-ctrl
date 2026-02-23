#!/usr/bin/env python3
"""Phase BLUF generator and manifest updater for bazaar skill.

@decision DEC-BAZAAR-014
@title bazaar_summarize.py generates phase BLUFs from disk artifacts
@status accepted
@rationale The forked bazaar skill agent exhausts context when it reads full JSON
artifacts between phases (ideators/*.json, judges/*.json, etc. can be 50-200KB
each). By moving all disk I/O into this script, the agent only ever reads a
5-15 line BLUF markdown file after each phase. This addresses REQ-P0-007 and
REQ-P0-010: each phase produces a concise BLUF presented to the user, and the
agent's context window remains free for reasoning and orchestration rather than
data storage. The manifest tracks run state so a crashed/interrupted run can
be resumed or diagnosed without re-reading all artifacts.

Usage:
    bazaar_summarize.py <phase_number> <output_dir>

Phase numbers: 1 (brief), 2 (ideation), 3 (funding), 4 (research),
               5 (analysis), 6 (report)

Outputs:
    <output_dir>/phase-<N>-bluf.md      -- 5-15 line BLUF for the agent to read
    <output_dir>/bazaar-manifest.json   -- created/updated with phase status + BLUF text
"""

import glob
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional


# ── Constants ─────────────────────────────────────────────────────────────────

MANIFEST_FILE = "bazaar-manifest.json"


# ── Manifest helpers ──────────────────────────────────────────────────────────

def _load_manifest(output_dir: Path) -> Dict[str, Any]:
    """Load existing manifest or return an empty skeleton."""
    manifest_path = output_dir / MANIFEST_FILE
    if manifest_path.exists():
        try:
            with open(manifest_path) as f:
                return json.load(f)
        except (json.JSONDecodeError, OSError):
            pass
    return {
        "question": "",
        "started": None,
        "completed": None,
        "output_dir": str(output_dir.resolve()),
        "providers": {},
        "phases": {},
        "report_path": None,
        "word_count": None,
        "scenarios_funded": None,
    }


def _save_manifest(output_dir: Path, manifest: Dict[str, Any]) -> None:
    """Write manifest to disk atomically (write + rename)."""
    manifest_path = output_dir / MANIFEST_FILE
    tmp_path = manifest_path.with_suffix(".json.tmp")
    with open(tmp_path, "w") as f:
        json.dump(manifest, f, indent=2)
    tmp_path.rename(manifest_path)


def _update_manifest_phase(
    manifest: Dict[str, Any],
    phase: int,
    bluf_text: str,
    artifacts: List[str],
    status: str = "completed",
) -> None:
    """Add or update a phase entry in the manifest."""
    manifest.setdefault("phases", {})[str(phase)] = {
        "status": status,
        "completed_at": datetime.now(timezone.utc).isoformat(),
        "artifacts": artifacts,
        "bluf": bluf_text,
    }


# ── BLUF generators per phase ─────────────────────────────────────────────────

def _bluf_phase1(output_dir: Path) -> tuple[str, List[str]]:
    """Generate BLUF for Phase 1 (Problem Framing / Brief).

    Reads brief.md and extracts question, scope, and key uncertainties.
    Returns (bluf_markdown, list_of_artifact_paths).
    """
    brief_path = output_dir / "brief.md"
    artifacts = [str(brief_path)]

    if not brief_path.exists():
        bluf = "## Phase 1 BLUF — Problem Framing\n\n**Status:** brief.md not found\n"
        return bluf, artifacts

    content = brief_path.read_text()

    # Extract question
    question = ""
    scope = ""
    uncertainties = []
    lines = content.splitlines()
    section = None
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("**Question**:") or stripped.startswith("**Question** :"):
            question = stripped.split(":", 1)[-1].strip()
        elif stripped.startswith("**Scope**:"):
            scope = stripped.split(":", 1)[-1].strip()
            section = "scope"
        elif stripped.startswith("**Key Uncertainties**:"):
            section = "uncertainties"
        elif section == "uncertainties" and stripped.startswith("-"):
            uncertainties.append(stripped[1:].strip())
        elif stripped.startswith("**") and section == "uncertainties":
            section = None

    uncertainty_lines = "\n".join(f"- {u}" for u in uncertainties[:5]) if uncertainties else "- (none extracted)"
    bluf = f"""## Phase 1 BLUF — Problem Framing

**Question:** {question or '(see brief.md)'}
**Scope:** {scope[:120] + '...' if len(scope) > 120 else scope or '(see brief.md)'}

**Key Uncertainties:**
{uncertainty_lines}

Brief saved to: `{brief_path.name}`
"""
    return bluf.strip(), artifacts


def _bluf_phase2(output_dir: Path) -> tuple[str, List[str]]:
    """Generate BLUF for Phase 2 (Diverse Ideation).

    Reads ideators/*.json and all_scenarios.json to report scenario counts and titles.
    Returns (bluf_markdown, list_of_artifact_paths).
    """
    ideator_paths = sorted(glob.glob(str(output_dir / "ideators" / "*.json")))
    # Exclude dispatch_summary.json
    ideator_paths = [p for p in ideator_paths if not Path(p).name.startswith("dispatch_")]
    artifacts = ideator_paths[:]

    all_scenarios_path = output_dir / "all_scenarios.json"
    if all_scenarios_path.exists():
        artifacts.append(str(all_scenarios_path))

    succeeded = 0
    failed = 0
    scenario_titles: List[str] = []
    seen_ids: set = set()

    for path in ideator_paths:
        try:
            with open(path) as f:
                data = json.load(f)
            if data.get("success", True):
                succeeded += 1
                parsed = data.get("parsed") or {}
                for s in parsed.get("scenarios", []):
                    sid = s.get("id", "")
                    if sid and sid not in seen_ids:
                        seen_ids.add(sid)
                        scenario_titles.append(f"{sid}: {s.get('title', '(no title)')}")
            else:
                failed += 1
        except (json.JSONDecodeError, OSError):
            failed += 1

    # Also load from all_scenarios.json if available (canonical deduped list)
    if all_scenarios_path.exists():
        try:
            with open(all_scenarios_path) as f:
                all_data = json.load(f)
            all_scenarios = all_data.get("scenarios", [])
            # Rebuild from canonical source
            scenario_titles = [
                f"{s.get('id', '?')}: {s.get('title', '(no title)')}"
                for s in all_scenarios
            ]
            seen_ids = {s.get("id", "") for s in all_scenarios}
        except (json.JSONDecodeError, OSError):
            pass

    total_scenarios = len(seen_ids)
    title_lines = "\n".join(f"  - {t}" for t in scenario_titles[:20])
    if len(scenario_titles) > 20:
        title_lines += f"\n  - ... ({len(scenario_titles) - 20} more)"

    failure_note = f"\n**Failures:** {failed} ideator(s) failed" if failed > 0 else ""

    bluf = f"""## Phase 2 BLUF — Diverse Ideation

**Ideators:** {succeeded} succeeded, {failed} failed
**Unique scenarios:** {total_scenarios}
{failure_note}

**Scenario list:**
{title_lines}
"""
    return bluf.strip(), artifacts


def _bluf_phase3(output_dir: Path) -> tuple[str, List[str]]:
    """Generate BLUF for Phase 3 (Judicial Funding).

    Reads funded_scenarios.json to report funding table, Kendall's W, Gini, eliminations.
    Returns (bluf_markdown, list_of_artifact_paths).
    """
    funded_path = output_dir / "funded_scenarios.json"
    artifacts = [str(funded_path)]

    if not funded_path.exists():
        bluf = "## Phase 3 BLUF — Judicial Funding\n\n**Status:** funded_scenarios.json not found\n"
        return bluf, artifacts

    try:
        with open(funded_path) as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        bluf = f"## Phase 3 BLUF — Judicial Funding\n\n**Error:** could not parse funded_scenarios.json: {e}\n"
        return bluf, artifacts

    funded = data.get("funded_scenarios", [])
    eliminated = data.get("eliminated_scenarios", [])
    metrics = data.get("metrics", {})

    kendalls_w = metrics.get("kendalls_w", "N/A")
    agreement = metrics.get("agreement", "N/A")
    gini = metrics.get("gini_coefficient", "N/A")
    judge_count = metrics.get("judge_count", "N/A")

    # Build compact funding table (top 10)
    rows = []
    for s in funded[:10]:
        rank = s.get("rank", "?")
        sid = s.get("scenario_id", "?")
        pct = s.get("funding_percent", 0)
        rows.append(f"  {rank:>3} | {sid:<40} | {pct:>5.1f}%")
    table = "\n".join(rows)
    if len(funded) > 10:
        table += f"\n  ... ({len(funded) - 10} more funded scenarios)"

    eliminated_note = f"{len(eliminated)} scenario(s) eliminated (below 3% cutoff)" if eliminated else "No eliminations"

    bluf = f"""## Phase 3 BLUF — Judicial Funding

**Judges:** {judge_count} | **Kendall's W:** {kendalls_w} ({agreement} agreement) | **Gini:** {gini}
**Scenarios funded:** {len(funded)} | {eliminated_note}

**Funding table:**
  Rank | Scenario ID                              | Funding%
{table}
"""
    return bluf.strip(), artifacts


def _bluf_phase4(output_dir: Path) -> tuple[str, List[str]]:
    """Generate BLUF for Phase 4 (Obsessive Research).

    Reads obsessives/*.json to report domain/search obsessive counts and signal counts.
    Returns (bluf_markdown, list_of_artifact_paths).
    """
    obsessive_paths = sorted(glob.glob(str(output_dir / "obsessives" / "*.json")))
    artifacts = obsessive_paths[:]

    domain_ok = 0
    domain_fail = 0
    search_ok = 0
    search_fail = 0
    signal_counts: Dict[str, int] = {}

    for path in obsessive_paths:
        name = Path(path).stem
        is_search = name.endswith("_search")
        is_domain = name.endswith("_domain")
        scenario_id = name.replace("_search", "").replace("_domain", "")

        try:
            with open(path) as f:
                data = json.load(f)
            success = data.get("success", True)
            parsed = data.get("parsed") or {}
            signals = parsed.get("signals", []) or parsed.get("findings", [])
            n_signals = len(signals)

            if n_signals == 0 and isinstance(parsed, dict):
                # Try counting any list field
                for v in parsed.values():
                    if isinstance(v, list) and len(v) > n_signals:
                        n_signals = len(v)

            if success:
                if is_domain:
                    domain_ok += 1
                elif is_search:
                    search_ok += 1
                # Accumulate signals per scenario
                signal_counts[scenario_id] = signal_counts.get(scenario_id, 0) + n_signals
            else:
                if is_domain:
                    domain_fail += 1
                elif is_search:
                    search_fail += 1
        except (json.JSONDecodeError, OSError):
            if is_domain:
                domain_fail += 1
            elif is_search:
                search_fail += 1

    signal_lines = "\n".join(
        f"  - {sid}: {cnt} signals"
        for sid, cnt in sorted(signal_counts.items(), key=lambda x: -x[1])[:10]
    ) or "  (none)"

    failure_note = ""
    failures = []
    if domain_fail:
        failures.append(f"{domain_fail} domain obsessive(s) failed")
    if search_fail:
        failures.append(f"{search_fail} search obsessive(s) failed")
    if failures:
        failure_note = f"\n**Failures:** {', '.join(failures)}"

    bluf = f"""## Phase 4 BLUF — Obsessive Research

**Domain obsessives:** {domain_ok} completed{f', {domain_fail} failed' if domain_fail else ''}
**Search obsessives:** {search_ok} completed{f', {search_fail} failed' if search_fail else ''}
{failure_note}

**Signals per scenario:**
{signal_lines}
"""
    return bluf.strip(), artifacts


def _bluf_phase5(output_dir: Path) -> tuple[str, List[str]]:
    """Generate BLUF for Phase 5 (Analyst Translation).

    Reads analysts/*.json to report analyst counts, key themes, confidence levels.
    Returns (bluf_markdown, list_of_artifact_paths).
    """
    analyst_paths = sorted(glob.glob(str(output_dir / "analysts" / "*.json")))
    analyst_paths = [p for p in analyst_paths if not Path(p).name.startswith("dispatch_")]
    artifacts = analyst_paths[:]

    succeeded = 0
    failed = 0
    high_conf = 0
    medium_conf = 0
    low_conf = 0
    themes: List[str] = []

    for path in analyst_paths:
        try:
            with open(path) as f:
                data = json.load(f)
            success = data.get("success", True)
            parsed = data.get("parsed") or {}
            if success:
                succeeded += 1
                conf = (parsed.get("confidence_level") or "").lower()
                if "high" in conf:
                    high_conf += 1
                elif "medium" in conf:
                    medium_conf += 1
                elif "low" in conf:
                    low_conf += 1
                # Extract first insight as a theme
                findings = parsed.get("findings", [])
                if findings and isinstance(findings, list):
                    insight = findings[0].get("insight", "") if isinstance(findings[0], dict) else str(findings[0])
                    if insight:
                        themes.append(insight[:80] + "..." if len(insight) > 80 else insight)
            else:
                failed += 1
        except (json.JSONDecodeError, OSError):
            failed += 1

    theme_lines = "\n".join(f"  - {t}" for t in themes[:5]) or "  (none extracted)"
    failure_note = f"\n**Failures:** {failed} analyst(s) failed" if failed > 0 else ""

    bluf = f"""## Phase 5 BLUF — Analyst Translation

**Analysts:** {succeeded} completed, {failed} failed
**Confidence distribution:** High={high_conf}, Medium={medium_conf}, Low={low_conf}
{failure_note}

**Key themes (top findings):**
{theme_lines}
"""
    return bluf.strip(), artifacts


def _bluf_phase6(output_dir: Path) -> tuple[str, List[str]]:
    """Generate BLUF for Phase 6 (Market-Proportional Report).

    Reads bazaar-report.md to report word count, section count, and funding summary.
    Returns (bluf_markdown, list_of_artifact_paths).
    """
    report_path = output_dir / "bazaar-report.md"
    artifacts = [str(report_path)]

    if not report_path.exists():
        bluf = "## Phase 6 BLUF — Report Generation\n\n**Status:** bazaar-report.md not found\n"
        return bluf, artifacts

    content = report_path.read_text()
    word_count = len(content.split())
    # Count markdown headers as sections
    sections = [line for line in content.splitlines() if line.startswith("## ")]
    section_count = len(sections)
    section_titles = "\n".join(f"  - {s[3:].strip()}" for s in sections[:8])
    if len(sections) > 8:
        section_titles += f"\n  - ... ({len(sections) - 8} more)"

    # Pull funding summary from funded_scenarios.json if available
    funded_summary = ""
    funded_path = output_dir / "funded_scenarios.json"
    if funded_path.exists():
        try:
            with open(funded_path) as f:
                fdata = json.load(f)
            funded = fdata.get("funded_scenarios", [])[:5]
            rows = [f"  {s.get('rank','')} | {s.get('scenario_id','?'):<40} | {s.get('funding_percent',0):.1f}%"
                    for s in funded]
            funded_summary = "\n**Top funded scenarios:**\n" + "\n".join(rows)
        except (json.JSONDecodeError, OSError):
            pass

    bluf = f"""## Phase 6 BLUF — Report Generation

**Report:** `{report_path.name}` ({word_count:,} words, {section_count} sections)

**Sections:**
{section_titles}
{funded_summary}
"""
    return bluf.strip(), artifacts


# ── Dispatch table ────────────────────────────────────────────────────────────

_PHASE_GENERATORS = {
    1: _bluf_phase1,
    2: _bluf_phase2,
    3: _bluf_phase3,
    4: _bluf_phase4,
    5: _bluf_phase5,
    6: _bluf_phase6,
}


# ── Main entry point ──────────────────────────────────────────────────────────

def summarize(phase: int, output_dir: Path) -> str:
    """Generate a BLUF for the given phase and update the manifest.

    Args:
        phase: Phase number 1-6
        output_dir: The bazaar run output directory

    Returns:
        The BLUF markdown text (also written to phase-N-bluf.md)

    Raises:
        ValueError: If phase is not 1-6
        OSError: If output_dir cannot be created or written
    """
    if phase not in _PHASE_GENERATORS:
        raise ValueError(f"Phase must be 1-6, got {phase}")

    output_dir = output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    # Generate BLUF
    generator = _PHASE_GENERATORS[phase]
    bluf_text, artifacts = generator(output_dir)

    # Write BLUF file
    bluf_path = output_dir / f"phase-{phase}-bluf.md"
    with open(bluf_path, "w") as f:
        f.write(bluf_text + "\n")

    # Update manifest
    manifest = _load_manifest(output_dir)
    _update_manifest_phase(manifest, phase, bluf_text, artifacts)

    # Update top-level manifest fields from phase data
    if phase == 3:
        funded_path = output_dir / "funded_scenarios.json"
        if funded_path.exists():
            try:
                with open(funded_path) as f:
                    fdata = json.load(f)
                manifest["scenarios_funded"] = fdata.get("metrics", {}).get(
                    "scenario_count_funded"
                )
            except (json.JSONDecodeError, OSError):
                pass
    elif phase == 6:
        report_path = output_dir / "bazaar-report.md"
        if report_path.exists():
            manifest["report_path"] = str(report_path)
            manifest["word_count"] = len(report_path.read_text().split())
            manifest["completed"] = datetime.now(timezone.utc).isoformat()

    _save_manifest(output_dir, manifest)

    return bluf_text


def main():
    """CLI entry point: bazaar_summarize.py <phase_number> <output_dir>"""
    if len(sys.argv) != 3:
        print(
            "Usage: bazaar_summarize.py <phase_number> <output_dir>",
            file=sys.stderr,
        )
        print("  phase_number: 1-6", file=sys.stderr)
        print("  output_dir:   path to the bazaar run output directory", file=sys.stderr)
        sys.exit(1)

    try:
        phase = int(sys.argv[1])
    except ValueError:
        print(f"Error: phase_number must be an integer, got {sys.argv[1]!r}", file=sys.stderr)
        sys.exit(1)

    output_dir = Path(sys.argv[2])

    try:
        bluf = summarize(phase, output_dir)
        print(bluf)
    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
    except OSError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
