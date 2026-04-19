"""Mechanical pin for the dated cutover invariant-coverage matrix.

@decision DEC-CLAUDEX-CUTOVER-INVARIANT-COVERAGE-MATRIX-001
Title: ClauDEX/CUTOVER_INVARIANT_COVERAGE_2026-04-18.md must remain structurally complete across all 16 CUTOVER_PLAN invariants
Status: proposed
Rationale: CUTOVER_PLAN.md's "cutover is not complete without mechanical
  checks" acceptance bar (line 1430) is satisfied for each invariant
  individually by sibling invariant-pin tests (`test_decision_ref_resolution`,
  `test_command_intent_single_authority`, `test_retrieval_layer_downstream_invariant`,
  `test_current_lane_state_invariants`, etc.). This test adds one more layer:
  a pin on the coverage **matrix itself**, ensuring that a future author
  cannot silently (a) remove an invariant row from the dated coverage
  artifact, (b) leave a row with an empty backing-test cell, or (c) break
  the matrix's structural shape so downstream audits silently degrade.

  The artifact being pinned is
  ``ClauDEX/CUTOVER_INVARIANT_COVERAGE_2026-04-18.md``. This pin does NOT
  assert the artifact's cited test files actually exist on disk — that is
  the job of the dated artifact's own authors plus the sibling invariant-
  pin tests. This pin's narrower job is:

  - **Row count:** the coverage table MUST contain exactly 16 data rows,
    one per CUTOVER_PLAN invariant (#1 through #16).
  - **Row coverage:** every data row's "Backing tests" column MUST be
    non-empty (no placeholder dashes, no `TBD`, no `-`).
  - **Status discipline:** every data row's "Status" column MUST be
    `covered` (not `partial`, not `missing`). When a genuine gap emerges,
    the sibling invariant-pin tests will fail first; if the artifact is
    later edited to reflect the gap by setting `partial` / `missing`, this
    test fails too — surfacing the downgrade as a structured reminder.
  - **Invariant-number coverage:** the set of invariant numbers present in
    the table MUST equal exactly {1, 2, 3, ..., 16}.

  Synthetic fixtures prove the scanner catches every shape of regression
  (missing row, empty backing cell, downgraded status, duplicated row).

Adjacent authorities:
  - ``ClauDEX/CUTOVER_PLAN.md`` § "Invariants That Must Become Tests" —
    the primary authority for what invariants exist.
  - ``ClauDEX/CUTOVER_INVARIANT_COVERAGE_2026-04-18.md`` — the dated
    coverage artifact this test validates (successor to 2026-04-17).
  - Sibling invariant-pin tests (the individual rows backing each
    invariant): ``test_decision_ref_resolution.py``,
    ``tests/runtime/policies/test_command_intent_single_authority.py``,
    ``test_retrieval_layer_downstream_invariant.py``,
    ``test_current_lane_state_invariants.py``,
    ``test_handoff_artifact_path_invariants.py``,
    ``test_stage_registry.py``, ``test_dispatch_engine.py``,
    ``test_hook_manifest.py``, ``test_hook_validate_settings.py``,
    ``test_constitution_registry.py``,
    ``tests/runtime/policies/test_bash_git_who.py``,
    ``tests/runtime/policies/test_capability_gate_invariants.py``,
    ``test_hook_doc_validation.py``, ``test_hook_doc_projection.py``,
    ``test_hook_doc_check_cli.py``, ``test_prompt_pack.py``,
    ``test_prompt_pack_resolver.py``, ``test_prompt_pack_validation.py``,
    ``test_decision_work_registry.py``,
    ``test_decision_digest_projection.py``,
    ``test_projection_reflow.py``, ``test_projection_schemas.py``,
    ``test_memory_retrieval.py``, ``test_goal_continuation.py``,
    ``test_goal_contract_codec.py``,
    ``tests/runtime/policies/test_post_bash_eval_invalidation.py``,
    ``test_bridge_permissions.py``.

Shadow-only discipline: this test is stdlib-only (``re``, ``pathlib``).
No SQLite, no git subprocess, no network, no importing of the runtime
decision-work-registry authority. It is a static fixture-reader.
"""

from __future__ import annotations

import re
import textwrap
from pathlib import Path
from typing import Dict, List, Set, Tuple

import pytest


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

_REPO_ROOT = Path(__file__).resolve().parents[2]

