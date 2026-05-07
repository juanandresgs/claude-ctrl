#!/usr/bin/env python3
"""Plan discipline enforcement tool for MASTER_PLAN.md.

Commands
--------
validate <path>
    Check required sections, Last updated date, decision-ID format,
    active-initiative required fields, and completed-initiative structure.
    Exits 0 on success, 1 on any violation (prints violation lines).

check-immutability <path>
    Compare permanent sections against the baseline snapshot.
    Permanent sections (Identity, Architecture, Original Intent, Principles)
    may be appended to but never rewritten.
    Emits JSON: {"immutable": bool, "violations": [{section, reason}]}
    Exits 0 if immutable, 1 if violations found.
    Creates .plan-baseline.json on first run (no error).

check-decision-log <path>
    Verify the decision log is append-only: every baseline entry must still
    appear in the same order; new entries may follow.
    Emits JSON: {"append_only": bool, "violations": [{reason}]}
    Exits 0 if append-only, 1 if violations found.
    Creates baseline on first run.

lookup-decision <path> <decision_id>
    Perform an exact, section-aware lookup for a DEC-* id in MASTER_PLAN.md.
    Emits JSON with line-numbered matches in the Decision Log section and
    across the full plan. Exits 0 when the id is present in the Decision Log,
    1 when absent, 2 for malformed input or unreadable files.

check-compression <path>
    Verify completed initiatives are compressed (no #### or ##### subsections).
    Verify active initiatives have all required fields.
    Emits JSON: {"valid": bool, "violations": [{initiative, reason}]}
    Exits 0 if valid, 1 if violations found.

stamp <path> [--summary TEXT]
    Replace the "Last updated:" line with today's ISO date (and optional
    summary). Regenerates .plan-baseline.json after stamping.

refresh-baseline <path>
    Regenerate .plan-baseline.json from the current file state.

@decision DEC-PLAN-001
Title: planctl.py as the single enforcement authority for MASTER_PLAN.md discipline
Status: accepted
Rationale: Dual enforcement between plan-validate.sh (inline shell) and
  planctl.py creates divergence risk. planctl.py is the canonical authority;
  plan-validate.sh is a thin shell bridge that calls planctl.py validate.
  All immutability, decision-log, and compression logic lives here — tested
  with real pytest unit tests rather than untestable shell assertions.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

REQUIRED_HEADERS = [
    "## Identity",
    "## Architecture",
    "## Original Intent",
    "## Principles",
    "## Decision Log",
    "## Active Initiatives",
    "## Completed Initiatives",
    "## Parked Issues",
]

# Permanent sections: name -> header pattern (matched as "## <name>")
PERMANENT_SECTIONS = [
    "Identity",
    "Architecture",
    "Original Intent",
    "Principles",
]

# Required fields for every Active Initiative block
ACTIVE_INITIATIVE_REQUIRED_FIELDS = [
    "Status",
    "Goal",
    "Scope",
    "Exit",
    "Dependencies",
]

# Decision log entry pattern: - `YYYY-MM-DD -- DEC-COMP-NNN` ...
# The plan uses em-dash (--) between date and ID.
_DEC_ENTRY_RE = re.compile(
    r"^-\s+`(\d{4}-\d{2}-\d{2})\s+--\s+(DEC-[A-Z]+-\d+)`(.*)$"
)

# Decision ID bare format check: DEC-COMPONENT-NNN (2+ uppercase letters, 3+ digits)
_DEC_ID_FORMAT_RE = re.compile(r"^DEC-[A-Z]{2,}-\d{3,}$")

# Broad token shape used for exact lookups. Decision IDs in project plans may
# carry more domain segments than the legacy validator allows, e.g.
# DEC-COEDITOR-HISTORY-FORMAT-001. Lookup must find those without changing the
# historical validate command's stricter format gate.
_DEC_ID_LOOKUP_RE = re.compile(r"^DEC-[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$")

# "Last updated:" line
_LAST_UPDATED_RE = re.compile(r"^Last updated:\s+(\d{4}-\d{2}-\d{2})", re.MULTILINE)

# Baseline filename relative to the plan file's parent directory
_BASELINE_FILE = ".plan-baseline.json"


# ---------------------------------------------------------------------------
# Section extraction helpers
# ---------------------------------------------------------------------------


def _extract_section(text: str, header: str) -> str | None:
    """Return the content between ``## <header>`` and the next ``##`` header.

    Returns None if the header is not found. Trailing whitespace is stripped.
    """
    pattern = re.compile(
        r"^##\s+" + re.escape(header) + r"\s*$(.+?)(?=^##\s|\Z)",
        re.MULTILINE | re.DOTALL,
    )
    m = pattern.search(text)
    if m is None:
        return None
    return m.group(1).strip()


def _section_hash(content: str) -> str:
    """SHA-256 of normalised section content (collapsed whitespace)."""
    normalised = " ".join(content.split())
    return hashlib.sha256(normalised.encode()).hexdigest()


# ---------------------------------------------------------------------------
# Baseline helpers
# ---------------------------------------------------------------------------


def _baseline_path(plan_path: Path) -> Path:
    return plan_path.parent / _BASELINE_FILE


def _build_baseline(text: str) -> dict[str, Any]:
    """Build the baseline dict from plan text.

    Structure:
    {
      "sections": {"Identity": "<hash>", ...},
      "decision_entries": ["- `YYYY-MM-DD -- DEC-X-NNN` ...", ...]
    }
    """
    sections: dict[str, str] = {}
    for name in PERMANENT_SECTIONS:
        content = _extract_section(text, name)
        if content is not None:
            sections[name] = _section_hash(content)

    entries = _parse_decision_entries(text)
    return {"sections": sections, "decision_entries": entries}


def _load_baseline(plan_path: Path) -> dict[str, Any] | None:
    bp = _baseline_path(plan_path)
    if not bp.exists():
        return None
    try:
        return json.loads(bp.read_text())
    except (json.JSONDecodeError, OSError):
        return None


def _save_baseline(plan_path: Path, baseline: dict[str, Any]) -> None:
    bp = _baseline_path(plan_path)
    bp.write_text(json.dumps(baseline, indent=2))


# ---------------------------------------------------------------------------
# Decision entry parsing
# ---------------------------------------------------------------------------


def _parse_decision_entries(text: str) -> list[str]:
    """Return all decision log entry lines in document order."""
    entries = []
    for line in text.splitlines():
        if _DEC_ENTRY_RE.match(line.strip()):
            entries.append(line.strip())
    return entries


def _decision_token_pattern(decision_id: str) -> re.Pattern[str]:
    """Return a regex that matches ``decision_id`` as a whole DEC token."""
    return re.compile(
        rf"(?<![A-Za-z0-9-]){re.escape(decision_id)}(?![A-Za-z0-9-])"
    )


def _decision_log_line_range(lines: list[str]) -> tuple[int, int] | None:
    """Return the 1-based inclusive line range for ``## Decision Log``.

    Returns None when the section is absent. The range includes the header line
    and stops immediately before the next level-2 section.
    """
    start: int | None = None
    for idx, line in enumerate(lines, start=1):
        if line.strip() == "## Decision Log":
            start = idx
            break
    if start is None:
        return None

    end = len(lines)
    for idx in range(start + 1, len(lines) + 1):
        line = lines[idx - 1]
        if line.startswith("## ") and line.strip() != "## Decision Log":
            end = idx - 1
            break
    return start, end


def _line_match(line_no: int, text: str) -> dict[str, Any]:
    return {"line": line_no, "text": text}


# ---------------------------------------------------------------------------
# validate command
# ---------------------------------------------------------------------------


def validate(path: Path) -> int:
    text = path.read_text()
    issues: list[str] = []

    # 1. Required section headers
    for header in REQUIRED_HEADERS:
        if header not in text:
            issues.append(f"missing: {header}")

    # 2. Last updated line with valid ISO date
    if not _LAST_UPDATED_RE.search(text):
        issues.append("missing or malformed 'Last updated: YYYY-MM-DD' line")

    # 3. Decision IDs follow DEC-COMPONENT-NNN format.
    # Broad capture: any word-boundary token starting with DEC- (catches DEC-001,
    # DEC-X-1, etc. that the strict pattern would silently skip). Then validate each.
    all_ids = set(re.findall(r"\bDEC-[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*\b", text))
    for dec_id in sorted(all_ids):
        if not _DEC_ID_FORMAT_RE.match(dec_id):
            issues.append(f"Decision ID '{dec_id}' must follow DEC-COMPONENT-NNN format")

    # 4. Active initiative required fields
    active_section = _extract_section(text, "Active Initiatives")
    if active_section:
        # Each ### block is an initiative
        for block in _split_initiative_blocks(active_section):
            header_line = block.splitlines()[0] if block.splitlines() else ""
            for field in ACTIVE_INITIATIVE_REQUIRED_FIELDS:
                if f"**{field}:**" not in block:
                    issues.append(
                        f"Active initiative '{header_line.strip()}' missing required field: {field}"
                    )

    if issues:
        for issue in issues:
            print(issue)
        return 1
    return 0


def _split_initiative_blocks(section_text: str) -> list[str]:
    """Split a section's text into individual ### initiative blocks."""
    blocks: list[str] = []
    current: list[str] = []
    for line in section_text.splitlines():
        if line.startswith("### ") and current:
            blocks.append("\n".join(current))
            current = [line]
        else:
            current.append(line)
    if current:
        blocks.append("\n".join(current))
    # Filter out blocks that don't start with ###
    return [b for b in blocks if b.lstrip().startswith("###")]


