"""Mechanical pin for the GS1 goal decision digest artifact.

This module verifies structural and content invariants of
``ClauDEX/GS1_GOAL_DIGEST_2026-04-18.md``. The artifact is a
planner-owned post-guardian projection whose authority is recorded in
``DEC-GS1-GOAL-DIGEST-001`` (the artifact's self-decision record). This
test file mechanically pins those invariants so a future author cannot
silently corrupt or hollow out the digest's load-bearing claims.

Scope and discipline:
- stdlib-only: ``re``, ``pathlib``, ``subprocess``.
- NO mocking, NO runtime imports, NO SQLite, NO git log --grep.
- All git SHA verification uses ``git cat-file -e <sha>^{commit}``
  (existence check) or ``git log -1 --format=%B <sha>`` (body scan).
- DEC-id entries are parsed from the artifact, not hardcoded; each
  confirmed entry is then verified against the referenced commit.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path
from typing import List, Tuple

import pytest

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_REPO_ROOT = Path(__file__).resolve().parents[2]
_DIGEST_DOC = _REPO_ROOT / "ClauDEX" / "GS1_GOAL_DIGEST_2026-04-18.md"
_CUTOVER_PLAN = _REPO_ROOT / "ClauDEX" / "CUTOVER_PLAN.md"
_GOAL_CONTINUATION_TEST = (
    _REPO_ROOT / "tests" / "runtime" / "test_goal_continuation.py"
)

# The DEC-id that is explicitly documented as DROPPED in the artifact.
# It must be excluded from the confirmed-entry count and git-log checks.
_DROPPED_DEC_ID = "DEC-CLAUDEX-CUTOVER-INVARIANT-COVERAGE-MATRIX-001"

# Expected counts from the artifact's authoritative final count line.
_EXPECTED_WORK_ITEM_ROWS = 8
_EXPECTED_CONFIRMED_DEC_IDS = 7


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _git_commit_exists(sha: str) -> subprocess.CompletedProcess:
    """Return CompletedProcess for 'git cat-file -e <sha>^{commit}'."""
    return subprocess.run(
        ["git", "-C", str(_REPO_ROOT), "cat-file", "-e", f"{sha}^{{commit}}"],
        capture_output=True,
    )


def _git_commit_body(sha: str) -> subprocess.CompletedProcess:
    """Return CompletedProcess for 'git log -1 --format=%B <sha>'."""
    return subprocess.run(
        ["git", "-C", str(_REPO_ROOT), "log", "-1", "--format=%B", sha],
        capture_output=True,
        text=True,
    )


def _parse_work_item_table(text: str) -> List[Tuple[str, str, str, str]]:
    """Parse rows from the '## Landed Work-Items Table' section.

    Returns list of (work_item_id, status, head_sha, title) tuples.
    Stops at the next '##' heading. Table cells may contain backtick
    wrappers which are stripped.
    """
    # Locate the section.
    section_match = re.search(r"^## Landed Work-Items Table", text, re.MULTILINE)
    if not section_match:
        return []
    section_text = text[section_match.end():]
    # Stop at the next heading.
    next_heading = re.search(r"^##\s", section_text, re.MULTILINE)
    if next_heading:
        section_text = section_text[: next_heading.start()]

    # Header row pattern: | work_item_id | status | head_sha | title |
    # Data rows: first cell is not purely dashes/spaces.
    row_re = re.compile(
        r"^\s*\|\s*(.+?)\s*\|\s*(.+?)\s*\|\s*(.+?)\s*\|\s*(.+?)\s*\|\s*$"
    )
    rows: List[Tuple[str, str, str, str]] = []
    for line in section_text.splitlines():
        m = row_re.match(line)
        if not m:
            continue
        c1, c2, c3, c4 = (m.group(i).strip().strip("`") for i in (1, 2, 3, 4))
        # Skip header row (contains 'work_item_id') and separator rows (all dashes).
        if "work_item_id" in c1 or re.fullmatch(r"[-\s|]+", line):
            continue
        if re.fullmatch(r"[-]+", c1):
            continue
        rows.append((c1, c2, c3, c4))
    return rows


def _parse_dec_id_entries(text: str) -> List[Tuple[str, str, bool]]:
    """Parse DEC-id entries from '## DEC-id Inventory'.

    Returns list of (dec_id, sha, is_confirmed) tuples.
    A sub-heading '### DEC-...' signals an entry. The sha is extracted
    from the first '**Commit:** `<sha>`' line within that entry.
    Whether the entry is confirmed is determined by absence of
    'NOT FOUND' or 'DROPPED' in its body (before the next sub-heading).
    """
    section_match = re.search(r"^## DEC-id Inventory", text, re.MULTILINE)
    if not section_match:
        return []
    section_text = text[section_match.end():]
    # Stop at the next ## heading.
    next_h2 = re.search(r"^## ", section_text, re.MULTILINE)
    if next_h2:
        section_text = section_text[: next_h2.start()]

    # Each ### DEC-... is an entry.
    entry_re = re.compile(r"^### (DEC-\S+)", re.MULTILINE)
    commit_re = re.compile(r"\*\*Commit:\*\*\s+`([^`]+)`")

    entries: List[Tuple[str, str, bool]] = []
    positions = [(m.start(), m.group(1)) for m in entry_re.finditer(section_text)]
    for idx, (pos, dec_id) in enumerate(positions):
        # Body runs from end of this heading line to start of next heading (or end).
        start = pos
        end = positions[idx + 1][0] if idx + 1 < len(positions) else len(section_text)
        body = section_text[start:end]

        commit_m = commit_re.search(body)
        sha = commit_m.group(1) if commit_m else ""

        # 'NOT FOUND' in the Verification line means the commit lacks the DEC-id.
        # 'DROPPED' in the Disposition line means it is excluded from the count.
        not_found = bool(re.search(r"\bNOT FOUND\b", body))
        dropped = bool(re.search(r"\bDROPPED\b", body))
        is_confirmed = not (not_found or dropped)

        entries.append((dec_id, sha, is_confirmed))

    return entries


# ---------------------------------------------------------------------------
# Test Classes
# ---------------------------------------------------------------------------


class TestGoalDigestDocExists:
    """The artifact must be present at its pinned path."""

    def test_digest_doc_file_is_present(self) -> None:
        assert _DIGEST_DOC.exists(), (
            f"GS1 goal digest artifact missing at {_DIGEST_DOC}. "
            "This file is a read-only planner-owned projection (DEC-GS1-GOAL-DIGEST-001). "
            "It must not be deleted or moved without a supervisor-approved successor slice."
        )


class TestGoalDigestTitleAndFrontMatter:
    """First non-empty line is the canonical title; body contains key phrases."""

    def test_first_non_empty_line_is_canonical_title(self) -> None:
        text = _read(_DIGEST_DOC)
        first_non_empty = next(
            (line for line in text.splitlines() if line.strip()), ""
        )
        expected = "# GS1 Goal Decision Digest (2026-04-18)"
        assert first_non_empty == expected, (
            f"First non-empty line mismatch.\n"
            f"  expected: {expected!r}\n"
            f"  actual:   {first_non_empty!r}"
        )

    def test_body_contains_subordinate_companion_phrase(self) -> None:
        text = _read(_DIGEST_DOC)
        assert "subordinate companion" in text, (
            "Digest must contain the phrase 'subordinate companion' in its front-matter "
            "to declare that it is a derived projection, not a parallel authority."
        )

    def test_body_references_decision_digest_projection_module(self) -> None:
        text = _read(_DIGEST_DOC)
        assert "runtime/core/decision_digest_projection.py" in text, (
            "Digest must reference 'runtime/core/decision_digest_projection.py' "
            "as the runtime projection authority."
        )


class TestGoalDigestAuthorityDiscipline:
    """The '## Authority Discipline' section must exist and name its three pillars."""

    def test_authority_discipline_section_present(self) -> None:
        text = _read(_DIGEST_DOC)
        assert re.search(r"(?m)^## Authority Discipline", text), (
            "Digest must contain '## Authority Discipline' section header."
        )

    def test_authority_discipline_names_decision_digest_projection(self) -> None:
        text = _read(_DIGEST_DOC)
        assert "runtime/core/decision_digest_projection.py" in text, (
            "Authority Discipline section must reference "
            "'runtime/core/decision_digest_projection.py'."
        )

    def test_authority_discipline_names_decision_work_registry(self) -> None:
        text = _read(_DIGEST_DOC)
        assert "runtime/core/decision_work_registry.py" in text, (
            "Authority Discipline section must reference "
            "'runtime/core/decision_work_registry.py'."
        )

    def test_authority_discipline_names_planner_owned_boundary_test(self) -> None:
        text = _read(_DIGEST_DOC)
        assert "tests/runtime/test_goal_continuation.py::TestPlannerOwnedBoundary" in text, (
            "Authority Discipline section must reference "
            "'tests/runtime/test_goal_continuation.py::TestPlannerOwnedBoundary' "
            "as the mechanical pin for Invariant #14."
        )


class TestGoalDigestWorkItemTableIntegrity:
    """The work-item table must have exactly 8 landed rows with resolvable SHAs."""

    def test_work_item_table_has_exactly_8_data_rows(self) -> None:
        text = _read(_DIGEST_DOC)
        rows = _parse_work_item_table(text)
        assert len(rows) == _EXPECTED_WORK_ITEM_ROWS, (
            f"Work-items table must have exactly {_EXPECTED_WORK_ITEM_ROWS} data rows; "
            f"found {len(rows)}. "
            f"work_item_ids found: {[r[0] for r in rows]}"
        )

    def test_all_work_item_rows_have_landed_status(self) -> None:
        text = _read(_DIGEST_DOC)
        rows = _parse_work_item_table(text)
        offenders = [
            (idx, row[0], row[1])
            for idx, row in enumerate(rows)
            if row[1].lower() != "landed"
        ]
        assert not offenders, (
            "All work-item rows must have status 'landed'.\n"
            + "\n".join(
                f"  row {idx}: work_item_id={wid!r} status={status!r}"
                for idx, wid, status in offenders
            )
        )

    def test_all_work_item_shas_resolve_in_git(self) -> None:
        text = _read(_DIGEST_DOC)
        rows = _parse_work_item_table(text)
        failures: List[str] = []
        for idx, (wid, status, sha, title) in enumerate(rows):
            result = _git_commit_exists(sha)
            if result.returncode != 0:
                failures.append(
                    f"  row {idx}: work_item_id={wid!r} sha={sha!r} "
                    f"stderr={result.stderr!r}"
                )
        assert not failures, (
            "One or more work-item SHAs do not resolve as commits in this repo:\n"
            + "\n".join(failures)
        )


class TestGoalDigestDecIdLineage:
    """DEC-id inventory: exactly 7 confirmed entries, each verified in git log."""

    def test_exactly_7_confirmed_dec_id_entries(self) -> None:
        text = _read(_DIGEST_DOC)
        entries = _parse_dec_id_entries(text)
        confirmed = [(d, s) for d, s, ok in entries if ok]
        assert len(confirmed) == _EXPECTED_CONFIRMED_DEC_IDS, (
            f"Expected exactly {_EXPECTED_CONFIRMED_DEC_IDS} confirmed DEC-id entries; "
            f"found {len(confirmed)}.\n"
            f"  All entries: {[(d, ok) for d, _, ok in entries]}"
        )

    def test_dropped_dec_id_is_excluded(self) -> None:
        text = _read(_DIGEST_DOC)
        entries = _parse_dec_id_entries(text)
        dropped = [(d, s, ok) for d, s, ok in entries if d == _DROPPED_DEC_ID]
        assert dropped, (
            f"Expected to find {_DROPPED_DEC_ID} listed in the DEC-id inventory "
            "(as a DROPPED entry). The artifact explicitly records what was excluded."
        )
        for dec_id, sha, is_confirmed in dropped:
            assert not is_confirmed, (
                f"{_DROPPED_DEC_ID} must be marked as NOT confirmed/DROPPED, "
                f"but the parser classified it as confirmed."
            )

    def test_confirmed_dec_ids_appear_in_commit_messages(self) -> None:
        text = _read(_DIGEST_DOC)
        entries = _parse_dec_id_entries(text)
        confirmed = [(d, s) for d, s, ok in entries if ok]
        failures: List[str] = []
        for dec_id, sha in confirmed:
            result = _git_commit_body(sha)
            if result.returncode != 0:
                failures.append(
                    f"  {dec_id}: git log failed for sha={sha!r} "
                    f"stderr={result.stderr!r}"
                )
                continue
            if dec_id not in result.stdout:
                failures.append(
                    f"  {dec_id}: NOT found in commit body for sha={sha!r}. "
                    f"First 200 chars of body: {result.stdout[:200]!r}"
                )
        assert not failures, (
            "One or more confirmed DEC-ids were not found in their referenced "
            "commit message body (via git log -1 --format=%B):\n"
            + "\n".join(failures)
        )


class TestGoalDigestInvariant14Pin:
    """Invariant #14 blockquote, CUTOVER_PLAN prose, and TestPlannerOwnedBoundary must all be present."""

    _INVARIANT_14_VERBATIM = (
        "> 14. Post-guardian continuation is planner-owned, "
        "not reviewer- or hook-owned."
    )
    _INVARIANT_14_PROSE = (
        "14. Post-guardian continuation is planner-owned, "
        "not reviewer- or hook-owned."
    )

    def test_digest_contains_invariant_14_blockquote(self) -> None:
        text = _read(_DIGEST_DOC)
        assert self._INVARIANT_14_VERBATIM in text, (
            f"Digest must contain the verbatim blockquote:\n"
            f"  {self._INVARIANT_14_VERBATIM!r}\n"
            "This is the load-bearing Invariant #14 citation."
        )

    def test_cutover_plan_contains_invariant_14_prose(self) -> None:
        text = _read(_CUTOVER_PLAN)
        assert self._INVARIANT_14_PROSE in text, (
            f"CUTOVER_PLAN.md must contain the prose:\n"
            f"  {self._INVARIANT_14_PROSE!r}\n"
            "If CUTOVER_PLAN.md was edited, the digest's blockquote is now stale."
        )

    def test_goal_continuation_test_has_planner_owned_boundary_class(self) -> None:
        text = _read(_GOAL_CONTINUATION_TEST)
        assert re.search(r"^class TestPlannerOwnedBoundary", text, re.MULTILINE), (
            "test_goal_continuation.py must contain 'class TestPlannerOwnedBoundary' "
            "(the mechanical pin for Invariant #14). "
            f"Searched in {_GOAL_CONTINUATION_TEST}."
        )