COVERAGE_DOC = (
    _REPO_ROOT / "ClauDEX" / "CUTOVER_INVARIANT_COVERAGE_2026-04-18.md"
)

# The canonical invariant numbers from CUTOVER_PLAN.md § Invariants That
# Must Become Tests (lines 1428–1456). If CUTOVER_PLAN legitimately grows
# beyond 16 invariants, a follow-on slice MUST update this constant and
# extend the coverage doc in the same change.
_EXPECTED_INVARIANT_NUMBERS: Set[int] = set(range(1, 17))

# Valid status values in the coverage matrix. Only `covered` is permitted
# when this doc is in a clean state; `partial` / `missing` exist in the
# vocabulary but must not appear in the live artifact.
_ALLOWED_STATUS_VALUES: Set[str] = {"covered", "partial", "missing"}
_REQUIRED_STATUS_VALUE: str = "covered"


# ---------------------------------------------------------------------------
# Parser — extracts the invariant coverage table from the dated artifact.
# ---------------------------------------------------------------------------

# The table is a markdown-flavored pipe table. Header row pattern:
#   | # | Invariant | Status | Backing tests |
# Separator row pattern:
#   | --- | --- | --- | --- |
# Data row pattern:
#   | <int> | <prose> | <status> | <prose with backticks, links> |
_TABLE_ROW_RE = re.compile(r"^\s*\|\s*(\d+)\s*\|\s*(.+?)\s*\|\s*(.+?)\s*\|\s*(.+?)\s*\|\s*$")


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _parse_table_rows_from_text(text: str) -> List[Tuple[int, str, str, str]]:
    """Parse every markdown-flavored pipe-table data row (#, invariant, status, backing).

    Header and separator rows are filtered out by requiring a numeric
    first column. Returns a list of tuples in document order.
    """
    rows: List[Tuple[int, str, str, str]] = []
    for line in text.splitlines():
        match = _TABLE_ROW_RE.match(line)
        if not match:
            continue
        try:
            num = int(match.group(1))
        except ValueError:
            continue
        invariant = match.group(2).strip()
        status = match.group(3).strip()
        backing = match.group(4).strip()
        rows.append((num, invariant, status, backing))
    return rows


def _parse_table_rows() -> List[Tuple[int, str, str, str]]:
    return _parse_table_rows_from_text(_read(COVERAGE_DOC))


# ---------------------------------------------------------------------------
# Tests — live artifact
# ---------------------------------------------------------------------------


class TestCoverageDocExists:
    def test_coverage_doc_file_is_present(self) -> None:
        assert COVERAGE_DOC.exists(), (
            f"Coverage matrix artifact missing at {COVERAGE_DOC}. "
            "The active pinned artifact is CUTOVER_INVARIANT_COVERAGE_2026-04-18.md "
            "(successor to 2026-04-17). If this artifact is being superseded "
            "by a newer dated file, update the COVERAGE_DOC constant in this "
            "test module in the same slice that introduces the successor."
        )


class TestCoverageRowCount:
    """The coverage table MUST contain exactly one data row per declared
    CUTOVER_PLAN invariant (16 total).
    """

    def test_coverage_table_has_exactly_16_data_rows(self) -> None:
        rows = _parse_table_rows()
        assert len(rows) == 16, (
            f"Coverage matrix at {COVERAGE_DOC.relative_to(_REPO_ROOT)} "
            f"contains {len(rows)} data row(s); expected exactly 16 "
            f"(one per CUTOVER_PLAN invariant #1–#16). Row numbers found: "
            f"{sorted(n for n, *_ in rows)}"
        )


class TestCoverageInvariantNumbers:
    """Every invariant number 1..16 must be present; no duplicates."""

    def test_invariant_numbers_cover_1_through_16_exactly(self) -> None:
        rows = _parse_table_rows()
        nums = [n for n, *_ in rows]
        present = set(nums)
        assert present == _EXPECTED_INVARIANT_NUMBERS, (
            f"Coverage matrix invariant-number set mismatch.\n"
            f"  expected: {sorted(_EXPECTED_INVARIANT_NUMBERS)}\n"
            f"  present:  {sorted(present)}\n"
            f"  missing:  {sorted(_EXPECTED_INVARIANT_NUMBERS - present)}\n"
            f"  extra:    {sorted(present - _EXPECTED_INVARIANT_NUMBERS)}"
        )

    def test_no_duplicate_invariant_numbers(self) -> None:
        rows = _parse_table_rows()
        nums = [n for n, *_ in rows]
        duplicates = sorted({n for n in nums if nums.count(n) > 1})
        assert not duplicates, (
            f"Coverage matrix has duplicate invariant number row(s): {duplicates}"
        )