# ---------------------------------------------------------------------------
# check-immutability command
# ---------------------------------------------------------------------------


def check_immutability(path: Path) -> int:
    """Compare permanent sections against baseline.

    Permanent sections may be appended to (current starts with baseline
    content) but not rewritten (current does NOT start with baseline).

    On first run (no baseline): create baseline and return immutable=True.
    """
    text = path.read_text()
    baseline = _load_baseline(path)

    if baseline is None:
        # First run: create baseline, no violation
        new_baseline = _build_baseline(text)
        _save_baseline(path, new_baseline)
        result = {"immutable": True, "violations": []}
        print(json.dumps(result))
        return 0

    violations: list[dict[str, str]] = []
    section_hashes = baseline.get("sections", {})

    for name in PERMANENT_SECTIONS:
        if name not in section_hashes:
            continue  # section wasn't in baseline — skip

        baseline_hash = section_hashes[name]
        current_content = _extract_section(text, name)
        if current_content is None:
            violations.append({
                "section": name,
                "reason": f"Permanent section '{name}' was deleted",
            })
            continue

        current_hash = _section_hash(current_content)
        if current_hash == baseline_hash:
            continue  # unchanged

        # Hash differs — check if this is an append (allowed) or rewrite (denied).
        # Reconstruct baseline section content by finding the original section.
        # We store only the hash, not the raw text, so we check structurally:
        # An append means the CURRENT section starts with the baseline text.
        # Since we only store hashes, we must use a different approach:
        # store the first N characters' hash as a prefix check.
        # Instead: re-run check by storing section text directly in baseline.
        # For backward compat: if baseline has "section_text" key, use it;
        # otherwise fall back to hash-only (treat as violation to be safe).
        section_texts = baseline.get("section_texts", {})
        if name in section_texts:
            baseline_text = section_texts[name]
            # Allow if current section starts with baseline text (append-only)
            if current_content.startswith(baseline_text):
                continue  # append is OK
            else:
                violations.append({
                    "section": name,
                    "reason": f"Permanent section '{name}' was rewritten (baseline text no longer leads the section)",
                })
        else:
            # No text stored — hash mismatch means violation
            violations.append({
                "section": name,
                "reason": f"Permanent section '{name}' was modified (hash mismatch, no baseline text available)",
            })

    result = {
        "immutable": len(violations) == 0,
        "violations": violations,
    }
    print(json.dumps(result))
    return 0 if result["immutable"] else 1