class TestGoalDigestSelfDecisionRecord:
    """The artifact must carry its own @decision block for DEC-GS1-GOAL-DIGEST-001."""

    _DEC_ANNOTATION = "@decision DEC-GS1-GOAL-DIGEST-001"

    def test_self_decision_annotation_present(self) -> None:
        text = _read(_DIGEST_DOC)
        assert self._DEC_ANNOTATION in text, (
            f"Digest must contain the self-decision annotation "
            f"{self._DEC_ANNOTATION!r}."
        )

    def test_self_decision_block_has_required_fields(self) -> None:
        text = _read(_DIGEST_DOC)
        ann_idx = text.find(self._DEC_ANNOTATION)
        assert ann_idx != -1, (
            f"Annotation {self._DEC_ANNOTATION!r} not found — cannot check fields."
        )
        # Check within a window of ~20 lines (~1200 chars) following the annotation.
        window = text[ann_idx: ann_idx + 1200]
        for field in ("Title:", "Status:", "Rationale:"):
            assert field in window, (
                f"Self-decision block for {self._DEC_ANNOTATION!r} must contain "
                f"'{field}' within ~20 lines of the annotation. "
                f"Window (first 300 chars): {window[:300]!r}"
            )


class TestGoalDigestSuccessorHistoryHeader:
    """The '## Successor History' section header must be present."""

    def test_successor_history_section_present(self) -> None:
        text = _read(_DIGEST_DOC)
        assert re.search(r"(?m)^## Successor History", text), (
            "Digest must contain the '## Successor History' section header "
            "so future slices can append to the revision trail."
        )