class TestCoverageBackingTestsNonEmpty:
    """Every row's Backing tests cell must be non-empty, non-placeholder."""

    _PLACEHOLDERS = frozenset({"-", "—", "–", "tbd", "TBD", "n/a", "N/A", "(pending)", ""})

    def test_every_row_has_non_empty_backing_tests_cell(self) -> None:
        rows = _parse_table_rows()
        offenders: List[str] = []
        for num, invariant, status, backing in rows:
            cleaned = backing.strip()
            if not cleaned or cleaned in self._PLACEHOLDERS:
                offenders.append(
                    f"  - Invariant #{num}: cell is empty/placeholder "
                    f"({backing!r}); invariant prose: {invariant!r}"
                )
        assert not offenders, (
            "Coverage matrix has rows with empty or placeholder Backing "
            "tests cells. Every invariant row MUST cite at least one "
            "concrete backing test file.\n" + "\n".join(offenders)
        )


class TestCoverageStatusDiscipline:
    """Every row's Status column must be `covered`. Downgrades surface as
    a structured test failure.
    """

    def test_every_row_has_covered_status(self) -> None:
        rows = _parse_table_rows()
        offenders: List[str] = []
        for num, invariant, status, backing in rows:
            cleaned = status.strip().lower()
            if cleaned != _REQUIRED_STATUS_VALUE:
                offenders.append(
                    f"  - Invariant #{num}: status {status!r} (expected "
                    f"{_REQUIRED_STATUS_VALUE!r}). If the invariant's "
                    "backing test truly regressed or became partial, the "
                    "sibling invariant-pin test should have already "
                    "failed; this downgrade is a second signal."
                )
        assert not offenders, (
            "Coverage matrix has rows with non-`covered` status. The "
            "matrix's purpose is to document complete coverage; any "
            "`partial` or `missing` entry requires an immediate repair "
            "slice, not a doc-only downgrade.\n" + "\n".join(offenders)
        )

    def test_status_values_are_from_allowed_vocabulary(self) -> None:
        rows = _parse_table_rows()
        offenders: List[str] = []
        for num, invariant, status, backing in rows:
            cleaned = status.strip().lower()
            if cleaned not in _ALLOWED_STATUS_VALUES:
                offenders.append(
                    f"  - Invariant #{num}: unrecognized status {status!r}. "
                    f"Allowed values: {sorted(_ALLOWED_STATUS_VALUES)}."
                )
        assert not offenders, (
            "Coverage matrix has rows with unrecognized status values.\n"
            + "\n".join(offenders)
        )


class TestArtifactDecisionHeader:
    """The coverage doc must open with its DEC-annotation so a future
    reader can locate its authority record.
    """

    _REQUIRED_DEC_ID = "DEC-CLAUDEX-CUTOVER-INVARIANT-COVERAGE-MATRIX-001"

    def test_artifact_names_its_decision_record(self) -> None:
        text = _read(COVERAGE_DOC)
        assert self._REQUIRED_DEC_ID in text, (
            f"Coverage matrix artifact must mention its decision record "
            f"{self._REQUIRED_DEC_ID!r} so a reader can locate the "
            "authority for the artifact's scope and discipline. The "
            "canonical mention appears in the 'Decision record:' line in "
            "the doc's header section."
        )


# ---------------------------------------------------------------------------
# Synthetic fixtures — prove the scanner catches every shape of regression.
# ---------------------------------------------------------------------------