# ---------------------------------------------------------------------------
# check-decision-log command
# ---------------------------------------------------------------------------


def check_decision_log(path: Path) -> int:
    """Verify the decision log is append-only.

    Every entry in the baseline must still appear in the same order.
    New entries after existing ones are allowed.
    """
    text = path.read_text()
    baseline = _load_baseline(path)

    if baseline is None:
        new_baseline = _build_baseline(text)
        _save_baseline(path, new_baseline)
        result = {"append_only": True, "violations": []}
        print(json.dumps(result))
        return 0

    baseline_entries: list[str] = baseline.get("decision_entries", [])
    current_entries: list[str] = _parse_decision_entries(text)

    violations: list[dict[str, str]] = []

    # Every baseline entry must appear in current, in order, as a subsequence
    current_idx = 0
    for b_entry in baseline_entries:
        # Find b_entry in current_entries starting from current_idx
        found = False
        for i in range(current_idx, len(current_entries)):
            if current_entries[i] == b_entry:
                current_idx = i + 1
                found = True
                break
        if not found:
            violations.append({
                "reason": f"Decision log entry deleted or modified: {b_entry[:80]}"
            })

    result = {
        "append_only": len(violations) == 0,
        "violations": violations,
    }
    print(json.dumps(result))
    return 0 if result["append_only"] else 1


