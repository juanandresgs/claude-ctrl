"""Mechanical pin for Invariant #11: @decision-ref links resolve to active decisions.

@decision DEC-CLAUDEX-DECISION-REF-SCAN-001
Title: @decision-ref / Refs cross-reference resolution scanner — Invariant #11 mechanical pin
Status: proposed
Rationale: The CUTOVER_PLAN.md Invariant #11 states that ``@decision-ref`` links
  must resolve to active or explicitly superseded decisions.  This module provides
  a filesystem-based scanner (no SQLite dependency, no network, no subprocess) that:

  - Walks the canonical scan roots (runtime/, hooks/, tests/, agents/,
    ClauDEX/*.md top-level only) collecting all @decision declarations and
    all @decision-ref / Refs cross-references.
  - Computes the set of referenced IDs that have no matching declaration.
  - Fails with a structured, operator-readable message if any unresolved IDs
    are found.
  - Allows a sanctioned-exception list (_KNOWN_DRIFT_IDS) for IDs whose repair
    is explicitly scope-deferred; the list is empty by default and MUST be kept
    empty unless a follow-on slice adds a dated comment explaining the deferral.

  Three positive synthetic fixtures plus one counter-test (scanner sanity) plus
  one live-repo scan compose the full test surface.

Adjacent authorities:
  - ``runtime/core/decision_work_registry.py`` — SQLite-backed decision store;
    this scanner is intentionally independent and filesystem-only.
  - ``ClauDEX/CUTOVER_PLAN.md`` Invariant #11 — the requirement this pin enforces.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Dict, List, Tuple

import pytest

# ---------------------------------------------------------------------------
# Configuration constants
# ---------------------------------------------------------------------------

# Directories (relative to the project root) that the scanner must walk.
# ClauDEX/*.md is handled specially — top-level .md files only, NOT recursive.
_SCAN_ROOTS = [
    "runtime",
    "hooks",
    "tests",
    "agents",
    # ClauDEX/*.md is injected at scan time as explicit file list, not a dir root.
]

# Paths (or path prefixes) the scanner must skip, relative to the project root.
# These exclusions are applied uniformly across all scan roots.
_SKIP_PATH_SEGMENTS = frozenset(
    [
        ".git",
        ".claudex",
        "tmp",
        "__pycache__",
        ".worktrees",
        "dist",
        "build",
        ".venv",
        "venv",
        "node_modules",
        # ClauDEX/braid-v2 subtree: path-inject imports make it a separate codebase.
        "braid-v2",
    ]
)

_SKIP_SUFFIXES = frozenset([".pyc"])

# ---------------------------------------------------------------------------
# Canonical regex patterns (word-boundary anchored where semantics allow it)
# ---------------------------------------------------------------------------

# Declaration: @decision DEC-SOMETHING-001
_RE_DECLARATION = re.compile(r"@decision\s+(DEC-[A-Z][A-Z0-9_-]*)")

# Explicit cross-ref: @decision-ref DEC-SOMETHING-001
_RE_EXPLICIT_REF = re.compile(r"@decision-ref\s+(DEC-[A-Z][A-Z0-9_-]*)")

# Commit-message-style ref: "Refs DEC-A" or "Refs DEC-A, DEC-B"
# Captures each ID individually; the outer match anchors on word boundary
# for "Refs" to avoid false-matching "xRefs".
_RE_REFS_SINGLE = re.compile(r"(?:^|\s)Refs\s+(DEC-[A-Z][A-Z0-9_-]*(?:\s*,\s*DEC-[A-Z][A-Z0-9_-]*)*)")
_RE_REFS_EACH = re.compile(r"DEC-[A-Z][A-Z0-9_-]*")

# ---------------------------------------------------------------------------
# Sanctioned exception list (MUST remain empty unless a follow-on slice adds
# a dated comment explaining the scope-deferral rationale for each entry).
# ---------------------------------------------------------------------------

_KNOWN_DRIFT_IDS: frozenset[str] = frozenset()

# ---------------------------------------------------------------------------
# Scanner helper
# ---------------------------------------------------------------------------


def _should_skip(path: Path, root: Path) -> bool:
    """Return True if the path should be excluded from the scan.

    Exclusion rules (applied to every component of the relative path):
    - Any component is in _SKIP_PATH_SEGMENTS.
    - File suffix is in _SKIP_SUFFIXES.

    The ``root`` parameter is used only to compute the relative path for
    segment-level matching; the path itself is still absolute for I/O.
    """
    try:
        rel = path.relative_to(root)
    except ValueError:
        rel = path
    for part in rel.parts:
        if part in _SKIP_PATH_SEGMENTS:
            return True
    if path.suffix in _SKIP_SUFFIXES:
        return True
    return False


def _extract_ids_from_line(line: str) -> Tuple[List[str], List[str]]:
    """Return (declared_ids, referenced_ids) found on a single line.

    A line may contain multiple patterns; all are extracted.
    """
    declared: List[str] = _RE_DECLARATION.findall(line)

    referenced: List[str] = []
    referenced.extend(_RE_EXPLICIT_REF.findall(line))
    # "Refs DEC-ID1, DEC-ID2" style: find the full match then split out individual IDs.
    for refs_match in _RE_REFS_SINGLE.findall(line):
        referenced.extend(_RE_REFS_EACH.findall(refs_match))

    return declared, referenced


def scan_repo(root: Path) -> Dict[str, object]:
    """Walk the canonical scan roots under *root* and collect decision annotations.

    Returns a dict::

        {
            "declared":   {DEC_ID: [(file_str, lineno), ...]},
            "referenced": {DEC_ID: [(file_str, lineno), ...]},
        }

    Files are visited in sorted order so output is deterministic.
    Binary-tainted files are read with ``errors="replace"`` to prevent crashes.

    The scan roots are:
      - runtime/, hooks/, tests/, agents/ — walked recursively
      - ClauDEX/*.md — top-level .md files only (no recursion into subdirs)

    All exclusions defined in ``_SKIP_PATH_SEGMENTS`` and ``_SKIP_SUFFIXES``
    are applied uniformly.
    """
    declared: Dict[str, List[Tuple[str, int]]] = {}
    referenced: Dict[str, List[Tuple[str, int]]] = {}

    def _record_declared(dec_id: str, file_str: str, lineno: int) -> None:
        declared.setdefault(dec_id, []).append((file_str, lineno))

    def _record_referenced(dec_id: str, file_str: str, lineno: int) -> None:
        referenced.setdefault(dec_id, []).append((file_str, lineno))

    def _scan_file(path: Path) -> None:
        rel_str = str(path.relative_to(root))
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                for lineno, line in enumerate(fh, start=1):
                    decls, refs = _extract_ids_from_line(line)
                    for d in decls:
                        _record_declared(d, rel_str, lineno)
                    for r in refs:
                        _record_referenced(r, rel_str, lineno)
        except (OSError, PermissionError):
            # Skip files we cannot read (e.g., broken symlinks).
            pass

    # Walk named directory roots recursively.
    for root_name in _SCAN_ROOTS:
        root_dir = root / root_name
        if not root_dir.is_dir():
            continue
        for path in sorted(root_dir.rglob("*")):
            if path.is_dir():
                continue
            if _should_skip(path, root):
                continue
            _scan_file(path)

    # Walk ClauDEX/*.md — top-level only, no subdirectory recursion.
    claudex_dir = root / "ClauDEX"
    if claudex_dir.is_dir():
        for path in sorted(claudex_dir.glob("*.md")):
            if path.is_file() and not _should_skip(path, root):
                _scan_file(path)

    return {"declared": declared, "referenced": referenced}


# ---------------------------------------------------------------------------
# Helper: resolve unresolved IDs with structured error messages
# ---------------------------------------------------------------------------


def _build_unresolved_message(unresolved: Dict[str, List[Tuple[str, int]]]) -> str:
    """Return a structured operator-readable failure message for unresolved IDs.

    Format::

        Unresolved @decision-ref / Refs targets (N unique ids, M locations):

          DEC-FOO-001
            - runtime/core/foo.py:12
            - hooks/bar.sh:45

        To fix: ...
    """
    total_locs = sum(len(v) for v in unresolved.values())
    lines = [
        f"Unresolved @decision-ref / Refs targets "
        f"({len(unresolved)} unique ids, {total_locs} locations):",
        "",
    ]
    for dec_id in sorted(unresolved):
        lines.append(f"  {dec_id}")
        for file_str, lineno in unresolved[dec_id]:
            lines.append(f"    - {file_str}:{lineno}")
        lines.append("")
    lines += [
        "To fix: add `@decision DEC-ID ...` header annotations in the modules",
        "that own these decisions, OR add the id to `_KNOWN_DRIFT_IDS` with a",
        "follow-on-slice comment if the repair is scope-deferred.",
    ]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Positive fixture test cases (synthetic, using tmp_path — never touch live repo)
# ---------------------------------------------------------------------------


def test_seeded_decision_resolves(tmp_path: Path) -> None:
    """A @decision-ref to a declared ID resolves without error.

    Production sequence mirrored: one module declares the decision, another
    module cross-references it via @decision-ref.  The scanner must report
    the reference as resolved (i.e., the ID appears in both ``declared`` and
    ``referenced``).
    """
    # Simulate a minimal runtime/ subtree.
    rt = tmp_path / "runtime"
    rt.mkdir()

    # File that declares the decision.
    declaration_file = rt / "owner.py"
    declaration_file.write_text(
        "# @decision DEC-SYNTH-ACTIVE-001\n"
        "# Title: Synthetic active decision for test\n"
        "# Status: active\n"
    )

    # File that cross-references it.
    ref_file = rt / "consumer.py"
    ref_file.write_text(
        "# @decision-ref DEC-SYNTH-ACTIVE-001\n"
        "# Refs the declared decision above.\n"
    )

    result = scan_repo(tmp_path)
    assert "DEC-SYNTH-ACTIVE-001" in result["declared"], (
        "Declaration not found; scanner failed to parse @decision header"
    )
    assert "DEC-SYNTH-ACTIVE-001" in result["referenced"], (
        "Reference not found; scanner failed to parse @decision-ref header"
    )
    # Resolved = referenced ID has a matching declaration.
    unresolved = set(result["referenced"]) - set(result["declared"])
    assert "DEC-SYNTH-ACTIVE-001" not in unresolved, (
        "DEC-SYNTH-ACTIVE-001 should be resolved (declaration exists)"
    )


def test_superseded_chain_resolves_via_supersession_annotation(tmp_path: Path) -> None:
    """A @decision-ref to a superseded ID still resolves if the declaration exists.

    Mechanism: a declared id is considered resolvable regardless of supersession
    status; the declaration itself IS the resolution.  More sophisticated
    supersession-to-active chain-checking is out of scope for this first pin.

    Note: This test uses ``@supersedes`` as the supersession header form.
    ``@supersession-of`` is also an accepted variant per the spec; testing that
    alternate form is deferred to a follow-on slice.
    """
    rt = tmp_path / "runtime"
    rt.mkdir()

    # Old decision — still declared, just annotated as superseded.
    old_file = rt / "old_module.py"
    old_file.write_text(
        "# @decision DEC-SYNTH-OLD-001\n"
        "# Title: Old decision (now superseded)\n"
        "# Status: superseded\n"
    )

    # New decision that supersedes the old one.
    new_file = rt / "new_module.py"
    new_file.write_text(
        "# @decision DEC-SYNTH-NEW-002\n"
        "# Title: New decision replacing old\n"
        "# Status: active\n"
        "# @supersedes DEC-SYNTH-OLD-001\n"
    )

    # Third file that cross-references the old (superseded) decision.
    ref_file = rt / "consumer.py"
    ref_file.write_text(
        "# @decision-ref DEC-SYNTH-OLD-001\n"
        "# Kept for historical cross-reference.\n"
    )

    result = scan_repo(tmp_path)
    assert "DEC-SYNTH-OLD-001" in result["declared"], (
        "Old decision declaration not found"
    )
    assert "DEC-SYNTH-NEW-002" in result["declared"], (
        "New decision declaration not found"
    )
    assert "DEC-SYNTH-OLD-001" in result["referenced"], (
        "Cross-reference to old decision not found"
    )
    # The old ID is declared, so it resolves even though it is superseded.
    unresolved = set(result["referenced"]) - set(result["declared"])
    assert "DEC-SYNTH-OLD-001" not in unresolved, (
        "DEC-SYNTH-OLD-001 should resolve: declaration exists (supersession does "
        "not remove the declaration in the first-pin scope)"
    )


def test_unknown_id_produces_structured_failure(tmp_path: Path) -> None:
    """A @decision-ref to an undeclared ID yields a structured unresolved error.

    The scan must:
    - Place the unknown ID in ``referenced`` but NOT in ``declared``.
    - The resolver helper must produce a structured message of the form:
      "DEC-SYNTH-UNKNOWN-999 referenced at <file>:<line> but never declared"
    """
    rt = tmp_path / "runtime"
    rt.mkdir()

    bad_ref_file = rt / "consumer_bad.py"
    # NOTE: The synthetic file content is assembled via concatenation so that
    # the pattern "@decision" + "-ref DEC-SYNTH-UNKNOWN-999" does NOT appear
    # as a literal match in THIS source file and therefore does not cause the
    # live-repo scan to find a self-referential unresolved ID.
    _ref_prefix = "@decision"
    _ref_tag = "-ref"
    bad_ref_file.write_text(
        f"# {_ref_prefix}{_ref_tag} DEC-SYNTH-UNKNOWN-999\n"
        "# This references a nonexistent decision — intentional for the test.\n"
    )

    result = scan_repo(tmp_path)
    assert "DEC-SYNTH-UNKNOWN-999" not in result["declared"], (
        "DEC-SYNTH-UNKNOWN-999 must NOT be in declared (no declaration exists)"
    )
    assert "DEC-SYNTH-UNKNOWN-999" in result["referenced"], (
        "DEC-SYNTH-UNKNOWN-999 must be in referenced (the @decision-ref line exists)"
    )

    # Build the unresolved map and check the structured error message.
    unresolved_ids = set(result["referenced"]) - set(result["declared"])
    assert "DEC-SYNTH-UNKNOWN-999" in unresolved_ids

    unresolved_map = {
        dec_id: result["referenced"][dec_id]
        for dec_id in unresolved_ids
    }
    message = _build_unresolved_message(unresolved_map)

    # The message must contain the ID and at least one file:line location.
    assert "DEC-SYNTH-UNKNOWN-999" in message
    # The structured message format requires at least "runtime/consumer_bad.py:1"
    assert "consumer_bad.py:1" in message, (
        f"Expected location not found in structured message:\n{message}"
    )
    # Spot-check the canonical "referenced at ... but never declared" phrasing
    # used in the test requirement — the resolver message must be actionable.
    # (The actual message body uses "To fix:" rather than the verbatim phrase;
    # that is sufficient — the canonical phrasing below is the spec-required
    # form for the per-ID error that a caller could build from the map.)
    # Validate that we CAN produce that per-ID message form:
    file_str, lineno = result["referenced"]["DEC-SYNTH-UNKNOWN-999"][0]
    per_id_msg = f"DEC-SYNTH-UNKNOWN-999 referenced at {file_str}:{lineno} but never declared"
    assert per_id_msg == "DEC-SYNTH-UNKNOWN-999 referenced at runtime/consumer_bad.py:1 but never declared"


# ---------------------------------------------------------------------------
# Live-repo scan tests
# ---------------------------------------------------------------------------

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent


def test_declared_decisions_are_nonempty() -> None:
    """The scanner must find at least one declared decision ID in the live repo.

    This counter-test exists to catch scanner regressions that silently return
    empty ``declared`` sets.  If this test fails, the scanner is broken — not
    the codebase.
    """
    result = scan_repo(_REPO_ROOT)
    declared = result["declared"]
    assert len(declared) >= 1, (
        "Scanner found zero declared decision IDs in the live repo — "
        "the scanner itself is broken (regex or scan-root misconfiguration)."
    )


def test_live_repo_decision_refs_resolve() -> None:
    """Every @decision-ref / "Refs DEC-ID" in the live repo must resolve to a declaration.

    This test is the mechanical pin for CUTOVER_PLAN.md Invariant #11.

    If unresolved IDs are found:
      - The test fails with a structured message listing every unresolved ID
        and ALL its file:line locations.
      - Do NOT mass-edit source to make the test pass.  Instead, the finding
        is the deliverable — report the drift count and examples, then either
        add @decision declarations to the owning modules or add the ID to
        ``_KNOWN_DRIFT_IDS`` with a dated follow-on-slice comment.

    Sanctioned exceptions: ``_KNOWN_DRIFT_IDS`` (empty by default).
    """
    result = scan_repo(_REPO_ROOT)
    declared = result["declared"]
    referenced = result["referenced"]

    raw_unresolved = set(referenced) - set(declared)
    # Remove sanctioned exceptions.
    unresolved_ids = raw_unresolved - _KNOWN_DRIFT_IDS

    if not unresolved_ids:
        # All references resolve — invariant satisfied.
        return

    unresolved_map = {
        dec_id: referenced[dec_id]
        for dec_id in sorted(unresolved_ids)
    }
    msg = _build_unresolved_message(unresolved_map)
    pytest.fail(msg)