# Clean fixture mirrors the live artifact's structural shape at small scale.
# Status, invariant text, and backing are all minimally valid.
_CLEAN_FIXTURE = """\
# Fixture — Coverage Matrix

## Coverage table

| # | Invariant | Status | Backing tests |
|---|---|---|---|
| 1 | Inv one | covered | tests/one.py |
| 2 | Inv two | covered | tests/two.py |
| 3 | Inv three | covered | tests/three.py |
| 4 | Inv four | covered | tests/four.py |
| 5 | Inv five | covered | tests/five.py |
| 6 | Inv six | covered | tests/six.py |
| 7 | Inv seven | covered | tests/seven.py |
| 8 | Inv eight | covered | tests/eight.py |
| 9 | Inv nine | covered | tests/nine.py |
| 10 | Inv ten | covered | tests/ten.py |
| 11 | Inv eleven | covered | tests/eleven.py |
| 12 | Inv twelve | covered | tests/twelve.py |
| 13 | Inv thirteen | covered | tests/thirteen.py |
| 14 | Inv fourteen | covered | tests/fourteen.py |
| 15 | Inv fifteen | covered | tests/fifteen.py |
| 16 | Inv sixteen | covered | tests/sixteen.py |
"""


_MISSING_ROW_FIXTURE = """\
# Fixture — Missing row

## Coverage table

| # | Invariant | Status | Backing tests |
|---|---|---|---|
| 1 | Inv one | covered | tests/one.py |
| 2 | Inv two | covered | tests/two.py |
| 3 | Inv three | covered | tests/three.py |
| 4 | Inv four | covered | tests/four.py |
| 5 | Inv five | covered | tests/five.py |
| 6 | Inv six | covered | tests/six.py |
| 7 | Inv seven | covered | tests/seven.py |
| 8 | Inv eight | covered | tests/eight.py |
| 9 | Inv nine | covered | tests/nine.py |
| 10 | Inv ten | covered | tests/ten.py |
| 11 | Inv eleven | covered | tests/eleven.py |
| 12 | Inv twelve | covered | tests/twelve.py |
| 13 | Inv thirteen | covered | tests/thirteen.py |
| 14 | Inv fourteen | covered | tests/fourteen.py |
| 15 | Inv fifteen | covered | tests/fifteen.py |
"""


_EMPTY_BACKING_FIXTURE = """\
# Fixture — Empty backing

## Coverage table

| # | Invariant | Status | Backing tests |
|---|---|---|---|
| 1 | Inv one | covered | tests/one.py |
| 2 | Inv two | covered | - |
| 3 | Inv three | covered | tests/three.py |
| 4 | Inv four | covered | tests/four.py |
| 5 | Inv five | covered | tests/five.py |
| 6 | Inv six | covered | tests/six.py |
| 7 | Inv seven | covered | tests/seven.py |
| 8 | Inv eight | covered | tests/eight.py |
| 9 | Inv nine | covered | tests/nine.py |
| 10 | Inv ten | covered | tests/ten.py |
| 11 | Inv eleven | covered | tests/eleven.py |
| 12 | Inv twelve | covered | tests/twelve.py |
| 13 | Inv thirteen | covered | tests/thirteen.py |
| 14 | Inv fourteen | covered | tests/fourteen.py |
| 15 | Inv fifteen | covered | tests/fifteen.py |
| 16 | Inv sixteen | covered | tests/sixteen.py |
"""


_DOWNGRADED_STATUS_FIXTURE = """\
# Fixture — Downgraded status

## Coverage table

| # | Invariant | Status | Backing tests |
|---|---|---|---|
| 1 | Inv one | covered | tests/one.py |
| 2 | Inv two | partial | tests/two.py |
| 3 | Inv three | covered | tests/three.py |
| 4 | Inv four | covered | tests/four.py |
| 5 | Inv five | covered | tests/five.py |
| 6 | Inv six | covered | tests/six.py |
| 7 | Inv seven | covered | tests/seven.py |
| 8 | Inv eight | covered | tests/eight.py |
| 9 | Inv nine | covered | tests/nine.py |
| 10 | Inv ten | covered | tests/ten.py |
| 11 | Inv eleven | covered | tests/eleven.py |
| 12 | Inv twelve | covered | tests/twelve.py |
| 13 | Inv thirteen | covered | tests/thirteen.py |
| 14 | Inv fourteen | covered | tests/fourteen.py |
| 15 | Inv fifteen | covered | tests/fifteen.py |
| 16 | Inv sixteen | covered | tests/sixteen.py |
"""