# ---------------------------------------------------------------------------
# lookup-decision command
# ---------------------------------------------------------------------------


def lookup_decision(path: Path, decision_id: str) -> int:
    """Look up a DEC-* id in the plan's Decision Log section.

    This is a read-only reviewer/orchestrator helper. It deliberately performs
    exact token matching and reports both section-scoped and full-plan matches
    so an agent can distinguish "not in the Decision Log" from "mentioned
    elsewhere in the plan" before filing a missing-decision finding.
    """
    if not _DEC_ID_LOOKUP_RE.match(decision_id):
        print(json.dumps({
            "status": "error",
            "message": (
                "lookup-decision: decision_id must be a DEC-* token; "
                f"got {decision_id!r}"
            ),
            "decision_id": decision_id,
            "found": False,
            "in_decision_log": False,
            "decision_log_matches": [],
            "all_matches": [],
        }))
        return 2

    try:
        text = path.read_text()
    except OSError as exc:
        print(json.dumps({
            "status": "error",
            "message": f"lookup-decision: failed to read {path}: {exc}",
            "decision_id": decision_id,
            "found": False,
            "in_decision_log": False,
            "decision_log_matches": [],
            "all_matches": [],
        }))
        return 2

    pattern = _decision_token_pattern(decision_id)
    lines = text.splitlines()
    decision_log_range = _decision_log_line_range(lines)

    all_matches: list[dict[str, Any]] = []
    decision_log_matches: list[dict[str, Any]] = []

    for line_no, line in enumerate(lines, start=1):
        if not pattern.search(line):
            continue
        match = _line_match(line_no, line.rstrip())
        all_matches.append(match)
        if (
            decision_log_range is not None
            and decision_log_range[0] <= line_no <= decision_log_range[1]
        ):
            decision_log_matches.append(match)

    found_in_log = bool(decision_log_matches)
    result = {
        "status": "found" if found_in_log else "missing",
        "decision_id": decision_id,
        "found": found_in_log,
        "in_decision_log": found_in_log,
        "decision_log_section_found": decision_log_range is not None,
        "decision_log_range": list(decision_log_range)
        if decision_log_range is not None
        else None,
        "decision_log_matches": decision_log_matches,
        "all_matches": all_matches,
        "plan_path": str(path),
    }
    print(json.dumps(result))
    return 0 if found_in_log else 1


# ---------------------------------------------------------------------------
# check-compression command
# ---------------------------------------------------------------------------


def check_compression(path: Path) -> int:
    """Verify initiative compression rules.

    Completed initiatives: no #### or ##### subsections allowed.
    Active initiatives: must have all required fields.
    """
    text = path.read_text()
    violations: list[dict[str, str]] = []

    # --- Completed initiatives: no deep subsections ---
    completed_section = _extract_section(text, "Completed Initiatives")
    if completed_section:
        for block in _split_initiative_blocks(completed_section):
            header_line = block.splitlines()[0].strip() if block.splitlines() else "(unknown)"
            for line in block.splitlines():
                if line.startswith("####") or line.startswith("#####"):
                    violations.append({
                        "initiative": header_line,
                        "reason": (
                            f"Completed initiative has uncompressed wave detail "
                            f"(subsection: {line.strip()[:60]})"
                        ),
                    })
                    break  # one violation per initiative is enough

    # --- Active initiatives: required fields ---
    active_section = _extract_section(text, "Active Initiatives")
    if active_section:
        for block in _split_initiative_blocks(active_section):
            header_line = block.splitlines()[0].strip() if block.splitlines() else "(unknown)"
            for field in ACTIVE_INITIATIVE_REQUIRED_FIELDS:
                if f"**{field}:**" not in block:
                    violations.append({
                        "initiative": header_line,
                        "reason": f"Active initiative missing required field: {field}",
                    })

    result = {
        "valid": len(violations) == 0,
        "violations": violations,
    }
    print(json.dumps(result))
    return 0 if result["valid"] else 1


# ---------------------------------------------------------------------------
# stamp command
# ---------------------------------------------------------------------------


def stamp(path: Path, summary: str | None = None) -> int:
    """Replace the Last updated line and regenerate the baseline."""
    text = path.read_text()
    today = datetime.date.today().isoformat()
    if summary:
        replacement = f"Last updated: {today} ({summary})"
    else:
        replacement = f"Last updated: {today}"

    stamped = re.sub(
        r"^Last updated:.*$",
        replacement,
        text,
        flags=re.MULTILINE,
    )
    if stamped == text:
        # No existing line — prepend
        stamped = f"{replacement}\n\n{text}"

    path.write_text(stamped)

    # Regenerate baseline after stamp
    new_baseline = _build_baseline(stamped)
    _save_baseline(path, new_baseline)
    return 0


# ---------------------------------------------------------------------------
# refresh-baseline command
# ---------------------------------------------------------------------------


def refresh_baseline(path: Path) -> int:
    """Regenerate .plan-baseline.json from current file state."""
    text = path.read_text()
    new_baseline = _build_baseline(text)
    _save_baseline(path, new_baseline)
    return 0


# ---------------------------------------------------------------------------
# _build_baseline needs to store section_texts too for prefix checking
# Override here after the function definitions are complete.
# ---------------------------------------------------------------------------


def _build_baseline(text: str) -> dict[str, Any]:  # type: ignore[no-redef]
    """Build the baseline dict from plan text.

    Stores both hashes (for quick equality) and raw section texts
    (for prefix-checking append-only writes in check_immutability).

    Structure:
    {
      "sections": {"Identity": "<hash>", ...},
      "section_texts": {"Identity": "<raw text>", ...},
      "decision_entries": ["- `YYYY-MM-DD -- DEC-X-NNN` ...", ...]
    }
    """
    sections: dict[str, str] = {}
    section_texts: dict[str, str] = {}
    for name in PERMANENT_SECTIONS:
        content = _extract_section(text, name)
        if content is not None:
            sections[name] = _section_hash(content)
            section_texts[name] = content

    entries = _parse_decision_entries(text)
    return {
        "sections": sections,
        "section_texts": section_texts,
        "decision_entries": entries,
    }


# ---------------------------------------------------------------------------
# CLI wiring
# ---------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(prog="planctl.py", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    validate_cmd = sub.add_parser("validate", help="Check required sections and structure")
    validate_cmd.add_argument("path", type=Path)

    imm_cmd = sub.add_parser("check-immutability", help="Check permanent sections against baseline")
    imm_cmd.add_argument("path", type=Path)

    dl_cmd = sub.add_parser("check-decision-log", help="Verify decision log is append-only")
    dl_cmd.add_argument("path", type=Path)

    lookup_cmd = sub.add_parser(
        "lookup-decision",
        help="Exact DEC-* lookup in the plan's Decision Log",
    )
    lookup_cmd.add_argument("path", type=Path)
    lookup_cmd.add_argument("decision_id")

    comp_cmd = sub.add_parser("check-compression", help="Verify initiative compression rules")
    comp_cmd.add_argument("path", type=Path)

    stamp_cmd = sub.add_parser("stamp", help="Update Last updated timestamp")
    stamp_cmd.add_argument("path", type=Path)
    stamp_cmd.add_argument("--summary", default=None, help="Optional summary for the timestamp")

    rb_cmd = sub.add_parser("refresh-baseline", help="Regenerate .plan-baseline.json")
    rb_cmd.add_argument("path", type=Path)

    args = parser.parse_args()

    dispatch = {
        "validate": lambda: validate(args.path),
        "check-immutability": lambda: check_immutability(args.path),
        "check-decision-log": lambda: check_decision_log(args.path),
        "lookup-decision": lambda: lookup_decision(args.path, args.decision_id),
        "check-compression": lambda: check_compression(args.path),
        "stamp": lambda: stamp(args.path, getattr(args, "summary", None)),
        "refresh-baseline": lambda: refresh_baseline(args.path),
    }

    fn = dispatch.get(args.command)
    if fn is None:
        print(f"unknown command: {args.command}", file=sys.stderr)
        return 1
    return fn()


if __name__ == "__main__":
    sys.exit(main())