_DUPLICATE_ROW_FIXTURE = """\
# Fixture — Duplicate invariant number

## Coverage table

| # | Invariant | Status | Backing tests |
|---|---|---|---|
| 1 | Inv one | covered | tests/one.py |
| 2 | Inv two | covered | tests/two.py |
| 3 | Inv three | covered | tests/three.py |
| 3 | Inv three DUPLICATE | covered | tests/three_dup.py |
| 5 | Inv five | covered | tests/five.py |
| 6 | Inv six | covered | tests/six.py |
| 7 | Inv seven | covered | tests/seven.py |
| 8 | Inv eight | covered | tests/eight.py |
| 9 | Inv nine | covered | tests/nine.py |
| 10 | Inv ten | covered | tests/ten.py |
| 11 | Inv eleven | covered | tests/eleven.py |
| 12 | Inv twelve | covered | tests/twelve.py |
| 13 | Inv thirteen | covered | tests/thirteen.py |
| 14 | Inv fourteen | covered | tests/fourteen.py |
| 15 | Inv fifteen | covered | tests/fifteen.py |
| 16 | Inv sixteen | covered | tests/sixteen.py |
"""


class TestScannerCatchesSyntheticRegressions:
    """Positive fixtures — every regression shape must be caught."""

    def test_clean_fixture_parses_16_rows(self) -> None:
        rows = _parse_table_rows_from_text(_CLEAN_FIXTURE)
        assert len(rows) == 16

    def test_clean_fixture_covers_1_through_16(self) -> None:
        rows = _parse_table_rows_from_text(_CLEAN_FIXTURE)
        assert {n for n, *_ in rows} == _EXPECTED_INVARIANT_NUMBERS

    def test_clean_fixture_all_rows_have_backing(self) -> None:
        rows = _parse_table_rows_from_text(_CLEAN_FIXTURE)
        for num, _, _, backing in rows:
            assert backing.strip() and backing.strip() != "-", (
                f"clean fixture row #{num} unexpectedly empty: {backing!r}"
            )

    def test_missing_row_fixture_is_detected(self) -> None:
        rows = _parse_table_rows_from_text(_MISSING_ROW_FIXTURE)
        assert len(rows) == 15, (
            f"expected 15 rows in missing-row fixture; got {len(rows)}"
        )
        present = {n for n, *_ in rows}
        missing = _EXPECTED_INVARIANT_NUMBERS - present
        assert missing == {16}, (
            f"missing-row fixture should lose invariant #16; actual "
            f"missing set: {missing}"
        )

    def test_empty_backing_fixture_is_detected(self) -> None:
        rows = _parse_table_rows_from_text(_EMPTY_BACKING_FIXTURE)
        assert len(rows) == 16
        # Row #2 has backing "-" which is a placeholder.
        placeholders = frozenset(
            {"-", "—", "–", "tbd", "TBD", "n/a", "N/A", "(pending)", ""}
        )
        offenders = [
            n for n, _, _, b in rows if b.strip() in placeholders or not b.strip()
        ]
        assert offenders == [2], (
            f"empty-backing fixture should flag row #2; actual offenders: {offenders}"
        )

    def test_downgraded_status_fixture_is_detected(self) -> None:
        rows = _parse_table_rows_from_text(_DOWNGRADED_STATUS_FIXTURE)
        assert len(rows) == 16
        offenders = [
            n for n, _, status, _ in rows
            if status.strip().lower() != _REQUIRED_STATUS_VALUE
        ]
        assert offenders == [2], (
            f"downgraded-status fixture should flag row #2; actual offenders: {offenders}"
        )

    def test_duplicate_row_fixture_is_detected(self) -> None:
        rows = _parse_table_rows_from_text(_DUPLICATE_ROW_FIXTURE)
        # Fixture has 16 data rows but with a duplicate of #3 and missing #4.
        nums = [n for n, *_ in rows]
        duplicates = sorted({n for n in nums if nums.count(n) > 1})
        missing = _EXPECTED_INVARIANT_NUMBERS - set(nums)
        assert duplicates == [3], (
            f"duplicate-row fixture should report dup on #3; actual: {duplicates}"
        )
        assert missing == {4}, (
            f"duplicate-row fixture should also report #4 missing; actual: {missing}"
        )


class TestModuleSurface:
    """Scanner-sanity pin — the parser must find a non-zero number of
    rows on the live artifact. Catches a parser regression that silently
    returns an empty list.
    """

    def test_live_artifact_parser_returns_non_empty(self) -> None:
        rows = _parse_table_rows()
        assert rows, (
            f"Parser returned zero rows from {COVERAGE_DOC}. Either the "
            "file is empty / missing, or the table regex has regressed. "
            f"File exists: {COVERAGE_DOC.exists()}"
        )
